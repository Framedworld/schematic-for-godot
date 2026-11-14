@tool
extends RefCounted
## Starter Schematics: ready-wired graphs offered when a new Schematic is created (Unreal's "pick a parent
## class" common classes, but already doing something). Each one is ordinary nodes, compiles on its own and
## refers to no other schematic by class, so any of them can be used alone. They find each other through
## groups instead: characters join "player", the Game State joins "game_state".

const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")

const LIST := [
	{"id": "topdown_2d", "name": "Top-Down Character (2D)", "file": "TopDownCharacter", "parent": "CharacterBody2D",
		"desc": "Moves in four directions with the arrow keys. Joins the 'player' group."},
	{"id": "platformer_2d", "name": "Platformer Character (2D)", "file": "PlatformerCharacter", "parent": "CharacterBody2D",
		"desc": "Runs left and right, falls with gravity and jumps. Joins the 'player' group."},
	{"id": "character_3d", "name": "Character (3D)", "file": "Character", "parent": "CharacterBody3D",
		"desc": "Walks on the ground plane, falls with gravity and jumps. Joins the 'player' group."},
	{"id": "pickup_2d", "name": "Pickup (2D)", "file": "Pickup", "parent": "Area2D",
		"desc": "Collected when a node in the 'player' group touches it: adds its value to the Game State's score, then removes itself."},
	{"id": "pickup_3d", "name": "Pickup (3D)", "file": "Pickup", "parent": "Area3D",
		"desc": "Collected when a node in the 'player' group touches it: adds its value to the Game State's score, then removes itself."},
	{"id": "trigger_2d", "name": "Trigger Volume (2D)", "file": "Trigger", "parent": "Area2D",
		"desc": "Calls its Entered and Exited event dispatchers when a node in the chosen group walks in or out."},
	{"id": "trigger_3d", "name": "Trigger Volume (3D)", "file": "Trigger", "parent": "Area3D",
		"desc": "Calls its Entered and Exited event dispatchers when a node in the chosen group walks in or out."},
	{"id": "projectile_2d", "name": "Projectile (2D)", "file": "Projectile", "parent": "Area2D",
		"desc": "Flies along its local X axis, damages what it hits (calls take_damage if present) and removes itself after its lifetime."},
	{"id": "projectile_3d", "name": "Projectile (3D)", "file": "Projectile", "parent": "Area3D",
		"desc": "Flies forward (local -Z), damages what it hits (calls take_damage if present) and removes itself after its lifetime."},
	{"id": "spawner_2d", "name": "Spawner (2D)", "file": "Spawner", "parent": "Node2D",
		"desc": "Spawns a scene at its own position on a repeating timer."},
	{"id": "spawner_3d", "name": "Spawner (3D)", "file": "Spawner", "parent": "Node3D",
		"desc": "Spawns a scene at its own position on a repeating timer."},
	{"id": "health", "name": "Health Component", "file": "Health", "parent": "Node",
		"desc": "Holds health, with Take Damage and Heal functions and Health Changed and Died event dispatchers. Add it as a child of anything that can be hurt."},
	{"id": "game_state", "name": "Game State", "file": "GameState", "parent": "Node",
		"desc": "Keeps the score. Joins the 'game_state' group so pickups can add to it and HUDs can listen to it."},
	{"id": "hud", "name": "Score HUD", "file": "HUD", "parent": "Label",
		"desc": "A label that shows the Game State's score and updates whenever it changes."},
	{"id": "data_asset", "name": "Data Asset (row structure)", "file": "ItemRow", "parent": "Resource",
		"desc": "A structure of fields, like an Unreal struct. Use it as the rows of a Data Table, or make single assets of it in the Inspector."},
	{"id": "function_library", "name": "Function Library", "file": "FunctionLibrary", "parent": "RefCounted",
		"desc": "Functions any schematic can call without an instance. They appear under Function Libraries in every action menu."},
	{"id": "interface", "name": "Schematic Interface", "file": "Interactable", "parent": "RefCounted",
		"desc": "A list of functions that other schematics agree to have. Call them on any object with a Message node; nothing happens if the object does not have them."},
	{"id": "macro_library", "name": "Macro Library", "file": "MacroLibrary", "parent": "RefCounted",
		"desc": "Macros shared with every schematic in the project. They appear under Macros in every action menu."},
]


