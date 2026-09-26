# Lifetime rule (docs/clinic_study_interface.md §3.2). For each pair, sort that
# day's calibration movement times and take the p-th one:
#     lifetime = t_(ceil(p * n))
# In play a hold must start within the lifetime, so an apple is caught exactly
# when the movement is no slower than that value (§3.3).
#
# Calibration timeouts count as slower than every catch: they sit at the top of
# the sorted list. Dropping them would keep only the fast movements and make
# the lifetime too short. If the p-th value falls among the timeouts, the
# lifetime is the cap they were cut at.
# Consumers use:  const Difficulty := preload("res://app/clinic/difficulty.gd")

const Protocol := preload("res://app/clinic/protocol.gd")


# mts: movement times (s) of the pair's caught calibration apples; timeouts: how
# many timed out. Returns -1 when the pair has no calibration apples at all.
static func lifetime(mts: Array, timeouts: int, p: float) -> float:
	var n := mts.size() + timeouts
	if n == 0:
		return -1.0
	var sorted := mts.duplicate()
	sorted.sort()
	var rank := clampi(ceili(p * float(n)), 1, n)   # 1-based position in the sorted list
	if rank > sorted.size():
		return Protocol.POINT_CAP_S
	return sorted[rank - 1]
