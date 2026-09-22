"""
Where should the two cameras sit? — "what if" placements, from one T1 recording.

The recording holds the device's pose at every T1 place, seen from cam0. That
is enough to ask what the cameras would see from somewhere else, without
moving anything: the camera pair (kept side by side, as mounted) is moved
BACK (away from the workspace, along the table), UP (away from the table) and
either keeps its current tilt or is re-aimed at the middle of the workspace.
For each placement and each place, every marker of the device is scored for
each camera:

  usable    facing the camera, on the raw fisheye image, and seen within
            EDGE_DEG of face-on — the markers the detector has a chance with
  angle     how far off the camera's axis it is (the undistorted image has to
            reach that far: border px ~ f * tan(angle) - 640 sideways)
  px/mm     sharpness: f / distance. Jitter grows roughly as 1 / (px/mm).

What this cannot predict: markers hidden by a hand or by the device itself,
blur, and detector misses. So the first row (the current placement) is also
compared with what the cameras actually saw in the recording.

Run (a full 96-place T1 recording):
    python pyscripts/analysis/camera_placement.py <folder>
    python pyscripts/analysis/camera_placement.py <folder> --back 0 100 200 --up 0 100
"""

import argparse
import os
import sys

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

# pyscripts/, one folder up, for board.py (the other imports are in this folder).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from analyse_holds import newest_recording, read_marks, read_samples
from coverage_markers import FRAME_H, FRAME_W, EDGE_DEG, load_calib, read_seen

GRID_PLACES = 96


