extends Node

signal trial_ended(trial_num: int, caught: int, spawned: int)
signal trial_started(trial_num: int)

enum DifficultyMode { LIFETIME, WORKSPACE }
var difficulty_mode: int = DifficultyMode.LIFETIME

var assigned_rate: float = 0.8

# Lifetime mode — threshold in seconds, offset in seconds (positive = easier)
var threshold: float = 4.05
var offset: float = 0.0

# Workspace mode — threshold as fraction of ws_radius [0,1], offset shifts it (positive = easier = closer)
var ws_threshold: float = 0.5
var ws_offset: float = 0.0

var trial_number: int = 0
var is_running: bool = false
var rolling_rate: float = 0.0

var ws_min: Vector2 = Vector2.ZERO
var ws_max: Vector2 = Vector2.ZERO
var ws_calibrated: bool = false
var _ws_any_recorded: bool = false
var _viewport_size: Vector2 = Vector2(960.0, 540.0)
var _last_spawn_pos: Vector2 = Vector2.ZERO

var _trial_caught: int = 0
var _trial_spawned: int = 0
var _trial_apple_start: int = 0
var _integral: float = 0.0
var outcome_log: Array = []   # [{lt, hit, pos}] — one entry per apple
var trial_log: Array = []     # [{trial, rate}] — one entry per completed trial

var _trial_timer: Timer
var _between_timer: Timer

var gain_p: float = 0.35
var gain_i: float = 0.05
var gain_d: float = 0.0
var _prev_error: float = 0.0
var catch_hold_time: float = 1.0   # revert to 0.8 for real patients

const DEAD_BAND: float = 0.05
var window_width: float = 2.4        # seconds — lifetime sampling window width

# Staircase calibration
var sc_step_coarse: float = 1.5   # step size (seconds) for first 2 reversals
var sc_step_fine:   float = 0.5   # step size after 2 reversals
var sc_n_reversals: int   = 6
var _sc_level: float = 0.0
var _sc_direction: int = 0          # +1 easier, -1 harder, 0 not started
var _sc_reversals: Array = []
var _sc_done: bool = false
const WS_WINDOW_FRAC: float = 0.30   # fraction of ws_radius — workspace sampling window width
var trial_duration: float = 60.0     # revert to 60.0 for real patients
const BETWEEN_DURATION: float = 3.0
const LIFETIME_MAX: float = 8.0   # revert to 15.0 for real patients
const LIFETIME_MIN: float = 0.1   # revert to 3.0 for real patients

func _ready() -> void:
	_trial_timer = Timer.new()
	_trial_timer.wait_time = trial_duration
	_trial_timer.one_shot = true
	_trial_timer.timeout.connect(_on_trial_timer_ended)
	add_child(_trial_timer)

	_between_timer = Timer.new()
	_between_timer.wait_time = BETWEEN_DURATION
	_between_timer.one_shot = true
	_between_timer.timeout.connect(_on_between_timer_ended)
	add_child(_between_timer)

func start_session(rate: float) -> void:
	assigned_rate = rate
	threshold = (LIFETIME_MAX + LIFETIME_MIN) * 0.5
	offset = 0.0
	ws_threshold = 0.5
	ws_offset = 0.0
	trial_number = 0
	rolling_rate = 0.0
	_integral = 0.0
	_prev_error = 0.0
	outcome_log.clear()
	trial_log.clear()
	ws_calibrated = false
	_ws_any_recorded = false
	_sc_level = LIFETIME_MIN
	_sc_direction = 0
	_sc_reversals.clear()
	_sc_done = false
	is_running = true
	_start_trial()

func _start_trial() -> void:
	trial_number += 1
	_trial_caught = 0
	_trial_spawned = 0
	_trial_apple_start = outcome_log.size()
	if trial_number > 1:
		_trial_timer.start(trial_duration)
	trial_started.emit(trial_number)

func record_spawn() -> void:
	_trial_spawned += 1

func record_catch(lt: float) -> void:
	outcome_log.append({"lt": lt, "hit": 1, "pos": _last_spawn_pos})
	_trial_caught += 1
	if trial_number == 1 and not _sc_done and difficulty_mode == DifficultyMode.LIFETIME:
		_update_staircase(true)

func record_miss(lt: float) -> void:
	outcome_log.append({"lt": lt, "hit": 0, "pos": _last_spawn_pos})
	if trial_number == 1 and not _sc_done and difficulty_mode == DifficultyMode.LIFETIME:
		_update_staircase(false)

