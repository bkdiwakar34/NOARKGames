extends Node

var player: AudioStreamPlayer

var main_theme = preload("res://Assets/Sound_effects/Clash-of-Clans-Main-Theme.mp3")
var pp_bgm    = preload("res://Assets/Sound_effects/smooth-midieval-332632-2.mp3")
var rr_bgm  = preload("res://Assets/Sound_effects/Age-of-War-Theme-Soundtrack.mp3")
var ft_bgm  = preload("res://Assets/Sound_effects/Original-Tetris-theme-Tetris-Sou.mp3")
var fc_bgm  = preload("res://Assets/Sound_effects/Pokmon-Legends-Z-A-OST-Lumiose-C.mp3")
var jy_bgm  = preload("res://Assets/Sound_effects/Kids-2.mp3")

func _ready():
    player = AudioStreamPlayer.new()
    add_child(player)
    player.autoplay = false
    player.volume_db = 0
    
    
    play_music("main")

func play_music(track_name: String):
    var stream: AudioStream = null
    
    match track_name:
        "main": stream = main_theme
        "pp_bgm": stream = pp_bgm
        "rr_bgm": stream = rr_bgm
        "ft_bgm": stream = ft_bgm
        "fc_bgm": stream = fc_bgm
        "jy_bgm": stream = jy_bgm
        _:
            print("Unknown track: ", track_name)
            return

    if player.stream != stream:
        player.stop()
        player.stream = stream
        player.play()
