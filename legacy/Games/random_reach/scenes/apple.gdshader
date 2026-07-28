shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0) = 0.0;

void fragment() {
    vec2 center = vec2(0.5, 0.5);
    vec2 pos = UV - center;
    float dist = length(pos);
    
    // Create a full circle
    if (dist > 0.5) {
        COLOR.a = 0.0; // Transparent outside
    } else {
        // Calculate angle from top (12 o'clock), going clockwise
        float angle = atan(-pos.x, pos.y);
        float normalized = (angle + PI) / (2.0 * PI);
        
        // Show only the portion up to progress (pie slice effect)
        if (normalized <= progress) {
            // Light blue shining
            COLOR = vec4(3.0, 0.5, 1.0, 0.5); // Light blue
        } else {
            COLOR.a = 0.0; // Transparent - creates rotating effect
        }
    }
}