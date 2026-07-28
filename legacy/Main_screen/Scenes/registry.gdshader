shader_type canvas_item;

uniform float corner_radius = 30.0;

void fragment() {
    vec2 uv = UV;
    vec2 size = 1.0 / TEXTURE_PIXEL_SIZE;
    
    // Get pixel position
    vec2 pos = uv * size;
    
    // Calculate distance from each corner
    vec2 top_left = pos;
    vec2 top_right = vec2(size.x - pos.x, pos.y);
    vec2 bottom_left = vec2(pos.x, size.y - pos.y);
    vec2 bottom_right = size - pos;
    
    // Check if we're in a corner region
    float alpha = 1.0;
    
    // Top-left corner
    if (pos.x < corner_radius && pos.y < corner_radius) {
        float dist = length(pos - vec2(corner_radius));
        alpha = smoothstep(corner_radius + 1.0, corner_radius - 1.0, dist);
    }
    // Top-right corner
    else if (pos.x > size.x - corner_radius && pos.y < corner_radius) {
        float dist = length(vec2(size.x - pos.x, pos.y) - vec2(corner_radius));
        alpha = smoothstep(corner_radius + 1.0, corner_radius - 1.0, dist);
    }
    // Bottom-left corner
    else if (pos.x < corner_radius && pos.y > size.y - corner_radius) {
        float dist = length(vec2(pos.x, size.y - pos.y) - vec2(corner_radius));
        alpha = smoothstep(corner_radius + 1.0, corner_radius - 1.0, dist);
    }
    // Bottom-right corner
    else if (pos.x > size.x - corner_radius && pos.y > size.y - corner_radius) {
        float dist = length(size - pos - vec2(corner_radius));
        alpha = smoothstep(corner_radius + 1.0, corner_radius - 1.0, dist);
    }
    
    COLOR = texture(TEXTURE, UV);
    COLOR.a *= alpha;
}