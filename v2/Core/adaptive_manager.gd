extends Node

signal trial_ended(trial_num: int, caught: int, spawned: int)
signal trial_started(trial_num: int)

# ── Public state (read by random_reach.gd) ────────────────────────────────────
var assigned_rate:   float   = 0.8
var trial_number:    int     = 0
var is_running:      bool    = false
var rolling_rate:    float   = 0.0
var catch_hold_time: float   = 1.0
var ws_min:          Vector2 = Vector2.ZERO
var ws_max:          Vector2 = Vector2.ZERO
var ws_calibrated:   bool    = false
var fitts_a:         float   = 0.0
var fitts_b:         float   = 0.5
var difficulty:      float   = 0.0  # current pair ID, for CSV logging

# ── Phase ─────────────────────────────────────────────────────────────────────
enum Phase { WORKSPACE_SCAN, PRECISION_SCAN, FITTS_CAL, SESSION }
var _phase: Phase = Phase.WORKSPACE_SCAN

# ── Viewport ──────────────────────────────────────────────────────────────────
var _viewport_size: Vector2 = Vector2(960.0, 540.0)
var _center:        Vector2 = Vector2(480.0, 270.0)

# ── Phase 0a: Workspace scan ──────────────────────────────────────────────────
# 4 cardinal directions × 3 A fractions × 2 repeats = 24 apples
const SCAN_A_FRACS: Array  = [0.3, 0.5, 0.7]
const SCAN_REPEATS: int    = 2
const SCAN_LIFETIME: float = 6.0
var _scan_dir_vecs: Array  = [
	Vector2(1.0, 0.0), Vector2(0.0, -1.0),
	Vector2(-1.0, 0.0), Vector2(0.0, 1.0)
]
var _scan_dir_idx: int   = 0
var _scan_a_idx:   int   = 0
var _scan_rep:     int   = 0
var _scan_hit:     int   = 0
var _a_max:        Array = [0.0, 0.0, 0.0, 0.0]
var _a_global_max: float = 200.0

# ── Phase 0b: Precision scan ──────────────────────────────────────────────────
# Fixed A, 5 decreasing W values × 3 repeats = 15 apples
const PREC_W_VALUES: Array = [120.0, 90.0, 60.0, 40.0, 25.0]  # W = diameter (px)
const PREC_REPEATS:  int   = 3
var _prec_w_idx: int   = 0
var _prec_rep:   int   = 0
var _prec_hit:   int   = 0
var _w_min:      float = 120.0  # smallest usable W after scan

# ── Phase 0c: Fitts calibration ───────────────────────────────────────────────
# 10 pairs × 20 valid observations each
const NUM_PAIRS:    int = 10
const CAL_PER_PAIR: int = 20

var aw_pairs:      Array = []  # [{A, W, cal_n, mt_sum, mt_sq}]
var _cal_pair_idx: int   = 0
var _cal_rep:      int   = 0   # valid observations for current pair
var _cal_total:    int   = 0   # total attempts (guards against abort loops)

# ── Fitts model ───────────────────────────────────────────────────────────────
# Recursive least squares: theta = [a, b], P = 2×2 covariance
var _rls_theta: Array = [0.0, 0.5]
var _rls_P:     Array = [[1000.0, 0.0], [0.0, 1000.0]]
var _rls_n:     int   = 0
# Per-pair Welford state for residual SD: pair_idx → {n, mean, M2}
var _welford:   Dictionary = {}

# ── Current apple tracking ────────────────────────────────────────────────────
var _trial_caught:        int     = 0
var _trial_spawned:       int     = 0
var _trial_apple_start:   int     = 0
var _current_pair_idx:    int     = -1
var _spawn_time:          int     = 0     # ticks_msec at spawn
var _last_spawn_pos:      Vector2 = Vector2.ZERO
var _player_pos_at_spawn: Vector2 = Vector2.ZERO
var outcome_log:          Array   = []
var trial_log:            Array   = []

# ── Timers ────────────────────────────────────────────────────────────────────
var _trial_timer:   Timer
var _between_timer: Timer
var trial_duration:       float = 60.0
const BETWEEN_DURATION:   float = 3.0
const LIFETIME_MAX:       float = 8.0
const LIFETIME_MIN:       float = 0.1


