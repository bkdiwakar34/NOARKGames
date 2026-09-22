"""
Why does a camera see fewer markers at some places? — from one T1 recording.

For every hold, every sample and each camera, each of the device's markers is
put into exactly one of these, checked in this order:

  seen      detected (it is in corners.csv)
  away      its face points away from the camera — cannot be seen from there
  sensor    at least one corner falls off the raw fisheye image (1280 x 800):
            the lens does not see it. Fix: move / tilt the cameras.
  crop      on the raw image, but off the undistorted image the detector
            searches: thrown away by the undistortion. Fix: a bigger border
            (undistort_pad_x_px / undistort_pad_y_px in settings.json).
  edge      in the image, but seen at more than EDGE_DEG from face-on
  missed    in the image, facing the camera, not edge-on — and not detected
            (hidden behind the device or a hand, blur, or the detector)

Where each marker "should be" comes from the recorded pose (samples.csv,
board in cam0's frame) and the calibration copied into the recording's calib/
folder: board_geometry.json places the markers, stereo_extrinsics.json moves
the pose into cam1, each camera's toml gives the fisheye lens (raw image).
The undistorted image's size and matrix come from meta.json (recordings from
before the border existed: the toml matrix and 1280 x 800). Samples without a
pose are skipped.

The numbers are markers per sample, averaged over the hold; the six columns
of one camera add up to the device's marker count. The last block says how
big a border would have held every `crop` marker of this recording.

Run:
    python pyscripts/coverage_markers.py                     # newest recording
    python pyscripts/coverage_markers.py <folder>
    python pyscripts/coverage_markers.py <folder> --rows 0 1  # only these grid rows
"""

import argparse
import csv
import json
import os
import sys

import cv2
import numpy as np
import toml
from scipy.spatial.transform import Rotation

from analyse_holds import _settings, newest_recording, read_marks, read_samples
from board import BoardGeometry

GRID_COLS = 12          # as validation_recorder.gd
FRAME_W, FRAME_H = 1280, 800
EDGE_DEG = 70.0         # beyond this from face-on a 50 mm marker is ~17 mm wide
BORDER_SPARE_PX = 20    # added to the measured need when suggesting a border
REASONS = ("seen", "away", "sensor", "crop", "edge", "missed")


def place_row_col(index: int) -> tuple:
    """T1 is laid out as a serpentine: even rows left to right, odd rows back."""
    row, i = divmod(index, GRID_COLS)
    return row, (i if row % 2 == 0 else GRID_COLS - 1 - i)


def load_calib(folder: str):
    """Per camera: (lens matrix, fisheye coefficients, undistorted matrix),
    plus the undistorted image size and border, the stereo transform and the
    device geometry."""
    s = _settings()
    calib = os.path.join(folder, "calib")

    def path(key, default):
        return os.path.join(calib, os.path.basename(s.get(key, default)))

    with open(os.path.join(folder, "meta.json")) as f:
        ud = json.load(f).get("undistorted")
    if ud:
        size, border = tuple(ud["size"]), tuple(ud["border_px"])
    else:
        size, border = (FRAME_W, FRAME_H), (0, 0)

    cams = []
    for c, (key, default) in enumerate((("calibration_file", "camera_calib.toml"),
                                        ("camera_calib_file_1", "camera_calib_1.toml"))):
        cal = toml.load(path(key, default))["calibration"]
        K = np.array(cal["camera_matrix"], dtype=np.float64).reshape(3, 3)
        D = np.array(cal["dist_coeffs"], dtype=np.float64).reshape(-1)[:4]
        K_ud = (np.array(ud[f"camera_matrix_cam{c}"], dtype=np.float64).reshape(3, 3)
                if ud else K)
        cams.append((K, D, K_ud))
    with open(path("stereo_extrinsics_file", "stereo_extrinsics.json")) as f:
        st = json.load(f)
    Rx = np.array(st["Rx"], dtype=np.float64).reshape(3, 3)
    tx = np.array(st["tx"], dtype=np.float64).reshape(3)
    board = BoardGeometry.load(path("board_geometry_file", "board_geometry.json"))
    return cams, size, border, Rx, tx, board


