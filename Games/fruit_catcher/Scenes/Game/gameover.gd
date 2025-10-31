extends TextureRect

# Breathing animation settings
@export var min_scale := 0.95
@export var max_scale := 1.05
@export var breathe_speed := 1.5

func _ready():
    # Set pivot to center for proper scaling
    pivot_offset = size / 2
    
    # Start breathing animation
    breathe()

func breathe():
    # Create a tween for smooth animation
    var tween = create_tween()
    tween.set_loops() # Loop forever
    tween.set_trans(Tween.TRANS_SINE)
    tween.set_ease(Tween.EASE_IN_OUT)
    
    # Scale up (breathe out)
    tween.tween_property(self, "scale", Vector2(max_scale, max_scale), breathe_speed)
    # Scale down (breathe in)
    tween.tween_property(self, "scale", Vector2(min_scale, min_scale), breathe_speed)
