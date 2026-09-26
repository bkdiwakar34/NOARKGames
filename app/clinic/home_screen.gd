extends Control

# Home (docs/clinic_study_interface.md §4.1), in the mockup's layout: the
# participant table (who, study progress, last session, today, action) with a
# search box, a "Before you start" panel of live device checks, New
# participant, and Settings (the sliders icon). Esc on this screen quits.

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
var _table: VBoxContainer
var _tracker_slot: HBoxContainer
var _tracker_chip: PanelContainer
var _tracker_check: Label
var _tracker_was: int = -2       # last shown tracker state, to rebuild the chip only on change


func _ready() -> void:
	var p := UI.page(self, "Reach Study")
	var bar: HBoxContainer = p["bar"]
	_tracker_slot = HBoxContainer.new()
	_tracker_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(_tracker_slot)
	var locked: bool = Protocol.LOCKED
	bar.add_child(UI.chip("Protocol v%d · %s" % [Protocol.VERSION, "locked" if locked else "draft"],
		UI.GOOD_BG if locked else UI.WARN_BG, UI.GOOD if locked else UI.WARN,
		Color("2E8B4A") if locked else UI.WARN_DOT))
	if db.settings.get("quick_test", false):
		bar.add_child(UI.chip("Quick test visits", UI.WARN_BG, UI.WARN, UI.WARN_DOT))
	else:
		bar.add_child(UI.chip("Clinic mode", Color("EDEBE6"), UI.INK2))
	bar.add_child(UI.sliders_button(func(): open_settings.emit(), "Settings"))

	var content: VBoxContainer = p["content"]
	var body := UI.row(content, 25)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 16)
	body.add_child(main)
	var head := UI.row(main, 11)
	var title := UI.label("Participants", UI.TITLE, UI.INK, true)
	head.add_child(title)
	var count := UI.label("%d registered" % db.participants.size(), 13, UI.MUTED)
	count.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(count)
	UI.spacer(head)
	var search := UI.field("", 216.0)
	search.placeholder_text = "Search ID or name"
	search.right_icon = _search_icon()
	search.text_changed.connect(func(t: String): _fill_table(t))
	head.add_child(search)
	head.add_child(UI.button("+  New participant", func(): open_registration.emit(), "primary"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main.add_child(scroll)
	_table = UI.card(scroll, 0.0, 0)
	_table.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fill_table("")

	var aside := VBoxContainer.new()
	aside.custom_minimum_size = Vector2(270.0, 0.0)
	aside.add_theme_constant_override("separation", 14)
	body.add_child(aside)
	_build_checks(UI.card(aside, 18.0, 5))
	var visit := UI.card(aside, 18.0, 5)
	visit.add_child(UI.label("One visit", 15, UI.INK, true))
	visit.add_child(UI.label(_visit_text(), 12, UI.MUTED, false, true))
	var quit := UI.label("Esc quits the app", 12, Color(UI.MUTED, 0.8))
	quit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	aside.add_child(quit)


# A small magnifier drawn into a texture for the search box.
func _search_icon() -> Texture2D:
	var img := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for a in 64:
		var t := TAU * float(a) / 64.0
		for r in [5.6, 6.0, 6.4]:
			img.set_pixel(int(9.0 + cos(t) * r), int(9.0 + sin(t) * r), UI.MUTED)
	for i in 6:
		img.set_pixel(13 + i, 13 + i, UI.MUTED)
		img.set_pixel(14 + i, 13 + i, UI.MUTED)
	return ImageTexture.create_from_image(img)


# ── Table ─────────────────────────────────────────────────────────────────────

func _fill_table(filter: String) -> void:
	for c in _table.get_children():
		c.queue_free()
	_table_head(_table)
	var f := filter.strip_edges().to_lower()
	var shown := 0
	for id in db.ids():
		var name_text := String(db.participants[id]["name"])
		if f != "" and not (String(id).to_lower().contains(f) or name_text.to_lower().contains(f)):
			continue
		UI.line(_table)
		_add_row(_table, id)
		shown += 1
	if shown == 0:
		var empty := MarginContainer.new()
		empty.add_theme_constant_override("margin_left", 20)
		empty.add_theme_constant_override("margin_top", 16)
		empty.add_theme_constant_override("margin_bottom", 16)
		var msg := "No participants yet — press New participant." if f == "" else "No participant matches “%s”." % filter
		empty.add_child(UI.label(msg, 14, UI.MUTED))
		_table.add_child(empty)


func _cells(parent: Control) -> HBoxContainer:
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 20)
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 11)
	parent.add_child(m)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	m.add_child(h)
	return h


