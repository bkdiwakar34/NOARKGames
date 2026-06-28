# Presentation notes — chronological development of the adaptive difficulty system

Source material for supervisor presentation. Math in LaTeX, render in any markdown viewer that supports it (Obsidian, VS Code preview, Typora, etc.).

---

## Step 1 — Inherit code from Sujith, run on Pi

**What was received:**

1. A Godot project with several mini-games (Mr Bean, ping pong, etc.) built by previous students — not designed for adaptive difficulty research, just for static gameplay.
2. A Python tracker script (precursor to `pyscripts/main.py`) that:
   - Captured frames from a Pi camera
   - Detected ArUco markers
   - Estimated 3D pose with `solvePnP`
   - Sent the position over UDP to the Godot game
3. A physical device — a graspable object with multiple ArUco markers glued on its faces.

**What "running it on the Pi" meant:**

- Set up Raspberry Pi: install `picamera2`, OpenCV, Godot's ARM build, Python dependencies.
- Wire up the camera with the right exposure / framerate / resolution for marker tracking.
- Confirm the tracker produces sensible 3D coordinates when the device moves in front of the camera.
- Confirm those coordinates reach the Godot game over UDP and move something on screen.

**Why this step had to come first:**

The PhD is about adaptive difficulty in rehab gaming. The treatment hypothesis only makes sense if the patient's movements actually drive the game. Without the tracker → Godot loop working, any difficulty algorithm is just a simulation. So: get the hardware-to-game link working before writing any adaptive logic.

---

## Step 2 — Create `v2/` with the reaching game

**Why a new folder:**

Inherited codebase had many files — multiple games, patient registry, scene infrastructure — and a lot of it wasn't needed for the planned research. Rather than tear apart someone else's structure and risk breaking parts you didn't understand, the cleaner move was to start fresh in a new folder.

**New structure:**

```
v2/
  Core/                           — autoloaded singletons (persistent across scenes)
    patient_db.gd                 — patient JSON + target_success_rate per patient
    global_signals.gd             — signal bus, current patient ID
    udp_receiver.gd               — UDP listener on port 12345 for tracker data
    session_manager.gd            — session/trial IDs, CSV logging
    adaptive_manager.gd           — (added in step 3) the difficulty controller
  Scenes/
    main.gd / .tscn               — entry point; routes to registration or game
    registration.gd / .tscn       — therapist fills patient details
    game_select.gd / .tscn        — pick game + set session parameters
    between_trial.gd / .tscn      — 3-second pause card between trials
  Games/
    random_reach/                 — the actual game
      random_reach.gd / .tscn     — main game loop
      apple.gd / .tscn            — single-apple behaviour
```

**Why Random Reach as the game:**

Three properties needed for the research to be tractable:

1. **A single, clean difficulty knob.** Adaptive difficulty needs one variable the controller can turn up or down. In Random Reach, that knob is the spawn distance from the workspace centre (later also: apple lifetime). Compare to a complex game with many simultaneous mechanics — you couldn't tell what the controller is actually controlling.
2. **A binary outcome per apple.** Each apple is either *caught* (cursor held inside the catch radius for `catch_hold_time` seconds before lifetime expires) or *missed*. Binary outcomes give a clean success rate to feed the controller.
3. **A fundamental rehab task.** Reaching is the canonical motor task in stroke rehab — what therapists test, what the literature measures. Results from this game translate to clinically meaningful findings.

**Why the apple metaphor (not abstract dots):**

- Engaging visual for patients with low motivation.
- Pulsing yellow catch ring and lifetime bar (green→yellow→red) give continuous feedback without explicit countdowns.
- Code-drawn, not sprite-based — sprite approach caused a "multi-apple bug" never fully diagnosed.

**What v2 did NOT have at this point:**

- No difficulty controller yet. Apples spawned at random with fixed lifetime. The plumbing (trial structure, catch/miss recording, success rate) was all in place, but nothing was adapting.
- That separation was intentional: get the game itself feeling right before bolting on the controller.

