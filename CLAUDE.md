# CLAUDE.md

**NOARKGames** — Godot 4.5 rehabilitation gaming platform for stroke patients.
All active development is in `app/` (platform/games/ui/installer split). `v2/` is the frozen
fallback it was copied from (launchable via `--main-scene res://v2/Scenes/main.tscn`); the
old codebase (`Main_screen/`, `Games/`) is untouched.
Read [docs/design.md](docs/design.md) for the architecture + current Fitts'-Law adaptive design.
Read [docs/v1_plan.md](docs/v1_plan.md) for the v1 product plan and build order.
Read [docs/setup.md](docs/setup.md) for hardware and how to run.
Read [docs/todo.md](docs/todo.md) for open work.

---

## Running

```bash
godot project.godot                        # open in editor
godot --path . --main-scene res://app/ui/main.tscn   # run from CLI
```

Main scene: `res://app/ui/main.tscn`
Display: fullscreen, canvas_items stretch, OpenGL compatibility (Raspberry Pi).

---

## Python Tracker

ArUco marker tracking → UDP → Godot. Run before launching game on Pi.

```bash
python -m venv .venv && .venv\Scripts\activate   # Windows
pip install -e .
python pyscripts/main.py                          # streams to 127.0.0.1:12345
```

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

