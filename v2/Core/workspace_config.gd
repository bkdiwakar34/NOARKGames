extends Node

var workspace_min: Vector2 = Vector2.ZERO
var workspace_max: Vector2 = Vector2.ZERO
var is_calibrated: bool    = false

# Sensor-to-screen calibration
var sensor_calibrated: bool = false
var raw_x_left:   float = 0.0   # raw_x when arm is at left edge of screen
var raw_x_right:  float = 1.0   # raw_x when arm is at right edge
var raw_z_top:    float = 0.0   # raw_z when arm is at top edge
var raw_z_bottom: float = 1.0   # raw_z when arm is at bottom edge

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

	if data.get("sensor_calibrated", false):
		raw_x_left   = data.get("raw_x_left",   0.0)
		raw_x_right  = data.get("raw_x_right",  1.0)
		raw_z_top    = data.get("raw_z_top",     0.0)
		raw_z_bottom = data.get("raw_z_bottom",  1.0)
		sensor_calibrated = (raw_x_right != raw_x_left) and (raw_z_bottom != raw_z_top)


func save_config(min_pos: Vector2, max_pos: Vector2) -> void:
	workspace_min = min_pos
	workspace_max = max_pos
	is_calibrated = true
	_write()


func save_sensor_calibration(x_left: float, x_right: float, z_top: float, z_bottom: float, vp_size: Vector2) -> void:
	raw_x_left   = x_left
	raw_x_right  = x_right
	raw_z_top    = z_top
	raw_z_bottom = z_bottom
	sensor_calibrated = true
	# Full viewport is now the workspace — scan will discover reachable cells within it
	workspace_min = Vector2.ZERO
	workspace_max = vp_size
	is_calibrated = true
	_write()


func _write() -> void:
	var data: Dictionary = {
		"min_x": workspace_min.x, "min_y": workspace_min.y,
		"max_x": workspace_max.x, "max_y": workspace_max.y,
		"sensor_calibrated": sensor_calibrated,
		"raw_x_left":   raw_x_left,
		"raw_x_right":  raw_x_right,
		"raw_z_top":    raw_z_top,
		"raw_z_bottom": raw_z_bottom,
	}
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()


func sensor_to_screen(rx: float, rz: float, vp: Vector2) -> Vector2:
	var sx := (rx - raw_x_left) / (raw_x_right - raw_x_left) * vp.x
	var sy := (rz - raw_z_top)  / (raw_z_bottom - raw_z_top)  * vp.y
	return Vector2(sx, sy)
