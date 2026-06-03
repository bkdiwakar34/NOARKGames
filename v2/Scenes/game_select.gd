extends Control

var _override_rate: float = 0.8
var _rate_buttons: Array = []
var _settings_overlay: Control

var _kp_edit:        LineEdit
var _ki_edit:        LineEdit
var _kd_edit:        LineEdit
var _width_edit:     LineEdit
var _hold_edit:      LineEdit
var _sc_coarse_edit: LineEdit
var _sc_fine_edit:   LineEdit
var _sc_rev_edit:    LineEdit

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
		"Apple Catch",
		"res://v2/Games/random_reach/random_reach.tscn"
	)
	_add_rate_selector(vp)
	_add_settings_button(vp)
	_build_settings_overlay(vp)

# ── Game card ────────────────────────────────────────────────────────────────

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

# ── Settings overlay (popup card) ─────────────────────────────────────────────

func _build_settings_overlay(vp: Vector2) -> void:
	_settings_overlay = Control.new()
	_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.visible = false
	add_child(_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.add_child(dim)

	var cw: float = 860.0
	var ch: float = 300.0
	var cx: float = (vp.x - cw) * 0.5
	var cy: float = (vp.y - ch) * 0.5

	var card_panel := Panel.new()
	card_panel.size = Vector2(cw, ch)
	card_panel.position = Vector2(cx, cy)
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.07, 0.14, 0.30)
	card_style.corner_radius_top_left = 16; card_style.corner_radius_top_right = 16
	card_style.corner_radius_bottom_left = 16; card_style.corner_radius_bottom_right = 16
	card_style.border_width_left = 1; card_style.border_width_right = 1
	card_style.border_width_top = 1; card_style.border_width_bottom = 1
	card_style.border_color = Color(0.25, 0.45, 0.70, 0.50)
	card_panel.add_theme_stylebox_override("panel", card_style)
	_settings_overlay.add_child(card_panel)

	var card := Control.new()
	card.position = Vector2(cx, cy)
	card.custom_minimum_size = Vector2(cw, ch)
	_settings_overlay.add_child(card)

	# Title
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.75, 0.88, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(cw, 30.0)
	title.position = Vector2(0.0, 10.0)
	card.add_child(title)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(32.0, 28.0)
	close_btn.position = Vector2(cw - 42.0, 8.0)
	close_btn.add_theme_font_size_override("font_size", 14)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.30, 0.20, 0.20, 0.70)
	csb.corner_radius_top_left = 6; csb.corner_radius_top_right = 6
	csb.corner_radius_bottom_left = 6; csb.corner_radius_bottom_right = 6
	close_btn.add_theme_stylebox_override("normal", csb)
	var csb_h := csb.duplicate(); csb_h.bg_color = Color(0.60, 0.20, 0.20, 0.90)
	close_btn.add_theme_stylebox_override("hover", csb_h)
	close_btn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.75))
	close_btn.pressed.connect(func(): _settings_overlay.visible = false)
	card.add_child(close_btn)

	_add_separator(card, cw, 44.0)
	_add_mode_section(card, cw, 52.0)
	_add_separator(card, cw, 122.0)
	_add_pid_section(card, cw, 132.0)
	_add_separator(card, cw, 200.0)
	_add_testing_section(card, cw, 210.0)

func _add_separator(parent: Control, w: float, y: float) -> void:
	var sep := ColorRect.new()
	sep.color = Color(0.25, 0.45, 0.70, 0.30)
	sep.size = Vector2(w - 40.0, 1.0)
	sep.position = Vector2(20.0, y)
	parent.add_child(sep)

# ── Settings sections (positions relative to card) ───────────────────────────

func _add_mode_section(card: Control, cw: float, y: float) -> void:
	var lbl := Label.new()
	lbl.text = "Difficulty mode:"
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.72, 0.90, 0.85))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(cw, 22.0)
	lbl.position = Vector2(0.0, y)
	card.add_child(lbl)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200.0, 36.0)
	btn.position = Vector2(cw * 0.5 - 100.0, y + 26.0)
	btn.add_theme_font_size_override("font_size", 16)
	_update_mode_btn(btn)
	btn.pressed.connect(func():
		if AdaptiveManager.difficulty_mode == AdaptiveManager.DifficultyMode.LIFETIME:
			AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.WORKSPACE
		else:
			AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.LIFETIME
		_update_mode_btn(btn)
	)
	card.add_child(btn)

func _update_mode_btn(btn: Button) -> void:
	if AdaptiveManager.difficulty_mode == AdaptiveManager.DifficultyMode.LIFETIME:
		btn.text = "Lifetime"
	else:
		btn.text = "Workspace"

