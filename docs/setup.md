# NOARKGames — Setup

How to set up the hardware and run the system on the Radxa Dragon Q6A. For what the system does and how it works, see [design.md](design.md).

---

## Hardware

| Component | Detail |
|---|---|
| Computer | Radxa Dragon Q6A (QCS6490, Linux ARM64), booting from SSD — see the UFS note in §3c |
| Camera | Two OV9281 monochrome fisheye cameras (160° FOV), via the `rcam` package |
| Input device | NOARK device with ArUco markers (IDs 12, 14, 20 active) |
| Display | 1920×1080 HDMI monitor, set to 100 Hz (§6) |
| Repo on board | `/home/radxa/Documents/NOARKGames/` |
| Godot binary | `/home/radxa/Downloads/Godot_v4.5-stable_linux.arm64` |

The Raspberry Pi 5 version of this system lives in its own repository,
[NOARKGames-pi](https://github.com/bkdiwakar34/NOARKGames-pi) — this repo is the
Dragon Q6A one only. `pyscripts/main.py` takes its frames from `rcam` and refuses
any other `camera_backend`; the Pi's picamera2 path is gone from this repo.

---

## First-time setup on a fresh Dragon Q6A

### 1. Install Godot

Download the ARM64 Linux Godot binary and place it at the path above. The project targets Godot 4.5.

### 2. System packages and Python

RadxaOS ships Python 3.12; `rcam` needs **3.13+**. Do not replace the system
Python - install 3.13 alongside it with `uv`.

```bash
sudo apt update
sudo apt install -y git curl build-essential clang libclang-dev                     linux-headers-$(uname -r) device-tree-compiler v4l-utils
```

| Package | Needed for |
|---|---|
| `build-essential`, `clang`, `libclang-dev` | `rcam`'s Rust extension (bindgen reads the kernel's C headers through libclang) |
| `linux-headers-$(uname -r)` | building the out-of-tree `ov9282` sensor driver |
| `device-tree-compiler` | `dtc` / `fdtoverlay`, used when checking or merging the camera overlay |
| `v4l-utils` | `media-ctl`, which `rcam` shells out to; without it `list_cameras()` raises |

