"""
Does the camera phase alignment hold?

Starts the real tracker (including its start-up alignment) without Godot, runs
it for a while, and prints the offset between the two cameras' capture times
once a second — folded into one frame period, so +6 and -4 ms at 100 fps read
as the same timing.

    python pyscripts/diagnostics/phase_test.py            # 20 s
    python pyscripts/diagnostics/phase_test.py --seconds 60
    python pyscripts/diagnostics/phase_test.py --debug   # + the tracker's timing line

The game must be closed: both want the cameras.
"""

import argparse
import os
import sys
import time

import numpy as np

# pyscripts/, one folder up, for main.py (the tracker itself).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from main import MainClass, _load_settings, calib_path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--debug", action="store_true",
                    help="keep the tracker's once-a-second timing line (ms per "
                         "stage, frames missed); no preview window")
    args = ap.parse_args()

    settings = _load_settings()
    settings["debug"] = args.debug                  # off: keep the output readable
    settings["debug_preview"] = False
    tracker = MainClass(cam_calib_path=calib_path(settings), settings=settings, udp=False)
    period = 1.0 / float(settings.get("framerate", 100))
    try:
        start = time.monotonic()
        window, last_print = [], start
        while time.monotonic() - start < args.seconds:
            r = tracker.process_frame()
            if r is None or r.t_cap[0] is None or r.t_cap[1] is None:
                continue
            d = (r.t_cap[0] - r.t_cap[1]) % period
            window.append((d - period if d > period / 2 else d) * 1000.0)
            now = time.monotonic()
            if now - last_print >= 1.0 and window:
                w = np.array(window)
                print(f"{now - start:5.1f} s   offset median {np.median(w):+6.2f} ms   "
                      f"range {w.min():+6.2f} .. {w.max():+6.2f}   ({len(w)} pairs)")
                window, last_print = [], now
    finally:
        tracker.close()


if __name__ == "__main__":
    main()
