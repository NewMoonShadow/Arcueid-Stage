shader_type canvas_item;

void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    float radius = length(p);
    float inner = exp(-radius * radius * 8.0) * 0.28;
    float outer = exp(-pow((radius - 0.56) * 5.6, 2.0)) * 0.22;
    float alpha = (inner + outer) * (1.0 - smoothstep(0.76, 1.0, radius));
    COLOR = vec4(0.23, 0.48, 0.92, alpha);
}
