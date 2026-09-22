"""
What happens when the pose jumps? — from one recording (T1 or T2).

1. Shake: the table position (game x, z) minus a smooth version of itself
   (Savitzky-Golay, SMOOTH_SAMPLES wide, 2nd order — follows real movement,
   not a 10 ms flick). A sample whose shake is above --thr mm is a jump.
2. For every sample it notes what else was going on:

     tags changed    a camera saw a different SET of tags than one sample before
     cam0 / cam1     ... which camera it was
     mode changed    how the pose was made changed (both / cam0 / cam1 / *_disagree)
     one camera      the pose came from one camera only
     cams apart      cam0's and cam1's poses more than --gap mm apart
     poor fit        a camera's reprojection error above 2x its recording median
     nothing         none of the above

3. Compares each one's share among the jumps with its share among ALL samples.
   A cause shows as "much more common at jumps than normally" (ratio >> 1);
   something that is equally common everywhere (ratio ~1) is not the cause.

Also: where on the table the jumps are (3 x 3 zones over this recording's
positions, printed with the zone limits in mm), and the ten biggest jumps with
the tags each camera saw at that moment.

Run:
    python pyscripts/analysis/find_jumps.py                 # newest recording
    python pyscripts/analysis/find_jumps.py <folder> --thr 0.5
"""

import argparse
import csv
import os
import sys

import numpy as np
from scipy.signal import savgol_filter

from analyse_holds import newest_recording, read_samples

SMOOTH_SAMPLES = 15          # 150 ms at 100 Hz
MIN_SEGMENT = SMOOTH_SAMPLES + 2


def read_tag_sets(folder: str, n: int) -> list:
    """Per sample: (frozenset of cam0's tag ids, frozenset of cam1's)."""
    sets = [[set(), set()] for _ in range(n)]
    with open(os.path.join(folder, "corners.csv")) as f:
        for row in csv.DictReader(f):
            i = int(row["sample"])
            if i < n:
                sets[i][int(row["cam"])].add(int(row["marker_id"]))
    return [(frozenset(a), frozenset(b)) for a, b in sets]


