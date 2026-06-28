# NOARKGames — Setup

How to set up the hardware and run the system on a Raspberry Pi. For what the system does and how it works, see [design.md](design.md).

---

## Hardware

| Component | Detail |
|---|---|
| Computer | Raspberry Pi 5 (Linux ARM64) |
| Camera | OV9281 monochrome fisheye camera (160° FOV), CSI ribbon |
| Input device | NOARK device with ArUco markers (IDs 12, 14, 20 active) |
| Display | Monitor connected to Pi |
| Repo on Pi | `/home/sujith/Documents/NOARKGames/` |
| Godot binary | `/home/sujith/Downloads/Godot_v4.5-stable_linux.arm64` |

---

## First-time setup on a fresh Pi

### 1. Install Godot

Download the ARM64 Linux Godot binary and place it at the path above. The project targets Godot 4.5.

### 2. Install Python deps

```bash
cd ~/Documents/NOARKGames
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

Dependencies declared in `pyproject.toml`; `uv.lock` pins exact versions.

### 3. Calibrate the camera (one-time per camera)

Print or display a 9×6 chessboard (square side **24.35 mm**, measured). Then:

```bash
python pyscripts/calibrate_camera.py
```

The script auto-captures frames when the board is held steady, runs `cv2.fisheye.calibrate`, and writes `pyscripts/camera_calib.toml`. Multi-pose verification at the end reports accuracy (mm), precision (mm), and reprojection fit (px) per pose. A typical good calibration has reprojection error < 1 px.

Recalibrate only if camera changes, lens changes, or resolution changes.

### 4. Calibrate sensor-to-screen mapping (one-time per workspace setup)

Run the game and use the workspace calibration overlay. The patient (or you) touches the four screen corners (TL → TR → BL → BR) with the device. The 6-parameter affine transform is fitted via OLS and written to `user://workspace_config.json`.

**Order matters:** TL → TR → BL → BR. Swapping the order silently produces a wrong-axis transform.

### 5. Configure settings

`settings.json` at the project root:

```json
{
    "debug": false,
    "udp_port": 12345,
    "calibration_file": "camera_calib.toml",
    "corner_refine": "contour",
    "corner_stability_threshold": 2.0,
    "filter_type": "one_euro",
    "kalman_process_noise": 0.01,
    "kalman_measurement_noise": 0.05,
    "one_euro_min_cutoff": 1.0,
    "one_euro_beta": 0.007,
    "one_euro_d_cutoff": 1.0,
    "pnp_method": "square",
    "framerate": 100
}
```

`debug: true` enables a 350×200 OpenCV preview window in the tracker and skips authentication in Godot (sets patient ID to `vvv`). Leave `false` for headless / production.

---

## Running the system

The tracker is launched automatically by the Godot UDPReceiver autoload. To run manually for debugging:

```bash
# Terminal 1 — tracker
cd ~/Documents/NOARKGames
source .venv/bin/activate
python pyscripts/main.py

# Terminal 2 — game
~/Downloads/Godot_v4.5-stable_linux.arm64 --path . --main-scene res://v2/Scenes/main.tscn
```

Or open `project.godot` in the Godot editor and press F5.

### Main scene

`res://v2/Scenes/main.tscn`. Display: fullscreen, `canvas_items` stretch mode, OpenGL compatibility renderer (Raspberry Pi requirement).

### Game flow

1. Main screen — type hospital ID → press **Enter** (not Play button) → enters game selection.
2. Game select screen — pick "Apple Catch", set session parameters from the gear menu, press play.
3. Game starts. Phase 0a (workspace scan) runs first, then Phase 0c (Fitts calibration), then the session.

---

## Auto-start on Pi boot (not yet implemented)

The tracker is currently launched by Godot's autoload. A systemd-service-based auto-start of Godot itself on Pi boot is planned but not built. See [todo.md](todo.md).

---

## Useful Linux commands for debugging

| Command | Purpose |
|---|---|
| `ss -unp` | List open UDP sockets with process names |
| `ps aux \| grep python` | Check whether tracker is alive |
| `journalctl -u <service> -n 30` | Last 30 log lines from a systemd service |
| `tail -f /tmp/tracker_timing.log` | Watch per-stage tracker timing in real time (debug mode only) |
| `ssh sujith@<pi-ip>` | Remote shell into the Pi over the same WiFi |

---

## Common issues

**Tracker prints `"settings.json not found"`** — settings file is missing or the working directory is wrong. The tracker looks for `settings.json` one level above `pyscripts/`.

**Cursor doesn't move** — check `UDPReceiver.connected` in the debug overlay. If `false`, the tracker isn't reaching the receiver. Confirm both are using port `12345` (set by `udp_port` in settings.json).

**Cursor moves but in the wrong direction** — likely the sensor-to-screen calibration was done in the wrong corner order. Redo the 4-corner calibration (TL → TR → BL → BR).

**`solvePnP` returns wildly inconsistent poses** — usually means the calibration file doesn't match the camera. Re-run `calibrate_camera.py`.

**Cursor jumps when a marker enters or leaves view** — `MARKER_OFFSETS` for that marker are wrong. The values must be expressed in the marker's own local frame; see [design.md §8](design.md).

**Per-stage timing print spam** — `debug` is enabled in `settings.json`. Set to `false` for normal operation.
