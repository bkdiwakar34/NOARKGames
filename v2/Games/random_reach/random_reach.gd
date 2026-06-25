extends Control

const APPLE_SCENE := preload("res://v2/Games/random_reach/apple.tscn")
const BETWEEN_TRIAL_SCENE := preload("res://v2/Scenes/between_trial.tscn")
const GRAPH_OVERLAY_SCRIPT := preload("res://v2/Games/random_reach/graph_overlay.gd")

var _catch_radius:    float = 60.0  # set per-apple from AdaptiveManager
var _catch_hold_time: float = 1.0
const LOG_INTERVAL := 0.02

var SCREEN_MIN: Vector2
var SCREEN_MAX: Vector2

var _player_pos: Vector2
var _current_apple: Node2D = null
var _catch_timer: float = 0.0
var _trial_caught: int = 0
var _between_trial: CanvasLayer = null
var _log_file: FileAccess = null
var _log_timer: Timer = null
var _score_label: Label = null
var _debug_label: Label = null
var _calib_label: Label = null
var _is_between_trial: bool = false
var _graph_overlay: Control = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport_rect().size
	if WorkspaceConfig.is_calibrated:
		SCREEN_MIN = WorkspaceConfig.workspace_min
		SCREEN_MAX = WorkspaceConfig.workspace_max
	else:
		SCREEN_MIN = Vector2(vp.x * 0.04, vp.y * 0.05)
		SCREEN_MAX = Vector2(vp.x * 0.95, vp.y * 0.93)
	_player_pos = vp * 0.5
	_catch_hold_time = AdaptiveManager.catch_hold_time
	AdaptiveManager.set_viewport_size(vp)
	_build_ui()
	_connect_signals()
	_start_logging()

func _build_ui() -> void:
	var vp := get_viewport_rect().size

	_between_trial = BETWEEN_TRIAL_SCENE.instantiate()
	add_child(_between_trial)
	_between_trial.visible = false

	_score_label = Label.new()
	_score_label.text = "0"
	_score_label.add_theme_font_size_override("font_size", 80)
	_score_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.05))
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_score_label.custom_minimum_size = Vector2(160.0, 90.0)
	_score_label.position = Vector2(vp.x - 175.0, 18.0)
	add_child(_score_label)

	var score_sub := Label.new()
	score_sub.text = "pops"
	score_sub.add_theme_font_size_override("font_size", 20)
	score_sub.add_theme_color_override("font_color", Color(0.50, 0.32, 0.08, 0.85))
	score_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_sub.custom_minimum_size = Vector2(160.0, 28.0)
	score_sub.position = Vector2(vp.x - 175.0, 110.0)
	add_child(score_sub)

	var stop_btn := Button.new()
	stop_btn.text = "■ Stop"
	stop_btn.custom_minimum_size = Vector2(88.0, 34.0)
	stop_btn.position = Vector2(12.0, 12.0)
	stop_btn.add_theme_font_size_override("font_size", 15)
	stop_btn.modulate.a = 0.70
	stop_btn.pressed.connect(_on_stop_pressed)
	add_child(stop_btn)

	_calib_label = Label.new()
	_calib_label.add_theme_font_size_override("font_size", 20)
	_calib_label.add_theme_color_override("font_color", Color(0.10, 0.10, 0.12, 0.92))
	_calib_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_calib_label.custom_minimum_size = Vector2(vp.x, 30.0)
	_calib_label.position = Vector2(0.0, 14.0)
	var calib_bg := StyleBoxFlat.new()
	calib_bg.bg_color = Color(1.0, 0.95, 0.78, 0.85)
	calib_bg.content_margin_left = 10.0
	calib_bg.content_margin_right = 10.0
	calib_bg.content_margin_top = 4.0
	calib_bg.content_margin_bottom = 4.0
	calib_bg.corner_radius_top_left = 6
	calib_bg.corner_radius_top_right = 6
	calib_bg.corner_radius_bottom_left = 6
	calib_bg.corner_radius_bottom_right = 6
	_calib_label.add_theme_stylebox_override("normal", calib_bg)
	add_child(_calib_label)

	_debug_label = Label.new()
	_debug_label.position = Vector2(12.0, vp.y - 56.0)
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	var label_bg := StyleBoxFlat.new()
	label_bg.bg_color = Color(0.0, 0.0, 0.0, 0.52)
	label_bg.content_margin_left = 6.0
	label_bg.content_margin_right = 6.0
	label_bg.content_margin_top = 4.0
	label_bg.content_margin_bottom = 4.0
	label_bg.corner_radius_top_left = 4
	label_bg.corner_radius_top_right = 4
	label_bg.corner_radius_bottom_left = 4
	label_bg.corner_radius_bottom_right = 4
	_debug_label.add_theme_stylebox_override("normal", label_bg)
	add_child(_debug_label)

