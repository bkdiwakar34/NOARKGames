# Work journal

A dated record of what was actually done. Written to be
readable months later, by you or by someone you hand the board to.

**How this differs from the other docs**

| Doc | Answers |
|---|---|
| [setup.md](setup.md) | "How do I set this up?" — the clean recipe, no history |
| **journal.md** (this) | "What did we do, and why is it like this?" — dated, with dead ends |
| [resume.md](resume.md) | "Where did I stop?" — one screen, overwritten each session |
| [weekly_progress.md](weekly_progress.md) | "What changed in the code?" — from git history |

New entries go at the **top**, under the date.

---

## 2026-09-23 to 09-25 — New tags, full recalibration, and the jitter explained

**Ended with:** everything recalibrated with new tag stickers and a new chessboard;
the joint fit made robust to one bad tag; `settings.json` cut from 49 keys to 17;
and a model that predicts the still jitter from the corner noise — it matches the
measurement (ratio 0.93). The remaining shimmer is corner noise, and the camera
arrangement is the biggest lever left.

### 1. New stickers and chessboard, recalibrated in order

- **Tags reprinted** (worn). Printed from `docs/markers.docx` at 100 % (Word:
  "No Scaling"); they measure about **50.0 × 49.5 mm** — the printer scales ~1 %
  differently along and across the paper feed. `MARKER_LENGTH` kept at 50.0 mm:
  expect ~0.5 % scale in distances (2–3 mm at 0.45–0.60 m). The mocap comparison
  fits and reports a scale factor for that (validation_plan §4.3b).
- **New chessboard: 13 × 9 squares of 30 mm** → 12 × 8 inner corners.
  `calibrate_camera.py` defaults changed; `--corners` / `--square-mm` added.
- Order: lenses → `calibrate_board.py` (only for the start layout and the grip
  point; its pair residuals of 5–9° / 5–9 mm and grip warnings up to 13.8 mm are
  the weak pairwise method, not the final result) → `calibrate_rig.py`: held-out
  error **2.61 → 0.70 px** (90th pct 4.40 → 1.10); tags moved 0–8.6 mm; cam1 moved
  1.30 mm, turned 0.42°.
- Lens results: cam0 fx 593.3, fy 597.7, cx 654.0, cy 418.8, fit **0.19 px**;
  cam1 fx 589.6, fy 592.9, cx 647.7, cy 383.8, fit **0.79 px** — 4× worse than
  cam0, worth redoing. Focal length ≈ 1.78 mm (3 µm pixels); Waveshare's "3.15 mm"
  contradicts its own 126° field of view. **fy is 0.6–0.7 % larger than fx on both
  cameras** — the size of the printer's error; check the chessboard with calipers
  both ways (10 squares = 300 mm).

### 2. Tracker changes

- **Robust joint fit** (`board.estimate_board_pose_dual_gn`, Huber loss at 1 px):
  a corner far off now pulls with weight 1/e instead of counting e²; frames are
  judged on the median corner error. Built-in default now.
- **Tag flicker counter** in `/tmp/tracker_timing.log` (`tag flickers: a+b`, and
  which tags: `cam1 flicker: 24x46/44 28x46/44`). Found: at one spot cam1 lost
  tags 24 and 28 **together** in ~45 % of frames; with the whole image searched it
  dropped to 0–4 — the **search box** loses them. Not fixed yet.
- **Debug preview**: both cameras, every tag with its ID, the search box drawn,
  box left on. (`debug_preview_box` removed.)
- **Tried and reverted**: fitting only x, z and yaw on the table plane (plane from
  the origin lock). The cursor froze in places — a real tilt or an inexact plane
  made the flat pose fail the fit check.
- **`settings.json` 49 → 17 keys**; decided values are now code defaults
  (joint solve, robust loss, both cameras, overlap, box margin 1.0, pairing 2 ms).
  The dead code behind removed options is still there, for after the validation.
