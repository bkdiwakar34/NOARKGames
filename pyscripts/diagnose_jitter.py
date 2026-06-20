"""
Jitter diagnostic for the ArUco tracker — multi-pose noise floor.

For each of 5 marker positions (centre + 4 workspace corners) the script
captures 200 static frames and computes per-corner pixel noise and
per-axis pose noise. Comparing the results across positions tells you
whether your jitter is roughly uniform (detection-limited everywhere)
or much worse at the edges of the workspace (geometry-limited).

Test 3 (synthetic-corner wiring sanity) runs once at the start.
Test 4 (PnP solver comparison) runs once at the centre pose only.

Setup:
  - Mount the camera so it cannot move during the entire experiment.
  - You will be prompted to place ONE marker at 5 different locations.
  - At each location, place the marker, step back, and press Enter.
  - Capture takes ~7 s per position; total experiment is ~3 minutes.

Run: python pyscripts/diagnose_jitter.py
"""

import platform
import sys
from pathlib import Path

import cv2
import numpy as np
import toml
from cv2 import aruco


NUM_FRAMES    = 200
MARKER_LENGTH = 0.05
IDEAL_TVEC    = np.array([0.0, 0.0, 0.5], dtype=np.float64)

POSE_NAMES: list[str] = [
    "centre",
    "top-left workspace corner",
    "top-right workspace corner",
    "bottom-left workspace corner",
    "bottom-right workspace corner",
]

SOLVER_NAMES = {
    cv2.SOLVEPNP_IPPE_SQUARE: "IPPE_SQUARE",
    cv2.SOLVEPNP_ITERATIVE:   "ITERATIVE",
    cv2.SOLVEPNP_SQPNP:       "SQPNP",
}


# ── setup ────────────────────────────────────────────────────────────────────

def load_calibration() -> tuple[np.ndarray, np.ndarray, tuple[int, int]]:
    path = Path(__file__).parent / "camera_calib.toml"
    if not path.exists():
        sys.exit(f"camera_calib.toml not found at {path}. Run calibrate_camera.py first.")
    data = toml.load(path)
    K = np.array(data["calibration"]["camera_matrix"]).reshape(3, 3)
    D = np.array(data["calibration"]["dist_coeffs"]).reshape(4, 1)
    res = data["calibration"].get("resolution", [1280, 800])
    return K, D, tuple(res)


def init_detector() -> aruco.ArucoDetector:
    params = aruco.DetectorParameters()
    params.useAruco3Detection     = True
    params.cornerRefinementMethod = aruco.CORNER_REFINE_APRILTAG
    dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
    return aruco.ArucoDetector(dictionary, params)


def init_camera(frame_size: tuple[int, int]):
    if platform.system() == "Linux":
        from picamera2 import Picamera2
        picam2 = Picamera2()
        picam2.configure(picam2.create_video_configuration(
            {"format": "YUV420", "size": frame_size},
            controls={"FrameRate": 30, "ExposureTime": 5000, "AeEnable": False},
        ))
        picam2.start()
        return ("pi", picam2)
    cap = cv2.VideoCapture(0, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  frame_size[0])
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, frame_size[1])
    return ("webcam", cap)


def grab_gray(cam, frame_size: tuple[int, int]):
    kind, src = cam
    if kind == "pi":
        frame = src.capture_array()
        return frame[:frame_size[1], :frame_size[0]] if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    ret, frame = src.read()
    if not ret:
        return None
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)


def solve_pose(corners: np.ndarray, K: np.ndarray, flag: int):
    obj = np.array(
        [[-MARKER_LENGTH / 2,  MARKER_LENGTH / 2, 0],
         [ MARKER_LENGTH / 2,  MARKER_LENGTH / 2, 0],
         [ MARKER_LENGTH / 2, -MARKER_LENGTH / 2, 0],
         [-MARKER_LENGTH / 2, -MARKER_LENGTH / 2, 0]],
        dtype=np.float32,
    )
    ok, rvec, tvec = cv2.solvePnP(obj, corners.astype(np.float32), K, np.zeros(5), flags=flag)
    if not ok:
        return None, None
    return rvec.flatten(), tvec.flatten()


