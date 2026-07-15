# v1 design system — "Calm Orchard" (mockup approved 2026-07-15).
# Consumers use:  const UITheme := preload("res://app/ui/ui_theme.gd")
# (deliberately not class_name: that needs an editor scan, and the Pi runs CLI-only.)
# Every screen reads colors, fonts and the shared background from here so the
# whole look changes in one place. Meaning is never carried by color alone:
# catch/miss also differ in shape and sound.

# ── Palette ───────────────────────────────────────────────────────────────────
const SKY_TOP     := Color("FFF3E2")   # dawn sky gradient
const SKY_MID     := Color("FFE7CD")
const SKY_LOW     := Color("FFDDBD")
const HILL        := Color("B7CFA4")   # sage hills on the horizon
const HILL_DEEP   := Color("9DBB8A")
const INK         := Color("4A3428")   # warm brown — all text, never black
const INK_SOFT    := Color(0.29, 0.20, 0.16, 0.62)
const APPLE_RED   := Color("D9483B")   # the single accent
const APPLE_DARK  := Color("B93A2F")
const APPLE_LIGHT := Color(0.93, 0.48, 0.42, 0.55)
const LEAF        := Color("5FA052")   # success: bright, fast, upward
const GOLD        := Color("F2B33D")   # stars + time ring
const MISS        := Color("9A938B")   # miss: soft, brief, downward
const CARD        := Color("FFFDF7")   # cream cards
const LASER       := Color(0.95, 0.15, 0.10)   # striker + trail: hot laser red (GoodNotes-style)
const PAPER       := Color("F6EFE4")   # installer workbench background

# Aliases kept for existing call sites
const BG_TOP      := SKY_TOP
const BG_BOTTOM   := SKY_LOW
const ACCENT      := APPLE_RED
const TEXT_DARK   := INK
const TEXT_SOFT   := INK_SOFT
const SUCCESS     := LEAF
const STAR_FILLED := GOLD
const STAR_EMPTY  := Color(0.29, 0.20, 0.16, 0.18)

const FONT_HUGE   := 64   # headings / big numbers
const FONT_LARGE  := 28   # everything else patient-facing

# ── Fonts (drop-in like audio: files appear → they're used, else default) ────
# Put Nunito-Regular.ttf and Nunito-ExtraBold.ttf in app/assets/fonts/
# (see the README there). Loaded at runtime — no editor import step needed.
static var _fonts_ready := false
static var font_regular: Font = null
static var font_bold: Font = null

static func ensure_fonts() -> void:
	if _fonts_ready:
		return
	_fonts_ready = true
	font_regular = _load_font("res://app/assets/fonts/Nunito-Regular.ttf")
	font_bold = _load_font("res://app/assets/fonts/Nunito-ExtraBold.ttf")

static func _load_font(path: String) -> Font:
	if not FileAccess.file_exists(path):
		return null
	var f := FontFile.new()
	if f.load_dynamic_font(path) != OK:
		return null
	return f

# Call once at startup: makes the regular face the default for every control.
static func apply_global_font() -> void:
	ensure_fonts()
	if font_regular:
		ThemeDB.fallback_font = font_regular

static func make_bold(l: Label) -> void:
	ensure_fonts()
	if font_bold:
		l.add_theme_font_override("font", font_bold)

# ── Shared orchard background (chooser + game draw this) ─────────────────────
static func draw_orchard(ci: CanvasItem, size: Vector2) -> void:
	for i in 24:
		var t := float(i) / 24.0
		var c := SKY_TOP.lerp(SKY_MID, t / 0.55) if t < 0.55 \
			else SKY_MID.lerp(SKY_LOW, (t - 0.55) / 0.45)
		ci.draw_rect(Rect2(0.0, t * size.y, size.x, size.y / 24.0 + 1.0), c)
	# soft morning sun, top-left, away from the play area
	ci.draw_circle(Vector2(size.x * 0.10, size.y * 0.14), size.x * 0.055, Color(1.0, 0.93, 0.75, 0.35))
	ci.draw_circle(Vector2(size.x * 0.10, size.y * 0.14), size.x * 0.034, Color(1.0, 0.95, 0.80, 0.65))
	_draw_hill(ci, size, size.y * 0.905, size.y * 0.055, 0.9, 1.2, HILL)
	_draw_hill(ci, size, size.y * 0.945, size.y * 0.040, 1.3, 4.0, HILL_DEEP)

static func _draw_hill(ci: CanvasItem, size: Vector2, base_y: float, amp: float,
		cycles: float, phase: float, col: Color) -> void:
	var pts := PackedVector2Array()
	var n := 32
	for i in n + 1:
		var x := size.x * float(i) / float(n)
		pts.append(Vector2(x, base_y - amp * (1.0 + sin(TAU * cycles * x / size.x + phase)) * 0.5))
	pts.append(Vector2(size.x, size.y))
	pts.append(Vector2(0.0, size.y))
	ci.draw_colored_polygon(pts, col)

# ── Card / pill styles ────────────────────────────────────────────────────────
static func card_style(border_col: Color = Color(0, 0, 0, 0), border_w: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD
	sb.set_corner_radius_all(26)
	sb.shadow_size = 16
	sb.shadow_color = Color(0.15, 0.10, 0.05, 0.25)
	sb.shadow_offset = Vector2(0.0, 6.0)
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border_col
	return sb

static func button_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb
