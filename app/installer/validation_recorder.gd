extends Control
# Validation recorder (docs/validation_plan.md) — researcher-only, opened from
# the installer. The tracker does the recording; this screen names it, starts
# and stops it, and guides the movement.
#
# The screen IS the table: the 4-corner workspace calibration maps the table
# onto the viewport, so a dot here is a place there. Nothing drawn here enters
# the data files — the analysis finds holds and reaches from the movement
# itself.

const UITheme := preload("res://app/ui/ui_theme.gd")

# Trial -> conditions. T0 is a dry run; T5 (record during a real game) is not built.
const TRIALS: Dictionary = {
	"T0": ["test"],
	"T1": ["grid"],
	"T2": ["circle_slow", "circle_comfortable", "circle_fast",
		   "eight_slow", "eight_comfortable", "eight_fast"],
	"T3": ["comfortable", "fast"],
}
const REPEATS: Array = ["r1", "r2", "r3", "r4", "r5"]

const GRID_COLS := 12          # T1 places across the table
const GRID_ROWS := 8           # T1 places near-to-far  (12 x 8 = 96, ~10 min)
const HOLD_S := 3.0            # length of a T1 hold, once you start it
const REACH_HOLD_S := 0.4      # T3 only needs the target touched, not held
const T3_DIRECTIONS := 8
# The workspace calibration maps the table onto the whole viewport, so the
# screen IS the table: targets are inset by this little only to keep a dot from
# sitting half off the edge. (Was 7% / 22% until 2026-09-21, which quietly left
# the near and far thirds of the table unmeasured.)
const MARGIN := Vector2(0.04, 0.05)
const T2_SECONDS := 30.0       # one T2 condition; the recording stops itself
const T2_LEAD_S := 3.0         # pacer waits at the start, so you can get on it
# T2 pacer speeds, on the TABLE (mm/s) — the workspace calibration converts
# them to screen pixels, so "300 mm/s" really is 300 mm/s of device movement.
# Reaches peak around 300-1000 mm/s, so these bracket the useful range.
# Tried on the board 2026-09-21: 300 mm/s of pacer is already the fast end of
# what the hand follows on these shapes, so it became the top rung.
const T2_SPEEDS := {"slow": 100.0, "comfortable": 200.0, "fast": 300.0}

var _trial: OptionButton
var _cond: OptionButton
var _rep: OptionButton
var _name_lbl: Label
var _rec_btn: Button
var _close_btn: Button
var _hint: Label

var _targets: Array = []       # [{pos: Vector2, done: bool}]
var _current: int = 0
var _hold_t: float = 0.0
var _holding: bool = false     # T1: a spacebar-started hold is running
var _cursor: Vector2 = Vector2.ZERO
var _trail: Array = []         # T2: recent cursor positions
var _elapsed: float = 0.0      # T2: seconds recorded so far
var _path: PackedVector2Array  # T2: the shape to trace
var _path_cum: Array = []      # cumulative length along _path, for the pacer
var _laps: int = 0
var _pacer_marked: bool = false
var _status: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_rebuild_targets()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_ESCAPE:
			# While recording the controls are hidden (they would sit on top of
			# the table), so Escape is how a run is stopped; a second Escape
			# leaves the screen.
			if _status.get("rec", false):
				_on_record_pressed()
			else:
				_close()
		KEY_SPACE:
			# Swallowed here: space would otherwise press whichever button has
			# focus — which used to stop the recording.
			get_viewport().set_input_as_handled()
			_start_hold()
		KEY_BACKSPACE:
			get_viewport().set_input_as_handled()
			_redo_previous()


# T1: you place the device, let your hand settle, then press space. The hold
# then runs its full 3 s — deliberately with no "did it move?" check, since
# that would judge the tracker by its own output. Redo a fumbled one with
# backspace; the mocap decides afterwards whether a hold was really still.
func _start_hold() -> void:
	if _trial_name() != "T1" or _holding or _current >= _targets.size():
		return
	if not _status.get("rec", false):
		return
	_holding = true
	_hold_t = 0.0
	_mark("hold_start")