def read_seen(folder: str, wanted: set) -> dict:
    """{sample: ({ids seen by cam0}, {ids seen by cam1})} for the wanted samples."""
    seen = {}
    with open(os.path.join(folder, "corners.csv")) as f:
        for row in csv.DictReader(f):
            n = int(row["sample"])
            if n in wanted:
                seen.setdefault(n, (set(), set()))[int(row["cam"])].add(int(row["marker_id"]))
    return seen


def overshoot(uv: np.ndarray, w: int, h: int) -> tuple:
    """How many px the corners reach past the image, sideways and up/down
    (0 when inside)."""
    over_x = max(0.0, -float(uv[:, 0].min()), float(uv[:, 0].max()) - w)
    over_y = max(0.0, -float(uv[:, 1].min()), float(uv[:, 1].max()) - h)
    return over_x, over_y


def classify(board, marker_id, R, t, cam, ud_size, seen_ids) -> tuple:
    """One marker, one camera, one sample. R, t: board -> this camera.
    Returns (reason, (overshoot x, overshoot y) — only for 'crop')."""
    if marker_id in seen_ids:
        return "seen", None
    K, D, K_ud = cam
    R_bm, t_bm = board.marker_poses[marker_id]
    centre = R @ t_bm + t                       # marker centre, camera frame
    normal = R @ R_bm[:, 2]                     # marker +Z = out of its face
    to_cam = -centre / np.linalg.norm(centre)
    cos_view = float(normal @ to_cam)
    if cos_view <= 0.0 or centre[2] <= 0.0:
        return "away", None
    corners = board.corners_in_board(marker_id) @ R.T + t       # camera frame
    rvec0, tvec0 = np.zeros(3), np.zeros(3)
    raw, _ = cv2.fisheye.projectPoints(corners.reshape(-1, 1, 3), rvec0, tvec0, K, D)
    if any(overshoot(raw.reshape(-1, 2), FRAME_W, FRAME_H)):
        return "sensor", None
    und, _ = cv2.projectPoints(corners, rvec0, tvec0, K_ud, np.zeros(5))
    over = overshoot(und.reshape(-1, 2), *ud_size)
    if any(over):
        return "crop", over
    if np.degrees(np.arccos(min(cos_view, 1.0))) > EDGE_DEG:
        return "edge", None
    return "missed", None


