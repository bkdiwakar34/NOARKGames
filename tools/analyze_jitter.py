"""
Analyze the jitter-comparison data: old setup (3 markers, equal-weight average)
vs new setup (all markers, rigid-body joint solve).

For each held target the "jitter" is the RMS distance of the tracked point from
its own mean position while the device was held still — i.e. how much the cursor
wandered at rest. Lower is better. The comparison is per-target (matched by
target_id) plus an overall summary, with plots saved for a presentation.

Run:  python tools/analyze_jitter.py
Reads every tools/jitter_data/jitter_test_*.csv, splits by the 'mode' column.
"""

import csv
import glob
import os
import numpy as np
import matplotlib.pyplot as plt

# ── config ────────────────────────────────────────────────────────────────────
DATA_DIR = os.path.join(os.path.dirname(__file__), "jitter_data")
# Screen positions are in the game's 1152-wide coordinate space. On a 23.8"
# 1920x1080 panel (~527 mm wide) that is 527/1152 mm per game-pixel. Adjust if
# the monitor differs; pixel results are unaffected.
MM_PER_PX = 527.0 / 1152.0

OLD_COLOR = "#D1495B"   # old setup
NEW_COLOR = "#2E8B84"   # new setup


def load_rows(path):
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            yield r


def load_all():
    """Return {mode: {target_id: Nx2 array of (screen_x, screen_y)}}.
    Consecutive byte-identical samples are collapsed: the tracker repeats each
    pose several times between fresh frames, and those repeats are not
    independent measurements (they don't change the spread, only inflate N)."""
    data = {}
    for path in sorted(glob.glob(os.path.join(DATA_DIR, "jitter_test_*.csv"))):
        prev = None
        for r in load_rows(path):
            key = (r["screen_x"], r["screen_y"], r["tracker_x"],
                   r["tracker_y"], r["tracker_z"])
            if key == prev:
                continue          # drop repeated (non-independent) frame
            prev = key
            mode = r["mode"]
            tid = int(r["target_id"])
            data.setdefault(mode, {}).setdefault(tid, []).append(
                (float(r["screen_x"]), float(r["screen_y"])))
    return {m: {t: np.array(v) for t, v in td.items()} for m, td in data.items()}


def jitter_rms_px(points):
    """RMS distance from the mean position (radial spread), in pixels."""
    c = points.mean(axis=0)
    d = points - c
    return float(np.sqrt(np.mean(np.sum(d * d, axis=1))))


# A recording is contaminated if the device was moved mid-capture (held at one
# spot, then another) rather than held still. Detect by comparing the centroid
# of the first half of samples to the second half: genuine jitter oscillates
# around one point (small shift); a move shows a large shift. Threshold in px.
MOVE_THRESHOLD_PX = 25.0


def segment_moved(points):
    if len(points) < 4:
        return False
    h = len(points) // 2
    shift = np.linalg.norm(points[:h].mean(axis=0) - points[h:].mean(axis=0))
    return shift > MOVE_THRESHOLD_PX


def main():
    data = load_all()
    modes = set(data)
    if not {"old", "new"} <= modes:
        raise SystemExit(f"Need both 'old' and 'new' modes; found: {sorted(modes)}")

    targets = sorted(set(data["old"]) & set(data["new"]))
    print(f"Matched targets (in both modes): {len(targets)}")

    # Drop targets where either recording was contaminated by a mid-capture move.
    excluded = [t for t in targets
                if segment_moved(data["old"][t]) or segment_moved(data["new"][t])]
    if excluded:
        print(f"Excluded {len(excluded)} target(s) where the device moved "
              f"mid-recording: {excluded}")
    targets = [t for t in targets if t not in excluded]
    print(f"Clean targets analysed: {len(targets)}\n")

    rows = []
    print(f"{'target':>6} | {'old (px)':>9} {'new (px)':>9} | "
          f"{'old (mm)':>9} {'new (mm)':>9} | {'improve x':>9} | {'n_old':>5} {'n_new':>5}")
    print("-" * 82)
    for t in targets:
        jo = jitter_rms_px(data["old"][t])
        jn = jitter_rms_px(data["new"][t])
        ratio = jo / jn if jn > 0 else float("nan")
        rows.append((t, jo, jn, ratio, len(data["old"][t]), len(data["new"][t])))
        print(f"{t:>6} | {jo:>9.2f} {jn:>9.2f} | {jo*MM_PER_PX:>9.2f} "
              f"{jn*MM_PER_PX:>9.2f} | {ratio:>8.2f}x | "
              f"{len(data['old'][t]):>5} {len(data['new'][t]):>5}")

    jo_all = np.array([r[1] for r in rows])
    jn_all = np.array([r[2] for r in rows])
    print("-" * 82)
    print(f"\nMedian jitter   old = {np.median(jo_all):.2f} px "
          f"({np.median(jo_all)*MM_PER_PX:.2f} mm)")
    print(f"Median jitter   new = {np.median(jn_all):.2f} px "
          f"({np.median(jn_all)*MM_PER_PX:.2f} mm)")
    print(f"Median improvement factor (old/new) = {np.median(jo_all/jn_all):.2f}x")
    print(f"Targets where new is tighter: {int(np.sum(jn_all < jo_all))} / {len(rows)}")

    _plot_bars(rows)
    _plot_clusters(data, targets)
    _plot_summary(jo_all, jn_all)
    print(f"\nPlots saved in {DATA_DIR}")


