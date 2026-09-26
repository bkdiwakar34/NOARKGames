extends Control

# Settings (docs/clinic_study_interface.md §4.9), in the mockup's layout: a
# side menu (Mode, Device, Protocol, Data) and one page at a time. The Device
# tools themselves (origin lock, 4-corner mapping, validation recorder) still
# live in the patient app's installer for now.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")

signal done

const PAGES: Array = [
	["Mode", "Clinic / Home · researcher overlay"],
	["Device", "Tracker, origin, screen mapping"],
	["Protocol", "Levels, pairs, timing"],
	["Data", "Where files are saved"],
]

var db: StudyDB                  # set by clinic_main before adding the screen
var _nav: VBoxContainer
var _page: VBoxContainer
var _current: int = 2            # opens on Protocol
var _device: Label               # live text on the Device page
var _fields: Dictionary = {}     # Protocol page: key -> LineEdit or Array of LineEdit
var _ids: Array = []             # Protocol page: live ID labels of the pairs
var _visit: Label                # Protocol page: live "one visit ≈ N min"
var _error: Label


func _ready() -> void:
	var p := UI.page(self, "Settings")
	var bar: HBoxContainer = p["bar"]
	bar.add_child(UI.button("‹  Participants", func(): done.emit(), "ghost"))
	var body := UI.row(p["content"], 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_nav = VBoxContainer.new()
	_nav.custom_minimum_size = Vector2(250.0, 0.0)
	_nav.add_theme_constant_override("separation", 4)
	body.add_child(_nav)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 18)
	scroll.add_child(_page)
	_open(_current)


func _open(i: int) -> void:
	_current = i
	for c in _nav.get_children():
		c.queue_free()
	for k in PAGES.size():
		_nav.add_child(_nav_item(k))
	for c in _page.get_children():
		c.queue_free()
	_device = null
	_visit = null
	_fields = {}
	_ids = []
	match i:
		0: _build_mode()
		1: _build_device()
		2: _build_protocol()
		3: _build_data()


func _nav_item(k: int) -> Button:
	var on := k == _current
	var b := Button.new()
	b.custom_minimum_size = Vector2(0.0, 64.0)
	var bg: Color = UI.CARD if on else Color(0, 0, 0, 0)
	var box := UI._box(bg, UI.LINE if on else Color(0, 0, 0, 0), 12, 1, 14.0, 8.0)
	for s in ["normal", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, box)
	b.add_theme_stylebox_override("hover", UI._box(UI.CARD, UI.LINE, 12, 1, 14.0, 8.0))
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 14.0
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	var t := UI.label(PAGES[k][0], 16, UI.ACCENT_DARK if on else UI.INK, true)
	var s := UI.label(PAGES[k][1], 13, UI.MUTED)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(t)
	v.add_child(s)
	b.add_child(v)
	b.pressed.connect(func(): _open(k))
	return b


func _title(text: String) -> HBoxContainer:
	var h := UI.row(_page, 12)
	h.add_child(UI.label(text, 26, UI.INK, true))
	return h


# ── Mode ──────────────────────────────────────────────────────────────────────

func _build_mode() -> void:
	_title("Mode")
	var who := UI.card(_page)
	who.add_child(UI.label("Who runs the session", 16, UI.INK, true))
	var cards := UI.row(who, 14)
	_mode_card(cards, "Clinic", "You run each visit from the participant list: register, then "
		+ "calibration and play.", true)
	_mode_card(cards, "Home", "The device starts straight in the game; calibration and the day's "
		+ "level are applied automatically. Not built yet.", false)
	_switch_card("show_check", "Researcher overlay",
		"Shows the calibration check after calibration, to redo it if needed. Never shows the level "
		+ "or the lifetimes. Off: play starts by itself.")
	_switch_card("quick_test", "Quick test visits",
		"%d calibration + %d play rounds, %d s rests — for checking the app. A quick visit still "
		% [Protocol.QUICK_CALIB_ROUNDS, Protocol.QUICK_PLAY_ROUNDS, int(Protocol.QUICK_REST_S)]
		+ "counts as a study day for that participant.")


