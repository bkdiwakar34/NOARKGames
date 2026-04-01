extends Node

# ── session state ─────────────────────────────────────────────────────────────
var session_id: int = 1
var current_date: String = ""
var trial_counts: Dictionary = {}

# ── screen bounds ─────────────────────────────────────────────────────────────
var X_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET3D: int

var current_score: int = 0
var path = "res://settings.json"

# 2D position scalers
@export var PLAYER_POS_SCALER_X: int = 20 * 100
@export var PLAYER_POS_SCALER_Z: int = 20 * 100

# 3D position scalers
@export var PLAYER3D_POS_SCALER_X: int = 20 * 100
@export var PLAYER3D_POS_SCALER_Y: int = 30 * 100

var screen_size = DisplayServer.screen_get_size()
var MIN_X: int = 10
var MAX_X: int = int(screen_size.x - screen_size.x * .15)
var MIN_Y: int = 10
var MAX_Y: int = int(screen_size.y - screen_size.y * .15)

var clamp_vector_x = Vector2(MIN_X, MIN_Y)
var clamp_vector_y = Vector2(MAX_X, MAX_Y)

# ── transport settings ────────────────────────────────────────────────────────
var stream_type: String = "udp"
var ble_device_name: String = "NOARK_Tracker"

const BLE_SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
const BLE_POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
const BLE_COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

# ── UDP ───────────────────────────────────────────────────────────────────────
@onready var udp: PacketPeerUDP = PacketPeerUDP.new()
@onready var thread_network = Thread.new()
@onready var thread_python = Thread.new()
@onready var thread_path_check = Thread.new()

# ── BLE ───────────────────────────────────────────────────────────────────────
var _ble_manager = null   # GdBLE instance
var ble_device = null     # BLEDevice instance (set from scan thread)
var thread_ble = Thread.new()

# ── connection state ──────────────────────────────────────────────────────────
@onready var connected: bool = false
@onready var disconnected: bool = false
@onready var reset_position: bool = false

# ── python launcher ───────────────────────────────────────────────────────────
@onready var interpreter_path: String
@onready var pyscript_path: String
@onready var pypath_checker_path: String
@export var endgame: bool = false

# ── networked position (raw) ──────────────────────────────────────────────────
var net_x: float
var net_y: float
var net_z: float
var net_a: float
var raw_x: float
var raw_y: float
var raw_z: float

var network_position: Vector2   = Vector2.ZERO
var network_position3D: Vector2 = Vector2.ZERO
var workspace: Vector2          = Vector2.ZERO

var scaled_x: float
var scaled_y: float
var scaled_z: float
var scaled_network_position: Vector2   = Vector2.ZERO
var scaled_network_position3D: Vector2 = Vector2.ZERO

# ── messaging ─────────────────────────────────────────────────────────────────
var quit_request: bool = false
@export var delay_time = 0.1
@onready var message_timer: Timer = Timer.new()
var _outgoing_message = "CONNECTED"
var _incoming_message: float

@onready var debug: bool


func _ready() -> void:
	var settings = JSON.parse_string(FileAccess.get_file_as_string(path))
	debug           = settings.get("debug", false)
	stream_type     = settings.get("stream_type", "udp")
	ble_device_name = settings.get("ble_device_name", "NOARK_Tracker")

	current_date = get_date_string()
	load_session_info()

	X_SCREEN_OFFSET   = int(screen_size.x / 4)
	Y_SCREEN_OFFSET   = int(screen_size.y / 4)
	Y_SCREEN_OFFSET3D = int(screen_size.y / 1.75)

	message_timer.autostart = true
	message_timer.wait_time = delay_time
	message_timer.one_shot  = false
	message_timer.timeout.connect(_on_heartbeat_tick)
	add_child(message_timer)

	GlobalSignals.SignalBus.connect(handle_quit_request)
	get_tree().set_auto_accept_quit(false)

	if OS.get_name() == "Windows":
		pyscript_path       = "E:\\CMC\\pyprojects\\programs_rpi\\rpi_python\\stream_optimize.py"
		pypath_checker_path = "E:\\CMC\\pyprojects\\programs_rpi\\rpi_python\\file_integrity.py"
		interpreter_path    = "E:\\CMC\\py_env\\venv\\Scripts\\python.exe"
	else:
		pyscript_path       = "/home/sujith/Documents/rpi_python/stream_optimize.py"
		pypath_checker_path = "/home/sujith/Documents/rpi_python/file_integrity.py"
		interpreter_path    = "/home/sujith/Documents/rpi_python/venv/bin/python"

	match stream_type:
		"udp":
			_init_udp()
		"ble":
			_init_ble()
		_:
			push_error("Unknown stream_type '%s' — falling back to UDP" % stream_type)
			stream_type = "udp"
			_init_udp()

	print(MAX_X, " " + str(MAX_Y))


