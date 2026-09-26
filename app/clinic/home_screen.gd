extends Control

# Home (docs/clinic_study_interface.md §4.1), in the mockup's layout: the
# participant table (who, study progress, last session, today, action), a
# "Before you start" panel of live device checks, New participant, Settings.

const UI := preload("res://app/clinic/clinic_ui.gd")
const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")
const TableSpace := preload("res://app/clinic/table_space.gd")

signal start_day(id: String)
signal resume_day(id: String)
signal open_registration
signal open_settings
signal quit_app

const RATIOS: Array = [1.7, 1.3, 0.9, 1.1]   # table columns; the action column is fixed
const MONTHS: Array = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var db: StudyDB                  # set by clinic_main before adding the screen
var _tracker_chip: PanelContainer
var _tracker_slot: HBoxContainer
var _tracker_check: Label
var _tracker_was: int = -2       # last shown tracker state, to rebuild the chip only on change


func _ready() -> void:
	var p := UI.page(self, "Reach Study")
	var bar: HBoxContainer = p["bar"]
	_tracker_slot = HBoxContainer.new()
	bar.add_child(_tracker_slot)
	var locked: bool = Protocol.LOCKED
	bar.add_child(UI.chip("Protocol v%d · %s" % [Protocol.VERSION, "locked" if locked else "draft"],
		UI.GOOD_BG if locked else UI.WARN_BG, UI.GOOD if locked else UI.WARN,
		Color("2E8B4A") if locked else UI.WARN_DOT))
	if db.settings.get("quick_test", false):
		bar.add_child(UI.chip("Quick test visits", UI.WARN_BG, UI.WARN, UI.WARN_DOT))
	else:
		bar.add_child(UI.chip("Clinic mode", Color("EDEBE6"), UI.INK2))
	bar.add_child(UI.button("Settings", func(): open_settings.emit()))
	bar.add_child(UI.button("Quit", func(): quit_app.emit(), "ghost"))

	var content: VBoxContainer = p["content"]
	var body := UI.row(content, 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 18)
	body.add_child(main)
	var head := UI.row(main)
	head.add_child(UI.label("Participants", UI.TITLE, UI.INK, true))
	head.add_child(UI.label("%d registered" % db.participants.size(), 15, UI.MUTED))
	UI.spacer(head)
	head.add_child(UI.button("+  New participant", func(): open_registration.emit(), "primary"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main.add_child(scroll)
	var table := UI.card(scroll, 0.0, 0)
	table.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_table_head(table)
	if db.participants.is_empty():
		var empty := MarginContainer.new()
		empty.add_theme_constant_override("margin_left", 22)
		empty.add_theme_constant_override("margin_top", 18)
		empty.add_theme_constant_override("margin_bottom", 18)
		empty.add_child(UI.label("No participants yet — press New participant.", 16, UI.MUTED))
		table.add_child(empty)
	for id in db.ids():
		UI.line(table)
		_add_row(table, id)

	var aside := VBoxContainer.new()
	aside.custom_minimum_size = Vector2(300.0, 0.0)
	aside.add_theme_constant_override("separation", 16)
	body.add_child(aside)
	_build_checks(UI.card(aside, 20.0, 6))
	var visit := UI.card(aside, 20.0, 6)
	visit.add_child(UI.label("One visit", 17, UI.INK, true))
	visit.add_child(UI.label(_visit_text(), 14, UI.MUTED, false, true))


# ── Table ─────────────────────────────────────────────────────────────────────

func _cells(parent: Control) -> HBoxContainer:
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	parent.add_child(m)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	m.add_child(h)
	return h


func _cell(h: HBoxContainer, c: Control, i: int) -> void:
	if i < RATIOS.size():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_stretch_ratio = RATIOS[i]
	else:
		c.custom_minimum_size.x = 170.0
	h.add_child(c)


func _table_head(table: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI._box(Color("FAF9F6"), Color("FAF9F6"), 16, 0, 0.0, 0.0))
	table.add_child(panel)
	var h := _cells(panel)
	var names: Array = ["Participant", "Study progress", "Last session", "Today", ""]
	for i in names.size():
		_cell(h, UI.caption(names[i]), i)


func _add_row(table: VBoxContainer, id: String) -> void:
	var p: Dictionary = db.participants[id]
	var days: Array = p["days"]
	var state := db.today_state(id)
	var kind := String(state["kind"])
	var h := _cells(table)

	var who := VBoxContainer.new()
	who.add_theme_constant_override("separation", 2)
	var name_row := UI.row(who, 10)
	name_row.add_child(UI.label(id, 14, Color("6B6E66"), true))
	name_row.add_child(UI.label(String(p["name"]), 17, UI.INK, true))
	who.add_child(UI.label("%d y · %s · %s-handed" % [int(p["age"]), p["gender"],
		String(p["hand"]).to_lower()], 14, UI.MUTED))
	_cell(h, who, 0)

	var progress := VBoxContainer.new()
	progress.add_theme_constant_override("separation", 6)
	var bars := UI.row(progress, 6)
	for i in StudyDB.DAYS:
		bars.add_child(UI.bar_piece(_day_colour(days, i)))
	progress.add_child(UI.label(_progress_text(days, state), 14, UI.INK2, true))
	_cell(h, progress, 1)

	_cell(h, UI.label(_last_text(days), 15, UI.INK2), 2)

	var today := HBoxContainer.new()
	today.add_child(_today_chip(kind, state, days))
	_cell(h, today, 3)

	var action := HBoxContainer.new()
	action.alignment = BoxContainer.ALIGNMENT_END
	match kind:
		"start":
			var b := UI.button("Start day %d" % int(state["day"]), func(): start_day.emit(id))
			b.add_theme_color_override("font_color", UI.ACCENT_DARK)
			b.add_theme_color_override("font_hover_color", UI.ACCENT_DARK)
			action.add_child(b)
		"resume":
			action.add_child(UI.button("Resume", func(): _confirm_resume(id, state), "primary"))
		_:
			action.add_child(UI.label("✓ Completed" if kind == "finished" else "✓ Done today",
				15, UI.GOOD, true))
	_cell(h, action, 4)


func _day_colour(days: Array, i: int) -> Color:
	if i >= days.size():
		return Color("E3DFD6")
	match String(days[i]["status"]):
		"done":
			return UI.GOOD
		"incomplete":
			return UI.WARN_DOT
	return Color("7FB08A")   # in progress


func _progress_text(days: Array, state: Dictionary) -> String:
	match String(state["kind"]):
		"resume":
			return "Day %d · round %d of %d" % [int(state["day"]), int(state["rounds_done"]),
				int(state["rounds_total"])]
		"finished":
			return "3 of 3 days"
	if days.is_empty():
		return "Not started"
	var done := 0
	var incomplete := 0
	for d in days:
		if d["status"] == "done":
			done += 1
		elif d["status"] == "incomplete":
			incomplete += 1
	var text := "%d of %d days" % [done, StudyDB.DAYS]
	if incomplete > 0:
		text += " · %d incomplete" % incomplete
	return text


func _last_text(days: Array) -> String:
	if days.is_empty():
		return "—"
	var date := String(days[-1]["date"])
	if date == StudyDB.today():
		return "Today"
	var parts := date.split("-")
	return "%d %s" % [int(parts[2]), MONTHS[int(parts[1]) - 1]] if parts.size() == 3 else date


func _today_chip(kind: String, state: Dictionary, days: Array) -> PanelContainer:
	match kind:
		"resume":
			var at := String(days[-1].get("calibrated_at", ""))
			return UI.chip("Calibrated " + at, UI.GOOD_BG, UI.GOOD, Color("2E8B4A"))
		"done_today":
			return UI.chip("Day %d done" % int(state["day"]), UI.GOOD_BG, UI.GOOD, Color("2E8B4A"))
		"finished":
			return UI.chip("Finished", Color("F1EFEA"), UI.MUTED, Color("B9B5AC"))
	return UI.chip("Calibration due", UI.WARN_BG, UI.WARN, UI.WARN_DOT)


func _confirm_resume(id: String, state: Dictionary) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Resume day %d?" % int(state["day"])
	dlg.dialog_text = ("%s · %s\n\nStopped after round %d of %d today.\n"
		+ "Today's calibration and level are kept; play continues at round %d.") % [
		id, db.participants[id]["name"], int(state["rounds_done"]), int(state["rounds_total"]),
		int(state["rounds_done"]) + 1]
	dlg.ok_button_text = "Resume at round %d" % (int(state["rounds_done"]) + 1)
	dlg.confirmed.connect(func(): resume_day.emit(id))
	add_child(dlg)
	dlg.popup_centered(Vector2i(520, 0))


# ── Side panel ────────────────────────────────────────────────────────────────

func _build_checks(v: VBoxContainer) -> void:
	v.add_child(UI.label("Before you start", 17, UI.INK, true))
	v.add_child(UI.label("Device checks, refreshed live.", 14, UI.MUTED))
	var ts := TableSpace.new(get_viewport_rect().size)
	_tracker_check = _check_row(v, "Tracker", "", true)
	var origin := FileAccess.file_exists("res://pyscripts/origin_lock.json")
	_check_row(v, "Origin lock", "Locked" if origin else "Missing — lock it in the installer", origin)
	_check_row(v, "Screen mapping", "4 corners set" if ts.mapped else "Not set — do the 4-corner mapping",
		ts.mapped)
	_check_row(v, "Protocol", "v%d locked" % Protocol.VERSION if Protocol.LOCKED
		else "Draft — lock before the study", Protocol.LOCKED)


# Returns the detail label, for rows that update live.
func _check_row(v: VBoxContainer, title: String, detail: String, ok: bool) -> Label:
	UI.line(v)
	var h := UI.row(v, 12)
	var mark := PanelContainer.new()
	var col: Color = UI.GOOD_BG if ok else UI.WARN_BG
	mark.add_theme_stylebox_override("panel", UI._box(col, col, 13, 0, 8.0, 2.0))
	mark.add_child(UI.label("✓" if ok else "!", 14, UI.GOOD if ok else UI.WARN, true))
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(mark)
	var t := VBoxContainer.new()
	t.add_theme_constant_override("separation", 0)
	t.add_child(UI.label(title, 15, UI.INK, true))
	var d := UI.label(detail, 13, UI.MUTED, false, true)
	t.add_child(d)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	return d


func _visit_text() -> String:
	var quick := bool(db.settings.get("quick_test", false))
	var c: int = Protocol.QUICK_CALIB_ROUNDS if quick else Protocol.CALIB_ROUNDS
	var n: int = Protocol.QUICK_PLAY_ROUNDS if quick else Protocol.PLAY_ROUNDS
	var rest: float = Protocol.QUICK_REST_S if quick else Protocol.REST_S
	# ~40 s reach scan, then every round, with a rest after all but the last.
	var s: float = 40.0 + float(Protocol.WARMUP_ROUNDS + c + n) * Protocol.ROUND_S + float(c + n) * rest
	return "Reach scan → warm-up → %d calibration rounds → %d play rounds. About %d min." % [
		c, n, roundi(s / 60.0)]


# ── Live tracker status ───────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	var hz: int = UDPReceiver.packets_per_sec if UDPReceiver.is_fresh() else -1
	if hz == _tracker_was:
		return
	_tracker_was = hz
	if _tracker_chip:
		_tracker_chip.queue_free()
	var ok := hz >= 0
	_tracker_chip = UI.chip("Tracker · %d Hz" % hz if ok else "Tracker not streaming",
		UI.GOOD_BG if ok else UI.WARN_BG, UI.GOOD if ok else UI.WARN,
		Color("2E8B4A") if ok else UI.ACCENT)
	_tracker_slot.add_child(_tracker_chip)
	_tracker_check.text = "Streaming, %d Hz" % hz if ok else "Not streaming — is the tracker running?"
