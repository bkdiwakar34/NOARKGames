extends Control

# Home (docs/clinic_study_interface.md §4.1): the participant list with each
# one's study progress and today's action, plus New participant and Settings.
# Plain look for now; the mockup's comes with the visuals package.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")

signal start_day(id: String)
signal resume_day(id: String)
signal open_registration
signal open_settings
signal quit_app

var db: StudyDB                  # set by clinic_main before adding the screen
var _tracker_label: Label


func _ready() -> void:
	var v := UI.page(self)

	var top := UI.row(v)
	top.add_child(UI.label("NOARK · Reach Study", UI.TITLE))
	UI.spacer(top)
	_tracker_label = UI.label("", 16, UI.MUTED)
	top.add_child(_tracker_label)
	var proto := "Protocol v%d · %s" % [Protocol.VERSION, "locked" if Protocol.LOCKED else "draft"]
	top.add_child(UI.label(proto, 16, UI.GOOD if Protocol.LOCKED else UI.WARN))
	if db.settings.get("quick_test", false):
		top.add_child(UI.label("Quick test ON", 16, UI.WARN))
	top.add_child(UI.button("New participant", func(): open_registration.emit(), true))
	top.add_child(UI.button("Settings", func(): open_settings.emit()))
	top.add_child(UI.button("Quit", func(): quit_app.emit()))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	if db.participants.is_empty():
		list.add_child(UI.label("No participants yet — press New participant.", UI.TEXT, UI.MUTED))
	for id in db.ids():
		_add_row(list, id)


func _process(_delta: float) -> void:
	var fresh: bool = UDPReceiver.is_fresh()
	var hz: int = UDPReceiver.packets_per_sec
	_tracker_label.text = "Tracker %d Hz" % hz if fresh else "Tracker not streaming"
	_tracker_label.add_theme_color_override("font_color", UI.GOOD if fresh else UI.ACCENT)


func _add_row(list: VBoxContainer, id: String) -> void:
	var p: Dictionary = db.participants[id]
	var state := db.today_state(id)
	var h := UI.row(UI.card(list), 24)

	var who := VBoxContainer.new()
	who.custom_minimum_size = Vector2(360.0, 0.0)
	who.add_child(UI.label("%s   %s" % [id, p["name"]], 20))
	who.add_child(UI.label("%d y · %s · %s-handed" % [int(p["age"]), p["gender"], String(p["hand"]).to_lower()],
		16, UI.MUTED))
	h.add_child(who)

	var progress := RichTextLabel.new()
	progress.bbcode_enabled = true
	progress.fit_content = true
	progress.scroll_active = false
	progress.custom_minimum_size = Vector2(300.0, 0.0)
	progress.add_theme_font_size_override("normal_font_size", 18)
	progress.text = _progress_bbcode(p["days"], state)
	h.add_child(progress)

	var days: Array = p["days"]
	var last := "—"
	if not days.is_empty():
		last = "Last: " + ("today" if days[-1]["date"] == StudyDB.today() else String(days[-1]["date"]))
	var last_label := UI.label(last, 16, UI.MUTED)
	last_label.custom_minimum_size = Vector2(160.0, 0.0)
	h.add_child(last_label)
	UI.spacer(h)

	match String(state["kind"]):
		"start":
			h.add_child(UI.button("Start day %d" % int(state["day"]), func(): start_day.emit(id), true))
		"resume":
			h.add_child(UI.button("Resume day %d" % int(state["day"]), func(): _confirm_resume(id, state), true))
		"done_today":
			h.add_child(UI.label("Day %d done today" % int(state["day"]), 18, UI.GOOD))
		"finished":
			h.add_child(UI.label("All 3 days done", 18, UI.GOOD))


# Three bars' worth of text: ● done, ◐ incomplete, ○ still to come.
func _progress_bbcode(days: Array, state: Dictionary) -> String:
	var marks := ""
	for i in StudyDB.DAYS:
		if i < days.size():
			match String(days[i]["status"]):
				"done":
					marks += "[color=#2E6B3F]●[/color] "
				"incomplete":
					marks += "[color=#D98E1F]◐[/color] "
				_:
					marks += "[color=#7FB08A]◐[/color] "
		else:
			marks += "[color=#C9C4BA]○[/color] "
	var text := ""
	match String(state["kind"]):
		"resume":
			text = "Day %d · round %d of %d" % [int(state["day"]), int(state["rounds_done"]),
				int(state["rounds_total"])]
		"finished":
			text = "Finished"
		"done_today":
			text = "Day %d done" % int(state["day"])
		_:
			var done := 0
			for d in days:
				if d["status"] == "done":
					done += 1
			text = "%d of %d days done" % [done, StudyDB.DAYS]
	return marks + " " + text


func _confirm_resume(id: String, state: Dictionary) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Resume"
	dlg.dialog_text = ("Resume day %d for %s?\n\n%d of %d play rounds done today.\n"
		+ "Today's calibration and level are kept; play continues at round %d.") % [
		int(state["day"]), id, int(state["rounds_done"]), int(state["rounds_total"]),
		int(state["rounds_done"]) + 1]
	dlg.ok_button_text = "Resume"
	dlg.confirmed.connect(func(): resume_day.emit(id))
	add_child(dlg)
	dlg.popup_centered()
