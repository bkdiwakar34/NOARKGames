extends Node2D

# One clinic visit (docs/clinic_study_interface.md §3-5; build plan §7.2,
# packages 1-3, and 5 for the look — night fireflies: night_sky.gd,
# night_life.gd, game_art.gd, effects.gd, sounds.gd):
#   reach scan -> warm-up -> calibration rounds -> calibration check -> play rounds.
# One target (a firefly; "apple" in the code and the files) at a time at one of
# the three fixed pairs; hold inside it for HOLD_S to catch it. Calibration
# rewards speed with points (3 / 2 / 1, shown as pips on the target) and waits
# up to the cap; play gives each pair the day's lifetime (difficulty.gd) and
# counts catches.
#
#   - Targets are placed and hit-tested in table mm (§3.4, table_space.gd); the
#     screen only draws them. The whole circle must lie inside the reach
#     outline from the scan (reach_scan.gd) and on screen, always at the
#     pair's exact distance (_spawn).
#   - Holds are judged per tracker sample on the camera's capture clock, so at
#     100 Hz rather than at the frame rate.
#   - MT = hold start − spawn, which equals catch − spawn − hold (design.md §4.6).
#   - An apple's "window" is how long a hold may take to start: the cap in
#     calibration, the lifetime in play. At the end of the window the apple
#     goes unless a hold is under way, which then finishes (caught) or breaks
#     (missed). So in play it is caught exactly when MT <= lifetime (§3.3), and
#     an apple on screen can always still be caught.
#
# clinic_main.gd sets `config` before adding it (participant, day, level,
# quick, show_check, and — when resuming a stopped day — the saved calibration)
# and keeps the study DB up to date from its signals. Keys: Enter / C / S on the
# calibration check, Enter on the last screen; Esc (clinic_main.gd) stops.

signal calibration_accepted(state: Dictionary)   # frozen calibration, for resuming
signal round_done(rounds_done: int)              # after each play round
signal finished                                  # the last play round ended
signal leave                                     # Enter on the last screen

const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")
const VisitLogger := preload("res://app/clinic/visit_logger.gd")
const ReachScan := preload("res://app/clinic/reach_scan.gd")
const Difficulty := preload("res://app/clinic/difficulty.gd")
const Art := preload("res://app/clinic/game_art.gd")
const Effects := preload("res://app/clinic/effects.gd")
const NightSky := preload("res://app/clinic/night_sky.gd")
const NightLife := preload("res://app/clinic/night_life.gd")
const Sounds := preload("res://app/clinic/sounds.gd")

const TIMEOUT_GRACE_S := 0.15     # samples reach Godot ~20 ms after capture; wait for them
const EDGE_MARGIN_PX := 12.0
const REPOSITION_W_MM := 60.0     # the uncounted apple that brings the hand where a pair fits
const SPOT_GRID_MM := 25.0        # grid for searching reposition spots
const FEW_SAMPLES := 20           # calibration check flags a pair with fewer apples
const STREAK := 3                 # this many "Perfect" catches in a row make a streak

const GOLD := Color("FFE27A")
const AMBER := Color(1.0, 0.75, 0.4)
const LASER := Color(0.95, 0.15, 0.10)   # the cursor, as in the patient game (ui_theme.gd LASER)
const TRAIL_MS := 600

enum Stage { SCAN, ROUND, REST, CHECK, DONE }

# {participant, day, level_index, order_id, quick, show_check, resume}.
# resume: {} for a fresh start, else the day record from study_db.gd
# (lifetimes, boundary, unfit, rounds_done, rounds_total).
var config: Dictionary = {}

var _ts: TableSpace
var _log: VisitLogger
var _scan: ReachScan
var _boundary := PackedVector2Array()   # reach outline, table mm; empty until the scan ends
var _rounds: Array = []          # [{phase, number}] in play order
var _round_idx: int = 0
var _stage: Stage = Stage.SCAN
var _stage_left: float = 0.0     # seconds left in the current round or rest
var _paused: bool = false        # tracker lost
var _quick: bool = false         # quick test: fewer rounds, short rests
var _attempt: int = 1            # calibration attempt; C / S on the check screen add one

var _hand: Vector2 = Vector2.ZERO   # latest hand position, table mm
var _apple: Dictionary = {}         # the current apple; empty = none
var _apple_n: int = 0               # apples spawned this round
var _pair_bag: Array = []           # every block of 3 apples uses each pair once
var _unfit: Dictionary = {}         # pair -> true: not played (fits nowhere / no lifetime)
var _no_fit: bool = false           # no pair left to play
var _spots: Dictionary = {}         # pair -> reposition spots (_spots_for)
var _repositions: int = 0           # reposition apples during calibration rounds
var _round_points: int = 0
var _round_caught: int = 0          # play: pair apples caught / missed this round
var _round_missed: int = 0
var _round_hits: int = 0            # calibration: apples that earned points this round
var _calib: Array = []              # per pair, this attempt's calibration: {caught, timeouts, mts}
var _lifetimes: Array = []          # per pair, s; -1 = not played
var _play: Array = []               # per pair: {caught, missed}

var _fx: Effects                    # catch / miss feedback (visual only)
var _life: NightLife                # the moving backdrop; flares on a streak
var _snd: Sounds
var _stage_t: float = 0.0           # seconds since the stage began (card animations)
var _shown_stage: int = -1
var _float_t: float = 0.0
var _spawn_after: float = 0.0       # the next target waits for the catch's hitstop
var _streak: int = 0                # "Perfect" catches in a row (calibration)
var _trail: Array = []              # cursor tail: [{pos (px), t (ms)}]
var _rounds_before: int = 0         # play rounds done before this session (a resumed day)


func _ready() -> void:
	var vp := get_viewport_rect().size
	_ts = TableSpace.new(vp)
	add_child(NightSky.new())
	_life = NightLife.new()
	add_child(_life)
	_snd = Sounds.new()
	add_child(_snd)
	_fx = Effects.new(vp)
	for k in Protocol.PAIRS.size():
		_play.append({"caught": 0, "missed": 0})
	_reset_calibration()
	_hand = _ts.screen_to_mm(vp * 0.5)
	_scan = ReachScan.new(_ts, vp)
	_quick = bool(config.get("quick", false))
	var resume: Dictionary = config.get("resume", {})
	if resume.is_empty():
		var calib: int = Protocol.QUICK_CALIB_ROUNDS if _quick else Protocol.CALIB_ROUNDS
		var play: int = Protocol.QUICK_PLAY_ROUNDS if _quick else Protocol.PLAY_ROUNDS
		for i in Protocol.WARMUP_ROUNDS:
			_rounds.append({"phase": "warmup", "number": i + 1})
		for i in calib:
			_rounds.append({"phase": "calibration", "number": i + 1})
		for i in play:
			_rounds.append({"phase": "play", "number": i + 1})
		_stage = Stage.SCAN
	else:
		_restore(resume)
	_log = VisitLogger.new()
	_log.open(String(config["participant"]), _header_lines())
	UDPReceiver.log_enabled = true
	# The participant sees only the laser dot; the system arrow is hidden (it
	# still moves, for the mouse fallback in development).
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


