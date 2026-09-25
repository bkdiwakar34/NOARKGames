# NOARKGames — Open TODOs

Active work-in-progress and known issues. Completed items live in git history, not here.
The v1 product build order (logging, game feel, kiosk, installer mode, upload) is tracked in
[v1_plan.md §7](v1_plan.md), not duplicated here.

---

## Tracker pipeline

What happens next, in order, is in [resume.md](resume.md). This is the full open list.

### Camera arrangement and validation

- **Wider camera rig** (decided 2026-09-25: ~300 mm apart, ~20° inward; longer CSI
  cables ordered). Mount, then recalibrate: `calibrate_rig.py` (may need
  `calibrate_stereo.py` first for a starting guess — the pair's geometry changes
  completely), origin lock, 4 corners. Confirm with `measure_sigma.py` +
  `compare_jitter.py` on a T1 grid.
- **OptiTrack validation** of the new rig — [validation_plan.md](validation_plan.md).

### Accuracy and jitter (the jitter is corner noise — model and measurement agree)

- **Redo cam1's lens calibration** (0.79 px vs cam0's 0.19 px).
- **Check the chessboard is square** — fy is 0.6–0.7 % larger than fx on both
  cameras, the size of the printer's error on the tag stickers.
- **Search box loses tags 24 and 28 together in cam1** at some spots (flicker
  ~45 % of frames; 0–4 % with the whole image searched).
- **Corner refinement method**: compare `contour` (now) with `apriltag` and `subpix`.
- **Light**: flicker-free white light (not 850 nm IR — the OptiTrack); lower gain.
- **Tag size**: set `MARKER_LENGTH` from the mocap's fitted scale; reprint the next
  set pre-compensated for the printer (~1 % along one axis).
- **A camera that cannot see the device** searches its whole image every frame,
  and frames are lost. Place its box from the other camera's pose instead.

### Code

- **Delete the dead code behind the removed settings** (averaging, raw pipeline,
  single-camera and per-marker modes, demo `SETUP:` switch) — after the validation.
- **Run `uv lock` on the board** and commit it: `gpiod` (sync pin) is installed by
  hand but not in `uv.lock`, so a fresh install would lack it.
- **Back up the calibration files off the board** after every recalibration
  (`camera_calib*.toml`, `board_geometry.json`, `stereo_extrinsics.json`,
  `origin_lock.json` — git-ignored).

### Maybe / later

- **ChArUco diamonds** instead of single tags: chessboard corners are located far
  more precisely than tag corners (~50 % less jitter expected), but a diamond needs
  ~3× the area of a tag to stay readable at 600 mm.
- **STag** (circular border): ~20 % lower corner noise; needs `pystag` and reprinting.
- **rapidtag** (colleague's Rust detector): faster, but no sub-pixel refinement yet.
- **Retroreflective tags + IR light**: only if it can be made to coexist with the
  OptiTrack's 850 nm.

Ruled out: display filtering (One Euro etc.) — decided 2026-09-24; fitting only
x, z, yaw on the table plane — tried 2026-09-23, froze the cursor.

---

## Godot / system integration

- **Auto-start Godot at boot.** Tracker is already auto-launched by the Godot autoload. A systemd unit (or similar) should start Godot itself at boot so the system is usable without SSH.
- **Data sync to researcher server.** The board pushes CSV files to a researcher's server when the patient connects to a mobile hotspot. Daily upload cadence.
- **Researcher dashboard.** Web-based view of patient progress. Technology not decided.

---

## Pre-clinical-deployment checklist

- [ ] Revert testing constants in `adaptive_manager.gd`:
  - `catch_hold_time` → 0.8
  - `LIFETIME_MAX` → 15.0
  - `LIFETIME_MIN` → 3.0
  - `trial_duration` → 60.0 (set via game_select UI)
- [ ] Verify Phase 0c calibration takes a tolerable amount of time on a real patient (currently 75 apples × ~3 s per attempt ≈ 4 min). Reduce `CAL_PER_PAIR` if needed.
- [ ] Q-Q-plot check of per-pair MT residuals — the lifetime formula assumes approximate normality. If badly violated, reconsider.
- [ ] One-session lag in (a, b) adaptation: RLS catches up over many trials, but large within-session improvements (e.g., warm-up) lag the model. Decide whether to add a forgetting factor or accept the lag.
