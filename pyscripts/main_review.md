# main.py walkthrough

A section-by-section read of `pyscripts/main.py`, tracing execution order from the entry point. Each section records what the code does and any improvement ideas we agree are worth doing.

Started: 2026-06-15

---

## TODO (open)

- **Switch `main.py` over to the new `camera_calib.toml`.** Once the Pi has been calibrated with `calibrate_camera.py`, replace the two-file setup (`calib_mono_faith.toml` + `good.toml`) with a single load of `camera_calib.toml`. The pipeline becomes: undistort frame with the fisheye params, then `solvePnP` using the same K with **zero distortion** (because the undistorted image is now pinhole-equivalent). Delete the old TOML files when done.
- **Run `calibrate_camera.py` on the Pi** and check the three quality numbers (accuracy < 1 mm, precision < 0.5 mm is the rough target).

## TODO (done)

- ~~Warn when `settings.json` is missing instead of silently using defaults.~~ Done — `_load_settings()` now prints the path it tried.
- ~~Write a new calibration script.~~ Done — see `pyscripts/calibrate_camera.py`. Auto-capture on stable detection, fisheye calibration, saves to `camera_calib.toml`, verify step reports accuracy/precision/fit.

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
