shader_type canvas_item;

varying vec4 item_tint;

void vertex() {
    item_tint = COLOR;
}

void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    float radius = length(p);
    vec2 source_uv = vec2(0.5, 407.0 / 1080.0) + (UV - 0.5) * vec2(900.0 / 1920.0, 900.0 / 1080.0);
    vec3 source = texture(TEXTURE, source_uv).rgb;
    float surface = dot(source, vec3(0.299, 0.587, 0.114));
    float relief = clamp((surface - 0.72) * 2.0, 0.0, 1.0);
    float rim_light = exp(-pow((radius - 0.842) * 28.0, 2.0));
    float illumination = 0.045 + 0.10 * (1.0 - smoothstep(-0.9, 0.55, p.x));
    vec3 moon = vec3(0.91, 0.94, 1.0) * (illumination + relief * 0.025 + rim_light * 0.075);
    float disk = 1.0 - smoothstep(0.845, 0.874, radius);
    float halo = exp(-pow((radius - 0.865) * 23.0, 2.0)) * 0.08;
    float alpha = clamp(disk + halo, 0.0, 1.0);
    COLOR = vec4(moon, alpha) * item_tint;
}
