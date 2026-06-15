"""
Pi camera (fisheye OV9281) calibration.

Hold a printed checkerboard in varied poses; the script auto-captures when
the board is detected and held steady, then runs cv2.fisheye.calibrate and
saves intrinsics + distortion to camera_calib.toml.

After saving, a verify step reports three quality numbers:
  - accuracy  (mm)  — measured square edge length vs the true 25 mm
  - precision (mm)  — std of position across still frames
  - fit       (px)  — reprojection error on the verify frames

Run on the Pi:  python pyscripts/calibrate_camera.py
"""

import os
import platform
import time
from datetime import datetime

import cv2
import numpy as np
import toml


BOARD_INNER_CORNERS = (9, 6)     # (cols, rows) of inner corners — change if your board differs
SQUARE_SIZE_M       = 0.02435    # measured with vernier on the printed OpenCV pattern
FRAME_SIZE          = (1280, 800)
NUM_CAPTURES        = 20
NUM_VERIFY_POSES    = 6          # how many distinct poses to test the calibration at
COOLDOWN_S          = 2.0        # min seconds between auto-snaps
STABLE_FRAMES       = 15         # how many frames the board must barely move
STABLE_PX_THRESHOLD = 2.0        # max mean corner motion (px) to count as still

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_PATH = os.path.join(_SCRIPT_DIR, "camera_calib.toml")


# ── camera ───────────────────────────────────────────────────────────────────

def init_camera():
    if platform.system() == "Linux":
        from picamera2 import Picamera2

        picam2 = Picamera2()
        config = picam2.create_video_configuration(
            {"format": "YUV420", "size": FRAME_SIZE},
            controls={"FrameRate": 100, "ExposureTime": 5000, "AeEnable": False},
        )
        picam2.configure(config)
        picam2.start()
        return ("pi", picam2)
    else:
        cap = cv2.VideoCapture(0, cv2.CAP_DSHOW)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_SIZE[0])
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_SIZE[1])
        return ("webcam", cap)


def capture_gray(cam):
    kind, src = cam
    if kind == "pi":
        frame = src.capture_array()
        # YUV420: Y plane (grayscale) is the first FRAME_SIZE[1] rows.
        return frame[:FRAME_SIZE[1], :FRAME_SIZE[0]] if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    ret, frame = src.read()
    if not ret:
        raise RuntimeError("webcam capture failed")
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)


# ── overlay ──────────────────────────────────────────────────────────────────

def draw_banner(frame, text, color=(255, 255, 255)):
    overlay = frame.copy()
    cv2.rectangle(overlay, (0, 0), (frame.shape[1], 60), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.6, frame, 0.4, 0, frame)
    cv2.putText(frame, text, (10, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2)
    return frame


def to_bgr(gray):
    return cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)


