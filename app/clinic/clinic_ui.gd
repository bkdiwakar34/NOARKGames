# Operator-screen look (Home, Registration, Settings): the mockup's clean
# dashboard — warm-grey ground, white rounded cards, one red accent — built as
# a Theme plus a few helpers. Manrope, as in the mockup (one variable font
# file in app/assets/fonts, loaded at runtime like app/ui/ui_theme.gd does, no
# editor import step), else Nunito. Sizes here are the mockup's x 0.9 (they
# were set on the project's 1152 x 648 canvas against the 1280 x 720 mockup).
# Consumers use:  const UI := preload("res://app/clinic/clinic_ui.gd")
# and set `theme = UI.theme()` on their root Control.
#
# Canvas: the project lays out on 1152 x 648, stretched 1.67x to the 1920 x 1080
# screen — everything came out 1.5x the mockup and soft. The clinic app lays out
# on CANVAS instead: 1.11x stretch, so those sizes land at the mockup's own size.
# The installer tools (4-corner mapping, validation recorder) still assume the
# project's canvas, so Settings switches back while one is open, and the
# 4-corner mapping stays in project-canvas pixels (table_space.gd rescales it).
const CANVAS := Vector2i(1728, 972)

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

const TEXT := 15
const TITLE := 25

static var _theme: Theme = null
static var _bold: Font = null


# ── Theme ─────────────────────────────────────────────────────────────────────

static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	var regular: Font = null
	var manrope := _font("res://app/assets/fonts/Manrope-Variable.ttf")
	if manrope:
		regular = _weight(manrope, 500)
		_bold = _weight(manrope, 800)
	else:
		regular = _font("res://app/assets/fonts/Nunito-Regular.ttf")
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


# ── Canvas ────────────────────────────────────────────────────────────────────

static func project_canvas() -> Vector2i:
	return Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")),
		int(ProjectSettings.get_setting("display/window/size/viewport_height")))


# clinic = true: the clinic app's CANVAS; false: the project's (installer tools).
static func use_canvas(clinic: bool) -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	root.content_scale_size = CANVAS if clinic else project_canvas()


static func _font(path: String) -> Font:
	if not FileAccess.file_exists(path):
		return null
	var f := FontFile.new()
	return f if f.load_dynamic_font(path) == OK else null


# One weight of a variable font.
static func _weight(base: Font, w: int) -> Font:
	var v := FontVariation.new()
	v.base_font = base
	v.variation_opentype = {"weight": w}
	return v


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
	var bar_box := _box(CARD, LINE, 0, 0, 29.0, 6.0)
	bar_box.border_width_bottom = 1
	bar_panel.custom_minimum_size = Vector2(0.0, 58.0)
	bar_panel.add_theme_stylebox_override("panel", bar_box)
	outer.add_child(bar_panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 9)
	bar.alignment = BoxContainer.ALIGNMENT_BEGIN
	bar_panel.add_child(bar)
	bar.add_child(_apple_mark())
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 7)
	name_row.add_child(label("NOARK", 16, INK, true))
	name_row.add_child(label(subtitle, 15, MUTED))
	bar.add_child(name_row)
	spacer(bar)

	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 29)
	margin.add_theme_constant_override("margin_right", 29)
	margin.add_theme_constant_override("margin_top", 25)
	margin.add_theme_constant_override("margin_bottom", 25)
	outer.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)
	return {"bar": bar, "content": content}