func _mode_card(parent: HBoxContainer, title: String, text: String, on: bool) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg: Color = Color("FFF8F6") if on else UI.CARD
	var border: Color = UI.ACCENT if on else UI.INPUT_LINE
	panel.add_theme_stylebox_override("panel", UI._box(bg, border, 14, 2, 20.0, 16.0))
	parent.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UI.label(title, 18, UI.INK if on else UI.MUTED, true))
	v.add_child(UI.label(text, 14, UI.INK2 if on else UI.MUTED, false, true))


func _switch_card(key: String, title: String, text: String) -> void:
	var c := UI.card(_page)
	var h := UI.row(c, 24)
	var t := VBoxContainer.new()
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_child(UI.label(title, 16, UI.INK, true))
	t.add_child(UI.label(text, 14, UI.MUTED, false, true))
	h.add_child(t)
	var sw := CheckButton.new()
	sw.button_pressed = bool(db.settings.get(key, false))
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.toggled.connect(func(on: bool):
		db.settings[key] = on
		db.save())
	h.add_child(sw)


# ── Device ────────────────────────────────────────────────────────────────────

func _build_device() -> void:
	_title("Device")
	var c := UI.card(_page)
	c.add_child(UI.label("Tracker and mapping", 16, UI.INK, true))
	_device = UI.label("", 16, UI.INK2)
	c.add_child(_device)
	UI.note_box(_page, "Origin lock, 4-corner screen mapping and the validation recorder: for now use the "
		+ "installer of the patient app (start it normally, then F10).")


func _process(_delta: float) -> void:
	if _device:
		var ts := TableSpace.new(get_viewport_rect().size)
		var ppm := ts.px_per_mm()
		var origin := FileAccess.file_exists("res://pyscripts/origin_lock.json")
		_device.text = "\n".join(PackedStringArray([
			"Tracker:  " + ("streaming, %d Hz" % UDPReceiver.packets_per_sec if UDPReceiver.is_fresh()
				else "not streaming"),
			"Screen mapping:  " + ("set, %.2f × %.2f px per mm (x × y)" % [ppm.x, ppm.y] if ts.mapped
				else "NOT SET — apples are drawn at a guessed scale"),
			"Origin lock:  " + ("present" if origin else "missing"),
		]))
	if _visit:
		_update_live()


# ── Protocol ──────────────────────────────────────────────────────────────────

