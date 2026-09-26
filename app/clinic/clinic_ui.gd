# Plain building blocks for the operator screens (Home, Registration,
# Settings). The mockup's dashboard look comes with the visuals package; until
# then these keep sizes readable and the screens consistent.
# Consumers use:  const UI := preload("res://app/clinic/clinic_ui.gd")

const BG := Color("F5F4F0")
const CARD := Color("FFFFFF")
const LINE := Color("E6E3DC")
const INK := Color("191A17")
const MUTED := Color("5F625B")
const ACCENT := Color("C0392B")
const GOOD := Color("2E6B3F")
const WARN := Color("9A5B0B")

const TEXT := 18
const TITLE := 28


# Background + margins + a vertical stack that fills the screen.
static func page(parent: Control) -> VBoxContainer:
	parent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	parent.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	margin.add_child(v)
	return v


static func label(text: String, size: int = TEXT, col: Color = INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


static func button(text: String, on_press: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 44.0)
	b.add_theme_font_size_override("font_size", TEXT)
	var normal := _box(ACCENT if primary else CARD, LINE if not primary else ACCENT)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", _box(ACCENT.darkened(0.15) if primary else Color("F1EFEA"),
		LINE if not primary else ACCENT))
	b.add_theme_stylebox_override("pressed", normal)
	b.add_theme_color_override("font_color", Color.WHITE if primary else INK)
	b.add_theme_color_override("font_hover_color", Color.WHITE if primary else INK)
	b.pressed.connect(on_press)
	return b


# A white rounded card holding a vertical stack.
static func card(parent: Control) -> VBoxContainer:
	var panel := PanelContainer.new()
	var sb := _box(CARD, LINE)
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	parent.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	return v


static func row(parent: Control, gap: int = 12) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", gap)
	parent.add_child(h)
	return h


static func spacer(parent: Control) -> void:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(s)


static func field(text: String = "", width: float = 220.0) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size = Vector2(width, 44.0)
	e.add_theme_font_size_override("font_size", TEXT)
	return e


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	return sb