func _redo_previous() -> void:
	if _trial_name() != "T1" or _holding or _current == 0:
		return
	_current -= 1
	_targets[_current]["done"] = false
	_mark("redo")


func _mark(what: String) -> void:
	if _current >= _targets.size():
		return
	var pos: Vector2 = _targets[_current]["pos"]
	UDPReceiver.send_mark("%s %d %.1f %.1f" % [what, _current, pos.x, pos.y])


func _close() -> void:
	if UDPReceiver.requested_recording() != "":
		UDPReceiver.request_recording("")
	queue_free()


# ── UI (everything else is drawn) ─────────────────────────────────────────────

func _build_ui() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	top.position = Vector2(40.0, 28.0)
	add_child(top)

	_trial = OptionButton.new()
	for t in TRIALS:
		_trial.add_item(t)
	_trial.item_selected.connect(func(_i: int): _on_trial_changed())
	top.add_child(_trial)
	_cond = OptionButton.new()
	_cond.item_selected.connect(func(_i: int): _on_condition_changed())
	top.add_child(_cond)
	_rep = OptionButton.new()
	for r in REPEATS:
		_rep.add_item(r)
	_rep.item_selected.connect(func(_i: int): _update_name())
	top.add_child(_rep)

	_name_lbl = Label.new()
	_name_lbl.position = Vector2(40.0, 66.0)
	_name_lbl.add_theme_font_size_override("font_size", 26)
	_name_lbl.add_theme_color_override("font_color", UITheme.INK)
	UITheme.make_bold(_name_lbl)
	add_child(_name_lbl)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", UITheme.INK_SOFT)
	_hint.position = Vector2(40.0, 100.0)
	add_child(_hint)

	_rec_btn = Button.new()
	_rec_btn.custom_minimum_size = Vector2(190.0, 52.0)
	_rec_btn.add_theme_color_override("font_color", Color.WHITE)
	_rec_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_rec_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	_rec_btn.pressed.connect(_on_record_pressed)
	add_child(_rec_btn)

	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.custom_minimum_size = Vector2(110.0, 52.0)
	_close_btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.INK))
	_close_btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.INK.lightened(0.18)))
	_close_btn.add_theme_color_override("font_color", Color.WHITE)
	_close_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_close_btn.pressed.connect(_close)
	add_child(_close_btn)
	_close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_close_btn.position = Vector2(get_viewport_rect().size.x - 150.0, 28.0)
	var back := _close_btn

	# Nothing here takes keyboard focus: the trials are driven by the spacebar,
	# and a focused control would eat it (and press itself).
	for node in [_trial, _cond, _rep, _rec_btn, back]:
		node.focus_mode = Control.FOCUS_NONE

	_on_trial_changed()


func _on_trial_changed() -> void:
	_cond.clear()
	for c in TRIALS[_trial.get_item_text(_trial.selected)]:
		_cond.add_item(c)
	_cond.select(0)
	_rep.select(0)
	_update_name()
	_rebuild_targets()


func _on_condition_changed() -> void:
	# A different condition starts its own repeat count: the number advances
	# only when the same condition is recorded again.
	_rep.select(0)
	_update_name()
	if _trial_name() == "T2":
		_build_path()      # circle <-> eight
	queue_redraw()


func _update_name() -> void:
	_name_lbl.text = "%s_%s_%s_%s" % [
		Time.get_date_string_from_system(),
		_trial.get_item_text(_trial.selected),
		_cond.get_item_text(_cond.selected),
		_rep.get_item_text(_rep.selected)]


func _trial_name() -> String:
	return _trial.get_item_text(_trial.selected)


func _on_record_pressed() -> void:
	if _status.get("rec", false):
		UDPReceiver.request_recording("")
		if _rep.selected + 1 < REPEATS.size():
			_rep.select(_rep.selected + 1)
			_update_name()
	else:
		_rebuild_targets()
		UDPReceiver.request_recording(_name_lbl.text)
		_pacer_marked = false