def capture_corner_stream(cam, frame_size, detector, undistort_maps):
    map1, map2 = undistort_maps
    samples, rejected = [], 0
    while len(samples) < NUM_FRAMES:
        gray = grab_gray(cam, frame_size)
        if gray is None:
            continue
        undistorted = cv2.remap(gray, map1, map2, cv2.INTER_CUBIC)
        corners, ids, _ = detector.detectMarkers(undistorted)
        if ids is None or len(ids) != 1:
            rejected += 1
            continue
        samples.append(corners[0].reshape(4, 2))
        if (len(samples) % 50) == 0:
            print(f"    {len(samples)}/{NUM_FRAMES}")
    print(f"    Done. ({rejected} frames rejected.)")
    return np.array(samples)


# ── tests ────────────────────────────────────────────────────────────────────

def analyse_corner_noise(corners: np.ndarray) -> float:
    per_corner_std = corners.std(axis=0)
    return float(per_corner_std.mean())


def analyse_pose_noise(corners: np.ndarray, K: np.ndarray) -> np.ndarray:
    tvecs = []
    for c in corners:
        _, t = solve_pose(c, K, cv2.SOLVEPNP_IPPE_SQUARE)
        if t is not None:
            tvecs.append(t)
    return np.array(tvecs).std(axis=0) * 1000  # mm


def mean_distance(corners: np.ndarray, K: np.ndarray) -> float:
    tvecs = []
    for c in corners:
        _, t = solve_pose(c, K, cv2.SOLVEPNP_IPPE_SQUARE)
        if t is not None:
            tvecs.append(t)
    return float(np.linalg.norm(np.array(tvecs).mean(axis=0)) * 1000)  # mm


def wiring_sanity_check(K: np.ndarray) -> None:
    print("\n=== Wiring sanity check (synthetic corners) ===")
    obj = np.array(
        [[-MARKER_LENGTH / 2,  MARKER_LENGTH / 2, 0],
         [ MARKER_LENGTH / 2,  MARKER_LENGTH / 2, 0],
         [ MARKER_LENGTH / 2, -MARKER_LENGTH / 2, 0],
         [-MARKER_LENGTH / 2, -MARKER_LENGTH / 2, 0]],
        dtype=np.float32,
    )
    ideal_pix, _ = cv2.projectPoints(obj, np.zeros(3, dtype=np.float64), IDEAL_TVEC, K, np.zeros(5))
    _, t = solve_pose(ideal_pix.reshape(4, 2), K, cv2.SOLVEPNP_IPPE_SQUARE)
    err_mm = float(np.linalg.norm(t - IDEAL_TVEC) * 1000)
    print(f"  Input tvec  (mm): {IDEAL_TVEC * 1000}")
    print(f"  Output tvec (mm): {t * 1000}")
    print(f"  |Δ| = {err_mm:.4f} mm")
    if err_mm < 0.01:
        print("  [OK ] PnP wiring is correct.")
    else:
        print("  [WARN] Wiring may be off — check K / distortion handling.")


def solver_comparison(corners: np.ndarray, K: np.ndarray) -> None:
    print("\n=== Solver comparison (centre pose) ===")
    print(f"  {'solver':<14s}  σ_x (mm)  σ_y (mm)  σ_z (mm)")
    for flag, name in SOLVER_NAMES.items():
        ts = []
        for c in corners:
            _, t = solve_pose(c, K, flag)
            if t is not None:
                ts.append(t)
        s_mm = np.array(ts).std(axis=0) * 1000
        print(f"  {name:<14s} {s_mm[0]:>8.2f}  {s_mm[1]:>8.2f}  {s_mm[2]:>8.2f}")


# ── main flow ────────────────────────────────────────────────────────────────

