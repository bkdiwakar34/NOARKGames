# NOARKGames — Open TODOs

Active work-in-progress and known issues. Completed items live in git history, not here.

---

## Tracker pipeline

- **Dragon Q6A dual-camera tracking** is implemented (`camera_backend: "rcam_dual"` in settings.json, see [setup.md §3c](setup.md)). Needs on-device verification: run `calibrate_stereo.py`, confirm origin-lock timing and grip-point smoothness are comparable to single-camera, and confirm the single-camera fallback (occlude one camera) behaves cleanly. **If either camera is physically moved or re-mounted, re-run `calibrate_stereo.py`** — the extrinsic transform is only valid for the rig's exact mounted geometry (same caveat as the existing single-camera origin-lock note below).
- **Re-run the 4-corner sensor-to-screen calibration.** The removal of `cv2.flip(frame, 1)` and the switch to a properly-fit `camera_calib.toml` changed the raw values the tracker reports. The old screen-mapping coefficients are invalid; redo via `workspace_calibration_overlay.gd`.
- **Resolution alignment audit.** `Config.FRAME_SIZE` is now `(1280, 800)` (OV9281 native). Confirm everything downstream in Godot is happy at this resolution.
- **Switch to OpenCV `aruco.Board` for skateboard pose.** Replace `_get_centroid` + `_get_local_coordinates` in `main.py` with a single `estimatePoseBoard` call. Requires each marker's full 6-DOF placement on the device, not just translation. Workflow: place labelled construction coord systems in Fusion 360 (`marker_4`, `marker_8`, …) on each marker face, write a Fusion 360 Python add-in that exports them to `skateboard_geometry.csv` with `id, x, y, z, qx, qy, qz, qw`; load that at startup.
- **Try ChArUco diamonds on each face.** Drop-in replacement for individual markers — gives 8 corners per face instead of 4, ~50 % reduction in hold-jitter, no CAD measurement needed. Each diamond is ~3× the size of a single marker so the device faces need room.

### Maybe / lower priority

- **Hold-detector + corner averaging on top of One Euro.** When speed has been below a threshold for N frames, average the last N corner positions instead of running One Euro. Noise drops by `√N` during the hold rather than approaching a fixed floor.
- **Retroreflective / IR-lit markers.** Stick retroreflective tape on the existing markers and add an LED ring around the camera. Decouples tracking from room lighting; lets exposure stay at 1–2 ms with maximum frame rate. OV9281 is IR-sensitive — IR LEDs + IR-pass filter would be invisible to the patient and give the cleanest result.
- **STag** (Stable Tag) for ~20 % lower corner-detection noise. Needs `pystag` (built from C++) and reprinted markers. Smaller win than diamonds for similar physical-rework cost — only worth it if `diagnose_jitter.py` shows corner σ is the bottleneck.

---

## Godot / system integration

- **Auto-start Godot on Pi boot.** Tracker is already auto-launched by the Godot autoload. A systemd unit (or similar) should start Godot itself at boot so the system is usable without SSH.
- **Data sync to researcher server.** Pi pushes CSV files to a researcher's server when the patient connects to a mobile hotspot. Daily upload cadence.
- **Researcher dashboard.** Web-based view of patient progress. Technology not decided.

---

## Pre-clinical-deployment checklist

- [ ] Revert testing constants in `adaptive_manager.gd`:
  - `catch_hold_time` → 0.8
  - `LIFETIME_MAX` → 15.0
  - `LIFETIME_MIN` → 3.0
  - `trial_duration` → 60.0 (set via game_select UI)
- [ ] Verify Phase 0c calibration takes a tolerable amount of time on a real patient (currently 75 apples × ~3 s per attempt ≈ 4 min). Reduce `CAL_PER_PAIR` if needed.
- [ ] Q-Q-plot check of per-pair MT residuals — the lifetime formula assumes approximate normality. If badly violated, reconsider.
- [ ] One-session lag in (a, b) adaptation: RLS catches up over many trials, but large within-session improvements (e.g., warm-up) lag the model. Decide whether to add a forgetting factor or accept the lag.
