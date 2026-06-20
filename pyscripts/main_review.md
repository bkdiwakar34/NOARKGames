# Tracker pipeline — review log

A rolling record of everything we've changed in the tracker (`pyscripts/main.py`, `pyscripts/filters.py`, `pyscripts/calibrate_camera.py`, `pyscripts/diagnose_jitter.py`) and the Godot adaptive system (`v2/Core/adaptive_manager.gd`, `v2/Games/random_reach/random_reach.gd`). Findings, decisions, and open TODOs.

Started: 2026-06-15.

---

## TODO (open)

- **Re-run the 4-corner screen-mapping calibration.** Both the removal of `cv2.flip(frame, 1)` and the switch to a properly-fit `camera_calib.toml` changed what raw values come out of the tracker. The old screen-mapping coefficients are invalid; redo via `workspace_calibration_overlay.gd`.
- **Resolution alignment audit.** `Config.FRAME_SIZE` is now `(1280, 800)` (OV9281 native). Confirm everything downstream in Godot is happy at this resolution.
- **Explore retroreflective / IR-lit markers.** Stick retroreflective tape on the existing markers and add an LED (visible or IR) ring around the camera. Decouples tracking from room lighting; lets exposure stay at 1–2 ms with maximum frame rate. OV9281 is IR-sensitive — IR LEDs + an IR-pass filter on the lens would be invisible to the patient and give the cleanest result.
- **Switch to OpenCV `aruco.Board` for skateboard pose.** Replace `_get_centroid` + `_get_local_coordinates` with a single `estimatePoseBoard` call. Requires each marker's full 6-DOF placement on the skateboard, not just translation. Workflow: place labelled construction coord systems in Fusion 360 (`marker_4`, `marker_8`, …) on each marker face, write a Fusion 360 Python add-in that exports them to `skateboard_geometry.csv` with `id, x, y, z, qx, qy, qz, qw`; load that at startup.
- **Try ChArUco diamonds on each face.** Drop-in replacement for individual markers — gives 8 corners per face instead of 4, ~50% reduction in hold-jitter, no CAD measurement needed. Each diamond is ~3× the size of a single marker so the skateboard faces need room.
- **Maybe add hold-detector + corner averaging on top of One Euro.** When speed has been below a threshold for N frames, average the last N corner positions instead of running One Euro. Noise drops by `√N` during the hold rather than approaching a fixed floor.
- **Maybe try STag** (Stable Tag) for ~20% lower corner-detection noise. Needs `pystag` installed (built from C++) on the Pi and reprinted markers. Smaller win than diamonds for similar physical-rework cost — only worth it if `diagnose_jitter.py` shows corner σ is the bottleneck.

---

## TODO (done)

### Calibration

- ~~`settings.json` missing → silent default.~~ Now `_load_settings()` prints `"settings.json not found at {path}, using defaults"`.
- ~~Two calibration files (`calib_mono_faith.toml` from the laptop webcam + `good.toml` for the Pi fisheye), with `solvePnP` accidentally using the laptop's intrinsics on the Pi.~~ Replaced both with a single `camera_calib.toml`. Both old files deleted.
- ~~Write a fisheye calibration script.~~ `pyscripts/calibrate_camera.py`: auto-capture on stable detection, runs `cv2.fisheye.calibrate`, saves to `camera_calib.toml`, multi-pose verify step reports accuracy (mm) / precision (mm) / fit (px) per pose plus overall stats.
- ~~Calibrate the Pi.~~ Done.
- ~~Wire `main.py` to the new calibration file.~~ Single load in `__init__`, fisheye undistort map built once, `solvePnP` and `drawFrameAxes` use K with `np.zeros(5)` distortion (image is already undistorted).
- ~~`vflip` was being applied but the OV9281 is mounted right-side-up.~~ Removed `libcamera.Transform(vflip=1)` from both `main.py` and `calibrate_camera.py`.
- ~~`cv2.flip(frame, 1)` introduced an x-axis error against the calibration's `cx`.~~ Removed.
- ~~`Config.FRAME_SIZE` was `(1200, 800)` but calibration is at `(1280, 800)`.~~ Aligned to `(1280, 800)`.

