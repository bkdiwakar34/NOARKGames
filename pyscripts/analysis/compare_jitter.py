#!/usr/bin/env python3
"""
compare_jitter.py - measured vs predicted jitter of the tracked pose, for
every still hold of a validation recording.

Measured: while the device stands still, the tracker's pose still shakes
from frame to frame. The standard deviation of the grip point's position,
and of the device's rotation, over the frames of a hold is that jitter.

Predicted: the same number from the error model of theoretical_error.py,

    Cov(delta) = (J^T J)^-1 J^T S J (J^T J)^-1,    S = diag(sigma_cam^2)

with nothing assumed: J is built at the hold's own pose, from the markers
each camera actually read in that hold, with the recording's own camera
matrices, stereo extrinsics and board geometry (meta.json and calib/), and
sigma_cam is the corner noise measured in that same hold (measure_sigma.py).
The tracker's joint fit weights every corner equally, hence the sandwich
form when the two cameras' sigma differ.

Measured / predicted near 1: corner noise explains the tracker's jitter.
Well above 1: something else shakes the pose too - markers flickering in
and out, the fit jumping between solutions, the two cameras' frames taken
at slightly different moments. The constant offset from calibration error
does not shake, so it is in neither number; OptiTrack measures that.

Holds whose corner noise is several times the median hold's were not still
(measure_sigma.py's rule) and are left out of the summary.

Runs where the recordings are. Needs theoretical_error.py and
measure_sigma.py in the same folder; numpy; matplotlib only for the chart.

    python3 compare_jitter.py ~/Documents/NOARK/validation
"""

import argparse
import csv
import json
import math
import os
import sys
from collections import defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from theoretical_error import (Board, corner_jacobian, load_K, turn_matrix,  # noqa: E402
                               _style, SURFACE, SERIES, INK, MUTED, AXIS)
from measure_sigma import analyse_hold, find_holds, find_recordings, read_csv  # noqa: E402

MIN_POSE_FRAMES = 100    # a hold with fewer tracked frames is skipped
SEEN_SHARE = 0.5         # a marker counts as read in a hold when it is in at least half its frames


def quat_to_R(x, y, z, w):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def R_to_quat(R):
    """(x, y, z, w) of a rotation matrix."""
    w = math.sqrt(max(0.0, 1 + R[0, 0] + R[1, 1] + R[2, 2])) / 2
    x = math.copysign(math.sqrt(max(0.0, 1 + R[0, 0] - R[1, 1] - R[2, 2])) / 2, R[2, 1] - R[1, 2])
    y = math.copysign(math.sqrt(max(0.0, 1 - R[0, 0] + R[1, 1] - R[2, 2])) / 2, R[0, 2] - R[2, 0])
    z = math.copysign(math.sqrt(max(0.0, 1 - R[0, 0] - R[1, 1] + R[2, 2])) / 2, R[1, 0] - R[0, 1])
    return x, y, z, w


def small_turn(dR):
    """Rotation vector (rad) of a rotation matrix close to the identity."""
    return 0.5 * np.array([dR[2, 1] - dR[1, 2], dR[0, 2] - dR[2, 0], dR[1, 0] - dR[0, 1]])


def load_rig(folder, board_fallback):
    """Camera matrices, cam1 -> cam0 extrinsics and board geometry as they
    were when this recording was made. None if the extrinsics are missing."""
    calib = os.path.join(folder, "calib")
    meta = {}
    if os.path.exists(os.path.join(folder, "meta.json")):
        with open(os.path.join(folder, "meta.json")) as f:
            meta = json.load(f)
    undistorted = meta.get("undistorted") or {}
    Ks = []
    for cam, name in ((0, "camera_calib.toml"), (1, "camera_calib_1.toml")):
        K = undistorted.get(f"camera_matrix_cam{cam}")
        Ks.append(np.array(K, dtype=float).reshape(3, 3) if K is not None
                  else load_K(os.path.join(calib, name), cam))
    ex_path = os.path.join(calib, "stereo_extrinsics.json")
    if not os.path.exists(ex_path):
        return None
    with open(ex_path) as f:
        ex = json.load(f)
    Rx = np.array(ex["Rx"], dtype=float).reshape(3, 3)
    tx = np.array(ex["tx"], dtype=float).reshape(3)
    board_path = os.path.join(calib, "board_geometry.json")
    board = Board(board_path if os.path.exists(board_path) else board_fallback)
    return Ks, Rx, tx, board, meta


