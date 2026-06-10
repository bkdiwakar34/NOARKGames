extends Node2D

signal apple_eaten
signal apple_missed

const BALLOON_RX := 22.0   # horizontal radius
const BALLOON_RY := 28.0   # vertical radius (taller than wide)
const CATCH_ARC_RADIUS := 46.0

var lifetime: float = 10.0
var balloon_color: Color = Color(0.9, 0.15, 0.12)
var _lifetime: float = 0.0
var _catch_progress: float = 0.0
var _eaten: bool = false

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
	var bob := sin(_lifetime * 5.0) * 3.0
	var center := Vector2(0.0, bob)

	# Pulsing yellow ring — marks the target
	var pulse := 0.5 + 0.5 * sin(_lifetime * 4.0)
	var ring_r := CATCH_ARC_RADIUS + 5.0 * sin(_lifetime * 4.0)
	draw_arc(center, ring_r, 0.0, TAU, 48, Color(1.0, 0.85, 0.1, pulse), 3.5)

	# Balloon body (oval polygon)
	var n := 36
	var body_pts := PackedVector2Array()
	for i in n:
		var a := float(i) / n * TAU
		body_pts.append(center + Vector2(cos(a) * BALLOON_RX, sin(a) * BALLOON_RY))
	draw_colored_polygon(body_pts, balloon_color)

	# Sheen highlight
	var hi_pts := PackedVector2Array()
	for i in 16:
		var a := float(i) / 16.0 * TAU
		hi_pts.append(center + Vector2(-7.0 + cos(a) * 5.0, -10.0 + sin(a) * 4.0))
	draw_colored_polygon(hi_pts, Color(1.0, 1.0, 1.0, 0.35))

	# Knot at bottom of balloon
	var knot_y := bob + BALLOON_RY + 2.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4.0, knot_y - 3.0),
		Vector2( 4.0, knot_y - 3.0),
		Vector2( 0.0, knot_y + 5.0)
	]), balloon_color.darkened(0.25))

	# String (gently swaying)
	var prev := Vector2(0.0, knot_y + 5.0)
	for i in 10:
		var t := float(i + 1) / 10.0
		var sx := sin(t * PI * 2.5 + _lifetime * 1.5) * 6.0
		var next := Vector2(sx, knot_y + 5.0 + t * 45.0)
		draw_line(prev, next, Color(0.55, 0.55, 0.55, 0.85), 1.5)
		prev = next

	# Lifetime bar
	var t := _lifetime / lifetime
	var bar_w := 52.0
	var bar_h := 6.0
	var bx := -bar_w * 0.5
	var by := bob - BALLOON_RY - 18.0
	draw_rect(Rect2(bx, by, bar_w, bar_h), Color(0.1, 0.1, 0.1, 0.65))
	var bar_col := Color(0.2, 0.85, 0.2) if t < 0.5 \
		else (Color(1.0, 0.75, 0.1) if t < 0.75 else Color(0.9, 0.15, 0.15))
	draw_rect(Rect2(bx, by, bar_w * (1.0 - t), bar_h), bar_col)

	# Catch arc — fills as pin holds position
	if _catch_progress > 0.0:
		draw_arc(center, CATCH_ARC_RADIUS,
			-PI * 0.5, -PI * 0.5 + TAU * _catch_progress,
			32, Color.WHITE, 5.0)
