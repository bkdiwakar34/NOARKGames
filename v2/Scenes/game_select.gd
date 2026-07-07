extends Control

var _override_rate: float = 0.8
var _rate_buttons: Array = []
var _settings_overlay: Control
var _hold_edit: LineEdit
var _cal_status_lbl: Label = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var patient := PatientDB.get_patient(PatientDB.current_patient_id)
	_override_rate = patient.get("target_success_rate", 0.8)
	_build_ui(patient.get("name", "Patient"))

func _build_ui(patient_name: String) -> void:
	var vp := get_viewport_rect().size

	var greeting := Label.new()
	greeting.text = "Hello, " + patient_name + "!"
	greeting.add_theme_font_size_override("font_size", 52)
	greeting.add_theme_color_override("font_color", Color(0.12, 0.32, 0.60))
	greeting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	greeting.custom_minimum_size = Vector2(vp.x, 72.0)
	greeting.position = Vector2(0.0, vp.y * 0.22)
	add_child(greeting)

	var subtitle := Label.new()
	subtitle.text = "Choose your game"
	subtitle.add_theme_font_size_override("font_size", 22)
	subtitle.add_theme_color_override("font_color", Color(0.28, 0.42, 0.60, 0.72))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.custom_minimum_size = Vector2(vp.x, 36.0)
	subtitle.position = Vector2(0.0, vp.y * 0.22 + 76.0)
	add_child(subtitle)

	_add_game_card(
		vp * 0.5 - Vector2(180.0, 100.0),
		"Balloon Pop",
		"res://v2/Games/random_reach/random_reach.tscn"
	)
	_add_rate_selector(vp)
	_add_settings_button(vp)
	_build_settings_overlay(vp)

# ── Game card ─────────────────────────────────────────────────────────────────

func _add_game_card(pos: Vector2, display_name: String, scene_path: String) -> void:
	var normal_sb := StyleBoxFlat.new()
	normal_sb.bg_color = Color(1.0, 0.92, 0.68)
	normal_sb.corner_radius_top_left = 18
	normal_sb.corner_radius_top_right = 18
	normal_sb.corner_radius_bottom_left = 18
	normal_sb.corner_radius_bottom_right = 18
	normal_sb.shadow_color = Color(0, 0, 0, 0.18)
	normal_sb.shadow_size = 6
	normal_sb.shadow_offset = Vector2(0, 3)

	var hover_sb := StyleBoxFlat.new()
	hover_sb.bg_color = Color(1.0, 0.85, 0.48)
	hover_sb.corner_radius_top_left = 18
	hover_sb.corner_radius_top_right = 18
	hover_sb.corner_radius_bottom_left = 18
	hover_sb.corner_radius_bottom_right = 18
	hover_sb.shadow_color = Color(0, 0, 0, 0.22)
	hover_sb.shadow_size = 8
	hover_sb.shadow_offset = Vector2(0, 4)

	var pressed_sb := StyleBoxFlat.new()
	pressed_sb.bg_color = Color(0.95, 0.78, 0.40)
	pressed_sb.corner_radius_top_left = 18
	pressed_sb.corner_radius_top_right = 18
	pressed_sb.corner_radius_bottom_left = 18
	pressed_sb.corner_radius_bottom_right = 18

	var btn := Button.new()
	btn.text = display_name
	btn.custom_minimum_size = Vector2(360.0, 200.0)
	btn.size = Vector2(360.0, 200.0)
	btn.position = pos
	btn.add_theme_font_size_override("font_size", 38)
	btn.add_theme_color_override("font_color", Color(0.50, 0.24, 0.02))
	btn.add_theme_stylebox_override("normal", normal_sb)
	btn.add_theme_stylebox_override("hover", hover_sb)
	btn.add_theme_stylebox_override("pressed", pressed_sb)
	btn.add_theme_stylebox_override("focus", normal_sb)
	btn.pressed.connect(func(): _start_game(scene_path))
	add_child(btn)

# ── Target rate selector ──────────────────────────────────────────────────────

