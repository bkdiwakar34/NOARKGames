"""
Simulation: P-only vs PI controller for adaptive difficulty.
Patient has a sigmoid performance curve (not a perfect step function).
Run: python pid_sim.py
"""
import numpy as np
import matplotlib.pyplot as plt

# --- Patient model ---
# P(catch | lifetime) — sigmoid centered at T_ACTUAL (patient's true 50% threshold)
# Algorithm does NOT know T_ACTUAL. It has to discover the right threshold.
T_ACTUAL = 2.5     # patient catches 50% of apples at this lifetime
STEEPNESS = 1.5    # how sharp the sigmoid is (higher = sharper, more step-like)

def patient_catch_prob(lifetime):
    return 1 / (1 + np.exp(-STEEPNESS * (lifetime - T_ACTUAL)))

# --- Game constants ---
LT_MIN = 0.1
LT_MAX = 8.0
TARGET_RATE = 0.70
DEAD_BAND = 0.05
N_TRIALS = 20
N_APPLES = 25      # apples per trial

def run(gain_p, gain_i, label, seed=42):
    rng = np.random.default_rng(seed)
    difficulty = 0.5
    integral = 0.0
    rates = []
    thresholds = []

    for _ in range(N_TRIALS):
        threshold = LT_MAX - difficulty * (LT_MAX - LT_MIN)
        thresholds.append(threshold)

        # Sample apples: TARGET_RATE% easy (above threshold), rest hard (below)
        lifetimes = []
        for _ in range(N_APPLES):
            if rng.random() < TARGET_RATE:
                lt = rng.uniform(threshold, LT_MAX)
            else:
                lt = rng.uniform(LT_MIN, threshold)
            lifetimes.append(lt)

        # Patient catches each apple probabilistically (sigmoid, not step function)
        catches = sum(rng.random() < patient_catch_prob(lt) for lt in lifetimes)
        rate = catches / N_APPLES
        rates.append(rate)

        # Control update — only outside dead band for P; I always accumulates
        error = rate - TARGET_RATE
        integral += error
        correction = gain_i * integral
        if abs(error) > DEAD_BAND:
            correction += gain_p * error
        difficulty = float(np.clip(difficulty + correction, 0.0, 1.0))

    return rates, thresholds

rates_p,  thresh_p  = run(gain_p=0.15, gain_i=0.00, label="P only")
rates_pi, thresh_pi = run(gain_p=0.15, gain_i=0.02, label="PI")

# --- Plot ---
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 8), sharex=True)
trials = range(1, N_TRIALS + 1)

ax1.plot(trials, [r * 100 for r in rates_p],  'b-o', label='P only', alpha=0.8)
ax1.plot(trials, [r * 100 for r in rates_pi], 'r-o', label='PI',     alpha=0.8)
ax1.axhline(TARGET_RATE * 100, color='green', linestyle='--', linewidth=1.5, label=f'Target {int(TARGET_RATE*100)}%')
ax1.axhspan((TARGET_RATE - DEAD_BAND) * 100, (TARGET_RATE + DEAD_BAND) * 100,
            alpha=0.12, color='green', label='±5% dead band')
ax1.set_ylabel('Success rate (%)')
ax1.set_title('Success rate per trial: P-only vs PI')
ax1.legend(loc='upper right')
ax1.set_ylim(20, 110)
ax1.grid(alpha=0.3)

ax2.plot(trials, thresh_p,  'b-o', label='P only threshold', alpha=0.8)
ax2.plot(trials, thresh_pi, 'r-o', label='PI threshold',     alpha=0.8)
ax2.axhline(T_ACTUAL, color='gray', linestyle=':', linewidth=1.5,
            label=f'True patient threshold {T_ACTUAL}s (unknown to algorithm)')
ax2.set_xlabel('Trial number')
ax2.set_ylabel('Threshold lifetime (s)')
ax2.set_title('How the algorithm adjusts the threshold over time')
ax2.legend(loc='upper right')
ax2.grid(alpha=0.3)

plt.tight_layout()
plt.savefig('pid_comparison.png', dpi=150)
plt.show()

# Summary
print(f"\nPatient true threshold: {T_ACTUAL}s  |  Target success rate: {TARGET_RATE:.0%}")
print(f"P-only  — mean rate (last 10 trials): {np.mean(rates_p[-10:]):.1%}")
print(f"PI      — mean rate (last 10 trials): {np.mean(rates_pi[-10:]):.1%}")