# ── UDP ───────────────────────────────────────────────────────────────────────

func _init_udp() -> void:
	udp.connect_to_host("127.0.0.1", 8000)
	thread_python.start(python_thread, Thread.PRIORITY_HIGH)
	thread_network.start(network_thread)


func network_thread() -> void:
	while true:
		if udp.get_available_packet_count() > 0:
			handle_udp_packet()
		if disconnected:
			break


func handle_udp_packet() -> void:
	var packet    = udp.get_packet()
	var my_floats = PackedByteArray(packet).to_float32_array()
	udp.put_packet(_outgoing_message.to_utf8_buffer())
	_apply_position_packet(my_floats)


# ── BLE ───────────────────────────────────────────────────────────────────────

func _init_ble() -> void:
	_ble_manager = GdBLE.new()
	if not _ble_manager.initialize():
		push_error("[BLE] Failed to initialise Bluetooth adapter")
		return
	print("[BLE] Adapter ready — launching scan thread…")
	thread_ble.start(_ble_scan_and_connect)


func _ble_scan_and_connect() -> void:
	# Runs on a background thread — scan() blocks for the full duration.
	while not disconnected and not endgame:
		print("[BLE] Scanning 10 s for '%s'…" % ble_device_name)
		var devices: Array = _ble_manager.scan(10.0)
		print("[BLE] Scan complete — %d device(s) found" % devices.size())

		for device in devices:
			var dname = device.get_name()
			var daddr = device.get_address()
			print("[BLE] Device: '%s'  addr=%s" % [dname, daddr])

			if dname == ble_device_name:
				print("[BLE] Connecting to %s…" % daddr)
				if device.connect():
					ble_device = device
					device.subscribe(BLE_SERVICE_UUID, BLE_POSITION_UUID)
					connected = true
					print("[BLE] Connected and subscribed — streaming position data")
					return   # stay connected; _process polls from here
				else:
					print("[BLE] Connection failed — will rescan")

		print("[BLE] Target not found — rescanning…")


# ── shared position update (UDP + BLE) ───────────────────────────────────────

func _apply_position_packet(my_floats: PackedFloat32Array) -> void:
	_incoming_message = my_floats[0]

	raw_x = my_floats[1]
	raw_y = my_floats[2]
	raw_z = my_floats[3]

	net_x = my_floats[1] * PLAYER_POS_SCALER_X  + X_SCREEN_OFFSET
	net_y = my_floats[2] * PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET3D
	net_z = my_floats[3] * PLAYER_POS_SCALER_Z   + Y_SCREEN_OFFSET
	net_a = my_floats[2] * PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET

	network_position   = Vector2(net_x, net_z)
	network_position3D = Vector2(net_x, net_y)
	workspace          = Vector2(net_x, net_a)

	scaled_x = my_floats[1] * PLAYER_POS_SCALER_X  * GlobalSignals.global_scalar_x + X_SCREEN_OFFSET
	scaled_y = my_floats[2] * PLAYER3D_POS_SCALER_Y * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET3D
	scaled_z = my_floats[3] * PLAYER_POS_SCALER_Z   * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET

	scaled_network_position   = Vector2(scaled_x, scaled_z)
	scaled_network_position3D = Vector2(scaled_x, scaled_y)


# ── transport send ────────────────────────────────────────────────────────────

func _send_transport_message(message: String) -> void:
	match stream_type:
		"udp":
			udp.put_packet(message.to_utf8_buffer())
		"ble":
			if ble_device != null and ble_device.is_connected():
				ble_device.write(BLE_SERVICE_UUID, BLE_COMMAND_UUID,
								 message.to_utf8_buffer())