func _build_protocol() -> void:
	var head := _title("Protocol")
	var locked: bool = Protocol.LOCKED
	head.add_child(UI.chip("v%d · %s" % [Protocol.VERSION, "locked" if locked else "draft"],
		UI.GOOD_BG if locked else UI.WARN_BG, UI.GOOD if locked else UI.WARN,
		Color("2E8B4A") if locked else UI.WARN_DOT))
	UI.spacer(head)
	var lock := CheckButton.new()
	lock.text = "Lock protocol"
	lock.button_pressed = locked
	lock.toggled.connect(func(on: bool):
		Protocol.set_locked(on)
		_open(2))
	head.add_child(lock)
	_page.add_child(UI.label("Locked: values are read-only and \"protocol v%d\" is written into every "
		% Protocol.VERSION + "data file header." if locked else
		"Draft: values can change while piloting; each saved change raises the version. Lock before "
		+ "the first real participant.", 14, UI.MUTED, false, true))

	var val: Dictionary = Protocol.values()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 18)
	_page.add_child(grid)

	var lv := _grid_card(grid, "Difficulty levels", "Percentile p of each pair's calibration movement times")
	var lrow := UI.row(lv, 12)
	var levels: Array = []
	for i in 3:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(UI.label("Level %d" % (i + 1), 14, UI.INK2, true))
		var e := _edit(str(val["levels"][i]))
		cell.add_child(e)
		levels.append(e)
		lrow.add_child(cell)
	_fields["levels"] = levels
	lv.add_child(UI.label("The same three for everyone; each participant's order is randomised and hidden.",
		13, UI.MUTED, false, true))

	var pv := _grid_card(grid, "Target pairs", "Fixed for everyone, in mm of hand movement")
	var pg := GridContainer.new()
	pg.columns = 4
	pg.add_theme_constant_override("h_separation", 12)
	pg.add_theme_constant_override("v_separation", 8)
	pv.add_child(pg)
	for h in ["Pair", "Distance A", "Width W", "ID"]:
		pg.add_child(UI.caption(h))
	for k in 3:
		var pair: Dictionary = val["pairs"][k]
		pg.add_child(UI.label(str(k + 1), 16, UI.INK, true))
		var a := _edit(str(pair["a_mm"]))
		var w := _edit(str(pair["w_mm"]))
		pg.add_child(a)
		pg.add_child(w)
		var id := UI.label("", 15, UI.INK2, true)
		id.custom_minimum_size = Vector2(90.0, 0.0)
		pg.add_child(id)
		_ids.append(id)
		_fields["pair%d" % k] = [a, w]
	pv.add_child(UI.label("ID = log2(A / W + 1), computed.", 13, UI.MUTED))

	var tv := _grid_card(grid, "Session timing", "")
	_line(tv, "round_s", "Round length (s)", val["round_s"])
	_line(tv, "rest_s", "Rest between rounds (s)", val["rest_s"])
	_line(tv, "calib_rounds", "Calibration rounds", val["calib_rounds"])
	_line(tv, "play_rounds", "Play rounds", val["play_rounds"])
	_line(tv, "hold_s", "Hold to catch (s)", val["hold_s"])
	_visit = UI.label("", 15, UI.INK, true)
	tv.add_child(_visit)

	var cv := _grid_card(grid, "Calibration game & reach scan", "")
	_line(cv, "point_cap_s", "Speed-point cap (s)", val["point_cap_s"])
	var limits := UI.row(cv, 12)
	var lt := UI.label("Point limits (s): 3 points below, 2 below", 15, UI.INK2, false, true)
	limits.add_child(lt)
	var l0 := _edit(str(val["point_limits_s"][0]), 90.0)
	var l1 := _edit(str(val["point_limits_s"][1]), 90.0)
	limits.add_child(l0)
	limits.add_child(l1)
	_fields["point_limits_s"] = [l0, l1]
	_line(cv, "reach_speed_mm_s", "Reach scan speed (mm/s)", val["reach_speed_mm_s"])
	_line(cv, "reach_wait_s", "Reach scan wait at the edge (s)", val["reach_wait_s"])

	_error = UI.label("", 15, UI.ACCENT, true, true)
	_page.add_child(_error)
	var buttons := UI.row(_page)
	UI.spacer(buttons)
	var save := UI.button("Save protocol", _save, "primary")
	save.disabled = locked
	buttons.add_child(save)


func _grid_card(grid: GridContainer, title: String, sub: String) -> VBoxContainer:
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(holder)
	var v := UI.card(holder, 20.0, 10)
	v.get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(title, 16, UI.INK, true))
	if sub != "":
		v.add_child(UI.label(sub, 13, UI.MUTED, false, true))
	return v


func _edit(text: String, width: float = 0.0) -> LineEdit:
	var e := UI.field(text, width)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL if width == 0.0 else Control.SIZE_SHRINK_END
	e.editable = not Protocol.LOCKED
	return e


func _line(v: VBoxContainer, key: String, caption: String, value) -> void:
	var h := UI.row(v, 12)
	h.add_child(UI.label(caption, 15, UI.INK2, false, true))
	var e := _edit(str(value), 110.0)
	h.add_child(e)
	_fields[key] = e


func _num(key: String, i: int = -1) -> float:
	var f = _fields[key]
	var e: LineEdit = f[i] if i >= 0 else f
	var t := e.text.strip_edges()
	return float(t) if t.is_valid_float() else -1.0


func _update_live() -> void:
	for k in _ids.size():
		var a := _num("pair%d" % k, 0)
		var w := _num("pair%d" % k, 1)
		_ids[k].text = "%.2f bits" % Protocol.id_bits(a, w) if a > 0.0 and w > 0.0 else "—"
	var c := _num("calib_rounds")
	var n := _num("play_rounds")
	var r := _num("round_s")
	var rest := _num("rest_s")
	if c > 0.0 and n > 0.0 and r > 0.0 and rest >= 0.0:
		var s := 40.0 + (float(Protocol.WARMUP_ROUNDS) + c + n) * r + (c + n) * rest
		_visit.text = "One visit ≈ %d min" % roundi(s / 60.0)
	else:
		_visit.text = "One visit: —"