func _cell(h: HBoxContainer, c: Control, i: int) -> void:
	if i < RATIOS.size():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_stretch_ratio = RATIOS[i]
	else:
		c.custom_minimum_size.x = 135.0
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
	h.alignment = BoxContainer.ALIGNMENT_CENTER

	var who := VBoxContainer.new()
	who.add_theme_constant_override("separation", 2)
	var name_row := UI.row(who, 9)
	name_row.add_child(UI.label(id, 13, Color("6B6E66"), true))
	name_row.add_child(UI.label(String(p["name"]), 15, UI.INK, true))
	who.add_child(UI.label("%d y · %s · %s-handed" % [int(p["age"]), p["gender"],
		String(p["hand"])], 12, UI.MUTED))
	_cell(h, who, 0)

	var progress := VBoxContainer.new()
	progress.add_theme_constant_override("separation", 5)
	var bars := UI.row(progress, 5)
	for i in StudyDB.DAYS:
		bars.add_child(UI.bar_piece(_day_colour(days, i), 23.0))
	progress.add_child(UI.label(_progress_text(days, state), 12, UI.INK2, true))
	_cell(h, progress, 1)

	_cell(h, UI.label(_last_text(days), 13, UI.INK2), 2)

	var today := HBoxContainer.new()
	today.add_child(_today_chip(kind, state, days))
	_cell(h, today, 3)

	# Red for what to do next (resume, a first day), outlined for later days.
	var action := HBoxContainer.new()
	action.alignment = BoxContainer.ALIGNMENT_END
	match kind:
		"start":
			var day := int(state["day"])
			action.add_child(UI.button("Start day %d" % day, func(): start_day.emit(id),
				"primary" if day == 1 else "outline"))
		"resume":
			action.add_child(UI.button("Resume", func(): _confirm_resume(id, state), "primary"))
		_:
			action.add_child(UI.label("✓ Completed" if kind == "finished" else "✓ Done today",
				13, UI.GOOD, true))
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
		text += " · day %d incomplete" % _first_incomplete(days)
	return text


func _first_incomplete(days: Array) -> int:
	for d in days:
		if d["status"] == "incomplete":
			return int(d["day"])
	return 0


func _last_text(days: Array) -> String:
	if days.is_empty():
		return "—"
	var last: Dictionary = days[-1]
	var date := String(last["date"])
	if date == StudyDB.today():
		var t := String(last.get("time", ""))
		return "Today, " + t if t != "" else "Today"
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


# The mockup's Resume prompt: a card over the dimmed list, with the day's
# rounds as a bar and what is kept.
func _confirm_resume(id: String, state: Dictionary) -> void:
	var m := UI.modal(self, 470.0)
	var layer: Control = m["layer"]
	var card: VBoxContainer = m["card"]
	var done := int(state["rounds_done"])
	var total := int(state["rounds_total"])
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	head.add_child(UI.label("%s · %s" % [id, db.participants[id]["name"]], 12, Color("6B6E66"), true))
	head.add_child(UI.label("Resume day %d?" % int(state["day"]), 22, UI.INK, true))
	card.add_child(head)
	var rounds := VBoxContainer.new()
	rounds.add_theme_constant_override("separation", 8)
	var bar := UI.row(rounds, 5)
	for i in total:
		var piece := UI.bar_piece(UI.GOOD if i < done else Color("E3DFD6"), 0.0)
		piece.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.add_child(piece)
	rounds.add_child(UI.label("Stopped after round %d of %d today." % [done, total], 13, UI.INK2))
	card.add_child(rounds)
	var kept := PanelContainer.new()
	kept.add_theme_stylebox_override("panel", UI._box(UI.GOOD_BG, UI.GOOD_BG, 11, 0, 14.0, 12.0))
	var at := String(db.current_day(id).get("calibrated_at", ""))
	kept.add_child(UI.label("✓  Today's calibration (%s) and level are kept. Play continues at round %d."
		% [at, done + 1], 12, UI.GOOD, false, true))
	card.add_child(kept)
	var buttons := UI.row(card, 11)
	UI.spacer(buttons)
	buttons.add_child(UI.button("Cancel", func(): layer.queue_free()))
	buttons.add_child(UI.button("Resume at round %d" % (done + 1), func(): resume_day.emit(id), "primary"))


# ── Side panel ────────────────────────────────────────────────────────────────

func _build_checks(v: VBoxContainer) -> void:
	v.add_child(UI.label("Before you start", 15, UI.INK, true))
	v.add_child(UI.label("Device checks, refreshed live.", 12, UI.MUTED))
	var ts := TableSpace.new(get_viewport_rect().size)
	_tracker_check = _check_row(v, "Tracker", "", true)
	var origin := FileAccess.file_exists("res://pyscripts/origin_lock.json")
	_check_row(v, "Origin lock", "Locked" if origin else "Missing — Settings → Device", origin)
	_check_row(v, "Screen mapping", "4 corners set" if ts.mapped else "Not set — Settings → Device",
		ts.mapped)
	_check_row(v, "Protocol", "v%d locked" % Protocol.VERSION if Protocol.LOCKED
		else "Draft — lock before the study", Protocol.LOCKED)


# Returns the detail label, for rows that update live.
func _check_row(v: VBoxContainer, title: String, detail: String, ok: bool) -> Label:
	UI.line(v)
	var h := UI.row(v, 11)
	var mark := PanelContainer.new()
	var col: Color = UI.GOOD_BG if ok else UI.WARN_BG
	mark.add_theme_stylebox_override("panel", UI._box(col, col, 12, 0, 7.0, 2.0))
	mark.add_child(UI.label("✓" if ok else "!", 13, UI.GOOD if ok else UI.WARN, true))
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(mark)
	var t := VBoxContainer.new()
	t.add_theme_constant_override("separation", 0)
	t.add_child(UI.label(title, 13, UI.INK, true))
	var d := UI.label(detail, 11, UI.MUTED, false, true)
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
