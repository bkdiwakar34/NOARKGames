extends Node2D

# Reach scan, then warm-up + calibration rounds, with plain shapes
# (docs/clinic_study_interface.md §4.3-4.4; build plan §7.2, packages 1-2).
# One apple at a time at one of the three fixed pairs; hold inside it for
# HOLD_S to catch it; speed points; 1-minute rounds with rests between.
#
#   - Apples are placed and hit-tested in table mm (§3.4, table_space.gd); the
#     screen only draws them. The whole circle must lie inside the reach
#     outline from the scan (reach_scan.gd) and on screen.
#   - Holds are judged per tracker sample on the camera's capture clock, so at
#     100 Hz rather than at the frame rate.
#   - MT = hold start − spawn, which equals catch − spawn − hold (design.md §4.6).
#   - An apple expires at spawn + POINT_CAP_S + HOLD_S (§3.3): a hold must start
#     within the cap, and one that does always has time to finish.
#
# Space starts; Esc (clinic_main.gd) quits.

const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")
const VisitLogger := preload("res://app/clinic/visit_logger.gd")
const ReachScan := preload("res://app/clinic/reach_scan.gd")

const PARTICIPANT_ID := "TEST"    # real IDs come with the study-DB package
const TIMEOUT_GRACE_S := 0.15     # samples reach Godot ~20 ms after capture; wait for them
const EDGE_MARGIN_PX := 12.0
const POP_S := 0.8                # how long a "+3" floats

const BG := Color("1E221D")
const INK := Color(1.0, 1.0, 1.0, 0.92)
const GOLD := Color("FFC23D")

enum Stage { READY, SCAN, ROUND, REST, DONE }

var _ts: TableSpace
var _log: VisitLogger
var _scan: ReachScan
var _boundary := PackedVector2Array()   # reach outline, table mm; empty until the scan ends
var _rounds: Array = []          # [{phase, number}] in play order
var _round_idx: int = 0
var _stage: Stage = Stage.READY
var _stage_left: float = 0.0     # seconds left in the current round or rest
var _paused: bool = false        # tracker lost

var _hand: Vector2 = Vector2.ZERO   # latest hand position, table mm
var _apple: Dictionary = {}         # the current apple; empty = none
var _apple_n: int = 0               # apples spawned this round
var _pair_bag: Array = []           # every block of 3 apples uses each pair once
var _round_points: int = 0
var _stats: Array = []              # per pair, calibration rounds only: {caught, timeouts, mts}
var _pops: Array = []               # floating "+3": {pos (mm), t0, text}


func _ready() -> void:
	var vp := get_viewport_rect().size
	_ts = TableSpace.new(vp)
	for i in Protocol.WARMUP_ROUNDS:
		_rounds.append({"phase": "warmup", "number": i + 1})
	for i in Protocol.CALIB_ROUNDS:
		_rounds.append({"phase": "calibration", "number": i + 1})
	for k in Protocol.PAIRS.size():
		_stats.append({"caught": 0, "timeouts": 0, "mts": []})
	_hand = _ts.screen_to_mm(vp * 0.5)
	_scan = ReachScan.new(_ts, vp)
	_log = VisitLogger.new()
	_log.open(PARTICIPANT_ID, _header_lines())
	UDPReceiver.log_enabled = true


func _exit_tree() -> void:
	UDPReceiver.log_enabled = false
	if _log:
		_log.close()


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
		"pairs_a_w_mm,%s" % " ".join(pairs),
		"hold_s,%s" % Protocol.HOLD_S,
		"point_cap_s,%s" % Protocol.POINT_CAP_S,
		"screen_mapped,%s" % _ts.mapped,
		"px_per_mm_x_y,%.3f %.3f" % [ppm.x, ppm.y],
		"origin_lock,%s" % origin,
	]


func _unhandled_input(event: InputEvent) -> void:
	if _stage == Stage.READY and event is InputEventKey and event.pressed \
			and not event.echo and event.keycode == KEY_SPACE:
		_stage = Stage.SCAN


