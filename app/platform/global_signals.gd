extends Node

var current_patient_id: String = ""
var selected_game_mode: String = "2D"

# Installer mode (see docs/v1_plan.md §4)
var return_to_installer: bool = false   # registration returns to the installer checklist when set
var show_debug_overlays: bool = true    # researcher overlays; game screens honor this from package 3 on

var data_path: String = (
	OS.get_user_data_dir() if OS.get_name() == "Android"
	else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
) + "/data"