func _add_rate_selector(vp: Vector2) -> void:
	var rates: Array = [0.4, 0.5, 0.7, 0.8, 0.9, 1.0]
	var lbl := Label.new()
	lbl.text = "Target rate:"
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.28, 0.42, 0.60, 0.80))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(vp.x, 28.0)
	lbl.position = Vector2(0.0, vp.y * 0.55)
	add_child(lbl)

	var btn_w: float = 72.0
	var btn_h: float = 36.0
	var gap: float = 8.0
	var total_w: float = rates.size() * btn_w + (rates.size() - 1) * gap
	var start_x: float = vp.x * 0.5 - total_w * 0.5
	var row_y: float = vp.y * 0.55 + 32.0

	for i in rates.size():
		var r: float = rates[i]
		var btn := Button.new()
		btn.text = "%d%%" % int(r * 100)
		btn.custom_minimum_size = Vector2(btn_w, btn_h)
		btn.size = Vector2(btn_w, btn_h)
		btn.position = Vector2(start_x + i * (btn_w + gap), row_y)
		btn.add_theme_font_size_override("font_size", 16)
		_style_rate_btn(btn, r == _override_rate)
		var captured_r := r
		btn.pressed.connect(func():
			_override_rate = captured_r
			for b in _rate_buttons:
				_style_rate_btn(b, false)
			_style_rate_btn(btn, true)
		)
		_rate_buttons.append(btn)
		add_child(btn)

func _style_rate_btn(btn: Button, selected: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	if selected:
		sb.bg_color = Color(0.15, 0.50, 0.90)
		btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	else:
		sb.bg_color = Color(0.72, 0.82, 0.92, 0.70)
		btn.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("focus", sb)
	var sb_pressed := StyleBoxFlat.new()
	sb_pressed.corner_radius_top_left = 8
	sb_pressed.corner_radius_top_right = 8
	sb_pressed.corner_radius_bottom_left = 8
	sb_pressed.corner_radius_bottom_right = 8
	sb_pressed.bg_color = sb.bg_color.darkened(0.15)
	btn.add_theme_stylebox_override("pressed", sb_pressed)

# ── Settings button ───────────────────────────────────────────────────────────

func _add_settings_button(vp: Vector2) -> void:
	var btn := Button.new()
	btn.text = "⚙  Settings"
	btn.custom_minimum_size = Vector2(150.0, 32.0)
	btn.position = Vector2(vp.x * 0.5 - 75.0, vp.y * 0.69)
	btn.add_theme_font_size_override("font_size", 14)
	var sn := StyleBoxFlat.new()
	sn.bg_color = Color(0.12, 0.26, 0.50, 0.75)
	sn.corner_radius_top_left = 8; sn.corner_radius_top_right = 8
	sn.corner_radius_bottom_left = 8; sn.corner_radius_bottom_right = 8
	var sh := sn.duplicate()
	sh.bg_color = Color(0.18, 0.36, 0.65, 0.90)
	btn.add_theme_stylebox_override("normal", sn)
	btn.add_theme_stylebox_override("hover", sh)
	btn.add_theme_stylebox_override("focus", sn)
	btn.add_theme_color_override("font_color", Color(0.82, 0.90, 1.0))
	btn.pressed.connect(func(): _settings_overlay.visible = not _settings_overlay.visible)
	add_child(btn)

# ── Settings overlay ──────────────────────────────────────────────────────────

func _build_settings_overlay(vp: Vector2) -> void:
	_settings_overlay = Control.new()
	_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.visible = false
	add_child(_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.06, 0.14, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.add_child(dim)

	var cw: float = 800.0
	var ch: float = 360.0
	var cx: float = (vp.x - cw) * 0.5
	var cy: float = (vp.y - ch) * 0.5

	# White card with subtle border + shadow
	var card_panel := Panel.new()
	card_panel.size = Vector2(cw, ch)
	card_panel.position = Vector2(cx, cy)
	var card_style := StyleBoxFlat.new()
	card_style.bg_color                   = Color(0.98, 0.98, 1.00)
	card_style.corner_radius_top_left     = 18
	card_style.corner_radius_top_right    = 18
	card_style.corner_radius_bottom_left  = 18
	card_style.corner_radius_bottom_right = 18
	card_style.border_width_left   = 1; card_style.border_width_right  = 1
	card_style.border_width_top    = 1; card_style.border_width_bottom = 1
	card_style.border_color        = Color(0.80, 0.82, 0.92)
	card_style.shadow_color        = Color(0.05, 0.05, 0.18, 0.30)
	card_style.shadow_size         = 16
	card_style.shadow_offset       = Vector2(0.0, 6.0)
	card_panel.add_theme_stylebox_override("panel", card_style)
	_settings_overlay.add_child(card_panel)

	# Content container — all children positioned relative to card top-left
	var card := Control.new()
	card.position         = Vector2(cx, cy)
	card.custom_minimum_size = Vector2(cw, ch)
	_settings_overlay.add_child(card)

	# Title
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.10, 0.13, 0.30))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	title.custom_minimum_size  = Vector2(cw, 50.0)
	title.position = Vector2(0.0, 0.0)
	card.add_child(title)

	# Close button — top-right
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(30.0, 30.0)
	close_btn.position            = Vector2(cw - 42.0, 10.0)
	close_btn.add_theme_font_size_override("font_size", 13)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.88, 0.88, 0.94)
	csb.corner_radius_top_left    = 8; csb.corner_radius_top_right    = 8
	csb.corner_radius_bottom_left = 8; csb.corner_radius_bottom_right = 8
	close_btn.add_theme_stylebox_override("normal", csb)
	var csb_h := csb.duplicate()
	csb_h.bg_color = Color(0.82, 0.20, 0.20)
	close_btn.add_theme_stylebox_override("hover", csb_h)
	close_btn.add_theme_color_override("font_color", Color(0.35, 0.38, 0.52))
	close_btn.pressed.connect(func(): _settings_overlay.visible = false)
	card.add_child(close_btn)

	_add_sep(card, cw, 50.0)

	var y: float = 62.0

	_add_section_label(card, "TESTING", cw, y);  y += 22.0
	_add_testing_section(card, cw, y)

	# Testing section ends at y ≈ 158; tracker demo toggles below
	_add_sep(card, cw, 166.0)
	_add_section_label(card, "TRACKER", cw, 172.0)
	_add_tracker_section(card, cw, 196.0)

	_add_sep(card, cw, 280.0)
	_add_section_label(card, "HARDWARE", cw, 286.0)
	_add_hardware_section(card, cw, 310.0)

