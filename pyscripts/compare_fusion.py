"""
Four ways to turn one recording's marker corners into a pose, compared on the
same data — does a joint solve beat the pose averaging the tracker does now?

Recomputed per sample from corners.csv (that is why the corners are saved):

  cam0      cam0's corners only
  cam1      cam1's corners only, moved into cam0's frame with the stereo extrinsic
  avg       what the tracker does today: each camera solved alone, then the two
            poses averaged, weighted 1/reprojection^2
  joint     one pose fitted to ALL corners from BOTH cameras at once

Judged on the T1 holds, where the device is still: the spread of the position
during a hold is noise, since the truth is constant. The camera time offset
does not matter here (it only biases a MOVING device), and the script prints
its distribution so that assumption is visible.

Everything comes from the recording's own calib/ copies, so an old recording is
still analysed with the calibration it was made under.

Run (on the board, venv active):
    python pyscripts/compare_fusion.py                    # newest recording
    python pyscripts/compare_fusion.py <folder> --stride 3
"""

import argparse
import collections
import csv
import json
import os
import sys

import cv2
import numpy as np
import toml
from scipy.optimize import least_squares

from analyse_holds import newest_recording, read_marks
from board import BoardGeometry, estimate_board_pose

METHODS = ["cam0", "cam1", "avg", "joint"]


def load_calibration(folder: str):
    """Intrinsics, stereo extrinsic and board geometry — from the copies stored
    with this recording, not from whatever pyscripts/ holds today."""
    calib = os.path.join(folder, "calib")

    def intrinsics(name: str):
        data = toml.load(os.path.join(calib, name))["calibration"]
        return np.array(data["camera_matrix"], dtype=np.float64).reshape(3, 3)

    with open(os.path.join(calib, "stereo_extrinsics.json")) as f:
        stereo = json.load(f)
    return (intrinsics("camera_calib.toml"), intrinsics("camera_calib_1.toml"),
            np.array(stereo["Rx"], dtype=np.float64).reshape(3, 3),
            np.array(stereo["tx"], dtype=np.float64).flatten(),
            BoardGeometry.load(os.path.join(calib, "board_geometry.json")))


def read_corners(folder: str) -> dict:
    """{sample: {cam: [(marker id, 4x2 corners), ...]}} — corners are in
    undistorted pixels, so projection uses zero distortion."""
    out = collections.defaultdict(lambda: {0: [], 1: []})
    with open(os.path.join(folder, "corners.csv")) as f:
        for row in csv.DictReader(f):
            uv = np.array([float(row[k]) for k in
                           ("u0", "v0", "u1", "v1", "u2", "v2", "u3", "v3")])
            out[int(row["sample"])][int(row["cam"])].append(
                (int(row["marker_id"]), uv.reshape(4, 2)))
    return out


def board_points(board: BoardGeometry, seen) -> tuple:
    """Marker corners in the board's own frame, paired with the pixels they
    were seen at. Markers missing from board_geometry.json are skipped."""
    obj, img = [], []
    for marker_id, uv in seen:
        if marker_id not in board.marker_poses:
            continue
        obj.append(board.corners_in_board(marker_id))
        img.append(uv)
    if not obj:
        return None, None
    return (np.concatenate(obj).astype(np.float64),
            np.concatenate(img).astype(np.float64))


def solve_single(board: BoardGeometry, seen, K):
    """Board pose in that camera's frame, exactly as the tracker solves it
    (estimate_board_pose), so "cam0" and "avg" really are today's behaviour."""
    if not seen:
        return None
    ids = np.array([marker_id for marker_id, _ in seen])
    corners = [uv.astype(np.float32).reshape(1, 4, 2) for _, uv in seen]
    return estimate_board_pose(board, corners, ids, K, None)


def to_cam0(rvec1, tvec1, Rx, tx):
    R = Rx @ cv2.Rodrigues(rvec1)[0]
    return cv2.Rodrigues(R)[0].flatten(), Rx @ tvec1 + tx


def average_poses(p0, p1, Rx, tx):
    """The tracker's fusion: inverse-reprojection-error-squared weights."""
    if p0 is None and p1 is None:
        return None
    if p1 is None:
        return p0[0], p0[1]
    r1, t1 = to_cam0(p1[0], p1[1], Rx, tx)
    if p0 is None:
        return r1, t1
    w0, w1 = 1.0 / max(p0[2], 1e-3) ** 2, 1.0 / max(p1[2], 1e-3) ** 2
    t = (w0 * p0[1] + w1 * t1) / (w0 + w1)
    q0 = cv2.Rodrigues(p0[0])[0]
    q1 = cv2.Rodrigues(r1)[0]
    # Rotations here differ by a fraction of a degree, so the cheap route —
    # average the rotation vectors and renormalise — is within noise of a
    # proper quaternion average.
    r = (w0 * cv2.Rodrigues(q0)[0].flatten() + w1 * cv2.Rodrigues(q1)[0].flatten()) / (w0 + w1)
    return r, t


# A joint fit is rejected when it disagrees with the pictures by more than this,
# or when it has wandered this far from the pose it started at. Weak geometry —
# one small marker at the edge of the table — can otherwise send the optimiser
# somewhere absurd (a 210 mm jump, seen on 2026-09-21).
JOINT_MAX_REPROJ_PX = 3.0
JOINT_MAX_JUMP_M = 0.02


