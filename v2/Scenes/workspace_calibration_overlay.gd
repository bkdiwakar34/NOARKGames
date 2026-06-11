extends Control

signal calibration_done

const CORNER_LABELS: Array = ["top-left", "top-right", "bottom-left", "bottom-right"]

var _cursor_pos:      Vector2 = Vector2.ZERO
var _raw_corners:     Array   = []   # Vector2(raw_x, raw_z) for each recorded corner
var _screen_corners:  Array   = []   # screen_pos at each corner (visual feedback only)
var _btn:             Button  = null
var _instruction_lbl: Label   = null
var _status_lbl:      Label   = null
var _coords_lbl:      Label   = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_update_ui()


func _build_ui() -> void:
	var vp := get_viewport_rect().size

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.12, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_instruction_lbl = Label.new()
	_instruction_lbl.add_theme_font_size_override("font_size", 26)
	_instruction_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	_instruction_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_instruction_lbl.custom_minimum_size  = Vector2(vp.x, 44.0)
	_instruction_lbl.position            = Vector2(0.0, vp.y * 0.36)
	add_child(_instruction_lbl)

	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 16)
	_status_lbl.add_theme_color_override("font_color", Color(0.65, 0.90, 0.65))
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.custom_minimum_size  = Vector2(vp.x, 28.0)
	_status_lbl.position             = Vector2(0.0, vp.y * 0.36 + 50.0)
	add_child(_status_lbl)

	_btn = Button.new()
	_btn.custom_minimum_size = Vector2(240.0, 52.0)
	_btn.size                = Vector2(240.0, 52.0)
	_btn.position            = Vector2(vp.x * 0.5 - 120.0, vp.y * 0.54)
	_btn.add_theme_font_size_override("font_size", 17)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.52, 0.88)
	sb.corner_radius_top_left = 10; sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10; sb.corner_radius_bottom_right = 10
	var sb_h := sb.duplicate(); sb_h.bg_color = Color(0.20, 0.62, 1.0)
	_btn.add_theme_stylebox_override("normal", sb)
	_btn.add_theme_stylebox_override("hover",  sb_h)
	_btn.add_theme_stylebox_override("focus",  sb)
	_btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_btn.pressed.connect(_on_btn_pressed)
	add_child(_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(110.0, 34.0)
	cancel_btn.position = Vector2(vp.x * 0.5 - 55.0, vp.y * 0.54 + 62.0)
	cancel_btn.add_theme_font_size_override("font_size", 14)
	cancel_btn.pressed.connect(func(): queue_free())
	add_child(cancel_btn)

	_coords_lbl = Label.new()
	_coords_lbl.add_theme_font_size_override("font_size", 15)
	_coords_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coords_lbl.custom_minimum_size  = Vector2(vp.x, 26.0)
	_coords_lbl.position             = Vector2(0.0, vp.y * 0.88)
	add_child(_coords_lbl)


func _process(_delta: float) -> void:
	var raw: Vector2 = UDPReceiver.screen_pos if UDPReceiver.connected else get_global_mouse_position()
	_cursor_pos = raw
	if UDPReceiver.connected:
		_coords_lbl.add_theme_color_override("font_color", Color(0.40, 0.90, 0.50))
		_coords_lbl.text = "Hardware connected — raw_x: %.3f  raw_z: %.3f" % [UDPReceiver.raw_x, UDPReceiver.raw_z]
	else:
		_coords_lbl.add_theme_color_override("font_color", Color(0.90, 0.65, 0.20))
		_coords_lbl.text = "Hardware NOT connected — mouse position used"
	queue_redraw()


func _draw() -> void:
	for c in _screen_corners:
		draw_circle(c, 9.0, Color(0.20, 0.88, 0.30, 0.85))
		draw_arc(c, 9.0, 0.0, TAU, 32, Color(0.20, 0.88, 0.30), 2.0)

	if _screen_corners.size() >= 2:
		var xs: Array = []; var ys: Array = []
		for c in _screen_corners:
			xs.append(c.x); ys.append(c.y)
		xs.sort(); ys.sort()
		var rmin := Vector2(xs[0], ys[0])
		var rmax := Vector2(xs[xs.size() - 1], ys[ys.size() - 1])
		draw_rect(Rect2(rmin, rmax - rmin), Color(0.25, 0.80, 0.30, 0.18), true)
		draw_rect(Rect2(rmin, rmax - rmin), Color(0.25, 0.80, 0.30, 0.65), false, 2.0)

	draw_arc(_cursor_pos, 15.0, 0.0, TAU, 48, Color(1.0, 0.88, 0.18, 0.92), 2.5)
	draw_circle(_cursor_pos, 3.5, Color(1.0, 0.88, 0.18, 0.92))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_KP_ENTER:
			_on_btn_pressed()
			get_viewport().set_input_as_handled()


func _on_btn_pressed() -> void:
	if _raw_corners.size() < 4:
		_raw_corners.append(Vector2(UDPReceiver.raw_x, UDPReceiver.raw_z))
		_screen_corners.append(_cursor_pos)
		_update_ui()
	else:
		_save_and_close()


func _update_ui() -> void:
	var n: int = _raw_corners.size()
	if n < 4:
		var corner_name: String = CORNER_LABELS[n]
		_instruction_lbl.text = "Move arm to the %s corner of the screen, then press Enter" % corner_name
		_btn.text             = "Record %s   [Enter]" % corner_name
		_status_lbl.text      = "%d / 4 corners recorded" % n
	else:
		_instruction_lbl.text = "All 4 corners recorded"
		_btn.text             = "Save & Close"
		_status_lbl.text      = "Press Save to confirm"


func _save_and_close() -> void:
	if _raw_corners.size() < 4:
		return
	# Order: TL=0, TR=1, BL=2, BR=3
	# x-left edge = average of TL.x and BL.x; x-right = average of TR.x and BR.x
	# z-top edge  = average of TL.y and TR.y; z-bottom = average of BL.y and BR.y
	var x_left:   float = (_raw_corners[0].x + _raw_corners[2].x) * 0.5
	var x_right:  float = (_raw_corners[1].x + _raw_corners[3].x) * 0.5
	var z_top:    float = (_raw_corners[0].y + _raw_corners[1].y) * 0.5
	var z_bottom: float = (_raw_corners[2].y + _raw_corners[3].y) * 0.5
	WorkspaceConfig.save_sensor_calibration(x_left, x_right, z_top, z_bottom, get_viewport_rect().size)
	calibration_done.emit()
	queue_free()
