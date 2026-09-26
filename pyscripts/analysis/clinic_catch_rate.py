#!/usr/bin/env python3
"""
clinic_catch_rate.py - does a clinic-study visit deliver its target catch rate?

Reads one visit folder written by the clinic app (app/clinic/visit_logger.gd):
targets.csv, calibration.csv and the level p in their header. For each pair it

  1. recomputes the lifetime from the calibration apples, the same rule as
     app/clinic/difficulty.gd (docs/clinic_study_interface.md §3.2):
         sort the pair's calibration movement times, timeouts counting as
         slower than every catch;  lifetime = t_(ceil(p * n))
     and shows it next to the one the app used (calibration.csv) - they must
     agree;
  2. counts the play apples caught and missed, and gives the real catch rate
     with a 95 % Wilson interval.

If the calibration rule works, p lies inside most pairs' intervals. The
interval is only the play-count spread: the calibration percentile itself is
estimated from ~40 movements, so a pair can miss p by a few more points.

Only the last calibration attempt counts (the check screen's C / S start a new
one); reposition apples are logged with their own phase and never count.

Usage (standard library only):
    python3 clinic_catch_rate.py                  # newest visit
    python3 clinic_catch_rate.py ~/Documents/NOARK/clinic/TEST/2026-09-26T09-40-00
"""

import argparse
import csv
import glob
import math
import os
import sys

CLINIC_DIR = os.path.expanduser("~/Documents/NOARK/clinic")


def read_visit_csv(path):
    """(header dict, list of row dicts). The first line is 'headerrows,N':
    N lines of key,value, then the column row."""
    with open(path, newline="") as f:
        first = f.readline().strip().split(",", 1)
        n = int(first[1])
        header = {}
        for _ in range(n - 1):
            key, _, value = f.readline().rstrip("\n").partition(",")
            header[key] = value
        return header, list(csv.DictReader(f))


def lifetime(mts, timeouts, p, cap):
    n = len(mts) + timeouts
    if n == 0:
        return None
    rank = min(max(math.ceil(p * n), 1), n)
    ordered = sorted(mts)
    return cap if rank > len(ordered) else ordered[rank - 1]


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    ph = k / n
    centre = (ph + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(ph * (1 - ph) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (centre - half, centre + half)


def newest_visit():
    folders = [d for d in glob.glob(os.path.join(CLINIC_DIR, "*", "*"))
               if os.path.isfile(os.path.join(d, "targets.csv"))]
    return max(folders, key=os.path.getmtime) if folders else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("visit", nargs="?", help="visit folder (default: newest)")
    args = ap.parse_args()
    folder = args.visit or newest_visit()
    if not folder:
        sys.exit("No visit folder found under " + CLINIC_DIR)

    header, targets = read_visit_csv(os.path.join(folder, "targets.csv"))
    _, calib = read_visit_csv(os.path.join(folder, "calibration.csv"))
    p = float(header["level_p"])
    cap = float(header["point_cap_s"])
    attempts = [int(r["attempt"]) for r in targets if r["phase"] == "calibration"]
    if not attempts:
        sys.exit("No calibration apples in " + folder)
    last = max(attempts)
    used = {int(r["pair"]): r["lifetime_s"] for r in calib if int(r["attempt"]) == last}

    print(f"{folder}\nlevel p = {p:.2f}, calibration attempt {last}\n")
    print(f"{'pair':>4} {'A/W mm':>9} {'cal n':>6} {'lifetime s':>11} {'app used':>9}"
          f" {'play caught':>12} {'rate':>6} {'95 % interval':>15} {'p inside':>9}")
    for k in sorted({int(r["pair"]) for r in targets if int(r["pair"]) > 0}):
        cal = [r for r in targets if r["phase"] == "calibration"
               and int(r["attempt"]) == last and int(r["pair"]) == k]
        mts = [float(r["mt_s"]) for r in cal if r["outcome"] == "caught"]
        timeouts = sum(r["outcome"] == "timeout" for r in cal)
        lt = lifetime(mts, timeouts, p, cap)
        play = [r for r in targets if r["phase"] == "play" and int(r["pair"]) == k]
        caught = sum(r["outcome"] == "caught" for r in play)
        n = caught + sum(r["outcome"] == "missed" for r in play)
        lo, hi = wilson(caught, n)
        aw = f"{float(cal[0]['a_mm']):.0f}/{float(cal[0]['w_mm']):.0f}" if cal else "-"
        lt_s = f"{lt:.3f}" if lt is not None else "-"
        rate = f"{caught / n:.0%}" if n else "-"
        ci = f"{lo:.0%}-{hi:.0%}" if n else "-"
        inside = ("yes" if lo <= p <= hi else "NO") if n else "-"
        print(f"{k:>4} {aw:>9} {len(mts) + timeouts:>6} {lt_s:>11} {used.get(k) or '-':>9}"
              f" {f'{caught} of {n}':>12} {rate:>6} {ci:>15} {inside:>9}")


if __name__ == "__main__":
    main()
