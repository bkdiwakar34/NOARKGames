extends Node

var raw_x: float = 0.0
var raw_y: float = 0.0
var raw_z: float = 0.0
var screen_pos: Vector2 = Vector2.ZERO
var connected: bool = false
var _tracker_pid: int = -1

const SCALER_X: int = 2000
const SCALER_Z: int = 2000

# Demo comparison toggles (set from the game_select settings menu)
var setup_subset: bool = false   # true = old marker set only (settings.json demo_subset_ids)
var setup_rigid:  bool = true    # true = joint rigid-body solve, false = per-marker

var packets_per_sec: int = 0     # measured arrival rate, updated once a second
var _pkt_count: int = 0
var _pkt_window_ms: int = 0

# Per-packet log buffer: filled on the network thread at tracker rate (~100 Hz),
# drained by the game scene once per frame via take_samples().
var log_enabled: bool = false
var _log_buffer: Array = []      # [unix_time, screen_x, screen_y, tracker_x, tracker_y, tracker_z]
var _log_mutex: Mutex = Mutex.new()

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _thread: Thread = Thread.new()
var _port: int = 12345
var _running: bool = true
var _outgoing: String = "CONNECTED"
var _offset_x: int
var _offset_y: int
var _viewport_size: Vector2 = Vector2(1152.0, 648.0)

func _ready() -> void:
	var screen = DisplayServer.screen_get_size()
	_offset_x = int(screen.x / 4)
	_offset_y = int(screen.y / 4)
	# Cache viewport size on main thread — safe to use in the network thread
	await get_tree().process_frame
	_viewport_size = get_viewport().get_visible_rect().size

	var settings = JSON.parse_string(FileAccess.get_file_as_string("res://settings.json"))
	if settings:
		_port = settings.get("udp_port", 12345)

	_start_tracker(settings)
	_udp.connect_to_host("127.0.0.1", _port)
	_thread.start(_network_loop)


func _start_tracker(settings) -> void:
	var pyscripts_dir: String = ProjectSettings.globalize_path("res://pyscripts")
	if not DirAccess.dir_exists_absolute(pyscripts_dir):
		return
	# Derived from the running project's own location rather than hardcoded to
	# one machine's home directory/username — the Pi and Q6A have different
	# users (sujith vs. radxa) but both keep .venv/ at the project root.
	var python_bin: String = ProjectSettings.globalize_path("res://.venv/bin/python3")
	var cmd: String = "cd '" + pyscripts_dir + "' && '" + python_bin + "' main.py"
	# Optional CPU-affinity pinning (e.g. "4-7") for boards with asymmetric
	# big.LITTLE cores (like the Q6A's 4xA78/4xA55) where the vision-heavy
	# tracker and Godot's own thread can otherwise get scheduled onto the
	# same physical cores and starve each other. Empty/unset on the Pi
	# (identical cores, no need) -- set locally per-deployment, not shared.
	var affinity: String = settings.get("tracker_cpu_affinity", "") if settings else ""
	if affinity != "":
		cmd = "taskset -c " + affinity + " bash -c \"" + cmd.replace("\"", "\\\"") + "\""
	_tracker_pid = OS.create_process("bash", ["-c", cmd])

func _network_loop() -> void:
	# Drain the queue every pass with a short poll. The old version slept
	# 100 ms whenever the queue was empty, so tracker packets arrived in
	# 100 ms bursts and screen_pos effectively updated at 10 Hz.
	var last_send: int = 0
	while _running:
		var got_any: bool = false
		while _udp.get_available_packet_count() > 0:
			var packet = _udp.get_packet()
			var floats = PackedByteArray(packet).to_float32_array()
			_apply_packet(floats)
			got_any = true
		var now: int = Time.get_ticks_msec()
		if now - last_send >= 100:
			_udp.put_packet(_outgoing.to_utf8_buffer())   # keepalive / sticky command
			last_send = now
		if not got_any:
			OS.delay_msec(2)

func _apply_packet(f: PackedFloat32Array) -> void:
	if f.size() < 4:
		return
	raw_x = f[1]
	raw_y = f[2]
	raw_z = f[3]
	if WorkspaceConfig.sensor_calibrated:
		screen_pos = WorkspaceConfig.sensor_to_screen(raw_x, raw_z, _viewport_size)
	else:
		screen_pos = Vector2(
			raw_x * SCALER_X + _offset_x,
			(raw_z - 0.2) * 1400.0 + 40.0
		)
	connected = true

	if log_enabled:
		_log_mutex.lock()
		_log_buffer.append([Time.get_unix_time_from_system(),
			screen_pos.x, screen_pos.y, raw_x, raw_y, raw_z])
		if _log_buffer.size() > 2000:  # safety cap if the game stops draining
			_log_buffer = _log_buffer.slice(_log_buffer.size() - 2000)
		_log_mutex.unlock()

	_pkt_count += 1
	var now: int = Time.get_ticks_msec()
	if now - _pkt_window_ms >= 1000:
		packets_per_sec = _pkt_count
		_pkt_count      = 0
		_pkt_window_ms  = now

# Hand the buffered packet samples to the caller and clear the buffer.
# Called once per frame by the game scene while logging.
func take_samples() -> Array:
	_log_mutex.lock()
	var out: Array = _log_buffer
	_log_buffer = []
	_log_mutex.unlock()
	return out

func send_tracker_setup(subset: bool, rigid: bool) -> void:
	setup_subset = subset
	setup_rigid  = rigid
	var markers: String = "subset" if subset else "all"
	var algo:    String = "rigid" if rigid else "legacy"
	# Sticky like every other outgoing command; tracker applies it once and
	# ignores the repeats, re-locking its origin on each actual change.
	_outgoing = "SETUP:%s,%s" % [markers, algo]

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
