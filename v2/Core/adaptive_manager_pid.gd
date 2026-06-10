extends Node

signal trial_ended(trial_num: int, caught: int, spawned: int)
signal trial_started(trial_num: int)

enum DifficultyMode { LIFETIME, WORKSPACE }
var difficulty_mode: int = DifficultyMode.LIFETIME

var assigned_rate: float = 0.8

# R-space controller (LIFETIME mode)
var r_center: float    = 1.0   # PID window centre in r-space
var threshold_r: float = 1.0   # r at ~50% catch rate, found by staircase
const V_ASSUMED: float = 300.0 # px/s — constant used to convert r ↔ lifetime

# Workspace mode (unchanged)
var ws_threshold: float = 0.5
var ws_offset: float    = 0.0

var trial_number: int   = 0
var is_running: bool    = false
var rolling_rate: float = 0.0

var ws_min: Vector2         = Vector2.ZERO
var ws_max: Vector2         = Vector2.ZERO
var ws_calibrated: bool     = false
var _ws_any_recorded: bool  = false
var _viewport_size: Vector2 = Vector2(960.0, 540.0)
var _last_spawn_pos: Vector2      = Vector2.ZERO
var _player_pos_at_spawn: Vector2 = Vector2.ZERO
var _speed_estimate: float        = 0.0

var _trial_caught: int      = 0
var _trial_spawned: int     = 0
var _trial_apple_start: int = 0
var _integral: float        = 0.0
var outcome_log: Array      = []
var trial_log: Array        = []

var _trial_timer: Timer
var _between_timer: Timer

var gain_p: float          = 0.35
var gain_i: float          = 0.05
var gain_d: float          = 0.0
var _prev_error: float     = 0.0
var catch_hold_time: float = 1.0

const DEAD_BAND: float  = 0.05
var window_width: float = 0.30   # r units (dimensionless)

# Staircase calibration — step sizes in r units
var sc_step_coarse: float = 0.15
var sc_step_fine:   float = 0.05
var sc_n_reversals: int   = 6
var _sc_r: float         = 0.0
var _sc_direction: int   = 0
var _sc_reversals: Array = []
var _sc_done: bool       = false

const SC_R_MIN: float       = 0.05
const SC_R_MAX: float       = 3.00
const WS_WINDOW_FRAC: float = 0.30
var trial_duration: float   = 60.0
const BETWEEN_DURATION: float = 3.0
const LIFETIME_MAX: float = 8.0
const LIFETIME_MIN: float = 0.1

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
	assigned_rate    = rate
	r_center         = 1.0
	threshold_r      = 1.0
	ws_threshold     = 0.5
	ws_offset        = 0.0
	trial_number     = 0
	rolling_rate     = 0.0
	_integral        = 0.0
	_prev_error      = 0.0
	outcome_log.clear()
	trial_log.clear()
	_speed_estimate  = 0.0
	ws_calibrated    = false
	_ws_any_recorded = false
	_sc_r            = SC_R_MIN
	_sc_direction    = 0
	_sc_reversals.clear()
	_sc_done         = false
	is_running       = true
	_start_trial()

func _start_trial() -> void:
	trial_number       += 1
	_trial_caught       = 0
	_trial_spawned      = 0
	_trial_apple_start  = outcome_log.size()
	if trial_number > 1:
		_trial_timer.start(trial_duration)
	trial_started.emit(trial_number)

func record_spawn(player_pos: Vector2) -> void:
	_trial_spawned       += 1
	_player_pos_at_spawn  = player_pos

func record_catch(lt: float) -> void:
	var dist: float = _last_spawn_pos.distance_to(_player_pos_at_spawn)
	if lt > 0.0:
		_speed_estimate = max(_speed_estimate, dist / lt)
	outcome_log.append({"lt": lt, "hit": 1, "pos": _last_spawn_pos, "sheep_pos": _player_pos_at_spawn})
	_trial_caught += 1
	if trial_number == 1 and not _sc_done and difficulty_mode == DifficultyMode.LIFETIME:
		_update_staircase(true)

func record_miss(lt: float) -> void:
	outcome_log.append({"lt": lt, "hit": 0, "pos": _last_spawn_pos, "sheep_pos": _player_pos_at_spawn})
	if trial_number == 1 and not _sc_done and difficulty_mode == DifficultyMode.LIFETIME:
		_update_staircase(false)

# Spawn position must be fetched first; lifetime is then derived from the distance.
func get_apple_lifetime(player_pos: Vector2, spawn_pos: Vector2) -> float:
	if difficulty_mode == DifficultyMode.WORKSPACE:
		return LIFETIME_MAX
	var dist: float = max(player_pos.distance_to(spawn_pos), 1.0)
	var r: float
	if trial_number == 1:
		r = _sc_r
	else:
		var half_w: float = window_width * 0.5
		var lo: float = clamp(r_center - half_w, SC_R_MIN, SC_R_MAX)
		var hi: float = clamp(r_center + half_w, SC_R_MIN, SC_R_MAX)
		r = randf_range(lo, max(lo + 0.001, hi))
	return clamp(dist / max(r * V_ASSUMED, 0.001), LIFETIME_MIN, LIFETIME_MAX)

