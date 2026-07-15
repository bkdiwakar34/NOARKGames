extends Control

var _hospital_id_input: LineEdit
var _name_input: LineEdit
var _age_input: SpinBox
var _stroke_time_input: SpinBox
var _comments_input: LineEdit
var _schedule_input: LineEdit
var _error_label: Label
var _submit_btn: Button
var _edit_mode: bool = false

var _gender_group: ButtonGroup
var _dominant_hand_group: ButtonGroup
var _affected_hand_group: ButtonGroup
var _success_rate_group: ButtonGroup

const SUCCESS_RATE_MAP = {"70%": 0.7, "80%": 0.8, "90%": 0.9}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	if GlobalSignals.edit_patient_id != "":
		_edit_mode = true
		_prefill(GlobalSignals.edit_patient_id)

func _build_ui() -> void:
	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_left", 120)
	margin.add_theme_constant_override("margin_right", 120)
	margin.add_theme_constant_override("margin_bottom", 40)
	add_child(margin)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	_add_title(vbox, "Patient Registration")
	_add_separator(vbox)

	_hospital_id_input = _add_text_field(vbox, "Hospital ID", "e.g. P001")
	_name_input = _add_text_field(vbox, "Patient Name", "Full name")

	vbox.add_child(_make_label("Age"))
	_age_input = SpinBox.new()
	_age_input.min_value = 18
	_age_input.max_value = 100
	_age_input.value = 60
	vbox.add_child(_age_input)

	_gender_group = _add_toggle_row(vbox, "Gender", ["Male", "Female", "Other"])

	vbox.add_child(_make_label("Time since stroke (months)"))
	_stroke_time_input = SpinBox.new()
	_stroke_time_input.min_value = 0
	_stroke_time_input.max_value = 240
	_stroke_time_input.value = 6
	vbox.add_child(_stroke_time_input)

	_dominant_hand_group = _add_toggle_row(vbox, "Dominant Hand", ["Left", "Right"])
	_affected_hand_group = _add_toggle_row(vbox, "Affected Hand", ["Left", "Right"])

	_add_separator(vbox)
	_success_rate_group = _add_toggle_row(vbox, "Therapy Group (assigned by therapist)", ["70%", "80%", "90%"])

	# 14 daily target rates sampled around the group mean (design.md §1);
	# shown editable so they can be inspected or hand-corrected before saving.
	vbox.add_child(_make_label("14-day target-rate schedule (Generate after picking the group; editable)"))
	var sched_row = HBoxContainer.new()
	sched_row.add_theme_constant_override("separation", 8)
	var gen_btn = Button.new()
	gen_btn.text = "Generate"
	gen_btn.custom_minimum_size = Vector2(120, 44)
	gen_btn.pressed.connect(_on_generate_schedule)
	sched_row.add_child(gen_btn)
	_schedule_input = LineEdit.new()
	_schedule_input.placeholder_text = "14 comma-separated rates"
	_schedule_input.custom_minimum_size = Vector2(0, 44)
	_schedule_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sched_row.add_child(_schedule_input)
	vbox.add_child(sched_row)
	_add_separator(vbox)

	_comments_input = _add_text_field(vbox, "Comments (optional)", "")

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color.RED)
	_error_label.visible = false
	vbox.add_child(_error_label)

	_submit_btn = Button.new()
	_submit_btn.text = "Register Patient"
	_submit_btn.custom_minimum_size = Vector2(0, 60)
	_submit_btn.pressed.connect(_on_register_pressed)
	vbox.add_child(_submit_btn)

func _add_text_field(parent: Node, label_text: String, placeholder: String) -> LineEdit:
	parent.add_child(_make_label(label_text))
	var field = LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size = Vector2(0, 44)
	parent.add_child(field)
	return field

func _add_toggle_row(parent: Node, label_text: String, options: Array) -> ButtonGroup:
	parent.add_child(_make_label(label_text))
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var group = ButtonGroup.new()
	for opt in options:
		var btn = Button.new()
		btn.text = opt
		btn.toggle_mode = true
		btn.button_group = group
		btn.custom_minimum_size = Vector2(100, 44)
		hbox.add_child(btn)
	parent.add_child(hbox)
	return group

func _add_title(parent: Node, text: String) -> void:
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 28)
	parent.add_child(lbl)

func _add_separator(parent: Node) -> void:
	parent.add_child(HSeparator.new())

func _make_label(text: String) -> Label:
	var lbl = Label.new()
	lbl.text = text
	return lbl

