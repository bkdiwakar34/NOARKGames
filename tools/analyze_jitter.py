"""
Analyze the jitter-comparison data: old setup (3 markers, equal-weight average)
vs new setup (all markers, rigid-body joint solve).

Jitter is the RMS distance of the tracked device position from its own mean
while held still — how much the position estimate wobbles at rest. It is
computed from the RAW tracker coordinates (tracker_x/y/z, in metres), so the
millimetre values are true physical device wobble: no monitor size, no table
size, no screen-mapping assumption enters. Lower is better.

Plots are laid out on the actual screen positions so you can see WHERE on the
workspace each setup struggles.

Run:  python tools/analyze_jitter.py
Reads every tools/jitter_data/jitter_test_*.csv, splits by the 'mode' column.
"""

import csv
import glob
import os
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.path import Path
from scipy.interpolate import RBFInterpolator
from scipy.spatial import ConvexHull

DATA_DIR = os.path.join(os.path.dirname(__file__), "jitter_data")
OLD_COLOR = "#C24B57"
NEW_COLOR = "#2E8B84"
INK = "#1f2a2e"
MUTED = "#5b6b70"
SCREEN_W, SCREEN_H = 1152.0, 648.0   # game coordinate space
MOVE_THRESHOLD_MM = 12.0             # exclude recordings where the device was moved mid-capture

plt.rcParams.update({"font.size": 12})


def load_all():
    """{mode: {target_id: Nx5 array of (screen_x, screen_y, tx, ty, tz)}}.
    Consecutive byte-identical samples collapsed (tracker repeats each pose
    between fresh frames; repeats are not independent measurements)."""
    data = {}
    for path in sorted(glob.glob(os.path.join(DATA_DIR, "jitter_test_*.csv"))):
        prev = None
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                key = (r["screen_x"], r["screen_y"], r["tracker_x"],
                       r["tracker_y"], r["tracker_z"])
                if key == prev:
                    continue
                prev = key
                data.setdefault(r["mode"], {}).setdefault(int(r["target_id"]), []).append(
                    (float(r["screen_x"]), float(r["screen_y"]),
                     float(r["tracker_x"]), float(r["tracker_y"]), float(r["tracker_z"])))
    return {m: {t: np.array(v) for t, v in td.items()} for m, td in data.items()}


def jitter_mm(points):
    """3-D RMS distance of the tracked position from its mean, in millimetres."""
    xyz = points[:, 2:5]
    d = xyz - xyz.mean(axis=0)
    return float(np.sqrt(np.mean(np.sum(d * d, axis=1)))) * 1000.0


def moved_mm(points):
    """True if the device was held at two different spots (first half vs second
    half of the tracked position shifts by more than the threshold)."""
    if len(points) < 4:
        return False
    xyz = points[:, 2:5]
    h = len(xyz) // 2
    return np.linalg.norm(xyz[:h].mean(axis=0) - xyz[h:].mean(axis=0)) * 1000.0 > MOVE_THRESHOLD_MM


def screen_pos(points):
    return points[:, 0:2].mean(axis=0)


def main():
    data = load_all()
    if not {"old", "new"} <= set(data):
        raise SystemExit(f"Need both 'old' and 'new' modes; found: {sorted(data)}")

    targets = sorted(set(data["old"]) & set(data["new"]))
    excluded = [t for t in targets
                if moved_mm(data["old"][t]) or moved_mm(data["new"][t])]
    targets = [t for t in targets if t not in excluded]
    print(f"Matched targets: {len(targets) + len(excluded)}   "
          f"excluded (device moved mid-recording): {excluded}   analysed: {len(targets)}\n")

    old_j = np.array([jitter_mm(data["old"][t]) for t in targets])
    new_j = np.array([jitter_mm(data["new"][t]) for t in targets])
    pos = np.array([screen_pos(data["new"][t]) for t in targets])

    print(f"{'target':>6} | {'old (mm)':>9} {'new (mm)':>9} | {'improve':>8}")
    print("-" * 42)
    for t, jo, jn in zip(targets, old_j, new_j):
        print(f"{t:>6} | {jo:>9.2f} {jn:>9.2f} | {jo/jn:>7.1f}x")
    print("-" * 42)
    print(f"\nMedian device wobble  old = {np.median(old_j):.2f} mm")
    print(f"Median device wobble  new = {np.median(new_j):.2f} mm")
    print(f"Median improvement factor = {np.median(old_j/new_j):.1f}x")
    print(f"New tighter at {int(np.sum(new_j < old_j))} / {len(targets)} positions")

    factor = float(np.median(old_j / new_j))
    _plot_screen_heatmap(pos, old_j, new_j, float(np.median(old_j)), float(np.median(new_j)))
    _plot_summary(old_j, new_j, factor)
    print(f"\nPlots saved in {DATA_DIR}")


