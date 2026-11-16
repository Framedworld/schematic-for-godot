extends SceneTree
## Headless test of the code link: which graph nodes each line of generated GDScript came from, and the other way round.
## Run: godot --headless --path . --script res://tests/test_code_link.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const CodeLink := preload("res://addons/schematic/editor/sc_code_link.gd")

var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("PASS  ", label)
	else:
		print("FAIL  ", label, "  ", detail)
		fails += 1


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func var_of(name: String, type: String, default := "") -> Dictionary:
	return {"name": name, "type": type, "default": default, "export": false, "category": "", "tooltip": ""}


## Compiles a schematic and builds its link: {c, code, link, lines}.
func make(bp: Dictionary) -> Dictionary:
	var c := Compiler.new()
	var code := c.compile(bp)
	var link := CodeLink.new().build(c, code)
	return {"c": c, "code": code, "link": link, "lines": code.split("\n")}


## The first line (1-based) whose text, stripped, begins with `start`; 0 when there is none.
func line_starting(m: Dictionary, start: String, from := 1) -> int:
	for i in range(from - 1, m.lines.size()):
		if String(m.lines[i]).strip_edges().begins_with(start):
			return i + 1
	return 0


func ints(a: PackedInt32Array) -> Array:
	return Array(a)


func at_ids(m: Dictionary, line: int) -> Array:
	return m.link.nodes_at(line).map(func(p): return int(p[1]))


func pairs_equal(a: Array, b: Array) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	test_math_set()
	test_shared_getter()
	test_branch_and_loops()
	test_reroutes()
	test_macro()
	test_inline_lambda()
	test_trace()
	test_whole_scripts()
	test_comments()
	test_multi_line_strings()
	test_speed()
	print("CODE LINK FAILS: ", fails)
	quit()


