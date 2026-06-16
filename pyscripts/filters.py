import math
import time

import cv2
import numpy as np


class ExponentialMovingAverageFilter3D:
    def __init__(self, alpha):
        self.alpha = alpha
        self.ema_x = None
        self.ema_y = None
        self.ema_z = None

    def update(self, sample):
        if self.ema_x is None:
            self.ema_x = sample[0]
            self.ema_y = sample[1]
            self.ema_z = sample[2]
        else:
            self.ema_x = self.alpha * sample[0] + (1 - self.alpha) * self.ema_x
            self.ema_y = self.alpha * sample[1] + (1 - self.alpha) * self.ema_y
            self.ema_z = self.alpha * sample[2] + (1 - self.alpha) * self.ema_z
        return np.array([self.ema_x, self.ema_y, self.ema_z])


class KalmanFilter3D:
    """
    Constant-velocity Kalman filter for 3D position.

    State : [x, y, z, vx, vy, vz]  (6-D)
    Measurement : [x, y, z]        (3-D, from solvePnP centroid)

    dt is measured per-update from time.monotonic() so the model stays correct
    regardless of frame-rate jitter. process_noise controls how much velocity
    can change between frames (higher = follows fast hand motion more closely,
    less smoothing). measurement_noise reflects how noisy the raw centroid is
    (higher = trust the model more, smooth harder).
    """

    def __init__(self, process_noise: float = 0.01, measurement_noise: float = 0.05) -> None:
        self.kf = cv2.KalmanFilter(6, 3)
        self.kf.measurementMatrix = np.array(
            [[1, 0, 0, 0, 0, 0],
             [0, 1, 0, 0, 0, 0],
             [0, 0, 1, 0, 0, 0]],
            dtype=np.float32,
        )
        self.kf.processNoiseCov     = np.eye(6, dtype=np.float32) * process_noise
        self.kf.measurementNoiseCov = np.eye(3, dtype=np.float32) * measurement_noise
        self.kf.errorCovPost        = np.eye(6, dtype=np.float32) * 1.0
        self._last_time: float | None = None
        self._initialised: bool = False

    def update(self, sample) -> np.ndarray:
        m = np.array(sample, dtype=np.float32).reshape(3, 1)
        now = time.monotonic()

        if not self._initialised:
            # Seed the state with the first measurement, zero velocity.
            self.kf.statePost = np.array(
                [m[0, 0], m[1, 0], m[2, 0], 0.0, 0.0, 0.0],
                dtype=np.float32,
            ).reshape(6, 1)
            self._last_time   = now
            self._initialised = True
            return np.array([m[0, 0], m[1, 0], m[2, 0]])

        dt = float(now - self._last_time)
        self._last_time = now
        self.kf.transitionMatrix = np.array(
            [[1, 0, 0, dt, 0, 0],
             [0, 1, 0, 0, dt, 0],
             [0, 0, 1, 0, 0, dt],
             [0, 0, 0, 1, 0,  0],
             [0, 0, 0, 0, 1,  0],
             [0, 0, 0, 0, 0,  1]],
            dtype=np.float32,
        )

        self.kf.predict()
        corrected = self.kf.correct(m)
        return np.array([corrected[0, 0], corrected[1, 0], corrected[2, 0]])


