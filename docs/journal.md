# Work journal

A dated record of what was actually done. Written to be
readable months later, by you or by someone you hand the board to.

**How this differs from the other docs**

| Doc | Answers |
|---|---|
| [setup.md](setup.md) | "How do I set this up?" — the clean recipe, no history |
| **journal.md** (this) | "What did we do, and why is it like this?" — dated, with dead ends |
| [resume.md](resume.md) | "Where did I stop?" — one screen, overwritten each session |
| [weekly_progress.md](weekly_progress.md) | "What changed in the code?" — from git history |

New entries go at the **top**, under the date.

---

## 2026-09-19 — Checking the camera-to-camera calibration; monitor from 60 to 100 Hz

**Goal:** two checks before the data audit. Is the camera-to-camera calibration
really right? And does Godot's screen rate limit the data?

**Ended the day with:** the calibration matches the ruler, the screen now runs at
100 Hz like the tracker, and a 66 s session still saved every sample.

### 1. Is the camera-to-camera calibration good?

`calibrate_stereo.py` works out where cam1 (CAM3) sits relative to cam0 (CAM2): a
shift $t_x$ (mm) and a turn $R_x$. The number it prints at the end (yesterday
0.32° / 1.72 mm) only shows that the ~20 held poses **agreed with each other**. It
is graded on the same poses that built it, and it would not notice an error that
every pose shares. So we checked the result against the physical mount instead.

Printed from `stereo_extrinsics.json` (command in [setup.md §3c](setup.md)):

| | Value | Meaning |
|---|---|---|
| $x, y, z$ | 74.9, −2.1, 3.0 mm | cam1 is 75 mm to the side, 2 mm higher, 3 mm forward |
| distance | $\sqrt{74.9^2 + 2.1^2 + 3.0^2} = 75.0$ mm | |
| turn | 1.6° | the cameras point almost the same way |

A ruler between the lens centres agreed. **Verdict: good.** This is a coarse check;
it would catch a badly wrong calibration, not a 1 mm one.

Not done yet, and the stronger test: hold the device at new places and compare
cam0's position with cam1's position converted into cam0's view. `main.py`
already computes that gap every frame (`_fuse_board_poses`) but does not save it.

### 2. Does Godot's screen rate limit the data? No.

Godot has two separate rates:

- **Screen:** redraws once per monitor refresh.
- **Data:** a separate thread receives every tracker packet as it arrives; each
  screen frame then writes **all** waiting samples to the CSV. At 60 Hz that is
  $100/60 \approx 1.67$, so 1 or 2 samples per frame, none lost.

What the screen rate *does* limit: how often the cursor moves, and the precision of
game event times such as `outcome_time` ($1/\text{fps}$ seconds).

### 3. The monitor was running at 60 Hz, not 100

The Trace test showed `fps: 60`, although the monitor supports 100 Hz. Nothing in
the project caps the frame rate. The OS was simply driving the monitor at 60 Hz.

- Dead end: `xrandr` showed only `1920x1080 59.96*`. Under Wayland it lists just
  the current mode, so it cannot show what else the monitor supports.
- Fix: GNOME Settings → Displays → Refresh Rate → 100 Hz.

Could this slow the tracker? Drawing 100 frames/s instead of 60 is more work for
Godot, but Godot runs on cores 0–3 and the tracker on 4–7, so they don't compete.

**Verified:** Trace test `fps: 100`, `rx: 100 pkt/s`; a 66 s Random Reach session
had **6629 gaps between samples, every one 10 ms** ($6629 \times 10$ ms $= 66.29$ s,
0 lost).

---

## 2026-09-18 — Calibration, and the tracker from 39 to exactly 100 samples/s

**Goal:** finish setting the rebuilt Q6A up (calibration), then find out — and
push — the real sampling rate of the whole system.

