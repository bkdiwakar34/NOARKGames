"""
The joint two-camera solve, slow vs standard — on one recording's corners.

Replays corners.csv sample by sample, the way the tracker would: each fit
starts from the previous sample's accepted pose, or, with none, from the
per-camera pose of the camera seeing more tags. From that SAME start it runs

  slow   board.estimate_board_pose_dual     (least_squares, derivatives by trial)
  fast   board.estimate_board_pose_dual_gn  (derivatives written out)

and reports, on this board's CPU:

  time per fit    median / 99th percentile / max, and how many fits took > 5 ms
  agreement       position and angle difference between the two answers —
                  should be ~0: they minimise the same thing
  accepted        how often each passes the tracker's reprojection/jump checks
  steps           the fast fit's iterations

Nothing in the tracker changes. Needs a recording made with straightened
corners (pipeline "current").

Run:
    python pyscripts/analysis/bench_joint.py                 # newest recording
    python pyscripts/analysis/bench_joint.py <folder>
"""

import argparse
import json
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from analyse_holds import newest_recording
from board import (estimate_board_pose, estimate_board_pose_dual,
                   estimate_board_pose_dual_gn)
from compare_fusion import load_calibration, read_corners


def matrices_used(folder: str, K0, K1):
    """The straightened image's matrices the corners were found with: from
    meta.json when the recording has them (a border shifts the centre),
    otherwise the calibration's own."""
    with open(os.path.join(folder, "meta.json")) as f:
        ud = json.load(f).get("undistorted")
    if ud:
        return (np.array(ud["camera_matrix_cam0"], np.float64).reshape(3, 3),
                np.array(ud["camera_matrix_cam1"], np.float64).reshape(3, 3))
    return K0, K1


def as_detector_output(seen):
    """[(id, 4x2), ...] -> (corners list of (1,4,2), ids array) or (None, None)."""
    if not seen:
        return None, None
    return ([uv.reshape(1, 4, 2) for _, uv in seen],
            np.array([[marker_id] for marker_id, _ in seen]))


def start_pose(board, c0, i0, c1, i1, K0, K1, Rx, tx):
    """The tracker's fallback start: the per-camera pose of the camera seeing
    more tags, in cam0's frame."""
    n0 = 0 if i0 is None else len(i0)
    n1 = 0 if i1 is None else len(i1)
    if n0 >= n1 and n0:
        p = estimate_board_pose(board, c0, i0, K0)
        return None if p is None else (p[0], p[1])
    if n1:
        p = estimate_board_pose(board, c1, i1, K1)
        if p is None:
            return None
        R1 = cv2.Rodrigues(np.asarray(p[0]).reshape(3, 1))[0]
        return cv2.Rodrigues(Rx @ R1)[0].flatten(), Rx @ np.asarray(p[1]).flatten() + tx
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    K0, K1, Rx, tx, board = load_calibration(folder)
    K0, K1 = matrices_used(folder, K0, K1)
    corners = read_corners(folder)

    t_slow, t_fast, d_pos, d_ang, steps = [], [], [], [], []
    acc_slow = acc_fast = n = 0
    prev_sample, prev_pose = None, None
    for sample in sorted(corners):
        c0, i0 = as_detector_output(corners[sample][0])
        c1, i1 = as_detector_output(corners[sample][1])
        guess = prev_pose if prev_sample == sample - 1 else None
        if guess is None:
            guess = start_pose(board, c0, i0, c1, i1, K0, K1, Rx, tx)
        if guess is None:
            prev_sample, prev_pose = sample, None
            continue

        a = time.perf_counter()
        slow = estimate_board_pose_dual(board, c0, i0, c1, i1, K0, K1, Rx, tx, guess)
        b = time.perf_counter()
        fast = estimate_board_pose_dual_gn(board, c0, i0, c1, i1, K0, K1, Rx, tx, guess,
                                           return_iters=True)
        c = time.perf_counter()
        if slow is None or fast is None:
            prev_sample, prev_pose = sample, None
            continue
        n += 1
        t_slow.append((b - a) * 1000.0)
        t_fast.append((c - b) * 1000.0)
        steps.append(fast[4])
        acc_slow += slow[3]
        acc_fast += fast[3]
        if slow[3] and fast[3]:
            d_pos.append(1000.0 * float(np.linalg.norm(np.asarray(slow[1]) - fast[1])))
            Rs = cv2.Rodrigues(np.asarray(slow[0], np.float64).reshape(3, 1))[0]
            Rf = cv2.Rodrigues(np.asarray(fast[0], np.float64).reshape(3, 1))[0]
            d_ang.append(float(np.degrees(np.arccos(np.clip((np.trace(Rs.T @ Rf) - 1) / 2, -1, 1)))))
        prev_sample = sample
        prev_pose = (fast[0], fast[1]) if fast[3] else None

    if not n:
        sys.exit("No samples with corners.")
    print(f"\n{folder}\n{n} fits\n")
    print(f"{'':6} {'median ms':>10} {'99th pct':>9} {'max':>8} {'> 5 ms':>7} {'accepted':>9}")
    for name, t, acc in (("slow", t_slow, acc_slow), ("fast", t_fast, acc_fast)):
        t = np.array(t)
        print(f"{name:6} {np.median(t):10.3f} {np.percentile(t, 99):9.2f} {t.max():8.1f} "
              f"{int((t > 5).sum()):7d} {100 * acc / n:8.1f}%")
    if d_pos:
        print(f"\nslow vs fast, both accepted ({len(d_pos)} fits): position diff median "
              f"{np.median(d_pos):.4f} mm, max {max(d_pos):.3f} mm; angle diff median "
              f"{np.median(d_ang):.5f} deg, max {max(d_ang):.4f} deg")
    s = np.array(steps)
    print(f"fast fit steps: median {np.median(s):.0f}, max {s.max()}")


if __name__ == "__main__":
    main()