# ── Separator + section label ─────────────────────────────────────────────────

func _add_sep(parent: Control, w: float, y: float) -> void:
	var sep := ColorRect.new()
	sep.color    = Color(0.80, 0.82, 0.93, 0.90)
	sep.size     = Vector2(w, 1.0)
	sep.position = Vector2(0.0, y)
	parent.add_child(sep)

func _add_section_label(parent: Control, text: String, cw: float, y: float) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.40, 0.50, 0.74))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size  = Vector2(cw, 20.0)
	lbl.position             = Vector2(0.0, y)
	parent.add_child(lbl)

# ── Testing section ───────────────────────────────────────────────────────────

func _add_testing_section(card: Control, cw: float, y: float) -> void:
	var row_h:   float = 32.0
	var row_gap: float = 10.0

	# Row 1 — Trial duration buttons
	var dur_lbl_w: float = 44.0
	var dur_btn_w: float = 52.0
	var dur_gap:   float = 6.0
	var durations: Array = [10.0, 20.0, 30.0, 60.0]
	var row1_w: float = dur_lbl_w + 10.0 + durations.size() * dur_btn_w + (durations.size() - 1) * dur_gap
	var row1_x: float = cw * 0.5 - row1_w * 0.5

	var dur_lbl := Label.new()
	dur_lbl.text = "Trial"
	dur_lbl.add_theme_font_size_override("font_size", 14)
	dur_lbl.add_theme_color_override("font_color", Color(0.20, 0.26, 0.50))
	dur_lbl.custom_minimum_size = Vector2(dur_lbl_w, row_h)
	dur_lbl.position            = Vector2(row1_x, y)
	dur_lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	card.add_child(dur_lbl)

	var dur_buttons: Array = []
	for i in durations.size():
		var d: float  = durations[i]
		var b         := Button.new()
		b.text        = "%ds" % int(d)
		b.custom_minimum_size = Vector2(dur_btn_w, row_h)
		b.size        = Vector2(dur_btn_w, row_h)
		b.position    = Vector2(row1_x + dur_lbl_w + 10.0 + i * (dur_btn_w + dur_gap), y)
		b.add_theme_font_size_override("font_size", 13)
		_style_rate_btn(b, d == AdaptiveManager.trial_duration)
		var cap_d: float  = d
		var cap_b: Button = b
		b.pressed.connect(func():
			AdaptiveManager.trial_duration = cap_d
			for db in dur_buttons: _style_rate_btn(db, false)
			_style_rate_btn(cap_b, true)
		)
		dur_buttons.append(b)
		card.add_child(b)

	y += row_h + row_gap

	# Row 2 — Hold time
	var lbl_w2: float  = 84.0
	var edit_w2: float = 70.0
	var row2_x: float  = cw * 0.5 - (lbl_w2 + edit_w2) * 0.5

	_hold_edit = _labeled_edit(card, "Hold (s)", row2_x, y, lbl_w2, edit_w2, row_h, AdaptiveManager.catch_hold_time, 1)

