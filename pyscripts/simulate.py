"""
simulate.py — PID Adaptive Difficulty Simulator

Enter per-trial success rates and choose how many apples trigger a correction.
Comparing N=1 (per-apple) vs N=20 (per-trial) shows how update frequency affects
controller stability.

Run:  python pyscripts/simulate.py
Deps: pip install matplotlib numpy   (tkinter is built into Python)
"""

import tkinter as tk
import matplotlib
matplotlib.use("TkAgg")
from matplotlib.figure import Figure
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
import matplotlib.ticker
import numpy as np

LIFETIME_MIN   = 0.1
LIFETIME_MAX   = 8.0
DEAD_BAND      = 0.05
N_CALIB_APPLES = 20


# ---------------------------------------------------------------------------
# Controller — mirrors adaptive_manager.gd exactly
# ---------------------------------------------------------------------------

class PIDController:
    def __init__(self, gain_p, gain_i, gain_d, window_width, target_rate):
        self.gain_p       = gain_p
        self.gain_i       = gain_i
        self.gain_d       = gain_d
        self.window_width = window_width
        self.target_rate  = target_rate
        self.threshold    = (LIFETIME_MAX + LIFETIME_MIN) * 0.5
        self.offset       = 0.0
        self._integral    = 0.0
        self._prev_error  = 0.0

    def calibrate(self, lifetimes, outcomes):
        caught = [lifetimes[i] for i, o in enumerate(outcomes) if o == 1]
        missed = [lifetimes[i] for i, o in enumerate(outcomes) if o == 0]
        if not caught:
            self.threshold = LIFETIME_MAX
        elif not missed:
            self.threshold = LIFETIME_MIN
        else:
            self.threshold = (min(caught) + max(missed)) / 2.0
        rate = sum(outcomes) / len(outcomes)
        self.offset = (self.target_rate - 0.5) * self.window_width
        self._prev_error = rate - self.target_rate

    def update(self, catch_rate):
        error      = catch_rate - self.target_rate
        derivative = error - self._prev_error
        self._prev_error = error
        self._integral  += error
        correction = self.gain_i * self._integral + self.gain_d * derivative
        if abs(error) > DEAD_BAND:
            correction += self.gain_p * error
        half_w     = self.window_width * 0.5
        min_offset = LIFETIME_MIN - self.threshold + half_w
        max_offset = LIFETIME_MAX - self.threshold - half_w
        self.offset = float(np.clip(self.offset - correction, min_offset, max_offset))

    def get_window(self):
        center = self.threshold + self.offset
        half_w = self.window_width * 0.5
        lo = float(np.clip(center - half_w, LIFETIME_MIN, LIFETIME_MAX))
        hi = float(np.clip(center + half_w, LIFETIME_MIN, LIFETIME_MAX))
        return lo, hi


# ---------------------------------------------------------------------------
# Outcome generation — deterministic from a success rate
# ---------------------------------------------------------------------------

