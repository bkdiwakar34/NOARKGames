extends Control

# Settings (docs/clinic_study_interface.md §4.9), in the mockup's layout: a
# side menu (Mode, Device, Protocol, Data) and one page at a time.
# Device opens the patient app's installer tools for origin lock, 4-corner
# mapping and the validation recorder (the same overlays, reused unchanged),
# runs a test drive, and switches the tracker's own debug preview window.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")

signal done
signal test_drive

const PAGES: Array = [
	["Mode", "Clinic / Home · researcher overlay"],
	["Device", "Tracker, origin, screen mapping, validation"],
	["Protocol", "Levels, pairs, timing"],
	["Data", "Folder and export"],
]

static var _preview_on: bool = false   # the tracker's debug preview window (kept across pages)

var db: StudyDB                  # set by clinic_main before adding the screen
var _nav: VBoxContainer
var _page: VBoxContainer
var _current: int = 2            # opens on Protocol
var _tool: Control = null        # an open installer overlay (Esc belongs to it)
var _live: Dictionary = {}       # Device page: labels updated every frame
var _fields: Dictionary = {}     # Protocol page: key -> LineEdit or Array of LineEdit
var _ids: Array = []             # Protocol page: live ID labels of the pairs
var _visit: Label                # Protocol page: live "one visit ≈ N min"
var _error: Label
var _export_pick: OptionButton
var _export_msg: Label


func _ready() -> void:
	var p := UI.page(self, "Settings")
	var bar: HBoxContainer = p["bar"]
	bar.add_child(UI.button("‹  Participants", func(): done.emit(), "ghost"))
	var body := UI.row(p["content"], 25)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_nav = VBoxContainer.new()
	_nav.custom_minimum_size = Vector2(216.0, 0.0)
	_nav.add_theme_constant_override("separation", 4)
	body.add_child(_nav)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 16)
	scroll.add_child(_page)
	_open(_current)


# True while an installer tool is open: clinic_main leaves Esc to it.
func busy() -> bool:
	return is_instance_valid(_tool)


func _open(i: int) -> void:
	_current = i
	for c in _nav.get_children():
		c.queue_free()
	for k in PAGES.size():
		_nav.add_child(_nav_item(k))
	for c in _page.get_children():
		c.queue_free()
	_live = {}
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
	b.custom_minimum_size = Vector2(0.0, 56.0)
	b.focus_mode = Control.FOCUS_NONE
	var bg: Color = UI.CARD if on else Color(0, 0, 0, 0)
	var box := UI._box(bg, UI.LINE if on else Color(0, 0, 0, 0), 11, 1, 13.0, 7.0)
	for s in ["normal", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, box)
	b.add_theme_stylebox_override("hover", UI._box(UI.CARD, UI.LINE, 11, 1, 13.0, 7.0))
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 13.0
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 1)
	var t := UI.label(PAGES[k][0], 14, UI.ACCENT_DARK if on else UI.INK, true)
	var s := UI.label(PAGES[k][1], 11, UI.MUTED)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(t)
	v.add_child(s)
	b.add_child(v)
	b.pressed.connect(func(): _open(k))
	return b


func _title(text: String) -> HBoxContainer:
	var h := UI.row(_page, 11)
	h.add_child(UI.label(text, 23, UI.INK, true))
	return h


# A card row: title and a note on the left, a control on the right.
func _row(parent: VBoxContainer, title: String, note: String, control: Control, first: bool = false) -> void:
	if not first:
		UI.line(parent)
	var h := UI.row(parent, 16)
	var t := VBoxContainer.new()
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_constant_override("separation", 1)
	t.add_child(UI.label(title, 13, UI.INK2))
	if note != "":
		t.add_child(UI.label(note, 11, UI.MUTED, false, true))
	h.add_child(t)
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(control)


# ── Mode ──────────────────────────────────────────────────────────────────────

