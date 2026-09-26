extends Node

# Sounds of the clinic game (feedback design 2026-09-26: graded catches as in
# osu!, a soft miss, a pluck when a hold starts, a streak sparkle, stars).
# Synthesized at start-up like app/platform/audio_manager.gd (no audio files,
# no editor import), with players of their own so the patient app's
# AudioManager is left alone.

const RATE := 22050

# Built once per app run (synthesis takes a moment), shared by every visit.
static var _bell: AudioStreamWAV = null    # one bell; pitch sets the grade
static var _chord: AudioStreamWAV = null   # "Perfect": bell plus a fifth and an octave
static var _miss: AudioStreamWAV = null
static var _pluck: AudioStreamWAV = null
static var _sparkle: AudioStreamWAV = null

var _players: Array = []
var _next: int = 0


func _ready() -> void:
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -2.0
		add_child(p)
		_players.append(p)
	if _bell == null:
		_bell = _make_bell([1.0], 0.9)
		_chord = _make_bell([1.0, 1.5, 2.0], 1.1)
		_miss = _make_miss()
		_pluck = _make_pluck()
		_sparkle = _make_sparkle()


func _play(stream: AudioStream, pitch: float = 1.0, db: float = 0.0) -> void:
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = -2.0 + db
	p.play()


# grade 3 / 2 / 1 in calibration; 0 = a play catch (no points).
func caught(grade: int) -> void:
	match grade:
		3:
			_play(_chord, 1.0, 1.0)
		2:
			_play(_bell, 0.84)
		1:
			_play(_bell, 0.67, -3.0)
		_:
			_play(_bell, 0.89)


func missed() -> void:
	_play(_miss, 1.0, -4.0)


func hold_started() -> void:
	_play(_pluck, 1.0, -8.0)


func streak() -> void:
	_play(_sparkle, 1.0, -1.0)


func star(i: int) -> void:
	_play(_bell, 1.0 + 0.125 * float(i), -4.0)


# ── Synthesis ─────────────────────────────────────────────────────────────────

func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav


# Glassy bell at 1046.5 Hz (C6) times each ratio: inharmonic partials with
# staggered decays give the shimmer; a fast attack keeps it crisp.
func _make_bell(ratios: Array, dur: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var gain := 0.5 / float(ratios.size())
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in ratios.size():
			var f: float = 1046.5 * float(ratios[k])
			var tk := t - 0.035 * float(k)       # the chord's notes roll in
			if tk < 0.0:
				continue
			v += (sin(TAU * f * tk) * exp(-tk * 4.5)
				+ 0.4 * sin(TAU * f * 2.76 * tk) * exp(-tk * 9.0)
				+ 0.15 * sin(TAU * f * 5.4 * tk) * exp(-tk * 15.0)) * minf(tk * 500.0, 1.0)
		s[i] = v * gain
	return _wav(s)


# Soft, low, falling note — noticeable, never punishing.
func _make_miss() -> AudioStreamWAV:
	var dur := 0.55
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := 330.0 * pow(247.0 / 330.0, minf(t / 0.35, 1.0))
		phase += f / RATE
		var env := minf(t * 60.0, 1.0) * exp(-t * 5.5)
		s[i] = (sin(TAU * phase) + 0.2 * sin(TAU * phase * 2.0)) * 0.45 * env
	return _wav(s)


# Short soft pluck when a hold begins.
func _make_pluck() -> AudioStreamWAV:
	var dur := 0.18
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		s[i] = sin(TAU * 1568.0 * t) * exp(-t * 30.0) * minf(t * 800.0, 1.0) * 0.4
	return _wav(s)


# Quick rising arpeggio for a streak.
func _make_sparkle() -> AudioStreamWAV:
	var notes: Array = [1318.5, 1568.0, 2093.0, 2637.0]
	var step := 0.06
	var dur := step * float(notes.size()) + 0.5
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in notes.size():
			var tk := t - step * float(k)
			if tk >= 0.0:
				v += sin(TAU * float(notes[k]) * tk) * exp(-tk * 7.0) * minf(tk * 600.0, 1.0)
		s[i] = v * 0.22
	return _wav(s)
