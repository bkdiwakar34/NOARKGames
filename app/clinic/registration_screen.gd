extends Control

# New participant (docs/clinic_study_interface.md §4.2), in the mockup's layout:
# one centred card. The level order is assigned on save from a balanced block
# of the 6 orders (study_db.gd) and never shown. The name stays on this device;
# data files use the ID only.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")

signal done

var db: StudyDB                  # set by clinic_main before adding the screen
var _id: LineEdit
var _name: LineEdit
var _age: SpinBox
var _gender: String = ""
var _hand: String = ""
var _error: Label


func _ready() -> void:
	var p := UI.page(self, "Reach Study")
	var bar: HBoxContainer = p["bar"]
	bar.add_child(UI.button("‹  Participants", func(): done.emit(), "ghost"))

	var content: VBoxContainer = p["content"]
	var centre := UI.row(content, 0)
	UI.spacer(centre)
	var holder := VBoxContainer.new()
	holder.custom_minimum_size = Vector2(720.0, 0.0)
	centre.add_child(holder)
	UI.spacer(centre)

	var c := UI.card(holder, 34.0, 20)
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	head.add_child(UI.label("New participant", 26, UI.INK, true))
	head.add_child(UI.label("Healthy-participant study · %d visits" % StudyDB.DAYS, 15, UI.MUTED))
	c.add_child(head)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 18)
	c.add_child(grid)

	_id = UI.field(db.next_id(), 0.0)
	_add(grid, "Participant ID", _id, "Next free ID, filled in for you")
	_name = UI.field("", 0.0)
	_name.placeholder_text = "First and last name"
	_add(grid, "Full name", _name, "Stays on this device only")
	_age = SpinBox.new()
	_age.min_value = 18
	_age.max_value = 100
	_age.value = 30
	_age.custom_minimum_size = Vector2(0.0, 46.0)
	_age.get_line_edit().custom_minimum_size = Vector2(0.0, 46.0)
	_add(grid, "Age", _age, "")
	_add(grid, "Gender", UI.segmented(["Female", "Male", "Other"], func(o): _gender = o), "")
	_add(grid, "Dominant hand", UI.segmented(["Left", "Right"], func(o): _hand = o), "")

	UI.note_box(c, "Level order is assigned for you. On save, the app gives this participant the next "
		+ "order from a balanced block of the 6 possible orders. It is stored with the data and "
		+ "never shown on screen.")
	_error = UI.label("", 15, UI.ACCENT, true, true)
	c.add_child(_error)
	var buttons := UI.row(c, 12)
	UI.spacer(buttons)
	buttons.add_child(UI.button("Cancel", func(): done.emit()))
	buttons.add_child(UI.button("Register participant", _register, "primary"))
	_name.grab_focus()


# One form cell: caption above, the control, an optional hint below.
func _add(grid: GridContainer, caption: String, control: Control, hint: String) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(caption, 14, UI.INK2, true))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(control)
	if hint != "":
		v.add_child(UI.label(hint, 13, UI.MUTED))
	grid.add_child(v)


func _register() -> void:
	var err := db.register(_id.text.strip_edges(), _name.text.strip_edges(), int(_age.value),
		_gender, _hand)
	if err != "":
		_error.text = err
		return
	done.emit()
