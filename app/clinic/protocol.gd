# Clinic study protocol values (docs/clinic_study_interface.md).
# DRAFT: the pairs and point limits are placeholders until the pilot
# (spec §6). The Settings page and the protocol lock come in a later
# package; until then this file is the only copy.
# Consumers use:  const Protocol := preload("res://app/clinic/protocol.gd")

const VERSION := "draft-1"

# The three target pairs, fixed for everyone, in table millimetres (spec §3.1).
const PAIRS: Array = [
	{"a_mm": 150.0, "w_mm": 60.0},
	{"a_mm": 300.0, "w_mm": 40.0},
	{"a_mm": 450.0, "w_mm": 25.0},
]

const HOLD_S := 1.0          # unbroken time inside the circle that counts as a catch
const ROUND_S := 60.0
const REST_S := 15.0
const WARMUP_ROUNDS := 1     # played like calibration, not counted
const CALIB_ROUNDS := 5

# Calibration speed points (spec §4.4). An apple waits up to POINT_CAP_S of
# movement time; the hold comes on top, so it expires at spawn + cap + hold.
const POINT_CAP_S := 8.0
const POINT_LIMITS_S: Array = [1.0, 2.0]   # MT < 1.0 s -> 3 points, < 2.0 s -> 2, else 1


static func points_for(mt: float) -> int:
	if mt < POINT_LIMITS_S[0]:
		return 3
	if mt < POINT_LIMITS_S[1]:
		return 2
	return 1


static func id_bits(a_mm: float, w_mm: float) -> float:
	return log(a_mm / w_mm + 1.0) / log(2.0)