func _build_mode() -> void:
	_title("Mode")
	var who := UI.card(_page, 22.0, 14)
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(UI.label("Who runs the session", 14, UI.INK, true))
	head.add_child(UI.label("Takes effect the next time the app starts a session", 12, UI.MUTED))
	who.add_child(head)
	var cards := UI.row(who, 13)
	var mode := String(db.settings.get("mode", "clinic"))
	_mode_card(cards, "clinic", "Clinic", "You run each visit from the participant list: register, then "
		+ "calibration and play.", "Home → reach scan → warm-up → calibration → play", mode == "clinic")
	_mode_card(cards, "home", "Home", "The device starts straight in the game. Calibration and the day's "
		+ "level are applied automatically.", "Game → calibration → play", mode == "home")
	if mode == "home":
		who.add_child(UI.label("Home mode is not built yet: the app still runs Clinic mode.", 12, UI.WARN, true))

	var ov := UI.card(_page, 22.0, 8)
	_row(ov, "Researcher overlay", "Adds a diagnostics panel on top of the participant screens and the "
		+ "calibration check after calibration. Never shows the level or the lifetimes. Off by default.",
		UI.switch(bool(db.settings.get("show_check", false)), func(on: bool): _setting("show_check", on)), true)
	var qt := UI.card(_page, 22.0, 8)
	_row(qt, "Quick test visits", "%d calibration + %d play rounds, %d s rests, for checking the app. "
		% [Protocol.QUICK_CALIB_ROUNDS, Protocol.QUICK_PLAY_ROUNDS, int(Protocol.QUICK_REST_S)]
		+ "A quick visit still counts as a study day for that participant.",
		UI.switch(bool(db.settings.get("quick_test", false)), func(on: bool): _setting("quick_test", on)), true)


func _setting(key: String, value) -> void:
	db.settings[key] = value
	db.save()


func _mode_card(parent: HBoxContainer, key: String, title: String, text: String, flow: String,
		on: bool) -> void:
	var b := Button.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0.0, 118.0)
	b.focus_mode = Control.FOCUS_NONE
	var bg: Color = Color("FFF8F6") if on else UI.CARD
	var border: Color = UI.ACCENT if on else UI.INPUT_LINE
	for s in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, UI._box(bg, border, 13, 2, 18.0, 14.0))
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 18.0
	v.offset_right = -18.0
	v.offset_top = 14.0
	v.add_theme_constant_override("separation", 7)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := UI.label(title, 16, UI.INK, true)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(t)
	UI.spacer(top)
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(20.0, 20.0)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func():
		dot.draw_circle(Vector2(10.0, 10.0), 9.0, border, false, 2.0, true)
		if on:
			dot.draw_circle(Vector2(10.0, 10.0), 4.5, UI.ACCENT, true, -1.0, true))
	top.add_child(dot)
	v.add_child(top)
	for line in [[text, 12, UI.INK2, false], [flow, 11, UI.MUTED, true]]:
		var l := UI.label(line[0], line[1], line[2], line[3], true)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(l)
	b.add_child(v)
	var pick := func():
		_setting("mode", key)
		_open.call_deferred(0)
	b.pressed.connect(pick)
	parent.add_child(b)


# ── Device ────────────────────────────────────────────────────────────────────

func _build_device() -> void:
	_title("Device")
	var tracker := UI.card(_page, 20.0, 10)
	var h := UI.row(tracker, 18)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(250.0, 0.0)
	left.add_theme_constant_override("separation", 6)
	h.add_child(left)
	var head := UI.row(left, 9)
	head.add_child(UI.label("Tracker", 14, UI.INK, true))
	var chip_slot := HBoxContainer.new()
	head.add_child(chip_slot)
	_live["chip"] = chip_slot
	for key in ["Sample rate", "Tags seen", "Device at", "Fusion"]:
		UI.line(left)
		var r := UI.row(left, 8)
		r.add_child(UI.label(key, 12, UI.MUTED))
		UI.spacer(r)
		var v := UI.label("—", 12, UI.INK, true)
		r.add_child(v)
		_live[key] = v
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(spacer)
	var prev := UI.button("Close debug preview" if _preview_on else "Open debug preview", _toggle_preview)
	left.add_child(prev)
	left.add_child(UI.label("The tracker's own camera window, with tag IDs and the search box. "
		+ "Costs frame rate while open.", 11, UI.MUTED, false, true))
	var tiles := UI.row(h, 11)
	tiles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for cam in 2:
		tiles.add_child(_cam_tile(cam))

	var tools := UI.card(_page, 20.0, 8)
	var origin := FileAccess.file_exists("res://pyscripts/origin_lock.json")
	var ts := TableSpace.new(get_viewport_rect().size)
	var ppm := ts.px_per_mm()
	_tool_row(tools, "Origin lock", "Device at the marked parking pose → confirm. One deliberate lock per "
		+ "installation.", "Locked" if origin else "Missing", origin, "Re-lock…", _relock, true)
	_tool_row(tools, "Screen mapping", "Four corners in order: top-left → top-right → bottom-left → "
		+ "bottom-right.", ("Set · %.1f × %.1f px/mm" % [ppm.x, ppm.y]) if ts.mapped else "Not set",
		ts.mapped, "Redo mapping", func(): _open_tool("res://app/installer/workspace_calibration_overlay.gd"))
	_tool_row(tools, "Test drive", "Live cursor and endless fireflies, nothing saved — to see the whole "
		+ "loop working.", "", true, "Start", func(): test_drive.emit())
	_tool_row(tools, "Validation recorder", "Record a grid for the OptiTrack comparison (Esc leaves it).",
		"", true, "Open", func(): _open_tool("res://app/installer/validation_recorder.gd"))


