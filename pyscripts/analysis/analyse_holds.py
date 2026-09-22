"""
What one T1 recording says about the device on its own — no motion capture yet.

For every place in the grid it reports, from the samples between that place's
hold_start and hold_end marks:

  n, dur      how many samples, over how long (sanity: ~300 samples, ~3.0 s)
  jitter      SD of the position while still, in mm, in the table plane
  drift       max - min over the hold, in mm (a slow slide shows here, not in SD)
  height      SD of the out-of-plane axis, in mm — physically 0, so this is error
  gap         cam0 vs cam1 disagreement (stereo_gap_mm): mean and max
  cams        share of samples where both cameras saw the device
  mk          mean markers seen (cam0 + cam1)

A place redone with backspace appears once: the last hold wins.

Run:
    python pyscripts/analysis/analyse_holds.py                      # newest recording
    python pyscripts/analysis/analyse_holds.py <folder>
    python pyscripts/analysis/analyse_holds.py <folder> --png map.png
"""

import argparse
import csv
import json
import os
import sys

import numpy as np

# pyscripts/, one folder up; settings.json is one further up, at the repo root.
_PYSCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _settings() -> dict:
    path = os.path.join(_PYSCRIPTS_DIR, "..", "settings.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def newest_recording() -> str:
    root = os.path.expanduser(
        _settings().get("validation_data_dir", "~/Documents/NOARK/validation"))
    folders = [os.path.join(root, d) for d in os.listdir(root)]
    folders = [d for d in folders if os.path.isfile(os.path.join(d, "marks.csv"))]
    if not folders:
        sys.exit(f"No recordings with marks.csv under {root}")
    return max(folders, key=os.path.getmtime)


def read_marks(folder: str) -> dict:
    """{place index: (start_sample, end_sample, x, y)} — the last hold of a
    place wins, so a redo replaces the fumbled attempt."""
    holds, open_start = {}, {}
    with open(os.path.join(folder, "marks.csv")) as f:
        for row in csv.DictReader(f):
            parts = row["label"].split()
            # Only hold marks are read here; T2 writes "pacer ..." and "lap n"
            # into the same file.
            if len(parts) < 4 or parts[0] not in ("hold_start", "hold_end"):
                continue
            try:
                what, index = parts[0], int(parts[1])
                x, y = float(parts[2]), float(parts[3])
            except ValueError:
                continue
            sample = int(row["sample"])
            if what == "hold_start":
                open_start[index] = sample
            elif what == "hold_end" and index in open_start:
                holds[index] = (open_start.pop(index), sample, x, y)
    if open_start:
        print(f"[warn] {len(open_start)} hold(s) never ended — recording stopped "
              f"mid-hold? places: {sorted(open_start)}")
    return holds


def read_samples(folder: str) -> dict:
    """samples.csv as columns of floats (blank -> nan), plus the raw fusion text."""
    cols = {}
    with open(os.path.join(folder, "samples.csv")) as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        for name in reader.fieldnames:
            if name == "fusion":
                cols[name] = [r[name] for r in rows]
            else:
                cols[name] = np.array(
                    [float(r[name]) if r[name] != "" else np.nan for r in rows])
    return cols


def _sd_mm(values: np.ndarray) -> float:
    v = values[~np.isnan(values)]
    return float(np.std(v) * 1000.0) if v.size else float("nan")


def _range_mm(values: np.ndarray) -> float:
    v = values[~np.isnan(values)]
    return float((v.max() - v.min()) * 1000.0) if v.size else float("nan")


def analyse(folder: str) -> list:
    holds = read_marks(folder)
    s = read_samples(folder)
    n_rows = len(s["sample"])
    # The game frame is the table frame in all but name: the device slides, so
    # x-z is the table plane and y is height. Falls back to the camera frame if
    # the origin was not locked during the recording.
    plane = ("game_x_m", "game_z_m", "game_y_m")
    if np.all(np.isnan(s["game_x_m"])):
        print("[warn] no game-frame coordinates (origin not locked) — "
              "using the camera frame instead; 'height' is then cam0's y axis.")
        plane = ("tx_m", "tz_m", "ty_m")

    out = []
    for index in sorted(holds):
        a, b, x, y = holds[index]
        a, b = max(a, 0), min(b, n_rows)
        if b - a < 2:
            continue
        sl = slice(a, b)
        px, pz, ph = (s[plane[0]][sl], s[plane[1]][sl], s[plane[2]][sl])
        t = s["t_cam0_s"][sl]
        gap = s["stereo_gap_mm"][sl]
        both = sum(1 for v in s["fusion"][sl] if v == "both")
        markers = np.nanmean(s["n_markers_cam0"][sl] + s["n_markers_cam1"][sl])
        out.append({
            "place": index, "x": x, "y": y, "n": b - a,
            "dur": float(np.nanmax(t) - np.nanmin(t)),
            "jitter": float(np.hypot(_sd_mm(px), _sd_mm(pz))),
            "drift": float(max(_range_mm(px), _range_mm(pz))),
            "height": _sd_mm(ph),
            "gap_mean": float(np.nanmean(gap)) if np.any(~np.isnan(gap)) else float("nan"),
            "gap_max": float(np.nanmax(gap)) if np.any(~np.isnan(gap)) else float("nan"),
            "both": 100.0 * both / (b - a),
            "mk": float(markers),
        })
    return out


def report(folder: str, rows: list) -> None:
    print(f"\n{folder}\n{len(rows)} places\n")
    head = (f"{'place':>5} {'n':>5} {'dur s':>6} {'jitter':>7} {'drift':>7} "
            f"{'height':>7} {'gap mm':>7} {'gap max':>8} {'both %':>7} {'mk':>5}")
    print(head)
    print("-" * len(head))
    for r in rows:
        print(f"{r['place']:>5} {r['n']:>5} {r['dur']:>6.2f} {r['jitter']:>7.2f} "
              f"{r['drift']:>7.2f} {r['height']:>7.2f} {r['gap_mean']:>7.2f} "
              f"{r['gap_max']:>8.2f} {r['both']:>7.0f} {r['mk']:>5.1f}")

    def summarise(key: str, unit: str = "mm") -> None:
        v = np.array([r[key] for r in rows], dtype=float)
        v = v[~np.isnan(v)]
        if not v.size:
            return
        worst = sorted(rows, key=lambda r: -(r[key] if r[key] == r[key] else -1))[:5]
        print(f"{key:>8}: median {np.median(v):6.2f} {unit}   "
              f"90th pct {np.percentile(v, 90):6.2f}   max {v.max():6.2f}   "
              f"worst places: {', '.join(str(w['place']) for w in worst)}")

    print("\nsummary")
    for key in ("jitter", "drift", "height", "gap_mean"):
        summarise(key)
    both = np.array([r["both"] for r in rows])
    print(f"{'both':>8}: median {np.median(both):6.0f} %   "
          f"places under 50 %: {int((both < 50).sum())}")


def write_png(rows: list, path: str, key: str = "jitter") -> None:
    """Map of the table: each place at the spot it was drawn on screen,
    coloured green (best) to red (worst) by `key`. Drawn with OpenCV so the
    board needs no extra packages."""
    import cv2

    w, h = 1280, 800
    img = np.full((h, w, 3), 246, np.uint8)
    xs = np.array([r["x"] for r in rows])
    ys = np.array([r["y"] for r in rows])
    vals = np.array([r[key] for r in rows], dtype=float)
    lo, hi = float(np.nanmin(vals)), float(np.nanmax(vals))
    span = max(hi - lo, 1e-6)
    # Coverage keys are better when high, the error keys when low: flip so green
    # always means best.
    higher_is_better = key in ("both", "mk")
    unit = {"both": "%", "mk": "markers"}.get(key, "mm")
    best, worst = (hi, lo) if higher_is_better else (lo, hi)
    # Screen coordinates -> image, keeping the layout
    sx = (xs - xs.min()) / max(xs.max() - xs.min(), 1e-6) * (w - 160) + 80
    sy = (ys - ys.min()) / max(ys.max() - ys.min(), 1e-6) * (h - 200) + 120
    for i, r in enumerate(rows):
        f = (vals[i] - lo) / span
        if higher_is_better:
            f = 1.0 - f
        colour = (60, int(200 * (1 - f)) + 40, int(200 * f) + 40)   # BGR
        cv2.circle(img, (int(sx[i]), int(sy[i])), 18, colour, -1)
        cv2.putText(img, f"{vals[i]:.1f}", (int(sx[i]) - 18, int(sy[i]) + 34),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.35, (60, 60, 60), 1)
    cv2.putText(img, f"{key} ({unit}): {best:.2f} green -> {worst:.2f} red", (60, 60),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (60, 60, 60), 2)
    cv2.imwrite(path, img)
    print(f"\nWrote {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    ap.add_argument("--png", help="also write a map of the table, coloured by --key")
    ap.add_argument("--key", default="jitter",
                    choices=["jitter", "drift", "height", "gap_mean", "gap_max",
                             "both", "mk"],
                    help="what the map colours (default: jitter)")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    rows = analyse(folder)
    if not rows:
        sys.exit("No complete holds found — is this a T1 recording?")
    report(folder, rows)
    if args.png:
        write_png(rows, args.png, args.key)


if __name__ == "__main__":
    main()
