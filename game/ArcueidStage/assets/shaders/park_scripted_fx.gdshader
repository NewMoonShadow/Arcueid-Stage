shader_type canvas_item;
uniform bool eye_frame = false;
uniform bool speed_lines = false;
void fragment() {
	vec2 p = UV - vec2(0.5, 0.65);
	float angle = atan(p.y, p.x);
	float radial = smoothstep(0.35, 0.68, length(p));
	float rays = pow(abs(sin(angle * 35.0 + sin(angle * 11.0))), 50.0);
	float vignette = eye_frame ? 1.0 - smoothstep(0.025, 0.14, UV.y) * smoothstep(0.025, 0.14, 1.0 - UV.y) : 0.0;
	float streak = speed_lines ? rays * radial * 0.45 : 0.0;
	COLOR = vec4(vec3(streak > 0.0 ? 1.0 : 0.0), max(vignette, streak));
}