Then Python and the project venv:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env
uv python install 3.13
cd ~/Documents/NOARKGames
uv venv --python 3.13 .venv
source .venv/bin/activate
uv pip install -e .          # tracker deps (opencv <5, scipy, toml)
uv pip install -e ./rcam     # camera package, INTO THE SAME venv
```

`uv pip`, not bare `pip`: a uv-created venv has no pip, and a bare `pip install`
would hit the system Python instead.

`uv pip install -e ./rcam` (not `cd rcam && uv sync`): `main.py` imports `rcam`
into its own process, so both must live in **one** venv. `uv sync` inside
`rcam/` builds a second, separate venv that the tracker cannot import from.

Dependencies declared in `pyproject.toml`; `uv.lock` pins exact versions.

### 3. Calibrate the camera (one-time per camera)

Print or display a 9×6 chessboard (square side **24.35 mm**, measured). Then:

```bash
python pyscripts/calibration/calibrate_camera.py --backend rcam --cam-id CAM2
```

The script auto-captures frames when the board is held steady, runs `cv2.fisheye.calibrate`, and writes `pyscripts/camera_calib.toml`. Multi-pose verification at the end reports accuracy (mm), precision (mm), and reprojection fit (px) per pose. A typical good calibration has reprojection error < 1 px.

Recalibrate only if camera changes, lens changes, or resolution changes.

### 3b. Calibrate the board geometry (one-time per device)

Measures each marker's fixed 3D pose on the device so the tracker can run one
joint rigid-body solvePnP over all visible markers (much less depth jitter
than per-marker averaging).

```bash
python pyscripts/calibration/calibrate_board.py --backend rcam --cam-id CAM2
```

Slowly rotate the device in front of the camera so every adjacent marker pair
is seen together (the back marker links through the side views). When each
pair counter shows ≥ 30 samples, press **S** to write
`pyscripts/board_geometry.json`. The grip-point consistency report at the end
flags any marker whose `MARKER_OFFSETS` entry disagrees by > 5 mm.

`main.py` uses the joint solve automatically when the file exists; without it,
it falls back to the old per-marker method. Redo only if a marker is re-glued.
Disable via `"use_board_pnp": false` in settings.json.

### 3c. Cameras: driver + device-tree overlay

Two OV9281 on `CAM2` (cam0) and `CAM3` (cam1). Neither the sensor driver nor the
board's description of the cameras is in the stock image, so both are built and
installed once per fresh OS.

**Connect the cameras with the board powered off.** Which camera goes in which
port matters: `stereo_extrinsics.json` encodes the cam1 -> cam0 transform, so
swapping the ports invalidates it.

#### Build and install the sensor driver

```bash
cd ~/Documents/NOARKGames/rcam/ov9281
make -C module
sudo install -D -m0644 module/ov9282.ko /lib/modules/$(uname -r)/updates/ov9282.ko
sudo depmod -a
sudo modprobe ov9282
lsmod | grep ov9282      # loaded, 0 users until the overlay lands
echo ov9282 | sudo tee /etc/modules-load.d/ov9282.conf   # load it at every boot
```

`ov9282` is the mainline driver that covers the OV9281; RadxaOS ships without it
enabled. The source in `module/` is unmodified mainline (6.18 series), so it
builds against a 6.18.x kernel as-is.

#### Enable the camera overlay (RadxaOS r2 images - `rsetup`)

```bash
sudo cp overlay/qcs6490-radxa-dragon-q6a-dual-ov9281.dtbo /boot/dtbo/
sudo rsetup      # Overlays -> Yes -> Manage overlays -> tick
                 # "Enable two Waveshare OV9281 cameras (CAM2 + CAM3)"
                 # -> Ok -> Rebuild overlays -> exit