## Every starter on offer: the built-in ones, then those of the kits whose addon is in the project.
static func all() -> Array:
	return LIST + Kits.starters()


static func find(id: String) -> Dictionary:
	for s in all():
		if s.id == id:
			return s
	return {}


## Starters meant for a node of class `cls` ("" = all of them). The general-purpose ones (parent Node, Node2D,
## Node3D) are offered only for exactly that class, so a CharacterBody2D is not offered a Game State.
static func fitting(cls := "") -> Array:
	var out := []
	for s in all():
		var general: bool = s.parent in ["Node", "Node2D", "Node3D"]
		if cls == "" or cls == s.parent or (not general and ClassDB.class_exists(cls) and ClassDB.is_parent_class(cls, s.parent)):
			out.append(s)
	return out


## A new schematic dictionary holding the starter's graph; {} for an unknown id.
static func build(id: String, cls_name := "") -> Dictionary:
	var s := find(id)
	if s.is_empty():
		return {}
	R.ensure_api()
	if bool(s.get("kit", false)):
		var kit_bp := Kits.build_starter(id, cls_name)
		if String(kit_bp.get("description", "")) == "":
			kit_bp["description"] = String(s.desc)
		return kit_bp
	var bp := Model.new_schematic(String(s.parent), cls_name)
	bp.description = String(s.desc)
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	g.next_id = 1
	match id:
		"topdown_2d": _topdown(bp, g)
		"platformer_2d": _character(bp, g, false)
		"character_3d": _character(bp, g, true)
		"pickup_2d": _pickup(bp, g, false)
		"pickup_3d": _pickup(bp, g, true)
		"trigger_2d": _trigger(bp, g, false)
		"trigger_3d": _trigger(bp, g, true)
		"projectile_2d": _projectile(bp, g, false)
		"projectile_3d": _projectile(bp, g, true)
		"spawner_2d": _spawner(bp, g, false)
		"spawner_3d": _spawner(bp, g, true)
		"health": _health(bp, g)
		"game_state": _game_state(bp, g)
		"hud": _hud(bp, g)
		"data_asset": _data_asset(bp, g)
		"function_library": _function_library(bp, g)
		"macro_library": _macro_library(bp, g)
		"interface": _interface(bp, g)
	return bp


# ---------------------------------------------------------------- small building helpers

static func _n(g: Dictionary, kind: String, x: float, y: float, p := {}, d := {}) -> Dictionary:
	var n := Model.add_node(g, kind, Vector2(x, y), p)
	n.d = d
	return n


static func _w(g: Dictionary, a: Dictionary, a_pin: String, b: Dictionary, b_pin: String) -> void:
	g.wires.append([int(a.id), a_pin, int(b.id), b_pin])


static func _var(bp: Dictionary, name: String, type: String, default := "", export := false, tip := "", cat := "") -> void:
	bp.variables.append({"name": name, "type": type, "default": default, "export": export, "category": cat, "tooltip": tip})


static func _frame(g: Dictionary, text: String, x: float, y: float, w: float, h: float) -> void:
	_n(g, "comment", x, y, {"text": text, "w": w, "h": h})


static func _vget(g: Dictionary, name: String, x: float, y: float) -> Dictionary:
	return _n(g, "var_get", x, y, {"name": name})


static func _math(g: Dictionary, op: String, x: float, y: float, d := {}) -> Dictionary:
	return _n(g, "math", x, y, {"op": op, "n": 2}, d)


## Index of the constructor of `type` that takes `count` floats (Vector2(x, y), Vector3(x, y, z)).
static func _float_ctor(type: String, count: int) -> int:
	var ctors: Array = R.api.types.get(type, {}).get("ctor", [])
	for i in ctors.size():
		if ctors[i].size() == count and String(ctors[i][0][1]) == "float":
			return i
	return 0


static func _function(bp: Dictionary, name: String, inputs: Array) -> Dictionary:
	var f := Model.new_graph(bp, name, "function")
	f.inputs = inputs
	f.nodes.remove_at(1)   # no outputs: the Return node is not needed
	return f


# ---------------------------------------------------------------- characters