func _process(delta: float) -> void:
	_read_hand()
	_update_pause()
	if not _paused:
		match _stage:
			Stage.SCAN:
				_scan.update(delta)
				if _scan.is_done():
					_log.log_reach(_scan.csv_rows())
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
		if t - spawn <= Protocol.POINT_CAP_S:   # past the cap no new hold may start
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
	_apple_n = 0
	_pair_bag = []


func _end_round() -> void:
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	_round_idx += 1
	if _round_idx >= _rounds.size():
		_stage = Stage.DONE
		UDPReceiver.log_enabled = false
		_log.close()
		return
	_stage = Stage.REST
	_stage_left = Protocol.REST_S


func _phase_name() -> String:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["phase"]
		Stage.REST:
			return "rest"
		Stage.SCAN:
			return "reach_scan"
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


# ── Apples ────────────────────────────────────────────────────────────────────

func _spawn() -> void:
	if _pair_bag.is_empty():
		_pair_bag = range(Protocol.PAIRS.size())
		_pair_bag.shuffle()
	var k: int = _pair_bag.pop_back()
	var a: float = Protocol.PAIRS[k]["a_mm"]
	var w: float = Protocol.PAIRS[k]["w_mm"]
	var place := _place(_hand, a, w)
	var t := _now()
	_apple_n += 1
	_apple = {
		"pair": k, "a_mm": a, "w_mm": w, "n": _apple_n,
		"start": _hand, "centre": place["centre"],
		"angle": place["angle"], "a_actual": place["a_actual"],
		"spawn_time": t, "hold_start": -1.0,
		"deadline": t + Protocol.POINT_CAP_S + Protocol.HOLD_S,
	}