func _ready() -> void:
	_trial_timer = Timer.new()
	_trial_timer.wait_time = trial_duration
	_trial_timer.one_shot  = true
	_trial_timer.timeout.connect(_on_trial_timer_ended)
	add_child(_trial_timer)

	_between_timer = Timer.new()
	_between_timer.wait_time = BETWEEN_DURATION
	_between_timer.one_shot  = true
	_between_timer.timeout.connect(_on_between_timer_ended)
	add_child(_between_timer)


func start_session(rate: float) -> void:
	assigned_rate     = rate
	trial_number      = 0
	rolling_rate      = 0.0
	is_running        = true
	ws_calibrated     = false
	_phase            = Phase.WORKSPACE_SCAN
	_scan_dir_idx     = 0;  _scan_a_idx = 0;  _scan_rep = 0;  _scan_hit = 0
	_a_max            = [0.0, 0.0, 0.0, 0.0];  _a_global_max = 200.0
	_prec_w_idx       = 0;  _prec_rep = 0;  _prec_hit = 0;  _w_min = 120.0
	_cal_pair_idx     = 0;  _cal_rep = 0;  _cal_total = 0
	_rls_theta        = [0.0, 0.5]
	_rls_P            = [[1000.0, 0.0], [0.0, 1000.0]]
	_rls_n            = 0
	_welford.clear()
	aw_pairs.clear()
	outcome_log.clear()
	trial_log.clear()
	_trial_caught     = 0;  _trial_spawned = 0
	_current_pair_idx = -1
	_center           = _viewport_size * 0.5


func set_viewport_size(s: Vector2) -> void:
	_viewport_size = s
	_center        = s * 0.5


func update_workspace(_screen_pos: Vector2) -> void:
	pass  # workspace determined by Phase 0a scan; kept for interface compatibility


# ─── Spawn & lifetime ─────────────────────────────────────────────────────────

func get_spawn_position(player_pos: Vector2) -> Vector2:
	var pos: Vector2
	match _phase:
		Phase.WORKSPACE_SCAN: pos = _scan_spawn()
		Phase.PRECISION_SCAN: pos = _prec_spawn()
		Phase.FITTS_CAL:      pos = _cal_spawn(player_pos)
		Phase.SESSION:        pos = _session_spawn(player_pos)
		_:                    pos = _center
	_last_spawn_pos = pos
	return pos


func get_apple_lifetime(_player_pos: Vector2, _spawn_pos: Vector2) -> float:
	if _phase != Phase.SESSION:
		return SCAN_LIFETIME
	return _fitts_lifetime()


func get_apple_radius() -> float:
	match _phase:
		Phase.PRECISION_SCAN:
			if _prec_w_idx < PREC_W_VALUES.size():
				return PREC_W_VALUES[_prec_w_idx] * 0.5
		Phase.FITTS_CAL, Phase.SESSION:
			if _current_pair_idx >= 0 and _current_pair_idx < aw_pairs.size():
				return aw_pairs[_current_pair_idx]["W"] * 0.5
	return 60.0


func record_spawn(player_pos: Vector2) -> void:
	_player_pos_at_spawn = player_pos
	_spawn_time          = Time.get_ticks_msec()
	_trial_spawned      += 1


func record_catch(_lt: float) -> void:
	var mt: float = (Time.get_ticks_msec() - _spawn_time) / 1000.0 - catch_hold_time
	_on_valid_mt(max(mt, 0.05), true)


func record_miss_completed() -> void:
	# Called from random_reach when player crosses target boundary after a miss
	var mt: float = (Time.get_ticks_msec() - _spawn_time) / 1000.0
	_on_valid_mt(max(mt, 0.05), false)


func record_miss(_lt: float) -> void:
	outcome_log.append({"hit": 0, "mt": -1.0, "pair_idx": _current_pair_idx})
	if _phase == Phase.FITTS_CAL:
		_cal_total += 1
		if _cal_total >= CAL_PER_PAIR * 2:
			_advance_cal_pair()


