# pyscripts/ — the tracker and its calibration tools

ArUco marker tracking → UDP → Godot. Run `main.py` before the game (the Godot
`UDPReceiver` autoload normally launches it for you). See
[../docs/setup.md](../docs/setup.md) for the hardware and full run instructions.

Files are deliberately flat — they import each other as siblings
(`from board import ...`), so moving them into subfolders would break those
imports without extra path plumbing.

## The tracker

| File | Purpose |
|---|---|
| `main.py` | The tracker. Camera capture, marker detection, pose solve (joint rigid-body or per-marker), origin lock, filtering, UDP streaming to Godot. |
| `board.py` | Shared device model: `MARKER_LENGTH`, `MARKER_OFFSETS` (grip offset per marker), and the `BoardGeometry` class that reads/writes `board_geometry.json`. |
| `filters.py` | Smoothing and gating: EMA, Kalman, One Euro, corner-stability. |

## Calibration (run once each — see setup.md for when)

| File | Produces | Purpose |
|---|---|---|
| `calibrate_camera.py` | `camera_calib.toml` | Fisheye lens intrinsics from a chessboard. Once per camera. |
| `calibrate_board.py` | `board_geometry.json` | Where each marker sits on the device, by chaining pairwise transforms to a reference marker. Once per device (redo if a marker is re-glued). |
| `calibrate_stereo.py` | `stereo_extrinsics.json` | Fixed transform between the two cameras (Dragon Q6A dual-camera setup only). |

## Utilities

| File | Purpose |
|---|---|
| `derive_offsets.py` | Back-solves a wrong/unknown `MARKER_OFFSETS` entry from the calibrated board geometry plus the markers that are trusted. |
| `pose_averaging.py` | Shared rigid-transform averaging with outlier trimming, used by both `calibrate_board.py` and `calibrate_stereo.py`. |
| `diagnose_jitter.py` | Multi-pose noise-floor measurement for the tracker itself. (For the old-vs-rigid comparison harness see [../tools/](../tools/).) |
| `markers.py` | Regenerates the printable ArUco marker PNGs. |

## Generated files (never committed — per machine / per device)

`camera_calib*.toml`, `board_geometry.json`, `stereo_extrinsics.json`,
`origin_lock.json`. These describe *this* camera and *this* device; syncing one
machine's copy onto another silently corrupts tracking, so `.gitignore` keeps
them local. Back them up outside git.