def _plot_bars(rows):
    t = [r[0] for r in rows]
    jo = [r[1] * MM_PER_PX for r in rows]
    jn = [r[2] * MM_PER_PX for r in rows]
    x = np.arange(len(t))
    fig, ax = plt.subplots(figsize=(13, 4.5))
    ax.bar(x - 0.2, jo, 0.4, label="Old (3 markers, average)", color=OLD_COLOR)
    ax.bar(x + 0.2, jn, 0.4, label="New (rigid body)", color=NEW_COLOR)
    ax.set_xlabel("Target"); ax.set_ylabel("Jitter — RMS spread (mm)")
    ax.set_title("Cursor jitter at rest, per workspace position")
    ax.set_xticks(x); ax.set_xticklabels(t, fontsize=7)
    ax.legend(); ax.grid(axis="y", alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(DATA_DIR, "jitter_bars.png"), dpi=150)
    plt.close(fig)


def _plot_clusters(data, targets):
    # Six targets spread across the run, clouds centered on their own mean so
    # old vs new overlay and the tighter cluster is obvious.
    picks = [targets[int(round(i))] for i in np.linspace(0, len(targets) - 1, 6)]
    fig, axes = plt.subplots(2, 3, figsize=(12, 8))
    for ax, t in zip(axes.flat, picks):
        for mode, col, lab in [("old", OLD_COLOR, "Old"), ("new", NEW_COLOR, "New")]:
            p = data[mode][t]
            d = (p - p.mean(axis=0)) * MM_PER_PX
            ax.scatter(d[:, 0], d[:, 1], s=10, alpha=0.5, color=col, label=lab)
        ax.set_title(f"Target {t}"); ax.set_aspect("equal")
        ax.axhline(0, color="0.8", lw=0.5); ax.axvline(0, color="0.8", lw=0.5)
        ax.set_xlabel("mm"); ax.set_ylabel("mm")
        lim = 6
        ax.set_xlim(-lim, lim); ax.set_ylim(-lim, lim)
        ax.legend(fontsize=8)
    fig.suptitle("Spread of the tracked point while held still (centered per target)")
    fig.tight_layout(); fig.savefig(os.path.join(DATA_DIR, "jitter_clusters.png"), dpi=150)
    plt.close(fig)


def _plot_summary(jo_all, jn_all):
    fig, ax = plt.subplots(figsize=(5, 5.5))
    parts = ax.boxplot([jo_all * MM_PER_PX, jn_all * MM_PER_PX],
                       tick_labels=["Old\n(3 markers)", "New\n(rigid body)"],
                       patch_artist=True, widths=0.5)
    for patch, col in zip(parts["boxes"], [OLD_COLOR, NEW_COLOR]):
        patch.set_facecolor(col); patch.set_alpha(0.6)
    for med in parts["medians"]:
        med.set_color("black")
    ax.set_ylabel("Jitter — RMS spread (mm)")
    ax.set_title("Jitter across all workspace positions")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(DATA_DIR, "jitter_summary.png"), dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    main()
