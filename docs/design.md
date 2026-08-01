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

### 4.1 Calibration phases (full run: first session, then weekly)

| Phase | Purpose | Apples |
|---|---|---|
| **0a — Workspace scan** | Discover the patient's reachable region | grid spiral, early-terminates at unreachable ring |
| **0c — Fitts calibration** | Fit Fitts model parameters $(a, b)$ | 5 distances × 3 widths × 5 reps = 75 |

Phase 0b (precision scan) was folded into 0c — the smallest reliably-hit width $W_{\min}$ is derived from per-$W$ hit rates within Phase 0c. Total calibration ~105 apples.

Since 2026-07-15 the calibration result (workspace tiles, $(a,b)$, per-pair variances) persists
in the patient file (`calib_profile`). Game start reuses it when the last full calibration is
under 7 days old; otherwise the phases rerun. The installer's *Auto / Always / Skip* switch
overrides this for testing and demos. Between full calibrations the model keeps adapting
online (§4.5), and the evolving state is re-saved after every trial.

### 4.2 Fitts' Law model

For each apple of amplitude $A$ (pixels) and width $W$ (pixels), the Index of Difficulty is

$$\mathrm{ID} = \log_2\!\left(\frac{A}{W} + 1\right) \qquad \text{(Shannon form, MacKenzie 1992)}$$

Movement time is modelled as

$$\mathrm{MT} = a + b \cdot \mathrm{ID}$$

where $a$ (s) is the intercept (initiation time) and $b$ (s/bit) is the slope (motor cost per bit of difficulty).

### 4.3 Initial $(a, b)$ fit (after Phase 0c)

Ordinary least squares over the $N = 15$ calibration pairs, using each pair's mean movement time $\overline{\mathrm{MT}}_k$:

$$b = \frac{N \sum_k \mathrm{ID}_k\,\overline{\mathrm{MT}}_k \;-\; \sum_k \mathrm{ID}_k \sum_k \overline{\mathrm{MT}}_k}{N \sum_k \mathrm{ID}_k^2 \;-\; \bigl(\sum_k \mathrm{ID}_k\bigr)^2}
\qquad\quad
a = \frac{\sum_k \overline{\mathrm{MT}}_k \;-\; b \sum_k \mathrm{ID}_k}{N}$$

The per-pair residual variance $\sigma_k^2$ is also initialised from the calibration sample.

### 4.4 Per-apple lifetime in the session

The session uses $5 \times 10 = 50$ $(A, W)$ pairs: the target width $W$ is **fixed for a whole
trial**, cycling through 10 session widths in reshuffled blocks (so trial number and size don't
confound), while the amplitude $A$ is drawn per apple from the 5 calibrated distances. For the
chosen pair $k$, the lifetime is set so the patient catches with probability $r$ (the day's
assigned target):

$$\widehat{\mathrm{MT}} = a + b\,\mathrm{ID}_k \qquad \sigma_k = \sqrt{\sigma_k^2}$$

$$\ell = \operatorname{clip}\!\bigl(\widehat{\mathrm{MT}} + z(r)\,\sigma_k,\;\; \ell_{\min},\; \ell_{\max}\bigr)$$

where $z(r) = \Phi^{-1}(r)$ is the standard-normal quantile (e.g. $z(0.8) \approx 0.84$).
Assumes MTs for a fixed $(A, W)$ are approximately normal.

### 4.5 Online adaptation

After every successful catch, form the observation $x = [1, \mathrm{ID}]^\top$ and prediction error
$e = \mathrm{MT} - x^\top \theta$, then update:

- **Recursive least squares** on $\theta = [a, b]^\top$ with covariance $P$ ($2 \times 2$,
  initialised at $1000\,I$ after a fresh calibration, or at a confident prior when a saved
  profile is loaded):

$$g = \frac{P x}{1 + x^\top P x} \qquad \theta \leftarrow \theta + g\,e \qquad P \leftarrow P - g\,x^\top P$$

- **Welford's algorithm** updates the per-pair residual SD $\sigma_k$ in a streaming,
  numerically stable way.

Misses carry no movement time and update nothing (known limitation — see todo.md).

### 4.6 Movement time measurement

$$\mathrm{MT} = t_{\mathrm{caught}} - t_{\mathrm{spawn}} - t_{\mathrm{hold}}$$

Times from `Time.get_ticks_msec()`; $t_{\mathrm{caught}}$ is the instant the target
disappears, i.e. when the cursor has stayed inside it for an unbroken
$t_{\mathrm{hold}}$.

**MT is acquisition time, not time-to-first-arrival** (deliberate, confirmed
2026-07-28). Only the final successful hold is subtracted, so if the patient
touches the target and overshoots, the failed hold and the return trip stay
inside MT. Example with $t_{\mathrm{hold}} = 1\,$s: touch at 0.8 s, overshoot,
re-enter at 1.5 s, hold completes at 2.5 s → MT = 1.5 s, not 0.8 s.

Two consequences when reporting:

