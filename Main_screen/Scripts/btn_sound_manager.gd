extends Node

var button_click_sound = preload("res://Assets/Sound_effects/button_pressed.mp3")
var sfx_player: AudioStreamPlayer

func _ready():
    sfx_player = AudioStreamPlayer.new()
    add_child(sfx_player)
    sfx_player.volume_db = 0
    
    get_tree().node_added.connect(_on_node_added)
    setup_buttons_in_node(get_tree().root)

func _on_node_added(node: Node):
    if node is BaseButton:
        setup_button(node)

func setup_buttons_in_node(node: Node):

    if node is BaseButton:
        setup_button(node)
    
    for child in node.get_children():
        setup_buttons_in_node(child)

func setup_button(button: BaseButton):

    if not button.pressed.is_connected(_on_button_pressed):
        button.pressed.connect(_on_button_pressed)

func _on_button_pressed():
    play_sound(button_click_sound)

func play_sound(stream: AudioStream):
    if stream:
        sfx_player.stream = stream
        sfx_player.play()

func set_volume(volume_db: float):
    sfx_player.volume_db = volume_db

# Optional: Disable sounds for specific buttons
func exclude_button(button: BaseButton):
    if button.pressed.is_connected(_on_button_pressed):
        button.pressed.disconnect(_on_button_pressed)
        
        
    
