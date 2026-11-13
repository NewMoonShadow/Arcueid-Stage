shader_type canvas_item;
render_mode unshaded;

uniform float angle = 0.0;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float c = cos(angle);
	float s = sin(angle);
	vec2 q = mat2(vec2(c, -s), vec2(s, c)) * p;
	float outer = length(q) - 0.58;
	float cutout = length(q - vec2(0.0, -0.23)) - 0.55;
	float distance_to_moon = max(outer, -cutout);
	float moon = 1.0 - smoothstep(-0.025, 0.025, distance_to_moon);
	float halo = exp(-max(distance_to_moon, 0.0) * 15.0);
	float direction = atan(q.y, q.x);
	float shimmer = 0.65 + 0.35 * sin(direction * 2.0 + angle * 2.0);
	float glow = halo * 0.30 * shimmer;
	float edge_fade = 1.0 - smoothstep(0.82, 1.0, length(p));
	vec3 blue = mix(vec3(0.08, 0.48, 0.92), vec3(0.26, 0.81, 1.0), clamp(q.y + 0.6, 0.0, 1.0));
	COLOR = vec4(mix(vec3(0.08, 0.63, 1.0), blue, moon), max(moon, glow) * edge_fade);
}