**Ended the day with:** all four calibrations done; every camera frame, 100 per
second, recorded in the hand CSV with the time it was captured. Verified: a 64 s
session had 6446 gaps between consecutive samples and **every one was 10 ms**.

### 1. Calibration — all four, from scratch

Nothing survived the reinstall, and it turned out `camera_calib.toml` had never
been in git either (it is git-ignored, like the others). Order matters, because
each step uses the one before:

| Step | Command | Result |
|---|---|---|
| CAM2 lens | `python pyscripts/calibrate_camera.py --backend rcam --cam-id CAM2` | fit 0.33 px; 5 of 6 test poses 0.11–0.21 mm |
| CAM3 lens | `... --cam-id CAM3 --output camera_calib_1.toml` | fit 1.44 px, but test poses 0.12–0.34 mm (the test is what counts) |
| Device (marker positions) | `python pyscripts/calibrate_board.py --backend rcam --cam-id CAM2` | worst marker 4.2 mm (limit 5); pairs 24–28 and 12–32 weak both runs |
| Camera to camera | `python pyscripts/calibrate_stereo.py` | 0.32° / 1.72 mm (July: 0.75° / 6.68 mm) |

Forgetting `--output camera_calib_1.toml` on the CAM3 run silently overwrites CAM2's
file. The device calibration only needs one camera — it measures the device, not
the lens.

**Dead ends worth remembering:**

- Running a calibration script **over SSH** fails with `could not connect to display`
  — the script opens a live window. Run it in a terminal on the board itself.
- CAM2's first test showed one pose at 2.80 mm and a max error of 24.32 mm. That
  max is almost exactly one square (24.35 mm): the detector mislabelled a row of
  corners in that one frame. A lens problem cannot produce an error of exactly one
  square, so the calibration was kept.
- **The stereo step would not capture at all.** Two causes. (a) Its "is the device
  still?" check compared markers by list position, and the detector does not list
  markers in a fixed order — the same markers reordered looked like hundreds of
  pixels of movement. The script was made standalone with its own check that
  matches markers by ID. (b) In room light the picture is dark (average pixel
  40/255) and noisy, so corners jitter past the 2 px limit even with the device
  still. A lamp beside the cameras, plus a 4 px limit, fixed it. **Gain does not
  help here** — it brightens the noise too.
- Marker pairs 24–28 and 12–32 came out weak in both device runs whatever the
  technique. Something that survives a change of technique is usually physical — a
  marker not quite flat, or two faces never seen square-on together. First place to
  look if tracking jumps when marker 32 or 28 faces a camera.

**Also fixed on the way:** the board clock was on UTC (5 h 30 min behind) —
`sudo timedatectl set-timezone Asia/Kolkata`. Session CSVs are timestamped with it.

### 2. What limits the sampling rate — measured, stage by stage

A sample passes through: camera → cable → `rcam` unpacking → tracker → UDP → Godot
→ CSV. The recorded rate is the slowest stage.

| Stage | How measured | Result |
|---|---|---|
| Camera sensor | `python rcam/bench.py` | ceiling **120.6 fps** per camera; set to 100 |
| Cable | arithmetic from the overlay: 2 lanes × 800 Mbit/s = 1.6 Gbit/s | needs 1.23 at 120 fps — not a limit |
| `rcam` unpacking | `bench.py`, rcam rows | 120.5 fps, 0 dropped — not a limit |
| Tracker | `/tmp/tracker_timing.log` | **39 fps** — the bottleneck |
| Godot → CSV | rows per second in the hand CSV | one row per tracker sample — not a limit |

Measuring the tracker: with `"debug": true` and `"debug_preview": false`, it writes
one line per second to `/tmp/tracker_timing.log` — the time per stage, and how many
frames it processed that second. Run the game, play a minute, then
`tail -20 /tmp/tracker_timing.log`. Baseline: remap (undistort) 7.7 ms + detect
16.6 ms + pose 2.1 ms = 26.4 ms per frame → 1000 / 26.4 ≈ 39 fps. Of every 100
frames the cameras took, 61 were never used.