func _on_valid_mt(mt: float, is_hit: bool) -> void:
	outcome_log.append({"hit": 1 if is_hit else 0, "mt": mt, "pair_idx": _current_pair_idx})
	match _phase:
		Phase.WORKSPACE_SCAN: _on_scan_outcome(is_hit)
		Phase.PRECISION_SCAN: _on_prec_outcome(is_hit)
		Phase.FITTS_CAL:      _on_cal_outcome(mt)
		Phase.SESSION:
			if is_hit:
				_trial_caught += 1
			_update_fitts_online(mt)
			_update_rolling_rate()


# ─── Phase 0a: Workspace scan ─────────────────────────────────────────────────

func _scan_spawn() -> Vector2:
	var diag: float  = _viewport_size.length() * 0.5
	var a: float     = diag * SCAN_A_FRACS[_scan_a_idx]
	var dir: Vector2 = _scan_dir_vecs[_scan_dir_idx]
	_current_pair_idx = -1
	return (_center + dir * a).clamp(
		Vector2(_viewport_size.x * 0.05, _viewport_size.y * 0.05),
		Vector2(_viewport_size.x * 0.95, _viewport_size.y * 0.95)
	)


func _on_scan_outcome(hit: bool) -> void:
	if hit:
		_scan_hit += 1
	_scan_rep += 1
	if _scan_rep < SCAN_REPEATS:
		return
	var diag: float = _viewport_size.length() * 0.5
	var a: float    = diag * SCAN_A_FRACS[_scan_a_idx]
	if _scan_hit >= 1:
		_a_max[_scan_dir_idx] = max(_a_max[_scan_dir_idx], a)
	_scan_rep = 0;  _scan_hit = 0
	_scan_a_idx += 1
	if _scan_a_idx >= SCAN_A_FRACS.size():
		_scan_a_idx = 0
		_scan_dir_idx += 1
	if _scan_dir_idx >= _scan_dir_vecs.size():
		_finish_workspace_scan()


func _finish_workspace_scan() -> void:
	for a_val in _a_max:
		_a_global_max = max(_a_global_max, float(a_val))
	if _a_global_max < 50.0:
		_a_global_max = _viewport_size.length() * 0.25
	var r: float  = _a_global_max
	ws_min        = _center - Vector2(r, r)
	ws_max        = _center + Vector2(r, r)
	ws_calibrated = true
	_phase        = Phase.PRECISION_SCAN


# ─── Phase 0b: Precision scan ─────────────────────────────────────────────────

func _prec_spawn() -> Vector2:
	var a: float     = _a_global_max * 0.4
	var angle: float = randf() * TAU
	_current_pair_idx = -1
	return (_center + Vector2(cos(angle), sin(angle)) * a).clamp(
		Vector2(_viewport_size.x * 0.05, _viewport_size.y * 0.05),
		Vector2(_viewport_size.x * 0.95, _viewport_size.y * 0.95)
	)


func _on_prec_outcome(hit: bool) -> void:
	if hit:
		_prec_hit += 1
	_prec_rep += 1
	if _prec_rep < PREC_REPEATS:
		return
	if _prec_hit >= 2:
		_w_min = PREC_W_VALUES[_prec_w_idx]
	_prec_rep = 0;  _prec_hit = 0
	_prec_w_idx += 1
	if _prec_w_idx >= PREC_W_VALUES.size():
		_finish_precision_scan()


func _finish_precision_scan() -> void:
	_build_aw_pairs()
	_phase        = Phase.FITTS_CAL
	_cal_pair_idx = 0;  _cal_rep = 0;  _cal_total = 0


func _build_aw_pairs() -> void:
	aw_pairs.clear()
	_welford.clear()
	var w_high: float = 120.0
	var w_low:  float = max(_w_min, 40.0)
	var idx:    int   = 0
	for i in 5:
		var t: float = float(i) / 4.0
		var a: float = lerp(_a_global_max * 0.20, _a_global_max * 0.85, t)
		for w in [w_high, w_low]:
			aw_pairs.append({"A": a, "W": float(w), "cal_n": 0, "mt_sum": 0.0, "mt_sq": 0.0})
			_welford[idx] = {"n": 0, "mean": 0.0, "M2": 0.0}
			idx += 1


# ─── Phase 0c: Fitts calibration ──────────────────────────────────────────────

