extends SceneTree
## Builds demo/machine: a chain-reaction machine in 3D. A marble is let go, drops through a trapdoor, is thrown
## through a hoop, knocks over a row of dominoes, and the last domino presses a button that fires a cannon at a
## tower of blocks. One schematic on the scene's root runs all of it; nothing else in the scene has a script.
## Run: godot --headless --path . --script res://tests/make_machine.gd
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

const DIR := "res://demo/machine/"
const DEPTH := 1.2            # how wide the track is, front to back
const MARBLE := 0.3           # the marble's radius
# Collision layers: 1 = everything solid, 2 = the tower's blocks, 4 = the marble and the dominoes.
const SOLID := 1
const BLOCK := 2
const MOVER := 4

const TRACK := Color(0.74, 0.73, 0.7)
const TEAL := Color(0.16, 0.74, 0.7)
const BLUE := Color(0.28, 0.52, 1.0)
const GREEN := Color(0.42, 0.84, 0.36)
const RED := Color(0.95, 0.24, 0.2)
const ORANGE := Color(1.0, 0.6, 0.12)
const DARK := Color(0.17, 0.19, 0.23)
const SKY := Color(0.075, 0.085, 0.105)
# The camera looks at CAM_AIM from CAM_FAR metres away, turned CAM_YAW to the right and raised CAM_PITCH.
const CAM_AIM := Vector3(5.9, 2.95, 0.0)
const CAM_FAR := 47.0
const CAM_YAW := 16.0
const CAM_PITCH := 9.0
const CAM_FOV := 30.0
const PASTELS := [Color(1.0, 0.56, 0.52), Color(1.0, 0.8, 0.45), Color(0.56, 0.86, 0.6), Color(0.5, 0.76, 1.0), Color(0.78, 0.62, 1.0)]

var top: Node3D
var mats := {}
var grip: PhysicsMaterial


func mat(color: Color, glow := 0.0, rough := 0.55, metal := 0.0) -> StandardMaterial3D:
	var key := "%s %s %s %s" % [color.to_html(), glow, rough, metal]
	if not mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = rough
		m.metallic = metal
		if glow > 0.0:
			m.emission_enabled = true
			m.emission = color
			m.emission_energy_multiplier = glow
		mats[key] = m
	return mats[key]


func add(parent: Node, node: Node, node_name: String) -> Node:
	node.name = node_name
	parent.add_child(node)
	return node


func mesh_box(parent: Node, size: Vector3, at: Vector3, material: Material, node_name := "Mesh") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = material
	mi.position = at
	add(parent, mi, node_name)
	return mi


func shape_box(parent: Node, size: Vector3, at := Vector3.ZERO) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = at
	add(parent, cs, "Shape")


## A solid box: `body` gets a mesh and a collision shape of this size.
func solid(body: Node3D, size: Vector3, material: Material, at := Vector3.ZERO) -> void:
	mesh_box(body, size, at, material)
	shape_box(body, size, at)


func fixed(parent: Node, node_name: String, centre: Vector3, size: Vector3, material: Material, turn := 0.0) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.position = centre
	b.rotation.z = turn
	b.physics_material_override = grip
	add(parent, b, node_name)
	solid(b, size, material)
	return b


## A plank whose top surface runs from `a` to `b` (x, y).
func plank(parent: Node, node_name: String, a: Vector2, b: Vector2, material: Material, thick := 0.16) -> StaticBody3D:
	var along := b - a
	var up := Vector2(-along.y, along.x).normalized()
	var mid := (a + b) * 0.5 - up * thick * 0.5
	return fixed(parent, node_name, Vector3(mid.x, mid.y, 0.0), Vector3(along.length(), thick, DEPTH), material, along.angle())


## A post from the ground up to `top`, behind the track. Only for looks.
func post(parent: Node, head: Vector2) -> void:
	mesh_box(parent, Vector3(0.14, head.y, 0.14), Vector3(head.x, head.y * 0.5, -DEPTH * 0.5 + 0.12), mat(DARK, 0.0, 0.7), "Post")


func sensor(node_name: String, centre: Vector2, size: Vector2, depth := 1.0, mask := MOVER) -> Area3D:
	var a := Area3D.new()
	a.position = Vector3(centre.x, centre.y, 0.0)
	a.collision_layer = 0
	a.collision_mask = mask
	add(top, a, node_name)
	shape_box(a, Vector3(size.x, size.y, depth))
	return a


