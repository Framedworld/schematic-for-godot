shader_type spatial;
render_mode unshaded, cull_disabled;

varying vec3 studio_position;

void vertex() {
	studio_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// The wall and floor meet in the same world-space light field.
	float elevation = studio_position.y - 0.12 * studio_position.z;
	vec2 key_uv = (vec2(studio_position.x, elevation) - vec2(5.0, 5.8)) / vec2(7.8, 4.8);
	vec2 bounce_uv = (vec2(studio_position.x, elevation) - vec2(15.0, 3.0)) / vec2(5.0, 4.5);
	float key_pool = exp(-1.25 * dot(key_uv, key_uv));
	float bounce = exp(-dot(bounce_uv, bounce_uv));
	ALBEDO = vec3(0.004, 0.009, 0.011)
		+ key_pool * vec3(0.032, 0.045, 0.043)
		+ bounce * vec3(0.014, 0.012, 0.009);
}
