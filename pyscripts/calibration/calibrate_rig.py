"""
Tag layout + camera-to-camera calibration, fitted TOGETHER from both cameras.

Why: board_geometry.json (where each tag sits on the device) was measured
with one camera, tag pair by tag pair, and stereo_extrinsics.json (where cam1
sits relative to cam0) was then built on top of it. Nothing ever made the two
agree with what BOTH cameras see at once, so the cameras computed slightly
different device poses (2 mm typical, far more with 1-2 tags in view) and every
way of combining them jumped or rejected frames (2026-09-22).

How: record the device moving in front of both cameras, then one bundle
adjustment over every corner of every frame of both cameras:

    unknowns   pose of each tag on the device (tag 12 = reference, fixed)
               cam1 relative to cam0
               the device's pose in every frame
    minimise   sum over frames, cameras, tags, corners of (seen - predicted)^2
               (Huber loss, 1 px, so an odd bad detection cannot drag it)

The lens calibrations (camera_calib*.toml) are kept as they are; the corners
are the tracker's own, straightened with them (border 0).

Honesty check: the fit uses every other frame; the frames it did NOT see are
then solved with the old and with the new calibration (only the device pose
free), and both errors are printed. The new files are only worth keeping if
the held-out error drops.

Run (the game closed — both want the cameras), from the repo root:
    python pyscripts/calibration/calibrate_rig.py              # 60 s of recording
    python pyscripts/calibration/calibrate_rig.py --seconds 90

While it records: move the device slowly over the WHOLE table, turning it
left and right (about +-45 deg) and tilting it a little, so every tag is seen
by both cameras from several angles. Keep your hand off the tags.

Writes pyscripts/board_geometry.json and pyscripts/stereo_extrinsics.json only
if you answer "y"; the old ones are kept as *.before-<date-time>.
After a change: re-lock the origin and redo the 4-corner table calibration.
"""

import argparse
import json
import os
import shutil
import sys
import time
from datetime import datetime

import cv2
import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix
from scipy.spatial.transform import Rotation

_PYSCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _PYSCRIPTS_DIR)

from board import BoardGeometry, estimate_board_pose, marker_object_points
from main import MainClass, _load_settings, calib_path

MAX_FRAMES = 500          # frames kept for the fit, spread over the recording
HUBER_PX = 1.0


# ── recording ────────────────────────────────────────────────────────────────

def record(tracker, seconds: float) -> list:
    """[(corners0, ids0, corners1, ids1)] for every frame where the two
    cameras together saw at least 3 tags and each saw at least one."""
    frames, seen_both = [], {}
    start = time.monotonic()
    last = 0.0
    while True:
        now = time.monotonic() - start
        if now >= seconds:
            break
        r = tracker.process_frame()
        if r is None:
            continue
        (c0, c1), (i0, i1) = r.corners, r.ids
        if i0 is None or i1 is None or len(i0) + len(i1) < 3:
            continue
        frames.append((c0, i0, c1, i1))
        for mid in set(np.asarray(i0).flatten()) & set(np.asarray(i1).flatten()):
            seen_both[int(mid)] = seen_both.get(int(mid), 0) + 1
        if now - last > 0.5:
            last = now
            tags = "  ".join(f"{k}:{v}" for k, v in sorted(seen_both.items()))
            sys.stdout.write(f"\r{seconds - now:5.1f} s left   frames {len(frames):5d}   "
                             f"tags seen by both cameras: {tags}      ")
            sys.stdout.flush()
    print()
    return frames


# ── the fit ──────────────────────────────────────────────────────────────────