## A body that only moves in the plane of the track.
func flat(body: RigidBody3D) -> void:
	body.axis_lock_linear_z = true
	body.axis_lock_angular_x = true
	body.axis_lock_angular_y = true


func ball_mesh(parent: Node, radius: float, material: Material) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mi.mesh = sm
	mi.material_override = material
	add(parent, mi, "Mesh")
	var cs := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = radius
	cs.shape = ss
	add(parent, cs, "Shape")


func own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		own(c, owner)


func save_scene(node: Node, file: String) -> bool:
	own(node, node)
	var ps := PackedScene.new()
	if ps.pack(node) != OK:
		return false
	return ResourceSaver.save(ps, DIR + file) == OK


# ---------------------------------------------------------------- the cannonball

func build_cannonball() -> bool:
	var ball := RigidBody3D.new()
	ball.name = "Cannonball"
	ball.mass = 20.0
	ball.continuous_cd = true
	ball.collision_layer = SOLID
	ball.collision_mask = SOLID | BLOCK | MOVER
	flat(ball)
	ball_mesh(ball, 0.28, mat(Color(0.1, 0.11, 0.13), 0.0, 0.3, 0.8))
	var ok := save_scene(ball, "cannonball.tscn")
	ball.free()
	return ok


# ---------------------------------------------------------------- the graph

func n(g: Dictionary, kind: String, x: float, y: float, p := {}, d := {}) -> Dictionary:
	var node := Model.add_node(g, kind, Vector2(x, y), p)
	node.d = d
	return node


func w(g: Dictionary, a: Dictionary, a_pin: String, b: Dictionary, b_pin: String) -> void:
	g.wires.append([int(a.id), a_pin, int(b.id), b_pin])


func entered(g: Dictionary, path: String, y: float) -> Dictionary:
	return n(g, "signal_event", 80, y, {"path": path, "signal": "body_entered", "cls": "Area3D", "args": [["body", "Node3D"]]})


## One lane per part of the machine, top to bottom in the order they happen.
func build_graph() -> Dictionary:
	var bp := Model.new_schematic("Node3D", "SC_Machine")
	bp.description = "Runs the whole chain reaction: each frame in the graph is one part of the machine."
	bp.variables.append({"name": "blocks_down", "type": "int", "default": "", "export": false, "category": "", "tooltip": "How many of the tower's blocks have reached the ground."})
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	g.next_id = 1
	var pitch := 400.0
	var y := 90.0

	# 1. the gate
	var ready := n(g, "event", 80, y, {"name": "_ready"})
	var wait1 := n(g, "tpl", 500, y, {"id": "wait"}, {"duration": "1.2"})
	var gate := n(g, "get_node", 640, y + 150, {"path": "Gate", "cls": "AnimatableBody3D"})
	var lift := n(g, "tpl", 940, y, {"id": "tween_property"}, {"property": "\"position:y\"", "final": "6.25", "duration": "0.25"})
	w(g, ready, "then", wait1, "exec")
	w(g, wait1, "then", lift, "exec")
	w(g, gate, "node", lift, "target")
	n(g, "comment", 40, y - 70, {"text": "1. Gate: lift it, and the marble rolls", "w": 1540, "h": 290})

	# 2. the trapdoor
	y += pitch
	var on_trap := entered(g, "TrapSensor", y)
	var wait2 := n(g, "tpl", 500, y, {"id": "wait"}, {"duration": "0.45"})
	var door := n(g, "get_node", 640, y + 150, {"path": "Trapdoor", "cls": "AnimatableBody3D"})
	var open := n(g, "tpl", 940, y, {"id": "tween_property"}, {"property": "\"rotation:z\"", "final": "-1.4", "duration": "0.2"})
	w(g, on_trap, "then", wait2, "exec")
	w(g, wait2, "then", open, "exec")
	w(g, door, "node", open, "target")
	n(g, "comment", 40, y - 70, {"text": "2. Trapdoor: hold the marble a moment, then drop it", "w": 1540, "h": 290})

	# 3. the launcher
	y += pitch
	var on_pad := entered(g, "Launcher", y)
	var as_body := n(g, "cast", 460, y, {"cls": "RigidBody3D"})
	var throw := n(g, "set_prop", 1010, y, {"cls": "RigidBody3D", "prop": "linear_velocity"}, {"value": "Vector3(2.4, 5.6, 0.0)"})
	w(g, on_pad, "then", as_body, "exec")
	w(g, on_pad, "p_body", as_body, "obj")
	w(g, as_body, "then", throw, "exec")
	w(g, as_body, "as", throw, "target")
	n(g, "comment", 40, y - 70, {"text": "3. Launcher: throw the marble through the hoop", "w": 1540, "h": 290})

	# 4. the cannon
	y += pitch
	var on_button := entered(g, "Button", y)
	var once := n(g, "do_once", 430, y)
	var muzzle := n(g, "get_node", 440, y + 170, {"path": "Cannon/Muzzle", "cls": "Marker3D"})
	var shot := n(g, "spawn", 690, y, {"xt": "Transform3D"}, {"scene": "preload(\"%scannonball.tscn\")" % DIR})
	var fire := n(g, "set_prop", 1130, y, {"cls": "RigidBody3D", "prop": "linear_velocity"}, {"value": "Vector3(20.0, 1.0, 0.0)"})
	w(g, on_button, "then", once, "exec")
	w(g, once, "then", shot, "exec")
	w(g, muzzle, "node", shot, "parent")
	w(g, shot, "then", fire, "exec")
	w(g, shot, "ret", fire, "target")
	n(g, "comment", 40, y - 70, {"text": "4. Cannon: the last domino presses the button", "w": 1540, "h": 290})

	# 5. the count
	y += pitch
	var on_floor := entered(g, "Floor", y)
	var count := n(g, "var_inc", 420, y, {"name": "blocks_down", "by": 1})
	var words := n(g, "format", 700, y + 110, {"text": "Blocks down: {count}"})
	var label := n(g, "get_node", 910, y + 88, {"path": "UI/Counter", "cls": "Label"})
	var show := n(g, "set_prop", 1130, y, {"cls": "Label", "prop": "text"})
	w(g, on_floor, "then", count, "exec")
	w(g, count, "then", show, "exec")
	w(g, count, "value", words, "f_count")
	w(g, label, "node", show, "target")
	w(g, words, "ret", show, "value")
	n(g, "comment", 40, y - 70, {"text": "5. Count: every block that reaches the ground", "w": 1540, "h": 290})

	# and again
	y += pitch
	var on_timer := n(g, "signal_event", 80, y, {"path": "Restart", "signal": "timeout", "cls": "Timer", "args": []})
	var again := n(g, "tpl", 420, y, {"id": "reload_scene"})
	w(g, on_timer, "then", again, "exec")
	n(g, "comment", 40, y - 70, {"text": "Then set it all up again", "w": 760, "h": 230})
	return bp


