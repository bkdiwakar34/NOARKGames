extends RefCounted

# Participants of the clinic study (docs/clinic_study_interface.md §1, §4.1-4.2,
# §4.8), in participants.json in the clinic data folder — separate from the
# patient app's patients.json. Saved whole after every change, through a
# temporary file, so a power cut leaves the old or the new file, never half.
#
#   participants[id] = {name, age, gender, hand, registered, order, days}
#     order = the three level indices in play order (one of the 6 permutations)
#     days  = one record per study day:
#             {day, date, status ("in_progress" | "done" | "incomplete"),
#              quick, level, calibrated_at, lifetimes, boundary, unfit,
#              rounds_total, rounds_done}
#   block    = orders still unused in the current balanced block of 6
#   settings = {show_check, quick_test}
#
# Study day advances by visit: the first session on a new date is the next day
# (an unfinished earlier day becomes "incomplete"); another session on the same
# date stays on that day and resumes it if play had started.

const Protocol := preload("res://app/clinic/protocol.gd")

const FILE_NAME := "participants.json"
const DAYS := 3
# The 6 orders of levels 0, 1, 2 (spec §1): one per participant, balanced blocks.
const ORDERS: Array = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

var participants: Dictionary = {}
var settings: Dictionary = {"show_check": true, "quick_test": false}
var _block: Array = []


func _init() -> void:
	var path := _path()
	if not FileAccess.file_exists(path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		push_error("Unreadable " + path)
		return
	participants = d.get("participants", {})
	_block = d.get("block", [])
	settings.merge(d.get("settings", {}), true)


func _path() -> String:
	return Protocol.data_dir() + "/" + FILE_NAME


func save() -> void:
	DirAccess.make_dir_recursive_absolute(Protocol.data_dir())
	var path := _path()
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		push_error("Could not write " + path)
		return
	f.store_string(JSON.stringify(
		{"participants": participants, "block": _block, "settings": settings}, "\t"))
	f.close()
	DirAccess.rename_absolute(path + ".tmp", path)


static func today() -> String:
	return Time.get_date_string_from_system()


func next_id() -> String:
	var n := 1
	while participants.has("P%03d" % n):
		n += 1
	return "P%03d" % n


# Returns "" or the reason it was refused.
func register(id: String, name_text: String, age: int, gender: String, hand: String) -> String:
	if id == "":
		return "The participant ID is empty."
	if participants.has(id):
		return "%s is already registered." % id
	if name_text == "":
		return "The name is empty."
	if gender == "" or hand == "":
		return "Choose gender and dominant hand."
	if _block.is_empty():
		_block = range(ORDERS.size())
		_block.shuffle()
	var order_idx := int(_block.pop_front())   # JSON gives numbers back as floats
	participants[id] = {
		"name": name_text, "age": age, "gender": gender, "hand": hand,
		"registered": today(), "order_id": order_idx + 1, "order": ORDERS[order_idx],
		"days": [],
	}
	save()
	return ""


# IDs, newest registration first.
func ids() -> Array:
	var out: Array = participants.keys()
	out.sort()
	out.reverse()
	return out


# What Home offers for this participant today:
#   {kind: "start" | "resume" | "done_today" | "finished", day, rounds_done, rounds_total}
func today_state(id: String) -> Dictionary:
	var days: Array = participants[id]["days"]
	if not days.is_empty():
		var last: Dictionary = days[-1]
		if last["date"] == today():
			if last["status"] == "done":
				return {"kind": "done_today", "day": last["day"]}
			if last.has("lifetimes") and int(last["rounds_done"]) < int(last["rounds_total"]):
				return {"kind": "resume", "day": last["day"],
					"rounds_done": last["rounds_done"], "rounds_total": last["rounds_total"]}
			return {"kind": "start", "day": last["day"]}   # stopped during calibration: start over
	if days.size() >= DAYS:
		return {"kind": "finished", "day": DAYS}
	return {"kind": "start", "day": days.size() + 1}


func level_index(id: String, day: int) -> int:
	return int(participants[id]["order"][day - 1])


# Starting a day's session from the reach scan. Reuses today's record (a
# restart after a stop during calibration) or opens the next day.
func begin_day(id: String, day: int, quick: bool) -> void:
	var days: Array = participants[id]["days"]
	if not days.is_empty() and days[-1]["date"] == today():
		days[-1] = {"day": day, "date": today(), "status": "in_progress"}
	else:
		if not days.is_empty() and days[-1]["status"] != "done":
			days[-1]["status"] = "incomplete"
		days.append({"day": day, "date": today(), "status": "in_progress"})
	days[-1]["quick"] = quick
	days[-1]["level"] = level_index(id, day)
	save()


# The frozen calibration, so a stopped day can resume play with it.
func save_calibration(id: String, state: Dictionary) -> void:
	var rec: Dictionary = participants[id]["days"][-1]
	rec.merge(state, true)
	rec["calibrated_at"] = Time.get_time_string_from_system().substr(0, 5)
	rec["rounds_done"] = 0
	save()


func save_round_done(id: String, rounds_done: int) -> void:
	participants[id]["days"][-1]["rounds_done"] = rounds_done
	save()


func finish_day(id: String) -> void:
	participants[id]["days"][-1]["status"] = "done"
	save()


func current_day(id: String) -> Dictionary:
	return participants[id]["days"][-1]
