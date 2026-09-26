extends Node2D

# One clinic visit with plain shapes (docs/clinic_study_interface.md §3-4;
# build plan §7.2, packages 1-3):
#   reach scan -> warm-up -> calibration rounds -> calibration check -> play rounds.
# One apple at a time at one of the three fixed pairs; hold inside it for HOLD_S
# to catch it. Calibration rewards speed with points and waits up to the cap;
# play gives each pair the day's lifetime (difficulty.gd) and counts catches.
#
#   - Apples are placed and hit-tested in table mm (§3.4, table_space.gd); the
#     screen only draws them. The whole circle must lie inside the reach
#     outline from the scan (reach_scan.gd) and on screen, always at the
#     pair's exact distance (_spawn).
#   - Holds are judged per tracker sample on the camera's capture clock, so at
#     100 Hz rather than at the frame rate.
#   - MT = hold start − spawn, which equals catch − spawn − hold (design.md §4.6).
#   - An apple's "window" is how long a hold may take to start: the cap in
#     calibration, the lifetime in play. It expires at spawn + window + HOLD_S
#     (§3.3), so in play it is caught exactly when MT <= lifetime.
#
# Keys: 1-3 pick the test level and Space starts (start screen); Enter / C / S
# on the calibration check; Esc (clinic_main.gd) quits.

const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")
const VisitLogger := preload("res://app/clinic/visit_logger.gd")
const ReachScan := preload("res://app/clinic/reach_scan.gd")
const Difficulty := preload("res://app/clinic/difficulty.gd")

const PARTICIPANT_ID := "TEST"    # real IDs come with the study-DB package
const TIMEOUT_GRACE_S := 0.15     # samples reach Godot ~20 ms after capture; wait for them
const EDGE_MARGIN_PX := 12.0
const POP_S := 0.8                # how long a "+3" floats
const REPOSITION_W_MM := 60.0     # the uncounted apple that brings the hand where a pair fits
const SPOT_GRID_MM := 25.0        # grid for searching reposition spots
const FEW_SAMPLES := 20           # calibration check flags a pair with fewer apples

const BG := Color("1E221D")
const INK := Color(1.0, 1.0, 1.0, 0.92)
const GOLD := Color("FFC23D")
const AMBER := Color(1.0, 0.75, 0.4)

enum Stage { READY, SCAN, ROUND, REST, CHECK, DONE }

var _ts: TableSpace
var _log: VisitLogger
var _scan: ReachScan
var _boundary := PackedVector2Array()   # reach outline, table mm; empty until the scan ends
var _rounds: Array = []          # [{phase, number}] in play order
var _round_idx: int = 0
var _stage: Stage = Stage.READY
var _stage_left: float = 0.0     # seconds left in the current round or rest
var _paused: bool = false        # tracker lost
var _level: int = 1              # index into Protocol.TEST_LEVELS
var _quick: bool = false         # quick test: fewer rounds, short rests (Q)
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
var _calib: Array = []              # per pair, this attempt's calibration: {caught, timeouts, mts}
var _lifetimes: Array = []          # per pair, s; -1 = not played
var _play: Array = []               # per pair: {caught, missed}
var _pops: Array = []               # floating "+3": {pos (mm), t0, text}


func _ready() -> void:
	var vp := get_viewport_rect().size
	_ts = TableSpace.new(vp)
	for k in Protocol.PAIRS.size():
		_play.append({"caught": 0, "missed": 0})
	_reset_calibration()
	_hand = _ts.screen_to_mm(vp * 0.5)
	_scan = ReachScan.new(_ts, vp)
	_log = VisitLogger.new()
	# Samples drive the cursor from the start; they are only written once the
	# visit's files are open (_begin_visit).
	UDPReceiver.log_enabled = true


func _exit_tree() -> void:
	UDPReceiver.log_enabled = false
	_log.close()


# On Space, once the level and quick-test choice are known (both go in the header).
func _begin_visit() -> void:
	var calib: int = Protocol.QUICK_CALIB_ROUNDS if _quick else Protocol.CALIB_ROUNDS
	var play: int = Protocol.QUICK_PLAY_ROUNDS if _quick else Protocol.PLAY_ROUNDS
	for i in Protocol.WARMUP_ROUNDS:
		_rounds.append({"phase": "warmup", "number": i + 1})
	for i in calib:
		_rounds.append({"phase": "calibration", "number": i + 1})
	for i in play:
		_rounds.append({"phase": "play", "number": i + 1})
	_log.open(PARTICIPANT_ID, _header_lines())
	_stage = Stage.SCAN


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
	return [
		"participant,%s" % PARTICIPANT_ID,
		"protocol_version,%s" % Protocol.VERSION,
		"level_p,%.2f" % _level_p(),
		"quick_test,%s" % _quick,
		"pairs_a_w_mm,%s" % " ".join(pairs),
		"hold_s,%s" % Protocol.HOLD_S,
		"point_cap_s,%s" % Protocol.POINT_CAP_S,
		"screen_mapped,%s" % _ts.mapped,
		"px_per_mm_x_y,%.3f %.3f" % [ppm.x, ppm.y],
		"origin_lock,%s" % origin,
	]


