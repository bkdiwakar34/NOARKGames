# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. The full story lives in
[journal.md](journal.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the latest [journal.md](journal.md) entry →
`git log --oneline -10`.

---

**Last updated:** 2026-09-26

**This repo is the Dragon Q6A one.** The Raspberry Pi version is `bkdiwakar34/NOARKGames-pi`.

## State

**Goal: validate the device against the lab's OptiTrack.** Protocol:
[validation_plan.md](validation_plan.md) (includes fitting a scale factor, §4.3b).
**The OptiTrack session has NOT happened yet** — it waits for the new camera
arrangement. Device-only recording on file: `2026-09-24_T1_grid_r1`.

**Decision 2026-09-25:** the error model (`compare_rigs.py`) showed a wider rig is
better — cameras 300 mm apart, turned 20° inward, ≈ 2–3× less depth error than
today's 76 mm parallel pair. **Longer CSI cables ordered.** Validate the new
arrangement, not the old one.

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

## Next session: the clinic study interface

While the cables are on their way, work is on the **game side**. On 2026-09-25 the
interface for the 3-day healthy-participant study was designed page by page and a
mockup approved: spec in [clinic_study_interface.md](clinic_study_interface.md),
mockup [Reach Study Interface](https://claude.ai/artifact/NGWbDRwzpNHSiedrXAdayx).
It is a **separate flow** — the current `app/ui` chooser → game flow stays untouched.

**2026-09-26: packages 1–5 built and working on the board** (`app/clinic/`, see spec §7):
reach scan → warm-up → calibration → check → play, lifetimes from the day's calibration,
participants with balanced level orders, study days by visit, resume, Settings with
protocol lock, device tools, export. Game look: **night fireflies** (graded catches
Perfect/Great/Good, hitstop, glass jar, sounds; laser-pointer cursor with tail).
Operator screens match the mockup.

**Tracker bug found and fixed the same day:** cam1 was dropped from nearly every pass
whenever the start-up camera phase came out negative (random per start) — the tracker
was often cam0-only. Fixed in `main.py` (pairing waits up to 4 ms); paired 100 %,
0 missed frames. See journal 2026-09-26 (afternoon).

Run it:

```bash
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/clinic/clinic_main.tscn
```

Data in `~/Documents/NOARK/clinic/`; check a visit with
`python3 pyscripts/analysis/clinic_catch_rate.py` (newest visit by default).

Next:
1. **New pair distances** (Settings → Protocol): 450 mm is too long for the table area
   — keep `A + W/2` within the reach area and get a high ID from a smaller W
   (e.g. A 220 / W 15 mm ≈ 4.0 bits).
2. **Pilot** a few full visits, then set percentiles, pairs and point limits from real
   movement times (`clinic_catch_rate.py`) and **lock the protocol**.

The tracker items below wait for the cables.

## Next actions (tracker)

1. **While the cables are on their way:**
   - **re-measure jitter** (`measure_sigma.py` + `compare_jitter.py` on a new T1
     grid) now that both cameras are really in every pass, and check the per-sample
     fusion field of older recordings (e.g. `2026-09-24_T1_grid_r1`) — they may be
     partly or wholly cam0-only;
   - design the mount for the new arrangement (≈ 300 mm apart, each camera turned
     10° inward; check the exact gap/angle with `compare_rigs.py --rigs` for the
     real table);
   - cam1 lens recalibration (0.79 → ~0.2 px) and check the chessboard is square
     (fy/fx differ 0.6–0.7 % on both cameras — measure 10 squares each way);
   - fix the search-box bug: cam1 loses tags 24 and 28 together at some spots
     (full-image search: flicker 45 % → 0–4 %).
2. **When the cables arrive:** mount the cameras, then recalibrate in order —
   lenses only if touched (a moved camera does not change its lens), then
   `calibrate_rig.py` (camera-to-camera changes completely: its starting guess is
   the old 76 mm pair, so it may need `calibrate_stereo.py` first for a start),
   origin lock, 4 corners. Measure: `measure_sigma.py` + `compare_jitter.py` on a
   T1 grid — the prediction for the new rig should hold.
3. **Then the OptiTrack session:** T0 gate, T1 ×2, T2 ×12, T3 ×6.
4. **Jitter levers after that, one at a time:** light; `corner_refine`
   (apriltag / subpix).

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