## 1. A Set fed by a math node fed by two getters.
func test_math_set() -> void:
	print("==== 1: a Set fed by a math node fed by two getters ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("a", "int", "1"))
	bp.variables.append(var_of("b", "int", "2"))
	bp.variables.append(var_of("total", "int", "0"))
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var ga := Model.add_node(g, "var_get", Vector2(), {"name": "a"})
	var gb := Model.add_node(g, "var_get", Vector2(), {"name": "b"})
	var add := Model.add_node(g, "op", Vector2(), {"op": "+", "l": "int", "r": "int", "ret": "int"})
	var st := Model.add_node(g, "var_set", Vector2(), {"name": "total"})
	wire(g, ev, "then", st, "exec")
	wire(g, ga, "value", add, "a")
	wire(g, gb, "value", add, "b")
	wire(g, add, "ret", st, "value")
	var m := make(bp)
	var gid := int(g.id)
	var line := line_starting(m, "total =")
	check("1 setup: the Set wrote `total = ...`", line != 0 and m.c.errors.is_empty(), m.code)
	check("1 the Set owns exactly that one line", ints(m.link.own_lines_of(gid, st.id)) == [line], str(m.link.own_lines_of(gid, st.id)))
	check("1 lines_of(Set) is the same line", ints(m.link.lines_of(gid, st.id)) == [line])
	for pair in [["math", add], ["getter a", ga], ["getter b", gb]]:
		var n: Dictionary = pair[1]
		check("1 %s: lines_of is the Set's line" % pair[0], ints(m.link.lines_of(gid, n.id)) == [line], str(m.link.lines_of(gid, n.id)))
		check("1 %s: own_lines_of is empty" % pair[0], m.link.own_lines_of(gid, n.id).is_empty())
	check("1 nodes_at lists the Set, then the math node, then the getters (a before b)",
		pairs_equal(m.link.nodes_at(line), [[gid, st.id], [gid, add.id], [gid, ga.id], [gid, gb.id]]), str(m.link.nodes_at(line)))
	var header := line_starting(m, "func go(")
	check("1 the function header belongs to the event node", ints(m.link.own_lines_of(gid, ev.id)).has(header) and m.link.kind_of_line(header) == "function"
		and pairs_equal(m.link.nodes_at(header), [[gid, ev.id]]), str(m.link.own_lines_of(gid, ev.id)))
	check("1 kind_of_line of the Set's line is node, and graph_of_line is the graph", m.link.kind_of_line(line) == "node" and m.link.graph_of_line(line) == gid)


## 2. One getter read by two execution nodes.
func test_shared_getter() -> void:
	print("==== 2: one getter read by two execution nodes ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("a", "int", "1"))
	bp.variables.append(var_of("x", "int", "0"))
	bp.variables.append(var_of("y", "int", "0"))
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var ga := Model.add_node(g, "var_get", Vector2(), {"name": "a"})
	var s1 := Model.add_node(g, "var_set", Vector2(), {"name": "x"})
	var s2 := Model.add_node(g, "var_set", Vector2(), {"name": "y"})
	wire(g, ev, "then", s1, "exec")
	wire(g, s1, "then", s2, "exec")
	wire(g, ga, "value", s1, "value")
	wire(g, ga, "value", s2, "value")
	var m := make(bp)
	var gid := int(g.id)
	var l1 := line_starting(m, "x =")
	var l2 := line_starting(m, "y =")
	check("2 setup: both Sets wrote a line", l1 != 0 and l2 != 0 and l1 != l2, m.code)
	check("2 the getter has both lines", ints(m.link.lines_of(gid, ga.id)) == [l1, l2], str(m.link.lines_of(gid, ga.id)))
	check("2 and each line names the getter", at_ids(m, l1).has(int(ga.id)) and at_ids(m, l2).has(int(ga.id)))
	check("2 each Set has only its own line", ints(m.link.lines_of(gid, s1.id)) == [l1] and ints(m.link.lines_of(gid, s2.id)) == [l2])


## 3. A Branch (both lines), a For loop header and a node inside the loop body; a getter feeding the condition.
func test_branch_and_loops() -> void:
	print("==== 3: Branch, For loop, loop body ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("flag", "bool", "false"))
	bp.variables.append(var_of("n", "int", "0"))
	bp.variables.append(var_of("log", "Array"))
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var gf := Model.add_node(g, "var_get", Vector2(), {"name": "flag"})
	var br := Model.add_node(g, "branch", Vector2(), {})
	var p_yes := Model.add_node(g, "print", Vector2(), {})
	p_yes.d["text"] = "\"yes\""
	var p_no := Model.add_node(g, "print", Vector2(), {})
	p_no.d["text"] = "\"no\""
	var lp := Model.add_node(g, "for", Vector2(), {})
	lp.d["first"] = "0"
	lp.d["last"] = "3"
	var gl := Model.add_node(g, "var_get", Vector2(), {"name": "log"})
	var app := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g, ev, "then", br, "exec")
	wire(g, gf, "value", br, "cond")
	wire(g, br, "true", p_yes, "exec")
	wire(g, br, "false", p_no, "exec")
	wire(g, p_no, "then", lp, "exec")
	wire(g, p_yes, "then", lp, "exec")
	wire(g, lp, "body", app, "exec")
	wire(g, gl, "value", app, "target")
	wire(g, lp, "index", app, "a0")
	var m := make(bp)
	var gid := int(g.id)
	print(m.code)
	var if_line := line_starting(m, "if ")
	var else_line := line_starting(m, "else:")
	var own := ints(m.link.own_lines_of(gid, br.id))
	check("3 setup: compiles with an if and an else", if_line != 0 and else_line != 0 and m.c.errors.is_empty(), str(m.c.errors))
	check("3 the Branch owns its `if` line and its `else:` line", own == [if_line, else_line], str(own))
	check("3 the condition getter is in the `if` line only (an `else:` holds no expression)",
		ints(m.link.lines_of(gid, gf.id)) == [if_line] and not at_ids(m, else_line).has(int(gf.id)), str(m.link.lines_of(gid, gf.id)))
	check("3 nodes_at(`else:`) is the Branch alone", pairs_equal(m.link.nodes_at(else_line), [[gid, br.id]]), str(m.link.nodes_at(else_line)))
	var for_line := line_starting(m, "for ")
	check("3 the For loop owns its header", for_line != 0 and ints(m.link.own_lines_of(gid, lp.id)).has(for_line), str(m.link.own_lines_of(gid, lp.id)))
	var body := line_starting(m, "log.append(", for_line)
	if body == 0:
		body = line_starting(m, "var ", for_line + 1)
	check("3 the node in the loop body has its own line, below the header", body > for_line and ints(m.link.own_lines_of(gid, app.id)).has(body), "%d %s" % [body, str(m.link.own_lines_of(gid, app.id))])
	check("3 the loop variable and the log getter are in the body line, not the header",
		at_ids(m, body).has(int(gl.id)) and not at_ids(m, for_line).has(int(gl.id)))


## 4. A reroute on a data wire and one on an execution wire.
func test_reroutes() -> void:
	print("==== 4: reroutes ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("a", "int", "1"))
	bp.variables.append(var_of("x", "int", "0"))
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var ga := Model.add_node(g, "var_get", Vector2(), {"name": "a"})
	var rd := Model.add_node(g, "reroute", Vector2(), {"t": "int"})
	var rx := Model.add_node(g, "reroute", Vector2(), {"t": "exec"})
	var st := Model.add_node(g, "var_set", Vector2(), {"name": "x"})
	wire(g, ev, "then", rx, "i")
	wire(g, rx, "o", st, "exec")
	wire(g, ga, "value", rd, "i")
	wire(g, rd, "o", st, "value")
	var m := make(bp)
	var gid := int(g.id)
	var line := line_starting(m, "x =")
	check("4 setup: the Set wrote its line through both reroutes", line != 0 and m.c.errors.is_empty(), m.code + str(m.c.errors))
	check("4 data reroute: the Set's line, no line of its own", ints(m.link.lines_of(gid, rd.id)) == [line] and m.link.own_lines_of(gid, rd.id).is_empty())
	check("4 nodes_at: the Set, the data reroute, then the getter", pairs_equal(m.link.nodes_at(line), [[gid, st.id], [gid, rd.id], [gid, ga.id]]), str(m.link.nodes_at(line)))
	check("4 the getter has the line through the reroute", ints(m.link.lines_of(gid, ga.id)) == [line])
	check("4 execution reroute: lines_of and own_lines_of are empty (it is a knot, the line is the next node's)",
		m.link.lines_of(gid, rx.id).is_empty() and m.link.own_lines_of(gid, rx.id).is_empty())
	check("4 execution reroute is not listed for the line after it", not at_ids(m, line).has(int(rx.id)))


## 5. A macro call: its lines are its expansion's; nodes_at names the call node, not the nodes inside the macro.
func test_macro() -> void:
	print("==== 5: macro ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("log", "Array"))
	bp.variables.append(var_of("seed_value", "int", "5"))
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var mg := Model.new_graph(bp, "once_add", "macro")
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
	var go := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var seed_get := Model.add_node(g, "var_get", Vector2(), {"name": "seed_value"})
	var ca := Model.add_node(g, "macro", Vector2(), {"name": "once_add"})
	var cb := Model.add_node(g, "macro", Vector2(), {"name": "once_add"})
	var l3 := Model.add_node(g, "var_get", Vector2(), {"name": "log"})
	var a3 := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g, go, "then", ca, "i_In")
	wire(g, seed_get, "value", ca, "i_value")
	wire(g, ca, "o_Out", cb, "i_In")
	wire(g, ca, "o_doubled", cb, "i_value")
	wire(g, cb, "o_Out", a3, "exec")
	wire(g, l3, "value", a3, "target")
	wire(g, cb, "o_doubled", a3, "a0")
	var m := make(bp)
	var gid := int(g.id)
	print(m.code)
	check("5 setup: compiles", m.c.errors.is_empty(), str(m.c.errors))
	for call_pair in [["first call", ca], ["second call", cb]]:
		var call: Dictionary = call_pair[1]
		var own := ints(m.link.own_lines_of(gid, call.id))
		check("5 %s: the macro node has lines of its own" % call_pair[0], not own.is_empty(), m.code)
		check("5 %s: lines_of is the same as own_lines_of" % call_pair[0], ints(m.link.lines_of(gid, call.id)) == own)
		var all_named := true
		for line in own:
			var at: Array = m.link.nodes_at(line)
			if at.is_empty() or not pairs_equal(at[0], [gid, int(call.id)]) or m.link.graph_of_line(line) != gid:
				all_named = false
		check("5 %s: nodes_at of each of its lines starts with the macro node, in the calling graph" % call_pair[0], all_named, str(own))
	check("5 the two calls do not share a line", ints(m.link.own_lines_of(gid, ca.id)).filter(func(l): return ints(m.link.own_lines_of(gid, cb.id)).has(l)).is_empty())
	var inner_empty := true
	for n in mg.nodes:
		if not m.link.lines_of(int(mg.id), int(n.id)).is_empty():
			inner_empty = false
	check("5 the nodes inside the macro's own graph have no lines", inner_empty)
	var seed_lines := ints(m.link.lines_of(gid, seed_get.id))
	check("5 a getter wired into the macro call takes part in the macro's lines", not seed_lines.is_empty() and seed_lines.all(func(l): return ints(m.link.own_lines_of(gid, ca.id)).has(l)), str(seed_lines))
	var decl_kinds := ints(m.link.own_lines_of(gid, ca.id)).map(func(l): return m.link.kind_of_line(l))
	check("5 the macro's lines are code (node) and the member the Do Once needs (declaration)", decl_kinds.has("node") and decl_kinds.has("declaration"), str(decl_kinds))


const LAMBDA_SOURCE := "extends Node\n\nvar out: Array = []\n\nfunc _ready() -> void:\n\tvar base := 10\n\tvar add_base := func(x): return x + base\n\tout.append(add_base.call(1))\n"


## 6. An inline lambda from a converted script.
func test_inline_lambda() -> void:
	print("==== 6: inline lambda ====")
	var bp: Dictionary = Importer.new().convert(LAMBDA_SOURCE, {}).bp
	var m := make(bp)
	print(m.code)
	var lam: Dictionary = {}
	for g in bp.graphs:
		if g.has("lambda"):
			lam = g
	var head := line_starting(m, "var add_base")
	if head == 0:
		head = _line_containing(m, "func(")
	check("6 setup: the importer made a lambda graph and the compiler wrote it inline", not lam.is_empty() and head != 0 and not m.code.contains("func _ready_lambda") and not m.code.contains("func add_base("), m.code)
	if lam.is_empty() or head == 0:
		return
	var outer := int(m.link.graph_of_line(head))
	check("6 the line that opens the lambda belongs to the outer graph", outer != int(lam.id) and outer > 0, "graph %d" % outer)
	var body := head + 1
	check("6 the lambda body line answers with the lambda's graph", m.link.graph_of_line(body) == int(lam.id) and int(m.link.nodes_at(body)[0][0]) == int(lam.id), str(m.link.nodes_at(body)))
	var entry := {}
	for n in lam.nodes:
		if n.kind == "fn_entry":
			entry = n
	check("6 the lambda's entry node has the opening line as its header", ints(m.link.lines_of(int(lam.id), int(entry.id))).has(head), str(m.link.lines_of(int(lam.id), int(entry.id))))
	check("6 nodes_at(opening line) names the outer node first and the lambda entry last", int(m.link.nodes_at(head)[0][0]) == outer and pairs_equal(m.link.nodes_at(head).back(), [int(lam.id), int(entry.id)]), str(m.link.nodes_at(head)))
	check("6 kind_of_line: the opening line is a node line, the lambda body too", m.link.kind_of_line(head) == "node" and m.link.kind_of_line(body) == "node")
	var lam_lines := 0
	for line in range(1, m.link.line_count + 1):
		if m.link.graph_of_line(line) == int(lam.id):
			lam_lines += 1
	check("6 no function of its own for the lambda; its body is %d line(s) of the lambda graph inside _ready" % lam_lines, lam_lines >= 1)


func _line_containing(m: Dictionary, text: String) -> int:
	for i in m.lines.size():
		if String(m.lines[i]).contains(text):
			return i + 1
	return 0


## 8. With trace on, the trace lines map to the node they report.
func test_trace() -> void:
	print("==== 8: trace ====")
	var bp := Model.new_schematic("Node", "")
	bp.variables.append(var_of("a", "int", "1"))
	bp.variables.append(var_of("b", "int", "2"))
	bp.variables.append(var_of("total", "int", "0"))
	bp["trace"] = true
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": "go", "params": []})
	var ga := Model.add_node(g, "var_get", Vector2(), {"name": "a"})
	var gb := Model.add_node(g, "var_get", Vector2(), {"name": "b"})
	var add := Model.add_node(g, "op", Vector2(), {"op": "+", "l": "int", "r": "int", "ret": "int"})
	var st := Model.add_node(g, "var_set", Vector2(), {"name": "total"})
	var pr := Model.add_node(g, "print", Vector2(), {})
	wire(g, ev, "then", st, "exec")
	wire(g, st, "then", pr, "exec")
	wire(g, ga, "value", add, "a")
	wire(g, gb, "value", add, "b")
	wire(g, add, "ret", st, "value")
	var m := make(bp)
	var gid := int(g.id)
	print(m.code)
	var traces := []
	var helper_lines := 0
	var wrong := []
	for line in range(1, m.link.line_count + 1):
		var kind: String = m.link.kind_of_line(line)
		if kind == "helper":
			helper_lines += 1
		if kind != "trace":
			continue
		traces.append(line)
		var text := String(m.lines[line - 1]).strip_edges()
		var args := text.trim_prefix("__sc_trace(").split(",")
		var named: Array = m.link.nodes_at(line)[0]
		if int(args[0]) != int(named[0]) or int(args[1]) != int(named[1]):
			wrong.append(line)
	check("8 trace lines exist (one for the Set, one for the Print) and each maps to the node it reports", traces.size() == 2 and wrong.is_empty(), "%s %s" % [str(traces), str(wrong)])
	check("8 the Set's own lines are its statement and its trace line", ints(m.link.own_lines_of(gid, st.id)).size() == 2 and ints(m.link.own_lines_of(gid, st.id)).has(traces[0]), str(m.link.own_lines_of(gid, st.id)))
	var t_set: int = traces[0]
	check("8 the math node and getters are in the Set's trace line (it reports the value arriving)", at_ids(m, t_set).has(int(add.id)) and at_ids(m, t_set).has(int(ga.id)), str(m.link.nodes_at(t_set)))
	check("8 the helpers the compiler wrote for tracing (__sc_trace, __sc_flush) are helper lines, with no node", helper_lines > 10 and m.link.nodes_at(line_starting(m, "func __sc_trace(")).is_empty() and m.link.kind_of_line(line_starting(m, "func __sc_trace(")) == "helper")
	var member := line_starting(m, "var __sc_hits")
	check("8 `var __sc_hits` is a declaration with no node", member != 0 and m.link.kind_of_line(member) == "declaration" and m.link.nodes_at(member).is_empty())


## Graphs of a script to check as a whole: [label, bp].
func whole_scripts() -> Array:
	var out := []
	out.append(["demo/SC_Demo.gd", Model.load_file("res://demo/SC_Demo.gd")])
	for sample in ["control_flow", "lambdas_inline", "scoping", "classes", "functions", "values", "waiting", "review_events", "comments", "lambda_comments", "comments_blocks"]:
		out.append(["converted %s.gd" % sample, Importer.new().convert(FileAccess.get_file_as_string("res://tests/convert/%s.gd" % sample), {}).bp])
	return out


## 7 and 9. Whole scripts.
func test_whole_scripts() -> void:
	print("==== 7 and 9: whole scripts ====")
	var seen_kinds := {}
	var scripts := whole_scripts()
	for entry in scripts:
		var label: String = entry[0]
		var bp: Dictionary = entry[1]
		for trace in [false, true]:
			if trace and label != "demo/SC_Demo.gd" and label != "converted control_flow.gd":
				continue
			bp["trace"] = trace
			var m := make(bp)
			var tag := "%s%s" % [label, " (trace on)" if trace else ""]
			var link: RefCounted = m.link
			var bad_kind := []
			var node_without := []
			var counts := {}
			for line in range(1, link.line_count + 1):
				var kind: String = link.kind_of_line(line)
				counts[kind] = int(counts.get(kind, 0)) + 1
				seen_kinds[kind] = true
				if not kind in CodeLink.KINDS:
					bad_kind.append(line)
				if kind in ["node", "trace"] and link.nodes_at(line).is_empty():
					node_without.append(line)
				if kind in ["header", "carried", "blank", "helper"] and not link.nodes_at(line).is_empty() and kind != "helper":
					node_without.append(-line)
				if kind in ["node", "trace"] and link.graph_of_line(line) < 1:
					node_without.append(line)
			check("7 %s: all %d lines have a kind from the set (%s)" % [tag, link.line_count, str(counts)], bad_kind.is_empty() and link.kind_of_line(0) == "" and link.kind_of_line(link.line_count + 1) == "", str(bad_kind))
			check("7 %s: every node/trace line has a node and a graph, no header/blank/carried line has one" % tag, node_without.is_empty(), str(node_without))
			# execution nodes reachable from an entry that have no line at all
			var empties := _unwritten_exec_nodes(bp, link)
			var unexplained := empties.filter(func(e): return not e.explained)
			for e in empties:
				print("      zero lines: graph %s node %d (%s)%s" % [e.graph, e.id, e.kind, "  -- " + e.why if e.explained else "  -- UNEXPLAINED"])
			check("7 %s: no execution node reachable from an entry is left without lines (%d listed, all explained)" % [tag, empties.size()], unexplained.is_empty())
			# 9. the round trip
			var broken := []
			var total := 0
			for g in bp.graphs:
				for n in g.nodes:
					for line in link.lines_of(int(g.id), int(n.id)):
						total += 1
						var found := false
						for p in link.nodes_at(line):
							if int(p[0]) == int(g.id) and int(p[1]) == int(n.id):
								found = true
						if not found:
							broken.append("%d:%d line %d" % [g.id, n.id, line])
					for line in link.own_lines_of(int(g.id), int(n.id)):
						if not Array(link.lines_of(int(g.id), int(n.id))).has(line):
							broken.append("own %d:%d line %d" % [g.id, n.id, line])
			check("9 %s: for every node and each of its %d lines, the node is in nodes_at(line)" % [tag, total], broken.is_empty() and total > 0, str(broken.slice(0, 8)))
			# and the other way: every node nodes_at names has the line
			var missing := []
			for line in range(1, link.line_count + 1):
				for p in link.nodes_at(line):
					if not Array(link.lines_of(int(p[0]), int(p[1]))).has(line):
						missing.append("line %d: %s" % [line, str(p)])
			check("9 %s: and every node nodes_at names has that line in lines_of" % tag, missing.is_empty(), str(missing.slice(0, 8)))
	var absent := []
	for kind in CodeLink.KINDS:
		if not seen_kinds.has(kind):
			absent.append(kind)
	check("7 every kind of the set shows up somewhere in these scripts", absent.is_empty(), "missing %s" % str(absent))


## Comment lines (a converted script's comments): kind "comment", their node answers nodes_at (that node only), lines_of
## has them and own_lines_of does not.
func test_comments() -> void:
	print("==== comments ====")
	for sample in ["comments", "lambda_comments", "comments_blocks"]:
		var bp: Dictionary = Importer.new().convert(FileAccess.get_file_as_string("res://tests/convert/%s.gd" % sample), {}).bp
		var m := make(bp)
		var link: RefCounted = m.link
		var listed: Dictionary = m.c.comment_lines
		var total := 0
		var with_node := 0
		var wrong := []
		var in_own := []
		var not_in_lines := []
		var extra_nodes := []
		var plain := 0
		for line in range(1, link.line_count + 1):
			var kind: String = link.kind_of_line(line)
			var text: String = link.text_of_line(line).strip_edges()
			if listed.has(line):
				total += 1
				if kind != "comment" or not text.begins_with("#"):
					wrong.append("%d %s '%s'" % [line, kind, text])
				var nodes: Array = link.nodes_at(line)
				if not nodes.is_empty():
					with_node += 1
					if nodes.size() != 1:
						extra_nodes.append(line)
					var gid := int(nodes[0][0])
					var nid := int(nodes[0][1])
					if not Array(link.lines_of(gid, nid)).has(line):
						not_in_lines.append(line)
					if Array(link.own_lines_of(gid, nid)).has(line) or not Array(link.comment_lines_of(gid, nid)).has(line):
						in_own.append(line)
			elif kind == "comment":
				wrong.append("%d is a comment but is not listed" % line)
			elif text.begins_with("#") and not text.begins_with("##") and not text.begins_with("# @schematic") and not text.begins_with("#region") and not text.begins_with("#endregion"):
				plain += 1
				wrong.append("%d is a # line not classified as a comment: '%s'" % [line, text])
		check("10 %s: %d comment lines, every one of kind comment and the others are not (%d with a node)" % [sample, total, with_node], total > 3 and wrong.is_empty() and with_node > 2, str(wrong.slice(0, 6)))
		check("10 %s: a comment line gives its node alone, lines_of has it, own_lines_of does not" % sample, extra_nodes.is_empty() and not_in_lines.is_empty() and in_own.is_empty(), "%s %s %s" % [extra_nodes, not_in_lines, in_own])
		check("10 %s: a comment's label is 'Comment'" % sample, CodeLink.LABELS.get("comment", "") == "Comment")
	# a comment above a statement: the statement's node has both lines; the node's own line is the statement alone
	var src := "extends Node\n\nvar out: Array = []\n\n\nfunc go() -> void:\n\t# say hello\n\tout.append(1)   # why\n\tout.append(2)\n"
	var m2 := make(Importer.new().convert(src, {}).bp)
	var note_line := line_starting(m2, "# say hello")
	var stmt := line_starting(m2, "out.append(1)")
	check("10 a note above a statement: its line is a comment, the statement's is a node, both the same node", note_line > 0 and stmt == note_line + 1 and m2.link.kind_of_line(note_line) == "comment" and m2.link.kind_of_line(stmt) == "node"
		and m2.link.nodes_at(note_line).size() == 1 and m2.link.nodes_at(note_line)[0] == m2.link.nodes_at(stmt)[0], str(m2.link.nodes_at(note_line)))
	var owner: Array = m2.link.nodes_at(stmt)[0]
	check("10 ... lines_of has the comment and the statement, own_lines_of the statement only", ints(m2.link.lines_of(int(owner[0]), int(owner[1]))) == [note_line, stmt] and ints(m2.link.own_lines_of(int(owner[0]), int(owner[1]))) == [stmt],
		str(ints(m2.link.lines_of(int(owner[0]), int(owner[1])))))
	check("10 a trailing comment stays part of its statement's line (a node line, no comment line of its own)", m2.link.kind_of_line(stmt) == "node" and m2.link.text_of_line(stmt).contains("# why"))
	# a comment above a lambda's first statement does not hide the line that opens the lambda
	var lsrc := "extends Node\n\nvar out: Array = []\n\n\nfunc _ready() -> void:\n\tvar base := 10\n\tvar f := func(x):\n\t\t# inside\n\t\treturn x + base\n\tout.append(f.call(1))\n"
	var m3 := make(Importer.new().convert(lsrc, {}).bp)
	var open3 := line_starting(m3, "var f := func")
	var body3 := line_starting(m3, "return x + base")
	check("10 a lambda whose body starts with a comment: the opening line is still the lambda entry's", open3 > 0 and body3 > open3 and m3.link.kind_of_line(open3 + 1) == "comment" and m3.link.nodes_at(open3).size() >= 2, str(m3.code))


## Execution nodes (not pure, not an entry) that can be reached from an entry along execution wires and have no
## line, as [{graph, id, kind, explained, why}]. A node can be reached and still be unwritten when the compiler
## left it out on purpose; each such reason is named here, anything else is "unexplained" and fails the test.
func _unwritten_exec_nodes(bp: Dictionary, link: RefCounted) -> Array:
	var out := []
	for g in bp.graphs:
		if String(g.kind) == "macro":
			continue
		var nodes := {}
		for n in g.nodes:
			nodes[int(n.id)] = n
		var descs := {}
		for n in g.nodes:
			descs[int(n.id)] = R.describe(n, bp, g)
		var reached := {}
		var queue := []
		for n in g.nodes:
			if n.kind in ["event", "custom_event", "input_action", "signal_event", "key_event", "fn_entry"]:
				reached[int(n.id)] = true
				queue.append(int(n.id))
		var i := 0
		while i < queue.size():
			var cur: int = queue[i]
			i += 1
			for w in g.wires:
				if int(w[0]) != cur or not nodes.has(int(w[2])):
					continue
				var pins: Array = descs[cur].outs.filter(func(o): return String(o.id) == String(w[1]))
				if pins.is_empty() or String(pins[0].type) != "exec" or reached.has(int(w[2])):
					continue
				reached[int(w[2])] = true
				queue.append(int(w[2]))
		for id in reached:
			var n: Dictionary = nodes[id]
			if bool(descs[id].pure) or n.kind in ["event", "custom_event", "input_action", "signal_event", "key_event", "fn_entry"]:
				continue
			if not link.lines_of(int(g.id), id).is_empty():
				continue
			# A Sequence runs its pins one after another and writes no statement of its own: what hangs on each pin is
			# written in order, each by its own node. (When a pin waits, the wrapping lines are the Sequence's: those
			# nodes have lines and are not listed.) lines_of is empty for it, which is right: the code it stands for
			# is the lines of the nodes it chains.
			var why := "writes no statement: its pins run in order, each by its own nodes" if String(n.kind) == "sequence" else ""
			out.append({"graph": String(g.name), "id": id, "kind": String(n.kind), "explained": why != "", "why": why})
	return out


## Largest script available, plus a synthetic one of about 2,000 lines: how long compile and build take.
func test_speed() -> void:
	print("==== speed ====")
	var src := "extends Node\n\nvar total := 0\nvar items: Array = []\n\n"
	for i in 150:
		src += "func work_%d(a: int, b: int) -> int:\n\tvar x := a + b * %d\n\tif x > %d:\n\t\ttotal += x\n\t\titems.append(x * 2)\n\telse:\n\t\ttotal -= 1\n\tfor k in range(3):\n\t\ttotal += k + a\n\tprint(\"work\", x, total)\n\treturn x + total\n\n" % [i, i + 2, i * 3]
	var bp: Dictionary = Importer.new().convert(src, {}).bp
	var t0 := Time.get_ticks_usec()
	var c := Compiler.new()
	var code := c.compile(bp)
	var t1 := Time.get_ticks_usec()
	var link := CodeLink.new().build(c, code)
	var t2 := Time.get_ticks_usec()
	var nodes := 0
	for g in bp.graphs:
		nodes += g.nodes.size()
	# and a round of queries, as the editor would make them: every node's lines, every line's nodes
	for g in bp.graphs:
		for n in g.nodes:
			link.lines_of(int(g.id), int(n.id))
	for line in range(1, link.line_count + 1):
		link.nodes_at(line)
	var t3 := Time.get_ticks_usec()
	print("TIMING synthetic script: %d lines, %d nodes: compile %.1f ms, build %.1f ms, then every query once %.1f ms" % [link.line_count, nodes, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0])
	check("speed: the synthetic script is about 2,000 lines and the link built", link.line_count > 1500, str(link.line_count))


## A string that runs over several lines takes several lines of the text: what is recorded for the lines after it
## must still be those lines (the function header's record on the header's line, a node's record on its line).
func test_multi_line_strings() -> void:
	var src := "extends Node

var banner := \"\"\"first
second
third\"\"\"
var count := 0


func bump(n: int) -> void:
	count += n
	print(\"\"\"a
b\"\"\")
	count -= 1
"
	var m := make(Importer.new().convert(src, {}).bp)
	var header := line_starting(m, "func bump(")
	var plus := line_starting(m, "count += n")
	var minus := line_starting(m, "count -= 1")
	check("multi-line strings: the script has the three lines looked for", header > 0 and plus > header and minus > plus, "%d %d %d" % [header, plus, minus])
	check("multi-line strings: the header line is recorded as the function", m.link.kind_of_line(header) == "function", m.link.kind_of_line(header))
	check("multi-line strings: the line after the member's string is a declaration", m.link.kind_of_line(line_starting(m, "var count")) == "declaration")
	var plus_nodes: Array = m.link.nodes_at(plus)
	var minus_nodes: Array = m.link.nodes_at(minus)
	check("multi-line strings: a statement before the string in the body has its node", not plus_nodes.is_empty() and ints(m.link.own_lines_of(int(plus_nodes[0][0]), int(plus_nodes[0][1]))).has(plus), str(plus_nodes))
	check("multi-line strings: a statement after the string in the body has its node", not minus_nodes.is_empty() and ints(m.link.own_lines_of(int(minus_nodes[0][0]), int(minus_nodes[0][1]))).has(minus), str(minus_nodes))
	check("multi-line strings: the two statements are different nodes", plus_nodes != minus_nodes)
	var blocks: Array = m.c.block_lines
	var found := false
	for b in blocks:
		if String(b[2]) == "bump":
			found = int(b[0]) == header and int(b[1]) == minus
	check("multi-line strings: the function's block runs from its header to its last line", found, str(blocks))
