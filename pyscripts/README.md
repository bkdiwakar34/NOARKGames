# pyscripts/ — the tracker and its tools

ArUco marker tracking → UDP → Godot. The Godot `UDPReceiver` autoload launches
`main.py` for you (`cd pyscripts && python main.py`). See
[../docs/setup.md](../docs/setup.md) for the hardware and full run instructions.

```
pyscripts/
  main.py, board.py, recording.py, pose_averaging.py   the tracker
  camera_calib*.toml, board_geometry.json, ...          this board's calibration (not in git)
  calibration/     run once per camera / device
  analysis/        read a validation recording, change nothing
  diagnostics/     checks on the live system
```

The tracker and the calibration files stay at the top: Godot starts `main.py`
from here and `main.py` reads the calibration files next to itself. Scripts in
the subfolders put `pyscripts/` on Python's path at their top, so they import
`board.py` etc. as before, and the calibration scripts write their files here,
not into `calibration/`.

Run everything from the repo root with the venv active, e.g.
`python pyscripts/analysis/analyse_holds.py`.

## The tracker

| File | Purpose |
|---|---|
| `main.py` | The tracker. Camera capture, undistortion, marker detection, pose solve, fusion of the two cameras, origin lock, UDP streaming to Godot. No smoothing. |
| `board.py` | Shared device model: `MARKER_LENGTH`, `MARKER_OFFSETS` (grip offset per marker), and the `BoardGeometry` class that reads/writes `board_geometry.json`. |
| `recording.py` | Validation recording: the per-recording files and the OptiTrack sync pin (header pin 35, ground pin 34). Driven by `main.py` when Godot's installer screen asks. See [../docs/validation_plan.md](../docs/validation_plan.md). |
| `pose_averaging.py` | Rigid-transform averaging with outlier trimming, shared by the tracker and the calibration scripts. |

## calibration/ — run once each (see setup.md for when)

| File | Produces | Purpose |
|---|---|---|
| `calibrate_camera.py` | `camera_calib.toml`, `camera_calib_1.toml` | Fisheye lens intrinsics from a chessboard. Once per camera. |
| `calibrate_board.py` | `board_geometry.json` | Where each marker sits on the device. Once per device (redo if a marker is re-glued). |
| `calibrate_stereo.py` | `stereo_extrinsics.json` | Fixed transform between the two cameras. Redo if a camera moves. |
| `calibrate_rig.py` | `board_geometry.json` + `stereo_extrinsics.json` | Both fitted TOGETHER from both cameras (bundle adjustment over every corner), so the tag layout and cam1-to-cam0 agree with what both cameras see. Checks itself on held-out frames; asks before writing. |
| `derive_offsets.py` | (prints) | Back-solves a wrong/unknown `MARKER_OFFSETS` entry from the calibrated board geometry. |
| `markers.py` | `tag_*.png` | Regenerates the printable marker images, in the current folder. |

## analysis/ — offline, from one recording

| File | Purpose |
|---|---|
| `analyse_holds.py` | What one T1 recording says without the mocap: per-place jitter, drift, height error, cam0-vs-cam1 disagreement, coverage, plus an optional map of the table (`--png`, `--key`). |
| `coverage_markers.py` | Why a camera sees fewer markers at some T1 places: each unseen marker sorted into facing away / off the lens / cropped by undistortion / edge-on / missed; suggests the undistortion border. |
| `compare_fusion.py` | Five ways of turning both cameras' corners into one pose, compared on the same recording. |
| `find_jumps.py` | What happens when the pose jumps: shake vs a smoothed path, and whether jumps coincide with tags changing, the fusion mode switching, the cameras disagreeing or a poor fit — compared with how common each is normally. |
| `bench_joint.py` | The joint two-camera solve, slow (numerical derivatives) vs standard (derivatives written out), on one recording's corners: time per fit on the board, agreement between the two, acceptance. |
| `which_calibration.py` | Which calibration makes the cameras disagree: each camera alone vs the joint fit, per tag, by distance from the image centre and by table zone — points at the stereo, device or lens calibration. |
| `camera_placement.py` | Where should the cameras sit? Scores "what if" placements (moved back / up, re-aimed) at every T1 place from the recorded device poses: usable markers, worst angle, sharpness. |
| `check_board.py` | Is the device geometry the limit? Per-marker consistency of `board_geometry.json`. |

## diagnostics/ — on the live system (close the game first)

| File | Purpose |
|---|---|
| `phase_test.py` | Runs the tracker without Godot and prints the two cameras' timing offset once a second. |
| `record_frames.py` | Frame bank: saves 50 raw frames per camera wherever you put the device, and shows which of 9 table zones are covered — for offline pipeline tests. |

## Generated files (never committed — per machine / per device)

`camera_calib*.toml`, `board_geometry.json`, `stereo_extrinsics.json`,
`origin_lock.json`, in this folder. These describe *this* camera and *this*
device; syncing one machine's copy onto another silently corrupts tracking, so
`.gitignore` keeps them local. Back them up outside git.
