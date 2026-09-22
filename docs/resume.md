# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-22, 17:10

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

**Starting the system** (on the board):

```bash
# camera driver loads at boot (/etc/modules-load.d/ov9282.conf, 2026-09-22)
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

Frame-rate check: `tail -n 3 /tmp/tracker_timing.log` (look at `missed`).

## Next action (user's plan)

1. **Validation screen (F10 → Validation recorder):** make sure it is right for tomorrow.
2. **Jitter, a little more** — candidates, cheapest first:
   - room-light flicker (44 % brightness pulsing measured at 5 ms): lights-off test,
     then a non-dimmable 5 V USB COB LED strip above the cameras (not 850 nm IR);
   - black/white window 15 → 23 px (`adaptive_thresh_win_size`) for big near tags.
   Measure with a T1 rows 0–1 recording + `analysis/analyse_holds.py` / `find_jumps.py`.
3. **2026-09-23: the lab session** — wire pin 35/34, T0 gate check, T1 ×2, T2 ×12, T3,
   Motive recording at the same name. T3 still untried.

## Small open items

- A camera that cannot see the device searches its whole image every frame → lost
  frames (hand, lens cap). Fix: place its box from the other camera's pose / throttle.
- Right up against the cameras the rate drops (~86/s); avoided by the new placement.
- Back up the calibration files off the board — **including the new ones**
  (`board_geometry.json`, `stereo_extrinsics.json`, `camera_calib*.toml`, `origin_lock.json`).
- Dead code inside `main.py` (per-marker solver, `SETUP:` switch, single-camera mode,
  `raw_joint` pipeline if it stays unused).
- `uv lock` on the board, then commit (`gpiod` not pinned).
- Closing Godot leaves the tracker running a few seconds (Godot kills the bash
  wrapper, not python) → a quick restart finds the cameras busy. Fix: `exec` in
  `udp_receiver.gd`'s start command. Meanwhile: `pkill -f pyscripts/main.py`.
- Decide on the in-game **■ Stop** button.

## Still to decide in the validation plan

Acceptance criteria per measure; where the reflective markers go on the device; T5
(recording during a real game).

## Deliberately not done

- Hardware camera sync — these Waveshare modules don't expose FSIN.
- Drift correction between the cameras — measured 0.3 ppm, not needed.
- Faster detection that changes what the detector computes — until the mocap can check it.
- Kiosk boot and upload — explicitly last.
