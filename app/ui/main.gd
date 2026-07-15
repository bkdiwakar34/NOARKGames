extends Node

func _ready() -> void:
	var patients = PatientDB.list_all_patients()
	if patients.is_empty():
		get_tree().change_scene_to_file("res://app/ui/registration.tscn")
	else:
		PatientDB.current_patient_id = patients[0]["hospital_id"]
		GlobalSignals.current_patient_id = patients[0]["hospital_id"]
		get_tree().change_scene_to_file("res://app/ui/game_select.tscn")
