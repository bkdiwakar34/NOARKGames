#!/usr/bin/env python3
"""
measure_sigma.py - the corner pixel noise sigma, measured from static
validation recordings.

While the device stands still, the only thing that moves a detected corner
from one frame to the next is noise. So for every corner of every marker in
each camera, the standard deviation of its u (and of its v) over the frames
of a hold is that corner's noise. Pooled over all of them:

    sigma = sqrt( mean over all corner coordinates of SD^2 )

That is the sigma theoretical_error.py takes (--sigma-ref). The device is
still, so there is no motion blur in it: it is the lower bound for a moving
device. A corner that is always off by the same amount (calibration error)
does not spread over time, so that is not in it either.

Cross-check from the same frames. Each camera's board-solve reprojection
error (samples.csv reproj_cam*_px) is the MEAN corner distance of that
camera's own fit, which for pure pixel noise is

    reproj = sigma * sqrt(pi/2) * sqrt((2N - 6) / 2N),   N = corners in the fit

sqrt(pi/2) is the mean length of a 2-D error with SD sigma per coordinate;
the second factor is the share of the noise the six pose numbers absorb. So
reproj / (sqrt(pi/2) sqrt((2N-6)/2N)) is a second estimate of sigma. If it
matches the first, pixel noise explains the fit residual; if it is clearly
bigger, something fixed (calibration, board geometry) adds to it; roughly
sqrt(reproj_sigma^2 - noise_sigma^2) per corner.

A hold whose sigma is several times the median hold's (--moved-factor) was
not still - the device was bumped or still being placed - and is shown but
left out of the pooled value, which one such hold would otherwise swamp.

Holds: in marks.csv every label containing "start" opens a hold, which the
next label containing "end" closes (Recording.write_mark: a mark's `sample`
is the next row to be written, so a hold is rows start .. end-1). A
recording without such marks is one hold; --whole forces that.

Usage (numpy only):
    python pyscripts/analysis/measure_sigma.py <recording folder> [<folder> ...]
    python pyscripts/analysis/measure_sigma.py ~/Documents/NOARK/validation      # every recording inside
"""

import argparse
import csv
import json
import math
import os
from collections import defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
UV = ["u0", "v0", "u1", "v1", "u2", "v2", "u3", "v3"]
MEAN_LENGTH_2D = math.sqrt(math.pi / 2)    # E|e| / sigma for a 2-D Gaussian error


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def find_recordings(paths):
    """Recording folders (those with a corners.csv): each path itself, or
    every recording directly inside it."""
    found = []
    for p in paths:
        p = os.path.expanduser(p)
        if os.path.exists(os.path.join(p, "corners.csv")):
            found.append(p)
        elif os.path.isdir(p):
            found += [os.path.join(p, n) for n in sorted(os.listdir(p))
                      if os.path.exists(os.path.join(p, n, "corners.csv"))]
    return found


def find_holds(marks, last_sample, whole):
    """[(label, first row, last row)]."""
    holds, opened = [], None
    if not whole:
        for m in marks:
            label, row = m["label"], int(m["sample"])
            if "start" in label.lower():
                opened = (label, row)
            elif "end" in label.lower() and opened is not None:
                holds.append((opened[0], opened[1], row - 1))
                opened = None
    return holds or [("whole recording", 0, last_sample)]


def pooled(variances):
    return math.sqrt(sum(variances) / len(variances)) if variances else float("nan")


