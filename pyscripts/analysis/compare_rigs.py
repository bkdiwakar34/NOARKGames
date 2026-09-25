#!/usr/bin/env python3
"""
compare_rigs.py - error maps of two or more camera arrangements on the SAME
colour scale, so they can be compared at a glance.

Same model and assumptions as theoretical_error.py (see its docstring): the
device facing the rig (yaw 0), grip point at lens height, errors are 1 SD
from corner noise sigma. Each rig is given as "gap_m:angle_deg" - the gap
between the two cameras and the angle between their optical axes (each
camera turned inward by half of it).

Colour scale: one per quantity (depth, sideways), shared by every rig. It
tops out at the 98th percentile of all maps so a few extreme cells at the
near corners do not wash out the rest; anything above shows in the darkest
colour (the arrow on the colour bar).

    python compare_rigs.py                                   # 75 mm straight vs 300 mm at 20 deg
    python compare_rigs.py --rigs 0.075:0 0.3:20 0.5:40
    python compare_rigs.py --measured jitter_by_hold.csv     # + measured holds on the first rig's maps
"""

import argparse
import csv
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import theoretical_error as te  # noqa: E402

XLABEL = "sideways (m), 0 = straight in front of the rig"
YLABEL = "distance from the cameras (m)"


def error_maps(board, Ks, gap, angle, laterals, depths, height, sigma, ratio, vis, yaw=0.0):
    """(depth error, sideways error) in mm over the table; NaN = pose not found."""
    dz = np.full((len(depths), len(laterals)), np.nan)
    dx = dz.copy()
    for i, z in enumerate(depths):
        for j, x in enumerate(laterals):
            unit, _ = te.unit_error(board, Ks, gap, angle, np.array([x, height, z]), yaw, ratio, vis)
            if unit is not None:
                dz[i, j], dx[i, j] = unit["err_z_mm"] * sigma, unit["err_x_mm"] * sigma
    return dz, dx


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rigs", nargs="+", default=["0.075:0", "0.3:20"],
                    help='camera arrangements as "gap_m:angle_deg"')
    ap.add_argument("--board", default=os.path.join(te.PYSCRIPTS, "board_geometry.json"))
    ap.add_argument("--calib0", default=os.path.join(te.PYSCRIPTS, "camera_calib.toml"))
    ap.add_argument("--calib1", default=os.path.join(te.PYSCRIPTS, "camera_calib_1.toml"))
    ap.add_argument("--sigma", type=float, default=0.315, help="cam0 corner noise, px (measured 2026-09-24)")
    ap.add_argument("--sigma-ratio", type=float, default=1.12, help="cam1 noise / cam0 noise")
    ap.add_argument("--measured", help="jitter_by_hold.csv from compare_jitter.py: each still hold is drawn "
                                       "as a dot, coloured by its MEASURED jitter on the same scale")
    ap.add_argument("--measured-rig", type=int, default=0,
                    help="which of --rigs the measured holds were recorded with (0 = the first)")
    ap.add_argument("--depth-range", type=float, nargs=3, default=[0.2, 1.2, 0.05], metavar=("MIN", "MAX", "STEP"))
    ap.add_argument("--lateral-range", type=float, nargs=3, default=[-0.4, 0.4, 0.02], metavar=("MIN", "MAX", "STEP"))
    ap.add_argument("--height", type=float, default=0.0)
    ap.add_argument("--heading", type=float, default=0.0,
                    help="which way the device faces, deg: 0 = straight at the rig, + = front turned toward cam1's side (same sign as the headings of recorded holds; median +28.5 on 2026-09-24)")
    ap.add_argument("--max-view-deg", type=float, default=70.0)
    ap.add_argument("--min-px", type=float, default=20.0)
    ap.add_argument("--pad", type=int, nargs=2, default=[0, 0], metavar=("X", "Y"))
    ap.add_argument("--no-occlusion", action="store_true",
                    help="count markers hidden behind nearer markers as readable")
    ap.add_argument("--out", default=os.path.join(HERE, "theoretical_error_out", "compare_rigs"))
    args = ap.parse_args()

    board = te.Board(args.board)
    Ks = [te.load_K(args.calib0, 0), te.load_K(args.calib1, 1)]
    vis = {"max_view_deg": args.max_view_deg, "min_px": args.min_px, "pad": tuple(args.pad),
           "occlusion": not args.no_occlusion}
    depths, laterals = te.span(*args.depth_range), te.span(*args.lateral_range)
    hx, hz = args.lateral_range[2] / 2, args.depth_range[2] / 2
    extent = (laterals[0] - hx, laterals[-1] + hx, depths[0] - hz, depths[-1] + hz)

    rigs = []
    for spec in args.rigs:
        gap, angle = (float(v) for v in spec.split(":"))
        dz, dx = error_maps(board, Ks, gap, angle, laterals, depths, args.height,
                            args.sigma, args.sigma_ratio, vis, yaw=-args.heading)
        rigs.append((gap, angle, dz, dx))

    # One colour scale per quantity, shared by all rigs.
    vmax = {q: float(np.nanpercentile(np.concatenate([r[i].ravel() for r in rigs]), 98))
            for q, i in (("depth", 2), ("sideways", 3))}

    # Measured holds (still ones only), in the rig frame the maps use.
    holds = []
    if args.measured:
        with open(args.measured, newline="") as f:
            holds = [r for r in csv.DictReader(f)
                     if r.get("moved", "False") != "True" and r.get("side_m")]
        print(f"{len(holds)} still holds from {args.measured}")
    dots = {"depth": [(float(r["side_m"]), float(r["depth_m"]), float(r["meas_z_mm"])) for r in holds],
            "sideways": [(float(r["side_m"]), float(r["depth_m"]), float(r["meas_side_mm"])) for r in holds]}

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LinearSegmentedColormap
    cmap = LinearSegmentedColormap.from_list("seq", te.SEQUENTIAL)
    cmap.set_bad(te.MISSING)
    os.makedirs(args.out, exist_ok=True)
    note = (f"1 SD from corner noise σ = {args.sigma:g} px (cam1 × {args.sigma_ratio:g}); device heading "
            f"{args.heading:+g}° (0 = facing the rig); markers hidden behind nearer markers "
            f"{'ignored' if args.no_occlusion else 'count as unread'}. Same colour scale on every map; darkest = {vmax['depth']:.2f} mm depth, "
            f"{vmax['sideways']:.2f} mm sideways or more. Grey = pose not found.")
    if holds:
        note += ("\nDots: MEASURED jitter of each still hold, same colour scale. A dot the colour of its "
                 "background = model right there; darker = more jitter than predicted.")

    def name(gap, angle):
        return f"{gap * 1000:.0f} mm apart, {angle:g}° between axes"

    def draw(ax, grid, top, title, points=()):
        im = ax.imshow(np.ma.masked_invalid(grid), cmap=cmap, origin="lower", aspect="auto",
                       extent=extent, interpolation="nearest", vmin=0, vmax=top)
        if points:
            x, y, v = zip(*points)
            ax.scatter(x, y, c=v, cmap=cmap, vmin=0, vmax=top, s=34, edgecolors=te.INK,
                       linewidths=0.7, zorder=3)
        te._style(ax, title, XLABEL, YLABEL)
        ax.grid(False)
        return im

    def colourbar(fig, im, axes, label):
        cb = fig.colorbar(im, ax=axes, extend="max", shrink=0.9)
        cb.set_label(label, color=te.INK2, fontsize=8)
        cb.ax.tick_params(labelsize=7, labelcolor=te.MUTED, colors=te.AXIS)
        cb.outline.set_visible(False)

    # All rigs in one figure: a row per rig, depth left, sideways right.
    fig, axes = plt.subplots(len(rigs), 2, figsize=(11, 4.6 * len(rigs)), squeeze=False,
                             layout="constrained")
    fig.patch.set_facecolor(te.SURFACE)
    for row, (gap, angle, dz, dx) in enumerate(rigs):
        mine = row == args.measured_rig
        im_z = draw(axes[row, 0], dz, vmax["depth"], f"Depth error · {name(gap, angle)}",
                    dots["depth"] if mine else ())
        im_x = draw(axes[row, 1], dx, vmax["sideways"], f"Sideways error · {name(gap, angle)}",
                    dots["sideways"] if mine else ())
    colourbar(fig, im_z, axes[:, 0], "depth error, 1 SD (mm)")
    colourbar(fig, im_x, axes[:, 1], "sideways error, 1 SD (mm)")
    fig.suptitle("Error over the table for different camera arrangements", x=0.01, ha="left",
                 color=te.INK, fontsize=12)
    fig.supxlabel(note, fontsize=7.5, color=te.MUTED, x=0.01, ha="left")
    path = os.path.join(args.out, "compare_rigs.png")
    fig.savefig(path, dpi=150, facecolor=te.SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {path}")

    # One figure per rig, same scale.
    for row, (gap, angle, dz, dx) in enumerate(rigs):
        mine = row == args.measured_rig
        fig, axes = plt.subplots(1, 2, figsize=(11, 4.8), layout="constrained")
        fig.patch.set_facecolor(te.SURFACE)
        colourbar(fig, draw(axes[0], dz, vmax["depth"], "Depth error", dots["depth"] if mine else ()),
                  axes[0], "depth error, 1 SD (mm)")
        colourbar(fig, draw(axes[1], dx, vmax["sideways"], "Sideways error",
                            dots["sideways"] if mine else ()),
                  axes[1], "sideways error, 1 SD (mm)")
        fig.suptitle(f"Error over the table · {name(gap, angle)}", x=0.01, ha="left",
                     color=te.INK, fontsize=12)
        fig.supxlabel(note, fontsize=7.5, color=te.MUTED, x=0.01, ha="left")
        path = os.path.join(args.out, f"map_{gap * 1000:.0f}mm_{angle:g}deg.png")
        fig.savefig(path, dpi=150, facecolor=te.SURFACE, bbox_inches="tight")
        plt.close(fig)
        print(f"wrote {path}")

    print(f"\nOver the table ({laterals[0]:g} to {laterals[-1]:g} m sideways, "
          f"{depths[0]:g} to {depths[-1]:g} m away), sigma = {args.sigma:g} px:")
    print(f"  {'rig':<32} {'depth median':>12} {'depth worst':>12} {'side median':>12} {'side worst':>11}")
    for gap, angle, dz, dx in rigs:
        print(f"  {name(gap, angle).replace('°', ' deg'):<32} {np.nanmedian(dz):>9.3f} mm {np.nanmax(dz):>9.3f} mm "
              f"{np.nanmedian(dx):>9.3f} mm {np.nanmax(dx):>8.3f} mm")

    if holds:
        # Measured vs the map cell each hold falls in. Looser than compare_jitter.py,
        # which predicts at the hold's own pose and markers: the map assumes yaw 0
        # and its own visibility rules.
        _, _, dz, dx = rigs[args.measured_rig]
        ratio = {"depth": [], "sideways": []}
        for q, grid in (("depth", dz), ("sideways", dx)):
            for x, z, v in dots[q]:
                i = int(np.clip(np.rint((z - depths[0]) / args.depth_range[2]), 0, len(depths) - 1))
                j = int(np.clip(np.rint((x - laterals[0]) / args.lateral_range[2]), 0, len(laterals) - 1))
                if np.isfinite(grid[i, j]) and grid[i, j] > 0:
                    ratio[q].append(v / grid[i, j])
        print(f"\nMeasured / map, {name(*rigs[args.measured_rig][:2]).replace('°', ' deg')}, median [middle half]:")
        for q in ("depth", "sideways"):
            if ratio[q]:
                q1, q2, q3 = np.percentile(ratio[q], [25, 50, 75])
                print(f"  {q:<9} {q2:.2f}   [{q1:.2f} - {q3:.2f}]   ({len(ratio[q])} holds)")


if __name__ == "__main__":
    main()