func _add_pid_section(card: Control, cw: float, y: float) -> void:
	var header := Label.new()
	header.text = "PID gains:"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(0.55, 0.72, 0.90, 0.85))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.custom_minimum_size = Vector2(cw, 22.0)
	header.position = Vector2(0.0, y)
	card.add_child(header)

	var row_h: float = 30.0
	var lbl_w: float = 30.0
	var edit_w: float = 70.0
	var group_w: float = lbl_w + 6.0 + edit_w
	var gap: float = 40.0
	var total_w: float = 3.0 * group_w + 2.0 * gap
	var start_x: float = cw * 0.5 - total_w * 0.5
	var row_y: float = y + 26.0

	var gains := [
		{"label": "Kp:", "val": AdaptiveManager.gain_p},
		{"label": "Ki:", "val": AdaptiveManager.gain_i},
		{"label": "Kd:", "val": AdaptiveManager.gain_d},
	]
	for i in gains.size():
		var gx: float = start_x + i * (group_w + gap)
		var glbl := Label.new()
		glbl.text = gains[i]["label"]
		glbl.add_theme_font_size_override("font_size", 14)
		glbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
		glbl.custom_minimum_size = Vector2(lbl_w, row_h)
		glbl.position = Vector2(gx, row_y)
		glbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card.add_child(glbl)
		var edit := _make_line_edit(gains[i]["val"], 2, edit_w, row_h)
		edit.position = Vector2(gx + lbl_w + 6.0, row_y)
		card.add_child(edit)
		if i == 0: _kp_edit = edit
		elif i == 1: _ki_edit = edit
		else: _kd_edit = edit

func _add_testing_section(card: Control, cw: float, y: float) -> void:
	var header := Label.new()
	header.text = "Testing:"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(0.55, 0.72, 0.90, 0.85))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.custom_minimum_size = Vector2(cw, 22.0)
	header.position = Vector2(0.0, y)
	card.add_child(header)

	var btn_h: float = 28.0
	var lbl_w: float = 46.0
	var edit_w: float = 60.0

	# Row 1: Trial duration | Width | Hold
	var row1_y: float = y + 26.0
	var durations: Array = [10.0, 20.0, 30.0, 60.0]
	var dur_buttons: Array = []
	var dur_btn_w: float = 46.0
	var dur_gap: float = 5.0
	var dur_section_w: float = lbl_w + durations.size() * dur_btn_w + (durations.size() - 1) * dur_gap
	var width_section_w: float = lbl_w + edit_w
	var hold_section_w: float = lbl_w + edit_w
	var section_gap: float = 20.0
	var row1_total: float = dur_section_w + section_gap + width_section_w + section_gap + hold_section_w
	var row1_x: float = cw * 0.5 - row1_total * 0.5

	# Trial label + buttons
	var dur_lbl := Label.new()
	dur_lbl.text = "Trial:"
	dur_lbl.add_theme_font_size_override("font_size", 13)
	dur_lbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
	dur_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	dur_lbl.position = Vector2(row1_x, row1_y)
	dur_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.add_child(dur_lbl)

	var dur_x: float = row1_x + lbl_w
	for i in durations.size():
		var d: float = durations[i]
		var b := Button.new()
		b.text = "%ds" % int(d)
		b.custom_minimum_size = Vector2(dur_btn_w, btn_h)
		b.size = Vector2(dur_btn_w, btn_h)
		b.position = Vector2(dur_x + i * (dur_btn_w + dur_gap), row1_y)
		b.add_theme_font_size_override("font_size", 13)
		_style_rate_btn(b, d == AdaptiveManager.trial_duration)
		var cap_d: float = d
		var cap_b: Button = b
		b.pressed.connect(func():
			AdaptiveManager.trial_duration = cap_d
			for db in dur_buttons: _style_rate_btn(db, false)
			_style_rate_btn(cap_b, true)
		)
		dur_buttons.append(b)
		card.add_child(b)

	# Width
	var ww_x: float = row1_x + dur_section_w + section_gap
	var ww_lbl := Label.new()
	ww_lbl.text = "Width(s):"
	ww_lbl.add_theme_font_size_override("font_size", 13)
	ww_lbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
	ww_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	ww_lbl.position = Vector2(ww_x, row1_y)
	ww_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.add_child(ww_lbl)
	_width_edit = _make_line_edit(AdaptiveManager.window_width, 1, edit_w, btn_h)
	_width_edit.position = Vector2(ww_x + lbl_w, row1_y)
	card.add_child(_width_edit)

	# Hold
	var hold_x: float = ww_x + width_section_w + section_gap
	var hold_lbl := Label.new()
	hold_lbl.text = "Hold(s):"
	hold_lbl.add_theme_font_size_override("font_size", 13)
	hold_lbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
	hold_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	hold_lbl.position = Vector2(hold_x, row1_y)
	hold_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.add_child(hold_lbl)
	_hold_edit = _make_line_edit(AdaptiveManager.catch_hold_time, 1, edit_w, btn_h)
	_hold_edit.position = Vector2(hold_x + lbl_w, row1_y)
	card.add_child(_hold_edit)

	# Row 2: Staircase parameters
	var row2_y: float = row1_y + btn_h + 8.0
	var sc_lbl_w: float = 50.0
	var sc_edit_w: float = 48.0
	var sc_gap: float = 16.0
	var rev_lbl_w: float = 36.0
	var rev_edit_w: float = 40.0
	var row2_total: float = sc_lbl_w + sc_edit_w + sc_gap + sc_lbl_w + sc_edit_w + sc_gap + rev_lbl_w + rev_edit_w
	var row2_x: float = cw * 0.5 - row2_total * 0.5

	for item in [
		{"label": "Coarse:", "x": row2_x,                                        "val": AdaptiveManager.sc_step_coarse, "dec": 1, "w": sc_edit_w, "lw": sc_lbl_w},
		{"label": "Fine:",   "x": row2_x + sc_lbl_w + sc_edit_w + sc_gap,        "val": AdaptiveManager.sc_step_fine,   "dec": 1, "w": sc_edit_w, "lw": sc_lbl_w},
		{"label": "Rev#:",   "x": row2_x + 2.0*(sc_lbl_w + sc_edit_w + sc_gap),  "val": float(AdaptiveManager.sc_n_reversals), "dec": 0, "w": rev_edit_w, "lw": rev_lbl_w},
	]:
		var slbl := Label.new()
		slbl.text = item["label"]
		slbl.add_theme_font_size_override("font_size", 13)
		slbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
		slbl.custom_minimum_size = Vector2(item["lw"], btn_h)
		slbl.position = Vector2(item["x"], row2_y)
		slbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card.add_child(slbl)
		var sedit := _make_line_edit(item["val"], item["dec"], item["w"], btn_h)
		sedit.position = Vector2(item["x"] + float(item["lw"]), row2_y)
		card.add_child(sedit)
		if item["label"] == "Coarse:": _sc_coarse_edit = sedit
		elif item["label"] == "Fine:":  _sc_fine_edit = sedit
		else:                           _sc_rev_edit = sedit

