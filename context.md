# NOARK — Project Context

## What it is
A 4-wheeled arm skateboard with ArUco markers. A camera tracks the markers to determine position. Games are already built and the device works to some extent — built by someone else.

## Current state (as of 2026-06-02)
- Full adaptive system on laptop — PI controller, workspace calibration, between-trial screen, session graph overlay done
- Two difficulty modes: Lifetime and Workspace
- Adaptive difficulty algorithm: in progress (simulate.py created, uncommitted) — not yet solid
- Task 7 (Godot auto-start on Pi boot): not yet started
- See design.md and build.md for full detail

## Status
- Now: Adaptive difficulty algorithm — distance as key parameter; in progress
- Next actions: Solidify algorithm with distance parameter; commit; then Task 7 (Godot auto-start on Pi boot)
- Recently done: Staircase calibration, settings popup redesign, reachable radius constraint based on patient speed (2026-06-03)
- Blocked: —
- last_touched: 2026-06-03

## Goal
Get system running on Pi with real arm tracker, then begin clinical study.

## Open TODOs (from build.md)
- [ ] Task 7: Godot auto-start on Pi boot
- [ ] Test workspace mode with real arm tracker on Pi
- [ ] Task 8: Python tracker accuracy fixes
- [ ] Task 9: Data sync to researcher server
- [ ] Task 10: Researcher dashboard
- [ ] Revert testing constants before real patient use (LIFETIME_MAX, LIFETIME_MIN, CATCH_HOLD_TIME)

## Key files
- `NOARKGames/SETUP_NOTES.md` — full setup history, current status, next steps
- `NOARKGames/pyscripts/tracker.py` — camera tracking, runs as systemd service
- `NOARKGames/Main_screen/Scripts/global_script.gd` — UDP receiver, position scaler
- `NOARKGames/settings.json` — runtime config

## Notes
- Runs on Raspberry Pi 5 (Linux ARM64), SSH: `ssh sujith@10.68.132.212`
- Godot 4.5 ARM64 binary at `/home/sujith/Downloads/Godot_v4.5-stable_linux.arm64`
