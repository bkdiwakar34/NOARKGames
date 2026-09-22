"""
Stereo extrinsic calibration for the Dragon Q6A dual-OV9281 rig.

Solves the fixed rigid transform between the two cameras (cam1 -> cam0) by
watching both cameras independently solve the pose of the SAME already-built
board (board_geometry.json, from calibrate_board.py) simultaneously, then
averaging many candidate (Rx, tx) samples with the same robust-averaging
machinery calibrate_board.py uses for marker-pair transforms. No new
checkerboard or target needed — this reuses the existing device/board.

Procedure:
  1. Run calibrate_camera.py for BOTH OV9281s first (two intrinsics files).
  2. Run calibrate_board.py once, if not already done (board_geometry.json).
  3. Mount both cameras in their final rigid position. Hold the device where
     BOTH cameras can see it, pause for a moment (auto-captures once held
     stable), then move to a clearly different pose and pause again —
     "hold-move-hold" through ~15-20 distinct poses, not one continuous pan.
  4. Watch the sample counter; aim for >= 20.
  5. Press S to solve and save, Q/Esc to abort.

Run: python pyscripts/calibration/calibrate_stereo.py

Imports no other script — only the two shared libraries: board.py (the device
model and pose solve, which must be the same one main.py tracks with) and
pose_averaging.py (the sample averaging, shared with calibrate_board.py).
"""

import json
import os
import sys
import threading
import time
from datetime import datetime

import cv2
import numpy as np
import toml
from cv2 import aruco

# pyscripts/, one folder up: board.py and pose_averaging.py are imported from
# there, and the tracker reads its calibration files there.
_PYSCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _PYSCRIPTS_DIR)

from board import BoardGeometry, estimate_board_pose
from pose_averaging import robust_average_transform

MIN_SAMPLES          = 20
STEREO_MAX_REPROJ_PX = 3.0
ROT_TOL_RAD          = np.deg2rad(2.0)   # tighter than calibrate_board's marker-pair tolerance —
TRANS_TOL_M          = 0.003             # camera-to-camera rigidity should exceed marker-gluing precision
MAX_FRAME_SKEW_S     = 0.02
STABLE_FRAMES        = 6     # consecutive stable frames (both cameras) before a pose counts — lower than
                              # calibrate_camera.py's 15 since requiring BOTH cameras stable at once for N
                              # frames compounds (P(both) = P(cam0) * P(cam1)), so a long run is much rarer here
STABLE_PX_THRESHOLD  = 4.0   # max corner motion (px) to count as still — 2.0 rarely passed in room light
COOLDOWN_S           = 2.0   # min seconds between accepted samples — forces a genuine move to the next pose

_SETTINGS_PATH = os.path.join(_PYSCRIPTS_DIR, "..", "settings.json")
OUTPUT_PATH = os.path.join(_PYSCRIPTS_DIR, "stereo_extrinsics.json")


def _settings() -> dict:
    if os.path.exists(_SETTINGS_PATH):
        with open(_SETTINGS_PATH) as f:
            return json.load(f)
    return {}


def load_calibration(settings_key: str = "calibration_file",
                     default_name: str = "camera_calib.toml"):
    """One camera's fisheye intrinsics from its .toml, named in settings.json."""
    calib_name = _settings().get(settings_key, default_name)
    path = calib_name if os.path.isabs(calib_name) else os.path.join(_PYSCRIPTS_DIR, calib_name)
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


