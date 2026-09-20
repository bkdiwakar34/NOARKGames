# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-20

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**The goal changed on 2026-09-20: validate the device against the lab's OptiTrack
before trusting any of its data.** The July agenda (data audit → healthy-user test →
analysis script) waits until that is done.

The protocol is agreed and written down:
**[validation_plan.md](validation_plan.md) — read it before doing anything here.**

The system itself is healthy: exactly 100 samples/s end to end, screen also at 100 Hz,
all four calibrations done, camera-to-camera checked against a ruler (75.0 mm, 1.6°).

**The recorder is built but has never been run.** Godot installer (F10) →
**Validation recorder**: name dropdowns, Record / Stop, live status. Godot draws the
screen (cores 0–3) and the tracker writes the files and watches the sync pin
(cores 4–7).

**Starting the system** (on the board):

```bash
sudo modprobe ov9282        # camera driver — needed after every reboot
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

SSH: `ssh radxa@<ip>` — the IP changes with the phone hotspot (`hostname -I` on the
board). Calibration scripts must be run in a terminal on the board, not over SSH
(they open a window).

## Next action

1. **Dry run of the recorder** (no OptiTrack needed). F10 → Validation recorder →
   `T0 / test / r1` → Record → move the device ~20 s → Stop.
   - **The number that matters: does it stay at 100 packets/s while recording?**
     The standalone version it replaced managed only 80–93.
   - Then check `~/Documents/NOARK/validation/<date>_T0_test_r1/`: `samples.csv`,
     `corners.csv`, `sync.csv`, `calib/`, `meta.json`, and run the usual gap check on
     `samples.csv` column `t_cam0_s` (expect all 10 ms).
   - Also confirm the game itself still behaves (Trace test `rx: 100 pkt/s`).
2. **In the lab:** eSync 2 output → pin 15 (signal) and pin 16 (ground). Record →
   start the Motive take → stop it → Stop. Expect 1 rising + 1 falling edge.
3. **Then the trials** of [validation_plan.md §2](validation_plan.md) (T1, T2, T3).

## Small open items

- **After the recorder is proven**, delete the dead code left on purpose: the
  per-marker solver, the `SETUP:` demo switch (Godot toggles too), single-camera mode,
  `pyscripts/diagnose_jitter.py` (broken here — it opens the camera via picamera2),
  and `tools/`'s jitter harness.
- `uv lock` on the board, then commit it (`gpiod` is installed by hand but not
  pinned — see [todo.md](todo.md)).
- Back up the four calibration files off the board (`pyscripts/camera_calib.toml`,
  `camera_calib_1.toml`, `board_geometry.json`, `stereo_extrinsics.json`) — and
  `origin_lock.json`.
- Auto-load `ov9282` at boot.
- One deliberate close-up run to confirm the 10 ms budget holds with the device
  nearest the cameras.
- Decide on the in-game **■ Stop** button (patients can reach the researcher graph).

## Still to decide in the validation plan

Acceptance criteria per measure; where the reflective markers go on the device; and
T5 (recording during a real game), which needs Record to survive the scene change.

## Deliberately not done

- 120 fps — possible (camera ceiling 120.6) but not needed.
- Faster detection that changes what the detector computes (Aruco3 downscaling,
  detecting on the raw picture) — rejected until accuracy can be checked.
- Kiosk boot (package 5) and upload (package 7) — explicitly last.
