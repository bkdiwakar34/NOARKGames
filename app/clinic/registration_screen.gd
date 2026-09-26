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
	# The save button sits in the top bar as well, so it is on screen whatever
	# the window height (the logical screen is only 648 px tall).
	var bar: HBoxContainer = p["bar"]
	bar.add_child(UI.button("Cancel", func(): done.emit(), "ghost"))
	bar.add_child(UI.button("Register participant", _register, "primary"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p["content"].add_child(scroll)
	var centre := HBoxContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)
	UI.spacer(centre)
	var holder := VBoxContainer.new()
	holder.custom_minimum_size = Vector2(760.0, 0.0)
	centre.add_child(holder)
	UI.spacer(centre)

	var c := UI.card(holder, 28.0, 14)
	var head := UI.row(c, 12)
	head.add_child(UI.label("New participant", 24, UI.INK, true))
	head.add_child(UI.label("Healthy-participant study · %d visits" % StudyDB.DAYS, 14, UI.MUTED))

	var row1 := UI.row(c, 16)
	_id = UI.field(db.next_id(), 0.0)
	_add(row1, "Participant ID", _id, 1.0)
	_name = UI.field("", 0.0)
	_name.placeholder_text = "First and last name (stays on this device)"
	_name.text_submitted.connect(func(_t): _register())
	_add(row1, "Full name", _name, 2.0)

	var row2 := UI.row(c, 16)
	_age = SpinBox.new()
	_age.min_value = 18
	_age.max_value = 100
	_age.value = 30
	_age.get_line_edit().custom_minimum_size = Vector2(0.0, 42.0)
	_add(row2, "Age", _age, 0.6)
	_add(row2, "Gender", UI.segmented(["Female", "Male", "Other"], func(o): _gender = o), 1.5)
	_add(row2, "Dominant hand", UI.segmented(["Left", "Right"], func(o): _hand = o), 1.0)

	UI.note_box(c, "Level order is assigned for you on save (the next order from a balanced block "
		+ "of the 6). It is stored with the data and never shown on screen.")
	_error = UI.label("", 15, UI.ACCENT, true, true)
	c.add_child(_error)
	_name.grab_focus()


# One form cell: caption above the control; ratio = its share of the row width.
func _add(parent: HBoxContainer, caption: String, control: Control, ratio: float) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_stretch_ratio = ratio
	v.add_child(UI.label(caption, 14, UI.INK2, true))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(control)
	parent.add_child(v)


func _register() -> void:
	var err := db.register(_id.text.strip_edges(), _name.text.strip_edges(), int(_age.value),
		_gender, _hand)
	if err != "":
		_error.text = err
		return
	done.emit()