func get_apple_lifetime() -> float:
	if difficulty_mode == DifficultyMode.WORKSPACE:
		return LIFETIME_MAX
	if trial_number == 1:
		return _sc_level
	var center: float = threshold + offset
	var half_w: float = window_width * 0.5
	var lt_min: float = clamp(center - half_w, LIFETIME_MIN, LIFETIME_MAX)
	var lt_max: float = clamp(center + half_w, LIFETIME_MIN, LIFETIME_MAX)
	return randf_range(lt_min, max(lt_min + 0.01, lt_max))

func _update_staircase(hit: bool) -> void:
	var step: float = sc_step_fine if _sc_reversals.size() >= 2 else sc_step_coarse
	var new_dir: int = -1 if hit else 1   # catch → harder, miss → easier
	if _sc_direction != 0 and new_dir != _sc_direction:
		_sc_reversals.append(_sc_level)
		if _sc_reversals.size() >= sc_n_reversals:
			_sc_done = true
			var sum: float = 0.0
			for r in _sc_reversals:
				sum += r
			_sc_level = sum / _sc_reversals.size()
			_trial_timer.stop()
			call_deferred("_on_trial_timer_ended")
			return
	_sc_direction = new_dir
	_sc_level = clamp(_sc_level + new_dir * step, LIFETIME_MIN, LIFETIME_MAX)

func _calibrate_from_trial1() -> void:
	var data: Array = outcome_log.duplicate()
	if data.is_empty():
		return

	if difficulty_mode == DifficultyMode.WORKSPACE:
		_calibrate_workspace(data)
		_prev_error = rolling_rate - assigned_rate
		return

	var n_caught: int = 0
	for e in data:
		if e["hit"] == 1:
			n_caught += 1

	if _sc_done:
		threshold = _sc_level
	else:
		# fallback: timer expired before staircase completed
		var min_caught_lt: float = LIFETIME_MAX
		var max_missed_lt: float = LIFETIME_MIN
		for e in data:
			var lt := float(e["lt"])
			if e["hit"] == 1:
				min_caught_lt = min(min_caught_lt, lt)
			else:
				max_missed_lt = max(max_missed_lt, lt)
		if n_caught == 0:
			threshold = LIFETIME_MAX
		elif n_caught == data.size():
			threshold = LIFETIME_MIN
		else:
			threshold = (min_caught_lt + max_missed_lt) * 0.5

	offset = (assigned_rate - 0.5) * window_width
	rolling_rate = float(n_caught) / float(data.size())
	_prev_error = rolling_rate - assigned_rate
	trial_log.append({
		"trial": trial_number, "rate": rolling_rate,
		"apple_start": _trial_apple_start,
		"lt_lo": LIFETIME_MIN, "lt_hi": LIFETIME_MAX, "lt_threshold": threshold,
	})

func _rect_edge_dist(angle: float, dx: float, dy: float) -> float:
	var cx := absf(cos(angle))
	var cy := absf(sin(angle))
	if cx < 0.0001: return dy / max(cy, 0.0001)
	if cy < 0.0001: return dx / max(cx, 0.0001)
	return min(dx / cx, dy / cy)

func _rect_scale(pos: Vector2, ws_center: Vector2, dx: float, dy: float) -> float:
	var dir := pos - ws_center
	if dir.length() < 0.01: return 0.0
	var edge_d := _rect_edge_dist(atan2(dir.y, dir.x), dx, dy)
	return dir.length() / max(edge_d, 0.01)

func _calibrate_workspace(data: Array) -> void:
	var ws_center: Vector2 = (ws_min + ws_max) * 0.5
	var dx: float = max((ws_max.x - ws_min.x) * 0.5, 1.0)
	var dy: float = max((ws_max.y - ws_min.y) * 0.5, 1.0)
	var max_caught_scale: float = 0.0
	var min_missed_scale: float = 2.0
	var n_caught: int = 0
	var n_missed: int = 0
	for e in data:
		var scale: float = _rect_scale(e["pos"], ws_center, dx, dy)
		if e["hit"] == 1:
			max_caught_scale = max(max_caught_scale, scale)
			n_caught += 1
		else:
			min_missed_scale = min(min_missed_scale, scale)
			n_missed += 1
	if n_caught == 0:
		ws_threshold = 1.0
	elif n_missed == 0:
		ws_threshold = 1.0
	else:
		ws_threshold = (max_caught_scale + min_missed_scale) * 0.5
	ws_offset = (assigned_rate - 0.5) * WS_WINDOW_FRAC  # positive = easier = shift window inside edge
	rolling_rate = float(n_caught) / float(data.size())
	trial_log.append({"trial": trial_number, "rate": rolling_rate, "apple_start": _trial_apple_start})

