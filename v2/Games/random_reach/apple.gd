extends Node2D

signal apple_eaten
signal apple_missed

var lifetime:        float = 10.0
var target_radius:   float = 28.0
var balloon_color:   Color = Color(0.12, 0.42, 0.42)
var _lifetime:       float = 0.0
var _catch_progress: float = 0.0
var _eaten:          bool  = false


func set_catch_progress(p: float) -> void:
	_catch_progress = p
	queue_redraw()


func eat() -> void:
	if _eaten:
		return
	_eaten = true
	apple_eaten.emit()
	queue_free()


func _process(delta: float) -> void:
	if _eaten:
		return
	if _catch_progress == 0.0:
		_lifetime += delta
	if _lifetime >= lifetime:
		apple_missed.emit()
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var r := target_radius
	var fill := balloon_color

	# Brighten fill as patient holds on target
	if _catch_progress > 0.0:
		fill = fill.lerp(Color(0.88, 0.97, 0.97), _catch_progress * 0.65)

	# Solid circle
	draw_circle(Vector2.ZERO, r, fill)

	# Outline — darkened version of fill
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, fill.darkened(0.38), 2.5)

	# Lifetime drain arc outside the circle, drains clockwise
	var time_frac := _lifetime / lifetime
	var arc_col: Color
	if time_frac < 0.5:
		arc_col = Color(0.52, 0.52, 0.52, 0.45)
	elif time_frac < 0.75:
		arc_col = Color(0.90, 0.58, 0.08, 0.65)
	else:
		arc_col = Color(0.85, 0.16, 0.16, 0.78)
	draw_arc(Vector2.ZERO, r + 7.0, -PI * 0.5,
		-PI * 0.5 + TAU * (1.0 - time_frac), 64, arc_col, 3.5)

	# Catch fill arc inside the circle edge
	if _catch_progress > 0.0:
		draw_arc(Vector2.ZERO, r - 5.0, -PI * 0.5,
			-PI * 0.5 + TAU * _catch_progress, 48, Color(1.0, 1.0, 1.0, 0.78), 4.5)