def show_dialog(frame, title, body_lines, color=(255, 255, 255)):
    """Draw a centred dialog box with a big title and a few lines of body text."""
    h, w = frame.shape[:2]
    box_w, box_h = int(w * 0.7), int(h * 0.55)
    x1, y1 = (w - box_w) // 2, (h - box_h) // 2
    x2, y2 = x1 + box_w, y1 + box_h

    overlay = frame.copy()
    cv2.rectangle(overlay, (x1, y1), (x2, y2), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.85, frame, 0.15, 0, frame)
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 3)

    (tw, _), _ = cv2.getTextSize(title, cv2.FONT_HERSHEY_SIMPLEX, 1.5, 3)
    cv2.putText(frame, title, (x1 + (box_w - tw) // 2, y1 + 80),
                cv2.FONT_HERSHEY_SIMPLEX, 1.5, color, 3)

    line_y = y1 + 150
    for line in body_lines:
        (lw, _), _ = cv2.getTextSize(line, cv2.FONT_HERSHEY_SIMPLEX, 0.8, 2)
        cv2.putText(frame, line, (x1 + (box_w - lw) // 2, line_y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)
        line_y += 40
    return frame


def dialog_countdown(cam, seconds, title, body_lines, color=(255, 255, 255)):
    """Show a dialog with a countdown that updates each second."""
    for s in range(seconds, 0, -1):
        gray = capture_gray(cam)
        frame = show_dialog(
            to_bgr(gray), title,
            body_lines + ["", f"Starting in {s}..."],
            color,
        )
        cv2.imshow("calibrate", frame)
        cv2.waitKey(1000)


# ── stability tracker ────────────────────────────────────────────────────────

class StabilityTracker:
    def __init__(self):
        self.history = []

    def update(self, corners):
        self.history.append(corners)
        if len(self.history) > STABLE_FRAMES:
            self.history.pop(0)

    def is_stable(self):
        if len(self.history) < STABLE_FRAMES:
            return False
        diffs = [np.linalg.norm(self.history[i] - self.history[i - 1], axis=-1).mean()
                 for i in range(1, len(self.history))]
        return float(np.mean(diffs)) < STABLE_PX_THRESHOLD

    def reset(self):
        self.history.clear()


# ── calibration ──────────────────────────────────────────────────────────────

def make_object_points():
    cols, rows = BOARD_INNER_CORNERS
    objp = np.zeros((1, cols * rows, 3), np.float32)
    objp[0, :, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    objp *= SQUARE_SIZE_M
    return objp


def run_calibration(imgpoints):
    objp = make_object_points()
    objpoints = [objp.copy() for _ in imgpoints]
    K = np.zeros((3, 3))
    D = np.zeros((4, 1))
    rvecs = [np.zeros((1, 1, 3), dtype=np.float64) for _ in imgpoints]
    tvecs = [np.zeros((1, 1, 3), dtype=np.float64) for _ in imgpoints]
    flags = (
        cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC
        | cv2.fisheye.CALIB_CHECK_COND
        | cv2.fisheye.CALIB_FIX_SKEW
    )
    rms, K, D, _, _ = cv2.fisheye.calibrate(
        objpoints, imgpoints, FRAME_SIZE, K, D, rvecs, tvecs,
        flags,
        (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 1e-6),
    )
    return K, D, float(rms)


# ── verify ───────────────────────────────────────────────────────────────────

def _capture_one_stable_pose(cam, K, D, pose_idx, total_poses):
    """
    Wait for the board to appear and be held still, then snap exactly one frame.
    Returns (corners_ud, rvec, tvec) for that frame.
    Mirrors how main.py uses the tracker: one frame per moment.
    """
    objp = make_object_points()
    flat_objp = objp[0]
    tracker = StabilityTracker()

    while True:
        gray = capture_gray(cam)
        overlay = to_bgr(gray)

        found, corners = cv2.findChessboardCorners(
            gray, BOARD_INNER_CORNERS,
            flags=cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_FAST_CHECK,
        )

        if found:
            corners = cv2.cornerSubPix(
                gray, corners, (11, 11), (-1, -1),
                (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.01),
            )
            cv2.drawChessboardCorners(overlay, BOARD_INNER_CORNERS, corners, found)
            tracker.update(corners.reshape(-1, 2))

            if tracker.is_stable():
                corners_ud = cv2.fisheye.undistortPoints(corners.reshape(-1, 1, 2), K, D, P=K)
                ok, rvec, tvec = cv2.solvePnP(flat_objp, corners_ud, K, np.zeros(4))
                if ok:
                    flash = cv2.addWeighted(overlay, 0.5, np.full_like(overlay, (0, 255, 0)), 0.5, 0)
                    flash = draw_banner(flash, f"Pose {pose_idx}/{total_poses} captured!", (0, 255, 0))
                    cv2.imshow("calibrate", flash)
                    cv2.waitKey(400)
                    return corners_ud.reshape(-1, 2), rvec.flatten(), tvec.flatten()

            color  = (0, 255, 255)
            status = "Hold still..."
        else:
            tracker.reset()
            color  = (0, 0, 255)
            status = "Show board to camera"

        overlay = draw_banner(
            overlay,
            f"Pose {pose_idx}/{total_poses} — move to a new spot, then {status}",
            color,
        )
        cv2.imshow("calibrate", overlay)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            return None


def verify(cam, K, D):
    """
    Multi-pose verify. One frame per pose, multiple poses across the field of
    view — matches how main.py uses the tracker (per-frame, no averaging).
    Reports the spread of accuracy across poses, not just the mean.
    """
    objp = make_object_points()
    flat_objp = objp[0]
    cols, rows = BOARD_INNER_CORNERS
    K_inv = np.linalg.inv(K)

    print(f"\n--- Verify phase ---")
    print(f"You'll be asked to hold the board still in {NUM_VERIFY_POSES} different positions.")
    print(f"Try to cover different distances, angles, and screen corners.")

    dialog_countdown(
        cam, 6,
        "TEST PHASE",
        [
            "Calibration complete. Now we'll test it.",
            "",
            f"Hold the board in {NUM_VERIFY_POSES} different poses.",
            "Vary the distance, angle, and screen position.",
            "Each pose auto-snaps when you stop moving.",
        ],
        color=(0, 255, 255),
    )

    captures = []   # list of (corners_ud, rvec, tvec)
    for i in range(NUM_VERIFY_POSES):
        result = _capture_one_stable_pose(cam, K, D, i + 1, NUM_VERIFY_POSES)
        if result is None:
            print("Verify aborted.")
            return
        captures.append(result)

    # Per-pose accuracy: mean absolute square-edge error reconstructed from each frame.
    per_pose_mean = []
    all_errors = []
    rep_errors = []
    for corners_ud, rvec, tvec in captures:
        R, _ = cv2.Rodrigues(rvec)
        plane_normal = R[:, 2]
        plane_offset = float(np.dot(tvec, plane_normal))

        recon = np.empty((cols * rows, 3))
        for j, (u, v) in enumerate(corners_ud):
            ray = K_inv @ np.array([u, v, 1.0])
            s = plane_offset / float(np.dot(ray, plane_normal))
            recon[j] = s * ray

        pose_errors = []
        for r in range(rows):
            for c in range(cols - 1):
                d = np.linalg.norm(recon[r * cols + c] - recon[r * cols + c + 1])
                pose_errors.append(abs(d - SQUARE_SIZE_M))
        for c in range(cols):
            for r in range(rows - 1):
                d = np.linalg.norm(recon[r * cols + c] - recon[(r + 1) * cols + c])
                pose_errors.append(abs(d - SQUARE_SIZE_M))

        per_pose_mean.append(float(np.mean(pose_errors)) * 1000)
        all_errors.extend(pose_errors)

        proj, _ = cv2.projectPoints(flat_objp, rvec, tvec, K, np.zeros(5))
        rep_errors.append(float(np.linalg.norm(corners_ud - proj.reshape(-1, 2), axis=1).mean()))

    arr = np.array(all_errors) * 1000   # convert to mm
    mean_mm = float(np.mean(arr))
    max_mm  = float(np.max(arr))
    p95_mm  = float(np.percentile(arr, 95))
    std_mm  = float(np.std(arr))

    print()
    print("--- Per-pose accuracy ---")
    for i, m in enumerate(per_pose_mean):
        print(f"  Pose {i + 1}: mean square-edge error = {m:.2f} mm")

    print()
    print("--- Overall ---")
    print(f"  Mean error          : {mean_mm:.2f} mm")
    print(f"  95th percentile     : {p95_mm:.2f} mm   (worst-case you'd hit most of the time)")
    print(f"  Max error           : {max_mm:.2f} mm   (worst single pair we saw)")
    print(f"  Std of errors       : {std_mm:.2f} mm   (spread)")
    print(f"  Reprojection error  : {float(np.mean(rep_errors)):.2f} px")
    print()
    print("  Rough rule for the Pi: max < 2 mm and p95 < 1 mm is a good calibration.")


# ── main flow ────────────────────────────────────────────────────────────────

def countdown(cam, seconds, message):
    for s in range(seconds, 0, -1):
        gray = capture_gray(cam)
        overlay = draw_banner(to_bgr(gray), f"{message} {s}...")
        cv2.imshow("calibrate", overlay)
        cv2.waitKey(1000)


def main():
    cam = init_camera()
    imgpoints = []
    tracker = StabilityTracker()
    last_capture = 0.0
    flash_until = 0.0

    dialog_countdown(
        cam, 5,
        "CALIBRATION PHASE",
        [
            f"We'll capture {NUM_CAPTURES} frames of the board",
            "in varied poses (different distances and angles).",
            "Each frame auto-snaps when you hold still.",
        ],
        color=(0, 255, 0),
    )
    print(f"Capturing {NUM_CAPTURES} frames. Hold the board in varied poses.")

    try:
        while len(imgpoints) < NUM_CAPTURES:
            gray = capture_gray(cam)
            overlay = to_bgr(gray)

            found, corners = cv2.findChessboardCorners(
                gray, BOARD_INNER_CORNERS,
                flags=cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_FAST_CHECK,
            )
            now = time.time()

            if found:
                corners = cv2.cornerSubPix(
                    gray, corners, (11, 11), (-1, -1),
                    (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.01),
                )
                cv2.drawChessboardCorners(overlay, BOARD_INNER_CORNERS, corners, found)
                tracker.update(corners.reshape(-1, 2))

                if tracker.is_stable() and now - last_capture > COOLDOWN_S:
                    imgpoints.append(corners.reshape(1, -1, 2).astype(np.float64))
                    last_capture = now
                    flash_until = now + 0.5
                    tracker.reset()
                    print(f"  captured {len(imgpoints)}/{NUM_CAPTURES}")

                stable = tracker.is_stable()
                color  = (0, 255, 0) if stable else (0, 255, 255)
                status = "Captured!" if stable else "Hold still..."
            else:
                tracker.reset()
                color  = (0, 0, 255)
                status = "Show board to camera"

            if now < flash_until:
                green = np.full_like(overlay, (0, 255, 0))
                overlay = cv2.addWeighted(overlay, 0.5, green, 0.5, 0)

            overlay = draw_banner(
                overlay,
                f"Captured {len(imgpoints)}/{NUM_CAPTURES} - {status}",
                color,
            )
            cv2.imshow("calibrate", overlay)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

        if len(imgpoints) < 10:
            print("Too few captures — aborting.")
            return

        # Computing banner
        overlay = draw_banner(to_bgr(capture_gray(cam)), "Computing calibration...")
        cv2.imshow("calibrate", overlay)
        cv2.waitKey(50)

        print("Computing calibration...")
        try:
            K, D, rms = run_calibration(imgpoints)
        except cv2.error as exc:
            print(f"Calibration failed: {exc}")
            print("Common cause: not enough variation in board poses. Re-run and tilt more.")
            return

        print(f"Calibration done. Reprojection error: {rms:.2f} px")

        data = {
            "calibration": {
                "camera_matrix":      K.tolist(),
                "dist_coeffs":        D.flatten().tolist(),
                "method":             "fisheye",
                "reprojection_error": rms,
                "resolution":         list(FRAME_SIZE),
                "date":               datetime.now().strftime("%Y-%m-%d"),
                "num_captures":       len(imgpoints),
                "square_size_m":      SQUARE_SIZE_M,
                "board_inner_corners": list(BOARD_INNER_CORNERS),
            }
        }
        with open(OUTPUT_PATH, "w") as f:
            toml.dump(data, f)
        print(f"Saved to {OUTPUT_PATH}")

        verify(cam, K, D)

        overlay = draw_banner(to_bgr(capture_gray(cam)), f"Done — saved {os.path.basename(OUTPUT_PATH)}")
        cv2.imshow("calibrate", overlay)
        cv2.waitKey(3000)

    finally:
        cv2.destroyAllWindows()
        kind, src = cam
        if kind == "pi":
            src.stop()
        else:
            src.release()


if __name__ == "__main__":
    main()
