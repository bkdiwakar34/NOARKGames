import csv
import json
import os
import platform
import socket
import struct
import threading
import time
from datetime import datetime
from typing import Optional

import cv2
import numpy as np
from cv2 import aruco
from scipy.spatial.transform import Rotation as ScipyRotation

import board as board_model
from board import BoardGeometry, estimate_board_pose
from filters import (
    CornerStabilityFilter,
    ExponentialMovingAverageFilter3D,
    KalmanFilter3D,
    NoOpFilter3D,
    OneEuroFilter3D,
)
from pose_averaging import rotation_angle


class _LatestFrameSlot:
    """Lock-guarded single-slot frame holder for a capture thread — always
    exposes the newest frame, overwriting the previous one rather than
    queuing (a queue.Queue's FIFO/blocking semantics are the wrong fit when
    all a reader ever wants is "whatever's newest")."""

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


def _weighted_quaternion_average(Ra: np.ndarray, Rb: np.ndarray,
                                  wa: float, wb: float) -> np.ndarray:
    """Two-rotation weighted average: flip to the same quaternion
    hemisphere, weighted-sum, renormalize. Sufficient for N=2 with an
    upstream disagreement gate already rejecting cases (large-angle
    disagreement) where full Markley-style averaging would matter."""
    qa = ScipyRotation.from_matrix(Ra).as_quat()
    qb = ScipyRotation.from_matrix(Rb).as_quat()
    if np.dot(qa, qb) < 0:
        qb = -qb
    q = wa * qa + wb * qb
    q /= np.linalg.norm(q)
    return ScipyRotation.from_quat(q).as_matrix()