class Problem:
    """Observations + parameter layout: [tags (all but reference) x 6]
    [stereo 6] [frames x 6]. A pose is (rotation vector, translation)."""

    def __init__(self, board: BoardGeometry, frames, K0, K1, Rx, tx):
        self.ref = board.reference_id
        self.tags = [m for m in sorted(board.marker_poses) if m != self.ref]
        self.tag_index = {m: i for i, m in enumerate(sorted(board.marker_poses))}
        self.all_tags = sorted(board.marker_poses)
        self.local = marker_object_points(board.marker_length).astype(np.float64)   # (4, 3)
        self.K = (np.asarray(K0, np.float64), np.asarray(K1, np.float64))
        obs_f, obs_c, obs_m, obs_uv = [], [], [], []
        init_frames = []
        for c0, i0, c1, i1 in frames:
            pose = initial_frame_pose(board, c0, i0, c1, i1, self.K, Rx, tx)
            if pose is None:
                continue
            f = len(init_frames)
            init_frames.append(pose)
            for cam, (cs, ids) in enumerate(((c0, i0), (c1, i1))):
                for cor, mid in zip(cs, np.asarray(ids).flatten()):
                    if int(mid) in self.tag_index:
                        obs_f.append(f)
                        obs_c.append(cam)
                        obs_m.append(self.tag_index[int(mid)])
                        obs_uv.append(np.asarray(cor, np.float64).reshape(4, 2))
        self.f = np.array(obs_f)
        self.c = np.array(obs_c)
        self.m = np.array(obs_m)
        self.uv = np.array(obs_uv)                 # (O, 4, 2)
        self.n_frames = len(init_frames)
        self.x0 = np.concatenate(
            [np.concatenate([cv2.Rodrigues(board.marker_poses[m][0])[0].flatten(),
                             board.marker_poses[m][1]]) for m in self.tags]
            + [np.concatenate([cv2.Rodrigues(np.asarray(Rx, np.float64))[0].flatten(),
                               np.asarray(tx, np.float64).flatten()])]
            + [np.concatenate(p) for p in init_frames])
        self.n_tag_params = 6 * len(self.tags)

    def unpack(self, x):
        tags = x[:self.n_tag_params].reshape(-1, 6)
        stereo = x[self.n_tag_params:self.n_tag_params + 6]
        frames = x[self.n_tag_params + 6:].reshape(-1, 6)
        return tags, stereo, frames

    def tag_points(self, tags):
        """(n tags, 4, 3) corner positions in the board frame."""
        pts = np.zeros((len(self.all_tags), 4, 3))
        k = 0
        for i, mid in enumerate(self.all_tags):
            if mid == self.ref:
                pts[i] = self.local                  # reference tag = board frame
            else:
                R = cv2.Rodrigues(tags[k, :3].reshape(3, 1))[0]
                pts[i] = self.local @ R.T + tags[k, 3:]
                k += 1
        return pts

    def residuals(self, x):
        tags, stereo, frames = self.unpack(x)
        P = self.tag_points(tags)[self.m]                                # (O, 4, 3)
        Rf = Rotation.from_rotvec(frames[:, :3]).as_matrix()[self.f]     # (O, 3, 3)
        p = np.einsum("oij,okj->oki", Rf, P) + frames[self.f, 3:][:, None, :]
        Rx = cv2.Rodrigues(stereo[:3].reshape(3, 1))[0]
        cam1 = self.c == 1
        p[cam1] = (p[cam1] - stereo[3:]) @ Rx                           # Rx^T (p0 - tx)
        out = np.empty_like(self.uv)
        for cam in (0, 1):
            sel = self.c == cam
            K = self.K[cam]
            z = np.maximum(p[sel, :, 2], 1e-6)
            out[sel, :, 0] = K[0, 0] * p[sel, :, 0] / z + K[0, 2]
            out[sel, :, 1] = K[1, 1] * p[sel, :, 1] / z + K[1, 2]
        return (self.uv - out).ravel()

    def sparsity(self, free_calibration: bool):
        """Which parameters each residual depends on (8 residuals per tag view)."""
        n = len(self.x0) if free_calibration else 6 * self.n_frames
        off = 0 if not free_calibration else self.n_tag_params + 6
        S = lil_matrix((8 * len(self.f), n), dtype=int)
        for o in range(len(self.f)):
            rows = slice(8 * o, 8 * o + 8)
            fc = off + 6 * self.f[o]
            S[rows, fc:fc + 6] = 1
            if free_calibration:
                mid = self.all_tags[self.m[o]]
                if mid != self.ref:
                    k = self.tags.index(mid)
                    S[rows, 6 * k:6 * k + 6] = 1
                if self.c[o] == 1:
                    S[rows, self.n_tag_params:self.n_tag_params + 6] = 1
        return S

    def solve(self, x_start, free_calibration: bool):
        """Fit (everything, or only the frame poses) from x_start; returns x."""
        if free_calibration:
            fun, x0 = self.residuals, x_start
        else:
            head = x_start[:self.n_tag_params + 6]
            def fun(xf):
                return self.residuals(np.concatenate([head, xf]))
            x0 = x_start[self.n_tag_params + 6:]
        res = least_squares(fun, x0, jac_sparsity=self.sparsity(free_calibration),
                            method="trf", loss="huber", f_scale=HUBER_PX, x_scale="jac",
                            max_nfev=200, verbose=0)
        if free_calibration:
            return res.x
        return np.concatenate([x_start[:self.n_tag_params + 6], res.x])

    def errors(self, x):
        """Per tag view: mean corner distance, px."""
        r = self.residuals(x).reshape(-1, 4, 2)
        return np.linalg.norm(r, axis=2).mean(axis=1)


