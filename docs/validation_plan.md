# Validation plan — NOARK device vs OptiTrack

**Status:** being agreed, started 2026-09-19. Sections 1–6 are decided; the open items
at the end are not.

**Goal:** show whether the device's raw pose is accurate and precise, at different
speeds, and whether it lags. Also show whether the per-reach measures built from it
(movement onset, peak speed, amplitude) agree with motion capture. If the raw data is
accurate, the derived measures follow. They still get their own check, because
differentiating amplifies noise (§1).

---

## 1. What is measured

Notation: $p$ = position, $R$ = orientation, subscripts $\text{dev}$ (device) and
$\text{moc}$ (mocap), both in the same frame and on the same clock (§4).

| # | Question | Measure |
|---|---|---|
| 1 | Position accuracy | $e(t) = p_\text{dev}(t) - p_\text{moc}(t)$; bias $= \overline{e}$; $\text{RMSE} = \sqrt{\tfrac{1}{N}\sum_t \lvert e(t)\rvert^2}$ |
| 2 | Orientation accuracy (yaw) | $\theta(t) = \angle\big(R_\text{dev}(t)\,R_\text{moc}(t)^\top\big)$; mean and RMSE |
| 3 | Precision (jitter while still) | SD of $p_\text{dev}$ over a still hold, next to the mocap's SD over the same hold |
| 4 | Error vs speed | measures 1–2 split into speed bands: still / slow / comfortable / fast |
| 5 | Lag | $\tau^* = \arg\max_\tau \sum_t v_\text{dev}(t)\,v_\text{moc}(t+\tau)$, $v$ = speed |
| 6 | Movement onset (reaction time) | onset per reach, device vs mocap, Bland–Altman |
| 7 | Vigour building blocks | peak speed $v_\text{peak}$ and amplitude $A$ per reach, Bland–Altman |

**Planar device, free checks.** The device slides on a table, so it moves in only three
ways: $x, y$ and yaw. Height $z$, roll and pitch are physically constant, so any
variation the device reports in them is pure error, visible even without the mocap:
SD of $z_\text{dev}$, SD of $\text{roll}_\text{dev}$ and $\text{pitch}_\text{dev}$.

**Vigour.** Not fixed here. Literature (Reppert et al. 2018, J Neurophysiol) defines
it as actual over expected peak speed for the amplitude,
$\text{vigour} = v_\text{peak} / v_\text{expected}(A)$ with
$v_\text{expected}(A) = \alpha\big(1 - 1/(1+\beta A)\big)$ fitted per person. Every
definition is built from $v_\text{peak}$ and $A$, so validating those two (measure 7)
covers any definition chosen later.

**Speed noise.** $v = \big(p(t+\Delta t) - p(t)\big)/\Delta t$ gives
$\sigma_v = \sqrt{2}\,\sigma_p/\Delta t$; e.g. $\sigma_p = 0.3$ mm at $\Delta t = 10$ ms
gives $\approx 42$ mm/s. The analysis uses **one** speed-smoothing method, applied
identically to both systems.

**Onset between samples.** Both systems run at 100 Hz (§6), so onsets are found by
interpolating the threshold crossing, not rounded to a frame:
$t_\text{onset} = t_k + \dfrac{v_\text{th} - v_k}{v_{k+1} - v_k}\,\Delta t$, where
$v_k < v_\text{th} \le v_{k+1}$.

---

## 2. Trials

One participant (the researcher): what is tested is the device, so the sample size
is the number of movements, not people.

| Trial | What | Design | Count | Answers |
|---|---|---|---|---|
| **T1** Static holds | Device still, 3 s per hold | **96 places** (12 across × 8 deep, spread over the whole table) held once each, natural grip; the whole grid done twice | 192 holds | 1, 2, 3 |
| **T2** Continuous | Follow a pacer dot round a circle or figure-eight over the whole table, 3 s lead-in + 30 s | 3 speeds (**100 / 200 / 300 mm/s**) × 2 shapes × 2 repeats | 12 × 30 s | 4, 5 |
| **T3** Discrete reaches | Centre → target → centre, self-paced (no go cue) | 8 directions × 2 distances × 2 speeds (comfortable, fast) × 3 repeats | 96 reaches | 6, 7 |
| **T5** Real game | Random Reach, 3 min | 2 runs | 2 × 3 min | all, under real use |

(T4, rotations about each axis, was dropped: the device is planar. Deliberately
turning the device at each place was dropped too, 2026-09-21: held by hand it sits
in a natural rotation anyway, and the time is better spent on more places. The yaw
error is still measured, over whatever rotation range the grip produces.)

