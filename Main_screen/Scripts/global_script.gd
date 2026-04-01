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
var stream_type: String = "udp"          # "udp" or "ble"
var ble_device_name: String = "NOARK_Tracker"

# ── UDP ───────────────────────────────────────────────────────────────────────
@onready var udp: PacketPeerUDP = PacketPeerUDP.new()
@onready var thread_network = Thread.new()
@onready var thread_python = Thread.new()
@onready var thread_path_check = Thread.new()

# ── BLE ───────────────────────────────────────────────────────────────────────
const BLE_SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
const BLE_POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
const BLE_COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

var bluetooth_manager = null
var ble_device = null

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
			push_error("Unknown stream_type '%s' in settings.json — falling back to UDP" % stream_type)
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
	print("[BLE] Initialising BluetoothManager…")
	bluetooth_manager = BluetoothManager.new()
	add_child(bluetooth_manager)
	bluetooth_manager.adapter_initialized.connect(_on_ble_adapter_initialized)
	bluetooth_manager.device_discovered.connect(_on_ble_device_discovered)
	bluetooth_manager.device_updated.connect(_on_ble_device_updated)
	bluetooth_manager.scan_started.connect(_on_ble_scan_started)
	bluetooth_manager.scan_stopped.connect(_on_ble_scan_stopped)
	bluetooth_manager.device_connecting.connect(_on_ble_device_connecting)
	bluetooth_manager.device_connected.connect(_on_ble_device_connected)
	bluetooth_manager.device_disconnected.connect(_on_ble_device_disconnected)
	bluetooth_manager.error_occurred.connect(_on_ble_error)
	bluetooth_manager.initialize()


func _on_ble_adapter_initialized(success: bool, error: String) -> void:
	if success:
		print("[BLE] Adapter ready — starting scan (target: '%s')…" % ble_device_name)
		bluetooth_manager.start_scan(15)
	else:
		push_error("[BLE] Adapter failed to initialise: " + error)


func _on_ble_scan_started() -> void:
	print("[BLE] Scan started")


func _on_ble_scan_stopped() -> void:
	print("[BLE] Scan stopped")
	# Restart scan if we still haven't connected
	if ble_device == null and not disconnected:
		print("[BLE] Target not found — restarting scan in 1 s…")
		await get_tree().create_timer(1.0).timeout
		bluetooth_manager.start_scan(15)


func _on_ble_device_discovered(device_info: Dictionary) -> void:
	var name    = device_info.get("name", "<no name>")
	var address = device_info.get("address", "??:??:??:??:??:??")
	var rssi    = device_info.get("rssi", 0)
	print("[BLE] Discovered: '%s'  addr=%s  rssi=%d" % [name, address, rssi])
	if name == ble_device_name:
		bluetooth_manager.stop_scan()
		print("[BLE] Target found! Connecting to %s…" % address)
		bluetooth_manager.connect_device(address)


func _on_ble_device_updated(device_info: Dictionary) -> void:
	# Fires on RSSI updates — only log if it's our target to avoid spam
	if device_info.get("name", "") == ble_device_name:
		print("[BLE] Target updated: rssi=%d" % device_info.get("rssi", 0))


func _on_ble_device_connecting(address: String) -> void:
	print("[BLE] Connecting to %s…" % address)


func _on_ble_device_connected(address: String) -> void:
	print("[BLE] Connected to %s — discovering services…" % address)
	ble_device = bluetooth_manager.get_device(address)
	ble_device.services_discovered.connect(_on_ble_services_discovered)
	ble_device.characteristic_notified.connect(_on_ble_position_notified)
	ble_device.connection_failed.connect(_on_ble_connection_failed)
	ble_device.operation_failed.connect(_on_ble_operation_failed)
	ble_device.discover_services()


func _on_ble_connection_failed(error: String) -> void:
	push_error("[BLE] Connection failed: " + error)
	ble_device = null
	await get_tree().create_timer(2.0).timeout
	bluetooth_manager.start_scan(15)


func _on_ble_device_disconnected(address: String) -> void:
	print("[BLE] Disconnected from %s" % address)
	connected  = false
	ble_device = null
	if not disconnected:
		print("[BLE] Reconnecting in 2 s…")
		await get_tree().create_timer(2.0).timeout
		bluetooth_manager.start_scan(15)


func _on_ble_services_discovered(services: Array) -> void:
	print("[BLE] %d service(s) discovered:" % services.size())
	for svc in services:
		print("       service  %s" % svc.get("uuid", "?"))
		var chars = svc.get("characteristics", [])
		for ch in chars:
			print("         char  %s  props=%s" % [ch.get("uuid", "?"), str(ch.get("properties", {}))])
	if ble_device == null:
		return
	print("[BLE] Subscribing to position characteristic…")
	ble_device.subscribe_characteristic(BLE_SERVICE_UUID, BLE_POSITION_UUID)
	connected = true
	print("[BLE] Ready — receiving position data")


func _on_ble_operation_failed(operation: String, error: String) -> void:
	push_error("[BLE] Operation '%s' failed: %s" % [operation, error])


func _on_ble_error(error_message: String) -> void:
	push_error("[BLE] Adapter error: " + error_message)


func _on_ble_position_notified(char_uuid: String, data: PackedByteArray) -> void:
	if char_uuid.to_lower() != BLE_POSITION_UUID.to_lower():
		return
	var floats = data.to_float32_array()
	if floats.size() >= 4:
		_apply_position_packet(floats)


# ── shared position update ────────────────────────────────────────────────────

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
				ble_device.write_characteristic(
					BLE_SERVICE_UUID, BLE_COMMAND_UUID,
					message.to_utf8_buffer(), false
				)


func _on_heartbeat_tick() -> void:
	_send_transport_message(_outgoing_message)


# ── process ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
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


# ── python launcher ───────────────────────────────────────────────────────────

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