func _update_difficulty() -> void:
	var resolved: int = outcome_log.size() - _trial_apple_start
	if resolved == 0:
		return
	rolling_rate = float(_trial_caught) / float(resolved)
	var error := rolling_rate - assigned_rate
	var derivative := error - _prev_error
	_prev_error = error
	_integral += error
	var correction: float = gain_i * _integral + gain_d * derivative
	if abs(error) > DEAD_BAND:
		correction += gain_p * error
	if difficulty_mode == DifficultyMode.WORKSPACE:
		var half_w: float = WS_WINDOW_FRAC * 0.5
		var min_ws_offset: float = -ws_threshold + half_w
		var max_ws_offset: float = (1.0 - ws_threshold) - half_w
		trial_log.append({"trial": trial_number, "rate": rolling_rate, "apple_start": _trial_apple_start})
		ws_offset = clamp(ws_offset - correction, min_ws_offset, max_ws_offset)
	else:
		var half_w: float = window_width * 0.5
		var center: float = threshold + offset
		trial_log.append({
			"trial": trial_number, "rate": rolling_rate,
			"apple_start": _trial_apple_start,
			"lt_lo": clamp(center - half_w, LIFETIME_MIN, LIFETIME_MAX),
			"lt_hi": clamp(center + half_w, LIFETIME_MIN, LIFETIME_MAX),
			"lt_threshold": threshold,
		})
		var min_offset: float = LIFETIME_MIN - threshold + half_w
		var max_offset: float = LIFETIME_MAX - threshold - half_w
		offset = clamp(offset - correction, min_offset, max_offset)

func update_workspace(screen_pos: Vector2) -> void:
	if trial_number != 1 or ws_calibrated:
		return
	if not _ws_any_recorded:
		ws_min = screen_pos
		ws_max = screen_pos
		_ws_any_recorded = true
	else:
		ws_min = ws_min.min(screen_pos)
		ws_max = ws_max.max(screen_pos)

func set_viewport_size(s: Vector2) -> void:
	_viewport_size = s

func get_spawn_position(player_pos: Vector2) -> Vector2:
	if not ws_calibrated:
		var s := _viewport_size
		_last_spawn_pos = Vector2(
			randi_range(int(s.x * 0.10), int(s.x * 0.85)),
			randi_range(int(s.y * 0.10), int(s.y * 0.85))
		)
		return _last_spawn_pos

	var ws_center: Vector2 = (ws_min + ws_max) * 0.5
	var spawn: Vector2

	if difficulty_mode == DifficultyMode.WORKSPACE:
		var dx: float = max((ws_max.x - ws_min.x) * 0.5, 1.0)
		var dy: float = max((ws_max.y - ws_min.y) * 0.5, 1.0)
		var angle: float = randf() * TAU
		var edge_d: float = _rect_edge_dist(angle, dx, dy)
		var center_scale: float = ws_threshold - ws_offset
		var half_w: float = WS_WINDOW_FRAC * 0.5
		var scale: float = randf_range(
			max(center_scale - half_w, 0.0),
			center_scale + half_w
		)
		spawn = ws_center + Vector2(cos(angle), sin(angle)) * scale * edge_d
		# clamp to screen only — apple may legitimately be outside workspace
		spawn.x = clamp(spawn.x, _viewport_size.x * 0.02, _viewport_size.x * 0.98)
		spawn.y = clamp(spawn.y, _viewport_size.y * 0.05, _viewport_size.y * 0.95)
	else:
		spawn = Vector2(randf_range(ws_min.x, ws_max.x), randf_range(ws_min.y, ws_max.y))

	var min_dist: float = (ws_max - ws_min).length() * 0.20
	var dir: Vector2 = spawn - player_pos
	if dir.length() < min_dist:
		if dir.length() < 0.01:
			dir = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
		else:
			dir = dir.normalized()
		spawn = player_pos + dir * min_dist
		if difficulty_mode == DifficultyMode.WORKSPACE:
			spawn.x = clamp(spawn.x, _viewport_size.x * 0.02, _viewport_size.x * 0.98)
			spawn.y = clamp(spawn.y, _viewport_size.y * 0.05, _viewport_size.y * 0.95)
		else:
			spawn.x = clamp(spawn.x, ws_min.x, ws_max.x)
			spawn.y = clamp(spawn.y, ws_min.y, ws_max.y)

	_last_spawn_pos = spawn
	return spawn

func _on_trial_timer_ended() -> void:
	if trial_number == 1:
		ws_calibrated = true
		_calibrate_from_trial1()
	else:
		_update_difficulty()
	trial_ended.emit(trial_number, _trial_caught, _trial_spawned)
	_between_timer.start(BETWEEN_DURATION)

func stop_session() -> void:
	_trial_timer.stop()
	_between_timer.stop()
	is_running = false

func _on_between_timer_ended() -> void:
	_start_trial()
