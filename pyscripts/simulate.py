"""
simulate.py — PID Adaptive Difficulty Simulator

Healthy user model. r = distance / (lifetime × speed).
Catch if r < 1, miss if r >= 1. Controller adjusts r directly.

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

R_MIN     = 0.05
R_MAX     = 2.00
DEAD_BAND = 0.05


# ---------------------------------------------------------------------------
# Controller — works in r-space
# ---------------------------------------------------------------------------

class PIDController:
    def __init__(self, gain_p, gain_i, gain_d, window_width, target_rate):
        self.gain_p       = gain_p
        self.gain_i       = gain_i
        self.gain_d       = gain_d
        self.window_width = window_width
        self.target_rate  = target_rate
        # place window so target_rate fraction is below r=1 from trial 1
        self.r_center     = 1.0 + window_width * (0.5 - target_rate)
        self._integral    = 0.0
        self._prev_error  = 0.0

    def update(self, catch_rate):
        error      = catch_rate - self.target_rate
        derivative = error - self._prev_error
        self._prev_error = error
        self._integral  += error
        correction = self.gain_i * self._integral + self.gain_d * derivative
        if abs(error) > DEAD_BAND:
            correction += self.gain_p * error
        half_w = self.window_width * 0.5
        self.r_center = float(np.clip(
            self.r_center + correction,
            R_MIN + half_w,
            R_MAX - half_w,
        ))

    def get_window(self):
        half_w = self.window_width * 0.5
        lo = float(np.clip(self.r_center - half_w, R_MIN, R_MAX))
        hi = float(np.clip(self.r_center + half_w, R_MIN, R_MAX))
        return lo, hi


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

def simulate(gain_p, gain_i, gain_d, window_width, target_rate,
             estimated_speed, actual_speed, workspace_radius, n_trials, trial_time):
    """
    Deterministic simulation. No random sampling.
    The controller sets window [lo, hi] using estimated_speed.
    Actual catch rate = fraction of that window where r < actual_speed/estimated_speed.
    PID sees this catch rate and adjusts the window each trial.
    """
    ctrl      = PIDController(gain_p, gain_i, gain_d, window_width, target_rate)
    threshold = actual_speed / max(estimated_speed, 1e-6)
    results   = []

    for t_idx in range(n_trials):
        lo, hi = ctrl.get_window()

        span       = max(hi - lo, 1e-9)
        catch_rate = float(np.clip((threshold - lo) / span, 0.0, 1.0))

        avg_r    = (lo + hi) / 2.0
        avg_lt   = (workspace_radius / 2.0) / max(avg_r * estimated_speed, 1e-6)
        n_apples = max(1, int(trial_time / max(avg_lt, 1e-6)))

        ctrl.update(catch_rate)
        lo2, hi2 = ctrl.get_window()

        results.append({
            "trial":      t_idx + 1,
            "catch_rate": catch_rate,
            "lo":         lo2,
            "hi":         hi2,
            "center":     (lo2 + hi2) / 2.0,
            "n_apples":   n_apples,
            "threshold":  threshold,
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


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("PID Adaptive Difficulty Simulator")
        root.configure(bg=BG)
        root.resizable(True, True)
        self._build()
        root.update_idletasks()
        w, h = 1150, 580
        x = (root.winfo_screenwidth()  - w) // 2
        y = (root.winfo_screenheight() - h) // 2
        root.geometry(f"{w}x{h}+{x}+{y}")

    def _lbl(self, parent, text, size=10, bold=False, fg=FG):
        return tk.Label(parent, text=text, bg=PANEL_BG, fg=fg,
                        font=("Segoe UI", size, "bold" if bold else "normal"))

    def _entry(self, parent, default, width=7):
        e = tk.Entry(parent, width=width, bg=ENTRY_BG, fg=FG,
                     insertbackground=FG, relief="flat", font=("Segoe UI", 10))
        e.insert(0, str(default))
        return e

    def _sep(self, parent):
        tk.Frame(parent, bg="#333355", height=1).pack(fill="x", pady=8)

    def _build(self):
        left = tk.Frame(self.root, bg=PANEL_BG, width=240)
        left.pack(side="left", fill="y", padx=(8, 4), pady=8)
        left.pack_propagate(False)

        self._entries = {}

        # Controller gains
        self._lbl(left, "CONTROLLER GAINS", bold=True, fg=ACCENT).pack(anchor="w", pady=(10, 4))
        for label, default in [("Kp", "0.35"), ("Ki", "0.05"), ("Kd", "0.00")]:
            row = tk.Frame(left, bg=PANEL_BG); row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6); e.pack(side="right")
            self._entries[label] = e

        self._sep(left)

        # Difficulty
        self._lbl(left, "DIFFICULTY", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 4))
        for label, default in [
            ("Target success rate", "0.70"),
            ("r window width",      "0.40"),
        ]:
            row = tk.Frame(left, bg=PANEL_BG); row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6); e.pack(side="right")
            self._entries[label] = e

        self._sep(left)

        # Trial settings
        self._lbl(left, "TRIAL SETTINGS", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 4))
        for label, default in [
            ("N trials",       "15"),
            ("Trial time (s)", "60"),
        ]:
            row = tk.Frame(left, bg=PANEL_BG); row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6); e.pack(side="right")
            self._entries[label] = e

        self._sep(left)

        # Patient
        self._lbl(left, "PATIENT", bold=True, fg=ACCENT).pack(anchor="w", pady=(0, 4))
        for label, default in [
            ("Estimated speed (px/s)", "300"),
            ("Actual speed (px/s)",    "300"),
            ("Workspace radius (px)",  "400"),
        ]:
            row = tk.Frame(left, bg=PANEL_BG); row.pack(fill="x", pady=2)
            self._lbl(row, label, size=9).pack(side="left")
            e = self._entry(row, default, width=6); e.pack(side="right")
            self._entries[label] = e

        self._sep(left)

        tk.Button(left, text="▶  RUN SIMULATION", bg=BTN_BG, fg=BTN_FG,
                  font=("Segoe UI", 11, "bold"), relief="flat",
                  cursor="hand2", command=self._run).pack(fill="x", ipady=8)

        self._err_lbl = tk.Label(left, text="", bg=PANEL_BG, fg="#e74c3c",
                                 font=("Segoe UI", 9), wraplength=225)
        self._err_lbl.pack(pady=(4, 0))

        self._stat_lbl = tk.Label(left, text="", bg=PANEL_BG, fg="#8888aa",
                                  font=("Segoe UI", 8), wraplength=225)
        self._stat_lbl.pack(pady=(2, 0))

        right = tk.Frame(self.root, bg=BG)
        right.pack(side="left", fill="both", expand=True, padx=(4, 8), pady=8)

        self._fig = Figure(facecolor=BG)
        canvas = FigureCanvasTkAgg(self._fig, master=right)
        canvas.draw()
        canvas.get_tk_widget().pack(fill="both", expand=True)
        self._canvas = canvas

        self._draw_empty()

    def _style_ax(self, ax):
        ax.set_facecolor(PANEL_BG)
        ax.tick_params(colors=FG, labelsize=8)
        for spine in ax.spines.values():
            spine.set_edgecolor("#444466")

    def _draw_empty(self):
        self._fig.clear()
        ax = self._fig.add_subplot(111)
        self._style_ax(ax)
        ax.text(0.5, 0.5, "Press  ▶ RUN  to simulate",
                transform=ax.transAxes, ha="center", va="center",
                color="#666688", fontsize=13)
        self._canvas.draw()

    def _run(self):
        self._err_lbl.config(text="")
        self._stat_lbl.config(text="")
        try:
            gain_p           = float(self._entries["Kp"].get())
            gain_i           = float(self._entries["Ki"].get())
            gain_d           = float(self._entries["Kd"].get())
            target_rate      = float(self._entries["Target success rate"].get())
            window_width     = float(self._entries["r window width"].get())
            n_trials         = int(self._entries["N trials"].get())
            trial_time       = float(self._entries["Trial time (s)"].get())
            estimated_speed  = float(self._entries["Estimated speed (px/s)"].get())
            actual_speed     = float(self._entries["Actual speed (px/s)"].get())
            workspace_radius = float(self._entries["Workspace radius (px)"].get())
            if n_trials < 1:
                raise ValueError("N trials must be ≥ 1")
            if estimated_speed <= 0 or actual_speed <= 0:
                raise ValueError("Speed must be > 0")
            if window_width <= 0:
                raise ValueError("r window width must be > 0")
            if trial_time <= 0:
                raise ValueError("Trial time must be > 0")
            if not (0.0 < target_rate < 1.0):
                raise ValueError("Target success rate must be in (0, 1)")
        except ValueError as ex:
            self._err_lbl.config(text=f"Input error: {ex}")
            return

        results = simulate(gain_p, gain_i, gain_d, window_width, target_rate,
                           estimated_speed, actual_speed, workspace_radius, n_trials, trial_time)

        total_apples = sum(r["n_apples"] for r in results)
        avg_apples   = total_apples / len(results) if results else 0
        self._stat_lbl.config(
            text=f"Total apples: {total_apples}   Avg/trial: {avg_apples:.1f}"
        )
        self._plot(results, target_rate)

    def _plot(self, results, target_rate):
        trials  = [r["trial"]      for r in results]
        rates   = [r["catch_rate"] for r in results]
        centers = [r["center"]     for r in results]
        lo      = [r["lo"]         for r in results]
        hi      = [r["hi"]         for r in results]

        self._fig.clear()
        ax_r  = self._fig.add_subplot(211)
        ax_sr = self._fig.add_subplot(212)
        self._fig.subplots_adjust(
            hspace=0.50, left=0.09, right=0.97, top=0.93, bottom=0.10)

        # ── Graph 1: r window per trial ─────────────────────────────────
        ax = ax_r
        self._style_ax(ax)
        ax.fill_between(trials, lo, hi, alpha=0.25, color=ACCENT)
        ax.plot(trials, centers, "-o", color=ACCENT,
                linewidth=1.5, markersize=4, label="r window centre")
        ax.plot(trials, lo, "-", color=ACCENT, alpha=0.5, linewidth=0.8)
        ax.plot(trials, hi, "-", color=ACCENT, alpha=0.5, linewidth=0.8)
        threshold = results[0]["threshold"]
        ax.axhline(1.0, color="#444466", linestyle="--",
                   linewidth=1.0, label="r = 1  (controller's assumed boundary)")
        ax.axhline(threshold, color="#e74c3c", linestyle="--",
                   linewidth=1.5, label=f"r = {threshold:.2f}  (actual catch boundary)")
        ax.set_xlim(0.5, trials[-1] + 0.5)
        ax.set_ylim(R_MIN - 0.1, R_MAX + 0.1)
        ax.set_xlabel("Trial", color=FG, fontsize=9)
        ax.set_ylabel("r", color=FG, fontsize=9)
        ax.set_title("Difficulty ratio r window per trial", color=FG, fontsize=10)
        ax.legend(fontsize=8, facecolor=PANEL_BG, labelcolor=FG, framealpha=0.8)
        ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))

        # ── Graph 2: catch rate per trial ───────────────────────────────
        ax = ax_sr
        self._style_ax(ax)
        ax.plot(trials, rates, "-o", color="#f39c12",
                linewidth=1.5, markersize=4, label="Catch rate")
        ax.axhline(target_rate, color="#e74c3c", linestyle="--",
                   linewidth=1.5, label=f"Target  {target_rate:.0%}")
        ax.set_xlim(0.5, trials[-1] + 0.5)
        ax.set_ylim(-0.05, 1.05)
        ax.set_xlabel("Trial", color=FG, fontsize=9)
        ax.set_ylabel("Catch rate", color=FG, fontsize=9)
        ax.set_title("Per-trial catch rate", color=FG, fontsize=10)
        ax.yaxis.set_major_formatter(
            matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:.0%}"))
        ax.legend(fontsize=8, facecolor=PANEL_BG, labelcolor=FG, framealpha=0.8)
        ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))

        self._canvas.draw()


# ---------------------------------------------------------------------------

root = tk.Tk()
app  = App(root)
root.mainloop()
