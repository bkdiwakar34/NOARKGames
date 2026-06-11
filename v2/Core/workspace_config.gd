extends Node

var workspace_min: Vector2 = Vector2.ZERO
var workspace_max: Vector2 = Vector2.ZERO
var is_calibrated: bool    = false

const CONFIG_PATH: String = "user://workspace_config.json"


func _ready() -> void:
	_load()


func _load() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not f:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not data is Dictionary:
		return
	workspace_min = Vector2(data.get("min_x", 0.0), data.get("min_y", 0.0))
	workspace_max = Vector2(data.get("max_x", 0.0), data.get("max_y", 0.0))
	if workspace_max.x > workspace_min.x and workspace_max.y > workspace_min.y:
		is_calibrated = true


func save_config(min_pos: Vector2, max_pos: Vector2) -> void:
	workspace_min = min_pos
	workspace_max = max_pos
	is_calibrated = true
	var data: Dictionary = {
		"min_x": min_pos.x, "min_y": min_pos.y,
		"max_x": max_pos.x, "max_y": max_pos.y
	}
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()