static func _topdown(bp: Dictionary, g: Dictionary) -> void:
	_var(bp, "speed", "float", "220.0", true, "Pixels per second.", "Movement")
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var grp := _n(g, "tpl", 360, 80, {"id": "add_to_group"}, {"group": "&\"player\""})
	_w(g, ready, "then", grp, "exec")
	_frame(g, "Pickups, triggers and HUDs look for the 'player' group", 40, 10, 680, 190)
	var phys := _n(g, "event", 80, 340, {"name": "_physics_process"})
	var dir := _n(g, "tpl", 80, 520, {"id": "input_vector"})
	var speed := _vget(g, "speed", 360, 660)
	var mul := _math(g, "*", 560, 540)
	var vel := _n(g, "set_prop", 760, 340, {"cls": "CharacterBody2D", "prop": "velocity"})
	var move := _n(g, "call", 1060, 340, {"cls": "CharacterBody2D", "method": "move_and_slide"})
	_w(g, dir, "ret", mul, "a0")
	_w(g, speed, "value", mul, "a1")
	_w(g, mul, "ret", vel, "value")
	_w(g, phys, "then", vel, "exec")
	_w(g, vel, "then", move, "exec")
	_frame(g, "Move: arrow keys (change the actions on Get Input Vector to use your own)", 40, 270, 1300, 470)


