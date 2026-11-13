shader_type canvas_item;

varying vec4 item_tint;

void vertex() {
    item_tint = COLOR;
}

void fragment() {
    vec4 tint = item_tint;
    // Sample a square around the supplied moon, keeping its original proportions.
    vec2 source_uv = vec2(0.5, 407.0 / 1080.0) + (UV - 0.5) * vec2(900.0 / 1920.0, 900.0 / 1080.0);
    vec4 source = texture(TEXTURE, source_uv);
    vec3 sky = vec3(60.0, 103.0, 203.0) / 255.0;
    float brightness = max((source.r - sky.r) / (1.0 - sky.r), (source.g - sky.g) / (1.0 - sky.g));
    float edge = 1.0 - smoothstep(0.86, 1.0, length(UV * 2.0 - 1.0));
    float alpha = smoothstep(0.02, 0.30, brightness) * edge * source.a;
    COLOR = vec4(source.rgb, alpha) * tint;
}
