#!/usr/bin/env python3
"""
visibility_explorer.py - builds visibility_explorer.html, a page that shows
which markers each camera should be able to read (the visibility rules of
theoretical_error.py) next to which markers it actually read in each still
hold of a validation recording.

The per-hold geometry - each marker's angle to each camera, whether its
corners land on the image, its shortest edge in pixels - is computed here,
with the same maths as theoretical_error.marker_seen. The page only applies
the two thresholds (max turn, min size) to those numbers and draws them, so
the agreement it shows is the one printed here.

Inputs, all as the tracker used them:
  board_geometry.json, stereo_extrinsics.json          (pyscripts/)
  jitter_by_hold.csv from compare_jitter.py            (hold poses + markers read)
  meta.json of the recording                           (undistorted image size and
                                                        camera matrices; without it the
                                                        camera_calib*.toml are used)

    python visibility_explorer.py --holds jitter_by_hold.csv --meta meta.json
"""

import argparse
import csv
import json
import os
import sys
from datetime import date

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from theoretical_error import IMAGE_SIZE, PYSCRIPTS, Board, hidden_behind, load_K  # noqa: E402

DEFAULT_MAX_VIEW_DEG = 70.0
DEFAULT_MIN_PX = 20.0


def quat_to_R(x, y, z, w):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def geometry(board, Ks, size, Rx, tx, R, t):
    """Per camera, per marker (sorted by id): angle between the marker's face
    and the direction to that camera, whether all corners are in front and on
    the image, the shortest projected edge, the projected corners, and which
    nearer marker (if any) covers it (theoretical_error.hidden_behind)."""
    lens = [np.zeros(3), tx]
    W, H = size
    out, projected = [[], []], [{}, {}]
    for mid in sorted(board.markers):
        m = board.markers[mid]
        c0 = m["corners"] @ R.T + t
        centre, normal = R @ m["centre"] + t, R @ m["normal"]
        for c in (0, 1):
            pc = c0 if c == 0 else (c0 - tx) @ Rx          # rows: Rx^T (p - tx)
            to_cam = lens[c] - centre
            cosang = float(np.clip(normal @ to_cam / np.linalg.norm(to_cam), -1, 1))
            g = {"id": mid, "angle": round(float(np.degrees(np.arccos(cosang))), 3),
                 "inFront": bool(np.all(pc[:, 2] > 1e-6)), "inImage": False, "minEdge": 0.0, "quad": None}
            if g["inFront"]:
                K = Ks[c]
                u = K[0, 0] * pc[:, 0] / pc[:, 2] + K[0, 2]
                v = K[1, 1] * pc[:, 1] / pc[:, 2] + K[1, 2]
                uv = np.stack([u, v], axis=1)
                g["inImage"] = bool(u.min() >= 0 and u.max() <= W - 1 and v.min() >= 0 and v.max() <= H - 1)
                g["minEdge"] = round(float(np.linalg.norm(uv - np.roll(uv, -1, axis=0), axis=1).min()), 3)
                g["quad"] = [[round(float(a), 2), round(float(b), 2)] for a, b in uv]
                projected[c][mid] = (uv, float(np.linalg.norm(centre - lens[c])))
            out[c].append(g)
    for c in (0, 1):
        hidden = hidden_behind(projected[c])
        for g in out[c]:
            g["blockedBy"] = hidden.get(g["id"])
    return out


def visible(g, max_view, min_px, occlusion=True):
    return (g["angle"] < max_view and g["inFront"] and g["inImage"] and g["minEdge"] >= min_px
            and not (occlusion and g["blockedBy"] is not None))


def agreement(holds, max_view, min_px, occlusion=True):
    """Share of frame-level predictions the model gets right. A marker the
    model calls readable is right in the frames it was read (its detection
    rate r); one it calls unreadable is right in the others (1 - r). Averaged
    over every marker, camera and hold - no frame is dropped."""
    right = n = 0
    for h in holds:
        for c in (0, 1):
            for g in h["geom"][c]:
                r = h["rate"][c].get(g["id"], 0.0)
                right += r if visible(g, max_view, min_px, occlusion) else 1.0 - r
                n += 1
    return 100.0 * right / n if n else float("nan"), n