def main() -> None:
    K, D, frame_size = load_calibration()
    print("Loaded calibration from camera_calib.toml")
    print(f"  Resolution: {frame_size}")
    print(f"  fx = {K[0,0]:.1f}, fy = {K[1,1]:.1f}")

    map1, map2 = cv2.fisheye.initUndistortRectifyMap(
        K, D, np.eye(3), K, frame_size, cv2.CV_16SC2
    )
    detector = init_detector()
    cam = init_camera(frame_size)

    wiring_sanity_check(K)

    print("\nMount the camera so it CANNOT move for the entire experiment.")
    print("You'll be prompted to reposition the marker for each of 5 poses.")

    results: list[dict] = []
    centre_corners: np.ndarray = None

    for i, pose_name in enumerate(POSE_NAMES):
        print(f"\n--- Pose {i + 1}/{len(POSE_NAMES)}: {pose_name} ---")
        print("Place the marker, step back, then press Enter to capture.")
        try:
            input()
        except EOFError:
            pass
        print(f"  Capturing {NUM_FRAMES} frames…")
        corners = capture_corner_stream(cam, frame_size, detector, (map1, map2))
        if i == 0:
            centre_corners = corners

        corner_sigma = analyse_corner_noise(corners)
        pose_sigma   = analyse_pose_noise(corners, K)
        distance     = mean_distance(corners, K)
        results.append({
            "name":   pose_name,
            "corner": corner_sigma,
            "pose":   pose_sigma,
            "dist":   distance,
        })
        print(f"  corner σ = {corner_sigma:.3f} px   pose σ = "
              f"({pose_sigma[0]:.2f}, {pose_sigma[1]:.2f}, {pose_sigma[2]:.2f}) mm   "
              f"distance = {distance:.0f} mm")

    if centre_corners is not None:
        solver_comparison(centre_corners, K)

    # ── final table ──────────────────────────────────────────────────────
    print("\n=== Summary across poses ===")
    print(f"{'pose':<32s} {'dist(mm)':>9s} {'cornerσ(px)':>13s} {'σ_x':>7s} {'σ_y':>7s} {'σ_z':>7s}")
    for r in results:
        p = r["pose"]
        print(f"{r['name']:<32s} {r['dist']:>9.0f} {r['corner']:>13.3f} {p[0]:>7.2f} {p[1]:>7.2f} {p[2]:>7.2f}")

    # Interpretation hints.
    print("\n=== Interpretation ===")
    centre = results[0]
    edges  = results[1:]
    edge_corner_max = max(r["corner"] for r in edges)
    edge_pose_xy_max = max(max(r["pose"][:2]) for r in edges)

    if centre["corner"] > 0.5:
        print("  Centre corner σ > 0.5 px → detection-limited everywhere.")
        print("    → Improve hardware (lighting, bigger markers, ChArUco diamonds).")
    elif centre["corner"] > 0.2:
        print("  Centre corner σ between 0.2–0.5 px → acceptable but improvable.")
    else:
        print("  Centre corner σ < 0.2 px → detection at the centre is excellent.")

    if edge_corner_max > 2 * centre["corner"]:
        print(f"  Edge corner σ ({edge_corner_max:.2f} px) is much worse than centre "
              f"({centre['corner']:.2f} px).")
        print("    → Pose jitter at workspace edges is geometry-limited.")
        print("    → Reach-to-edge motions will be jitterier than reach-to-centre.")
    else:
        print("  Corner σ is roughly uniform across poses → jitter is similar everywhere.")

    if max(centre["pose"][2], 0.1) > 5 * max(centre["pose"][0], centre["pose"][1]):
        print(f"  Depth σ_z ({centre['pose'][2]:.2f} mm) is much larger than lateral σ_x/σ_y.")
        print("    → That's normal for a single square marker (depth ambiguity).")
        print("    → A multi-marker board would dramatically cut depth jitter.")

    kind, src = cam
    if kind == "pi":
        src.stop()
    else:
        src.release()


if __name__ == "__main__":
    main()
