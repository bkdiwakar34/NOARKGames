# NOARKGames — System Design

A rehabilitation gaming platform for stroke patients. The patient holds an instrumented device with ArUco markers on its faces; a camera tracks the markers in real time; the resulting 3D position drives a reaching game on a Raspberry Pi. The game's difficulty adapts trial by trial to maintain a target success rate assigned per patient.

This is the instrument for a PhD study on the causal relationship between success rate and adherence to therapy.

The product plan for the home-deployable version (kiosk experience, UI system, installer mode, build order) is in [v1_plan.md](v1_plan.md).

---

## 1. PhD Study Context

- **Research question:** What is the causal relationship between success rate in game-based therapy and patient adherence to that therapy?
- **Design:** 3-arm randomised pilot study.
- **Groups:** target group means of 70%, 80%, 90% per session.
- **Per-day target sampling:** each patient is randomised to one group, and 14 daily target rates are pre-sampled from `N(μ, σ²)` with `σ = 0.05`. The controller receives the current day's target and is blind to the group / mean.
- **Independent variable:** observed success rate (driven by the adaptive controller).
- **Dependent variable:** total therapy time over 2 weeks (adherence).
- **Duration:** 2 weeks, home-based after Day 1 training.

---

## 2. Session Structure

- A **session** is the period between device start and stop.
- A **trial** is 60 seconds of gameplay.
- Trials run back-to-back automatically; the patient never sees trial boundaries.
- Between trials, a 3-second pause shows only `"You caught X apples"` — the patient is not shown the success rate or difficulty.
- One patient per Pi; no login; current patient ID persists in `patients.json`.

---

## 3. Game — Random Reach ("Apple Catch")

A single reaching game wired to the adaptive controller. Each apple is a target; the player reaches the cursor into the catch zone and holds for `catch_hold_time` to confirm a catch. If the apple's lifetime expires first, it is a miss.

**Visual:** apple is **code-drawn, not sprite-based**. The sprite approach caused a multi-apple bug that was never fully diagnosed — code-drawn rendering is a permanent design rule.

**On-screen UI:**
- Score counter (top-right).
- Lifetime bar on the apple, fading green → yellow → red.
- Pulsing yellow catch ring around the apple.
- White catch arc that fills clockwise as the player holds the cursor inside.
- Stop button (top-left, 70% opacity) — ends the session and shows the session graph overlay.

**Game name vs internal name:** the on-screen title is "Apple Catch"; the internal/CSV name is `RandomReach`.

---

## 4. Adaptive Controller (current — Fitts' Law)

The deployed `v2/Core/adaptive_manager.gd` uses Fitts' Law to drive difficulty. It replaced an earlier PI controller (preserved as `adaptive_manager_pid.gd` for reference).

### 4.1 Calibration phases (run before normal play, every session)

| Phase | Purpose | Apples |
|---|---|---|
| **0a — Workspace scan** | Discover the patient's reachable region | grid spiral, early-terminates at unreachable ring |
| **0c — Fitts calibration** | Fit Fitts model parameters `(a, b)` | 5 distances × 3 widths × 5 reps = 75 |

Phase 0b (precision scan) was folded into 0c — the smallest reliably-hit width `W_min` is derived from per-W hit rates within Phase 0c. Total calibration ~105 apples.

### 4.2 Fitts' Law model

For each apple of amplitude `A` (pixels) and width `W` (pixels), the Index of Difficulty is

```
ID = log2(A/W + 1)        (Shannon form, MacKenzie 1992)
```

Movement time is modelled as

```
MT = a + b·ID
```

where `a` (s) is the intercept (initiation time) and `b` (s/bit) is the slope (motor cost per bit of difficulty).

### 4.3 Initial `(a, b)` fit (after Phase 0c)

Ordinary least squares on the 15 calibration pairs:

```
b = (N·Σ ID·MT̄ − Σ ID · Σ MT̄) / (N·Σ ID² − (Σ ID)²)
a = (Σ MT̄ − b·Σ ID) / N
```

Per-pair residual variance `σ²_k` is also initialised from the calibration sample.

### 4.4 Per-apple lifetime in the session

