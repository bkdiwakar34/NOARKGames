"""
Frame bank: raw camera frames at chosen table places, for offline pipeline tests.

Every later test of the image pipeline (undistortion, detection settings, detect
on the raw image, ...) runs on these same frames, so versions can be compared
directly instead of through a new T1 recording each time.

Runs the real tracker without Godot (like phase_test.py) and guides you to each
place live in the terminal, using where that place was in a full T1 recording:

    place 6 (near edge, middle)   x +42 mm  z -15 mm   (44 mm off) | cam0 5  cam1 4
    place 6 (near edge, middle)   ON TARGET (3 mm) - hold still, Enter | cam0 5  cam1 4

x and z are the table (game) coordinates the tracker sends to Godot: slide the
device a little and watch which way they change. Keys: Enter = record this
place (only when ON TARGET), s = skip, r = redo the previous place, q = quit.

Per place it saves FRAMES consecutive frames from each camera, untouched (the
raw fisheye image, before undistortion), with capture times, sequence numbers
and what the tracker computed for each.

The game must be closed: both want the cameras.

    python pyscripts/diagnostics/record_frames.py
    python pyscripts/diagnostics/record_frames.py --targets ~/Documents/NOARK/validation/2026-09-22_T1_grid_r1

Output: ~/Documents/NOARK/framebank/<date-time>/place_NN/{cam0.npy, cam1.npy,
frames.csv}, plus meta.json and calib/ at the top.
"""

import argparse
import csv
import json
import os
import select
import shutil
import sys
import termios
import time
import tty
from datetime import datetime

import numpy as np

_PYSCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _PYSCRIPTS_DIR)                                # main.py
sys.path.insert(0, os.path.join(_PYSCRIPTS_DIR, "analysis"))      # analyse_holds.py

from analyse_holds import read_marks, read_samples
from main import MainClass, _load_settings, calib_path

FRAMES = 50
ON_TARGET_MM = 10.0
GRID_PLACES = 96
PLACES = [                        # T1 place index, what it tests
    (0,  "near left corner, weakest"),
    (11, "near right corner"),
    (6,  "near edge, middle: missed markers, jumps"),
    (10, "near edge: the 59.8 mm drift place"),
    (3,  "near edge, good (contrast)"),
    (41, "middle"),
    (54, "middle"),
    (84, "far right corner"),
    (95, "far left corner"),
    (89, "far edge, middle"),
]
CALIB_FILES = [("calibration_file", "camera_calib.toml"),
               ("camera_calib_file_1", "camera_calib_1.toml"),
               ("stereo_extrinsics_file", "stereo_extrinsics.json"),
               ("board_geometry_file", "board_geometry.json"),
               (None, "origin_lock.json")]


def find_full_t1(root: str) -> str:
    """Newest recording with a complete 96-place T1 grid."""
    folders = sorted((os.path.join(root, d) for d in os.listdir(root)),
                     key=os.path.getmtime, reverse=True)
    for d in folders:
        if os.path.isfile(os.path.join(d, "marks.csv")) and len(read_marks(d)) >= GRID_PLACES:
            return d
    sys.exit(f"No complete T1 grid under {root} — pass one with --targets")


def place_targets(folder: str) -> dict:
    """{place: (x mm, z mm)} — the mean table position of each T1 hold."""
    holds, s = read_marks(folder), read_samples(folder)
    if np.all(np.isnan(s["game_x_m"])):
        sys.exit(f"{folder} has no table (game) coordinates — origin was not locked.")
    out = {}
    for index, (a, b, _, _) in holds.items():
        x, z = s["game_x_m"][a:b], s["game_z_m"][a:b]
        if np.any(~np.isnan(x)):
            out[index] = (1000.0 * float(np.nanmean(x)), 1000.0 * float(np.nanmean(z)))
    return out


def same_origin(ref_folder: str) -> bool:
    here = os.path.join(_PYSCRIPTS_DIR, "origin_lock.json")
    there = os.path.join(ref_folder, "calib", "origin_lock.json")
    if not (os.path.exists(here) and os.path.exists(there)):
        return False
    with open(here) as a, open(there) as b:
        return json.load(a) == json.load(b)


class Keys:
    """Single key presses from the terminal without waiting for Enter."""
    def __enter__(self):
        self.fd = sys.stdin.fileno()
        self.old = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        return self

    def __exit__(self, *exc):
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old)

    def get(self):
        if select.select([sys.stdin], [], [], 0)[0]:
            return sys.stdin.read(1)
        return None


def n_markers(ids) -> int:
    return 0 if ids is None else len(ids)


def status_line(text: str) -> None:
    sys.stdout.write("\r" + text.ljust(110)[:110])
    sys.stdout.flush()


def capture_place(tracker, n: int) -> tuple:
    """n consecutive passes with both raw frames: (frames0, frames1, rows)."""
    frames0, frames1, rows = [], [], []
    while len(rows) < n:
        r = tracker.process_frame()
        raw0, raw1 = tracker.last_raw_frames
        if r is None or raw0 is None or raw1 is None:
            continue
        frames0.append(np.array(raw0, copy=True))
        frames1.append(np.array(raw1, copy=True))
        g = [None] * 3 if r.local_coords is None else list(np.asarray(r.local_coords).reshape(3))
        rows.append([len(rows), r.t_cap[0], r.t_cap[1], r.seq[0], r.seq[1],
                     n_markers(r.ids[0]), n_markers(r.ids[1]), r.fusion or "", *g])
    return np.stack(frames0), np.stack(frames1), rows


