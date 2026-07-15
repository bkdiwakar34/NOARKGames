# NOARKGames — V1 Plan

The reference document for building v1: the version a stroke patient can use alone at home
for the 2-week study. Agreed 2026-07-15. Change this document first, code second.

Companion docs: [design.md](design.md) (architecture + adaptive algorithm), [setup.md](setup.md)
(hardware + calibration), [todo.md](todo.md) (tracker-side open work).

---

## 1. Product statement

A kiosk. The patient switches it on, a game chooser appears, they pick a game with two
physical buttons, they play, they switch it off whenever they want. Nothing to log into,
nothing to configure, nothing they can break. Everything requiring skill happens with the
researcher present; everything that happens without the researcher requires none.

---

## 2. Decisions log (locked for v1)

| Decision | Choice | Why |
|---|---|---|
| Who operates it at home | Patient alone, no caregiver assumed | Study is home-based after Day 1 |
| Session dose | Full freedom, no software nudging | Adherence is the dependent variable; encouragement happens by call/message, outside the software |
| Game selection | 2 physical arcade buttons (GPIO): "next" cycles, "play" starts, hold "play" ~3 s exits | One-hand friendly, no cursor precision needed, scales to more games |
| Power-off | Any time, including mid-trial | Data must be complete without clean shutdown → flush every row |
| Patient feedback | Per-target catch/miss effects + 5-star trial screen; background music tried and removed 2026-07-15 (annoying in testing — re-enable is one line if a real track changes the verdict) | Chosen by researcher |
| Star fill rule | Caught / spawned (success ratio) | Deliberate: the controller holds this ≈ constant, so feedback is a warm ritual, not a performance signal — keeps feedback from confounding the challenge→motivation study. Revisit after study 1. |
| Patient-facing language | English, near-zero text | Aphasia-aware design: icons + sound carry meaning; the few words translate cheaply later |
| Visual identity | "Calm Orchard" (mockup approved 2026-07-15): dawn-sky gradient + sage hills on patient screens, warm-brown ink, apple-red accent, Nunito font (drop-in), flat warm paper for the installer | Interface lives in the game's world; calm and readable for older patients |
| Game display name | "Apple Harvest" (was "Apple Catch"); internal/log name stays RandomReach | Warmer, adult; log name frozen for data continuity |
| Researcher interface | Hidden installer mode in the same app (not separate software) | Setup needs the live tracker + game stack; one deployment; kiosk-industry standard |
| Day's target success rate | Read automatically from the patient file (pre-sampled 14-day schedule per design.md §1) | Nobody is present at home to set it |

---

## 3. Patient experience

### Screens (the only four the patient ever sees)

1. **Boot splash** — logo + "starting…". Power-on never shows a desktop or console.
2. **Chooser** — one giant card per game (picture + name). Highlighted card visibly
   bigger/brighter. Bottom strip: the two physical buttons as icons with their meaning.
3. **Game** — play area, score counter, nothing else. All researcher overlays (debug label,
   Fitts plot, stop button, end-of-session graph) move behind the researcher flag.
4. **Star screen** — after each 1-minute trial: five stars fill left-to-right, one per beat,
   with sound; big "Well done"; auto-continues into the next trial.

Plus one designed system state: **tracker signal lost** → soft pause, friendly one-liner +
picture ("place the handle back on the table"), self-recovering. No error codes, ever.

### UI design system (one theme file, every screen reads from it)

- **Palette:** warm/calm (cream background, one accent). Catch and miss each get a fixed
  color **plus** a fixed shape and sound — meaning never carried by color alone.
- **Type:** two sizes only — huge and large. If text must shrink to fit, the screen is
  overloaded.
- **Motion language:** catch = bright, fast, upward (burst + ascending sound); miss = soft,
  brief, downward (gentle deflate + low muted tone). Noticeable, never punishing.
- **Layout:** one purpose per screen; primary content centered; nothing interactive at screen
  edges (hemianopia / neglect).
- **Consistency rule:** every future game must reuse the same star screen, pause overlay, and
  meaning-sounds. One product, not a collection of projects.

---

## 4. Installer mode (researcher-only, same app)

**Entry:** keyboard attached + key combo on the splash screen (patients have no keyboard).

**Landing page — install checklist**, green/red per item:
camera calibrated · board geometry present · origin locked · workspace calibrated ·
patient registered · upload configured. Installs become repeatable, not memory-dependent.

