# NOARKGames — System Design
_Last updated: 2026-05-29_

---

## What this system is

A rehabilitation gaming platform for stroke patients. Patients hold a device with ArUco markers. A camera tracks arm position in real time. Mini-games run on a Raspberry Pi. The game difficulty adapts trial by trial to maintain a target success rate assigned to each patient by the therapist.

This system is the instrument for a PhD study on the causal relationship between success rate and adherence to therapy.

---

## PhD Study Context

- **Research question:** What is the causal relationship between success rate in game-based therapy and a patient's adherence to that therapy?
- **Design:** 3-arm randomised pilot study
- **Groups:** 70%, 80%, 90% average success rate per session
- **Independent variable:** Success rate (controlled by adaptive difficulty)
- **Dependent variable:** Total therapy time over 2 weeks (adherence)
- **Duration:** 2 weeks, home-based after Day 1 training

---

## Session Structure

- **Session** = from device start to device stop
- **Trial** = 1 minute of gameplay
- Trials run back to back automatically — patient never sees trial boundaries
- Between trials: 3-second pause showing only "You caught X apples" (patient never sees success rate or difficulty)
- Patient chooses which game to play at any point

---

## Workspace Calibration (per session)

- Runs implicitly during the first trial of every session
- No instruction to the patient — they just play normally
- System records all arm positions (raw camera coordinates) visited in the first 60 seconds
- Bounding box of those positions = functional workspace for that session
- Updates every session to capture daily variation in ROM (fatigue, spasticity, time of day)
- Workspace-relative difficulty scale makes the system patient-agnostic

---

## Difficulty Scale

- Single number: 0.0 (easy) to 1.0 (hard)
- Relative to that patient's functional workspace measured that session
- **0.0** → target spawns near the centre of the workspace (minimal reach required)
- **1.0** → target spawns at the edge of the workspace (maximum reach required)
- Same scale for all patients regardless of impairment level
- Session starts at difficulty = 0.5 (mid-range) and adjusts from there

---

## Adaptive Controller

Runs after each 1-minute trial.

**Input:** Rolling success rate from last 5 trials
```
rolling_rate = sum(caught in last 5 trials) / sum(spawned in last 5 trials)
```

**Error signal:**
```
error = rolling_rate - assigned_rate
```

**Adjustment (proportional with dead band):**
```
if |error| > 0.05:
    difficulty = clamp(difficulty + k * error, 0.0, 1.0)
```
- Dead band of ±5% matches the protocol's stated SD of ±5%
- k (gain) = 0.5 (starting value, tune empirically)
- Patient does not see difficulty, error, or success rate

**Why adaptive is necessary even with workspace calibration:**
Success rate depends not only on workspace but on fatigue, mood, speed, spasticity — factors that vary daily. The adaptive mechanism responds to actual performance, not predicted performance.

---

## Architecture

### AdaptiveManager (new global autoload)
Lives for the entire session, independent of which game is running.

| Variable | Purpose |
|---|---|
| `assigned_rate` | Loaded from patient record (0.7 / 0.8 / 0.9) |
| `difficulty` | Current difficulty 0.0–1.0, adjusted after each trial |
| `workspace_bounds` | Bounding box of arm positions from first trial |
| `trial_history` | Last 5 trials: [caught, spawned] pairs |
| `trial_number` | Which trial we're on |
| `trial_timer` | Timer node, fires every 60 seconds |

| Method | Purpose |
|---|---|
| `start_session(assigned_rate)` | Called when patient starts playing |
| `record_spawn()` | Called by any game when a target appears |
| `record_catch()` | Called by any game when a target is caught |
| `get_spawn_position(player_pos) → Vector2` | Returns a difficulty-scaled spawn position |
| `update_workspace(arm_pos)` | Called every frame during first trial |

| Signal | Purpose |
|---|---|
| `trial_ended(trial_num, caught, spawned)` | Games listen to show between-trial screen |

### Game integration (each game needs)
1. Call `AdaptiveManager.record_spawn()` when target appears
2. Call `AdaptiveManager.record_catch()` when target is caught
3. Use `AdaptiveManager.get_spawn_position(position)` for target placement
4. Listen to `trial_ended` to show 3-second pause screen

### First implementation: Random Reach
Other games wired later using same interface.

---

## Patient Data

- `target_success_rate` field added to patient record in `patients.json`
- Set by therapist during registration on Day 1
- Values: 0.7, 0.8, or 0.9 (group assignment)

---

## Data Logging (per session CSV)

Existing CSV logging extended with:
- Per-trial: trial number, apples caught, apples spawned, success rate, difficulty used
- Session summary: total trials, total time, overall session success rate

---

## Data Sync

- Patient connects device to mobile hotspot once a day
- Pi pushes CSV files to researcher's server
- Researcher views dashboard (web-based)
- **Status:** Not yet built — last priority

---

## Build Order (task list)

| # | Task | Status |
|---|------|--------|
| 1 | Add `target_success_rate` to patient registration + patient_db.gd | Not started |
| 2 | Build `AdaptiveManager` autoload | Not started |
| 3 | Workspace calibration in AdaptiveManager (first trial) | Not started |
| 4 | Wire Random Reach to AdaptiveManager | Not started |
| 5 | Between-trial screen in Random Reach | Not started |
| 6 | Godot auto-start on Pi boot | Not started |
| 7 | Python tracker accuracy fixes (corner refinement, resolution) | Not started |
| 8 | Data sync to researcher server | Not started |
| 9 | Researcher dashboard (web) | Not started |

---

## Open Questions

- Calibration: same OV9281 model, different unit — existing calibration (good.toml) is likely close enough for relative tracking. Recalibrate before clinical trial.
- Exclusion criteria: patients whose success rate is <50% even at difficulty=0.0 (floor effect) should be excluded. Verify during Day 1 training.
- Gain constant k=0.5 needs empirical tuning once system is running.
- Dashboard: technology not decided yet.

---

## Hardware

| Component | Detail |
|---|---|
| Computer | Raspberry Pi 5 |
| Camera | OV9281 monochrome fisheye, 160° FOV, CSI ribbon |
| Input device | NOARK device with ArUco markers (IDs 4, 8, 12, 14, 20) |
| Username on Pi | `sujith` |
| Repo on Pi | `/home/sujith/Documents/NOARKGames/` |
| Godot binary | `/home/sujith/Downloads/Godot_v4.5-stable_linux.arm64` |

---

## Key Files

| File | Purpose |
|---|---|
| `pyscripts/tracker.py` | Production tracker — runs as systemd service on Pi |
| `pyscripts/main.py` | Development tracker (Windows) |
| `pyscripts/calibration/good.toml` | Camera calibration |
| `Main_screen/Scripts/global_script.gd` | UDP receiver, position scaling |
| `Main_screen/Scripts/global_signals.gd` | Signal bus, shared state |
| `Main_screen/Scripts/patient_db.gd` | Patient JSON database |
| `Games/random_reach/Scripts/player.gd` | Random Reach main logic |
| `settings.json` | Runtime config (stream type, port, debug) |
| `SETUP_NOTES.md` | Full setup history and troubleshooting log |