func _level_p() -> float:
	return Protocol.TEST_LEVELS[_level]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = event.keycode
	if _stage == Stage.READY:
		if key >= KEY_1 and key < KEY_1 + Protocol.TEST_LEVELS.size():
			_level = key - KEY_1
		elif key == KEY_Q:
			_quick = not _quick
		elif key == KEY_SPACE:
			_begin_visit()
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
					_spawn()
				elif _now() > float(_apple["deadline"]) + TIMEOUT_GRACE_S:
					_finish_apple("timeout", _apple["deadline"])
				if _stage_left <= 0.0:
					_end_round()
			Stage.REST:
				_stage_left -= delta
				if _stage_left <= 0.0:
					_start_round()
	var now := _now()
	_pops = _pops.filter(func(p): return now - float(p["t0"]) < POP_S)
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
	_round_points = 0
	_round_caught = 0
	_round_missed = 0
	_apple_n = 0
	_pair_bag = []


func _end_round() -> void:
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	var finished: String = _rounds[_round_idx]["phase"]
	_round_idx += 1
	if _round_idx >= _rounds.size():
		_stage = Stage.DONE
		UDPReceiver.log_enabled = false
		_log.close()
	elif finished == "calibration" and _rounds[_round_idx]["phase"] == "play":
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
		Stage.READY:
			return "ready"
	return "done"


# The round being played; during a rest, the round just finished.
func _round_number() -> int:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["number"]
		Stage.REST:
			return _rounds[_round_idx - 1]["number"]
	return 0


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
	if Protocol.SHOW_CALIB_CHECK:
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
		"spawn_time": t, "hold_start": -1.0, "play": in_play,
		"window": window, "deadline": t + window + Protocol.HOLD_S,
	}


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
		_pops.append({"pos": a["centre"], "t0": _now(), "text": "+%d" % pts})
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


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	var vp := get_viewport_rect().size
	var font: Font = ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, vp), BG)
	if _stage == Stage.SCAN:
		_scan.draw(self, font)
	if _stage == Stage.ROUND and not _paused and not _apple.is_empty():
		_draw_apple()
	if _stage == Stage.ROUND and _no_fit:
		_text(font, Vector2(vp.x * 0.5, vp.y * 0.5), "None of the pairs fits this reach area",
			30, AMBER, vp.x)
	for p in _pops:
		var age: float = _now() - float(p["t0"])
		var pos := _ts.mm_to_screen(p["pos"]) + Vector2(0.0, -50.0 - 70.0 * age)
		_text(font, pos, p["text"], 40, Color(GOLD, 1.0 - age / POP_S), 200.0)
	var cur := _ts.mm_to_screen(_hand)
	draw_circle(cur, 11.0, Color(0.0, 0.0, 0.0, 0.5))
	draw_circle(cur, 8.0, Color.WHITE)
	_draw_hud(font, vp)
	match _stage:
		Stage.READY:
			var levels := PackedStringArray()
			for i in Protocol.TEST_LEVELS.size():
				var mark: String = "[%d]" % (i + 1) if i == _level else " %d " % (i + 1)
				levels.append("%s p = %.2f" % [mark, Protocol.TEST_LEVELS[i]])
			var quick: String = "Quick test: ON — %d calibration + %d play rounds, %d s rests" % [
				Protocol.QUICK_CALIB_ROUNDS, Protocol.QUICK_PLAY_ROUNDS, int(Protocol.QUICK_REST_S)] \
				if _quick else "Quick test: off (full visit, about 27 min)"
			_draw_card(font, vp, ["Visit test", "Test level:  " + "    ".join(levels), quick,
				"1, 2, 3: level    Q: quick test    Space: start"])
		Stage.REST:
			_draw_card(font, vp, _rest_lines())
		Stage.CHECK:
			_draw_check(font, vp)
		Stage.DONE:
			_draw_summary(font, vp)
	if _paused:
		_draw_card(font, vp, ["Tracker lost", "Place the handle back on the table"])
	if not _ts.mapped:
		_text(font, Vector2(20.0, vp.y - 20.0),
			"Screen mapping not set: drawing at 3 px/mm. Run the 4-corner mapping in the installer.",
			18, AMBER)


func _draw_apple() -> void:
	var centre: Vector2 = _apple["centre"]
	var w: float = _apple["w_mm"]
	var inside := TableSpace.inside(_hand, centre, w)
	var ring := _ts.circle_outline(centre, w * 0.5)
	var closed := ring.duplicate()
	closed.append(ring[0])
	draw_colored_polygon(ring, Color(0.35, 0.85, 0.45, 0.35) if inside else Color(1.0, 1.0, 1.0, 0.10))
	draw_polyline(closed, Color(0.45, 0.95, 0.55) if inside else INK, 3.0, true)
	if _apple["play"]:
		# Time left: an orange arc 10 mm outside the circle, draining to the deadline.
		var spawn: float = _apple["spawn_time"]
		var deadline: float = _apple["deadline"]
		var left := clampf((deadline - _now()) / (deadline - spawn), 0.0, 1.0)
		_arc(centre, w * 0.5 + 10.0, left, Color(1.0, 0.6, 0.2), 4.0)
	var hold_start: float = _apple["hold_start"]
	if hold_start >= 0.0:
		# Hold progress: a gold arc 5 mm outside the circle.
		_arc(centre, w * 0.5 + 5.0, (_now() - hold_start) / Protocol.HOLD_S, GOLD, 5.0)


