extends SceneTree
## Generates a small complete game made only of blueprints (res://demo/game): a player you move with the
## arrow keys, coins spawned by a game blueprint, and a HUD that listens to the player's event dispatcher.
## Blueprints refer to each other by class name, so run it, import, and run it again until it says "complete":
##   godot --headless --path . --script res://tests/make_game.gd ; godot --headless --path . --import
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const Compiler := preload("res://addons/blueprints/core/bp_compiler.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")

const DIR := "res://demo/game/"
var problems := 0


func wire(g, a, ap, b, bp_) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func save(bp: Dictionary, file: String) -> void:
	var c := Compiler.new()
	var code := c.compile(bp)
	for e in c.errors:
		print("  ", file, " ERROR: ", e.m)
		problems += 1
	var f := FileAccess.open(DIR + file, FileAccess.WRITE)
	f.store_string(Model.build_source(code, bp))
	f.close()


func text(file: String, content: String) -> void:
	var f := FileAccess.open(DIR + file, FileAccess.WRITE)
	f.store_string(content)
	f.close()


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()

	# ------------------------------------------------------------ BP_Player
	var pl := Model.new_blueprint("CharacterBody2D", "BP_Player")
	pl.description = "Top-down player. Arrow keys move it; coins call Add Score."
	pl.variables.append({"name": "speed", "type": "float", "default": "220.0", "export": true, "category": "Movement", "tooltip": "Pixels per second."})
	pl.variables.append({"name": "score", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	pl.dispatchers.append({"name": "score_changed", "params": [["new_score", "int"]]})
	var pg: Dictionary = pl.graphs[0]
	var p_ready: Dictionary = pg.nodes[0]
	pg.nodes.remove_at(1)
	var p_grp := Model.add_node(pg, "tpl", Vector2(320, 80), {"id": "add_to_group"})
	p_grp.d["group"] = "&\"player\""
	wire(pg, p_ready, "then", p_grp, "exec")
	var p_phys := Model.add_node(pg, "event", Vector2(80, 300), {"name": "_physics_process"})
	var p_in := Model.add_node(pg, "tpl", Vector2(80, 470), {"id": "input_vector"})
	var p_speed := Model.add_node(pg, "var_get", Vector2(330, 600), {"name": "speed"})
	var p_mul := Model.add_node(pg, "math", Vector2(520, 500), {"op": "*", "n": 2})
	var p_vel := Model.add_node(pg, "set_prop", Vector2(700, 300), {"cls": "CharacterBody2D", "prop": "velocity"})
	var p_move := Model.add_node(pg, "call", Vector2(980, 300), {"cls": "CharacterBody2D", "method": "move_and_slide"})
	wire(pg, p_in, "ret", p_mul, "a0")
	wire(pg, p_speed, "value", p_mul, "a1")
	wire(pg, p_mul, "ret", p_vel, "value")
	wire(pg, p_phys, "then", p_vel, "exec")
	wire(pg, p_vel, "then", p_move, "exec")
	var pf := Model.new_graph(pl, "add_score", "function")
	pf.inputs = [["amount", "int"]]
	pf.nodes.remove_at(1)
	var pf_get := Model.add_node(pf, "var_get", Vector2(80, 300), {"name": "score"})
	var pf_add := Model.add_node(pf, "math", Vector2(260, 280), {"op": "+", "n": 2})
	var pf_set := Model.add_node(pf, "var_set", Vector2(420, 120), {"name": "score"})
	var pf_emit := Model.add_node(pf, "emit", Vector2(680, 120), {"name": "score_changed"})
	wire(pf, pf.nodes[0], "then", pf_set, "exec")
	wire(pf, pf_get, "value", pf_add, "a0")
	wire(pf, pf.nodes[0], "p_amount", pf_add, "a1")
	wire(pf, pf_add, "ret", pf_set, "value")
	wire(pf, pf_set, "then", pf_emit, "exec")
	wire(pf, pf_set, "out", pf_emit, "a_new_score")
	save(pl, "BP_Player.gd")
	if not T.class_known("BP_Player"):
		print("phase 1 written (BP_Player). Import the project and run again.")
		quit()
		return

	# ------------------------------------------------------------ BP_Coin
	var co := Model.new_blueprint("Area2D", "BP_Coin")
	co.description = "Gives its value to the player that touches it, then removes itself."
	co.variables.append({"name": "value", "type": "int", "default": "5", "export": true, "spawn": true, "category": "", "tooltip": "Score given when collected."})
	var cg: Dictionary = co.graphs[0]
	cg.nodes.clear()
	var c_ev := Model.add_node(cg, "signal_event", Vector2(80, 80), {"path": ".", "signal": "body_entered", "cls": "Area2D", "args": [["body", "Node2D"]]})
	var c_cast := Model.add_node(cg, "cast", Vector2(380, 80), {"cls": "BP_Player"})
	var c_val := Model.add_node(cg, "var_get", Vector2(520, 280), {"name": "value"})
	var c_add := Model.add_node(cg, "call", Vector2(700, 80), {"cls": "BP_Player", "method": "add_score"})
	var c_die := Model.add_node(cg, "tpl", Vector2(980, 80), {"id": "destroy_node"})
	wire(cg, c_ev, "then", c_cast, "exec")
	wire(cg, c_ev, "p_body", c_cast, "obj")
	wire(cg, c_cast, "then", c_add, "exec")
	wire(cg, c_cast, "as", c_add, "target")
	wire(cg, c_val, "value", c_add, "a0")
	wire(cg, c_add, "then", c_die, "exec")
	save(co, "BP_Coin.gd")
	text("coin.tscn", """[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://demo/game/BP_Coin.gd" id="1"]

[sub_resource type="CircleShape2D" id="shape"]
radius = 12.0

[node name="Coin" type="Area2D"]
script = ExtResource("1")

[node name="Shape" type="CollisionShape2D" parent="."]
shape = SubResource("shape")
""")

	# ------------------------------------------------------------ BP_HUD
	var hud := Model.new_blueprint("Label", "BP_HUD")
	hud.description = "Shows the player's score by listening to its score_changed dispatcher."
	var hg: Dictionary = hud.graphs[0]
	var h_ready: Dictionary = hg.nodes[0]
	hg.nodes.remove_at(1)
	var h_find := Model.add_node(hg, "tpl", Vector2(80, 260), {"id": "get_first_node_in_group"})
	h_find.d["group"] = "&\"player\""
	var h_cast := Model.add_node(hg, "cast", Vector2(340, 80), {"cls": "BP_Player"})
	var h_bind := Model.add_node(hg, "bind_signal", Vector2(660, 80), {"cls": "BP_Player", "signal": "score_changed"})
	var h_ref := Model.add_node(hg, "event_ref", Vector2(420, 280), {"fn": "OnScoreChanged"})
	var h_ev := Model.add_node(hg, "custom_event", Vector2(80, 460), {"name": "OnScoreChanged", "params": [["new_score", "int"]]})
	var h_fmt := Model.add_node(hg, "format", Vector2(300, 600), {"text": "Score: {score}"})
	var h_set := Model.add_node(hg, "set_prop", Vector2(620, 460), {"cls": "Label", "prop": "text"})
	wire(hg, h_ready, "then", h_cast, "exec")
	wire(hg, h_find, "ret", h_cast, "obj")
	wire(hg, h_cast, "then", h_bind, "exec")
	wire(hg, h_cast, "as", h_bind, "target")
	wire(hg, h_ref, "fn", h_bind, "fn")
	wire(hg, h_ev, "then", h_set, "exec")
	wire(hg, h_ev, "p_new_score", h_fmt, "f_score")
	wire(hg, h_fmt, "ret", h_set, "value")
	save(hud, "BP_HUD.gd")

	if not T.class_known("BP_Coin"):
		print("phase 2 written (BP_Coin, BP_HUD). Import the project and run again.")
		quit()
		return

	# ------------------------------------------------------------ BP_Game
	var gm := Model.new_blueprint("Node2D", "BP_Game")
	gm.description = "Spawns a row of coins worth 10, 20 and 30."
	var gg: Dictionary = gm.graphs[0]
	var g_ready: Dictionary = gg.nodes[0]
	gg.nodes.remove_at(1)
	var g_for := Model.add_node(gg, "for", Vector2(320, 80), {})
	g_for.d["last"] = "2"
	var g_spawn := Model.add_node(gg, "spawn", Vector2(620, 80), {"xt": "Transform2D"})
	g_spawn.d["scene"] = "preload(\"res://demo/game/coin.tscn\")"
	var g_plus := Model.add_node(gg, "math", Vector2(320, 360), {"op": "+", "n": 2})
	g_plus.d["a1"] = "1"
	var g_val := Model.add_node(gg, "math", Vector2(470, 360), {"op": "*", "n": 2})
	g_val.d["a1"] = "10"
	var g_step := Model.add_node(gg, "math", Vector2(620, 520), {"op": "*", "n": 2})
	g_step.d["a1"] = "80"
	var g_x := Model.add_node(gg, "math", Vector2(770, 520), {"op": "+", "n": 2})
	g_x.d["a1"] = "200"
	var ctor_i := 0
	var ctors: Array = R.api.types["Vector2"].ctor
	for i in ctors.size():
		if ctors[i].size() == 2 and ctors[i][0][1] == "float":
			ctor_i = i
	var g_vec := Model.add_node(gg, "ctor", Vector2(930, 500), {"type": "Vector2", "i": ctor_i})
	var g_pos := Model.add_node(gg, "set_prop", Vector2(1160, 80), {"cls": "Node2D", "prop": "position"})
	wire(gg, g_ready, "then", g_for, "exec")
	wire(gg, g_for, "body", g_spawn, "exec")
	wire(gg, g_for, "index", g_plus, "a0")
	wire(gg, g_plus, "ret", g_val, "a0")
	wire(gg, g_val, "ret", g_spawn, "x_value")
	wire(gg, g_for, "index", g_step, "a0")
	wire(gg, g_step, "ret", g_x, "a0")
	wire(gg, g_x, "ret", g_vec, "a0")
	wire(gg, g_spawn, "then", g_pos, "exec")
	wire(gg, g_spawn, "ret", g_pos, "target")
	wire(gg, g_vec, "ret", g_pos, "value")
	save(gm, "BP_Game.gd")
	text("main.tscn", """[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://demo/game/BP_Game.gd" id="1"]
[ext_resource type="Script" path="res://demo/game/BP_Player.gd" id="2"]
[ext_resource type="Script" path="res://demo/game/BP_HUD.gd" id="3"]

[sub_resource type="CircleShape2D" id="shape"]
radius = 14.0

[node name="Game" type="Node2D"]
script = ExtResource("1")

[node name="Player" type="CharacterBody2D" parent="."]
position = Vector2(80, 0)
motion_mode = 1
script = ExtResource("2")

[node name="Shape" type="CollisionShape2D" parent="Player"]
shape = SubResource("shape")

[node name="HUD" type="Label" parent="."]
offset_left = 20.0
offset_top = -120.0
text = "Score: 0"
script = ExtResource("3")

[node name="Camera2D" type="Camera2D" parent="."]
position = Vector2(280, 0)
""")
	print("complete: demo/game written with %d problem(s)" % problems)
	quit(1 if problems else 0)