def initial_frame_pose(board, c0, i0, c1, i1, K, Rx, tx):
    """Device pose (cam0 frame) from the camera seeing more tags, with the
    current calibration."""
    order = sorted(((len(i0), 0, c0, i0), (len(i1), 1, c1, i1)), key=lambda v: -v[0])
    for _, cam, cs, ids in order:
        p = estimate_board_pose(board, cs, ids, K[cam], None)
        if p is None:
            continue
        rvec, tvec = np.asarray(p[0], np.float64).flatten(), np.asarray(p[1], np.float64).flatten()
        if cam == 1:
            R = np.asarray(Rx) @ cv2.Rodrigues(rvec.reshape(3, 1))[0]
            rvec, tvec = cv2.Rodrigues(R)[0].flatten(), np.asarray(Rx) @ tvec + np.asarray(tx).flatten()
        return rvec, tvec
    return None


def subset(frames, keep):
    return [frames[i] for i in keep]


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=60.0)
    args = ap.parse_args()

    settings = _load_settings()
    settings.update({"debug": False, "debug_preview": False, "pipeline": "current",
                     "undistort_pad_x_px": 0, "undistort_pad_y_px": 0})
    tracker = MainClass(cam_calib_path=calib_path(settings), settings=settings, udp=False)
    K0, K1 = tracker.camera_matrix.copy(), tracker.camera_matrix_1.copy()
    Rx, tx = tracker._stereo_Rx.copy(), tracker._stereo_tx.copy()
    board = tracker.board
    print("\nMove the device slowly over the whole table, turning it left and right "
          "(about +-45 deg) and tilting it a little. Starting in 3 s...")
    time.sleep(3)
    try:
        frames = record(tracker, args.seconds)
    finally:
        tracker.close()
    if len(frames) < 50:
        sys.exit(f"Only {len(frames)} usable frames — move the device where both cameras see it.")
    keep = np.unique(np.linspace(0, len(frames) - 1, min(MAX_FRAMES, len(frames))).astype(int))
    frames = subset(frames, keep)
    train, test = frames[0::2], frames[1::2]
    print(f"{len(frames)} frames: {len(train)} to fit, {len(test)} held out")

    print("Fitting (can take a minute or two)...")
    fit = Problem(board, train, K0, K1, Rx, tx)
    x_old = fit.solve(fit.x0, free_calibration=False)       # old calibration, frames only
    x_new = fit.solve(x_old, free_calibration=True)         # everything together
    e_old, e_new = fit.errors(x_old), fit.errors(x_new)

    # The new calibration as files.
    tags, stereo, _ = fit.unpack(x_new)
    new_poses = dict(board.marker_poses)
    for k, mid in enumerate(fit.tags):
        new_poses[mid] = (cv2.Rodrigues(tags[k, :3].reshape(3, 1))[0], tags[k, 3:].copy())
    new_board = BoardGeometry(board.marker_length, board.reference_id, new_poses, board.grip_point)
    Rx_new = cv2.Rodrigues(stereo[:3].reshape(3, 1))[0]
    tx_new = stereo[3:].copy()

    # Held-out frames: only the device pose free, old vs new calibration.
    held_old = Problem(board, test, K0, K1, Rx, tx)
    held_new = Problem(new_board, test, K0, K1, Rx_new, tx_new)
    h_old = held_old.errors(held_old.solve(held_old.x0, free_calibration=False))
    h_new = held_new.errors(held_new.solve(held_new.x0, free_calibration=False))

    print("\nReprojection error per tag view (px)        median    90th pct")
    for name, e in (("fitted frames, old calibration", e_old), ("fitted frames, new calibration", e_new),
                    ("HELD-OUT frames, old calibration", h_old), ("HELD-OUT frames, new calibration", h_new)):
        print(f"  {name:36} {np.median(e):8.2f}  {np.percentile(e, 90):8.2f}")

    print("\nPer tag, held-out frames (median px): old -> new, and how far the tag moved")
    for mid in fit.all_tags:
        so = held_old.m == held_old.tag_index[mid]
        sn = held_new.m == held_new.tag_index[mid]
        moved = 1000.0 * np.linalg.norm(new_poses[mid][1] - board.marker_poses[mid][1])
        if so.any():
            print(f"  tag {mid:>2}: {np.median(h_old[so]):5.2f} -> {np.median(h_new[sn]):5.2f} px   "
                  f"moved {moved:5.2f} mm   ({int(so.sum())} views)")
    ang = np.degrees(np.arccos(np.clip((np.trace(Rx.T @ Rx_new) - 1) / 2, -1, 1)))
    print(f"\ncam1 relative to cam0: baseline {1000 * np.linalg.norm(tx):.1f} -> "
          f"{1000 * np.linalg.norm(tx_new):.1f} mm, moved {1000 * np.linalg.norm(tx_new - tx):.2f} mm, "
          f"turned {ang:.3f} deg")

    better = np.median(h_new) < np.median(h_old)
    print("\nHeld-out error " + ("DROPPED — the new calibration explains unseen frames better."
                                  if better else "did NOT drop — keeping the old files is safer."))
    if input("Write the new board_geometry.json and stereo_extrinsics.json? [y/N] ").strip().lower() != "y":
        print("Nothing written.")
        return
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bpath = os.path.join(_PYSCRIPTS_DIR, settings.get("board_geometry_file", "board_geometry.json"))
    spath = os.path.join(_PYSCRIPTS_DIR, settings.get("stereo_extrinsics_file", "stereo_extrinsics.json"))
    for path in (bpath, spath):
        if os.path.exists(path):
            shutil.copy2(path, f"{path}.before-{stamp}")
    meta = {"date": datetime.now().isoformat(timespec="seconds"), "tool": "calibrate_rig.py",
            "frames_fitted": len(train), "frames_held_out": len(test),
            "held_out_median_px_old": float(np.median(h_old)),
            "held_out_median_px_new": float(np.median(h_new))}
    new_board.save(bpath, meta=meta)
    with open(spath, "w") as f:
        json.dump({"Rx": Rx_new.tolist(), "tx": tx_new.tolist(), "meta": meta}, f, indent=2)
    print(f"Written (old ones kept as *.before-{stamp}).")
    print("Next: start Godot, re-lock the origin, redo the 4-corner table calibration.")


if __name__ == "__main__":
    main()