**The autoload design choice:**

The 5 `Core/` files are *autoloaded* — Godot instantiates them at startup as global singletons, accessible from any scene as `AdaptiveManager.foo`, etc. The alternative (passing them as constructor arguments down the scene tree) would mean rewiring everything every time you added a feature.

---

## Step 2.5 — Workspace calibration (how the rectangle was drawn)

Before any difficulty control could happen, the system needed to know the patient's reachable region. This was a piece of automatic, implicit calibration done during the **first 60-second trial of every session**.

**The idea in one line:** record every position the cursor visits during Trial 1; the rectangle that just contains all of them is the workspace.

**The procedure:**

1. **Trial 1 starts** with no workspace known. Apples spawn at random positions across most of the viewport (10–85% of the screen in each axis). This deliberately scatters apples all over the screen so the patient has to reach in every direction.
2. **Every frame**, the system observes the current cursor position. It maintains two running values: `ws_min` (the smallest x and smallest y seen so far) and `ws_max` (the largest x and largest y seen so far). These two points define an axis-aligned rectangle that always just contains every observed position.
3. **The rectangle grows** as the patient reaches further into corners. If they reach a point further left than anything before, `ws_min.x` updates. If they reach further down, `ws_max.y` updates. Etc.
4. **Trial 1 ends** (60-second timer fires). The rectangle is frozen — it is now the workspace for the rest of the session.
5. From **Trial 2 onward**, all difficulty-controlled spawning happens relative to this rectangle: its centre is the easy point, its edges are the hard limit.

**Why this design:**

- **No explicit calibration step.** The patient never sees a "calibration phase" — they just play normally. The first trial is gameplay AND measurement at the same time.
- **Per-session.** Updates every session, so daily variation in range of motion (fatigue, time of day, spasticity) is captured automatically.
- **Patient-agnostic.** A mild-stroke patient's rectangle is big; a severe-stroke patient's rectangle is small. Same algorithm fits both.
- **Axis-aligned rectangle.** Simplest shape — just two corner points. Doesn't capture diagonal reach asymmetries, but easy to define, compute, and reason about.

**Known limitations of this approach (which is why it was later replaced in Step 7):**

- The rectangle includes regions the patient may never have reached just because they happened to pass through a corner once.
- A true reachable region is not a perfect rectangle — it's some irregular shape limited by joint range and muscle weakness.
- A single outlier point (e.g. an accidental over-reach) inflates the rectangle permanently.

---

## Step 3 — Proportional controller (workspace-based)

Original design from `design.md` v1, 2026-05-29. Workspace-based only.

### Control parameters

| Parameter | Symbol | Initial value | Range / units | Role |
|---|---|---|---|---|
| Difficulty | d | 0.5 | [0, 1] dimensionless | Control variable — what we adjust |
| Assigned success rate | r | per patient | {0.7, 0.8, 0.9} | Setpoint — what we want |
| Observed success rate | s_n | computed | [0, 1] | Measured variable after trial n |
| Error | e_n = s_n − r | computed | [−1, 1] | Distance from setpoint |
| Proportional gain | K_p | 0.5 | — | How aggressively we react |
| Dead band | δ | 0.05 | success-rate units | "Ignore noise" zone around zero error |
| Rolling window | N | 5 trials | — | How many recent trials feed into s_n |

### How each parameter is defined

**Difficulty d — initialised at session start:**

    d_0 = 0.5

Mid-range so the controller has room to move in either direction on the first update.

**Difficulty → physical effect (the actuator):**

    spawn distance from workspace centre = d_n × R_ws(θ_n)

where R_ws(θ_n) is the distance from workspace centre to workspace edge in a random direction θ_n drawn uniformly from [0, 2π).

**Observed success rate — computed at end of each trial:**

    s_n = (sum of caught apples in last 5 trials) / (sum of spawned apples in last 5 trials)

**Error signal:**

    e_n = s_n − r

