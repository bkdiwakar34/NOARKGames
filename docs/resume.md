# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-22, 20:10

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**Goal: validate the device against the lab's OptiTrack — session planned for
2026-09-23.** Protocol: **[validation_plan.md](validation_plan.md)**.

**The tracker today** (committed `settings.json`):
- `"dual_solve": "joint"` — ONE solve over all corners of both cameras (fast,
  derivatives written out). `"average"` = the old per-camera average, as a fallback.
- `"overlap_detect_solve": true` — search frame N while solving N−1:
  **100 samples/s, 0 missed** through Godot. Positions arrive 10 ms later.
- `"pipeline": "current"` (image straightened), border `0`, 15 px threshold window,
  5 ms exposure, `stereo_max_frame_skew_ms` 2.
- **Calibration redone 2026-09-22 with `calibration/calibrate_rig.py`** (tag layout +
  cam1-to-cam0 fitted together): held-out error 1.26 → 0.80 px. Old files kept as
  `pyscripts/*.before-<date-time>`.
- Camera setup moved away from the near edge; origin re-locked, 4 corners redone.

**Result:** big jumps gone, cursor steadier; a **very slight shimmer** remains.

**Evening 2026-09-22 — start-up made reliable** (tested, starts first time):
- camera driver loads at boot (`/etc/modules-load.d/ov9282.conf`);
- tracker watchdog + capture times on the monotonic clock — the board has no
  battery clock and jumps (+2 h 19 min) when it syncs online, which killed the
  tracker ("no UDP packets from Godot for 3 s");
- Godot's start command uses `exec`, so quitting the game stops the tracker;
- the overlap's first pass reads Godot too (start-up longer than 3 s no longer exits).

**Recorder checked:** T1 dots cover the table, T2 pacer right (fast = lap 6),
T3 runs (16 reaches, 32 labels). T0 gate check left for the lab (real eSync).

**Starting the system** (on the board):

```bash
# camera driver loads at boot (/etc/modules-load.d/ov9282.conf, 2026-09-22)
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

Frame-rate check: `tail -n 3 /tmp/tracker_timing.log` (look at `missed`).

## Next action: 2026-09-23, the lab session (tracker frozen as is)

Decided: no tracker changes before the validation — it measures today's setup.

Before leaving: back up the calibration files (below). Carry the camera mount as
one piece — if the two cameras shift relative to each other, run
`calibration/calibrate_rig.py` (5 min) before recording.

In the lab:
1. Let the board get online (its clock syncs; wait until `date` is right).
2. Recalibrate everything, in this order (game closed):
   `calibration/calibrate_camera.py --backend rcam --cam-id CAM2`, then
   `--cam-id CAM3 --output camera_calib_1.toml`; then `calibration/calibrate_rig.py`
   (tag layout + cam1-to-cam0 together — NOT calibrate_board/calibrate_stereo, which
   chain the errors); then start Godot, **re-lock the origin, redo the 4 corners**.
3. Wire eSync → pin 35, GND → pin 34; **T0**: gate low, Motive record → high → low.
   Our cameras have no IR filter: watch whether the OptiTrack's 850 nm strobes make
   the image pulse (tracking steady? `tail -n 3 /tmp/tracker_timing.log`).
4. T1 ×2, T2 ×12, T3 (comfortable ×3, fast ×3), Motive take named like each recording.

After the lab — jitter, one change at a time, each measured:
light (LED strip) → corner method (contour / subpix / apriltag, on still AND moving
raw frames) → One Euro filter for the game display only (data stays raw). Offline,
every recording can be re-solved as cam0 / cam1 / average / joint
(`analysis/compare_fusion.py`) and compared with the mocap.

## Small open items

- A camera that cannot see the device searches its whole image every frame → lost
  frames (hand, lens cap). Fix: place its box from the other camera's pose / throttle.
- Right up against the cameras the rate drops (~86/s); avoided by the new placement.
- Back up the calibration files off the board — **including the new ones**
  (`board_geometry.json`, `stereo_extrinsics.json`, `camera_calib*.toml`, `origin_lock.json`).
- Dead code inside `main.py` (per-marker solver, `SETUP:` switch, single-camera mode,
  `raw_joint` pipeline if it stays unused).
- `uv lock` on the board, then commit (`gpiod` not pinned).
- `compare_fusion.py`'s joint method still uses the slow fit (same answers, slower).
- Decide on the in-game **■ Stop** button.

## Still to decide in the validation plan

Acceptance criteria per measure; where the reflective markers go on the device; T5
(recording during a real game).

## Deliberately not done

- Hardware camera sync — these Waveshare modules don't expose FSIN.
- Drift correction between the cameras — measured 0.3 ppm, not needed.
- Faster detection that changes what the detector computes — until the mocap can check it.
- Kiosk boot and upload — explicitly last.