# A centre at distance a (mm) from the hand, in a random direction where the
# whole circle fits (_fits).
func _place(start: Vector2, a: float, w: float) -> Dictionary:
	var r := w * 0.5
	var fits: Array = []
	var offset := randf() * TAU
	for i in 36:
		var ang := offset + TAU * float(i) / 36.0
		if _fits(start + Vector2.from_angle(ang) * a, r):
			fits.append(ang)
	if not fits.is_empty():
		var pick: float = fits.pick_random()
		return {"centre": start + Vector2.from_angle(pick) * a, "angle": pick, "a_actual": a}
	# No direction fits at the full distance (hand near the edge of its reach):
	# head for the scan's centre ring and shorten until it fits. The file keeps
	# both distances (a_mm, a_actual_mm).
	var dir := (_scan.home - start).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var d := a
	while d > r and not _fits(start + dir * d, r):
		d -= 5.0
	return {"centre": start + dir * d, "angle": dir.angle(), "a_actual": d}


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
	var caught := outcome == "caught"
	var counted := _phase_name() == "calibration"
	var mt := -1.0
	var pts := 0
	if caught:
		mt = float(a["hold_start"]) - float(a["spawn_time"])
		pts = Protocol.points_for(mt)
		_round_points += pts
		_pops.append({"pos": a["centre"], "t0": _now(), "text": "+%d" % pts})
		if counted:
			_stats[a["pair"]]["caught"] += 1
			_stats[a["pair"]]["mts"].append(mt)
	elif outcome == "timeout" and counted:
		_stats[a["pair"]]["timeouts"] += 1
	var start: Vector2 = a["start"]
	var centre: Vector2 = a["centre"]
	_log.log_target([
		_phase_name(), _round_number(), a["n"], int(a["pair"]) + 1, a["a_mm"], a["w_mm"],
		"%.1f" % a["a_actual"], "%.1f" % rad_to_deg(a["angle"]),
		"%.2f" % start.x, "%.2f" % start.y, "%.2f" % centre.x, "%.2f" % centre.y,
		"%.6f" % a["spawn_time"], ("%.6f" % a["hold_start"]) if caught else "",
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
			_draw_card(font, vp, ["Calibration test", "Press Space to start"])
		Stage.REST:
			var prev: Dictionary = _rounds[_round_idx - 1]
			var title: String = "Warm-up done" if prev["phase"] == "warmup" \
				else "Round %d done" % prev["number"]
			_draw_card(font, vp, [title, "%d points" % _round_points,
				"Next round in %d" % ceili(_stage_left)])
		Stage.DONE:
			_draw_summary(font, vp)
	if _paused:
		_draw_card(font, vp, ["Tracker lost", "Place the handle back on the table"])
	if not _ts.mapped:
		_text(font, Vector2(20.0, vp.y - 20.0),
			"Screen mapping not set: drawing at 3 px/mm. Run the 4-corner mapping in the installer.",
			18, Color(1.0, 0.75, 0.4))


func _draw_apple() -> void:
	var centre: Vector2 = _apple["centre"]
	var w: float = _apple["w_mm"]
	var inside := TableSpace.inside(_hand, centre, w)
	var ring := _ts.circle_outline(centre, w * 0.5)
	var closed := ring.duplicate()
	closed.append(ring[0])
	draw_colored_polygon(ring, Color(0.35, 0.85, 0.45, 0.35) if inside else Color(1.0, 1.0, 1.0, 0.10))
	draw_polyline(closed, Color(0.45, 0.95, 0.55) if inside else INK, 3.0, true)
	var hold_start: float = _apple["hold_start"]
	if hold_start >= 0.0:
		# Hold progress: a gold arc 5 mm outside the circle.
		var frac := clampf((_now() - hold_start) / Protocol.HOLD_S, 0.0, 1.0)
		var arc := _ts.circle_outline(centre, w * 0.5 + 5.0, 64)
		var n := int(frac * 64.0) + 1
		if n >= 2:
			draw_polyline(arc.slice(0, n), GOLD, 5.0, true)


func _draw_hud(font: Font, vp: Vector2) -> void:
	var label := ""
	if _stage == Stage.ROUND:
		var r: Dictionary = _rounds[_round_idx]
		label = "Warm-up" if r["phase"] == "warmup" \
			else "Round %d of %d" % [r["number"], Protocol.CALIB_ROUNDS]
		var left := maxi(ceili(_stage_left), 0)
		_text(font, Vector2(vp.x * 0.5, 44.0), "%d:%02d" % [left / 60, left % 60], 30, INK, 200.0)
	elif _stage == Stage.REST:
		label = "Rest"
	else:
		return   # ready, scan, done: no round HUD
	_text(font, Vector2(24.0, 44.0), label, 28, INK)
	_text(font, Vector2(vp.x - 244.0, 44.0), "%d points" % _round_points, 28, INK, 220.0)


func _draw_card(font: Font, vp: Vector2, lines: Array, body_size: int = 30) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.55))
	var step := float(body_size) * 1.6
	var y := vp.y * 0.5 - step * 0.5 * float(lines.size() - 1)
	for i in lines.size():
		_text(font, Vector2(vp.x * 0.5, y), lines[i], 48 if i == 0 else body_size, INK, vp.x)
		y += 64.0 if i == 0 else step


func _draw_summary(font: Font, vp: Vector2) -> void:
	var lines: Array = ["Calibration done"]
	for k in Protocol.PAIRS.size():
		var p: Dictionary = Protocol.PAIRS[k]
		var s: Dictionary = _stats[k]
		lines.append("Pair %d · %d / %d mm · %.2f bits — caught %d, timeouts %d, median %s" % [
			k + 1, int(p["a_mm"]), int(p["w_mm"]), Protocol.id_bits(p["a_mm"], p["w_mm"]),
			s["caught"], s["timeouts"], _median_text(s["mts"])])
	lines.append(_reach_text())
	lines.append("Saved in " + _log.folder)
	lines.append("Esc to quit")
	_draw_card(font, vp, lines, 26)


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


func _median_text(values: Array) -> String:
	if values.is_empty():
		return "—"
	var v := values.duplicate()
	v.sort()
	var m: int = v.size() / 2
	var med: float = v[m] if v.size() % 2 == 1 else (float(v[m - 1]) + float(v[m])) * 0.5
	return "%.2f s" % med


# Left-aligned at pos, or centred on pos.x when width > 0 (pos.y = baseline).
func _text(font: Font, pos: Vector2, s: String, size: int, col: Color, width: float = -1.0) -> void:
	if width > 0.0:
		draw_string(font, Vector2(pos.x - width * 0.5, pos.y), s,
			HORIZONTAL_ALIGNMENT_CENTER, width, size, col)
	else:
		draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
