"""
Rigid-body board model for the multi-marker NOARK device.

The markers are glued to one rigid object, so the whole constellation has a
single pose. Once each marker's fixed pose *on the device* is known (from
calibrate_board.py), all detected corners — from however many markers happen
to be visible — feed one joint solvePnP. Depth is then constrained by the
spread between markers instead of each marker's own apparent size, which
cuts Z jitter dramatically and removes the IPPE tilt-ambiguity flips.

Board frame = the reference marker's frame (identity pose for the reference).
Geometry is stored in board_geometry.json next to this file.
"""

import json

import cv2
import numpy as np
from scipy.optimize import least_squares

MARKER_LENGTH = 0.05

# Offsets from each marker's center to the handle grip point, expressed
# in the marker's own frame (+X = printed-right, +Y = printed-up, +Z = out
# of face). Derived from the CAD model — markers are glued with +Y
# (printed-up) aligned to device-up.
MARKER_OFFSETS = {
    4:  np.array([-0.002, -0.016, -0.056]),   # front-right    (angled 60° from +X, into -Y)
    8:  np.array([ 0.002, -0.016, -0.056]),   # front-left     (angled 60° from +X, into +Y)
    12: np.array([ 0.001, -0.016, -0.059]),   # front
    14: np.array([ 0.000, -0.066, -0.065]),   # front-top      (angled 10° from +X toward +Z)
    20: np.array([ 0.125, -0.017, -0.054]),   # back-right     (-Y side)
    24: np.array([-0.125, -0.017, -0.054]),   # back-left      (+Y side, mirror of 20)
    28: np.array([-0.161, -0.019,  0.104]),   # back-far-left  wing (empirical, via derive_offsets.py)
    32: np.array([ 0.157, -0.017,  0.115]),   # back-far-right wing (empirical, via derive_offsets.py)
}


def marker_object_points(length: float = MARKER_LENGTH) -> np.ndarray:
    """Corner coordinates in the marker's own frame, in ArUco detection
    order (TL, TR, BR, BL) — must match cv2.SOLVEPNP_IPPE_SQUARE."""
    h = length / 2
    return np.array(
        [[-h,  h, 0],
         [ h,  h, 0],
         [ h, -h, 0],
         [-h, -h, 0]],
        dtype=np.float32,
    )


class BoardGeometry:
    """Fixed pose of every marker in the board frame, plus the grip point.

    marker_poses maps id -> (R, t) where R (3,3) and t (3,) take a point
    from the marker's frame into the board frame: p_board = R @ p_marker + t.
    """

    def __init__(self, marker_length: float, reference_id: int,
                 marker_poses: dict, grip_point: np.ndarray):
        self.marker_length = float(marker_length)
        self.reference_id = int(reference_id)
        self.marker_poses = marker_poses
        self.grip_point = np.asarray(grip_point, dtype=np.float64).flatten()

    def corners_in_board(self, marker_id: int) -> np.ndarray:
        R, t = self.marker_poses[marker_id]
        local = marker_object_points(self.marker_length).astype(np.float64)
        return (local @ R.T) + t

    @classmethod
    def load(cls, path: str) -> "BoardGeometry":
        with open(path) as f:
            data = json.load(f)
        poses = {
            int(mid): (np.array(m["rotation"], dtype=np.float64).reshape(3, 3),
                       np.array(m["translation"], dtype=np.float64).flatten())
            for mid, m in data["markers"].items()
        }
        return cls(data["marker_length"], data["reference_id"],
                   poses, np.array(data["grip_point"]))

    def save(self, path: str, meta: dict = None) -> None:
        data = {
            "marker_length": self.marker_length,
            "reference_id": self.reference_id,
            "grip_point": self.grip_point.tolist(),
            "markers": {
                str(mid): {"rotation": R.tolist(), "translation": t.tolist()}
                for mid, (R, t) in self.marker_poses.items()
            },
        }
        if meta:
            data["meta"] = meta
        with open(path, "w") as f:
            json.dump(data, f, indent=2)


def reprojection_error(obj_pts, img_pts, rvec, tvec, camera_matrix) -> float:
    """Mean pixel distance between detected corners and the pose's projection."""
    proj, _ = cv2.projectPoints(
        np.asarray(obj_pts, dtype=np.float64), rvec, tvec, camera_matrix, np.zeros(5)
    )
    return float(np.linalg.norm(proj.reshape(-1, 2) - np.asarray(img_pts).reshape(-1, 2), axis=1).mean())


def _board_points(board: BoardGeometry, corners, ids):
    """(object points in the board frame, image points) for the markers this
    camera saw and the geometry knows about. (None, None) if there are none."""
    if ids is None:
        return None, None
    obj_pts, img_pts = [], []
    for corner, _id in zip(corners, np.asarray(ids).flatten()):
        _id = int(_id)
        if _id not in board.marker_poses:
            continue
        obj_pts.append(board.corners_in_board(_id))
        img_pts.append(np.asarray(corner).reshape(4, 2))
    if not obj_pts:
        return None, None
    return (np.concatenate(obj_pts).astype(np.float64),
            np.concatenate(img_pts).astype(np.float64))


# A joint fit is thrown away when it disagrees with the images by more than
# this, or has moved this far from the pose it started at. With weak geometry
# (one small marker at the edge of the workspace) an unbounded fit can wander
# — offline it once returned a pose 210 mm out (2026-09-21).
DUAL_MAX_REPROJ_PX = 3.0
DUAL_MAX_JUMP_M = 0.02