# ── targets ───────────────────────────────────────────────────────────────────

func _rebuild_targets() -> void:
	var vp := get_viewport_rect().size
	var lo := Vector2(vp.x * MARGIN.x, vp.y * MARGIN.y)
	var hi := Vector2(vp.x * (1.0 - MARGIN.x), vp.y * (1.0 - MARGIN.y))
	_targets = []
	_current = 0
	_hold_t = 0.0
	_holding = false
	_elapsed = 0.0
	_laps = 0
	_trail = []
	if _trial_name() == "T2":
		_build_path()

	match _trial_name():
		"T1":
			# Serpentine order: the device travels to the neighbouring place,
			# never back across the table.
			for row in GRID_ROWS:
				var y: float = lo.y + (hi.y - lo.y) * (float(row) / float(GRID_ROWS - 1))
				for i in GRID_COLS:
					var col: int = i if row % 2 == 0 else GRID_COLS - 1 - i
					var x: float = lo.x + (hi.x - lo.x) * (float(col) / float(GRID_COLS - 1))
					_targets.append({"pos": Vector2(x, y), "done": false})
		"T3":
			# Centre-out reaches: centre, out to a target, back to centre, out
			# to the next. Each reach then starts from the same place and its
			# distance is the one it was designed to be.
			var centre := (lo + hi) * 0.5
			var far: float = min(hi.x - lo.x, hi.y - lo.y) * 0.5
			for d in [far * 0.45, far * 0.95]:
				for k in T3_DIRECTIONS:
					var a: float = TAU * float(k) / float(T3_DIRECTIONS)
					_targets.append({"pos": centre, "done": false, "kind": "centre"})
					_targets.append({"pos": centre + Vector2(cos(a), sin(a)) * d,
									 "done": false, "kind": "target"})
	queue_redraw()


func _target_radius() -> float:
	var vp := get_viewport_rect().size
	return min(vp.x, vp.y) * 0.030


func _hold_time() -> float:
	return HOLD_S if _trial_name() == "T1" else REACH_HOLD_S


func _fill_fraction() -> float:
	if _trial_name() == "T1" and not _holding:
		return 0.0
	return clampf(_hold_t / _hold_time(), 0.0, 1.0)


# ── per-frame ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_status = UDPReceiver.recorder_status()
	# The tracker refused to start (name already used, disk problem): stop
	# asking, or Godot would repeat the request every 100 ms.
	var wanted: String = UDPReceiver.requested_recording()
	var rec_error: String = str(_status.get("rec_error", ""))
	if rec_error != "" and wanted != "" and rec_error.begins_with(wanted):
		UDPReceiver.request_recording("")
	_cursor = UDPReceiver.screen_pos if UDPReceiver.connected \
		else get_global_mouse_position()

	if _status.get("rec", false):
		if _trial_name() == "T2" and not _pacer_marked:
			# Sent once the tracker is actually recording (REC_START takes a
			# moment), so the mark lands in the file.
			_pacer_marked = true
			UDPReceiver.send_mark("pacer %s %.0f mm_s lead %.1f s" % [
				_condition(), _speed_mm_s(), T2_LEAD_S])
		_elapsed += delta
		_advance_targets(delta)
		_update_trail()
		# T2 conditions are all the same length, so the screen ends them.
		if _trial_name() == "T2" and _elapsed >= T2_LEAD_S + T2_SECONDS:
			_on_record_pressed()

	_layout_status_bar()
	_refresh_buttons()
	queue_redraw()


