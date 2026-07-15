extends Node2D

const UITheme := preload("res://app/ui/ui_theme.gd")

signal apple_eaten
signal apple_missed

var lifetime:        float = 10.0
var target_radius:   float = 28.0
var balloon_color:   Color = Color(0.12, 0.42, 0.42)
var _lifetime:       float = 0.0
var _catch_progress: float = 0.0
var _eaten:          bool  = false
var _missed:         bool  = false
var _deflate:        float = 0.0
const DEFLATE_TIME:  float = 0.45  # miss animation: soft, brief, downward


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
	if _missed:
		_deflate += delta
		if _deflate >= DEFLATE_TIME:
			queue_free()
		queue_redraw()
		return
	if _catch_progress == 0.0:
		_lifetime += delta
	if _lifetime >= lifetime:
		_missed = true
		apple_missed.emit()  # game logic proceeds now; the deflate is only visual
		return
	queue_redraw()


func _draw() -> void:
	if _missed:
		# Eased two-element dissolve: body shrinks/sinks with accelerating
		# ease while an expanding thin ring "releases" outward and fades.
		var p := clampf(_deflate / DEFLATE_TIME, 0.0, 1.0)
		var ease_in := p * p                      # slow start, fast finish
		var ease_out := 1.0 - (1.0 - p) * (1.0 - p)  # fast start, soft landing

		var ring_col := balloon_color.lerp(UITheme.MISS, 0.5)
		ring_col.a = 0.55 * (1.0 - p)
		draw_arc(Vector2.ZERO, target_radius * (1.0 + 0.65 * ease_out),
			0.0, TAU, 64, ring_col, 2.0)

		var body_col := balloon_color.lerp(UITheme.MISS, 0.4 + 0.5 * p)
		body_col.a = pow(1.0 - p, 1.4)
		var r_d := target_radius * (1.0 - 0.8 * ease_in)
		draw_circle(Vector2(0.0, 22.0 * ease_in), r_d, body_col)
		return

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