func _cal_spawn(player_pos: Vector2) -> Vector2:
	if aw_pairs.is_empty() or _cal_pair_idx >= aw_pairs.size():
		return _center
	_current_pair_idx = _cal_pair_idx
	var a: float      = aw_pairs[_cal_pair_idx]["A"]
	var angle: float  = randf() * TAU
	difficulty        = _fitts_id(aw_pairs[_cal_pair_idx]["A"], aw_pairs[_cal_pair_idx]["W"])
	return (player_pos + Vector2(cos(angle), sin(angle)) * a).clamp(
		Vector2(_viewport_size.x * 0.05, _viewport_size.y * 0.05),
		Vector2(_viewport_size.x * 0.95, _viewport_size.y * 0.95)
	)


func _on_cal_outcome(mt: float) -> void:
	var pair: Dictionary = aw_pairs[_cal_pair_idx]
	pair["cal_n"]  += 1
	pair["mt_sum"] += mt
	pair["mt_sq"]  += mt * mt
	_update_fitts_online(mt)
	_cal_rep   += 1
	_cal_total += 1
	if _cal_rep >= CAL_PER_PAIR:
		_advance_cal_pair()


func _advance_cal_pair() -> void:
	_cal_rep    = 0
	_cal_total  = 0
	_cal_pair_idx += 1
	if _cal_pair_idx >= aw_pairs.size():
		_finish_fitts_cal()


func _finish_fitts_cal() -> void:
	_fit_fitts_batch()
	_phase             = Phase.SESSION
	trial_number       = 0
	_trial_caught      = 0
	_trial_spawned     = 0
	_trial_apple_start = outcome_log.size()
	_start_trial()


func _fit_fitts_batch() -> void:
	var ids: Array = [];  var mts: Array = []
	for pair in aw_pairs:
		if pair["cal_n"] < 2:
			continue
		ids.append(_fitts_id(pair["A"], pair["W"]))
		mts.append(pair["mt_sum"] / pair["cal_n"])
	if ids.size() < 2:
		return
	var n: int = ids.size()
	var sx: float = 0.0;  var sy: float  = 0.0
	var sxx: float = 0.0; var sxy: float = 0.0
	for i in n:
		sx  += ids[i];  sy  += mts[i]
		sxx += ids[i] * ids[i];  sxy += ids[i] * mts[i]
	var denom: float = n * sxx - sx * sx
	if absf(denom) < 1e-6:
		return
	fitts_b    = (n * sxy - sx * sy) / denom
	fitts_a    = (sy - fitts_b * sx) / n
	_rls_theta = [fitts_a, fitts_b]
	# Initialise per-pair Welford from calibration variance
	for i in aw_pairs.size():
		var pair: Dictionary = aw_pairs[i]
		if pair["cal_n"] < 2:
			continue
		var id_:  float = _fitts_id(pair["A"], pair["W"])
		var pred: float = fitts_a + fitts_b * id_
		var n_i:  int   = pair["cal_n"]
		var mean: float = pair["mt_sum"] / n_i
		var var_: float = (pair["mt_sq"] - pair["mt_sum"] * pair["mt_sum"] / n_i) / (n_i - 1)
		_welford[i]     = {"n": n_i, "mean": mean - pred, "M2": var_ * (n_i - 1)}


# ─── SESSION ──────────────────────────────────────────────────────────────────

func _session_spawn(player_pos: Vector2) -> Vector2:
	if aw_pairs.is_empty():
		return _center
	_current_pair_idx    = randi_range(0, aw_pairs.size() - 1)
	var pair: Dictionary = aw_pairs[_current_pair_idx]
	var a: float         = pair["A"]
	var angle: float     = randf() * TAU
	difficulty           = _fitts_id(pair["A"], pair["W"])
	return (player_pos + Vector2(cos(angle), sin(angle)) * a).clamp(
		Vector2(_viewport_size.x * 0.05, _viewport_size.y * 0.05),
		Vector2(_viewport_size.x * 0.95, _viewport_size.y * 0.95)
	)