func _advance_targets(delta: float) -> void:
	if _current >= _targets.size():
		return
	var target: Dictionary = _targets[_current]
	if _trial_name() == "T1":
		# Started by the spacebar, runs to the end (see _start_hold).
		if not _holding:
			return
		_hold_t += delta
		if _hold_t >= HOLD_S:
			_mark("hold_end")
			target["done"] = true
			_current += 1
			_holding = false
			_hold_t = 0.0
		return
	# T3: hands-free — touching the lit target advances it.
	if _cursor.distance_to(target["pos"]) < _target_radius():
		_hold_t += delta
		if _hold_t >= REACH_HOLD_S:
			_mark("at_" + str(target.get("kind", "target")))
			target["done"] = true
			_current += 1
			_hold_t = 0.0
	else:
		_hold_t = 0.0


func _update_trail() -> void:
	if _trial_name() != "T2":
		return
	_trail.append(_cursor)
	if _trail.size() > 220:
		_trail.pop_front()


func _refresh_buttons() -> void:
	var recording: bool = _status.get("rec", false)
	var pending: bool = (UDPReceiver.requested_recording() != "") != recording

	# The table fills the screen, so nothing may sit on top of it during a run:
	# every control hides, and the one status line is drawn in the corner.
	for node in [_trial, _cond, _rep, _name_lbl, _hint, _rec_btn, _close_btn]:
		node.visible = not recording
	if recording:
		return
	var colour: Color = UITheme.INK if recording else UITheme.APPLE_RED
	_rec_btn.text = "■  Stop" if recording else "●  Record"
	_rec_btn.disabled = pending or not WorkspaceConfig.is_calibrated
	_rec_btn.add_theme_stylebox_override("normal", UITheme.button_style(colour))
	_rec_btn.add_theme_stylebox_override("hover", UITheme.button_style(colour.lightened(0.18)))
	_rec_btn.add_theme_stylebox_override("pressed", UITheme.button_style(colour.darkened(0.2)))
	for box in [_trial, _cond, _rep]:
		box.disabled = recording or pending

	var rec_error: String = str(_status.get("rec_error", ""))
	if not WorkspaceConfig.is_calibrated:
		_hint.text = "workspace not calibrated — run the 4-corner calibration first"
	elif rec_error != "":
		_hint.text = "could not start: " + rec_error
	elif pending:
		_hint.text = "waiting for the tracker…"
	elif str(_status.get("sync_err", "")) != "":
		_hint.text = "sync pin unavailable"
	elif recording and _trial_name() == "T1":
		_hint.text = "space = hold 3 s      backspace = redo the last one"
	elif recording:
		_hint.text = ""
	else:
		_hint.text = str(_status.get("last", ""))


func _layout_status_bar() -> void:
	var vp := get_viewport_rect().size
	_rec_btn.position = Vector2(40.0, vp.y - 82.0)


# ── drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), UITheme.PAPER)
	_draw_table_edge(vp)
	# Idle, the controls sit over the table, so the dots stay hidden until
	# there is something to record.
	var recording: bool = _status.get("rec", false)
	match _trial_name():
		"T1", "T3":
			if recording:
				_draw_targets()
		"T2":
			_draw_guide_shape(vp)
			_draw_trail()
			if recording:
				_draw_progress(vp)
	_draw_cursor()
	_draw_status_strip(vp)


func _draw_table_edge(vp: Vector2) -> void:
	# The table's own edge: the whole screen, not the target area.
	draw_rect(Rect2(Vector2(3.0, 3.0), vp - Vector2(6.0, 6.0)),
		Color(UITheme.INK, 0.14), false, 2.0)


func _draw_targets() -> void:
	var r := _target_radius()
	for i in _targets.size():
		var t: Dictionary = _targets[i]
		var pos: Vector2 = t["pos"]
		if t["done"]:
			draw_circle(pos, r * 0.38, UITheme.LEAF)
		elif i == _current:
			draw_arc(pos, r, 0.0, TAU, 48, UITheme.APPLE_RED, 3.0)
			var frac: float = _fill_fraction()
			if frac > 0.0:
				draw_arc(pos, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 48, UITheme.GOLD, 6.0)
		else:
			draw_circle(pos, 3.0, Color(UITheme.INK, 0.22))