- $a$ and $b$ are fitted to *acquisition* time, so $b$ is not the classical
  Fitts "motor cost per bit" (that is defined on first-arrival time). Call it an
  acquisition-time slope. MT also starts at spawn, so reaction time sits inside
  $a$ alongside movement initiation.
- Overshoot inconsistency enters $\sigma_k$, and $\sigma_k$ sets the deadline via
  $z(r)\sigma_k$ — so a patient's difficulty depends partly on their steadiness,
  not on speed alone. Intended, but worth stating.

### 4.7 Reachability constraint

Apples spawn only inside the patient's measured workspace. A candidate position is sampled at
distance $A$ from the player at a random angle (up to 24 attempts) and accepted iff it lands
inside a tile the patient hit during the workspace scan — the same geometry the researcher
shade overlay draws, so overlay and acceptance cannot disagree. If no angle at distance $A$
lands in-region, the apple falls back to a comfortable-zone cell (actual distance then differs
from the pair's nominal $A$; logged difficulty uses the nominal value — known limitation).
*(The earlier velocity-based pull-back described here was replaced on 2026-07-15.)*

---

## 5. Earlier Controller (PI on lifetime / workspace) — historical

Replaced 2026-06-10. Preserved as `v2/Core/adaptive_manager_pid.gd`. Two interchangeable modes:

- **Lifetime mode** — controlled the centre of a lifetime-sampling window around a per-patient threshold `t` (in seconds). PI update: `Δ ← Δ − (K_p·e + K_i·I)`, with dead band ±0.05.
- **Workspace mode** — same controller template, but on the rect-scale of the spawn position (0 = workspace centre, 1 = workspace edge).

Calibration was a 1-up 1-down adaptive staircase converging to the 50% threshold (replaced an earlier midpoint-of-extremes estimator).

The full historical maths walkthrough is in [presentation_notes.md](presentation_notes.md) and [presentation.tex](presentation.tex). Removed primarily because lifetime alone is not a good difficulty axis — Fitts' Law treats distance and width jointly.

---

## 6. Architecture

All active code is in `app/`, split platform / games / ui / installer (see
[v1_plan.md](v1_plan.md)). `v2/` is the frozen fallback `app/` was copied from,
still launchable via `--main-scene res://v2/Scenes/main.tscn`. The pre-v2
codebase is retired in `legacy/` (`.gdignore`d, see `legacy/README.md`).

### Autoloads (order matters; see `project.godot`)

| # | Name | Script | Purpose |
|---|---|---|---|
| 1 | PatientDB | `app/platform/patient_db.gd` | Patient JSON, rate schedule, calibration profile |
| 2 | GlobalSignals | `app/platform/global_signals.gd` | Signal bus, current_patient_id, installer flags |
| 3 | UDPReceiver | `app/platform/udp_receiver.gd` | UDP:12345, screen_pos, 100 Hz log buffer |
| 4 | SessionManager | `app/platform/session_manager.gd` | Session/trial IDs, CSV logs |
| 5 | AdaptiveManager | `app/platform/adaptive_manager.gd` | Trial timer, Fitts model, lifetime selection |
| 6 | WorkspaceConfig | `app/platform/workspace_config.gd` | 4-corner sensor-to-screen affine |
| 7 | AudioManager | `app/platform/audio_manager.gd` | Catch / miss / star sounds |

### Folder layout

```
app/
  platform/           — the autoloads above (tracking, data, difficulty)
  ui/
    chooser.tscn / .gd            — patient landing screen (game cards)
    main.tscn / .gd               — entry; routes to registration or chooser
    registration.tscn / .gd       — patient details + 14-day rate schedule
    game_select.tscn / .gd        — researcher session settings
    between_trial.tscn / .gd      — 5-star trial summary
    ui_theme.gd                   — design system (colors, fonts, background)
  games/reach/
    random_reach.gd / .tscn       — the reaching game, wired to AdaptiveManager
    apple.gd / .tscn              — single target (lifetime, catch, miss)
    graph_overlay.gd              — stop-session graph (programmatic, no .tscn)
  installer/
    installer.tscn / .gd          — checklist, origin ritual, test drive (F10)
    workspace_calibration_overlay.gd  — 4-corner sensor-to-screen calibration
  assets/               — fonts (Nunito), audio drop-in folder
pyscripts/
  main.py             — production tracker (Pi + dev)
  filters.py          — EMA / Kalman / OneEuro / CornerStability
  calibrate_camera.py — fisheye intrinsics calibration
  calibrate_board.py  — per-device marker layout (board_geometry.json)
  diagnose_jitter.py  — multi-pose noise-floor measurement
tools/
  jitter_test.gd/.tscn  — standalone old-vs-rigid jitter comparison harness
  analyze_jitter.py     — its analysis + figures
  jitter_data/          — collected CSVs and generated plots
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

The full math derivation of every stage (pinhole projection, fisheye distortion, marker detection, corner refinement, solvePnP) is in [tracker-math.md](April-tag%20tracking.md).

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