def _load_settings() -> dict:
    """Read settings.json from the project root (one level above pyscripts/)."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(script_dir, "..", "settings.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    print(f"settings.json not found at {path}, using defaults")
    return {"debug": False}


class Config:
    FRAME_SIZE = (1280, 800)        # OV9281 native resolution; matches camera_calib.toml
    MARKER_LENGTH = board_model.MARKER_LENGTH
    UDP_IP = "localhost"
    ALPHA = 0.4
    ORIGIN_LOCK_FRAMES = 10         # consecutive stable frames required before locking the world origin
    ORIGIN_STABLE_PX   = 2.0        # max mean corner motion (px) between frames to count as stable
    BOARD_MAX_REPROJ_PX = 3.0       # board solve worse than this -> re-initialise without the previous-frame guess
    # Grip-point offsets now live in board.py (shared with calibrate_board.py).
    MARKER_OFFSETS = board_model.MARKER_OFFSETS


class MainClass:
    def __init__(self, cam_calib_path: str, settings: Optional[dict] = None) -> None:
        if settings is None:
            settings = {}

        self.debug = settings.get("debug", False)
        self.udp_port        = settings.get("udp_port", 12345)

        filter_type = str(settings.get("filter_type", "ema")).lower()
        if filter_type == "none":
            self.filter = NoOpFilter3D()
        elif filter_type == "kalman":
            kf_proc = float(settings.get("kalman_process_noise",     0.01))
            kf_meas = float(settings.get("kalman_measurement_noise", 0.05))
            self.filter = KalmanFilter3D(process_noise=kf_proc, measurement_noise=kf_meas)
        elif filter_type == "one_euro":
            oe_min   = float(settings.get("one_euro_min_cutoff", 1.0))
            oe_beta  = float(settings.get("one_euro_beta",       0.007))
            oe_dcut  = float(settings.get("one_euro_d_cutoff",   1.0))
            self.filter = OneEuroFilter3D(min_cutoff=oe_min, beta=oe_beta, d_cutoff=oe_dcut)
        else:
            self.filter = ExponentialMovingAverageFilter3D(alpha=Config.ALPHA)
        print(f"Using {filter_type} filter for smoothing")
        self.frame_size    = Config.FRAME_SIZE
        self.marker_length = Config.MARKER_LENGTH

        import toml
        calib_data = toml.load(cam_calib_path)
        self.camera_matrix = np.array(calib_data["calibration"]["camera_matrix"]).reshape(3, 3)
        self.dist_coeffs   = np.array(calib_data["calibration"]["dist_coeffs"])

        # Two ways to remove the lens distortion, same result downstream:
        #
        #   undistort_image = True   remap all 1,024,000 pixels once per frame, then
        #                            detect on the corrected image (the original path).
        #   undistort_image = False  detect on the raw frame and undistort only the
        #                            handful of corner points that come back. Costs a
        #                            few dozen point transforms instead of a megapixel
        #                            remap. calibrate_camera.py's verify() already does
        #                            exactly this.
        #
        # Either way the corners reaching solvePnP are pinhole-equivalent with
        # intrinsics = camera_matrix, so it is still called with np.zeros(5).
        self._undistort_image = bool(settings.get("undistort_image", True))
        if self._undistort_image:
            self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
                self.camera_matrix, self.dist_coeffs, np.eye(3),
                self.camera_matrix, self.frame_size, cv2.CV_16SC2,
            )
        else:
            self.map1 = self.map2 = None
            print("undistort_image=False — detecting on the raw frame, "
                  "undistorting corners only")

        # Leave cores free for Godot on the Pi — OpenCV otherwise parallelises
        # detection across ALL cores and starves the game's render thread.
        opencv_threads = int(settings.get("opencv_threads", 2))
        if opencv_threads > 0:
            cv2.setNumThreads(opencv_threads)
            print(f"OpenCV limited to {opencv_threads} threads")

        self._corner_refine_name = str(settings.get("corner_refine", "contour")).lower()
        self._thresh_win = int(settings.get("adaptive_thresh_win_size", 15))
        self.detector = self._init_detector()

        pnp_map = {
            "iterative": cv2.SOLVEPNP_ITERATIVE,
            "square":    cv2.SOLVEPNP_IPPE_SQUARE,
        }
        pnp_name = str(settings.get("pnp_method", "square")).lower()
        self._pnp_flag = pnp_map.get(pnp_name, cv2.SOLVEPNP_IPPE_SQUARE)
        print(f"PnP method: {pnp_name}  (options: {list(pnp_map)})")

        self._framerate = int(settings.get("framerate", 100))
        print(f"Camera framerate target: {self._framerate}")

        # Skip solvePnP when corners haven't moved — reuse last pose instead.
        # Eliminates per-frame jitter from solvePnP returning slightly different
        # answers on near-identical inputs.
        stability_threshold = float(settings.get("corner_stability_threshold", 2.0))
        self.corner_stability = CornerStabilityFilter(threshold=stability_threshold)
        self.corner_stability_1 = CornerStabilityFilter(threshold=stability_threshold)  # cam1, dual-camera mode only
        self._cached_rvecs = None
        self._cached_tvecs = None

        # Joint rigid-body solve: enabled when board_geometry.json exists
        # (produced by calibrate_board.py). Falls back to per-marker PnP +
        # weighted averaging otherwise.
        self.board = None
        self._board_rvec = None      # last good board pose — ITERATIVE guess for the next frame
        self._board_tvec = None
        self._cached_board_pose = None
        self._board_rvec_1 = None    # cam1's own guess cache, dual-camera mode only
        self._board_tvec_1 = None
        self._cached_board_pose_1 = None
        self._origin_R    = None     # locked board orientation (world frame)
        self._origin_grip = None     # locked grip position in camera frame
        if settings.get("use_board_pnp", True):
            board_name = settings.get("board_geometry_file", "board_geometry.json")
            board_path = (
                board_name if os.path.isabs(board_name)
                else os.path.join(os.path.dirname(os.path.abspath(__file__)), board_name)
            )
            if os.path.exists(board_path):
                self.board = BoardGeometry.load(board_path)
                print(f"Joint rigid-body PnP enabled: {len(self.board.marker_poses)} "
                      f"markers from {board_path}")
            else:
                print(f"No board geometry at {board_path} — using per-marker PnP. "
                      f"Run calibrate_board.py to enable the joint solve.")

        # Demo comparison mode, switched at runtime by a "SETUP:<markers>,<algo>"
        # UDP command from Godot's settings menu (old vs new setup for demos).
        self._demo_subset = set(int(i) for i in settings.get("demo_subset_ids", [12, 20]))
        self._allowed_ids = None          # None = use all detected markers
        self._use_rigid   = True          # joint solve when board geometry is loaded
        self._equal_weight = False        # per-marker path: equal vs pixel-area weighting
        self._setup_state = ("all", "rigid")

        # Persisted world origin: the locked (R, grip) live in the CAMERA frame,
        # so as long as the camera doesn't move they stay valid across restarts —
        # the screen calibration in Godot then survives too. Delete the file
        # (or set persist_origin false) after physically moving the camera.
        self._persist_origin = bool(settings.get("persist_origin", True))
        self._origin_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "origin_lock.json"
        )

        self.picam2 = None                          # Pi camera object (set in _init_rpi_camera)
        self.video_frame  = None                    # latest captured image, refreshed every frame
        self.first_frame  = True                    # True until the world origin has been locked (see _maybe_lock_origin)
        self.save_path    = None                    # folder for this patient's CSV, created on first USER: message
        self.csv_writer   = None                    # csv.writer for the active session, created alongside save_path
        self._csv_file    = None                    # underlying file handle for csv_writer; closed when CHANGE happens or run() exits
        self.record       = False                   # True once Godot has sent USER: and we should log rows
        self.received_message: bytes = b""          # most recent UDP command from Godot (sticky — last command is reused each frame)
        self.addr         = None                    # Godot's UDP address, learned from the first incoming packet
        self._hid         = None                    # current patient hospital ID; set on first USER:/CHANGE: message
        self._dbg_last_print = 0.0                  # timestamp of last debug print, to throttle to ~1/sec

        # Per-stage timing buffer (filled by process_frame, drained by the debug print
        # once a second). Each entry is [capture_ms, remap_ms, detect_ms, pose_send_ms].
        self._stage_times = []
        # Tracker timing log — opened only when debug is on. Plays nice with
        # `tail -f` from another terminal even when Godot launches main.py.
        self._timing_log = open("/tmp/tracker_timing.log", "a", buffering=1) if self.debug else None
        if self._timing_log is not None:
            self._timing_log.write(f"\n--- tracker started {datetime.now().isoformat(timespec='seconds')} ---\n")

        # World-origin lock state: don't anchor the reference frame to a single noisy detection.
        # Wait for ORIGIN_LOCK_FRAMES consecutive frames with the same marker set and < ORIGIN_STABLE_PX motion.
        self._origin_stable_count = 0
        self._prev_corners = None
        self._prev_ids = None

        # Timestamp of the last fresh UDP packet from Godot. run() exits if no fresh packet
        # arrives for 3 seconds — Godot sends "CONNECTED" every 100 ms by default, so this
        # only trips when Godot has actually died or stopped responding.
        self._last_msg_time = time.time()

        self._curr_session = os.path.join(
            "Session-" + datetime.today().strftime("%Y-%m-%d"), "MovementData"
        )

        # Reuse the previous session's world origin (see _persist_origin above).
        # Must run after first_frame is initialised.
        if self._persist_origin and os.path.exists(self._origin_path):
            self._load_origin()

        # Dual-camera (rcam / Dragon Q6A) fusion state — only exercised when
        # camera_backend == "rcam_dual"; harmless to set up unconditionally.
        self.camera_matrix_1 = None
        self.map1_1 = None
        self.map2_1 = None
        self._stereo_Rx = None                # cam1 -> cam0 rotation, from stereo_extrinsics.json
        self._stereo_tx = None                # cam1 -> cam0 translation
        self._stereo_max_reproj_px      = float(settings.get("stereo_max_reproj_px", 4.0))
        self._stereo_disagree_rot_rad   = np.deg2rad(float(settings.get("stereo_disagree_rot_deg", 6.0)))
        self._stereo_disagree_trans_m   = float(settings.get("stereo_disagree_trans_mm", 20.0)) / 1000.0
        self._stereo_max_frame_skew_s   = float(settings.get("stereo_max_frame_skew_ms", 20.0)) / 1000.0
        self._origin_stable_m           = float(settings.get("origin_stable_m", 0.002))
        self._origin_stable_rad         = float(settings.get("origin_stable_rad", 0.0175))
        self._disagree_count  = 0             # consecutive frames cam0/cam1 poses disagreed too much
        self._disagree_warned = False
        self._prev_fused_pose = None          # pose-space stability gate for dual-camera origin lock

        # Camera
        self._camera_backend = str(settings.get("camera_backend", "auto")).lower()
        self._dual_camera = self._camera_backend == "rcam_dual"
        self._init_camera_backend(settings)

        self._init_udp_socket()

    # ── detector ─────────────────────────────────────────────────────────────

    def _init_detector(self):
        refine_map = {
            "none":     aruco.CORNER_REFINE_NONE,
            "subpix":   aruco.CORNER_REFINE_SUBPIX,
            "contour":  aruco.CORNER_REFINE_CONTOUR,
            "apriltag": aruco.CORNER_REFINE_APRILTAG,
        }
        refine_flag = refine_map.get(self._corner_refine_name, aruco.CORNER_REFINE_CONTOUR)
        params = aruco.DetectorParameters()
        params.useAruco3Detection     = True
        params.cornerRefinementMethod = refine_flag
        # Single adaptive-threshold pass instead of the default three (window
        # sizes 3/13/23): our marker sizes are a known range, so one mid-size
        # window finds them at ~1/3 the detection cost. 0 = OpenCV default.
        if self._thresh_win > 0:
            params.adaptiveThreshWinSizeMin  = self._thresh_win
            params.adaptiveThreshWinSizeMax  = self._thresh_win
            params.adaptiveThreshWinSizeStep = 1
            print(f"Adaptive threshold: single {self._thresh_win} px window")
        dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
        print(f"Detector corner refinement: {self._corner_refine_name}")
        return aruco.ArucoDetector(dictionary, params)


    # ── cameras ──────────────────────────────────────────────────────────────

    def _init_rpi_camera(self) -> None:
        from picamera2 import Picamera2

        self.picam2 = Picamera2()
        config = self.picam2.create_video_configuration(
            # YUV420 is the camera's native format → no conversion cost.
            # Y plane is already grayscale, which is what marker detection uses.
            {"format": "YUV420", "size": self.frame_size},
            controls={
                "FrameRate": self._framerate,  # target rate; real-world rate may be lower
                "ExposureTime": 5000,          # 5 ms — short enough to freeze hand motion (no blur on marker corners)
                "AeEnable": False,             # lock auto-exposure off so the camera can't override ExposureTime
            },
        )
        self.picam2.configure(config)
        self.picam2.start()

        # Auto-exposure tune-then-lock disabled for now — the 1-second AE convergence
        # was adding noticeable lag and the chosen exposure caused lag during gameplay.
        # Re-enable later if room lighting becomes an issue.
        # time.sleep(1.0)
        # meta = self.picam2.capture_metadata()
        # exposure = min(int(meta.get("ExposureTime", 5000)), 20_000)
        # gain     = float(meta.get("AnalogueGain", 1.0))
        # self.picam2.set_controls({"AeEnable": False, "ExposureTime": exposure, "AnalogueGain": gain})
        # print(f"Camera exposure locked at {exposure} us, gain {gain:.2f}")

    def _init_camera(self) -> None:
        self.camera = cv2.VideoCapture(0, cv2.CAP_DSHOW)
        self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        self.camera.set(cv2.CAP_PROP_FPS, 30)

    def _init_camera_backend(self, settings: dict) -> None:
        """Dispatches to legacy picamera2, the new rcam backend (single or
        dual OV9281), or the Windows cv2.VideoCapture dev fallback.

        "auto" reproduces today's exact platform.system()=="Linux" -> picamera2
        behavior — existing Pi deployments need no settings.json changes at
        all. Dragon Q6A deployments opt in explicitly via camera_backend."""
        if self._camera_backend == "rcam_dual":
            self._init_rcam_dual(settings)
        elif self._camera_backend == "rcam_single":
            self._init_rcam_single(settings)
        elif platform.system() == "Linux":
            self._init_rpi_camera()
        else:
            self._init_camera()

    def _rcam_controls(self, settings: dict) -> dict:
        """Exposure/gain/framerate controls for an rcam Camera — mirrors the
        fixed 5 ms exposure / locked auto-exposure / target framerate used
        for the picamera2 path."""
        return {
            "ExposureTime": int(settings.get("rcam_exposure_us", 5000)),
            "AnalogueGain": float(settings.get("rcam_gain", 4.0)),
            "FrameRate": self._framerate,
        }

    def _start_capture_thread(self, cam_index: int) -> None:
        self._cam_threads[cam_index] = threading.Thread(
            target=self._capture_loop, args=(cam_index,), daemon=True
        )
        self._cam_threads[cam_index].start()

    def _init_rcam_single(self, settings: dict) -> None:
        """One rcam camera (Dragon Q6A, single-camera mode) — same shape as
        _init_rpi_camera but for the new V4L2-direct backend."""
        from rcam import Camera

        cam_id = settings.get("rcam_id_0", "CAM2")
        cam = Camera(cam_id)
        cam.configure(size=self.frame_size, bit_depth=8)
        cam.set_controls(self._rcam_controls(settings))
        cam.start()

        self._rcam         = [cam]
        self._frame_slots   = [_LatestFrameSlot()]
        self._cam_errors    = [None]
        self._cam_error_logged = [False]
        self._cam_threads   = [None]
        self._stop_capture  = threading.Event()
        self._start_capture_thread(0)

    def _init_rcam_dual(self, settings: dict) -> None:
        """Two rcam cameras (Dragon Q6A dual-camera mode), each with its own
        capture thread, intrinsics/undistort map, and pose-solve state."""
        from rcam import Camera

        cam_ids = [settings.get("rcam_id_0", "CAM2"), settings.get("rcam_id_1", "CAM3")]
        controls = self._rcam_controls(settings)
        self._rcam = []
        for cam_id in cam_ids:
            cam = Camera(cam_id)
            cam.configure(size=self.frame_size, bit_depth=8)
            cam.set_controls(controls)
            cam.start()
            self._rcam.append(cam)

        self._frame_slots      = [_LatestFrameSlot(), _LatestFrameSlot()]
        self._cam_errors       = [None, None]
        self._cam_error_logged = [False, False]
        self._cam_threads      = [None, None]
        self._stop_capture     = threading.Event()
        self._start_capture_thread(0)
        self._start_capture_thread(1)

        self._load_second_intrinsics(settings)
        self._load_stereo_extrinsics(settings)

    def _load_second_intrinsics(self, settings: dict) -> None:
        """Cam1's own fisheye intrinsics — each OV9281 needs its own
        calibration file, same shape as the one MainClass.__init__ already
        loaded for cam0 via cam_calib_path."""
        import toml

        _pyscripts_dir = os.path.dirname(os.path.abspath(__file__))
        calib_name = settings.get("camera_calib_file_1", "camera_calib_1.toml")
        path = calib_name if os.path.isabs(calib_name) else os.path.join(_pyscripts_dir, calib_name)
        if not os.path.exists(path):
            raise FileNotFoundError(
                f"Dual-camera mode needs cam1's own intrinsics — not found at {path}. "
                f"Run calibrate_camera.py for the second OV9281 first."
            )
        calib_data = toml.load(path)
        self.camera_matrix_1 = np.array(calib_data["calibration"]["camera_matrix"]).reshape(3, 3)
        dist_coeffs_1 = np.array(calib_data["calibration"]["dist_coeffs"])
        self.map1_1, self.map2_1 = cv2.fisheye.initUndistortRectifyMap(
            self.camera_matrix_1, dist_coeffs_1, np.eye(3),
            self.camera_matrix_1, self.frame_size, cv2.CV_16SC2,
        )
        print(f"Loaded cam1 calibration from {path}")

    def _load_stereo_extrinsics(self, settings: dict) -> None:
        """(Rx, tx): cam1 -> cam0 rigid transform, produced by calibrate_stereo.py."""
        _pyscripts_dir = os.path.dirname(os.path.abspath(__file__))
        name = settings.get("stereo_extrinsics_file", "stereo_extrinsics.json")
        path = name if os.path.isabs(name) else os.path.join(_pyscripts_dir, name)
        if not os.path.exists(path):
            raise FileNotFoundError(
                f"Dual-camera mode needs the cam-to-cam extrinsic calibration — not found "
                f"at {path}. Run calibrate_stereo.py first."
            )
        with open(path) as f:
            data = json.load(f)
        self._stereo_Rx = np.array(data["Rx"], dtype=np.float64).reshape(3, 3)
        self._stereo_tx = np.array(data["tx"], dtype=np.float64).flatten()
        print(f"Loaded stereo extrinsics from {path}")

    def _capture_loop(self, cam_index: int) -> None:
        """Runs in a daemon thread: writes (frame, timestamp) into this
        camera's slot every time a new frame is ready. capture_array() is
        blocking with no timeout; on stream-end it raises, which we record
        as this camera's error rather than letting it cross the thread
        boundary and kill the process silently.

        time.sleep(0) after each frame is a cooperative yield — same "leave
        room for other threads" principle as opencv_threads, in case this
        loop ever gets more CPU-greedy than intended (e.g. frames arriving
        faster than expected) and starves Godot's own background thread."""
        try:
            while not self._stop_capture.is_set():
                frame = self._rcam[cam_index].capture_array()
                self._frame_slots[cam_index].put(frame, time.monotonic())
                time.sleep(0)
        except Exception as exc:
            self._cam_errors[cam_index] = exc

    def _capture_single_frame(self):
        """One frame from whichever single-camera backend is active. Returns
        None if a frame isn't available this iteration (dev cv2 fallback, or
        an rcam capture thread that hasn't produced a frame yet)."""
        if self._camera_backend == "rcam_single":
            frame, _ts = self._frame_slots[0].get_latest()
            if self._cam_errors[0] is not None:
                raise self._cam_errors[0]
            return frame
        if platform.system() == "Linux":
            # YUV420 comes back as (h*3/2, w): the Y plane is the first h rows,
            # then the quarter-resolution U and V planes. Y alone is the
            # grayscale image everything downstream wants. Slicing here matters
            # when undistort_image is False — with the remap in place the output
            # was sized from the maps, which hid the extra rows; without it,
            # detectMarkers would otherwise threshold 400 rows of chroma.
            frame = self.picam2.capture_array()
            return frame[:self.frame_size[1], :self.frame_size[0]]
        ret, frame = self.camera.read()
        if not ret or frame is None:
            return None
        return frame

    def _capture_dual_frames(self):
        """Latest frame from each capture thread's slot. A dead camera
        (thread raised, e.g. on stream end) reports None here from then on —
        _fuse_board_poses already falls back to the surviving camera's solo
        pose, so no separate "degrade to single camera" path is needed.
        Raises only when both cameras have died (nothing left to track,
        mirroring run()'s existing "no fresh UDP for 3s" exit)."""
        if self._cam_errors[0] is not None and self._cam_errors[1] is not None:
            raise RuntimeError(
                f"Both camera threads died (cam0: {self._cam_errors[0]!r}, "
                f"cam1: {self._cam_errors[1]!r})"
            )
        for i in (0, 1):
            if self._cam_errors[i] is not None and not self._cam_error_logged[i]:
                print(f"[warn] camera {i} capture thread died ({self._cam_errors[i]!r}) "
                      f"— continuing tracking on the surviving camera.")
                self._cam_error_logged[i] = True

        frame0, ts0 = (None, None) if self._cam_errors[0] is not None else self._frame_slots[0].get_latest()
        frame1, ts1 = (None, None) if self._cam_errors[1] is not None else self._frame_slots[1].get_latest()
        if frame0 is not None and frame1 is not None and abs(ts0 - ts1) > self._stereo_max_frame_skew_s:
            # Stale pairing during fast motion — treat cam1 as "not ready yet"
            # rather than fusing a mismatched pair; usually re-syncs next frame.
            frame1 = None
        return frame0, frame1

    # ── transport init ────────────────────────────────────────────────────────

    def _init_udp_socket(self) -> None:
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.bind((Config.UDP_IP, self.udp_port))
        self.udp_socket.setblocking(False)
        print("UDP socket bound to", self.udp_socket.getsockname())

    # ── transport send / receive ──────────────────────────────────────────────

    def _recv_command(self) -> bytes:
        """Return the latest command from Godot, or b'' if none."""
        try:
            data, self.addr = self.udp_socket.recvfrom(30)
            self._last_msg_time = time.time()
            return data
        except socket.error:
            return b""

    def _send_coordinates(self, command: str, coords: np.ndarray) -> None:
        """Map a string command to a float code and stream 4 floats to Godot."""
        if self.addr is None:
            return
        code_map = {"STOP": -99.0, "START": 2.0, "RESET": 5.0}
        msg_code = code_map.get(command, 2.0)
        data = np.append(msg_code, coords).flatten()
        data_bytes = struct.pack("<" + "f" * len(data), *data)
        self.udp_socket.sendto(data_bytes, self.addr)

    # ── pose estimation ───────────────────────────────────────────────────────

    def _undistort_corners(self, corners):
        """Map corners detected in the raw (still distorted) frame into the
        pinhole-equivalent coordinates the rest of the pipeline assumes.

        Used only when undistort_image is False. Replaces a full-frame remap
        with four point transforms per marker — the same trick verify() in
        calibrate_camera.py uses. P=camera_matrix puts the results back in
        pixel units rather than normalised ones, so everything downstream
        (corner stability checks, solvePnP, reprojection error) is unchanged."""
        if corners is None or len(corners) == 0:
            return corners
        out = []
        for c in corners:
            pts = np.asarray(c, dtype=np.float64).reshape(-1, 1, 2)
            ud = cv2.fisheye.undistortPoints(
                pts, self.camera_matrix, self.dist_coeffs, P=self.camera_matrix
            )
            out.append(ud.reshape(1, -1, 2).astype(np.float32))
        return out

    def estimate_pose(self, corners):
        marker_points = np.array(
            [
                [-self.marker_length / 2,  self.marker_length / 2, 0],
                [ self.marker_length / 2,  self.marker_length / 2, 0],
                [ self.marker_length / 2, -self.marker_length / 2, 0],
                [-self.marker_length / 2, -self.marker_length / 2, 0],
            ],
            dtype=np.float32,
        )
        rvecs, tvecs = [], []
        zero_dist = np.zeros(5)  # frame is undistorted upstream → no residual distortion
        for corner in corners:
            success, rvec, tvec = cv2.solvePnP(
                marker_points, corner, self.camera_matrix, zero_dist,
                flags=self._pnp_flag,
            )
            if success:
                rvecs.append(rvec.flatten())
                tvecs.append(tvec.flatten())
        return np.array(rvecs), np.array(tvecs)

    def _solve_camera_pose(self, cam_index: int, corners, ids):
        """Board-pose solve for one camera, using its own camera_matrix,
        stability filter, and ITERATIVE-guess cache. Returns (rvec, tvec,
        reproj), or None if no known marker is visible, the solve fails, or
        (dual-camera mode only) reproj exceeds stereo_max_reproj_px — a bad
        solve here must be hard-rejected before it reaches the fusion
        weighting, since inverse-variance weighting only *down*-weights a
        bad estimate, it doesn't reject one.

        cam_index 0 is also how the single-camera path solves its pose now
        (this is the same guess-cache/BOARD_MAX_REPROJ_PX-reinit logic that
        used to live inline in _process_board, just parameterized so cam1
        can reuse it with its own state)."""
        if cam_index == 0:
            camera_matrix = self.camera_matrix
            stability     = self.corner_stability
            cached        = self._cached_board_pose
            guess_rvec    = self._board_rvec
            guess_tvec    = self._board_tvec
        else:
            camera_matrix = self.camera_matrix_1
            stability     = self.corner_stability_1
            cached        = self._cached_board_pose_1
            guess_rvec    = self._board_rvec_1
            guess_tvec    = self._board_tvec_1

        if stability.is_stable(corners, ids) and cached is not None:
            rvec, tvec, reproj = cached
        else:
            guess = (guess_rvec, guess_tvec) if guess_rvec is not None else None
            result = estimate_board_pose(self.board, corners, ids, camera_matrix, guess)
            if result is None:
                return None
            rvec, tvec, reproj = result
            # A stale guess (fast motion, re-entry after occlusion) can trap the
            # iterative solver in a bad local minimum — re-initialise from scratch.
            if guess is not None and reproj > Config.BOARD_MAX_REPROJ_PX:
                fresh = estimate_board_pose(self.board, corners, ids, camera_matrix, None)
                if fresh is not None and fresh[2] < reproj:
                    rvec, tvec, reproj = fresh
            cached = (rvec, tvec, reproj)
            if cam_index == 0:
                self._cached_board_pose = cached
                self._board_rvec, self._board_tvec = rvec, tvec
            else:
                self._cached_board_pose_1 = cached
                self._board_rvec_1, self._board_tvec_1 = rvec, tvec

        if self._dual_camera and reproj > self._stereo_max_reproj_px:
            return None
        return rvec, tvec, reproj

    def _transform_pose_to_cam0(self, pose1):
        """cam1's (rvec, tvec, reproj) -> (R, t, reproj) expressed in cam0's
        frame, via the calibrated extrinsic self._stereo_Rx/self._stereo_tx."""
        rvec1, tvec1, reproj1 = pose1
        R1 = cv2.Rodrigues(rvec1)[0]
        R1p = self._stereo_Rx @ R1
        t1p = self._stereo_Rx @ tvec1 + self._stereo_tx
        return R1p, t1p, reproj1

    def _fuse_board_poses(self, pose0, pose1):
        """Combines cam0's and cam1's independent board-pose solves into one
        pose in cam0's frame.

        If only one camera saw the board, its pose is used directly
        (transformed into cam0's frame first if it's cam1) — this is also
        how a dead or occluded camera degrades gracefully to single-camera
        tracking; no separate fallback path is needed.

        If both saw it but disagree by more than the configured tolerance
        (stale stereo calibration, or a transient bad solve in one camera),
        falls back to the lower-reprojection-error camera for this frame and
        logs a one-time warning after the disagreement persists — never
        fuses garbage, never crashes.

        Otherwise fuses via inverse-reprojection-error-squared-weighted
        translation mean and a simple weighted quaternion average for
        rotation (full Markley-style averaging is unnecessary for N=2 with
        this disagreement gate already in place)."""
        if pose0 is None and pose1 is None:
            return None
        if pose1 is None:
            return pose0
        R1p, t1p, e1 = self._transform_pose_to_cam0(pose1)
        if pose0 is None:
            return cv2.Rodrigues(R1p)[0].flatten(), t1p, e1

        rvec0, tvec0, e0 = pose0
        R0 = cv2.Rodrigues(rvec0)[0]

        ang  = rotation_angle(R0 @ R1p.T)
        dist = float(np.linalg.norm(tvec0 - t1p))
        if ang > self._stereo_disagree_rot_rad or dist > self._stereo_disagree_trans_m:
            self._disagree_count += 1
            if self._disagree_count >= 30 and not self._disagree_warned:
                print("[warn] cam0/cam1 board poses disagree persistently — "
                      "stereo extrinsic calibration may be stale; re-run calibrate_stereo.py.")
                self._disagree_warned = True
            return pose0 if e0 <= e1 else (cv2.Rodrigues(R1p)[0].flatten(), t1p, e1)
        self._disagree_count  = 0
        self._disagree_warned = False

        w0, w1  = 1.0 / max(e0, 1e-3) ** 2, 1.0 / max(e1, 1e-3) ** 2
        t_fused = (w0 * tvec0 + w1 * t1p) / (w0 + w1)
        R_fused = _weighted_quaternion_average(R0, R1p, w0, w1)
        reproj_fused = (w0 * e0 + w1 * e1) / (w0 + w1)
        return cv2.Rodrigues(R_fused)[0].flatten(), t_fused, reproj_fused

    def _pose_is_stable(self, rvec, tvec) -> bool:
        """Dual-camera origin-lock stability gate: True if translation/
        rotation delta from the previous frame's fused pose is below
        origin_stable_m/origin_stable_rad. Replaces the pixel-based
        _detection_matches_prev for this path, since two cameras' pixel
        spaces aren't directly comparable."""
        if self._prev_fused_pose is None:
            return False
        prev_rvec, prev_tvec = self._prev_fused_pose
        dt = float(np.linalg.norm(tvec - prev_tvec))
        dr = rotation_angle(cv2.Rodrigues(rvec)[0] @ cv2.Rodrigues(prev_rvec)[0].T)
        return dt < self._origin_stable_m and dr < self._origin_stable_rad

    def _detection_matches_prev(self, corners, ids) -> bool:
        """True if the current detection has the same marker IDs and barely moved since the previous frame."""
        if self._prev_ids is None:
            return False
        if set(self._prev_ids.flatten().tolist()) != set(ids.flatten().tolist()):
            return False
        prev_map = {int(i): c for i, c in zip(self._prev_ids.flatten(), self._prev_corners)}
        curr_map = {int(i): c for i, c in zip(ids.flatten(), corners)}
        motions = [float(np.linalg.norm(prev_map[i] - curr_map[i], axis=-1).mean()) for i in prev_map]
        return float(np.mean(motions)) < Config.ORIGIN_STABLE_PX

    def _maybe_lock_origin(self, corners, ids, rvecs, tvecs) -> None:
        """Count consecutive stable detections; when the threshold is hit, lock the world origin."""
        if self._detection_matches_prev(corners, ids):
            self._origin_stable_count += 1
        else:
            self._origin_stable_count = 1
        self._prev_corners = corners
        self._prev_ids = ids

        if self._origin_stable_count >= Config.ORIGIN_LOCK_FRAMES:
            # Anchor to the first detected marker with a known grip offset —
            # stored in the shared camera-frame form used by both solver paths.
            ids_flat = np.array(ids).flatten()
            rvecs_a  = np.array(rvecs).reshape(len(ids_flat), 3)
            tvecs_a  = np.array(tvecs).reshape(len(ids_flat), 3)
            for k, _id in enumerate(ids_flat):
                if int(_id) in Config.MARKER_OFFSETS:
                    R = cv2.Rodrigues(rvecs_a[k])[0]
                    self._origin_R    = R
                    self._origin_grip = R @ Config.MARKER_OFFSETS[int(_id)] + tvecs_a[k]
                    break
            else:
                return  # no known marker in view — keep waiting
            self.first_frame = False
            self._prev_corners = None
            self._prev_ids = None
            self._save_origin()
            print(f"World origin locked after {self._origin_stable_count} stable frames.")

    def _draw_axes(self, rvecs, tvecs) -> None:
        zero_dist = np.zeros(5)
        for rvec, tvec in zip(rvecs, tvecs):
            cv2.drawFrameAxes(
                self.video_frame, self.camera_matrix, zero_dist, rvec, tvec, 0.05
            )

    def _get_centroid(self, corners, ids, rvecs, tvecs) -> np.ndarray:
        ids   = np.array(ids).flatten()
        tvecs = np.array(tvecs).reshape(len(ids), 3)
        rvecs = np.array(rvecs).reshape(len(ids), 3)

        grip_points = np.full((len(ids), 3), np.nan)
        weights     = np.zeros(len(ids))
        for index, _id in enumerate(ids):
            if _id not in Config.MARKER_OFFSETS:
                continue
            grip_points[index] = (
                cv2.Rodrigues(rvecs[index])[0]
                @ Config.MARKER_OFFSETS[_id].reshape(3, 1)
                + tvecs[index].reshape(3, 1)
            ).T[0]
            if self._equal_weight:
                # Reconstructing the old setup's behavior for comparison: every
                # visible marker counts the same, regardless of apparent size.
                weights[index] = 1.0
            else:
                # Weight = projected pixel area of this marker (shoelace via diagonals).
                # Bigger marker in the image => corners more precise => more trustworthy.
                c = np.asarray(corners[index]).reshape(4, 2)
                d1 = c[2] - c[0]   # top-left → bottom-right
                d2 = c[3] - c[1]   # top-right → bottom-left
                weights[index] = 0.5 * abs(d1[0] * d2[1] - d1[1] * d2[0])

        valid = ~np.isnan(grip_points[:, 0])
        total_w = weights[valid].sum()
        if not valid.any() or total_w == 0.0:
            return np.nanmean(grip_points, axis=0).flatten()
        return (grip_points[valid] * weights[valid, None]).sum(axis=0) / total_w

    # ── demo comparison mode ──────────────────────────────────────────────────

    def _apply_setup(self, cmd: bytes) -> None:
        """Handle "SETUP:<subset|all>,<rigid|legacy|equal>" from Godot's settings menu
        or the standalone jitter-comparison tool. "equal" is per-marker with equal
        weighting (vs. legacy's pixel-area weighting) — used to reconstruct the old
        setup's behavior for comparison; never sent during normal patient sessions."""
        try:
            markers, algo = cmd.decode().split(":", 1)[1].strip().split(",")
        except ValueError:
            print(f"Malformed SETUP command: {cmd!r}")
            return
        if (markers, algo) == self._setup_state:
            return  # Godot re-sends its sticky command every 100 ms
        self._setup_state = (markers, algo)
        self._allowed_ids = self._demo_subset if markers == "subset" else None
        self._use_rigid    = (algo == "rigid")
        self._equal_weight = (algo == "equal")
        self._reset_origin()
        solver = "rigid body" if (self._use_rigid and self.board is not None) else \
            ("per-marker (equal weight)" if self._equal_weight else "per-marker")
        print(f"Setup changed: markers={sorted(self._allowed_ids) if self._allowed_ids else 'all'}, "
              f"solver={solver} — re-locking origin")

    def _filter_markers(self, corners, ids):
        """Drop detections outside the allowed marker set (demo subset mode)."""
        if ids is None or self._allowed_ids is None:
            return corners, ids
        keep = [k for k, _id in enumerate(ids.flatten()) if int(_id) in self._allowed_ids]
        if not keep:
            return (), None
        return tuple(corners[k] for k in keep), ids[keep]

    def _reset_origin(self) -> None:
        """Clear pose caches on a mode switch. The origin lives in the camera
        frame and is shared by both solver paths, so an existing lock is kept —
        re-lock only happens when no origin exists yet."""
        self.first_frame          = self._origin_R is None
        self._origin_stable_count = 0
        self._prev_corners        = None
        self._prev_ids            = None
        self._prev_fused_pose     = None
        self._cached_rvecs        = None
        self._cached_tvecs        = None
        self._cached_board_pose   = None
        self._board_rvec          = None
        self._board_tvec          = None
        self._cached_board_pose_1 = None
        self._board_rvec_1        = None
        self._board_tvec_1        = None
        self._disagree_count      = 0
        self._disagree_warned     = False

    def _relock_origin(self) -> None:
        """RELOCK command from the Godot installer: discard the world origin
        (memory + persisted file) and re-lock from the next stable detection.
        Meant to be triggered with the device parked at the marked pose, so
        re-locked frames are physically repeatable across installations."""
        self._origin_R    = None
        self._origin_grip = None
        self._reset_origin()   # first_frame becomes True since no origin exists now
        if os.path.exists(self._origin_path):
            try:
                os.remove(self._origin_path)
            except OSError as exc:
                print(f"Could not delete {self._origin_path}: {exc}")
        print("RELOCK: origin cleared — waiting for a stable detection to re-lock.")

    # ── origin persistence ────────────────────────────────────────────────────

    def _save_origin(self) -> None:
        if not self._persist_origin:
            return
        with open(self._origin_path, "w") as f:
            json.dump({
                "R":    np.asarray(self._origin_R).tolist(),
                "grip": np.asarray(self._origin_grip).flatten().tolist(),
            }, f)

    def _load_origin(self) -> None:
        try:
            with open(self._origin_path) as f:
                data = json.load(f)
            self._origin_R    = np.array(data["R"], dtype=np.float64).reshape(3, 3)
            self._origin_grip = np.array(data["grip"], dtype=np.float64).flatten()
        except (OSError, ValueError, KeyError) as exc:
            print(f"Could not load {self._origin_path} ({exc}) — will re-lock.")
            return
        self.first_frame = False
        print(f"World origin restored from {self._origin_path} "
              f"(delete this file after moving the camera).")

    # ── per-frame pose paths (return local coords, or None while origin unlocked) ──

    def _process_per_marker(self, corners, ids):
        """Legacy path: independent solvePnP per marker, weighted grip average."""
        if self.corner_stability.is_stable(corners, ids) and self._cached_rvecs is not None:
            rvecs, tvecs = self._cached_rvecs, self._cached_tvecs
        else:
            rvecs, tvecs = self.estimate_pose(corners)
            self._cached_rvecs, self._cached_tvecs = rvecs, tvecs

        if self.first_frame:
            self._maybe_lock_origin(corners, ids, rvecs, tvecs)
            return None

        self._draw_axes(rvecs, tvecs)
        centroid = self._get_centroid(corners, ids, rvecs, tvecs)
        return self._origin_R.T @ (self._origin_grip - centroid)

    def _process_board(self, rvec, tvec, corners=None, ids=None):
        """Joint path: takes an already-solved rigid-body pose — either a
        lone camera's solve (single-camera mode) or the fused pose from both
        cameras (dual-camera mode) — so both paths share all downstream
        logic (origin lock, grip point, overlay) unchanged. The actual
        solvePnP call now lives in _solve_camera_pose (and, in dual mode,
        _fuse_board_poses combines the two cameras' solves before this is
        called).

        corners/ids are optional and only meaningful for the single-camera
        origin-lock stability gate (pixel-motion based) — dual-camera mode
        passes None and uses a pose-space stability gate instead, since two
        cameras' pixel spaces aren't directly comparable."""
        if self.first_frame:
            self._maybe_lock_origin_board(rvec, tvec, corners, ids)
            return None

        R = cv2.Rodrigues(rvec)[0]
        grip = R @ self.board.grip_point + tvec
        self._draw_board_overlay(rvec, tvec, grip)
        return self._origin_R.T @ (self._origin_grip - grip)

    def _maybe_lock_origin_board(self, rvec, tvec, corners=None, ids=None) -> None:
        """Board-mode origin lock. Single-camera: pixel-space stability via
        corners/ids (_detection_matches_prev), matching the legacy behavior
        exactly. Dual-camera (corners is None): pose-space stability via
        translation/rotation delta from the previous frame's fused pose
        (_pose_is_stable), since pixel motion isn't comparable across two
        different cameras."""
        if self._dual_camera:
            stable = self._pose_is_stable(rvec, tvec)
            self._prev_fused_pose = (rvec, tvec)
        else:
            stable = self._detection_matches_prev(corners, ids)
            self._prev_corners, self._prev_ids = corners, ids

        if stable:
            self._origin_stable_count += 1
        else:
            self._origin_stable_count = 1

        if self._origin_stable_count >= Config.ORIGIN_LOCK_FRAMES:
            self._origin_R = cv2.Rodrigues(rvec)[0]
            self._origin_grip = self._origin_R @ self.board.grip_point + tvec
            self.first_frame = False
            self._prev_corners = None
            self._prev_ids = None
            self._prev_fused_pose = None
            self._save_origin()
            print(f"World origin locked after {self._origin_stable_count} stable frames (board mode).")

    def _draw_board_overlay(self, rvec, tvec, grip) -> None:
        zero_dist = np.zeros(5)
        cv2.drawFrameAxes(
            self.video_frame, self.camera_matrix, zero_dist, rvec, tvec, 0.05
        )
        if grip[2] > 0:
            pix, _ = cv2.projectPoints(
                grip.reshape(1, 3), np.zeros(3), np.zeros(3),
                self.camera_matrix, zero_dist,
            )
            cv2.circle(self.video_frame,
                       tuple(int(v) for v in pix.ravel()), 6, (0, 0, 255), -1)

    # ── CSV recording ─────────────────────────────────────────────────────────

    def _select_hospitalid(self) -> None:
        if self.save_path is None:
            # Close any previously-open CSV before opening a new one (avoids leak on CHANGE).
            if self._csv_file is not None:
                self._csv_file.close()
                self._csv_file = None
                self.csv_writer = None

            self.save_path = os.path.join(
                os.path.expanduser("~/Documents/NOARK/data"),
                self._hid,
                self._curr_session,
            )
            os.makedirs(self.save_path, exist_ok=True)
            csv_path = os.path.join(
                self.save_path,
                datetime.now().strftime("%Y_%m_%d_%H_%M_%S") + "_data.csv",
            )
            self._csv_file  = open(csv_path, "w", newline="")
            self.csv_writer = csv.writer(self._csv_file)
            self.csv_writer.writerow(["Time", "X", "Y", "Z"])

    # ── main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        t0 = time.perf_counter() if self.debug else 0.0

        # Capture frame(s)
        if self._dual_camera:
            frame0, frame1 = self._capture_dual_frames()
            if frame0 is None and frame1 is None:
                return
        else:
            frame0 = self._capture_single_frame()
            frame1 = None
            if frame0 is None:
                return
        t1 = time.perf_counter() if self.debug else 0.0

        # INTER_LINEAR: ~half the cost of INTER_CUBIC; corner sub-pixel accuracy
        # comes from the detector's corner refinement, not the resampling kernel.
        #
        # skip_remap: undistort the four corners per marker instead of the whole
        # frame (see _undistort_corners). Single-camera only — the dual path
        # would also need cam1's own intrinsics, so it keeps the remap.
        skip_remap = (not self._undistort_image) and not self._dual_camera
        if frame0 is not None:
            if not skip_remap:
                frame0 = cv2.remap(frame0, self.map1, self.map2, interpolation=cv2.INTER_LINEAR)
            self.video_frame = frame0
        if self._dual_camera and frame1 is not None:
            frame1 = cv2.remap(frame1, self.map1_1, self.map2_1, interpolation=cv2.INTER_LINEAR)
        t2 = time.perf_counter() if self.debug else 0.0

        # Poll command from Godot
        cmd = self._recv_command()
        if cmd.startswith(b"SETUP:"):
            self._apply_setup(cmd)   # demo mode switch, not a dispatch command
        elif cmd == b"RELOCK":
            self._relock_origin()    # installer origin ritual, not a dispatch command
        elif cmd:
            self.received_message = cmd

        # Detect markers
        corners0 = ids0 = None
        if frame0 is not None:
            corners0, ids0, _ = self.detector.detectMarkers(frame0)
            if skip_remap:
                corners0 = self._undistort_corners(corners0)
            corners0, ids0 = self._filter_markers(corners0, ids0)
        corners1 = ids1 = None
        if self._dual_camera and frame1 is not None:
            corners1, ids1, _ = self.detector.detectMarkers(frame1)
            corners1, ids1 = self._filter_markers(corners1, ids1)
        t3 = time.perf_counter() if self.debug else 0.0

        local_coords = None
        if self._dual_camera and self.board is not None and self._use_rigid:
            # Joint fusion path: each camera solves independently, cam1's pose
            # gets transformed into cam0's frame, then combined — see
            # _fuse_board_poses for the disagreement/fallback handling that
            # keeps a dead or occluded camera from breaking tracking.
            if ids0 is not None:
                self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners0, ids0)
            pose0 = self._solve_camera_pose(0, corners0, ids0) if ids0 is not None else None
            pose1 = self._solve_camera_pose(1, corners1, ids1) if ids1 is not None else None
            fused = self._fuse_board_poses(pose0, pose1)
            if fused is not None:
                local_coords = self._process_board(fused[0], fused[1])
        elif ids0 is not None:
            # Single-camera path (also used when dual-camera mode has no board
            # geometry loaded, or the demo SETUP toggle selected the legacy
            # per-marker solver — cam1 is simply not consulted in that case).
            self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners0, ids0)
            if self.board is not None and self._use_rigid:
                pose0 = self._solve_camera_pose(0, corners0, ids0)
                if pose0 is not None:
                    local_coords = self._process_board(pose0[0], pose0[1], corners0, ids0)
            else:
                local_coords = self._process_per_marker(corners0, ids0)

        if local_coords is not None:
            local_coords = self.filter.update(local_coords)

            # Dispatch command
            if self.received_message:
                if self.received_message == b"STOP":
                    self._send_coordinates("STOP", local_coords)
                elif self.received_message.startswith(b"USER:"):
                    new_hid = self.received_message.decode().split(":")[1]
                    if new_hid != self._hid:
                        self._hid = new_hid
                        self._select_hospitalid()
                        self.record = True
                    self._send_coordinates("START", local_coords)
                elif self.received_message.startswith(b"CHANGE:"):
                    new_hid = self.received_message.decode().split(":")[1]
                    if new_hid != self._hid:
                        self.save_path = None      # force _select_hospitalid to make a new folder/CSV
                        self._hid = new_hid
                        self._select_hospitalid()
                        self.record = True
                    self._send_coordinates("START", local_coords)
                elif self.received_message == b"RESET":
                    self._send_coordinates("RESET", local_coords)
                else:
                    self._send_coordinates("START", local_coords)

                if self.record and self.csv_writer:
                    self.csv_writer.writerow(
                        [datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3], *local_coords]
                    )

        if self.debug:
            t4 = time.perf_counter()
            self._stage_times.append((
                (t1 - t0) * 1000.0,   # capture
                (t2 - t1) * 1000.0,   # remap (undistort)
                (t3 - t2) * 1000.0,   # detect
                (t4 - t3) * 1000.0,   # pose + filter + send
            ))

            now = time.time()
            if now - self._dbg_last_print > 1.0:
                if ids0 is not None:
                    sides = [np.linalg.norm(c[0][i] - c[0][(i + 1) % 4])
                             for c in corners0 for i in range(4)]
                    print(f"marker side: avg {np.mean(sides):.1f} px  (n={len(sides)//4} markers)")
                if self._stage_times:
                    arr = np.array(self._stage_times)
                    means = arr.mean(axis=0)
                    total = float(means.sum())
                    line = (f"capture: {means[0]:5.2f} ms  |  "
                            f"remap: {means[1]:5.2f} ms  |  "
                            f"detect: {means[2]:5.2f} ms  |  "
                            f"pose+send: {means[3]:5.2f} ms  |  "
                            f"total: {total:5.2f} ms  ({len(arr)} frames)")
                    print(line)
                    if self._timing_log is not None:
                        self._timing_log.write(
                            f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]}  {line}\n"
                        )
                    self._stage_times.clear()
                self._dbg_last_print = now
            self.video_frame = cv2.resize(self.video_frame, (350, 200))
            cv2.imshow("frame", self.video_frame)

    def run(self) -> None:
        try:
            while True:
                try:
                    self.process_frame()
                    if time.time() - self._last_msg_time > 3.0:
                        print("No UDP packets from Godot for 3 s — exiting.")
                        break
                except Exception as exc:
                    print(f"Error: {exc} — Godot likely closed")
                    break

                if self.received_message == b"STOP":
                    break
                if self.debug and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self._camera_backend in ("rcam_single", "rcam_dual"):
                self._stop_capture.set()
                for t in self._cam_threads:
                    if t is not None:
                        t.join(timeout=1.0)
                for cam in self._rcam:
                    try:
                        cam.stop()
                    except Exception:
                        pass
            if self._csv_file is not None:
                self._csv_file.close()
            if self._timing_log is not None:
                self._timing_log.close()
            if self.debug:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    settings = _load_settings()

    _pyscripts_dir = os.path.dirname(os.path.abspath(__file__))
    # settings.json["calibration_file"] picks which .toml to load. A bare
    # filename is resolved relative to pyscripts/; an absolute path is used as-is.
    _calib_name = settings.get("calibration_file", "camera_calib.toml")
    CAMERA_CALIB_PATH = (
        _calib_name if os.path.isabs(_calib_name)
        else os.path.join(_pyscripts_dir, _calib_name)
    )
    print(f"Loading calibration from: {CAMERA_CALIB_PATH}")

    main = MainClass(cam_calib_path=CAMERA_CALIB_PATH, settings=settings)
    main.run()
