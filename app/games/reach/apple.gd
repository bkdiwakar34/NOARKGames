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
		scale = Vector2.ONE
		apple_missed.emit()  # game logic proceeds now; the deflate is only visual
		return
	# Gentle size pulse over the last quarter of the lifetime — urgency the
	# eye catches without alarm colors
	if _lifetime / lifetime > 0.75 and _catch_progress == 0.0:
		scale = Vector2.ONE * (1.0 + 0.035 * sin(Time.get_ticks_msec() * 0.012))
	else:
		scale = Vector2.ONE
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

	# Flat cartoon apple: solid body, one crisp outline, one shine — reads
	# cleanly at every size and matches the flat orchard world (the earlier
	# fake-3D shading discs looked blobby).
	draw_circle(Vector2.ZERO, r, UITheme.APPLE_RED)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, UITheme.APPLE_DARK, maxf(2.5, r * 0.07), true)
	draw_set_transform(Vector2(-r * 0.36, -r * 0.40), -0.55, Vector2(1.0, 0.55))
	draw_circle(Vector2.ZERO, r * 0.18, Color(1.0, 1.0, 1.0, 0.55))
	draw_set_transform(Vector2(r * 0.02, -r * 0.98), 0.15, Vector2.ONE)
	draw_rect(Rect2(-r * 0.06, -r * 0.30, r * 0.12, r * 0.34), Color(0.42, 0.29, 0.17))
	draw_set_transform(Vector2(r * 0.32, -r * 1.02), -0.5, Vector2(1.0, 0.5))
	draw_circle(Vector2.ZERO, r * 0.24, UITheme.LEAF)
	draw_arc(Vector2.ZERO, r * 0.24, 0.0, TAU, 32, Color(0.25, 0.42, 0.20), 2.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Brighten while the patient holds on target
	if _catch_progress > 0.0:
		draw_circle(Vector2.ZERO, r, Color(1.0, 0.97, 0.90, 0.45 * _catch_progress))

	# Time ring: gold on a clearly visible track, tight to the outline and
	# thick enough to read at arm's length
	var time_frac := _lifetime / lifetime
	var ring_r := r + maxf(10.0, r * 0.18)
	var ring_w := maxf(6.0, r * 0.13)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64,
		Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.22), ring_w, true)
	draw_arc(Vector2.ZERO, ring_r, -PI * 0.5,
		-PI * 0.5 + TAU * (1.0 - time_frac), 64, UITheme.GOLD, ring_w - 2.0, true)

	# Catch progress arc inside the body edge
	if _catch_progress > 0.0:
		draw_arc(Vector2.ZERO, r - 6.0, -PI * 0.5,
			-PI * 0.5 + TAU * _catch_progress, 48, Color(1.0, 1.0, 1.0, 0.85), 5.0, true)