def hold_jitter(board, Ks, Rx, tx, pose_rows, corner_rows, sigma):
    """Measured and predicted jitter of one hold, or None."""
    rows = [s for s in pose_rows if s.get("tx_m") and s.get("qw")]
    if len(rows) < MIN_POSE_FRAMES:
        return None
    Rs = [quat_to_R(*(float(s[k]) for k in ("qx", "qy", "qz", "qw"))) for s in rows]
    ts = np.array([[float(s[k]) for k in ("tx_m", "ty_m", "tz_m")] for s in rows])
    R_ref, t_ref = Rs[len(Rs) // 2], np.median(ts, axis=0)

    # Measured: spread of the grip point (cam0 frame) and of the rotation.
    grip = np.array([R @ board.grip + t for R, t in zip(Rs, ts)])
    # Also along the rig's own axes, to place the hold on compare_rigs.py's maps:
    # sideways = along the line from cam0 to cam1, from its midpoint.
    side_dir = tx / np.linalg.norm(tx)
    side = (grip - tx / 2) @ side_dir
    turns = np.array([small_turn(R @ R_ref.T) for R in Rs])
    meas_axis = grip.std(axis=0, ddof=1)
    meas_pos = float(np.sqrt((meas_axis ** 2).sum()))
    meas_rot = float(np.degrees(np.sqrt(turns.var(axis=0, ddof=1).sum())))

    # The markers each camera read in most of the hold's frames.
    frames = defaultdict(set)
    for r in corner_rows:
        frames[(int(r["cam"]), int(r["marker_id"]))].add(int(r["sample"]))
    seen = {cam: sorted(m for (c, m), s in frames.items()
                        if c == cam and m in board.markers and len(s) >= SEEN_SHARE * len(rows))
            for cam in (0, 1)}
    # Read in some frames of the hold but not most: blinking in and out.
    flicker = {cam: sorted(m for (c, m), s in frames.items()
                           if c == cam and m in board.markers and 0 < len(s) < SEEN_SHARE * len(rows))
               for cam in (0, 1)}
    # Detection rate: share of the hold's frames in which each camera read each
    # marker (markers never read are left out, i.e. 0). visibility_explorer.py
    # scores the model frame by frame from these.
    n_frames = len(pose_rows)
    rates = {cam: " ".join(f"{m}:{len(s) / n_frames:.3f}" for (c, m), s in sorted(frames.items())
                           if c == cam and m in board.markers)
             for cam in (0, 1)}

    # Predicted: the error model at this pose.
    blocks, weights = [], []
    for cam in (0, 1):
        if not seen[cam] or not np.isfinite(sigma[cam]):
            continue
        for mid in seen[cam]:
            for b in board.markers[mid]["corners"]:
                blocks.append(corner_jacobian(Ks[cam], R_ref @ b + t_ref, cam, Rx, tx))
                weights += [sigma[cam] ** 2] * 2
    if len(blocks) < 3:
        return None
    J = np.vstack(blocks)
    JtJ_inv = np.linalg.inv(J.T @ J)
    cov = JtJ_inv @ (J.T * np.array(weights)) @ J @ JtJ_inv
    q0 = R_ref @ board.grip + t_ref
    Jq = np.hstack([turn_matrix(q0), np.eye(3)])
    cov_q = Jq @ cov @ Jq.T
    pred_axis = np.sqrt(np.diag(cov_q))
    return {
        "frames": len(rows), "distance_m": float(t_ref[2]),
        "side_m": float(np.median(side)), "depth_m": float(np.median(grip[:, 2])),
        "meas_side_mm": float(side.std(ddof=1)) * 1000,
        "pred_side_mm": float(np.sqrt(side_dir @ cov_q @ side_dir)) * 1000,
        "markers_cam0": len(seen[0]), "markers_cam1": len(seen[1]),
        "meas_x_mm": meas_axis[0] * 1000, "meas_y_mm": meas_axis[1] * 1000,
        "meas_z_mm": meas_axis[2] * 1000, "meas_pos_mm": meas_pos * 1000,
        "pred_x_mm": pred_axis[0] * 1000, "pred_y_mm": pred_axis[1] * 1000,
        "pred_z_mm": pred_axis[2] * 1000,
        "pred_pos_mm": float(np.sqrt(np.trace(cov_q))) * 1000,
        "meas_rot_deg": meas_rot,
        "pred_rot_deg": float(np.degrees(np.sqrt(np.trace(cov[:3, :3])))),
        # Which markers each camera read, and the hold's pose (board -> cam0),
        # for the marker-visibility check (visibility_explorer.html).
        "ids_cam0": " ".join(map(str, seen[0])), "ids_cam1": " ".join(map(str, seen[1])),
        "flicker_cam0": " ".join(map(str, flicker[0])), "flicker_cam1": " ".join(map(str, flicker[1])),
        "rates_cam0": rates[0], "rates_cam1": rates[1], "hold_frames": n_frames,
        **dict(zip(("ref_qx", "ref_qy", "ref_qz", "ref_qw"), R_to_quat(R_ref))),
        **dict(zip(("ref_tx_m", "ref_ty_m", "ref_tz_m"), map(float, t_ref))),
    }


def chart(kept, path):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed - no chart")
        return
    fig, axes = plt.subplots(1, 2, figsize=(9.5, 4.4))
    fig.patch.set_facecolor(SURFACE)
    for ax, (m, p, unit, title) in zip(axes, (
            ("meas_pos_mm", "pred_pos_mm", "mm", "Grip point position"),
            ("meas_rot_deg", "pred_rot_deg", "deg", "Rotation"))):
        x = np.array([r[p] for r in kept])
        y = np.array([r[m] for r in kept])
        top = 1.1 * max(x.max(), y.max())
        ax.plot([0, top], [0, top], color=AXIS, linewidth=1.2, linestyle="--")
        ax.annotate("measured = predicted", (top * 0.97, top * 0.97), ha="right", va="bottom",
                    fontsize=7.5, color=MUTED)
        ax.scatter(x, y, s=22, color=SERIES[0], edgecolor=SURFACE, linewidth=0.6, zorder=3)
        ax.set_xlim(0, top)
        ax.set_ylim(0, top)
        ax.set_aspect("equal")
        _style(ax, title, f"predicted jitter, 1 SD ({unit})", f"measured jitter, 1 SD ({unit})")
    fig.suptitle(f"Measured vs predicted jitter  ·  {len(kept)} still holds",
                 x=0.01, ha="left", color=INK, fontsize=11)
    fig.text(0.01, 0.01, "Each dot is one hold. Prediction uses that hold's pose, markers read "
             "and measured corner noise.", fontsize=7.5, color=MUTED)
    fig.tight_layout(rect=(0, 0.04, 1, 0.94))
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    print(f"Chart: {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="recording folder(s), or a folder of recordings")
    ap.add_argument("--board", default=os.path.join(os.path.dirname(HERE), "board_geometry.json"),
                    help="used only if a recording has no calib/board_geometry.json")
    ap.add_argument("--whole", action="store_true", help="ignore marks: each recording is one hold")
    ap.add_argument("--trim", type=int, default=0, help="frames dropped at each end of a hold")
    ap.add_argument("--min-frames", type=int, default=30)
    ap.add_argument("--moved-factor", type=float, default=3.0)
    ap.add_argument("--out", default=os.path.join(HERE, "jitter_out"))
    args = ap.parse_args()

    results = []
    for folder in find_recordings(args.paths):
        name = os.path.basename(os.path.normpath(folder))
        rig = load_rig(folder, args.board)
        if rig is None:
            print(f"{name}: no calib/stereo_extrinsics.json - skipped")
            continue
        Ks, Rx, tx, board, meta = rig
        settings = meta.get("settings", {})
        print(f"{name}: pipeline {meta.get('pipeline', '?')}, "
              f"dual_solve {settings.get('dual_solve', 'joint (default)')}, "
              f"robust_loss_px {settings.get('robust_loss_px', '1.0 (default)')}")
        samples = read_csv(os.path.join(folder, "samples.csv"))
        by_sample = defaultdict(list)
        for r in read_csv(os.path.join(folder, "corners.csv")):
            by_sample[int(r["sample"])].append(r)
        last = max((int(s["sample"]) for s in samples), default=-1)
        for label, lo, hi in find_holds(read_csv(os.path.join(folder, "marks.csv")), last, args.whole):
            lo, hi = lo + args.trim, hi - args.trim
            pose_rows = [s for s in samples if lo <= int(s["sample"]) <= hi]
            corner_rows = [r for s in range(lo, hi + 1) for r in by_sample.get(s, [])]
            _, cams, _ = analyse_hold(corner_rows, pose_rows, lo, hi, args.min_frames)
            sigma = {cam: cams[cam]["sigma_px"] for cam in (0, 1)}
            res = hold_jitter(board, Ks, Rx, tx, pose_rows, corner_rows, sigma)
            if res is not None:
                results.append({"recording": name, "hold": label,
                                "sigma_cam0_px": sigma[0], "sigma_cam1_px": sigma[1], **res})

    if not results:
        raise SystemExit("No hold with enough tracked frames.")

    med = {c: float(np.nanmedian([r[f"sigma_cam{c}_px"] for r in results])) for c in (0, 1)}
    for r in results:
        r["moved"] = any(r[f"sigma_cam{c}_px"] > args.moved_factor * med[c] for c in (0, 1))

    print(f"\n  {'hold':<26} {'dist':>6} {'markers':>7}   {'position jitter (mm)':^26}   "
          f"{'rotation jitter (deg)':^26}")
    print(f"  {'':<26} {'':>6} {'':>7}   {'measured':>8} {'predicted':>9} {'ratio':>6}   "
          f"{'measured':>8} {'predicted':>9} {'ratio':>6}")
    for r in results:
        flag = "  <- not still, left out" if r["moved"] else ""
        print(f"  {r['hold'][:26]:<26} {r['distance_m']:>5.2f}m {r['markers_cam0']:>3}+{r['markers_cam1']:<3}  "
              f"{r['meas_pos_mm']:>8.3f} {r['pred_pos_mm']:>9.3f} {r['meas_pos_mm'] / r['pred_pos_mm']:>6.2f}   "
              f"{r['meas_rot_deg']:>8.4f} {r['pred_rot_deg']:>9.4f} "
              f"{r['meas_rot_deg'] / r['pred_rot_deg']:>6.2f}{flag}")

    kept = [r for r in results if not r["moved"]]
    ratio_pos = [r["meas_pos_mm"] / r["pred_pos_mm"] for r in kept]
    ratio_rot = [r["meas_rot_deg"] / r["pred_rot_deg"] for r in kept]
    ratio_z = [r["meas_z_mm"] / r["pred_z_mm"] for r in kept]
    print(f"\n{len(kept)} still holds ({len(results) - len(kept)} left out). Measured / predicted, "
          f"median [middle half]:")
    for label, v in (("position", ratio_pos), ("  depth only", ratio_z), ("rotation", ratio_rot)):
        q1, q2, q3 = np.percentile(v, [25, 50, 75])
        print(f"  {label:<12} {q2:.2f}   [{q1:.2f} - {q3:.2f}]")

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "jitter_by_hold.csv"), "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0]))
        writer.writeheader()
        writer.writerows(results)
    print(f"Per hold: {os.path.join(args.out, 'jitter_by_hold.csv')}")
    chart(kept, os.path.join(args.out, "jitter_measured_vs_predicted.png"))


if __name__ == "__main__":
    main()