def solve_joint(obj0, img0, obj1, img1, K0, K1, Rx, tx, guess):
    """One pose in cam0's frame fitted to both cameras' corners at once.

    A board point b sits at  p0 = R b + t  in cam0, and the same point is at
    p1 = Rx^T (p0 - tx) in cam1, so one (R, t) predicts both images.

    Returns (rvec, tvec, accepted). On a rejected fit the guess is returned
    unchanged, which is what a tracker would have to do."""
    RxT = Rx.T

    def predict(x):
        rvec, tvec = x[:3], x[3:]
        out = []
        if obj0 is not None:
            proj = cv2.projectPoints(obj0, rvec, tvec, K0, np.zeros(5))[0].reshape(-1, 2)
            out.append(proj - img0)
        if obj1 is not None:
            R = cv2.Rodrigues(rvec)[0]
            r1 = cv2.Rodrigues(RxT @ R)[0].flatten()
            t1 = RxT @ (tvec - tx)
            proj = cv2.projectPoints(obj1, r1, t1, K1, np.zeros(5))[0].reshape(-1, 2)
            out.append(proj - img1)
        return np.concatenate(out)

    x0 = np.concatenate(guess)
    try:
        res = least_squares(lambda x: predict(x).ravel(), x0, method="lm", xtol=1e-10)
    except Exception:
        return guess[0], guess[1], False

    err = float(np.linalg.norm(predict(res.x), axis=1).mean())
    jump = float(np.linalg.norm(res.x[3:] - x0[3:]))
    if err > JOINT_MAX_REPROJ_PX or jump > JOINT_MAX_JUMP_M or not np.all(np.isfinite(res.x)):
        return guess[0], guess[1], False
    return res.x[:3], res.x[3:], True


def analyse(folder: str, stride: int) -> None:
    K0, K1, Rx, tx, board = load_calibration(folder)
    holds = read_marks(folder)
    corners = read_corners(folder)
    times = {}
    with open(os.path.join(folder, "samples.csv")) as f:
        for row in csv.DictReader(f):
            if row["t_cam0_s"] and row["t_cam1_s"]:
                times[int(row["sample"])] = (float(row["t_cam0_s"]), float(row["t_cam1_s"]))

    offs = np.array([(a - b) * 1000.0 for a, b in times.values()])
    if offs.size:
        print(f"\ncamera time offset (cam0 - cam1): median {np.median(offs):+.2f} ms   "
              f"5th {np.percentile(offs, 5):+.2f}   95th {np.percentile(offs, 95):+.2f}   "
              f"SD {offs.std():.2f}")

    per_hold = []
    rejected, attempted = [0], [0]
    for index in sorted(holds):
        a, b, _, _ = holds[index]
        positions = {m: [] for m in METHODS}
        for sample in range(a, b, stride):
            seen = corners.get(sample)
            if seen is None:
                continue
            obj0, img0 = board_points(board, seen[0])
            obj1, img1 = board_points(board, seen[1])
            p0 = solve_single(board, seen[0], K0)
            p1 = solve_single(board, seen[1], K1)
            if p0 is not None:
                positions["cam0"].append(p0[1])
            if p1 is not None:
                positions["cam1"].append(to_cam0(p1[0], p1[1], Rx, tx)[1])
            fused = average_poses(p0, p1, Rx, tx)
            if fused is not None:
                positions["avg"].append(fused[1])
                guess = (fused[0], fused[1])
                rvec, tvec, accepted = solve_joint(
                    obj0, img0, obj1, img1, K0, K1, Rx, tx, guess)
                positions["joint"].append(tvec)
                rejected[0] += 0 if accepted else 1
                attempted[0] += 1
        row = {"place": index, "n": len(positions["joint"])}
        for m in METHODS:
            p = np.array(positions[m])
            # Noise while still: SD per axis, combined. Truth is constant, so
            # all of this is error.
            row[m] = float(np.sqrt((p.std(axis=0) ** 2).sum()) * 1000.0) if len(p) > 2 else np.nan
        per_hold.append(row)

    head = f"{'place':>5} {'n':>4} " + " ".join(f"{m:>8}" for m in METHODS)
    print(f"\njitter while still, mm (lower is better)\n\n{head}\n" + "-" * len(head))
    for row in per_hold:
        print(f"{row['place']:>5} {row['n']:>4} " +
              " ".join(f"{row[m]:>8.3f}" for m in METHODS))

    if attempted[0]:
        print(f"\njoint fits rejected (kept the averaged pose instead): "
              f"{rejected[0]} of {attempted[0]} "
              f"({100.0 * rejected[0] / attempted[0]:.2f} %) — limits: "
              f"{JOINT_MAX_REPROJ_PX} px, {JOINT_MAX_JUMP_M * 1000:.0f} mm")

    print("\nsummary (mm)")
    base = np.array([r["avg"] for r in per_hold], dtype=float)
    for m in METHODS:
        v = np.array([r[m] for r in per_hold], dtype=float)
        v = v[~np.isnan(v)]
        if not v.size:
            continue
        change = ""
        if m != "avg" and base.size:
            ratio = np.nanmedian(np.array([r[m] for r in per_hold], dtype=float)) / np.nanmedian(base)
            change = f"   ({(ratio - 1) * 100:+.0f}% vs avg)"
        print(f"{m:>6}: median {np.median(v):6.3f}   90th pct {np.percentile(v, 90):6.3f}"
              f"   max {v.max():6.3f}{change}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    ap.add_argument("--stride", type=int, default=3,
                    help="use every Nth sample of each hold (default 3, ~100 per hold)")
    args = ap.parse_args()
    folder = args.folder or newest_recording()
    print(folder)
    analyse(folder, max(1, args.stride))


if __name__ == "__main__":
    main()
