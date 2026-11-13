shader_type canvas_item;

varying vec4 item_tint;

void vertex() {
    item_tint = COLOR;
}

float glyph_alpha(vec4 sample_color, float y) {
    float white = min(sample_color.r, min(sample_color.g, sample_color.b));
    // Keep a screen-pixel-wide transition when extracting the glyphs.
    float transition = max(fwidth(white), 0.135);
    return sample_color.a * smoothstep(0.785 - transition, 0.785 + transition, white) * (1.0 - step(0.89, y));
}

void fragment() {
    vec4 tint = item_tint;
    float alpha = glyph_alpha(texture(TEXTURE, UV), UV.y);
    vec2 step_uv = TEXTURE_PIXEL_SIZE * 2.0;
    float outline = max(max(glyph_alpha(texture(TEXTURE, UV + vec2(step_uv.x, 0.0)), UV.y), glyph_alpha(texture(TEXTURE, UV - vec2(step_uv.x, 0.0)), UV.y)),
                        max(glyph_alpha(texture(TEXTURE, UV + vec2(0.0, step_uv.y)), UV.y + step_uv.y), glyph_alpha(texture(TEXTURE, UV - vec2(0.0, step_uv.y)), UV.y - step_uv.y)));
    COLOR = vec4(mix(vec3(0.12, 0.20, 0.40), vec3(0.98, 0.99, 1.0), alpha), max(alpha, outline)) * tint;
}
