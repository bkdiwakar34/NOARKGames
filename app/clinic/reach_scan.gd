extends RefCounted

# Reach scan (docs/clinic_study_interface.md §4.3; build plan package 2).
# Hold the cursor in the centre ring for HOME_HOLD_S, then follow a light that
# glides out along REACH_SPOKES directions to the screen edge, waits, and comes
# back. For each spoke the reach is the furthest the hand got along it while
# the light was out:
#     reach = max over time of (hand − home) · u      (u = unit spoke direction)
# Sideways drift does not count; the wait at the far end lets a slow follower
# catch up. The light cannot go past the screen edge, so a reach that got that
# far is marked "screen" (the apples cannot appear beyond it either).
#
# Driven by round_runner.gd: on_sample() per tracker sample, update() per
# frame, draw() from its _draw. All positions are table mm.

const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")

const HOME_R_MM := 30.0
const HOME_HOLD_S := 1.0
const GAP_S := 0.5              # pause at home between spokes
const EDGE_MARGIN_PX := 20.0
const SCREEN_LIMIT_MM := 10.0   # reach within this of the light's end = limited by the screen

enum Step { HOME, OUT, WAIT, BACK, GAP, DONE }

var home: Vector2
var results: Array = []         # per spoke: {angle_deg, reach_mm, edge, light_mm, limited_by}

var _ts: TableSpace
var _vp: Vector2
var _step: Step = Step.HOME
var _spoke: int = 0
var _u: Vector2 = Vector2.RIGHT
var _light: float = 0.0         # light's distance from home along the spoke, mm
var _light_max: float = 0.0     # where it turns back: the screen edge
var _best: float = 0.0          # furthest hand projection on this spoke
var _timer: float = 0.0
var _home_hold: float = -1.0    # sample time the hand entered the ring; -1 = not inside
var _hand: Vector2 = Vector2.ZERO


func _init(ts: TableSpace, viewport_size: Vector2) -> void:
	_ts = ts
	_vp = viewport_size
	home = ts.screen_to_mm(viewport_size * 0.5)


func is_done() -> bool:
	return _step == Step.DONE


func on_sample(t: float, hand: Vector2) -> void:
	_hand = hand
	match _step:
		Step.HOME:
			if hand.distance_to(home) > HOME_R_MM:
				_home_hold = -1.0
			elif _home_hold < 0.0:
				_home_hold = t
			elif t - _home_hold >= HOME_HOLD_S:
				_begin_spoke()
		Step.OUT, Step.WAIT:
			_best = maxf(_best, (hand - home).dot(_u))


func update(delta: float) -> void:
	match _step:
		Step.OUT:
			_light += Protocol.REACH_SPEED_MM_S * delta
			if _light >= _light_max:
				_light = _light_max
				_step = Step.WAIT
				_timer = Protocol.REACH_WAIT_S
		Step.WAIT:
			_timer -= delta
			if _timer <= 0.0:
				_step = Step.BACK
		Step.BACK:
			_light -= Protocol.REACH_SPEED_MM_S * delta
			if _light <= 0.0:
				_light = 0.0
				_finish_spoke()
		Step.GAP:
			_timer -= delta
			if _timer <= 0.0:
				_begin_spoke()


# Tracker lost mid-spoke: that spoke starts again once it is back.
func restart_spoke() -> void:
	if _step in [Step.OUT, Step.WAIT, Step.BACK]:
		_light = 0.0
		_step = Step.GAP
		_timer = GAP_S


func _begin_spoke() -> void:
	_u = Vector2.from_angle(TAU * float(_spoke) / float(Protocol.REACH_SPOKES))
	_light = 0.0
	_best = 0.0
	_light_max = 0.0
	var rect := Rect2(Vector2.ZERO, _vp).grow(-EDGE_MARGIN_PX)
	while rect.has_point(_ts.mm_to_screen(home + _u * (_light_max + 5.0))):
		_light_max += 5.0
	_step = Step.OUT


func _finish_spoke() -> void:
	var reach := clampf(_best, 0.0, _light_max)
	results.append({
		"angle_deg": 360.0 * float(_spoke) / float(Protocol.REACH_SPOKES),
		"reach_mm": reach,
		"edge": home + _u * reach,
		"light_mm": _light_max,
		"limited_by": "screen" if reach >= _light_max - SCREEN_LIMIT_MM else "hand",
	})
	_spoke += 1
	if _spoke >= Protocol.REACH_SPOKES:
		_step = Step.DONE
	else:
		_step = Step.GAP
		_timer = GAP_S


# The reach outline in table mm, spokes in order (a star-shaped polygon around home).
func boundary() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for r in results:
		pts.append(r["edge"])
	return pts


# Rows for reach.csv (visit_logger.gd REACH_COLUMNS).
func csv_rows() -> Array:
	var rows: Array = []
	for i in results.size():
		var r: Dictionary = results[i]
		var edge: Vector2 = r["edge"]
		rows.append([i + 1, "%.1f" % r["angle_deg"], "%.1f" % r["reach_mm"],
			"%.2f" % edge.x, "%.2f" % edge.y, "%.1f" % r["light_mm"], r["limited_by"]])
	return rows


func draw(ci: CanvasItem, font: Font) -> void:
	var ring := _ts.circle_outline(home, HOME_R_MM)
	var closed := ring.duplicate()
	closed.append(ring[0])
	var in_ring := _hand.distance_to(home) <= HOME_R_MM
	if _step == Step.HOME and in_ring:
		ci.draw_colored_polygon(ring, Color(0.35, 0.85, 0.45, 0.35))
	ci.draw_polyline(closed, Color(1.0, 1.0, 1.0, 0.85), 3.0, true)

	if _step in [Step.OUT, Step.WAIT, Step.BACK]:
		var p := _ts.mm_to_screen(home + _u * _light)
		ci.draw_circle(p, 30.0, Color(1.0, 0.85, 0.35, 0.18))
		ci.draw_circle(p, 20.0, Color(1.0, 0.85, 0.35, 0.35))
		ci.draw_circle(p, 12.0, Color("FFC23D"))

	# Progress: one dot per spoke along the top.
	var n := Protocol.REACH_SPOKES
	var x0 := _vp.x * 0.5 - 14.0 * float(n - 1)
	for i in n:
		var c: Color = Color("FFC23D") if i < _spoke else Color(1.0, 1.0, 1.0, 0.3)
		ci.draw_circle(Vector2(x0 + 28.0 * float(i), 36.0), 8.0, c)

	var msg: String = "Hold the cursor in the ring to start" if _step == Step.HOME else "Follow the light"
	ci.draw_string(font, Vector2(0.0, 92.0), msg, HORIZONTAL_ALIGNMENT_CENTER, _vp.x, 30,
		Color(1.0, 1.0, 1.0, 0.92))