def shake_mm(x: np.ndarray, z: np.ndarray) -> np.ndarray:
    """Distance from the smoothed path, per sample (nan where no pose or too
    short a run of poses to smooth)."""
    out = np.full(len(x), np.nan)
    valid = ~(np.isnan(x) | np.isnan(z))
    i = 0
    while i < len(x):
        if not valid[i]:
            i += 1
            continue
        j = i
        while j < len(x) and valid[j]:
            j += 1
        if j - i >= MIN_SEGMENT:
            sx = savgol_filter(x[i:j], SMOOTH_SAMPLES, 2)
            sz = savgol_filter(z[i:j], SMOOTH_SAMPLES, 2)
            out[i:j] = np.hypot(x[i:j] - sx, z[i:j] - sz)
        i = j
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", help="recording folder (default: the newest)")
    ap.add_argument("--thr", type=float, default=1.0, help="jump threshold, mm (default 1.0)")
    ap.add_argument("--gap", type=float, default=5.0,
                    help="'cams apart' threshold, mm (default 5.0)")
    args = ap.parse_args()

    folder = args.folder or newest_recording()
    s = read_samples(folder)
    n = len(s["sample"])
    if np.all(np.isnan(s["game_x_m"])):
        sys.exit("No game (table) coordinates in this recording — origin not locked.")
    x, z = s["game_x_m"] * 1000.0, s["game_z_m"] * 1000.0
    shake = shake_mm(x, z)
    have = ~np.isnan(shake)
    jumps = have & (shake > args.thr)

    tags = read_tag_sets(folder, n)
    fusion = np.array(s["fusion"], dtype=object)
    prev = np.r_[0, np.arange(n - 1)]                      # index of the sample before
    cam0_changed = np.array([tags[i][0] != tags[prev[i]][0] for i in range(n)])
    cam1_changed = np.array([tags[i][1] != tags[prev[i]][1] for i in range(n)])
    cam0_changed[0] = cam1_changed[0] = False
    mode_changed = fusion != fusion[prev]
    mode_changed[0] = False
    one_camera = np.isin(fusion, ["cam0", "cam1", "cam0_disagree", "cam1_disagree"])
    gap = s["stereo_gap_mm"]
    apart = ~np.isnan(gap) & (gap > args.gap)
    poor = np.zeros(n, bool)
    for cam in (0, 1):
        r = s[f"reproj_cam{cam}_px"]
        if np.any(~np.isnan(r)):
            poor |= ~np.isnan(r) & (r > 2.0 * np.nanmedian(r))
    tags_changed = cam0_changed | cam1_changed
    nothing = ~(tags_changed | mode_changed | one_camera | apart | poor)

    print(f"\n{folder}")
    print(f"{n} samples, {int(have.sum())} with a smoothed position")
    sh = shake[have]
    print(f"shake (distance from the smoothed path): median {np.median(sh):.2f} mm, "
          f"95th pct {np.percentile(sh, 95):.2f}, max {sh.max():.1f}")
    nj = int(jumps.sum())
    secs = n / 100.0
    print(f"jumps above {args.thr} mm: {nj}  ({100 * nj / max(have.sum(), 1):.1f} % of samples, "
          f"{nj / max(secs, 1e-9):.1f} per second)")
    if nj == 0:
        return

    print(f"\n{'':16} {'all samples':>12} {'at jumps':>10} {'ratio':>7}")
    for name, flag in (("tags changed", tags_changed), ("  cam0", cam0_changed),
                       ("  cam1", cam1_changed), ("mode changed", mode_changed),
                       ("one camera", one_camera), ("cams apart", apart),
                       ("poor fit", poor), ("nothing", nothing)):
        base = 100.0 * flag[have].mean()
        at = 100.0 * flag[jumps].mean()
        ratio = at / base if base > 0 else float("inf")
        print(f"{name:16} {base:11.1f}% {at:9.1f}% {ratio:7.1f}")

    # Where on the table: 3 x 3 zones over this recording's range of positions.
    xs, zs = x[have], z[have]
    xe = np.quantile(xs, [0, 1 / 3, 2 / 3, 1])
    ze = np.quantile(zs, [0, 1 / 3, 2 / 3, 1])
    xi = np.clip(np.searchsorted(xe, x, side="right") - 1, 0, 2)
    zi = np.clip(np.searchsorted(ze, z, side="right") - 1, 0, 2)
    print("\njumps per zone: jumps / samples  (x across, z down the table; edges in mm)")
    print("             " + "  ".join(f"x {xe[c]:6.0f}..{xe[c + 1]:<6.0f}" for c in range(3)))
    for r in range(3):
        cells = []
        for c in range(3):
            m = have & (xi == c) & (zi == r)
            k = int((jumps & m).sum())
            cells.append(f"{k:5d} / {int(m.sum()):<6d} ({100 * k / max(m.sum(), 1):4.1f}%)")
        print(f"z {ze[r]:5.0f}..{ze[r + 1]:<5.0f}  " + "  ".join(cells))

    print("\nbiggest jumps:")
    print(f"{'sample':>7} {'shake mm':>9} {'tags cam0':>16} {'tags cam1':>16} {'mode':>14} "
          f"{'gap mm':>7}")
    for i in np.argsort(-np.where(jumps, shake, -1))[:10]:
        if not jumps[i]:
            break
        t0 = ",".join(str(t) for t in sorted(tags[i][0])) or "-"
        t1 = ",".join(str(t) for t in sorted(tags[i][1])) or "-"
        g = "" if np.isnan(gap[i]) else f"{gap[i]:.1f}"
        print(f"{i:>7} {shake[i]:9.2f} {t0:>16} {t1:>16} {fusion[i]:>14} {g:>7}")


if __name__ == "__main__":
    main()