# A stopped day resumes play with its frozen calibration (§4.8): the remaining
# play rounds, after a rest to get ready.
func _restore(r: Dictionary) -> void:
	_lifetimes = r["lifetimes"]
	for pt in r["boundary"]:
		_boundary.append(Vector2(pt[0], pt[1]))
	for k in r["unfit"]:
		_unfit[int(k)] = true
	_rounds_before = int(r["rounds_done"])
	for i in range(int(r["rounds_done"]), int(r["rounds_total"])):
		_rounds.append({"phase": "play", "number": i + 1})
	_stage = Stage.REST
	_stage_left = _rest_s()


func _exit_tree() -> void:
	UDPReceiver.log_enabled = false
	_log.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # back for the operator screens


func _rest_s() -> float:
	return Protocol.QUICK_REST_S if _quick else Protocol.REST_S


func _rounds_of(phase: String) -> int:
	var n := 0
	for r in _rounds:
		if r["phase"] == phase:
			n += 1
	return n


func _header_lines() -> Array:
	var origin := "absent"
	var raw := FileAccess.get_file_as_string("res://pyscripts/origin_lock.json")
	if raw != "":
		origin = raw.replace(",", ";").replace("\n", " ").strip_edges()
	var pairs := PackedStringArray()
	for p in Protocol.PAIRS:
		pairs.append("%d/%d" % [int(p["a_mm"]), int(p["w_mm"])])
	var ppm := _ts.px_per_mm()
	var resume: Dictionary = config.get("resume", {})
	return [
		"participant,%s" % config["participant"],
		"study_day,%d" % int(config["day"]),
		"order_id,%d" % int(config["order_id"]),
		"level_index,%d" % (int(config["level_index"]) + 1),
		"level_p,%.2f" % _level_p(),
		"resumed_after_round,%s" % (str(int(resume["rounds_done"])) if not resume.is_empty() else ""),
		"protocol_version,%s%s" % [Protocol.VERSION, " locked" if Protocol.LOCKED else " draft"],
		"quick_test,%s" % _quick,
		"pairs_a_w_mm,%s" % " ".join(pairs),
		"hold_s,%s" % Protocol.HOLD_S,
		"point_cap_s,%s" % Protocol.POINT_CAP_S,
		"screen_mapped,%s" % _ts.mapped,
		"px_per_mm_x_y,%.3f %.3f" % [ppm.x, ppm.y],
		"origin_lock,%s" % origin,
	]


func _level_p() -> float:
	return Protocol.LEVELS[int(config["level_index"])]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = event.keycode
	if _stage == Stage.DONE:
		if key == KEY_ENTER or key == KEY_KP_ENTER:
			leave.emit()
	elif _stage == Stage.CHECK:
		if key == KEY_ENTER or key == KEY_KP_ENTER:
			_accept_calibration()
		elif key == KEY_C:
			_redo_calibration(false)
		elif key == KEY_S:
			_redo_calibration(true)


func _process(delta: float) -> void:
	_read_hand()
	_update_pause()
	if not _paused:
		match _stage:
			Stage.SCAN:
				_scan.update(delta)
				if _scan.is_done():
					var rows: Array = []
					for r in _scan.csv_rows():
						rows.append([_attempt] + r)
					_log.log_reach(rows)
					_boundary = _scan.boundary()
					_start_round()
			Stage.ROUND:
				_stage_left -= delta
				if _apple.is_empty():
					if _now() >= _spawn_after:   # after the last catch's hitstop
						_spawn()
				elif _apple_expired():
					_finish_apple("timeout", _window_end())
				if _stage_left <= 0.0:
					_end_round()
			Stage.REST:
				_stage_left -= delta
				if _stage_left <= 0.0:
					_start_round()
	# Visuals and sound only from here.
	if int(_stage) != _shown_stage:
		_shown_stage = int(_stage)
		_stage_t = 0.0
	var before := _stage_t
	_stage_t += delta
	if _stage == Stage.REST:
		# A bell for each star as it pops in on the rest card.
		for i in _rest_stars():
			var at := 0.25 + 0.28 * float(i)
			if before < at and _stage_t >= at:
				_snd.star(i)
	_fx.update(delta)
	var now_ms := Time.get_ticks_msec()
	var cur := _ts.mm_to_screen(_hand)
	if _trail.is_empty() or cur.distance_to(_trail[-1]["pos"]) > 3.0:
		_trail.append({"pos": cur, "t": now_ms})
	while not _trail.is_empty() and now_ms - int(_trail[0]["t"]) > TRAIL_MS:
		_trail.pop_front()
	if _stage == Stage.DONE:
		_float_t += delta
		if _float_t > 0.2:
			_float_t = 0.0
			var vp := get_viewport_rect().size
			_fx.float_up(Vector2(randf() * vp.x, vp.y + 10.0))
	queue_redraw()


# ── Hand samples ──────────────────────────────────────────────────────────────

func _now() -> float:
	return Time.get_unix_time_from_system()


# Feeds every tracker sample since the last frame to the hold logic and the
# hand log. UDPReceiver buffers them at tracker rate with the capture time.
func _read_hand() -> void:
	var samples: Array = UDPReceiver.take_samples()
	if not UDPReceiver.connected:
		# Mouse fallback (development only): one sample per frame, not logged.
		_on_sample(_now(), _ts.screen_to_mm(get_global_mouse_position()))
		return
	var phase := _phase_name()
	var rnd := _round_number()
	var rows: Array = []
	for s in samples:
		# s = [arrival, screen_x, screen_y, tracker_x, tracker_y, tracker_z, capture]
		var mm := TableSpace.tracker_to_mm(s[3], s[5])
		rows.append(["%.6f" % s[0], "%.6f" % s[6], phase, rnd,
			"%.2f" % mm.x, "%.2f" % mm.y, s[3], s[4], s[5]])
		_on_sample(s[6], mm)
	_log.log_hand(rows)


func _on_sample(t: float, mm: Vector2) -> void:
	_hand = mm
	if _stage == Stage.SCAN and not _paused:
		_scan.on_sample(t, mm)
		return
	if _paused or _stage != Stage.ROUND or _apple.is_empty():
		return
	var spawn: float = _apple["spawn_time"]
	if t < spawn:
		return
	if not TableSpace.inside(mm, _apple["centre"], _apple["w_mm"]):
		_apple["hold_start"] = -1.0
		return
	var hold_start: float = _apple["hold_start"]
	if hold_start < 0.0:
		if t - spawn <= float(_apple["window"]):   # past the window no new hold may start
			_apple["hold_start"] = t
			_snd.hold_started()
	elif t - hold_start >= Protocol.HOLD_S:
		_finish_apple("caught", t)