## Gravity, jump and walking for CharacterBody2D (side view) or CharacterBody3D.
static func _character(bp: Dictionary, g: Dictionary, three: bool) -> void:
	var cls := "CharacterBody3D" if three else "CharacterBody2D"
	var vt := "Vector3" if three else "Vector2"
	var ci := _float_ctor(vt, 3 if three else 2)
	_var(bp, "speed", "float", "5.0" if three else "300.0", true, "Walking speed (%s per second)." % ("metres" if three else "pixels"), "Movement")
	_var(bp, "jump_velocity", "float", "4.5" if three else "-450.0", true,
		"Upward speed at the start of a jump." + ("" if three else " Negative, because Y points down in 2D."), "Movement")
	_var(bp, "gravity", "float", "9.8" if three else "980.0", true, "Downward acceleration while in the air.", "Movement")

	var ready := _n(g, "event", 80, 20, {"name": "_ready"})
	var grp := _n(g, "tpl", 360, 20, {"id": "add_to_group"}, {"group": "&\"player\""})
	_w(g, ready, "then", grp, "exec")

	var phys := _n(g, "event", 80, 300, {"name": "_physics_process"})
	var seq := _n(g, "sequence", 360, 300, {"n": 3})
	_w(g, phys, "then", seq, "exec")
	var parts := func(x: float, y: float) -> Dictionary:
		var v := _n(g, "get_prop", x, y, {"cls": cls, "prop": "velocity"})
		var b := _n(g, "break", x + 240, y, {"type": vt})
		_w(g, v, "value", b, "v")
		return b
	var make := func(x: float, y: float, keep: Dictionary, keep_pins: Array) -> Dictionary:
		var c := _n(g, "ctor", x, y, {"type": vt, "i": ci})
		for kp in keep_pins:
			_w(g, keep, "m_" + String(kp[0]), c, String(kp[1]))
		return c
	var set_vel := func(x: float, y: float, value: Dictionary) -> Dictionary:
		var s := _n(g, "set_prop", x, y, {"cls": cls, "prop": "velocity"})
		_w(g, value, "ret", s, "value")
		return s
	var side := [["x", "a0"], ["z", "a2"]] if three else [["x", "a0"]]

	# The lanes start at x0, leaving a clear gutter for the three wires coming down from the Sequence.
	var x0 := 1000.0

	# lane 1: gravity while in the air
	var y1 := 300.0
	_frame(g, "Gravity: fall while not on the floor", x0 - 40, y1 - 70, 1500, 450)
	var floor1 := _n(g, "call", x0, y1 + 130, {"cls": cls, "method": "is_on_floor"})
	var b1 := _n(g, "branch", x0 + 280, y1)
	_w(g, seq, "then_0", b1, "exec")
	_w(g, floor1, "ret", b1, "cond")
	var p1: Dictionary = parts.call(x0, y1 + 270)
	var grav := _vget(g, "gravity", x0 + 300, y1 + 150)
	var gd := _math(g, "*", x0 + 500, y1 + 140)
	_w(g, grav, "value", gd, "a0")
	_w(g, phys, "p_delta", gd, "a1")
	var vy := _math(g, "-" if three else "+", x0 + 680, y1 + 210)
	_w(g, p1, "m_y", vy, "a0")
	_w(g, gd, "ret", vy, "a1")
	var c1: Dictionary = make.call(x0 + 860, y1 + 200, p1, side)
	_w(g, vy, "ret", c1, "a1")
	var s1: Dictionary = set_vel.call(x0 + 1160, y1, c1)
	_w(g, b1, "false", s1, "exec")

	# lane 2: jump
	var y2 := y1 + 520.0
	_frame(g, "Jump: only from the floor (ui_accept is Space / Enter)", x0 - 40, y2 - 70, 1500, 480)
	var floor2 := _n(g, "call", x0, y2 + 110, {"cls": cls, "method": "is_on_floor"})
	var pressed := _n(g, "call", x0, y2 + 230, {"cls": "Input", "method": "is_action_just_pressed"}, {"a0": "&\"ui_accept\""})
	var both := _math(g, "and", x0 + 310, y2 + 130)
	_w(g, floor2, "ret", both, "a0")
	_w(g, pressed, "ret", both, "a1")
	var b2 := _n(g, "branch", x0 + 500, y2)
	var r2 := _n(g, "reroute", x0 - 120, y2 + 30, {"t": "exec"})   # keeps the wire in the gutter, clear of lane 1
	_w(g, seq, "then_1", r2, "i")
	_w(g, r2, "o", b2, "exec")
	_w(g, both, "ret", b2, "cond")
	var p2: Dictionary = parts.call(x0 + 330, y2 + 300)
	var jump := _vget(g, "jump_velocity", x0 + 600, y2 + 190)
	var c2: Dictionary = make.call(x0 + 860, y2 + 200, p2, side)
	_w(g, jump, "value", c2, "a1")
	var s2: Dictionary = set_vel.call(x0 + 1160, y2, c2)
	_w(g, b2, "true", s2, "exec")

	# lane 3: walk, then let the physics body move
	var y3 := y2 + 550.0
	_frame(g, "Move: arrow keys, then Move And Slide applies the velocity", x0 - 40, y3 - 70, 1800, 520)
	var p3: Dictionary = parts.call(x0 + 330, y3 + 340)
	var c3 := _n(g, "ctor", x0 + 860, y3 + 200, {"type": vt, "i": ci})
	_w(g, p3, "m_y", c3, "a1")
	if three:
		var dir := _n(g, "tpl", x0, y3 + 110, {"id": "input_vector"})
		var db := _n(g, "break", x0 + 330, y3 + 110, {"type": "Vector2"})
		_w(g, dir, "ret", db, "v")
		var sp := _vget(g, "speed", x0 + 380, y3 + 240)
		var mx := _math(g, "*", x0 + 620, y3 + 110)
		var mz := _math(g, "*", x0 + 620, y3 + 220)
		_w(g, db, "m_x", mx, "a0")
		_w(g, sp, "value", mx, "a1")
		_w(g, db, "m_y", mz, "a0")
		_w(g, sp, "value", mz, "a1")
		_w(g, mx, "ret", c3, "a0")
		_w(g, mz, "ret", c3, "a2")
	else:
		var axis := _n(g, "tpl", x0, y3 + 110, {"id": "input_axis"})
		var sp := _vget(g, "speed", x0 + 380, y3 + 240)
		var mx := _math(g, "*", x0 + 620, y3 + 140)
		_w(g, axis, "ret", mx, "a0")
		_w(g, sp, "value", mx, "a1")
		_w(g, mx, "ret", c3, "a0")
	var s3: Dictionary = set_vel.call(x0 + 1160, y3, c3)
	var r3 := _n(g, "reroute", x0 - 180, y3 + 30, {"t": "exec"})
	_w(g, seq, "then_2", r3, "i")
	_w(g, r3, "o", s3, "exec")
	var move := _n(g, "call", x0 + 1460, y3, {"cls": cls, "method": "move_and_slide"})
	_w(g, s3, "then", move, "exec")


# ---------------------------------------------------------------- things in the world