- `rapidtag` (colleague's Rust AprilTag detector, PyPI) looked at: faster, but
  has **no sub-pixel corner refinement** yet, so not usable for us.

### 3. The jitter, measured and predicted (analysis scripts, not yet committed)

- `measure_sigma.py`: corner noise from still holds, **σ ≈ 0.30 px (cam0),
  0.34 px (cam1)**.
- `theoretical_error.py`: predicted pose error from σ with the tracker's own
  maths, Cov = σ² (JᵀJ)⁻¹ (sandwich form when the cameras differ).
- `compare_jitter.py` on `2026-09-24_T1_grid_r1` (98 still holds): measured
  **0.30 mm**, predicted **0.35 mm**, **ratio 0.93** (10th–90th pct 0.71–1.39) —
  **corner noise explains the jitter**; nothing else is shaking the pose.
- `compare_rigs.py`: same model for other arrangements. **Cameras 300 mm apart,
  turned 20° inward, cut the depth error roughly 2–3× over the workspace** against
  today's 76 mm parallel rig.
- `visibility_explorer.py/.html`: which tags each camera should see vs read.

So the levers left, in order: corner noise (light, refinement method, tag design)
and the camera arrangement. No filtering (user's decision).

---

## 2026-09-22 — Why the two cameras disagreed, and a calibration that makes them agree

**Ended the day with:** the tracker at 100 samples/s with 0 lost (search and solve
overlapped), ONE joint solve over both cameras' corners instead of averaging two
poses, and a new tag layout + camera-to-camera calibration fitted together from
both cameras. Cursor clearly steadier; a very slight shimmer remains. The camera
setup was moved so the device no longer comes right up to the cameras.

### 1. Do the cameras cover the whole table?

`analysis/coverage_markers.py` (new) sorts every tag a camera did NOT see into:
facing away / off the lens / cropped by the image straightening / edge-on / in
view but missed. On a full T1 grid (96 places):

- Both cameras saw the device at **every** place (lowest 86 % of samples).
- **Nothing was ever off the lens** (`sensor = 0`): the 160° lens covers the table.
- At the two near corners 3 tags per camera were **cropped by the straightening**:
  it drew a 1280 x 800 image with the lens's own focal length, which keeps only
  ~49° to each side of a lens that sees ~66°. A border setting
  (`undistort_pad_x_px`) fixes that — 489 px brought back ~40 % of those tags —
  but costs frames, so it is **0** for now.
- Near the middle of the near edge, tags in plain view were **missed** — the
  places where the pose jumped. Suspect (not tested): the tags are biggest there
  and the black/white window is a single 15 px (`adaptive_thresh_win_size`).

### 2. Camera placement, lens, exposure (worked out, nothing changed)

- `analysis/camera_placement.py` (new) re-scores the recorded device poses as if
  the cameras were moved back / up / re-aimed. The cameras sit at device height
  (10 mm above the grip plane), looking along the table. Moving back lowers the
  worst angle (57° -> 41° at 200 mm) but costs sharpness (jitter x1.37); moving up
  does nothing — the tags are on the device's sides.
- 160° lens: needed for the near corners (±61° across); the best possible other
  lens would be only ~8 % sharper.
- Exposure stays **5 ms** for now. For movements up to ~1 m/s (healthy reaching
  peaks ~1.1 m/s) 2–3 ms is the target, which needs ~2.5x more light. A
  colleague's recorder measured **44 % frame-to-frame brightness pulsing at 5 ms
  under 50 Hz room light** on this board. Plan: a non-dimmable 5 V USB COB LED
  strip above the cameras. **Not 850 nm infrared** — the OptiTrack works at 850 nm.

### 3. Camera time offset

The colleague's `dual_recorder_rcam.py` corrects ~50 ppm drift between the two
sensors' crystals. Ours: **0.3 ppm** over 120 s (offset stayed −0.1..−0.2 ms), so
the start-up alignment is enough. One real gap closed: a frame could be paired
with the other camera's frame up to 20 ms away — i.e. its *previous* frame, 10 ms
older (10 mm apart at 1 m/s). `stereo_max_frame_skew_ms` 20 -> **2**.

### 4. 100 samples/s, for real this time

The tracker's own timing line showed each pass needed **10–12 ms** of a 10 ms
budget: search 7.5–9 ms, then solve 2.5–3.3 ms, one after the other.
**Overlap** (`overlap_detect_solve`): the camera threads search frame N while the
main thread solves frame N−1. Result through Godot: **100/s, 0 missed**, main
thread waiting 0.1 ms for the search, ~7 ms spare per frame. Cost: each position
reaches Godot 10 ms later. Each camera now has its own worker thread.

- Dead end: `phase_test.py`'s "pairs per second" said 80–93 for old and new code
  alike — it measured the test harness, not a regression. **Check frame rate
  through Godot** (recording's missed frames, `/tmp/tracker_timing.log`).
- Still open: a camera that cannot see the device (a hand, a lens cap) searches
  its whole image every frame, and frames are lost.
- Still open: right up against the cameras the search box covers most of the
  image and the rate drops (~86/s). Worked around by moving the setup.

### 5. The jitter: the two cameras disagreed

`analysis/find_jumps.py` (new) finds every sample that jumps off the smoothed
path and checks what coincided with it:

- **T1: jumps up to 41 mm**, all alike — cam0 sees tags 24, 28, cam1 only tag 28,
  the two poses 51–57 mm apart, and the tracker keeps **cam1**. The averaging
  picked the camera with the lower fit error on disagreement and weighted by
  1/error²; a single tag's 4 corners always fit well, so the camera seeing FEWER
  tags — the least certain pose — won.
- T2 (moving): small jumps, twice as likely when the cameras were > 5 mm apart.

**Joint solve** (`"dual_solve": "joint"`): one pose fitted to all corners of both
cameras, each camera counting by its corners — no picking, no averaging.
First version dropped to ~12/s near the cameras. Checked offline
(`analysis/bench_joint.py`, new): the slow fitter was not the reason — the joint
fit **rejected 85 % of frames** on the T1 grid: no single pose fitted both
cameras there. The fast, standard version (`board.estimate_board_pose_dual_gn`,
derivatives written out) gives identical answers (0.000 mm on 69 583 fits), ~2 ms,
worst 8.5 ms instead of 44.

**Why no single pose fitted:** the tag layout (`board_geometry.json`) was
measured with ONE camera, pair by pair, and the camera-to-camera calibration was
built on top of it; nothing made them agree with both cameras at once.
`analysis/which_calibration.py` (new) pointed at the layout (tags 20, 24 worse in
both cameras alone).

**Fix: `calibration/calibrate_rig.py` (new)** — 60 s of moving the device in front
of both cameras, then one bundle adjustment: every tag's pose on the device
(tag 12 fixed), cam1 relative to cam0 and the device pose per frame, over every
corner of both cameras. Checked on frames the fit never saw:

| | median | 90th pct |
|---|---|---|
| old calibration | 1.26 px | 2.15 px |
| new calibration | **0.80 px** | **1.42 px** |

Tags moved 0.65–3.07 mm (28 the most; 20, 32, 24 next); cam1 moved 2.01 mm and
turned 0.31° (baseline 75.0 -> 76.1 mm). Old files kept as `*.before-<date-time>`.

### 6. Dead ends, kept for the record

- **`"pipeline": "raw_joint"`** (built, off): tags found on the raw fisheye image
  + one solve through the lens model. Two changes at once, not faster (89/s),
  jittery — tested before the calibration was fixed. Stays in the code, off.
  A live search-box view (`debug_preview_box`) exists for it.
- **Border 489 px**: brings back corner tags, costs frames. Setting kept, at 0.
- Several recordings were redone because the morning T1 grid was deleted.

### 7. Evening: why the tracker "did not open" after power-on

It started only after closing and re-opening the game a couple of times, and once
quit mid-session with "No UDP packets from Godot for 3 s — exiting". Not the
cameras (no driver errors; 100/s, 0 missed right up to it). `dmesg` audit stamps
showed the **wall clock jumping +8321 s** at 19:34:22: the board has no battery
clock and steps it when it gets online. The 3 s check used `time.time()`, so the
jump looked like 2 h of silence. Fixed on the monotonic clock (also the capture
times sent to Godot). Two more causes of failed starts, fixed too: the overlap's
first pass did not read Godot, so a set-up longer than 3 s (camera phase
alignment, up to ~14 restarts) tripped the check; and quitting the game killed
only the `bash` wrapper, leaving the tracker holding the cameras (`exec` now).
The camera driver now loads at boot (`/etc/modules-load.d/ov9282.conf`).

Recorder checked for the lab: T1 dots cover the table, T2 pacer right (fast =
lap 6), T3 works (32 labels). Decided: no tracker changes before the validation;
jitter work (light, corner method, display-only One Euro filter) after it.

### 8. Housekeeping

`pyscripts/` reorganised: the tracker stays at the top (Godot starts it there);
`calibration/`, `analysis/`, `diagnostics/` hold the rest. `tools/` and
`diagnose_jitter.py` deleted (in git history). New: frame bank recorder
(`diagnostics/record_frames.py`, 11 spots of raw frames, unused so far).

---

## 2026-09-21 — The recorder in use, and why two cameras help so little

**Ended the day with:** a finished recorder screen (T1, T2, T3), a full-table T1
grid and six T2 runs recorded with almost no lost frames, the two cameras' frame
timing aligned at start-up, and a clear answer to "why isn't the second camera
better?". No mocap yet — everything below is the device on its own.

### 1. The recorder, made usable

Each problem was found by actually doing a trial:

- **Folder name lost its last character** (`…_r` instead of `…_r1`): the tracker read
  Godot's commands into a 30-byte buffer. Now 256.
- **Holds started before the hand settled**: the ring began filling on entering the
  circle. Now **space** starts a 3 s hold; **backspace** redoes the last one. A
  "did it move?" check was proposed and dropped — it would judge the tracker by its
  own output, so marker noise could abort a good hold.
- **Space stopped the recording**: Godot's focused button ate the key. Buttons no
  longer take focus.
- **No mapping from samples to places**: added `marks.csv` — every hold start/end
  with the tracker's clock and the `samples.csv` row, so place 7 is exactly rows
  1204–1504, not a guess.
- **Only the middle of the table was measured**: targets were inset 7 % sideways and
  22 % top and bottom, i.e. 56 % of the depth. Now 4–5 %, whole table.
- **Text sat on top of the dots**: every control now hides while recording; Escape
  stops.
- **T2 had no shape and no pace**: now a red **pacer dot** runs along a circle or
  figure-eight at a set speed on the table (the 4-corner calibration converts mm/s to
  pixels), with a 3 s lead-in and an automatic stop at 30 s. Speeds tuned by trying:
  **100 / 200 / 300 mm/s**. Lap counts came out 2 / 4 / 6 — exactly proportional,
  which confirms the pacer's speed.
- **Repeat numbers ran on across conditions** (first recording of each was `r5`):
  now reset per condition.

### 2. Frames: from 4.6 % lost to none

| Change | Why |
|---|---|
| Rows flushed twice a second, not per row | 100 flushes/s cost ~3 frames per 40 s |
| CSV writing moved to a writer thread | the loop used 9.95 of its 10 ms *before* writing, and the writing was outside the measured window |
| Search-box margin capped at 120 px (`roi_margin_max_px`) | the margin is one marker width, ~300 px close to a camera, so the box approached the full frame exactly there |

Result: full-table T1 grid **0 lost** of 64 524; six T2 runs 7 of ~20 000.

### 3. The sync pin moved: 15 → 35

With nothing connected, pin 15 read HIGH — the board pulls it up harder than the
chip's pull-down. A cable fault would then look like "Motive recording". Every free
pin was read with `gpioget -B pull-down`; **header pin 35** (line 100) idles LOW,
ground next to it on **pin 34**.

### 4. Why doesn't the second camera reduce the jitter? (the long part)

- **Joint solve** (one pose fitted to both cameras' corners): −35 % jitter standing
  still (0.72 → 0.47 mm), but live it cost ~1 ms the budget lacked (100 → 85/s) and
  gave a jittery trail. Off.
- **Camera timing**: the two cameras were 1.6 ms apart in one recording and 4.6 ms in
  the next. Cause: both run at exactly the same rate but start one after the other,
  so `offset = (start gap) mod 10 ms`. **Fix:** at start-up the tracker measures the
  offset and restarts cam1 until it is under 0.5 ms (after discarding 10 frames each
  time — without that, the first fix measured an unsettled camera and did not hold).
  Now **~0.2–0.4 ms**, steady (`phase_test.py`). Hardware sync was not possible:
  these Waveshare modules don't bring the sensor's FSIN pin out.
- **Even with aligned cameras the joint solve is unstable while moving**: `joint` and
  `joint_corr` differed 2× in smoothness on nearly identical input while fitting the
  images equally well — an ill-conditioned fit, sliding along a depth–tilt valley.
- **Board geometry** (`check_board.py`): the three wing markers 24, 28, 32 agree least
  (matches the 2026-09-18 calibration's weak pairs), but dropping them raised jitter
  0.470 → 0.532 mm. Not the limit. (The first version of this script had a bug —
  IPPE_SQUARE fed board-frame corners — and reported 130–220 mm; fixed.)
- **The reason:** the cameras are 75 mm apart at ~500 mm, **8.5°** between the views,
  so both are weak in the same direction (depth). As depth rulers, the device's own
  250 mm of markers beats the 75 mm baseline: $\sigma_\text{depth} \approx
  \sigma_\text{side}\,Z/S \approx 2\sigma_\text{side}$ from the device, against
  $\sigma_\text{side}\,Z/B \approx 6.7\sigma_\text{side}$ from stereo. Two near-identical
  views can at best give $1/\sqrt{2}$. The eyes are the same geometry (63 mm, 7.2°) —
  they manage because their angular precision is ~3× finer.
- **What would help:** fit only the 3 real unknowns (x, z, yaw on the table plane)
  to both cameras' corners — removes exactly the directions the cameras can't agree
  on; or mount the cameras 60–90° apart (≈ 0.6–1 m, needs longer CSI cables).

### 5. Numbers so far (whole table, no mocap)

Jitter while still median 0.44 mm; height error 0.09 mm; noise while moving ≈ 0.66
mm; cam0-vs-cam1 disagreement median 2.0 mm, worst in one corner.

---

## 2026-09-20 — A new goal: validate the device against motion capture

**Goal changed.** The July list (data audit → healthy-user test → analysis script) is
on hold. Before the data means anything, the device has to be checked against the
lab's OptiTrack system. This entry is the decisions and the build; the protocol
itself lives in [validation_plan.md](validation_plan.md) and is the file to read.

### 1. What we decided, and why

The plan doc has the detail. The choices worth remembering here:

- **Motive drives the sync, not us.** The eSync 2 sends a "Recording Gate" — high
  for the whole take — into a Dragon GPIO pin (pin 15 that day; moved to pin 35 on
  2026-09-21, see that entry). The kernel
  stamps each edge on the same clock the camera frames carry, so the alignment error
  is microseconds instead of the 8.3 ms of waiting for Motive to react to a pulse
  from us. Both edges are logged, so the two clocks' drift (up to 30 ms over 10 min
  at 50 ppm) can be scaled out.
- **3.3 V both sides** (OptiTrack's docs and Radxa's), so the wire connects directly.
- **Save the raw marker corners, not only the pose.** Then cam0 alone, cam1 alone,
  today's pose averaging and a proper joint solve can all be recomputed offline from
  the same recording and compared against the mocap. The mocap decides which is best;
  no re-recording.
- **Save both cameras' capture times.** The cameras are not triggered together, so
  the paired frame can be up to 5 ms away; during movement that biases the fused
  position by about 2.5 mm at 1 m/s. The first recording measures the real offset.
- **The device is planar** (it slides on a table), so a rotations trial was dropped.
  Height and tilt are physically constant, which makes any change the tracker reports
  in them a free error measurement.
- **Vigour** is defined in the literature as peak speed divided by the speed expected
  for that reach distance. Both parts come from position, so the validation checks
  peak speed and amplitude per reach and leaves the definition to the analysis.

### 2. Tracker cleanup before building anything

Removed what never runs on this board (409 lines): the smoothing filters and all of
`filters.py` (`filter_type` has been `"none"` since the rigid-body solve), the
corner-stability pose reuse (threshold `0.0` — it never triggered), the tracker's own
`Time,X,Y,Z` CSV (it only started on a `USER:` command Godot never sends), the
detect-on-raw-frame option, and the START/RESET packet codes. The code slot in each
packet stayed, at `2.0` — which turned out to be useful hours later (see below).

Still to go, and deliberately not done until the recorder is proven on the board:
the per-marker solver, the `SETUP:` demo switch, single-camera mode,
`diagnose_jitter.py` (broken here anyway — it opens the camera through picamera2),
and `tools/`'s jitter harness.

### 3. The recorder, built twice

**First version: a standalone Python window** (Tk) that ran the tracker in its own
process. It worked, but it ran at **50 samples/s**. Pinned to the fast cores
(`taskset -c 4-7`) it reached **80–93**, still not 100, and the number was the same
whether it was recording or not — so the cost was the window's own process, not the
file writing.

**Second version: the recorder moved into the game**, where the split already
measured at exactly 100/s stays intact:

| | Cores | Does |
|---|---|---|
| Godot | 0–3 | the screen: name dropdowns, Record/Stop, live status |
| Tracker | 4–7 | tracks, writes the files, watches the sync pin |

Godot sends `REC_START:<name>` / `REC_STOP` with its existing 100 ms keepalive and
**repeats the command until the tracker's status agrees**, so a lost packet cannot
leave the two disagreeing. The tracker sends a status packet back twice a second —
told apart from position samples by that leftover code slot: `2.0` = sample,
`7.0` = status. Opened from the installer (F10) → **Validation recorder**.

`recorder.py` was deleted; its file-writing and sync-pin code live in
`pyscripts/recording.py`. Not yet run on the board.

### 4. Repo clean-up

- `.conda` (156 MB): a Python environment VS Code once created here; nothing used it.
- `rcam/.venv` (481 MB) and `rcam/target` (282 MB): build output for **this** machine,
  never in git, never used here since code only runs on the board. 861 MB → 98 MB.
- `debug.json`: `{"debug":true}` from the original codebase; nothing has ever read it.
  The real flag is `settings.json["debug"]`.
- `.python-version`: 3.11 → 3.13, which is what `rcam` needs.
- Stale claim in setup.md that `main.py` still carries the Pi's picamera2 path.

---

## 2026-09-19 — Checking the camera-to-camera calibration; monitor from 60 to 100 Hz

**Goal:** two checks before the data audit. Is the camera-to-camera calibration
really right? And does Godot's screen rate limit the data?

**Ended the day with:** the calibration matches the ruler, the screen now runs at
100 Hz like the tracker, and a 66 s session still saved every sample.

### 1. Is the camera-to-camera calibration good?

`calibrate_stereo.py` works out where cam1 (CAM3) sits relative to cam0 (CAM2): a
shift $t_x$ (mm) and a turn $R_x$. The number it prints at the end (yesterday
0.32° / 1.72 mm) only shows that the ~20 held poses **agreed with each other**. It
is graded on the same poses that built it, and it would not notice an error that
every pose shares. So we checked the result against the physical mount instead.

Printed from `stereo_extrinsics.json` (command in [setup.md §3c](setup.md)):

| | Value | Meaning |
|---|---|---|
| $x, y, z$ | 74.9, −2.1, 3.0 mm | cam1 is 75 mm to the side, 2 mm higher, 3 mm forward |
| distance | $\sqrt{74.9^2 + 2.1^2 + 3.0^2} = 75.0$ mm | |
| turn | 1.6° | the cameras point almost the same way |

A ruler between the lens centres agreed. **Verdict: good.** This is a coarse check;
it would catch a badly wrong calibration, not a 1 mm one.

Not done yet, and the stronger test: hold the device at new places and compare
cam0's position with cam1's position converted into cam0's view. `main.py`
already computes that gap every frame (`_fuse_board_poses`) but does not save it.

### 2. Does Godot's screen rate limit the data? No.

Godot has two separate rates:

- **Screen:** redraws once per monitor refresh.
- **Data:** a separate thread receives every tracker packet as it arrives; each
  screen frame then writes **all** waiting samples to the CSV. At 60 Hz that is
  $100/60 \approx 1.67$, so 1 or 2 samples per frame, none lost.

What the screen rate *does* limit: how often the cursor moves, and the precision of
game event times such as `outcome_time` ($1/\text{fps}$ seconds).

### 3. The monitor was running at 60 Hz, not 100

The Trace test showed `fps: 60`, although the monitor supports 100 Hz. Nothing in
the project caps the frame rate. The OS was simply driving the monitor at 60 Hz.

- Dead end: `xrandr` showed only `1920x1080 59.96*`. Under Wayland it lists just
  the current mode, so it cannot show what else the monitor supports.
- Fix: GNOME Settings → Displays → Refresh Rate → 100 Hz.

Could this slow the tracker? Drawing 100 frames/s instead of 60 is more work for
Godot, but Godot runs on cores 0–3 and the tracker on 4–7, so they don't compete.

**Verified:** Trace test `fps: 100`, `rx: 100 pkt/s`; a 66 s Random Reach session
had **6629 gaps between samples, every one 10 ms** ($6629 \times 10$ ms $= 66.29$ s,
0 lost).

---

## 2026-09-18 — Calibration, and the tracker from 39 to exactly 100 samples/s

**Goal:** finish setting the rebuilt Q6A up (calibration), then find out — and
push — the real sampling rate of the whole system.

**Ended the day with:** all four calibrations done; every camera frame, 100 per
second, recorded in the hand CSV with the time it was captured. Verified: a 64 s
session had 6446 gaps between consecutive samples and **every one was 10 ms**.

### 1. Calibration — all four, from scratch

Nothing survived the reinstall, and it turned out `camera_calib.toml` had never
been in git either (it is git-ignored, like the others). Order matters, because
each step uses the one before:

| Step | Command | Result |
|---|---|---|
| CAM2 lens | `python pyscripts/calibrate_camera.py --backend rcam --cam-id CAM2` | fit 0.33 px; 5 of 6 test poses 0.11–0.21 mm |
| CAM3 lens | `... --cam-id CAM3 --output camera_calib_1.toml` | fit 1.44 px, but test poses 0.12–0.34 mm (the test is what counts) |
| Device (marker positions) | `python pyscripts/calibrate_board.py --backend rcam --cam-id CAM2` | worst marker 4.2 mm (limit 5); pairs 24–28 and 12–32 weak both runs |
| Camera to camera | `python pyscripts/calibrate_stereo.py` | 0.32° / 1.72 mm (July: 0.75° / 6.68 mm) |

Forgetting `--output camera_calib_1.toml` on the CAM3 run silently overwrites CAM2's
file. The device calibration only needs one camera — it measures the device, not
the lens.

**Dead ends worth remembering:**

- Running a calibration script **over SSH** fails with `could not connect to display`
  — the script opens a live window. Run it in a terminal on the board itself.
- CAM2's first test showed one pose at 2.80 mm and a max error of 24.32 mm. That
  max is almost exactly one square (24.35 mm): the detector mislabelled a row of
  corners in that one frame. A lens problem cannot produce an error of exactly one
  square, so the calibration was kept.
- **The stereo step would not capture at all.** Two causes. (a) Its "is the device
  still?" check compared markers by list position, and the detector does not list
  markers in a fixed order — the same markers reordered looked like hundreds of
  pixels of movement. The script was made standalone with its own check that
  matches markers by ID. (b) In room light the picture is dark (average pixel
  40/255) and noisy, so corners jitter past the 2 px limit even with the device
  still. A lamp beside the cameras, plus a 4 px limit, fixed it. **Gain does not
  help here** — it brightens the noise too.
- Marker pairs 24–28 and 12–32 came out weak in both device runs whatever the
  technique. Something that survives a change of technique is usually physical — a
  marker not quite flat, or two faces never seen square-on together. First place to
  look if tracking jumps when marker 32 or 28 faces a camera.

**Also fixed on the way:** the board clock was on UTC (5 h 30 min behind) —
`sudo timedatectl set-timezone Asia/Kolkata`. Session CSVs are timestamped with it.

### 2. What limits the sampling rate — measured, stage by stage

A sample passes through: camera → cable → `rcam` unpacking → tracker → UDP → Godot
→ CSV. The recorded rate is the slowest stage.

| Stage | How measured | Result |
|---|---|---|
| Camera sensor | `python rcam/bench.py` | ceiling **120.6 fps** per camera; set to 100 |
| Cable | arithmetic from the overlay: 2 lanes × 800 Mbit/s = 1.6 Gbit/s | needs 1.23 at 120 fps — not a limit |
| `rcam` unpacking | `bench.py`, rcam rows | 120.5 fps, 0 dropped — not a limit |
| Tracker | `/tmp/tracker_timing.log` | **39 fps** — the bottleneck |
| Godot → CSV | rows per second in the hand CSV | one row per tracker sample — not a limit |

Measuring the tracker: with `"debug": true` and `"debug_preview": false`, it writes
one line per second to `/tmp/tracker_timing.log` — the time per stage, and how many
frames it processed that second. Run the game, play a minute, then
`tail -20 /tmp/tracker_timing.log`. Baseline: remap (undistort) 7.7 ms + detect
16.6 ms + pose 2.1 ms = 26.4 ms per frame → 1000 / 26.4 ≈ 39 fps. Of every 100
frames the cameras took, 61 were never used.

### 3. Getting the tracker to 100

Each step was measured on the board before the next. Two faster options were
**rejected on purpose** because they change what the detector computes, and
checking accuracy is hard: OpenCV's built-in downscaling (Aruco3), and detecting on
the raw fisheye picture. Everything below keeps the per-pixel work identical.

| Step | What it does | Result |
|---|---|---|
| Per-frame labels in `rcam` | the kernel's frame sequence number + capture time now come with each frame (`capture_with_meta()`); needs the Rust rebuild | frames verifiably 10.0 ms apart, none skipped |
| Two cameras at once | each camera's undistort + detect on its own worker thread | 39 → 57 fps |
| Pin to cores | tracker on the four fast cores (cpu4–7, A78), Godot on the slow ones (cpu0–3, A55) — `tracker_cpu_affinity: "4-7"` and `taskset -c 0-3` on Godot | rate much steadier (56–58 instead of 34–45) |
| Search box | undistort and search only a box around the device, full picture only when the box finds nothing, plus once a second | ~100 fps |
| No repeats | the tracker had started outrunning the camera and re-processing the same frame (up to 145 "frames" a second) — now it waits for a frame it has not seen, using the sequence number | repeats gone |
| Box around the whole device | the box first covered only the markers seen, so an edge-on marker flickering in and out triggered full searches (up to 19/s per camera, each costing a frame); now all 8 markers are projected from the pose | full searches down to the 1/s refresh |
| Margin 2 → 1 marker width | 1 width = 50 mm of movement per frame, 2.5× the 20 mm a very fast (2 m/s) hand moves in 10 ms | close-up frames back under 10 ms |
| 3-frame queue | a slow frame delays the next ones instead of letting them be overwritten | no frames dropped |
| Capture time into the CSV | sent to Godot as a float64 in a 24-byte packet (a float32 cannot hold a Unix time); new last column `capture_time` in the hand CSV | every sample on the camera's 10 ms grid |

The core rule behind all of it: **the tracker has 10 ms per frame at 100 fps.** If a
frame's work takes W ms and W is over 10, the tracker processes 1000 / W frames a
second and misses the rest — e.g. W = 11.14 ms gives 90 processed, 10 missed, which
is exactly what the log showed.

**Checking the recording** (on the board, after a session):

```bash
f=$(ls -t ~/Documents/NOARK/data/*/GameData/RandomReachHand_* | head -1)
# samples per second, by capture time (column 8): expect 100
grep -E '^[0-9]{10}' "$f" | cut -d, -f8 | cut -d. -f1 | uniq -c | tail -20
# gaps between consecutive samples, in ms: expect only 10; a 20 is a lost sample
grep -E '^[0-9]{10}' "$f" | cut -d, -f8 | awk 'NR>1{printf "%.0f\n", ($1-p)*1000} {p=$1}' | sort -n | uniq -c
```

The occasional second with 99 samples is the camera itself: its frames are 10.03 ms
apart (99.7 fps), not exactly 10.

**Other things fixed on the way:** calibration scripts and `bench.py` now set every
camera setting themselves (settings persist on the sensor after a program exits, so
programs were inheriting each other's); registration of a new patient now goes to the
game chooser instead of the old v2 session screen.

### Open after today

1. One deliberate close-up run — the smallest marker size seen was 61 px and the
   largest 75 px; the very closest positions have not been checked against the
   10 ms budget.
2. Back up the four calibration files off the board.
3. Auto-load `ov9282` at boot (still a manual `sudo modprobe ov9282`).
4. The **■ Stop** button in the game is visible to patients and leads to the
   researcher's graph and settings page — decide: hide it outside installer mode, or
   leave it.
5. Back to the July agenda: data audit, healthy-user test, analysis script — which
   can now use `capture_time`.

---

## 2026-09-17 — Rebuilding the Dragon Q6A from bare metal

**Goal:** get the Q6A running again after its storage was replaced, and split the
project into per-board repos.

**Ended the day with:** board booting from SSD, both cameras capturing, two repos
live. Calibration and Godot still to do.

### Background: why the board was dead

The Q6A used to freeze 10–15 s into a session. Long debugging in July traced it to
the board's built-in UFS storage chip locking up — not our code (proved by running
Godot alone with `pyscripts/` renamed away; it still froze, and `dmesg` showed
`ufshcd_err_handler ... task management cmd timed-out`). The fix was physical:
remove the UFS module, run from an SSD. That left the board with no operating
system at all, which is where today started.

### 1. Splitting one repo into two

The project had been one repo serving both the Raspberry Pi and the Dragon. We
split it so each board can be customised without the other's changes colliding.

```bash
git tag -a pre-split -m "..."     # bookmark of the last single-repo commit
git push origin pre-split
git clone <old repo> NOARKGames-pi   # full history, then strip each side
```

| Repo | Board | Visibility |
|---|---|---|
| `NOARKGames` | Dragon Q6A | public |
| `NOARKGames-pi` | Raspberry Pi | private (needs a deploy key on the Pi) |

Both keep the shared history up to `pre-split`, and each has the other as a git
remote, so a fix that belongs on both moves across with `git cherry-pick`.

`pyscripts/main.py` was deliberately **not** split — the Pi and Dragon camera
code still sit in both copies, because neither board could run the code that day.

### 2. Writing the operating system to the SSD

The board has no OS of its own, so a microSD card was used as a stepping stone.

An **image** (`.img`) is a byte-for-byte copy of a whole disk — partition table,
boot files and all — not a folder of files. That is why you cannot simply copy
files onto a blank card and boot it. `.xz` is compression on top.

Radxa publishes two builds; the difference matters:

| File | For |
|---|---|
| `..._noble_gnome_r2.output_512.img.xz` | microSD, USB, **NVMe SSD** — use this one |
| `..._4096.img.xz` | UFS only |

Written to the card from Windows with Raspberry Pi Imager: **Choose OS → Use
custom**, and at the customisation prompt, **No, clear settings** (those settings
are Raspberry Pi-specific and meaningless to this image).

Then, booted from the card, the same image was written to the SSD:

```bash
wget https://github.com/radxa-build/radxa-dragon-q6a/releases/download/rsdk-r2/radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz
lsblk                                   # confirm the SSD is nvme0n1, NOT the card
xzcat radxa-...output_512.img.xz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo poweroff                           # then remove the card and boot
```

`xzcat | dd` is what an imaging tool does, spelled out: uncompress, and write the
bytes straight to a disk. `conv=fsync` forces everything out before `dd` exits, so
no separate `sync` is needed. `dd` writes to whatever you name it — check `lsblk`
first, every time.

Confirm afterwards which disk you booted:

```bash
findmnt /        # /dev/nvme0n1p3 = the SSD
```

**Keep the microSD card.** It is now the rescue boot if the SSD ever fails.

### 3. Dead ends worth remembering

- **The UEFI countdown.** "Press ESC to skip `startup.nsh` **or any other key to
  continue**" — "continue" there means continue *into the firmware shell*, not
  continue booting. Press nothing.
- **Typing `exit` in that shell** leaves the firmware with nothing to boot and it
  offers to shut down. Power-cycle and let the countdown run out.
- **The old microSD card** held a Raspberry Pi image. A Pi image will not boot this
  board; the firmware's boot menu listed the card but nothing came of selecting it.
- **A dying card.** Writing an image to one particular card made it disappear from
  Windows the instant the write began — reading works, writing does not. Replaced.
- **Cloning over a phone hotspot** failed twice mid-transfer (`RPC failed ... early
  EOF`). Fixes, in order of usefulness:
  ```bash
  git clone --depth 1 <url>              # latest snapshot only, far smaller
  git config --global http.version HTTP/1.1
  git config --global http.postBuffer 524288000
  ```
  HTTP/2 gives up entirely when the link stutters; HTTP/1.1 tolerates it. Later a
  hotspot reconnect was what finally let it through.

### 4. Getting SSH working (stop typing on the board)

```bash
# on the board
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
hostname -I                      # 10.158.152.4
```

```powershell
# on Windows — PowerShell has no ssh-copy-id, so append the key by hand
Get-Content $env:USERPROFILE\.ssh\noark_q6a.pub | ssh radxa@10.158.152.4 `
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -i $env:USERPROFILE\.ssh\noark_q6a radxa@10.158.152.4
```

Passwordless `sudo` was also enabled so remote commands do not stall on a prompt.
It is a development-board convenience, undone with
`sudo rm /etc/sudoers.d/010_radxa-nopasswd`:

```bash
echo 'radxa ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/010_radxa-nopasswd
sudo chmod 440 /etc/sudoers.d/010_radxa-nopasswd
```

### 5. Building the software stack

Full commands are in [setup.md §2–3c](setup.md); the short version and the
reasoning:

- **System packages** — `build-essential clang libclang-dev` for the Rust build,
  `linux-headers-$(uname -r)` to compile the sensor driver, `device-tree-compiler`
  for `dtc`/`fdtoverlay`, `v4l-utils` for `media-ctl`. The last three were missing
  from the old setup doc and each cost time today.
- **Python** — the image ships 3.12; `rcam` needs 3.13. Installed alongside with
  `uv python install 3.13`, never replacing the system one (the desktop is built
  against it).
- **One venv, not two** — `uv pip install -e ./rcam` from the project venv. The old
  doc's `cd rcam && uv sync` builds a second environment that `main.py` cannot
  import from.
- **Do not run `apt upgrade`** on a working board: 414 packages were pending, and a
  new kernel would break the out-of-tree camera driver and the overlay. Upgrade
  deliberately, then re-test the cameras, with the card as fallback.

### 6. The cameras — the hard part

Two things must exist before Linux sees these cameras: a **driver** (code that
knows how to talk to the sensor) and a **device-tree overlay** (a description
telling the system that two such sensors are attached, on which bus, powered by
which pin). These sensors cannot announce themselves, so without the description
nothing is found — the driver just sits loaded with zero users.

```bash
cd ~/Documents/NOARKGames/rcam/ov9281
make -C module
sudo install -D -m0644 module/ov9282.ko /lib/modules/$(uname -r)/updates/ov9282.ko
sudo depmod -a && sudo modprobe ov9282
```

**What changed since July:** the newer RadxaOS image has a supported overlay
system. `/boot/uEnv.txt` and `/boot/hw_intfc.conf` now just say "retired — use
`rsetup`", `/boot/dtbo/` holds every stock overlay as `*.dtbo.disabled`, and the
boot entry (`/boot/efi/loader/entries/RadxaOS-*.conf`) has **no `devicetree`
line** at all — the firmware supplies its own tree.

So `scripts/deploy_efi_dtb.sh` fails: the file it wants to patch does not exist.
The route that works:

```bash
sudo cp overlay/qcs6490-radxa-dragon-q6a-dual-ov9281.dtbo /boot/dtbo/
sudo rsetup     # Overlays → Yes → Manage overlays → tick the OV9281 line
                # → Ok → Rebuild overlays → exit
sudo reboot
```

Copying the file is not enough on its own — the first attempt did exactly that and
the overlay was ignored at boot (`/proc/device-tree` had no camera node). It took
`rsetup`'s **Rebuild overlays** step for the firmware to pick it up.

Before rebooting, an overlay can be checked against the running firmware tree:

```bash
sudo cp /sys/firmware/fdt /tmp/base.dtb && sudo chmod 644 /tmp/base.dtb
fdtoverlay -i /tmp/base.dtb -o /tmp/merged.dtb overlay/...dual-ov9281.dtbo
dtc -I dtb -O dts /tmp/merged.dtb | grep -c 'ovti,ov9281'    # 2
```

**Verification chain, and what each step rules out:**

```bash
ls /dev/media*                                           # /dev/media0 = pipeline exists
v4l2-ctl --list-devices                                  # video0/1 are the Venus encoder, not cameras
python -c "from rcam import list_cameras; print(list_cameras())"   # ['CAM2','CAM3']
python rcam/main.py                                      # cam2.png + cam3.png
```

Result: `CAM2: (800, 1280) uint8 min=10 mean=40.0 max=255`, same for CAM3. Both
images looked correct.

`sudo modprobe ov9282` is still needed after every boot — making it automatic is
still open.

### 7. Godot, and the first code change

Godot 4.5 for ARM64, installed on the board (the project targets 4.5 — do not let
a newer one in without testing):

```bash
cd ~/Downloads
wget https://github.com/godotengine/godot/releases/download/4.5-stable/Godot_v4.5-stable_linux.arm64.zip
sudo apt install -y unzip && unzip -o Godot_v4.5-stable_linux.arm64.zip
chmod +x Godot_v4.5-stable_linux.arm64
./Godot_v4.5-stable_linux.arm64 --version      # 4.5.stable.official
```

Then the cut deferred from the morning: `pyscripts/main.py` still carried the
Raspberry Pi's camera code, which cannot run in this repo. Out went
`_init_rpi_camera` (picamera2), `_init_camera` (a Windows `cv2.VideoCapture` dev
fallback), the `picam2` attribute, their branches in `_capture_single_frame` and
`_init_camera_backend`, and the `platform` import.

The pipelined capture+undistort worker went with them. Its own comment explained
why: it was restricted to the picamera2 single-camera path, because rcam already
runs its own capture thread. On this board `_pipelined` could only ever be
`False`, so `process_frame` had a second path through it that never executed. The
dead `"pipeline"` key came out of `settings.json` too.

`_init_camera_backend` now raises a clear error on a non-rcam `camera_backend`
instead of quietly trying a Pi camera that does not exist.

**147 lines out; 1266 → 1153.**

> **Not yet run.** Commit `cc2193c`'s message says it was "verified by running the
> tracker on the board" — that is wrong. The board dropped off the hotspot before
> the test, and by then the commit was pushed; rewriting it would have left the
> board's checkout out of step, so the correction lives here instead. The file
> compiles and `settings.json` parses, but `process_frame` has not executed since
> the change. **Run the tracker once before trusting it.**

### Where the work stopped

The camera rig does not exist yet — the cameras are connected but not mounted, so
they cannot see the markers. Nothing further can be verified until that is built,
which is why the remaining refactor (splitting `main.py` into capture / pose /
stream modules, and moving the calibration and one-off scripts into subfolders)
was left undone rather than stacked untested on top of today's cut.

### Open after today


1. **Build the camera rig** — mount both cameras in their final position. Everything
   else waits on this.
2. **Run the tracker once** to verify today's strip (`cc2193c`), before any further
   refactoring.
3. **Calibration from scratch** — no backups of `camera_calib_1.toml`,
   `board_geometry.json` or `stereo_extrinsics.json` survived the reinstall.
   Order: `calibrate_camera.py` per camera (needs a 9x6 chessboard, 24.35 mm
   squares) -> `calibrate_board.py` -> `calibrate_stereo.py`, the last only once the
   cameras are in their final mount. **Back them up off the board this time.**
4. Auto-load `ov9282` at boot (still a manual `modprobe` every reboot).
5. Finish the pyscripts refactor: split `main.py` into capture / pose / stream, and
   move calibration and one-off scripts into subfolders.
