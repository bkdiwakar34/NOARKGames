extends Node

var raw_x: float = 0.0
var raw_y: float = 0.0
var raw_z: float = 0.0
var screen_pos: Vector2 = Vector2.ZERO
var connected: bool = false
var _tracker_pid: int = -1

const SCALER_X: int = 2000
const SCALER_Z: int = 2000

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _thread: Thread = Thread.new()
var _port: int = 12345
var _running: bool = true
var _outgoing: String = "CONNECTED"
var _offset_x: int
var _offset_y: int

func _ready() -> void:
	var screen = DisplayServer.screen_get_size()
	_offset_x = int(screen.x / 4)
	_offset_y = int(screen.y / 4)

	var settings = JSON.parse_string(FileAccess.get_file_as_string("res://settings.json"))
	if settings:
		_port = settings.get("udp_port", 12345)

	_start_tracker()
	_udp.connect_to_host("127.0.0.1", _port)
	_thread.start(_network_loop)


func _start_tracker() -> void:
	var pyscripts_dir: String = ProjectSettings.globalize_path("res://pyscripts")
	if not DirAccess.dir_exists_absolute(pyscripts_dir):
		return
	_tracker_pid = OS.create_process(
		"bash", ["-c", "cd '" + pyscripts_dir + "' && /home/sujith/Documents/NOARKGames/.venv/bin/python3 main.py"]
	)

func _network_loop() -> void:
	while _running:
		if _udp.get_available_packet_count() > 0:
			var packet = _udp.get_packet()
			var floats = PackedByteArray(packet).to_float32_array()
			_udp.put_packet(_outgoing.to_utf8_buffer())
			_apply_packet(floats)
		else:
			_udp.put_packet(_outgoing.to_utf8_buffer())
			OS.delay_msec(100)

func _apply_packet(f: PackedFloat32Array) -> void:
	if f.size() < 4:
		return
	raw_x = f[1]
	raw_y = f[2]
	raw_z = f[3]
	screen_pos = Vector2(
		raw_x * SCALER_X + _offset_x,
		(raw_z - 0.2) * 1400.0 + 40.0
	)
	connected = true

func stop() -> void:
	_running = false
	_outgoing = "STOP"
	_udp.put_packet(_outgoing.to_utf8_buffer())
	_thread.wait_to_finish()
	if _tracker_pid > 0:
		OS.kill(_tracker_pid)
		_tracker_pid = -1

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