static func _pickup(bp: Dictionary, g: Dictionary, three: bool) -> void:
	var cls := "Area3D" if three else "Area2D"
	_var(bp, "value", "int", "1", true, "Score given when collected.")
	bp.dispatchers.append({"name": "collected", "params": [["by", "Node"]]})
	var ev := _n(g, "signal_event", 80, 120, {"path": ".", "signal": "body_entered", "cls": cls, "args": [["body", "Node3D" if three else "Node2D"]]})
	var is_player := _n(g, "tpl", 80, 330, {"id": "is_in_group"}, {"group": "&\"player\""})
	var br := _n(g, "branch", 420, 120)
	var emit := _n(g, "emit", 660, 120, {"name": "collected"})
	var state := _n(g, "tpl", 660, 330, {"id": "get_first_node_in_group"}, {"group": "&\"game_state\""})
	var value := _vget(g, "value", 760, 470)
	var add := _n(g, "tpl", 980, 120, {"id": "call_message"}, {"fn": "&\"add_score\""})
	var die := _n(g, "tpl", 1340, 120, {"id": "destroy_node"})
	_w(g, ev, "then", br, "exec")
	_w(g, ev, "p_body", is_player, "target")
	_w(g, is_player, "ret", br, "cond")
	_w(g, br, "true", emit, "exec")
	_w(g, ev, "p_body", emit, "a_by")
	_w(g, emit, "then", add, "exec")
	_w(g, state, "ret", add, "target")
	_w(g, value, "value", add, "arg")
	_w(g, add, "then", die, "exec")
	_frame(g, "Collected by anything in the 'player' group. Give this node a CollisionShape child.", 40, 40, 1560, 540)


static func _trigger(bp: Dictionary, g: Dictionary, three: bool) -> void:
	var cls := "Area3D" if three else "Area2D"
	var body_t := "Node3D" if three else "Node2D"
	_var(bp, "group", "StringName", "&\"player\"", true, "Only nodes in this group set the trigger off.")
	bp.dispatchers.append({"name": "entered", "params": [["body", "Node"]]})
	bp.dispatchers.append({"name": "exited", "params": [["body", "Node"]]})
	var y := 120.0
	for pair in [["body_entered", "entered"], ["body_exited", "exited"]]:
		var ev := _n(g, "signal_event", 80, y, {"path": ".", "signal": pair[0], "cls": cls, "args": [["body", body_t]]})
		var grp := _vget(g, "group", 80, y + 290)
		var in_group := _n(g, "tpl", 300, y + 190, {"id": "is_in_group"})
		var br := _n(g, "branch", 640, y)
		var emit := _n(g, "emit", 900, y, {"name": pair[1]})
		_w(g, ev, "then", br, "exec")
		_w(g, ev, "p_body", in_group, "target")
		_w(g, grp, "value", in_group, "group")
		_w(g, in_group, "ret", br, "cond")
		_w(g, br, "true", emit, "exec")
		_w(g, ev, "p_body", emit, "a_body")
		y += 460.0
	_frame(g, "Bind to Entered / Exited from another schematic, or continue the graph after the Call nodes", 40, 40, 1180, 880)


static func _projectile(bp: Dictionary, g: Dictionary, three: bool) -> void:
	var cls := "Area3D" if three else "Area2D"
	_var(bp, "speed", "float", "20.0" if three else "400.0", true, "%s per second." % ("Metres" if three else "Pixels"))
	_var(bp, "lifetime", "float", "3.0", true, "Seconds before it removes itself.")
	_var(bp, "damage", "float", "1.0", true, "Passed to take_damage on whatever it hits.")
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var life := _vget(g, "lifetime", 180, 230)
	var wait := _n(g, "delay", 360, 80)
	var expire := _n(g, "tpl", 640, 80, {"id": "destroy_node"})
	_w(g, ready, "then", wait, "exec")
	_w(g, life, "value", wait, "duration")
	_w(g, wait, "then", expire, "exec")
	_frame(g, "Lifetime", 40, 10, 900, 290)

	var phys := _n(g, "event", 80, 420, {"name": "_physics_process"})
	var speed := _vget(g, "speed", 180, 600)
	if three:
		var dist := _n(g, "math", 380, 560, {"op": "*", "n": 3}, {"a2": "-1.0"})
		_w(g, speed, "value", dist, "a0")
		_w(g, phys, "p_delta", dist, "a1")
		var offset := _n(g, "ctor", 560, 540, {"type": "Vector3", "i": _float_ctor("Vector3", 3)}, {"a0": "0.0", "a1": "0.0"})
		_w(g, dist, "ret", offset, "a2")
		var fly := _n(g, "call", 860, 420, {"cls": "Node3D", "method": "translate_object_local"})
		_w(g, offset, "ret", fly, "a0")
		_w(g, phys, "then", fly, "exec")
	else:
		var dist := _math(g, "*", 380, 560)
		_w(g, speed, "value", dist, "a0")
		_w(g, phys, "p_delta", dist, "a1")
		var fly := _n(g, "call", 640, 420, {"cls": "Node2D", "method": "move_local_x"})
		_w(g, dist, "ret", fly, "a0")
		_w(g, phys, "then", fly, "exec")
	_frame(g, "Fly forward", 40, 350, 1160, 360)

	var hit := _n(g, "signal_event", 80, 840, {"path": ".", "signal": "body_entered", "cls": cls, "args": [["body", "Node3D" if three else "Node2D"]]})
	var dmg := _vget(g, "damage", 260, 1040)
	var hurt := _n(g, "tpl", 460, 840, {"id": "call_message"}, {"fn": "&\"take_damage\""})
	var die := _n(g, "tpl", 820, 840, {"id": "destroy_node"})
	_w(g, hit, "then", hurt, "exec")
	_w(g, hit, "p_body", hurt, "target")
	_w(g, dmg, "value", hurt, "arg")
	_w(g, hurt, "then", die, "exec")
	_frame(g, "Hit: the body's take_damage function is called if it has one", 40, 770, 1160, 370)


