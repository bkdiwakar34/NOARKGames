# Participant-screen art (docs/clinic_study_interface.md §5, the mockup's
# "polished 2D orchard"): colours, the code-drawn apple, stars, plates and
# cards, drawn with CanvasItem calls. Code-drawn on purpose (CLAUDE.md: the
# sprite apple had a multi-apple bug). Everything here only draws; the catch
# zone and hit test stay in table mm (table_space.gd).
# Consumers use:  const Art := preload("res://app/clinic/game_art.gd")

const GOLD := Color("FFC23D")
const GOLD_DARK := Color("C98200")
const CREAM := Color("FFFCF3")
const CREAM_DARK := Color("F1E4CA")
const CARD_BASE := Color("DDCCAA")
const INK := Color("2E2419")
const INK_SOFT := Color("6E5A44")
const LEAF := Color("5FA052")
const LEAF_DARK := Color("2F6E2A")
const STAR_EMPTY := Color("E9E1D2")
const RED_BUTTON := Color("C0392B")

# Apple tones: highlight, body, shadow.
const RED: Array = [Color("F4775E"), Color("CC3524"), Color("7C1A11")]
const RIPE_GOLD: Array = [Color("FBE38A"), Color("E6A92A"), Color("9A6512")]
const DULL: Array = [Color("B5A596"), Color("7D6A5A"), Color("46382D")]

const APPLE_N := 28

static var _bold: Font = null
static var _unit: PackedVector2Array = PackedVector2Array()   # unit apple outline
static var _mesh_idx: PackedInt32Array = PackedInt32Array()


static func font() -> Font:
	if _bold == null:
		var path := "res://app/assets/fonts/Nunito-ExtraBold.ttf"
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			if f.load_dynamic_font(path) == OK:
				_bold = f
		if _bold == null:
			_bold = ThemeDB.fallback_font
	return _bold


# Text centred on pos (pos.y = the visual middle of the line).
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color) -> void:
	var f := font()
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var base := pos + Vector2(-w * 0.5, f.get_ascent(size) * 0.5 - f.get_descent(size) * 0.3)
	ci.draw_string(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# ── Apple ─────────────────────────────────────────────────────────────────────

# Unit apple outline: a circle with a dimple at the top, slightly wide, flatter
# underneath. Built once.
static func _outline() -> PackedVector2Array:
	if _unit.is_empty():
		for i in APPLE_N:
			var t := TAU * float(i) / float(APPLE_N) - PI * 0.5
			var d := angle_difference(t, -PI * 0.5)
			var rr := 1.0 - 0.17 * exp(-d * d / 0.05)
			var y := sin(t) * rr * (0.93 if sin(t) > 0.0 else 1.0)
			_unit.append(Vector2(cos(t) * rr * 1.05, y))
		# Triangles: centre (0) -> inner ring (1..N) -> outer ring (N+1..2N).
		for i in APPLE_N:
			var j := (i + 1) % APPLE_N
			for v in [0, 1 + i, 1 + j,
					1 + i, 1 + APPLE_N + i, 1 + APPLE_N + j,
					1 + i, 1 + APPLE_N + j, 1 + j]:
				_mesh_idx.push_back(v)
	return _unit


# An apple of radius r (px) at pos, shaded light at the upper left to dark at
# the rim. tones: RED / RIPE_GOLD / DULL. One triangle mesh for the body.
static func draw_apple(ci: CanvasItem, pos: Vector2, r: float, tones: Array, rot: float = 0.0,
		alpha: float = 1.0) -> void:
	var outline := _outline()
	var hc := Vector2(-0.34, -0.30)   # where the light hits
	var pts := PackedVector2Array([hc])
	var cols := PackedColorArray([Color(tones[0], alpha)])
	for p in outline:
		pts.append(hc.lerp(p, 0.6))
		cols.append(Color(tones[1], alpha))
	for p in outline:
		pts.append(p)
		cols.append(Color(tones[2], alpha))
	ci.draw_set_transform(pos, rot, Vector2(r, r))
	RenderingServer.canvas_item_add_triangle_array(ci.get_canvas_item(), _mesh_idx, pts, cols)
	# Dimple shadow, soft highlight, specular dot.
	ci.draw_set_transform(pos + Vector2(0.0, -0.80 * r).rotated(rot), rot, Vector2(0.22 * r, 0.08 * r))
	ci.draw_circle(Vector2.ZERO, 1.0, Color(tones[2], 0.45 * alpha))
	ci.draw_set_transform(pos + Vector2(-0.36 * r, -0.18 * r).rotated(rot), rot - 0.42,
		Vector2(0.12 * r, 0.24 * r))
	ci.draw_circle(Vector2.ZERO, 1.0, Color(1.0, 1.0, 1.0, 0.42 * alpha))
	ci.draw_set_transform(pos, rot, Vector2(r, r))
	ci.draw_circle(Vector2(-0.40, -0.36), 0.055, Color(1.0, 1.0, 1.0, 0.85 * alpha))
	# Stem and leaf (in apple units: the transform scales them by r).
	ci.draw_line(Vector2(0.0, -0.80), Vector2(0.10, -1.12), Color(Color("5B3A1E"), alpha), 0.08)
	var leaf := PackedVector2Array([Vector2(0.08, -1.0), Vector2(0.40, -1.30), Vector2(0.62, -1.18),
		Vector2(0.44, -0.98)])
	ci.draw_polygon(leaf, PackedColorArray([Color(LEAF, alpha), Color(LEAF, alpha),
		Color(LEAF_DARK, alpha), Color(LEAF_DARK, alpha)]))
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ── Stars, plates, cards ──────────────────────────────────────────────────────

static func star_points(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + PI * float(i) / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.46))
	return pts


