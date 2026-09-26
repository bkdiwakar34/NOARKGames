# Participant-screen art, "night fireflies" (chosen 2026-09-26 over the
# orchard): colours, smooth radial textures, glass panels, text. Circles are
# drawn as radial-gradient textures, not polygons, so their edges stay smooth
# at any size. Everything here only draws; the catch zone and the hit test stay
# in table mm (table_space.gd).
# Consumers use:  const Art := preload("res://app/clinic/game_art.gd")

const INK := Color("F4F7FF")
const INK_SOFT := Color(0.93, 0.95, 1.0, 0.62)
const NAVY := Color("0B1026")

# The firefly: pale core, yellow-green body, green rim.
const FF_CORE := Color("FDFFE8")
const FF_BODY := Color("EAF79A")
const FF_MID := Color("B9E356")
const FF_RIM := Color("86C23A")
const FF_GLOW := Color("D6FF8C")

# Grades (calibration points): colour and word, as in osu!'s 300 / 100 / 50.
const GRADE_COL: Array = [Color("C9D1E6"), Color("E8F0FF"), Color("9CF5B4"), Color("FFE27A")]
const GRADE_WORD: Array = ["", "Good", "Great", "Perfect!"]

const GOLD := Color("FFE27A")
const MISS := Color("8A93A8")

static var _bold: Font = null
static var _glow: GradientTexture2D = null
static var _disc: GradientTexture2D = null
static var _orb: GradientTexture2D = null


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


static func _radial(offsets: Array, colors: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t


# Soft light: bright centre fading to nothing.
static func glow() -> Texture2D:
	if _glow == null:
		_glow = _radial([0.0, 0.18, 0.5, 1.0],
			[Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.14), Color(1, 1, 1, 0)])
	return _glow


# Solid disc with a thin soft edge (the texture's radius is 1.0 of fill_to).
static func disc() -> Texture2D:
	if _disc == null:
		_disc = _radial([0.0, 0.955, 1.0], [Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	return _disc


# The firefly's body: its edge is the catch circle.
static func orb() -> Texture2D:
	if _orb == null:
		_orb = _radial([0.0, 0.38, 0.72, 0.955, 1.0],
			[FF_CORE, FF_BODY, FF_MID, FF_RIM, Color(FF_RIM, 0.0)])
	return _orb


# A texture centred on c, size (w, h) — w != h draws the ellipse the table
# circle becomes when the screen mapping scales x and y differently.
static func blit(ci: CanvasItem, tex: Texture2D, c: Vector2, size: Vector2, col: Color = Color.WHITE) -> void:
	ci.draw_texture_rect(tex, Rect2(c - size * 0.5, size), false, col)


# Text centred on pos (pos.y = the visual middle of the line); optional soft halo.
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		halo: Color = Color(0, 0, 0, 0)) -> void:
	var f := font()
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var base := pos + Vector2(-w * 0.5, f.get_ascent(size) * 0.5 - f.get_descent(size) * 0.3)
	if halo.a > 0.0:
		ci.draw_string_outline(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(4, size / 4), halo)
	ci.draw_string(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func text_width(s: String, size: int) -> float:
	return font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


static func _box(bg: Color, radius: int, border: Color = Color(0, 0, 0, 0), bw: int = 0,
		shadow: float = 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.anti_aliasing = true
	if shadow > 0.0:
		sb.shadow_size = int(shadow)
		sb.shadow_color = Color(0.0, 0.0, 0.05, 0.45)
	return sb


# Frosted-glass pill / panel (HUD).
static func draw_glass(ci: CanvasItem, rect: Rect2, radius: int = 16) -> void:
	ci.draw_style_box(_box(Color(1, 1, 1, 0.07), radius, Color(1, 1, 1, 0.13), 1), rect)


# Big card (rest, complete, pause): deep night glass with a soft shadow.
static func draw_card(ci: CanvasItem, rect: Rect2) -> void:
	ci.draw_style_box(_box(Color(0.06, 0.09, 0.19, 0.9), 28, Color(1, 1, 1, 0.14), 1, 34.0), rect)


static func draw_pill(ci: CanvasItem, rect: Rect2, col: Color) -> void:
	ci.draw_style_box(_box(col, int(rect.size.y * 0.5)), rect)


static func star_points(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + PI * float(i) / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.46))
	return pts


# A star: gold with a glow when earned, a faint outline when not.
static func draw_star(ci: CanvasItem, c: Vector2, r: float, filled: bool) -> void:
	var pts := star_points(c, r)
	var closed := pts.duplicate()
	closed.append(pts[0])
	if filled:
		blit(ci, glow(), c, Vector2(r, r) * 4.2, Color(GOLD, 0.35))
		var cols := PackedColorArray()
		for p in pts:
			cols.append(Color("FFF6C8").lerp(Color("FFC23D"), clampf((p.y - c.y + r) / (2.0 * r), 0.0, 1.0)))
		ci.draw_polygon(pts, cols)
		ci.draw_polyline(closed, Color("FFB020"), 1.5, true)
	else:
		ci.draw_colored_polygon(pts, Color(1, 1, 1, 0.06))
		ci.draw_polyline(closed, Color(1, 1, 1, 0.28), 1.5, true)
