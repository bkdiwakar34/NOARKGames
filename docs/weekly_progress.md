# Weekly progress — chronological work log

Derived from git history. Grouped by ISO week. Author names in `[brackets]`. Your commits are under `bkdiwakar34`.

---

## Pre-history (2025-09 — 2025-11)

Initial NOARKGames codebase built by Yuvanesh and Sujith. Multiple mini-games (Mr Bean, ping pong), patient registry, scene infrastructure. **Not your work — this is the inherited codebase.**

Key commits:
- 2025-09-03 `[Yuvanesh]` initial commit from YUV
- 2025-10-20 `[Sujith]` refactor + patient registry + scoring system
- 2025-10-24 `[Yuvanesh]` sound effects + Mr Bean error fix
- 2025-11-05 last activity before long gap

## Pre-history (2026-04)

Sujith rebuilt parts: upgraded to new Godot version, added Python tracker code into the repo, BLE plugin experiments for Android.

Key commits:
- 2026-04-01 `[Sujith]` upgrading to new godot version + adding python code here itself
- 2026-04-02 `[Sujith]` testing locally with python — tracker working in Windows
- 2026-04-04 `[Sujith]` UPDATING CALIBRATION

---

## Week 22 — 2026-05-25 to 2026-05-31

**Your first commit on the project.**

- `2026-05-27` Fix UDP port (12345), disable auto Python launch, fix Linux paths.
  - Got the inherited code running on the Pi. Three integration fixes: port number mismatch, auto-launch was misbehaving, Linux file paths.

**Theme**: getting the handed-down system to run on the Pi.

---

## Week 23 — 2026-06-01 to 2026-06-07

**Big foundational week — built v2 from scratch.**

