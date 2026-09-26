extends Node2D

# The night meadow behind every participant screen (style A, chosen
# 2026-09-26): a deep sky, the moon's glow, misty hills and a dark meadow.
# Never moves, so it is drawn once, behind its parent (show_behind_parent).
# The twinkling stars and drifting fireflies are night_life.gd, a sibling
# drawn just above this. The middle of the screen stays dark for the targets.

const Art := preload("res://app/clinic/game_art.gd")

var _vp: Vector2


func _ready() -> void:
	show_behind_parent = true
	_vp = get_viewport_rect().size


func _band(y0: float, y1: float, c0: Color, c1: Color) -> void:
	draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(_vp.x, y0), Vector2(_vp.x, y1), Vector2(0, y1)]),
		PackedColorArray([c0, c0, c1, c1]))


# A hill: a smooth ridge down to the bottom, with an anti-aliased edge line.
func _hill(base: float, amp: float, cycles: float, phase: float, top: Color, bottom: Color) -> void:
	var ridge := PackedVector2Array()
	var n := 64
	for i in n + 1:
		var x := _vp.x * float(i) / float(n)
		var u := TAU * x / _vp.x
		ridge.append(Vector2(x, base - amp * (0.6 * sin(cycles * u + phase) + 0.4 * sin(2.3 * cycles * u + phase * 1.7))))
	var pts := ridge.duplicate()
	var cols := PackedColorArray()
	for i in ridge.size():
		cols.append(top)
	pts.append(Vector2(_vp.x, _vp.y))
	cols.append(bottom)
	pts.append(Vector2(0.0, _vp.y))
	cols.append(bottom)
	draw_polygon(pts, cols)
	draw_polyline(ridge, top, 2.0, true)


func _draw() -> void:
	var w := _vp.x
	var h := _vp.y
	_band(0.0, h * 0.45, Color("080C1F"), Color("121C3A"))
	_band(h * 0.45, h * 0.75, Color("121C3A"), Color("17304A"))
	_band(h * 0.75, h, Color("17304A"), Color("1B3B3E"))
	# The moon and its halo, high on the right, away from the play area.
	var moon := Vector2(w * 0.80, h * 0.15)
	Art.blit(self, Art.glow(), moon, Vector2(h, h) * 1.3, Color(0.85, 0.9, 1.0, 0.12))
	Art.blit(self, Art.glow(), moon, Vector2(h, h) * 0.55, Color(0.95, 0.95, 1.0, 0.22))
	Art.blit(self, Art.glow(), moon, Vector2(h, h) * 0.2, Color(1.0, 1.0, 1.0, 0.45))
	Art.blit(self, Art.disc(), moon, Vector2(h, h) * 0.055, Color("F4F1E6"))
	Art.blit(self, Art.disc(), moon + Vector2(h * 0.008, h * 0.006), Vector2(h, h) * 0.02, Color(0.8, 0.8, 0.85, 0.35))
	# Far hills, mist, near hills.
	_hill(h * 0.80, h * 0.035, 1.3, 0.4, Color("1B3346"), Color("10202B"))
	draw_polygon(PackedVector2Array([Vector2(0, h * 0.66), Vector2(w, h * 0.66), Vector2(w, h * 0.84), Vector2(0, h * 0.84)]),
		PackedColorArray([Color(0.62, 0.78, 0.85, 0.0), Color(0.62, 0.78, 0.85, 0.0),
			Color(0.62, 0.78, 0.85, 0.10), Color(0.62, 0.78, 0.85, 0.10)]))
	_hill(h * 0.90, h * 0.025, 0.9, 3.0, Color("13262E"), Color("0A1519"))
	# Grass blades along the bottom edge.
	for i in 48:
		var x := w * float(i) / 48.0 + 6.0 * sin(float(i) * 5.3)
		var lean := 7.0 * sin(float(i) * 2.9)
		draw_line(Vector2(x, h + 2.0), Vector2(x + lean, h - 16.0 - 8.0 * absf(sin(float(i)))),
			Color("0C1B1F"), 3.0, true)
