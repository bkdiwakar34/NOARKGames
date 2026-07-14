"""
Back-solve MARKER_OFFSETS for markers whose entries are wrong or unknown,
using the calibrated board geometry plus the markers that are trusted.

calibrate_board.py measures every marker's true pose on the device
(board_geometry.json) without using the offsets at all, so that data stays
valid even when an offset entry is wrong. The trusted markers agree on
where the grip point is; projecting that shared point back into a suspect
marker's own frame gives the offset that marker should have had:

    o = R_m^T @ (g_board - t_m)

Run on the Pi (needs an up-to-date board_geometry.json with the suspect
markers included):

    python pyscripts/derive_offsets.py --suspect 28 32

Paste the printed lines into MARKER_OFFSETS in board.py, then re-run
calibrate_board.py to verify (all markers should land within ~5 mm) and to
regenerate the stored grip point the tracker uses at runtime.
"""

import argparse
import os

import numpy as np

from board import BoardGeometry, MARKER_OFFSETS

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geometry",
                        default=os.path.join(_SCRIPT_DIR, "board_geometry.json"))
    parser.add_argument("--suspect", type=int, nargs="+", required=True,
                        help="marker ids whose offsets should be re-derived")
    args = parser.parse_args()

    board = BoardGeometry.load(args.geometry)
    suspect = set(args.suspect)

    missing = suspect - set(board.marker_poses)
    if missing:
        raise SystemExit(f"markers {sorted(missing)} not in {args.geometry} — "
                         "re-run calibrate_board.py with them visible first")

    trusted = sorted(i for i in board.marker_poses
                     if i in MARKER_OFFSETS and i not in suspect)
    if not trusted:
        raise SystemExit("no trusted markers left to define the grip point")

    grips = np.array([board.marker_poses[i][0] @ MARKER_OFFSETS[i]
                      + board.marker_poses[i][1] for i in trusted])
    g = grips.mean(axis=0)
    spread_mm = np.linalg.norm(grips - g, axis=1) * 1000

    print("Trusted-marker grip agreement (each should be a few mm at most —")
    print("if any is large, that marker's offset is also suspect):")
    for i, d in zip(trusted, spread_mm):
        print(f"  marker {i}: {d:.1f} mm")

    print("\nDerived entries — paste into MARKER_OFFSETS in board.py:")
    for i in sorted(suspect):
        R, t = board.marker_poses[i]
        o = R.T @ (g - t)
        print(f"    {i}: np.array([{o[0]: .3f}, {o[1]: .3f}, {o[2]: .3f}]),")


if __name__ == "__main__":
    main()