func _save() -> void:
	var v: Dictionary = {
		"levels": [_num("levels", 0), _num("levels", 1), _num("levels", 2)],
		"pairs": [],
		"hold_s": _num("hold_s"), "round_s": _num("round_s"), "rest_s": _num("rest_s"),
		"calib_rounds": int(_num("calib_rounds")), "play_rounds": int(_num("play_rounds")),
		"point_cap_s": _num("point_cap_s"),
		"point_limits_s": [_num("point_limits_s", 0), _num("point_limits_s", 1)],
		"reach_speed_mm_s": _num("reach_speed_mm_s"), "reach_wait_s": _num("reach_wait_s"),
	}
	for k in 3:
		v["pairs"].append({"a_mm": _num("pair%d" % k, 0), "w_mm": _num("pair%d" % k, 1)})
	var err := _check(v)
	if err != "":
		_error.text = err
		return
	Protocol.save_values(v)
	_open(2)


func _check(v: Dictionary) -> String:
	for p in v["levels"]:
		if p <= 0.0 or p >= 1.0:
			return "Each level must be between 0 and 1, e.g. 0.75."
	for pair in v["pairs"]:
		if pair["a_mm"] <= 0.0 or pair["w_mm"] <= 0.0:
			return "Pair distances and widths must be positive numbers."
	for key in ["hold_s", "round_s", "rest_s", "point_cap_s", "reach_speed_mm_s", "reach_wait_s"]:
		if v[key] <= 0.0:
			return "Every time and speed must be a positive number."
	if v["calib_rounds"] < 1 or v["play_rounds"] < 1:
		return "At least one calibration and one play round."
	if v["point_limits_s"][0] <= 0.0 or v["point_limits_s"][1] <= v["point_limits_s"][0]:
		return "Point limits: two positive numbers, the second larger."
	return ""


# ── Data ──────────────────────────────────────────────────────────────────────

func _build_data() -> void:
	_title("Data")
	var dir := Protocol.data_dir()
	var c := UI.card(_page)
	c.add_child(UI.label("Where it is saved", 16, UI.INK, true))
	var h := UI.row(c, 12)
	var path := PanelContainer.new()
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path.add_theme_stylebox_override("panel", UI._box(UI.SOFT, Color("ECE8DF"), 10, 1, 14.0, 10.0))
	path.add_child(UI.label(dir + "/<participant ID>/<visit start>/", 15, UI.INK, false, true))
	h.add_child(path)
	h.add_child(UI.button("Open folder", func(): OS.shell_open(dir)))
	c.add_child(UI.label("Rows are written to disk as they happen, so a power cut loses nothing. "
		+ "Files use the participant ID only, never the name.", 14, UI.MUTED, false, true))

	var f := UI.card(_page, 22.0, 0)
	f.add_child(UI.label("Files per visit", 16, UI.INK, true))
	var files: Array = [
		["targets.csv", "One row per apple: phase, round, pair, where, when, lifetime, outcome, movement time, points."],
		["hand.csv", "Every tracker sample at 100 Hz: hand position in table mm, capture time."],
		["reach.csv", "The reach scan: how far the hand got in each of the 8 directions."],
		["calibration.csv", "Per pair: calibration result and the lifetime used for play."],
	]
	for row in files:
		UI.line(f)
		var r := UI.row(f, 18)
		var name_label := UI.label(row[0], 15, UI.INK, true)
		name_label.custom_minimum_size = Vector2(170.0, 0.0)
		r.add_child(name_label)
		r.add_child(UI.label(row[1], 14, UI.INK2, false, true))
	var also := UI.label("Next to them: participants.json (study days, level orders) and protocol.json.",
		14, UI.MUTED, false, true)
	_page.add_child(also)
