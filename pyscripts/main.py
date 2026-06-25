import csv
import json
import os
import platform
import socket
import struct
import time
from datetime import datetime
from typing import Optional

import cv2
import numpy as np
from cv2 import aruco

from filters import (
    CornerStabilityFilter,
    ExponentialMovingAverageFilter3D,
    KalmanFilter3D,
    NoOpFilter3D,
    OneEuroFilter3D,
)


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
    MARKER_LENGTH = 0.05
    UDP_IP = "localhost"
    ALPHA = 0.4
    ORIGIN_LOCK_FRAMES = 10         # consecutive stable frames required before locking the world origin
    ORIGIN_STABLE_PX   = 2.0        # max mean corner motion (px) between frames to count as stable
    # Offsets from each marker's center to the handle grip point, expressed
    # in the marker's own frame (+X = printed-right, +Y = printed-up, +Z = out
    # of face). Derived from the CAD model — markers are glued with +Y
    # (printed-up) aligned to device-up.
    MARKER_OFFSETS = {
        12: np.array([ 0.001,  0.046, -0.059]),   # front face
        14: np.array([-0.125,  0.045, -0.054]),   # left face
        20: np.array([ 0.125,  0.045, -0.054]),   # right face
    }


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

        # Fisheye undistort map. After remapping a frame with these, the image is
        # pinhole-equivalent with intrinsics = camera_matrix and zero distortion,
        # so downstream solvePnP uses camera_matrix with np.zeros(5).
        self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
            self.camera_matrix, self.dist_coeffs, np.eye(3),
            self.camera_matrix, self.frame_size, cv2.CV_16SC2,
        )

        self._corner_refine_name = str(settings.get("corner_refine", "contour")).lower()
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
        self._cached_rvecs = None
        self._cached_tvecs = None

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

        # Camera
        if platform.system() == "Linux":
            self._init_rpi_camera()
        else:
            self._init_camera()

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
            self.first_id   = ids
            self.first_rvec = rvecs
            self.first_tvec = tvecs
            self.first_frame = False
            self._prev_corners = None
            self._prev_ids = None
            print(f"World origin locked after {self._origin_stable_count} stable frames.")

    def _draw_axes(self, rvecs, tvecs) -> None:
        zero_dist = np.zeros(5)
        for rvec, tvec in zip(rvecs, tvecs):
            cv2.drawFrameAxes(
                self.video_frame, self.camera_matrix, zero_dist, rvec, tvec, 0.05
            )

    def _get_centroid(self, ids, rvecs, tvecs) -> np.ndarray:
        ids   = np.array(ids).flatten()
        tvecs = np.array(tvecs).reshape(len(ids), 3)
        rvecs = np.array(rvecs).reshape(len(ids), 3)

        transformed = np.full((len(ids), 3), np.nan)
        for index, _id in enumerate(ids):
            if _id in Config.MARKER_OFFSETS:
                transformed[index] = (
                    cv2.Rodrigues(rvecs[index])[0]
                    @ Config.MARKER_OFFSETS[_id].reshape(3, 1)
                    + tvecs[index].reshape(3, 1)
                ).T[0]
        return np.nanmean(transformed, axis=0).flatten()

    def _get_local_coordinates(self, first_id, first_rvecs, first_tvecs, centroid) -> np.ndarray:
        first_id    = np.array(first_id).flatten()
        first_tvecs = np.array(first_tvecs).reshape(len(first_id), 3)
        first_rvecs = np.array(first_rvecs).reshape(len(first_id), 3)

        _id  = first_id[0]
        _r   = cv2.Rodrigues(first_rvecs[0])[0]
        _t   = first_tvecs[0]
        _local_camera_t = (
            _r @ Config.MARKER_OFFSETS[_id].reshape(3, 1) + _t.reshape(3, 1)
        ).T[0]
        return (_r.T @ (_local_camera_t - centroid).reshape(3, 1)).T[0]

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

        # Capture frame
        if platform.system() == "Linux":
            self.video_frame = self.picam2.capture_array()
        else:
            ret, self.video_frame = self.camera.read()
            if not ret or self.video_frame is None:
                return
        t1 = time.perf_counter() if self.debug else 0.0

        self.video_frame = cv2.remap(
            self.video_frame, self.map1, self.map2, interpolation=cv2.INTER_CUBIC
        )
        t2 = time.perf_counter() if self.debug else 0.0

        # Poll command from Godot
        cmd = self._recv_command()
        if cmd:
            self.received_message = cmd

        # Detect markers
        corners, ids, _ = self.detector.detectMarkers(self.video_frame)
        t3 = time.perf_counter() if self.debug else 0.0
        if ids is not None:
            self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners, ids)

            if self.corner_stability.is_stable(corners, ids) and self._cached_rvecs is not None:
                rvecs, tvecs = self._cached_rvecs, self._cached_tvecs
            else:
                rvecs, tvecs = self.estimate_pose(corners)
                self._cached_rvecs, self._cached_tvecs = rvecs, tvecs

            if self.first_frame:
                self._maybe_lock_origin(corners, ids, rvecs, tvecs)

        if ids is not None and not self.first_frame:
            self._draw_axes(rvecs, tvecs)
            centroid    = self._get_centroid(ids, rvecs, tvecs)
            local_coords = self._get_local_coordinates(
                self.first_id, self.first_rvec, self.first_tvec, centroid
            )
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
                if ids is not None:
                    sides = [np.linalg.norm(c[0][i] - c[0][(i + 1) % 4])
                             for c in corners for i in range(4)]
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
