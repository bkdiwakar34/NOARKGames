extends Node

var session_id: int = 1
var current_date: String = ""
var trial_counts: Dictionary = {}

func _ready() -> void:
	current_date = get_date_string()
	_load()

func get_date_string() -> String:
	var t = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [t.year, t.month, t.day]

func start_new_session_if_needed() -> void:
	var today = get_date_string()
	if today != current_date:
		current_date = today
		session_id = 1
		trial_counts.clear()
	else:
		session_id += 1
		trial_counts.clear()
	_save()

func get_next_trial_id(game_name: String) -> int:
	trial_counts[game_name] = trial_counts.get(game_name, 0) + 1
	_save()
	return trial_counts[game_name]

func create_log_file(game_name: String, patient_id: String) -> FileAccess:
	var base_path = GlobalSignals.data_path + "/" + patient_id + "/GameData"
	if not DirAccess.dir_exists_absolute(base_path):
		DirAccess.make_dir_recursive_absolute(base_path)

	var filename = "%s_S%d_T%d_%s.csv" % [
		game_name, session_id, get_next_trial_id(game_name), current_date
	]
	var file = FileAccess.open(base_path + "/" + filename, FileAccess.WRITE)
	if not file:
		push_error("Could not create log file: ", filename)
		return null

	file.store_line("headerrows,7")
	file.store_line("game_name,%s" % game_name)
	file.store_line("h_id,%s" % patient_id)
	file.store_line("device_location,PMR")
	file.store_line("device_version,NOARK-0.1.0")
	file.store_line("protocol_version,0.2.0")
	file.store_line("start_time,%s" % Time.get_datetime_string_from_system())
	return file

func _load() -> void:
	if not FileAccess.file_exists("user://session.json"):
		return
	var file = FileAccess.open("user://session.json", FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(data) == TYPE_DICTIONARY:
		current_date = data.get("current_date", get_date_string())
		session_id = data.get("session_id", 1)
		trial_counts = data.get("trial_counts", {})

func _save() -> void:
	var file = FileAccess.open("user://session.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"current_date": current_date,
		"session_id": session_id,
		"trial_counts": trial_counts,
	}))
	file.close()