func _draw() -> void:
	var size := get_rect().size
	for i in 24:
		var t := float(i) / 24.0
		var col := Color(0.96, 0.94, 0.91).lerp(Color(0.88, 0.83, 0.76), t)
		draw_rect(Rect2(0.0, t * size.y, size.x, size.y / 24.0 + 1.0), col)

	if AdaptiveManager.ws_calibrated:
		var ws_col := Color(0.3, 0.3, 0.3, 0.22)
		var ws_min := AdaptiveManager.ws_min
		var ws_max := AdaptiveManager.ws_max
		draw_rect(Rect2(ws_min, ws_max - ws_min), ws_col, false, 1.5)
		var center := (ws_min + ws_max) * 0.5
		draw_line(center - Vector2(10, 0), center + Vector2(10, 0), ws_col, 1.5)
		draw_line(center - Vector2(0, 10), center + Vector2(0, 10), ws_col, 1.5)
		if is_instance_valid(_current_apple):
			draw_line(center, _current_apple.position, Color(1, 1, 1, 0.2), 1.0)

	# Grid workspace scan overlay (visible during scan and until Phase 0b ends)
	var scan_cells: Array = AdaptiveManager._scan_cells
	if not scan_cells.is_empty() and AdaptiveManager._phase <= AdaptiveManager.Phase.PRECISION_SCAN:
		var current_idx: int = AdaptiveManager._scan_cell_idx
		var half: float = AdaptiveManager.SCAN_CELL_SIZE * 0.5
		var cell_sz: float = AdaptiveManager.SCAN_CELL_SIZE
		for i in scan_cells.size():
			var cell: Dictionary = scan_cells[i]
			var rect: Rect2 = Rect2(cell["pos"] - Vector2(half, half), Vector2(cell_sz, cell_sz))
			if AdaptiveManager._phase == AdaptiveManager.Phase.WORKSPACE_SCAN and i == current_idx:
				draw_rect(rect, Color(1.0, 0.85, 0.0, 0.30), true)
				draw_rect(rect, Color(1.0, 0.85, 0.0, 0.90), false, 2.5)
			elif cell["hit"]:
				draw_rect(rect, Color(0.20, 0.80, 0.20, 0.28), true)
				draw_rect(rect, Color(0.20, 0.80, 0.20, 0.70), false, 1.5)
			elif i < current_idx:
				draw_rect(rect, Color(0.90, 0.20, 0.20, 0.15), true)
				draw_rect(rect, Color(0.90, 0.20, 0.20, 0.45), false, 1.0)
			else:
				draw_rect(rect, Color(0.70, 0.70, 0.70, 0.20), false, 1.0)

	# Cursor — thin charcoal ring with small centre dot
	var cursor_col := Color(0.22, 0.22, 0.22, 0.82)
	draw_arc(_player_pos, 13.0, 0.0, TAU, 48, cursor_col, 2.0)
	draw_circle(_player_pos, 2.5, cursor_col)

	# Fitts fit overlay (bottom-right) — live scatter of (ID, MT) points and
	# the current a + b·ID line. Visible during Phase 0c and the live session.
	if AdaptiveManager._phase >= AdaptiveManager.Phase.FITTS_CAL:
		_draw_fitts_overlay()