**Tools behind it:**

- **Patient registration** — ID, group assignment, the pre-sampled 14-day target-rate
  schedule, notes.
- **Origin ritual** — guided: device at the marked parking pose → confirm → origin locked ✓.
  (Ritual standardizes the frame across kits; even without it, each file's origin stamp
  permits post-hoc conversion to the camera frame — see §5.)
- **Workspace calibration** — existing 4-corner flow (TL → TR → BL → BR).
- **Test drive** — live cursor + a few real targets; never leave a home without seeing the
  loop work.
- **Debug toggles** — the hidden overlays, switchable here.

Out of installer mode for v1: camera / board / stereo calibration stay as CLI scripts over
SSH (researcher-only, already working, done at bench prep).

---

## 5. Data (schema agreed 2026-07-15)

Two CSVs per game run in `Documents/NOARK/data/<patient>/GameData/`, every row flushed to
disk immediately (power-cut safe):

- **Hand stream** (~100 Hz, one row per tracker packet):
  `epochtime, trial, screen_x, screen_y, tracker_x, tracker_y, tracker_z`.
  No mouse-fallback logging — tracker only.
- **Targets** (one row per target):
  `trial, spawn_time, target_x, target_y, diameter_px, outcome (caught/expired/aborted),
  outcome_time`. Trial 0 = calibration-phase targets.

**Origin stamp:** each hand file's header carries the contents of `origin_lock.json`.
Because the lock is stored in the camera frame, any session's coordinates can be converted
back to the (fixed, physically shared) camera frame:
`p_camera = grip_lock - R_lock * p_stream`. The stamp is both audit trail and undo key.

`origin_lock.json` is calibration data — back it up with `camera_calib.toml`; never
regenerate casually. One deliberate lock per installation (parking pose), then permanent.

Schema versioning: bump `protocol_version` in the CSV header whenever columns change, and
record the mapping in this document.

Known accepted gap (v1): difficulty does not react to the success-rate error; an all-miss
trial changes nothing (misses carry no movement time). See todo.md pre-clinical checklist.

---

## 6. Workflow after v1

1. **Bench prep** (lab, once per kit): flash Pi, install software, camera calibration, board
   geometry. Kits leave the bench hardware-complete.
2. **Installation** (patient's home, once, ~20 min): physical setup → boot → keyboard +
   combo → work the checklist down to all-green → test drive → unplug keyboard → leave.
3. **Patient daily**: switch on → play → switch off. The entire manual.
4. **Research loop** (weekly rhythm): device uploads CSVs daily when networked; researcher
   watches adherence per patient; drops trigger a call/message (human channel, outside the
   software); analysis runs on accumulated files whenever ready.
5. **Maintenance** (rare): camera bumped / furniture moved → one visit: origin ritual +
   workspace calibration (~10 min). Software update → SSH, git pull, reboot (manual in v1).

---

## 7. Build order

Each package independently testable on the Pi; none of 2–7 touches the adaptive algorithm
or the data schema. (Order revised 2026-07-15: package 6 pulled forward, before 2 — setup
flow needed before piloting. Package 0 — scaffold `app/` from v2 — done and Pi-verified.)

- [ ] **1. Data logging** — the two-CSV schema above + origin stamp + per-row flush.
      (In progress: udp_receiver packet buffer partially in as of 2026-07-15.)
- [ ] **2. Game feel** — music loop, catch effect + sound, miss effect + sound, star screen
      replacing the between-trial display. Needs audio assets (free game-asset libraries).
- [ ] **3. Screen hygiene** — researcher overlays behind the hidden flag; patient screen =
      game + score + stars only; tracker-lost pause state.
- [ ] **4. Chooser + GPIO buttons** — card UI, two-button navigation, hold-to-exit.
- [ ] **5. Kiosk boot** — systemd starts Godot on power-on; boot splash; patient ID +
      day-rate from patient file; login screen becomes installer-only.
- [ ] **6. Installer mode** — checklist landing page + tools (§4).
- [ ] **7. Data upload** — daily push to researcher server when network available.

**Explicitly out of v1:** cross-day progress displays, second game, researcher dashboard,
dose logic, SD-card write-protection hardening, automatic software updates, translation,
miss-censored difficulty adaptation, wrapping calibration scripts in UI.