func _on_register_pressed() -> void:
	var id = _hospital_id_input.text.strip_edges()
	var name_text = _name_input.text.strip_edges()
	var gender_btn = _gender_group.get_pressed_button()
	var dom_btn = _dominant_hand_group.get_pressed_button()
	var aff_btn = _affected_hand_group.get_pressed_button()
	var rate_btn = _success_rate_group.get_pressed_button()

	if id.is_empty():
		_show_error("Hospital ID is required.")
		return
	if name_text.is_empty():
		_show_error("Patient name is required.")
		return
	if not gender_btn:
		_show_error("Please select a gender.")
		return
	if not dom_btn:
		_show_error("Please select dominant hand.")
		return
	if not aff_btn:
		_show_error("Please select affected hand.")
		return
	if not rate_btn:
		_show_error("Please select a therapy group.")
		return

	var rate = SUCCESS_RATE_MAP.get(rate_btn.text, -1.0)

	var schedule: Array = []
	for part in _schedule_input.text.split(",", false):
		var v: float = part.strip_edges().to_float()
		if v <= 0.0 or v >= 1.0:
			_show_error("Schedule values must be between 0 and 1.")
			return
		schedule.append(v)
	if schedule.size() != 14:
		_show_error("Schedule needs exactly 14 values — press Generate.")
		return

	var ok: bool
	if _edit_mode:
		ok = PatientDB.update_patient(id, {
			"name": name_text,
			"age": int(_age_input.value),
			"gender": gender_btn.text,
			"stroke_time": int(_stroke_time_input.value),
			"dominant_hand": dom_btn.text,
			"affected_hand": aff_btn.text,
			"target_success_rate": rate,
			"comments": _comments_input.text.strip_edges(),
			"rate_schedule": schedule,
		})
		if not ok:
			_show_error("Update failed — patient no longer exists.")
			return
	else:
		ok = PatientDB.add_patient(
			id, name_text, int(_age_input.value), gender_btn.text,
			int(_stroke_time_input.value), dom_btn.text, aff_btn.text,
			rate, _comments_input.text.strip_edges(), schedule
		)
		if not ok:
			_show_error("A patient with this ID already exists.")
			return

	PatientDB.current_patient_id = id
	GlobalSignals.current_patient_id = id
	GlobalSignals.edit_patient_id = ""
	if GlobalSignals.return_to_installer:
		get_tree().change_scene_to_file("res://app/installer/installer.tscn")
	else:
		get_tree().change_scene_to_file("res://app/ui/game_select.tscn")


func _prefill(id: String) -> void:
	var p: Dictionary = PatientDB.get_patient(id)
	if p.is_empty():
		return
	_hospital_id_input.text = id
	_hospital_id_input.editable = false  # the ID is the record's identity
	_name_input.text = p.get("name", "")
	_age_input.value = p.get("age", 60)
	_stroke_time_input.value = p.get("stroke_time", 6)
	_comments_input.text = p.get("comments", "")
	_press_matching(_gender_group, p.get("gender", ""))
	_press_matching(_dominant_hand_group, p.get("dominant_hand", ""))
	_press_matching(_affected_hand_group, p.get("affected_hand", ""))
	for key in SUCCESS_RATE_MAP:
		if absf(SUCCESS_RATE_MAP[key] - float(p.get("target_success_rate", -1.0))) < 0.001:
			_press_matching(_success_rate_group, key)
	var parts: PackedStringArray = []
	for v in p.get("rate_schedule", []):
		parts.append("%.3f" % float(v))
	_schedule_input.text = ", ".join(parts)
	_submit_btn.text = "Save Changes"


func _press_matching(group: ButtonGroup, text: String) -> void:
	for btn in group.get_buttons():
		if btn.text == text:
			btn.button_pressed = true
			return


func _on_generate_schedule() -> void:
	var rate_btn = _success_rate_group.get_pressed_button()
	if not rate_btn:
		_show_error("Pick the therapy group first, then press Generate.")
		return
	var mean: float = SUCCESS_RATE_MAP.get(rate_btn.text, 0.8)
	var vals: PackedStringArray = []
	for i in 14:
		vals.append("%.3f" % clampf(randfn(mean, 0.05), 0.4, 0.95))
	_schedule_input.text = ", ".join(vals)
	_error_label.visible = false

func _show_error(msg: String) -> void:
	_error_label.text = msg
	_error_label.visible = true
