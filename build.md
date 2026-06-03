# NOARKGames — Build Progress
_Last updated: 2026-06-03_

All new code lives in `v2/`. Old code in `Main_screen/` and `Games/` is untouched.

---

## v2 Folder Structure

```
v2/
  Core/
    patient_db.gd       — patient records + target_success_rate
    global_signals.gd   — current_patient_id, data_path, game_mode
    udp_receiver.gd     — UDP:12345, stores raw_x/y/z + screen_pos
    session_manager.gd  — session/trial IDs, CSV log file creation
    adaptive_manager.gd — trial timer, workspace calibration, PID difficulty controller
  Scenes/
    main.tscn / main.gd           — entry: routes to registration or game_select
    registration.tscn / .gd       — therapist registers patient on Day 1
    game_select.tscn / .gd        — game selection + all session parameter controls
    between_trial.tscn / .gd      — 3-sec pause overlay (warm amber card)
  Games/
    random_reach/
      random_reach.tscn / .gd     — Apple Catch game, wired to AdaptiveManager
      apple.tscn / .gd            — apple target: code-drawn (red circle, stem, leaf, pulsing ring)
      graph_overlay.gd            — stop-session graph screen (no .tscn — programmatic)
pyscripts/
  simulate.py           — interactive PID simulator (run on Windows, not Pi)
```

---

## Tasks

| # | Task | Status |
|---|------|--------|
| 1 | patient_db.gd + registration UI with target_success_rate | Done |
| 2 | AdaptiveManager autoload | Done |
| 3 | Workspace calibration in AdaptiveManager | Done |
| 4 | Wire Random Reach to AdaptiveManager | Done |
| 5 | Between-trial screen | Done |
| 5b | UI redesign (sprites, bg, aesthetics) | Done |
| 6a | Per-apple rolling window algorithm | Done |
| 6b | Workspace debug visualization | Done |
| 6c | Stop button + session graph overlay | Done |
| 6d | Algorithm redesign — PI controller + calibration trial | Done |
| 6e | Algorithm redesign — window-around-threshold sampling | Done |
| 6f | Workspace difficulty mode + mode toggle on game_select | Done |
| 6g | Per-trial success rate graph in overlay | Done |
| 6h | Graph: threshold line + sampling band per trial | Done |
| 6i | Device integration: heartbeat fix + Z-axis mapping | Done |
| 6j | Target rate selector on game_select (session override) | Done |
| 6k | PID controller + tuning UI on game_select | Done |
| 6l | Fix success rate bug (spawned vs resolved apple count) | Done |
| 6m | Interactive PID simulator (pyscripts/simulate.py) | Done |
| 6n | Staircase calibration for threshold estimation (trial 1) | Done |
| 6o | game_select redesign — clean main screen + settings popup | Done |
| 6p | Graph 1 improvements — adaptive Y axis, muted colours, smaller dots | Done |
| 7 | Godot auto-start on Pi boot | Not started |
| 8 | Python tracker accuracy fixes | Not started |
| 9 | Data sync to researcher server | Not started |
| 10 | Researcher dashboard | Not started |

---

## What works right now (confirmed on Dell 14 laptop + Raspberry Pi 5 with real device)

- Project runs cleanly with 5 autoloads
- Registration screen: therapist fills patient details + assigns 70/80/90% group
- Game select screen: sky gradient background, "Apple Catch" card button, all session controls
- Apple Catch game:
  - Player: jet.png sheep sprite at scale 0.15
  - Apple: code-drawn (red circle 28px, stem, leaf, shine, pulsing yellow ring)
  - Background: programmatic blue sky gradient (no texture)
  - Score counter top-right (orange)
  - Debug label bottom-left: `T# thr:Xs off:+Xs rate:X% err:+X%` / `ws center`
  - Workspace bounding box + center cross + spawn line appear from trial 2 onward
  - Between-trial amber card with "You caught X apples!"
  - **■ Stop** button top-left (70% opacity): stops session, shows session graph
- Graph overlay (two graphs):
  - Graph 1: apple lifetime (Y) vs apple number (X) — green=caught, red=missed, dashed orange threshold line, blue band per trial showing sampling window
  - Graph 2: per-trial success rate (Y) vs trial number (X) — orange line, dashed target line
  - "Back to menu" button
- AdaptiveManager: calibration trial → window-around-threshold sampling → PID controller
- UDPReceiver: proactive 100ms heartbeat so tracker.py learns reply address on startup
- Device confirmed working: arm tracker drives sheep, workspace calibration runs correctly

---

## Game select screen

Main screen shows: greeting, Apple Catch card, target rate buttons, "⚙ Settings" button.

Tapping "⚙ Settings" opens a centered popup card with three sections:

