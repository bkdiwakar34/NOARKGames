#!/usr/bin/env python3
"""
theoretical_error.py - predicted pose error of the two-camera tracker.

The tracker's joint fit (board.estimate_board_pose_dual_gn) finds the one
board pose whose predicted corners best match every corner both cameras saw:

    p_hat = argmin_p  sum_c sum_k || u_k^c - u_hat_k^c(p) ||^2

Linearised about the true pose, the pose error delta (a small turn omega
about cam0's origin, then a slide t, both in cam0's frame - the same
parameters as the tracker's LM step) follows from the corner pixel noise eps:

    J delta = eps   ->   delta = (J^T J)^-1 J^T eps

so, with every pixel coordinate carrying independent noise of size sigma,

    Cov(delta) = sigma^2 (J^T J)^-1

(or the sandwich (J^T J)^-1 J^T S J (J^T J)^-1 when cam1's sigma differs
from cam0's, --sigma-ratio). J is built exactly as the tracker builds it,
one 2 x 6 block per visible corner:

    J_k^0 = P_k^0 [M_k  I]          P = pixel per 3D position (projection)
    J_k^1 = P_k^1 Rx^T [M_k  I]     M_k = -[p_k^0]x, how a small turn moves p_k^0

The position error of a point q on the device (the grip point - what Godot
receives) is then [M_q I] Cov(delta) [M_q I]^T, because omega turns about
cam0's origin, not about the device.

What it varies
  - pixel noise sigma                      (error_vs_depth_sigma.png)
  - camera gap, i.e. baseline              (error_vs_depth_baseline.png)
  - camera gap x angle between the cameras (error_baseline_vergence.png)
  - where the device is on the table       (error_map_position.png)
  - which way the device is turned (yaw)   (error_vs_yaw.png)
Every value is also written to theoretical_error.csv.

Frames
  Rig frame: origin midway between the two lenses; x from cam0 towards cam1,
  y down, z forward - a level camera's axes. cam0 sits at (-B/2, 0, 0), cam1
  at (+B/2, 0, 0), each turned about y by half the vergence angle towards
  the other, so the two optical axes cross in front of the rig. Errors are
  reported in this frame: x = sideways, y = vertical, z = depth.

Assumptions (all exposed as options)
  - Device level on the table: board +Y = device up = rig -y (as in
    main.py's _placement). At yaw 0 the board's +Z - the reference marker's
    face normal - points back at the cameras; --yaw-range turns it.
  - A marker counts as seen by a camera when its face is turned towards
    that camera by less than --max-view-deg, all four corners fall inside
    the (optionally padded) undistorted image, and its shortest edge is at
    least --min-px long, and no part of it is covered by a marker nearer the
    camera (hidden_behind). The device's body between markers and the hand
    are not modelled; --no-occlusion turns the marker-behind-marker test off.
  - Pinhole model with each camera's calibrated fx, fy: this is what the
    default "current" pipeline fits (undistorted pixels). raw_joint fits
    fisheye pixels, which weights corners near the image edge differently.
  - Plain least squares. The tracker's Huber loss (robust_px = 1) behaves
    the same while corner errors stay under 1 px, i.e. for sigma well below
    1 px.
  - Pixel noise only: no motion blur, no camera-to-camera timing offset, no
    calibration error in K, Rx/tx or the board geometry.

Run (numpy + matplotlib only, no OpenCV needed):
    python pyscripts/analysis/theoretical_error.py
    python pyscripts/analysis/theoretical_error.py --sigma-ref 0.19 --sigma-ratio 4.2
"""

import argparse
import csv
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PYSCRIPTS = os.path.dirname(HERE)

IMAGE_SIZE = (1280, 800)   # OV9281, same as Config.FRAME_SIZE

# Used only when camera_calib*.toml is not found: camera_matrix from the
# 2026-09 calibrations of cam0 and cam1.
FALLBACK_K = {
    0: [[593.3306, 0.0, 653.9633], [0.0, 597.6877, 418.7712], [0.0, 0.0, 1.0]],
    1: [[589.6151, 0.0, 647.7000], [0.0, 592.8858, 383.8443], [0.0, 0.0, 1.0]],
}

