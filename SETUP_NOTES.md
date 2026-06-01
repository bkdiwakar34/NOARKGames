# NOARKGames — Setup Notes
_Last updated: 2026-05-27 19:11_

---

## What this system is

A rehabilitation gaming platform for stroke patients. The patient holds/wears a physical device (**NOARK device**) that has ArUco markers attached. A camera tracks those markers in real time. The position data drives mini-games on screen — the patient moves their arm to play the game, which is the therapy.

---

## Hardware

| Component | Detail |
|---|---|
| Computer | Raspberry Pi 5 (Linux ARM64) |
| Camera | OV9281 monochrome fisheye camera (160° FOV), CSI ribbon cable |
| Input device | NOARK device with ArUco markers (IDs 4, 8, 12, 14, 20) |
| Display | Monitor connected to Pi |
| Username on Pi | `sujith` |
| Repo on Pi | `/home/sujith/Documents/NOARKGames/` |
| Godot binary | `/home/sujith/Downloads/Godot_v4.5-stable_linux.arm64` |

---

## Full data pipeline

```
OV9281 Camera (160° FOV, fisheye)
    ↓
pyscripts/tracker.py  (Python — runs as systemd service on boot)
    - captures frames via picamera2 at 100fps
    - undistorts fisheye using calibration/good.toml
    - detects ArUco markers (AprilTag 36h11 dictionary)
    - estimates 3D pose via solvePnP
    - computes centroid across all visible markers
    - applies EMA smoothing (alpha=0.4)
    - packs 11 floats: [status_code, cx,cy,cz, rvx,rvy,rvz, tx,ty,tz, ref_id]
    ↓
UDP socket → localhost:12345
    ↓
Main_screen/Scripts/global_script.gd  (Godot — reads first 4 floats)
    - background thread reads UDP packets
    - _apply_position_packet() reads: [code, x, y, z]
    - scales raw coords to screen pixels
    - exposes net_x, net_y, net_z as global variables
    ↓
All games (GDScript)
    - read GlobalScript.network_position or network_position3D
    - use it to move game objects
```

**Also back the other way:**
```
Godot → sends heartbeat ("CONNECTED") every 0.1s → port 12345
tracker.py → receives heartbeat, knows Godot's reply address → sends coordinates back
```

---

## Key concepts explained

**ArUco markers** — Printed square patterns a camera can detect and uniquely identify. Each has an ID. Camera + calibration lets us compute exact 3D position in space.

**Pose estimation (solvePnP)** — Given 2D pixel positions of marker corners + real-world marker size → compute 3D position and rotation.

**EMA filter** — Exponential Moving Average. Smooths noisy data. alpha=0.4 means 40% new data, 60% history. Reduces jitter.

**Fisheye undistortion** — The 160° wide-angle lens distorts the image. Calibration captures this mathematically so it can be corrected before detection.

**Calibration file (good.toml)** — Stores camera intrinsics (focal length, optical centre, distortion coefficients). Generated once by pointing camera at checkerboard. Located at `pyscripts/calibration/good.toml`.

**UDP** — Network protocol used as inter-process communication between tracker.py and Godot. Both on same machine (localhost). Fast, no handshake needed.

**SSH** — Lets you control the Pi terminal from Windows over WiFi. `ssh sujith@10.68.132.212`

**systemd service** — A program registered to start automatically on Linux boot. `noark-tracker.service` starts `tracker.py` at boot time.

**Autoload (Godot)** — Scripts loaded once, alive for entire session. `GlobalScript` is an autoload — any game can access `GlobalScript.network_position` directly.

---

## Files

