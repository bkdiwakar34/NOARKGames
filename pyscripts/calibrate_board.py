"""
Board-geometry calibration for the multi-marker NOARK device.

Measures each marker's fixed pose on the device by watching you slowly
rotate it in front of the camera, then writes pyscripts/board_geometry.json
for main.py's joint rigid-body solve.

Procedure:
  1. Mount the camera as for normal use; good, even light.
  2. Hold the device ~40-60 cm away and slowly rotate it so every adjacent
     pair of markers is seen together from many angles (the back marker
     links to the front ones through the side views).
  3. Watch the pair counters in the preview; aim for >= 30 per pair.
  4. Press S to solve and save, Q/Esc to abort.

Run: python pyscripts/calibrate_board.py
"""

import json
import os
import platform
import sys
from datetime import datetime

import cv2
import numpy as np
import toml
from cv2 import aruco

from board import (
    BoardGeometry,
    MARKER_LENGTH,
    MARKER_OFFSETS,
    marker_object_points,
)

MIN_PAIR_SAMPLES = 30
MAX_REPROJ_PX    = 1.0    # reject poorly-fitting single-marker solves
AMBIGUITY_RATIO  = 2.0    # reject frames where the 2nd IPPE solution fits nearly as well
ROT_TOL_RAD      = np.deg2rad(3.0)   # outlier trim: rotation residual
TRANS_TOL_M      = 0.005             # outlier trim: translation residual (5 mm)
REFERENCE_ID     = 12

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_PATH = os.path.join(_SCRIPT_DIR, "board_geometry.json")


# ── setup (mirrors diagnose_jitter.py) ───────────────────────────────────────

def load_calibration():
    settings_path = os.path.join(_SCRIPT_DIR, "..", "settings.json")
    calib_name = "camera_calib.toml"
    if os.path.exists(settings_path):
        with open(settings_path) as f:
            calib_name = json.load(f).get("calibration_file", calib_name)
    path = calib_name if os.path.isabs(calib_name) else os.path.join(_SCRIPT_DIR, calib_name)
    if not os.path.exists(path):
        sys.exit(f"Calibration file not found: {path}. Run calibrate_camera.py first.")
    data = toml.load(path)
    K = np.array(data["calibration"]["camera_matrix"]).reshape(3, 3)
    D = np.array(data["calibration"]["dist_coeffs"]).reshape(4, 1)
    res = data["calibration"].get("resolution", [1280, 800])
    print(f"Loaded calibration from {path}")
    return K, D, tuple(res)


def init_detector() -> aruco.ArucoDetector:
    params = aruco.DetectorParameters()
    params.useAruco3Detection     = True
    params.cornerRefinementMethod = aruco.CORNER_REFINE_APRILTAG
    dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
    return aruco.ArucoDetector(dictionary, params)


def init_camera(frame_size):
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


def grab_gray(cam, frame_size):
    kind, src = cam
    if kind == "pi":
        frame = src.capture_array()
        return frame[:frame_size[1], :frame_size[0]] if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    ret, frame = src.read()
    if not ret:
        return None
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)


def release_camera(cam):
    kind, src = cam
    if kind == "pi":
        src.stop()
    else:
        src.release()


# ── per-frame measurement ────────────────────────────────────────────────────

_MOBJ = marker_object_points(MARKER_LENGTH).astype(np.float64)


def robust_marker_pose(corner, K):
    """Single-marker pose, or None if the fit is poor or tilt-ambiguous."""
    img = np.asarray(corner).reshape(4, 2).astype(np.float64)
    n, rvecs, tvecs, errs = cv2.solvePnPGeneric(
        _MOBJ, img, K, np.zeros(5), flags=cv2.SOLVEPNP_IPPE_SQUARE
    )
    if n == 0:
        return None
    errs = np.asarray(errs).flatten()
    if errs[0] > MAX_REPROJ_PX:
        return None
    if n >= 2 and errs[1] < AMBIGUITY_RATIO * errs[0]:
        return None  # near-frontal view: the mirrored tilt fits almost as well
    R = cv2.Rodrigues(rvecs[0])[0]
    return R, np.asarray(tvecs[0]).flatten()


