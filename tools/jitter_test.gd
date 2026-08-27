extends Control
# Standalone jitter-comparison tool — NOT part of the patient product.
# Compares "old setup" (markers 12/24/20, equal-weight average) against the
# current "new setup" (all markers, rigid-body joint solve), at fixed
# workspace positions, for a workdone presentation.
#
# Run directly, bypassing the app entirely — no existing scene is touched:
#   godot --path . tools/jitter_test.tscn   (or F6 with this scene open)
# The tracker is launched automatically by the UDPReceiver autoload, exactly
# as in the main app; the cursor follows the mouse only until the device is
# actually seen by the camera, then switches to the tracker.
#
# Flow: START MENU (calibrate? / which mode?) -> [calibration] -> GRID.
# Grid controls:
#   LEFT/RIGHT  change target (only while stopped)
#   M           toggle old/new mode (only while stopped)
#   SPACE       start/stop recording at the current target+mode
#   ESC         save the CSV and quit

const CELL_SIZE: float = 60.0  # denser re-run for smoother jitter-heatmap interpolation
                                # (was 120.0, matching AdaptiveManager.SCAN_CELL_SIZE)
const RECORD_DURATION: float = 5.0  # fixed per-segment recording, so every segment
                                    # has the same sample count (fair variance comparison)

enum State { MENU, CALIBRATE, GRID }
var _state: int = State.MENU

var _do_calibration: bool = true
var _mode: String = "new"         # "old" or "new"

var _targets: Array = []          # Vector2 positions
var _recorded: Array = []         # {"old": bool, "new": bool} per target
var _target_idx: int = 0
var _recording: bool = false
var _record_left: float = 0.0     # seconds remaining in the current fixed-duration recording
var _log_file: FileAccess = null
var _player_pos: Vector2 = Vector2.ZERO

var _menu: Control = null
var _calib_check: CheckBox = null
var _mode_option: OptionButton = null
var _status_label: Label = null
var _calib_overlay: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_menu()


# ── Start menu ────────────────────────────────────────────────────────────────

func _build_menu() -> void:
	_menu = VBoxContainer.new()
	_menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_menu.custom_minimum_size = Vector2(560, 0)
	_menu.add_theme_constant_override("separation", 22)
	add_child(_menu)

	var title := Label.new()
	title.text = "Jitter comparison test"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu.add_child(title)

	var already := "  (already calibrated)" if WorkspaceConfig.is_calibrated else "  (not calibrated yet)"
	_calib_check = CheckBox.new()
	_calib_check.text = "Do 4-corner calibration first" + already
	_calib_check.add_theme_font_size_override("font_size", 22)
	_calib_check.button_pressed = not WorkspaceConfig.is_calibrated
	_menu.add_child(_calib_check)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 14)
	var mode_lbl := Label.new()
	mode_lbl.text = "Start in mode:"
	mode_lbl.add_theme_font_size_override("font_size", 22)
	mode_row.add_child(mode_lbl)
	_mode_option = OptionButton.new()
	_mode_option.add_theme_font_size_override("font_size", 22)
	_mode_option.add_item("NEW  (all markers, rigid body)")   # index 0 -> "new"
	_mode_option.add_item("OLD  (12/24/20, equal weight)")    # index 1 -> "old"
	_mode_option.select(0)
	mode_row.add_child(_mode_option)
	_menu.add_child(mode_row)

	var hint := Label.new()
	hint.text = "You can switch mode any time during the test with the M key."
	hint.add_theme_font_size_override("font_size", 16)
	hint.modulate = Color(0.3, 0.3, 0.3)
	_menu.add_child(hint)

	var start_btn := Button.new()
	start_btn.text = "Start"
	start_btn.custom_minimum_size = Vector2(0, 56)
	start_btn.add_theme_font_size_override("font_size", 24)
	start_btn.pressed.connect(_on_start_pressed)
	_menu.add_child(start_btn)

	var tracker_note := Label.new()
	tracker_note.name = "TrackerNote"
	tracker_note.add_theme_font_size_override("font_size", 16)
	tracker_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu.add_child(tracker_note)


