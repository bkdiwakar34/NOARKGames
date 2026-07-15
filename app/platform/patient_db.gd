extends Node

const RECORDS_DIR = "NOARK/records"
const DB_FILE = "patients.json"

var patient_register: Dictionary = {}
var current_patient_id: String = ""

var records_path: String
var database_file_path: String

func _init():
	_setup_paths()
	_ensure_directory_exists()
	load_database()

func _setup_paths() -> void:
	var base_dir = OS.get_user_data_dir() if OS.get_name() == "Android" \
		else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
	records_path = base_dir.path_join("records")
	database_file_path = records_path.path_join(DB_FILE)

func _ensure_directory_exists() -> void:
	if not DirAccess.dir_exists_absolute(records_path):
		DirAccess.make_dir_recursive_absolute(records_path)

func load_database() -> bool:
	if not FileAccess.file_exists(database_file_path):
		patient_register = {}
		current_patient_id = ""
		save_database()
		return true

	var file = FileAccess.open(database_file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open patient database: ", database_file_path)
		return false

	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Failed to parse patient database")
		return false
	file.close()

	var data = json.get_data()
	if typeof(data) == TYPE_DICTIONARY:
		patient_register = data.get("patient_register", {})
		current_patient_id = data.get("current_patient_id", "")
		return true

	push_error("Invalid patient database format")
	return false

func save_database() -> bool:
	var data = {
		"patient_register": patient_register,
		"current_patient_id": current_patient_id
	}
	var file = FileAccess.open(database_file_path, FileAccess.WRITE)
	if not file:
		push_error("Failed to save patient database")
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true

func add_patient(hospital_id: String, patient_name: String, age: int, gender: String,
		stroke_time: int, dominant_hand: String, affected_hand: String,
		target_success_rate: float, comments: String = "",
		rate_schedule: Array = []) -> bool:
	if hospital_id in patient_register:
		push_error("Patient ID already exists: ", hospital_id)
		return false

	patient_register[hospital_id] = {
		"name": patient_name,
		"age": age,
		"gender": gender,
		"stroke_time": stroke_time,
		"dominant_hand": dominant_hand,
		"affected_hand": affected_hand,
		"target_success_rate": target_success_rate,
		"comments": comments,
		"rate_schedule": rate_schedule,          # 14 pre-sampled daily target rates
		"start_date": Time.get_date_string_from_system()  # day 1 of the schedule
	}
	save_database()
	return true


# Day's assigned rate from the pre-sampled schedule (day 1 = start_date).
# Falls back to the fixed target_success_rate when no schedule exists, and
# holds the last scheduled value once the study window has passed.
func get_todays_rate(hospital_id: String) -> float:
	var p: Dictionary = get_patient(hospital_id)
	if p.is_empty():
		return -1.0
	var sched: Array = p.get("rate_schedule", [])
	if sched.is_empty():
		return p.get("target_success_rate", -1.0)
	var day_idx: int = 0
	var start_str: String = p.get("start_date", "")
	if start_str != "":
		var start_unix: int = Time.get_unix_time_from_datetime_string(start_str + "T00:00:00")
		var today_unix: int = Time.get_unix_time_from_datetime_string(
			Time.get_date_string_from_system() + "T00:00:00")
		day_idx = int(round(float(today_unix - start_unix) / 86400.0))
	day_idx = clamp(day_idx, 0, sched.size() - 1)
	return float(sched[day_idx])

func update_patient(hospital_id: String, fields: Dictionary) -> bool:
	if not hospital_id in patient_register:
		push_error("Cannot update unknown patient: ", hospital_id)
		return false
	var rec: Dictionary = patient_register[hospital_id]
	# A changed schedule restarts the study clock (new day 1); any other edit
	# must not shift which day's rate get_todays_rate() picks.
	if fields.has("rate_schedule") and fields["rate_schedule"] != rec.get("rate_schedule", []):
		rec["start_date"] = Time.get_date_string_from_system()
	for k in fields:
		rec[k] = fields[k]
	save_database()
	return true


# Saved calibration profile (workspace tiles + Fitts model), written by
# AdaptiveManager so sessions can start without the 4-minute calibration.
func set_calib_profile(hospital_id: String, profile: Dictionary) -> void:
	if hospital_id in patient_register:
		patient_register[hospital_id]["calib_profile"] = profile
		save_database()


func get_calib_profile(hospital_id: String) -> Dictionary:
	return get_patient(hospital_id).get("calib_profile", {})


func remove_patient(hospital_id: String) -> bool:
	if hospital_id in patient_register:
		patient_register.erase(hospital_id)
		save_database()
		return true
	return false

func get_patient(hospital_id: String) -> Dictionary:
	return patient_register.get(hospital_id, {})

func list_all_patients() -> Array:
	var patients = []
	for hospital_id in patient_register.keys():
		var p = patient_register[hospital_id]
		patients.append({
			"hospital_id": hospital_id,
			"name": p.get("name", ""),
			"age": p.get("age", 0),
			"gender": p.get("gender", ""),
			"stroke_time": p.get("stroke_time", 0),
			"dominant_hand": p.get("dominant_hand", ""),
			"affected_hand": p.get("affected_hand", ""),
			"target_success_rate": p.get("target_success_rate", -1.0),
			"comments": p.get("comments", ""),
		})
	return patients
