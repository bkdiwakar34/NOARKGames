"""
Shared rigid-transform averaging utilities.

Used by calibrate_board.py (averaging marker-to-marker pair transforms) and
calibrate_stereo.py (averaging camera-to-camera extrinsic transforms) — same
math, different sample sources.
"""

import numpy as np

DEFAULT_ROT_TOL_RAD = np.deg2rad(3.0)   # outlier trim: rotation residual
DEFAULT_TRANS_TOL_M = 0.005             # outlier trim: translation residual (5 mm)


def mean_rotation(Rs):
    """Chordal mean: average the matrices, project back onto SO(3) via SVD."""
    U, _, Vt = np.linalg.svd(np.mean(Rs, axis=0))
    if np.linalg.det(U @ Vt) < 0:
        U[:, -1] *= -1
    return U @ Vt


def rotation_angle(R):
    return float(np.arccos(np.clip((np.trace(R) - 1) / 2, -1.0, 1.0)))


def robust_average_transform(samples, rot_tol_rad=DEFAULT_ROT_TOL_RAD,
                              trans_tol_m=DEFAULT_TRANS_TOL_M):
    """Trimmed average of relative transforms. Returns (R, t, stats)."""
    Rs = np.array([s[0] for s in samples])
    ts = np.array([s[1] for s in samples])
    keep = np.ones(len(samples), dtype=bool)
    for _ in range(2):
        R_bar = mean_rotation(Rs[keep])
        t_bar = np.median(ts[keep], axis=0)
        ang = np.array([rotation_angle(R @ R_bar.T) for R in Rs])
        dt  = np.linalg.norm(ts - t_bar, axis=1)
        new_keep = (ang < rot_tol_rad) & (dt < trans_tol_m)
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