# The path to trace: one big ellipse ("circle"), or the same ellipse crossed
# in the middle ("eight"). The eight's two reversals are what let the analysis
# measure the device's lag; a steady circle looks the same at every instant.
func _build_path() -> void:
	var vp := get_viewport_rect().size
	var centre := vp * 0.5
	var rx := vp.x * (0.5 - MARGIN.x - 0.02)
	var ry := vp.y * (0.5 - MARGIN.y - 0.02)
	var eight := _condition().begins_with("eight")
	_path = PackedVector2Array()
	var n := 240
	for i in n + 1:
		var t: float = TAU * float(i) / float(n)
		if eight:
			# Lemniscate of Gerono: one stroke, crossing itself at the centre.
			_path.append(centre + Vector2(cos(t) * rx, sin(2.0 * t) * ry * 0.5))
		else:
			_path.append(centre + Vector2(cos(t) * rx, sin(t) * ry))
	_path_cum = [0.0]
	for i in range(1, _path.size()):
		_path_cum.append(_path_cum[i - 1] + _path[i].distance_to(_path[i - 1]))


func _condition() -> String:
	return _cond.get_item_text(_cond.selected)


# Screen pixels per metre on the table, from the 4-corner calibration: the
# linear part of its affine maps metres to pixels, and the square root of its
# determinant is the average scale (it is near-uniform for a flat table).
func _px_per_m() -> float:
	var a: Array = WorkspaceConfig.affine
	var det: float = absf(a[0][0] * a[1][1] - a[0][1] * a[1][0])
	return sqrt(det) if det > 0.0 else 1000.0


func _speed_mm_s() -> float:
	var parts := _condition().split("_")
	return float(T2_SPEEDS.get(parts[parts.size() - 1], 300.0))


func _pacer_speed_px() -> float:
	return _speed_mm_s() * 0.001 * _px_per_m()


# Where the pacer is after _elapsed seconds: a constant distance along the
# path, so the speed is the same everywhere on it (unlike a constant step in
# the shape's parameter, which would race through the straight parts).
func _pacer_pos() -> Vector2:
	if _path.size() < 2:
		return get_viewport_rect().size * 0.5
	var total: float = _path_cum[_path_cum.size() - 1]
	# It waits at the start of the path through the lead-in.
	var moving: float = max(_elapsed - T2_LEAD_S, 0.0)
	var travelled: float = _pacer_speed_px() * moving
	var lap := int(travelled / total)
	if lap > _laps:
		_laps = lap
		if _status.get("rec", false):
			UDPReceiver.send_mark("lap %d" % lap)
	var s: float = fmod(travelled, total)
	for i in range(1, _path_cum.size()):
		if _path_cum[i] >= s:
			var seg: float = _path_cum[i] - _path_cum[i - 1]
			var f: float = 0.0 if seg <= 0.0 else (s - _path_cum[i - 1]) / seg
			return _path[i - 1].lerp(_path[i], f)
	return _path[_path.size() - 1]


func _draw_guide_shape(_vp: Vector2) -> void:
	if _path.size() < 2:
		_build_path()
	draw_polyline(_path, Color(UITheme.INK, 0.18), 3.0)
	if _status.get("rec", false):
		# The pacer: keep the cursor on it. Its speed is the condition.
		var p := _pacer_pos()
		draw_circle(p, 26.0, Color(UITheme.APPLE_RED, 0.22))
		draw_circle(p, 14.0, UITheme.APPLE_RED)
		var left: float = T2_LEAD_S - _elapsed
		if left > 0.0:
			# Waiting for you: get the cursor onto the dot.
			draw_arc(p, 40.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - left / T2_LEAD_S),
				48, UITheme.GOLD, 5.0)
			draw_string(ThemeDB.fallback_font, p + Vector2(52.0, 8.0),
				"%d" % (int(ceil(left))), HORIZONTAL_ALIGNMENT_LEFT, -1, 34, UITheme.INK)