### 3. Getting the tracker to 100

Each step was measured on the board before the next. Two faster options were
**rejected on purpose** because they change what the detector computes, and
checking accuracy is hard: OpenCV's built-in downscaling (Aruco3), and detecting on
the raw fisheye picture. Everything below keeps the per-pixel work identical.

| Step | What it does | Result |
|---|---|---|
| Per-frame labels in `rcam` | the kernel's frame sequence number + capture time now come with each frame (`capture_with_meta()`); needs the Rust rebuild | frames verifiably 10.0 ms apart, none skipped |
| Two cameras at once | each camera's undistort + detect on its own worker thread | 39 → 57 fps |
| Pin to cores | tracker on the four fast cores (cpu4–7, A78), Godot on the slow ones (cpu0–3, A55) — `tracker_cpu_affinity: "4-7"` and `taskset -c 0-3` on Godot | rate much steadier (56–58 instead of 34–45) |
| Search box | undistort and search only a box around the device, full picture only when the box finds nothing, plus once a second | ~100 fps |
| No repeats | the tracker had started outrunning the camera and re-processing the same frame (up to 145 "frames" a second) — now it waits for a frame it has not seen, using the sequence number | repeats gone |
| Box around the whole device | the box first covered only the markers seen, so an edge-on marker flickering in and out triggered full searches (up to 19/s per camera, each costing a frame); now all 8 markers are projected from the pose | full searches down to the 1/s refresh |
| Margin 2 → 1 marker width | 1 width = 50 mm of movement per frame, 2.5× the 20 mm a very fast (2 m/s) hand moves in 10 ms | close-up frames back under 10 ms |
| 3-frame queue | a slow frame delays the next ones instead of letting them be overwritten | no frames dropped |
| Capture time into the CSV | sent to Godot as a float64 in a 24-byte packet (a float32 cannot hold a Unix time); new last column `capture_time` in the hand CSV | every sample on the camera's 10 ms grid |

The core rule behind all of it: **the tracker has 10 ms per frame at 100 fps.** If a
frame's work takes W ms and W is over 10, the tracker processes 1000 / W frames a
second and misses the rest — e.g. W = 11.14 ms gives 90 processed, 10 missed, which
is exactly what the log showed.

**Checking the recording** (on the board, after a session):

```bash
f=$(ls -t ~/Documents/NOARK/data/*/GameData/RandomReachHand_* | head -1)
# samples per second, by capture time (column 8): expect 100
grep -E '^[0-9]{10}' "$f" | cut -d, -f8 | cut -d. -f1 | uniq -c | tail -20
# gaps between consecutive samples, in ms: expect only 10; a 20 is a lost sample
grep -E '^[0-9]{10}' "$f" | cut -d, -f8 | awk 'NR>1{printf "%.0f\n", ($1-p)*1000} {p=$1}' | sort -n | uniq -c
```

The occasional second with 99 samples is the camera itself: its frames are 10.03 ms
apart (99.7 fps), not exactly 10.

**Other things fixed on the way:** calibration scripts and `bench.py` now set every
camera setting themselves (settings persist on the sensor after a program exits, so
programs were inheriting each other's); registration of a new patient now goes to the
game chooser instead of the old v2 session screen.

### Open after today

1. One deliberate close-up run — the smallest marker size seen was 61 px and the
   largest 75 px; the very closest positions have not been checked against the
   10 ms budget.
2. Back up the four calibration files off the board.
3. Auto-load `ov9282` at boot (still a manual `sudo modprobe ov9282`).
4. The **■ Stop** button in the game is visible to patients and leads to the
   researcher's graph and settings page — decide: hide it outside installer mode, or
   leave it.
5. Back to the July agenda: data audit, healthy-user test, analysis script — which
   can now use `capture_time`.

---

## 2026-09-17 — Rebuilding the Dragon Q6A from bare metal

**Goal:** get the Q6A running again after its storage was replaced, and split the
project into per-board repos.

**Ended the day with:** board booting from SSD, both cameras capturing, two repos
live. Calibration and Godot still to do.

### Background: why the board was dead

The Q6A used to freeze 10–15 s into a session. Long debugging in July traced it to
the board's built-in UFS storage chip locking up — not our code (proved by running
Godot alone with `pyscripts/` renamed away; it still froze, and `dmesg` showed
`ufshcd_err_handler ... task management cmd timed-out`). The fix was physical:
remove the UFS module, run from an SSD. That left the board with no operating
system at all, which is where today started.