def hold_poses(holds: dict, s: dict) -> list:
    """(place, sample, R0, t0) — the middle valid sample of each hold, board
    pose in cam0's frame."""
    out = []
    for index in sorted(holds):
        a, b, _, _ = holds[index]
        rows = [n for n in range(a, min(b, len(s["sample"])))
                if not np.isnan(s["tx_m"][n]) and not np.isnan(s["qw"][n])]
        if not rows:
            continue
        n = rows[len(rows) // 2]
        R0 = Rotation.from_quat([s["qx"][n], s["qy"][n], s["qz"][n], s["qw"][n]]).as_matrix()
        t0 = np.array([s["tx_m"][n], s["ty_m"][n], s["tz_m"][n]])
        out.append((index, n, R0, t0))
    return out


def table_frame(grips: np.ndarray) -> tuple:
    """Plane through the grip points (the device slides on the table), in
    cam0's frame: centre, up (table normal, towards the cameras), back
    (along the table from the workspace towards the cameras), side."""
    centre = grips.mean(axis=0)
    _, _, vt = np.linalg.svd(grips - centre)
    up = vt[2]
    if up @ (np.zeros(3) - centre) < 0:          # the cameras are above the table
        up = -up
    to_cam = -centre
    back = to_cam - (to_cam @ up) * up
    back /= np.linalg.norm(back)
    side = np.cross(up, back)
    return centre, up, back, side


def aim_rotation(axis_now: np.ndarray, target_dir: np.ndarray) -> np.ndarray:
    """Smallest rotation turning axis_now onto target_dir (both unit)."""
    v = np.cross(axis_now, target_dir)
    s, c = np.linalg.norm(v), float(axis_now @ target_dir)
    if s < 1e-9:
        return np.eye(3)
    return Rotation.from_rotvec(v / s * np.arctan2(s, c)).as_matrix()


def score_marker(board, marker_id, R, t, K, D):
    """(usable?, off-axis angle deg, px per mm) for one marker, one camera."""
    R_bm, t_bm = board.marker_poses[marker_id]
    centre = R @ t_bm + t
    dist = float(np.linalg.norm(centre))
    normal = R @ R_bm[:, 2]
    cos_view = float(normal @ (-centre / dist))
    off_axis = float(np.degrees(np.arccos(np.clip(centre[2] / dist, -1.0, 1.0))))
    px_per_mm = K[0, 0] / (dist * 1000.0)
    if cos_view <= 0.0 or centre[2] <= 0.0:
        return False, off_axis, px_per_mm
    corners = board.corners_in_board(marker_id) @ R.T + t
    raw, _ = cv2.fisheye.projectPoints(corners.reshape(-1, 1, 3), np.zeros(3), np.zeros(3), K, D)
    uv = raw.reshape(-1, 2)
    on_sensor = bool(np.all((uv[:, 0] >= 0) & (uv[:, 0] < FRAME_W)
                            & (uv[:, 1] >= 0) & (uv[:, 1] < FRAME_H)))
    face_on = np.degrees(np.arccos(min(cos_view, 1.0))) <= EDGE_DEG
    return on_sensor and face_on, off_axis, px_per_mm


def evaluate(poses, board, cams, Rx, tx, move: np.ndarray, Q: np.ndarray) -> dict:
    """Score every place with the camera pair moved to `move` (cam0's new
    origin, in the old cam0 frame) and turned by Q (new axes as columns)."""
    RxT = Rx.T
    ids = sorted(board.marker_poses)
    usable, worst_angle, density = [], [], []
    for _, _, R0, t0 in poses:
        Rn, tn = Q.T @ R0, Q.T @ (t0 - move)             # board in the new cam0 frame
        per_cam = [(Rn, tn), (RxT @ Rn, RxT @ (tn - tx))]
        n_usable, angles, dens = 0, [], []
        for (R, t), (K, D, _) in zip(per_cam, cams):
            for mid in ids:
                ok, ang, ppm = score_marker(board, mid, R, t, K, D)
                if ok:
                    n_usable += 1
                    angles.append(ang)
                    dens.append(ppm)
        usable.append(n_usable)
        worst_angle.append(max(angles) if angles else float("nan"))
        density.append(float(np.median(dens)) if dens else float("nan"))
    return {"usable": np.array(usable), "angle": np.array(worst_angle),
            "density": np.array(density)}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="T1 recording folder (default: the newest)")
    ap.add_argument("--back", type=float, nargs="*", default=[0, 100, 200, 300],
                    help="mm to move the cameras back, away from the workspace")
    ap.add_argument("--up", type=float, nargs="*", default=[0, 100, 200],
                    help="mm to move the cameras up, away from the table")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    cams, _, _, Rx, tx, board = load_calib(folder)
    holds = read_marks(folder)
    s = read_samples(folder)
    poses = hold_poses(holds, s)
    if len(poses) < GRID_PLACES:
        print(f"[warn] {len(poses)} of {GRID_PLACES} places — a partial grid only "
              f"describes part of the workspace")
    if len(poses) < 4:
        sys.exit("Too few places with a pose.")

    grips = np.array([R0 @ board.grip_point + t0 for _, _, R0, t0 in poses])
    centre, up, back, side = table_frame(grips)
    rel = grips - centre
    along_back, along_side = rel @ back, rel @ side
    height = abs(float((np.zeros(3) - centre) @ up))       # table plane to cam0
    horiz = float((np.zeros(3) - centre) @ back)
    depression = float(np.degrees(np.arcsin(np.clip(-(np.array([0, 0, 1.0]) @ up), -1, 1))))

    print(f"\n{folder}\n{len(poses)} places")
    print("\nworkspace as the cameras see it now (cam0, mm)")
    print(f"  size: {1000 * np.ptp(along_side):.0f} wide x {1000 * np.ptp(along_back):.0f} deep")
    print(f"  camera height above the table:         {1000 * height:.0f}")
    print(f"  camera to workspace centre, along table: {1000 * horiz:.0f}")
    print(f"  camera to near edge / far edge:        "
          f"{1000 * (horiz - along_back.max()):.0f} / {1000 * (horiz - along_back.min()):.0f}")
    print(f"  camera axis below horizontal:          {depression:.0f} deg")

    # Sanity check of the scoring against what the cameras really saw.
    seen = read_seen(folder, {n for _, n, _, _ in poses})
    actual = np.array([len(seen.get(n, (set(), set()))[0]) + len(seen.get(n, (set(), set()))[1])
                       for _, n, _, _ in poses])
    now = evaluate(poses, board, cams, Rx, tx, np.zeros(3), np.eye(3))
    print(f"\ncheck, current placement: predicted usable {np.mean(now['usable']):.1f} "
          f"markers per place, actually seen {np.mean(actual):.1f} "
          f"(the gap is hands, the device itself and detector misses)")

    base_density = float(np.nanmedian(now["density"]))
    z_axis = np.array([0.0, 0.0, 1.0])
    print(f"\n{'back':>5} {'up':>5} {'tilt':>7}  {'usable markers per place':>26}  "
          f"{'places':>7}  {'worst':>6}  {'px/mm':>6}  {'jitter':>6}")
    print(f"{'mm':>5} {'mm':>5} {'':>7}  {'min':>6} {'10th':>6} {'median':>6}      "
          f"{'< 4':>7}  {'angle':>6}  {'median':>6}  {'x now':>6}")
    print("-" * 82)
    for d in args.back:
        for h in args.up:
            move = (d / 1000.0) * back + (h / 1000.0) * up
            aim = aim_rotation(z_axis, (centre - move) / np.linalg.norm(centre - move))
            for label, Q in (("as now", np.eye(3)), ("aimed", aim)):
                r = evaluate(poses, board, cams, Rx, tx, move, Q)
                dens = float(np.nanmedian(r["density"]))
                mark = "  <- current" if d == 0 and h == 0 and label == "as now" else ""
                print(f"{d:>5.0f} {h:>5.0f} {label:>7}  {r['usable'].min():>6d} "
                      f"{np.percentile(r['usable'], 10):>6.0f} {np.median(r['usable']):>6.0f}      "
                      f"{int((r['usable'] < 4).sum()):>7d}  {np.nanmax(r['angle']):>5.0f}°  "
                      f"{dens:>6.2f}  {base_density / dens:>6.2f}{mark}")
    print("\nusable = cam0 + cam1, out of 16. 'aimed' turns the pair so cam0 looks at the"
          "\nworkspace centre. worst angle = furthest usable marker from a camera's axis."
          "\njitter x now ~ how much larger the noise would be, from sharpness alone.")


if __name__ == "__main__":
    main()
