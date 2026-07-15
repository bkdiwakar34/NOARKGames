extends Control
# Installer / researcher mode (docs/v1_plan.md §4). Reached with F10 from the
# game-select screen — requires a keyboard, which patients don't have.
# Plain functional UI on purpose; the design system arrives in later packages.

const SETTINGS_PATH := "res://settings.json"
const UITheme := preload("res://app/ui/ui_theme.gd")

var _pages: Dictionary = {}          # name -> VBoxContainer
var _check_rows: Dictionary = {}     # check name -> {"sb": StyleBoxFlat, "label": Label}
var _origin_status: Label
var _edit_btn: Button
var _test_info: Label
var _relock_waiting: bool = false
var _refresh_timer: Timer
var _player_pos: Vector2 = Vector2.ZERO
var _test_targets: Array = []        # [{pos, hit}]

const CHECKS: Array = [
	"Camera calibrated",
	"Board geometry",
	"Origin locked",
	"Workspace calibrated",
	"Patient registered",
	"Upload configured",
]


func _input(event: InputEvent) -> void:
	# F10 toggles installer mode: it got you in, it gets you out.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F10:
		get_tree().change_scene_to_file("res://app/ui/chooser.tscn")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	GlobalSignals.return_to_installer = false
	GlobalSignals.edit_patient_id = ""  # clear a stale edit flag from an abandoned edit
	_build_checklist_page()
	_build_origin_page()
	_build_test_page()
	_show_page("checklist")

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 1.0
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_refresh_status)
	add_child(_refresh_timer)
	_refresh_status()


# ── Page framework ────────────────────────────────────────────────────────────

func _new_page(page_name: String, title: String) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_top", "margin_left", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 60)
	add_child(margin)
	# Scroll wrapper so pages can never push their bottom buttons off-screen
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", UITheme.INK)
	UITheme.make_bold(lbl)
	box.add_child(lbl)
	box.add_child(HSeparator.new())
	_pages[page_name] = margin
	return box


func _show_page(page_name: String) -> void:
	for k in _pages:
		_pages[k].visible = (k == page_name)
	queue_redraw()


func _add_button(parent: Node, text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 48)
	btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.INK))
	btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.INK.lightened(0.18)))
	btn.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.INK.darkened(0.25)))
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.pressed.connect(cb)
	parent.add_child(btn)
	return btn


# ── Checklist (landing page) ──────────────────────────────────────────────────

