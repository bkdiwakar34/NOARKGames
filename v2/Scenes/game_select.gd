extends Control

var _override_rate: float = 0.8
var _rate_buttons: Array = []

var _kp_edit:       LineEdit
var _ki_edit:       LineEdit
var _kd_edit:       LineEdit
var _width_edit:    LineEdit
var _hold_edit:     LineEdit
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
	_add_mode_toggle(vp)
	_add_pid_row(vp)
	_add_testing_row(vp)

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

func _add_mode_toggle(vp: Vector2) -> void:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.28, 0.42, 0.60, 0.80))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(vp.x, 28.0)
	label.position = Vector2(0.0, vp.y * 0.66)
	label.text = "Difficulty mode:"
	add_child(label)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200.0, 40.0)
	btn.position = Vector2(vp.x * 0.5 - 100.0, vp.y * 0.66 + 32.0)
	btn.add_theme_font_size_override("font_size", 18)
	_update_mode_btn(btn)
	btn.pressed.connect(func():
		if AdaptiveManager.difficulty_mode == AdaptiveManager.DifficultyMode.LIFETIME:
			AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.WORKSPACE
		else:
			AdaptiveManager.difficulty_mode = AdaptiveManager.DifficultyMode.LIFETIME
		_update_mode_btn(btn)
	)
	add_child(btn)

func _update_mode_btn(btn: Button) -> void:
	if AdaptiveManager.difficulty_mode == AdaptiveManager.DifficultyMode.LIFETIME:
		btn.text = "Lifetime"
	else:
		btn.text = "Workspace"

func _make_line_edit(value: float, decimals: int, w: float, h: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = "%.*f" % [decimals, value]
	e.custom_minimum_size = Vector2(w, h)
	e.size = Vector2(w, h)
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.15, 0.28)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.25, 0.45, 0.70)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", sb)
	e.add_theme_color_override("font_color", Color(0.88, 0.92, 1.0))
	e.add_theme_font_size_override("font_size", 15)
	return e

func _add_pid_row(vp: Vector2) -> void:
	var header := Label.new()
	header.text = "PID gains:"
	header.add_theme_font_size_override("font_size", 16)
	header.add_theme_color_override("font_color", Color(0.28, 0.42, 0.60, 0.80))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.custom_minimum_size = Vector2(vp.x, 24.0)
	header.position = Vector2(0.0, vp.y * 0.76)
	add_child(header)

	var row_h: float = 32.0
	var lbl_w: float = 30.0
	var edit_w: float = 70.0
	var group_w: float = lbl_w + 6.0 + edit_w   # 106
	var gap: float = 40.0
	var total_w: float = 3.0 * group_w + 2.0 * gap
	var start_x: float = vp.x * 0.5 - total_w * 0.5
	var row_y: float = vp.y * 0.76 + 28.0

	var gains := [
		{"label": "Kp:", "val": AdaptiveManager.gain_p},
		{"label": "Ki:", "val": AdaptiveManager.gain_i},
		{"label": "Kd:", "val": AdaptiveManager.gain_d},
	]

	for i in gains.size():
		var gx: float = start_x + i * (group_w + gap)
		var lbl := Label.new()
		lbl.text = gains[i]["label"]
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
		lbl.custom_minimum_size = Vector2(lbl_w, row_h)
		lbl.position = Vector2(gx, row_y)
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(lbl)

		var edit := _make_line_edit(gains[i]["val"], 2, edit_w, row_h)
		edit.position = Vector2(gx + lbl_w + 6.0, row_y)
		add_child(edit)

		if i == 0: _kp_edit = edit
		elif i == 1: _ki_edit = edit
		else: _kd_edit = edit

