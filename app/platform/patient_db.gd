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
		target_success_rate: float, comments: String = "") -> bool:
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
		"comments": comments
	}
	save_database()
	return true

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
