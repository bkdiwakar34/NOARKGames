import math
import time

import cv2
import numpy as np


class NoOpFilter3D:
    """Pass-through filter — useful for measuring the raw noise floor downstream."""

    def update(self, sample) -> np.ndarray:
        return np.asarray(sample, dtype=np.float64)


class CornerStabilityFilter:
    """Gate solvePnP calls: skip re-estimation when marker corners haven't moved."""

    def __init__(self, threshold: float = 2.0):
        self.threshold = threshold
        self._prev_corners = None
        self._prev_ids = None

    def is_stable(self, corners, ids) -> bool:
        """Return True if all corners moved less than threshold pixels since last update."""
        ids_flat = np.array(ids).flatten()
        n = len(corners)

        if self._prev_corners is None or n != len(self._prev_corners):
            self._store(corners, ids_flat)
            return False

        if not np.array_equal(np.sort(ids_flat), np.sort(self._prev_ids)):
            self._store(corners, ids_flat)
            return False

        curr = np.array(corners)  # (N, 1, 4, 2)
        prev = np.array(self._prev_corners)
        if curr.shape != prev.shape:
            self._store(corners, ids_flat)
            return False

        if float(np.max(np.linalg.norm(curr - prev, axis=-1))) > self.threshold:
            self._store(corners, ids_flat)
            return False

        return True

    def _store(self, corners, ids_flat) -> None:
        self._prev_corners = [c.copy() for c in corners]
        self._prev_ids = ids_flat.copy()

    def reset(self) -> None:
        """Force the next is_stable() call to return False and re-arm from scratch."""
        self._prev_corners = None
        self._prev_ids = None


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
