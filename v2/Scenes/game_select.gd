extends Control

var _override_rate: float = 0.8
var _rate_buttons: Array = []

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
	lbl.position = Vector2(0.0, vp.y * 0.70)
	add_child(lbl)

	var btn_w: float = 72.0
	var btn_h: float = 36.0
	var gap: float = 8.0
	var total_w: float = rates.size() * btn_w + (rates.size() - 1) * gap
	var start_x: float = vp.x * 0.5 - total_w * 0.5
	var row_y: float = vp.y * 0.70 + 32.0

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
	label.position = Vector2(0.0, vp.y * 0.80)
	label.text = "Difficulty mode:"
	add_child(label)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200.0, 40.0)
	btn.position = Vector2(vp.x * 0.5 - 100.0, vp.y * 0.80 + 32.0)
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

func _start_game(scene_path: String) -> void:
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