func _labeled_edit(parent: Control, lbl_text: String, x: float, y: float,
		lbl_w: float, edit_w: float, h: float, value: float, decimals: int) -> LineEdit:
	var lbl := Label.new()
	lbl.text = lbl_text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.20, 0.26, 0.50))
	lbl.custom_minimum_size = Vector2(lbl_w, h)
	lbl.position            = Vector2(x, y)
	lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(lbl)

	var edit := _make_line_edit(value, decimals, edit_w, h)
	edit.position = Vector2(x + lbl_w, y)
	parent.add_child(edit)
	return edit

# ── Tracker section (demo comparison toggles) ────────────────────────────────

func _add_tracker_section(card: Control, cw: float, y: float) -> void:
	var row_h: float = 32.0
	var lbl_w: float = 84.0
	var btn_w: float = 130.0
	var gap:   float = 6.0
	var row_x: float = cw * 0.5 - (lbl_w + 10.0 + btn_w * 2.0 + gap) * 0.5

	_tracker_toggle_row(card, row_x, y, lbl_w, btn_w, row_h, gap,
		"Markers", "Old (12+20)", "All",
		UDPReceiver.setup_subset,
		func(first: bool): UDPReceiver.send_tracker_setup(first, UDPReceiver.setup_rigid))

	_tracker_toggle_row(card, row_x, y + row_h + 10.0, lbl_w, btn_w, row_h, gap,
		"Solver", "Per-marker", "Rigid body",
		not UDPReceiver.setup_rigid,
		func(first: bool): UDPReceiver.send_tracker_setup(UDPReceiver.setup_subset, not first))


# Generic two-option toggle row. `a_selected` = whether the FIRST option is
# active; the callback receives true when the first option is chosen.
func _tracker_toggle_row(parent: Control, x: float, y: float, lbl_w: float, btn_w: float,
		h: float, gap: float, lbl_text: String, text_a: String, text_b: String,
		a_selected: bool, on_select: Callable) -> void:
	var lbl := Label.new()
	lbl.text = lbl_text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.20, 0.26, 0.50))
	lbl.custom_minimum_size = Vector2(lbl_w, h)
	lbl.position            = Vector2(x, y)
	lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(lbl)

	var btn_a := Button.new()
	var btn_b := Button.new()
	var texts: Array = [text_a, text_b]
	var btns:  Array = [btn_a, btn_b]
	for i in 2:
		var b: Button = btns[i]
		b.text = texts[i]
		b.custom_minimum_size = Vector2(btn_w, h)
		b.size     = Vector2(btn_w, h)
		b.position = Vector2(x + lbl_w + 10.0 + i * (btn_w + gap), y)
		b.add_theme_font_size_override("font_size", 13)
		parent.add_child(b)
	_style_rate_btn(btn_a, a_selected)
	_style_rate_btn(btn_b, not a_selected)
	btn_a.pressed.connect(func():
		_style_rate_btn(btn_a, true)
		_style_rate_btn(btn_b, false)
		on_select.call(true)
	)
	btn_b.pressed.connect(func():
		_style_rate_btn(btn_a, false)
		_style_rate_btn(btn_b, true)
		on_select.call(false)
	)

# ── Hardware section ─────────────────────────────────────────────────────────