Sample an `(A, W)` pair uniformly from the 15 calibrated pairs, then set the lifetime so the patient catches with probability `r` (the day's target):

```
MT̂ = a + b·ID
σ = √σ²_k
lifetime = clip(MT̂ + z(r)·σ, ℓ_min, ℓ_max)
```

`z(r) = Φ⁻¹(r)` is the standard-normal quantile (e.g. `z(0.8) = 0.84`). Assumes MTs for a fixed `(A, W)` are approximately normal.

### 4.5 Online adaptation

After every successful catch (`MT`, `ID`):

- **RLS** updates `(a, b)` incrementally:
  - State: `θ = [a, b]`, covariance `P` (2×2, initialised at 1000·I).
  - Per observation: `g = Pẍ / (1 + xᵀPx)`, `θ ← θ + g·err`, `P ← P − g·xᵀP`.
- **Welford** updates per-pair residual SD `σ_k` in a streaming, numerically stable way.

### 4.6 Movement time measurement

```
MT = t_caught − t_spawn − t_hold
```

Times from `Time.get_ticks_msec()`. Subtracting `t_hold` (1 s) isolates the reach from the catch-confirmation hold.

### 4.7 Reachability constraint

Apples can only spawn at positions the patient can physically reach in the lifetime they're given:

```
v̂ ← max(v̂, d_i / ℓ_i)   over catches i
d_max = ℓ · v̂
```

If a sampled spawn is further than `d_max` from the player, it is pulled back along the same direction so distance equals `d_max`.

---

## 5. Earlier Controller (PI on lifetime / workspace) — historical

Replaced 2026-06-10. Preserved as `v2/Core/adaptive_manager_pid.gd`. Two interchangeable modes:

- **Lifetime mode** — controlled the centre of a lifetime-sampling window around a per-patient threshold `t` (in seconds). PI update: `Δ ← Δ − (K_p·e + K_i·I)`, with dead band ±0.05.
- **Workspace mode** — same controller template, but on the rect-scale of the spawn position (0 = workspace centre, 1 = workspace edge).

Calibration was a 1-up 1-down adaptive staircase converging to the 50% threshold (replaced an earlier midpoint-of-extremes estimator).

The full historical maths walkthrough is in [presentation_notes.md](presentation_notes.md) and [presentation.tex](presentation.tex). Removed primarily because lifetime alone is not a good difficulty axis — Fitts' Law treats distance and width jointly.

---

## 6. v2 Architecture

All active code is in `v2/`. The old codebase (`Main_screen/`, `Games/`) is untouched but unused.

### Autoloads (order matters; see `project.godot`)

| # | Name | Script | Purpose |
|---|---|---|---|
| 1 | PatientDB | `v2/Core/patient_db.gd` | Patient JSON, target_success_rate |
| 2 | GlobalSignals | `v2/Core/global_signals.gd` | Signal bus, current_patient_id |
| 3 | UDPReceiver | `v2/Core/udp_receiver.gd` | UDP:12345, screen_pos |
| 4 | SessionManager | `v2/Core/session_manager.gd` | Session/trial IDs, CSV logs |
| 5 | AdaptiveManager | `v2/Core/adaptive_manager.gd` | Trial timer, Fitts model, lifetime selection |

### Folder layout

```
v2/
  Core/                     — 5 autoloads above
  Scenes/
    main.tscn / .gd                       — entry; routes to registration or game_select
    registration.tscn / .gd               — therapist registers patient on Day 1
    game_select.tscn / .gd                — game selection + session controls
    between_trial.tscn / .gd              — 3-sec amber pause card
    workspace_calibration_overlay.gd      — 4-corner sensor-to-screen calibration
  Games/
    random_reach/
      random_reach.gd / .tscn             — main game, wired to AdaptiveManager
      apple.gd / .tscn                    — single-apple (lifetime, catch, miss)
      graph_overlay.gd                    — stop-session graph (programmatic, no .tscn)
pyscripts/
  main.py             — production tracker (Pi + dev)
  filters.py          — EMA / Kalman / OneEuro / CornerStability
  calibrate_camera.py — fisheye intrinsics calibration
  diagnose_jitter.py  — multi-pose noise-floor measurement
  simulate.py         — interactive PID simulator (legacy, kept for reference)
```

---

## 7. Tracker → Godot Pipeline

```
OV9281 fisheye camera (160° FOV)
    ↓ picamera2 @ 100fps
pyscripts/main.py
    - fisheye undistort (cv2.fisheye + INTER_CUBIC remap)
    - ArUco detection (AprilTag 36h11), sub-pixel corner refinement
    - solvePnP per marker → (R, t)
    - apply MARKER_OFFSETS (in marker local frame) → grip position
    - centroid across visible markers
    - corner stability gate (skip solvePnP if corners haven't moved)
    - temporal filter (EMA / Kalman / OneEuro, selectable)
    ↓ UDP 4-float packet
v2/Core/udp_receiver.gd  (port 12345)
    - background thread reads packets
    - sensor-to-screen 2D affine transform (4 corners → 6-parameter fit)
    - exposes screen_pos as global state
    ↓
v2/Core/adaptive_manager.gd
    - sets per-apple (A, W) and lifetime via Fitts' formula
    - updates (a, b) via RLS, σ_k via Welford after each catch
```

Heartbeat: Godot sends `CONNECTED` every 100 ms to port 12345 so the tracker learns Godot's reply address on startup.

The full math derivation of every stage (pinhole projection, fisheye distortion, marker detection, corner refinement, solvePnP) is in [tracker-math.md](tracker-math.md).

---

## 8. Marker Offsets (CAD-derived)

For each marker on the device, an offset vector `o` is stored in the marker's own coordinate frame (`+X` printed-right, `+Y` printed-up, `+Z` outward normal of marker face). The grip position in the camera frame is

```
p_grip = R_marker · o + t_marker
```

Each marker independently estimates the grip; the per-marker estimates are averaged for the final centroid. Mismatched offsets cause the cursor to jump when markers go in or out of view — so the offsets were derived from the Fusion 360 CAD model rather than hand-tuned.

**Deployed values** (metres, marker-local frame):

| Marker | Position on device | Offset |
|---|---|---|
| 12 | front face | `(0.001, 0.046, −0.059)` |
| 14 | left face  | `(−0.125, 0.045, −0.054)` |
| 20 | right face | `(0.125, 0.045, −0.054)` |

Sanity check: 14 and 20 are mirror images about `X = 0` (left-right symmetry); all three share `Y ≈ +0.045` (grip ~4.5 cm above each face centre); all three have negative `Z` (grip behind the outward-facing marker).

---

## 9. Workspace and Sensor-to-Screen Calibration

Two distinct calibrations happen at session start:

1. **Phase 0a (workspace scan)** — finds the patient's reachable cells on screen. Output: `reachable_cells`, workspace centre, `a_comfortable`, `R_ws`. Game-side, runs in Godot.
2. **Sensor-to-screen** — fits a 6-parameter 2D affine transform from tracker `(r_x, r_z)` (metres) to screen `(s_x, s_y)` (pixels) using 4 corner samples + OLS. Absorbs the camera-to-screen tilt. Stored in `user://workspace_config.json`. Run once per setup, not per session.

---

## 10. Smoothing Filters (in tracker)

Selectable via `settings.json["filter_type"]`. Implementations in `pyscripts/filters.py`.

| Filter | Behaviour | Pros / Cons |
|---|---|---|
| `none` (NoOp) | pass-through | for noise-floor measurement only |
| `ema` | `y = α·x + (1−α)·y_prev` | one knob, can't balance hold vs reach |
| `kalman` | 6-D const-velocity, per-update `Δt` from monotonic clock | overshoots at reach endpoints (model violation) |
| `one_euro` | EMA with `α` adapting to estimated speed | hold-quiet, reach-responsive; deployed default |

In addition: `CornerStabilityFilter` gates `solvePnP` itself — if no corner has moved more than 2 px since the last frame, the cached `(R, t)` is reused. Eliminates jitter caused by `solvePnP` optimiser variance on near-identical inputs.

---

## 11. Data Logging

- **Per-trial CSV** — per-apple rows logged by tracker (`Time, X, Y, Z`) in `~/Documents/NOARK/data/<hospital_id>/Session-YYYY-MM-DD/MovementData/`.
- **Session graphs** — stop-session overlay shows apple lifetime vs apple number (caught/missed) and per-trial success rate vs trial number.
- **CSV name** uses internal name `RandomReach`, not the on-screen "Apple Catch".

Data sync to a researcher server and a researcher dashboard are planned but not built.

---

## 12. Key design conventions (do not violate)

- All UI is **programmatic GDScript** — no `.tscn` files for v2 game scenes.
- Always use `get_viewport_rect().size`; never `DisplayServer.screen_get_size()`.
- Type inference breaks on autoload properties: use `var x: float = AutoLoad.value`, not `:=`.
- Mouse fallback is active when `UDPReceiver.connected == false` — dev only.
- `AdaptiveManager.start_session(rate)` must be called in game_select before the scene change.
- Apple is code-drawn — sprite approach caused a multi-apple bug.
- Success rate uses **resolved** apple count (`outcome_log`), not spawned count.
- `cv2.flip` / `vflip` must NOT be applied to camera frames — calibration's `c_x, c_y` were fit on the un-flipped image; flipping breaks `solvePnP`.
- Workspace 4-corner calibration must record TL → TR → BL → BR in that order — swapping silently produces a wrong-axis transform.

---

## 13. Testing constants — revert before patient use

| File | Variable | Testing | Production |
|---|---|---|---|
| `adaptive_manager.gd` | `catch_hold_time` | 1.0 | 0.8 |
| `adaptive_manager.gd` | `LIFETIME_MAX` | 8.0 | 15.0 |
| `adaptive_manager.gd` | `LIFETIME_MIN` | 0.1 | 3.0 |
| `adaptive_manager.gd` | `trial_duration` | UI-set | 60.0 |

All are settable from the game_select Testing row — no code change needed before clinical deployment.
