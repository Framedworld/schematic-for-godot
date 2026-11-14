extends Node3D
## Vectors, colours, arrays, dictionaries and text, and changing them in place.

var out: Array = []
var spot := Vector3(1, 2, 3)
var tint := Color(0.2, 0.4, 0.6)
var frame := Transform3D.IDENTITY
var grid: Array = [[1, 2], [3, 4]]
var stats := {"hp": 10, "pos": Vector2(1, 1), "tags": ["a"], "deep": {"n": 1}}
var samples := PackedFloat32Array([1.0, 2.0, 3.0])
var names: Array[String] = ["b", "a", "c"]
var partner: Node3D


func _ready() -> void:
	# members of a property, of a member and of a local
	position.x += 2.5
	position.y = -position.x
	position *= 2
	rotation.z = PI / 2
	scale = Vector3.ONE * 2
	scale.y *= 0.5
	spot.z -= 1
	spot += Vector3.UP
	tint.r = 1.0
	tint.a *= 0.5
	frame.origin.x = 4
	frame.basis.x = Vector3(0, 0, 1)
	var local := Vector2(3, 4)
	local.x *= 2
	local = local.normalized() * 10
	out.append([position, rotation, scale, spot, tint, frame, local, local.length(), spot.length_squared()])
	# another node's properties
	partner = Node3D.new()
	partner.name = "Partner"
	add_child(partner)
	partner.position.y = 5
	partner.position += Vector3(1, 0, 1)
	partner.transform.origin.z *= 3
	partner.scale.x += 1
	partner.visible = not partner.visible
	out.append([partner.position, partner.scale, partner.visible, partner.global_position, partner.get_parent() == self, get_child_count()])
	# arrays
	grid[0][1] = 20
	grid[1].append(5)
	grid.append([6])
	grid[-1][0] += 1
	var flat := []
	for row in grid:
		for cell in row:
			flat.append(cell)
	flat.sort()
	flat.reverse()
	var sliced := flat.slice(1, 4)
	out.append([grid, flat, sliced, flat.size(), flat.has(20), flat.find(5), flat.front(), flat.back(), flat.max(), flat.min(), flat.count(1),
		flat.pop_back(), flat.pop_front(), flat, [1, 2, 3].is_empty(), [] == [], flat[1], flat[-1]])
	names.sort()
	names.push_front("z")
	names.erase("a")
	names.insert(1, "m")
	out.append([names, ", ".join(names), names.is_typed(), names.get_typed_builtin() == TYPE_STRING])
	samples.append(4.5)
	samples[0] = 9.5
	var copy := samples.duplicate()
	copy[1] = -1.0
	out.append([samples, copy, samples.size(), Array(samples).map(func(s): return s * 2)])
	# dictionaries
	stats.hp -= 3
	stats["mp"] = 4
	stats.pos.x = 7
	stats.tags.append("b")
	stats.deep.n += 1
	stats["deep"]["m"] = [stats.hp]
	stats.erase("missing")
	var keys := stats.keys()
	keys.sort()
	out.append([stats, keys, stats.size(), stats.has("hp"), stats.get("none", "fallback"), stats.get("hp"), "mp" in stats, stats.values().size()])
	var merged := {"a": 1}
	merged.merge({"a": 2, "b": 3})
	merged.merge({"a": 9}, true)
	out.append(merged)
	# text
	var text := "Hello, World"
	out.append([text.length(), text.to_upper(), text.to_lower(), text.substr(7), text.left(5), text.right(5), text.find("o"), text.rfind("o"),
		text.replace("l", "L"), text.split(", "), text.begins_with("Hell"), text.ends_with("x"), text.contains("lo, W"), text[0], text[-1],
		text.reverse(), "  pad ".strip_edges(), "a,b,,c".split(",", false), "%s|%s" % [text.pad_zeros(3), "7".pad_zeros(3)], "x".repeat(3),
		"snake_case_name".to_pascal_case(), "PascalName".to_snake_case(), "3.5".to_float(), "42".to_int(), "abc".is_valid_int(), text.hash() != 0,
		"é".length(), "a" < "b", "apple".similarity("apply") > 0.5, text.count("l"), text.get_slice(",", 0), text.capitalize(), String.num(3.14159, 2)])
	var built := ""
	for i in 3:
		built += str(i) + ("," if i < 2 else "")
	built = built.insert(0, "[") + "]"
	out.append([built, StringName("x") == &"x", &"sn" + "str", NodePath("A/B:prop").get_name(1), NodePath("A/B:prop").get_subname(0), str(^"A/B")])
	# numbers
	out.append([absi(-3), absf(-2.5), clampi(15, 0, 10), clampf(0.5, 0.0, 1.0), lerpf(0.0, 10.0, 0.25), snappedf(3.14159, 0.01), roundi(2.5), floori(-2.5),
		ceili(2.1), mini(3, 7), maxf(1.5, 0.5), signf(-4.0), wrapi(11, 0, 10), fposmod(-1.0, 3.0), posmod(-1, 3), sqrt(16.0), pow(2.0, 8.0), min(1, 2.5, -3),
		max(4, 9.5), is_equal_approx(0.1 + 0.2, 0.3), int(7.9), float(3), int("12"), float("1.5"), bool(0), bool(2.5), str(1.0), typeof(1.0) == TYPE_FLOAT,
		deg_to_rad(180.0), move_toward(0.0, 10.0, 3.0), smoothstep(0.0, 1.0, 0.5), is_zero_approx(0.0000001), remap(5.0, 0.0, 10.0, 0.0, 1.0), 10 / 4, 10 % 4, 10.0 / 4])