# Tracker was streaming but packets stopped: freeze the round and drop the
# apple, or restart the scan's current spoke.
func _update_pause() -> void:
	var lost: bool = UDPReceiver.connected and not UDPReceiver.is_fresh()
	if lost == _paused:
		return
	_paused = lost
	if not lost:
		return
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	if _stage == Stage.SCAN:
		_scan.restart_spoke()


# ── Rounds ────────────────────────────────────────────────────────────────────

func _start_round() -> void:
	_stage = Stage.ROUND
	_stage_left = Protocol.ROUND_S
	_fx.release_jar()
	_round_points = 0
	_round_caught = 0
	_round_missed = 0
	_round_hits = 0
	_apple_n = 0
	_pair_bag = []


func _end_round() -> void:
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	var ended: Dictionary = _rounds[_round_idx]
	_round_idx += 1
	if ended["phase"] == "play":
		round_done.emit(int(ended["number"]))
	if _round_idx >= _rounds.size():
		_stage = Stage.DONE
		UDPReceiver.log_enabled = false
		_log.close()
		finished.emit()
	elif ended["phase"] == "calibration" and _rounds[_round_idx]["phase"] == "play":
		_enter_check()
	else:
		_stage = Stage.REST
		_stage_left = _rest_s()


func _phase_name() -> String:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["phase"]
		Stage.REST:
			return "rest"
		Stage.SCAN:
			return "reach_scan"
		Stage.CHECK:
			return "check"
	return "done"


# The round being played; during a rest, the round just finished (0 before the
# first round of a resumed day).
func _round_number() -> int:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["number"]
		Stage.REST:
			return _prev_round().get("number", 0)
	return 0


# The round before the current one; {} at the start of a resumed day.
func _prev_round() -> Dictionary:
	return _rounds[_round_idx - 1] if _round_idx > 0 else {}


# ── Calibration -> play ───────────────────────────────────────────────────────

func _reset_calibration() -> void:
	_calib = []
	for k in Protocol.PAIRS.size():
		_calib.append({"caught": 0, "timeouts": 0, "mts": []})
	_repositions = 0


func _enter_check() -> void:
	_lifetimes = []
	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		_lifetimes.append(Difficulty.lifetime(c["mts"], c["timeouts"], _level_p()))
	if bool(config.get("show_check", true)):
		_stage = Stage.CHECK
	else:
		_accept_calibration()


# The model is frozen from here on (§3.3): these lifetimes hold for all of play.
func _accept_calibration() -> void:
	var rows: Array = []
	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		var lt: float = _lifetimes[k]
		if lt < 0.0:
			_unfit[k] = true
		rows.append([_attempt, k + 1, _pair_a(k), _pair_w(k), c["caught"], c["timeouts"],
			_median_text(c["mts"], false), "%.2f" % _level_p(),
			("%.4f" % lt) if lt >= 0.0 else ""])
	_log.log_calibration(rows)
	var boundary: Array = []
	for pt in _boundary:
		boundary.append([pt.x, pt.y])
	calibration_accepted.emit({
		"lifetimes": _lifetimes.duplicate(), "boundary": boundary, "unfit": _unfit.keys(),
		"rounds_total": _rounds_of("play"),
	})
	_no_fit = false
	_stage = Stage.REST
	_stage_left = _rest_s()


# C: play the calibration rounds again. S: the reach scan first, then them.
func _redo_calibration(rescan: bool) -> void:
	_attempt += 1
	_reset_calibration()
	_round_idx = Protocol.WARMUP_ROUNDS
	_no_fit = false
	if rescan:
		_boundary = PackedVector2Array()
		_spots = {}
		_unfit = {}
		_scan = ReachScan.new(_ts, get_viewport_rect().size)
		_stage = Stage.SCAN
	else:
		_start_round()


# ── Apples ────────────────────────────────────────────────────────────────────

# Every counted apple sits at its pair's exact distance A from the hand — never
# shortened. When the hand is somewhere the pairs still due in this block do not
# fit from:
#   1. try the other pairs still due in the block;
#   2. else put an uncounted "reposition" apple (big, easy) at the nearest spot
#      from which a due pair does fit, so the next apple can go at full distance;
#   3. a pair that fits from nowhere in the reach area is skipped for the visit
#      (the summary says so: the pair values are too big for this reach).
func _spawn() -> void:
	if _no_fit:
		return
	if _pair_bag.is_empty():
		for k in Protocol.PAIRS.size():
			if not _unfit.has(k):
				_pair_bag.append(k)
		if _pair_bag.is_empty():
			_no_fit = true
			return
		_pair_bag.shuffle()
	for i in range(_pair_bag.size() - 1, -1, -1):
		var k: int = _pair_bag[i]
		var angles := _fit_angles(_hand, _pair_a(k), _pair_w(k) * 0.5, 36)
		if not angles.is_empty():
			_pair_bag.remove_at(i)
			var ang: float = angles.pick_random()
			_new_apple("pair", k, _hand + Vector2.from_angle(ang) * _pair_a(k), _pair_w(k))
			return
	for i in range(_pair_bag.size() - 1, -1, -1):
		var k: int = _pair_bag[i]
		var spot = _reposition_spot(k)
		if spot != null:
			_new_apple("reposition", -1, spot, REPOSITION_W_MM)
			return
		_pair_bag.remove_at(i)
		_unfit[k] = true


func _new_apple(kind: String, k: int, centre: Vector2, w: float) -> void:
	var t := _now()
	var dist := _hand.distance_to(centre)
	var in_play := _phase_name() == "play" and kind == "pair"
	var window: float = _lifetimes[k] if in_play else Protocol.POINT_CAP_S
	_apple_n += 1
	_apple = {
		"kind": kind, "pair": k, "a_mm": _pair_a(k) if k >= 0 else dist, "w_mm": w,
		"n": _apple_n, "start": _hand, "centre": centre,
		"angle": (centre - _hand).angle(), "a_actual": dist,
		"spawn_time": t, "hold_start": -1.0, "play": in_play, "window": window,
	}


func _window_end() -> float:
	return float(_apple["spawn_time"]) + float(_apple["window"])


# Past its window with no hold under way. The grace lets the last tracker
# samples of the window arrive (they reach Godot ~20 ms after capture).
func _apple_expired() -> bool:
	return float(_apple["hold_start"]) < 0.0 and _now() > _window_end() + TIMEOUT_GRACE_S


func _pair_a(k: int) -> float:
	return Protocol.PAIRS[k]["a_mm"]