### 2026-06-01 (v2 created)
- Add v2 codebase: adaptive difficulty, PI controller, session graphs *(full rebuild — 5 autoloads, Random Reach game, between-trial screen, session graph overlay, build.md, design.md, SETUP_NOTES.md)*
- Fix Z-axis screen mapping in UDPReceiver *(Z-axis distance → screen Y coordinate)*
- Tune PI gains for arm-based play (GAIN_P 0.15→0.35, GAIN_I 0.02→0.05) *(arm has natural deceleration → needs higher gain than mouse)*
- Graph: show threshold line and sampling band per trial
- Add target rate selector on game_select (40/50/70/80/90/100%) *(per-session override of patient's assigned rate)*

### 2026-06-02 (PID upgrade)
- **PID controller** + gain controls on game_select *(upgraded from PI; gains adjustable from UI without code changes)*
- Add trial duration and window width controls to game_select
- Replace +/- buttons with text inputs; add catch hold time control

### 2026-06-03 (calibration + reachability)
- Replace random calibration with **staircase method** *(1-up 1-down adaptive procedure to find each patient's threshold lifetime — much faster convergence than random sampling)*
- Staircase calibration UI: coarse step, fine step, n_reversals all settable
- Redesign settings popup: light card, segmented mode toggle, fix label truncation
- **Reachability constraint**: spawn apples within `lifetime × speed_estimate` radius from player *(prevents physically-impossible apples)*

### 2026-06-04 (simulator)
- Use sheep position at spawn time for speed estimation
- **Interactive PID simulator** (`pyscripts/simulate.py`): per-apple update frequency control
- Simulator redesign: r-space (`r = distance / (lifetime × speed)`), principled init, deterministic analytic catch rate, healthy user model with separate `actual_speed` vs `estimated_speed`

**Theme**: built the adaptive difficulty system end-to-end (PI → PID → staircase calibration → simulator for validation).

---

## Week 24 — 2026-06-08 to 2026-06-14

**Major pivot: PID → Fitts' Law. Hardware integration.**

### 2026-06-10 (Fitts' Law replacement)
- **Replace PID adaptive manager with Fitts' Law ADA system** *(see [v2/Core/adaptive_manager_pid.gd](v2/Core/adaptive_manager_pid.gd) — kept as reference, no longer autoloaded)*
- Fix Pi-specific type inference bug *(explicit type annotation for phase_str)*

### 2026-06-11 (hardware integration sprint)
- Phase 0b, hardware workspace calibration, apple visual redesign
- Calibration overlay: show live coordinates and hardware status
- **Auto-start and auto-stop tracking script from UDPReceiver** *(Godot launches Python tracker automatically; closes it on quit)*
- Fix auto-start: use venv python3 for main.py on Pi
- Gate cv2.imshow/waitKey behind debug flag *(fixes headless auto-start crash — no display server on Pi)*
- Fix port mismatch: main.py reads udp_port from settings.json
- **4-corner sensor-to-screen calibration** *(records raw sensor values at TL/TR/BL/BR and derives linear transform — replaces hardcoded constants that broke on the Acer screen)*
- Fix thread-safety: cache viewport size on main thread instead of calling get_viewport() from network thread

### 2026-06-12
- Remove BLE transport entirely *(BLE plugin route abandoned; UDP-only)*
- Consolidate calibration files into repo

**Theme**: switched the entire adaptive model from PID → Fitts' Law, then did all the hardware integration needed to run on the actual Pi+device setup.

---

## Week 25 — 2026-06-15 to 2026-06-21

**Tracker quality week — proper calibration + smoothing filters.**

### 2026-06-15 (proper camera calibration)
- **Add fisheye camera calibration script with multi-pose verify** *(`pyscripts/calibrate_camera.py` — auto-capture on stable detection, runs `cv2.fisheye.calibrate`, multi-pose accuracy/precision/fit reports)*
- Calibrate the Pi for the first time properly
- Remove `vflip` from picamera2 config *(camera mounted right-side-up — vflip was wrong)*
- Update calibration board defaults to OpenCV 9×6 pattern, measured 24.35 mm squares
- Wire main.py to single `camera_calib.toml` *(was loading laptop's webcam calibration on the Pi — `solvePnP` was using wrong intrinsics)*
- **Lock world origin only after 10 consecutive stable detections** *(was anchoring to the first noisy detection; now waits ~0.3 s of stability)*
- Fix dead-Godot heartbeat: track actual packet arrivals, not sticky cache
- Constrain calibration spawns to reachable region, add progress label
- Revert to fixed 5 ms exposure on Pi *(auto-tune adapted to room light but added lag)*

### 2026-06-16 (smoothing filters)
- **Add KalmanFilter3D** as opt-in alternative to EMA smoothing *(constant-velocity 6-D Kalman on [x,y,z,vx,vy,vz], dt measured per-update)*
- Expose `filter_type` knob in settings.json
- **Add One Euro filter** *(adaptive cutoff scaled with speed — heavy smoothing during hold, opens up during reach)*
- Expose kalman + one_euro tuning knobs in settings.json

### 2026-06-19
- Skip Phase 0b, expand Phase 0c to 15 pairs × 5 reps, add live Fitts plot *(calibration drops from ~260 to ~105 apples)*
- **Use `INTER_CUBIC` for fisheye undistort remap** *(was `INTER_LINEAR` — bicubic preserves edge sharpness for sub-pixel corner refinement)*

### 2026-06-20
- Add jitter diagnostic (`pyscripts/diagnose_jitter.py`), per-stage timing in main.py
- Refresh review log

**Theme**: fix the tracker properly — fisheye calibration, world origin lock, three smoothing filter options, jitter diagnostics.

---

## Week 26 — 2026-06-22 to 2026-06-28

**Tracker polish + documentation + this week's session.**

### 2026-06-22
- Extend review log with rejected-variant rationale and design caveats
- Add settings.json knob to pick which calibration file to load
- **Upgrade workspace calibration from 4 edges to 2D affine fit** *(handles tilted camera vs screen; least-squares fit over 4 corners)*
- Add NoOpFilter3D *(`filter_type = "none"` disables smoothing for noise-floor measurement)*
- Expose corner refinement method via settings.json *(none / subpix / contour / apriltag)*

### 2026-06-23
- **Add `pipeline_math.md` — full math walkthrough of the tracker** *(pinhole model, fisheye distortion, marker detection, sub-pixel refinement, solvePnP, frame transforms)*
- Rename pipeline doc and expand pinhole-projection section *(now [pyscripts/Aruco Tracking Pipeline.md](pyscripts/Aruco Tracking Pipeline.md))*

### 2026-06-25 (this session)
- **Add CornerStabilityFilter** to gate solvePnP when corners are still *(ported from Sujith's `filters.py`; threshold-based reuse of previous pose, kills jitter from solvePnP run-to-run variance)*
- **Recompute MARKER_OFFSETS from CAD model** *(replaced old guessed offsets — derived from Fusion measurements of grip point + each marker face center)*
- Fix MARKER_OFFSETS — markers are glued with +Y (printed-up), not +X *(initial orientation observation was wrong because grayscale debug view rendered X and Y axes both as black; corrected once viewed in color)*
- Expose pnp_method and framerate via settings.json *(iterative vs square; framerate target for picam2)*
- **Remove post-miss follow-through tracking** *(was waiting up to 6 s for player to reach missed apple before spawning next; felt laggy and not needed for current study)*

**Theme**: tracker polish + documentation for the supervisor presentation + final fixes to marker geometry.

---

## At-a-glance phase summary

| Weeks | Phase | Theme |
|-------|-------|-------|
| Pre-2026-05 | Inherited | Codebase from Yuvanesh + Sujith. Not your work. |
| Week 22 | First commit | Get the Pi running. |
| Week 23 | Foundation | v2 rebuild + PI → PID controller + staircase calibration + simulator. |
| Week 24 | Pivot | PID → Fitts' Law. Hardware integration sprint. |
| Week 25 | Tracker quality | Fisheye calibration, world origin lock, smoothing filters. |
| Week 26 | Polish + docs | Affine workspace calibration, math walkthrough doc, marker offset fixes. |
