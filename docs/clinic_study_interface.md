# Clinic study interface — spec

The interface for the **3-day study with healthy participants**, designed 2026-09-25.
It is a **separate app flow**: the current `app/ui` flow (chooser → Apple Harvest, the
14-day patient kiosk) works and is **not touched**. The new flow gets its own entry scene
and folder; it may read the shared platform code but does not edit the existing screens.

Mockup (approved 2026-09-25): [Reach Study Interface](https://claude.ai/artifact/NGWbDRwzpNHSiedrXAdayx)
— design canvas, one artboard per screen, clickable in Play mode.

Nothing here is implemented yet. Change this document first, code second.

---

## 1. Study rules

| Rule | Decision |
|---|---|
| Participants | Healthy adults |
| Length | 3 visits, one difficulty level per visit |
| Levels | Three percentiles $p$ — **the same three for everyone** (values not decided) |
| Level order | Randomised per participant **by the app at registration**, balanced blocks of the $3! = 6$ orders (shuffle the 6, hand one to each of the next 6 participants, reshuffle). Stored and locked, **never shown on screen** |
| Study day | Advances **by visit**: the first session on a new calendar date is the next study day, whatever the gap. A second session on the same date stays on that day. The date of each day is recorded |
| Calibration | Reach scan + Fitts calibration on **every visit** |
| Play | 15 rounds × 60 s, 15 s rest between (settings — fixed dose vs open-ended still open) |
| Game | One game for the whole study, the same for every participant |

Why the level is hidden: the participant sits in front of the same screen as the
researcher; knowing "today is the hard day" could change effort and confound the level.

Why the same game for everyone: the level effect is a within-person difference, which
cancels the person and the game — but not a game × level interaction. With one game that
interaction is a constant; with games varying across people it mixes into the average.

## 2. Flow

```
Clinic mode:  Home → Reach scan → Warm-up → Calibration rounds → Play rounds → Session complete → Home
Home mode:    straight to the game (calibration and level applied automatically)
```

There is **no Difficulty page** and, in clinic mode, **no Game choice page**: the level
follows from the participant's order and the study day; the game is fixed. The
Clinic / Home toggle lives in Settings.

Operated by the researcher with **mouse + keyboard**.

## 3. Difficulty

### 3.1 Target pairs

Three $(A, W)$ pairs, **fixed for everyone**, set in millimetres, spread over a range of
$\mathrm{ID} = \log_2(A/W + 1)$. Draft values (not decided):

| Pair | $A$ (mm) | $W$ (mm) | ID (bits) |
|---|---|---|---|
| 1 | 150 | 60 | 1.81 |
| 2 | 300 | 40 | 3.09 |
| 3 | 450 | 25 | 4.25 |

Calibration and play both use **only these three pairs**. The reach scan decides *where*
an apple may appear (arm lengths differ); the pair decides its distance and size.

*For a later patient version:* fix the three **IDs** instead and scale $A$ and $W$ together
to each person's reach — ID depends only on $A/W$.

### 3.2 Lifetime rule

For pair $k$, sort that day's calibration movement times $t_{(1)} \le \dots \le t_{(n_k)}$.
The lifetime on a level with percentile $p$ is the empirical $p$-th value:

$$\ell_k = t_{(\lceil p\, n_k \rceil)} \qquad \text{e.g. } n_k = 40,\ p = 0.8 \Rightarrow \ell_k = t_{(32)}$$

No Fitts line and no normal assumption — movement times are right-skewed, and a normal fit
misplaces the high percentiles. Movement time is measured as today
(design.md §4.6: spawn to the end of the successful hold, minus the hold).

### 3.3 The model is frozen after calibration

No online updating during play (no RLS on $(a, b)$, no Welford on $\sigma_k$).
Two reasons:

- **Catch-only updates drift down.** Only movements with $\mathrm{MT} \le \ell$ are caught, and
  their mean is below the true mean: $\mathbb{E}[\mathrm{MT} \mid \mathrm{MT} \le \ell] = \mu - \sigma\,\varphi(z)/\Phi(z)$,
  i.e. $\mu - 0.50\,\sigma$ at $p = 0.7$. The lifetime would shrink and a 70 % day drift toward 50 %.
- **Counting misses lets coasting inflate MT.** A participant who stops trying would
  lengthen the lifetimes and make the game easier.

Because calibration now carries everything, it runs every visit (learning between days
would otherwise shift the real success rate: a Day-1 model on a faster Day 3 turns a
70 % level into ~90 %), and it is preceded by a warm-up round.

## 4. Pages

### 4.1 Home (operator)

- Top bar: product name, tracker status (rate), protocol version + draft/locked, mode, Settings.
- Participant list, **two lines per row**:
  - line 1: **ID · name**; line 2: age · gender · dominant hand;
  - study progress: three day bars (done / in progress / incomplete / to come) + label;
  - last session date; today's status (calibrated at hh:mm / calibration due / finished);
  - action: **Start day N** / **Resume** / Completed.
- Search, **New participant** button.
- Side panel: device checks (tracker, origin lock, screen mapping, protocol locked).

### 4.2 Registration (operator)

- Participant ID (next free, editable), full name, age, gender (Female / Male / Other),
  dominant hand (Left / Right).
- Level order assigned on save (balanced block), stored, not shown.
- The name stays on the device; data files and folders use the ID only.

### 4.3 Reach scan (participant)

- A glowing target **glides from the centre out past reach and back**, along **8 spokes**,
  ~150 mm/s → one spoke = 900 mm / 150 mm/s = 6 s, all 8 ≈ 48 s.
- Edge in each direction = the farthest cursor point, detected when the target–cursor gap
  starts growing along the path. Apples then spawn inside the 8-point boundary.
- On screen: "Follow the light", 8 progress dots.

### 4.4 Warm-up and calibration rounds (participant)

- Looks and feels like the game: **1-minute rounds, 15 s rest**. No numbers or panels.
- Warm-up: one round, same game and pairs, **not counted**.
- Calibration: ~40 apples per pair (≈ 5 rounds ≈ 6 min with rests).
- **Speed points, no visible deadline**: each apple waits up to a generous cap (8 s); a
  faster catch earns more — the apple ripens gold → red, 3 → 2 → 1 points (thresholds TBD).
  Nearly every movement is recorded whole (no censoring).
- **Calibration check** — shown after the last calibration round **only when the researcher
  overlay is on** (§4.9); with the overlay off, play starts by itself after the rest card.
  Contents:
  - per pair: ID, $A$, $W$, caught / spawned, timeouts, and the movement-time spread
    (10th–90th percentile bar with the median marked);
  - the reach boundary from the 8 spokes, drawn in the screen outline;
  - buttons: **Redo from reach scan** · **Redo calibration rounds** · **Accept · start play**.
  - Never shows lifetimes or the level (the participant can see the screen).

### 4.5 Play rounds (participant)

- Same pairs; lifetime from §3.2; lifetime shown as a ring draining around the catch zone.
- HUD: round progress segments (top centre), caught count (top right).

### 4.6 Rest cards (participant, 15 s)

TypingClub-style card:

- **Play:** row of 5 stars, stars $= \mathrm{round}(5 \cdot \text{caught}/\text{spawned})$; ring with the
  success % ; "18 of 22 apples"; countdown "Next round in 12".
  (Shows the success rate deliberately — the researcher's choice, knowing it reflects the level.)
- **Calibration:** same card with **points** instead of %: stars $= \mathrm{round}(5 \cdot \text{points} / (3\cdot\text{caught}))$.

### 4.7 Session complete (participant → operator)

Whole-session stars, overall %, rounds played, "Saved · Day N of 3", **Done** → Home.

### 4.8 Interruptions

- Same date: Home shows "Day N · round 6 of 15" with **Resume**, which opens a prompt
  ("Resume day N?", rounds done, "today's calibration and level are kept") → **Resume at
  round 7** / Cancel. Play continues with that day's frozen calibration and level.
- Cut **during calibration**: calibration restarts from the reach scan.
- A later date: the unfinished day is marked incomplete in the data; the visit is the next
  study day.
- **Tracker lost** (packets stop mid-round): soft pause — the game blurs, a card shows the
  handle settling onto the table with "Place the handle back on the table / The game
  continues by itself"; round timers stop and it resumes on its own when packets return.
  No error codes.

### 4.9 Settings (operator)

| Group | Contents |
|---|---|
| Mode | Clinic / Home toggle; researcher overlay on/off |
| Device | Tracker status + camera preview, origin lock, 4-corner screen mapping, test drive, validation recorder |
| Protocol | 3 percentiles, 3 pairs (A, W in mm; ID computed), round length, rest, warm-up, calibration rounds, play rounds, speed-point cap, spoke count and speed |
| Data | Data folder, export |

**Lock protocol:** editable while piloting; once locked, values are read-only and the
protocol version (e.g. "protocol v3") is written into every data file header.

**Researcher overlay** (Mode page, off by default). It sits on the screen the participant
watches, so it **never shows $p$, the lifetimes or the day's level** — it is safe to leave
on with a participant present. It adds:

- after calibration: the calibration check (§4.4);
- during play: a small panel, bottom-left — tracker rate and missed frames, cursor
  position, round and time left, current apple's pair, caught / missed this round, hold time.

**Data page:** files per visit — visit header (ID, study day + date, level, protocol
version, origin-lock stamp), hand stream (100 Hz), targets (one row per apple, with phase:
reach scan / warm-up / calibration / play), calibration result (reach boundary, each pair's
sorted MTs, the lifetimes used). Rows flushed as written; files use the ID only. Export to USB.

## 5. Look

- **Operator screens:** clean professional dashboard — neutral warm-grey ground, white
  cards, Manrope, one accent (apple red `#C0392B`).
- **Participant screens:** polished 2D game with real physics — layered orchard scene with
  depth and light, shaded apples with shadows; a caught apple flies into a basket and
  bounces; a missed apple dulls, falls, bounces and rolls away; particle bursts. Fredoka
  for game text, same accent.
- The catch zone is always exactly $W$ wide and clearly drawn, whatever the apple looks like.
- Must hold 60 fps on the Dragon (Godot on cores 0–3, compatibility renderer, tracker
  alongside).

## 6. Open items

- The three percentile values.
- The final pair values (A, W).
- Fixed dose (15 rounds) vs open-ended play.
- Speed-point thresholds (time limits for 3 / 2 / 1 points).
- Whether the apple stays code-drawn in the new app (the sprite multi-apple bug in the old
  app was never diagnosed).