func _update_staircase(hit: bool) -> void:
	var step: float  = sc_step_fine if _sc_reversals.size() >= 2 else sc_step_coarse
	var new_dir: int = 1 if hit else -1   # catch → r up (harder), miss → r down (easier)
	if _sc_direction != 0 and new_dir != _sc_direction:
		_sc_reversals.append(_sc_r)
		if _sc_reversals.size() >= sc_n_reversals:
			_sc_done = true
			var sum: float = 0.0
			for rv in _sc_reversals:
				sum += rv
			threshold_r = sum / _sc_reversals.size()
			_trial_timer.stop()
			call_deferred("_on_trial_timer_ended")
			return
	_sc_direction = new_dir
	_sc_r = clamp(_sc_r + new_dir * step, SC_R_MIN, SC_R_MAX)

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

	if not _sc_done:
		# Fallback: timer expired before staircase completed.
		# Estimate threshold_r from highest-r catch and lowest-r miss.
		var max_caught_r: float = SC_R_MIN
		var min_missed_r: float = SC_R_MAX
		var has_catches := false
		var has_misses  := false
		for e in data:
			var dist: float = e["pos"].distance_to(e["sheep_pos"])
			var lt: float   = float(e["lt"])
			var r: float    = dist / max(lt * V_ASSUMED, 0.001)
			if e["hit"] == 1:
				max_caught_r = max(max_caught_r, r)
				has_catches  = true
			else:
				min_missed_r = min(min_missed_r, r)
				has_misses   = true
		if not has_catches:
			threshold_r = SC_R_MAX
		elif not has_misses:
			threshold_r = SC_R_MIN
		else:
			threshold_r = (max_caught_r + min_missed_r) * 0.5

	var half_w: float = window_width * 0.5
	r_center = clamp(threshold_r + window_width * (0.5 - assigned_rate), SC_R_MIN + half_w, SC_R_MAX - half_w)

	rolling_rate = float(n_caught) / float(data.size())
	_prev_error  = rolling_rate - assigned_rate

	var avg_dist: float = _avg_dist(data)
	trial_log.append({
		"trial": trial_number, "rate": rolling_rate,
		"apple_start": _trial_apple_start,
		"r_center": r_center, "r_lo": r_center - half_w, "r_hi": r_center + half_w,
		"threshold_r": threshold_r,
		"lt_lo":        avg_dist / max((r_center + half_w) * V_ASSUMED, 0.001),
		"lt_hi":        avg_dist / max((r_center - half_w) * V_ASSUMED, 0.001),
		"lt_threshold": avg_dist / max(threshold_r * V_ASSUMED, 0.001),
	})

func _avg_dist(data: Array) -> float:
	if data.is_empty():
		return 200.0
	var total: float = 0.0
	for e in data:
		total += float(e["pos"].distance_to(e["sheep_pos"]))
	return total / data.size()

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
	var ws_center: Vector2  = (ws_min + ws_max) * 0.5
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
	if n_caught == 0 or n_missed == 0:
		ws_threshold = 1.0
	else:
		ws_threshold = (max_caught_scale + min_missed_scale) * 0.5
	ws_offset    = (assigned_rate - 0.5) * WS_WINDOW_FRAC
	rolling_rate = float(n_caught) / float(data.size())
	trial_log.append({"trial": trial_number, "rate": rolling_rate, "apple_start": _trial_apple_start})

func _update_difficulty() -> void:
	var resolved: int = outcome_log.size() - _trial_apple_start
	if resolved == 0:
		return
	rolling_rate = float(_trial_caught) / float(resolved)
	var error: float      = rolling_rate - assigned_rate
	var derivative: float = error - _prev_error
	_prev_error  = error
	_integral   += error
	var correction: float = gain_i * _integral + gain_d * derivative
	if abs(error) > DEAD_BAND:
		correction += gain_p * error

	if difficulty_mode == DifficultyMode.WORKSPACE:
		var half_w: float        = WS_WINDOW_FRAC * 0.5
		var min_ws_offset: float = -ws_threshold + half_w
		var max_ws_offset: float = (1.0 - ws_threshold) - half_w
		trial_log.append({"trial": trial_number, "rate": rolling_rate, "apple_start": _trial_apple_start})
		ws_offset = clamp(ws_offset - correction, min_ws_offset, max_ws_offset)
	else:
		var half_w: float = window_width * 0.5
		r_center = clamp(r_center + correction, SC_R_MIN + half_w, SC_R_MAX - half_w)
		var trial_data: Array = outcome_log.slice(_trial_apple_start)
		var avg_dist: float   = _avg_dist(trial_data)
		trial_log.append({
			"trial": trial_number, "rate": rolling_rate,
			"apple_start": _trial_apple_start,
			"r_center": r_center, "r_lo": r_center - half_w, "r_hi": r_center + half_w,
			"threshold_r": threshold_r,
			"lt_lo":        avg_dist / max((r_center + half_w) * V_ASSUMED, 0.001),
			"lt_hi":        avg_dist / max((r_center - half_w) * V_ASSUMED, 0.001),
			"lt_threshold": avg_dist / max(threshold_r * V_ASSUMED, 0.001),
		})

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

# No apple_lt parameter — spawn position is chosen first, lifetime derived from distance.
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
		var dx: float         = max((ws_max.x - ws_min.x) * 0.5, 1.0)
		var dy: float         = max((ws_max.y - ws_min.y) * 0.5, 1.0)
		var angle: float      = randf() * TAU
		var edge_d: float     = _rect_edge_dist(angle, dx, dy)
		var center_scale: float = ws_threshold - ws_offset
		var half_w: float     = WS_WINDOW_FRAC * 0.5
		var scale: float      = randf_range(max(center_scale - half_w, 0.0), center_scale + half_w)
		spawn = ws_center + Vector2(cos(angle), sin(angle)) * scale * edge_d
		spawn.x = clamp(spawn.x, _viewport_size.x * 0.02, _viewport_size.x * 0.98)
		spawn.y = clamp(spawn.y, _viewport_size.y * 0.05, _viewport_size.y * 0.95)
	else:
		spawn = Vector2(randf_range(ws_min.x, ws_max.x), randf_range(ws_min.y, ws_max.y))

	var min_dist: float = (ws_max - ws_min).length() * 0.20
	var dir: Vector2    = spawn - player_pos
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