static func draw_star(ci: CanvasItem, c: Vector2, r: float, filled: bool) -> void:
	var pts := star_points(c, r)
	if filled:
		var cols := PackedColorArray()
		for p in pts:
			cols.append(Color("FFE88E").lerp(Color("F4A614"), clampf((p.y - c.y + r) / (2.0 * r), 0.0, 1.0)))
		ci.draw_polygon(pts, cols)
	else:
		ci.draw_colored_polygon(pts, STAR_EMPTY)
	var closed := pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, GOLD_DARK if filled else Color("D5CAB6"), maxf(1.5, r * 0.07), true)
	if filled:
		ci.draw_set_transform(c + Vector2(-0.22 * r, -0.12 * r), -0.5, Vector2(0.14 * r, 0.08 * r))
		ci.draw_circle(Vector2.ZERO, 1.0, Color(1.0, 1.0, 1.0, 0.6))
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


static func _box(bg: Color, radius: int, border: Color = Color(0, 0, 0, 0), bw: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.anti_aliasing = true
	return sb


# Cream plate with a chunky base (score, level pills): the "game button" look.
static func draw_plate(ci: CanvasItem, rect: Rect2, radius: int = 18) -> void:
	ci.draw_style_box(_box(Color(0.16, 0.10, 0.04, 0.22), radius), rect.grow(3.0).grow_side(SIDE_BOTTOM, 8.0))
	ci.draw_style_box(_box(Color("CBB38A"), radius), rect.grow_side(SIDE_BOTTOM, 5.0))
	var top := _box(CREAM, radius, Color(1, 1, 1, 0.9), 2)
	ci.draw_style_box(top, rect)


# Big card (rest, complete, pause) over a dimmed game.
static func draw_card(ci: CanvasItem, rect: Rect2) -> void:
	ci.draw_style_box(_box(Color(0.08, 0.05, 0.0, 0.28), 34), rect.grow(10.0).grow_side(SIDE_BOTTOM, 14.0))
	ci.draw_style_box(_box(CARD_BASE, 32), rect.grow_side(SIDE_BOTTOM, 8.0))
	ci.draw_style_box(_box(Color("FBF6EA"), 32, Color(1, 1, 1, 0.95), 2), rect)


static func draw_pill(ci: CanvasItem, rect: Rect2, col: Color) -> void:
	ci.draw_style_box(_box(col, int(rect.size.y * 0.5)), rect)
