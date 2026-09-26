# Operator-screen look (Home, Registration, Settings): the mockup's clean
# dashboard — warm-grey ground, white rounded cards, one red accent — built as
# a Theme plus a few helpers. Nunito from app/assets/fonts (loaded at runtime,
# like app/ui/ui_theme.gd does; no editor import step).
# Consumers use:  const UI := preload("res://app/clinic/clinic_ui.gd")
# and set `theme = UI.theme()` on their root Control.

const BG := Color("F5F4F0")
const CARD := Color("FFFFFF")
const SOFT := Color("F6F4EE")      # info boxes, table header
const LINE := Color("E6E3DC")
const INPUT_LINE := Color("D9D5CC")
const INK := Color("191A17")
const INK2 := Color("3B3D38")
const MUTED := Color("5F625B")
const ACCENT := Color("C0392B")
const ACCENT_DARK := Color("8E2A1F")
const GOOD := Color("2E6B3F")
const GOOD_BG := Color("EEF5EF")
const WARN := Color("7A4A0B")
const WARN_BG := Color("FBF1E0")
const WARN_DOT := Color("D98E1F")

const TEXT := 17
const TITLE := 28

static var _theme: Theme = null
static var _bold: Font = null


# ── Theme ─────────────────────────────────────────────────────────────────────

static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	var regular := _font("res://app/assets/fonts/Nunito-Regular.ttf")
	_bold = _font("res://app/assets/fonts/Nunito-ExtraBold.ttf")
	if regular:
		t.default_font = regular
	t.default_font_size = TEXT

	t.set_color("font_color", "Label", INK)

	t.set_stylebox("normal", "LineEdit", _box(CARD, INPUT_LINE, 10, 1, 14.0))
	t.set_stylebox("focus", "LineEdit", _box(Color(0, 0, 0, 0), ACCENT, 10, 2, 14.0))
	t.set_stylebox("read_only", "LineEdit", _box(Color("F3F1EC"), INPUT_LINE, 10, 1, 14.0))
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_uneditable_color", "LineEdit", MUTED)
	t.set_color("font_placeholder_color", "LineEdit", Color(MUTED, 0.7))
	t.set_color("caret_color", "LineEdit", INK)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.25))

	for cls in ["Button", "OptionButton"]:
		t.set_stylebox("normal", cls, _box(CARD, INPUT_LINE, 10, 1, 16.0))
		t.set_stylebox("hover", cls, _box(SOFT, INPUT_LINE, 10, 1, 16.0))
		t.set_stylebox("pressed", cls, _box(Color("EFECE6"), INPUT_LINE, 10, 1, 16.0))
		t.set_stylebox("disabled", cls, _box(Color("F3F1EC"), LINE, 10, 1, 16.0))
		t.set_stylebox("focus", cls, _box(Color(0, 0, 0, 0), Color(ACCENT, 0.6), 10, 2, 16.0))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
				"font_hover_pressed_color"]:
			t.set_color(c, cls, INK2)
		t.set_color("font_disabled_color", cls, Color(MUTED, 0.7))

	for cls in ["CheckBox", "CheckButton"]:
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
				"font_hover_pressed_color"]:
			t.set_color(c, cls, INK)
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())

	t.set_stylebox("panel", "PopupMenu", _box(CARD, LINE, 10, 1, 8.0))
	t.set_stylebox("hover", "PopupMenu", _box(SOFT, SOFT, 6, 0, 8.0))
	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", INK)
	t.set_stylebox("panel", "AcceptDialog", _box(CARD, LINE, 12, 1, 20.0))

	var sep := StyleBoxLine.new()
	sep.color = LINE
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	_theme = t
	return t


static func _font(path: String) -> Font:
	if not FileAccess.file_exists(path):
		return null
	var f := FontFile.new()
	return f if f.load_dynamic_font(path) == OK else null


static func _box(bg: Color, border: Color, radius: int = 10, border_w: int = 1,
		pad_x: float = 16.0, pad_y: float = 8.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# ── Page frame ────────────────────────────────────────────────────────────────

# Warm-grey page with the white top bar (apple mark, NOARK, a subtitle) and a
# padded content area. Returns {bar: HBox for the bar's right side, content: VBox}.
static func page(root: Control, subtitle: String) -> Dictionary:
	root.theme = theme()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 0)
	root.add_child(outer)

	var bar_panel := PanelContainer.new()
	var bar_box := _box(CARD, LINE, 0, 0, 32.0, 10.0)
	bar_box.border_width_bottom = 1
	bar_panel.add_theme_stylebox_override("panel", bar_box)
	outer.add_child(bar_panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar_panel.add_child(bar)
	bar.add_child(_apple_mark())
	bar.add_child(label("NOARK", 19, INK, true))
	bar.add_child(label(subtitle, 17, MUTED))
	spacer(bar)

	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 30)
	outer.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	margin.add_child(content)
	return {"bar": bar, "content": content}