func _draw_fitts_overlay() -> void:
	var aw_pairs: Array = AdaptiveManager.aw_pairs
	if aw_pairs.is_empty():
		return

	# Collect (ID, MT) points from the outcome log.
	var pts: Array = []
	for entry in AdaptiveManager.outcome_log:
		var pi: int   = entry["pair_idx"]
		var mt: float = entry["mt"]
		if pi < 0 or pi >= aw_pairs.size() or mt < 0.0:
			continue
		var pair: Dictionary = aw_pairs[pi]
		var id_: float = log(pair["A"] / max(pair["W"], 1.0) + 1.0) / log(2.0)
		pts.append(Vector2(id_, mt))

	# Box position + size.
	var vp:    Vector2 = get_rect().size
	var box_w: float   = 240.0
	var box_h: float   = 170.0
	var pad:   float   = 14.0
	var ox:    float   = vp.x - box_w - pad
	var oy:    float   = vp.y - box_h - pad

	# Background panel.
	draw_rect(Rect2(ox, oy, box_w, box_h), Color(0.98, 0.96, 0.92, 0.88), true)
	draw_rect(Rect2(ox, oy, box_w, box_h), Color(0.30, 0.30, 0.32, 0.80), false, 1.5)

	# Plot area within the box.
	var plot_l: float = ox + 40.0
	var plot_r: float = ox + box_w - 14.0
	var plot_t: float = oy + 28.0
	var plot_b: float = oy + box_h - 26.0

	# Axis ranges. ID typically 1–6 bits; MT capped at 3 s (or auto if larger).
	var x_min: float = 0.5
	var x_max: float = 6.0
	var y_min: float = 0.0
	var y_max: float = 3.0
	for p in pts:
		if p.y > y_max:
			y_max = p.y
	if y_max > 6.0:
		y_max = 6.0  # hard cap

	# Axes.
	var axis_col := Color(0.30, 0.30, 0.32, 0.85)
	draw_line(Vector2(plot_l, plot_t), Vector2(plot_l, plot_b), axis_col, 1.0)
	draw_line(Vector2(plot_l, plot_b), Vector2(plot_r, plot_b), axis_col, 1.0)

	# Fit line: MT = a + b · ID.
	var a: float = AdaptiveManager.fitts_a
	var b: float = AdaptiveManager.fitts_b
	var y1: float = a + b * x_min
	var y2: float = a + b * x_max
	var px1: float = lerp(plot_l, plot_r, (x_min - x_min) / (x_max - x_min))
	var py1: float = lerp(plot_b, plot_t, clamp((y1 - y_min) / (y_max - y_min), 0.0, 1.0))
	var px2: float = lerp(plot_l, plot_r, (x_max - x_min) / (x_max - x_min))
	var py2: float = lerp(plot_b, plot_t, clamp((y2 - y_min) / (y_max - y_min), 0.0, 1.0))
	draw_line(Vector2(px1, py1), Vector2(px2, py2), Color(0.85, 0.22, 0.20, 0.95), 1.8)

	# Scatter points.
	var pt_col := Color(0.18, 0.45, 0.85, 0.82)
	for p in pts:
		var sx: float = lerp(plot_l, plot_r, clamp((p.x - x_min) / (x_max - x_min), 0.0, 1.0))
		var sy: float = lerp(plot_b, plot_t, clamp((p.y - y_min) / (y_max - y_min), 0.0, 1.0))
		draw_circle(Vector2(sx, sy), 2.5, pt_col)

	# Labels.
	var font: Font = get_theme_default_font()
	var text_col := Color(0.18, 0.18, 0.20)
	draw_string(font, Vector2(ox + 10.0, oy + 18.0),
		"Fitts: MT = %.2f + %.2f·ID" % [a, b],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, text_col)
	draw_string(font, Vector2(plot_r - 16.0, plot_b + 14.0), "ID",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, text_col)
	draw_string(font, Vector2(ox + 6.0, plot_t - 4.0), "MT (s)",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, text_col)
	draw_string(font, Vector2(ox + 10.0, oy + box_h - 8.0),
		"n=%d" % pts.size(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, text_col)

func _connect_signals() -> void:
	AdaptiveManager.trial_ended.connect(_on_trial_ended)
	AdaptiveManager.trial_started.connect(_on_trial_started)

func _start_logging() -> void:
	_log_file = SessionManager.create_log_file("RandomReach", PatientDB.current_patient_id)
	if _log_file:
		_log_file.store_csv_line(PackedStringArray([
			"epochtime", "trial", "difficulty",
			"player_x", "player_y", "apple_x", "apple_y", "status"
		]))
	_log_timer = Timer.new()
	_log_timer.wait_time = LOG_INTERVAL
	_log_timer.autostart = true
	_log_timer.timeout.connect(_on_log_tick)
	add_child(_log_timer)

func _process(delta: float) -> void:
	_update_player_pos()
	AdaptiveManager.update_workspace(_player_pos)

	if not _is_between_trial:
		if _current_apple == null:
			_spawn_apple()
		elif _current_apple != null:
			_check_catch(delta)

	var rate_pct := int(AdaptiveManager.rolling_rate * 100.0)
	var target_pct := int(AdaptiveManager.assigned_rate * 100.0)
	var err_pct := rate_pct - target_pct
	var phase_names: Array[String] = ["WS_SCAN", "PREC_SCAN", "FITTS_CAL", "SESSION"]
	var phase_str: String = phase_names[AdaptiveManager._phase] if AdaptiveManager._phase < phase_names.size() else "?"
	_debug_label.text = "T%d  [%s]  a:%.3f  b:%.3f  ID:%.2f\nrate:%d%%  err:%+d%%  r:%d" % [
		AdaptiveManager.trial_number, phase_str,
		AdaptiveManager.fitts_a, AdaptiveManager.fitts_b, AdaptiveManager.difficulty,
		rate_pct, err_pct, AdaptiveManager._rls_n
	]

	var prog: Dictionary = AdaptiveManager.get_calibration_progress()
	if prog.is_empty():
		_calib_label.visible = false
	else:
		_calib_label.visible = true
		_calib_label.text = "Setting up (%d/%d) — %s: apple %d / %d" % [
			prog["phase"], prog["phases"], prog["name"],
			prog["current"] + 1, prog["total"]
		]

	queue_redraw()


func _update_player_pos() -> void:
	var raw: Vector2 = UDPReceiver.screen_pos if UDPReceiver.connected else get_global_mouse_position()
	_player_pos = _player_pos.lerp(raw, 0.8)
	_player_pos.x = clamp(_player_pos.x, SCREEN_MIN.x, SCREEN_MAX.x)
	_player_pos.y = clamp(_player_pos.y, SCREEN_MIN.y, SCREEN_MAX.y)

func _spawn_apple() -> void:
	if is_instance_valid(_current_apple):
		_current_apple.queue_free()
	var spawn_pos := AdaptiveManager.get_spawn_position(_player_pos)
	spawn_pos.x = clamp(spawn_pos.x, SCREEN_MIN.x, SCREEN_MAX.x)
	spawn_pos.y = clamp(spawn_pos.y, SCREEN_MIN.y, SCREEN_MAX.y)
	var apple_lt: float = AdaptiveManager.get_apple_lifetime(_player_pos, spawn_pos)
	_current_apple = APPLE_SCENE.instantiate()
	_catch_radius = AdaptiveManager.get_apple_radius()
	_current_apple.position = spawn_pos
	_current_apple.lifetime = apple_lt
	_current_apple.target_radius = _catch_radius
	_current_apple.balloon_color = Color.from_hsv(randf(), 0.65, 0.72)
	_current_apple.apple_eaten.connect(_on_apple_eaten)
	_current_apple.apple_missed.connect(_on_apple_missed)
	add_child(_current_apple)
	AdaptiveManager.record_spawn(_player_pos)
	_catch_timer = 0.0

func _check_catch(delta: float) -> void:
	if not is_instance_valid(_current_apple):
		_current_apple = null
		_catch_timer = 0.0
		return
	if _player_pos.distance_to(_current_apple.position) < _catch_radius:
		_catch_timer += delta
		_current_apple.set_catch_progress(clamp(_catch_timer / _catch_hold_time, 0.0, 1.0))
		if _catch_timer >= _catch_hold_time:
			_current_apple.eat()
	elif _catch_timer > 0.0:
		_catch_timer = 0.0
		_current_apple.set_catch_progress(0.0)

func _on_apple_eaten() -> void:
	var lt: float = _current_apple.lifetime if is_instance_valid(_current_apple) else 0.0
	AdaptiveManager.record_catch(lt)
	_trial_caught += 1
	_score_label.text = str(_trial_caught)
	var burst_pos: Vector2 = _current_apple.position if is_instance_valid(_current_apple) else _player_pos
	_spawn_catch_burst(burst_pos)
	_current_apple = null
	_catch_timer = 0.0

func _on_apple_missed() -> void:
	var lt: float = _current_apple.lifetime if is_instance_valid(_current_apple) else 0.0
	AdaptiveManager.record_miss(lt)
	_current_apple = null
	_catch_timer   = 0.0

func _spawn_catch_burst(pos: Vector2) -> void:
	for i in 7:
		var star := Label.new()
		star.text = "★"
		star.add_theme_font_size_override("font_size", 24)
		star.add_theme_color_override("font_color", Color(1.0, 0.80, 0.1))
		star.position = pos - Vector2(12.0, 12.0)
		add_child(star)
		var angle := i * TAU / 7.0 + randf_range(-0.2, 0.2)
		var target := pos + Vector2(cos(angle), sin(angle)) * randf_range(55.0, 90.0) - Vector2(12.0, 12.0)
		var tween := create_tween().set_parallel(true)
		tween.tween_property(star, "position", target, 0.45)
		tween.tween_property(star, "modulate:a", 0.0, 0.45)
		tween.chain().tween_callback(func(): star.queue_free())

func _on_trial_ended(_trial_num: int, caught: int, _spawned: int) -> void:
	_is_between_trial = true
	_catch_timer = 0.0
	if is_instance_valid(_current_apple):
		_current_apple.queue_free()
	_current_apple = null
	_between_trial.show_result(caught)
	_between_trial.visible = true

func _on_trial_started(_trial_num: int) -> void:
	_is_between_trial = false
	_trial_caught = 0
	_score_label.text = "0"
	_between_trial.visible = false

func _on_log_tick() -> void:
	if not _log_file:
		return
	var has_apple := is_instance_valid(_current_apple)
	var apple_x := _current_apple.position.x if has_apple else -1.0
	var apple_y := _current_apple.position.y if has_apple else -1.0
	var status: String = "between" if _is_between_trial \
		else ("catching" if _catch_timer > 0.0 else "reaching")
	_log_file.store_csv_line(PackedStringArray([
		str(Time.get_unix_time_from_system()),
		str(AdaptiveManager.trial_number),
		str(AdaptiveManager.difficulty),
		str(_player_pos.x), str(_player_pos.y),
		str(apple_x), str(apple_y),
		status
	]))

func _on_stop_pressed() -> void:
	if _graph_overlay != null:
		return
	AdaptiveManager.stop_session()
	_is_between_trial = true
	if is_instance_valid(_current_apple):
		_current_apple.queue_free()
	_current_apple = null
	_graph_overlay = GRAPH_OVERLAY_SCRIPT.new()
	_graph_overlay.closed.connect(_on_graph_closed)
	add_child(_graph_overlay)

func _on_graph_closed() -> void:
	get_tree().change_scene_to_file("res://v2/Scenes/game_select.tscn")

func _exit_tree() -> void:
	if AdaptiveManager.trial_ended.is_connected(_on_trial_ended):
		AdaptiveManager.trial_ended.disconnect(_on_trial_ended)
	if AdaptiveManager.trial_started.is_connected(_on_trial_started):
		AdaptiveManager.trial_started.disconnect(_on_trial_started)
	if _log_file:
		_log_file.close()
		_log_file = null