func _fitts_lifetime() -> float:
	if _current_pair_idx < 0 or _current_pair_idx >= aw_pairs.size():
		return 3.0
	var pair: Dictionary = aw_pairs[_current_pair_idx]
	var id_:  float      = _fitts_id(pair["A"], pair["W"])
	var pred: float      = _rls_theta[0] + _rls_theta[1] * id_
	var sd:   float      = _pair_sd(_current_pair_idx)
	var z:    float      = _z_from_rate(assigned_rate)
	return clamp(pred + z * sd, LIFETIME_MIN, LIFETIME_MAX)


# ─── Fitts math ───────────────────────────────────────────────────────────────

func _fitts_id(a: float, w: float) -> float:
	return log(a / max(w, 1.0) + 1.0) / log(2.0)


func _z_from_rate(rate: float) -> float:
	# Abramowitz & Stegun rational approximation for normal inverse CDF
	# Max error < 0.00045 for rate in [0.05, 0.95]
	rate = clamp(rate, 0.05, 0.95)
	if absf(rate - 0.5) < 0.001:
		return 0.0
	var p: float = rate if rate >= 0.5 else 1.0 - rate
	var t: float = sqrt(-2.0 * log(1.0 - p))
	var z: float = t - (2.515517 + 0.802853 * t + 0.010328 * t * t) / \
		(1.0 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t)
	return z if rate >= 0.5 else -z


func _pair_sd(pair_idx: int) -> float:
	if not _welford.has(pair_idx):
		return 0.3
	var w: Dictionary = _welford[pair_idx]
	if w["n"] < 2:
		return 0.3
	return sqrt(w["M2"] / float(w["n"] - 1))


# ─── Online Fitts update (RLS + Welford) ──────────────────────────────────────

func _update_fitts_online(mt: float) -> void:
	if _current_pair_idx < 0 or _current_pair_idx >= aw_pairs.size():
		return
	var pair: Dictionary = aw_pairs[_current_pair_idx]
	var id_:  float      = _fitts_id(pair["A"], pair["W"])
	# RLS update for (a, b)
	var x:    Array  = [1.0, id_]
	var pred: float  = _rls_theta[0] + _rls_theta[1] * id_
	var err:  float  = mt - pred
	var px:   Array  = [
		_rls_P[0][0] * x[0] + _rls_P[0][1] * x[1],
		_rls_P[1][0] * x[0] + _rls_P[1][1] * x[1]
	]
	var denom: float = 1.0 + x[0] * px[0] + x[1] * px[1]
	var g: Array     = [px[0] / denom, px[1] / denom]
	_rls_theta[0]   += g[0] * err;  _rls_theta[1] += g[1] * err
	fitts_a = _rls_theta[0];        fitts_b = _rls_theta[1]
	_rls_P[0][0] -= g[0] * px[0];  _rls_P[0][1] -= g[0] * px[1]
	_rls_P[1][0] -= g[1] * px[0];  _rls_P[1][1] -= g[1] * px[1]
	_rls_n += 1
	# Welford update for residual SD of this pair
	var residual: float = mt - (fitts_a + fitts_b * id_)
	if not _welford.has(_current_pair_idx):
		_welford[_current_pair_idx] = {"n": 0, "mean": 0.0, "M2": 0.0}
	var w: Dictionary = _welford[_current_pair_idx]
	w["n"] += 1
	var delta: float = residual - w["mean"]
	w["mean"]       += delta / float(w["n"])
	w["M2"]         += delta * (residual - w["mean"])


func _update_rolling_rate() -> void:
	var total: int = outcome_log.size() - _trial_apple_start
	if total <= 0:
		return
	var hits: int = 0
	for e in outcome_log.slice(_trial_apple_start):
		if e["hit"] == 1:
			hits += 1
	rolling_rate = float(hits) / float(total)


# ─── Trial management ─────────────────────────────────────────────────────────

func _start_trial() -> void:
	trial_number       += 1
	_trial_caught       = 0
	_trial_spawned      = 0
	_trial_apple_start  = outcome_log.size()
	_trial_timer.start(trial_duration)
	trial_started.emit(trial_number)


func _on_trial_timer_ended() -> void:
	trial_ended.emit(trial_number, _trial_caught, _trial_spawned)
	_between_timer.start(BETWEEN_DURATION)


func _on_between_timer_ended() -> void:
	_start_trial()


func stop_session() -> void:
	_trial_timer.stop()
	_between_timer.stop()
	is_running = false
