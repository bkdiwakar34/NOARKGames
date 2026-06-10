# Changes — ADA Implementation

## Overview
Replaced the PID-based adaptive difficulty system with a Fitts' Law model (ADA).
Visual theme changed from apple-catching to balloon-popping.

---

## Files changed

### `Core/adaptive_manager_pid.gd` — NEW (backup)
Original PID + staircase adaptive manager. Kept unmodified for reference.

### `Core/adaptive_manager.gd` — REPLACED
Full rewrite. Key differences from the PID version:

| | Old (PID) | New (ADA) |
|---|---|---|
| Calibration | Staircase on Trial 1 | 3-phase calibration before Session |
| Difficulty control | PID error correction | Fitts' Law threshold formula |
| Target parameter | r-space window centre | (A, W) pairs + model |
| Online update | PID integral | RLS + Welford per pair |

**Calibration phases (run before Trial 1):**
- **Phase 0a — Workspace scan**: 4 directions × 3 distances × 2 repeats = 24 apples. Determines max reachable A per direction.
- **Phase 0b — Precision scan**: 5 W values × 3 repeats = 15 apples. Determines smallest usable target width W_min.
- **Phase 0c — Fitts calibration**: 10 (A, W) pairs × 20 valid observations = 200 apples. Fits MT = a + b·log₂(A/W + 1).

**Session lifetime threshold:**
```
lifetime = (a + b·log₂(A/W + 1)) + z·SD_residual(A, W)
```
where z is derived from the target success rate via normal inverse CDF.

**Online model update (per apple):**
- (a, b): Recursive Least Squares
- SD_residual per pair: Welford's online algorithm

**MT measurement:**
- Hit: `Time.get_ticks_msec()` at spawn → at catch, minus `catch_hold_time`
- Miss (completed): spawn time → when player crosses target boundary (tracked for 6 s)
- Miss (aborted): discarded if player never reaches target position

**New public methods:**
- `get_apple_radius() -> float` — returns W/2 for current pair; used to set catch radius per apple
- `record_miss_completed()` — called from random_reach when player crosses missed target position

**Public variables added:**
- `fitts_a`, `fitts_b` — current model parameters
- `difficulty` — current pair's Index of Difficulty (bits), logged to CSV
- `_phase` — current phase enum (read by debug label)

---

### `Games/random_reach/random_reach.gd` — MODIFIED

- `CATCH_RADIUS` (const 60 px) → `_catch_radius` (var, set per apple from `AdaptiveManager.get_apple_radius()`)
- Jet sprite removed; pin/needle drawn procedurally in `_draw()`. Tip at `_player_pos`, pointing toward balloon. Cursor is effectively a point — consistent with Fitts' W.
- Post-miss movement tracking: after a miss, player position is checked against the missed balloon location for up to 6 seconds. If reached → `record_miss_completed()`. If not → trial discarded.
- New apple only spawns after miss tracking window closes (prevents immediate re-spawn that would cancel tracking).
- `balloon_color` set per spawn: `Color.from_hsv(randf(), 0.75, 0.92)` — random saturated hue.
- Score label sub-text changed from "apples" to "pops".
- Debug label updated: shows phase, fitts_a, fitts_b, current ID, rolling rate, RLS sample count.

---

### `Games/random_reach/apple.gd` — MODIFIED

Visual only — logic unchanged.

- Apple → Balloon: oval polygon body, sheen highlight, knot, swaying string
- `balloon_color: Color` property added (set externally per spawn)
- `APPLE_RADIUS` replaced by `BALLOON_RX = 22`, `BALLOON_RY = 28`
- `CATCH_ARC_RADIUS` unchanged (46 px)

---

## Things to test on Pi

1. **Calibration phases complete without hanging** — watch for workspace scan (24 apples), precision scan (15), Fitts cal (200). Total ~25 min at 6 s lifetime.
2. **RLS matrix update** — if `fitts_a` and `fitts_b` stay at 0.0/0.5 after calibration, the RLS nested array update (`_rls_P[0][0] -= ...`) is not working. Workaround: refactor `_rls_P` to 4 separate floats.
3. **Session lifetime values** — after calibration, check debug label shows plausible lifetime (0.5–5 s range). If lifetime is always hitting LIFETIME_MIN or LIFETIME_MAX, the model is off.
4. **Post-miss tracking** — confirm a missed balloon does not immediately re-spawn; the pin should still be visible and movable toward the old balloon position.
5. **UDP receiver** — no changes to that path; should work as before.

---

## Known limitations
- Calibration is long (~25 min). `CAL_PER_PAIR` can be reduced (e.g. to 10) for faster testing.
- Normality of MT residuals assumed. Check Q-Q plots from calibration data.
- Model update has one-session lag for catching large improvement in patient performance.
