import collections
import dataclasses
import json
import os
import socket
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from typing import Optional

import cv2
import numpy as np
from cv2 import aruco
from scipy.spatial.transform import Rotation as ScipyRotation

import board as board_model
from board import (BoardGeometry, estimate_board_pose, estimate_board_pose_dual,
                   estimate_board_pose_dual_gn, estimate_board_pose_raw)
from pose_averaging import rotation_angle
from recording import Recording, SyncWatcher, sanitize_name


# Longest the loop waits for a new camera frame before handing control back to
# run() (which checks Godot's heartbeat). Frames arrive every 10 ms at 100 fps.
FRAME_WAIT_S = 0.05

# Frames each camera's queue holds. A slow pass then delays the next frames
# instead of letting them be overwritten; the loop catches up because a
# typical pass (~7.5 ms) is shorter than the 10 ms between frames. Only if it
# falls more than this many frames behind is the oldest one dropped (and
# counted as missed). 3 frames = 30 ms of slack at 100 fps.
FRAME_QUEUE_DEPTH = 3

# First float32 of a UDP packet to Godot: 2.0 = a position sample (24 bytes,
# see _send_coordinates), 7.0 = a validation-recorder status packet (4 bytes
# + JSON). udp_receiver.gd branches on this.
SAMPLE_CODE = 2.0
STATUS_CODE = 7.0
STATUS_PERIOD_S = 0.5


class _FrameQueue:
    """The last FRAME_QUEUE_DEPTH frames from one camera's capture thread, each
    with its kernel capture time and sequence number, oldest first."""

    def __init__(self) -> None:
        self._cond = threading.Condition()
        self._items = collections.deque(maxlen=FRAME_QUEUE_DEPTH)   # (frame, ts, seq)

    def put(self, frame, ts: float, seq) -> None:
        """ts: the frame's capture time; seq: the kernel's frame sequence number."""
        with self._cond:
            self._items.append((frame, ts, seq))
            self._cond.notify_all()

    def next_after(self, last_seq, timeout: float):
        """The oldest queued frame this reader has not processed yet — the
        first with seq > last_seq (the newest, on the first call) — waiting
        up to timeout for one to arrive. Returns (frame, ts, seq) or None."""
        def pick():
            if not self._items:
                return None
            if last_seq is None:
                return self._items[-1]
            for item in self._items:
                if item[2] > last_seq:
                    return item
            return None
        with self._cond:
            if self._cond.wait_for(lambda: pick() is not None, timeout):
                return pick()
            return None

    def nearest(self, ts: float):
        """The queued frame captured closest in time to ts — for pairing the
        second camera with the driving camera's frame. (frame, ts, seq) or None."""
        with self._cond:
            if not self._items:
                return None
            return min(self._items, key=lambda item: abs(item[1] - ts))


@dataclasses.dataclass
class FrameResult:
    """What one process_frame() pass computed. Pairs are (cam0, cam1);
    an entry is None when that camera had no frame / saw no marker / was not
    solved this pass.

    t_cap         capture time of each camera's frame, monotonic seconds
                  (same clock as time.monotonic() and gpiod edge events)
    seq           kernel frame sequence number of each camera's frame
    corners, ids  detected markers, corners in undistorted full-frame pixels
    reproj        each camera's board-solve reprojection error, px — kept
                  even when the solve was then rejected (> stereo_max_reproj_px)
    fusion        "cam0", "cam1", "both", "cam0_disagree", "cam1_disagree", None
    stereo_gap    (m, rad) between the two cameras' poses when both solved
    fused         (rvec, tvec, reproj) board pose in cam0's frame, or None
    local_coords  grip point in the game (origin-lock) frame, m — what Godot
                  receives; None until the origin is locked"""
    t_cap: tuple
    seq: tuple
    corners: tuple
    ids: tuple
    reproj: tuple
    fusion: Optional[str]
    stereo_gap: Optional[tuple]
    fused: Optional[tuple]
    local_coords: Optional[np.ndarray]


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
    ORIGIN_LOCK_FRAMES = 10         # consecutive stable frames required before locking the world origin
    ORIGIN_STABLE_PX   = 2.0        # max mean corner motion (px) between frames to count as stable
    BOARD_MAX_REPROJ_PX = 3.0       # board solve worse than this -> re-initialise without the previous-frame guess
    # Grip-point offsets now live in board.py (shared with calibrate_board.py).
    MARKER_OFFSETS = board_model.MARKER_OFFSETS


