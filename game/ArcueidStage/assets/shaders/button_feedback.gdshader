shader_type canvas_item;
render_mode unshaded;

uniform float hover = 0.0;
uniform float press = 0.0;
uniform float sweep = 1.2;
uniform float pulse = 1.0;
uniform vec2 origin = vec2(0.5);
uniform vec2 pointer = vec2(0.5);

void fragment() {
	float extent = mix(0.12, 0.47, hover);
	float horizontal = 1.0 - smoothstep(extent - 0.08, extent, abs(UV.x - 0.5));
	float line = exp(-abs(UV.y - 0.92) * 135.0) * horizontal * hover;
	float halo = exp(-abs(UV.y - 0.88) * 13.0) * horizontal * hover * 0.11;
	float glint = exp(-pow((UV.x - sweep) * 18.0, 2.0)) * hover;
	float glow = glint * exp(-abs(UV.y - 0.8) * 5.0) * 0.13;
	float distance = length((UV - origin) * vec2(1.0, 0.45));
	float ripple = exp(-abs(distance - pulse * 1.2) * 55.0) * (1.0 - pulse) * 0.28;
	float pressed = press * 0.09 * (1.0 - smoothstep(0.05, 0.7, length(UV - vec2(0.5))));
	float alpha = clamp(line * 0.85 + halo + glow + ripple + pressed, 0.0, 1.0);
	COLOR *= vec4(mix(vec3(0.15, 0.72, 1.0), vec3(0.72, 0.98, 1.0), glint), alpha);
}
