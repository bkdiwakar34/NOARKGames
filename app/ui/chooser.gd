extends Control

const UITheme := preload("res://app/ui/ui_theme.gd")

# Patient-facing game chooser (docs/v1_plan.md §3, screen 2).
# Keyboard maps one-to-one to the future GPIO arcade buttons:
#   Left/Right = "next" button      Enter = "play" button
# (ESC inside a game = the future hold-play-to-exit.)
# F10 = researcher installer, as everywhere.

const GAMES: Array = [
	{"name": "Apple Catch", "scene": "res://app/games/reach/random_reach.tscn"},
]

var _selected: int = 0
var _cards: Array = []
var _style_normal: StyleBoxFlat
var _style_selected: StyleBoxFlat


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport_rect().size

	_style_normal = _card_style(Color(0.99, 0.97, 0.93, 0.95), Color(0.75, 0.70, 0.62), 2)
	_style_selected = _card_style(Color(1.0, 0.99, 0.95, 1.0), UITheme.ACCENT, 6)

	var title := Label.new()
	title.text = "Choose your game"
	title.add_theme_font_size_override("font_size", UITheme.FONT_HUGE)
	title.add_theme_color_override("font_color", UITheme.TEXT_DARK)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(vp.x, 90.0)
	title.position = Vector2(0.0, vp.y * 0.10)
	add_child(title)

	# Game cards, centered row
	var card_size := Vector2(360.0, 420.0)
	var gap := 48.0
	var row_w := GAMES.size() * card_size.x + (GAMES.size() - 1) * gap
	for i in GAMES.size():
		var card := Panel.new()
		card.size = card_size
		card.position = Vector2(
			(vp.x - row_w) * 0.5 + i * (card_size.x + gap),
			vp.y * 0.30)
		add_child(card)
		_cards.append(card)

		# Code-drawn game icon (an apple), per the no-sprite rule
		var icon := Control.new()
		icon.position = Vector2(card_size.x * 0.5, 150.0)
		card.add_child(icon)
		icon.draw.connect(func():
			icon.draw_circle(Vector2.ZERO, 95.0, Color(0.82, 0.18, 0.15))
			icon.draw_circle(Vector2(-30.0, -35.0), 24.0, Color(1.0, 1.0, 1.0, 0.25))
			icon.draw_rect(Rect2(-6.0, -130.0, 12.0, 40.0), Color(0.35, 0.22, 0.10))
			icon.draw_circle(Vector2(26.0, -112.0), 17.0, Color(0.30, 0.62, 0.25)))

		var name_lbl := Label.new()
		name_lbl.text = GAMES[i]["name"]
		name_lbl.add_theme_font_size_override("font_size", 40)
		name_lbl.add_theme_color_override("font_color", UITheme.TEXT_DARK)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.custom_minimum_size = Vector2(card_size.x, 60.0)
		name_lbl.position = Vector2(0.0, 290.0)
		card.add_child(name_lbl)

	# Hint bar (mirrors the future physical buttons)
	var hint := Label.new()
	hint.text = "◀ ▶  choose          ⏎  play"
	hint.add_theme_font_size_override("font_size", UITheme.FONT_LARGE)
	hint.add_theme_color_override("font_color", UITheme.TEXT_SOFT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.custom_minimum_size = Vector2(vp.x, 50.0)
	hint.position = Vector2(0.0, vp.y - 90.0)
	add_child(hint)

	_update_selection()


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
	var size := get_rect().size
	for i in 24:
		var t := float(i) / 24.0
		draw_rect(Rect2(0.0, t * size.y, size.x, size.y / 24.0 + 1.0),
			UITheme.BG_TOP.lerp(UITheme.BG_BOTTOM, t))
