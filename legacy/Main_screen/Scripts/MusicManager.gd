extends Node
var bgm_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer


var music_tracks := {
    "main": "res://Assets/Sound_effects/Clash-of-Clans-Main-Theme.mp3",
    "pp_bgm": "res://Assets/Sound_effects/smooth-midieval-332632-2.mp3",
    "rr_bgm": "res://Assets/Sound_effects/Age-of-War-Theme-Soundtrack.mp3",
    "ft_bgm": "res://Assets/Sound_effects/Original-Tetris-theme-Tetris-Sou.mp3",
    "fc_bgm": "res://Assets/Sound_effects/Pokmon-Legends-Z-A-OST-Lumiose-C.mp3",
    "jy_bgm": "res://Assets/Sound_effects/Kids-2.mp3"
}


var bgm_volumes := {
    "main": 0.0,
    "pp_bgm": -10.0,
    "rr_bgm": -15.0,
    "ft_bgm": -15.0,
    "fc_bgm": -10.0,
    "jy_bgm": 0.0
}

var sound_effects := {
    "scored": "res://Assets/Sound_effects/scored.mp3",
    "hit": "res://Assets/Sound_effects/lightning-strike-386161_kP0k5uhh.mp3",
    "ball": "res://Assets/Sound_effects/hit.mp3",
    "fruit_missed": "res://Assets/Sound_effects/car-crash-sound-376882.mp3",
    "game_over":"res://Assets/Sound_effects/level-up-04-243762.mp3"
}


var sfx_volumes := {
    "scored": 0.0,
    "hit": 0.0,
    "ball": 10.0,
    "fruit_missed": 0.0,
    "game_over":0.0
}
                
func _ready():
    # Create background music player
    bgm_player = AudioStreamPlayer.new()
    add_child(bgm_player)
    
    # Create sound effect player
    sfx_player = AudioStreamPlayer.new()
    add_child(sfx_player)
    
    play_music("main")

func play_music(track_name: String):
    if not music_tracks.has(track_name):
        push_error("Unknown BGM track: " + track_name)
        return
    
    var stream = load(music_tracks[track_name]) as AudioStream
    if stream == null:
        push_error("Failed to load music track: " + track_name)
        return
    
    # Enable looping based on the stream type
    if stream is AudioStreamMP3:
        stream.loop = true
    elif stream is AudioStreamOggVorbis:
        stream.loop = true
    
    # Only restart if different track
    if bgm_player.stream != stream:
        bgm_player.stop()
        bgm_player.stream = stream
        bgm_player.volume_db = bgm_volumes[track_name]  # Set individual volume
        bgm_player.play()

func play_sound_effect(effect_name: String):
    if not sound_effects.has(effect_name):
        push_error("Unknown sound effect: " + effect_name)
        return
    
    var stream = load(sound_effects[effect_name]) as AudioStream
    if stream == null:
        push_error("Failed to load sound effect: " + effect_name)
        return
    
    sfx_player.stream = stream
    sfx_player.volume_db = sfx_volumes[effect_name] 
    sfx_player.play()

func stop_music():
    bgm_player.stop()

func set_music_volume(volume_db: float):
    bgm_player.volume_db = volume_db

func set_sfx_volume(volume_db: float):
    sfx_player.volume_db = volume_db