sudo reboot
```

Copying the file alone is **not** enough - the firmware only picks up overlays
after `rsetup`'s *Rebuild overlays* step. Navigation: arrows move, space toggles,
Tab reaches `<Ok>`, Esc goes back.

> **`scripts/deploy_efi_dtb.sh` does not work on r2 images.** It merges into
> `/boot/efi/RadxaOS/<ver>/qcs6490-radxa-dragon-q6a.dtb`, which does not exist
> here: the loader entry carries no `devicetree` line and the firmware supplies
> its own tree. The script and `rcam/ov9281/README.md`'s TL;DR describe the older
> image. Use `rsetup`.

To sanity-check an overlay before rebooting, merge it against the *running*
firmware tree - this fails loudly if it would not apply:

```bash
sudo cp /sys/firmware/fdt /tmp/base.dtb && sudo chmod 644 /tmp/base.dtb
fdtoverlay -i /tmp/base.dtb -o /tmp/merged.dtb     overlay/qcs6490-radxa-dragon-q6a-dual-ov9281.dtbo
dtc -I dtb -O dts /tmp/merged.dtb 2>/dev/null | grep -c 'ovti,ov9281'   # expect 2
```

#### Verify, in this order

```bash
ls /dev/media*                                            # /dev/media0 exists
media-ctl -d /dev/media0 -p | grep ov9281                 # two sensors
cd ~/Documents/NOARKGames && source .venv/bin/activate
python -c "from rcam import list_cameras; print(list_cameras())"   # ['CAM2','CAM3']
python rcam/main.py                                       # writes cam2.png, cam3.png
```

Each step localises a different failure:

| Symptom | Meaning |
|---|---|
| no `/dev/media*` | overlay not applied - `rsetup` rebuild missing, or it did not boot |
| `/dev/video0,1` only | those are the Venus encoder, not cameras - same cause as above |
| `media-ctl not found` | `v4l-utils` missing |
| `list_cameras()` returns `[]` | pipeline up, sensor silent - check the ribbon orientation |

The `/etc/modules-load.d/ov9282.conf` line above loads the driver at every boot
(verified 2026-09-22: after a reboot `lsmod | grep ov9282` shows it without any
command). Without it, `sudo modprobe ov9282` is needed after each boot, and Godot
started before it finds no cameras.

#### Calibration and settings

1. `pyscripts/calibration/calibrate_camera.py` once per camera - default
   `camera_calib.toml` for cam0 (`CAM2`), then
   `--cam-id CAM3 --output camera_calib_1.toml` for cam1.
2. `pyscripts/calibration/calibrate_board.py` (one board, either camera) if
   `board_geometry.json` does not exist yet.
3. `python pyscripts/calibration/calibrate_stereo.py` - the fixed rigid transform between the
   two cameras, from both tracking the same board simultaneously (no separate
   checkerboard). Move the device until the sample counter passes 60, press **S**
   to save `pyscripts/stereo_extrinsics.json`.

   **Ruler check** — print where cam1 sits relative to cam0 and compare it with the
   mount (lens centre to lens centre):

   ```bash
   cd ~/Documents/NOARKGames && source .venv/bin/activate
   python -c "import json,numpy as np; d=json.load(open('pyscripts/stereo_extrinsics.json')); t=np.array(d['tx']).flatten()*1000; R=np.array(d['Rx']); print('x, y, z (mm):', t.round(1)); print('distance (mm):', round(float(np.linalg.norm(t)),1)); print('turn (deg):', round(float(np.degrees(np.arccos(np.clip((np.trace(R)-1)/2,-1,1)))),1))"
   ```

   $x$ = right, $y$ = down, $z$ = forward, all in cam0's view; distance
   $= \sqrt{x^2 + y^2 + z^2}$; turn $= \arccos\big((\operatorname{tr} R_x - 1)/2\big)$.
   For the side-by-side mount expect nearly all the distance in $x$, and the
   distance to match the ruler within a few mm (2026-09-19: 75.0 mm, 1.6°). This
   catches a badly wrong calibration, not a 1 mm error.
4. `settings.json` already sets `"camera_backend": "rcam_dual"` in this repo.

`camera_calib_1.toml`, `board_geometry.json` and `stereo_extrinsics.json` are
git-ignored (per-device) - **back them up off the board**, or a reinstall costs a
full recalibration.

If one camera loses its feed mid-session (occlusion, disconnect), the tracker
falls back to the surviving camera rather than stopping.

#### Known hardware issue: onboard UFS storage freezes (run from an SSD)

**Symptom.** About 10–15 s into a session the tracker exits with
`No UDP packets from Godot for 3s`. It looks like a tracker bug, but it is not.

**Cause.** The Q6A's onboard UFS storage module (KIOXIA `THGJFGT1E45BAILB`) periodically
locks up, which stalls every process that touches the disk — Godot included. Confirmed
2026-07 by running Godot alone with `pyscripts/` renamed away: the stall still happened.
`dmesg` shows:

```
ufshcd-qcom 1d84000.ufshc: ufshcd_err_handler ... task management cmd timed-out
```

and, in one occurrence at the same moment, `msm_dpu: hangcheck detected gpu lockup rb 0!`.

**Fix (2026-07-11).** Remove the onboard UFS module and boot/run from an SSD. No kernel or
firmware change was needed. Tried first, did **not** help: pinning tracker and Godot to
separate cores (`tracker_cpu_affinity` in settings.json, `taskset -c 0-3` for Godot),
capping GPU frequency (`/sys/class/devfreq/3d00000.gpu/max_freq`), disabling the tracker's
preview window.

**Check on a new board:** `dmesg | grep -i ufshc` after a few minutes of running the game.
Any `err_handler` / `timed-out` line means the same fault.

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
    "pnp_method": "square",
    "framerate": 100
}
```

`debug: true` enables a 350×200 OpenCV preview window in the tracker and skips authentication in Godot (sets patient ID to `vvv`). Leave `false` for headless / production.

### 6. Set the monitor to 100 Hz