# Board axes in the rig frame at yaw 0: +X = rig +x, +Y (device up) = rig -y,
# +Z (reference marker's face) = rig -z, i.e. facing the cameras.
BOARD_AT_YAW0 = np.array([[1.0, 0.0, 0.0],
                          [0.0, -1.0, 0.0],
                          [0.0, 0.0, -1.0]])


# -- inputs --------------------------------------------------------------------

def load_K(path: str, cam: int) -> np.ndarray:
    if path and os.path.exists(path):
        try:
            import tomllib                        # Python 3.11+
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except ImportError:
            import toml                           # what main.py uses
            data = toml.load(path)
        section = data.get("calibration", data)
        print(f"cam{cam}: intrinsics from {path}")
        return np.array(section["camera_matrix"], dtype=float).reshape(3, 3)
    print(f"cam{cam}: {path} not found - using the built-in 2026-09 values")
    return np.array(FALLBACK_K[cam], dtype=float)


class Board:
    """board_geometry.json, read the same way as board.BoardGeometry: each
    marker's (R, t) takes marker-frame points into the board frame, corners
    in ArUco order (TL, TR, BR, BL) as in board.marker_object_points."""

    def __init__(self, path: str):
        with open(path) as f:
            data = json.load(f)
        self.length = float(data["marker_length"])
        self.grip = np.array(data["grip_point"], dtype=float).reshape(3)
        h = self.length / 2
        local = np.array([[-h, h, 0.0], [h, h, 0.0], [h, -h, 0.0], [-h, -h, 0.0]])
        self.markers = {}
        for mid, m in data["markers"].items():
            R = np.array(m["rotation"], dtype=float).reshape(3, 3)
            t = np.array(m["translation"], dtype=float).reshape(3)
            self.markers[int(mid)] = {
                "corners": local @ R.T + t,   # 4 x 3, board frame
                "centre": t,
                "normal": R[:, 2],            # marker +Z, out of its face
            }
        print(f"board: {len(self.markers)} markers, {self.length * 1000:.0f} mm, from {path}")


# -- geometry ------------------------------------------------------------------

def rot_y(angle: float) -> np.ndarray:
    c, s = np.cos(angle), np.sin(angle)
    return np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])


def rig_cameras(baseline: float, vergence_deg: float):
    """[(R_c, C_c)] for c = 0, 1: the camera's axes as columns in the rig
    frame, and its lens position. Each is turned half the vergence towards
    the other."""
    half = np.deg2rad(vergence_deg) / 2
    return [(rot_y(+half), np.array([-baseline / 2, 0.0, 0.0])),
            (rot_y(-half), np.array([+baseline / 2, 0.0, 0.0]))]


def device_pose(board: Board, grip_rig: np.ndarray, yaw_deg: float):
    """Board -> rig (R_rb, t_rb) that puts the grip point at grip_rig, device
    turned by yaw_deg about the vertical."""
    R_rb = rot_y(np.deg2rad(yaw_deg)) @ BOARD_AT_YAW0
    return R_rb, grip_rig - R_rb @ board.grip


def turn_matrix(p: np.ndarray) -> np.ndarray:
    """M = -[p]x: a small turn w (rad) about the frame's origin moves p by M @ w.
    Columns = the effect of a turn about x, about y, about z."""
    x, y, z = p
    return np.array([[0.0, z, -y],
                     [-z, 0.0, x],
                     [y, -x, 0.0]])


def projection_jacobian(K: np.ndarray, p: np.ndarray) -> np.ndarray:
    """P = d(u, v) / d(X, Y, Z) for u = cx + fx X/Z, v = cy + fy Y/Z."""
    X, Y, Z = p
    fx, fy = K[0, 0], K[1, 1]
    return np.array([[fx / Z, 0.0, -fx * X / Z ** 2],
                     [0.0, fy / Z, -fy * Y / Z ** 2]])


