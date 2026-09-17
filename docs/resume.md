# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-17

**This repo is the Dragon Q6A one.** Split from the Raspberry Pi repo
(`bkdiwakar34/NOARKGames-pi`) on 2026-09-17; shared history up to tag `pre-split`,
shared fixes move across by `git cherry-pick`.

## State of the board

Rebuilt from bare metal today and **working**: boots from the SSD (`nvme0n1p3`), both
OV9281 cameras detected and capturing, Godot 4.5 installed, repo cloned at
`~/Documents/NOARKGames`. Reachable at `radxa@10.158.152.4` with the
`~/.ssh/noark_q6a` key — **the IP changes with the hotspot**, so check `hostname -I`
on the board if SSH times out.

Two things that do **not** survive a reboot:

```bash
sudo modprobe ov9282                 # camera driver
source .venv/bin/activate            # per terminal
```

The old UFS freezing fault is gone with the hardware — the boot menu lists no UFS
device and `dmesg | grep -i ufshc` is silent.

## The blocker

**The camera rig does not exist.** Both cameras are connected but not mounted, so
they cannot see the markers. Nothing below can be verified until that is built.

## Next action

1. Build the rig — mount both cameras in their final position.
2. Run the tracker once: `python pyscripts/main.py` on the board. This verifies
   commit `cc2193c`, which removed 147 lines (the Pi camera path and the pipelined
   undistort worker) and **has never been executed** — the commit message wrongly
   claims otherwise, see the journal.
3. Calibrate from scratch — nothing survived the reinstall. `calibrate_camera.py`
   per camera (9×6 chessboard, 24.35 mm squares), then `calibrate_board.py`, then
   `calibrate_stereo.py` once the mount is final. **Back the files up off the board.**

## Open question

Where should the rig be built, and is the mount final enough to calibrate stereo
against?

## Deliberately not done

- Splitting `main.py` into capture / pose / stream modules, and moving the
  calibration and one-off scripts into subfolders — waiting on a verified baseline
  rather than stacking untested cuts.
- Kiosk boot (package 5) and upload (package 7) — explicitly last.