def make_outcomes(rate, n):
    """Return n binary outcomes with exactly round(rate*n) catches, evenly spaced."""
    n_caught = int(round(rate * n))
    # spread catches evenly across the apple sequence
    outcomes = [0] * n
    if n_caught > 0:
        positions = [int(round(i * (n - 1) / (n_caught - 1))) for i in range(n_caught)] \
                    if n_caught > 1 else [n // 2]
        for p in positions:
            outcomes[p] = 1
    return outcomes


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

def simulate(gain_p, gain_i, gain_d, window_width, target_rate,
             trial_rates, apples_per_trial, update_every):
    """
    trial_rates      — list of floats [0..1], one per trial (trial 1 = calibration)
    apples_per_trial — how many apples per trial
    update_every     — controller updates after every N apples using those N apples
                       (1 = per apple, apples_per_trial = per trial, same as before)

    Returns list of dicts, one per apple:
        {apple, trial, outcome, lo, hi, center, updated}
    """
    ctrl = PIDController(gain_p, gain_i, gain_d, window_width, target_rate)

    # Build full apple sequence
    all_outcomes = []
    apple_trial  = []
    for t_idx, rate in enumerate(trial_rates):
        outcomes = make_outcomes(rate, apples_per_trial)
        all_outcomes.extend(outcomes)
        apple_trial.extend([t_idx + 1] * apples_per_trial)

    results = []
    total   = len(all_outcomes)

    # Trial 1 — calibration using first apples_per_trial outcomes
    calib   = all_outcomes[:apples_per_trial]
    lts     = np.linspace(LIFETIME_MIN, LIFETIME_MAX, apples_per_trial)
    ctrl.calibrate(lts, calib)

    lo, hi = ctrl.get_window()
    for i in range(apples_per_trial):
        results.append({
            "apple":   i + 1,
            "trial":   1,
            "outcome": calib[i],
            "lo":      lo,
            "hi":      hi,
            "center":  (lo + hi) / 2.0,
            "updated": False,
        })

    # Trial 2+ — rolling correction every `update_every` apples
    window_buf = []
    apples_since_update = 0

    for idx in range(apples_per_trial, total):
        outcome = all_outcomes[idx]
        window_buf.append(outcome)
        apples_since_update += 1
        updated = False

        if apples_since_update >= update_every:
            rate = sum(window_buf[-update_every:]) / update_every
            ctrl.update(rate)
            apples_since_update = 0
            updated = True

        lo, hi = ctrl.get_window()
        results.append({
            "apple":   idx + 1,
            "trial":   apple_trial[idx],
            "outcome": outcome,
            "lo":      lo,
            "hi":      hi,
            "center":  (lo + hi) / 2.0,
            "updated": updated,
        })

    return results


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

BG       = "#1a1a2e"
PANEL_BG = "#16213e"
FG       = "#e0e0ff"
ENTRY_BG = "#0f3460"
BTN_BG   = "#27ae60"
BTN_FG   = "white"
ACCENT   = "#4a90d9"

DEFAULT_TRIAL_RATES = [1.0, 0.1, 0.1, 0.9, 0.9, 0.9]


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("PID Adaptive Difficulty Simulator")
        root.configure(bg=BG)
        root.resizable(True, True)
        self._build()
        root.update_idletasks()
        w, h = 1200, 680
        x = (root.winfo_screenwidth()  - w) // 2
        y = (root.winfo_screenheight() - h) // 2
        root.geometry(f"{w}x{h}+{x}+{y}")

    def _lbl(self, parent, text, size=10, bold=False, fg=FG):
        f = ("Segoe UI", size, "bold" if bold else "normal")
        return tk.Label(parent, text=text, bg=PANEL_BG, fg=fg, font=f)

    def _entry(self, parent, default, width=7):
        e = tk.Entry(parent, width=width, bg=ENTRY_BG, fg=FG,
                     insertbackground=FG, relief="flat",
                     font=("Segoe UI", 10))
        e.insert(0, str(default))
        return e

    def _build(self):
        # ── Left control panel ──────────────────────────────────────────
        left = tk.Frame(self.root, bg=PANEL_BG, width=250)
        left.pack(side="left", fill="y", padx=(8, 4), pady=8)
        left.pack_propagate(False)

        # Controller gains
        self._lbl(left, "CONTROLLER GAINS", bold=True, fg=ACCENT).pack(anchor="w", pady=(10, 4))
        params = [
            ("Kp",  "0.35"),
            ("Ki",  "0.05"),
            ("Kd",  "0.00"),
        ]
        self._entries = {}
        for label, default in params:
            row = tk.Frame(left, bg=PANEL_BG)
            row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6)
            e.pack(side="right")
            self._entries[label] = e

        tk.Frame(left, bg="#333355", height=1).pack(fill="x", pady=8)

        # Other settings
        self._lbl(left, "OTHER SETTINGS", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 4))
        settings = [
            ("Lifetime spread (s)",   "2.4"),
            ("Target success rate",   "0.80"),
            ("Apples per trial",      "20"),
        ]
        for label, default in settings:
            row = tk.Frame(left, bg=PANEL_BG)
            row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6)
            e.pack(side="right")
            self._entries[label] = e

        tk.Frame(left, bg="#333355", height=1).pack(fill="x", pady=8)

        # Update frequency — the key new control
        self._lbl(left, "UPDATE FREQUENCY", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 2))
        self._lbl(left, "Correct after every N apples.\n1 = per apple   20 = per trial",
                  size=8, fg="#8888aa").pack(anchor="w", pady=(0, 6))
        row = tk.Frame(left, bg=PANEL_BG)
        row.pack(fill="x", pady=2)
        self._lbl(row, "N apples per update", size=9).pack(side="left")
        e = self._entry(row, "20", width=6)
        e.pack(side="right")
        self._entries["N apples per update"] = e

        tk.Frame(left, bg="#333355", height=1).pack(fill="x", pady=8)

        # Per-trial success rates
        self._lbl(left, "SUCCESS RATE PER TRIAL", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 2))
        self._lbl(left, "(Trial 1 = calibration)", size=8, fg="#8888aa").pack(anchor="w", pady=(0, 4))

        self._trial_frame = tk.Frame(left, bg=PANEL_BG)
        self._trial_frame.pack(fill="x")
        self._trial_entries = []
        for r in DEFAULT_TRIAL_RATES:
            self._add_trial_row(r)

        btn_row = tk.Frame(left, bg=PANEL_BG)
        btn_row.pack(fill="x", pady=(6, 0))
        tk.Button(btn_row, text="+ Add trial", bg="#1a5276", fg=FG,
                  font=("Segoe UI", 9), relief="flat",
                  command=self._add_trial).pack(side="left", padx=(0, 4))
        tk.Button(btn_row, text="− Remove", bg="#641e16", fg=FG,
                  font=("Segoe UI", 9), relief="flat",
                  command=self._remove_trial).pack(side="left")

        tk.Frame(left, bg="#333355", height=1).pack(fill="x", pady=10)

        tk.Button(left, text="▶  RUN SIMULATION", bg=BTN_BG, fg=BTN_FG,
                  font=("Segoe UI", 11, "bold"), relief="flat",
                  cursor="hand2", command=self._run).pack(fill="x", ipady=8)

        self._err_lbl = tk.Label(left, text="", bg=PANEL_BG, fg="#e74c3c",
                                 font=("Segoe UI", 9), wraplength=230)
        self._err_lbl.pack(pady=(4, 0))

        # ── Right graph panel ───────────────────────────────────────────
        right = tk.Frame(self.root, bg=BG)
        right.pack(side="left", fill="both", expand=True, padx=(4, 8), pady=8)

        self._fig = Figure(facecolor=BG)
        self._ax_lt = self._fig.add_subplot(211)
        self._ax_sr = self._fig.add_subplot(212)
        self._fig.subplots_adjust(hspace=0.45, left=0.08, right=0.97, top=0.93, bottom=0.10)
        self._style_ax(self._ax_lt)
        self._style_ax(self._ax_sr)
        self._draw_empty()

        canvas = FigureCanvasTkAgg(self._fig, master=right)
        canvas.draw()
        canvas.get_tk_widget().pack(fill="both", expand=True)
        self._canvas = canvas

    def _add_trial_row(self, default=0.8):
        n   = len(self._trial_entries) + 1
        row = tk.Frame(self._trial_frame, bg=PANEL_BG)
        row.pack(fill="x", pady=1)
        self._lbl(row, f"Trial {n}:", size=9).pack(side="left")
        e = self._entry(row, default, width=5)
        e.pack(side="right")
        self._trial_entries.append((row, e))

    def _add_trial(self):
        self._add_trial_row(0.8)

    def _remove_trial(self):
        if len(self._trial_entries) <= 1:
            return
        row, _ = self._trial_entries.pop()
        row.destroy()

    def _style_ax(self, ax):
        ax.set_facecolor(PANEL_BG)
        ax.tick_params(colors=FG, labelsize=8)
        for spine in ax.spines.values():
            spine.set_edgecolor("#444466")

    def _draw_empty(self):
        for ax in [self._ax_lt, self._ax_sr]:
            ax.clear()
            self._style_ax(ax)
            ax.text(0.5, 0.5, "Press  ▶ RUN  to simulate",
                    transform=ax.transAxes, ha="center", va="center",
                    color="#666688", fontsize=11)
        self._ax_lt.set_title("Apple lifetime window per apple", color=FG, fontsize=10)
        self._ax_sr.set_title("Success rate (rolling window)",   color=FG, fontsize=10)

    def _run(self):
        self._err_lbl.config(text="")
        try:
            gain_p          = float(self._entries["Kp"].get())
            gain_i          = float(self._entries["Ki"].get())
            gain_d          = float(self._entries["Kd"].get())
            window_width    = float(self._entries["Lifetime spread (s)"].get())
            target_rate     = float(self._entries["Target success rate"].get())
            apples_per_trial = int(self._entries["Apples per trial"].get())
            update_every    = int(self._entries["N apples per update"].get())
            if update_every < 1:
                raise ValueError("N apples per update must be ≥ 1")
            trial_rates = []
            for _, e in self._trial_entries:
                v = float(e.get())
                if not (0.0 <= v <= 1.0):
                    raise ValueError(f"Success rate must be 0–1, got {v}")
                trial_rates.append(v)
        except ValueError as ex:
            self._err_lbl.config(text=f"Input error: {ex}")
            return

        results = simulate(gain_p, gain_i, gain_d, window_width, target_rate,
                           trial_rates, apples_per_trial, update_every)
        self._plot(results, target_rate, apples_per_trial, update_every)

    def _plot(self, results, target_rate, apples_per_trial, update_every):
        apples  = [r["apple"]   for r in results]
        centers = [r["center"]  for r in results]
        lo      = [r["lo"]      for r in results]
        hi      = [r["hi"]      for r in results]
        # Rolling success rate — same window as the controller uses
        rolling_rates = []
        buf = []
        for r in results:
            buf.append(r["outcome"])
            window = buf[-update_every:] if len(buf) >= update_every else buf
            rolling_rates.append(sum(window) / len(window))

        n_trials = max(r["trial"] for r in results)
        trial_boundaries = [apples_per_trial * t for t in range(1, n_trials)]

        # ── Graph 1: lifetime window ────────────────────────────────────
        ax = self._ax_lt
        ax.clear()
        self._style_ax(ax)
        ax.fill_between(apples, lo, hi, alpha=0.25, color=ACCENT)
        ax.plot(apples, centers, "-", color=ACCENT, linewidth=1.5, label="Window centre")
        ax.plot(apples, lo, "-", color=ACCENT, alpha=0.5, linewidth=0.8)
        ax.plot(apples, hi, "-", color=ACCENT, alpha=0.5, linewidth=0.8)

        # Mark correction points
        update_apples  = [r["apple"] for r in results if r["updated"]]
        update_centers = [r["center"] for r in results if r["updated"]]
        if update_apples:
            ax.plot(update_apples, update_centers, "|", color="#f39c12",
                    markersize=8, markeredgewidth=1.2, label=f"Correction (every {update_every})")

        for tb in trial_boundaries:
            ax.axvline(tb, color="#666688", linestyle=":", linewidth=0.8)

        ax.set_xlim(0.5, apples[-1] + 0.5)
        ax.set_ylim(LIFETIME_MIN - 0.5, LIFETIME_MAX + 0.5)
        ax.set_xlabel("Apple number", color=FG, fontsize=9)
        ax.set_ylabel("Apple lifetime (s)", color=FG, fontsize=9)
        ax.set_title(f"Apple lifetime window  (correction every {update_every} apples)",
                     color=FG, fontsize=10)
        ax.legend(fontsize=8, facecolor=PANEL_BG, labelcolor=FG, framealpha=0.8)

        # ── Graph 2: rolling success rate ───────────────────────────────
        ax = self._ax_sr
        ax.clear()
        self._style_ax(ax)
        ax.plot(apples, rolling_rates, "-", color="#f39c12", linewidth=1.5,
                label=f"Rolling rate (N={update_every})")
        ax.axhline(target_rate, color="#e74c3c", linestyle="--",
                   linewidth=1.5, label=f"Target  {target_rate:.0%}")

        for tb in trial_boundaries:
            ax.axvline(tb, color="#666688", linestyle=":", linewidth=0.8,
                       label="Trial boundary" if tb == trial_boundaries[0] else "")

        ax.set_xlim(0.5, apples[-1] + 0.5)
        ax.set_ylim(-0.05, 1.05)
        ax.set_xlabel("Apple number", color=FG, fontsize=9)
        ax.set_ylabel("Success rate", color=FG, fontsize=9)
        ax.set_title("Rolling success rate", color=FG, fontsize=10)
        ax.yaxis.set_major_formatter(
            matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:.0%}"))
        ax.legend(fontsize=8, facecolor=PANEL_BG, labelcolor=FG, framealpha=0.8)

        self._canvas.draw()


# ---------------------------------------------------------------------------

root = tk.Tk()
app  = App(root)
root.mainloop()
