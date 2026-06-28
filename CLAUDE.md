# CLAUDE.md

**NOARKGames** — Godot 4.5 rehabilitation gaming platform for stroke patients.
All active development is in `v2/`. The old codebase (`Main_screen/`, `Games/`) is untouched.
Read [docs/design.md](docs/design.md) for the architecture + current Fitts'-Law adaptive design.
Read [docs/setup.md](docs/setup.md) for hardware and how to run.
Read [docs/todo.md](docs/todo.md) for open work.

---

## Running

```bash
godot project.godot                        # open in editor
godot --path . --main-scene res://v2/Scenes/main.tscn   # run from CLI
```

Main scene: `res://v2/Scenes/main.tscn`
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

## v2 Autoloads (project.godot order matters)

| # | Name | Script | Purpose |
|---|------|--------|---------|
| 1 | PatientDB | `v2/Core/patient_db.gd` | Patient JSON, target_success_rate |
| 2 | GlobalSignals | `v2/Core/global_signals.gd` | Signal bus, current_patient_id |
| 3 | UDPReceiver | `v2/Core/udp_receiver.gd` | UDP:12345, screen_pos |
| 4 | SessionManager | `v2/Core/session_manager.gd` | Session/trial IDs, CSV logs |
| 5 | AdaptiveManager | `v2/Core/adaptive_manager.gd` | Trial timer, difficulty controller |

---

## Critical v2 Notes

- All UI is programmatic GDScript — no `.tscn` files for game scenes
- Apple MUST be code-drawn — sprite approach caused a multi-apple bug (never diagnosed)
- Always use `get_viewport_rect().size` — never `DisplayServer.screen_get_size()`
- Type inference breaks on autoload properties: use `var x: float = AutoLoad.value`, not `:=`
- Mouse fallback active when `UDPReceiver.connected == false` (dev only)
- `AdaptiveManager.start_session(rate)` must be called in game_select before scene change

---

