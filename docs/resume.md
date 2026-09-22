# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-22

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**Goal: validate the device against the lab's OptiTrack.** Protocol:
**[validation_plan.md](validation_plan.md)** — read it first. The July agenda (data
audit → healthy-user test → analysis) waits until this is done.

**The recorder works** — Godot installer (F10) → **Validation recorder**:
- **T1**: 96 places over the whole table; **space** = 3 s hold, **backspace** = redo.
- **T2**: red pacer dot on a circle / figure-eight at 100 / 200 / 300 mm/s, 3 s lead-in,
  stops itself after 30 s.
- **T3**: centre → target → centre. **Not tried yet.**
- **Escape** stops a recording. Files per recording: `samples.csv`, `corners.csv`,
  `sync.csv`, `marks.csv` (maps samples to places / laps), `calib/`, `meta.json`.

**The tracker holds 100 samples/s over the whole table** (0 lost on a full T1 grid,
0.03 % on six T2 runs). **The two cameras' frames are aligned at start-up** to
~0.2–0.4 ms (was 1.6–4.6 ms, different each start).

**Sync wiring: eSync 2 signal → header pin 35, ground → pin 34** (pin 15 dropped —
it idles HIGH).

**Starting the system** (on the board):

```bash
sudo modprobe ov9282        # camera driver — needed after every reboot
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

"Device or resource busy" = a tracker is still running: `pkill -f pyscripts/main.py`.

## Where we stopped

Investigating why two cameras give so little less jitter (still ~0.44 mm static,
~0.66 mm moving). **Answer found:** they are 75 mm apart at ~500 mm (8.5° between
views), so both are weak in the same direction; the device's own 250 mm marker spread
is already a better depth ruler. Averaging is the best of five fusion methods tried;
the 6-DOF joint solve is unstable while moving (off in the tracker).

Open offer: a one-page `docs/why_two_cameras.md` with just this, in your numbers.

## Next action

Pick one:

1. **Table-plane fit, offline** — fit only x, z, yaw (plane from `origin_lock.json`) to
   both cameras' corners, test on the T1 grid and `T2_eight_fast_r1` with
   `compare_fusion.py`. Free, no hardware. Only if it wins does it go into the tracker.
2. **Try T3 once**, then **the lab session**: wire pin 35/34, `T0` to check the gate
   (1 rising + 1 falling edge), then T1 ×2, T2 ×12, T3 with Motive recording at the
   same name.

## Small open items

- Delete dead code left on purpose (now safe — recorder proven): per-marker solver,
  `SETUP:` demo switch (+ Godot toggles), single-camera mode, `diagnose_jitter.py`,
  `tools/` jitter harness.
- `uv lock` on the board, then commit (`gpiod` installed by hand but not pinned).
- Back up the calibration files off the board (`camera_calib*.toml`,
  `board_geometry.json`, `stereo_extrinsics.json`, `origin_lock.json`).
- Auto-load `ov9282` at boot.
- Decide on the in-game **■ Stop** button.

## Still to decide in the validation plan

Acceptance criteria per measure; where the reflective markers go on the device; T5
(recording during a real game).

## Deliberately not done

- Hardware camera sync — these Waveshare modules don't expose FSIN.
- Joint two-camera solve in the live tracker — unstable while moving, costs ~1 ms.
- Faster detection that changes what the detector computes — rejected until the mocap
  can check accuracy.
- Kiosk boot and upload — explicitly last.
