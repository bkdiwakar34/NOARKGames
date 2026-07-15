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

		var ring_col := UITheme.APPLE_RED.lerp(UITheme.MISS, 0.5)
		ring_col.a = 0.55 * (1.0 - p)
		draw_arc(Vector2.ZERO, target_radius * (1.0 + 0.65 * ease_out),
			0.0, TAU, 64, ring_col, 2.0)

		var body_col := UITheme.APPLE_RED.lerp(UITheme.MISS, 0.4 + 0.5 * p)
		body_col.a = pow(1.0 - p, 1.4)
		var r_d := target_radius * (1.0 - 0.8 * ease_in)
		draw_circle(Vector2(0.0, 22.0 * ease_in), r_d, body_col)
		return

	var r := target_radius

	# Apple body: dark base + offset lighter body fakes radial shading
	draw_circle(Vector2.ZERO, r, UITheme.APPLE_DARK)
	draw_circle(Vector2(-r * 0.08, -r * 0.10), r * 0.92, UITheme.APPLE_RED)
	draw_circle(Vector2(-r * 0.30, -r * 0.32), r * 0.45, UITheme.APPLE_LIGHT)
	draw_circle(Vector2(-r * 0.32, -r * 0.36), r * 0.16, Color(1.0, 1.0, 1.0, 0.35))

	# Brighten while the patient holds on target
	if _catch_progress > 0.0:
		draw_circle(Vector2.ZERO, r, Color(1.0, 0.97, 0.90, 0.45 * _catch_progress))

	# Stem + leaf
	draw_set_transform(Vector2(r * 0.02, -r * 0.98), 0.12, Vector2.ONE)
	draw_rect(Rect2(-r * 0.05, -r * 0.28, r * 0.10, r * 0.30), Color(0.42, 0.29, 0.17))
	draw_set_transform(Vector2(r * 0.30, -r * 1.04), -0.5, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, r * 0.22, UITheme.LEAF)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Time ring: one calm gold ring emptying clockwise on a faint track
	# (replaces the old grey/orange/red three-alarm arc)
	var time_frac := _lifetime / lifetime
	var track := Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.12)
	draw_arc(Vector2.ZERO, r + 9.0, 0.0, TAU, 64, track, 4.0, true)
	draw_arc(Vector2.ZERO, r + 9.0, -PI * 0.5,
		-PI * 0.5 + TAU * (1.0 - time_frac), 64, UITheme.GOLD, 4.0, true)

	# Catch progress arc inside the body edge
	if _catch_progress > 0.0:
		draw_arc(Vector2.ZERO, r - 6.0, -PI * 0.5,
			-PI * 0.5 + TAU * _catch_progress, 48, Color(1.0, 1.0, 1.0, 0.85), 5.0, true)
