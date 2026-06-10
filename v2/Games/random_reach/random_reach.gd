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
var _missed_apple_pos: Vector2 = Vector2.ZERO
var _tracking_miss: bool = false
var _miss_track_timer: float = 0.0
const MISS_TRACK_WINDOW: float = 6.0
var _trial_caught: int = 0
var _between_trial: CanvasLayer = null
var _log_file: FileAccess = null
var _log_timer: Timer = null
var _score_label: Label = null
var _debug_label: Label = null
var _is_between_trial: bool = false
var _graph_overlay: Control = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport_rect().size
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
		var col := Color(0.38, 0.68, 0.95).lerp(Color(0.72, 0.90, 1.0), t)
		draw_rect(Rect2(0.0, t * size.y, size.x, size.y / 24.0 + 1.0), col)

	if AdaptiveManager.ws_calibrated:
		var ws_col := Color(1, 1, 1, 0.3)
		var ws_min := AdaptiveManager.ws_min
		var ws_max := AdaptiveManager.ws_max
		draw_rect(Rect2(ws_min, ws_max - ws_min), ws_col, false, 1.5)
		var center := (ws_min + ws_max) * 0.5
		draw_line(center - Vector2(10, 0), center + Vector2(10, 0), ws_col, 1.5)
		draw_line(center - Vector2(0, 10), center + Vector2(0, 10), ws_col, 1.5)
		if is_instance_valid(_current_apple):
			draw_line(center, _current_apple.position, Color(1, 1, 1, 0.2), 1.0)

	# Pin tool — tip at _player_pos, pointing toward balloon
	var pin_dir: Vector2
	if is_instance_valid(_current_apple):
		pin_dir = (_current_apple.position - _player_pos)
	elif _tracking_miss:
		pin_dir = (_missed_apple_pos - _player_pos)
	else:
		pin_dir = Vector2(1.0, 0.0)
	if pin_dir.length() > 0.01:
		pin_dir = pin_dir.normalized()
	var perp := Vector2(-pin_dir.y, pin_dir.x)
	var tip  := _player_pos
	var head := _player_pos - pin_dir * 30.0
	# Shaft
	draw_line(head, tip, Color(0.80, 0.82, 0.88), 2.5)
	# Tip triangle
	draw_colored_polygon(PackedVector2Array([
		tip,
		tip - pin_dir * 9.0 + perp * 3.5,
		tip - pin_dir * 9.0 - perp * 3.5
	]), Color(0.92, 0.94, 1.0))
	# Head (red circle)
	draw_circle(head, 7.0, Color(0.85, 0.12, 0.12))
	draw_circle(head + Vector2(-2.0, -2.0), 2.5, Color(1.0, 0.55, 0.55, 0.5))

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

	if _tracking_miss:
		_miss_track_timer += delta
		if _player_pos.distance_to(_missed_apple_pos) < _catch_radius:
			AdaptiveManager.record_miss_completed()
			_tracking_miss = false
		elif _miss_track_timer >= MISS_TRACK_WINDOW:
			_tracking_miss = false  # movement aborted — discard trial

	if not _is_between_trial:
		if _current_apple == null and not _tracking_miss:
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
	_current_apple.position = spawn_pos
	_current_apple.lifetime = apple_lt
	_current_apple.balloon_color = Color.from_hsv(randf(), 0.75, 0.92)
	_current_apple.apple_eaten.connect(_on_apple_eaten)
	_current_apple.apple_missed.connect(_on_apple_missed)
	add_child(_current_apple)
	_catch_radius = AdaptiveManager.get_apple_radius()
	_tracking_miss = false
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
	if is_instance_valid(_current_apple):
		_missed_apple_pos  = _current_apple.position
		_tracking_miss     = true
		_miss_track_timer  = 0.0
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
