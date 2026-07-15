extends CanvasLayer

const UITheme := preload("res://app/ui/ui_theme.gd")

# Trial-end star screen: five stars, no text — the stars are the message
# (near-zero-text rule, docs/v1_plan.md §3). Fill count = catch ratio × 5,
# deliberately near-constant by design (decisions log in v1_plan.md).

const STAR_COUNT := 5
const STAR_BEAT  := 0.38  # seconds between stars filling

var _stars: Array = []
var _fill_tween: Tween

func _ready() -> void:
	var vp := get_viewport().get_visible_rect().size
	var card_size := Vector2(680.0, 240.0)
	var card_pos := vp * 0.5 - card_size * 0.5

	# Soft dim over the game
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.22)
	dim.size = vp
	dim.position = Vector2.ZERO
	add_child(dim)

	# Rounded card with drop shadow
	var card := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.995, 0.975, 0.935, 0.98)
	sb.set_corner_radius_all(28)
	sb.shadow_size = 18
	sb.shadow_color = Color(0.15, 0.10, 0.05, 0.28)
	sb.shadow_offset = Vector2(0.0, 6.0)
	card.add_theme_stylebox_override("panel", sb)
	card.size = card_size
	card.position = card_pos
	add_child(card)

	# Star row, centered in the card
	var star_cell := 122.0
	var star_h := 160.0
	var row_width := star_cell * STAR_COUNT
	for i in STAR_COUNT:
		var star := Label.new()
		star.text = "★"
		star.add_theme_font_size_override("font_size", 100)
		star.add_theme_color_override("font_color", UITheme.STAR_EMPTY)
		star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		star.size = Vector2(star_cell, star_h)
		star.position = card_pos + Vector2(
			(card_size.x - row_width) * 0.5 + i * star_cell,
			(card_size.y - star_h) * 0.5)
		star.pivot_offset = star.size * 0.5  # scale pops from the center
		add_child(star)
		_stars.append(star)


func show_result(caught: int, spawned: int) -> void:
	var filled := int(round(STAR_COUNT * float(caught) / float(max(spawned, 1))))
	for star in _stars:
		star.add_theme_color_override("font_color", UITheme.STAR_EMPTY)
		star.scale = Vector2.ONE
	if _fill_tween and _fill_tween.is_valid():
		_fill_tween.kill()
	if filled == 0:
		return
	_fill_tween = create_tween()
	for i in filled:
		_fill_tween.tween_interval(STAR_BEAT)
		_fill_tween.tween_callback(_fill_star.bind(i))


func _fill_star(i: int) -> void:
	if not visible:
		return  # trial already resumed; stay silent
	var star: Label = _stars[i]
	star.add_theme_color_override("font_color", UITheme.STAR_FILLED)
	AudioManager.play_star(i)
	star.scale = Vector2(1.45, 1.45)
	var t := create_tween()
	t.tween_property(star, "scale", Vector2.ONE, 0.30) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