A fresh install drives the monitor at 60 Hz even when it can do more. Godot draws
once per monitor refresh (vsync on, no FPS cap in `project.godot`), so the screen
follows this setting.

GNOME (RadxaOS): `gnome-control-center display` → **Refresh Rate** → **100 Hz** → Apply.
(`xrandr` cannot be used to check it: under Wayland it lists only the current mode.)

**Check:** Game select → gear → **Trace test** shows `fps: 100` and `rx: 100 pkt/s`.

What it changes: the cursor updates 100 times a second instead of 60, and game
event times (`outcome_time`) are precise to $1/100$ s $= 10$ ms instead of
$1/60$ s $\approx 16.7$ ms. What it does **not** change: the sampling rate. Every
tracker sample is saved at any screen rate, because each screen frame writes all
samples that arrived since the last one ($100/60 \approx 1.67$ per frame at 60 Hz).

---

## Running the system

Normal use — start Godot on the four slow cores; it launches the tracker itself,
pinned to the four fast ones:

```bash
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

The Q6A's cores are not equal: cpu0–3 are Cortex-A55 at 1958 MHz, cpu4–6
Cortex-A78 at 2400 MHz, cpu7 an A78 at 2707 MHz (read from
`/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq`). The tracker is the
time-critical process, so `"tracker_cpu_affinity": "4-7"` in settings.json makes
Godot start it with `taskset -c 4-7`; `taskset -c 0-3` on Godot keeps the game
off those cores.

To run manually for debugging:

```bash
# Terminal 1 — tracker
cd ~/Documents/NOARKGames
source .venv/bin/activate
python pyscripts/main.py

# Terminal 2 — game
~/Downloads/Godot_v4.5-stable_linux.arm64 --path . --main-scene res://app/ui/main.tscn
```

Or open `project.godot` in the Godot editor and press F5.

### Main scene

`res://app/ui/main.tscn`. Display: fullscreen, `canvas_items` stretch mode, OpenGL compatibility renderer.
### Game flow

1. Main screen — type hospital ID → press **Enter** (not Play button) → enters game selection.
2. Game select screen — pick "Apple Catch", set session parameters from the gear menu, press play.
3. Game starts. Phase 0a (workspace scan) runs first, then Phase 0c (Fitts calibration), then the session.

---

## Auto-start on boot (not yet implemented)

The tracker is currently launched by Godot's autoload. A systemd-service-based auto-start of Godot itself on boot is planned but not built. See [todo.md](todo.md).

---

## Useful Linux commands for debugging

| Command | Purpose |
|---|---|
| `ss -unp` | List open UDP sockets with process names |
| `ps aux \| grep python` | Check whether tracker is alive |
| `journalctl -u <service> -n 30` | Last 30 log lines from a systemd service |
| `tail -f /tmp/tracker_timing.log` | Watch per-stage tracker timing in real time (debug mode only) |
| `ssh radxa@<board-ip>` | Remote shell into the Q6A over the same WiFi |
| `dmesg \| grep -i ufshc` | Check for the UFS storage fault (see §3c) — no output is good |

---

## Common issues

**Tracker prints `"settings.json not found"`** — settings file is missing or the working directory is wrong. The tracker looks for `settings.json` one level above `pyscripts/`.

**Cursor doesn't move** — check `UDPReceiver.connected` in the debug overlay. If `false`, the tracker isn't reaching the receiver. Confirm both are using port `12345` (set by `udp_port` in settings.json).

**Cursor moves but in the wrong direction** — likely the sensor-to-screen calibration was done in the wrong corner order. Redo the 4-corner calibration (TL → TR → BL → BR).

**`solvePnP` returns wildly inconsistent poses** — usually means the calibration file doesn't match the camera. Re-run `calibrate_camera.py`.

**Cursor jumps when a marker enters or leaves view** — `MARKER_OFFSETS` for that marker are wrong. The values must be expressed in the marker's own local frame; see [design.md §8](design.md).

**Per-stage timing print spam** — `debug` is enabled in `settings.json`. Set to `false` for normal operation.