def corner_jacobian(K: np.ndarray, p0: np.ndarray, cam: int, Rx: np.ndarray, tx: np.ndarray) -> np.ndarray:
    """J_k^c, 2 x 6: how corner k's pixel in camera `cam` moves per unit of
    (omega, t). p0 = the corner in cam0's frame. Same as the tracker's
    residuals_and_jacobian (dudp . A . D)."""
    to_cam = np.eye(3) if cam == 0 else Rx.T          # cam0 frame -> this camera's frame
    pc = p0 if cam == 0 else Rx.T @ (p0 - tx)
    return projection_jacobian(K, pc) @ to_cam @ np.hstack([turn_matrix(p0), np.eye(3)])


def marker_seen(corners_rig, centre_rig, normal_rig, R_c, C_c, K, vis) -> bool:
    to_cam = C_c - centre_rig
    if normal_rig @ to_cam / np.linalg.norm(to_cam) < np.cos(np.deg2rad(vis["max_view_deg"])):
        return False                                  # face turned away
    pc = (corners_rig - C_c) @ R_c                    # rig -> camera frame
    if np.any(pc[:, 2] <= 1e-6):
        return False                                  # behind the lens
    u = K[0, 0] * pc[:, 0] / pc[:, 2] + K[0, 2]
    v = K[1, 1] * pc[:, 1] / pc[:, 2] + K[1, 2]
    (W, H), (px, py) = IMAGE_SIZE, vis["pad"]
    if u.min() < -px or u.max() > W - 1 + px or v.min() < -py or v.max() > H - 1 + py:
        return False                                  # off the image
    uv = np.stack([u, v], axis=1)
    edges = np.linalg.norm(uv - np.roll(uv, -1, axis=0), axis=1)
    return bool(edges.min() >= vis["min_px"])         # big enough to decode


def project_quad(corners_rig, R_c, C_c, K):
    """A marker's four corners in camera pixels, or None if any is behind the lens."""
    pc = (corners_rig - C_c) @ R_c
    if np.any(pc[:, 2] <= 1e-6):
        return None
    return np.stack([K[0, 0] * pc[:, 0] / pc[:, 2] + K[0, 2],
                     K[1, 1] * pc[:, 1] / pc[:, 2] + K[1, 2]], axis=1)


def _inside(point, quad) -> bool:
    """Point strictly inside a convex quadrilateral (either winding)."""
    s = [(quad[(i + 1) % 4][0] - quad[i][0]) * (point[1] - quad[i][1])
         - (quad[(i + 1) % 4][1] - quad[i][1]) * (point[0] - quad[i][0]) for i in range(4)]
    return all(v > 0 for v in s) or all(v < 0 for v in s)


def hidden_behind(projected: dict) -> dict:
    """Markers another marker blocks from this camera: {hidden id: blocking id}.

    projected: {id: (quad in pixels, distance of the marker's centre from the
    camera)}. A marker counts as hidden when any of its corners, or its
    centre, falls inside the image of a marker nearer the camera - the
    detector needs all four corners and the whole black border, so a partly
    covered marker is not read. The device's body between markers is not
    modelled; on the 2026-09-24 grid this rule alone took the misses from
    125 to 2 (visibility_explorer.py)."""
    hidden = {}
    for mid, (quad, dist) in projected.items():
        points = list(quad) + [np.mean(quad, axis=0)]
        for other, (oquad, odist) in projected.items():
            if other != mid and odist < dist and any(_inside(p, oquad) for p in points):
                hidden[mid] = other
                break
    return hidden


# -- the error model -----------------------------------------------------------

