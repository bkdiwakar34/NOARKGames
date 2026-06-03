extends Control

var _override_rate: float = 0.8
var _rate_buttons: Array = []
var _settings_overlay: Control
var _mode_btns: Array = []

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
	var ch: float = 370.0
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

	_add_section_label(card, "DIFFICULTY MODE", cw, y);  y += 22.0
	_add_mode_section(card, cw, y);                       y += 48.0
	_add_sep(card, cw, y);                                y += 14.0

	_add_section_label(card, "PID GAINS", cw, y);         y += 22.0
	_add_pid_section(card, cw, y);                        y += 46.0
	_add_sep(card, cw, y);                                y += 14.0

	_add_section_label(card, "TESTING", cw, y);           y += 22.0
	_add_testing_section(card, cw, y)

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

# ── Mode section — segmented control ─────────────────────────────────────────

func _add_mode_section(card: Control, cw: float, y: float) -> void:
	var btn_w: float = 170.0
	var btn_h: float = 38.0
	var sx: float    = cw * 0.5 - btn_w  # two buttons total = btn_w * 2, center them

	var lt_btn := Button.new()
	lt_btn.text = "Lifetime"
	lt_btn.custom_minimum_size = Vector2(btn_w, btn_h)
	lt_btn.size = Vector2(btn_w, btn_h)
	lt_btn.position = Vector2(sx, y)
	lt_btn.add_theme_font_size_override("font_size", 15)
	card.add_child(lt_btn)

	var ws_btn := Button.new()
	ws_btn.text = "Workspace"
	ws_btn.custom_minimum_size = Vector2(btn_w, btn_h)
	ws_btn.size = Vector2(btn_w, btn_h)
	ws_btn.position = Vector2(sx + btn_w, y)
	ws_btn.add_theme_font_size_override("font_size", 15)
	card.add_child(ws_btn)

	_mode_btns = [lt_btn, ws_btn]
	_refresh_mode_btns(AdaptiveManager.difficulty_mode == AdaptiveManager.DifficultyMode.LIFETIME)

	lt_btn.pressed.connect(func():
		AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.LIFETIME
		_refresh_mode_btns(true)
	)
	ws_btn.pressed.connect(func():
		AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.WORKSPACE
		_refresh_mode_btns(false)
	)

func _refresh_mode_btns(lifetime_active: bool) -> void:
	if _mode_btns.size() < 2:
		return
	var states := [lifetime_active, not lifetime_active]
	for i in 2:
		var btn: Button  = _mode_btns[i]
		var active: bool = states[i]
		var sb := StyleBoxFlat.new()
		sb.bg_color     = Color(0.18, 0.46, 0.86) if active else Color(0.96, 0.96, 1.00)
		sb.border_color = Color(0.18, 0.46, 0.86) if active else Color(0.72, 0.76, 0.90)
		sb.border_width_left   = 1; sb.border_width_right  = 1
		sb.border_width_top    = 1; sb.border_width_bottom = 1
		if i == 0:
			sb.corner_radius_top_left    = 10; sb.corner_radius_bottom_left  = 10
		else:
			sb.corner_radius_top_right   = 10; sb.corner_radius_bottom_right = 10
		btn.add_theme_stylebox_override("normal",  sb)
		btn.add_theme_stylebox_override("hover",   sb)
		btn.add_theme_stylebox_override("pressed", sb)
		btn.add_theme_stylebox_override("focus",   sb)
		var tc := Color(1.0, 1.0, 1.0) if active else Color(0.28, 0.36, 0.58)
		btn.add_theme_color_override("font_color", tc)

# ── PID section ───────────────────────────────────────────────────────────────

func _add_pid_section(card: Control, cw: float, y: float) -> void:
	var lbl_w:   float = 36.0
	var edit_w:  float = 84.0
	var gap:     float = 8.0
	var col_gap: float = 60.0
	var group_w: float = lbl_w + gap + edit_w
	var total_w: float = 3.0 * group_w + 2.0 * col_gap
	var sx: float      = cw * 0.5 - total_w * 0.5
	var row_h: float   = 34.0

	var gains := [
		{"label": "Kp", "val": AdaptiveManager.gain_p},
		{"label": "Ki", "val": AdaptiveManager.gain_i},
		{"label": "Kd", "val": AdaptiveManager.gain_d},
	]
	for i in gains.size():
		var gx: float = sx + i * (group_w + col_gap)

		var glbl := Label.new()
		glbl.text = gains[i]["label"]
		glbl.add_theme_font_size_override("font_size", 15)
		glbl.add_theme_color_override("font_color", Color(0.20, 0.26, 0.50))
		glbl.custom_minimum_size = Vector2(lbl_w, row_h)
		glbl.position            = Vector2(gx, y)
		glbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
		card.add_child(glbl)

		var edit := _make_line_edit(gains[i]["val"], 2, edit_w, row_h)
		edit.position = Vector2(gx + lbl_w + gap, y)
		card.add_child(edit)

		if i == 0: _kp_edit = edit
		elif i == 1: _ki_edit = edit
		else: _kd_edit = edit

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

	# Row 2 — Window + Hold
	var lbl_w2: float  = 84.0
	var edit_w2: float = 70.0
	var r2_gap: float  = 52.0
	var row2_w: float  = lbl_w2 + edit_w2 + r2_gap + lbl_w2 + edit_w2
	var row2_x: float  = cw * 0.5 - row2_w * 0.5

	_width_edit = _labeled_edit(card, "Window (s)", row2_x,                          y, lbl_w2, edit_w2, row_h, AdaptiveManager.window_width,    1)
	_hold_edit  = _labeled_edit(card, "Hold (s)",   row2_x + lbl_w2 + edit_w2 + r2_gap, y, lbl_w2, edit_w2, row_h, AdaptiveManager.catch_hold_time, 1)

	y += row_h + row_gap

	# Row 3 — Staircase params
	var lbl_w3: float  = 68.0
	var edit_w3: float = 58.0
	var r3_gap: float  = 36.0
	var row3_w: float  = (lbl_w3 + edit_w3) * 3.0 + r3_gap * 2.0
	var row3_x: float  = cw * 0.5 - row3_w * 0.5

	_sc_coarse_edit = _labeled_edit(card, "Coarse", row3_x,                             y, lbl_w3, edit_w3, row_h, AdaptiveManager.sc_step_coarse,          1)
	_sc_fine_edit   = _labeled_edit(card, "Fine",   row3_x + lbl_w3 + edit_w3 + r3_gap, y, lbl_w3, edit_w3, row_h, AdaptiveManager.sc_step_fine,            1)
	_sc_rev_edit    = _labeled_edit(card, "Rev #",  row3_x + (lbl_w3 + edit_w3 + r3_gap) * 2.0, y, lbl_w3, edit_w3, row_h, float(AdaptiveManager.sc_n_reversals), 0)

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