# One camera: its tag count, live from the tracker's status packets. The
# picture itself is only in the debug preview (the tracker sends no images).
func _cam_tile(cam: int) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(0.0, 176.0)
	panel.add_theme_stylebox_override("panel", UI._box(Color("1E211D"), Color("1E211D"), 11, 0, 12.0, 10.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	v.add_child(UI.label("cam%d" % cam, 12, Color.WHITE, true))
	var mid := CenterContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(mid)
	var n := UI.label("—", 30, Color.WHITE, true)
	mid.add_child(n)
	_live["cam%d" % cam] = n
	var note := UI.label("tags per frame", 11, Color(1, 1, 1, 0.55))
	v.add_child(note)
	_live["cam%d_note" % cam] = note
	v.add_child(UI.label("picture: Open debug preview", 10, Color(1, 1, 1, 0.4)))
	return panel


func _tool_row(parent: VBoxContainer, title: String, note: String, state: String, ok: bool,
		action: String, on_press: Callable, first: bool = false) -> void:
	if not first:
		UI.line(parent)
	var h := UI.row(parent, 14)
	var mark := PanelContainer.new()
	var col: Color = UI.GOOD_BG if ok else UI.WARN_BG
	mark.add_theme_stylebox_override("panel", UI._box(col, col, 13, 0, 8.0, 2.0))
	mark.add_child(UI.label(("✓" if ok else "!") if state != "" else "▸", 13,
		UI.GOOD if ok else UI.WARN, true))
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(mark)
	var t := VBoxContainer.new()
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_constant_override("separation", 1)
	t.add_child(UI.label(title, 14, UI.INK, true))
	t.add_child(UI.label(note, 12, UI.MUTED, false, true))
	h.add_child(t)
	if state != "":
		var s := UI.label(state, 12, UI.GOOD if ok else UI.WARN, true)
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(s)
	var b := UI.button(action, on_press)
	b.custom_minimum_size.x = 135.0
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(b)


func _open_tool(path: String) -> void:
	_tool = load(path).new()
	add_child(_tool)
	_tool.tree_exited.connect(func():
		if is_inside_tree() and not is_queued_for_deletion():
			_open.call_deferred(1))   # refresh the statuses it may have changed


func _relock() -> void:
	var m := UI.modal(self, 440.0)
	var layer: Control = m["layer"]
	var card: VBoxContainer = m["card"]
	card.add_child(UI.label("Re-lock the origin?", 20, UI.INK, true))
	card.add_child(UI.label("Put the device at the marked parking pose and keep it still, then press "
		+ "Lock. Every later recording uses the new origin.", 13, UI.INK2, false, true))
	var buttons := UI.row(card, 11)
	UI.spacer(buttons)
	buttons.add_child(UI.button("Cancel", func(): layer.queue_free()))
	var lock := func():
		UDPReceiver.request_origin_relock()
		layer.queue_free()
	buttons.add_child(UI.button("Lock", lock, "primary"))


func _toggle_preview() -> void:
	_preview_on = not _preview_on
	UDPReceiver.send_command("PREVIEW_ON" if _preview_on else "PREVIEW_OFF")
	_open(1)


func _process(_delta: float) -> void:
	if _live.is_empty() and _visit == null:
		return
	if not _live.is_empty():
		var fresh: bool = UDPReceiver.is_fresh()
		var st: Dictionary = UDPReceiver.recorder_status()
		var slot: HBoxContainer = _live["chip"]
		if slot.get_child_count() == 0 or bool(slot.get_meta("fresh", not fresh)) != fresh:
			for c in slot.get_children():
				c.queue_free()
			slot.add_child(UI.chip("Streaming" if fresh else "Not streaming", UI.GOOD_BG if fresh else UI.WARN_BG,
				UI.GOOD if fresh else UI.WARN, Color("2E8B4A") if fresh else UI.ACCENT))
			slot.set_meta("fresh", fresh)
		_live["Sample rate"].text = "%d Hz" % UDPReceiver.packets_per_sec if fresh else "—"
		_live["Tags seen"].text = "%.1f + %.1f" % [float(st.get("m0", 0)), float(st.get("m1", 0))] if fresh else "—"
		_live["Device at"].text = ("%.0f, %.0f mm" % [float(st["x_mm"]), float(st["z_mm"])]) \
			if fresh and st.has("x_mm") else "not seen"
		_live["Fusion"].text = String(st.get("fusion", "")) if fresh and String(st.get("fusion", "")) != "" else "—"
		# Mean over the last half second (the tracker's status window), and the
		# share of passes that had this camera's frame at all.
		for cam in 2:
			var paired: float = float(st.get("p%d" % cam, 0.0))
			_live["cam%d" % cam].text = "%.1f" % float(st.get("m%d" % cam, 0)) if fresh else "—"
			var note: Label = _live["cam%d_note" % cam]
			note.text = ("tags per frame · paired %d %%" % roundi(100.0 * paired)) if fresh else "tags per frame"
			note.add_theme_color_override("font_color",
				Color(1, 0.72, 0.45) if fresh and paired < 0.95 else Color(1, 1, 1, 0.55))
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
	var lock_box := PanelContainer.new()
	lock_box.add_theme_stylebox_override("panel", UI._box(UI.CARD, UI.INPUT_LINE, 11, 1, 11.0, 7.0))
	var lock_row := UI.row(lock_box, 10)
	var relock := func(on: bool):
		Protocol.set_locked(on)
		_open.call_deferred(2)
	lock_row.add_child(UI.switch(locked, relock))
	lock_row.add_child(UI.label("Lock protocol", 13, UI.INK, true))
	head.add_child(lock_box)
	_page.add_child(UI.label(("Locked. Values are read-only and \"protocol v%d\" is written into every data "
		+ "file header.") % Protocol.VERSION if locked else
		"Draft: values can change while piloting; each saved change raises the version. Lock before "
		+ "the first real participant.", 12, UI.MUTED, false, true))

	var val: Dictionary = Protocol.values()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	_page.add_child(grid)

	var lv := _grid_card(grid, "Difficulty levels", "Percentile p of each pair's calibration movement times")
	var lrow := UI.row(lv, 11)
	var levels: Array = []
	for i in 3:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(UI.label("Level %d" % (i + 1), 12, UI.INK2, true))
		var e := _edit(str(val["levels"][i]))
		cell.add_child(e)
		levels.append(e)
		lrow.add_child(cell)
	_fields["levels"] = levels
	lv.add_child(UI.label("The same three for everyone; each participant's order is randomised and hidden. "
		+ "Lifetime of pair k = the p-th value of that day's sorted movement times.", 11, UI.MUTED, false, true))

	var pv := _grid_card(grid, "Target pairs", "Fixed for everyone · mm of hand movement")
	var pg := GridContainer.new()
	pg.columns = 4
	pg.add_theme_constant_override("h_separation", 11)
	pg.add_theme_constant_override("v_separation", 7)
	pv.add_child(pg)
	for h in ["Pair", "Distance A", "Width W", "ID"]:
		pg.add_child(UI.caption(h))
	for k in 3:
		var pair: Dictionary = val["pairs"][k]
		pg.add_child(UI.label(str(k + 1), 14, UI.INK, true))
		var a := _edit(str(pair["a_mm"]))
		var w := _edit(str(pair["w_mm"]))
		pg.add_child(a)
		pg.add_child(w)
		var id := UI.label("", 13, UI.INK2, true)
		id.custom_minimum_size = Vector2(80.0, 0.0)
		pg.add_child(id)
		_ids.append(id)
		_fields["pair%d" % k] = [a, w]
	pv.add_child(UI.label("ID = log2(A / W + 1), computed.", 11, UI.MUTED))

	var tv := _grid_card(grid, "Session timing", "")
	_line(tv, "round_s", "Round length (s)", "", val["round_s"], true)
	_line(tv, "rest_s", "Rest between rounds (s)", "", val["rest_s"])
	_fixed(tv, "Warm-up round (not counted)", "", "1 round")
	_line(tv, "calib_rounds", "Calibration rounds", "", val["calib_rounds"])
	_line(tv, "play_rounds", "Play rounds", "", val["play_rounds"])
	var visit_box := PanelContainer.new()
	visit_box.add_theme_stylebox_override("panel", UI._box(UI.SOFT, UI.SOFT, 9, 0, 11.0, 8.0))
	var vr := UI.row(visit_box, 8)
	vr.add_child(UI.label("One visit", 12, UI.INK2, true))
	UI.spacer(vr)
	_visit = UI.label("", 13, UI.INK, true)
	vr.add_child(_visit)
	tv.add_child(visit_box)

	var cv := _grid_card(grid, "Calibration game & reach scan", "")
	_line(cv, "point_cap_s", "Speed-point cap (s)", "Target waits at most this long", val["point_cap_s"], true)
	var limits := HBoxContainer.new()
	limits.add_theme_constant_override("separation", 6)
	var l0 := _edit(str(val["point_limits_s"][0]), 62.0)
	var l1 := _edit(str(val["point_limits_s"][1]), 62.0)
	limits.add_child(l0)
	limits.add_child(l1)
	_fields["point_limits_s"] = [l0, l1]
	_row(cv, "Point limits (s)", "3 points below the first, 2 below the second", limits)
	_line(cv, "hold_s", "Hold to catch (s)", "Unbroken time inside the circle", val["hold_s"])
	_fixed(cv, "Reach scan directions", "Spokes from the centre", str(Protocol.REACH_SPOKES))
	_line(cv, "reach_speed_mm_s", "Reach scan target speed (mm/s)", "Glides out past reach and back",
		val["reach_speed_mm_s"])
	_line(cv, "reach_wait_s", "Reach scan wait at the edge (s)", "", val["reach_wait_s"])

	_error = UI.label("", 13, UI.ACCENT, true, true)
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
	var v := UI.card(holder, 18.0, 9)
	v.get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(UI.label(title, 14, UI.INK, true))
	if sub != "":
		head.add_child(UI.label(sub, 12, UI.MUTED, false, true))
	v.add_child(head)
	return v


func _edit(text: String, width: float = 0.0) -> LineEdit:
	var e := UI.field(text, width)
	e.custom_minimum_size.y = 36.0
	if width == 0.0:
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.alignment = HORIZONTAL_ALIGNMENT_RIGHT if width > 0.0 else HORIZONTAL_ALIGNMENT_LEFT
	e.editable = not Protocol.LOCKED
	return e


func _line(v: VBoxContainer, key: String, caption: String, note: String, value, first: bool = false) -> void:
	var e := _edit(str(value), 90.0)
	_fields[key] = e
	_row(v, caption, note, e, first)


func _fixed(v: VBoxContainer, caption: String, note: String, value: String) -> void:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(90.0, 36.0)
	box.add_theme_stylebox_override("panel", UI._box(Color("F3F1EC"), UI.INPUT_LINE, 10, 1, 12.0, 6.0))
	var l := UI.label(value, 14, UI.MUTED, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(l)
	_row(v, caption, note + (" · fixed" if note != "" else "Fixed"), box)


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
		_visit.text = "≈ %d min" % roundi(s / 60.0)
	else:
		_visit.text = "—"


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
	var c := UI.card(_page, 20.0, 10)
	c.add_child(UI.label("Where it is saved", 14, UI.INK, true))
	var h := UI.row(c, 11)
	var path := PanelContainer.new()
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path.add_theme_stylebox_override("panel", UI._box(UI.SOFT, Color("ECE8DF"), 10, 1, 13.0, 9.0))
	path.add_child(UI.label(dir + "/<participant ID>/<visit start>/", 13, UI.INK, false, true))
	h.add_child(path)
	h.add_child(UI.button("Change…", _change_dir))
	h.add_child(UI.button("Open", func(): OS.shell_open(dir)))
	if Protocol.pending_data_dir() != "":
		c.add_child(UI.label("From the next start: " + Protocol.pending_data_dir()
			+ ". Files already saved stay where they are.", 12, UI.WARN, true, true))
	c.add_child(UI.label("Every row is written to disk as it happens, so a power cut loses nothing. Files use "
		+ "the participant ID only, never the name.", 12, UI.MUTED, false, true))

	var f := UI.card(_page, 20.0, 0)
	f.add_child(UI.label("Files per visit", 14, UI.INK, true))
	var files: Array = [
		["targets.csv", "One row per target: phase, round, pair, where, when, lifetime, outcome, movement time, points."],
		["hand.csv", "Every tracker sample at 100 Hz: hand position in table mm, capture time."],
		["reach.csv", "The reach scan: how far the hand got in each of the 8 directions."],
		["calibration.csv", "Per pair: calibration result and the lifetime used for play."],
	]
	for row in files:
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_top", 9)
		m.add_theme_constant_override("margin_bottom", 9)
		UI.line(f)
		f.add_child(m)
		var r := UI.row(m, 16)
		var name_label := UI.label(row[0], 13, UI.INK, true)
		name_label.custom_minimum_size = Vector2(150.0, 0.0)
		r.add_child(name_label)
		r.add_child(UI.label(row[1], 12, UI.INK2, false, true))

	var e := UI.card(_page, 20.0, 10)
	var eh := UI.row(e, 16)
	var et := VBoxContainer.new()
	et.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	et.add_child(UI.label("Export", 14, UI.INK, true))
	et.add_child(UI.label("Copies to a USB drive. Nothing on the device is removed.", 12, UI.MUTED, false, true))
	eh.add_child(et)
	_export_pick = OptionButton.new()
	_export_pick.custom_minimum_size = Vector2(150.0, 40.0)
	for id in db.ids():
		_export_pick.add_item(id)
	eh.add_child(_export_pick)
	var one := func():
		if _export_pick.item_count > 0:
			_export(_export_pick.get_item_text(_export_pick.selected))
	eh.add_child(UI.button("Export one", one))
	eh.add_child(UI.button("Export all", func(): _export(""), "primary"))
	_export_msg = UI.label("", 12, UI.INK2, true, true)
	e.add_child(_export_msg)


func _change_dir() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.title = "Folder for the clinic data"
	fd.current_dir = Protocol.data_dir()
	var chosen := func(d: String):
		Protocol.set_data_dir(d)
		_open.call_deferred(3)
	fd.dir_selected.connect(chosen)
	add_child(fd)
	fd.popup_centered(Vector2i(820, 520))


# Copy one participant's folder (or everything) to the first USB drive found.
func _export(id: String) -> void:
	var usb := _usb_drive()
	if usb == "":
		_export_msg.text = "No USB drive found — plug one in and try again."
		return
	var src := Protocol.data_dir() + ("/" + id if id != "" else "")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var dst := "%s/NOARK-clinic-%s%s" % [usb, stamp, "-" + id if id != "" else ""]
	var n := _copy_dir(src, dst)
	_export_msg.text = "Copied %d files to %s" % [n, dst] if n >= 0 else "Copy failed — is the drive full or read-only?"


func _usb_drive() -> String:
	var user := OS.get_environment("USER")
	for base in ["/media/" + user, "/run/media/" + user]:
		var d := DirAccess.open(base)
		if d == null:
			continue
		for drive in d.get_directories():
			return base + "/" + drive
	return ""


# Returns the number of files copied, or -1 on an error.
func _copy_dir(src: String, dst: String) -> int:
	var d := DirAccess.open(src)
	if d == null or DirAccess.make_dir_recursive_absolute(dst) != OK:
		return -1
	var n := 0
	for f in d.get_files():
		if DirAccess.copy_absolute(src + "/" + f, dst + "/" + f) != OK:
			return -1
		n += 1
	for sub in d.get_directories():
		var k := _copy_dir(src + "/" + sub, dst + "/" + sub)
		if k < 0:
			return -1
		n += k
	return n
