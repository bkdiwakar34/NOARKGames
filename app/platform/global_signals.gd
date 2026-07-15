extends Node

const UITheme := preload("res://app/ui/ui_theme.gd")

func _ready() -> void:
	# One call themes every control in the app (falls back to the default
	# font until Nunito ttf files are dropped into app/assets/fonts/).
	UITheme.apply_global_font()

var current_patient_id: String = ""
var selected_game_mode: String = "2D"

# Installer mode (see docs/v1_plan.md §4)
var return_to_installer: bool = false   # registration returns to the installer checklist when set
var edit_patient_id: String = ""        # registration opens pre-filled in edit mode when set
# Calibration policy at game start: "auto" = full calibration when the saved
# profile is missing/older than 7 days; "always" / "never" are the installer's
# manual override for testing and demos (resets to auto on relaunch).
var calib_mode: String = "auto"
var show_debug_overlays: bool = true    # researcher overlays; game screens honor this from package 3 on

var data_path: String = (
	OS.get_user_data_dir() if OS.get_name() == "Android"
	else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
) + "/data"