static func _spawner(bp: Dictionary, g: Dictionary, three: bool) -> void:
	_var(bp, "scene", "PackedScene", "", true, "The scene to spawn.")
	_var(bp, "interval", "float", "2.0", true, "Seconds between spawns.")
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var timer := _n(g, "tpl", 420, 80, {"id": "set_timer"}, {"looping": "true"})
	var ref := _n(g, "event_ref", 120, 240, {"fn": "SpawnOne"})
	var every := _vget(g, "interval", 200, 320)
	_w(g, ready, "then", timer, "exec")
	_w(g, ref, "fn", timer, "event")
	_w(g, every, "value", timer, "time")
	_frame(g, "Start a repeating timer", 40, 10, 760, 400)
	var ev := _n(g, "custom_event", 80, 520, {"name": "SpawnOne", "params": []})
	var scene_a := _vget(g, "scene", 140, 680)
	var ok := _n(g, "is_valid", 380, 520)
	var scene_b := _vget(g, "scene", 480, 720)
	var spawn := _n(g, "spawn", 700, 520, {"xt": "Transform3D" if three else "Transform2D"})
	_w(g, ev, "then", ok, "exec")
	_w(g, scene_a, "value", ok, "obj")
	_w(g, ok, "valid", spawn, "exec")
	_w(g, scene_b, "value", spawn, "scene")
	_frame(g, "Spawn one as a child of this node (set Scene in the Inspector)", 40, 450, 1040, 400)


# ---------------------------------------------------------------- game rules and UI

