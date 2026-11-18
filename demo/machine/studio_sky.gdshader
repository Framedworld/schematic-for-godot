shader_type sky;

// A neutral photo studio for reflections in the enamel and brass.
float softbox(vec3 direction, vec3 normal, vec2 extent, float feather) {
	vec3 right = normalize(cross(normal, vec3(0.0, 1.0, 0.0)));
	vec3 up = cross(right, normal);
	float depth = dot(direction, normal);
	vec2 uv = abs(vec2(dot(direction, right), dot(direction, up))) / max(depth, 0.001);
	vec2 mask = 1.0 - smoothstep(extent, extent + feather, uv);
	return mask.x * mask.y * step(0.0, depth);
}

void sky() {
	vec3 d = EYEDIR;
	float top = smoothstep(-0.05, 0.9, d.y);
	vec3 light = mix(vec3(0.077, 0.092, 0.097), vec3(0.22, 0.235, 0.24), top);
	light += vec3(4.8, 4.15, 3.3) * softbox(d, normalize(vec3(-0.6, 0.9, 0.8)), vec2(0.58, 0.25), 0.06);
	light += vec3(1.6, 2.2, 2.6) * softbox(d, normalize(vec3(0.75, 0.4, -0.7)), vec2(0.16, 0.8), 0.055);
	light += vec3(2.2, 1.95, 1.6) * softbox(d, normalize(vec3(0.2, 0.85, 0.45)), vec2(0.04, 0.85), 0.02);
	COLOR = light;
}
