extends Control
# Standalone jitter-comparison tool — NOT part of the patient product.
# Compares "old setup" (markers 12/24/20, equal-weight average) against the
# current "new setup" (all markers, rigid-body joint solve), at fixed
# workspace positions, for a workdone presentation.
#
# Run directly, bypassing the app entirely — no existing scene is touched:
#   godot --path . tools/jitter_test.tscn
# (autoloads still load normally, including UDPReceiver and WorkspaceConfig.)
#
# Controls:
#   LEFT/RIGHT  change target (only while stopped)
#   M           toggle old/new mode (only while stopped)
#   SPACE       start/stop recording at the current target+mode
#   ESC         save the CSV and quit

const CELL_SIZE: float = 120.0  # matches AdaptiveManager.SCAN_CELL_SIZE

var _targets: Array = []          # Vector2 positions
var _recorded: Array = []         # {"old": bool, "new": bool} per target
var _target_idx: int = 0
var _mode: String = "new"         # "old" or "new"
var _recording: bool = false
var _log_file: FileAccess = null
var _player_pos: Vector2 = Vector2.ZERO
var _status_label: Label
var _calib_overlay: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.position = Vector2(16, 16)
	_status_label.custom_minimum_size = Vector2(900, 140)
	add_child(_status_label)

	if WorkspaceConfig.is_calibrated:
		_start_after_calibration()
	else:
		_calib_overlay = load("res://app/installer/workspace_calibration_overlay.gd").new()
		_calib_overlay.calibration_done.connect(_start_after_calibration)
		add_child(_calib_overlay)


func _start_after_calibration() -> void:
	_calib_overlay = null
	_build_grid()
	_open_log_file()
	_apply_mode()
	UDPReceiver.log_enabled = true


func _build_grid() -> void:
	var gmin: Vector2 = WorkspaceConfig.workspace_min
	var gmax: Vector2 = WorkspaceConfig.workspace_max
	var usable_w: float = gmax.x - gmin.x
	var usable_h: float = gmax.y - gmin.y
	var cols: int = max(1, int(usable_w / CELL_SIZE))
	var rows: int = max(1, int(usable_h / CELL_SIZE))
	var step_x: float = usable_w / cols
	var step_y: float = usable_h / rows
	var ox: float = gmin.x + step_x * 0.5
	var oy: float = gmin.y + step_y * 0.5
	_targets.clear()
	_recorded.clear()
	for r in rows:
		for c in cols:
			_targets.append(Vector2(ox + c * step_x, oy + r * step_y))
			_recorded.append({"old": false, "new": false})


func _open_log_file() -> void:
	var base_dir: String = (
		OS.get_user_data_dir() if OS.get_name() == "Android"
		else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
	) + "/jitter_test"
	if not DirAccess.dir_exists_absolute(base_dir):
		DirAccess.make_dir_recursive_absolute(base_dir)
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	_log_file = FileAccess.open(base_dir + "/jitter_test_" + stamp + ".csv", FileAccess.WRITE)
	if _log_file:
		_log_file.store_csv_line(PackedStringArray([
			"epochtime", "target_id", "mode",
			"screen_x", "screen_y", "tracker_x", "tracker_y", "tracker_z"
		]))
	else:
		push_error("jitter_test: could not create log file in ", base_dir)


func _apply_mode() -> void:
	if _mode == "new":
		UDPReceiver.send_setup_raw("all", "rigid")
	else:
		UDPReceiver.send_setup_raw("subset", "equal")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_LEFT:
			if not _recording:
				_target_idx = (_target_idx - 1 + _targets.size()) % _targets.size()
		KEY_RIGHT:
			if not _recording:
				_target_idx = (_target_idx + 1) % _targets.size()
		KEY_M:
			if not _recording:
				_mode = "old" if _mode == "new" else "new"
				_apply_mode()
		KEY_SPACE:
			_recording = not _recording
			if not _recording:
				_recorded[_target_idx][_mode] = true
		KEY_ESCAPE:
			_finish()


func _process(_delta: float) -> void:
	_player_pos = UDPReceiver.screen_pos if UDPReceiver.connected else get_global_mouse_position()
	var samples: Array = UDPReceiver.take_samples()
	if _recording and _log_file:
		for s in samples:
			_log_file.store_csv_line(PackedStringArray([
				str(s[0]), str(_target_idx), _mode,
				str(s[1]), str(s[2]), str(s[3]), str(s[4]), str(s[5])
			]))
		_log_file.flush()

	var done: int = 0
	for r in _recorded:
		if r["old"] and r["new"]:
			done += 1
	_status_label.text = "Target %d / %d   (%d fully recorded)\nMode: %s%s\ntracker: %s  %d pkt/s\n\nLEFT/RIGHT: change target (stopped only)   M: toggle mode (stopped only)\nSPACE: start/stop recording   ESC: save and quit" % [
		_target_idx + 1, _targets.size(), done,
		_mode.to_upper(), "  [RECORDING]" if _recording else "",
		"connected" if UDPReceiver.connected else "NOT connected", UDPReceiver.packets_per_sec,
	]
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_rect().size), Color(0.96, 0.94, 0.91))

	for i in _targets.size():
		var pos: Vector2 = _targets[i]
		var rec: Dictionary = _recorded[i]
		var col: Color
		if rec["old"] and rec["new"]:
			col = Color(0.20, 0.75, 0.25, 0.8)   # both modes done
		elif rec["old"] or rec["new"]:
			col = Color(0.90, 0.60, 0.10, 0.8)   # one mode done
		else:
			col = Color(0.55, 0.55, 0.55, 0.5)   # not started
		draw_arc(pos, CELL_SIZE * 0.5, 0.0, TAU, 32, col, 2.0)
		if i == _target_idx:
			draw_arc(pos, CELL_SIZE * 0.5 + 5.0, 0.0, TAU, 32, Color(0.85, 0.15, 0.10, 0.9), 3.0)

	var cursor_col := Color(0.15, 0.45, 0.85, 0.9)
	draw_arc(_player_pos, 13.0, 0.0, TAU, 32, cursor_col, 2.5)
	draw_circle(_player_pos, 3.0, cursor_col)


func _finish() -> void:
	UDPReceiver.log_enabled = false
	UDPReceiver.send_setup_raw("all", "rigid")  # restore the production default before exiting
	if _log_file:
		_log_file.close()
		_log_file = null
	get_tree().quit()