func _arc(centre: Vector2, r_mm: float, frac: float, col: Color, width: float) -> void:
	var pts := _ts.circle_outline(centre, r_mm, 64)
	pts.append(pts[0])
	var n := int(clampf(frac, 0.0, 1.0) * 64.0) + 1
	if n >= 2:
		draw_polyline(pts.slice(0, n), col, width, true)


func _draw_hud(font: Font, vp: Vector2) -> void:
	if _stage != Stage.ROUND and _stage != Stage.REST:
		return   # ready, scan, check, done: no round HUD
	var play := _phase_name() == "play" or (_stage == Stage.REST \
		and _rounds[_round_idx - 1]["phase"] == "play")
	var label := "Rest"
	if _stage == Stage.ROUND:
		var r: Dictionary = _rounds[_round_idx]
		var total := _rounds_of("play" if play else "calibration")
		label = "Warm-up" if r["phase"] == "warmup" else "Round %d of %d" % [r["number"], total]
		var left := maxi(ceili(_stage_left), 0)
		_text(font, Vector2(vp.x * 0.5, 44.0), "%d:%02d" % [left / 60, left % 60], 30, INK, 200.0)
	_text(font, Vector2(24.0, 44.0), label, 28, INK)
	var score := "%d caught" % _round_caught if play else "%d points" % _round_points
	_text(font, Vector2(vp.x - 244.0, 44.0), score, 28, INK, 220.0)


func _rest_lines() -> Array:
	var prev: Dictionary = _rounds[_round_idx - 1]
	var title: String = "Warm-up done" if prev["phase"] == "warmup" \
		else "Round %d done" % prev["number"]
	var next := "Next round in %d" % ceili(_stage_left)
	if prev["phase"] != "play":
		return [title, "%d points" % _round_points, next]
	var n := _round_caught + _round_missed
	var rate := 100.0 * float(_round_caught) / float(maxi(n, 1))
	return [title, "%d of %d caught · %d %%" % [_round_caught, n, roundi(rate)], next]


# Researcher's calibration check (§4.4). Never shows the lifetimes or the level.
func _draw_check(font: Font, vp: Vector2) -> void:
	var lines: Array = ["Calibration check"]
	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		var n: int = c["caught"] + c["timeouts"]
		var line := "Pair %d · %d / %d mm — " % [k + 1, int(_pair_a(k)), int(_pair_w(k))]
		if _unfit.has(k):
			line += "does not fit this reach area"
		else:
			line += "caught %d, timeouts %d, median %s" % [
				c["caught"], c["timeouts"], _median_text(c["mts"], true)]
			if n < FEW_SAMPLES:
				line += "  (few apples)"
		lines.append(line)
	lines.append(_reach_text() + ", %d reposition apples" % _repositions)
	lines.append("Enter: start play    C: redo calibration rounds    S: redo from reach scan")
	_draw_card(font, vp, lines, 26)


# Test summary (a later package turns the end of a visit into the participant's
# closing card). Here: each pair's lifetime and real catch rate against p.
func _draw_summary(font: Font, vp: Vector2) -> void:
	var p := _level_p()
	var lines: Array = ["Visit done — target p = %.2f" % p]
	for k in Protocol.PAIRS.size():
		var head := "Pair %d · %d / %d mm — " % [k + 1, int(_pair_a(k)), int(_pair_w(k))]
		if _unfit.has(k) or _lifetimes.is_empty() or float(_lifetimes[k]) < 0.0:
			lines.append(head + "not played")
			continue
		var c: int = _play[k]["caught"]
		var n: int = c + int(_play[k]["missed"])
		lines.append(head + "lifetime %.2f s, caught %d of %d = %d %%" % [
			_lifetimes[k], c, n, roundi(100.0 * float(c) / float(maxi(n, 1)))])
	lines.append("Saved in " + _log.folder)
	lines.append("Esc to quit")
	_draw_card(font, vp, lines, 26)


func _draw_card(font: Font, vp: Vector2, lines: Array, body_size: int = 30) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.55))
	var step := float(body_size) * 1.6
	var y := vp.y * 0.5 - step * 0.5 * float(lines.size() - 1)
	for i in lines.size():
		_text(font, Vector2(vp.x * 0.5, y), lines[i], 48 if i == 0 else body_size, INK, vp.x)
		y += 64.0 if i == 0 else step


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


# Left-aligned at pos, or centred on pos.x when width > 0 (pos.y = baseline).
func _text(font: Font, pos: Vector2, s: String, size: int, col: Color, width: float = -1.0) -> void:
	if width > 0.0:
		draw_string(font, Vector2(pos.x - width * 0.5, pos.y), s,
			HORIZONTAL_ALIGNMENT_CENTER, width, size, col)
	else:
		draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
