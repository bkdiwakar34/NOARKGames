# Clinic study protocol (docs/clinic_study_interface.md §4.9, Settings -> Protocol).
# The editable values are static vars: the defaults below, overridden by
# protocol.json in the clinic data folder (load_saved, at startup). Saving a
# change bumps VERSION; once LOCKED the Settings page makes them read-only.
# Every visit file carries the version (round_runner.gd header).
# DRAFT: pairs, levels and point limits are placeholders until the pilot (spec §6).
# Consumers use:  const Protocol := preload("res://app/clinic/protocol.gd")

const FILE_NAME := "protocol.json"

static var VERSION: int = 1
static var LOCKED: bool = false

# The three levels: percentile p of each pair's calibration movement times,
# the same for everyone; each participant plays them in their own order (spec §1).
static var LEVELS: Array = [0.60, 0.75, 0.90]

# The three target pairs, fixed for everyone, in table millimetres (spec §3.1).
static var PAIRS: Array = [
	{"a_mm": 150.0, "w_mm": 60.0},
	{"a_mm": 300.0, "w_mm": 40.0},
	{"a_mm": 450.0, "w_mm": 25.0},
]

static var HOLD_S: float = 1.0       # unbroken time inside the circle that counts as a catch
static var ROUND_S: float = 60.0
static var REST_S: float = 15.0
static var CALIB_ROUNDS: int = 5
static var PLAY_ROUNDS: int = 15

# Calibration speed points (spec §4.4). A hold must start within POINT_CAP_S
# of the spawn (round_runner.gd).
static var POINT_CAP_S: float = 8.0
static var POINT_LIMITS_S: Array = [1.0, 2.0]   # MT < 1.0 s -> 3 points, < 2.0 s -> 2, else 1

# Reach scan (spec §4.3): a light glides from the centre ring to the screen
# edge along each spoke, waits, and comes back.
static var REACH_SPEED_MM_S: float = 150.0
static var REACH_WAIT_S: float = 1.0

# Fixed, not in Settings.
const WARMUP_ROUNDS := 1     # played like calibration, not counted
const REACH_SPOKES := 8

# Quick test (Settings -> Mode): a short visit for checking the app. It still
# counts as a study day; the visit header says quick_test,true.
const QUICK_CALIB_ROUNDS := 2
const QUICK_PLAY_ROUNDS := 3
const QUICK_REST_S := 5.0


static func data_dir() -> String:
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK/clinic"


static func points_for(mt: float) -> int:
	if mt < float(POINT_LIMITS_S[0]):
		return 3
	if mt < float(POINT_LIMITS_S[1]):
		return 2
	return 1


static func id_bits(a_mm: float, w_mm: float) -> float:
	return log(a_mm / w_mm + 1.0) / log(2.0)


# The editable values as one dictionary (Settings page, protocol.json).
static func values() -> Dictionary:
	return {
		"levels": LEVELS.duplicate(), "pairs": PAIRS.duplicate(true),
		"hold_s": HOLD_S, "round_s": ROUND_S, "rest_s": REST_S,
		"calib_rounds": CALIB_ROUNDS, "play_rounds": PLAY_ROUNDS,
		"point_cap_s": POINT_CAP_S, "point_limits_s": POINT_LIMITS_S.duplicate(),
		"reach_speed_mm_s": REACH_SPEED_MM_S, "reach_wait_s": REACH_WAIT_S,
	}


static func _apply(v: Dictionary) -> void:
	LEVELS = v.get("levels", LEVELS)
	PAIRS = v.get("pairs", PAIRS)
	HOLD_S = float(v.get("hold_s", HOLD_S))
	ROUND_S = float(v.get("round_s", ROUND_S))
	REST_S = float(v.get("rest_s", REST_S))
	CALIB_ROUNDS = int(v.get("calib_rounds", CALIB_ROUNDS))
	PLAY_ROUNDS = int(v.get("play_rounds", PLAY_ROUNDS))
	POINT_CAP_S = float(v.get("point_cap_s", POINT_CAP_S))
	POINT_LIMITS_S = v.get("point_limits_s", POINT_LIMITS_S)
	REACH_SPEED_MM_S = float(v.get("reach_speed_mm_s", REACH_SPEED_MM_S))
	REACH_WAIT_S = float(v.get("reach_wait_s", REACH_WAIT_S))


static func load_saved() -> void:
	var path := data_dir() + "/" + FILE_NAME
	if not FileAccess.file_exists(path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		push_error("Unreadable " + path + " — using the defaults")
		return
	VERSION = int(d.get("version", VERSION))
	LOCKED = bool(d.get("locked", LOCKED))
	_apply(d.get("values", {}))


# New values from the Settings page. Refused while locked; a real change bumps
# the version so files before and after it can be told apart.
static func save_values(v: Dictionary) -> bool:
	if LOCKED:
		return false
	if JSON.stringify(v) != JSON.stringify(values()):
		_apply(v)
		VERSION += 1
	_write()
	return true


static func set_locked(on: bool) -> void:
	LOCKED = on
	_write()


static func _write() -> void:
	DirAccess.make_dir_recursive_absolute(data_dir())
	var path := data_dir() + "/" + FILE_NAME
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		push_error("Could not write " + path)
		return
	f.store_string(JSON.stringify({"version": VERSION, "locked": LOCKED, "values": values()}, "\t"))
	f.close()
	DirAccess.rename_absolute(path + ".tmp", path)   # replace in one step: no half-written file