static func _health(bp: Dictionary, g: Dictionary) -> void:
	_var(bp, "max_health", "float", "100.0", true, "Health at the start, and the most Heal can restore.")
	_var(bp, "health", "float", "", false, "Current health.")
	bp.dispatchers.append({"name": "health_changed", "params": [["health", "float"], ["max_health", "float"]]})
	bp.dispatchers.append({"name": "died", "params": []})
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var full := _vget(g, "max_health", 180, 240)
	var fill := _n(g, "var_set", 400, 80, {"name": "health"})
	_w(g, ready, "then", fill, "exec")
	_w(g, full, "value", fill, "value")
	_frame(g, "Start at full health. Call Take Damage / Heal from other schematics; bind to Health Changed and Died.", 40, 10, 1000, 330)

	var td := _function(bp, "take_damage", [["amount", "float"]])
	var t_in: Dictionary = td.nodes[0]
	var t_cur := _vget(td, "health", 80, 320)
	var t_sub := _math(td, "-", 300, 300)
	var t_floor := _n(td, "util", 460, 300, {"name": "maxf"}, {"a1": "0.0"})
	var t_set := _n(td, "var_set", 700, 120, {"name": "health"})
	var t_max := _vget(td, "max_health", 760, 320)
	var t_emit := _n(td, "emit", 980, 120, {"name": "health_changed"})
	var t_dead := _math(td, "<=", 1100, 340, {"a1": "0.0"})
	var t_br := _n(td, "branch", 1320, 120)
	var t_died := _n(td, "emit", 1560, 120, {"name": "died"})
	_w(td, t_cur, "value", t_sub, "a0")
	_w(td, t_in, "p_amount", t_sub, "a1")
	_w(td, t_sub, "ret", t_floor, "a0")
	_w(td, t_in, "then", t_set, "exec")
	_w(td, t_floor, "ret", t_set, "value")
	_w(td, t_set, "then", t_emit, "exec")
	_w(td, t_set, "out", t_emit, "a_health")
	_w(td, t_max, "value", t_emit, "a_max_health")
	_w(td, t_emit, "then", t_br, "exec")
	_w(td, t_set, "out", t_dead, "a0")
	_w(td, t_dead, "ret", t_br, "cond")
	_w(td, t_br, "true", t_died, "exec")

	var hl := _function(bp, "heal", [["amount", "float"]])
	var h_in: Dictionary = hl.nodes[0]
	var h_cur := _vget(hl, "health", 80, 320)
	var h_add := _math(hl, "+", 300, 300)
	var h_max := _vget(hl, "max_health", 300, 420)
	var h_cap := _n(hl, "util", 480, 300, {"name": "minf"})
	var h_set := _n(hl, "var_set", 720, 120, {"name": "health"})
	var h_max2 := _vget(hl, "max_health", 780, 320)
	var h_emit := _n(hl, "emit", 1000, 120, {"name": "health_changed"})
	_w(hl, h_cur, "value", h_add, "a0")
	_w(hl, h_in, "p_amount", h_add, "a1")
	_w(hl, h_add, "ret", h_cap, "a0")
	_w(hl, h_max, "value", h_cap, "a1")
	_w(hl, h_in, "then", h_set, "exec")
	_w(hl, h_cap, "ret", h_set, "value")
	_w(hl, h_set, "then", h_emit, "exec")
	_w(hl, h_set, "out", h_emit, "a_health")
	_w(hl, h_max2, "value", h_emit, "a_max_health")


static func _game_state(bp: Dictionary, g: Dictionary) -> void:
	_var(bp, "score", "int", "", false, "The current score.")
	bp.dispatchers.append({"name": "score_changed", "params": [["new_score", "int"]]})
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var grp := _n(g, "tpl", 360, 80, {"id": "add_to_group"}, {"group": "&\"game_state\""})
	_w(g, ready, "then", grp, "exec")
	_frame(g, "Pickups and HUDs find the Game State through the 'game_state' group", 40, 10, 720, 200)
	var f := _function(bp, "add_score", [["amount", "int"]])
	var f_in: Dictionary = f.nodes[0]
	var cur := _vget(f, "score", 80, 320)
	var add := _math(f, "+", 300, 300)
	var store := _n(f, "var_set", 480, 120, {"name": "score"})
	var emit := _n(f, "emit", 760, 120, {"name": "score_changed"})
	_w(f, cur, "value", add, "a0")
	_w(f, f_in, "p_amount", add, "a1")
	_w(f, f_in, "then", store, "exec")
	_w(f, add, "ret", store, "value")
	_w(f, store, "then", emit, "exec")
	_w(f, store, "out", emit, "a_new_score")


static func _hud(bp: Dictionary, g: Dictionary) -> void:
	var ready := _n(g, "event", 80, 80, {"name": "_ready"})
	var show := _n(g, "call_self", 360, 80, {"fn": "OnScoreChanged"}, {"a_new_score": "0"})
	var state := _n(g, "tpl", 360, 280, {"id": "get_first_node_in_group"}, {"group": "&\"game_state\""})
	var ok := _n(g, "is_valid", 700, 80)
	var state2 := _n(g, "tpl", 700, 280, {"id": "get_first_node_in_group"}, {"group": "&\"game_state\""})
	var ref := _n(g, "event_ref", 760, 400, {"fn": "OnScoreChanged"})
	var bind := _n(g, "call", 1060, 80, {"cls": "Object", "method": "connect"}, {"a0": "&\"score_changed\""})
	_w(g, ready, "then", show, "exec")
	_w(g, show, "then", ok, "exec")
	_w(g, state, "ret", ok, "obj")
	_w(g, ok, "valid", bind, "exec")
	_w(g, state2, "ret", bind, "target")
	_w(g, ref, "fn", bind, "a1")
	_frame(g, "Listen to the Game State's Score Changed dispatcher (if there is a Game State)", 40, 10, 1420, 490)
	var ev := _n(g, "custom_event", 80, 620, {"name": "OnScoreChanged", "params": [["new_score", "int"]]})
	var fmt := _n(g, "format", 300, 780, {"text": "Score: {score}"})
	var put := _n(g, "set_prop", 660, 620, {"cls": "Label", "prop": "text"})
	_w(g, ev, "then", put, "exec")
	_w(g, ev, "p_new_score", fmt, "f_score")
	_w(g, fmt, "ret", put, "value")
	_frame(g, "Show the score", 40, 550, 960, 400)


