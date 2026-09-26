extends Control

# Settings (docs/clinic_study_interface.md §4.9): Mode, Device, Protocol, Data.
# Plain look for now. The Device tools themselves (origin lock, 4-corner
# mapping, validation recorder) still live in the patient app's installer.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")

signal done

var db: StudyDB                  # set by clinic_main before adding the screen
var _device: Label
var _proto_fields: Dictionary = {}   # key -> LineEdit (or Array of LineEdit)
var _proto_status: Label
var _proto_error: Label
var _lock: CheckButton


func _ready() -> void:
	var v := UI.page(self)
	var top := UI.row(v)
	top.add_child(UI.label("Settings", UI.TITLE))
	UI.spacer(top)
	top.add_child(UI.button("Back to participants", func(): done.emit()))

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", UI.TEXT)
	v.add_child(tabs)
	_build_mode(_tab(tabs, "Mode"))
	_build_device(_tab(tabs, "Device"))
	_build_protocol(_tab(tabs, "Protocol"))
	_build_data(_tab(tabs, "Data"))


func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	tabs.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	scroll.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	margin.add_child(v)
	return v


# ── Mode ──────────────────────────────────────────────────────────────────────

func _build_mode(v: VBoxContainer) -> void:
	v.add_child(UI.label("Clinic mode: you run each visit from the participant list.", 18))
	v.add_child(UI.label("Home mode (straight to the game, for home use) is not built yet.", 16, UI.MUTED))
	_check(v, "show_check", "Show the calibration check after calibration (researcher overlay)",
		"It never shows the level or the lifetimes. Off: play starts by itself.")
	_check(v, "quick_test", "Quick test visits: %d calibration + %d play rounds, %d s rests" % [
		Protocol.QUICK_CALIB_ROUNDS, Protocol.QUICK_PLAY_ROUNDS, int(Protocol.QUICK_REST_S)],
		"For checking the app. A quick visit still counts as a study day for that participant.")


func _check(v: VBoxContainer, key: String, text: String, note: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.add_theme_font_size_override("font_size", UI.TEXT)
	c.button_pressed = bool(db.settings.get(key, false))
	c.toggled.connect(func(on: bool):
		db.settings[key] = on
		db.save())
	v.add_child(c)
	v.add_child(UI.label("      " + note, 15, UI.MUTED))


# ── Device ────────────────────────────────────────────────────────────────────

func _build_device(v: VBoxContainer) -> void:
	_device = UI.label("", 18)
	v.add_child(_device)
	v.add_child(UI.label("Origin lock, 4-corner screen mapping and the validation recorder: for now use "
		+ "the installer of the patient app (start it normally, F10).", 16, UI.MUTED))


func _process(_delta: float) -> void:
	var ts := TableSpace.new(get_viewport_rect().size)
	var ppm := ts.px_per_mm()
	var origin := FileAccess.file_exists("res://pyscripts/origin_lock.json")
	var lines := PackedStringArray([
		"Tracker: " + ("streaming, %d Hz" % UDPReceiver.packets_per_sec if UDPReceiver.is_fresh()
			else "not streaming"),
		"Screen mapping: " + ("set, %.2f × %.2f px per mm (x × y)" % [ppm.x, ppm.y] if ts.mapped
			else "NOT SET — apples are drawn at a guessed scale"),
		"Origin lock: " + ("present" if origin else "missing"),
	])
	_device.text = "\n".join(lines)


# ── Protocol ──────────────────────────────────────────────────────────────────

func _build_protocol(v: VBoxContainer) -> void:
	var head := UI.row(v)
	_proto_status = UI.label("", 20)
	head.add_child(_proto_status)
	UI.spacer(head)
	_lock = CheckButton.new()
	_lock.text = "Lock protocol"
	_lock.add_theme_font_size_override("font_size", UI.TEXT)
	_lock.button_pressed = Protocol.LOCKED
	_lock.toggled.connect(_on_lock)
	head.add_child(_lock)

	var val: Dictionary = Protocol.values()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 10)
	v.add_child(grid)
	_multi(grid, "levels", "Levels (percentile p): level 1, 2, 3", val["levels"])
	for k in 3:
		var pair: Dictionary = val["pairs"][k]
		_multi(grid, "pair%d" % k, "Pair %d: A, W (mm)" % (k + 1), [pair["a_mm"], pair["w_mm"]])
	_single(grid, "hold_s", "Hold to catch (s)", val["hold_s"])
	_single(grid, "round_s", "Round length (s)", val["round_s"])
	_single(grid, "rest_s", "Rest between rounds (s)", val["rest_s"])
	_single(grid, "calib_rounds", "Calibration rounds", val["calib_rounds"])
	_single(grid, "play_rounds", "Play rounds", val["play_rounds"])
	_single(grid, "point_cap_s", "Speed-point cap (s)", val["point_cap_s"])
	_multi(grid, "point_limits_s", "Point limits (s): 3 points below, 2 points below", val["point_limits_s"])
	_single(grid, "reach_speed_mm_s", "Reach scan speed (mm/s)", val["reach_speed_mm_s"])
	_single(grid, "reach_wait_s", "Reach scan wait at the edge (s)", val["reach_wait_s"])

	_proto_error = UI.label("", 18, UI.ACCENT)
	v.add_child(_proto_error)
	var buttons := UI.row(v)
	buttons.add_child(UI.button("Save protocol", _save_protocol, true))
	_refresh_protocol()


func _single(grid: GridContainer, key: String, caption: String, value) -> void:
	grid.add_child(UI.label(caption, 17, UI.MUTED))
	var e := UI.field(str(value), 140.0)
	_proto_fields[key] = e
	grid.add_child(e)


func _multi(grid: GridContainer, key: String, caption: String, values: Array) -> void:
	grid.add_child(UI.label(caption, 17, UI.MUTED))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var edits: Array = []
	for x in values:
		var e := UI.field(str(x), 110.0)
		edits.append(e)
		h.add_child(e)
	_proto_fields[key] = edits
	grid.add_child(h)


func _refresh_protocol() -> void:
	_proto_status.text = "Protocol v%d · %s" % [Protocol.VERSION, "locked" if Protocol.LOCKED else "draft"]
	_proto_status.add_theme_color_override("font_color", UI.GOOD if Protocol.LOCKED else UI.WARN)
	for key in _proto_fields:
		var f = _proto_fields[key]
		for e in (f if f is Array else [f]):
			e.editable = not Protocol.LOCKED


func _on_lock(on: bool) -> void:
	Protocol.set_locked(on)
	_refresh_protocol()


func _num(key: String, i: int = -1) -> float:
	var f = _proto_fields[key]
	var e: LineEdit = f[i] if i >= 0 else f
	var t := e.text.strip_edges()
	return float(t) if t.is_valid_float() else -1.0


func _save_protocol() -> void:
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
	var err := _check_protocol(v)
	if err != "":
		_proto_error.text = err
		return
	_proto_error.text = ""
	Protocol.save_values(v)
	_refresh_protocol()


func _check_protocol(v: Dictionary) -> String:
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

func _build_data(v: VBoxContainer) -> void:
	var dir := Protocol.data_dir()
	v.add_child(UI.label("Everything is saved in", 18, UI.MUTED))
	v.add_child(UI.label(dir, 20))
	v.add_child(UI.label("participants.json and protocol.json, and one folder per participant with a "
		+ "folder per visit: targets.csv, hand.csv, reach.csv, calibration.csv. Files use the ID only.",
		16, UI.MUTED))
	var buttons := UI.row(v)
	buttons.add_child(UI.button("Open folder", func(): OS.shell_open(dir)))