def estimate_board_pose_dual(board: BoardGeometry, corners0, ids0, corners1, ids1,
                             K0, K1, Rx, tx, guess):
    """One board pose in cam0's frame, fitted to ALL corners from BOTH cameras.

    Both cameras see one rigid object, so one pose predicts both images: a
    board point b is at p0 = R b + t in cam0 and at p1 = Rx^T (p0 - tx) in
    cam1. Fitting once uses every corner, instead of solving each camera alone
    and averaging the two answers — worth about a third of the jitter while
    still (0.72 -> 0.47 mm median over one T1 grid, 2026-09-21).

    guess: (rvec, tvec) to start from — the averaged pose, which is also what
    is returned when the fit is rejected.

    Returns (rvec (3,), tvec (3,), mean_reproj_px, accepted) or None when
    neither camera has a usable marker.
    """
    obj0, img0 = _board_points(board, corners0, ids0)
    obj1, img1 = _board_points(board, corners1, ids1)
    if obj0 is None and obj1 is None:
        return None
    zero_dist = np.zeros(5)
    RxT = np.asarray(Rx, dtype=np.float64).T
    tx = np.asarray(tx, dtype=np.float64).flatten()

    def errors(x):
        rvec, tvec = x[:3], x[3:]
        out = []
        if obj0 is not None:
            proj = cv2.projectPoints(obj0, rvec, tvec, K0, zero_dist)[0].reshape(-1, 2)
            out.append(proj - img0)
        if obj1 is not None:
            r1 = cv2.Rodrigues(RxT @ cv2.Rodrigues(rvec)[0])[0].flatten()
            t1 = RxT @ (tvec - tx)
            proj = cv2.projectPoints(obj1, r1, t1, K1, zero_dist)[0].reshape(-1, 2)
            out.append(proj - img1)
        return np.concatenate(out)

    x0 = np.concatenate([np.asarray(guess[0], dtype=np.float64).reshape(3),
                         np.asarray(guess[1], dtype=np.float64).reshape(3)])
    try:
        res = least_squares(lambda x: errors(x).ravel(), x0, method="lm", xtol=1e-9)
        x = res.x
    except Exception:
        return guess[0], guess[1], float("nan"), False

    err = float(np.linalg.norm(errors(x), axis=1).mean())
    jump = float(np.linalg.norm(x[3:] - x0[3:]))
    if (not np.all(np.isfinite(x)) or err > DUAL_MAX_REPROJ_PX
            or jump > DUAL_MAX_JUMP_M):
        return guess[0], guess[1], err, False
    return x[:3], x[3:], err, True


def estimate_board_pose(board: BoardGeometry, corners, ids, camera_matrix,
                        guess=None):
    """Single rigid-body pose from all visible known markers.

    Returns (rvec (3,), tvec (3,), mean_reproj_px) or None if no known
    marker is visible / the solve fails.

    Solver choice:
      - guess available  -> ITERATIVE refined from the previous frame's pose.
        Works for any marker count and naturally rejects the mirrored
        tilt solution of a lone planar marker.
      - >= 2 markers, no guess -> SQPNP (robust for arbitrary 3D point sets).
      - 1 marker, no guess -> IPPE_SQUARE on that marker, composed with its
        stored board pose.
    """
    ids_flat = np.asarray(ids).flatten()
    obj_pts, img_pts, used_ids = [], [], []
    for corner, _id in zip(corners, ids_flat):
        _id = int(_id)
        if _id not in board.marker_poses:
            continue
        obj_pts.append(board.corners_in_board(_id))
        img_pts.append(np.asarray(corner).reshape(4, 2))
        used_ids.append(_id)
    if not used_ids:
        return None

    obj = np.concatenate(obj_pts).astype(np.float64)
    img = np.concatenate(img_pts).astype(np.float64)
    zero_dist = np.zeros(5)  # frames are undistorted upstream

    if guess is not None:
        rvec0 = np.asarray(guess[0], dtype=np.float64).reshape(3, 1).copy()
        tvec0 = np.asarray(guess[1], dtype=np.float64).reshape(3, 1).copy()
        ok, rvec, tvec = cv2.solvePnP(
            obj, img, camera_matrix, zero_dist, rvec0, tvec0,
            useExtrinsicGuess=True, flags=cv2.SOLVEPNP_ITERATIVE,
        )
    elif len(used_ids) >= 2:
        ok, rvec, tvec = cv2.solvePnP(
            obj, img, camera_matrix, zero_dist, flags=cv2.SOLVEPNP_SQPNP,
        )
    else:
        _id = used_ids[0]
        ok, r_m, t_m = cv2.solvePnP(
            marker_object_points(board.marker_length).astype(np.float64), img,
            camera_matrix, zero_dist, flags=cv2.SOLVEPNP_IPPE_SQUARE,
        )
        if not ok:
            return None
        R_pnp = cv2.Rodrigues(r_m)[0]
        R_bm, t_bm = board.marker_poses[_id]
        R_cb = R_pnp @ R_bm.T                       # camera <- board
        t_cb = t_m.flatten() - R_cb @ t_bm
        rvec = cv2.Rodrigues(R_cb)[0]
        tvec = t_cb.reshape(3, 1)

    if not ok:
        return None
    err = reprojection_error(obj, img, rvec, tvec, camera_matrix)
    return rvec.flatten(), tvec.flatten(), err