- Places are **rough**: the mocap is the truth, so each hold is judged at whatever
  pose it actually has. Guidance is on screen — the workspace calibration maps the
  table onto the viewport, so the dots the recorder draws (§3) are places on the
  table. 3 s at 100 samples/s = 300 samples per place, enough for its jitter.
- The second grid (device re-placed) separates "this spot on the table is bad" from
  noise.
- The go cue is not needed for measure 6:
  $\text{RT}_\text{dev} - \text{RT}_\text{moc} = \text{onset}_\text{dev} - \text{onset}_\text{moc}$.
- ~96 reaches gives a 95 % margin on each Bland–Altman limit of about
  $\pm 1.96\sqrt{3/n}\,s = \pm 0.34\,s$ ($s$ = SD of the differences).
- Holds and reaches are **labelled in `marks.csv`** (§3), so each place's samples are
  known exactly rather than inferred from the movement.
- Total ≈ 50 min of recording (T1 ~20, T2 ~10, T3 ~10, T5 ~8), one lab session.

### Naming

One recording per block; the **Motive take gets the identical name**.

`<date>_<trial>_<condition>_r<repeat>`, e.g. `2026-09-22_T1_grid_r1`,
`2026-09-22_T2_circle_slow_r1`, `2026-09-22_T3_fast_r3`, `2026-09-22_T5_game_r2`.

| Trial | One recording holds | Conditions | Recordings |
|---|---|---|---|
| T1 | a whole grid, 96 holds | `grid` | 2 |
| T2 | one shape at one speed | `circle` / `eight` × `slow` / `comfortable` / `fast` | 12 |
| T3 | one speed: 8 directions × 2 distances = 16 reaches | `comfortable` / `fast` | 6 |
| T5 | one game run | `game` | 2 |

The recorder builds the name from dropdowns (trial, condition, repeat) plus the date,
so a typo cannot break the pairing; it is typed into Motive by hand.

---

## 3. Recording on the device

### Recorder — in the game, not a separate program

**Godot installer (F10) → Validation recorder** (`app/installer/validation_recorder.gd`).
Name dropdowns (trial, condition, repeat; the date is added), Record / Stop, and a
screen that guides the movement. **The screen is the table**: the 4-corner workspace
calibration maps the table onto the viewport, so Record stays disabled until that
calibration exists.

| Trial | What the screen shows |
|---|---|
| T1 | 96 dots (12 × 8) over the whole table, walked in serpentine order. The next one is ringed. Place the device, let your hand settle, then **press space**: the ring fills over 3 s and the dot turns green. **Backspace** redoes the last place. Counter: `17 / 96`. |
| T2 | The shape drawn faintly and a **red pacer dot** running along it at the condition's speed; keep the cursor on it. The dot waits 3 s at the start (gold ring + countdown), then moves for 30 s, and the recording **stops itself**. Speeds are on the table, not the screen: the 4-corner calibration gives pixels per metre ($\sqrt{\lvert\det A\rvert}$ of its linear part). The dot moves at constant distance along the path, so the speed is the same everywhere on the figure-eight. |
| T3 | Alternates centre and target (8 directions × 2 distances); touching the lit one advances. Every reach starts from the same place. |
| T0 | Cursor only — dry run. |

Speeds were tuned on the board (2026-09-21): 300 mm/s is already the fast end of what
the hand follows on these shapes. If error grows with speed, the result must be stated
as "validated up to 300 mm/s".

The dots stay hidden until Record, and **every control hides while recording** (the
table fills the screen); one line in the top-left corner shows name, progress, rate,
gate and the keys. **Escape stops** a recording; a second Escape leaves the screen.
The repeat number resets to `r1` when trial or condition changes.

A hold runs its full 3 s once started, with **no "did it move?" check** (dropped
2026-09-21): such a check would read the tracker's own output, so marker noise or a
bad solve would abort a good hold — judging the tracker by the thing under test. The
mocap decides afterwards whether a hold was really still.

Bottom strip: Record/Stop, progress, and two indicators — sample rate (green at
≥ 95/s) and the OptiTrack gate (green while Motive records). Nothing drawn on this
screen enters the data files except the labels in `marks.csv`.

The work is split the way the 100 Hz measurement already runs:

| | Runs on | Does |
|---|---|---|
| Godot | cores 0–3 | the screen; sends `REC_START:<name>` / `REC_STOP`, repeated with the 100 ms keepalive until the tracker's status agrees, so a lost packet cannot desynchronise them |
| Tracker (`main.py` + `recording.py`) | cores 4–7 | tracks, writes the files, watches the sync pin; sends a status packet twice a second (first float32 = 7.0, then JSON; position samples are 2.0) |

The files and the pin stay in the tracker: the pin's edges and the camera frames must
be stamped with the same kernel clock, and Godot cannot read GPIO.

**Rejected 2026-09-20:** a standalone Tk window running the tracker in its own
process (`pyscripts/recorder.py`, deleted). It ran at 50/s unpinned and 80–93/s
pinned to cores 4–7, recording or not, i.e. the window's own process cost, not the
file writing. Nothing is written during a patient session: recording starts only when
Godot asks.

### Sync with OptiTrack

- **Direction:** Motive → Dragon. The eSync 2 output is set to **Recording Gate**
  (high for the whole Motive take, low otherwise).
- **Voltage:** eSync 2 output is 3.3 V; Dragon header pins are 3.3 V (tolerant to
  3.63 V), so the wire goes straight in. A 1 kΩ series resistor is optional
  protection.
- **Wiring:** signal → **header pin 35** (`GPIO_100`, `/dev/gpiochip4` line 100);
  ground → **header pin 34** (GND, next to it).
  Pin 15 (line 1) was the first choice and was dropped on 2026-09-21: with nothing
  connected it reads HIGH, because the board pulls it up harder than the chip's
  internal pull-down. The eSync would have overridden that, but then an unplugged or
  broken cable looks exactly like "Motive recording". Checked with
  `gpioget -B pull-down gpiochip4 <line>` over every free header pin; line 100 idles
  LOW and is header pin 35 in both Radxa's pinout and the board's own naming.
- **Timing:** the kernel timestamps each edge (µs precision) on `CLOCK_MONOTONIC`,
  the same clock as each camera frame's capture time.
- **Drift:** both edges are logged, so clock drift between the systems is removed by
  scaling (§4, step 1). Uncorrected, 50 ppm over 10 min would be
  $600 \times 50\times10^{-6} = 30$ ms.

### Files — one folder per recording

| File | One row per | Contents |
|---|---|---|
| `samples.csv` | sample (100/s) | sample number; cam0 and cam1 capture times and frame sequence numbers; camera(s) used (`fusion`); markers seen per camera; reprojection error per camera; cam0-vs-cam1 pose gap (mm, °); combined board pose in cam0's frame (`tx..tz`, quaternion `qx..qw`); grip point in the game frame (`game_x..z`) |
| `corners.csv` | marker seen by a camera | sample number, camera, marker ID, 4 corners (8 numbers) |
| `sync.csv` | pin edge | kernel time, rising / falling |
| `marks.csv` | labelled moment | `t_s`, `sample` (the row in `samples.csv` at that moment), `label`. T1 writes `hold_start i x y` and `hold_end i x y` per place (`i` = place index, `x y` = where it was drawn), plus `redo i x y`; T2 writes `pacer <condition> <speed> mm_s lead 3.0 s` once and
`lap n` each lap; T3 writes `at_centre i x y` / `at_target i x y`. **This is what maps data to places** — no segmentation by guesswork. |
| `calib/` | — | copies of `camera_calib.toml`, `camera_calib_1.toml`, `stereo_extrinsics.json`, `board_geometry.json`, `origin_lock.json` |
| `meta.json` | — | date, settings, git commit |

Every row flushed to disk as written. ~7 MB/min.

Why the raw corners and both capture times:

- **Fusion method decided by the data.** The tracker now averages the two cameras'
  separate poses (weights $w = 1/e^2$, $e$ = reprojection error). With the corners
  saved, the alternatives can be recomputed offline on the same recording and each
  compared against the mocap: cam0 only, cam1 only, pose averaging, and a joint solve
  (one pose fitted to both cameras' corners at once).
- **Camera offset.** The cameras are not triggered together; the paired cam1 frame is
  up to 5 ms from cam0's. During movement the fused position is off by
  $w_1 \cdot v \cdot \delta$ (e.g. $0.5 \times 1000$ mm/s $\times 0.005$ s $= 2.5$ mm at
  1 m/s). The first recording measures the real $\delta$. It can then be corrected
  offline by interpolating cam1 to cam0's capture time, or in hardware (OV9281
  frame-sync input, if the modules and driver support it).
- **Frame choice deferred.** With corners and calibration saved, the pose can be
  expressed in the camera frame or the game frame later.

---

## 4. Comparison