func _on_heartbeat_tick() -> void:
	_send_transport_message(_outgoing_message)


# ── process ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# BLE: poll latest notification each frame
	if stream_type == "ble":
		if ble_device != null and ble_device.is_connected():
			var data: PackedByteArray = ble_device.poll_notification(BLE_POSITION_UUID)
			if data.size() >= 16:
				_apply_position_packet(data.to_float32_array())
		elif ble_device != null and not ble_device.is_connected() and not disconnected:
			# Lost connection — restart scan
			print("[BLE] Connection lost — rescanning…")
			connected  = false
			ble_device = null
			if not thread_ble.is_alive():
				thread_ble = Thread.new()
				thread_ble.start(_ble_scan_and_connect)

	# UDP: watchdog to restart Python if it crashes
	if stream_type == "udp" and not thread_python.is_alive() and not endgame and not debug:
		thread_python = Thread.new()
		thread_python.start(python_thread, Thread.PRIORITY_HIGH)

	match _incoming_message:
		-99.0:
			disconnected = true
			endgame      = true
			if stream_type == "udp":
				thread_network.wait_to_finish()
				thread_python.wait_to_finish()
			get_tree().quit()
		2.0:
			connected = true
		5.0:
			reset_position = true


# ── UDP threads ───────────────────────────────────────────────────────────────

func python_thread() -> void:
	if not debug:
		var output = []
		print("Python thread started.")
		OS.execute(interpreter_path, [pyscript_path], output)
		print(output)
	else:
		print("Debugging…")


func _path_checker() -> void:
	var output = []
	print(output)


# ── quit / patient change ─────────────────────────────────────────────────────

func handle_quit_request() -> void:
	_outgoing_message = "STOP"
	print("Camera closed properly")
	_send_transport_message(_outgoing_message)


func change_patient() -> void:
	_outgoing_message = "USER:" + PatientDB.current_patient_id


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		endgame = true
		handle_quit_request()
		if stream_type == "udp":
			thread_python.wait_to_finish()
		elif stream_type == "ble":
			if ble_device != null:
				ble_device.disconnect()
			if thread_ble.is_alive():
				thread_ble.wait_to_finish()
		get_tree().quit()


# ── session helpers ───────────────────────────────────────────────────────────

func get_date_string() -> String:
	var time = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [time.year, time.month, time.day]


func start_new_session_if_needed() -> void:
	var today = get_date_string()
	if today != current_date:
		current_date = today
		session_id   = 1
		trial_counts.clear()
	else:
		session_id += 1
		trial_counts.clear()
	save_session_info()


func get_next_trial_id(game_name: String) -> int:
	if not trial_counts.has(game_name):
		trial_counts[game_name] = 1
	else:
		trial_counts[game_name] += 1
	save_session_info()
	return trial_counts[game_name]


func load_session_info() -> void:
	if FileAccess.file_exists("user://session.json"):
		var file = FileAccess.open("user://session.json", FileAccess.READ)
		var data = JSON.parse_string(file.get_as_text())
		if typeof(data) == TYPE_DICTIONARY:
			current_date = data.get("current_date", get_date_string())
			session_id   = data.get("session_id", 1)
			trial_counts = data.get("trial_counts", {})


func save_session_info() -> void:
	var data = {
		"current_date": current_date,
		"session_id":   session_id,
		"trial_counts": trial_counts,
	}
	var file = FileAccess.open("user://session.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data))


func get_top_score_for_game(game_name: String, p_id: String) -> int:
	var top_score := 0
	var folder_path = GlobalSignals.data_path + "/" + p_id + "/GameData"

	if DirAccess.dir_exists_absolute(folder_path):
		print("inside")
		var dir = DirAccess.open(folder_path)
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".csv") and file_name.begins_with(game_name):
				var file = FileAccess.open(folder_path + "/" + file_name, FileAccess.READ)
				if file:
					var is_first_line = true
					while not file.eof_reached():
						var line = file.get_line()
						if is_first_line:
							is_first_line = false
							continue
						var fields = line.split(",")
						if fields.size() > 0:
							var score_str = fields[0].strip_edges()
							if score_str.is_valid_int():
								var score = int(score_str)
								if score > top_score:
									top_score = score
					file.close()
			file_name = dir.get_next()

	return top_score