static func _apple_mark() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(30.0, 30.0)
	c.draw.connect(func():
		c.draw_circle(Vector2(15.0, 17.0), 11.0, ACCENT)
		c.draw_set_transform(Vector2(20.0, 6.0), -0.6, Vector2(1.0, 0.5))
		c.draw_circle(Vector2.ZERO, 6.0, GOOD)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE))
	return c


# ── Pieces ────────────────────────────────────────────────────────────────────

static func label(text: String, size: int = TEXT, col: Color = INK, bold: bool = false,
		wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if bold and _bold:
		l.add_theme_font_override("font", _bold)
	if wrap:
		# Wrapping labels take the width they are given instead of widening the page.
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size = Vector2(10.0, 0.0)
	return l


static func caption(text: String) -> Label:
	return label(text.to_upper(), 13, Color("6B6E66"), true)


# kind: "primary" (red), "secondary" (white, theme), "ghost" (no box).
static func button(text: String, on_press: Callable, kind: String = "secondary") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 44.0)
	if _bold:
		b.add_theme_font_override("font", _bold)
	if kind == "primary":
		b.add_theme_stylebox_override("normal", _box(ACCENT, ACCENT, 10, 1, 18.0))
		b.add_theme_stylebox_override("hover", _box(ACCENT.darkened(0.12), ACCENT, 10, 1, 18.0))
		b.add_theme_stylebox_override("pressed", _box(ACCENT_DARK, ACCENT_DARK, 10, 1, 18.0))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, Color.WHITE)
	elif kind == "ghost":
		var empty := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 10, 0, 12.0)
		for s in ["normal", "pressed", "focus"]:
			b.add_theme_stylebox_override(s, empty)
		b.add_theme_stylebox_override("hover", _box(SOFT, SOFT, 10, 0, 12.0))
	b.pressed.connect(on_press)
	return b


# A white rounded card holding a vertical stack.
static func card(parent: Control, pad: float = 22.0, gap: int = 12) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(CARD, LINE, 16, 1, pad, pad * 0.8))
	parent.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", gap)
	panel.add_child(v)
	return v


# A soft box for notes (e.g. "level order is assigned for you").
static func note_box(parent: Control, text: String) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(SOFT, Color("ECE8DF"), 12, 1, 18.0, 14.0))
	parent.add_child(panel)
	panel.add_child(label(text, 15, MUTED, false, true))


# Rounded pill with a status dot: tracker, protocol, today's state.
static func chip(text: String, bg: Color, fg: Color, dot: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(bg, bg, 999, 0, 12.0, 5.0))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	panel.add_child(h)
	if dot.a > 0.0:
		var d := Panel.new()
		d.custom_minimum_size = Vector2(8.0, 8.0)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.add_theme_stylebox_override("panel", _box(dot, dot, 4, 0, 0.0, 0.0))
		h.add_child(d)
	h.add_child(label(text, 14, fg, true))
	return panel


# Small rounded bar (study-day progress).
static func bar_piece(col: Color, w: float = 30.0) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(w, 8.0)
	p.add_theme_stylebox_override("panel", _box(col, col, 4, 0, 0.0, 0.0))
	return p


# Segmented choice (gender, hand): returns the HBox; on_pick(option) on click.
static func segmented(options: Array, on_pick: Callable) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color("F1EFEA"), Color("F1EFEA"), 12, 0, 4.0, 4.0))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	panel.add_child(h)
	var group := ButtonGroup.new()
	for opt in options:
		var b := Button.new()
		b.text = opt
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0.0, 38.0)
		var off := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 9, 0, 12.0, 4.0)
		var on := _box(CARD, Color(0, 0, 0, 0.08), 9, 1, 12.0, 4.0)
		b.add_theme_stylebox_override("normal", off)
		b.add_theme_stylebox_override("hover", off)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
		b.add_theme_color_override("font_color", MUTED)
		b.add_theme_color_override("font_pressed_color", INK)
		b.add_theme_color_override("font_hover_pressed_color", INK)
		if _bold:
			b.add_theme_font_override("font", _bold)
		b.pressed.connect(func(): on_pick.call(opt))
		h.add_child(b)
	return panel


static func field(text: String = "", width: float = 220.0) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size = Vector2(width, 46.0)
	return e


static func row(parent: Control, gap: int = 12) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", gap)
	parent.add_child(h)
	return h


static func spacer(parent: Control) -> void:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(s)


static func line(parent: Control) -> void:
	parent.add_child(HSeparator.new())