func _pair_w(k: int) -> float:
	return Protocol.PAIRS[k]["w_mm"]


# Directions (radians) in which a circle of radius r at distance a from start fits.
func _fit_angles(start: Vector2, a: float, r: float, n: int) -> Array:
	var out: Array = []
	var offset := randf() * TAU
	for i in n:
		var ang := offset + TAU * float(i) / float(n)
		if _fits(start + Vector2.from_angle(ang) * a, r):
			out.append(ang)
	return out


# Nearest spot to the hand from which pair k fits in plenty of directions
# (at least half as many as the best spot), so where the hand ends up inside
# the reposition circle does not matter. null when the pair fits from nowhere.
func _reposition_spot(k: int) -> Variant:
	var spots := _spots_for(k)
	if spots.is_empty():
		return null
	var most := 0
	for s in spots:
		most = maxi(most, s["n"])
	var pick = null
	var nearest := INF
	for s in spots:
		var d := _hand.distance_to(s["pos"])
		if int(s["n"]) * 2 >= most and d < nearest:
			nearest = d
			pick = s["pos"]
	return pick


# Grid points (every SPOT_GRID_MM) where a reposition apple fits and from which
# pair k fits in some direction: [{pos, n = how many of 24 directions}].
# Computed once per pair, the first time it is needed.
func _spots_for(k: int) -> Array:
	if _spots.has(k):
		return _spots[k]
	var area := Rect2(_boundary[0], Vector2.ZERO) if _boundary.size() >= 3 \
		else Rect2(_ts.screen_to_mm(Vector2.ZERO), Vector2.ZERO)
	for b in _boundary:
		area = area.expand(b)
	if _boundary.size() < 3:
		area = area.expand(_ts.screen_to_mm(get_viewport_rect().size))
	var list: Array = []
	var x := area.position.x
	while x <= area.end.x:
		var y := area.position.y
		while y <= area.end.y:
			var p := Vector2(x, y)
			if _fits(p, REPOSITION_W_MM * 0.5):
				var n := _fit_angles(p, _pair_a(k), _pair_w(k) * 0.5, 24).size()
				if n > 0:
					list.append({"pos": p, "n": n})
			y += SPOT_GRID_MM
		x += SPOT_GRID_MM
	_spots[k] = list
	return list


# The whole circle is on screen and inside the reach outline.
func _fits(centre: Vector2, r: float) -> bool:
	if not _ts.fits_on_screen(centre, r, get_viewport_rect().size, EDGE_MARGIN_PX):
		return false
	if _boundary.size() < 3:
		return true
	for i in 16:
		var p := centre + Vector2.from_angle(TAU * float(i) / 16.0) * r
		if not Geometry2D.is_point_in_polygon(p, _boundary):
			return false
	return true


