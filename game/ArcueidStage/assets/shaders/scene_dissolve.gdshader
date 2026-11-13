shader_type canvas_item;
render_mode unshaded;

uniform float progress = 0.0;
uniform float aspect = 1.77778;
uniform vec2 origin = vec2(0.5, 0.38);

void fragment() {
	vec2 uv = (UV - origin) / (1.0 + progress * 0.025) + origin;
	vec2 blur = TEXTURE_PIXEL_SIZE * progress * 3.0;
	vec4 old = texture(TEXTURE, uv) * 0.4;
	old += texture(TEXTURE, uv + vec2(blur.x, 0.0)) * 0.15;
	old += texture(TEXTURE, uv - vec2(blur.x, 0.0)) * 0.15;
	old += texture(TEXTURE, uv + vec2(0.0, blur.y)) * 0.15;
	old += texture(TEXTURE, uv - vec2(0.0, blur.y)) * 0.15;
	float reach = length(max(origin, vec2(1.0) - origin) * vec2(aspect, 1.0));
	float radius = mix(-0.36, reach + 0.36, progress);
	float distance = length((UV - origin) * vec2(aspect, 1.0));
	float cover = smoothstep(radius - 0.34, radius + 0.34, distance);
	float moonlight = exp(-pow((distance - radius) / 0.25, 2.0)) * sin(progress * 3.14159);
	old.rgb = mix(old.rgb, vec3(0.36, 0.64, 0.80), moonlight * 0.13);
	COLOR = vec4(old.rgb, old.a * cover);
}