# ---------------------------------------------------------------- libraries

static func _data_asset(bp: Dictionary, g: Dictionary) -> void:
	bp["library"] = "data"
	_var(bp, "display_name", "String", "", true, "Shown to the player.")
	_var(bp, "icon", "Texture2D", "", true, "Picture for menus and the HUD.")
	_var(bp, "value", "int", "0", true, "What it is worth.")
	_var(bp, "weight", "float", "1.0", true, "How heavy it is.")
	_var(bp, "stackable", "bool", "true", true, "Can several share one inventory slot?")
	_frame(g, "A data asset only needs variables: each one is a field. Rename, add and remove them in My Schematic.", 40, 40, 1000, 160)


static func _function_library(bp: Dictionary, g: Dictionary) -> void:
	bp["library"] = "function"
	_frame(g, "A function library has no events. Add functions in My Schematic; every schematic can call them.", 40, 40, 900, 160)
	var f := Model.new_graph(bp, "percent", "function")
	f.inputs = [["value", "float"], ["maximum", "float"]]
	f.outputs = [["result", "float"]]
	f.pure = true
	var entry: Dictionary = f.nodes[0]
	var ret: Dictionary = f.nodes[1]
	ret.x = 760.0
	var div := _math(f, "/", 320, 300)
	var mul := _math(f, "*", 520, 300, {"a1": "100.0"})
	_w(f, entry, "then", ret, "exec")
	_w(f, entry, "p_value", div, "a0")
	_w(f, entry, "p_maximum", div, "a1")
	_w(f, div, "ret", mul, "a0")
	_w(f, mul, "ret", ret, "r_result")
	_frame(f, "Example: value as a percentage of maximum. Pure, so it has no exec pins where it is used.", 40, 40, 1000, 420)


static func _interface(bp: Dictionary, g: Dictionary) -> void:
	bp["library"] = "interface"
	_frame(g, "An interface has no events and no code. Add functions in My Schematic and give each its inputs and outputs; schematics that implement the interface (Class Settings > Interfaces) fill them in.", 40, 40, 1000, 160)
	var f := Model.new_graph(bp, "interact", "function")
	f.inputs = [["instigator", "Node"]]
	_w(f, f.nodes[0], "then", f.nodes[1], "exec")
	_frame(f, "Only the name, the inputs and the outputs matter here (Details panel). Nodes placed in this graph are not used.", 40, 40, 900, 420)


static func _macro_library(bp: Dictionary, g: Dictionary) -> void:
	bp["library"] = "macro"
	_frame(g, "A macro library only needs macros. Add them in My Schematic; every schematic can use them.", 40, 40, 900, 160)
	var m := Model.new_graph(bp, "Repeat", "macro")
	m.inputs = [["In", "exec"], ["Times", "int"]]
	m.outputs = [["Body", "exec"], ["Index", "int"], ["Done", "exec"]]
	var m_in: Dictionary = m.nodes[0]
	var m_out: Dictionary = m.nodes[1]
	m_out.x = 900.0
	var last := _math(m, "-", 300, 300, {"a1": "1"})
	var loop := _n(m, "for", 520, 120)
	_w(m, m_in, "i_In", loop, "exec")
	_w(m, m_in, "i_Times", last, "a0")
	_w(m, last, "ret", loop, "last")
	_w(m, loop, "body", m_out, "o_Body")
	_w(m, loop, "index", m_out, "o_Index")
	_w(m, loop, "completed", m_out, "o_Done")
	_frame(m, "Example: runs Body the given number of times, then Done", 40, 40, 1160, 420)
