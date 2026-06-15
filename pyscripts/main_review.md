# main.py walkthrough

A section-by-section read of `pyscripts/main.py`, tracing execution order from the entry point. Each section records what the code does and any improvement ideas we agree are worth doing.

Started: 2026-06-15

---

## TODO (open)

- **Re-run the 4-corner screen-mapping calibration.** Two things changed in `main.py` that the screen-mapping was silently absorbing: (1) `cv2.flip(frame, 1)` was removed, (2) the camera intrinsics now come from a correctly-calibrated `camera_calib.toml`. The old screen-mapping coefficients are no longer valid.
- **Resolution alignment audit.** `Config.FRAME_SIZE` was bumped from `(1200, 800)` to `(1280, 800)` to match the calibration. Confirm the Pi camera still configures at 1280×800 cleanly and the downstream Godot mapping still works at the new resolution.
- **Explore retroreflective / IR-lit markers** to decouple tracking from room lighting. Simplest first experiment: stick retroreflective tape on the ArUco markers and add a ring of LEDs (visible or IR) around the camera lens. Lets exposure drop to 1–2 ms, runs at full frame rate, room lighting becomes irrelevant. OV9281 is IR-sensitive — IR LEDs + an IR-pass filter on the lens would give the cleanest result and be invisible to the patient.
- **Switch to OpenCV `aruco.Board` for skateboard pose.** Replace the current `_get_centroid` + `_get_local_coordinates` two-step (which only uses one marker for orientation and averages by hand) with a single `estimatePoseBoard` call that solves for the whole skateboard's pose using all visible markers simultaneously. Needs each marker's full 6-DOF placement on the skateboard (not just the position offsets currently in `Config.MARKER_OFFSETS`). Workflow: in Fusion 360, place labelled construction coord systems (`marker_4`, `marker_8`, …) on each marker face; write a Fusion 360 Python add-in that exports them to `skateboard_geometry.csv` with `id, x, y, z, qx, qy, qz, qw`; main.py loads that at startup and builds the `aruco.Board`.

## TODO (done)

- ~~Warn when `settings.json` is missing instead of silently using defaults.~~ Done — `_load_settings()` now prints the path it tried.
- ~~Write a new calibration script.~~ Done — see `pyscripts/calibrate_camera.py`. Auto-capture on stable detection, fisheye calibration, saves to `camera_calib.toml`, verify step reports accuracy/precision/fit.
- ~~Run calibration on the Pi.~~ Done.
- ~~Switch `main.py` over to `camera_calib.toml`.~~ Done. Two TOML files (`calib_mono_faith.toml` + `good.toml`) replaced by one. Undistort map is built in `__init__` from the loaded fisheye `K`/`D`; `solvePnP` and `drawFrameAxes` now use `K` with zero distortion because the frame is already undistorted upstream. `cv2.flip(frame, 1)` removed (was introducing a small x-error against the calibration's `cx`). Old TOML files deleted.

---

## Walkthrough log

### 1. Entry point — `if __name__ == "__main__":` (line 335)

- `_load_settings()` reads `settings.json` from the project root. Now prints a warning if the file is missing instead of silently falling back to defaults.
- The hardcoded `CAMERA_CALIB_PATH = calib_mono_faith.toml` is the trigger that led us into the calibration discussion. We found that the current code loads `calib_mono_faith.toml` (the laptop webcam's calibration) and uses it for `solvePnP` even on the Pi — which is wrong, because on the Pi `solvePnP` should use the OV9281's own intrinsics (from `good.toml`, with zero distortion after the fisheye undistort step).
- Decision: replace both TOML files with a single fresh `camera_calib.toml`, produced by a dedicated calibration script. Script is written; main.py switch-over is the next step.

### 2. Calibration logic (deep dive)

Notes captured during the side discussion, in case it helps future-you:

- A camera calibration produces a 3×3 intrinsic matrix `K` (focal length + optical centre) and a set of distortion coefficients describing how the lens bends straight lines.
- Standard pinhole model: 5 coefficients `(k1, k2, p1, p2, k3)`. Fisheye model: 4 coefficients `(k1, k2, k3, k4)`. Same shape of `K` either way.
- The Pi camera (OV9281, 160° FOV) needs the fisheye model — pinhole maths can't represent the lens correctly.
- One calibration is enough per camera; it gets *used* twice in the pipeline (once to undistort the frame, once for `solvePnP`).
- Quality numbers the verify step reports:
  - **Accuracy** — measured square edge length vs the true 25 mm. Tilt-invariant because it uses known board geometry.
  - **Precision** — std of position across N still frames. Tells you the tracker's jitter floor.
  - **Fit** — reprojection error in px on the verify frames. < 1 px is good.
