# Resume here

Read this first after any break. Overwrite it (don't append) in the last 5 minutes of
every session, while you still remember. History lives in git and
[weekly_progress.md](weekly_progress.md); this file only holds *now*.

**How to re-enter:** this file (2 min) → the matching section of [design.md](design.md) →
`git log --oneline -10`.

---

**Last updated:** 2026-09-17

**This repo is the Dragon Q6A one.** Split from the Raspberry Pi repo
(`bkdiwakar34/NOARKGames-pi`) on 2026-09-17; shared history up to tag `pre-split`.
`settings.json` here defaults to `camera_backend: "rcam_dual"`.
**`pyscripts/main.py` still contains the Pi's picamera2 path** — deliberately, since no
board could run the code on split day. Strip it once a Q6A run confirms the tracker is
healthy.

**Board state 2026-09-17:** the Q6A's onboard UFS module is gone (the firmware boot menu
lists only SD card and SPI flash), so the old freezing fault cannot recur. The board has
no OS yet — a fresh microSD is being written with
`radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz`. An M.2 **2230** NVMe SSD is the
intended final home; the card is the stepping stone.

**Before that:** repo cleanup on 2026-09-15 — `v2/`, `legacy/` and the unused
`addons/easy_charts/` were deleted; everything before that is at git tag
`archive-before-cleanup`.

**State of the two threads before the break:**

1. *Game (`app/`)* — v1 packages 0–4 and 6 built and Pi-verified by 2026-07-15.
   The agenda set that day, **not confirmed done**:
   - audit that all required data is saved (schema: [v1_plan.md §5](v1_plan.md))
   - test on a healthy user
   - Python analysis script over the CSVs to check the difficulty algorithm
2. *Tracker* — jitter comparison (old 3-marker vs rigid body) done 2026-07-24,
   plots in `tools/jitter_data/`. On 2026-08-27 the grid was tightened to 60 px cells
   and a calibration-order bug in `tools/jitter_test.gd` was fixed — **the denser
   re-run has not been recorded yet** (no CSV after 07-24). Latest doc work:
   [April-tag tracking.md](April-tag%20tracking.md), sections 0–3 (camera model,
   fisheye, calibration, undistortion).

**Next action:** pull on the Pi, launch `res://app/ui/main.tscn`, confirm it still starts
after the cleanup. Then pick which thread to resume.

**Open question:** which thread comes first — the game-data agenda, or the jitter re-run?

**Deliberately last:** kiosk boot (package 5), upload (package 7).