func _build_checklist_page() -> void:
	var box := _new_page("checklist", "Installer — Install Checklist")
	for check in CHECKS:
		var pc := PanelContainer.new()
		var row_sb := StyleBoxFlat.new()
		row_sb.bg_color = UITheme.CARD
		row_sb.set_corner_radius_all(10)
		row_sb.content_margin_left = 16.0
		row_sb.content_margin_right = 12.0
		row_sb.content_margin_top = 10.0
		row_sb.content_margin_bottom = 10.0
		pc.add_theme_stylebox_override("panel", row_sb)
		var h := HBoxContainer.new()
		var nm := Label.new()
		nm.text = check
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.add_theme_font_size_override("font_size", 20)
		nm.add_theme_color_override("font_color", UITheme.INK)
		h.add_child(nm)
		var pill := PanelContainer.new()
		var pill_sb := StyleBoxFlat.new()
		pill_sb.set_corner_radius_all(99)
		pill_sb.content_margin_left = 14.0
		pill_sb.content_margin_right = 14.0
		pill_sb.content_margin_top = 3.0
		pill_sb.content_margin_bottom = 3.0
		pill.add_theme_stylebox_override("panel", pill_sb)
		var pl := Label.new()
		pl.add_theme_font_size_override("font_size", 15)
		pl.add_theme_color_override("font_color", Color.WHITE)
		pill.add_child(pl)
		h.add_child(pill)
		pc.add_child(h)
		box.add_child(pc)
		_check_rows[check] = {"sb": pill_sb, "label": pl}
	box.add_child(HSeparator.new())

	# Researcher switches: overlay visibility + calibration policy
	var dbg := CheckButton.new()
	dbg.text = "Show researcher overlays in game"
	dbg.add_theme_color_override("font_color", UITheme.INK)
	dbg.add_theme_color_override("font_pressed_color", UITheme.INK)
	dbg.add_theme_color_override("font_hover_color", UITheme.INK)
	dbg.button_pressed = GlobalSignals.show_debug_overlays
	dbg.toggled.connect(func(on: bool): GlobalSignals.show_debug_overlays = on)
	box.add_child(dbg)

	var calib_row := HBoxContainer.new()
	calib_row.add_theme_constant_override("separation", 12)
	var calib_lbl := Label.new()
	calib_lbl.text = "Calibration at game start:"
	calib_lbl.add_theme_color_override("font_color", UITheme.INK)
	calib_row.add_child(calib_lbl)
	var calib_opt := OptionButton.new()
	calib_opt.add_item("Auto (weekly)")     # calib_mode "auto"
	calib_opt.add_item("Always calibrate")  # "always" — testing
	calib_opt.add_item("Skip (use saved)")  # "never" — demos
	calib_opt.select(["auto", "always", "never"].find(GlobalSignals.calib_mode))
	calib_opt.item_selected.connect(func(i: int):
		GlobalSignals.calib_mode = ["auto", "always", "never"][i])
	calib_row.add_child(calib_opt)
	box.add_child(calib_row)

	box.add_child(HSeparator.new())

	# Tool buttons in rows, like the approved mockup — not a scrolling stack
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 10)
	box.add_child(tools)
	_add_button(tools, "Register new patient", _on_register_patient)
	_edit_btn = _add_button(tools, "Edit current patient", _on_edit_patient)
	_add_button(tools, "Origin ritual", func(): _show_page("origin"))
	_add_button(tools, "Workspace calibration", _on_workspace_cal)
	_add_button(tools, "Test drive", _on_test_drive)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 10)
	box.add_child(row2)
	_add_button(row2, "Session settings", func():
		get_tree().change_scene_to_file("res://app/ui/game_select.tscn"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(spacer)
	_add_button(row2, "Exit installer ▸", func():
		get_tree().change_scene_to_file("res://app/ui/chooser.tscn"))


func _refresh_status() -> void:
	var origin_ok := FileAccess.file_exists(_pyscripts_path("", "origin_lock.json"))
	var patient: Dictionary = PatientDB.get_patient(PatientDB.current_patient_id)
	var patient_ok: bool = not patient.is_empty()
	var sched_ok: bool = patient_ok and not patient.get("rate_schedule", []).is_empty()

	_set_check("Camera calibrated",
		FileAccess.file_exists(_pyscripts_path("calibration_file", "camera_calib.toml")))
	_set_check("Board geometry",
		FileAccess.file_exists(_pyscripts_path("board_geometry_file", "board_geometry.json")))
	_set_check("Origin locked", origin_ok)
	_set_check("Workspace calibrated", WorkspaceConfig.is_calibrated)
	if patient_ok and not sched_ok:
		_set_pill("Patient registered", "! no schedule", Color("C99A2E"))
	else:
		_set_check("Patient registered", sched_ok)
	_set_pill("Upload configured", "v1: later", Color(0.55, 0.52, 0.48))

	_edit_btn.visible = patient_ok
	if patient_ok:
		_edit_btn.text = "Edit patient %s" % PatientDB.current_patient_id

	if _pages["origin"].visible:
		_refresh_origin_page(origin_ok)


func _set_check(check: String, ok: bool) -> void:
	if ok:
		_set_pill(check, "✓ done", UITheme.LEAF)
	else:
		_set_pill(check, "✗ missing", Color("C4483B"))


func _set_pill(check: String, text: String, color: Color) -> void:
	var row: Dictionary = _check_rows[check]
	row["sb"].bg_color = color
	row["label"].text = text


# settings.json can rename calibration files (e.g. per-machine camera calib);
# resolve through it so the checklist verifies the file actually in use.
func _pyscripts_path(settings_key: String, default_name: String) -> String:
	var fname := default_name
	if settings_key != "":
		var settings = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
		if settings is Dictionary and settings.has(settings_key):
			fname = str(settings[settings_key])
	return ProjectSettings.globalize_path("res://pyscripts/" + fname)


func _on_register_patient() -> void:
	GlobalSignals.return_to_installer = true
	get_tree().change_scene_to_file("res://app/ui/registration.tscn")


func _on_edit_patient() -> void:
	GlobalSignals.return_to_installer = true
	GlobalSignals.edit_patient_id = PatientDB.current_patient_id
	get_tree().change_scene_to_file("res://app/ui/registration.tscn")


func _on_workspace_cal() -> void:
	var cal: Control = load("res://app/installer/workspace_calibration_overlay.gd").new()
	cal.calibration_done.connect(func(): _refresh_status())
	add_child(cal)


# ── Origin ritual page ────────────────────────────────────────────────────────

func _build_origin_page() -> void:
	var box := _new_page("origin", "Origin Ritual")
	var instr := Label.new()
	instr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instr.add_theme_color_override("font_color", UITheme.INK)
	instr.text = ("Only needed after a camera move or a fresh install.\n" +
		"1. Place the device at the marked parking pose on the table.\n" +
		"2. Press Re-lock and keep the device still.\n" +
		"3. Wait for the ✓ — then never touch origin_lock.json again.")
	box.add_child(instr)
	_origin_status = Label.new()
	_origin_status.add_theme_font_size_override("font_size", 22)
	_origin_status.add_theme_color_override("font_color", UITheme.INK)
	box.add_child(_origin_status)
	_add_button(box, "Re-lock origin now", _on_relock)
	_add_button(box, "Back", func(): _show_page("checklist"))


func _on_relock() -> void:
	if not UDPReceiver.connected:
		_origin_status.text = "Tracker not connected — cannot re-lock."
		return
	UDPReceiver.request_origin_relock()
	_relock_waiting = true
	_origin_status.text = "Waiting for re-lock — keep the device parked and still…"


func _refresh_origin_page(origin_ok: bool) -> void:
	var conn := "tracker connected, %d packets/s" % UDPReceiver.packets_per_sec \
		if UDPReceiver.connected else "tracker NOT connected"
	if _relock_waiting:
		if origin_ok:
			_relock_waiting = false
			_origin_status.text = "Re-locked ✓  (%s)" % conn
		# else keep the waiting text
	else:
		_origin_status.text = ("Origin locked ✓" if origin_ok else "No origin lock ✗") \
			+ "  (%s)" % conn


# ── Test drive page ───────────────────────────────────────────────────────────

func _on_test_drive() -> void:
	var vp := get_viewport_rect().size
	_test_targets = []
	for i in 3:
		_test_targets.append({
			"pos": Vector2(vp.x * (0.3 + 0.2 * i), vp.y * 0.55),
			"hit": false
		})
	_show_page("test")


func _build_test_page() -> void:
	var box := _new_page("test", "Test Drive")
	var instr := Label.new()
	instr.text = "Move the device — the cursor should follow. Touch all three circles."
	instr.add_theme_color_override("font_color", UITheme.INK)
	box.add_child(instr)
	_test_info = Label.new()
	_test_info.add_theme_color_override("font_color", UITheme.INK)
	box.add_child(_test_info)
	_add_button(box, "Back", func(): _show_page("checklist"))


func _process(_delta: float) -> void:
	if not _pages.has("test") or not _pages["test"].visible:
		return
	_player_pos = UDPReceiver.screen_pos if UDPReceiver.connected \
		else get_global_mouse_position()
	for t in _test_targets:
		if _player_pos.distance_to(t["pos"]) < 55.0:
			t["hit"] = true
	_test_info.text = "tracker: %s   %d packets/s   pos: (%.0f, %.0f)" % [
		"connected" if UDPReceiver.connected else "NOT connected (mouse shown)",
		UDPReceiver.packets_per_sec, _player_pos.x, _player_pos.y]
	queue_redraw()


func _draw() -> void:
	# Flat warm paper — the workbench, deliberately not the patient's orchard
	draw_rect(Rect2(Vector2.ZERO, get_rect().size), UITheme.PAPER)
	if not _pages.has("test") or not _pages["test"].visible:
		return
	for t in _test_targets:
		var col := Color(UITheme.LEAF, 0.9) if t["hit"] else Color(0.5, 0.5, 0.55, 0.9)
		draw_arc(t["pos"], 55.0, 0.0, TAU, 48, col, 4.0)
		if t["hit"]:
			draw_circle(t["pos"], 12.0, col)
	var cursor := Color(UITheme.INK, 0.9)
	draw_arc(_player_pos, 13.0, 0.0, TAU, 48, cursor, 2.0)
	draw_circle(_player_pos, 2.5, cursor)
