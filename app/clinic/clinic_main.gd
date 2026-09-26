extends Node

# Entry of the clinic-study flow (docs/clinic_study_interface.md), separate from
# the patient app. Run with
#     --main-scene res://app/clinic/clinic_main.tscn
# Holds the study DB and the current screen: Home, Registration, Settings, or a
# visit (round_runner.gd), and writes the visit's progress to the DB as it goes.
# Esc: on Home quits; in a visit stops it (the day can be resumed today);
# elsewhere goes back to Home.

const StudyDB := preload("res://app/clinic/study_db.gd")
const Protocol := preload("res://app/clinic/protocol.gd")
const HomeScreen := preload("res://app/clinic/home_screen.gd")
const RegistrationScreen := preload("res://app/clinic/registration_screen.gd")
const SettingsScreen := preload("res://app/clinic/settings_screen.gd")
const RoundRunner := preload("res://app/clinic/round_runner.gd")

var _db: StudyDB
var _screen: Node = null
var _visit_id: String = ""       # participant of the running visit


func _ready() -> void:
	# Smooth edges on shapes and lines, for this app only (the patient app's
	# project settings are untouched).
	get_viewport().msaa_2d = Viewport.MSAA_4X
	Protocol.load_saved()
	_db = StudyDB.new()
	_show_home()


func _show(screen: Node) -> void:
	if _screen:
		_screen.queue_free()
	_screen = screen
	add_child(screen)


func _show_home() -> void:
	_visit_id = ""
	var home := HomeScreen.new()
	home.db = _db
	home.start_day.connect(_start_day)
	home.resume_day.connect(_resume_day)
	home.open_registration.connect(func():
		var reg := RegistrationScreen.new()
		reg.db = _db
		reg.done.connect(_show_home)
		_show(reg))
	home.open_settings.connect(_show_settings)
	home.quit_app.connect(_quit)
	_show(home)


func _show_settings() -> void:
	var s := SettingsScreen.new()
	s.db = _db
	s.done.connect(_show_home)
	s.test_drive.connect(_run_test_drive)
	_show(s)


# Settings -> Device -> Test drive: the game with endless targets, nothing
# saved and no participant. Esc ends it.
func _run_test_drive() -> void:
	var runner := RoundRunner.new()
	runner.config = {"participant": "TEST", "day": 0, "quick": false, "resume": {},
		"level_index": 0, "order_id": 0, "show_check": false, "test": true}
	_show(runner)


func _start_day(id: String) -> void:
	var day := int(_db.today_state(id)["day"])
	var quick := bool(_db.settings.get("quick_test", false))
	_db.begin_day(id, day, quick)
	_run_visit(id, day, quick, {})


func _resume_day(id: String) -> void:
	var rec := _db.current_day(id)
	_db.touch(id)
	_run_visit(id, int(rec["day"]), bool(rec.get("quick", false)), rec)


func _run_visit(id: String, day: int, quick: bool, resume: Dictionary) -> void:
	_visit_id = id
	var runner := RoundRunner.new()
	runner.config = {
		"participant": id, "day": day, "quick": quick, "resume": resume,
		"level_index": _db.level_index(id, day),
		"order_id": int(_db.participants[id]["order_id"]),
		"show_check": bool(_db.settings.get("show_check", true)),
	}
	runner.calibration_accepted.connect(func(state: Dictionary): _db.save_calibration(id, state))
	runner.round_done.connect(func(n: int): _db.save_round_done(id, n))
	runner.finished.connect(func(): _db.finish_day(id))
	runner.leave.connect(_show_home)
	_show(runner)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE):
		return
	if _screen and _screen.has_method("busy") and _screen.busy():
		return   # an installer tool is open in Settings: its own Esc handles it
	get_viewport().set_input_as_handled()
	if _screen is HomeScreen:
		_quit()
	else:
		_show_home()   # a stopped visit stays "in progress": resumable today


# Stop the tracker here: get_tree().quit() does not send the window-close
# request that UDPReceiver stops it on.
func _quit() -> void:
	UDPReceiver.stop()
	get_tree().quit()
