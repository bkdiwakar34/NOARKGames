extends Node2D

signal apple_eaten
signal apple_missed

const APPLE_RADIUS := 28.0
const CATCH_ARC_RADIUS := 46.0

var lifetime: float = 10.0
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

	# Pulsing yellow ring — marks the target clearly
	var pulse := 0.5 + 0.5 * sin(_lifetime * 4.0)
	var ring_r := CATCH_ARC_RADIUS + 5.0 * sin(_lifetime * 4.0)
	draw_arc(Vector2(0.0, bob), ring_r, 0.0, TAU, 48, Color(1.0, 0.85, 0.1, pulse), 3.5)

	# Apple body
	draw_circle(Vector2(0.0, bob), APPLE_RADIUS, Color(0.90, 0.15, 0.12))
	# Shine highlight
	draw_circle(Vector2(-9.0, bob - 10.0), 7.0, Color(1.0, 0.55, 0.55, 0.45))
	# Stem
	draw_line(Vector2(1.0, bob - APPLE_RADIUS + 2.0),
		Vector2(4.0, bob - APPLE_RADIUS - 9.0),
		Color(0.32, 0.18, 0.04), 3.0)
	# Leaf
	draw_circle(Vector2(9.0, bob - APPLE_RADIUS - 5.0), 8.0, Color(0.15, 0.70, 0.20))

	# Lifetime bar
	var t := _lifetime / lifetime
	var bar_w := 60.0
	var bar_h := 7.0
	var bx := -bar_w * 0.5
	var by := bob - APPLE_RADIUS - 22.0
	draw_rect(Rect2(bx, by, bar_w, bar_h), Color(0.1, 0.1, 0.1, 0.70))
	var bar_col := Color(0.2, 0.85, 0.2) if t < 0.5 \
		else (Color(1.0, 0.75, 0.1) if t < 0.75 else Color(0.9, 0.15, 0.15))
	draw_rect(Rect2(bx, by, bar_w * (1.0 - t), bar_h), bar_col)

	# Catch arc — fills as player holds position
	if _catch_progress > 0.0:
		draw_arc(Vector2(0.0, bob), CATCH_ARC_RADIUS,
			-PI * 0.5, -PI * 0.5 + TAU * _catch_progress,
			32, Color.WHITE, 5.0)