### Detection / pose

- ~~Switch `cornerRefinementMethod` from `CORNER_REFINE_CONTOUR` to `CORNER_REFINE_APRILTAG`.~~ Better sub-pixel accuracy for AprilTag markers (~half the corner noise).
- ~~`cv2.remap` interpolation was `INTER_LINEAR` (~0.5 px edge blur).~~ Switched to `INTER_CUBIC` — sharper, marginally more CPU.
- ~~World origin was anchored to the very first frame with any detection (jittery).~~ Now waits for 10 consecutive frames where the same marker set has < 2 px mean corner motion before locking. ~0.3 s warmup. Prints `"World origin locked after N stable frames."`
- ~~Dead code cleanup.~~ Removed unused `Config.MARKER_SEPARATION`, `self.marker_separation`, the inline `import time` calls, and `CoordinateTransform` references.

### Camera

- ~~Tried camera auto-exposure tune-then-lock (1 s AE convergence → freeze).~~ Adapts to room lighting but added perceptible lag. Reverted to fixed `ExposureTime=5000` (commented-out code preserved for future re-enable).

### Filter

- ~~Added `KalmanFilter3D`~~ — constant-velocity 6-D Kalman on `[x, y, z, vx, vy, vz]`, dt measured per-update.
- ~~Added `OneEuroFilter3D`~~ — adaptive cutoff scaled with speed; tuned for reach-and-hold.
- ~~`settings.json["filter_type"]` picks "ema" / "kalman" / "one_euro".~~ All three knobs exposed in `settings.json` with defaults.
- ~~`OneEuroFilter3D`'s default `beta` (`0.007`) is tuned for input in pixels; for meters it needs to be ~1000× larger.~~ Recommendation noted: try `beta ≈ 5–10` for meters.

### Heartbeat / dispatch

- ~~`run()`'s 3-second heartbeat was checking the sticky `received_message`, so it could never fire after the first packet.~~ Now checks `self._last_msg_time`, which is updated only when a fresh UDP packet actually arrives.
- ~~`CHANGE:` dispatch re-created the patient CSV folder + file every single frame after a CHANGE message arrived (because the message is sticky).~~ Now only re-initialises when the hospital ID actually changes.
- ~~CSV file handle was opened in `_select_hospitalid()` and dropped on the floor.~~ Now tracked as `self._csv_file`, closed before opening a new one and closed in `run()`'s `finally` block.
- ~~CSV timestamp was `"%d/%m/%Y %H:%M:%S"` — locale-ambiguous and only 1 s resolution; tracker writes ~30 rows per second all with the same timestamp.~~ Switched to ISO-8601 with millisecond precision: `"%Y-%m-%d %H:%M:%S.%f"[:-3]`.

### Diagnostics

- ~~Wrote `pyscripts/diagnose_jitter.py`~~ — multi-pose static-marker noise floor measurement. Reports corner σ (px), pose σ (mm), wiring sanity check, solver comparison across IPPE_SQUARE / ITERATIVE / SQPNP, and an automatic interpretation. Prompts the user through 5 marker poses (centre + 4 workspace corners).
- ~~Added per-stage timing instrumentation to `main.py`.~~ When `debug=true`, prints rolling 1-second averages of capture / remap / detect / pose+send to stdout AND appends to `/tmp/tracker_timing.log` for `tail -f` from another terminal.

### Adaptive (Godot side)

