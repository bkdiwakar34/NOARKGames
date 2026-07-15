extends Node

var current_patient_id: String = ""
var selected_game_mode: String = "2D"

var data_path: String = (
	OS.get_user_data_dir() if OS.get_name() == "Android"
	else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
) + "/data"
