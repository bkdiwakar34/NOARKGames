extends RefCounted

# One visit's files (docs/clinic_study_interface.md §4.9, Data page), in
#     ~/Documents/NOARK/clinic/<participant ID>/<start time>/
# kept apart from the patient app's NOARK/data. Target rows are flushed as they
# are written, hand rows once per frame, so a power cut loses at most one frame.
#   targets.csv — one row per apple
#   hand.csv    — every tracker sample (~100 Hz); none in mouse-fallback mode
#   reach.csv   — the reach scan, one row per spoke
# All start with the same key,value header; the first line says how many.

const TARGET_COLUMNS: Array = [
	"phase", "round", "apple", "pair", "a_mm", "w_mm", "a_actual_mm", "angle_deg",
	"start_x_mm", "start_y_mm", "target_x_mm", "target_y_mm",
	"spawn_time", "hold_start_time", "outcome", "outcome_time", "mt_s", "points",
]
const HAND_COLUMNS: Array = [
	"epochtime", "capture_time", "phase", "round",
	"hand_x_mm", "hand_y_mm", "tracker_x", "tracker_y", "tracker_z",
]
const REACH_COLUMNS: Array = [
	"spoke", "angle_deg", "reach_mm", "edge_x_mm", "edge_y_mm", "light_mm", "limited_by",
]

var folder: String = ""
var _targets: FileAccess = null
var _hand: FileAccess = null
var _reach: FileAccess = null


# header: Array of "key,value" lines. Returns false if a file could not be made.
func open(participant_id: String, header: Array) -> bool:
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	folder = "%s/NOARK/clinic/%s/%s" % [
		OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS), participant_id, stamp]
	DirAccess.make_dir_recursive_absolute(folder)
	_targets = _open_csv("targets.csv", header, TARGET_COLUMNS)
	_hand = _open_csv("hand.csv", header, HAND_COLUMNS)
	_reach = _open_csv("reach.csv", header, REACH_COLUMNS)
	return _targets != null and _hand != null and _reach != null


func _open_csv(file_name: String, header: Array, columns: Array) -> FileAccess:
	var f := FileAccess.open(folder + "/" + file_name, FileAccess.WRITE)
	if f == null:
		push_error("Could not create " + folder + "/" + file_name)
		return null
	f.store_line("headerrows,%d" % (header.size() + 2))
	for line in header:
		f.store_line(line)
	f.store_line("start_time,%s" % Time.get_datetime_string_from_system())
	f.store_csv_line(PackedStringArray(columns))
	f.flush()
	return f


func log_target(row: Array) -> void:
	_write(_targets, [row])


# One frame's worth of hand rows, flushed together.
func log_hand(rows: Array) -> void:
	_write(_hand, rows)


func log_reach(rows: Array) -> void:
	_write(_reach, rows)


func _write(f: FileAccess, rows: Array) -> void:
	if f == null or rows.is_empty():
		return
	for row in rows:
		var out := PackedStringArray()
		for v in row:
			out.append(str(v))
		f.store_csv_line(out)
	f.flush()


func close() -> void:
	if _targets:
		_targets.close()
		_targets = null
	if _hand:
		_hand.close()
		_hand = null
	if _reach:
		_reach.close()
		_reach = null
