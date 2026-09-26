extends Control

# New participant (docs/clinic_study_interface.md §4.2). The level order is
# assigned on save from a balanced block of the 6 orders (study_db.gd) and is
# never shown. The name stays on this device; data files use the ID only.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")

signal done

const GENDERS: Array = ["Female", "Male", "Other"]
const HANDS: Array = ["Left", "Right"]

var db: StudyDB                  # set by clinic_main before adding the screen
var _id: LineEdit
var _name: LineEdit
var _age: SpinBox
var _gender: OptionButton
var _hand: OptionButton
var _error: Label


func _ready() -> void:
	var v := UI.page(self)
	var top := UI.row(v)
	top.add_child(UI.label("New participant", UI.TITLE))
	UI.spacer(top)
	top.add_child(UI.button("Cancel", func(): done.emit()))

	var c := UI.card(v)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 14)
	c.add_child(grid)

	_id = UI.field(db.next_id())
	_add(grid, "Participant ID", _id)
	_name = UI.field("", 360.0)
	_name.placeholder_text = "First and last name"
	_add(grid, "Full name", _name)
	_age = SpinBox.new()
	_age.min_value = 18
	_age.max_value = 100
	_age.value = 30
	_age.custom_minimum_size = Vector2(140.0, 44.0)
	_add(grid, "Age", _age)
	_gender = _choice(GENDERS)
	_add(grid, "Gender", _gender)
	_hand = _choice(HANDS)
	_add(grid, "Dominant hand", _hand)

	c.add_child(UI.label("The level order is assigned when you register, stored with the data, "
		+ "and never shown on screen. The name stays on this device; files use the ID only.",
		16, UI.MUTED))
	_error = UI.label("", 18, UI.ACCENT)
	c.add_child(_error)
	var buttons := UI.row(c)
	UI.spacer(buttons)
	buttons.add_child(UI.button("Register participant", _register, true))
	_name.grab_focus()


func _add(grid: GridContainer, caption: String, control: Control) -> void:
	grid.add_child(UI.label(caption, 18, UI.MUTED))
	grid.add_child(control)


func _choice(options: Array) -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(220.0, 44.0)
	o.add_theme_font_size_override("font_size", UI.TEXT)
	o.add_item("Choose…")
	for s in options:
		o.add_item(s)
	return o


func _picked(o: OptionButton, options: Array) -> String:
	return "" if o.selected <= 0 else String(options[o.selected - 1])


func _register() -> void:
	var err := db.register(_id.text.strip_edges(), _name.text.strip_edges(), int(_age.value),
		_picked(_gender, GENDERS), _picked(_hand, HANDS))
	if err != "":
		_error.text = err
		return
	done.emit()