def unit_error(board, Ks, baseline, vergence_deg, grip_rig, yaw_deg, sigma_ratio, vis):
    """Grip-point and yaw error for cam0 pixel noise sigma = 1 px (multiply by
    the real sigma). None if the pose is not determined (too few corners)."""
    cams = rig_cameras(baseline, vergence_deg)
    (R0, C0), (R1, C1) = cams
    R_rb, t_rb = device_pose(board, grip_rig, yaw_deg)

    # Everything the fit sees is in cam0's frame.
    R, t = R0.T @ R_rb, R0.T @ (t_rb - C0)            # board -> cam0
    Rx, tx = R0.T @ R1, R0.T @ (C1 - C0)              # cam1 -> cam0

    # Which markers each camera reads: the per-marker tests, then (unless
    # vis["occlusion"] is False) no marker hidden behind a nearer one.
    candidates, projected, corners_0 = [[], []], [{}, {}], {}
    for mid, m in board.markers.items():
        corners_rig = m["corners"] @ R_rb.T + t_rb
        centre_rig = R_rb @ m["centre"] + t_rb
        normal_rig = R_rb @ m["normal"]
        corners_0[mid] = m["corners"] @ R.T + t       # p_k^0
        for c, (R_c, C_c) in enumerate(cams):
            quad = project_quad(corners_rig, R_c, C_c, Ks[c])
            if quad is not None:
                projected[c][mid] = (quad, float(np.linalg.norm(centre_rig - C_c)))
            if marker_seen(corners_rig, centre_rig, normal_rig, R_c, C_c, Ks[c], vis):
                candidates[c].append(mid)

    blocks, weights, seen, seen_any = [], [], [0, 0], set()
    for c in (0, 1):
        hidden = hidden_behind(projected[c]) if vis.get("occlusion", True) else {}
        for mid in candidates[c]:
            if mid in hidden:
                continue
            seen[c] += 1
            seen_any.add(mid)
            for p0 in corners_0[mid]:
                blocks.append(corner_jacobian(Ks[c], p0, c, Rx, tx))
                weights += [1.0 if c == 0 else sigma_ratio ** 2] * 2

    out = {"markers_cam0": seen[0], "markers_cam1": seen[1], "markers_any": len(seen_any)}
    if len(blocks) < 3:                               # < 6 equations for 6 unknowns
        return None, out
    J = np.vstack(blocks)                             # 2N x 6
    JtJ = J.T @ J
    if np.linalg.cond(JtJ) > 1e12:
        return None, out
    JtJ_inv = np.linalg.inv(JtJ)
    cov = JtJ_inv @ (J.T * np.array(weights)) @ J @ JtJ_inv

    q0 = R @ board.grip + t                           # grip point, cam0 frame
    Jq = np.hstack([turn_matrix(q0), np.eye(3)])
    cov_q = R0 @ (Jq @ cov @ Jq.T) @ R0.T             # -> rig frame
    cov_w = R0 @ cov[:3, :3] @ R0.T
    sd_q = np.sqrt(np.diag(cov_q))
    sd_w = np.degrees(np.sqrt(np.diag(cov_w)))
    out.update({
        "err_x_mm": sd_q[0] * 1000, "err_y_mm": sd_q[1] * 1000, "err_z_mm": sd_q[2] * 1000,
        "err_3d_mm": np.sqrt(np.trace(cov_q)) * 1000,
        "err_rot_x_deg": sd_w[0], "err_yaw_deg": sd_w[1], "err_rot_z_deg": sd_w[2],
    })
    return out, out


ERR_KEYS = ("err_x_mm", "err_y_mm", "err_z_mm", "err_3d_mm",
            "err_rot_x_deg", "err_yaw_deg", "err_rot_z_deg")


def at_sigma(unit, info, sigma):
    """Scale a sigma = 1 result: every error is proportional to sigma."""
    row = {"markers_cam0": info["markers_cam0"], "markers_cam1": info["markers_cam1"],
           "markers_any": info["markers_any"], "sigma_px": sigma}
    for k in ERR_KEYS:
        row[k] = unit[k] * sigma if unit is not None else float("nan")
    return row


def span(lo, hi, step):
    return np.round(np.arange(lo, hi + step / 2, step), 6)


# -- charts --------------------------------------------------------------------
# Reference palette of the data-viz method (light surface). Four categorical
# slots in fixed order; slots 3-4 sit below 3:1 contrast, so every line is
# also direct-labelled and marked with its own shape.

SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRIDLINE, AXIS, MISSING = "#e1e0d9", "#c3c2b7", "#f0efec"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
SHAPES = ["o", "s", "^", "D"]
SEQUENTIAL = ["#cde2fb", "#b7d3f6", "#9ec5f4", "#86b6ef", "#6da7ec", "#5598e7",
              "#3987e5", "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"]