# ── Shared helpers ────────────────────────────────────────────────────────────

func _make_line_edit(value: float, decimals: int, w: float, h: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = "%.*f" % [decimals, value]
	e.custom_minimum_size = Vector2(w, h)
	e.size = Vector2(w, h)
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.15, 0.28)
	sb.border_width_left = 1; sb.border_width_right = 1
	sb.border_width_top = 1; sb.border_width_bottom = 1
	sb.border_color = Color(0.25, 0.45, 0.70)
	sb.corner_radius_top_left = 4; sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4; sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 4.0; sb.content_margin_right = 4.0
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", sb)
	e.add_theme_color_override("font_color", Color(0.88, 0.92, 1.0))
	e.add_theme_font_size_override("font_size", 14)
	return e

func _safe_float(text: String, fallback: float) -> float:
	if text.is_valid_float():
		return text.to_float()
	return fallback

func _start_game(scene_path: String) -> void:
	AdaptiveManager.gain_p          = _safe_float(_kp_edit.text,        AdaptiveManager.gain_p)
	AdaptiveManager.gain_i          = _safe_float(_ki_edit.text,        AdaptiveManager.gain_i)
	AdaptiveManager.gain_d          = _safe_float(_kd_edit.text,        AdaptiveManager.gain_d)
	AdaptiveManager.window_width    = _safe_float(_width_edit.text,     AdaptiveManager.window_width)
	AdaptiveManager.catch_hold_time = _safe_float(_hold_edit.text,      AdaptiveManager.catch_hold_time)
	AdaptiveManager.sc_step_coarse  = _safe_float(_sc_coarse_edit.text, AdaptiveManager.sc_step_coarse)
	AdaptiveManager.sc_step_fine    = _safe_float(_sc_fine_edit.text,   AdaptiveManager.sc_step_fine)
	AdaptiveManager.sc_n_reversals  = int(_safe_float(_sc_rev_edit.text, float(AdaptiveManager.sc_n_reversals)))
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
