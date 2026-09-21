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
const COVER_COLS := 24         # T2 coverage cells across the whole screen
const COVER_ROWS := 16

var _trial: OptionButton
var _cond: OptionButton
var _rep: OptionButton
var _name_lbl: Label
var _rec_btn: Button
var _hint: Label

var _targets: Array = []       # [{pos: Vector2, done: bool}]
var _current: int = 0
var _hold_t: float = 0.0
var _holding: bool = false     # T1: a spacebar-started hold is running
var _cursor: Vector2 = Vector2.ZERO
var _trail: Array = []         # T2: recent cursor positions
var _cells: Dictionary = {}    # T2: visited coverage cells
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
	_cond.item_selected.connect(func(_i: int): _update_name())
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

	var back := Button.new()
	back.text = "Close"
	back.custom_minimum_size = Vector2(110.0, 52.0)
	back.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.INK))
	back.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.INK.lightened(0.18)))
	back.add_theme_color_override("font_color", Color.WHITE)
	back.add_theme_color_override("font_hover_color", Color.WHITE)
	back.pressed.connect(_close)
	add_child(back)
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	back.position = Vector2(get_viewport_rect().size.x - 150.0, 28.0)

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
	_update_name()
	_rebuild_targets()


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


# ── targets ───────────────────────────────────────────────────────────────────

func _rebuild_targets() -> void:
	var vp := get_viewport_rect().size
	var lo := Vector2(vp.x * MARGIN.x, vp.y * MARGIN.y)
	var hi := Vector2(vp.x * (1.0 - MARGIN.x), vp.y * (1.0 - MARGIN.y))
	_targets = []
	_current = 0
	_hold_t = 0.0
	_holding = false
	_cells = {}
	_trail = []

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
			# Centre-out reaches: 8 directions at two distances, near first.
			var centre := (lo + hi) * 0.5
			var far: float = min(hi.x - lo.x, hi.y - lo.y) * 0.5
			for d in [far * 0.45, far * 0.95]:
				for k in T3_DIRECTIONS:
					var a: float = TAU * float(k) / float(T3_DIRECTIONS)
					_targets.append({"pos": centre + Vector2(cos(a), sin(a)) * d,
									 "done": false})
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
		_advance_targets(delta)
		_update_coverage()

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
			_mark("reached")
			target["done"] = true
			_current += 1
			_hold_t = 0.0
	else:
		_hold_t = 0.0


func _update_coverage() -> void:
	if _trial_name() != "T2":
		return
	var vp := get_viewport_rect().size
	var cell := Vector2i(int(_cursor.x / (vp.x / COVER_COLS)),
						 int(_cursor.y / (vp.y / COVER_ROWS)))
	_cells[cell] = true
	_trail.append(_cursor)
	if _trail.size() > 220:
		_trail.pop_front()


func _refresh_buttons() -> void:
	var recording: bool = _status.get("rec", false)
	var pending: bool = (UDPReceiver.requested_recording() != "") != recording
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
	match _trial_name():
		"T1", "T3":
			_draw_targets()
		"T2":
			_draw_coverage(vp)
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


func _draw_coverage(vp: Vector2) -> void:
	var cell := Vector2(vp.x / COVER_COLS, vp.y / COVER_ROWS)
	for key in _cells:
		var c: Vector2i = key
		# Inset a little so the cells read as a stippled area, not as blocks.
		draw_rect(Rect2(Vector2(c.x, c.y) * cell + cell * 0.18, cell * 0.64),
			Color(UITheme.LEAF, 0.22))
	for i in range(1, _trail.size()):
		draw_line(_trail[i - 1], _trail[i], Color(UITheme.LASER, 0.55), 2.0)


func _draw_cursor() -> void:
	draw_arc(_cursor, 13.0, 0.0, TAU, 48, Color(UITheme.INK, 0.85), 2.0)
	draw_circle(_cursor, 3.0, UITheme.INK)


func _draw_status_strip(vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var y := vp.y - 56.0
	var recording: bool = _status.get("rec", false)

	if _trial_name() in ["T1", "T3"]:
		draw_string(font, Vector2(260.0, y), "%d / %d" % [_current, _targets.size()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UITheme.INK)
	elif _trial_name() == "T2":
		var covered := int(round(100.0 * float(_cells.size()) / float(COVER_COLS * COVER_ROWS)))
		draw_string(font, Vector2(260.0, y), "covered %d%%" % covered,
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


func _draw_pill(x: float, y: float, text: String, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 28.0
	draw_rect(Rect2(Vector2(x, y - 22.0), Vector2(w, 32.0)), Color(col, 0.16), true)
	draw_string(font, Vector2(x + 14.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)
