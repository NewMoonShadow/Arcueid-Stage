shader_type canvas_item;
render_mode unshaded;

uniform float hover = 0.0;
uniform vec2 control_size = vec2(200.0, 48.0);
uniform float font_height = 32.0;
uniform float grain = 0.0;
varying vec2 local_position;
varying vec4 tint;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float soft_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(cell), hash(cell + vec2(1.0, 0.0)), f.x),
               mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0)), f.x), f.y);
}

void vertex() {
    local_position = VERTEX;
    tint = COLOR;
}

void fragment() {
    float y = clamp((local_position.y - (control_size.y - font_height) * 0.5) / font_height, 0.0, 1.0);
    vec3 blue = mix(vec3(0.38, 0.90, 0.96), vec3(0.0, 0.30, 0.52), y);
    blue = mix(blue, mix(vec3(0.55, 1.0, 1.0), vec3(0.0, 0.65, 0.85), y), step(0.01, grain));
    float etched = soft_noise(local_position * vec2(0.12, 0.4)) - 0.5;
    float mottling = soft_noise(local_position * 0.035) - 0.5;
    float veins = sin(local_position.y * 0.46 + sin(local_position.x * 0.13) * 2.5);
    blue *= 1.0 + grain * (etched * 0.6 + mottling * 0.65 + veins * 0.16);
    float foreground = smoothstep(0.4, 0.8, max(tint.r, max(tint.g, tint.b)));
    COLOR.rgb = mix(COLOR.rgb, mix(vec3(0.97, 0.98, 1.0), blue, hover), foreground);
    // Blur only the glyph mask, never the rectangular control area.
    vec2 step_uv = TEXTURE_PIXEL_SIZE * 1.8;
    float halo = 0.0;
    halo += texture(TEXTURE, UV + vec2(step_uv.x, 0.0)).a;
    halo += texture(TEXTURE, UV - vec2(step_uv.x, 0.0)).a;
    halo += texture(TEXTURE, UV + vec2(0.0, step_uv.y)).a;
    halo += texture(TEXTURE, UV - vec2(0.0, step_uv.y)).a;
    COLOR.a = max(COLOR.a, halo * 0.045 * hover * foreground * tint.a);
}