# ── averaging ────────────────────────────────────────────────────────────────

def mean_rotation(Rs):
    """Chordal mean: average the matrices, project back onto SO(3) via SVD."""
    U, _, Vt = np.linalg.svd(np.mean(Rs, axis=0))
    if np.linalg.det(U @ Vt) < 0:
        U[:, -1] *= -1
    return U @ Vt


def rotation_angle(R):
    return float(np.arccos(np.clip((np.trace(R) - 1) / 2, -1.0, 1.0)))


def robust_average_transform(samples):
    """Trimmed average of relative transforms. Returns (R, t, stats)."""
    Rs = np.array([s[0] for s in samples])
    ts = np.array([s[1] for s in samples])
    keep = np.ones(len(samples), dtype=bool)
    for _ in range(2):
        R_bar = mean_rotation(Rs[keep])
        t_bar = np.median(ts[keep], axis=0)
        ang = np.array([rotation_angle(R @ R_bar.T) for R in Rs])
        dt  = np.linalg.norm(ts - t_bar, axis=1)
        new_keep = (ang < ROT_TOL_RAD) & (dt < TRANS_TOL_M)
        if new_keep.sum() < max(10, 0.2 * len(samples)):
            print("    [warn] outlier trim too aggressive — keeping all samples")
            new_keep = np.ones(len(samples), dtype=bool)
        keep = new_keep
    R_bar = mean_rotation(Rs[keep])
    t_bar = ts[keep].mean(axis=0)
    stats = {
        "n_used": int(keep.sum()),
        "n_total": len(samples),
        "rot_residual_deg": float(np.rad2deg(
            np.mean([rotation_angle(R @ R_bar.T) for R in Rs[keep]]))),
        "trans_residual_mm": float(np.linalg.norm(ts[keep] - t_bar, axis=1).mean() * 1000),
    }
    return R_bar, t_bar, stats


# ── graph: chain pairwise transforms to the reference marker ─────────────────

def compose(Ra, ta, Rb, tb):
    """T_a<-c = T_a<-b @ T_b<-c."""
    return Ra @ Rb, Ra @ tb + ta


def invert(R, t):
    return R.T, -R.T @ t