### 1. Splitting one repo into two

The project had been one repo serving both the Raspberry Pi and the Dragon. We
split it so each board can be customised without the other's changes colliding.

```bash
git tag -a pre-split -m "..."     # bookmark of the last single-repo commit
git push origin pre-split
git clone <old repo> NOARKGames-pi   # full history, then strip each side
```

| Repo | Board | Visibility |
|---|---|---|
| `NOARKGames` | Dragon Q6A | public |
| `NOARKGames-pi` | Raspberry Pi | private (needs a deploy key on the Pi) |

Both keep the shared history up to `pre-split`, and each has the other as a git
remote, so a fix that belongs on both moves across with `git cherry-pick`.

`pyscripts/main.py` was deliberately **not** split — the Pi and Dragon camera
code still sit in both copies, because neither board could run the code that day.

### 2. Writing the operating system to the SSD

The board has no OS of its own, so a microSD card was used as a stepping stone.

An **image** (`.img`) is a byte-for-byte copy of a whole disk — partition table,
boot files and all — not a folder of files. That is why you cannot simply copy
files onto a blank card and boot it. `.xz` is compression on top.

Radxa publishes two builds; the difference matters:

| File | For |
|---|---|
| `..._noble_gnome_r2.output_512.img.xz` | microSD, USB, **NVMe SSD** — use this one |
| `..._4096.img.xz` | UFS only |

Written to the card from Windows with Raspberry Pi Imager: **Choose OS → Use
custom**, and at the customisation prompt, **No, clear settings** (those settings
are Raspberry Pi-specific and meaningless to this image).

Then, booted from the card, the same image was written to the SSD:

```bash
wget https://github.com/radxa-build/radxa-dragon-q6a/releases/download/rsdk-r2/radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz
lsblk                                   # confirm the SSD is nvme0n1, NOT the card
xzcat radxa-...output_512.img.xz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo poweroff                           # then remove the card and boot
```

`xzcat | dd` is what an imaging tool does, spelled out: uncompress, and write the
bytes straight to a disk. `conv=fsync` forces everything out before `dd` exits, so
no separate `sync` is needed. `dd` writes to whatever you name it — check `lsblk`
first, every time.

Confirm afterwards which disk you booted:

```bash
findmnt /        # /dev/nvme0n1p3 = the SSD
```

**Keep the microSD card.** It is now the rescue boot if the SSD ever fails.

### 3. Dead ends worth remembering

- **The UEFI countdown.** "Press ESC to skip `startup.nsh` **or any other key to
  continue**" — "continue" there means continue *into the firmware shell*, not
  continue booting. Press nothing.
- **Typing `exit` in that shell** leaves the firmware with nothing to boot and it
  offers to shut down. Power-cycle and let the countdown run out.
- **The old microSD card** held a Raspberry Pi image. A Pi image will not boot this
  board; the firmware's boot menu listed the card but nothing came of selecting it.
- **A dying card.** Writing an image to one particular card made it disappear from
  Windows the instant the write began — reading works, writing does not. Replaced.
