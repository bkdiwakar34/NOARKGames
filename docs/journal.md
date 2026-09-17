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
