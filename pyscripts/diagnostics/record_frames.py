"""
Frame bank: raw camera frames at spots all over the table, for offline pipeline tests.

Every later test of the image pipeline (undistortion, detection settings, detect
on the raw image, ...) runs on these same frames, so versions can be compared
directly instead of through a new T1 recording each time.

Runs the real tracker without Godot (like phase_test.py). The table is split
into 9 zones (near / middle / far x left / centre / right) using a full T1
recording: a spot belongs to the zone of the nearest T1 place, with

    near = grid rows 0-1, middle = rows 2-5, far = rows 6-7
    left = columns 0-3, centre = columns 4-7, right = columns 8-11

Put the device anywhere; the terminal says which zone it is in:

    zone: near-left  (not yet)  - Enter to record | cam0 3  cam1 2    done 2/9: far-left, middle-centre

Enter records wherever the device is (a done zone can take more spots — useful
along the near edge); q quits. Corner zones: push the device into the corner.
near-centre: right at the near edge, where the pose jumped.

Per spot it saves FRAMES consecutive frames from each camera, untouched (the
raw fisheye image, before undistortion), with capture times, sequence numbers
and what the tracker computed for each.

The game must be closed: both want the cameras.

    python pyscripts/diagnostics/record_frames.py
    python pyscripts/diagnostics/record_frames.py --targets ~/Documents/NOARK/validation/2026-09-22_T1_grid_r1

Output: ~/Documents/NOARK/framebank/<date-time>/spot_NN_<zone>/{cam0.npy,
cam1.npy, frames.csv}, plus meta.json and calib/ at the top.
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
from coverage_markers import place_row_col
from main import MainClass, _load_settings, calib_path

FRAMES = 50
GRID_PLACES = 96
ROW_BANDS = [("near", range(0, 2)), ("middle", range(2, 6)), ("far", range(6, 8))]
COL_BANDS = [("left", range(0, 4)), ("centre", range(4, 8)), ("right", range(8, 12))]
ZONES = [f"{r}-{c}" for r, _ in ROW_BANDS for c, _ in COL_BANDS]
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


def place_positions(folder: str) -> tuple:
    """(positions mm (N, 2) as x, z; zone name per place) from the T1 holds."""
    holds, s = read_marks(folder), read_samples(folder)
    if np.all(np.isnan(s["game_x_m"])):
        sys.exit(f"{folder} has no table (game) coordinates — origin was not locked.")
    pos, zone = [], []
    for index, (a, b, _, _) in sorted(holds.items()):
        x, z = s["game_x_m"][a:b], s["game_z_m"][a:b]
        if not np.any(~np.isnan(x)):
            continue
        row, col = place_row_col(index)
        r = next(name for name, band in ROW_BANDS if row in band)
        c = next(name for name, band in COL_BANDS if col in band)
        pos.append((1000.0 * float(np.nanmean(x)), 1000.0 * float(np.nanmean(z))))
        zone.append(f"{r}-{c}")
    return np.array(pos), zone


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
    sys.stdout.write("\r" + text.ljust(120)[:120])
    sys.stdout.flush()


def capture_spot(tracker, n: int) -> tuple:
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


def save_spot(d: str, frames0, frames1, rows) -> None:
    os.makedirs(d)
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
    positions, place_zone = place_positions(ref)
    print(f"Zones from {ref}")
    if not same_origin(ref):
        print("[warn] origin_lock.json differs from the one that recording used, so the "
              "zones may be shifted a little. Check the first spot against where the "
              "T1 dots were.")

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
            "zones_from": ref, "frames_per_spot": args.frames,
            "zones": "near = T1 rows 0-1, middle = 2-5, far = 6-7; left = columns "
                     "0-3, centre = 4-7, right = 8-11 (zone of the nearest T1 place)",
            "frames": "raw fisheye images, uint8, shape (frames, height, width), "
                      "before undistortion",
            "settings": settings,
            "undistorted": {"size": list(tracker.ud_size),
                            "border_px": list(tracker._ud_pad),
                            "camera_matrix_cam0": tracker.camera_matrix.tolist(),
                            "camera_matrix_cam1": (None if tracker.camera_matrix_1 is None
                                                   else tracker.camera_matrix_1.tolist())},
            "spots": []}
    print(f"Saving to {out_dir}\n")
    print("Enter = record here   q = quit\n")

    done = {z: 0 for z in ZONES}
    try:
        with Keys() as keys:
            last_draw, zone, where = 0.0, None, None
            while True:
                r = tracker.process_frame()
                key = keys.get()
                if key == "q":
                    break
                if r is None:
                    continue
                m0, m1 = n_markers(r.ids[0]), n_markers(r.ids[1])
                if r.local_coords is None:
                    zone, where = None, None
                    text = "device not tracked"
                else:
                    g = np.asarray(r.local_coords).reshape(3) * 1000.0
                    where = (float(g[0]), float(g[2]))
                    nearest = int(np.argmin(np.hypot(*(positions - where).T)))
                    zone = place_zone[nearest]
                    state = "not yet" if done[zone] == 0 else f"done x{done[zone]}"
                    text = f"zone: {zone:<13} ({state})  - Enter to record"
                n_done = sum(1 for z in ZONES if done[z])
                todo = [z for z in ZONES if not done[z]]
                tail = (f"done {n_done}/9" + (f", still: {', '.join(todo)}" if todo else ", all zones"))
                now = time.monotonic()
                if now - last_draw > 0.1:
                    status_line(f"{text} | cam0 {m0}  cam1 {m1}   {tail}")
                    last_draw = now
                if key not in ("\n", "\r") or zone is None:
                    continue

                frames0, frames1, rows = capture_spot(tracker, args.frames)
                spot = len(meta["spots"])
                save_spot(os.path.join(out_dir, f"spot_{spot:02d}_{zone}"), frames0, frames1, rows)
                seqs = [row[3] for row in rows if row[3] is not None]
                gaps = int(seqs[-1] - seqs[0] + 1 - len(seqs)) if len(seqs) > 1 else 0
                meta["spots"].append({"spot": spot, "zone": zone,
                                      "position_mm": list(where), "lost_frames_cam0": gaps})
                done[zone] += 1
                print(f"\nspot {spot} saved in {zone}: {len(rows)} frames per camera, "
                      f"{gaps} lost")
    finally:
        tracker.close()
        with open(os.path.join(out_dir, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)
        missing = [z for z in ZONES if not done[z]]
        print(f"\n{len(meta['spots'])} spots saved in {out_dir}"
              + (f"; zones not covered: {', '.join(missing)}" if missing else "; all 9 zones covered"))


if __name__ == "__main__":
    main()
