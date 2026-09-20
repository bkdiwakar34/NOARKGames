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
| **T1** Static holds | Device still, 5 s per hold | 9 points (3 × 3 grid over the workspace) × 3 headings (≈ −30°, 0°, +30° yaw); whole grid done twice, re-placing the device | 54 holds | 1, 2, 3 |
| **T2** Continuous | Circles and figure-eights over the whole workspace, 30 s each | 3 speeds × 2 shapes × 2 repeats | 12 × 30 s | 4, 5 |
| **T3** Discrete reaches | Still → reach → hold, self-paced (no go cue) | 8 directions × 2 distances × 2 speeds (comfortable, fast) × 3 repeats | 96 reaches | 6, 7 |
| **T5** Real game | Random Reach, 3 min | 2 runs | 2 × 3 min | all, under real use |

(T4, rotations about each axis, was dropped: the device is planar.)

- Points and headings are **rough**. The mocap is the truth, so each hold is judged
  at whatever pose it actually has. Guidance is the live x, y, yaw readout in the
  recorder (§3), with no marks on the table.
- The go cue is not needed for measure 6:
  $\text{RT}_\text{dev} - \text{RT}_\text{moc} = \text{onset}_\text{dev} - \text{onset}_\text{moc}$.
- ~96 reaches gives a 95 % margin on each Bland–Altman limit of about
  $\pm 1.96\sqrt{3/n}\,s = \pm 0.34\,s$ ($s$ = SD of the differences).
- Holds and reaches within a recording are found automatically from the movement
  (still → moving → still) in both systems.
- Total ≈ 40 min of recording, one lab session.

### Naming

One recording per block; the **Motive take gets the identical name**.

`<date>_<trial>_<condition>_r<repeat>`, e.g. `2026-09-22_T1_grid_r1`,
`2026-09-22_T2_circle_slow_r1`, `2026-09-22_T3_fast_r3`, `2026-09-22_T5_game_r2`.

| Trial | One recording holds | Conditions | Recordings |
|---|---|---|---|
| T1 | a whole grid, 27 holds | `grid` | 2 |
| T2 | one shape at one speed | `circle` / `eight` × `slow` / `comfortable` / `fast` | 12 |
| T3 | one speed: 8 directions × 2 distances = 16 reaches | `comfortable` / `fast` | 6 |
| T5 | one game run | `game` | 2 |

The recorder builds the name from dropdowns (trial, condition, repeat) plus the date,
so a typo cannot break the pairing; it is typed into Motive by hand.

---

## 3. Recording on the device

### Recorder — in the game, not a separate program

**Godot installer (F10) → Validation recorder.** Name dropdowns (trial, condition,
repeat; the date is added), Record / Stop, and a live status: packets/s, markers per
camera, which camera(s) the pose came from, gate HIGH/LOW with the edge count, and
the device's x, z and yaw for placing it.

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
- **Wiring:** signal → **pin 15** (`GPIO_1`, `/dev/gpiochip4` line 1, checked
  `unused` with `gpioinfo` on 2026-09-19); ground → **pin 16** (GND).
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
| 1 | Workspace map: each T1 hold at its position, coloured by its error |
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
- **Recorder:** rebuilt inside Godot 2026-09-20, **not yet run on the board**.
  First run = a `T0_test` dry run, checking it holds 100 samples/s while recording.
