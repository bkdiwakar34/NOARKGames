# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-19

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**The system works end to end at exactly 100 samples/s, and the screen now runs at
100 Hz too.** Board rebuilt (SSD), both cameras calibrated, device and stereo
calibrated, Godot 4.5 installed. Camera-to-camera calibration checked against a
ruler (75.0 mm, 1.6° — matches the mount). Monitor switched 60 → 100 Hz in GNOME
Displays; a 66 s session still saved every sample (6629 gaps, all 10 ms). The hand
CSV has a `capture_time` column (camera capture time, Unix s to 1 µs).

**Starting the system** (on the board):

```bash
sudo modprobe ov9282        # camera driver — needed after every reboot
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

Godot starts the tracker itself, pinned to the fast cores. SSH: `ssh radxa@<ip>` — the IP
changes with the phone hotspot (`hostname -I` on the board). Calibration scripts must
be run in a terminal on the board, not over SSH (they open a window).

## Next action

Pick up the July agenda, which the sampling-rate work now supports:

1. **Data audit** — check every field the study needs is saved (schema:
   [v1_plan.md §5](v1_plan.md)). Data lives in `~/Documents/NOARK/data/<patient>/GameData/`.
2. **Healthy-user test** sessions.
3. **Analysis script** over the CSVs — use `capture_time`, not `epochtime`, for anything
   timing-sensitive.

## Small open items

- Stronger stereo test: save `main.py`'s per-frame cam0-vs-cam1 gap (`_fuse_board_poses`
  already computes it) and check it across the workspace. Its tolerance (20 mm / 6°)
  lets smaller disagreements be averaged in silently.
- One deliberate close-up run to confirm the 10 ms budget holds with the device nearest
  the cameras.
- Back up the four calibration files off the board (`pyscripts/camera_calib.toml`,
  `camera_calib_1.toml`, `board_geometry.json`, `stereo_extrinsics.json`).
- Auto-load `ov9282` at boot.
- Decide on the in-game **■ Stop** button (patients can reach the researcher graph).

## Deliberately not done

- 120 fps — possible (camera ceiling 120.6) but not needed.
- Faster detection that changes what the detector computes (Aruco3 downscaling,
  detecting on the raw picture) — rejected until accuracy can be checked.
- Kiosk boot (package 5) and upload (package 7) — explicitly last.
