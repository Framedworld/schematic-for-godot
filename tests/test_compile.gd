extends SceneTree
## Headless compiler test: builds schematics in code, compiles them, loads the generated GDScript and runs it.
## Run: godot --headless --path . --script res://tests/test_compile.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")

var fails := 0

# A script long enough that the importer gives the far parameter `dt` a node of its own, a second event, a
# function, and a Match whose first case binds `p` and `q`.
const V7_SOURCE := "extends Node\n\nfunc _process(dt):\n\tvar a = 1\n\tprint(a)\n\tprint(a)\n\tprint(a)\n\tprint(a)\n\tprint(a)\n\tprint(dt * 2.0)\n\nfunc _physics_process(delta):\n\tprint(\"x\")\n\nfunc helper(x):\n\tprint(x)\n\nfunc _ready():\n\tvar v = [1, 2]\n\tmatch v:\n\t\t[var p, var q]:\n\t\t\tprint(p + q)\n\t\t_:\n\t\t\tprint(\"none\")\n\tprint(\"after\")\n"


func v7_check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label, "  ", detail)
		fails += 1


## The schematic the importer makes from V7_SOURCE.
func v7_bp() -> Dictionary:
	return Importer.new().convert(V7_SOURCE, {}).bp


func v7_name_nodes(g: Dictionary, bound: bool) -> Array:
	return g.nodes.filter(func(n): return n.kind == "const" and n.p.has("of") and bool(n.p.get("bound", false)) == bound)


## The print node that an event's chain starts with ("x" for _physics_process).
func v7_node(g: Dictionary, kind: String, key: String, value: Variant) -> Dictionary:
	for n in g.nodes:
		if n.kind == kind and (n.p.get(key) == value or n.d.get(key) == value):
			return n
	return {}


## Makes `src`'s value pin the only thing feeding `reader`'s pin.
func v7_feed(g: Dictionary, src: Dictionary, reader: Dictionary, pin: String) -> void:
	g.wires = g.wires.filter(func(w): return not (int(w[2]) == int(reader.id) and w[3] == pin))
	g.wires.append([int(src.id), "value", int(reader.id), pin])


