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

MARKER_LENGTH = 0.05

# Offsets from each marker's center to the handle grip point, expressed
# in the marker's own frame (+X = printed-right, +Y = printed-up, +Z = out
# of face). Derived from the CAD model — markers are glued with +Y
# (printed-up) aligned to device-up.
MARKER_OFFSETS = {
    4:  np.array([-0.002, -0.016, -0.056]),   # front-right (angled 60° from +X, into -Y)
    8:  np.array([ 0.002, -0.016, -0.056]),   # front-left  (angled 60° from +X, into +Y)
    12: np.array([ 0.001, -0.016, -0.059]),   # front
    14: np.array([ 0.000, -0.066, -0.065]),   # front-top   (angled 10° from +X toward +Z)
    20: np.array([ 0.125, -0.017, -0.054]),   # back / -Y side
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
