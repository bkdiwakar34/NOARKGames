extends Node2D

# The orchard backdrop behind every participant screen (mockup: "Orchard scene"):
# golden-hour sky and sun, clouds, far and near hills with a row of trees, the
# meadow, branches framing the top corners, a soft vignette. Drawn once (it
# does not move), behind its parent: show_behind_parent. The middle of the
# screen stays clear for the apples.

var _vp: Vector2


func _ready() -> void:
	show_behind_parent = true
	_vp = get_viewport_rect().size


# Vertical gradient band from y0 to y1.
func _band(y0: float, y1: float, c0: Color, c1: Color) -> void:
	draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(_vp.x, y0), Vector2(_vp.x, y1), Vector2(0, y1)]),
		PackedColorArray([c0, c0, c1, c1]))


# A hill: a smooth top edge (sum of two sines) down to the bottom of the screen,
# lighter at the top edge than at the bottom.
func _hill(base: float, amp: float, cycles: float, phase: float, top: Color, bottom: Color) -> void:
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var n := 40
	for i in n + 1:
		var x := _vp.x * float(i) / float(n)
		var u := TAU * x / _vp.x
		pts.append(Vector2(x, base - amp * (0.6 * sin(cycles * u + phase) + 0.4 * sin(2.3 * cycles * u + phase * 1.7))))
		cols.append(top)
	pts.append(Vector2(_vp.x, _vp.y))
	cols.append(bottom)
	pts.append(Vector2(0.0, _vp.y))
	cols.append(bottom)
	draw_polygon(pts, cols)


func _leaf(pos: Vector2, angle: float, size: float, dark: bool) -> void:
	draw_set_transform(pos, angle, Vector2(size, size * 0.42))
	draw_circle(Vector2.ZERO, 1.0, Color("2E6A2A") if dark else Color("5E9E47"))
	draw_set_transform(pos + Vector2(-0.2, -0.25) * size, angle, Vector2(size * 0.6, size * 0.18))
	draw_circle(Vector2.ZERO, 1.0, Color(1.0, 1.0, 1.0, 0.10))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# A branch from the corner with leaves along it; mirror = right-hand corner.
func _branch(mirror: bool) -> void:
	var s := _vp.x / 1280.0
	var fx := func(x: float) -> float: return _vp.x - x * s if mirror else x * s
	var main := PackedVector2Array()
	for i in 13:
		var t := float(i) / 12.0
		main.append(Vector2(fx.call(-20.0 + 330.0 * t), (22.0 + 60.0 * sin(t * 2.6) - 10.0 * t) * s))
	draw_polyline(main, Color("5A3D26"), 16.0 * s, true)
	var twig := PackedVector2Array([Vector2(fx.call(160.0), 62.0 * s), Vector2(fx.call(205.0), 105.0 * s),
		Vector2(fx.call(235.0), 150.0 * s)])
	draw_polyline(twig, Color("5A3D26"), 7.0 * s, true)
	var leaves: Array = [[30, 36, -0.3], [62, 62, 0.5], [95, 34, -0.6], [128, 74, 0.4], [160, 44, -0.2],
		[192, 82, 0.7], [218, 52, -0.4], [248, 76, 0.3], [276, 48, -0.2], [304, 72, 0.6],
		[204, 118, 1.0], [230, 142, 1.2], [250, 166, 0.9], [178, 104, -0.7], [14, 74, 0.3], [60, 16, -0.9]]
	for i in leaves.size():
		var l: Array = leaves[i]
		var ang: float = l[2]
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		_leaf(Vector2(fx.call(float(l[0])), float(l[1]) * s), -ang if mirror else ang, 26.0 * s, i % 3 == 0)


func _draw() -> void:
	var w := _vp.x
	var h := _vp.y
	# Sky: blue high up, warm near the horizon.
	_band(0.0, h * 0.38, Color("78AEDB"), Color("B8D8EA"))
	_band(h * 0.38, h * 0.62, Color("B8D8EA"), Color("F4E3C6"))
	_band(h * 0.62, h, Color("F4E3C6"), Color("F2C68C"))
	# Sun with a wide glow, top right of centre (clear of the play area's middle).
	var sun := Vector2(w * 0.70, h * 0.21)
	for i in 8:
		draw_circle(sun, h * (0.46 - 0.05 * float(i)), Color(1.0, 0.95, 0.80, 0.07))
	draw_circle(sun, h * 0.06, Color("FFF6D6"))
	# Clouds.
	for c in [[0.20, 0.17, 1.0], [0.48, 0.11, 0.7], [0.88, 0.30, 0.6]]:
		var p := Vector2(w * float(c[0]), h * float(c[1]))
		var k: float = c[2] * h / 720.0
		for e in [[0, 0, 92, 24], [48, -14, 58, 26], [-44, -6, 48, 20]]:
			draw_set_transform(p + Vector2(e[0], e[1]) * k, 0.0, Vector2(e[2], e[3]) * k)
			draw_circle(Vector2.ZERO, 1.0, Color(1.0, 1.0, 1.0, 0.55))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Hills, far to near, with a row of orchard trees on the middle one.
	_hill(h * 0.58, h * 0.04, 1.3, 0.4, Color("A9C3B8"), Color("C9D6C2"))
	_hill(h * 0.66, h * 0.035, 1.1, 2.0, Color("8DB27E"), Color("6D9760"))
	for i in 16:
		var x := w * (0.03 + 0.062 * float(i)) + 9.0 * sin(float(i) * 3.1)
		if x > w * 0.38 and x < w * 0.52:
			continue   # a gap in the row, like the mockup
		var y := h * 0.625 + 4.0 * sin(float(i) * 1.7)
		var r := h * (0.020 + 0.006 * sin(float(i) * 2.3))
		draw_rect(Rect2(x - 1.5, y, 3.0, r * 0.9), Color("5A4632"))
		draw_circle(Vector2(x, y), r, Color("5B8A52"))
		draw_circle(Vector2(x - r * 0.3, y - r * 0.3), r * 0.45, Color(1.0, 1.0, 1.0, 0.08))
	_hill(h * 0.78, h * 0.025, 0.8, 4.0, Color("97C46A"), Color("4A8436"))
	_band(h * 0.90, h, Color(0.25, 0.48, 0.18, 0.0), Color(0.25, 0.48, 0.18, 0.55))
	# Grass blades along the bottom.
	for i in 40:
		var x := w * float(i) / 40.0 + 7.0 * sin(float(i) * 5.3)
		var lean := 6.0 * sin(float(i) * 2.9)
		draw_line(Vector2(x, h), Vector2(x + lean, h - 14.0 - 6.0 * absf(sin(float(i)))), Color("3A722C"), 2.5, true)
	# Branches framing the top corners.
	_branch(false)
	_branch(true)
	# Vignette: dark edges fading inward.
	var edge := Color(0.11, 0.16, 0.07, 0.30)
	var clear := Color(0.11, 0.16, 0.07, 0.0)
	var m := h * 0.22
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, m), Vector2(0, m)]),
		PackedColorArray([edge, edge, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, h - m), Vector2(w, h - m), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([clear, clear, edge, edge]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(m, 0), Vector2(m, h), Vector2(0, h)]),
		PackedColorArray([edge, clear, clear, edge]))
	draw_polygon(PackedVector2Array([Vector2(w - m, 0), Vector2(w, 0), Vector2(w, h), Vector2(w - m, h)]),
		PackedColorArray([clear, edge, edge, clear]))