func _add_hardware_section(card: Control, cw: float, y: float) -> void:
	var row_h: float = 32.0
	var btn_w: float = 180.0
	var lbl_w: float = cw - btn_w - 40.0
	var row_x: float = cw * 0.5 - (btn_w + lbl_w + 8.0) * 0.5

	_cal_status_lbl = Label.new()
	_cal_status_lbl.add_theme_font_size_override("font_size", 13)
	_cal_status_lbl.custom_minimum_size = Vector2(lbl_w, row_h)
	_cal_status_lbl.position            = Vector2(row_x, y)
	_cal_status_lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	_update_cal_status()
	card.add_child(_cal_status_lbl)

	var cal_btn := Button.new()
	cal_btn.text = "Calibrate workspace"
	cal_btn.custom_minimum_size = Vector2(btn_w, row_h)
	cal_btn.size                = Vector2(btn_w, row_h)
	cal_btn.position            = Vector2(row_x + lbl_w + 8.0, y)
	cal_btn.add_theme_font_size_override("font_size", 13)
	cal_btn.pressed.connect(_on_calibrate_pressed)
	card.add_child(cal_btn)


func _update_cal_status() -> void:
	if _cal_status_lbl == null:
		return
	if WorkspaceConfig.is_calibrated:
		var mn := WorkspaceConfig.workspace_min
		var mx := WorkspaceConfig.workspace_max
		_cal_status_lbl.add_theme_color_override("font_color", Color(0.15, 0.55, 0.20))
		_cal_status_lbl.text = "Calibrated  (%d×%d px)" % [int(mx.x - mn.x), int(mx.y - mn.y)]
	else:
		_cal_status_lbl.add_theme_color_override("font_color", Color(0.65, 0.30, 0.20))
		_cal_status_lbl.text = "Not calibrated"


func _on_calibrate_pressed() -> void:
	_settings_overlay.visible = false
	var CAL_SCENE := load("res://v2/Scenes/workspace_calibration_overlay.gd")
	var cal: Control = CAL_SCENE.new()
	cal.calibration_done.connect(_update_cal_status)
	add_child(cal)


# ── Shared helpers ────────────────────────────────────────────────────────────

func _make_line_edit(value: float, decimals: int, w: float, h: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = "%.*f" % [decimals, value]
	e.custom_minimum_size = Vector2(w, h)
	e.size = Vector2(w, h)
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.00, 1.00, 1.00)
	sb.border_width_left = 1; sb.border_width_right  = 1
	sb.border_width_top  = 1; sb.border_width_bottom = 1
	sb.border_color = Color(0.70, 0.74, 0.88)
	sb.corner_radius_top_left    = 6; sb.corner_radius_top_right    = 6
	sb.corner_radius_bottom_left = 6; sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 4.0; sb.content_margin_right = 4.0

	var sb_focus := sb.duplicate()
	sb_focus.border_color = Color(0.20, 0.48, 0.88)
	sb_focus.border_width_left = 2; sb_focus.border_width_right  = 2
	sb_focus.border_width_top  = 2; sb_focus.border_width_bottom = 2

	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus",  sb_focus)
	e.add_theme_color_override("font_color",            Color(0.10, 0.14, 0.30))
	e.add_theme_color_override("font_selected_color",   Color(1.00, 1.00, 1.00))
	e.add_theme_color_override("selection_color",       Color(0.20, 0.48, 0.88, 0.50))
	e.add_theme_font_size_override("font_size", 15)
	return e

func _safe_float(text: String, fallback: float) -> float:
	if text.is_valid_float():
		return text.to_float()
	return fallback

func _start_game(scene_path: String) -> void:
	AdaptiveManager.catch_hold_time = _safe_float(_hold_edit.text, AdaptiveManager.catch_hold_time)
	if not AdaptiveManager.is_running:
		AdaptiveManager.start_session(_override_rate)
	get_tree().change_scene_to_file(scene_path)

func _draw() -> void:
	var size := get_rect().size
	for i in 40:
		var t := float(i) / 40.0
		var col: Color = Color(0.40, 0.75, 0.98).lerp(Color(0.78, 0.91, 1.0), t / 0.65) if t < 0.65 \
			else Color(0.78, 0.91, 1.0).lerp(Color(0.56, 0.82, 0.44), (t - 0.65) / 0.35)
		draw_rect(Rect2(0.0, t * size.y, size.x, size.y / 40.0 + 1.0), col)