def save_place(out_dir: str, index: int, frames0, frames1, rows) -> None:
    d = os.path.join(out_dir, f"place_{index:02d}")
    os.makedirs(d, exist_ok=True)
    np.save(os.path.join(d, "cam0.npy"), frames0)
    np.save(os.path.join(d, "cam1.npy"), frames1)
    with open(os.path.join(d, "frames.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["i", "t_cam0_s", "t_cam1_s", "seq_cam0", "seq_cam1",
                    "n_markers_cam0", "n_markers_cam1", "fusion",
                    "game_x_m", "game_y_m", "game_z_m"])
        w.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--targets", help="a full T1 recording (default: the newest one)")
    ap.add_argument("--frames", type=int, default=FRAMES)
    args = ap.parse_args()

    settings = _load_settings()
    root = os.path.expanduser(settings.get("validation_data_dir", "~/Documents/NOARK/validation"))
    ref = args.targets or find_full_t1(root)
    targets = place_targets(ref)
    missing = [p for p, _ in PLACES if p not in targets]
    if missing:
        sys.exit(f"{ref} has no position for places {missing}")
    print(f"Targets from {ref}")
    if not same_origin(ref):
        print("[warn] origin_lock.json differs from the one that recording used, so the "
              "targets may be shifted. Check the first place against where the T1 dot was.")

    out_dir = os.path.join(os.path.dirname(root), "framebank",
                           datetime.now().strftime("%Y-%m-%d_%H-%M-%S"))
    os.makedirs(os.path.join(out_dir, "calib"))
    for key, default in CALIB_FILES:
        name = settings.get(key, default) if key else default
        path = name if os.path.isabs(name) else os.path.join(_PYSCRIPTS_DIR, name)
        if os.path.exists(path):
            shutil.copy2(path, os.path.join(out_dir, "calib"))

    settings["debug"] = False                       # keep the output readable
    tracker = MainClass(cam_calib_path=calib_path(settings), settings=settings, udp=False)
    meta = {"created": datetime.now().isoformat(timespec="seconds"),
            "targets_from": ref, "frames_per_place": args.frames,
            "frames": "raw fisheye images, uint8, shape (frames, height, width), "
                      "before undistortion",
            "settings": settings,
            "undistorted": {"size": list(tracker.ud_size),
                            "border_px": list(tracker._ud_pad),
                            "camera_matrix_cam0": tracker.camera_matrix.tolist(),
                            "camera_matrix_cam1": (None if tracker.camera_matrix_1 is None
                                                   else tracker.camera_matrix_1.tolist())},
            "places": {}}
    print(f"Saving to {out_dir}\n")
    print("Enter = record (when ON TARGET)   s = skip   r = redo previous   q = quit\n")

    done, i = [], 0
    try:
        with Keys() as keys:
            while i < len(PLACES):
                index, label = PLACES[i]
                tx, tz = targets[index]
                key = None
                last_draw = 0.0
                while True:
                    r = tracker.process_frame()
                    key = keys.get() or key
                    now = time.monotonic()
                    if r is None:
                        continue
                    on_target, text = False, ""
                    m0, m1 = n_markers(r.ids[0]), n_markers(r.ids[1])
                    if r.local_coords is None:
                        text = f"place {index} ({label})   device not tracked"
                    else:
                        g = np.asarray(r.local_coords).reshape(3) * 1000.0
                        dx, dz = tx - g[0], tz - g[2]
                        off = float(np.hypot(dx, dz))
                        on_target = off <= ON_TARGET_MM
                        text = (f"place {index} ({label})   "
                                + (f"ON TARGET ({off:.0f} mm) - hold still, Enter" if on_target
                                   else f"x {dx:+5.0f} mm  z {dz:+5.0f} mm  ({off:.0f} mm off)"))
                    if now - last_draw > 0.1:
                        status_line(f"{text} | cam0 {m0}  cam1 {m1}")
                        last_draw = now
                    if key in ("\n", "\r"):
                        key = None
                        if on_target:
                            break
                    elif key in ("s", "r", "q"):
                        break
                    else:
                        key = None
                if key == "q":
                    break
                if key == "s":
                    print(f"\nplace {index} skipped")
                    i += 1
                    continue
                if key == "r":
                    if done:
                        i = PLACES.index(next(p for p in PLACES if p[0] == done.pop()))
                        print(f"\nredo place {PLACES[i][0]}")
                    continue
                frames0, frames1, rows = capture_place(tracker, args.frames)
                save_place(out_dir, index, frames0, frames1, rows)
                seqs = [row[3] for row in rows if row[3] is not None]
                gaps = int(seqs[-1] - seqs[0] + 1 - len(seqs)) if len(seqs) > 1 else 0
                meta["places"][str(index)] = {"label": label, "target_mm": [tx, tz],
                                              "lost_frames_cam0": gaps}
                print(f"\nplace {index} saved: {len(rows)} frames per camera, "
                      f"{gaps} lost")
                done.append(index)
                i += 1
    finally:
        tracker.close()
        with open(os.path.join(out_dir, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)
        print(f"\n{len(done)} of {len(PLACES)} places saved in {out_dir}")


if __name__ == "__main__":
    main()
