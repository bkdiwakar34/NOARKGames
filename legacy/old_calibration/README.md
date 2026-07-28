# old_calibration/ — retired camera calibration

`camera_calib_diwakar.toml` belongs to a **different camera** than the one in
use. Its focal length is ~598 px against the current camera's ~887 px, and its
principal point differs by over 100 px — different optics entirely, not an older
calibration of the same unit.

It also predates the split between calibration and configuration: it carries
marker sizes, UDP host/port and display flags alongside the intrinsics, which
now live in `settings.json`.

Kept only as a record. **Do not point `settings.json` at it** — applying another
camera's intrinsics silently produces wrong 3D positions.

The live calibration is `pyscripts/camera_calib.toml`, regenerated per machine
by `calibrate_camera.py` and gitignored (see `pyscripts/README.md`).