def analyse_hold(corner_rows, sample_rows, lo, hi, min_frames):
    """Per camera and per marker: sigma from the frame-to-frame spread, and
    sigma from the reprojection error."""
    series = defaultdict(list)            # (cam, marker, corner, axis) -> values
    sizes = defaultdict(list)             # (cam, marker) -> mean edge length, px
    for r in corner_rows:
        if not lo <= int(r["sample"]) <= hi:
            continue
        cam, mid = int(r["cam"]), int(r["marker_id"])
        uv = np.array([float(r[k]) for k in UV]).reshape(4, 2)
        for j in range(4):
            series[(cam, mid, j, 0)].append(uv[j, 0])
            series[(cam, mid, j, 1)].append(uv[j, 1])
        sizes[(cam, mid)].append(np.linalg.norm(uv - np.roll(uv, -1, axis=0), axis=1).mean())

    var = {k: float(np.var(v, ddof=1)) for k, v in series.items() if len(v) >= min_frames}
    markers = []
    for cam, mid in sorted(sizes):
        vu = [v for (c, m, _, a), v in var.items() if c == cam and m == mid and a == 0]
        vv = [v for (c, m, _, a), v in var.items() if c == cam and m == mid and a == 1]
        if not vu:
            continue
        markers.append({"cam": cam, "marker_id": mid,
                        "frames": min(len(series[(cam, mid, j, 0)]) for j in range(4)),
                        "size_px": float(np.mean(sizes[(cam, mid)])),
                        "sigma_u_px": pooled(vu), "sigma_v_px": pooled(vv),
                        "sigma_px": pooled(vu + vv)})

    rows = [s for s in sample_rows if lo <= int(s["sample"]) <= hi]
    cams = {}
    for cam in (0, 1):
        v = [x for (c, *_), x in var.items() if c == cam]
        est = []
        for s in rows:
            n, rep = s.get(f"n_markers_cam{cam}", ""), s.get(f"reproj_cam{cam}_px", "")
            if n and rep and int(n) >= 2:
                N = 4 * int(n)
                est.append(float(rep) / (MEAN_LENGTH_2D * math.sqrt((2 * N - 6) / (2 * N))))
        cams[cam] = {"variances": v,
                     "markers": sum(1 for m in markers if m["cam"] == cam),
                     "sigma_px": pooled(v),
                     "sigma_reproj_px": float(np.median(est)) if est else float("nan")}
    tz = [float(s["tz_m"]) for s in rows if s.get("tz_m")]
    return markers, cams, (float(np.median(tz)) if tz else float("nan"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="recording folder(s), or a folder of recordings")
    ap.add_argument("--whole", action="store_true", help="ignore marks: each recording is one hold")
    ap.add_argument("--trim", type=int, default=0,
                    help="frames dropped at each end of a hold (settling after placing it)")
    ap.add_argument("--min-frames", type=int, default=30,
                    help="a corner seen in fewer frames of a hold is left out")
    ap.add_argument("--moved-factor", type=float, default=3.0,
                    help="a hold whose sigma is over this many times the median hold's is "
                         "taken as not still and left out of the pooled value")
    ap.add_argument("--out", default=os.path.join(HERE, "sigma_out", "sigma_by_marker.csv"))
    args = ap.parse_args()

    recordings = find_recordings(args.paths)
    if not recordings:
        raise SystemExit("No recording folders (with a corners.csv) found.")

    results, table = [], []                   # results: one entry per hold per camera
    for folder in recordings:
        name = os.path.basename(os.path.normpath(folder))
        pipeline = "?"
        meta_path = os.path.join(folder, "meta.json")
        if os.path.exists(meta_path):
            with open(meta_path) as f:
                pipeline = json.load(f).get("pipeline", "?")
        pixels = "RAW fisheye px" if pipeline == "raw_joint" else "undistorted px"
        corner_rows = read_csv(os.path.join(folder, "corners.csv"))
        sample_rows = read_csv(os.path.join(folder, "samples.csv"))
        last = max((int(s["sample"]) for s in sample_rows), default=-1)
        holds = find_holds(read_csv(os.path.join(folder, "marks.csv")), last, args.whole)

        for label, lo, hi in holds:
            markers, cams, dist = analyse_hold(corner_rows, sample_rows, lo + args.trim,
                                               hi - args.trim, args.min_frames)
            for cam in (0, 1):
                results.append({"recording": name, "pipeline": f"{pipeline}: {pixels}",
                                "hold": label, "dist": dist, "cam": cam, **cams[cam]})
            for m in markers:
                table.append({"recording": name, "hold": label, "distance_m": round(dist, 4), **m})

    # A hold whose spread is far above the others' was not still (device
    # bumped, or put down during the hold). It would swamp the pooled sigma -
    # one hold at 5 px outweighs a hundred at 0.3 - so it is shown but left out.
    median = {cam: float(np.nanmedian([r["sigma_px"] for r in results if r["cam"] == cam]))
              for cam in (0, 1)}
    for r in results:
        r["moved"] = r["sigma_px"] > args.moved_factor * median[r["cam"]]

    shown = None
    for r in results:
        if r["recording"] != shown:
            shown = r["recording"]
            print(f"\n{shown}   (pipeline {r['pipeline']})")
            print(f"  {'hold':<28} {'dist':>6}  cam  markers  sigma (spread)  sigma (from reproj)")
        flag = "   <- not still, left out" if r["moved"] else ""
        print(f"  {r['hold'][:28]:<28} {r['dist']:>5.2f}m  {r['cam']:>3}  {r['markers']:>7}  "
              f"{r['sigma_px']:>11.3f} px  {r['sigma_reproj_px']:>15.3f} px{flag}")

    kept = [r for r in results if not r["moved"]]
    left_out = len({(r["recording"], r["hold"]) for r in results if r["moved"]})
    spread = {cam: pooled([v for r in kept if r["cam"] == cam for v in r["variances"]]) for cam in (0, 1)}
    reproj = {cam: float(np.nanmedian([r["sigma_reproj_px"] for r in kept if r["cam"] == cam]))
              for cam in (0, 1)}
    print(f"\nPooled over {len(kept) // 2} holds ({left_out} left out as not still):")
    for cam in (0, 1):
        fixed = math.sqrt(max(reproj[cam] ** 2 - spread[cam] ** 2, 0.0))
        print(f"  cam{cam}:  noise sigma {spread[cam]:.3f} px   from reproj {reproj[cam]:.3f} px"
              f"   -> fixed error ~{fixed:.3f} px per corner")
    print(f"For theoretical_error.py:  --sigma-ref {spread[0]:.3f} "
          f"--sigma-ratio {spread[1] / spread[0]:.2f}")

    if table:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(table[0]))
            writer.writeheader()
            writer.writerows(table)
        print(f"Per-marker sigma: {args.out}")


if __name__ == "__main__":
    main()
