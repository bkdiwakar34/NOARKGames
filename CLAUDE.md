# CLAUDE.md

**NOARKGames (Dragon Q6A)** — Godot 4.5 rehabilitation gaming platform for stroke patients.
**This repo targets the Radxa Dragon Q6A + dual OV9281 via `rcam/` only.** The Raspberry
Pi 5 version is a separate repo (`bkdiwakar34/NOARKGames-pi`), split off 2026-09-17;
shared history up to tag `pre-split`, shared fixes move across by `git cherry-pick`.
All game code is in `app/` (platform/games/ui/installer split) — the only version. Older
codebases (`v2/`, `legacy/`) were deleted 2026-09-15 and live only at git tag
`archive-before-cleanup`.
Read [docs/resume.md](docs/resume.md) first — where work last stopped and the next action.
Read [docs/journal.md](docs/journal.md) for the dated build log (what was done, why, and the dead ends); add an entry at the top after any hands-on session.
Read [docs/design.md](docs/design.md) for the architecture + current Fitts'-Law adaptive design.
Read [docs/v1_plan.md](docs/v1_plan.md) for the v1 product plan and build order.
Read [docs/setup.md](docs/setup.md) for hardware and how to run.
Read [docs/todo.md](docs/todo.md) for open work.

---

## Running (on the Dragon Q6A)

```bash
taskset -c 0-3 ~/Downloads/Godot_v4.5-stable_linux.arm64 --path ~/Documents/NOARKGames --main-scene res://app/ui/main.tscn
```

Main scene: `res://app/ui/main.tscn`
Display: fullscreen, canvas_items stretch, OpenGL compatibility.
The camera driver loads at boot (`/etc/modules-load.d/ov9282.conf`); see
[docs/setup.md](docs/setup.md) for a fresh board. Code is never run on the Windows
machine — changes are pushed and tested on the board.

---

## Python Tracker

AprilTag tracking with two OV9281 cameras (`rcam`) → one joint pose → UDP → Godot.
**Godot starts it** (`app/platform/udp_receiver.gd`, pinned to cores 4-7); it
streams to 127.0.0.1:12345 and exits when Godot stops talking to it.

```bash
source .venv/bin/activate                       # venv made with uv, see setup.md
tail -n 3 /tmp/tracker_timing.log               # per second: ms per stage, missed frames, tag flicker
```

`settings.json` holds only what may change per board; decided values are defaults
in `pyscripts/main.py`. Tools: `pyscripts/README.md` (calibration/, analysis/,
diagnostics/).

---

## Autoloads (project.godot order matters)

| # | Name | Script | Purpose |
|---|------|--------|---------|
| 1 | PatientDB | `app/platform/patient_db.gd` | Patient JSON, target_success_rate |
| 2 | GlobalSignals | `app/platform/global_signals.gd` | Signal bus, current_patient_id |
| 3 | UDPReceiver | `app/platform/udp_receiver.gd` | UDP:12345, screen_pos |
| 4 | SessionManager | `app/platform/session_manager.gd` | Session/trial IDs, CSV logs |
| 5 | AdaptiveManager | `app/platform/adaptive_manager.gd` | Trial timer, difficulty controller |

---

## Critical Notes

- All UI is programmatic GDScript — no `.tscn` files for game scenes
- Apple MUST be code-drawn — sprite approach caused a multi-apple bug (never diagnosed)
- Always use `get_viewport_rect().size` — never `DisplayServer.screen_get_size()`
- Type inference breaks on autoload properties: use `var x: float = AutoLoad.value`, not `:=`
- Mouse fallback active when `UDPReceiver.connected == false` (dev only)
- `AdaptiveManager.start_session(rate)` must be called in game_select before scene change

---

