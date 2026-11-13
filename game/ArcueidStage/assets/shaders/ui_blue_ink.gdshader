shader_type canvas_item;
render_mode unshaded;

uniform float hover = 0.0;
uniform float disabled = 0.0;

void fragment() {
    vec3 base = mix(vec3(0.025, 0.19, 0.31), vec3(0.012, 0.04, 0.19), UV.y);
    float drift = sin(UV.x * 8.0 - TIME * 0.65 + sin(UV.y * 7.0 + TIME * 0.3));
    float wash = exp(-pow((UV.y - 0.35 - drift * 0.16) * 3.8, 2.0));
    base += vec3(0.01, 0.15, 0.26) * wash * (0.2 + hover * 0.65);
    base = mix(base, vec3(0.045, 0.08, 0.13), disabled * 0.72);
    // The wash has soft edges and is invisible at rest: no rectangular plate.
    float softness = exp(-dot((UV - vec2(0.5)) * vec2(2.0, 1.8), (UV - vec2(0.5)) * vec2(2.0, 1.8)) * 2.0);
    COLOR *= vec4(base + vec3(0.02, 0.32, 0.5), hover * softness * 0.3 * (1.0 - disabled));
}