def _style(ax, title, xlabel, ylabel):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(AXIS)
    ax.tick_params(colors=AXIS, labelcolor=MUTED, labelsize=8)
    ax.grid(True, color=GRIDLINE, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.set_title(title, color=INK, fontsize=10, loc="left")
    ax.set_xlabel(xlabel, color=INK2, fontsize=9)
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)


def _lines(ax, x, series, labels):
    """Up to four series, each with its own colour and marker shape, and a
    direct label at its last point - pushed apart where lines end close
    together, so the labels never overlap."""
    ends = []
    for i, (y, label) in enumerate(zip(series, labels)):
        y = np.asarray(y, dtype=float)
        ax.plot(x, y, color=SERIES[i], linewidth=2, marker=SHAPES[i], markersize=4,
                markeredgecolor=SURFACE, markeredgewidth=0.8, label=label)
        ok = np.flatnonzero(np.isfinite(y))
        if len(ok):
            ends.append([y[ok[-1]], x[ok[-1]], label])
    ax.set_ylim(bottom=0)
    ax.margins(x=0.12)
    lo, hi = ax.get_ylim()
    gap = 0.07 * (hi - lo)
    ends.sort(key=lambda e: e[0])
    for k in range(1, len(ends)):                     # push each label above the one below
        ends[k][0] = max(ends[k][0], ends[k - 1][0] + gap)
    x_label = max(e[1] for e in ends) if ends else 0
    for y_label, _, label in ends:
        ax.annotate(label, (x_label, y_label), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=7.5, color=INK2, annotation_clip=False)


def _figure(n_panels, width=4.2, height=3.4):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, n_panels, figsize=(width * n_panels, height), squeeze=False)
    fig.patch.set_facecolor(SURFACE)
    return plt, fig, axes[0]


def _legend(fig, axes):
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", ncol=len(labels), frameon=False,
               fontsize=8, labelcolor=INK2)


def _save(plt, fig, path, subtitle):
    fig.text(0.01, 0.01, subtitle, fontsize=7.5, color=MUTED, ha="left", va="bottom")
    fig.tight_layout(rect=(0, 0.05, 1, 0.92))
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    print(f"  wrote {path}")


def _heatmap(ax, grid, xticks, yticks, cbar_label, fig, extent=None, annotate=False, levels=None):
    """levels=None: continuous values. levels=n: whole numbers 0 .. n-1 (counts),
    one colour step each."""
    from matplotlib.colors import BoundaryNorm, LinearSegmentedColormap, ListedColormap
    if levels is None:
        cmap, norm = LinearSegmentedColormap.from_list("seq", SEQUENTIAL), None
    else:
        steps = [SEQUENTIAL[round(i * (len(SEQUENTIAL) - 1) / max(levels - 1, 1))] for i in range(levels)]
        cmap, norm = ListedColormap(steps), BoundaryNorm(np.arange(-0.5, levels), levels)
    cmap.set_bad(MISSING)
    data = np.ma.masked_invalid(grid)
    if extent is None:
        im = ax.imshow(data, cmap=cmap, norm=norm, origin="lower", aspect="auto")
        ax.set_xticks(range(len(xticks)), xticks)
        ax.set_yticks(range(len(yticks)), yticks)
        ax.grid(False)
    else:
        im = ax.imshow(data, cmap=cmap, norm=norm, origin="lower", aspect="auto", extent=extent,
                       interpolation="nearest")
        ax.grid(False)
    if annotate:
        vmax = np.nanmax(grid) if np.isfinite(grid).any() else 1.0
        for (i, j), v in np.ndenumerate(grid):
            text = "not\nseen" if not np.isfinite(v) else f"{v:.2f}"
            dark = np.isfinite(v) and v / vmax > 0.55
            ax.text(j, i, text, ha="center", va="center", fontsize=7.5,
                    color=SURFACE if dark else INK)
    cb = fig.colorbar(im, ax=ax, fraction=0.05, pad=0.03)
    if levels is not None:
        cb.set_ticks(range(levels))
    cb.set_label(cbar_label, color=INK2, fontsize=8)
    cb.ax.tick_params(labelsize=7, labelcolor=MUTED, colors=AXIS)
    cb.outline.set_visible(False)