## Compiles and returns [code, errors that are not warnings].
func v7_compile(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	return [code, c.errors.filter(func(e): return not e.w)]


func v7_only(errs: Array, node_id: int, msg: String, label: String) -> void:
	v7_check(label, errs.size() == 1 and int(errs[0].n) == node_id and String(errs[0].m) == msg,
		"got %s, wanted node %d: %s" % [str(errs), node_id, msg])


func v7_tests() -> void:
	T.refresh_globals()
	R.ensure_api()
	print("==== V7: name nodes read where their name does not exist ====")
	# a far parameter read in its own event
	var bp := v7_bp()
	var g: Dictionary = bp.graphs[0]
	var far := v7_name_nodes(g, false)
	v7_check("v7 far parameter: the importer made a name node with `of`", far.size() == 1 and String(far[0].p.expr) == "dt" and int(far[0].p.of) == 1)
	var res := v7_compile(bp)
	v7_check("v7 far parameter read in its own event: compiles with no error", res[1].is_empty() and String(res[0]).contains("print((dt * 2.0))"), str(res[1]))

	# the same name node feeding a node of another event
	bp = v7_bp()
	g = bp.graphs[0]
	far = v7_name_nodes(g, false)
	var other := v7_node(g, "util", "a0", "\"x\"")
	v7_feed(g, far[0], other, "a0")
	res = v7_compile(bp)
	v7_only(res[1], int(far[0].id), "'dt' is a parameter of Event Process. It can only be read by nodes that run from that event.",
		"v7 name node read in another event: one error, on the name node, naming the event")
	v7_check("v7 name node read in another event: the compile still completes", String(res[0]).contains("func _physics_process") and String(res[0]).contains("print(null)"), str(res[0]))

	# the name node copied into the function's graph (its entry node has the same id as the event's)
	bp = v7_bp()
	g = bp.graphs[0]
	far = v7_name_nodes(g, false)
	var fg: Dictionary = bp.graphs[1]
	var copy: Dictionary = far[0].duplicate(true)
	copy.id = int(fg.next_id)
	fg.next_id = int(fg.next_id) + 1
	fg.nodes.append(copy)
	var fprint := v7_node(fg, "util", "name", "print")
	v7_feed(fg, copy, fprint, "a0")
	res = v7_compile(bp)
	v7_only(res[1], int(copy.id), "'dt' was a parameter of an event or function that is not in this graph any more.",
		"v7 name node copied into a function graph: 'not in this graph any more'")

	# a name a Match case binds
	bp = v7_bp()
	g = bp.graphs[0]
	var bound := v7_name_nodes(g, true)
	v7_check("v7 match: the importer made name nodes with bound, of and arm", bound.size() == 2 and bound.all(func(n): return int(n.p.of) == int(v7_node(g, "switch", "t", "any").id) and n.p.arm == "case_0"))
	res = v7_compile(bp)
	v7_check("v7 match name read inside its case: compiles with no error", res[1].is_empty() and String(res[0]).contains("print((p + q))"), str(res[1]))
	var after := v7_node(g, "util", "a0", "\"after\"")
	v7_feed(g, bound[0], after, "a0")
	res = v7_compile(bp)
	v7_only(res[1], int(bound[0].id), "'p' is a name set by one case of a Match. It can only be read inside that case.",
		"v7 match name read after the match: the Match message")
	bp = v7_bp()
	g = bp.graphs[0]
	bound = v7_name_nodes(g, true)
	var none := v7_node(g, "util", "a0", "\"none\"")
	v7_feed(g, bound[1], none, "a0")
	res = v7_compile(bp)
	v7_only(res[1], int(bound[1].id), "'q' is a name set by one case of a Match. It can only be read inside that case.",
		"v7 match name read in another case: the Match message")

	# a const with no `of`: graphs saved before this, and consts made in the editor
	bp = v7_bp()
	g = bp.graphs[0]
	far = v7_name_nodes(g, false)
	other = v7_node(g, "util", "a0", "\"x\"")
	far[0].p.erase("of")
	far[0].p.erase("in")
	v7_feed(g, far[0], other, "a0")
	res = v7_compile(bp)
	v7_check("v7 const without `of`: no error", res[1].is_empty() and String(res[0]).contains("print(dt)"), str(res[1]))

	# the entry node deleted while the name node stays wired to a reader in another event
	bp = v7_bp()
	g = bp.graphs[0]
	far = v7_name_nodes(g, false)
	other = v7_node(g, "util", "a0", "\"x\"")
	v7_feed(g, far[0], other, "a0")
	g.nodes = g.nodes.filter(func(n): return int(n.id) != 1)
	g.wires = g.wires.filter(func(w): return int(w[0]) != 1 and int(w[2]) != 1)
	res = v7_compile(bp)
	v7_only(res[1], int(far[0].id), "'dt' was a parameter of an event or function that is not in this graph any more.",
		"v7 entry node deleted: 'not in this graph any more'")
	var mg := v7_bp()
	var mgg: Dictionary = mg.graphs[0]
	bound = v7_name_nodes(mgg, true)
	v7_feed(mgg, bound[0], v7_node(mgg, "util", "a0", "\"after\""), "a0")
	mgg.nodes = mgg.nodes.filter(func(n): return n.kind != "switch")
	res = v7_compile(mg)
	v7_check("v7 match node deleted: 'not in this graph any more'", res[1].any(func(e): return int(e.n) == int(bound[0].id) and String(e.m) == "'p' was a name set by a Match case that is not in this graph any more."), str(res[1]))




## Lambdas of a converted script are written back as lambdas where they stood; the function and Bind form is
## kept for graphs made by hand and wherever the inline form could mean something else.
const LAMBDA_SOURCE := "extends Node\n\nvar out: Array = []\n\nfunc grid_sum(w: int, h: int) -> int:\n\tvar grid := PackedInt32Array()\n\tgrid.resize(w * h)\n\tvar get_cell := func(x: int, y: int) -> int:\n\t\tif x < 0 or y < 0 or x >= w or y >= h:\n\t\t\treturn 1\n\t\treturn grid[y * w + x]\n\tvar total := 0\n\tfor i in w:\n\t\ttotal += get_cell.call(i, 0) + get_cell.call(-1, i)\n\treturn total\n\nfunc _ready():\n\tout.append(grid_sum(4, 3))\n"
const LAMBDA_RENAME_SOURCE := "extends RefCounted\n\nfunc f(n: int) -> int:\n\tvar off := 1\n\tvar pick := func(a: int) -> int:\n\t\tvar ra := a * 2\n\t\treturn ra + off - 1\n\tvar ra: int = pick.call(n)\n\treturn ra + off\n"
## An EventGraph local captured by a lambda that has to be a member of the script (it is named in text): the
## lambda must take its value when it is made, so it keeps the bound form.
const LAMBDA_MEMBER_SOURCE := "extends Node\n\nvar out: Array = []\n\nfunc _ready():\n\tvar total := 0\n\tfor i in 3:\n\t\ttotal += i\n\tvar g := func(): return total\n\ttotal = 50\n\tout.append(g.call())\n\tset(\"total_ready\", 1)\n"


func lambda_tests() -> void:
	var bp: Dictionary = Importer.new().convert(LAMBDA_SOURCE, {}).bp
	var c := Compiler.new()
	var code := c.compile(bp)
	var lg := Model.graph_named(bp, "_grid_sum_lambda")
	v7_check("lambda: the importer marks the lambda's graph with its captured values", not lg.is_empty() and int(lg.get("lambda", -1)) == 3, str(lg.get("lambda", null)))
	v7_check("lambda: written as a lambda where it stood", code.contains("var get_cell := func(x: int, y: int) -> int:") and not code.contains("func _grid_sum_lambda")
		and not code.contains(".bind(") and not code.contains("_grid_sum_lambda"), code)
	var gs := GDScript.new()
	gs.source_code = code
	v7_check("lambda: the script loads", gs.reload() == OK)
	var lines := code.split("\n")
	var body_line := -1
	var head_line := -1
	for i in lines.size():
		if lines[i].contains("var get_cell := func("):
			head_line = i + 1
		if lines[i].strip_edges() == "return grid[((y * w) + x)]":
			body_line = i + 1
	var lgid := int(lg.get("id", -1))
	var at: Array = c.line_map.get(body_line, [])
	var head_at: Array = c.line_map.get(head_line, [])
	v7_check("lambda: a line of its body belongs to a node of the lambda's graph", body_line != -1 and at.size() == 2 and int(at[0]) == lgid
		and not Model.find_node(lg, int(at[1])).is_empty() and String(Model.find_node(lg, int(at[1])).kind) == "fn_return", "line %d -> %s" % [body_line, str(at)])
	v7_check("lambda: its first line belongs to the node it is stored by", head_at.size() == 2 and int(head_at[0]) == int(Model.graph_named(bp, "grid_sum").id), str(head_at))
	var every_body_line := true
	for i in range(head_line + 1, head_line + 4):
		var li: Array = c.line_map.get(i, [])
		if li.size() != 2 or int(li[0]) != lgid:
			every_body_line = false
	v7_check("lambda: every line of its body belongs to the lambda's graph", every_body_line)
	# live debugging: the trace calls inside the lambda name the lambda's graph
	bp["trace"] = true
	var traced := Compiler.new().compile(bp)
	var tgs := GDScript.new()
	tgs.source_code = traced
	v7_check("lambda: with live debugging on, its nodes report from inside the lambda", traced.contains("\t\t__sc_trace(%d, " % lgid) and tgs.reload() == OK, traced)
	bp.erase("trace")
	# used from a second place (a call made in the editor, say): it is a function again
	var gsum := Model.graph_named(bp, "grid_sum")
	Model.add_node(gsum, "call_self", Vector2(), {"fn": "_grid_sum_lambda"})
	var twice := Compiler.new().compile(bp)
	v7_check("lambda: used from two places, it is the function and a Bind", twice.contains("func _grid_sum_lambda(") and twice.contains("_grid_sum_lambda.bind(grid, h, w)"), twice)

	# a graph made by hand: a function with values bound to a reference to it stays exactly that
	var hb := Model.new_schematic("Node", "")
	var hg: Dictionary = hb.graphs[0]
	hg.nodes.clear()
	var ce := Model.add_node(hg, "custom_event", Vector2(), {"name": "run_bound", "params": [["k", "int"]]})
	var fg := Model.new_graph(hb, "add_k", "function")
	fg.inputs = [["x", "int"], ["k", "int"]]
	fg.outputs = [["sum", "int"]]
	var add := Model.add_node(fg, "op", Vector2(), {"op": "+", "l": "int", "r": "int", "ret": "int"})
	wire(fg, fg.nodes[0], "p_x", add, "a")
	wire(fg, fg.nodes[0], "p_k", add, "b")
	wire(fg, fg.nodes[0], "then", fg.nodes[1], "exec")
	wire(fg, add, "ret", fg.nodes[1], "r_sum")
	var ref := Model.add_node(hg, "event_ref", Vector2(), {"fn": "add_k"})
	var bnd := Model.add_node(hg, "bcall", Vector2(), {"type": "Callable", "method": "bind", "n": 1})
	wire(hg, ref, "fn", bnd, "target")
	wire(hg, ce, "p_k", bnd, "v0")
	var keep := Model.add_node(hg, "print", Vector2(), {})
	wire(hg, ce, "then", keep, "exec")
	wire(hg, bnd, "ret", keep, "text")
	var hand := Compiler.new().compile(hb)
	v7_check("lambda: a function bound by hand stays a function and a Bind", hand.contains("func add_k(x: int, k: int) -> int:") and hand.contains("add_k.bind(k)")
		and not hand.contains("func(x"), hand)

	# a local of the lambda named like a local the function declares after it: GDScript would refuse the two in one
	# scope once the lambda is inside the function, so the lambda's own is renamed
	var rb: Dictionary = Importer.new().convert(LAMBDA_RENAME_SOURCE, {}).bp
	var renamed := Compiler.new().compile(rb)
	var rgs := GDScript.new()
	rgs.source_code = renamed
	var rok := rgs.reload() == OK
	var robj: Object = rgs.new() if rok else null
	v7_check("lambda: its own local is renamed where the function has one of that name", rok and renamed.contains("var ra_l") and not renamed.contains(".bind(")
		and robj != null and int(robj.call("f", 3)) == 7, renamed)

	# a captured EventGraph local that must be a member: the bound form, which takes the value when it is made
	var mb: Dictionary = Importer.new().convert(LAMBDA_MEMBER_SOURCE, {}).bp
	var member := Compiler.new().compile(mb)
	v7_check("lambda: capturing a local that became a member, it stays a function and a Bind", member.contains("var total_ready") and member.contains("_ready_lambda.bind(total_ready)")
		and member.contains("func _ready_lambda("), member)


func wire(g, a, ap, b, bp_) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func build(bp: Dictionary, label: String) -> Object:
	var c := Compiler.new()
	var code := c.compile(bp)
	var src := Model.build_source(code, bp)
	print("==== ", label, " ====\n", code)
	for e in c.errors:
		print("  COMPILE ", "warn" if e.w else "ERROR", " node ", e.n, ": ", e.m)
		fails += 1
	var back := Model.parse_source(src)
	if JSON.stringify(back, "", true) != JSON.stringify(Model.normalize(JSON.parse_string(JSON.stringify(bp))), "", true):
		print("  ROUNDTRIP MISMATCH")
		fails += 1
	var gs := GDScript.new()
	gs.source_code = src
	var err := gs.reload()
	if err != OK:
		print("  GDSCRIPT REJECTED: ", err)
		fails += 1
		return null
	return gs.new()


func _init() -> void:
	# --- 1: events, branch, sequence, loops, vars, math, function with outputs, do once, flip flop
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "health", "type": "float", "default": "100.0", "export": true, "category": "Stats", "tooltip": "Current health."})
	bp.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	bp.dispatchers.append({"name": "died", "params": [["who", "Node"]]})
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(0, 0), {"name": "run_test", "params": [["amount", "float"]]})
	var seq := Model.add_node(g, "sequence", Vector2(), {"n": 3})
	wire(g, ev, "then", seq, "exec")
	var sub := Model.add_node(g, "op", Vector2(), {"op": "-", "l": "float", "r": "float", "ret": "float"})
	var hget := Model.add_node(g, "var_get", Vector2(), {"name": "health"})
	var hset := Model.add_node(g, "var_set", Vector2(), {"name": "health"})
	wire(g, hget, "value", sub, "a")
	wire(g, ev, "p_amount", sub, "b")
	wire(g, sub, "ret", hset, "value")
	wire(g, seq, "then_0", hset, "exec")
	var le := Model.add_node(g, "op", Vector2(), {"op": "<=", "l": "float", "r": "float", "ret": "bool"})
	wire(g, hset, "out", le, "a")
	var br := Model.add_node(g, "branch", Vector2(), {})
	wire(g, hset, "then", br, "exec")
	wire(g, le, "ret", br, "cond")
	var em := Model.add_node(g, "emit", Vector2(), {"name": "died"})
	wire(g, br, "true", em, "exec")
	var lp := Model.add_node(g, "for", Vector2(), {})
	lp.d["first"] = "1"
	lp.d["last"] = "3"
	wire(g, seq, "then_1", lp, "exec")
	var mul := Model.add_node(g, "op", Vector2(), {"op": "*", "l": "int", "r": "int", "ret": "int"})
	mul.d["b"] = "2"
	wire(g, lp, "index", mul, "a")
	var lget := Model.add_node(g, "var_get", Vector2(), {"name": "log"})
	var app := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g, lp, "body", app, "exec")
	wire(g, lget, "value", app, "target")
	wire(g, mul, "ret", app, "a0")
	var once := Model.add_node(g, "do_once", Vector2(), {})
	wire(g, lp, "completed", once, "exec")
	var app2 := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	app2.d["a0"] = "\"once\""
	wire(g, once, "then", app2, "exec")
	wire(g, lget, "value", app2, "target")
	var fg := Model.new_graph(bp, "clamp_add", "function")
	fg.inputs = [["a", "float"], ["b", "float"]]
	fg.outputs = [["sum", "float"], ["big", "bool"]]
	var fe: Dictionary = fg.nodes[0]
	var fr: Dictionary = fg.nodes[1]
	var add := Model.add_node(fg, "op", Vector2(), {"op": "+", "l": "float", "r": "float", "ret": "float"})
	wire(fg, fe, "p_a", add, "a")
	wire(fg, fe, "p_b", add, "b")
	var gt := Model.add_node(fg, "op", Vector2(), {"op": ">", "l": "float", "r": "float", "ret": "bool"})
	gt.d["b"] = "50.0"
	wire(fg, add, "ret", gt, "a")
	wire(fg, fe, "then", fr, "exec")
	wire(fg, add, "ret", fr, "r_sum")
	wire(fg, gt, "ret", fr, "r_big")
	var cs := Model.add_node(g, "call_self", Vector2(), {"fn": "clamp_add"})
	cs.d["a_b"] = "5.0"
	wire(g, seq, "then_2", cs, "exec")
	wire(g, hget, "value", cs, "a_a")
	var app3 := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g, cs, "then", app3, "exec")
	wire(g, lget, "value", app3, "target")
	wire(g, cs, "r_sum", app3, "a0")
	var ff := Model.add_node(g, "flip_flop", Vector2(), {})
	wire(g, app3, "then", ff, "exec")
	var pa := Model.add_node(g, "print", Vector2(), {})
	pa.d["text"] = "\"flip A\""
	var pb := Model.add_node(g, "print", Vector2(), {})
	pb.d["text"] = "\"flop B\""
	wire(g, ff, "a", pa, "exec")
	wire(g, ff, "b", pb, "exec")
	var o := build(bp, "logic")
	if o:
		o.run_test(30.0)
		o.run_test(30.0)
		print("health=", o.health, " log=", o.log)
		if o.health != 40.0 or str(o.log) != "[2, 4, 6, \"once\", 75.0, 2, 4, 6, 45.0]":
			print("  WRONG RESULT")
			fails += 1
		o.free()

	# --- 2: CharacterBody3D schematic: engine calls, properties, delay, input, signal event, cast, make/break
	var b2 := Model.new_schematic("CharacterBody3D", "")
	var g2: Dictionary = b2.graphs[0]
	var ready: Dictionary = g2.nodes[0]
	var proc: Dictionary = g2.nodes[1]
	var seq2 := Model.add_node(g2, "sequence", Vector2(), {"n": 2})
	wire(g2, ready, "then", seq2, "exec")
	var dl := Model.add_node(g2, "delay", Vector2(), {})
	dl.d["duration"] = "0.05"
	var p1 := Model.add_node(g2, "print", Vector2(), {})
	p1.d["text"] = "\"after delay\""
	wire(g2, seq2, "then_0", dl, "exec")
	wire(g2, dl, "then", p1, "exec")
	var p2 := Model.add_node(g2, "print", Vector2(), {})
	p2.d["text"] = "\"immediately\""
	wire(g2, seq2, "then_1", p2, "exec")
	var rot := Model.add_node(g2, "call", Vector2(), {"cls": "Node3D", "method": "rotate_y"})
	wire(g2, proc, "then", rot, "exec")
	wire(g2, proc, "p_delta", rot, "a0")
	var gp := Model.add_node(g2, "get_prop", Vector2(), {"cls": "Node3D", "prop": "position"})
	var brk := Model.add_node(g2, "break", Vector2(), {"type": "Vector3"})
	var mk := Model.add_node(g2, "ctor", Vector2(), {"type": "Vector3", "i": 3})
	var sp := Model.add_node(g2, "set_prop", Vector2(), {"cls": "CharacterBody3D", "prop": "velocity"})
	wire(g2, gp, "value", brk, "v")
	wire(g2, brk, "m_x", mk, "a0")
	mk.d["a1"] = "9.8"
	wire(g2, mk, "ret", sp, "value")
	wire(g2, rot, "then", sp, "exec")
	var mv := Model.add_node(g2, "call", Vector2(), {"cls": "CharacterBody3D", "method": "move_and_slide"})
	wire(g2, sp, "then", mv, "exec")
	var isf := Model.add_node(g2, "call", Vector2(), {"cls": "CharacterBody3D", "method": "is_on_floor"})
	var br2 := Model.add_node(g2, "branch", Vector2(), {})
	wire(g2, mv, "then", br2, "exec")
	wire(g2, isf, "ret", br2, "cond")
	var gpar := Model.add_node(g2, "call", Vector2(), {"cls": "Node", "method": "get_parent"})
	var cast := Model.add_node(g2, "cast", Vector2(), {"cls": "Node3D"})
	wire(g2, br2, "true", cast, "exec")
	wire(g2, gpar, "ret", cast, "obj")
	var p3 := Model.add_node(g2, "print", Vector2(), {})
	wire(g2, cast, "then", p3, "exec")
	wire(g2, cast, "as", p3, "text")
	var ia := Model.add_node(g2, "input_action", Vector2(), {"action": "jump"})
	var p4 := Model.add_node(g2, "print", Vector2(), {})
	p4.d["text"] = "\"jump\""
	wire(g2, ia, "pressed", p4, "exec")
	var se := Model.add_node(g2, "signal_event", Vector2(), {"path": ".", "signal": "tree_exiting", "cls": "Node", "args": []})
	var p5 := Model.add_node(g2, "print", Vector2(), {})
	p5.d["text"] = "\"bye\""
	wire(g2, se, "then", p5, "exec")
	var inp := Model.add_node(g2, "call", Vector2(), {"cls": "Input", "method": "is_action_pressed"})
	inp.d["a0"] = "&\"jump\""
	var sel := Model.add_node(g2, "select", Vector2(), {})
	sel.d["a"] = "1"
	sel.d["b"] = "2"
	wire(g2, inp, "ret", sel, "pick")
	var p6 := Model.add_node(g2, "print", Vector2(), {})
	wire(g2, br2, "false", p6, "exec")
	wire(g2, sel, "ret", p6, "text")
	var o2 := build(b2, "character")
	if o2:
		root.add_child(o2)
		await create_timer(0.3).timeout
		o2.queue_free()
		await process_frame

	# --- 3: macros - expanded per call site, each with its own Do Once state, data in/out
	var b3 := Model.new_schematic("Node", "")
	b3.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g3: Dictionary = b3.graphs[0]
	g3.nodes.clear()
	var mg := Model.new_graph(b3, "once_add", "macro")
	mg.inputs = [["In", "exec"], ["value", "int"]]
	mg.outputs = [["Out", "exec"], ["doubled", "int"]]
	var m_in: Dictionary = mg.nodes[0]
	var m_out: Dictionary = mg.nodes[1]
	var m_once := Model.add_node(mg, "do_once", Vector2(), {})
	var m_log := Model.add_node(mg, "var_get", Vector2(), {"name": "log"})
	var m_app := Model.add_node(mg, "bcall", Vector2(), {"type": "Array", "method": "append"})
	var m_mul := Model.add_node(mg, "op", Vector2(), {"op": "*", "l": "int", "r": "int", "ret": "int"})
	m_mul.d["b"] = "2"
	wire(mg, m_in, "i_In", m_once, "exec")
	wire(mg, m_once, "then", m_app, "exec")
	wire(mg, m_log, "value", m_app, "target")
	wire(mg, m_in, "i_value", m_app, "a0")
	wire(mg, m_app, "then", m_out, "o_Out")
	wire(mg, m_in, "i_value", m_mul, "a")
	wire(mg, m_mul, "ret", m_out, "o_doubled")
	var go := Model.add_node(g3, "custom_event", Vector2(), {"name": "go", "params": []})
	var ca := Model.add_node(g3, "macro", Vector2(), {"name": "once_add"})
	ca.d["i_value"] = "1"
	var cb := Model.add_node(g3, "macro", Vector2(), {"name": "once_add"})
	var l3 := Model.add_node(g3, "var_get", Vector2(), {"name": "log"})
	var a3 := Model.add_node(g3, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g3, go, "then", ca, "i_In")
	wire(g3, ca, "o_Out", cb, "i_In")
	wire(g3, ca, "o_doubled", cb, "i_value")
	wire(g3, cb, "o_Out", a3, "exec")
	wire(g3, l3, "value", a3, "target")
	wire(g3, cb, "o_doubled", a3, "a0")
	var o3 := build(b3, "macros")
	if o3:
		o3.go()
		o3.go()
		print("macro log=", o3.log)
		if str(o3.log) != "[1, 2, 4]":
			print("  WRONG RESULT")
			fails += 1
		o3.free()

	# --- 4: timeline - plays a float track, fires Update each frame and Finished at the end
	var b4 := Model.new_schematic("Node", "")
	b4.variables.append({"name": "vals", "type": "Array", "default": "", "export": false})
	b4.variables.append({"name": "done", "type": "bool", "default": "", "export": false})
	var g4: Dictionary = b4.graphs[0]
	g4.nodes.clear()
	var st4 := Model.add_node(g4, "custom_event", Vector2(), {"name": "start", "params": []})
	var tl := Model.add_node(g4, "timeline", Vector2(), {"name": "Fade", "length": 0.2, "loop": false, "autoplay": false,
		"tracks": [{"name": "Alpha", "type": "float", "smooth": false, "keys": [[0.0, "0.0"], [0.2, "1.0"]]},
			{"name": "Tint", "type": "Color", "smooth": true, "keys": [[0.0, "Color(1, 0, 0, 1)"], [0.2, "Color(0, 0, 1, 1)"]]}]})
	var v4 := Model.add_node(g4, "var_get", Vector2(), {"name": "vals"})
	var ap4 := Model.add_node(g4, "bcall", Vector2(), {"type": "Array", "method": "append"})
	var sd4 := Model.add_node(g4, "var_set", Vector2(), {"name": "done"})
	sd4.d["value"] = "true"
	wire(g4, st4, "then", tl, "play_start")
	wire(g4, tl, "update", ap4, "exec")
	wire(g4, v4, "value", ap4, "target")
	wire(g4, tl, "t_Alpha", ap4, "a0")
	wire(g4, tl, "finished", sd4, "exec")
	var o4 := build(b4, "timeline")
	if o4:
		root.add_child(o4)
		o4.start()
		await create_timer(0.6).timeout
		var vals: Array = o4.vals
		print("timeline samples=", vals.size(), " last=", vals[-1] if not vals.is_empty() else null, " done=", o4.done)
		var mono := true
		for i in range(1, vals.size()):
			if vals[i] < vals[i - 1]:
				mono = false
		if vals.size() < 3 or not is_equal_approx(vals[-1], 1.0) or not o4.done or not mono:
			print("  WRONG RESULT")
			fails += 1
		o4.queue_free()
		await process_frame

	# --- 5: template nodes (Godot tie-ins): groups, timer by event, message call, tween
	var b5 := Model.new_schematic("Node2D", "")
	b5.variables.append({"name": "ticks", "type": "int", "default": "", "export": false})
	b5.variables.append({"name": "found", "type": "int", "default": "", "export": false})
	b5.variables.append({"name": "tweened", "type": "bool", "default": "", "export": false})
	var g5: Dictionary = b5.graphs[0]
	g5.nodes.clear()
	var rd5 := Model.add_node(g5, "event", Vector2(), {"name": "_ready"})
	var grp := Model.add_node(g5, "tpl", Vector2(), {"id": "add_to_group"})
	grp.d["group"] = "&\"things\""
	var tm := Model.add_node(g5, "tpl", Vector2(), {"id": "set_timer"})
	tm.d["time"] = "0.05"
	tm.d["looping"] = "true"
	var evr := Model.add_node(g5, "event_ref", Vector2(), {"fn": "tick"})
	var tick := Model.add_node(g5, "custom_event", Vector2(), {"name": "tick", "params": []})
	var tg := Model.add_node(g5, "var_get", Vector2(), {"name": "ticks"})
	var tadd := Model.add_node(g5, "op", Vector2(), {"op": "+", "l": "int", "r": "int", "ret": "int"})
	tadd.d["b"] = "1"
	var tset := Model.add_node(g5, "var_set", Vector2(), {"name": "ticks"})
	wire(g5, tick, "then", tset, "exec")
	wire(g5, tg, "value", tadd, "a")
	wire(g5, tadd, "ret", tset, "value")
	var all := Model.add_node(g5, "tpl", Vector2(), {"id": "get_nodes_in_group"})
	all.d["group"] = "&\"things\""
	var sz := Model.add_node(g5, "bcall", Vector2(), {"type": "Array", "method": "size"})
	var fset := Model.add_node(g5, "var_set", Vector2(), {"name": "found"})
	var msg := Model.add_node(g5, "tpl", Vector2(), {"id": "call_message"})
	msg.d["fn"] = "&\"does_not_exist\""
	var slf := Model.add_node(g5, "self", Vector2(), {})
	var tw := Model.add_node(g5, "tpl", Vector2(), {"id": "tween_property"})
	tw.d["final"] = "Vector2(10, 0)"
	tw.d["duration"] = "0.1"
	var wset := Model.add_node(g5, "var_set", Vector2(), {"name": "tweened"})
	wset.d["value"] = "true"
	wire(g5, rd5, "then", grp, "exec")
	wire(g5, grp, "then", tm, "exec")
	wire(g5, evr, "fn", tm, "event")
	wire(g5, tm, "then", fset, "exec")
	wire(g5, all, "ret", sz, "target")
	wire(g5, sz, "ret", fset, "value")
	wire(g5, fset, "then", msg, "exec")
	wire(g5, slf, "self", msg, "target")
	wire(g5, msg, "then", tw, "exec")
	wire(g5, tw, "then", wset, "exec")
	var o5 := build(b5, "templates")
	if o5:
		root.add_child(o5)
		await create_timer(0.4).timeout
		print("templates: ticks=", o5.ticks, " found=", o5.found, " tweened=", o5.tweened, " pos=", o5.position)
		if o5.ticks < 3 or o5.found != 1 or not o5.tweened or not o5.position.is_equal_approx(Vector2(10, 0)):
			print("  WRONG RESULT")
			fails += 1
		o5.queue_free()
		await process_frame

	# --- 6: child schematic of a schematic class (SC_Demo): override an event and a function, call parent
	if ClassDB.class_exists("Node3D") and ResourceLoader.exists("res://demo/SC_Demo.gd"):
		var b6 := Model.new_schematic("SC_Demo", "")
		var g6: Dictionary = b6.graphs[0]
		g6.nodes.clear()
		var rd6 := Model.add_node(g6, "event", Vector2(), {"name": "_ready"})
		var par := Model.add_node(g6, "call_parent", Vector2(), {"method": "_ready"})
		var pr6 := Model.add_node(g6, "print", Vector2(), {})
		pr6.d["text"] = "\"child ready\""
		wire(g6, rd6, "then", par, "exec")
		wire(g6, par, "then", pr6, "exec")
		var wf := Model.new_graph(b6, "wave", "function")
		wf.inputs = [["t", "float"]]
		wf.outputs = [["height", "float"]]
		wf.nodes[1].d["r_height"] = "7.0"
		wire(wf, wf.nodes[0], "then", wf.nodes[1], "exec")
		print("overridable has wave: ", R.schematic_actions(b6, g6).any(func(a): return a.k == "call_parent" and a.p.method == "wave"))
		var o6 := build(b6, "child schematic")
		if o6:
			var h: float = o6.wave(1.0)
			print("child wave -> ", h, "  is SC_Demo: ", o6 is SC_Demo)
			if h != 7.0:
				print("  WRONG RESULT")
				fails += 1
			o6.free()

	# --- 7: wildcard math, format string, multigate, dictionary / reverse loops, increments, key events
	var b7 := Model.new_schematic("Node", "")
	b7.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	b7.variables.append({"name": "count", "type": "int", "default": "", "export": false})
	b7.variables.append({"name": "v", "type": "Vector3", "default": "Vector3(1, 2, 3)", "export": false})
	b7.variables.append({"name": "prices", "type": "Dictionary", "default": "{\"a\": 1, \"b\": 2}", "export": false})
	var g7: Dictionary = b7.graphs[0]
	g7.nodes.clear()
	var e7 := Model.add_node(g7, "custom_event", Vector2(), {"name": "go", "params": []})
	var lg := Model.add_node(g7, "var_get", Vector2(), {"name": "log"})
	var st := {"n": e7, "pin": "then"}
	var push := func(src: Dictionary, src_pin: String) -> void:
		var ap := Model.add_node(g7, "bcall", Vector2(), {"type": "Array", "method": "append"})
		wire(g7, st.n, st.pin, ap, "exec")
		wire(g7, lg, "value", ap, "target")
		wire(g7, src, src_pin, ap, "a0")
		st.n = ap
		st.pin = "then"
	# Vector3 * float through the wildcard Multiply -> result type must be Vector3
	var vg := Model.add_node(g7, "var_get", Vector2(), {"name": "v"})
	var mul7 := Model.add_node(g7, "math", Vector2(), {"op": "*", "n": 2})
	mul7.d["a1"] = "2.0"
	wire(g7, vg, "value", mul7, "a0")
	print("wildcard Vector3 * float -> ", R.describe(mul7, b7, g7).outs[0].type)
	if R.describe(mul7, b7, g7).outs[0].type != "Vector3":
		print("  WRONG TYPE")
		fails += 1
	push.call(mul7, "ret")
	# three-input Add of ints, then a comparison
	var add7 := Model.add_node(g7, "math", Vector2(), {"op": "+", "n": 3})
	add7.d["a0"] = "1"
	add7.d["a1"] = "2"
	add7.d["a2"] = "3"
	var gt7 := Model.add_node(g7, "math", Vector2(), {"op": ">", "n": 2})
	gt7.d["a1"] = "5"
	wire(g7, add7, "ret", gt7, "a0")
	push.call(gt7, "ret")
	# format string
	var fm := Model.add_node(g7, "format", Vector2(), {"text": "{who} has {n} coins"})
	fm.d["f_who"] = "\"Sam\""
	wire(g7, add7, "ret", fm, "f_n")
	push.call(fm, "ret")
	# increment
	var inc := Model.add_node(g7, "var_inc", Vector2(), {"name": "count", "by": 1})
	wire(g7, st.n, st.pin, inc, "exec")
	st.n = inc
	push.call(inc, "value")
	# dictionary loop
	var dg := Model.add_node(g7, "var_get", Vector2(), {"name": "prices"})
	var dl7 := Model.add_node(g7, "for_each_dict", Vector2(), {})
	wire(g7, st.n, st.pin, dl7, "exec")
	wire(g7, dg, "value", dl7, "dict")
	var dap := Model.add_node(g7, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g7, dl7, "body", dap, "exec")
	wire(g7, lg, "value", dap, "target")
	wire(g7, dl7, "value", dap, "a0")
	# reverse loop
	var mk7 := Model.add_node(g7, "make_array", Vector2(), {"n": 3})
	mk7.d["e0"] = "\"x\""
	mk7.d["e1"] = "\"y\""
	mk7.d["e2"] = "\"z\""
	var rl := Model.add_node(g7, "for_each", Vector2(), {"rev": true})
	wire(g7, dl7, "completed", rl, "exec")
	wire(g7, mk7, "ret", rl, "array")
	var rap := Model.add_node(g7, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g7, rl, "body", rap, "exec")
	wire(g7, lg, "value", rap, "target")
	wire(g7, rl, "element", rap, "a0")
	# multigate (sequential, no loop): third call does nothing
	var mgt := Model.add_node(g7, "multigate", Vector2(), {"n": 2})
	wire(g7, rl, "completed", mgt, "exec")
	for i in 2:
		var gate_app := Model.add_node(g7, "bcall", Vector2(), {"type": "Array", "method": "append"})
		gate_app.d["a0"] = "\"gate%d\"" % i
		wire(g7, mgt, "out_%d" % i, gate_app, "exec")
		wire(g7, lg, "value", gate_app, "target")
	# keyboard event
	var ke := Model.add_node(g7, "key_event", Vector2(), {"key": "KEY_F"})
	var kp := Model.add_node(g7, "print", Vector2(), {})
	wire(g7, ke, "pressed", kp, "exec")
	var o7 := build(b7, "unreal-comparison nodes")
	if o7:
		o7.go()
		var first: Array = o7.log.duplicate()
		o7.log.clear()
		o7.go()
		o7.go()
		print("first: ", first)
		print("then:  ", o7.log)
		var want := "[(2.0, 4.0, 6.0), true, \"Sam has 6 coins\", 1, 1, 2, \"z\", \"y\", \"x\", \"gate0\"]"
		if str(first) != want or not o7.log.has("gate1") or o7.log.count("gate0") != 0 or o7.count != 3:
			print("  WRONG RESULT")
			fails += 1
		var key_ev := InputEventKey.new()
		key_ev.keycode = KEY_F
		key_ev.pressed = true
		o7._unhandled_input(key_ev)
		o7.free()

	# --- 8: Construction Script, Notify On Change, Expose on Spawn
	var b8 := Model.new_schematic("Node2D", "")
	b8.variables.append({"name": "size", "type": "int", "default": "2", "export": true, "spawn": true})
	b8.variables.append({"name": "hp", "type": "int", "default": "", "export": false, "notify": true})
	b8.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	b8.variables.append({"name": "seen_size", "type": "int", "default": "", "export": false})
	var g8: Dictionary = b8.graphs[0]
	# Ready -> seen_size = size   (proves spawn values arrive before Ready)
	var ss := Model.add_node(g8, "var_set", Vector2(), {"name": "seen_size"})
	var sg := Model.add_node(g8, "var_get", Vector2(), {"name": "size"})
	wire(g8, g8.nodes[0], "then", ss, "exec")
	wire(g8, sg, "value", ss, "value")
	# ConstructionScript: position = Vector2(size, 0)
	var cg := Model.new_graph(b8, "ConstructionScript", "function")
	cg.nodes = cg.nodes.filter(func(x): return x.kind == "fn_entry")
	var csg := Model.add_node(cg, "var_get", Vector2(), {"name": "size"})
	var cmk := Model.add_node(cg, "ctor", Vector2(), {"type": "Vector2", "i": 3})
	var csp := Model.add_node(cg, "set_prop", Vector2(), {"cls": "Node2D", "prop": "position"})
	wire(cg, cg.nodes[0], "then", csp, "exec")
	wire(cg, csg, "value", cmk, "a0")
	wire(cg, cmk, "ret", csp, "value")
	# on_hp_changed: log.append(hp)
	var ng := Model.new_graph(b8, "on_hp_changed", "function")
	ng.nodes = ng.nodes.filter(func(x): return x.kind == "fn_entry")
	var nl := Model.add_node(ng, "var_get", Vector2(), {"name": "log"})
	var nh := Model.add_node(ng, "var_get", Vector2(), {"name": "hp"})
	var na := Model.add_node(ng, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(ng, ng.nodes[0], "then", na, "exec")
	wire(ng, nl, "value", na, "target")
	wire(ng, nh, "value", na, "a0")
	var c8 := Compiler.new()
	var code8 := c8.compile(b8)
	var o8 := build(b8, "construction script")
	if o8:
		var has_tool := code8.contains("\n@tool\n")
		var guarded := code8.contains("func _process(delta: float) -> void:\n\tif Engine.is_editor_hint():\n\t\treturn")
		o8.hp = 1
		root.add_child(o8)
		var pos_ready: Vector2 = o8.position
		o8.size = 9
		o8.hp = 5
		print("construct: tool=", has_tool, " process guarded=", guarded, " pos after ready=", pos_ready, " after size=9: ", o8.position, " notify log=", o8.log, " seen=", o8.seen_size)
		if not has_tool or not guarded or pos_ready != Vector2(2, 0) or o8.position != Vector2(9, 0) or str(o8.log) != "[5]" or o8.seen_size != 2:
			print("  WRONG RESULT")
			fails += 1
		o8.queue_free()
		await process_frame
	# Save that schematic + a scene using it, then spawn it from another schematic with the exposed pin set.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	var fgd := FileAccess.open("res://tests/tmp/spawn_me.gd", FileAccess.WRITE)
	fgd.store_string(Model.build_source(code8, b8))
	fgd.close()
	var root_node := Node2D.new()
	root_node.name = "SpawnMe"
	root_node.set_script(load("res://tests/tmp/spawn_me.gd"))
	var packed := PackedScene.new()
	packed.pack(root_node)
	ResourceSaver.save(packed, "res://tests/tmp/spawn_me.tscn")
	root_node.free()
	var b9 := Model.new_schematic("Node2D", "")
	var g9: Dictionary = b9.graphs[0]
	g9.nodes.clear()
	var e9 := Model.add_node(g9, "custom_event", Vector2(), {"name": "go", "params": []})
	var sp9 := Model.add_node(g9, "spawn", Vector2(), {"xt": "Transform2D"})
	sp9.d["scene"] = "preload(\"res://tests/tmp/spawn_me.tscn\")"
	sp9.d["x_size"] = "7"
	wire(g9, e9, "then", sp9, "exec")
	var d9 := R.describe(sp9, b9, g9)
	print("spawn pins: ", d9.ins.map(func(x): return x.id), " -> ", d9.outs[-1].type)
	var o9 := build(b9, "expose on spawn")
	if o9:
		root.add_child(o9)
		o9.go()
		var kid: Node = o9.get_child(0) if o9.get_child_count() > 0 else null
		print("spawned child seen_size=", kid.seen_size if kid else null, " pos=", kid.position if kid else null)
		if kid == null or kid.seen_size != 7 or kid.position != Vector2(7, 0) or not d9.ins.any(func(x): return x.id == "x_size"):
			print("  WRONG RESULT")
			fails += 1
		o9.queue_free()
		await process_frame

	# --- 10: exec wire looping back (plain and through a Delay), values read from another event, macro locals
	var b10 := Model.new_schematic("Node", "")
	b10.variables.append({"name": "count", "type": "int", "default": "", "export": false})
	b10.variables.append({"name": "ticks", "type": "int", "default": "", "export": false})
	b10.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g10: Dictionary = b10.graphs[0]
	g10.nodes.clear()
	# go(): count++ ; if count < 3 -> wire back to the increment ; else log count
	var e10 := Model.add_node(g10, "custom_event", Vector2(), {"name": "go", "params": [["amount", "int"]]})
	var inc10 := Model.add_node(g10, "var_inc", Vector2(), {"name": "count", "by": 1})
	var lt10 := Model.add_node(g10, "math", Vector2(), {"op": "<", "n": 2})
	lt10.d["a1"] = "3"
	var br10 := Model.add_node(g10, "branch", Vector2(), {})
	var lg10 := Model.add_node(g10, "var_get", Vector2(), {"name": "log"})
	var ap10 := Model.add_node(g10, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g10, e10, "then", inc10, "exec")
	wire(g10, inc10, "then", br10, "exec")
	wire(g10, inc10, "value", lt10, "a0")
	wire(g10, lt10, "ret", br10, "cond")
	wire(g10, br10, "true", inc10, "exec")
	wire(g10, br10, "false", ap10, "exec")
	wire(g10, lg10, "value", ap10, "target")
	wire(g10, inc10, "value", ap10, "a0")
	# Ready -> Delay -> ticks++ -> if ticks < 3 -> back into the Delay  (classic "tick every N seconds" loop)
	var r10 := Model.add_node(g10, "event", Vector2(), {"name": "_ready"})
	var dl10 := Model.add_node(g10, "delay", Vector2(), {})
	dl10.d["duration"] = "0.03"
	var ti10 := Model.add_node(g10, "var_inc", Vector2(), {"name": "ticks", "by": 1})
	var tl10 := Model.add_node(g10, "math", Vector2(), {"op": "<", "n": 2})
	tl10.d["a1"] = "3"
	var tb10 := Model.add_node(g10, "branch", Vector2(), {})
	wire(g10, r10, "then", dl10, "exec")
	wire(g10, dl10, "then", ti10, "exec")
	wire(g10, ti10, "then", tb10, "exec")
	wire(g10, ti10, "value", tl10, "a0")
	wire(g10, tl10, "ret", tb10, "cond")
	wire(g10, tb10, "true", dl10, "exec")
	# other(): reads go()'s parameter and the result of a function call made inside go()'s chain
	var fn10 := Model.new_graph(b10, "twice", "function")
	fn10.inputs = [["x", "int"]]
	fn10.outputs = [["r", "int"]]
	var fm10 := Model.add_node(fn10, "math", Vector2(), {"op": "*", "n": 2})
	fm10.d["a1"] = "2"
	wire(fn10, fn10.nodes[0], "p_x", fm10, "a0")
	wire(fn10, fm10, "ret", fn10.nodes[1], "r_r")
	wire(fn10, fn10.nodes[0], "then", fn10.nodes[1], "exec")
	var cs10 := Model.add_node(g10, "call_self", Vector2(), {"fn": "twice"})
	wire(g10, ap10, "then", cs10, "exec")
	wire(g10, e10, "p_amount", cs10, "a_x")
	var o10e := Model.add_node(g10, "custom_event", Vector2(), {"name": "other", "params": []})
	var oa1 := Model.add_node(g10, "bcall", Vector2(), {"type": "Array", "method": "append"})
	var oa2 := Model.add_node(g10, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g10, o10e, "then", oa1, "exec")
	wire(g10, lg10, "value", oa1, "target")
	wire(g10, e10, "p_amount", oa1, "a0")
	wire(g10, oa1, "then", oa2, "exec")
	wire(g10, lg10, "value", oa2, "target")
	wire(g10, cs10, "r_r", oa2, "a0")
	# macro with a local variable, used twice
	var mg10 := Model.new_graph(b10, "remember", "macro")
	mg10.inputs = [["In", "exec"], ["value", "int"]]
	mg10.outputs = [["Out", "exec"], ["kept", "int"]]
	mg10.locals = [{"name": "tmp", "type": "int", "default": ""}]
	var ls := Model.add_node(mg10, "local_set", Vector2(), {"name": "tmp"})
	var lgt := Model.add_node(mg10, "local_get", Vector2(), {"name": "tmp"})
	wire(mg10, mg10.nodes[0], "i_In", ls, "exec")
	wire(mg10, mg10.nodes[0], "i_value", ls, "value")
	wire(mg10, ls, "then", mg10.nodes[1], "o_Out")
	wire(mg10, lgt, "value", mg10.nodes[1], "o_kept")
	var me10 := Model.add_node(g10, "custom_event", Vector2(), {"name": "macros", "params": []})
	var mc1 := Model.add_node(g10, "macro", Vector2(), {"name": "remember"})
	mc1.d["i_value"] = "11"
	var mc2 := Model.add_node(g10, "macro", Vector2(), {"name": "remember"})
	mc2.d["i_value"] = "22"
	var ma1 := Model.add_node(g10, "bcall", Vector2(), {"type": "Array", "method": "append"})
	var ma2 := Model.add_node(g10, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g10, me10, "then", mc1, "i_In")
	wire(g10, mc1, "o_Out", mc2, "i_In")
	wire(g10, mc2, "o_Out", ma1, "exec")
	wire(g10, lg10, "value", ma1, "target")
	wire(g10, mc1, "o_kept", ma1, "a0")
	wire(g10, ma1, "then", ma2, "exec")
	wire(g10, lg10, "value", ma2, "target")
	wire(g10, mc2, "o_kept", ma2, "a0")
	var o10 := build(b10, "loops back, cross-event values, macro locals")
	if o10:
		o10.go(21)
		o10.other()
		o10.macros()
		root.add_child(o10)
		await create_timer(0.5).timeout
		print("loop-back: count=", o10.count, " ticks=", o10.ticks, " log=", o10.log)
		if o10.count != 3 or o10.ticks != 3 or str(o10.log) != "[3, 21, 42, 11, 22]":
			print("  WRONG RESULT")
			fails += 1
		o10.queue_free()
		await process_frame

	# --- 11: schematic enums (typed variable, literals, switch) and split struct pins (input and output)
	var b11 := Model.new_schematic("Node2D", "")
	b11["enums"] = [{"name": "Mood", "values": ["Calm", "Angry", "Scared"]}]
	b11.variables.append({"name": "mood", "type": "int", "enum": "Mood", "default": "1", "export": true})
	b11.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g11: Dictionary = b11.graphs[0]
	g11.nodes.clear()
	var e11 := Model.add_node(g11, "custom_event", Vector2(), {"name": "go", "params": []})
	var mg11 := Model.add_node(g11, "var_get", Vector2(), {"name": "mood"})
	print("enum pin: ", R.describe(mg11, b11, g11).outs[0].get("enum", ""), " values: ", R.enum_values("@Mood"))
	var sw11 := Model.add_node(g11, "switch", Vector2(), {"t": "int", "enum": "@Mood", "cases": [["Calm", "0"], ["Angry", "1"], ["Scared", "2"]]})
	var lg11 := Model.add_node(g11, "var_get", Vector2(), {"name": "log"})
	var sa11 := Model.add_node(g11, "bcall", Vector2(), {"type": "Array", "method": "append"})
	sa11.d["a0"] = "\"angry\""
	wire(g11, e11, "then", sw11, "exec")
	wire(g11, mg11, "value", sw11, "sel")
	wire(g11, sw11, "case_1", sa11, "exec")
	wire(g11, lg11, "value", sa11, "target")
	# set mood = Mood.Scared via an enum literal, then position = (split x, split y) and log position.x via split output
	var lit11 := Model.add_node(g11, "const", Vector2(), {"expr": "Mood.Scared", "t": "int", "label": "Mood.Scared"})
	var ms11 := Model.add_node(g11, "var_set", Vector2(), {"name": "mood"})
	wire(g11, sa11, "then", ms11, "exec")
	wire(g11, lit11, "value", ms11, "value")
	var sp11 := Model.add_node(g11, "set_prop", Vector2(), {"cls": "Node2D", "prop": "position"})
	sp11["split"] = {"value": true}
	sp11.d["value~x"] = "3.0"
	sp11.d["value~y"] = "4.0"
	wire(g11, ms11, "then", sp11, "exec")
	var gp11 := Model.add_node(g11, "get_prop", Vector2(), {"cls": "Node2D", "prop": "position"})
	gp11["split"] = {"value": true}
	var pa11 := Model.add_node(g11, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g11, sp11, "then", pa11, "exec")
	wire(g11, lg11, "value", pa11, "target")
	wire(g11, gp11, "value~y", pa11, "a0")
	var d11 := R.describe(sp11, b11, g11)
	print("split pins: ", d11.ins.map(func(x): return x.id), "  out: ", R.describe(gp11, b11, g11).outs.map(func(x): return x.id))
	var o11 := build(b11, "enums and split pins")
	if o11:
		o11.go()
		var props := o11.get_property_list().filter(func(x): return x.name == "mood")
		print("enums/split: log=", o11.log, " mood=", o11.mood, " pos=", o11.position, " inspector hint=", props[0].hint_string if not props.is_empty() else "?")
		if str(o11.log) != "[\"angry\", 4.0]" or o11.mood != 2 or o11.position != Vector2(3, 4) or props.is_empty() or not String(props[0].hint_string).contains("Angry"):
			print("  WRONG RESULT")
			fails += 1
		o11.free()

	# --- 12: replicated custom events (run locally when offline), exec reroute, animation-tree nodes compile
	var b12 := Model.new_schematic("Node", "")
	b12.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	b12.variables.append({"name": "tree", "type": "AnimationTree", "default": "", "export": true})
	var g12: Dictionary = b12.graphs[0]
	g12.nodes.clear()
	var lg12 := Model.add_node(g12, "var_get", Vector2(), {"name": "log"})
	var modes_12 := ["server", "multicast", "owner"]
	var go12 := Model.add_node(g12, "custom_event", Vector2(), {"name": "go", "params": []})
	var prev12: Dictionary = go12
	for i in modes_12.size():
		var evn_12 := Model.add_node(g12, "custom_event", Vector2(), {"name": "ev_" + modes_12[i], "params": [["v", "int"]], "rpc": modes_12[i], "reliable": i != 1})
		var ap_12 := Model.add_node(g12, "bcall", Vector2(), {"type": "Array", "method": "append"})
		wire(g12, evn_12, "then", ap_12, "exec")
		wire(g12, lg12, "value", ap_12, "target")
		wire(g12, evn_12, "p_v", ap_12, "a0")
		var cl_12 := Model.add_node(g12, "call_self", Vector2(), {"fn": "ev_" + modes_12[i]})
		cl_12.d["a_v"] = str(i + 1)
		# route the exec wire through a reroute node between calls
		var rr_12 := Model.add_node(g12, "reroute", Vector2(), {"t": "exec"})
		wire(g12, prev12, "then", rr_12, "i")
		wire(g12, rr_12, "o", cl_12, "exec")
		prev12 = cl_12
	var at_12 := Model.add_node(g12, "custom_event", Vector2(), {"name": "anim", "params": []})
	var tg_12 := Model.add_node(g12, "var_get", Vector2(), {"name": "tree"})
	var tv_12 := Model.add_node(g12, "tpl", Vector2(), {"id": "anim_travel"})
	var sp12 := Model.add_node(g12, "tpl", Vector2(), {"id": "anim_set_param"})
	wire(g12, at_12, "then", tv_12, "exec")
	wire(g12, tg_12, "value", tv_12, "tree")
	wire(g12, tv_12, "then", sp12, "exec")
	wire(g12, tg_12, "value", sp12, "tree")
	var c12 := Compiler.new()
	var code12 := c12.compile(b12)
	var o12 := build(b12, "rpc events, reroute, animation nodes")
	if o12:
		root.add_child(o12)
		o12.go()
		await process_frame
		var ann_12 := code12.contains("@rpc(\"any_peer\", \"call_local\", \"reliable\")\nfunc ev_server") and code12.contains("@rpc(\"authority\", \"call_local\", \"unreliable\")\nfunc ev_multicast")
		print("rpc: log=", o12.log, " annotations=", ann_12)
		if str(o12.log) != "[1, 2, 3]" or not ann_12:
			print("  WRONG RESULT")
			fails += 1
		o12.queue_free()
		await process_frame
	# tracing adds calls only when the class setting is on
	b12["trace"] = true
	var traced_12 := Compiler.new().compile(b12)
	b12["trace"] = false
	print("trace on adds calls: ", traced_12.contains("__sc_trace(1, "), "  off: ", not code12.contains("__sc_trace"))
	if not traced_12.contains("__sc_trace(1, ") or code12.contains("__sc_trace"):
		print("  WRONG RESULT")
		fails += 1
	print("trace sends pin values: ", traced_12.contains(", {\""))
	if not traced_12.contains(", {\""):
		print("  WRONG RESULT")
		fails += 1
	var gt12 := GDScript.new()
	gt12.source_code = traced_12
	if gt12.reload() != OK:
		print("  TRACED CODE REJECTED")
		fails += 1

	# --- 13: timeline event track fires once when playback crosses its key, before Finished
	var b13 := Model.new_schematic("Node", "")
	b13.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g13: Dictionary = b13.graphs[0]
	g13.nodes.clear()
	var st13 := Model.add_node(g13, "custom_event", Vector2(), {"name": "start", "params": []})
	var tl13 := Model.add_node(g13, "timeline", Vector2(), {"name": "Shot", "length": 0.2, "loop": false, "autoplay": false,
		"tracks": [{"name": "Alpha", "type": "float", "smooth": false, "keys": [[0.0, "0.0"], [0.2, "1.0"]]},
			{"name": "Fire", "type": "event", "keys": [[0.1, ""]]}]})
	var lg13 := Model.add_node(g13, "var_get", Vector2(), {"name": "log"})
	var a13 := Model.add_node(g13, "bcall", Vector2(), {"type": "Array", "method": "append"})
	a13.d["a0"] = "\"fire\""
	var f13 := Model.add_node(g13, "bcall", Vector2(), {"type": "Array", "method": "append"})
	f13.d["a0"] = "\"finished\""
	wire(g13, st13, "then", tl13, "play_start")
	wire(g13, tl13, "e_Fire", a13, "exec")
	wire(g13, lg13, "value", a13, "target")
	wire(g13, tl13, "finished", f13, "exec")
	wire(g13, lg13, "value", f13, "target")
	print("timeline pins: ", R.describe(tl13, b13, g13).outs.map(func(x): return "%s:%s" % [x.id, x.type]))
	var o13 := build(b13, "timeline event track")
	if o13:
		root.add_child(o13)
		o13.start()
		await create_timer(0.6).timeout
		print("event track log=", o13.log)
		if str(o13.log) != "[\"fire\", \"finished\"]":
			print("  WRONG RESULT")
			fails += 1
		o13.queue_free()
		await process_frame

	print("virtual _process found: ", not R.find_method("Node", "_process").is_empty(), "  static actions: ", R.static_actions().size(),
		"  chain(CharacterBody3D): ", R.chain_actions("CharacterBody3D").size())
	v7_tests()
	lambda_tests()
	print("FAILS: ", fails)
	quit(1 if fails else 0)
