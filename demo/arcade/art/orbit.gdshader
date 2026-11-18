shader_type canvas_item;
render_mode unshaded;

float hash21(vec2 point) {
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 pixels = SCREEN_UV / SCREEN_PIXEL_SIZE;
	vec2 uv = (SCREEN_UV - 0.5) * vec2(SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, 1.0);
	float haze = (1.0 - smoothstep(0.0, 0.9, abs(uv.y + 0.32 * uv.x + 0.08)));
	vec3 color = mix(vec3(0.017, 0.034, 0.063), vec3(0.072, 0.15, 0.20), haze * 0.8);
	for (int layer = 0; layer < 2; layer++) {
		float index = float(layer);
		vec2 grid = (pixels + vec2(TIME * (1.1 + index), 0.0)) / (28.0 + 43.0 * index);
		vec2 cell = floor(grid);
		float h = hash21(cell + index * 31.1);
		vec2 center = vec2(h, hash21(cell + vec2(41.7, 18.5))) * 0.8 + 0.1;
		float distance_to_star = length(fract(grid) - center) * (28.0 + 43.0 * index);
		float star = (1.0 - smoothstep(0.15, 1.25 + index * 0.3, distance_to_star)) * step(0.72 + 0.10 * index, h);
		color += vec3(0.58, 0.72, 0.77) * star * (0.45 + 0.25 * sin(h * 70.0 + TIME));
	}
	COLOR = vec4(color, 1.0);
}