- ~~Multi-pose Fitts spawn was clamping only to the viewport, so apples could land outside the patient's reachable region.~~ New `_sample_reachable_spawn` in `adaptive_manager.gd` tries 24 random angles at distance `a` and accepts the first that lands within one scan-cell of a `reachable_cell`. Falls back to a random comfortable cell if none qualify.
- ~~Skipped Phase 0b (precision scan) and folded its job into Phase 0c.~~ Phase 0c now uses 5 distances × 3 widths = 15 pairs at 5 reps each (75 apples total vs the previous 30+200). `_w_min` is derived from per-W hit rates at the end of Phase 0c, not from a dedicated phase. Total session calibration drops from ~260 to ~105 apples.
- ~~No on-screen progress during calibration phases.~~ Added a centred banner that reads `"Setting up (1/2) — Workspace scan: apple 14 / 40"` etc., visible during the calibration phases and hidden during the live session.
- ~~No visualisation of the Fitts fit.~~ Added a 240×170 panel pinned to the bottom-right corner of `random_reach.gd`. Scatters every `(ID, MT)` from `outcome_log` as blue dots, draws the live `MT = a + b·ID` line in red, prints the current `a`, `b` and sample count. Only visible from Phase 0c onward.

---

## Open questions / notes

- **Why One Euro beats Kalman here.** Kalman is mathematically optimal under specific assumptions (linear system, Gaussian noise, model fits reality). Its constant-velocity model is wrong at exactly the moments that matter for rehab — the stops at targets — so it briefly overshoots. One Euro makes no model assumption; it just scales smoothing with measured speed. For input devices where motion is unpredictable, adaptive smoothing wins.
- **Why fisheye undistort the *image* and not the *corners*.** Standard advice is to detect on the raw image and undistort the few corner points downstream. For a 160° fisheye, the raw-image marker boundary is so curved near the image edges that `detectMarkers`'s quad filter rejects it. So we undistort the whole image first — pay a small precision cost from interpolation (mitigated by `INTER_CUBIC`) to avoid silently losing markers at the workspace edges.
- **What `solveCanonical()` doesn't do.** Even with the right calibration and refinement, single-marker pose estimation has natural depth ambiguity for planar targets; `σ_z` is usually ~3–5× larger than `σ_x` or `σ_y`. A multi-marker Board would shrink that.
- **Timing budget at 30 fps.** Each frame has 33 ms. Typical breakdown on Pi 5: capture ≈ 2 ms, remap ≈ 5 ms, detect ≈ 10–15 ms, pose+send < 1 ms. Total ≈ 18–23 ms — plenty of headroom. `diagnose_jitter.py` + `/tmp/tracker_timing.log` are how to confirm in practice.
- **`tracker.py` on the Pi has a separate UDP I/O thread (`UDPStreamer`); `main.py` does it inline.** Not a real lag source on localhost with tiny packets, but a structural difference worth knowing about.

---

## Walkthrough log (early notes)

### 1. Entry point — `if __name__ == "__main__":`

- `_load_settings()` reads `settings.json` from the project root; now prints a warning if missing.
- The hardcoded `CAMERA_CALIB_PATH = calib_mono_faith.toml` triggered the calibration discussion — main.py was loading the laptop webcam's calibration even on the Pi. Resolved by replacing both files with `camera_calib.toml`.

### 2. Calibration concepts

- Calibration produces: `K` (3×3 intrinsics — focal length and optical centre) + distortion coefficients (lens model).
- Pinhole model: 5 coefficients `(k1, k2, p1, p2, k3)`. Fisheye model: 4 coefficients `(k1, k2, k3, k4)` — different equations.
- OV9281 (160° FOV) needs the fisheye model; pinhole maths can't fit it.
- One calibration per camera; used twice in the pipeline — once to undistort, once for `solvePnP` (with zero distortion after undistortion).
- `calibrate_camera.py`'s verify step reports:
  - **Accuracy** — square-edge length error vs the true 25 mm (tilt-invariant).
  - **Precision** — std of position across N still frames.
  - **Fit** — reprojection error in px.
