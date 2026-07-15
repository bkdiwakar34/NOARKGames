extends CanvasLayer

const UITheme := preload("res://app/ui/ui_theme.gd")

# Trial-end star screen (docs/v1_plan.md §3): five stars fill left-to-right,
# one per beat with a rising chime. Fill count = catch ratio × 5 — deliberately
# near-constant by design (decisions log in v1_plan.md), a warm ritual rather
# than a performance signal.

const STAR_COUNT := 5
const STAR_BEAT  := 0.38  # seconds between stars filling

var _stars: Array = []    # Label nodes
var _sub_label: Label
var _caught_label: Label
var _fill_tween: Tween

func _ready() -> void:
	var vp := get_viewport().get_visible_rect().size
	var card_size := Vector2(640.0, 300.0)
	var card_pos := vp * 0.5 - card_size * 0.5

	# Subtle dim over the game
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.28)
	dim.size = vp
	dim.position = Vector2.ZERO
	add_child(dim)

	# Warm card
	var card := ColorRect.new()
	card.color = UITheme.CARD
	card.size = card_size
	card.position = card_pos
	add_child(card)

	# Star row
	var star_size := 92.0
	var row_width := star_size * STAR_COUNT
	for i in STAR_COUNT:
		var star := Label.new()
		star.text = "★"
		star.add_theme_font_size_override("font_size", int(star_size * 0.9))
		star.add_theme_color_override("font_color", UITheme.STAR_EMPTY)
		star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star.custom_minimum_size = Vector2(star_size, star_size * 1.2)
		star.position = card_pos + Vector2(
			(card_size.x - row_width) * 0.5 + i * star_size, 30.0)
		add_child(star)
		_stars.append(star)

	# Caught count, small, under the stars
	_caught_label = Label.new()
	_caught_label.add_theme_font_size_override("font_size", UITheme.FONT_LARGE)
	_caught_label.add_theme_color_override("font_color", UITheme.TEXT_DARK)
	_caught_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caught_label.custom_minimum_size = Vector2(card_size.x, 40.0)
	_caught_label.position = card_pos + Vector2(0.0, 168.0)
	add_child(_caught_label)

	# Encouragement sub-text
	_sub_label = Label.new()
	_sub_label.add_theme_font_size_override("font_size", UITheme.FONT_LARGE)
	_sub_label.add_theme_color_override("font_color", UITheme.TEXT_SOFT)
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.custom_minimum_size = Vector2(card_size.x, 48.0)
	_sub_label.position = card_pos + Vector2(0.0, 222.0)
	add_child(_sub_label)


func show_result(caught: int, spawned: int) -> void:
	var filled := int(round(STAR_COUNT * float(caught) / float(max(spawned, 1))))
	for star in _stars:
		star.add_theme_color_override("font_color", UITheme.STAR_EMPTY)
	_caught_label.text = "You caught %d apples!" % caught
	_sub_label.text = _encouragement()

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
	_stars[i].add_theme_color_override("font_color", UITheme.STAR_FILLED)
	AudioManager.play_star(i)


func _encouragement() -> String:
	var msgs := ["Keep it up!", "Nice work!", "Great reach!", "Well done!", "Excellent!", "Keep going!"]
	return msgs[randi() % msgs.size()]