# -- main ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--board", default=os.path.join(PYSCRIPTS, "board_geometry.json"))
    ap.add_argument("--calib0", default=os.path.join(PYSCRIPTS, "camera_calib.toml"))
    ap.add_argument("--calib1", default=os.path.join(PYSCRIPTS, "camera_calib_1.toml"))
    ap.add_argument("--out", default=os.path.join(HERE, "theoretical_error_out"))
    ap.add_argument("--sigmas", type=float, nargs="+", default=[0.1, 0.2, 0.5, 1.0],
                    help="pixel noise values compared in the sigma chart, px (at most 4)")
    ap.add_argument("--sigma-ref", type=float, default=0.2,
                    help="pixel noise used by every other chart, px")
    ap.add_argument("--sigma-ratio", type=float, default=1.0,
                    help="cam1's pixel noise / cam0's (0.79 / 0.19 = 4.2 with the 2026-09 calibrations)")
    ap.add_argument("--baseline", type=float, default=0.075, help="your rig's camera gap, m")
    ap.add_argument("--vergence", type=float, default=0.0,
                    help="your rig's angle between the two optical axes, deg")
    ap.add_argument("--baselines", type=float, nargs="+", default=[0.075, 0.15, 0.3, 0.5],
                    help="camera gaps to compare, m (at most 4 in the line chart)")
    ap.add_argument("--vergences", type=float, nargs="+", default=[0, 10, 20, 30, 45],
                    help="angles between the optical axes to compare, deg")
    ap.add_argument("--depth-range", type=float, nargs=3, default=[0.3, 1.2, 0.05],
                    metavar=("MIN", "MAX", "STEP"), help="device distance from the rig, m")
    ap.add_argument("--depth-ref", type=float, default=0.6,
                    help="device distance used by the heatmap and yaw charts, m")
    ap.add_argument("--lateral-range", type=float, nargs=3, default=[-0.4, 0.4, 0.02],
                    metavar=("MIN", "MAX", "STEP"), help="device sideways position, m")
    ap.add_argument("--yaw-range", type=float, nargs=3, default=[-90, 90, 5],
                    metavar=("MIN", "MAX", "STEP"), help="device turn about the vertical, deg")
    ap.add_argument("--height", type=float, default=0.0,
                    help="grip point below lens height, m (+ = lower than the lenses)")
    ap.add_argument("--max-view-deg", type=float, default=70.0,
                    help="a marker turned further than this from a camera is not read")
    ap.add_argument("--min-px", type=float, default=20.0,
                    help="a marker whose shortest edge is under this many px is not read")
    ap.add_argument("--no-occlusion", action="store_true",
                    help="count markers hidden behind nearer markers as readable (the model before 2026-09-25)")
    ap.add_argument("--pad", type=int, nargs=2, default=[0, 0], metavar=("X", "Y"),
                    help="undistort_pad_x_px / undistort_pad_y_px from settings.json")
    args = ap.parse_args()

    if not os.path.exists(args.board):
        raise SystemExit(f"No board geometry at {args.board} - copy board_geometry.json from "
                         f"the board, or pass --board.")
    board = Board(args.board)
    Ks = [load_K(args.calib0, 0), load_K(args.calib1, 1)]
    vis = {"max_view_deg": args.max_view_deg, "min_px": args.min_px, "pad": tuple(args.pad),
           "occlusion": not args.no_occlusion}
    os.makedirs(args.out, exist_ok=True)

    depths = span(*args.depth_range)
    laterals = span(*args.lateral_range)
    yaws = span(*args.yaw_range)
    rows = []

    def run(study, baseline, vergence, x, z, yaw, sigmas):
        unit, info = unit_error(board, Ks, baseline, vergence,
                                np.array([x, args.height, z]), yaw, args.sigma_ratio, vis)
        out = []
        for s in sigmas:
            row = {"study": study, "baseline_m": baseline, "vergence_deg": vergence,
                   "x_m": x, "z_m": z, "yaw_deg": yaw, **at_sigma(unit, info, s)}
            rows.append(row)
            out.append(row)
        return out

    B, V, s_ref = args.baseline, args.vergence, args.sigma_ref
    rig = f"gap {B * 1000:.0f} mm, cameras {V:g} deg apart"
    note = (f"Pixel noise only (no blur, timing or calibration error). cam1 noise = "
            f"{args.sigma_ratio:g} x cam0. Markers read when turned < {args.max_view_deg:g} deg "
            f"from the camera and >= {args.min_px:g} px wide.")
    print("Charts:")

    # 1. Pixel noise: device straight ahead of the rig, moving away.
    sigmas = args.sigmas[:4]
    res = [run("depth_sigma", B, V, 0.0, z, 0.0, sigmas) for z in depths]
    plt, fig, axes = _figure(3)
    for ax, key, title, unit in zip(axes, ("err_x_mm", "err_z_mm", "err_yaw_deg"),
                                    ("Sideways error", "Depth error", "Yaw error"),
                                    ("mm", "mm", "deg")):
        _lines(ax, depths, [[r[i][key] for r in res] for i in range(len(sigmas))],
               [f"σ = {s:g} px" for s in sigmas])
        _style(ax, title, "device distance from the cameras (m)", f"error, 1 SD ({unit})")
    _legend(fig, axes)
    fig.suptitle(f"Error vs distance for different pixel noise  ·  {rig}",
                 x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "error_vs_depth_sigma.png"), note)

    # 2. Camera gap: same line of travel, sigma_ref.
    gaps = args.baselines[:4]
    res = [[run("depth_baseline", b, V, 0.0, z, 0.0, [s_ref])[0] for z in depths] for b in gaps]
    plt, fig, axes = _figure(3)
    for ax, key, title, unit in zip(axes, ("err_x_mm", "err_z_mm", "err_yaw_deg"),
                                    ("Sideways error", "Depth error", "Yaw error"),
                                    ("mm", "mm", "deg")):
        _lines(ax, depths, [[r[key] for r in rb] for rb in res],
               [f"{b * 1000:.0f} mm gap" for b in gaps])
        _style(ax, title, "device distance from the cameras (m)", f"error, 1 SD ({unit})")
    _legend(fig, axes)
    fig.suptitle(f"Error vs distance for different camera gaps  ·  σ = {s_ref:g} px, "
                 f"cameras {V:g} deg apart", x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "error_vs_depth_baseline.png"), note)

    # 3. Camera gap x angle between the cameras, device at depth_ref.
    grid_z = np.full((len(args.baselines), len(args.vergences)), np.nan)
    grid_3d = grid_z.copy()
    for i, b in enumerate(args.baselines):
        for j, v in enumerate(args.vergences):
            r = run("baseline_vergence", b, v, 0.0, args.depth_ref, 0.0, [s_ref])[0]
            grid_z[i, j], grid_3d[i, j] = r["err_z_mm"], r["err_3d_mm"]
    plt, fig, axes = _figure(2, width=5.0, height=3.8)
    xt = [f"{v:g}°" for v in args.vergences]
    yt = [f"{b * 1000:.0f}" for b in args.baselines]
    for ax, grid, title in zip(axes, (grid_z, grid_3d), ("Depth error", "Total position error")):
        _heatmap(ax, grid, xt, yt, "error, 1 SD (mm)", fig, annotate=True)
        _style(ax, title, "angle between the cameras' axes", "camera gap (mm)")
        ax.grid(False)
    fig.suptitle(f"Camera gap and angle  ·  device {args.depth_ref:g} m away, σ = {s_ref:g} px",
                 x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "error_baseline_vergence.png"), note)

    # 4. Where the device is on the table, your rig, sigma_ref.
    map_z = np.full((len(depths), len(laterals)), np.nan)
    map_x = map_z.copy()
    counts = {k: map_z.copy() for k in ("markers_cam0", "markers_cam1", "markers_any")}
    for i, z in enumerate(depths):
        for j, x in enumerate(laterals):
            r = run("position_map", B, V, x, z, 0.0, [s_ref])[0]
            map_z[i, j], map_x[i, j] = r["err_z_mm"], r["err_x_mm"]
            for k in counts:
                counts[k][i, j] = r[k]
    hx, hz = args.lateral_range[2] / 2, args.depth_range[2] / 2
    extent = (laterals[0] - hx, laterals[-1] + hx, depths[0] - hz, depths[-1] + hz)
    plt, fig, axes = _figure(2, width=5.0, height=4.4)
    for ax, grid, title in zip(axes, (map_z, map_x), ("Depth error", "Sideways error")):
        _heatmap(ax, grid, None, None, "error, 1 SD (mm)", fig, extent=extent)
        _style(ax, title, "sideways (m), 0 = straight in front of the rig",
               "distance from the cameras (m)")
        ax.grid(False)
    fig.suptitle(f"Error over the table  ·  {rig}, σ = {s_ref:g} px  (grey = no marker read)",
                 x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "error_map_position.png"), note)

    # 4b. How many markers are read at each spot - the reason the error map
    # looks the way it does.
    plt, fig, axes = _figure(3, width=4.6, height=4.4)
    n_levels = len(board.markers) + 1
    for ax, key, title in zip(axes, ("markers_cam0", "markers_cam1", "markers_any"),
                              ("Read by cam0", "Read by cam1", "Read by either camera")):
        _heatmap(ax, counts[key], None, None, "markers", fig, extent=extent, levels=n_levels)
        _style(ax, title, "sideways (m), 0 = straight in front of the rig",
               "distance from the cameras (m)")
        ax.grid(False)
    fig.suptitle(f"Markers read over the table  ·  {rig}, device facing the rig (yaw 0)",
                 x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "markers_map_position.png"), note)

    # 5. Which way the device is turned, your rig, device at depth_ref.
    res = [run("yaw", B, V, 0.0, args.depth_ref, y, [s_ref])[0] for y in yaws]
    plt, fig, axes = _figure(4, width=3.6)
    for ax, key, title, unit in zip(axes[:3], ("err_x_mm", "err_z_mm", "err_yaw_deg"),
                                    ("Sideways error", "Depth error", "Yaw error"),
                                    ("mm", "mm", "deg")):
        ax.plot(yaws, [r[key] for r in res], color=SERIES[0], linewidth=2, marker="o",
                markersize=3.5, markeredgecolor=SURFACE, markeredgewidth=0.8)
        ax.set_ylim(bottom=0)
        _style(ax, title, "device yaw (deg)", f"error, 1 SD ({unit})")
    _lines(axes[3], yaws, [[r["markers_cam0"] for r in res], [r["markers_cam1"] for r in res]],
           ["cam0", "cam1"])
    _style(axes[3], "Markers read", "device yaw (deg)", "markers")
    fig.suptitle(f"Error vs which way the device faces  ·  {args.depth_ref:g} m away, {rig}, "
                 f"σ = {s_ref:g} px", x=0.01, ha="left", color=INK, fontsize=11)
    _save(plt, fig, os.path.join(args.out, "error_vs_yaw.png"), note)

    csv_path = os.path.join(args.out, "theoretical_error.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"  wrote {csv_path}  ({len(rows)} rows)")

    # Headline numbers for your rig, straight ahead.
    print(f"\nYour rig ({rig}), device straight ahead, sigma = {s_ref:g} px:")
    print(f"  {'distance':>8}  {'sideways':>9}  {'vertical':>9}  {'depth':>9}  {'yaw':>8}  markers")
    for z in (0.3, 0.5, 0.75, 1.0):
        if depths[0] - 1e-9 <= z <= depths[-1] + 1e-9:
            r = run("summary", B, V, 0.0, z, 0.0, [s_ref])[0]
            print(f"  {z:>6.2f} m  {r['err_x_mm']:>6.3f} mm  {r['err_y_mm']:>6.3f} mm  "
                  f"{r['err_z_mm']:>6.3f} mm  {r['err_yaw_deg']:>5.3f} deg  "
                  f"{r['markers_cam0']} + {r['markers_cam1']}")


if __name__ == "__main__":
    main()