| File | What it does |
|---|---|
| `pyscripts/tracker.py` | **Production tracker** — runs as systemd service, uses good.toml |
| `pyscripts/main.py` | Older tracker — do NOT use (conflicts with tracker.py) |
| `pyscripts/filters.py` | Exponential moving average filter |
| `pyscripts/calibration/good.toml` | Camera calibration (OV9281, fisheye, 1280×800) |
| `Main_screen/Scripts/global_script.gd` | UDP receiver, position scaler, Godot autoload |
| `settings.json` | Runtime config — stream type, UDP port, debug mode |
| `project.godot` | Godot project entry point |

---

## calibration/good.toml — key values

```toml
[camera]
resolution = [1280, 800]
model = "OV9281"
fov = 160

[stream_data]
ip = "localhost"
port = 12345       ← tracker.py binds HERE

[display]
display = false    ← no camera preview window (runs headless)

[aruco]
marker_length = 0.05
marker_spacing = 0.01
```

---

## settings.json — current state (after fixes)

```json
{
    "debug": false,
    "stream_type": "udp",
    "ble_device_name": "NOARK_Tracker",
    "udp_port": 12345,
    "launch_python": false
}
```

`launch_python: false` — tracker.py runs as a systemd service, Godot must NOT try to launch its own Python.

---

## What was wrong and what was fixed

### Problem 1 — Wrong stream type
`settings.json` had `"stream_type": "ble"` → Godot was trying BLE, not UDP.
**Fix:** Changed to `"stream_type": "udp"`.

