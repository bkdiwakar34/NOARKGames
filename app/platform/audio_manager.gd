extends Node
# App-wide sound (docs/v1_plan.md §3, motion/sound language).
#
# Placeholder sounds are synthesized here at startup — no asset files, no
# import pipeline, identical on every machine. To replace any of them, drop
# a real file into app/assets/audio/ named music/catch/miss/star (.ogg or
# .wav) and it is used instead; the synthesized version is only a fallback.
#
# Meaning-sounds are fixed across all games (consistency rule):
#   catch = short rising two-note chime      miss = soft falling tone
#   star  = small bell, pitch rising with each star

const SAMPLE_RATE:       int = 22050
const MUSIC_SAMPLE_RATE: int = 11025   # lower rate: pad sounds fine, halves startup cost

var _music_player: AudioStreamPlayer
var _sfx_player:   AudioStreamPlayer
var _star_player:  AudioStreamPlayer

var _catch_stream: AudioStream
var _miss_stream:  AudioStream
var _star_stream:  AudioStream


func _ready() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.volume_db = -1.0
	add_child(_music_player)
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.volume_db = 2.0
	add_child(_sfx_player)
	_star_player = AudioStreamPlayer.new()
	_star_player.volume_db = 2.0
	add_child(_star_player)

	_music_player.stream = _load_or("music", _make_music())
	_catch_stream = _load_or("catch", _make_catch())
	_miss_stream  = _load_or("miss",  _make_miss())
	_star_stream  = _load_or("star",  _make_star())


# ── Public API ────────────────────────────────────────────────────────────────

func start_music() -> void:
	if not _music_player.playing:
		_music_player.play()

func stop_music() -> void:
	_music_player.stop()

func play_catch() -> void:
	_sfx_player.stream = _catch_stream
	_sfx_player.play()

func play_miss() -> void:
	_sfx_player.stream = _miss_stream
	_sfx_player.play()

func play_star(index: int) -> void:
	_star_player.stream = _star_stream
	_star_player.pitch_scale = 1.0 + 0.13 * index  # each star a step brighter
	_star_player.play()


# ── File override ─────────────────────────────────────────────────────────────

func _load_or(sound_name: String, fallback: AudioStream) -> AudioStream:
	# Runtime loading (not `load()`): works without the editor import step,
	# so dropped-in files take effect on next launch even on a CLI-only Pi.
	var base := "res://app/assets/audio/" + sound_name
	if FileAccess.file_exists(base + ".ogg"):
		var ogg := AudioStreamOggVorbis.load_from_file(base + ".ogg")
		if ogg:
			if sound_name == "music":
				ogg.loop = true
			return ogg
	if FileAccess.file_exists(base + ".wav"):
		var wav := AudioStreamWAV.load_from_file(base + ".wav")
		if wav:
			return wav
	return fallback


# ── Synthesis ─────────────────────────────────────────────────────────────────

func _wav_from_samples(samples: PackedFloat32Array, rate: int, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	return wav


# Catch: bubble pop (fast upward sweep, snappy decay) + high sparkle tail.
func _make_catch() -> AudioStreamWAV:
	var dur := 0.30
	var n := int(SAMPLE_RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var f := 380.0 * pow(950.0 / 380.0, minf(t / 0.07, 1.0))
		phase += f / SAMPLE_RATE
		var pop := sin(TAU * phase) * exp(-t * 26.0)
		var t2 := t - 0.05
		var spark := 0.0
		if t2 > 0.0:
			spark = (sin(TAU * 1568.0 * t2) + 0.4 * sin(TAU * 2349.0 * t2)) \
				* exp(-t2 * 16.0) * 0.45
		s[i] = (pop * 0.85 + spark) * 0.75
	return _wav_from_samples(s, SAMPLE_RATE, false)


# Miss: soft descending two-note mallet ("duh-dum") — gentle, never punishing.
# Kept above ~250 Hz so small monitor speakers can render it.
func _make_miss() -> AudioStreamWAV:
	var dur := 0.5
	var n := int(SAMPLE_RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var note_split := 0.16
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var f := 392.0 if t < note_split else 293.7
		var tn := t if t < note_split else t - note_split
		var env := minf(tn * 90.0, 1.0) * exp(-tn * 9.0)
		s[i] = (sin(TAU * f * tn) + 0.22 * sin(TAU * f * 4.0 * tn)) * 0.55 * env
	return _wav_from_samples(s, SAMPLE_RATE, false)


# Star: glockenspiel-like bell — inharmonic partials with staggered decays
# give the metallic shimmer; pitch rises per star via play_star().
func _make_star() -> AudioStreamWAV:
	var dur := 0.7
	var n := int(SAMPLE_RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var body := sin(TAU * 1046.5 * t) * exp(-t * 5.0)
		var p2 := 0.45 * sin(TAU * 1046.5 * 2.76 * t) * exp(-t * 9.0)
		var p3 := 0.18 * sin(TAU * 1046.5 * 5.40 * t) * exp(-t * 14.0)
		var attack := minf(t * 400.0, 1.0)
		s[i] = (body + p2 + p3) * 0.50 * attack
	return _wav_from_samples(s, SAMPLE_RATE, false)


# Music: calm pentatonic arpeggio over a low drone, ~13 s seamless loop.
func _make_music() -> AudioStreamWAV:
	var notes: Array = [261.63, 329.63, 392.00, 440.00, 523.25, 440.00, 392.00, 329.63,
		293.66, 329.63, 392.00, 440.00, 392.00, 329.63, 293.66, 261.63]  # C-pentatonic phrase
	var note_dur := 0.82
	var n := int(MUSIC_SAMPLE_RATE * note_dur * notes.size())
	var s := PackedFloat32Array()
	s.resize(n)
	var samples_per_note := int(MUSIC_SAMPLE_RATE * note_dur)
	for i in n:
		var t := float(i) / MUSIC_SAMPLE_RATE
		var ni := int(i / float(samples_per_note)) % notes.size()
		var tn := float(i % samples_per_note) / MUSIC_SAMPLE_RATE
		var f: float = notes[ni]
		# per-note envelope: soft attack, slow release (pad-like)
		var env := minf(tn * 6.0, 1.0) * exp(-tn * 1.8)
		# One octave up (f*2) with a brightness harmonic: small monitor
		# speakers barely reproduce quiet sines below ~250 Hz.
		var arp := (sin(TAU * f * 2.0 * t) + 0.35 * sin(TAU * f * 4.0 * t)) * 0.30 * env
		var drone := (sin(TAU * 261.63 * t) + 0.5 * sin(TAU * 392.0 * t)) * 0.08
		s[i] = arp + drone
	return _wav_from_samples(s, MUSIC_SAMPLE_RATE, true)