Sign convention: e_n > 0 means patient is doing better than target → game is too easy → d should increase.

### Control law (how d is updated)

    if |e_n| > δ:
        d_{n+1} = clip(d_n + K_p × e_n, 0, 1)
    else:
        d_{n+1} = d_n        # inside dead band — do nothing

In words:
- Compute the error after each trial.
- If error is outside the ±5% dead band, nudge d by K_p × e_n.
- Clip d to [0, 1] (workspace has hard edges).
- If error is inside the dead band, leave d alone (assume it's noise).

### Worked example

Target r = 0.8, current d_n = 0.5, observed s_n = 0.6.

- e_n = 0.6 − 0.8 = −0.2
- |e_n| = 0.2 > 0.05 → apply update
- d_{n+1} = clip(0.5 + 0.5 × (−0.2), 0, 1) = clip(0.4, 0, 1) = 0.4
- Difficulty decreased — next apples spawn closer to centre.

### Rationale for each design choice

**Why proportional only (no integral or derivative term):**
- Simplest closed-loop controller — output directly proportional to error. One parameter to tune.
- Starting simple lets you confirm the closed loop works at all before adding complexity.
- More complex controllers (PI, PID) add states that can themselves go wrong; defer until you know you need them.

**Why a dead band |e_n| > δ:**
- Even at perfectly tuned difficulty, observed success rate fluctuates because catches/misses are stochastic (Bernoulli).
- With 5 trials × ~20 apples = 100 samples, standard error on the rate estimate is sqrt(0.8 × 0.2 / 100) ≈ 0.04 — ±4% just from sampling noise.
- A dead band of ±5% ignores changes within that noise floor. Without it, the controller chases its own measurement noise and oscillates.

**Why rolling window of 5 trials:**
- Single trial ≈ 10–20 apples. Standard error from one trial: sqrt(0.8 × 0.2 / 15) ≈ 0.10 — too noisy to control on.
- 5 trials → standard error drops to ~0.04 — comparable to the dead band.
- Tradeoff: longer window = more stable estimate but slower response to real changes (fatigue, recovery).

**Why workspace-relative (not absolute pixels):**
- Patient-agnostic: d = 0.7 means "70% of this patient's reach" — works equally for mild and severe impairment.
- Captures daily variation in range of motion (fatigue, time of day, spasticity).
- No per-patient gain tuning required — the workspace itself rescales the controller's units.

**Why update only at trial boundaries (not per apple):**
- Per-apple updates would double-count: one apple contributes to the error, then immediately changes the difficulty, which changes the next apple's outcome — non-stationary system, controller can't converge.
- 60-second trial windows give a stable snapshot of success rate for the controller to react to.

**Workspace calibration (implicit):**
- Runs implicitly during the first trial of every session — no instruction to patient.
- System records all arm positions visited in the first 60 seconds.
- Bounding box of those positions = functional workspace for the session.
- Updates every session to capture daily variation in ROM.

### What happened after — the limit that forced PI

The P controller has a known structural problem: **steady-state error**.

Imagine the controller has run for several trials and d has settled at some value where observed rate is close-but-not-equal to target — say s = 0.78 when r = 0.80. Then:

    e = 0.78 − 0.80 = −0.02
    |e| = 0.02 < δ = 0.05

Error falls inside the dead band → update law says d_{n+1} = d_n → **the controller stops correcting even though the rate is still wrong**.

The system therefore settles into any state inside a ±5% band around the target, not at the target itself. For a research instrument designed to drive patients to a *specific* assigned rate (70 / 80 / 90), this matters: a 78% group is not an 80% group.

Two ways to fix it:
1. **Shrink the dead band** — but then the controller chases sampling noise (5 trials × ~20 apples gives a standard error of ~4%, so a dead band smaller than ±5% would oscillate).
2. **Add an integral term** — accumulate the small residual error over time so it eventually grows large enough to push the controller, without reducing the dead band.

You chose option 2 → move to **PI**, first v2 commit (2026-06-01).

