extends CanvasLayer

var _label: Label
var _sub_label: Label

func _ready() -> void:
	var vp := get_viewport().get_visible_rect().size
	var card_size := Vector2(580.0, 240.0)
	var card_pos := vp * 0.5 - card_size * 0.5

	# Subtle dim over the game
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.28)
	dim.size = vp
	dim.position = Vector2.ZERO
	add_child(dim)

	# Warm amber card
	var card := ColorRect.new()
	card.color = Color(1.0, 0.88, 0.38, 0.97)
	card.size = card_size
	card.position = card_pos
	add_child(card)

	# Caught count
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 54)
	_label.add_theme_color_override("font_color", Color(0.22, 0.10, 0.02))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.custom_minimum_size = Vector2(card_size.x, 140.0)
	_label.position = card_pos + Vector2(0.0, 16.0)
	add_child(_label)

	# Encouragement sub-text
	_sub_label = Label.new()
	_sub_label.add_theme_font_size_override("font_size", 26)
	_sub_label.add_theme_color_override("font_color", Color(0.40, 0.20, 0.04, 0.85))
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sub_label.custom_minimum_size = Vector2(card_size.x, 68.0)
	_sub_label.position = card_pos + Vector2(0.0, 158.0)
	add_child(_sub_label)

func show_result(caught: int) -> void:
	_label.text = "You caught\n%d apples!" % caught
	_sub_label.text = _encouragement()

func _encouragement() -> String:
	var msgs := ["Keep it up!", "Nice work!", "Great reach!", "Well done!", "Excellent!", "Keep going!"]
	return msgs[randi() % msgs.size()]
