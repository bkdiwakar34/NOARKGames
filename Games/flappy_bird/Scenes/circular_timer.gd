extends Control

@onready var time_label := Label.new()
var progress := 1.0
var max_time := 60

func _ready() -> void:
    custom_minimum_size = Vector2(85, 120)
    
    # Setup and center label
    time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    time_label.set_anchors_preset(Control.PRESET_CENTER)
    time_label.position = Vector2(-60, -20)
    time_label.size = Vector2(120, 40)
    
    # Apply styling
    time_label.add_theme_font_size_override("font_size", 20)
    time_label.add_theme_color_override("font_color", Color.BLACK)
    var font = load("res://Assets/Fonts/Bungee-Regular.ttf")
    if font:
        time_label.add_theme_font_override("font", font)
    
    add_child(time_label)

func set_time(time: int) -> void:
    max_time = time
    progress = 1.0
    time_label.text = "%d:%02d" % [time / 60, time % 60]
    queue_redraw()

func update_time(time_left: int) -> void:
    progress = float(time_left) / float(max_time)
    time_label.text = "%d:%02d" % [time_left / 60, time_left % 60]
    queue_redraw()

func _draw() -> void:
    var center := size / 2
    var radius: float = min(size.x, size.y) / 2.0 - 10.0
    
    # Background circle
    draw_arc(center, radius, 0, TAU, 64, Color(0.2, 0.2, 0.2, 0.5), 8.0)
    
    # Progress arc with color based on remaining time
    var color := Color.HOT_PINK if progress > 0.3 else (Color.ORANGE if progress > 0.15 else Color.RED)
    draw_arc(center, radius, -PI/2, -PI/2 - TAU * progress, 64, color, 8.0, true)