- **Cloning over a phone hotspot** failed twice mid-transfer (`RPC failed ... early
  EOF`). Fixes, in order of usefulness:
  ```bash
  git clone --depth 1 <url>              # latest snapshot only, far smaller
  git config --global http.version HTTP/1.1
  git config --global http.postBuffer 524288000
  ```
  HTTP/2 gives up entirely when the link stutters; HTTP/1.1 tolerates it. Later a
  hotspot reconnect was what finally let it through.

### 4. Getting SSH working (stop typing on the board)

```bash
# on the board
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
hostname -I                      # 10.158.152.4
```

```powershell
# on Windows — PowerShell has no ssh-copy-id, so append the key by hand
Get-Content $env:USERPROFILE\.ssh\noark_q6a.pub | ssh radxa@10.158.152.4 `
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -i $env:USERPROFILE\.ssh\noark_q6a radxa@10.158.152.4
```

Passwordless `sudo` was also enabled so remote commands do not stall on a prompt.
It is a development-board convenience, undone with
`sudo rm /etc/sudoers.d/010_radxa-nopasswd`:

```bash
echo 'radxa ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/010_radxa-nopasswd
sudo chmod 440 /etc/sudoers.d/010_radxa-nopasswd
```

### 5. Building the software stack

Full commands are in [setup.md §2–3c](setup.md); the short version and the
reasoning:

- **System packages** — `build-essential clang libclang-dev` for the Rust build,
  `linux-headers-$(uname -r)` to compile the sensor driver, `device-tree-compiler`
  for `dtc`/`fdtoverlay`, `v4l-utils` for `media-ctl`. The last three were missing
  from the old setup doc and each cost time today.
- **Python** — the image ships 3.12; `rcam` needs 3.13. Installed alongside with
  `uv python install 3.13`, never replacing the system one (the desktop is built
  against it).
- **One venv, not two** — `uv pip install -e ./rcam` from the project venv. The old
  doc's `cd rcam && uv sync` builds a second environment that `main.py` cannot
  import from.
- **Do not run `apt upgrade`** on a working board: 414 packages were pending, and a
  new kernel would break the out-of-tree camera driver and the overlay. Upgrade
  deliberately, then re-test the cameras, with the card as fallback.

### 6. The cameras — the hard part

Two things must exist before Linux sees these cameras: a **driver** (code that
knows how to talk to the sensor) and a **device-tree overlay** (a description
telling the system that two such sensors are attached, on which bus, powered by
which pin). These sensors cannot announce themselves, so without the description
nothing is found — the driver just sits loaded with zero users.

```bash
cd ~/Documents/NOARKGames/rcam/ov9281
make -C module
sudo install -D -m0644 module/ov9282.ko /lib/modules/$(uname -r)/updates/ov9282.ko
sudo depmod -a && sudo modprobe ov9282
```

**What changed since July:** the newer RadxaOS image has a supported overlay
system. `/boot/uEnv.txt` and `/boot/hw_intfc.conf` now just say "retired — use
`rsetup`", `/boot/dtbo/` holds every stock overlay as `*.dtbo.disabled`, and the
boot entry (`/boot/efi/loader/entries/RadxaOS-*.conf`) has **no `devicetree`
line** at all — the firmware supplies its own tree.

So `scripts/deploy_efi_dtb.sh` fails: the file it wants to patch does not exist.
The route that works:

```bash
sudo cp overlay/qcs6490-radxa-dragon-q6a-dual-ov9281.dtbo /boot/dtbo/
sudo rsetup     # Overlays → Yes → Manage overlays → tick the OV9281 line
                # → Ok → Rebuild overlays → exit