| Section | Controls |
|---------|----------|
| Difficulty mode | Toggle: Lifetime / Workspace |
| PID gains | `Kp [0.35]  Ki [0.05]  Kd [0.00]` |
| Testing | Trial: 10s/20s/30s/60s — `Width(s) [2.4]` — `Hold(s) [1.0]` — `Coarse [1.5]` — `Fine [0.5]` — `Rev# [6]` |

All values written to AdaptiveManager when "Apple Catch" is tapped. Target rate is session-only, not saved to patients.json.

---

## Current apple visual (apple.gd — code-drawn, NO sprites)

- Red circle radius 28px, bobbing animation (sin wave, ±3px)
- Shine highlight top-left, brown stem, green leaf top-right
- Pulsing yellow ring: CATCH_ARC_RADIUS=46
- Lifetime bar: green→yellow→red (`var lifetime: float` — set dynamically by AdaptiveManager)
- **Lifetime countdown PAUSES while player is in catch radius** (`_catch_progress > 0`) — prevents apple expiring mid-catch
- White catch arc: fills clockwise as player holds (`AdaptiveManager.catch_hold_time`)

**Do NOT go back to sprite-based apple — caused multi-apple bug, never fully diagnosed.**

---

## Adaptive difficulty — BUILT (adaptive_manager.gd)

Two modes selectable from game_select screen: **LIFETIME** and **WORKSPACE**.

### Shared logic (both modes)

```
Trial 1 — calibration (lifetime mode only):
  Staircase procedure (1-up 1-down):
    Start at LIFETIME_MIN (hard end)
    catch → decrease lifetime by step (harder)
    miss  → increase lifetime by step (easier)
    Coarse step (sc_step_coarse) for first 2 reversals; fine step (sc_step_fine) after
    Stop after sc_n_reversals reversals → threshold = mean of reversal lifetimes
  Trial 1 timer is NOT started — calibration ends only when staircase completes
  Fallback: if timer fires before staircase done, use caught/missed midpoint (old method)
  Set initial offset = (assigned_rate - 0.5) × window_width

Trial 2+ — window sampling:
  Sample from a window centered at (threshold + offset) [lifetime]
                              or (threshold - offset) [workspace]
  Window width: window_width seconds [lifetime] or WS_WINDOW_FRAC of edge dist [workspace]

  At trial end — PID update:
    rolling_rate = trial_caught / resolved_apples   ← resolved, not spawned (bug fix 2026-06-02)
    error = rolling_rate - assigned_rate
    derivative = error - prev_error
    prev_error = error
    _integral += error
    correction = gain_i * _integral + gain_d * derivative
    if |error| > DEAD_BAND: correction += gain_p * error
    offset = clamp(offset - correction, ...)   # positive offset = easier in both modes
```

### Lifetime mode

- Mechanism: apple lifetime controls difficulty
- threshold (seconds): lifetime where P(catch) ≈ 0.5 — calibrated from trial 1
- offset (seconds, positive = easier): window shifts toward longer lifetimes
- Window width: `window_width` (default 2.4s) — settable from game_select
- Apple experience: all apples feel challenging but achievable (no bimodal extremes)

### Workspace mode