func _finish_apple(outcome: String, t: float) -> void:
	var a: Dictionary = _apple
	_apple = {}
	var k: int = a["pair"]
	var reposition: bool = a["kind"] == "reposition"
	var in_play: bool = a["play"]
	var in_calib := _phase_name() == "calibration" and not reposition
	if outcome == "timeout" and in_play:
		outcome = "missed"
	var caught := outcome == "caught"
	var mt := -1.0
	var pts := 0
	if caught:
		mt = float(a["hold_start"]) - float(a["spawn_time"])
	if reposition and _phase_name() == "calibration":
		_repositions += 1
	if in_play:
		if caught:
			_play[k]["caught"] += 1
			_round_caught += 1
		elif outcome == "missed":
			_play[k]["missed"] += 1
			_round_missed += 1
	elif caught and _phase_name() != "play":
		pts = Protocol.points_for(mt)
		_round_points += pts
		_round_hits += 1
	if in_calib:
		if caught:
			_calib[k]["caught"] += 1
			_calib[k]["mts"].append(mt)
		elif outcome == "timeout":
			_calib[k]["timeouts"] += 1
	var start: Vector2 = a["start"]
	var centre: Vector2 = a["centre"]
	# Reposition apples: phase "reposition", pair 0, so a filter on the phase
	# leaves them out.
	_log.log_target([
		"reposition" if reposition else _phase_name(), _attempt, _round_number(), a["n"],
		k + 1, "%.1f" % a["a_mm"], a["w_mm"],
		"%.1f" % a["a_actual"], "%.1f" % rad_to_deg(a["angle"]),
		"%.2f" % start.x, "%.2f" % start.y, "%.2f" % centre.x, "%.2f" % centre.y,
		"%.6f" % a["spawn_time"], ("%.4f" % a["window"]) if in_play else "",
		("%.6f" % a["hold_start"]) if caught else "",
		outcome, "%.6f" % t, ("%.4f" % mt) if caught else "", pts,
	])
	# Feedback only (already logged): a catch holds still for a moment (hitstop,
	# longer for a better grade), bursts with its grade and sound, and flies to
	# the jar; a miss dims and sinks; an aborted one just goes.
	var pos := _ts.mm_to_screen(centre)
	var size := _target_size(float(a["w_mm"]))
	if caught:
		var grade := 0 if in_play else pts
		_spawn_after = _now() + _fx.catch_at(pos, size, grade)
		_snd.caught(grade)
		if not in_play:
			_streak = _streak + 1 if pts == 3 else 0
			if _streak > 0 and _streak % STREAK == 0:
				_life.flare = 1.0
				_snd.streak()
				_fx.word(Vector2(get_viewport_rect().size.x * 0.5, 120.0), "Streak ×%d" % _streak, "", GOLD, 30)
	elif outcome == "missed" or outcome == "timeout":
		_fx.miss_at(pos, size)
		_snd.missed()
		_streak = 0


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	var vp := get_viewport_rect().size
	# The night backdrop is two children drawn behind this node (night_sky.gd, night_life.gd).
	if _stage == Stage.ROUND or _stage == Stage.REST:
		_fx.draw_jar(self)
	if _stage == Stage.ROUND and not _paused and not _apple.is_empty():
		_draw_apple()
	_fx.draw(self)
	if _stage == Stage.SCAN:
		_scan.draw(self, Art.font())
	_draw_cursor()
	_draw_hud(vp)
	if _stage == Stage.ROUND and _no_fit:
		_label(vp * 0.5, "None of the pairs fits this reach area", 24, AMBER)
	if _stage == Stage.ROUND and _phase_name() == "play" and bool(config.get("show_check", false)):
		_draw_overlay(vp)
	match _stage:
		Stage.REST:
			_draw_rest(vp)
		Stage.CHECK:
			_draw_check(vp)
		Stage.DONE:
			_draw_complete(vp)
	if _paused:
		_draw_pause(vp)
	if not _ts.mapped:
		draw_string(Art.font(), Vector2(16.0, vp.y - 12.0),
			"Screen mapping not set: drawing at 3 px/mm. Run the 4-corner mapping in the installer.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER)


# Text with a soft dark halo, readable anywhere on the night sky.
func _label(pos: Vector2, s: String, size: int, col: Color) -> void:
	Art.text(self, pos, s, size, col, Color(0.02, 0.03, 0.08, 0.6))


# The catch circle on screen: W mm across, which may be a slight ellipse when
# the screen mapping scales x and y differently (§3.4).
func _target_size(w_mm: float) -> Vector2:
	var ppm := _ts.px_per_mm()
	return Vector2(w_mm * ppm.x, w_mm * ppm.y)


# Points it is worth right now (calibration): 3, 2, 1 as the limits pass.
func _worth(now: float) -> int:
	return Protocol.points_for(now - float(_apple["spawn_time"]))


# The target is one object: a firefly whose edge is the catch circle.
#   calibration: three pips above it, one fading at each point limit (3 -> 2 -> 1);
#   holding:     it fills with light from its centre — full = caught;
#   play:        its own edge drains over the lifetime (no extra ring).
func _draw_apple() -> void:
	var centre: Vector2 = _apple["centre"]
	var w: float = _apple["w_mm"]
	var now := _now()
	var age := now - float(_apple["spawn_time"])
	var c := _ts.mm_to_screen(centre)
	var size := _target_size(w)
	var inside := TableSpace.inside(_hand, centre, w)
	var pop := 1.0   # appears with a little overshoot
	if age < 0.16:
		pop = age / 0.16 * 1.1
	elif age < 0.3:
		pop = lerpf(1.1, 1.0, (age - 0.16) / 0.14)
	# A light, not a ball: wide halo, see-through body, bright core, and a thin
	# bright rim that marks W exactly.
	var breath := 1.0 + 0.07 * sin(now * 3.2)
	Art.blit(self, Art.glow(), c, size * (3.4 * breath) * pop, Color(Art.FF_GLOW, 0.5 if inside else 0.34))
	Art.blit(self, Art.disc(), c, size * pop, Color(Art.FF_GLOW, 0.20 if inside else 0.13))
	Art.blit(self, Art.glow(), c, size * (0.95 * breath) * pop, Color(Art.FF_CORE, 0.85))
	Art.blit(self, Art.disc(), c, size * 0.12 * pop, Color.WHITE)
	var hold_start: float = _apple["hold_start"]
	if hold_start >= 0.0:
		var frac: float = clampf((now - hold_start) / Protocol.HOLD_S, 0.0, 1.0)
		Art.blit(self, Art.disc(), c, size * frac, Color(1.0, 1.0, 0.92, 0.75))
		Art.blit(self, Art.glow(), c, size * (1.2 + 1.6 * frac), Color(1.0, 1.0, 0.88, 0.4 * frac))
	var rim := Color(1.0, 1.0, 0.95, 0.95) if inside else Color(Art.FF_BODY, 0.85)
	var rim_w := 3.0 if inside else 2.0
	if _apple["play"]:
		# Play: the rim itself drains over the lifetime.
		var window: float = _apple["window"]
		var left := clampf((_window_end() - now) / window, 0.0, 1.0)
		_arc(centre, w * 0.5, 1.0, Color(rim, 0.18), rim_w)
		_arc(centre, w * 0.5, left, rim, rim_w + 1.0)
	else:
		_arc(centre, w * 0.5, 1.0, rim, rim_w)
	if not _apple["play"] and _apple["kind"] == "pair":
		var worth := _worth(now) if hold_start < 0.0 else Protocol.points_for(hold_start - float(_apple["spawn_time"]))
		for i in 3:
			var p := c + Vector2((float(i) - 1.0) * 16.0, -size.y * 0.5 - 16.0)
			if i < worth:
				Art.blit(self, Art.glow(), p, Vector2(26.0, 26.0), Color(Art.GOLD, 0.7))
				Art.blit(self, Art.disc(), p, Vector2(9.0, 9.0), Color.WHITE)
			else:
				Art.blit(self, Art.disc(), p, Vector2(7.0, 7.0), Color(1, 1, 1, 0.2))


# Part of a table-space ring, from the top, clockwise.
func _arc(centre: Vector2, r_mm: float, frac: float, col: Color, width: float) -> void:
	var n := int(clampf(frac, 0.0, 1.0) * 64.0)
	if n < 1:
		return
	var pts := PackedVector2Array()
	for i in n + 1:
		var a := -PI * 0.5 + TAU * float(i) / 64.0
		pts.append(_ts.mm_to_screen(centre + Vector2(cos(a), sin(a)) * r_mm))
	draw_polyline(pts, col, width, true)


# The hand: a laser-pointer dot with a fading tail, as in the patient game
# (GoodNotes style): red glow, red body, white-hot centre; the tail is the last
# TRAIL_MS of movement, wide and faint outside, thin and bright inside.
func _draw_cursor() -> void:
	var now := Time.get_ticks_msec()
	for pass_i in 2:
		for i in range(1, _trail.size()):
			var age := float(now - int(_trail[i]["t"])) / float(TRAIL_MS)
			if pass_i == 0:
				draw_line(_trail[i - 1]["pos"], _trail[i]["pos"], Color(LASER, (1.0 - age) * 0.22),
					lerpf(20.0, 6.0, age), true)
			else:
				draw_line(_trail[i - 1]["pos"], _trail[i]["pos"], Color(1.0, 0.75, 0.70, (1.0 - age) * 0.85),
					lerpf(6.0, 2.0, age), true)
	var c := _ts.mm_to_screen(_hand)
	Art.blit(self, Art.glow(), c, Vector2(62.0, 62.0), Color(LASER, 0.45))
	Art.blit(self, Art.disc(), c, Vector2(28.0, 28.0), LASER)
	Art.blit(self, Art.disc(), c, Vector2(11.0, 11.0), Color(1.0, 0.95, 0.92))


# Round progress (a segment per round, the current one filling) and the score plate.
func _draw_hud(vp: Vector2) -> void:
	if _stage != Stage.ROUND and _stage != Stage.REST:
		return   # scan, check, done: no round HUD
	var play: bool = _phase_name() == "play" or (_stage == Stage.REST \
		and _prev_round().get("phase", "play") == "play")
	var segs: Array = []
	for i in _rounds.size():
		if (_rounds[i]["phase"] == "play") == play:
			segs.append(i)
	# Round progress: a dot per round in a glass pill; done rounds glow. On a
	# resumed day the rounds played before the stop come first, as done.
	var before := _rounds_before if play else 0
	var n := segs.size() + before
	var w := float(n) * 17.0 + 22.0
	var pill := Rect2(vp.x * 0.5 - w * 0.5, 16.0, w, 30.0)
	Art.draw_glass(self, pill, 15)
	for j in n:
		var gi: int = -1 if j < before else segs[j - before]
		var p := Vector2(pill.position.x + 19.0 + float(j) * 17.0, pill.get_center().y)
		if gi < _round_idx:
			Art.blit(self, Art.glow(), p, Vector2(22.0, 22.0), Color(Art.FF_GLOW, 0.6))
			Art.blit(self, Art.disc(), p, Vector2(9.0, 9.0), Art.FF_BODY)
		elif gi == _round_idx and _stage == Stage.ROUND:
			var frac := clampf(1.0 - _stage_left / Protocol.ROUND_S, 0.0, 1.0)
			draw_arc(p, 7.0, 0.0, TAU, 24, Color(1, 1, 1, 0.25), 2.0, true)
			if frac > 0.0:
				draw_arc(p, 7.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, Color.WHITE, 2.0, true)
			Art.blit(self, Art.disc(), p, Vector2(6.0, 6.0), Color.WHITE)
		else:
			Art.blit(self, Art.disc(), p, Vector2(7.0, 7.0), Color(1, 1, 1, 0.22))
	# Score: caught this round (play) or points (calibration).
	var score := str(_round_caught) if play else str(_round_points)
	var unit := "caught" if play else "points"
	var sw := Art.text_width(score, 32) + Art.text_width(unit, 15) + 52.0
	var plate := Rect2(vp.x - 20.0 - sw, 14.0, sw, 50.0)
	Art.draw_glass(self, plate, 16)
	var f := Art.font()
	draw_string(f, plate.position + Vector2(20.0, 36.0), score, HORIZONTAL_ALIGNMENT_LEFT, -1, 32, Art.INK)
	draw_string(f, plate.position + Vector2(28.0 + Art.text_width(score, 32), 36.0), unit,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Art.INK_SOFT)


func _dim(vp: Vector2, a: float = 0.45) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.08, a))


