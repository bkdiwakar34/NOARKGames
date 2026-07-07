extends Control
# Tracing demo overlay: nested rectangle outlines + a persistent trail of the
# cursor path. Trace an outline with the device; trail raggedness makes tracker
# jitter directly visible. Combine with the TRACKER toggles in the settings
# menu to compare old/new marker sets and solvers on the same shapes.

const TRAIL_MAX: int = 30000
const RECT_FRACTIONS: Array = [0.85, 0.55, 0.25]  # of the usable workspace rect

var _trail: PackedVector2Array = PackedVector2Array()
var _cursor: Vector2 = Vector2.ZERO
var _mode_lbl: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.16)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_mode_lbl = Label.new()
	_mode_lbl.add_theme_font_size_override("font_size", 16)
	_mode_lbl.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	_mode_lbl.position = Vector2(16.0, 12.0)
	add_child(_mode_lbl)

	var clear_btn := Button.new()
	clear_btn.text = "Clear trail (C)"
	clear_btn.custom_minimum_size = Vector2(150.0, 36.0)
	clear_btn.position = Vector2(16.0, 44.0)
	clear_btn.pressed.connect(_clear_trail)
	add_child(clear_btn)

	var close_btn := Button.new()
	close_btn.text = "✕  Close (Esc)"
	close_btn.custom_minimum_size = Vector2(150.0, 36.0)
	close_btn.position = Vector2(get_viewport_rect().size.x - 166.0, 12.0)
	close_btn.pressed.connect(queue_free)
	add_child(close_btn)


func _process(_dt: float) -> void:
	if UDPReceiver.connected:
		_cursor = UDPReceiver.screen_pos
	else:
		_cursor = get_viewport().get_mouse_position()  # dev fallback

	if _trail.is_empty() or _trail[_trail.size() - 1].distance_to(_cursor) > 0.5:
		_trail.append(_cursor)
		if _trail.size() > TRAIL_MAX:
			_trail = _trail.slice(_trail.size() - TRAIL_MAX)

	var markers: String = "12+20" if UDPReceiver.setup_subset else "all markers"
	var solver:  String = "rigid body" if UDPReceiver.setup_rigid else "per-marker"
	_mode_lbl.text = "Tracker: %s  |  %s        trail: %d pts" % [markers, solver, _trail.size()]
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_C:
			_clear_trail()
		elif event.keycode == KEY_ESCAPE:
			queue_free()


func _clear_trail() -> void:
	_trail = PackedVector2Array()


func _draw() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var centre: Vector2 = vp * 0.5
	var usable: Vector2 = vp * 0.86

	# Guide rectangles to trace along
	for f in RECT_FRACTIONS:
		var sz: Vector2 = usable * f
		draw_rect(Rect2(centre - sz * 0.5, sz), Color(0.35, 0.55, 0.85, 0.9), false, 3.0)

	# The trail — the evidence
	if _trail.size() >= 2:
		draw_polyline(_trail, Color(0.55, 0.95, 0.55), 2.0, true)

	# Cursor
	draw_circle(_cursor, 7.0, Color(1.0, 0.45, 0.30))
