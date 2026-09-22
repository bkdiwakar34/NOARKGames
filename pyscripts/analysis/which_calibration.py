"""
Which calibration makes the two cameras disagree? — from one recording's corners.

For every sample where both cameras saw tags it fits the device pose three ways:

  cam0 alone   only cam0's corners (board.estimate_board_pose)
  cam1 alone   only cam1's corners
  joint        one pose for both cameras' corners (board.estimate_board_pose_dual_gn)

and measures how far each fitted pose puts each corner from where it was seen
(reprojection error, px). Each calibration leaves its own fingerprint:

  camera-to-camera (stereo_extrinsics.json)
      alone fits are fine, the JOINT fit is poor everywhere-ish.
      -> redo calibration/calibrate_stereo.py
  tag layout on the device (board_geometry.json)
      a particular tag is poor in the ALONE fits of both cameras.
      -> redo calibration/calibrate_board.py
  a lens (camera_calib*.toml)
      one camera's ALONE fit gets worse towards the edge of its image.
      -> redo calibration/calibrate_camera.py for that camera

Single-tag alone fits are left out of the "alone" numbers: one tag's 4
corners always fit almost perfectly, which says nothing.

Run:
    python pyscripts/analysis/which_calibration.py                 # newest recording
    python pyscripts/analysis/which_calibration.py <folder> --stride 2
"""

import argparse
import collections
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from analyse_holds import newest_recording, read_samples
from bench_joint import as_detector_output, matrices_used
from board import DUAL_MAX_REPROJ_PX, estimate_board_pose, estimate_board_pose_dual_gn
from compare_fusion import load_calibration, read_corners

RADIUS_BINS = [0, 200, 400, 600, 2000]      # px from the image centre


def project(board, seen, R, t, K):
    """Per tag: (id, 4x2 seen, 4x2 predicted) for a pose in THIS camera's frame."""
    out = []
    for marker_id, uv in seen:
        if marker_id not in board.marker_poses:
            continue
        p = board.corners_in_board(marker_id) @ R.T + t
        pred = np.stack([K[0, 0] * p[:, 0] / p[:, 2] + K[0, 2],
                         K[1, 1] * p[:, 1] / p[:, 2] + K[1, 2]], axis=1)
        out.append((marker_id, uv, pred))
    return out


def tag_errors(board, seen, R, t, K):
    """[(id, mean px error of its 4 corners, mean distance of its corners
    from the image centre)]"""
    c = np.array([K[0, 2], K[1, 2]])
    return [(mid, float(np.linalg.norm(uv - pred, axis=1).mean()),
             float(np.linalg.norm(uv - c, axis=1).mean()))
            for mid, uv, pred in project(board, seen, R, t, K)]