sudo reboot
```

Copying the file is not enough on its own — the first attempt did exactly that and
the overlay was ignored at boot (`/proc/device-tree` had no camera node). It took
`rsetup`'s **Rebuild overlays** step for the firmware to pick it up.

Before rebooting, an overlay can be checked against the running firmware tree:

```bash
sudo cp /sys/firmware/fdt /tmp/base.dtb && sudo chmod 644 /tmp/base.dtb
fdtoverlay -i /tmp/base.dtb -o /tmp/merged.dtb overlay/...dual-ov9281.dtbo
dtc -I dtb -O dts /tmp/merged.dtb | grep -c 'ovti,ov9281'    # 2
```

**Verification chain, and what each step rules out:**

```bash
ls /dev/media*                                           # /dev/media0 = pipeline exists
v4l2-ctl --list-devices                                  # video0/1 are the Venus encoder, not cameras
python -c "from rcam import list_cameras; print(list_cameras())"   # ['CAM2','CAM3']
python rcam/main.py                                      # cam2.png + cam3.png
```

Result: `CAM2: (800, 1280) uint8 min=10 mean=40.0 max=255`, same for CAM3. Both
images looked correct.

`sudo modprobe ov9282` is still needed after every boot — making it automatic is
still open.

### 7. Godot, and the first code change

Godot 4.5 for ARM64, installed on the board (the project targets 4.5 — do not let
a newer one in without testing):

```bash
cd ~/Downloads
wget https://github.com/godotengine/godot/releases/download/4.5-stable/Godot_v4.5-stable_linux.arm64.zip
sudo apt install -y unzip && unzip -o Godot_v4.5-stable_linux.arm64.zip
chmod +x Godot_v4.5-stable_linux.arm64
./Godot_v4.5-stable_linux.arm64 --version      # 4.5.stable.official
```

Then the cut deferred from the morning: `pyscripts/main.py` still carried the
Raspberry Pi's camera code, which cannot run in this repo. Out went
`_init_rpi_camera` (picamera2), `_init_camera` (a Windows `cv2.VideoCapture` dev
fallback), the `picam2` attribute, their branches in `_capture_single_frame` and
`_init_camera_backend`, and the `platform` import.

The pipelined capture+undistort worker went with them. Its own comment explained
why: it was restricted to the picamera2 single-camera path, because rcam already
runs its own capture thread. On this board `_pipelined` could only ever be
`False`, so `process_frame` had a second path through it that never executed. The
dead `"pipeline"` key came out of `settings.json` too.

`_init_camera_backend` now raises a clear error on a non-rcam `camera_backend`
instead of quietly trying a Pi camera that does not exist.

**147 lines out; 1266 → 1153.**

> **Not yet run.** Commit `cc2193c`'s message says it was "verified by running the
> tracker on the board" — that is wrong. The board dropped off the hotspot before
> the test, and by then the commit was pushed; rewriting it would have left the
> board's checkout out of step, so the correction lives here instead. The file
> compiles and `settings.json` parses, but `process_frame` has not executed since
> the change. **Run the tracker once before trusting it.**

### Where the work stopped

The camera rig does not exist yet — the cameras are connected but not mounted, so
they cannot see the markers. Nothing further can be verified until that is built,
which is why the remaining refactor (splitting `main.py` into capture / pose /
stream modules, and moving the calibration and one-off scripts into subfolders)
was left undone rather than stacked untested on top of today's cut.

### Open after today


1. **Build the camera rig** — mount both cameras in their final position. Everything
   else waits on this.
2. **Run the tracker once** to verify today's strip (`cc2193c`), before any further
   refactoring.
3. **Calibration from scratch** — no backups of `camera_calib_1.toml`,
   `board_geometry.json` or `stereo_extrinsics.json` survived the reinstall.
   Order: `calibrate_camera.py` per camera (needs a 9x6 chessboard, 24.35 mm
   squares) -> `calibrate_board.py` -> `calibrate_stereo.py`, the last only once the
   cameras are in their final mount. **Back them up off the board this time.**
4. Auto-load `ov9282` at boot (still a manual `modprobe` every reboot).
5. Finish the pyscripts refactor: split `main.py` into capture / pose / stream, and
   move calibration and one-off scripts into subfolders.
