# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NOARKGames** (also known as "Oskar_RPI") is a Godot 4.5-based rehabilitation gaming platform for stroke patients. The platform provides multiple mini-games that track motor skills recovery and patient progress through comprehensive data logging and visualization.

**Platform**: Godot 4.5 with GDScript
**Primary Target**: Linux ARM64 (Raspberry Pi)
**Secondary Target**: Android

## Running and Building

### Development
```bash
# Open in Godot Editor 4.5+
godot project.godot

# Run project (F5 in editor)
# Or from command line:
godot --path . --main-scene res://Main_screen/Scenes/main.tscn
```

### Export/Build
Export presets configured in `export_presets.cfg`:

**Linux ARM64** (Primary deployment):
```bash
# Export path: ./NOARK.arm64
# Includes SSH remote deploy for Raspberry Pi
# Uses OpenGL compatibility renderer
```

**Android**:
```bash
# Mobile platform support
# Check export_presets.cfg for full Android config
```

### Debug Mode
Edit `debug.json` to toggle debug mode:
```json
{"debug": true}   # Uses 'vvv' as patient ID, skips authentication
{"debug": false}  # Production mode, uses real patient IDs
```

Debug mode affects:
- Patient ID resolution in `Manager.create_game_log_file()`
- File path construction in data logging
- Patient data validation

## Architecture

### Autoload System (Global Singletons)
The platform uses Godot's autoload feature for core systems. Order matters for dependencies:

1. **PatientDB** (`Main_screen/Scripts/patient_db.gd`)
   - Centralized patient database management (JSON-based)
   - Stores patient records in user documents directory
   - Path: `{DOCUMENTS}/NOARK/records/patients.json`
   - Provides methods: `add_patient()`, `remove_patient()`, `get_patient()`, `list_all_patients()`
   - Cross-platform compatible (Windows, Linux, Android)

2. **Manager** (`Main_screen/Scripts/manager.gd`)
   - Creates CSV log files for game sessions
   - Handles file I/O for patient data
   - Format: `{game}_S{session}_T{trial}_{date}.csv`
   - CSV headers: `game_name, h_id, device_location, device_version, protocol_version, start_time`

3. **GlobalSignals** (`Main_screen/Scripts/global_signals.gd`)
   - Signal bus for inter-component communication
   - Stores global state: `current_patient_id`, `selected_training_hand`, `affected_hand`
   - Data path: `OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "//NOARK//data"`
   - Controls game button states via `enable_game_buttons()`

4. **GlobalScript** (`Main_screen/Scripts/global_script.gd`)
   - Session/trial management: `session_id`, `trial_counts` dictionary
   - UDP networking on `127.0.0.1:8000` for external device integration
   - Screen positioning: `network_position`, `scaled_network_position`
   - Position scalers for 2D/3D games: `PLAYER_POS_SCALER_X`, `PLAYER3D_POS_SCALER_Y`
   - Threading: `thread_network`, `thread_python`, `thread_path_check`

5. **SoundFx** (`Main_screen/Scenes/SoundFx.tscn`)
   - Audio management scene (autoloaded)

6. **GlobalTimer** (`Main_screen/Scripts/global_timer.gd`)
   - Centralized timer for session tracking

7. **ScoreManager** (`Main_screen/Scripts/score_db.gd`)
   - Score tracking and persistence (JSON-based)
   - Stores high scores in user documents directory
   - Path: `{DOCUMENTS}/NOARK/records/scores.json`
   - Provides methods: `get_top_score()`, `update_top_score()`, `get_all_scores_for_patient()`
   - Auto-migrates from old `user://score_data.tres` format

8. **DebugSettings** (`Main_screen/Scripts/debug_settings.gd`)
   - Debug configuration handling

9. **AudioManager**, **SceneTransition**, **GlobalTimerManager**
   - Game-specific managers (primarily for Jumpify)

### Data Flow and Patient System

**Patient Registration Flow**:
1. Patient details entered in registration UI → saved via `PatientDB.add_patient()`
2. Patient data stored in JSON: `{DOCUMENTS}/NOARK/records/patients.json`
3. Patient ID stored in both `PatientDB.current_patient_id` and `GlobalSignals.current_patient_id`
4. Data directory created: `{DOCUMENTS}/NOARK/data/{patient_id}/GameData/`

**Game Session Flow**:
1. Game starts → calls `Manager.create_game_log_file(game_name, patient_id)`
2. Session ID from `GlobalScript.session_id`
3. Trial ID from `GlobalScript.get_next_trial_id(game_name)` (auto-increments per game)
4. CSV file created with 7-line header + data rows
5. Game logs data at intervals (typically 0.02s) via file handle

**Data File Structure**:
```
{DOCUMENTS}/
  NOARK/
    records/
      patients.json  # Patient database (JSON format)
      scores.json    # High scores per patient per game
    data/
      {patient_id}/
        GameData/
          flappy_bird_S1_T1_2025-10-20.csv
          ping_pong_S1_T1_2025-10-20.csv
          ...
```

### Game Architecture Pattern

All games follow this structure:

**Main Scene Controller** (e.g., `flappy_main.gd`, `PingPong.gd`):
- Game state management: `game_running`, `game_over`, `is_paused`
- Score/health tracking
- Timer management (countdown, logging intervals)
- CSV data logging via `Manager.create_game_log_file()`
- Input handling and game loop

**Player/Character Scripts** (e.g., `pilot.gd`, `2Dplayer.gd`, `pp_player.gd`):
- Movement and physics
- Input processing (keyboard/mouse or UDP network position)
- Collision detection
- Animation control