1. **Time:** device sample times onto Motive's clock from the two gate edges:
   $t_\text{moc}(i) = (t_i - t_\text{rise})\cdot L_m / L_d$, with
   $L_m$ = Motive take length and $L_d = t_\text{fall} - t_\text{rise}$.
2. **Common time base:** interpolate the mocap pose to each device sample time.
   Worst-case linear-interpolation error $a h^2/8$: 0.125 mm at 100 Hz for
   $a = 10$ m/s².
2b. **Report errors in the table's frame** (decided 2026-09-21). Both systems see the
   device moving in one plane, which defines the table; the error at each place is
   then three numbers that mean something physical: **left-right**, **near-far**, and
   **height** (out of the plane, physically ~0). The screen mapping is not used for
   this — it is a 2D fit for drawing targets, while the error analysis needs the
   physical plane.
3. **Space:** two fixed unknowns, $\text{Pose}_\text{moc}(t) = X\cdot\text{Pose}_\text{dev}(t)\cdot Y$
   ($X$ = cameras relative to the mocap origin, $Y$ = reflective markers relative to
   the device frame), found by least squares. **Fit on `T1_grid_r1` only, test on
   everything else**, so the fit cannot absorb the device's own error. The height
   component of $X$ and $Y$ is not separable with planar motion; it is only a
   constant $z$ offset and does not affect $x, y$ or yaw.
4. **Measures** of §1, per trial.

---

## 5. Graphs and tables (agreed 2026-09-19, open to change)

| Measure | Graph |
|---|---|
| 1, 2 | Time series from one T2 recording: device and mocap $x, y$, yaw overlaid, error underneath |
| 1 | Error map of the table: the 96 T1 places at their positions, coloured by error (left-right, near-far and height as three panels) |
| 3 | Hold jitter (SD) per hold, device next to mocap |
| 4 | Error against speed, with RMSE per speed band |
| 5 | Cross-correlation against time shift $\tau$, peak marked |
| 6, 7 | Bland–Altman for onset, $v_\text{peak}$, $A$: difference vs mean, bias and $\pm 1.96$ SD lines |
| free checks | Histograms of device $z$, roll, pitch |

Plus one summary table: each measure, its value, pass / fail against the acceptance
criteria (not yet set).

---

## 6. Motive settings

- **Frame rate:** 100 Hz (lab standard), or **240 Hz if the cameras allow**. A finer
  reference is better (interpolation, onset timing, peak speed). Check the camera
  model: Flex 3 tops out at 100 Hz, Prime/PrimeX 13 at 240 Hz.
- **eSync 2 output:** Recording Gate.

---

## Not yet decided

- **Acceptance criteria:** what error counts as good enough, per measure.
- **Reflective markers on the device:** how many, where, rigid body definition in
  Motive.
- **T5 (game):** now possible in principle (the recorder lives in the game), but not
  built: it needs Record to survive the change of scene into Random Reach.
- **T3** has not been run yet.

## Findings so far (device only, no mocap yet — 2026-09-21)

| | Result |
|---|---|
| Sample loss | Full T1 grid (whole table): 0 lost. Six T2 runs: 7 of ~20 000 (0.03 %). |
| Jitter while still | median 0.44 mm, 90th pct 1.06 mm (whole table) |
| Height error (physically 0) | median 0.09 mm |
| Cam0 vs cam1 disagreement | median 2.0 mm; worst at one corner / one edge of the table |
| Noise while moving (T2 fast) | ≈ 0.66 mm (3rd-difference RMS / $\sqrt{20}$) |
| Camera time offset | was 1.6–4.6 ms, **different every start-up**; now aligned to ~0.2–0.4 ms at start-up (see journal) |
| Fusion | today's averaging is the best of five methods while moving; the 6-DOF joint solve wins 35 % standing still but is unstable (ill-conditioned) while moving — off in the tracker |

Why two cameras help so little here: they are 75 mm apart at ~500 mm, 8.5° between
the views, so both are weak in the same (depth) direction; the device's own 250 mm
marker spread is a longer depth ruler than the 75 mm baseline. Next test: fit only
the 3 real unknowns (x, z, yaw on the table plane from `origin_lock.json`) to both
cameras' corners, offline, before any hardware change.

Analysis scripts (all offline, on the board): `analyse_holds.py` (per-place jitter,
drift, height, camera disagreement, `--png` map), `compare_fusion.py` (five fusion
methods; hold mode for T1, smoothness mode for T2), `check_board.py` (per-marker
consistency of `board_geometry.json`), `phase_test.py` (camera offset over time).