def _smooth_field(pos, vals, gx, gy):
    """Smooth continuous field via thin-plate RBF over the full rectangle."""
    rbf = RBFInterpolator(pos, vals, kernel="thin_plate_spline", smoothing=1.0)
    pts = np.column_stack([gx.ravel(), gy.ravel()])
    return np.clip(rbf(pts), 0.0, None).reshape(gx.shape)


def _plot_screen_heatmap(pos, old_j, new_j, med_old, med_new):
    vmax = float(np.ceil(np.percentile(np.concatenate([old_j, new_j]), 95)))
    gx, gy = np.meshgrid(np.linspace(0, SCREEN_W, 300), np.linspace(0, SCREEN_H, 170))
    fig, axes = plt.subplots(1, 2, figsize=(13, 4.6), constrained_layout=True)
    im = None
    for ax, vals, title, med in [
            (axes[0], old_j, "Old setup  (3 markers, averaged)", med_old),
            (axes[1], new_j, "New setup  (rigid body)", med_new)]:
        field = _smooth_field(pos, vals, gx, gy)
        im = ax.pcolormesh(gx, gy, field, cmap="RdBu_r", vmin=0, vmax=vmax,
                           shading="gouraud", rasterized=True)
        ax.set_title(f"{title}\nmedian {med:.2f} mm")
        ax.set_aspect("equal")
        ax.invert_yaxis()   # screen y grows downward
        ax.set_xlabel("screen x (px)")
    axes[0].set_ylabel("screen y (px)")
    cbar = fig.colorbar(im, ax=axes, fraction=0.026, pad=0.02)
    cbar.set_label("Device wobble at rest (mm)")
    fig.suptitle("Tracking jitter across the workspace", fontsize=15)
    fig.savefig(os.path.join(DATA_DIR, "jitter_screenmap.png"), dpi=200,
                bbox_inches="tight", facecolor="white")
    plt.close(fig)


def _plot_summary(old_j, new_j, factor):
    fig, ax = plt.subplots(figsize=(6, 5.6))
    fig.subplots_adjust(left=0.14, right=0.95, top=0.82, bottom=0.10)
    positions = [0, 1]
    for x, vals, col in [(0, old_j, OLD_COLOR), (1, new_j, NEW_COLOR)]:
        jitter_x = x + (np.random.default_rng(0).uniform(-0.07, 0.07, len(vals)))
        ax.scatter(jitter_x, vals, s=26, color=col, alpha=0.45, edgecolors="none", zorder=3)
        med = np.median(vals)
        ax.plot([x - 0.22, x + 0.22], [med, med], color=col, lw=3, zorder=4)
        ax.text(x, med, f"  {med:.2f} mm", va="center", ha="left",
                fontsize=12, color=col, fontweight="bold")
    ax.set_xticks(positions)
    ax.set_xticklabels(["Old setup\n3 markers, averaged", "New setup\nrigid body"], fontsize=12)
    ax.set_ylabel("Device wobble at rest (mm)", fontsize=12)
    ax.set_ylim(0, None)
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(axis="y", alpha=0.25)
    ax.set_title("Tracking jitter across all positions", fontsize=17,
                 fontweight="bold", loc="left", pad=28)
    ax.text(0, 1.03, f"New setup is {factor:.1f}× tighter (median)",
            transform=ax.transAxes, fontsize=12, color=MUTED, va="bottom")
    fig.savefig(os.path.join(DATA_DIR, "jitter_summary.png"), dpi=200,
                bbox_inches="tight", facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    main()