func _on_start_pressed() -> void:
	_do_calibration = _calib_check.button_pressed
	_mode = "new" if _mode_option.selected == 0 else "old"

	_menu.queue_free()
	_menu = null

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.position = Vector2(16, 16)
	_status_label.custom_minimum_size = Vector2(1000, 160)
	add_child(_status_label)

	if _do_calibration:
		_state = State.CALIBRATE
		_calib_overlay = load("res://app/installer/workspace_calibration_overlay.gd").new()
		_calib_overlay.calibration_done.connect(_on_calibration_done)
		add_child(_calib_overlay)
	else:
		_enter_grid()


func _on_calibration_done() -> void:
	_calib_overlay = null
	_enter_grid()


# ── Grid ──────────────────────────────────────────────────────────────────────

func _enter_grid() -> void:
	_state = State.GRID
	_build_grid()
	_open_log_file()
	_apply_mode()
	UDPReceiver.log_enabled = true


func _build_grid() -> void:
	var gmin: Vector2 = WorkspaceConfig.workspace_min
	var gmax: Vector2 = WorkspaceConfig.workspace_max
	if not (gmax.x > gmin.x and gmax.y > gmin.y):
		var vp := get_viewport_rect().size   # no calibration -> full viewport
		gmin = Vector2(vp.x * 0.05, vp.y * 0.05)
		gmax = Vector2(vp.x * 0.95, vp.y * 0.95)
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
	if _state != State.GRID:
		return
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
			# Start a fixed-duration recording; ignored while one is running,
			# so the duration is always exactly RECORD_DURATION (no manual stop).
			if not _recording:
				_recording = true
				_record_left = RECORD_DURATION
		KEY_ESCAPE:
			_finish()


func _process(delta: float) -> void:
	if _state == State.MENU:
		if _menu:
			var note: Label = _menu.get_node_or_null("TrackerNote")
			if note:
				if UDPReceiver.connected:
					note.text = "Tracker connected — %d packets/s" % UDPReceiver.packets_per_sec
					note.modulate = Color(0.15, 0.6, 0.2)
				else:
					note.text = "Tracker not connected yet — show the device to the camera"
					note.modulate = Color(0.8, 0.5, 0.1)
		return
	if _state != State.GRID:
		return

	_player_pos = UDPReceiver.screen_pos if UDPReceiver.connected else get_global_mouse_position()
	var samples: Array = UDPReceiver.take_samples()
	if _recording and _log_file:
		for s in samples:
			_log_file.store_csv_line(PackedStringArray([
				str(s[0]), str(_target_idx), _mode,
				str(s[1]), str(s[2]), str(s[3]), str(s[4]), str(s[5])
			]))
		_log_file.flush()
		_record_left -= delta
		if _record_left <= 0.0:
			_recording = false
			_recorded[_target_idx][_mode] = true

	var done: int = 0
	for r in _recorded:
		if r["old"] and r["new"]:
			done += 1
	var track := "connected  %d pkt/s" % UDPReceiver.packets_per_sec if UDPReceiver.connected \
		else "NOT connected (cursor = mouse)"
	var rec_txt := "   [RECORDING %.1f s]" % _record_left if _recording else ""
	_status_label.text = "Target %d / %d   (%d fully recorded)\nMode: %s%s\nTracker: %s\n\nLEFT/RIGHT: change target   M: toggle mode   (both only when idle)\nSPACE: record %.0f s (auto-stops)   ESC: save and quit" % [
		_target_idx + 1, _targets.size(), done,
		_mode.to_upper(), rec_txt,
		track, RECORD_DURATION,
	]
	queue_redraw()


func _draw() -> void:
	if _state != State.GRID:
		return
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