def side_text(v):
    s = f"{v:+.2f}"
    return "0.00 m" if s in ("+0.00", "-0.00") else s + " m"


def rates_of(text):
    """'12:1.000 28:0.120' -> {12: 1.0, 28: 0.12}"""
    return {int(k): float(v) for k, v in (item.split(":") for item in text.split())} if text else {}


def ids(text):
    return [int(v) for v in text.split()] if text else []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--holds", default=os.path.join(HERE, "jitter_by_hold.csv"))
    ap.add_argument("--meta", default=os.path.join(HERE, "meta.json"),
                    help="the recording's meta.json (image size and camera matrices the tracker used)")
    ap.add_argument("--board", default=os.path.join(PYSCRIPTS, "board_geometry.json"))
    ap.add_argument("--extrinsics", default=os.path.join(PYSCRIPTS, "stereo_extrinsics.json"))
    ap.add_argument("--calib0", default=os.path.join(PYSCRIPTS, "camera_calib.toml"))
    ap.add_argument("--calib1", default=os.path.join(PYSCRIPTS, "camera_calib_1.toml"))
    ap.add_argument("--template", default=os.path.join(HERE, "visibility_explorer_template.html"))
    ap.add_argument("--out", default=os.path.join(HERE, "visibility_explorer.html"))
    args = ap.parse_args()

    board = Board(args.board)
    with open(args.extrinsics) as f:
        ex = json.load(f)
    Rx = np.array(ex["Rx"], dtype=float).reshape(3, 3)
    tx = np.array(ex["tx"], dtype=float).reshape(3)

    meta = {}
    if args.meta and os.path.exists(args.meta):
        with open(args.meta) as f:
            meta = json.load(f)
    ud = meta.get("undistorted") or {}
    if ud.get("camera_matrix_cam0") and ud.get("camera_matrix_cam1"):
        Ks = [np.array(ud[f"camera_matrix_cam{c}"], dtype=float).reshape(3, 3) for c in (0, 1)]
        size = tuple(int(v) for v in ud.get("size", IMAGE_SIZE))
        cam_source = f"undistorted camera matrices and image size ({size[0]} x {size[1]}) from {os.path.basename(args.meta)}"
    else:
        Ks = [load_K(args.calib0, 0), load_K(args.calib1, 1)]
        size = IMAGE_SIZE
        cam_source = "camera_calib.toml and camera_calib_1.toml, image 1280 x 800 (no meta.json given)"
    print(f"cameras: {cam_source}")
    for c in (0, 1):
        print(f"  cam{c}: fx {Ks[c][0, 0]:.1f}  fy {Ks[c][1, 1]:.1f}  cx {Ks[c][0, 2]:.1f}  cy {Ks[c][1, 2]:.1f}")

    holds = []
    if args.holds and os.path.exists(args.holds):
        with open(args.holds, newline="") as f:
            rows = list(csv.DictReader(f))
        if rows and "ids_cam0" not in rows[0]:
            print(f"{args.holds} has no marker IDs - rerun the updated compare_jitter.py. Free placement only.")
            rows = []
        elif rows and "rates_cam0" not in rows[0]:
            print(f"{args.holds} has no per-frame detection rates (older compare_jitter.py): a marker read in "
                  f"most frames counts as 100 %, anything else as 0 %.")
        taken = {}
        for r in rows:
            if r.get("moved") == "True":
                continue
            R = quat_to_R(*(float(r[k]) for k in ("ref_qx", "ref_qy", "ref_qz", "ref_qw")))
            t = np.array([float(r[k]) for k in ("ref_tx_m", "ref_ty_m", "ref_tz_m")])
            number = r["hold"].split()[1] if r["hold"].startswith("hold_start") else r["hold"]
            taken[number] = taken.get(number, 0) + 1
            label = (f"Hold {number}{' (take ' + str(taken[number]) + ')' if taken[number] > 1 else ''}"
                     f" · {float(r['depth_m']):.2f} m away · {side_text(float(r['side_m']))} sideways")
            holds.append({
                "label": label, "R": R, "t": t, "grip": R @ board.grip + t,
                "rate": ([rates_of(r["rates_cam0"]), rates_of(r["rates_cam1"])] if "rates_cam0" in r
                         else [{m: 1.0 for m in ids(r["ids_cam0"])}, {m: 1.0 for m in ids(r["ids_cam1"])}]),
                "measPos": float(r["meas_pos_mm"]), "predPos": float(r["pred_pos_mm"]),
            })
        for h in holds:
            h["geom"] = geometry(board, Ks, size, Rx, tx, h["R"], h["t"])

    if holds:
        up = np.mean([h["R"][:, 1] for h in holds], axis=0)
        up /= np.linalg.norm(up)
        base = max(holds, key=lambda h: -h["R"][2, 2])["R"]          # front facing the cameras most
        table_y = float(np.median([h["grip"][1] for h in holds]))
        print(f"{len(holds)} still holds, scored frame by frame (share of frame-level predictions right)")
        for occ, name in ((False, "without blocking"), (True, "with blocking   ")):
            pct, total = agreement(holds, DEFAULT_MAX_VIEW_DEG, DEFAULT_MIN_PX, occ)
            grid = [(agreement(holds, a, p, occ)[0], a, p) for a in range(30, 90) for p in range(4, 61)]
            best = max(grid, key=lambda g: (round(g[0], 9), -np.hypot(g[1] - 70, g[2] - 20)))
            print(f"  {name}: {pct:.1f} % at {DEFAULT_MAX_VIEW_DEG:g} deg / {DEFAULT_MIN_PX:g} px, "
                  f"best {best[0]:.1f} % at {best[1]} deg / {best[2]} px  ({total} marker-camera pairs)")
    else:
        up = np.array([0.0, -1.0, 0.0])
        base = np.array([[1.0, 0, 0], [0, -1.0, 0], [0, 0, -1.0]])
        table_y = 0.0

    data = {
        "board": {"grip": board.grip.tolist(),
                  "markers": {str(mid): {"corners": m["corners"].tolist(), "centre": m["centre"].tolist(),
                                         "normal": m["normal"].tolist()} for mid, m in board.markers.items()}},
        "cams": [{"fx": float(K[0, 0]), "fy": float(K[1, 1]), "cx": float(K[0, 2]), "cy": float(K[1, 2])} for K in Ks],
        "image": {"w": size[0], "h": size[1]},
        "Rx": Rx.tolist(), "tx": tx.tolist(),
        "up": up.tolist(), "base": np.asarray(base).tolist(),
        "startGrip": [float(tx[0] / 2), table_y, 0.45],
        "defaults": {"maxView": DEFAULT_MAX_VIEW_DEG, "minPx": DEFAULT_MIN_PX},
        "holds": [{"label": h["label"], "R": h["R"].tolist(), "t": h["t"].tolist(), "grip": h["grip"].tolist(),
                   "rate": [{str(k): v for k, v in h["rate"][c].items()} for c in (0, 1)],
                   "measPos": h["measPos"], "predPos": h["predPos"],
                   "geom": h["geom"]} for h in holds],
        "source": (f"Board: {os.path.basename(args.board)}. Cameras: {cam_source}. Camera placement: "
                   f"{os.path.basename(args.extrinsics)} ({np.linalg.norm(tx) * 1000:.1f} mm apart). "
                   + (f"Holds: {os.path.basename(args.holds)}, {len(holds)} still holds, scored frame by frame: "
                      f"a marker the model calls readable is right in the share of frames it was read in, one "
                      f"it calls unreadable in the rest. " if holds else "")
                   + f"Built {date.today().isoformat()} by visibility_explorer.py."),
    }
    with open(args.template, encoding="utf-8") as f:
        page = f.read()
    page = page.replace("/*__DATA__*/null", json.dumps(data, separators=(",", ":")))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"wrote {args.out}  ({len(page) / 1024:.0f} kB)")


if __name__ == "__main__":
    main()