func _draw_trail() -> void:
	for i in range(1, _trail.size()):
		draw_line(_trail[i - 1], _trail[i], Color(UITheme.LASER, 0.55), 2.0)


func _draw_progress(vp: Vector2) -> void:
	var left := vp.x * 0.25
	var width := vp.x * 0.5
	var y := vp.y - 40.0
	var frac: float = clampf((_elapsed - T2_LEAD_S) / T2_SECONDS, 0.0, 1.0)
	draw_rect(Rect2(Vector2(left, y), Vector2(width, 10.0)), Color(UITheme.INK, 0.12))
	draw_rect(Rect2(Vector2(left, y), Vector2(width * frac, 10.0)), UITheme.LEAF)
	draw_string(ThemeDB.fallback_font, Vector2(left + width + 16.0, y + 11.0),
		"%.0f s" % max(T2_LEAD_S + T2_SECONDS - _elapsed, 0.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, UITheme.INK)


func _draw_cursor() -> void:
	draw_arc(_cursor, 13.0, 0.0, TAU, 48, Color(UITheme.INK, 0.85), 2.0)
	draw_circle(_cursor, 3.0, UITheme.INK)


func _draw_status_strip(vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var y := vp.y - 56.0
	var recording: bool = _status.get("rec", false)

	if recording:
		_draw_running_line(vp)
		return

	if _trial_name() in ["T1", "T3"]:
		draw_string(font, Vector2(260.0, y), "%d / %d" % [_current, _targets.size()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UITheme.INK)
	elif _trial_name() == "T2":
		draw_string(font, Vector2(260.0, y), "%.0f s at %.0f mm/s" % [T2_SECONDS, _speed_mm_s()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UITheme.INK)

	# Two indicators, right-hand side: sample rate and the OptiTrack gate.
	var rate: int = UDPReceiver.packets_per_sec
	var rate_ok: bool = rate >= 95
	_draw_pill(vp.x - 430.0, y, "%d /s" % rate, UITheme.LEAF if rate_ok else UITheme.APPLE_RED)
	var gate_on: bool = _status.get("gate", false)
	_draw_pill(vp.x - 300.0, y, "gate " + ("HIGH" if gate_on else "low"),
		UITheme.LEAF if gate_on else Color(UITheme.INK, 0.35))
	if recording:
		var n: int = int(_status.get("n", 0))
		_draw_pill(vp.x - 150.0, y, "%d" % n, UITheme.APPLE_RED)


# While recording: one small line in the top-left corner, on a chip so it stays
# readable over a dot. Everything else on screen belongs to the table.
func _draw_running_line(vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var bits := ["● " + str(_status.get("name", ""))]
	match _trial_name():
		"T1":
			bits.append("%d / %d" % [_current, _targets.size()])
			bits.append("space = hold")
		"T3":
			bits.append("%d / %d" % [_current, _targets.size()])
		"T2":
			bits.append("%.0f mm/s" % _speed_mm_s())
			bits.append("%.0f s left" % max(T2_LEAD_S + T2_SECONDS - _elapsed, 0.0))
	bits.append("%d /s" % UDPReceiver.packets_per_sec)
	bits.append("gate " + ("HIGH" if _status.get("gate", false) else "low"))
	bits.append("esc = stop")
	var text := "      ".join(bits)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x + 32.0
	draw_rect(Rect2(Vector2(16.0, 14.0), Vector2(w, 34.0)), Color(UITheme.PAPER, 0.88))
	var colour: Color = UITheme.INK if UDPReceiver.packets_per_sec >= 95 else UITheme.APPLE_RED
	draw_string(font, Vector2(32.0, 37.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, colour)


func _draw_pill(x: float, y: float, text: String, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 28.0
	draw_rect(Rect2(Vector2(x, y - 22.0), Vector2(w, 32.0)), Color(col, 0.16), true)
	draw_string(font, Vector2(x + 14.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)