**Game Objects** (e.g., `pipe.gd`, `ball.gd`, `apple.gd`):
- Obstacle/target behavior
- Scoring triggers
- Object pooling/spawning

**UI Components**:
- Score displays, health indicators, timer labels
- Game over screens, pause menus
- Results visualization (via EasyCharts addon)

### Network Integration

**UDP Communication** (`GlobalScript.udp`):
- Connects to `127.0.0.1:8000` on startup
- Receives position data: `net_x`, `net_y`, `net_z`, `net_a`
- Scales to screen coordinates: `scaled_network_position`, `scaled_network_position3D`
- Clamps to screen bounds: `MIN_X`, `MAX_X`, `MIN_Y`, `MAX_Y`
- Thread-based processing: `thread_network`

**Position Scaling**:
```gdscript
# 2D Games
network_position = Vector2(net_x, net_y)
scaled_x = network_position.x * PLAYER_POS_SCALER_X
scaled_y = network_position.y * PLAYER_POS_SCALER_Z

# 3D Games
scaled_x = net_x * PLAYER3D_POS_SCALER_X
scaled_y = net_y * PLAYER3D_POS_SCALER_Y
```

## Game Modes

The platform supports **2D** and **3D** game modes (set via `GlobalSignals.selected_game_mode`):

**Games with Both 2D and 3D Modes:**
- **Flappy Bird**: `FlyThrough` (2D) / `FlyThrough3D` (3D) - Separate scores tracked
- **Random Reach**: `RandomReach` (2D) / `RandomReach3D` (3D) - Separate scores tracked

**2D-Only Games:**
- **Ping Pong**: `PingPong` (2D with physics)
- **Fruit Catcher**: `FruitCatcher` (2D)

**3D-Only Games:**
- **Jumpify**: 3D platformer
- **Assessment modules**: 3D workspace tracking

**Scoring:** Games that support both modes maintain separate high scores for 2D and 3D. The `game_name` variable is updated dynamically based on `is_3d_mode` flag, which is set from `GlobalSignals.selected_game_mode` on game start.

## Input System

Configured in `project.godot`:
- **Jump**: Space
- **quit**: Escape
- **reset**: R
- **Left**: A or Left Arrow
- **Right**: D or Right Arrow
- **move_up**: W or Up Arrow
- **move_down**: S or Down Arrow
- **mouse_left**: Left Mouse Button

Games can use keyboard input OR network position (from UDP) interchangeably.

## Display Configuration

- **Mode**: Fullscreen (`window/size/mode=2`)
- **Stretch**: Canvas items with ignore aspect ratio
- **Renderer**: OpenGL Compatibility (`gl_compatibility`) for Raspberry Pi support
- **VRAM**: S3TC/BPTC compression for desktop, ETC2/ASTC for mobile

## Critical Implementation Details

### When Creating New Games:
1. Call `Manager.create_game_log_file(game_name, patient_id)` in `_ready()`
2. Store returned file handle for logging
3. Use `GlobalScript.session_id` and `GlobalScript.get_next_trial_id(game_name)`
4. Log data at consistent intervals (typically 0.02s via Timer)
5. Close file handle on game end

### When Modifying Autoloads:
- Order in `project.godot` matters for initialization dependencies
- `PatientDB`, `Manager`, and `GlobalSignals` must load before game scenes
- Debug mode is read from `debug.json` in `_ready()` of Manager and GlobalScript

### When Working with Patient Data:
**Using the Patient Database:**
- Access via global singleton: `PatientDB.add_patient()`, `PatientDB.get_patient(hospital_id)`
- Current patient ID: `PatientDB.current_patient_id` or `GlobalSignals.current_patient_id`
- List all patients: `PatientDB.list_all_patients()` returns Array of Dictionaries
- Patient database automatically saves to: `{DOCUMENTS}/NOARK/records/patients.json`
- All data persists in user documents directory (survives game updates/reinstalls)

**Using the Score System:**
- Access via global singleton: `ScoreManager.get_top_score(patient_id, game_name)`
- Update scores: `ScoreManager.update_top_score(patient_id, game_name, new_score)`
- Get all scores for patient: `ScoreManager.get_all_scores_for_patient(patient_id)`
- Scores automatically save to: `{DOCUMENTS}/NOARK/records/scores.json`
- Only updates if new score is higher than current top score
- **2D/3D Modes**: Games supporting both modes use different game names (e.g., `FlyThrough` vs `FlyThrough3D`)
  - Set `game_name` dynamically in `_update_game_name()` based on `is_3d_mode` flag
  - Example: `game_name = "GameName3D" if is_3d_mode else "GameName"`
  - This ensures separate high score tracking for 2D and 3D gameplay

**Data Directory Management:**
- Always check debug mode: `if debug: p_id = 'vvv'`
- Use `GlobalSignals.data_path` for game data directory: `{DOCUMENTS}/NOARK/data`
- Create directories recursively: `DirAccess.make_dir_recursive_absolute()`
- CSV logging format is standardized across all games

### Screen Positioning:
- Screen bounds calculated in `GlobalScript._ready()` based on `DisplayServer.screen_get_size()`
- Different scalers for 2D vs 3D: `PLAYER_POS_SCALER_X/Z` vs `PLAYER3D_POS_SCALER_X/Y`
- Clamp positions to prevent off-screen movement

## Third-Party Dependencies

**EasyCharts** (`addons/easy_charts/`):
- Enabled in editor plugins
- Used in Results/ scenes for progress visualization
- Line charts, bar charts for patient metrics