# Glass pill with a small draining ring: "Next round in 12".
func _countdown_pill(centre: Vector2, text: String) -> void:
	var w := Art.text_width(text, 18) + 70.0
	var rect := Rect2(centre.x - w * 0.5, centre.y - 21.0, w, 42.0)
	Art.draw_glass(self, rect, 21)
	var rc := rect.position + Vector2(24.0, 21.0)
	draw_arc(rc, 10.0, 0.0, TAU, 32, Color(1, 1, 1, 0.18), 4.0, true)
	var left := clampf(_stage_left / _rest_s(), 0.0, 1.0)
	if left > 0.0:
		draw_arc(rc, 10.0, -PI * 0.5, -PI * 0.5 + TAU * left, 32, Art.FF_BODY, 4.0, true)
	Art.text(self, rect.get_center() + Vector2(14.0, 0.0), text, 18, Art.INK)


# How many stars the rest card shows (for the star bells in _process).
func _rest_stars() -> int:
	var prev := _prev_round()
	if prev.is_empty():
		return 0
	if prev["phase"] == "play":
		return roundi(5.0 * float(_round_caught) / float(maxi(_round_caught + _round_missed, 1)))
	return roundi(5.0 * float(_round_points) / float(maxi(3 * _round_hits, 1)))


# Five stars that pop in one by one, the first `filled` gold.
func _stars(centre: Vector2, filled: int, big: float) -> void:
	for i in 5:
		var p := centre + Vector2(float(i - 2) * big * 2.3, -6.0 if i == 2 else 0.0)
		var rr := big * (1.2 if i == 2 else 1.0)
		Art.draw_star(self, p, rr, false)
		if i < filled:
			var st := clampf((_stage_t - 0.25 - 0.28 * float(i)) / 0.3, 0.0, 1.0)
			if st > 0.0:
				var sc := st * 1.25 if st < 0.7 else lerpf(1.25, 1.0, (st - 0.7) / 0.3)
				Art.draw_star(self, p, rr * sc, true)


# Rest card, TypingClub style: stars, a ring that fills to the round's result,
# the number counting up, and the countdown (§4.6).
func _draw_rest(vp: Vector2) -> void:
	_dim(vp)
	var card := Rect2(vp.x * 0.5 - 250.0, vp.y * 0.5 - 200.0, 500.0, 380.0)
	Art.draw_card(self, card)
	var cx := card.get_center().x
	var prev := _prev_round()
	if prev.is_empty():   # a resumed day
		Art.text(self, Vector2(cx, card.position.y + 120.0), "Welcome back", 38, Art.INK)
		Art.text(self, Vector2(cx, card.position.y + 175.0), "Day %d continues" % int(config["day"]),
			20, Art.INK_SOFT)
		_countdown_pill(Vector2(cx, card.end.y - 60.0), "First round in %d" % ceili(_stage_left))
		return
	var play: bool = prev["phase"] == "play"
	var frac := 0.0
	var ring_col := Art.FF_BODY
	if play:
		frac = float(_round_caught) / float(maxi(_round_caught + _round_missed, 1))
	else:
		frac = float(_round_points) / float(maxi(3 * _round_hits, 1))
		ring_col = Art.GOLD
	var grow := 1.0 - pow(1.0 - clampf((_stage_t - 0.3) / 1.1, 0.0, 1.0), 3.0)   # ease out
	_stars(Vector2(cx, card.position.y + 70.0), _rest_stars(), 24.0)
	var rc := Vector2(cx, card.position.y + 190.0)
	draw_arc(rc, 62.0, 0.0, TAU, 72, Color(1, 1, 1, 0.1), 14.0, true)
	if frac * grow > 0.0:
		Art.blit(self, Art.glow(), rc, Vector2(230.0, 230.0), Color(ring_col, 0.12 * grow))
		draw_arc(rc, 62.0, -PI * 0.5, -PI * 0.5 + TAU * frac * grow, 72, ring_col, 14.0, true)
	var big := "%d%%" % roundi(100.0 * frac * grow) if play else str(roundi(float(_round_points) * grow))
	Art.text(self, rc + Vector2(0.0, -6.0), big, 40, Art.INK)
	Art.text(self, rc + Vector2(0.0, 26.0), "caught" if play else "points", 15, Art.INK_SOFT)
	var line := "%d of %d fireflies" % [_round_caught, _round_caught + _round_missed] if play \
		else "Faster catches earn more"
	Art.text(self, Vector2(cx, card.position.y + 285.0), line, 17, Art.INK_SOFT)
	_countdown_pill(Vector2(cx, card.end.y - 42.0), "Next round in %d" % ceili(_stage_left))