static func _apple_mark() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(27.0, 27.0)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.draw.connect(func():
		c.draw_circle(Vector2(13.5, 15.0), 10.0, ACCENT, true, -1.0, true)
		c.draw_set_transform(Vector2(18.0, 5.5), -0.6, Vector2(1.0, 0.5))
		c.draw_circle(Vector2.ZERO, 5.5, GOOD, true, -1.0, true)
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
	return label(text.to_upper(), 11, Color("6B6E66"), true)


# kind: "primary" (red), "secondary" (white, theme), "outline" (white, red
# text and a light red border: the table's other rows), "ghost" (no box).
static func button(text: String, on_press: Callable, kind: String = "secondary") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 40.0)
	b.add_theme_font_size_override("font_size", 14)
	if _bold:
		b.add_theme_font_override("font", _bold)
	if kind == "primary":
		b.add_theme_stylebox_override("normal", _box(ACCENT, ACCENT, 10, 1, 16.0))
		b.add_theme_stylebox_override("hover", _box(ACCENT.darkened(0.12), ACCENT, 10, 1, 16.0))
		b.add_theme_stylebox_override("pressed", _box(ACCENT_DARK, ACCENT_DARK, 10, 1, 16.0))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, Color.WHITE)
	elif kind == "outline":
		b.add_theme_stylebox_override("normal", _box(CARD, Color("E3C2BC"), 10, 1, 16.0))
		b.add_theme_stylebox_override("hover", _box(Color("FFF8F6"), Color("E3C2BC"), 10, 1, 16.0))
		b.add_theme_stylebox_override("pressed", _box(Color("FBEDEA"), Color("E3C2BC"), 10, 1, 16.0))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, ACCENT_DARK)
	elif kind == "ghost":
		var empty := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 10, 0, 12.0)
		for s in ["normal", "pressed", "focus"]:
			b.add_theme_stylebox_override(s, empty)
		b.add_theme_stylebox_override("hover", _box(SOFT, SOFT, 10, 0, 12.0))
	b.pressed.connect(on_press)
	return b


# Square icon button (the mockup's Settings "sliders" icon).
static func sliders_button(on_press: Callable, tip: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(40.0, 40.0)
	b.tooltip_text = tip
	b.pressed.connect(on_press)
	b.draw.connect(func():
		var col := INK2
		for i in 3:
			var y := 13.0 + 7.0 * float(i)
			b.draw_line(Vector2(11.0, y), Vector2(29.0, y), col, 1.8, true)
			var kx: float = [16.0, 23.0, 14.0][i]
			b.draw_circle(Vector2(kx, y), 3.2, CARD, true, -1.0, true)
			b.draw_circle(Vector2(kx, y), 3.2, col, false, 1.8, true))
	return b


# The mockup's switch: a green track when on. Returns a toggle Button.
static func switch(on: bool, on_toggle: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = on
	b.custom_minimum_size = Vector2(46.0, 26.0)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.focus_mode = Control.FOCUS_NONE
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, empty)
	b.draw.connect(func():
		var lit: bool = b.button_pressed
		var col: Color = GOOD if lit else Color("CFCAC0")
		var track := _box(col, col, 13, 0, 0.0, 0.0)
		b.draw_style_box(track, Rect2(Vector2.ZERO, Vector2(46.0, 26.0)))
		var x := 33.0 if lit else 13.0
		b.draw_circle(Vector2(x, 14.0), 10.5, Color(0, 0, 0, 0.12), true, -1.0, true)
		b.draw_circle(Vector2(x, 13.0), 10.0, Color.WHITE, true, -1.0, true))
	b.toggled.connect(func(v: bool):
		b.queue_redraw()
		on_toggle.call(v))
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
	panel.add_theme_stylebox_override("panel", _box(SOFT, Color("ECE8DF"), 12, 1, 16.0, 12.0))
	parent.add_child(panel)
	panel.add_child(label(text, 13, MUTED, false, true))


# Rounded pill with a status dot: tracker, protocol, today's state.
static func chip(text: String, bg: Color, fg: Color, dot: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(bg, bg, 999, 0, 11.0, 5.0))
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 7)
	panel.add_child(h)
	if dot.a > 0.0:
		var d := Panel.new()
		d.custom_minimum_size = Vector2(7.0, 7.0)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.add_theme_stylebox_override("panel", _box(dot, dot, 4, 0, 0.0, 0.0))
		h.add_child(d)
	h.add_child(label(text, 12, fg, true))
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
		b.custom_minimum_size = Vector2(0.0, 34.0)
		b.add_theme_font_size_override("font_size", 13)
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
	e.custom_minimum_size = Vector2(width, 41.0)
	e.add_theme_font_size_override("font_size", 14)
	return e


# A dimmed layer over the screen with a centred white card (the Resume
# prompt). Returns {layer: the Control to free, card: VBox to fill}.
static func modal(root: Control, width: float) -> Dictionary:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(layer)
	var dim := ColorRect.new()
	dim.color = Color(0.098, 0.102, 0.09, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(centre)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0.0)
	var sb := _box(CARD, CARD, 18, 0, 27.0, 25.0)
	sb.shadow_size = 30
	sb.shadow_color = Color(0, 0, 0, 0.25)
	panel.add_theme_stylebox_override("panel", sb)
	centre.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	panel.add_child(v)
	return {"layer": layer, "card": v}


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
