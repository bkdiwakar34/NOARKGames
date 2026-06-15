import csv
import json
import os
import platform
import socket
import struct
from datetime import datetime
from typing import Optional

import cv2
import numpy as np
from cv2 import aruco

from filters import ExponentialMovingAverageFilter3D


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
    FRAME_SIZE = (1200, 800)
    MARKER_LENGTH = 0.05
    MARKER_SEPARATION = 0.01
    UDP_IP = "localhost"
    ALPHA = 0.4
    MARKER_OFFSETS = {
        4:  np.array([0.00,  0.1,    -0.069]),
        8:  np.array([0.00,  0.01,   -0.069]),
        12: np.array([0.00,  0.0,    -0.1075]),
        14: np.array([-0.09, 0.0,    -0.069]),
        20: np.array([0.1,   0.0,    -0.069]),
    }


class MainClass:
    def __init__(self, cam_calib_path: str, settings: Optional[dict] = None) -> None:
        if settings is None:
            settings = {}

        self.debug = settings.get("debug", False)
        self.udp_port        = settings.get("udp_port", 12345)

        self.filter            = ExponentialMovingAverageFilter3D(alpha=Config.ALPHA)
        self.frame_size        = Config.FRAME_SIZE
        self.marker_length     = Config.MARKER_LENGTH
        self.marker_separation = Config.MARKER_SEPARATION

        import toml
        calib_data = toml.load(cam_calib_path)
        self.camera_matrix    = np.array(calib_data["calibration"]["camera_matrix"]).reshape(3, 3)
        self.distortion_coeff = np.array(calib_data["calibration"]["dist_coeffs"])

        self.detector = self._init_detector()
    

        self.picam2 = self.map1 = self.map2 = None  # Pi camera object + fisheye undistort maps (set in _init_rpi_camera)
        self.video_frame  = None                    # latest captured image, refreshed every frame
        self.first_frame  = True                    # True until the first frame with detected markers — used to lock the world origin
        self.save_path    = None                    # folder for this patient's CSV, created on first USER: message
        self.csv_writer   = None                    # csv.writer for the active session, created alongside save_path
        self.record       = False                   # True once Godot has sent USER: and we should log rows
        self.received_message: bytes = b""          # most recent UDP command from Godot (sticky — last command is reused each frame)
        self.addr         = None                    # Godot's UDP address, learned from the first incoming packet
        self._dbg_last_print = 0.0                  # timestamp of last debug print, to throttle to ~1/sec

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
        params = aruco.DetectorParameters()
        params.useAruco3Detection     = True
        params.cornerRefinementMethod = aruco.CORNER_REFINE_CONTOUR
        dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
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
                "FrameRate": 100,       # high rate for low-latency tracking; real-world rate may be lower
                "ExposureTime": 5000,   # 5 ms — short enough to freeze hand motion (no blur on marker corners)
                "AeEnable": False,      # lock auto-exposure off so the camera can't override ExposureTime
            },
        )
        self.picam2.configure(config)
        self.picam2.start()

        import toml
        _pyscripts_dir = os.path.dirname(os.path.abspath(__file__))
        fish_params = toml.load(os.path.join(_pyscripts_dir, "good.toml"))
        fish_matrix = np.array(fish_params["calibration"]["camera_matrix"]).reshape(3, 3)
        fish_dist   = np.array(fish_params["calibration"]["dist_coeffs"])
        self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
            fish_matrix, fish_dist, np.eye(3), fish_matrix, self.frame_size, cv2.CV_16SC2
        )

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
        for corner in corners:
            success, rvec, tvec = cv2.solvePnP(
                marker_points, corner, self.camera_matrix, self.distortion_coeff,
                flags=cv2.SOLVEPNP_IPPE_SQUARE,
            )
            if success:
                rvecs.append(rvec.flatten())
                tvecs.append(tvec.flatten())
        return np.array(rvecs), np.array(tvecs)

    def _draw_axes(self, rvecs, tvecs) -> None:
        for rvec, tvec in zip(rvecs, tvecs):
            cv2.drawFrameAxes(
                self.video_frame, self.camera_matrix, self.distortion_coeff, rvec, tvec, 0.05
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
            self.csv_writer = csv.writer(open(csv_path, "w", newline=""))
            self.csv_writer.writerow(["Time", "X", "Y", "Z"])

    # ── main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        # Capture frame
        if platform.system() == "Linux":
            self.video_frame = self.picam2.capture_array()
            self.video_frame = cv2.remap(
                self.video_frame, self.map1, self.map2, interpolation=cv2.INTER_LINEAR
            )
            self.video_frame = cv2.flip(self.video_frame, 1)
        else:
            ret, self.video_frame = self.camera.read()
            if not ret or self.video_frame is None:
                return

        # Poll command from Godot
        cmd = self._recv_command()
        if cmd:
            self.received_message = cmd

        # Detect markers
        corners, ids, _ = self.detector.detectMarkers(self.video_frame)
        if ids is not None:
            self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners, ids)
            rvecs, tvecs = self.estimate_pose(corners)

            if self.first_frame:
                self.first_id   = ids
                self.first_rvec = rvecs
                self.first_tvec = tvecs
                self.first_frame = False

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
                    self._hid = self.received_message.decode().split(":")[1]
                    if self.save_path is None:
                        self._select_hospitalid()
                    self._send_coordinates("START", local_coords)
                    self.record = True
                elif self.received_message.startswith(b"CHANGE:"):
                    self.save_path = None
                    self._hid = self.received_message.decode().split(":")[1]
                    self._select_hospitalid()
                    self._send_coordinates("START", local_coords)
                    self.record = True
                elif self.received_message == b"RESET":
                    self._send_coordinates("RESET", local_coords)
                else:
                    self._send_coordinates("START", local_coords)

                if self.record and self.csv_writer:
                    self.csv_writer.writerow(
                        [datetime.now().strftime("%d/%m/%Y %H:%M:%S"), *local_coords]
                    )

        if self.debug:
            import time
            if ids is not None and time.time() - self._dbg_last_print > 1.0:
                sides = [np.linalg.norm(c[0][i] - c[0][(i + 1) % 4])
                         for c in corners for i in range(4)]
                print(f"marker side: avg {np.mean(sides):.1f} px  (n={len(sides)//4} markers)")
                self._dbg_last_print = time.time()
            self.video_frame = cv2.resize(self.video_frame, (350, 200))
            cv2.imshow("frame", self.video_frame)

    def run(self) -> None:
        import time

        last_heartbeat = time.time()

        try:
            while True:
                try:
                    self.process_frame()
                    if self.received_message:
                        last_heartbeat = time.time()
                    if time.time() - last_heartbeat > 3.0:
                        print("Lost connection to Godot, exiting…")
                        break
                except Exception as exc:
                    print(f"Error: {exc} — Godot likely closed")
                    break

                if self.received_message == b"STOP":
                    break
                if self.debug and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self.debug:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    settings = _load_settings()

    _pyscripts_dir = os.path.dirname(os.path.abspath(__file__))
    CAMERA_CALIB_PATH = os.path.join(_pyscripts_dir, "calib_mono_faith.toml")

    main = MainClass(cam_calib_path=CAMERA_CALIB_PATH, settings=settings)
    main.run()