class OneEuroFilter3D:
    """
    One Euro Filter (https://gery.casiez.net/1euro/) for 3D position.

    Adaptive low-pass: the cutoff frequency rises with hand speed, so the
    filter smooths heavily when the device is held still (small jitter
    rejected) and opens up when the user reaches for a target (no lag).

    min_cutoff : cutoff in Hz at zero speed. Lower → smoother hold.
    beta       : how much the cutoff grows with speed. Higher → more reactive.
    d_cutoff   : cutoff in Hz for the speed (derivative) estimate.
    """

    def __init__(self, min_cutoff: float = 1.0, beta: float = 0.007, d_cutoff: float = 1.0) -> None:
        self.min_cutoff = float(min_cutoff)
        self.beta       = float(beta)
        self.d_cutoff   = float(d_cutoff)
        self._x_prev    = None
        self._dx_prev   = np.zeros(3, dtype=np.float64)
        self._t_prev: float | None = None

    @staticmethod
    def _alpha(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def update(self, sample) -> np.ndarray:
        x = np.array(sample, dtype=np.float64)
        now = time.monotonic()
        if self._x_prev is None:
            self._x_prev = x.copy()
            self._t_prev = now
            return x

        dt = max(now - self._t_prev, 1e-6)
        self._t_prev = now

        # Smoothed derivative (used as the speed estimate).
        dx          = (x - self._x_prev) / dt
        a_d         = self._alpha(self.d_cutoff, dt)
        dx_smoothed = a_d * dx + (1.0 - a_d) * self._dx_prev

        # Adaptive cutoff scales with speed.
        speed  = float(np.linalg.norm(dx_smoothed))
        cutoff = self.min_cutoff + self.beta * speed
        a_x    = self._alpha(cutoff, dt)

        x_smoothed    = a_x * x + (1.0 - a_x) * self._x_prev
        self._x_prev  = x_smoothed
        self._dx_prev = dx_smoothed
        return x_smoothed


class CoordinateTransform:
    def __init__(self, offsets):
        self.offsets = offsets
        self.rotation_matrix = None
        self.translation_vector = None
        self.transformed = None

    def compute_transformed_coordinates(self, coordinate):
        self.rotation_matrix = R.from_rotvec(
            np.array([coordinate["rx"], coordinate["ry"], coordinate["rz"]]).T
        ).as_matrix()
        self.translation_vector = np.array(
            [coordinate["x"], coordinate["y"], coordinate["z"]]
        )
        self.transformed = np.array(
            [
                (_r @ self.offsets.reshape(3, 1) + _t.reshape(3, 1)).T[0]
                for _r, _t in zip(self.rotation_matrix, self.translation_vector.T)
            ]
        )
        return self.rotation_matrix, self.translation_vector, self.transformed

    def transform_to_world_coordinates(self):
        _r_88_inv = self.rotation_matrix[0].T
        _tvec_88_0 = self.translation_vector.T[0]
        world_coordinates = {}
        for key in [12, 14, 20, 88, 89]:
            world_coordinates[key] = _r_88_inv @ (self.transformed - self.offsets).T
        return world_coordinates


# import numpy as np
# from scipy.spatial.transform import Rotation as R

# # Define offsets
# offsets = {
#     12: np.array([-0.054, 0.031, -0.069]),
#     14: np.array([0.00, 0.1025, -0.069]),
#     20: np.array([0.00, 0.01, -0.069]),
#     88: np.array([0.00, 0.031, -0.1075]),
#     89: np.array([0.054, 0.031, -0.069])
# }

# # Function to compute transformed coordinates
# def compute_transformed_coordinates(coordinate, id_offset):
#     rotation_matrix = R.from_rotvec(np.array([coordinate['rx'], coordinate['ry'], coordinate['rz']]).T).as_matrix()
#     translation_vector = np.array([coordinate['x'], coordinate['y'], coordinate['z']])
#     transformed = np.array([(_r @ id_offset.reshape(3,1) + _t.reshape(3,1)).T[0] for _r, _t in zip(rotation_matrix, translation_vector.T)])
#     return rotation_matrix, translation_vector, transformed

# # Compute transformations
# results = {}
# for key in [12, 14, 20, 88, 89]:
#     results[key] = compute_transformed_coordinates(coordinate[str(key)], offsets[key])

# # Transform to world coordinates
# _r_88_inv = results[88][0][0].T
# _tvec_88_0 = results[88][1].T[0]

# world_coordinates = {}
# for key in [12, 14, 20, 88, 89]:
#     world_coordinates[key] = _r_88_inv @ (results[key][2] - _tvec_88_0).T

# _gt_12, _gt_14, _gt_20, _gt_88, _gt_89 = [world_coordinates[key] for key in [12, 14, 20, 88, 89]]