def solve_board_frame(edges):
    """BFS from the reference marker through averaged pair transforms.
    edges: {(i, j): (R, t)} with i < j, mapping marker-j frame -> marker-i frame.
    Returns {id: (R, t)} marker frame -> board (reference-marker) frame."""
    adjacency = {}
    for (i, j), (R, t) in edges.items():
        adjacency.setdefault(i, []).append((j, R, t))
        Rj, tj = invert(R, t)
        adjacency.setdefault(j, []).append((i, Rj, tj))

    if REFERENCE_ID not in adjacency:
        sys.exit(f"Reference marker {REFERENCE_ID} has no usable pair samples — aborting.")

    poses = {REFERENCE_ID: (np.eye(3), np.zeros(3))}
    queue = [REFERENCE_ID]
    while queue:
        i = queue.pop(0)
        Ri, ti = poses[i]
        for j, R_ij, t_ij in adjacency.get(i, []):
            if j in poses:
                continue
            poses[j] = compose(Ri, ti, R_ij, t_ij)
            queue.append(j)
    return poses


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    K, D, frame_size = load_calibration()
    map1, map2 = cv2.fisheye.initUndistortRectifyMap(
        K, D, np.eye(3), K, frame_size, cv2.CV_16SC2
    )
    detector = init_detector()
    cam = init_camera(frame_size)

    device_ids = set(MARKER_OFFSETS)
    pair_samples: dict = {}
    print("\nSlowly rotate the device so every adjacent marker pair is seen together.")
    print("S = solve & save   Q/Esc = abort\n")

    aborted = False
    try:
        while True:
            gray = grab_gray(cam, frame_size)
            if gray is None:
                continue
            und = cv2.remap(gray, map1, map2, cv2.INTER_CUBIC)
            corners, ids, _ = detector.detectMarkers(und)

            vis = cv2.cvtColor(und, cv2.COLOR_GRAY2BGR)
            if ids is not None:
                vis = aruco.drawDetectedMarkers(vis, corners, ids)
                poses = {}
                for c, _id in zip(corners, ids.flatten()):
                    _id = int(_id)
                    if _id in device_ids:
                        p = robust_marker_pose(c, K)
                        if p is not None:
                            poses[_id] = p
                good = sorted(poses)
                for a in range(len(good)):
                    for b in range(a + 1, len(good)):
                        i, j = good[a], good[b]
                        Ri, ti = poses[i]
                        Rj, tj = poses[j]
                        # marker-j frame expressed in marker-i frame
                        pair_samples.setdefault((i, j), []).append(
                            (Ri.T @ Rj, Ri.T @ (tj - ti))
                        )

            y = 30
            for (i, j), s in sorted(pair_samples.items()):
                colour = (0, 255, 0) if len(s) >= MIN_PAIR_SAMPLES else (0, 165, 255)
                cv2.putText(vis, f"{i}-{j}: {len(s)}", (10, y),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, colour, 2)
                y += 28
            cv2.imshow("board calibration  [S=save  Q=abort]", cv2.resize(vis, (960, 600)))

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                aborted = True
                break
            if key == ord("s"):
                break
    except KeyboardInterrupt:
        aborted = True
    finally:
        release_camera(cam)
        cv2.destroyAllWindows()

    if aborted:
        print("Aborted — nothing written.")
        return

    # Average each pair with enough samples.
    edges, edge_stats = {}, {}
    print("\n=== Pair transforms ===")
    for pair, samples in sorted(pair_samples.items()):
        if len(samples) < MIN_PAIR_SAMPLES:
            print(f"  {pair[0]}-{pair[1]}: only {len(samples)} samples — skipped")
            continue
        R, t, stats = robust_average_transform(samples)
        edges[pair] = (R, t)
        edge_stats[f"{pair[0]}-{pair[1]}"] = stats
        print(f"  {pair[0]}-{pair[1]}: {stats['n_used']}/{stats['n_total']} used, "
              f"residual {stats['rot_residual_deg']:.2f} deg / "
              f"{stats['trans_residual_mm']:.2f} mm")

    if not edges:
        print("No pair reached the minimum sample count — nothing written.")
        return

    poses = solve_board_frame(edges)
    missing = device_ids - set(poses)
    if missing:
        print(f"\n[warn] markers never linked to the reference: {sorted(missing)}")
        print("       Re-run and show these together with an already-linked marker.")

    # Grip point: each marker independently predicts it; agreement validates
    # both the solved geometry and MARKER_OFFSETS.
    grip_ids = sorted(i for i in poses if i in MARKER_OFFSETS)
    grips = np.array([poses[i][0] @ MARKER_OFFSETS[i] + poses[i][1] for i in grip_ids])
    grip = grips.mean(axis=0)
    spread_mm = np.linalg.norm(grips - grip, axis=1) * 1000
    print("\n=== Grip-point consistency (per marker, mm from mean) ===")
    for i, d in zip(grip_ids, spread_mm):
        flag = "  <-- check MARKER_OFFSETS / gluing" if d > 5 else ""
        print(f"  marker {i}: {d:.1f} mm{flag}")

    board = BoardGeometry(MARKER_LENGTH, REFERENCE_ID, poses, grip)
    board.save(OUTPUT_PATH, meta={
        "date": datetime.now().isoformat(timespec="seconds"),
        "pair_stats": edge_stats,
        "grip_spread_mm": spread_mm.tolist(),
    })
    print(f"\nSaved {OUTPUT_PATH} ({len(poses)} markers).")
    print("main.py will now use the joint rigid-body solve automatically.")


if __name__ == "__main__":
    main()