def med(values):
    return f"{np.median(values):6.2f}" if len(values) else "     -"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    ap.add_argument("--stride", type=int, default=5, help="use every Nth sample (default 5)")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    K0, K1, Rx, tx, board = load_calibration(folder)
    K0, K1 = matrices_used(folder, K0, K1)
    Ks = (K0, K1)
    corners = read_corners(folder)
    s = read_samples(folder)
    row_of = {int(v): i for i, v in enumerate(s["sample"]) if not np.isnan(v)}

    alone = {0: [], 1: []}                       # per-sample mean px, fits with >= 2 tags
    joint_cam = {0: [], 1: []}                   # joint fit's error in each camera
    joint_all, rejected = [], 0
    alone_tag = collections.defaultdict(list)    # (cam, id) -> px, alone fits
    joint_tag = collections.defaultdict(list)    # (cam, id) -> px, joint fit
    alone_radius = collections.defaultdict(list)  # (cam, radius bin) -> px
    zone_joint = collections.defaultdict(list)   # (xi, zi) -> joint px
    positions = []

    samples = [k for k in sorted(corners) if corners[k][0] and corners[k][1]][::args.stride]
    for sample in samples:
        seen = corners[sample]
        poses = {}
        for cam in (0, 1):
            c, i = as_detector_output(seen[cam])
            fit = estimate_board_pose(board, c, i, Ks[cam], None)
            if fit is None:
                continue
            R = cv2.Rodrigues(np.asarray(fit[0], np.float64).reshape(3, 1))[0]
            t = np.asarray(fit[1], np.float64).flatten()
            poses[cam] = (R, t, len(seen[cam]))
            if len(seen[cam]) >= 2:
                errs = tag_errors(board, seen[cam], R, t, Ks[cam])
                alone[cam].append(float(np.mean([e for _, e, _ in errs])))
                for mid, e, rad in errs:
                    alone_tag[(cam, mid)].append(e)
                    b = int(np.searchsorted(RADIUS_BINS, rad, side="right") - 1)
                    alone_radius[(cam, b)].append(e)
        if not poses:
            continue
        # Joint fit, started from the camera seeing more tags (in cam0's frame).
        cam, (R, t, _) = max(poses.items(), key=lambda kv: kv[1][2])
        if cam == 1:
            R, t = Rx @ R, Rx @ t + tx
        c0, i0 = as_detector_output(seen[0])
        c1, i1 = as_detector_output(seen[1])
        fit = estimate_board_pose_dual_gn(board, c0, i0, c1, i1, K0, K1, Rx, tx,
                                          (cv2.Rodrigues(R)[0].flatten(), t))
        if fit is None:
            continue
        R0 = cv2.Rodrigues(np.asarray(fit[0], np.float64).reshape(3, 1))[0]
        t0 = np.asarray(fit[1], np.float64)
        per_cam = {0: (R0, t0), 1: (Rx.T @ R0, Rx.T @ (t0 - tx))}
        all_errs = []
        for c in (0, 1):
            errs = tag_errors(board, seen[c], *per_cam[c], Ks[c])
            if errs:
                joint_cam[c].append(float(np.mean([e for _, e, _ in errs])))
            for mid, e, _ in errs:
                joint_tag[(c, mid)].append(e)
                all_errs.append(e)
        je = float(np.mean(all_errs))
        joint_all.append(je)
        rejected += je > DUAL_MAX_REPROJ_PX
        r = row_of.get(sample)
        if r is not None and not np.isnan(s["game_x_m"][r]):
            positions.append((1000 * s["game_x_m"][r], 1000 * s["game_z_m"][r], je))

    if not joint_all:
        sys.exit("No samples where both cameras saw tags.")
    n = len(joint_all)
    print(f"\n{folder}\n{n} samples with both cameras (every {args.stride}th)\n")
    print("1. Overall (median reprojection error, px)")
    print(f"   cam0 alone {med(alone[0])}    cam1 alone {med(alone[1])}    "
          f"(fits with >= 2 tags)")
    print(f"   joint, in cam0 {med(joint_cam[0])}    joint, in cam1 {med(joint_cam[1])}")
    print(f"   joint above {DUAL_MAX_REPROJ_PX:.0f} px (the tracker rejects these): "
          f"{100 * rejected / n:.1f} % of samples")

    print("\n2. Per tag (median px; n = times seen)")
    print(f"   {'tag':>4}   {'cam0 alone':>10} {'cam1 alone':>10}   "
          f"{'cam0 joint':>10} {'cam1 joint':>10}   {'n cam0':>7} {'n cam1':>7}")
    for mid in sorted(board.marker_poses):
        print(f"   {mid:>4}   {med(alone_tag[(0, mid)]):>10} {med(alone_tag[(1, mid)]):>10}   "
              f"{med(joint_tag[(0, mid)]):>10} {med(joint_tag[(1, mid)]):>10}   "
              f"{len(joint_tag[(0, mid)]):7d} {len(joint_tag[(1, mid)]):7d}")

    print("\n3. Alone fits by distance from the image centre (median px; n)")
    for cam in (0, 1):
        cells = []
        for b in range(len(RADIUS_BINS) - 1):
            v = alone_radius[(cam, b)]
            cells.append(f"{RADIUS_BINS[b]}-{RADIUS_BINS[b + 1]} px: {med(v).strip()} ({len(v)})")
        print(f"   cam{cam}   " + "   ".join(cells))

    if positions:
        p = np.array(positions)
        xe = np.quantile(p[:, 0], [0, 1 / 3, 2 / 3, 1])
        ze = np.quantile(p[:, 1], [0, 1 / 3, 2 / 3, 1])
        xi = np.clip(np.searchsorted(xe, p[:, 0], side="right") - 1, 0, 2)
        zi = np.clip(np.searchsorted(ze, p[:, 1], side="right") - 1, 0, 2)
        print("\n4. Joint error by table zone: median px (% rejected)   (edges in mm)")
        print("               " + "  ".join(f"x {xe[c]:5.0f}..{xe[c + 1]:<5.0f}   " for c in range(3)))
        for r in range(3):
            cells = []
            for c in range(3):
                v = p[(xi == c) & (zi == r), 2]
                cells.append(f"{med(v)} ({100 * np.mean(v > DUAL_MAX_REPROJ_PX):4.0f}%)   "
                             if len(v) else "      -            ")
            print(f"   z {ze[r]:5.0f}..{ze[r + 1]:<5.0f}  " + "  ".join(cells))


if __name__ == "__main__":
    main()