### Problem 2 — Wrong Linux paths in global_script.gd
Godot was trying to launch:
- `/home/sujith/Documents/rpi_python/stream_optimize.py` (doesn't exist)
- `/home/sujith/Documents/rpi_python/venv/bin/python` (wrong directory)

**Fix:** Updated to:
- `/home/sujith/Documents/NOARKGames/pyscripts/main.py`
- `/home/sujith/Documents/NOARKGames/.venv/bin/python`

### Problem 3 — Port mismatch (critical)
- `tracker.py` listens on port **12345** (from good.toml)
- Godot was connecting to port **8000** (hardcoded)
- They were not communicating at all

**Fix:** Added `udp_port` variable to `global_script.gd`, read from `settings.json`. Set `"udp_port": 12345` in settings.

### Problem 4 — Camera conflict
- `tracker.py` runs as `noark-tracker.service` (auto-start on boot), holds the camera
- Godot was also launching `main.py` → two scripts fought over camera → crash

**Fix:** Added `launch_python` flag to `global_script.gd`. Set `"launch_python": false` in settings.json. Godot now skips Python launch entirely — the service handles it.

---

## Changes made to global_script.gd

1. Added class variables:
   ```gdscript
   var udp_port: int = 8000
   var launch_python: bool = true
   ```

2. In `_ready()`, read from settings:
   ```gdscript
   udp_port      = settings.get("udp_port", 8000)
   launch_python = settings.get("launch_python", true)
   ```

3. In `_init_udp()`:
   ```gdscript
   udp.connect_to_host("127.0.0.1", udp_port)   # was hardcoded 8000
   if launch_python:
       thread_python.start(...)                   # now conditional
   ```

4. In `_process()` watchdog:
   ```gdscript
   if stream_type == "udp" and launch_python and not thread_python.is_alive() ...
   ```

---

## Session 2 problems found and fixed (2026-05-27)

### Problem 5 — Pi was on wrong branch
Pi's repo was on branch `transfering-logic`, not `main`. When Windows pushed fixes to `main`, the Pi couldn't see them.
**Fix:** `git checkout main` on the Pi.

### Problem 6 — Pi's remote pointed to Sujith's original repo
Pi's `origin` was set to `SujithChristopher/NOARKGames`, not the user's fork `bkdiwakar34/NOARKGames`. So `git pull` fetched from the wrong place.
**Fix:** `git remote set-url origin https://github.com/bkdiwakar34/NOARKGames.git` on Pi, then `git pull`.

### Problem 7 — tracker.py and udp_streamer.py missing from main branch
Both files existed only on the `transfering-logic` branch. Switching to `main` removed them from disk.
**Fix:** `git checkout transfering-logic -- pyscripts/tracker.py` and `git checkout transfering-logic -- pyscripts/udp_streamer.py` to copy files from old branch into main without switching branches.

**Note:** These files have NOT been pushed to GitHub yet (authentication blocked the push). They are committed locally on Pi only. ← **TO DO**

### Problem 8 — tracker.py was running in BLE mode (not UDP)
The systemd service started at boot when `settings.json` still had `"stream_type": "ble"`. The process read BLE at startup, never opened a UDP socket. Running process doesn't reload settings — a restart was needed.
**Fix:** `sudo systemctl restart noark-tracker.service` after settings.json was corrected.

### Problem 9 — tracker.py exits cleanly when Godot restarts
tracker.py has a 3-second heartbeat timeout. When Godot is closed/restarted, heartbeats stop → tracker exits with code 0 (clean). Systemd's default `Restart=on-failure` does NOT restart on clean exit.
**Result:** Every time Godot restarts, tracker.py must be manually restarted.
**Fix needed:** Change systemd service to `Restart=always`. ← **TO DO**
**Workaround:** `sudo systemctl restart noark-tracker.service` after each Godot restart.

### Problem 10 — debug.json had debug:true, sheep followed mouse not device
`debug.json` had `{"debug": true}`. The Random Reach game reads this and replaces device position with mouse cursor position. Sheep appeared to only move left/right because mouse is 2D on screen.
**Fix:** Changed to `{"debug": false}`.

### Problem 11 — App flow: Enter key, not Play button, goes to game selection
The Play button on the main screen goes to the patient **registry** (detail view), not game selection. To reach game selection: type hospital ID → press **Enter** on keyboard.
Also: patients must be registered first. The registry screen is the registration UI.

### Problem 12 — 2D mode wrong for front-mounted camera
The game's 2D mode maps: camera X → screen X, camera Z (depth) → screen Y.
With the camera **in front** of the patient, depth (Z) is always large (0.3–1m). At scaler 2000: net_z = 600–2000px, always exceeds screen max (600px), always clamped to bottom edge.
**Result:** Sheep stuck at bottom of screen, only moves left/right.
**Fix:** Use **3D mode** instead. 3D mode maps: camera X → screen X, camera Y (up/down in camera view) → screen Y. This is the correct mapping for a front-facing camera where the patient moves their arm left/right and up/down.

---

## Current status (as of 2026-05-28 15:05)

- [x] Godot 4.5 ARM64 runs on Pi
- [x] tracker.py running as systemd service (`noark-tracker.service`)
- [x] All original 4 bugs fixed and pushed to GitHub (`main` branch)
- [x] Pi synced to correct remote (`bkdiwakar34/NOARKGames.git`) and `main` branch
- [x] tracker.py and udp_streamer.py restored to Pi filesystem
- [x] End-to-end pipeline verified: tracker sends 30 pkt/s, Godot receives, game responds
- [x] debug.json set to false — device controls game, not mouse
- [x] Patient registration flow understood: Enter key → game selection
- [x] Systemd service set to `Restart=always` and `RestartSec=3` — tracker auto-restarts when Godot closes
- [x] 2D mode Z mapping fixed — sheep now moves in both X and Z directions
- [ ] tracker.py and udp_streamer.py not yet pushed to GitHub (need GitHub auth on Pi) ← **TO DO**
- [ ] Z mapping is hardcoded (quick fix) — needs systematic workspace calibration ← **TO DO**

---

## Session 4 — Z mapping fix (2026-05-28)

### Problem 13 — Sheep stuck at bottom in 2D mode (Z axis)
The 2D mode maps: camera Z (depth) → screen Y. Formula in `global_script.gd` line 466:
```gdscript
net_z = my_floats[3] * PLAYER_POS_SCALER_Z + Y_SCREEN_OFFSET
```
With `PLAYER_POS_SCALER_Z = 2000` and `Y_SCREEN_OFFSET = screen_height/4 = 270`:
- At Z = 0.2m (closest): `0.2 × 2000 + 270 = 670px` → exceeds MAX_BOUNDS.y (600) → clamped to bottom
- At Z = 0.6m (farthest): `0.6 × 2000 + 270 = 1470px` → way off screen

**Measured workspace (tabletop setup, camera in front):**
- X: -0.2m to +0.2m (arm left/right)
- Z: 0.2m to 0.6m (arm forward/backward on table)
- Screen resolution: 1920×1080
- Player bounds: MIN_BOUNDS = Vector2(44, 40), MAX_BOUNDS = Vector2(1105, 600)

**Quick fix applied** (hardcoded values for now):
```gdscript
net_z = (my_floats[3] - 0.2) * 1400 + 40
```
Maps Z range 0.2–0.6m → screen Y range 40–600px. Sheep now moves in both directions.

**Known limitation:** The 0.2m and 1400 values are hardcoded from the measured workspace. If camera position or patient position changes, this breaks. Needs systematic workspace calibration (see Next steps).

### Debugging approach used
1. Added `print(f"x={centroid[0]:.3f} y={centroid[1]:.3f} z={centroid[2]:.3f}")` in tracker.py after centroid computation — confirmed Z range 0.2–0.6m
2. Added `print("net_x: ", net_x, "  net_z: ", net_z)` in `_apply_position_packet()` in global_script.gd — confirmed net_z ≈ 925 (off screen)
3. Added `print("is_3d: ", is_3d_mode, "  net_pos: ", GlobalScript.network_position)` in player.gd `_update_player_position()` — confirmed 2D mode, confirmed Y=925 always clamped to 600

---

## Next steps

1. **Push missing files to GitHub** — tracker.py and udp_streamer.py need to go from Pi → GitHub so they're safe:
   - Set up GitHub personal access token on Pi, OR
   - Copy file contents and push from Windows machine

2. **Systematic workspace calibration** — replace hardcoded Z values with a proper mapping:
   - Expose `x_min`, `x_max`, `z_min`, `z_max` in `settings.json`
   - Formula: `screen_x = (raw_x - x_min) / (x_max - x_min) × screen_width`
   - Formula: `screen_z = (raw_z - z_min) / (z_max - z_min) × screen_height`
   - Long-term: build a calibration screen in Godot where patient moves through full range

3. **Remove debug prints** — remove the temporary print statements added in tracker.py, global_script.gd, and player.gd

---

## How to run the system

1. `tracker.py` starts automatically on boot (systemd service) — auto-restarts if Godot closes
2. Open terminal on Pi's desktop
3. Run Godot:
   ```bash
   /home/sujith/Downloads/Godot_v4.5-stable_linux.arm64
   ```
4. Open project at `/home/sujith/Documents/NOARKGames/project.godot`
5. Type hospital ID → press **Enter** (not Play button) → select game → select **2D mode** → play
6. Tracker restarts automatically — no manual restart needed

---

## Concepts glossary

**`ss -unp`** — Lists open UDP sockets with process names. Useful for debugging which program is on which port.

**`ps aux | grep X`** — Lists all running processes, filtered for X. Checks if a process is alive.

**`systemctl list-units --type=service`** — Lists all systemd services and their status.

**`sed -i 's|old|new|g' file`** — Find-and-replace directly in a file. `-i` = in-place. `s|old|new|g` = substitute old with new, globally.

**`chmod +x file`** — Makes a file executable on Linux.

**`2>/dev/null`** — Discards error output. Hides crash messages (bad for debugging).

**`tee file`** — Writes output to both terminal and file simultaneously.

**`git stash`** — Temporarily saves uncommitted changes. `git stash drop` discards them.

**`git checkout <branch> -- <file>`** — Copies one specific file from another branch into your current branch, without switching branches. Like borrowing one page from a different binder.

**`git remote set-url origin <url>`** — Changes which GitHub repo the local repo points to for push/pull. Needed when a fork is pointed at the wrong upstream.

**`journalctl -u <service> -n 30`** — Shows the last 30 log lines from a systemd service. Use this to see crash messages, print output, and errors from tracker.py.

**`Restart=always` vs `Restart=on-failure`** — systemd restart policies. `on-failure` only restarts when a process crashes (non-zero exit code). `always` restarts even on clean exits (code 0). tracker.py exits cleanly on heartbeat timeout, so `on-failure` does not restart it.

**Camera axis convention** — Camera X = horizontal. Camera Y = vertical (positive downward in image). Camera Z = depth (distance from camera). Which physical motion maps to which axis depends on camera orientation. Front camera: arm left/right → X, arm up/down → Y, arm toward/away → Z. Use 3D mode (X + Y) with front camera; 2D mode (X + Z depth) was designed for overhead camera.

---

## Session 3 — Codebase understanding (2026-05-28)

### File map
Full file map established. Key categories:
- **Core autoloads:** `global_script.gd`, `global_signals.gd`, `patient_db.gd`, `manager.gd`, `debug_settings.gd`
- **Screens:** `main_window.gd`, `registry.gd`, `select_game.gd`, `3d_games.gd`
- **Games:** random_reach, flappy_bird, fruit_catcher, ping_pong, Jumpify, assessment
- **Addons:** `easy_charts` (used by Results screen), `gdble` + `GdAndroidBLE` (BLE — inactive when stream_type=udp)
- **Python:** `main.py` (old tracker — do not use), `tracker.py` (production, Pi only), `filters.py`, `udp_streamer.py` (Pi only)
- **Safe to delete:** `android/tablet-crash-log.txt`, `android/tablet-logcat.txt`, `android/*.idsig`, `test_android_adb.ps1`, `pyscripts/main.py`

### Python pipeline understood
Full pipeline: camera frame → ArUco detection → solvePnP → centroid with offsets → EMA filter → UDP send

**ArUco markers** — printed square patterns with unique IDs. Camera detects their 4 corners in 2D pixels.

**solvePnP** — given 4 real-world 3D corner positions (known from marker size) + 4 image pixel positions + camera calibration → outputs (x,y,z) position and rotation of marker in 3D space.

**MARKER_OFFSETS** — each marker's known physical position relative to device centre. Allows computing device centre position regardless of which marker is currently visible. Handles the problem of different markers appearing as patient rotates wrist.

**Centroid** — averages device-centre estimates from all visible markers for stability.

**EMA filter** — alpha=0.4. Smooths jitter without excessive lag. Formula: `smoothed = 0.4 * new + 0.6 * previous`.

### Camera calibration understood
- Done once by pointing camera at checkerboard
- Produces: camera matrix (focal length + optical centre) + distortion coefficients
- `good.toml` reprojection error: **0.618px** — genuinely valid (under 1.0px is good)
- Fisheye undistortion: `cv2.remap()` warps entire frame before marker detection runs
- Recalibrate only if: camera changes, lens changes, or resolution changes

### Improvements identified
Tracked in `IMPROVEMENTS.md` at project root:
1. Switch `CORNER_REFINE_CONTOUR` → `CORNER_REFINE_SUBPIX` (`main.py` line 99)
2. Fix resolution mismatch — calibration 1280×800, tracker runs at 1200×800
3. Formal marker size justification needed for clinical paper (formula: `projected_px = focal_length × size / distance`)
4. Kalman filter as future candidate to replace EMA

### Learning path established
Python side first (user knows Python, new to Godot):
1. `filters.py` ← next
2. `_get_centroid()` in `main.py`
3. `_send_coordinates()` in `main.py`
4. Then Godot side: `debug_settings.gd` → `patient_db.gd` → `main_window.gd` → `global_signals.gd` → `global_script.gd` → `player.gd`