# Closing card (§4.7): stars and the whole session's result; Enter returns to Home.
func _draw_complete(vp: Vector2) -> void:
	_dim(vp, 0.32)
	var card := Rect2(vp.x * 0.5 - 300.0, vp.y * 0.5 - 235.0, 600.0, 460.0)
	Art.draw_card(self, card)
	var cx := card.get_center().x
	var y0 := card.position.y
	var c := 0
	var n := 0
	for k in Protocol.PAIRS.size():
		c += int(_play[k]["caught"])
		n += int(_play[k]["caught"]) + int(_play[k]["missed"])
	var frac := float(c) / float(maxi(n, 1))
	Art.text(self, Vector2(cx, y0 + 62.0), "Session complete", 38, Art.INK)
	Art.text(self, Vector2(cx, y0 + 104.0), "Thank you — well played", 18, Art.INK_SOFT)
	_stars(Vector2(cx, y0 + 165.0), roundi(5.0 * frac), 26.0)
	var tiles: Array = [["%d%%" % roundi(100.0 * frac), "fireflies caught"],
		[str(_rounds_of("play") + _rounds_before), "rounds played"]]
	for i in 2:
		var tile := Rect2(cx - 185.0 + float(i) * 200.0, y0 + 222.0, 170.0, 84.0)
		Art.draw_glass(self, tile, 18)
		Art.text(self, tile.get_center() + Vector2(0.0, -12.0), tiles[i][0], 32, Art.INK)
		Art.text(self, tile.get_center() + Vector2(0.0, 22.0), tiles[i][1], 14, Art.INK_SOFT)
	var btn := Rect2(cx - 100.0, y0 + 336.0, 200.0, 54.0)
	Art.blit(self, Art.glow(), btn.get_center(), Vector2(320.0, 150.0), Color(Art.FF_GLOW, 0.18))
	draw_style_box(Art._box(Art.FF_BODY, 27), btn)
	Art.text(self, btn.get_center(), "Done  (Enter)", 22, Art.NAVY)
	Art.text(self, Vector2(cx, y0 + 425.0), "✓ Saved · day %d of 3" % int(config["day"]), 14, Art.INK_SOFT)


# Tracker lost (§4.8): the handle settling onto its spot on the table.
func _draw_pause(vp: Vector2) -> void:
	_dim(vp, 0.5)
	var card := Rect2(vp.x * 0.5 - 240.0, vp.y * 0.5 - 190.0, 480.0, 370.0)
	Art.draw_card(self, card)
	var cx := card.get_center().x
	var y0 := card.position.y
	var t := fmod(_stage_t + float(Time.get_ticks_msec()) / 1000.0, 2.4) / 2.4
	var drop := clampf((t - 0.15) / 0.4, 0.0, 1.0) if t < 0.85 else 1.0 - (t - 0.85) / 0.15
	var table_y := y0 + 150.0
	draw_polygon(PackedVector2Array([Vector2(cx - 130, table_y), Vector2(cx + 130, table_y),
		Vector2(cx + 112, table_y + 40), Vector2(cx - 112, table_y + 40)]),
		PackedColorArray([Color("3A4A63"), Color("3A4A63"), Color("222D40"), Color("222D40")]))
	draw_rect(Rect2(cx - 130, table_y - 6, 260, 9), Color("4A5B76"))
	var spot_a := 0.35 + 0.65 * drop
	Art.blit(self, Art.glow(), Vector2(cx, table_y - 2), Vector2(170.0, 40.0), Color(Art.FF_GLOW, 0.35 * spot_a))
	for i in 12:
		var a0 := TAU * float(i) / 12.0
		var p0 := Vector2(cx, table_y - 2) + Vector2(cos(a0) * 64.0, sin(a0) * 8.0)
		var p1 := Vector2(cx, table_y - 2) + Vector2(cos(a0 + 0.3) * 64.0, sin(a0 + 0.3) * 8.0)
		draw_line(p0, p1, Color(Art.FF_BODY, spot_a), 3.0, true)
	var dy := -34.0 * (1.0 - drop)
	var body := Rect2(cx - 56, table_y - 50 + dy, 112, 46)
	draw_style_box(Art._box(Color("65727E"), 12), body)
	draw_rect(Rect2(cx - 46, table_y - 40 + dy, 18, 18), Color("F2F2F2"))
	draw_rect(Rect2(cx + 28, table_y - 40 + dy, 18, 18), Color("F2F2F2"))
	draw_style_box(Art._box(Color("3E4852"), 10), Rect2(cx - 14, table_y - 88 + dy, 28, 42))
	draw_style_box(Art._box(Color("5B6773"), 6), Rect2(cx - 20, table_y - 94 + dy, 40, 12))
	Art.text(self, Vector2(cx, y0 + 238.0), "Place the handle", 30, Art.INK)
	Art.text(self, Vector2(cx, y0 + 274.0), "back on the table", 30, Art.INK)
	Art.text(self, Vector2(cx, y0 + 312.0), "The game continues by itself", 17, Art.INK_SOFT)
	for i in 3:
		var bob := sin(float(Time.get_ticks_msec()) / 1000.0 * 5.0 - float(i) * 0.9)
		draw_circle(Vector2(cx - 18.0 + 18.0 * float(i), y0 + 342.0 - 3.0 * bob), 5.0,
			Color(Art.FF_BODY, 0.45 + 0.4 * bob))


# Researcher overlay during play (§4.9): diagnostics only — never p, the
# lifetimes or the level, since the participant can see the screen.
func _draw_overlay(vp: Vector2) -> void:
	var box := Rect2(16.0, vp.y - 164.0, 290.0, 148.0)
	draw_style_box(Art._box(Color(0.08, 0.09, 0.07, 0.78), 12), box)
	var f: Font = ThemeDB.fallback_font
	var y := box.position.y + 26.0
	draw_circle(Vector2(box.position.x + 18.0, y - 5.0), 4.0, Color("E4553F"))
	draw_string(Art.font(), Vector2(box.position.x + 30.0, y), "RESEARCHER OVERLAY", HORIZONTAL_ALIGNMENT_LEFT,
		-1, 12, Color("F3B6AC"))
	var left := maxi(ceili(_stage_left), 0)
	var pair := "—"
	if not _apple.is_empty() and int(_apple["pair"]) >= 0:
		var k: int = _apple["pair"]
		pair = "pair %d (A %d · W %d)" % [k + 1, int(_pair_a(k)), int(_pair_w(k))]
	var rows: Array = [
		["Tracker", "%d Hz" % UDPReceiver.packets_per_sec],
		["Round", "%d of %d · %d:%02d left" % [_round_number(), _rounds_of("play") + _rounds_before,
			left / 60, left % 60]],
		["Apple", pair],
		["This round", "%d caught · %d missed" % [_round_caught, _round_missed]],
	]
	for row in rows:
		y += 26.0
		draw_string(f, Vector2(box.position.x + 16.0, y), row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("C9C5BB"))
		draw_string(f, Vector2(box.position.x + 110.0, y), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("F4F2EC"))