func _add_testing_row(vp: Vector2) -> void:
	var header := Label.new()
	header.text = "Testing:"
	header.add_theme_font_size_override("font_size", 16)
	header.add_theme_color_override("font_color", Color(0.28, 0.42, 0.60, 0.80))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.custom_minimum_size = Vector2(vp.x, 24.0)
	header.position = Vector2(0.0, vp.y * 0.87)
	add_child(header)

	var row_y: float = vp.y * 0.87 + 28.0
	var btn_h: float = 32.0
	var lbl_w: float = 50.0
	var edit_w: float = 66.0
	var section_gap: float = 28.0

	# Trial duration section
	var durations: Array = [10.0, 20.0, 30.0, 60.0]
	var dur_buttons: Array = []
	var dur_btn_w: float = 50.0
	var dur_gap: float = 6.0
	var dur_section_w: float = lbl_w + durations.size() * dur_btn_w + (durations.size() - 1) * dur_gap
	# Width section: label + edit
	var width_section_w: float = lbl_w + edit_w
	# Hold section: label + edit
	var hold_section_w: float = lbl_w + edit_w
	# Staircase section: Coarse | Fine | Rev
	var sc_lbl_w: float = 50.0
	var sc_edit_w: float = 48.0
	var sc_inner_gap: float = 12.0
	var sc_section_w: float = sc_lbl_w + sc_edit_w + sc_inner_gap + sc_lbl_w + sc_edit_w + sc_inner_gap + 36.0 + 40.0
	var total_w: float = dur_section_w + section_gap + width_section_w + section_gap + hold_section_w + section_gap + sc_section_w
	var start_x: float = vp.x * 0.5 - total_w * 0.5

	# --- Trial duration ---
	var dur_lbl := Label.new()
	dur_lbl.text = "Trial:"
	dur_lbl.add_theme_font_size_override("font_size", 15)
	dur_lbl.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
	dur_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	dur_lbl.position = Vector2(start_x, row_y)
	dur_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(dur_lbl)

	var dur_x: float = start_x + lbl_w
	for i in durations.size():
		var d: float = durations[i]
		var b := Button.new()
		b.text = "%ds" % int(d)
		b.custom_minimum_size = Vector2(dur_btn_w, btn_h)
		b.size = Vector2(dur_btn_w, btn_h)
		b.position = Vector2(dur_x + i * (dur_btn_w + dur_gap), row_y)
		b.add_theme_font_size_override("font_size", 14)
		_style_rate_btn(b, d == AdaptiveManager.trial_duration)
		var captured_d: float = d
		var captured_b: Button = b
		b.pressed.connect(func():
			AdaptiveManager.trial_duration = captured_d
			for db in dur_buttons:
				_style_rate_btn(db, false)
			_style_rate_btn(captured_b, true)
		)
		dur_buttons.append(b)
		add_child(b)

	# --- Window width ---
	var ww_x: float = start_x + dur_section_w + section_gap
	var ww_lbl := Label.new()
	ww_lbl.text = "Width (s):"
	ww_lbl.add_theme_font_size_override("font_size", 14)
	ww_lbl.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
	ww_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	ww_lbl.position = Vector2(ww_x, row_y)
	ww_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(ww_lbl)
	_width_edit = _make_line_edit(AdaptiveManager.window_width, 1, edit_w, btn_h)
	_width_edit.position = Vector2(ww_x + lbl_w, row_y)
	add_child(_width_edit)

	# --- Catch hold time ---
	var hold_x: float = ww_x + width_section_w + section_gap
	var hold_lbl := Label.new()
	hold_lbl.text = "Hold (s):"
	hold_lbl.add_theme_font_size_override("font_size", 14)
	hold_lbl.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
	hold_lbl.custom_minimum_size = Vector2(lbl_w, btn_h)
	hold_lbl.position = Vector2(hold_x, row_y)
	hold_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(hold_lbl)
	_hold_edit = _make_line_edit(AdaptiveManager.catch_hold_time, 1, edit_w, btn_h)
	_hold_edit.position = Vector2(hold_x + lbl_w, row_y)
	add_child(_hold_edit)

	# --- Staircase calibration ---
	var sc_x: float = hold_x + hold_section_w + section_gap
	for item in [
		{"label": "Coarse:", "x": sc_x, "val": AdaptiveManager.sc_step_coarse, "dec": 1, "w": sc_edit_w},
		{"label": "Fine:", "x": sc_x + sc_lbl_w + sc_edit_w + sc_inner_gap, "val": AdaptiveManager.sc_step_fine, "dec": 1, "w": sc_edit_w},
		{"label": "Rev#:", "x": sc_x + 2.0 * (sc_lbl_w + sc_edit_w + sc_inner_gap), "val": float(AdaptiveManager.sc_n_reversals), "dec": 0, "w": 40.0},
	]:
		var slbl := Label.new()
		slbl.text = item["label"]
		slbl.add_theme_font_size_override("font_size", 14)
		slbl.add_theme_color_override("font_color", Color(0.20, 0.35, 0.55))
		slbl.custom_minimum_size = Vector2(sc_lbl_w, btn_h)
		slbl.position = Vector2(item["x"], row_y)
		slbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(slbl)
		var sedit := _make_line_edit(item["val"], item["dec"], item["w"], btn_h)
		sedit.position = Vector2(item["x"] + sc_lbl_w, row_y)
		add_child(sedit)
		if item["label"] == "Coarse:": _sc_coarse_edit = sedit
		elif item["label"] == "Fine:": _sc_fine_edit = sedit
		else: _sc_rev_edit = sedit

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