- Mechanism: spawn distance from workspace center controls difficulty
- threshold (rect scale): scale = 1.0 is bounding box edge — calibrated from trial 1 catch/miss positions
- offset (positive = easier = closer to center): window shifts inward or outward relative to edge
- Window width: WS_WINDOW_FRAC = 0.30 of edge distance
- Hard apples spawn **outside** the bounding box (unreachable for patients who can't extend beyond workspace)
- Spawn uses **rectangular** edge geometry (`_rect_edge_dist()`), not circular radius
- Apple lifetime fixed at LIFETIME_MAX in workspace mode (distance is the only difficulty lever)
- Only meaningful with real arm tracker — mouse users can reach anything on screen

### Spawn constraint (both modes)

- Minimum distance between consecutive spawns: 20% of workspace diagonal from player position
- Prevents consecutive apples appearing in same location (which would bypass difficulty)
- If random spawn is too close, push outward along same direction

**Runtime-adjustable vars (set from game_select settings panel before starting session):**
```
gain_p          = 0.35   # tuned for arm-based play
gain_i          = 0.05
gain_d          = 0.00   # derivative term; 0 = pure PI behaviour
window_width    = 2.4    # seconds (lifetime mode sampling window)
trial_duration  = 60.0   # revert to 60.0 for real patients
catch_hold_time = 1.0    # revert to 0.8 for real patients
sc_step_coarse  = 1.5    # staircase coarse step (first 2 reversals)
sc_step_fine    = 0.5    # staircase fine step (after 2 reversals)
sc_n_reversals  = 6      # staircase stops after this many reversals
```

**Fixed constants:**
```
DEAD_BAND        = 0.05
WS_WINDOW_FRAC   = 0.30
BETWEEN_DURATION = 3.0
LIFETIME_MAX     = 8.0   # revert to 15.0 for real patients
LIFETIME_MIN     = 0.1   # revert to 3.0 for real patients
```

**Outcome log:**
- `AdaptiveManager.outcome_log` — Array of `{lt: float, hit: int, pos: Vector2}`, one entry per apple
- `AdaptiveManager.trial_log` — Array of `{trial: int, rate: float}`, one entry per completed trial
- Both cleared at `start_session()`

**Known gap:** threshold and offset reset on every `start_session()`. No cross-session memory.
If needed in future: persist in patients.json between sessions.

---

## Testing constants — MUST REVERT before real patient use

| File | Variable | Current (testing) | Revert to (patients) |
|------|----------|-------------------|----------------------|
| `adaptive_manager.gd` | `catch_hold_time` | `1.0` | `0.8` |
| `adaptive_manager.gd` | `LIFETIME_MAX` | `8.0` | `15.0` |
| `adaptive_manager.gd` | `LIFETIME_MIN` | `0.1` | `3.0` |
| `adaptive_manager.gd` | `trial_duration` | set via UI | `60.0` |

All of these are now settable from the game_select Testing row — no code change needed.

---

## PID simulator (pyscripts/simulate.py)

Run on Windows laptop to understand controller behaviour before testing on Pi.

```bash
pip install matplotlib numpy
python pyscripts/simulate.py
```

- Enter per-trial success rates manually (e.g. `1.0, 0.1, 0.1, 0.9, 0.9, 0.9`)
- Set Kp, Ki, Kd, window width in text inputs
- Hit Run — see lifetime window and success rate graphs update
- Uses the same PID logic as adaptive_manager.gd

---

## Stop button + graph overlay (graph_overlay.gd)

- **■ Stop** button: top-left of game screen, 70% opacity
- Clicking it: calls `AdaptiveManager.stop_session()`, freezes game, instantiates `graph_overlay.gd` as child Control
- Graph overlay shows two stacked graphs:
  - **Graph 1** (top, 34% height): apple lifetime vs apple number — green=caught, red=missed, dashed "start" reference
  - **Graph 2** (bottom, 26% height): per-trial success rate vs trial number — yellow dots, dashed orange target line
  - Title, stats (caught/missed/target), legend top-right
  - "Back to menu" button → returns to game_select
- `graph_overlay.gd` has no .tscn — instantiated via `GRAPH_OVERLAY_SCRIPT.new()`
- **All type annotations must be explicit** (no `:=` on values from autoload properties)

---

## Workspace debug visualization (random_reach.gd _draw())

Active from trial 2 onward (after `ws_calibrated = true`):
- Thin white rectangle (alpha 0.3) = workspace bounding box
- White cross = workspace center
- Thin white line from center to current apple position
- Debug label (bottom-left, dark pill): `T# thr:Xs off:+Xs rate:X% err:+X%` / `ws:(x,y)->(x,y) center:(x,y)`

---

## Key design decisions (permanent)

- All UI programmatic in GDScript — no Godot editor scenes
- One Pi per patient, no login — current_patient_id persists in patients.json
- Game name on screen: "Apple Catch". Internal/CSV name: "RandomReach"
- Mouse fallback when UDPReceiver.connected == false (dev only)
- AdaptiveManager.start_session(rate) called in game_select before scene change
- Viewport size passed via set_viewport_size() in random_reach._ready()
- 2D background = programmatic gradient. SheepBG-min-2.png = 3D mode only
- Apple MUST be code-drawn — sprite approach caused multi-apple bug
- Success rate uses resolved apple count (outcome_log), not spawned count — avoids undercounting when timer fires mid-apple

---

## Device integration notes (2026-06-01)

- **Heartbeat fix**: `udp_receiver.gd` `_network_loop` now sends "CONNECTED" at 100ms intervals when no packet is available. Required because tracker.py only sends data after learning Godot's reply address from an incoming message.
- **Z-axis mapping**: `screen_pos.y = (raw_z - 0.2) * 1400.0 + 40.0` — maps Z range 0.2–0.6m to screen Y 40–600px. Hardcoded for current tabletop setup. See SETUP_NOTES.md for context.
- **EMA alpha**: Changed from 0.4 → 0.7 in `pyscripts/tracker.py` (Pi only, not in repo) — reduces curved tracking paths.
- **PID gains tuned**: arm-based play catches more apples than mouse (natural deceleration near targets). Default Kp=0.35, Ki=0.05, Kd=0.00 — adjustable from game_select without code changes.

---

## Next steps

1. Tune PID gains systematically using the test protocol (see simulate.py)
2. Task 7: Configure Raspberry Pi to auto-launch Godot on boot
3. Task 8: Python tracker accuracy fixes
