"""
Is the device's stored geometry the thing limiting the tracker?

The tracker fits ONE pose to every visible marker, using each marker's stored
position on the device (board_geometry.json, from calibrate_board.py). If a
stored position is wrong, that marker pulls the fit its own way — and because
different markers are visible at different places on the table, the fitted
pose shifts as they come and go. That looks exactly like jitter and drift.

Run on a T1 recording, which holds the device still at many places:

  1. Per-marker disagreement: solve the pose from each marker alone, convert
     to the device's grip point, and report how far each marker's answer sits
     from the group. A marker 4 mm out is a geometry error, not noise.

  2. Jitter by marker set: recompute the holds using all markers, then only
     the agreeing ones. If the jitter drops, the geometry is the limit and a
     better calibrate_board.py run is worth more than new optics.

Uses the calibration stored with the recording, so old recordings stay
interpretable.

    python pyscripts/analysis/check_board.py [folder] [--worst 3]
"""

import argparse
import collections
import csv
import os
import sys

import cv2
import numpy as np

# pyscripts/, one folder up, for board.py (the other imports are in this folder).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from analyse_holds import newest_recording, read_marks
from board import BoardGeometry, estimate_board_pose, marker_object_points
from compare_fusion import load_calibration, read_corners


def grip_from_marker(board: BoardGeometry, marker_id: int, uv, K):
    """Where this marker alone says the grip point is, in the camera's frame.

    Solved in the MARKER's own frame — IPPE_SQUARE needs a square centred on
    the origin, which board-frame corners are not — then composed with the
    marker's stored pose on the device, exactly as board.estimate_board_pose
    does for a lone marker.
    """
    ok, rvec, tvec = cv2.solvePnP(
        marker_object_points(board.marker_length).astype(np.float64),
        uv.astype(np.float64), K, np.zeros(5), flags=cv2.SOLVEPNP_IPPE_SQUARE)
    if not ok:
        return None
    R_pnp = cv2.Rodrigues(rvec)[0]
    R_bm, t_bm = board.marker_poses[marker_id]
    R_cb = R_pnp @ R_bm.T                      # camera <- board
    t_cb = tvec.flatten() - R_cb @ t_bm
    return R_cb @ board.grip_point + t_cb


def pose_with(board: BoardGeometry, seen, K, allowed):
    """Board pose from the allowed markers only, the tracker's own solver."""
    kept = [(m, uv) for m, uv in seen if m in allowed]
    if not kept:
        return None
    ids = np.array([m for m, _ in kept])
    corners = [uv.astype(np.float32).reshape(1, 4, 2) for _, uv in kept]
    return estimate_board_pose(board, corners, ids, K, None)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?")
    ap.add_argument("--worst", type=int, default=3,
                    help="how many markers to drop in the second test (default 3)")
    ap.add_argument("--stride", type=int, default=5)
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    print(folder)
    K0, K1, Rx, tx, board = load_calibration(folder)
    holds = read_marks(folder)
    if not holds:
        raise SystemExit("No holds in this recording — run it on a T1 grid.")
    corners = read_corners(folder)

    # ── 1. per-marker disagreement ──
    # Each marker's own answer for the grip point, against the average of the
    # markers seen in that same frame. Only frames with >= 3 markers count, so
    # the reference is not one other marker's opinion.
    spread = collections.defaultdict(list)
    seen_count = collections.Counter()
    for index in sorted(holds):
        a, b, _, _ = holds[index]
        for sample in range(a, b, args.stride):
            for cam, K in ((0, K0), (1, K1)):
                seen = corners.get(sample, {}).get(cam, [])
                seen = [(m, uv) for m, uv in seen if m in board.marker_poses]
                if len(seen) < 3:
                    continue
                grips = {}
                for marker_id, uv in seen:
                    g = grip_from_marker(board, marker_id, uv, K)
                    if g is not None:
                        grips[marker_id] = g
                if len(grips) < 3:
                    continue
                for marker_id, g in grips.items():
                    others = [v for k, v in grips.items() if k != marker_id]
                    ref = np.mean(others, axis=0)
                    spread[marker_id].append(float(np.linalg.norm(g - ref)) * 1000.0)
                    seen_count[marker_id] += 1

    print("\n1. how far each marker's own answer sits from the others (mm)\n")
    print(f"{'marker':>7} {'frames':>8} {'median':>8} {'90th':>8} {'max':>8}")
    print("-" * 42)
    ranked = []
    for marker_id in sorted(spread):
        v = np.array(spread[marker_id])
        ranked.append((float(np.median(v)), marker_id))
        print(f"{marker_id:>7} {len(v):>8} {np.median(v):>8.2f} "
              f"{np.percentile(v, 90):>8.2f} {v.max():>8.2f}")
    ranked.sort(reverse=True)
    worst = [m for _, m in ranked[:args.worst]]
    print(f"\nworst {args.worst}: {worst}  (dropped in test 2)")

    # ── 2. jitter with and without them ──
    keep_all = set(board.marker_poses)
    keep_good = keep_all - set(worst)
    rows = []
    for index in sorted(holds):
        a, b, _, _ = holds[index]
        out = {}
        for name, allowed in (("all", keep_all), ("good", keep_good)):
            pts = []
            for sample in range(a, b, args.stride):
                seen = corners.get(sample, {}).get(0, [])
                pose = pose_with(board, seen, K0, allowed)
                if pose is not None:
                    pts.append(pose[1])
            p = np.array(pts)
            out[name] = (float(np.sqrt((p.std(axis=0) ** 2).sum()) * 1000.0)
                         if len(p) > 2 else np.nan)
        rows.append(out)

    print("\n2. jitter while still, cam0 only (mm)\n")
    for name in ("all", "good"):
        v = np.array([r[name] for r in rows], dtype=float)
        v = v[~np.isnan(v)]
        if v.size:
            print(f"{name:>6} markers: median {np.median(v):6.3f}   "
                  f"90th pct {np.percentile(v, 90):6.3f}   max {v.max():6.3f}")
    print("\nIf 'good' is clearly lower, the stored geometry is the limit: "
          "re-run calibrate_board.py\nand watch those markers, rather than "
          "changing cameras or lighting.")


if __name__ == "__main__":
    main()