class _LatestFrameSlot:
    """Newest frame from one camera's capture thread — overwritten, never queued."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._frame = None
        self._ts = None

    def put(self, frame, ts: float) -> None:
        with self._lock:
            self._frame, self._ts = frame, ts

    def get_latest(self):
        with self._lock:
            return self._frame, self._ts


class StillnessCheck:
    """Has the device stopped moving, as seen by one camera?

    Compares each frame's marker corners with a reference frame, marker by
    marker (matched by id — detectMarkers does not list markers in a fixed
    order), and calls it still only if every corner is within `threshold_px`
    of where it was. Any real movement, or a change in which markers are
    visible, re-anchors the reference to the current frame."""

    def __init__(self, threshold_px: float) -> None:
        self.threshold_px = threshold_px
        self._ref = None                     # {marker id: (4, 2) corner array}

    def is_still(self, corners, ids) -> bool:
        current = {int(i): np.asarray(c, dtype=np.float64).reshape(4, 2)
                   for i, c in zip(np.asarray(ids).flatten(), corners)}
        ref, self._ref = self._ref, current
        if ref is None or ref.keys() != current.keys():
            return False
        motion = max(float(np.max(np.linalg.norm(current[i] - ref[i], axis=1)))
                     for i in current)
        if motion > self.threshold_px:
            return False
        self._ref = ref                      # still: keep measuring against the anchor
        return True

    def reset(self) -> None:
        self._ref = None


def load_board() -> BoardGeometry:
    settings = _settings()
    name = settings.get("board_geometry_file", "board_geometry.json")
    path = name if os.path.isabs(name) else os.path.join(_PYSCRIPTS_DIR, name)
    if not os.path.exists(path):
        sys.exit(f"board_geometry.json not found at {path}. Run calibrate_board.py first.")
    return BoardGeometry.load(path)


def init_dual_camera(frame_size):
    from rcam import Camera

    settings = _settings()
    # All three, like main.py — never rely on what the last program left set.
    controls = {
        "ExposureTime": int(settings.get("rcam_exposure_us", 5000)),
        "AnalogueGain": float(settings.get("rcam_gain", 4.0)),
        "FrameRate":    int(settings.get("framerate", 100)),
    }
    cam0 = Camera(settings.get("rcam_id_0", "CAM2"))
    cam1 = Camera(settings.get("rcam_id_1", "CAM3"))
    for cam in (cam0, cam1):
        cam.configure(size=frame_size, bit_depth=8)
        cam.set_controls(controls)
        cam.start()

    slots = [_LatestFrameSlot(), _LatestFrameSlot()]
    stop = threading.Event()

    def _loop(cam, slot):
        while not stop.is_set():
            slot.put(cam.capture_array(), time.monotonic())

    threads = [
        threading.Thread(target=_loop, args=(cam0, slots[0]), daemon=True),
        threading.Thread(target=_loop, args=(cam1, slots[1]), daemon=True),
    ]
    for t in threads:
        t.start()
    return cam0, cam1, slots, stop, threads


def grab_gray_pair(slots):
    (frame0, ts0), (frame1, ts1) = slots[0].get_latest(), slots[1].get_latest()
    if frame0 is None or frame1 is None:
        return None
    if abs(ts0 - ts1) > MAX_FRAME_SKEW_S:
        return None
    return frame0, frame1


def main():
    board = load_board()
    K0, D0, frame_size = load_calibration()
    K1, D1, _ = load_calibration(settings_key="camera_calib_file_1", default_name="camera_calib_1.toml")
    map1_0, map2_0 = cv2.fisheye.initUndistortRectifyMap(K0, D0, np.eye(3), K0, frame_size, cv2.CV_16SC2)
    map1_1, map2_1 = cv2.fisheye.initUndistortRectifyMap(K1, D1, np.eye(3), K1, frame_size, cv2.CV_16SC2)
    detector = init_detector()
    cam0, cam1, slots, stop, threads = init_dual_camera(frame_size)

    samples = []
    stability0 = StillnessCheck(threshold_px=STABLE_PX_THRESHOLD)
    stability1 = StillnessCheck(threshold_px=STABLE_PX_THRESHOLD)
    stable_count = 0
    last_capture = 0.0
    flash_until = 0.0
    print("\nHold the device where BOTH cameras can see it, pause until it captures,")
    print("then move to a clearly different pose and pause again.")
    print("S = solve & save   Q/Esc = abort\n")

    aborted = False
    try:
        while True:
            pair = grab_gray_pair(slots)
            if pair is None:
                if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                    aborted = True
                    break
                continue
            frame0, frame1 = pair
            und0 = cv2.remap(frame0, map1_0, map2_0, cv2.INTER_CUBIC)
            und1 = cv2.remap(frame1, map1_1, map2_1, cv2.INTER_CUBIC)

            corners0, ids0, _ = detector.detectMarkers(und0)
            corners1, ids1, _ = detector.detectMarkers(und1)

            vis = cv2.cvtColor(und0, cv2.COLOR_GRAY2BGR)
            if ids0 is not None:
                vis = aruco.drawDetectedMarkers(vis, corners0, ids0)

            now = time.time()
            both_stable = False
            if ids0 is not None and ids1 is not None:
                # Evaluate both every frame (no short-circuit), so each camera's
                # reference stays current even while the other one is moving.
                still0 = stability0.is_still(corners0, ids0)
                still1 = stability1.is_still(corners1, ids1)
                both_stable = still0 and still1
            else:
                stability0.reset()
                stability1.reset()

            if both_stable:
                stable_count += 1
            else:
                stable_count = 0

            if (both_stable and stable_count >= STABLE_FRAMES
                    and now - last_capture > COOLDOWN_S):
                # Fresh solves (no ITERATIVE-guess reuse) so this sample isn't
                # biased toward the previous one.
                result0 = estimate_board_pose(board, corners0, ids0, K0, guess=None)
                result1 = estimate_board_pose(board, corners1, ids1, K1, guess=None)
                if result0 is not None and result1 is not None:
                    rvec0, tvec0, err0 = result0
                    rvec1, tvec1, err1 = result1
                    if err0 <= STEREO_MAX_REPROJ_PX and err1 <= STEREO_MAX_REPROJ_PX:
                        R0 = cv2.Rodrigues(rvec0)[0]
                        R1 = cv2.Rodrigues(rvec1)[0]
                        Rx_i = R0 @ R1.T
                        tx_i = tvec0 - Rx_i @ tvec1
                        samples.append((Rx_i, tx_i))
                        last_capture = now
                        flash_until = now + 0.5
                        stable_count = 0   # require a fresh hold before the next sample

            if now < flash_until:
                green = np.full_like(vis, (0, 255, 0))
                vis = cv2.addWeighted(vis, 0.5, green, 0.5, 0)

            colour = (0, 255, 0) if len(samples) >= MIN_SAMPLES else (0, 165, 255)
            if ids0 is None or ids1 is None:
                status = "Show device to both cameras"
            elif not both_stable:
                status = "Hold still..."
            elif last_capture > 0 and now - last_capture <= COOLDOWN_S:
                status = "Move to a new pose"
            else:
                status = "..."
            cv2.putText(vis, f"samples: {len(samples)}  ({status})", (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, colour, 2)
            cv2.imshow("stereo calibration  [S=save  Q=abort]", cv2.resize(vis, (960, 600)))

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                aborted = True
                break
            if key == ord("s"):
                break
    except KeyboardInterrupt:
        aborted = True
    finally:
        stop.set()
        for t in threads:
            t.join(timeout=1.0)
        cam0.stop()
        cam1.stop()
        cv2.destroyAllWindows()

    if aborted:
        print("Aborted — nothing written.")
        return
    if len(samples) < MIN_SAMPLES:
        print(f"Only {len(samples)} samples (< {MIN_SAMPLES}) — nothing written. "
              f"Move the device more so both cameras see the board from varied angles.")
        return

    Rx, tx, stats = robust_average_transform(samples, ROT_TOL_RAD, TRANS_TOL_M)
    print(f"\nExtrinsic solved: {stats['n_used']}/{stats['n_total']} samples used, "
          f"residual {stats['rot_residual_deg']:.2f} deg / {stats['trans_residual_mm']:.2f} mm")

    with open(OUTPUT_PATH, "w") as f:
        json.dump({
            "Rx": Rx.tolist(),
            "tx": tx.tolist(),
            "meta": {
                "date": datetime.now().isoformat(timespec="seconds"),
                "n_used": stats["n_used"],
                "n_total": stats["n_total"],
                "rot_residual_deg": stats["rot_residual_deg"],
                "trans_residual_mm": stats["trans_residual_mm"],
            },
        }, f, indent=2)
    print(f"\nSaved {OUTPUT_PATH}.")
    print('main.py will use this automatically when camera_backend is "rcam_dual".')


if __name__ == "__main__":
    main()
