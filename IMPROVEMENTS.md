# NOARK — Improvement Tracker
_Last updated: 2026-05-28_

---

## Python / Tracking

### 1. Corner refinement method
- **File:** `pyscripts/main.py` line 99
- **Current:** `params.cornerRefinementMethod = aruco.CORNER_REFINE_CONTOUR`
- **Proposed:** Switch to `aruco.CORNER_REFINE_SUBPIX`
- **Why:** Sub-pixel refinement is more accurate than contour-based. Small code change, better pose estimation accuracy.
- **Status:** Not tested yet

### 2. Resolution mismatch
- **File:** `pyscripts/main.py` line 28, `pyscripts/calibration/good.toml`
- **Current:** Calibration done at 1280×800, tracker captures at 1200×800
- **Proposed:** Either recalibrate at 1200×800, or change `FRAME_SIZE` to `(1280, 800)`
- **Why:** Camera matrix computed for 1280px width is being applied to 1200px frames — introduces systematic position error
- **Status:** Not tested yet

### 3. Marker size justification
- **Current:** Marker size is 5cm — chosen pragmatically, not formally derived
- **Proposed:** Derive minimum marker size from detection distance and pixel projection formula. Verify empirically across operating range (0.5–1m).
- **Formula:** `projected_pixels = focal_length × marker_size / distance`
  - At 1m: `787 × 0.05 / 1.0 ≈ 39px` (above 30px minimum — acceptable)
  - At 1.5m: `787 × 0.05 / 1.5 ≈ 26px` (below threshold — may fail)
- **Why:** Needed if system goes into a clinical paper — reviewers will ask
- **Status:** Not done

---

## Future candidates (not yet evaluated)

- Kalman filter instead of EMA for smoother tracking during fast arm movement
- Formal accuracy characterisation — measure position error at known distances
