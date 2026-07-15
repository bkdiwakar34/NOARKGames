extends Control

const UITheme := preload("res://app/ui/ui_theme.gd")

# Patient-facing game chooser (docs/v1_plan.md §3, screen 2).
# Keyboard maps one-to-one to the future GPIO arcade buttons:
#   Left/Right = "next" button      Enter = "play" button
# (ESC inside a game = the future hold-play-to-exit.)
# F10 = researcher installer, as everywhere.

const GAMES: Array = [
	# Display name only — logs/CSV filenames keep the internal name RandomReach
	# for data continuity across the study.
	{"name": "Apple Harvest", "scene": "res://app/games/reach/random_reach.tscn"},
]

var _selected: int = 0
var _cards: Array = []
var _style_normal: StyleBoxFlat
var _style_selected: StyleBoxFlat


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport_rect().size

	_style_normal = UITheme.card_style(Color(0.75, 0.70, 0.62), 2)
	_style_selected = UITheme.card_style(UITheme.APPLE_RED, 6)

	var title := Label.new()
	title.text = "Choose your game"
	title.add_theme_font_size_override("font_size", UITheme.FONT_HUGE)
	title.add_theme_color_override("font_color", UITheme.TEXT_DARK)
	UITheme.make_bold(title)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(vp.x, 90.0)
	title.position = Vector2(0.0, vp.y * 0.10)
	add_child(title)

	# Game cards, centered row — sized so several games fit on one screen
	var card_size := Vector2(280.0, 330.0)
	var gap := 44.0
	var row_w := GAMES.size() * card_size.x + (GAMES.size() - 1) * gap
	for i in GAMES.size():
		var card := Panel.new()
		card.size = card_size
		card.position = Vector2(
			(vp.x - row_w) * 0.5 + i * (card_size.x + gap),
			vp.y * 0.30)
		add_child(card)
		_cards.append(card)

		# Code-drawn game icon — the same minimal dot-with-leaf as in play
		var icon := Control.new()
		icon.position = Vector2(card_size.x * 0.5, 118.0)
		card.add_child(icon)
		icon.draw.connect(func():
			icon.draw_circle(Vector2.ZERO, 65.0, UITheme.APPLE_RED)
			icon.draw_set_transform(Vector2(28.0, -54.0), -0.6, Vector2(1.0, 0.5))
			icon.draw_circle(Vector2.ZERO, 17.0, UITheme.LEAF)
			icon.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE))

		var name_lbl := Label.new()
		name_lbl.text = GAMES[i]["name"]
		name_lbl.add_theme_font_size_override("font_size", 30)
		name_lbl.add_theme_color_override("font_color", UITheme.TEXT_DARK)
		UITheme.make_bold(name_lbl)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.custom_minimum_size = Vector2(card_size.x, 50.0)
		name_lbl.position = Vector2(0.0, 225.0)
		card.add_child(name_lbl)

	# Hint bar: the two future physical buttons as colored circles — the same
	# colors will mark the real buttons on the table.
	var hint_panel := PanelContainer.new()
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(1.0, 0.99, 0.97, 0.72)
	hsb.set_corner_radius_all(99)
	hsb.content_margin_left = 30.0
	hsb.content_margin_right = 30.0
	hsb.content_margin_top = 10.0
	hsb.content_margin_bottom = 10.0
	hint_panel.add_theme_stylebox_override("panel", hsb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 40)
	hint_panel.add_child(hb)
	hb.add_child(_hint_item("◀ ▶", Color("5B8DB8"), "choose"))
	hb.add_child(_hint_item("▶", UITheme.LEAF, "play"))
	add_child(hint_panel)
	await get_tree().process_frame
	hint_panel.position = Vector2((vp.x - hint_panel.size.x) * 0.5, vp.y - 96.0)

	_update_selection()


func _hint_item(symbol: String, dot_color: Color, word: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var dot := PanelContainer.new()
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = dot_color
	dsb.set_corner_radius_all(99)
	dsb.content_margin_left = 12.0
	dsb.content_margin_right = 12.0
	dsb.content_margin_top = 6.0
	dsb.content_margin_bottom = 6.0
	dot.add_theme_stylebox_override("panel", dsb)
	var sym := Label.new()
	sym.text = symbol
	sym.add_theme_font_size_override("font_size", 18)
	sym.add_theme_color_override("font_color", Color.WHITE)
	dot.add_child(sym)
	h.add_child(dot)
	var lbl := Label.new()
	lbl.text = word
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_LARGE)
	lbl.add_theme_color_override("font_color", UITheme.TEXT_SOFT)
	h.add_child(lbl)
	return h


func _card_style(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(26)
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.shadow_size = 14
	sb.shadow_color = Color(0.15, 0.10, 0.05, 0.22)
	sb.shadow_offset = Vector2(0.0, 5.0)
	return sb


func _update_selection() -> void:
	for i in _cards.size():
		_cards[i].add_theme_stylebox_override("panel",
			_style_selected if i == _selected else _style_normal)
		_cards[i].scale = Vector2.ONE * (1.04 if i == _selected else 1.0)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F10:
			get_tree().change_scene_to_file("res://app/installer/installer.tscn")
		KEY_RIGHT:
			_selected = (_selected + 1) % GAMES.size()
			_update_selection()
		KEY_LEFT:
			_selected = (_selected - 1 + GAMES.size()) % GAMES.size()
			_update_selection()
		KEY_ENTER, KEY_KP_ENTER:
			_start_selected()


func _start_selected() -> void:
	# Same session bootstrap game_select's play button performs: today's
	# scheduled rate (falls back inside get_todays_rate), then the game.
	var rate: float = PatientDB.get_todays_rate(PatientDB.current_patient_id)
	if rate <= 0.0:
		rate = 0.8
	if not AdaptiveManager.is_running:
		AdaptiveManager.start_session(rate)
	get_tree().change_scene_to_file(GAMES[_selected]["scene"])


func _draw() -> void:
	UITheme.draw_orchard(self, get_rect().size)