# Researcher's calibration check (§4.4), operator style. Each pair's movement
# times as a 10th–90th percentile bar with the median; the reach outline.
# Never shows the lifetimes or the level.
func _draw_check(vp: Vector2) -> void:
	_dim(vp, 0.55)
	var panel := Rect2(vp.x * 0.5 - 500.0, vp.y * 0.5 - 280.0, 1000.0, 560.0)
	draw_style_box(Art._box(Color(0, 0, 0, 0.25), 20), panel.grow(6.0))
	draw_style_box(Art._box(Color.WHITE, 18), panel)
	var f: Font = ThemeDB.fallback_font
	var b := Art.font()
	var x0 := panel.position.x + 30.0
	var y := panel.position.y + 34.0
	var ink := Color("191A17")
	var muted := Color("5F625B")
	draw_circle(Vector2(x0 + 4.0, y - 5.0), 4.0, Color("C0392B"))
	draw_string(b, Vector2(x0 + 14.0, y), "RESEARCHER OVERLAY", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, muted)
	draw_string(b, Vector2(x0, y + 32.0), "Calibration check", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, ink)
	var total := 0
	for k in Protocol.PAIRS.size():
		total += int(_calib[k]["caught"]) + int(_calib[k]["timeouts"])
	draw_string(f, Vector2(x0, y + 58.0), "%d calibration apples, %d reposition. Play waits for you." % [
		total, _repositions], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, muted)

	# Scale for the bars: 0 to a bit past the slowest pair's 90th percentile.
	var span := 1.0
	for k in Protocol.PAIRS.size():
		var v: Array = _calib[k]["mts"].duplicate()
		v.sort()
		if not v.is_empty():
			span = maxf(span, _pct(v, 0.9) * 1.2)
	var bar_x := x0 + 330.0
	var bar_w := 380.0
	y += 100.0
	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		draw_line(Vector2(x0, y - 22.0), Vector2(x0 + 700.0, y - 22.0), Color("EEEBE4"), 1.0)
		draw_string(b, Vector2(x0, y), "Pair %d · %.2f bits" % [k + 1, Protocol.id_bits(_pair_a(k), _pair_w(k))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ink)
		draw_string(f, Vector2(x0, y + 20.0), "A %d · W %d mm" % [int(_pair_a(k)), int(_pair_w(k))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)
		if _unfit.has(k):
			draw_string(b, Vector2(x0 + 180.0, y + 8.0), "does not fit this reach area",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("9A5B0B"))
			y += 74.0
			continue
		var caught: int = c["caught"]
		var timeouts: int = c["timeouts"]
		draw_string(b, Vector2(x0 + 180.0, y), "%d / %d caught" % [caught, caught + timeouts],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ink)
		var note := "no timeouts" if timeouts == 0 else "%d timeout%s" % [timeouts, "" if timeouts == 1 else "s"]
		if caught + timeouts < FEW_SAMPLES:
			note += " · few apples"
		draw_string(f, Vector2(x0 + 180.0, y + 20.0), note, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("9A5B0B") if timeouts > 0 or caught + timeouts < FEW_SAMPLES else muted)
		var track := Rect2(bar_x, y - 12.0, bar_w, 22.0)
		draw_style_box(Art._box(Color("F3F1EC"), 6), track)
		var v: Array = c["mts"].duplicate()
		v.sort()
		if not v.is_empty():
			var lo := _pct(v, 0.1)
			var hi := _pct(v, 0.9)
			var md := _pct(v, 0.5)
			draw_style_box(Art._box(Color("9CC3A5"), 6),
				Rect2(bar_x + bar_w * lo / span, y - 7.0, maxf(4.0, bar_w * (hi - lo) / span), 12.0))
			draw_rect(Rect2(bar_x + bar_w * md / span - 1.5, y - 14.0, 3.0, 26.0), Color("1F4D2C"))
			draw_string(f, Vector2(bar_x, y + 28.0), "median %.2f s · %.2f–%.2f s" % [md, lo, hi],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("3B3D38"))
		y += 74.0
	draw_string(f, Vector2(bar_x, y - 16.0), "0 s", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, muted)
	draw_string(f, Vector2(bar_x + bar_w - 40.0, y - 16.0), "%.1f s" % span, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		muted)

	# Reach outline, the screen as the frame.
	var map := Rect2(panel.end.x - 250.0, panel.position.y + 110.0, 220.0, 160.0)
	draw_string(b, Vector2(map.position.x, map.position.y - 12.0), "REACH", HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		muted)
	draw_style_box(Art._box(Color("F6F4EE"), 8, Color("D9D5CC"), 1), map)
	if _boundary.size() >= 3:
		var k2 := minf(map.size.x / vp.x, map.size.y / vp.y)
		var off := map.position + (map.size - vp * k2) * 0.5
		var poly := PackedVector2Array()
		for p in _boundary:
			poly.append(off + _ts.mm_to_screen(p) * k2)
		draw_colored_polygon(poly, Color(0.75, 0.22, 0.17, 0.15))
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, Color("C0392B"), 2.0, true)
		draw_circle(off + _ts.mm_to_screen(_scan.home) * k2, 3.0, ink)
	draw_string(f, Vector2(map.position.x, map.end.y + 20.0), _reach_text(), HORIZONTAL_ALIGNMENT_LEFT, 220.0,
		12, muted)

	var foot_y := panel.end.y - 30.0
	draw_line(Vector2(x0, foot_y - 26.0), Vector2(panel.end.x - 30.0, foot_y - 26.0), Color("EEEBE4"), 1.0)
	draw_string(f, Vector2(x0, foot_y), "Lifetimes and the level are never shown here.",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)
	draw_string(b, Vector2(panel.end.x - 560.0, foot_y),
		"Enter: start play    C: redo calibration    S: redo from reach scan",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("8E2A1F"))


# q-th percentile of an ascending list (nearest rank).
func _pct(sorted: Array, q: float) -> float:
	return float(sorted[clampi(roundi(q * float(sorted.size() - 1)), 0, sorted.size() - 1)])


func _reach_text() -> String:
	if _scan.results.is_empty():
		return "Reach: not measured"
	var lo := INF
	var hi := 0.0
	var by_screen := 0
	for r in _scan.results:
		lo = minf(lo, r["reach_mm"])
		hi = maxf(hi, r["reach_mm"])
		if r["limited_by"] == "screen":
			by_screen += 1
	return "Reach %d–%d mm, %d of %d directions stopped by the screen edge" % [
		int(lo), int(hi), by_screen, _scan.results.size()]


func _median_text(values: Array, with_unit: bool) -> String:
	if values.is_empty():
		return "—" if with_unit else ""
	var v := values.duplicate()
	v.sort()
	var m: int = v.size() / 2
	var med: float = v[m] if v.size() % 2 == 1 else (float(v[m - 1]) + float(v[m])) * 0.5
	return ("%.2f s" % med) if with_unit else ("%.4f" % med)