def undistorted_fov(K_ud: np.ndarray, size: tuple) -> str:
    """Angles the undistorted image spans from the optical axis, in degrees."""
    fx, fy, cx, cy = K_ud[0, 0], K_ud[1, 1], K_ud[0, 2], K_ud[1, 2]
    w, h = size
    left, right = np.degrees(np.arctan(cx / fx)), np.degrees(np.arctan((w - cx) / fx))
    up, down = np.degrees(np.arctan(cy / fy)), np.degrees(np.arctan((h - cy) / fy))
    return (f"left {left:.0f}, right {right:.0f}, up {up:.0f}, down {down:.0f} "
            f"(total {left + right:.0f} x {up + down:.0f})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    ap.add_argument("--rows", type=int, nargs="*", help="grid rows to report (default: all)")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    cams, ud_size, border, Rx, tx, board = load_calib(folder)
    holds = read_marks(folder)
    if not holds:
        sys.exit("No complete holds found — is this a T1 recording?")
    s = read_samples(folder)
    wanted = {n for a, b, _, _ in holds.values() for n in range(a, b)}
    seen = read_seen(folder, wanted)
    RxT = Rx.T
    ids = sorted(board.marker_poses)

    print(f"\n{folder}")
    print(f"{len(ids)} markers on the device: {ids}")
    print(f"undistorted image: {ud_size[0]} x {ud_size[1]} "
          f"(border {border[0]} sideways, {border[1]} up/down)")
    for c, (_, _, K_ud) in enumerate(cams):
        print(f"cam{c} undistorted image spans (deg from the axis): "
              f"{undistorted_fov(K_ud, ud_size)}")
    print("\nmarkers per sample, averaged over the hold "
          "(seen / away / sensor / crop / edge / missed)\n")
    cell = "  ".join(f"{r[:4]:>4}" for r in REASONS)
    print(f"{'place':>5} {'row':>3} {'col':>3}   cam0: {cell}   cam1: {cell}")

    totals = [dict.fromkeys(REASONS, 0) for _ in cams]
    per_marker = [{i: dict.fromkeys(REASONS, 0) for i in ids} for _ in cams]
    overs = [[], []]                               # crop overshoot, x and y, all cameras
    for index in sorted(holds):
        row, col = place_row_col(index)
        if args.rows and row not in args.rows:
            continue
        a, b, _, _ = holds[index]
        counts = [dict.fromkeys(REASONS, 0) for _ in cams]
        n_used = 0
        for n in range(a, min(b, len(s["sample"]))):
            t0 = np.array([s["tx_m"][n], s["ty_m"][n], s["tz_m"][n]])
            q = np.array([s["qx"][n], s["qy"][n], s["qz"][n], s["qw"][n]])
            if np.any(np.isnan(t0)) or np.any(np.isnan(q)):
                continue
            R0 = Rotation.from_quat(q).as_matrix()
            poses = [(R0, t0), (RxT @ R0, RxT @ (t0 - tx))]
            sets = seen.get(n, (set(), set()))
            n_used += 1
            for c, ((R, t), cam) in enumerate(zip(poses, cams)):
                for mid in ids:
                    why, over = classify(board, mid, R, t, cam, ud_size, sets[c])
                    counts[c][why] += 1
                    totals[c][why] += 1
                    per_marker[c][mid][why] += 1
                    if over is not None:
                        overs[0].append(over[0])
                        overs[1].append(over[1])
        if not n_used:
            print(f"{index:>5} {row:>3} {col:>3}   no pose in this hold")
            continue
        text = ["  ".join(f"{counts[c][r] / n_used:>4.1f}" for r in REASONS)
                for c in range(len(cams))]
        print(f"{index:>5} {row:>3} {col:>3}         {text[0]}         {text[1]}")

    print("\nwhere each marker went, share of all reported samples")
    for c in range(len(cams)):
        print(f"\ncam{c}  {'id':>3}  " + "  ".join(f"{r:>6}" for r in REASONS))
        for mid in ids:
            tot = sum(per_marker[c][mid].values()) or 1
            print(f"      {mid:>3}  " + "  ".join(
                f"{100 * per_marker[c][mid][r] / tot:>5.0f}%" for r in REASONS))
        tot = sum(totals[c].values()) or 1
        print(f"      all  " + "  ".join(
            f"{100 * totals[c][r] / tot:>5.0f}%" for r in REASONS))

    print("\nborder needed to keep every 'crop' marker (px past the current image)")
    if not overs[0]:
        print("  none cropped — the current border is enough for these rows")
        return
    need = []
    for axis, name, have in ((0, "sideways", border[0]), (1, "up/down ", border[1])):
        v = np.array(overs[axis])
        v_hit = v[v > 0]
        worst = float(v.max())
        need.append(int(np.ceil(have + worst + BORDER_SPARE_PX)) if worst > 0 else have)
        pct = f"{np.percentile(v_hit, 95):6.0f}" if v_hit.size else "     -"
        print(f"  {name}: past the edge in {v_hit.size:>6} marker-samples, "
              f"95th pct {pct} px, worst {worst:6.0f} px")
    w, h = FRAME_W + 2 * need[0], FRAME_H + 2 * need[1]
    print(f"\n  suggested settings.json:  \"undistort_pad_x_px\": {need[0]},  "
          f"\"undistort_pad_y_px\": {need[1]}")
    print(f"  -> undistorted image {w} x {h}, "
          f"{w * h / (FRAME_W * FRAME_H):.2f}x the pixels of 1280 x 800 "
          f"(whole-image searches only)")


if __name__ == "__main__":
    main()
