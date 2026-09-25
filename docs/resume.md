# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-25

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**Goal: validate the device against the lab's OptiTrack.** Protocol:
[validation_plan.md](validation_plan.md) (includes fitting a scale factor, §4.3b).
Whether the OptiTrack session has happened is not recorded in the repo yet —
**check and note it here.** Device-only recording on file: `2026-09-24_T1_grid_r1`.

**Tracker** (defaults in code; `settings.json` now has only 17 keys):
- joint two-camera fit, Huber robust loss 1 px, frames judged on median corner error;
- search and solve overlapped: 100 samples/s, 0 missed (setup kept in the table centre);
- starts reliably: driver at boot, monotonic clock, `exec` start, first pass reads Godot;
- debug preview: both cameras, tag IDs, search box; timing log counts tag flicker.

**Calibration (2026-09-23/24):** new tag stickers (~50.0 × 49.5 mm, `MARKER_LENGTH`
kept 50.0), new chessboard (12 × 8 inner corners, 30 mm), lenses redone
(cam0 0.19 px, **cam1 0.79 px**), `calibrate_board.py` then `calibrate_rig.py`
(held-out 0.70 px). Backup of the previous files: `~/calib_backup_2026-09-23/`.

**Jitter, understood:** measured 0.30 mm still vs 0.35 mm predicted from corner
noise σ ≈ 0.3 px (ratio 0.93, 98 holds). What remains is corner noise; no filter.

**Starting the system:** power on, wait for the clock to sync if recording for the
mocap, then

```bash
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

Frame rate / flicker: `tail -n 3 /tmp/tracker_timing.log`.

## Next actions

1. **Commit the analysis scripts** in `pyscripts/analysis/` (`measure_sigma.py`,
   `theoretical_error.py`, `compare_jitter.py`, `compare_rigs.py`,
   `visibility_explorer.py` + template) — not the outputs (`jitter_by_hold.csv`,
   `meta.json`, `visibility_explorer.html`, `theoretical_error_out/`); decide where
   outputs live.
2. **Validation session** (if not done): T0 gate, T1 ×2, T2 ×12, T3 ×6.
3. **Jitter levers, measured one at a time:** light; `corner_refine` (apriltag /
   subpix); cam1 lens recalibration (0.79 → ~0.2 px); check the chessboard is
   square (fy/fx differ 0.6–0.7 % on both cameras).
4. **Camera arrangement:** model says 300 mm apart, 20° inward ≈ 2–3× less depth
   error — needs longer CSI cables and a new mount; recalibrate after.
5. **Bug:** the search box makes cam1 lose tags 24 and 28 together at some spots
   (full-image search: flicker 45 % → 0–4 %).

## Small open items

- Delete the dead code behind the removed settings (averaging, raw pipeline,
  single-camera, per-marker, demo switch) — after the validation.
- A camera that cannot see the device searches its whole image every frame.
- `uv lock` on the board; decide on the in-game ■ Stop button.
- Next sticker print: pre-compensate the printer's ~1 % along one axis.

## Deliberately not done

- Display filtering (One Euro etc.) — user's decision: fix the source.
- Table-plane (x, z, yaw) fit — tried 2026-09-23, froze the cursor, reverted.
- Hardware camera sync — the modules don't expose FSIN. Drift correction — 0.3 ppm.
- Kiosk boot and upload — explicitly last.