class MainClass:
    def __init__(self, cam_calib_path: str, settings: Optional[dict] = None,
                 udp: bool = True) -> None:
        if settings is None:
            settings = {}

        self.debug = settings.get("debug", False)
        # Preview window is independent of the timing output: debug=True with
        # debug_preview=False gives the stage times at full speed.
        self._debug_preview = bool(settings.get("debug_preview", True)) and self.debug
        self.udp_port        = settings.get("udp_port", 12345)

        self.frame_size    = Config.FRAME_SIZE
        self.marker_length = Config.MARKER_LENGTH

        import toml
        calib_data = toml.load(cam_calib_path)
        lens_matrix      = np.array(calib_data["calibration"]["camera_matrix"]).reshape(3, 3)
        self.dist_coeffs = np.array(calib_data["calibration"]["dist_coeffs"])

        # The undistorted image is the sensor's size plus a border on every
        # side. Undistorting with the lens's own focal length into 1280 x 800
        # keeps only ~49 deg sideways / ~35 deg down of a lens that sees ~66 /
        # ~41, and at the table corners nearest the cameras 3 of each camera's
        # 8 markers fell in the part thrown away (coverage_markers.py,
        # 2026-09-22). The border keeps them; the focal length is unchanged,
        # so a marker in the middle of the image is exactly as before.
        self._ud_pad  = (int(settings.get("undistort_pad_x_px", 0)),
                         int(settings.get("undistort_pad_y_px", 0)))
        self.ud_size  = (self.frame_size[0] + 2 * self._ud_pad[0],
                         self.frame_size[1] + 2 * self._ud_pad[1])
        print(f"Undistorted image: {self.ud_size[0]} x {self.ud_size[1]} "
              f"(border {self._ud_pad[0]} / {self._ud_pad[1]} px)")

        # Lens distortion is removed by remapping the whole frame, then detecting
        # on the corrected image. The corners reaching solvePnP are therefore
        # pinhole-equivalent with intrinsics = camera_matrix (the lens matrix
        # with its centre moved by the border), so it is called with np.zeros(5).
        self.camera_matrix = self._undistorted_matrix(lens_matrix)
        # The fisheye lens itself, for the "raw_joint" pipeline, which finds the
        # markers on the raw image and never straightens it.
        self._lens0 = (np.asarray(lens_matrix, np.float64),
                       np.asarray(self.dist_coeffs, np.float64).reshape(4, 1))
        self._lens1 = None
        self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
            lens_matrix, self.dist_coeffs, np.eye(3),
            self.camera_matrix, self.ud_size, cv2.CV_16SC2,
        )

        # Leave cores free for Godot on the Pi — OpenCV otherwise parallelises
        # detection across ALL cores and starves the game's render thread.
        opencv_threads = int(settings.get("opencv_threads", 2))
        if opencv_threads > 0:
            cv2.setNumThreads(opencv_threads)
            print(f"OpenCV limited to {opencv_threads} threads")

        self._corner_refine_name = str(settings.get("corner_refine", "contour")).lower()
        self._thresh_win = int(settings.get("adaptive_thresh_win_size", 15))
        # Tag-reading settings (2026-09-24), exposed to steady small and oblique
        # tags that blink in and out of detection — each blink shifts the pose
        # a little. Defaults = what the tracker always used.
        self._aruco3 = bool(settings.get("aruco3_detection", True))
        self._pixels_per_cell = int(settings.get("perspective_pixels_per_cell", 4))
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

        # Joint rigid-body solve: enabled when board_geometry.json exists
        # (produced by calibrate_board.py). Falls back to per-marker PnP +
        # weighted averaging otherwise.
        self.board = None
        self._board_rvec = None      # last good board pose — ITERATIVE guess for the next frame
        self._board_tvec = None
        self._board_rvec_1 = None    # cam1's own guess cache, dual-camera mode only
        self._board_tvec_1 = None
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

        self.video_frame  = None                    # latest captured image, refreshed every frame
        self.last_raw_frames = (None, None)         # latest raw (distorted) frame per camera
        self.first_frame  = True                    # True until the world origin has been locked (see _maybe_lock_origin)
        self.received_message: bytes = b""          # most recent UDP command from Godot (sticky — last command is reused each frame)
        self.addr         = None                    # Godot's UDP address, learned from the first incoming packet
        self._dbg_last_print = 0.0                  # timestamp of last debug print, to throttle to ~1/sec

        # Per-stage timing buffer (filled by process_frame, drained by the debug print
        # once a second). Each entry is [capture_ms, remap_ms, detect_ms, pose_send_ms].
        self._stage_times = []
        # Finer split of the pose stage: [(both solvePnPs ms, search boxes ms)]
        self._sub_times = []
        self._search_ms = []                  # per-camera search times from the camera threads
        self._pass_capture_ms = 0.0
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
        # Monotonic, not time.time(): the board has no battery clock, so the
        # wall clock JUMPS when it syncs over the network after boot (+8321 s
        # on 2026-09-22) and a wall-clock gap then read as "no message from
        # Godot for 2 hours" — the tracker exited mid-session.
        self._last_msg_time = time.monotonic()

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
        # Joint two-camera solve (board.estimate_board_pose_dual): one pose
        # fitted to both cameras' corners instead of averaging two poses.
        # Offline it cut the jitter while still by a third on the 2026-09-21 T1
        # grid, but live it is OFF by default (2026-09-21): the fit cost ~1 ms
        # the 10 ms budget does not have (100 -> 85 samples/s), and it assumes
        # both cameras saw the same instant, while cam1's frame is ~1.6 ms
        # older — harmless standing still, wrong while moving. It belongs in
        # the offline analysis (compare_fusion.py) until cam1's corners are
        # carried to cam0's capture time first.
        self._joint_solve    = bool(settings.get("joint_solve", False))
        self._joint_rejected = 0              # fits thrown out since the last timing line
        # How the two cameras make one pose (2026-09-22): "average" = each
        # camera solved alone, then averaged (_fuse_board_poses); "joint" = one
        # solve over all corners of both cameras (_solve_joint).
        self._dual_solve = str(settings.get("dual_solve", "average")).lower()
        self._joint_prev = None               # last accepted joint pose, start of the next fit
        # Huber loss in the joint fit (board.estimate_board_pose_dual_gn): a
        # corner further off than this many px pulls with weight delta/e
        # instead of counting e^2, so one noisy or half-hidden tag cannot drag
        # the pose; frames are then judged on the median corner error.
        # 0 = plain least squares (before 2026-09-24).
        self._robust_px = float(settings.get("robust_loss_px", 0.0))
        print(f"Two-camera solve: {self._dual_solve}"
              + (f"  (robust loss {self._robust_px:g} px)" if self._robust_px > 0 else ""))
        # Pipeline (2026-09-22). "current": each camera's frame is straightened,
        # markers found, each camera solved alone, the two poses averaged.
        # "raw_joint": markers found on the RAW image (no straightening), then
        # ONE solve over all corners from both cameras, each predicted through
        # its own fisheye model (board.estimate_board_pose_raw), started from
        # the previous frame's pose. Dual camera + board geometry only.
        self._pipeline = str(settings.get("pipeline", "current")).lower()
        self._raw = self._pipeline == "raw_joint"
        self._raw_guess = None                # last accepted raw_joint pose (cam0 frame)
        print(f"Pipeline: {self._pipeline}")
        self._disagree_count  = 0             # consecutive frames cam0/cam1 poses disagreed too much
        self._disagree_warned = False
        self._prev_fused_pose = None          # pose-space stability gate for dual-camera origin lock

        # Camera
        self._camera_backend = str(settings.get("camera_backend", "auto")).lower()
        self._dual_camera = self._camera_backend == "rcam_dual"
        self._init_camera_backend(settings)

        # Dual mode: remap + detect run for both cameras at once, one worker per
        # camera, instead of cam0 then cam1. cv2.remap and detectMarkers release
        # the GIL, so the two really run in parallel on separate cores; the loop
        # then costs the slower camera, not the sum. Each camera gets its own
        # detector — ArucoDetector is not documented as safe to share across
        # threads. The computation per camera is unchanged.
        #
        # One single-thread executor PER camera (2026-09-22): a camera's jobs
        # then run strictly one after another, which the overlap below relies
        # on — its search-box state and its detector are touched by one thread.
        #
        # Overlap (overlap_detect_solve): the main thread solves frame N-1
        # while the camera threads search frame N, so a pass costs about
        # max(search, solve) instead of their sum — the sum was 10-12 ms of a
        # 10 ms budget. Same computation per frame; each result reaches Godot
        # one frame (10 ms) later; a frame's search box comes from the pose of
        # two frames before (one before, without the overlap).
        self._cam_pools = None
        self._overlap = bool(settings.get("overlap_detect_solve", False))
        self._pending = None                  # frame searched last pass, not yet solved
        if self._dual_camera:
            self.detector_1 = self._init_detector()
            self._cam_pools = [ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"cam{i}")
                               for i in (0, 1)]
            print(f"Overlap search/solve: {'on' if self._overlap else 'off'}")

        # Search box (region of interest), per camera: once the device is found,
        # the next frame is undistorted and searched only in a box around the
        # whole device (all markers projected with this frame's pose — see
        # _roi_from_pose; the detected markers' box when there is no pose),
        # widened by roi_margin_markers marker-widths on every side. Inside the
        # box the undistorted pixels are the same map entries as the full remap
        # and the detector sees the same neighbourhoods, so corners come out the
        # same. A box that yields no markers at all is re-searched full-frame in
        # the same pass, and every roi_full_every-th frame is full-frame
        # regardless. Off while the debug preview is on, since the preview needs
        # the whole picture.
        # debug_preview_box (raw_joint only): keep the box on while previewing
        # and show both raw frames with the box searched this frame.
        self._preview_box    = (bool(settings.get("debug_preview_box", False))
                                and self._debug_preview and self._raw)
        self._roi_enabled    = (bool(settings.get("roi_enabled", True))
                                and (not self._debug_preview or self._preview_box))
        self._roi_used       = [None, None]   # box searched this frame per camera, None = whole frame
        self._roi_margin     = float(settings.get("roi_margin_markers", 2.0))
        # The margin is measured in marker widths, so it balloons exactly when
        # the device is near a camera (a marker can be 300 px across) and the
        # box then approaches the full frame — the pass overruns 10 ms and a
        # frame is lost. It only has to cover movement between two frames:
        # 1 m/s at 10 ms is ~10 mm, about 60 px close up. Capped 2026-09-21.
        self._roi_margin_max_px = float(settings.get("roi_margin_max_px", 120.0))
        self._roi_full_every = int(settings.get("roi_full_every", 100))
        # All marker corners of the device in the board frame (from
        # board_geometry.json). Projected with a camera's latest pose, they give
        # a box around the WHOLE device — markers seen edge-on or hidden this
        # frame included — so a marker missing from the box is never the box's
        # fault, and the full-frame fallback is only needed when nothing at all
        # is found.
        self._device_pts = None
        if self.board is not None:
            self._device_pts = np.concatenate(
                [self.board.corners_in_board(mid) for mid in self.board.marker_poses]
            ).astype(np.float64)
        self._roi        = [None, None]   # (x0, y0, x1, y1) in undistorted pixels — camera thread's own
        self._roi_next   = [None, None]   # box from the latest pose, handed to the next search (main thread)
        self._roi_count  = [0, 0]         # markers found last frame
        self._roi_age    = [0, 0]         # frames since the last full-frame search
        self._full_count = [0, 0]         # full-frame searches since the last timing line
        self._prev_tags  = [None, None]   # tag ids found in the previous frame, per camera
        self._tag_flips  = [0, 0]         # frames whose tag set differed from the frame before
        self._flip_ids   = [collections.Counter(), collections.Counter()]  # which tags came or went
        self._seen_ids   = [collections.Counter(), collections.Counter()]  # frames each tag was found in

        # Sequence numbers of the last frame processed per camera, so no frame
        # is processed twice; and camera frames skipped since the last timing
        # line (gaps in the driving camera's sequence).
        self._last_seq         = [None, None]
        # Capture time of the frame this pass is processing (kernel clock,
        # CLOCK_MONOTONIC), sent to Godot with each position as Unix time.
        # The offset between the two clocks is read fresh each time
        # (_mono_to_unix), because the wall clock is stepped when the board
        # syncs over the network after boot; an offset taken once at start-up
        # stamped every later sample 2+ hours wrong.
        self._frame_t_cap   = None
        self._last_seq_driver  = None
        self._missed_count     = 0

        # What this pass used and found, per camera — reset at the start of
        # every process_frame() and returned in its FrameResult (read by
        # recorder.py; the Godot path ignores it).
        self._frame_ts     = [None, None]   # capture time of each camera's frame (monotonic s)
        self._frame_seqs   = [None, None]   # kernel sequence number of each camera's frame
        self._last_reproj  = [None, None]   # each camera's board-solve reprojection error (px),
                                            # kept even when the solve is then rejected
        self._last_fusion  = None           # which camera(s) the pose came from (_fuse_board_poses)
        self._last_stereo_gap = None        # (m, rad) between cam0's and cam1's poses, both solved

        # Validation recording (docs/validation_plan.md), driven by Godot's
        # installer screen: nothing is written unless it sends REC_START.
        self._settings  = settings      # copied into each recording's meta.json
        self._rec_lock  = threading.Lock()
        self._recording = None
        self._rec_dir   = os.path.expanduser(
            settings.get("validation_data_dir", "~/Documents/NOARK/validation"))
        self._rec_last  = ""            # summary of the last recording, shown in Godot
        self._rec_error = ""            # why the last REC_START failed (name in use, ...)
        self._status_t  = 0.0           # when the last status packet went out
        self._sync = None
        self._sync_error = None
        self._init_sync_watcher(settings)

        # udp=False: no socket, so no port clash with a running game and no
        # dependence on Godot's heartbeat.
        self._udp_enabled = udp
        self.udp_socket = None
        if udp:
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
        params.useAruco3Detection     = self._aruco3
        params.cornerRefinementMethod = refine_flag
        # How finely each cell is sampled when the tag's code is read: at the
        # far edge a cell is ~6 px, and 4 samples per cell leaves little margin.
        params.perspectiveRemovePixelPerCell = self._pixels_per_cell
        print(f"Tag reading: aruco3 {'on' if self._aruco3 else 'off'}, "
              f"{self._pixels_per_cell} px per cell")
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

    def _init_camera_backend(self, settings: dict) -> None:
        """Dragon Q6A only: two OV9281 via rcam, or one for bring-up.

        The Raspberry Pi's picamera2 path lives in the NOARKGames-pi repo;
        anything but an rcam backend is a settings.json mistake on this board,
        so say so instead of failing later inside the capture loop."""
        if self._camera_backend == "rcam_dual":
            self._init_rcam_dual(settings)
        elif self._camera_backend == "rcam_single":
            self._init_rcam_single(settings)
        else:
            raise ValueError(
                f'camera_backend={self._camera_backend!r} is not supported in the '
                f'Dragon Q6A repo — use "rcam_dual" (two cameras) or "rcam_single".'
            )

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
        """One rcam camera (Dragon Q6A, single-camera mode) — bring-up and
        fallback; rcam_dual is the normal path on this board."""
        from rcam import Camera

        cam_id = settings.get("rcam_id_0", "CAM2")
        cam = Camera(cam_id)
        cam.configure(size=self.frame_size, bit_depth=8)
        cam.set_controls(self._rcam_controls(settings))
        cam.start()

        self._rcam         = [cam]
        self._frame_slots   = [_FrameQueue()]
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

        if settings.get("cam_phase_align", True):
            self._align_camera_phase(settings, controls)

        self._frame_slots      = [_FrameQueue(), _FrameQueue()]
        self._cam_errors       = [None, None]
        self._cam_error_logged = [False, False]
        self._cam_threads      = [None, None]
        self._stop_capture     = threading.Event()
        self._start_capture_thread(0)
        self._start_capture_thread(1)

        self._load_second_intrinsics(settings)
        self._load_stereo_extrinsics(settings)

    def _align_camera_phase(self, settings: dict, controls: dict) -> None:
        """Bring the two cameras' frames into step by restarting cam1.

        Both sensors run at exactly the same rate (they share a clock, so the
        offset does not drift within a session), but each starts its frame
        timer when its stream is switched on, one after the other. So

            offset = (gap between the two starts) mod frame period

        — 1.6 ms in one recording, 4.6 ms in the next, never predictable.
        Restarting cam1 draws a new offset; after a random pause the draws are
        spread over the whole period, so a handful of tries lands one within
        the tolerance (1 in 10 per try for 0.5 ms of a 10 ms period).

        Runs before the capture threads, reading frames directly. Offsets use
        the kernel's own capture times, so any frame from each camera will do.
        """
        import random

        period = 1.0 / float(self._framerate)
        tol = float(settings.get("cam_phase_tolerance_ms", 0.5)) / 1000.0
        max_attempts = int(settings.get("cam_phase_max_attempts", 20))

        def measure() -> float:
            # A freshly started sensor may not be on its final rhythm for its
            # first frames — measuring those judged a phase the camera then
            # left (aligned to 0.14 ms at start-up, ~4 ms apart in the
            # recording that followed). Let both settle first.
            for _ in range(10):
                self._rcam[0].capture_with_meta()
                self._rcam[1].capture_with_meta()
            offs = []
            for _ in range(10):
                t0 = self._rcam[0].capture_with_meta()[2]
                t1 = self._rcam[1].capture_with_meta()[2]
                d = (t0 - t1) % period            # 0 .. period
                offs.append(d - period if d > period / 2 else d)
            return float(np.median(offs))

        try:
            phase = measure()
            first = phase
            attempts = 0
            while abs(phase) > tol and attempts < max_attempts:
                attempts += 1
                self._rcam[1].stop()
                time.sleep(random.uniform(0.0, period))
                self._rcam[1].set_controls(controls)
                self._rcam[1].start()
                phase = measure()
        except Exception as exc:                  # never block tracking on this
            print(f"[warn] camera phase alignment skipped: {exc}")
            return
        self._phase_offset_ms = phase * 1000.0
        print(f"Camera phase: {first * 1000.0:+.2f} ms -> {phase * 1000.0:+.2f} ms "
              f"after {attempts} restart(s) of cam1")

    def _undistorted_matrix(self, lens_matrix: np.ndarray) -> np.ndarray:
        """Intrinsics of the undistorted image: the lens's own, with the image
        centre moved by the border so the same ray lands the same distance
        from the centre."""
        K = np.array(lens_matrix, dtype=np.float64).copy()
        K[0, 2] += self._ud_pad[0]
        K[1, 2] += self._ud_pad[1]
        return K

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
        lens_matrix_1 = np.array(calib_data["calibration"]["camera_matrix"]).reshape(3, 3)
        dist_coeffs_1 = np.array(calib_data["calibration"]["dist_coeffs"])
        self.camera_matrix_1 = self._undistorted_matrix(lens_matrix_1)
        self._lens1 = (np.asarray(lens_matrix_1, np.float64),
                       np.asarray(dist_coeffs_1, np.float64).reshape(4, 1))
        self.map1_1, self.map2_1 = cv2.fisheye.initUndistortRectifyMap(
            lens_matrix_1, dist_coeffs_1, np.eye(3),
            self.camera_matrix_1, self.ud_size, cv2.CV_16SC2,
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
                # Kernel capture time + sequence number travel with the frame:
                # the loop uses seq to never process the same frame twice, and
                # the capture time (same monotonic clock as time.monotonic())
                # for the cam0/cam1 pairing check.
                frame, seq, t_cap = self._rcam[cam_index].capture_with_meta()
                self._frame_slots[cam_index].put(frame, t_cap, seq)
                time.sleep(0)
        except Exception as exc:
            self._cam_errors[cam_index] = exc

    def _count_missed(self, seq) -> None:
        """Frames the driving camera produced that the loop never processed —
        the gap between consecutive sequence numbers, minus one."""
        last = self._last_seq_driver
        if last is not None and seq > last + 1:
            self._missed_count += seq - last - 1
        self._last_seq_driver = seq

    def _capture_single_frame(self):
        """Next not-yet-processed frame from the single camera's capture
        thread, waiting for it if needed. None if none arrives within
        FRAME_WAIT_S (run() then gets a chance to check Godot's heartbeat)."""
        got = self._frame_slots[0].next_after(self._last_seq[0], FRAME_WAIT_S)
        if self._cam_errors[0] is not None:
            raise self._cam_errors[0]
        if got is None:
            return None
        frame, ts, seq = got
        self._last_seq[0] = seq
        self._count_missed(seq)
        self._frame_t_cap = ts
        self._frame_ts[0], self._frame_seqs[0] = ts, seq
        return frame

    def _capture_dual_frames(self):
        """One pass per frame from the driving camera (cam0, or cam1 once cam0
        has died), in capture order: takes the oldest queued frame not yet
        processed (waiting if there is none), then pairs it with the other
        camera's queued frame captured closest to it, if within
        stereo_max_frame_skew_ms. Every pass is a distinct frame, none is
        skipped unless the loop falls FRAME_QUEUE_DEPTH frames behind, and the
        pass rate is the camera's frame rate.

        A dead camera (thread raised, e.g. on stream end) reports None here
        from then on — _fuse_board_poses already falls back to the surviving
        camera's solo pose. Raises only when both cameras have died (nothing
        left to track, mirroring run()'s existing "no fresh UDP for 3s" exit).
        Returns (None, None) if no new frame arrives within FRAME_WAIT_S."""
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

        driver = 0 if self._cam_errors[0] is None else 1
        other = 1 - driver
        got = self._frame_slots[driver].next_after(self._last_seq[driver], FRAME_WAIT_S)
        if got is None:
            return None, None
        frame_d, ts_d, seq_d = got
        self._last_seq[driver] = seq_d
        self._count_missed(seq_d)
        self._frame_t_cap = ts_d
        self._frame_ts[driver], self._frame_seqs[driver] = ts_d, seq_d

        frame_o = None
        if self._cam_errors[other] is None:
            match = self._frame_slots[other].nearest(ts_d)
            if match is not None:
                frame_o, ts_o, seq_o = match
                if abs(ts_d - ts_o) > self._stereo_max_frame_skew_s:
                    # No frame of the other camera close enough in capture
                    # time — fuse without it this pass.
                    frame_o = None
                else:
                    self._last_seq[other] = seq_o
                    self._frame_ts[other], self._frame_seqs[other] = ts_o, seq_o

        frames = [None, None]
        frames[driver], frames[other] = frame_d, frame_o
        return frames[0], frames[1]

    # ── transport init ────────────────────────────────────────────────────────

    def _init_udp_socket(self) -> None:
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.bind((Config.UDP_IP, self.udp_port))
        self.udp_socket.setblocking(False)
        print("UDP socket bound to", self.udp_socket.getsockname())

    # ── validation recording (docs/validation_plan.md) ────────────────────────

    def _init_sync_watcher(self, settings: dict) -> None:
        """Watch the OptiTrack sync pin from start-up, so the installer screen
        can show the gate's state before a recording starts. A missing library,
        a busy line or no permission is reported, not fatal: tracking and the
        game do not depend on the pin."""
        chip = settings.get("sync_gpio_chip", "/dev/gpiochip4")
        line = int(settings.get("sync_gpio_line", 1))
        self._sync_desc = {"chip": chip, "line": line, "bias": None}
        try:
            self._sync = SyncWatcher(chip, line, self._on_sync_edge)
            self._sync_desc["bias"] = self._sync.bias
            print(f"Sync pin: {chip} line {line}, bias {self._sync.bias}")
        except Exception as exc:                 # no gpiod, no permission, line busy
            self._sync_error = f"{type(exc).__name__}: {exc}"
            print(f"[warn] sync pin {chip} line {line} unavailable: {self._sync_error}")

    def _on_sync_edge(self, t: float, rising: bool) -> None:
        """Called from the SyncWatcher thread for every edge."""
        with self._rec_lock:
            if self._recording is not None:
                self._recording.write_edge(t, rising)

    def _start_recording(self, raw_name: str) -> None:
        name = sanitize_name(raw_name)
        with self._rec_lock:
            if self._recording is not None:
                if self._recording.name == name:
                    return                       # Godot re-sends until it sees the status
                self._close_recording_locked()
            folder = os.path.join(self._rec_dir, name)
            extra = {"sync_pin": self._sync_desc,
                     "sync_error": self._sync_error,
                     "mono_to_unix_s": self._mono_to_unix(),
                     "pipeline": self._pipeline,
                     # raw_joint: corners.csv holds RAW fisheye pixels; these
                     # are the lens models they were found with.
                     "lens": {"camera_matrix_cam0": self._lens0[0].tolist(),
                              "dist_coeffs_cam0": self._lens0[1].flatten().tolist(),
                              "camera_matrix_cam1": (None if self._lens1 is None
                                                     else self._lens1[0].tolist()),
                              "dist_coeffs_cam1": (None if self._lens1 is None
                                                   else self._lens1[1].flatten().tolist())},
                     "undistorted": {
                         "size": list(self.ud_size),
                         "border_px": list(self._ud_pad),
                         "camera_matrix_cam0": self.camera_matrix.tolist(),
                         "camera_matrix_cam1": (None if self.camera_matrix_1 is None
                                                else self.camera_matrix_1.tolist()),
                     }}
            try:
                self._recording = Recording(folder, name, self._settings, extra)
            except OSError as exc:               # name already used, disk full, ...
                # Godot repeats REC_START until the status says "recording";
                # this tells it to stop asking instead of retrying forever.
                self._rec_error = f"{name}: {exc}"
                print(f"[warn] recording {name} not started: {exc}")
                return
            self._rec_last = ""
            self._rec_error = ""
            print(f"Recording {name} -> {folder}")

    def _stop_recording(self) -> None:
        with self._rec_lock:
            self._close_recording_locked()

    def _close_recording_locked(self) -> None:
        if self._recording is None:
            return
        rec = self._recording
        self._recording = None
        rec.close()
        self._rec_last = rec.summary()
        print(self._rec_last)

    def _send_status(self, result: Optional[FrameResult]) -> None:
        """Small JSON packet for Godot's validation-recorder screen: what the
        tracker sees and what it is writing. Sent a few times a second, not
        per frame."""
        if self.addr is None:
            return
        with self._rec_lock:
            rec = self._recording
            status = {
                "rec":    rec is not None,
                "name":   rec.name if rec else "",
                "n":      rec.n_samples if rec else 0,
                "missed": rec.missed_frames if rec else 0,
                "rise":   len(rec.rising) if rec else 0,
                "fall":   len(rec.falling) if rec else 0,
                "marks":  rec.n_marks if rec else 0,
                "folder": rec.folder if rec else self._rec_dir,
                "last":   self._rec_last,
                "rec_error": self._rec_error,
            }
        status["gate"] = bool(self._sync.high) if self._sync is not None else False
        status["sync_err"] = self._sync_error or ""
        status["m0"] = status["m1"] = 0
        status["fusion"] = ""
        if result is not None:
            status["m0"] = 0 if result.ids[0] is None else len(result.ids[0])
            status["m1"] = 0 if result.ids[1] is None else len(result.ids[1])
            status["fusion"] = result.fusion or ""
            status.update(self._placement(result))
        payload = struct.pack("<f", STATUS_CODE) + json.dumps(status).encode()
        try:
            self.udp_socket.sendto(payload, self.addr)
        except OSError:
            pass

    def _placement(self, result: FrameResult) -> dict:
        """Where the device is, for placing it during validation trials:
        displacement from the locked origin in mm, and the heading (yaw).
        The device is used flat on a table and board +Y is device-up, so the
        table plane is x-z and yaw is the turn about Y."""
        if result.fused is None or result.local_coords is None or self._origin_R is None:
            return {}
        d = -np.asarray(result.local_coords).reshape(3) * 1000.0
        R = cv2.Rodrigues(np.asarray(result.fused[0], dtype=np.float64).reshape(3))[0]
        yaw = ScipyRotation.from_matrix(self._origin_R.T @ R).as_euler("YXZ", degrees=True)[0]
        return {"x_mm": round(float(d[0]), 1), "z_mm": round(float(d[2]), 1),
                "h_mm": round(float(d[1]), 1), "yaw_deg": round(float(yaw), 1)}

    # ── transport send / receive ──────────────────────────────────────────────

    @staticmethod
    def _mono_to_unix() -> float:
        """Unix time minus monotonic time, now. Read per use: the wall clock
        can be stepped (network time sync after boot)."""
        return time.time() - time.monotonic()

    def _recv_command(self) -> bytes:
        """Return the latest command from Godot, or b'' if none."""
        try:
            # 256, not 30: a REC_START carries a recording name, and a 30-byte
            # buffer silently truncated it (2026-09-21, "..._r1" arrived as "..._r").
            data, self.addr = self.udp_socket.recvfrom(256)
            self._last_msg_time = time.monotonic()
            return data
        except socket.error:
            return b""

    def _send_coordinates(self, coords: np.ndarray) -> None:
        """Stream one sample to Godot — 24 bytes:
             bytes  0-15  4 × float32: code, x, y, z
             bytes 16-23  1 × float64: capture time of the frame, Unix seconds
        The code is always 2.0 and Godot ignores it; the slot is kept so the
        packet layout Godot parses stays unchanged.
        The capture time is float64 because float32 cannot hold a Unix time
        to better than ~2 minutes. Godot reads it when the packet is 24 bytes
        and falls back to its own arrival time otherwise."""
        if self.addr is None:
            return
        data = np.append(SAMPLE_CODE, coords).flatten()
        t_cap = (self._frame_t_cap + self._mono_to_unix()
                 if self._frame_t_cap is not None else time.time())
        data_bytes = struct.pack("<" + "f" * len(data), *data) + struct.pack("<d", t_cap)
        self.udp_socket.sendto(data_bytes, self.addr)

    # ── pose estimation ───────────────────────────────────────────────────────

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
        """Board-pose solve for one camera, using its own camera_matrix and
        ITERATIVE-guess cache. Returns (rvec, tvec,
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
            guess_rvec    = self._board_rvec
            guess_tvec    = self._board_tvec
        else:
            camera_matrix = self.camera_matrix_1
            guess_rvec    = self._board_rvec_1
            guess_tvec    = self._board_tvec_1

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
        if cam_index == 0:
            self._board_rvec, self._board_tvec = rvec, tvec
        else:
            self._board_rvec_1, self._board_tvec_1 = rvec, tvec
        self._last_reproj[cam_index] = float(reproj)

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

    def _record_stereo_gap(self, pose0, pose1) -> None:
        """cam0-vs-cam1 pose disagreement (m, rad) for the recording, when both
        cameras solved — diagnostics only in the joint mode."""
        if pose0 is None or pose1 is None:
            return
        R1p, t1p, _ = self._transform_pose_to_cam0(pose1)
        R0 = cv2.Rodrigues(pose0[0])[0]
        self._last_stereo_gap = (float(np.linalg.norm(pose0[1] - t1p)),
                                 float(rotation_angle(R0 @ R1p.T)))

    def _solve_joint(self, corners0, ids0, corners1, ids1, pose0, pose1):
        """dual_solve = "joint": ONE board pose (cam0 frame) fitted to all
        corners of both cameras (board.estimate_board_pose_dual, straightened
        pixels). No camera is picked and no two poses are averaged: every
        corner counts the same, so a camera seeing one tag has 4 corners' say
        against 16 from a camera seeing four. (The average weighted cameras by
        1/fit-error^2, which favours the camera with FEWER tags — one tag fits
        its 4 corners almost perfectly while its pose is the least certain —
        and on disagreement kept that camera: the 40-50 mm jumps of the
        2026-09-22 recordings, find_jumps.py.)

        Start: the previous frame's joint pose; if there is none or that fit
        is rejected, the per-camera pose of the camera seeing more tags.
        Rejected (> DUAL_MAX_REPROJ_PX, or > DUAL_MAX_JUMP_M from its start)
        from both starts -> None for this frame.
        Returns (rvec, tvec, mean reprojection px) or None."""
        n0 = 0 if ids0 is None else len(ids0)
        n1 = 0 if ids1 is None else len(ids1)
        if n0 == 0 and n1 == 0:
            self._joint_prev = None
            return None
        starts = []
        if self._joint_prev is not None:
            starts.append(self._joint_prev)
        for n, pose, cam in sorted(((n0, pose0, 0), (n1, pose1, 1)), key=lambda p: -p[0]):
            if pose is None:
                continue
            if cam == 0:
                starts.append((pose[0], pose[1]))
            else:
                R1p, t1p, _ = self._transform_pose_to_cam0(pose)
                starts.append((cv2.Rodrigues(R1p)[0].flatten(), t1p))
            break
        for guess in starts:
            # The standard multi-camera fit, derivatives written out: same
            # answers as estimate_board_pose_dual (bench_joint.py, 2026-09-22:
            # 0.000 mm apart on 69 583 fits), worst case 8.5 ms instead of 44.
            joint = estimate_board_pose_dual_gn(
                self.board, corners0, ids0, corners1, ids1,
                self.camera_matrix, self.camera_matrix_1,
                self._stereo_Rx, self._stereo_tx, guess, robust_px=self._robust_px)
            if joint is not None and joint[3]:
                rvec, tvec, err, _ = joint
                self._joint_prev = (rvec, tvec)
                self._last_fusion = "joint" if n0 and n1 else ("cam0" if n0 else "cam1")
                return rvec, tvec, err
        self._joint_prev = None
        self._joint_rejected += 1
        return None

    def _roi_from_joint_pose(self, fused) -> None:
        """Both cameras' next search boxes from the one joint pose."""
        rvec, tvec, err = fused
        self._roi_from_pose(0, fused, self.camera_matrix)
        R1 = self._stereo_Rx.T @ cv2.Rodrigues(np.asarray(rvec, np.float64).reshape(3, 1))[0]
        t1 = self._stereo_Rx.T @ (np.asarray(tvec, np.float64).flatten() - self._stereo_tx)
        self._roi_from_pose(1, (cv2.Rodrigues(R1)[0].flatten(), t1, err), self.camera_matrix_1)

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
        this disagreement gate already in place).

        Sets self._last_fusion to what was used — "cam0", "cam1", "both",
        or "cam0_disagree"/"cam1_disagree" (both seen, too far apart, the
        named one kept) — and self._last_stereo_gap to (distance m, angle rad)
        between the two cameras' poses whenever both were solved."""
        self._last_stereo_gap = None
        if pose0 is None and pose1 is None:
            self._last_fusion = None
            return None
        if pose1 is None:
            self._last_fusion = "cam0"
            return pose0
        R1p, t1p, e1 = self._transform_pose_to_cam0(pose1)
        if pose0 is None:
            self._last_fusion = "cam1"
            return cv2.Rodrigues(R1p)[0].flatten(), t1p, e1

        rvec0, tvec0, e0 = pose0
        R0 = cv2.Rodrigues(rvec0)[0]

        ang  = rotation_angle(R0 @ R1p.T)
        dist = float(np.linalg.norm(tvec0 - t1p))
        self._last_stereo_gap = (dist, float(ang))
        if ang > self._stereo_disagree_rot_rad or dist > self._stereo_disagree_trans_m:
            self._disagree_count += 1
            if self._disagree_count >= 30 and not self._disagree_warned:
                print("[warn] cam0/cam1 board poses disagree persistently — "
                      "stereo extrinsic calibration may be stale; re-run calibrate_stereo.py.")
                self._disagree_warned = True
            if e0 <= e1:
                self._last_fusion = "cam0_disagree"
                return pose0
            self._last_fusion = "cam1_disagree"
            return cv2.Rodrigues(R1p)[0].flatten(), t1p, e1
        self._disagree_count  = 0
        self._disagree_warned = False
        self._last_fusion     = "both"

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
        self._board_rvec          = None
        self._board_tvec          = None
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
        rvecs, tvecs = self.estimate_pose(corners)

        if self.first_frame:
            self._maybe_lock_origin(corners, ids, rvecs, tvecs)
            return None

        if self._debug_preview:            # overlay exists only to be shown
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
        if self._debug_preview and not self._raw:   # overlay is for the straightened image
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

    # ── main loop ─────────────────────────────────────────────────────────────

    def _detect_job(self, cam, frame, box):
        """One camera's search, run on that camera's own thread (_cam_pools).
        box: the search box from the latest pose (main thread), or None to use
        this camera's own box from its last search. Returns (image, corners,
        ids, ms spent)."""
        t = time.perf_counter()
        if self._raw:
            out = self._raw_detect(cam, frame, self.detector if cam == 0 else self.detector_1, box)
        elif cam == 0:
            out = self._remap_detect(0, frame, self.map1, self.map2, self.detector, box)
        else:
            out = self._remap_detect(1, frame, self.map1_1, self.map2_1, self.detector_1, box)
        return (*out, (time.perf_counter() - t) * 1000.0)

    def _remap_detect(self, cam, frame, map1, map2, detector, box=None):
        """One camera's share of a dual-mode frame: undistort, then detect —
        inside that camera's search box when there is one, else full-frame.
        Runs on this camera's own thread; `cam` selects this camera's box
        state, which only that thread touches — the main thread hands in a
        pose-based box as `box` instead of writing the state.
        Returns (undistorted image — the box crop when the box was used,
        corners in full-frame undistorted pixels, ids)."""
        self._roi_age[cam] += 1
        roi = box if box is not None else self._roi[cam]
        if (self._roi_enabled and roi is not None
                and self._roi_age[cam] < self._roi_full_every):
            x0, y0, x1, y1 = roi
            # Slicing the maps undistorts just this rectangle of the output:
            # same map entries as the full remap, so the same pixels.
            crop = cv2.remap(frame, map1[y0:y1, x0:x1], map2[y0:y1, x0:x1],
                             interpolation=cv2.INTER_LINEAR)
            corners, ids, _ = detector.detectMarkers(crop)
            corners, ids = self._filter_markers(corners, ids)
            n = 0 if ids is None else len(ids)
            if n > 0:
                offset = np.array([x0, y0], dtype=np.float32)
                corners = tuple(c + offset for c in corners)
                self._update_roi(cam, corners, n)
                return crop, corners, ids
            # Box found nothing: fall through to a full-frame search, same pass.

        self._roi_age[cam] = 0
        self._full_count[cam] += 1
        frame = cv2.remap(frame, map1, map2, interpolation=cv2.INTER_LINEAR)
        corners, ids, _ = detector.detectMarkers(frame)
        corners, ids = self._filter_markers(corners, ids)
        self._update_roi(cam, corners, 0 if ids is None else len(ids))
        return frame, corners, ids

    def _raw_detect(self, cam, frame, detector, box=None):
        """raw_joint pipeline, one camera: find the markers on the RAW frame —
        inside the search box when there is one, else full-frame. Same box
        logic as _remap_detect, minus the straightening. Corners come out in
        raw (distorted) pixels."""
        self._roi_age[cam] += 1
        roi = box if box is not None else self._roi[cam]
        self._roi_used[cam] = None
        if (self._roi_enabled and roi is not None
                and self._roi_age[cam] < self._roi_full_every):
            x0, y0, x1, y1 = roi
            self._roi_used[cam] = roi
            crop = frame[y0:y1, x0:x1]
            corners, ids, _ = detector.detectMarkers(crop)
            corners, ids = self._filter_markers(corners, ids)
            n = 0 if ids is None else len(ids)
            if n > 0:
                offset = np.array([x0, y0], dtype=np.float32)
                corners = tuple(c + offset for c in corners)
                self._update_roi(cam, corners, n)
                return frame, corners, ids
            # Box found nothing: fall through to a full-frame search, same pass.

        self._roi_used[cam] = None
        self._roi_age[cam] = 0
        self._full_count[cam] += 1
        corners, ids, _ = detector.detectMarkers(frame)
        corners, ids = self._filter_markers(corners, ids)
        self._update_roi(cam, corners, 0 if ids is None else len(ids))
        return frame, corners, ids

    def _box_preview(self, frames, corners, ids) -> np.ndarray:
        """Both raw frames side by side, on copies: the tags found, and the
        search box of this frame — green rectangle, or a red border and FULL
        when the whole frame was searched."""
        tiles = []
        for cam in (0, 1):
            frame = frames[cam]
            if frame is None:
                continue
            img = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR) if frame.ndim == 2 else frame.copy()
            if ids[cam] is not None:
                aruco.drawDetectedMarkers(img, corners[cam], ids[cam])
            roi = self._roi_used[cam]
            h, w = img.shape[:2]
            if roi is None:
                cv2.rectangle(img, (0, 0), (w - 1, h - 1), (0, 0, 255), 12)
                cv2.putText(img, "FULL", (30, 90), cv2.FONT_HERSHEY_SIMPLEX, 3, (0, 0, 255), 6)
            else:
                cv2.rectangle(img, (roi[0], roi[1]), (roi[2], roi[3]), (0, 255, 0), 4)
            cv2.putText(img, f"cam{cam}", (30, h - 30), cv2.FONT_HERSHEY_SIMPLEX, 2,
                        (255, 255, 0), 4)
            tiles.append(cv2.resize(img, (640, 400)))
        if not tiles:
            return np.zeros((400, 640, 3), np.uint8)
        return np.hstack(tiles)

    def _roi_from_pose_raw(self, cam, rvec, tvec) -> None:
        """raw_joint pipeline: like _roi_from_pose, with the device projected
        through this camera's fisheye lens onto the raw image."""
        if self._device_pts is None:
            return
        K, D = self._lens0 if cam == 0 else self._lens1
        pix, _ = cv2.fisheye.projectPoints(
            self._device_pts.reshape(-1, 1, 3),
            np.asarray(rvec, np.float64).reshape(3, 1),
            np.asarray(tvec, np.float64).reshape(3, 1), K, D)
        quads = pix.reshape(-1, 4, 2)
        side = float(np.linalg.norm(quads - np.roll(quads, -1, axis=1), axis=2).max())
        margin = min(self._roi_margin * side, self._roi_margin_max_px)
        self._set_roi(cam, quads.reshape(-1, 2), margin)

    def _solve_raw_joint(self, corners0, ids0, corners1, ids1):
        """raw_joint pipeline: one pose (cam0 frame) from both cameras' raw
        corners. Starts from the previous frame's pose; a poor fit
        (> stereo_max_reproj_px) is retried from a fresh start, and rejected if
        still poor. Sets _last_reproj per camera and _last_fusion to which
        cameras contributed. Returns (rvec, tvec, reproj) or None."""
        if ids0 is None and ids1 is None:
            self._raw_guess = None
            return None
        args = (self.board, corners0, ids0, corners1, ids1, self._lens0, self._lens1,
                self._stereo_Rx, self._stereo_tx)
        result = estimate_board_pose_raw(*args, guess=self._raw_guess)

        def worst(r):
            return np.nanmax([r[2], r[3]]) if r is not None else np.inf

        if self._raw_guess is not None and worst(result) > self._stereo_max_reproj_px:
            fresh = estimate_board_pose_raw(*args, guess=None)
            if worst(fresh) < worst(result):
                result = fresh
        if result is None or worst(result) > self._stereo_max_reproj_px:
            if result is not None:
                self._last_reproj = [None if np.isnan(e) else float(e) for e in result[2:]]
            self._raw_guess = None
            self._joint_rejected += 1
            return None
        rvec, tvec, e0, e1 = result
        self._last_reproj = [None if np.isnan(e0) else float(e0),
                             None if np.isnan(e1) else float(e1)]
        self._last_fusion = ("both" if ids0 is not None and ids1 is not None
                             else "cam0" if ids0 is not None else "cam1")
        self._raw_guess = (rvec, tvec)
        if self._roi_enabled:
            self._roi_from_pose_raw(0, rvec, tvec)
            R1 = self._stereo_Rx.T @ cv2.Rodrigues(np.asarray(rvec).reshape(3, 1))[0]
            t1 = self._stereo_Rx.T @ (np.asarray(tvec).flatten() - self._stereo_tx)
            self._roi_from_pose_raw(1, cv2.Rodrigues(R1)[0], t1)
        return rvec, tvec, float(np.nanmean([e0, e1]))

    def _roi_from_pose(self, cam, pose, camera_matrix) -> None:
        """Replace this camera's next search box with one around the whole
        device: all marker corners projected with this frame's pose, widened
        by roi_margin_markers × the largest projected marker side. Runs on the
        main thread after both workers have finished. Without a pose (too few
        markers, or a rejected solve) the markers-only box from _update_roi
        stays in place."""
        if pose is None or self._device_pts is None:
            return
        rvec, tvec, _ = pose
        pix, _ = cv2.projectPoints(self._device_pts, rvec, tvec,
                                   camera_matrix, np.zeros(5))
        quads = pix.reshape(-1, 4, 2)
        side = float(np.linalg.norm(quads - np.roll(quads, -1, axis=1), axis=2).max())
        margin = min(self._roi_margin * side, self._roi_margin_max_px)
        pts = quads.reshape(-1, 2)
        self._set_roi(cam, pts, margin)

    def _search_size(self) -> tuple:
        """Size of the image the markers are searched in: the raw frame in the
        raw_joint pipeline, the straightened image otherwise."""
        return self.frame_size if self._raw else self.ud_size

    def _set_roi(self, cam, pts, margin) -> None:
        """Pose-based box for this camera's NEXT search (main thread). Handed
        over through _roi_next — never written into the camera thread's own
        state, which may be mid-search when the overlap is on."""
        w, h = self._search_size()
        x0 = int(max(0, np.floor(pts[:, 0].min() - margin)))
        y0 = int(max(0, np.floor(pts[:, 1].min() - margin)))
        x1 = int(min(w, np.ceil(pts[:, 0].max() + margin)))
        y1 = int(min(h, np.ceil(pts[:, 1].max() + margin)))
        if x1 > x0 and y1 > y0:
            self._roi_next[cam] = (x0, y0, x1, y1)

    def _update_roi(self, cam, corners, n) -> None:
        """Next frame's search box: the markers' bounding box, widened on every
        side by roi_margin_markers × the largest marker side. Measured in
        marker widths, the margin scales with distance to the camera, and
        2 widths = 100 mm of travel between frames for 50 mm markers."""
        self._roi_count[cam] = n
        if n == 0:
            self._roi[cam] = None
            return
        quads = [np.asarray(c, dtype=np.float64).reshape(4, 2) for c in corners]
        pts = np.concatenate(quads)
        side = max(float(np.linalg.norm(q - np.roll(q, -1, axis=0), axis=1).max())
                   for q in quads)
        margin = min(self._roi_margin * side, self._roi_margin_max_px)
        w, h = self._search_size()
        self._roi[cam] = (
            int(max(0, np.floor(pts[:, 0].min() - margin))),
            int(max(0, np.floor(pts[:, 1].min() - margin))),
            int(min(w, np.ceil(pts[:, 0].max() + margin))),
            int(min(h, np.ceil(pts[:, 1].max() + margin))),
        )

    def _poll_command(self) -> None:
        """Read and act on one command from Godot (one per pass; Godot's
        heartbeat is every 100 ms). Also what keeps the "Godot still there?"
        check fed (_recv_command stamps _last_msg_time)."""
        if not self._udp_enabled:
            return
        cmd = self._recv_command()
        if cmd.startswith(b"SETUP:"):
            self._apply_setup(cmd)   # demo mode switch, not a dispatch command
        elif cmd == b"RELOCK":
            self._relock_origin()    # installer origin ritual, not a dispatch command
        elif cmd.startswith(b"REC_START:"):
            # Godot repeats this until its status shows the recording is
            # running, so a lost packet cannot leave the two disagreeing.
            self._start_recording(cmd.decode(errors="replace").split(":", 1)[1])
        elif cmd == b"REC_STOP":
            self._stop_recording()
        elif cmd.startswith(b"MARK:"):
            # A labelled moment from the recorder screen (hold start/end,
            # target reached) — see Recording.write_mark.
            with self._rec_lock:
                if self._recording is not None:
                    self._recording.write_mark(
                        time.monotonic(),
                        cmd.decode(errors="replace").split(":", 1)[1])
        elif cmd:
            self.received_message = cmd

    def process_frame(self) -> Optional[FrameResult]:
        """One pass: capture, detect, solve, fuse, and (with udp) send to
        Godot. Returns what the pass computed, or None when no new frame
        arrived within FRAME_WAIT_S.

        With overlap_detect_solve (dual camera): this pass starts the search of
        the new frame on the camera threads, then solves the frame searched
        last pass while they work, and returns THAT frame's result (its own
        capture times and sequence numbers). The first pass returns None."""
        job = self._start_frame()
        if job is None:
            # No new frame: still read Godot, so a pause in frames never looks
            # like Godot having gone (the 3 s check in run()).
            self._poll_command()
            return None
        if not (self._overlap and self._dual_camera):
            return self._finish_frame(job)
        prev, self._pending = self._pending, job
        if prev is None:
            # First pass with the overlap: nothing solved yet — but read Godot,
            # or a start-up longer than 3 s tripped the check (2026-09-22).
            self._poll_command()
            return None
        return self._finish_frame(prev)

    def _start_frame(self) -> Optional[dict]:
        """Capture, then (dual camera) hand each frame to its camera thread.
        Returns the frame's job — frames, search futures, capture times —
        or None when no new frame arrived."""
        t0 = time.perf_counter()
        self._frame_ts   = [None, None]
        self._frame_seqs = [None, None]
        if self._dual_camera:
            frame0, frame1 = self._capture_dual_frames()
            if frame0 is None and frame1 is None:
                return None
        else:
            frame0, frame1 = self._capture_single_frame(), None
            if frame0 is None:
                return None
        job = {"frames": (frame0, frame1), "ts": list(self._frame_ts),
               "seqs": list(self._frame_seqs), "t_cap": self._frame_t_cap,
               "futs": (None, None)}
        self._pass_capture_ms = (time.perf_counter() - t0) * 1000.0
        if self._dual_camera:
            # Both cameras searched at once, each on its own thread; the box
            # from the latest pose is handed over with the frame.
            boxes, self._roi_next = self._roi_next, [None, None]
            job["futs"] = tuple(
                None if f is None else self._cam_pools[c].submit(self._detect_job, c, f, boxes[c])
                for c, f in enumerate((frame0, frame1)))
        return job

    def _finish_frame(self, job: dict) -> FrameResult:
        """Everything after the search, for one frame's job: wait for its
        search, solve, fuse, origin, send, record."""
        self._frame_ts, self._frame_seqs = job["ts"], job["seqs"]
        self._frame_t_cap = job["t_cap"]
        self._last_reproj  = [None, None]
        self._last_fusion  = None
        self._last_stereo_gap = None
        # The raw frames, before undistortion, for diagnostics/record_frames.py.
        # A reference only: costs nothing and changes nothing below.
        self.last_raw_frames = job["frames"]
        frame0, frame1 = job["frames"]
        t_wait = time.perf_counter()

        # INTER_LINEAR: ~half the cost of INTER_CUBIC; corner sub-pixel accuracy
        # comes from the detector's corner refinement, not the resampling kernel.
        corners0 = ids0 = None
        corners1 = ids1 = None
        if self._dual_camera:
            fut0, fut1 = job["futs"]
            if fut0 is not None:
                frame0, corners0, ids0, ms0 = fut0.result()
                self.video_frame = frame0
                self._search_ms.append(ms0)
            if fut1 is not None:
                frame1, corners1, ids1, ms1 = fut1.result()
                self._search_ms.append(ms1)
        else:
            frame0 = cv2.remap(frame0, self.map1, self.map2, interpolation=cv2.INTER_LINEAR)
            self.video_frame = frame0
            corners0, ids0, _ = self.detector.detectMarkers(frame0)
            corners0, ids0 = self._filter_markers(corners0, ids0)
        t3 = time.perf_counter()
        wait_ms = (t3 - t_wait) * 1000.0
        # Tag flicker: a frame whose set of found tags differs from the frame
        # before. Each change moves the pose slightly (the tags' layout is
        # calibrated to ~0.7 px, not 0), so flicker is seen as vibration.
        for cam, ids in ((0, ids0), (1, ids1)):
            now = frozenset() if ids is None else frozenset(int(i) for i in np.asarray(ids).flatten())
            if self._prev_tags[cam] is not None and now != self._prev_tags[cam]:
                self._tag_flips[cam] += 1
                self._flip_ids[cam].update(now ^ self._prev_tags[cam])
            self._seen_ids[cam].update(now)
            self._prev_tags[cam] = now

        self._poll_command()

        local_coords = None
        fused = None
        if self._raw and self._dual_camera and self.board is not None:
            # raw_joint: one solve over both cameras' raw corners (see
            # _solve_raw_joint); it also places the next search boxes. (No
            # drawing here: the raw frames are the camera's read-only buffers —
            # the preview draws on copies, see _box_preview.)
            ta = time.perf_counter() if self.debug else 0.0
            fused = self._solve_raw_joint(corners0, ids0, corners1, ids1)
            if self.debug:
                self._sub_times.append(((time.perf_counter() - ta) * 1000.0, 0.0))
            if fused is not None:
                local_coords = self._process_board(fused[0], fused[1])
        elif self._dual_camera and self.board is not None and self._use_rigid:
            # Joint fusion path: each camera solves independently, cam1's pose
            # gets transformed into cam0's frame, then combined — see
            # _fuse_board_poses for the disagreement/fallback handling that
            # keeps a dead or occluded camera from breaking tracking.
            if ids0 is not None and self._debug_preview:
                self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners0, ids0)
            pose0 = self._solve_camera_pose(0, corners0, ids0) if ids0 is not None else None
            pose1 = self._solve_camera_pose(1, corners1, ids1) if ids1 is not None else None
            ta = time.perf_counter() if self.debug else 0.0
            if self._dual_solve == "joint":
                # One solve over all corners of both cameras (see _solve_joint);
                # the per-camera poses above are only its fallback start and
                # the cam0-vs-cam1 gap written to recordings.
                self._record_stereo_gap(pose0, pose1)
                fused = self._solve_joint(corners0, ids0, corners1, ids1, pose0, pose1)
                tb = time.perf_counter() if self.debug else 0.0
                if self._roi_enabled:
                    if fused is not None:
                        self._roi_from_joint_pose(fused)
                    else:
                        self._roi_from_pose(0, pose0, self.camera_matrix)
                        self._roi_from_pose(1, pose1, self.camera_matrix_1)
                if self.debug:
                    self._sub_times.append(((tb - t3) * 1000.0,
                                            (time.perf_counter() - tb) * 1000.0))
            else:
                if self._roi_enabled:
                    self._roi_from_pose(0, pose0, self.camera_matrix)
                    self._roi_from_pose(1, pose1, self.camera_matrix_1)
                tb = time.perf_counter() if self.debug else 0.0
                fused = self._fuse_board_poses(pose0, pose1)
                if self.debug:
                    # Where the "pose+send" time actually goes — the two solves,
                    # the search-box projection, then the rest (fuse, origin, UDP).
                    self._sub_times.append(((ta - t3) * 1000.0, (tb - ta) * 1000.0))
            if self._dual_solve != "joint" and fused is not None and self._joint_solve \
                    and pose0 is not None and pose1 is not None:
                # One pose from both cameras' corners, started from the averaged
                # pose and falling back to it when the fit is rejected.
                joint = estimate_board_pose_dual(
                    self.board, corners0, ids0, corners1, ids1,
                    self.camera_matrix, self.camera_matrix_1,
                    self._stereo_Rx, self._stereo_tx, (fused[0], fused[1]))
                if joint is not None:
                    rvec_j, tvec_j, err_j, accepted = joint
                    if accepted:
                        fused = (rvec_j, tvec_j, err_j)
                        self._last_fusion = "joint"
                    else:
                        self._joint_rejected += 1
            if fused is not None:
                local_coords = self._process_board(fused[0], fused[1])
        elif ids0 is not None:
            # Single-camera path (also used when dual-camera mode has no board
            # geometry loaded, or the demo SETUP toggle selected the legacy
            # per-marker solver — cam1 is simply not consulted in that case).
            if self._debug_preview:
                self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners0, ids0)
            if self.board is not None and self._use_rigid:
                pose0 = self._solve_camera_pose(0, corners0, ids0)
                if pose0 is not None:
                    fused = pose0
                    self._last_fusion = "cam0"
                    local_coords = self._process_board(pose0[0], pose0[1], corners0, ids0)
            else:
                local_coords = self._process_per_marker(corners0, ids0)

        if local_coords is not None and self.received_message:
            self._send_coordinates(local_coords)

        if self.debug:
            t4 = time.perf_counter()
            # Main thread's time this pass: waiting for the camera frame, then
            # waiting for the search result, then solving and sending. With the
            # overlap the search mostly ran during the previous pass's solve,
            # so "waited" is what is left of it, not its length.
            self._stage_times.append((
                self._pass_capture_ms,   # capture (this pass)
                wait_ms,                 # waited for the search
                0.0,
                (t4 - t3) * 1000.0,      # pose + send
            ))

            now = time.monotonic()
            if now - self._dbg_last_print > 1.0:
                if ids0 is not None:
                    sides = [np.linalg.norm(c[0][i] - c[0][(i + 1) % 4])
                             for c in corners0 for i in range(4)]
                    print(f"marker side: avg {np.mean(sides):.1f} px  (n={len(sides)//4} markers)")
                if self._stage_times:
                    arr = np.array(self._stage_times)
                    means = arr.mean(axis=0)
                    total = float(means.sum())
                    if self._dual_camera:
                        search = float(np.mean(self._search_ms)) if self._search_ms else 0.0
                        self._search_ms.clear()
                        stages = (f"search per camera (own thread): {search:5.2f} ms  |  "
                                  f"main waited for it: {means[1]:5.2f} ms  |  "
                                  f"full-frame searches: {self._full_count[0]}+{self._full_count[1]}  |  "
                                  f"tag flickers: {self._tag_flips[0]}+{self._tag_flips[1]}  |  ")
                        self._tag_flips = [0, 0]
                        # Which tags blink, per camera: "28x41/60" = tag 28 came or
                        # went 41 times and was found in 60 of the frames.
                        for cam in (0, 1):
                            which = "  ".join(
                                f"{tag}x{n}/{self._seen_ids[cam][tag]}"
                                for tag, n in self._flip_ids[cam].most_common(4))
                            stages += f"cam{cam} flicker: {which or '-'}  |  "
                            self._flip_ids[cam].clear()
                            self._seen_ids[cam].clear()
                        if self._joint_solve or self._raw or self._dual_solve == "joint":
                            stages += f"joint rejects: {self._joint_rejected}  |  "
                            self._joint_rejected = 0
                        self._full_count = [0, 0]
                    else:
                        stages = f"remap+detect: {means[1]:5.2f} ms  |  "
                    pose_split = ""
                    if self._sub_times:
                        sub = np.array(self._sub_times).mean(axis=0)
                        pose_split = (f"(solve {sub[0]:4.2f} + boxes {sub[1]:4.2f} + "
                                      f"rest {max(means[3] - sub.sum(), 0.0):4.2f})  ")
                        self._sub_times.clear()
                    line = (f"wait+capture: {means[0]:5.2f} ms  |  "
                            + stages +
                            f"pose+send: {means[3]:5.2f} ms {pose_split} |  "
                            f"total: {total:5.2f} ms  ({len(arr)} frames, "
                            f"{self._missed_count} missed)")
                    self._missed_count = 0
                    print(line)
                    if self._timing_log is not None:
                        self._timing_log.write(
                            f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]}  {line}\n"
                        )
                    self._stage_times.clear()
                self._dbg_last_print = now
            # The preview costs a resize, a window blit and the waitKey in run()
            # — several ms per frame, and it lands *outside* t0..t4, so it never
            # appears in the printed stage times while still capping the frame
            # rate. debug_preview=False keeps the numbers without that cost.
            if self._preview_box:
                cv2.imshow("frame", self._box_preview((frame0, frame1),
                                                      (corners0, corners1), (ids0, ids1)))
            elif self._debug_preview:
                self.video_frame = cv2.resize(self.video_frame, (350, 200))
                cv2.imshow("frame", self.video_frame)

        result = FrameResult(
            t_cap=tuple(self._frame_ts),
            seq=tuple(self._frame_seqs),
            corners=(corners0, corners1),
            ids=(ids0, ids1),
            reproj=tuple(self._last_reproj),
            fusion=self._last_fusion,
            stereo_gap=self._last_stereo_gap,
            fused=fused,
            local_coords=local_coords,
        )

        with self._rec_lock:
            if self._recording is not None:
                self._recording.write_sample(result)
        now = time.monotonic()
        if self._udp_enabled and now - self._status_t >= STATUS_PERIOD_S:
            self._status_t = now
            self._send_status(result)
        return result

    def close(self) -> None:
        """Stop the cameras and worker threads, close the timing log."""
        self._stop_recording()
        if self._sync is not None:
            self._sync.close()
        if self._cam_pools is not None:
            for pool in self._cam_pools:
                pool.shutdown(wait=True)
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
        if self._timing_log is not None:
            self._timing_log.close()
        if self.debug:
            cv2.destroyAllWindows()

    def run(self) -> None:
        # Start the "Godot still there?" clock when the loop starts, not when
        # set-up began: camera set-up + phase alignment can take over 3 s.
        self._last_msg_time = time.monotonic()
        try:
            while True:
                try:
                    self.process_frame()
                    if time.monotonic() - self._last_msg_time > 3.0:
                        print("No UDP packets from Godot for 3 s — exiting.")
                        break
                except Exception as exc:
                    print(f"Error: {exc} — Godot likely closed")
                    break

                if self.received_message == b"STOP":
                    break
                # waitKey only exists to service the preview window; without a
                # window it is a pure >=1 ms penalty per frame.
                if self._debug_preview and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            self.close()


def calib_path(settings: dict) -> str:
    """cam0's intrinsics file. settings.json["calibration_file"] picks it; a
    bare filename is resolved relative to pyscripts/, an absolute path is
    used as-is."""
    name = settings.get("calibration_file", "camera_calib.toml")
    if os.path.isabs(name):
        return name
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), name)


if __name__ == "__main__":
    settings = _load_settings()
    CAMERA_CALIB_PATH = calib_path(settings)
    print(f"Loading calibration from: {CAMERA_CALIB_PATH}")

    main = MainClass(cam_calib_path=CAMERA_CALIB_PATH, settings=settings)
    main.run()
