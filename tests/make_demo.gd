extends SceneTree
## Generates the demo schematic (res://demo/SC_Demo.gd).
## Run: godot --headless --path . --script res://tests/make_demo.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")


func wire(g, a, ap, b, bp_) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func _init() -> void:
	var bp := Model.new_schematic("Node3D", "SC_Demo")
	bp.description = "Demo schematic: spins and bounces its node. Press Space (jump) to change speed."
	bp.variables.append({"name": "spin_speed", "type": "float", "default": "90.0", "export": true, "category": "Motion", "tooltip": "Degrees per second."})
	bp.variables.append({"name": "bounce_height", "type": "float", "default": "0.5", "export": true, "category": "Motion", "tooltip": "How high the node bounces."})
	bp.variables.append({"name": "time", "type": "float", "default": "", "export": false, "category": "", "tooltip": ""})
	bp.dispatchers.append({"name": "speed_changed", "params": [["new_speed", "float"]]})
	var g: Dictionary = bp.graphs[0]
	var ready: Dictionary = g.nodes[0]
	var proc: Dictionary = g.nodes[1]
	ready.x = 60; ready.y = 60
	proc.x = 60; proc.y = 330

	# Ready -> Print -> Sequence -> (Delay -> Print) / Print
	var pr := Model.add_node(g, "print", Vector2(300, 60), {})
	pr.d["text"] = "\"Hello from a Schematic!\""
	var seq := Model.add_node(g, "sequence", Vector2(600, 60), {"n": 2})
	var dl := Model.add_node(g, "delay", Vector2(820, 30), {})
	dl.d["duration"] = "1.0"
	var pr2 := Model.add_node(g, "print", Vector2(1080, 30), {})
	pr2.d["text"] = "\"...one second later\""
	var pr3 := Model.add_node(g, "print", Vector2(820, 170), {})
	pr3.d["text"] = "\"Sequence does not wait for the Delay\""
	wire(g, ready, "then", pr, "exec")
	wire(g, pr, "then", seq, "exec")
	wire(g, seq, "then_0", dl, "exec")
	wire(g, dl, "then", pr2, "exec")
	wire(g, seq, "then_1", pr3, "exec")

	# Process -> rotate_y(deg_to_rad(spin_speed) * delta) -> time += delta -> position = (0, wave(time), 0)
	var gs := Model.add_node(g, "var_get", Vector2(60, 500), {"name": "spin_speed"})
	var d2r := Model.add_node(g, "util", Vector2(230, 480), {"name": "deg_to_rad"})
	var mul := Model.add_node(g, "op", Vector2(470, 470), {"op": "*", "l": "float", "r": "float", "ret": "float"})
	var rot := Model.add_node(g, "call", Vector2(620, 330), {"cls": "Node3D", "method": "rotate_y"})
	wire(g, gs, "value", d2r, "a0")
	wire(g, d2r, "ret", mul, "a")
	wire(g, proc, "p_delta", mul, "b")
	wire(g, proc, "then", rot, "exec")
	wire(g, mul, "ret", rot, "a0")
	var gt := Model.add_node(g, "var_get", Vector2(640, 520), {"name": "time"})
	var add := Model.add_node(g, "op", Vector2(790, 500), {"op": "+", "l": "float", "r": "float", "ret": "float"})
	var st := Model.add_node(g, "var_set", Vector2(940, 330), {"name": "time"})
	wire(g, gt, "value", add, "a")
	wire(g, proc, "p_delta", add, "b")
	wire(g, add, "ret", st, "value")
	wire(g, rot, "then", st, "exec")
	var wave := Model.add_node(g, "call_self", Vector2(1120, 500), {"fn": "wave"})
	var mk := Model.add_node(g, "ctor", Vector2(1340, 470), {"type": "Vector3", "i": 3})
	var sp := Model.add_node(g, "set_prop", Vector2(1580, 330), {"cls": "Node3D", "prop": "position"})
	wire(g, st, "out", wave, "a_t")
	wire(g, wave, "r_height", mk, "a1")
	wire(g, mk, "ret", sp, "value")
	wire(g, st, "then", sp, "exec")

	# InputAction jump -> FlipFlop -> speed * 2 / speed / 2 -> Call speed_changed
	var ia := Model.add_node(g, "input_action", Vector2(60, 720), {"action": "jump"})
	var ff := Model.add_node(g, "flip_flop", Vector2(330, 720), {})
	var gs2 := Model.add_node(g, "var_get", Vector2(330, 900), {"name": "spin_speed"})
	var m2 := Model.add_node(g, "op", Vector2(520, 860), {"op": "*", "l": "float", "r": "float", "ret": "float"})
	m2.d["b"] = "4.0"
	var dv := Model.add_node(g, "op", Vector2(520, 960), {"op": "/", "l": "float", "r": "float", "ret": "float"})
	dv.d["b"] = "4.0"
	var sa := Model.add_node(g, "var_set", Vector2(700, 700), {"name": "spin_speed"})
	var sb := Model.add_node(g, "var_set", Vector2(700, 830), {"name": "spin_speed"})
	var em := Model.add_node(g, "emit", Vector2(1000, 740), {"name": "speed_changed"})
	wire(g, ia, "pressed", ff, "exec")
	wire(g, ff, "a", sa, "exec")
	wire(g, ff, "b", sb, "exec")
	wire(g, gs2, "value", m2, "a")
	wire(g, gs2, "value", dv, "a")
	wire(g, m2, "ret", sa, "value")
	wire(g, dv, "ret", sb, "value")
	wire(g, sa, "then", em, "exec")
	wire(g, sb, "then", em, "exec")
	wire(g, sa, "out", em, "a_new_speed")
	Model.add_node(g, "comment", Vector2(30, 660), {"text": "Press Space: toggle fast / slow spin", "w": 1250.0, "h": 400.0})

	# Timeline "Pulse" (auto play, looping): Update -> scale = Vector3.ONE * Scale track
	var tl := Model.add_node(g, "timeline", Vector2(60, 1130), {"name": "Pulse", "length": 2.0, "loop": true, "autoplay": true,
		"tracks": [{"name": "Scale", "type": "float", "smooth": true, "keys": [[0.0, "1.0"], [1.0, "1.35"], [2.0, "1.0"]]}]})
	var one := Model.add_node(g, "const", Vector2(330, 1330), {"expr": "Vector3.ONE", "t": "Vector3", "label": "Vector3.ONE"})
	var vmul := Model.add_node(g, "op", Vector2(520, 1300), {"op": "*", "l": "Vector3", "r": "float", "ret": "Vector3"})
	var ssc := Model.add_node(g, "set_prop", Vector2(700, 1130), {"cls": "Node3D", "prop": "scale"})
	wire(g, tl, "update", ssc, "exec")
	wire(g, one, "value", vmul, "a")
	wire(g, tl, "t_Scale", vmul, "b")
	wire(g, vmul, "ret", ssc, "value")

	# macro "LogTwice": In -> print(text) -> print(text) -> Out ; used from the jump handler
	var mg := Model.new_graph(bp, "LogTwice", "macro")
	mg.inputs = [["In", "exec"], ["text", "String"]]
	mg.outputs = [["Out", "exec"]]
	var m_in: Dictionary = mg.nodes[0]
	var m_out: Dictionary = mg.nodes[1]
	m_out.x = 900
	var mp1 := Model.add_node(mg, "print", Vector2(320, 120), {})
	var mp2 := Model.add_node(mg, "print", Vector2(600, 120), {})
	wire(mg, m_in, "i_In", mp1, "exec")
	wire(mg, mp1, "then", mp2, "exec")
	wire(mg, mp2, "then", m_out, "o_Out")
	wire(mg, m_in, "i_text", mp1, "text")
	wire(mg, m_in, "i_text", mp2, "text")
	var mc := Model.add_node(g, "macro", Vector2(1010, 900), {"name": "LogTwice"})
	mc.d["i_text"] = "\"speed toggled\""
	wire(g, em, "then", mc, "i_In")

	# function wave(t) -> height = abs(sin(t * 3)) * bounce_height
	var fg := Model.new_graph(bp, "wave", "function")
	fg.pure = true
	fg.inputs = [["t", "float"]]
	fg.outputs = [["height", "float"]]
	var fe: Dictionary = fg.nodes[0]
	var fr: Dictionary = fg.nodes[1]
	fr.x = 1000
	var t3 := Model.add_node(fg, "op", Vector2(300, 260), {"op": "*", "l": "float", "r": "float", "ret": "float"})
	t3.d["b"] = "3.0"
	var sn := Model.add_node(fg, "util", Vector2(440, 250), {"name": "sin"})
	var ab := Model.add_node(fg, "util", Vector2(640, 250), {"name": "absf"})
	var bh := Model.add_node(fg, "var_get", Vector2(640, 360), {"name": "bounce_height"})
	var mh := Model.add_node(fg, "op", Vector2(850, 270), {"op": "*", "l": "float", "r": "float", "ret": "float"})
	wire(fg, fe, "p_t", t3, "a")
	wire(fg, t3, "ret", sn, "a0")
	wire(fg, sn, "ret", ab, "a0")
	wire(fg, ab, "ret", mh, "a")
	wire(fg, bh, "value", mh, "b")
	wire(fg, mh, "ret", fr, "r_height")
	wire(fg, fe, "then", fr, "exec")

	var c := Compiler.new()
	var code := c.compile(bp)
	for e in c.errors:
		print("ERROR: ", e)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://demo"))
	var f := FileAccess.open("res://demo/SC_Demo.gd", FileAccess.WRITE)
	f.store_string(Model.build_source(code, bp))
	f.close()
	print(code)
	quit()
