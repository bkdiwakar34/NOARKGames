extends Node2D

const UITheme := preload("res://app/ui/ui_theme.gd")

signal apple_eaten
signal apple_missed

var lifetime:        float = 10.0
var target_radius:   float = 28.0
var balloon_color:   Color = Color(0.12, 0.42, 0.42)  # unused; kept for interface compatibility
var _lifetime:       float = 0.0
var _catch_progress: float = 0.0
var _eaten:          bool  = false
var _missed:         bool  = false
var _spawn_done:     bool  = false
var _fall_t:         float = 0.0
var _fall_v:         float = 0.0
const FALL_TIME:     float = 0.6   # miss: the apple drops off the world (down = gone)


func _ready() -> void:
	# Springy bounce-in on spawn (approved in the round-2 demo)
	scale = Vector2.ZERO
	var t := create_tween()
	t.tween_property(self, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_callback(func(): _spawn_done = true)


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
		# Orchard physics: gravity, slight tumble, fade — then gone
		_fall_t += delta
		_fall_v += 1400.0 * delta
		position.y += _fall_v * delta
		rotation += 1.6 * delta
		modulate.a = clampf(1.0 - _fall_t / FALL_TIME, 0.0, 1.0)
		if _fall_t >= FALL_TIME:
			queue_free()
		queue_redraw()
		return
	if _catch_progress == 0.0:
		_lifetime += delta
	if _lifetime >= lifetime:
		_missed = true
		scale = Vector2.ONE
		apple_missed.emit()  # game logic proceeds now; the fall is only visual
		return
	# Gentle size pulse over the last quarter of the lifetime — urgency the
	# eye catches without alarm colors (skipped until the spawn bounce ends)
	if _spawn_done:
		if _lifetime / lifetime > 0.75 and _catch_progress == 0.0:
			scale = Vector2.ONE * (1.0 + 0.035 * sin(Time.get_ticks_msec() * 0.012))
		else:
			scale = Vector2.ONE
	queue_redraw()


func _draw() -> void:
	var r := target_radius

	# Minimal apple: one confident red dot with a small leaf — no outline,
	# no stem, no shine (flat, Two-Dots-inspired, approved in the demo)
	draw_circle(Vector2.ZERO, r, UITheme.APPLE_RED)
	draw_set_transform(Vector2(r * 0.42, -r * 0.82), -0.6, Vector2(1.0, 0.5))
	draw_circle(Vector2.ZERO, r * 0.26, UITheme.LEAF)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if _missed:
		return  # falling: just the fading dot, no ring or progress

	# Brighten while the patient holds on target
	if _catch_progress > 0.0:
		draw_circle(Vector2.ZERO, r, Color(1.0, 0.97, 0.90, 0.45 * _catch_progress))

	# Time ring: gold on a visible track, tight to the dot
	var time_frac := _lifetime / lifetime
	var ring_r := r + maxf(10.0, r * 0.18)
	var ring_w := maxf(6.0, r * 0.13)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64,
		Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.22), ring_w, true)
	draw_arc(Vector2.ZERO, ring_r, -PI * 0.5,
		-PI * 0.5 + TAU * (1.0 - time_frac), 64, UITheme.GOLD, ring_w - 2.0, true)

	# Catch progress arc inside the dot's edge
	if _catch_progress > 0.0:
		draw_arc(Vector2.ZERO, r - 6.0, -PI * 0.5,
			-PI * 0.5 + TAU * _catch_progress, 48, Color(1.0, 1.0, 1.0, 0.85), 5.0, true)