# ---------------------------------------------------------------- the scene

func build_scene(script: Script) -> bool:
	top = Node3D.new()
	top.name = "Machine"
	grip = PhysicsMaterial.new()
	grip.friction = 0.9
	var track := mat(TRACK)

	# light and air
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.7, 0.85)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.15
	env.ssao_enabled = true
	env.fog_enabled = true                      # the ground fades into the background instead of ending at a line
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.0
	env.fog_depth_begin = 46.0
	env.fog_depth_end = 80.0
	var we := WorldEnvironment.new()
	we.environment = env
	add(top, we, "WorldEnvironment")
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -28, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.shadow_blur = 1.6
	sun.directional_shadow_max_distance = 90.0
	add(top, sun, "Sun")
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 40, 0)
	fill.light_color = Color(0.6, 0.72, 1.0)
	fill.light_energy = 0.3
	add(top, fill, "Fill")
	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = CAM_FOV
	add(top, cam, "Camera")
	var yaw := deg_to_rad(CAM_YAW)
	var pitch := deg_to_rad(CAM_PITCH)
	cam.look_at_from_position(CAM_AIM + CAM_FAR * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)), CAM_AIM)

	# the ground and the wall behind
	var ground := fixed(top, "Ground", Vector3(5, -0.25, -40), Vector3(300, 0.5, 160), mat(Color(0.12, 0.14, 0.17), 0.0, 0.85))
	ground.collision_layer = SOLID

	var parts := Node3D.new()
	add(top, parts, "Track")

	# 1. the first ramp and its gate
	plank(parts, "Ramp1", Vector2(-5.2, 5.36), Vector2(-3.0, 4.7), track)
	fixed(parts, "Stop1", Vector3(-5.28, 5.55, 0), Vector3(0.16, 0.6, DEPTH), track)
	post(parts, Vector2(-5.0, 5.1))
	post(parts, Vector2(-3.15, 4.55))
	var gate := AnimatableBody3D.new()
	gate.position = Vector3(-4.2, 5.5, 0)
	add(top, gate, "Gate")
	solid(gate, Vector3(0.12, 1.0, DEPTH), mat(TEAL, 0.25))

	# 2. the trapdoor, hinged at its left end, and the wall that stops the marble over it
	var door := AnimatableBody3D.new()
	door.position = Vector3(-3.0, 4.7, 0)
	door.physics_material_override = grip
	add(top, door, "Trapdoor")
	solid(door, Vector3(1.0, 0.12, DEPTH), mat(BLUE, 0.25), Vector3(0.5, -0.06, 0))
	fixed(parts, "TrapWall", Vector3(-1.9, 4.6, 0), Vector3(0.2, 1.8, DEPTH), track)
	sensor("TrapSensor", Vector2(-2.45, 5.0), Vector2(0.5, 0.5))

	# 3. the second ramp and the launcher at its end
	plank(parts, "Ramp2", Vector2(-2.95, 3.0), Vector2(-0.6, 2.4), track)
	fixed(parts, "Stop2", Vector3(-3.05, 3.2, 0), Vector3(0.2, 0.7, DEPTH), track)
	plank(parts, "Pad", Vector2(-0.6, 2.4), Vector2(0.3, 2.4), mat(GREEN, 0.35))
	post(parts, Vector2(-2.8, 2.8))
	post(parts, Vector2(-0.1, 2.25))
	sensor("Launcher", Vector2(-0.1, 2.75), Vector2(0.3, 0.5))
	var hoop := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.58
	ring.outer_radius = 0.7
	hoop.mesh = ring
	hoop.material_override = mat(ORANGE, 1.6)
	hoop.position = Vector3(0.87, 4.3, 0)
	hoop.rotation.z = PI / 2.0
	add(top, hoop, "Hoop")

	# 4. the landing slope, the long table and the dominoes
	plank(parts, "Landing", Vector2(1.6, 1.55), Vector2(3.6, 1.2), track)
	fixed(parts, "Stop3", Vector3(1.5, 1.8, 0), Vector3(0.2, 0.8, DEPTH), track)
	plank(parts, "Table", Vector2(3.6, 1.2), Vector2(9.3, 1.2), track)
	for px in [1.8, 3.6, 5.5, 7.4, 9.1]:
		post(parts, Vector2(px, 1.05))
	var dominoes := Node3D.new()
	add(top, dominoes, "Dominoes")
	for i in 6:
		var dom := RigidBody3D.new()
		dom.position = Vector3(4.6 + 0.45 * i, 1.2 + 0.45, 0)
		dom.mass = 0.25
		dom.collision_layer = SOLID | MOVER
		dom.collision_mask = SOLID | BLOCK | MOVER
		flat(dom)
		add(dominoes, dom, "Domino%d" % (i + 1))
		solid(dom, Vector3(0.12, 0.9, 0.7), mat(Color(1.0, 0.45, 0.62).lerp(Color(0.6, 0.45, 1.0), i / 5.0), 0.15))

	# 5. the button and the cannon
	sensor("Button", Vector2(7.5, 1.35), Vector2(0.4, 0.3))
	var cap := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.24
	disc.bottom_radius = 0.24
	disc.height = 0.06
	cap.mesh = disc
	cap.material_override = mat(RED, 0.8)
	cap.position = Vector3(7.5, 1.23, 0)
	add(top, cap, "ButtonCap")
	var cannon := StaticBody3D.new()
	cannon.position = Vector3(8.45, 1.4, 0)
	add(top, cannon, "Cannon")
	solid(cannon, Vector3(0.7, 0.4, 0.8), mat(DARK, 0.0, 0.5, 0.3))
	var barrel := MeshInstance3D.new()
	var tube := CylinderMesh.new()
	tube.top_radius = 0.3
	tube.bottom_radius = 0.36
	tube.height = 1.1
	barrel.mesh = tube
	barrel.material_override = mat(DARK, 0.0, 0.35, 0.6)
	barrel.position = Vector3(0.2, 0.45, 0)
	barrel.rotation.z = -PI / 2.0 + 0.09
	add(cannon, barrel, "Barrel")
	var band := MeshInstance3D.new()
	var hoop2 := CylinderMesh.new()
	hoop2.top_radius = 0.33
	hoop2.bottom_radius = 0.33
	hoop2.height = 0.12
	band.mesh = hoop2
	band.material_override = mat(ORANGE, 0.9)
	band.position = Vector3(0.7, 0.495, 0)
	band.rotation.z = -PI / 2.0 + 0.09
	add(cannon, band, "Band")
	var muzzle := Marker3D.new()
	muzzle.position = Vector3(0.75, 0.45, 0)
	add(cannon, muzzle, "Muzzle")

	# 6. the tower
	fixed(parts, "Pedestal", Vector3(11.2, 0.4, 0), Vector3(1.7, 0.8, 1.2), track)
	var tower := Node3D.new()
	add(top, tower, "Tower")
	var number := 0
	for level in 6:
		for col in 3:
			for row in 2:
				number += 1
				var block := RigidBody3D.new()
				block.position = Vector3(10.7 + 0.5 * col, 0.8 + 0.25 + 0.5 * level, -0.25 + 0.5 * row)
				block.mass = 0.25
				block.collision_layer = SOLID | BLOCK
				block.collision_mask = SOLID | BLOCK | MOVER
				add(tower, block, "Block%d" % number)
				solid(block, Vector3.ONE * 0.5, mat(PASTELS[(level + col + row) % PASTELS.size()], 0.12))
	sensor("Floor", Vector2(13.0, 0.15), Vector2(12.0, 0.3), 14.0, BLOCK)

	# the marble
	var marble := RigidBody3D.new()
	marble.position = Vector3(-4.62, 5.52, 0)
	marble.mass = 2.0
	marble.continuous_cd = true
	marble.can_sleep = false          # it waits at the gate, and a sleeping body would not notice the gate lifting
	marble.collision_layer = SOLID | MOVER
	marble.collision_mask = SOLID | BLOCK | MOVER
	marble.physics_material_override = grip
	flat(marble)
	add(top, marble, "Marble")
	ball_mesh(marble, MARBLE, mat(ORANGE, 0.75, 0.25))
	var glow := OmniLight3D.new()
	glow.light_color = ORANGE
	glow.light_energy = 1.2
	glow.omni_range = 3.0
	add(marble, glow, "Glow")
	var trail := CPUParticles3D.new()
	trail.amount = 36
	trail.lifetime = 0.45
	trail.local_coords = false
	trail.gravity = Vector3.ZERO
	trail.spread = 0.0
	trail.initial_velocity_min = 0.0
	trail.initial_velocity_max = 0.0
	var dot := SphereMesh.new()
	dot.radius = 0.16
	dot.height = 0.32
	dot.radial_segments = 12
	dot.rings = 6
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot_mat.vertex_color_use_as_albedo = true
	dot_mat.albedo_color = Color(1, 1, 1, 1)
	dot.material = dot_mat
	trail.mesh = dot
	var shrink := Curve.new()
	shrink.add_point(Vector2(0, 1))
	shrink.add_point(Vector2(1, 0))
	trail.scale_amount_curve = shrink
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 0.72, 0.2, 0.55))
	fade.set_color(1, Color(1.0, 0.45, 0.1, 0.0))
	trail.color_ramp = fade
	trail.position = Vector3(0, 0, -0.05)
	add(marble, trail, "Trail")

	# the count and the timer that starts it all again
	var ui := CanvasLayer.new()
	add(top, ui, "UI")
	var counter := Label.new()
	counter.text = "Blocks down: 0"
	counter.anchor_left = 1.0
	counter.anchor_right = 1.0
	counter.offset_left = -520.0
	counter.offset_right = -32.0
	counter.offset_top = 20.0
	counter.offset_bottom = 80.0
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var ls := LabelSettings.new()
	ls.font_size = 40
	ls.outline_size = 8
	ls.outline_color = Color(0.03, 0.04, 0.06)
	counter.label_settings = ls
	add(ui, counter, "Counter")
	var timer := Timer.new()
	timer.wait_time = 16.0
	timer.one_shot = true
	timer.autostart = true
	add(top, timer, "Restart")

	top.set_script(script)
	var ok := save_scene(top, "machine.tscn")
	top.free()
	return ok


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()
	var fails := 0
	if not build_cannonball():
		fails += 1
		print("FAIL cannonball.tscn was not saved")
	var bp := build_graph()
	var c := Compiler.new()
	var code := c.compile(bp)
	for e in c.errors:
		print("  ", "warning " if e.w else "ERROR ", e.m)
		if not e.w:
			fails += 1
	var f := FileAccess.open(DIR + "SC_Machine.gd", FileAccess.WRITE)
	f.store_string(Model.build_source(code, bp))
	f.close()
	var script := ResourceLoader.load(DIR + "SC_Machine.gd", "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if script == null or not build_scene(script):
		fails += 1
		print("FAIL machine.tscn was not saved")
	print("MACHINE FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
