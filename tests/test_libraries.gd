extends SceneTree
## Function libraries (static functions any blueprint can call) and macro libraries (macros shared between
## blueprint files). Run: godot --headless --path . --script res://tests/test_libraries.gd
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const Compiler := preload("res://addons/blueprints/core/bp_compiler.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const Starters := preload("res://addons/blueprints/core/bp_starters.gd")

const DIR := "res://tests/tmp/libs/"
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func build(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	return [code, c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))]


func write(file: String, bp: Dictionary) -> String:
	var out := build(bp)
	var f := FileAccess.open(DIR + file, FileAccess.WRITE)
	f.store_string(Model.build_source(out[0], bp))
	f.close()
	R.invalidate_libraries()
	return out[0]


func script_from(code: String) -> GDScript:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			lines[i] = "#"
	var scr := GDScript.new()
	scr.source_code = "\n".join(lines)
	return scr if scr.reload() == OK else null


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()

	# ================================================================ function library
	var lib := Model.new_blueprint("RefCounted", "BP_TLib")
	lib["library"] = "function"
	lib.variables.append({"name": "calls", "type": "int", "default": "", "export": true, "category": "", "tooltip": ""})
	# pure: double(x) -> x * 2
	var dbl := Model.new_graph(lib, "double", "function")
	dbl.inputs = [["x", "int"]]
	dbl.outputs = [["result", "int"]]
	dbl.pure = true
	var d_mul := Model.add_node(dbl, "math", Vector2(300, 300), {"op": "*", "n": 2})
	d_mul.d["a1"] = "2"
	wire(dbl, dbl.nodes[0], "then", dbl.nodes[1], "exec")
	wire(dbl, dbl.nodes[0], "p_x", d_mul, "a0")
	wire(dbl, d_mul, "ret", dbl.nodes[1], "r_result")
	# impure: bump() -> counts its calls in a library variable, and uses a sibling function
	var bump := Model.new_graph(lib, "bump", "function")
	bump.outputs = [["total", "int"]]
	var b_inc := Model.add_node(bump, "var_inc", Vector2(300, 120), {"name": "calls", "by": 1})
	var b_dbl := Model.add_node(bump, "call_self", Vector2(520, 300), {"fn": "double"})
	wire(bump, bump.nodes[0], "then", b_inc, "exec")
	wire(bump, b_inc, "then", bump.nodes[1], "exec")
	wire(bump, b_inc, "value", b_dbl, "a_x")
	wire(bump, b_dbl, "r_result", bump.nodes[1], "r_total")
	var lib_code := write("BP_TLib.gd", lib)
	var lib_out := build(lib)
	check("function library compiles", lib_out[1].is_empty(), str(lib_out[1]))
	check("its functions and variables are static", lib_code.contains("static func double(x: int) -> int:") and lib_code.contains("static func bump() -> int:")
		and lib_code.contains("static var calls: int") and not lib_code.contains("@export"))
	var lib_scr := script_from(lib_code)
	check("generated library loads", lib_scr != null)
	if lib_scr:
		check("static call without an instance", lib_scr.double(21) == 42)
		lib_scr.bump()
		check("library variable is shared state", lib_scr.bump() == 4 and lib_scr.calls == 2, "calls %d" % lib_scr.calls)

	# what a library can't have
	var bad := lib.duplicate(true)
	bad["class_name"] = ""
	check("no class name is an error", build(bad)[1].any(func(m): return m.contains("needs a Class Name")), str(build(bad)[1]))
	bad = lib.duplicate(true)
	var bad_ev := Model.add_node(bad.graphs[0], "custom_event", Vector2(80, 80), {"name": "Oops", "params": []})
	var bad_pr := Model.add_node(bad.graphs[0], "print", Vector2(300, 80), {})
	wire(bad.graphs[0], bad_ev, "then", bad_pr, "exec")
	check("an event in a library is an error", build(bad)[1].any(func(m): return m.contains("only functions")), str(build(bad)[1]))
	bad = lib.duplicate(true)
	bad.dispatchers.append({"name": "changed", "params": []})
	check("a dispatcher in a library is an error", build(bad)[1].any(func(m): return m.contains("event dispatchers")), str(build(bad)[1]))

	# another blueprint calls it. (The class is registered by hand here; the editor test does it for real.)
	T._globals["BP_TLib"] = {"base": "RefCounted", "path": DIR + "BP_TLib.gd"}
	check("the library is found by the project scan", R.libraries().any(func(l): return l.kind == "function" and l.name == "BP_TLib"), str(R.libraries()))
	var acts := R.all_class_actions().filter(func(a): return String(a.c).begins_with("Function Libraries|BP_TLib"))
	var labels := acts.map(func(a): return String(a.l))
	check("its functions are listed under Function Libraries", labels.has("Double") and labels.has("Bump"), str(labels))
	var user := Model.new_blueprint("Node", "")
	user.variables.append({"name": "a", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	user.variables.append({"name": "b", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	var ug: Dictionary = user.graphs[0]
	ug.nodes.remove_at(1)
	var u_dbl := Model.add_node(ug, "call", Vector2(300, 300), {"cls": "BP_TLib", "method": "double"})
	u_dbl.d["a0"] = "5"
	var u_seta := Model.add_node(ug, "var_set", Vector2(300, 80), {"name": "a"})
	var u_bump := Model.add_node(ug, "call", Vector2(560, 80), {"cls": "BP_TLib", "method": "bump"})
	var u_setb := Model.add_node(ug, "var_set", Vector2(820, 80), {"name": "b"})
	wire(ug, ug.nodes[0], "then", u_seta, "exec")
	wire(ug, u_dbl, "ret", u_seta, "value")
	wire(ug, u_seta, "then", u_bump, "exec")
	wire(ug, u_bump, "then", u_setb, "exec")
	wire(ug, u_bump, "ret", u_setb, "value")
	var dd := R.describe(u_dbl, user, ug)
	var bd := R.describe(u_bump, user, ug)
	check("a pure library function has no exec pins and no Target pin", dd.pure and dd.ins.size() == 1 and dd.ins[0].id == "a0", str(dd.ins.map(func(p): return p.id)))
	check("an impure one has exec pins and no Target pin", not bd.pure and bd.ins.size() == 1 and bd.ins[0].type == "exec", str(bd.ins.map(func(p): return p.id)))
	var user_out := build(user)
	check("the calling blueprint compiles to BP_TLib.double(...)", user_out[1].is_empty() and String(user_out[0]).contains("BP_TLib.double(5)") and String(user_out[0]).contains("BP_TLib.bump()"), str(user_out[1]))
	var user_scr := script_from(String(user_out[0]).replace("BP_TLib.", "load(\"%sBP_TLib.gd\")." % DIR))
	if user_scr:
		var node := Node.new()
		node.set_script(user_scr)
		root.add_child(node)
		await process_frame
		check("it runs: double(5) and the shared counter", node.a == 10 and node.b == 2, "a %d b %d" % [node.a, node.b])
		node.queue_free()
	else:
		check("the calling blueprint loads", false)

	# ================================================================ macro library
	var ml := Starters.build("macro_library", "")
	# Twice: uses the library's own Repeat macro (a macro inside a library that uses a sibling)
	var tw := Model.new_graph(ml, "Twice", "macro")
	tw.outputs = [["Body", "exec"], ["Done", "exec"]]
	var tw_rep := Model.add_node(tw, "macro", Vector2(300, 120), {"name": "Repeat"})
	tw_rep.d["i_Times"] = "2"
	wire(tw, tw.nodes[0], "i_In", tw_rep, "i_In")
	wire(tw, tw_rep, "o_Body", tw.nodes[1], "o_Body")
	wire(tw, tw_rep, "o_Done", tw.nodes[1], "o_Done")
	var ml_out := build(ml)
	check("macro library compiles", ml_out[1].is_empty(), str(ml_out[1]))
	var ml_path := DIR + "BP_TMacros.gd"
	write("BP_TMacros.gd", ml)
	check("the macro library is found by the project scan", R.libraries().any(func(l): return l.kind == "macro" and l.path == ml_path), str(R.libraries()))

	var mu := Model.new_blueprint("Node", "")
	mu.variables.append({"name": "hits", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	mu.variables.append({"name": "sum", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	mu.variables.append({"name": "done", "type": "bool", "default": "", "export": false, "category": "", "tooltip": ""})
	var mg: Dictionary = mu.graphs[0]
	mg.nodes.remove_at(1)
	var macts := R.blueprint_actions(mu, mg).filter(func(a): return String(a.c) == "Macros|BP_TMacros")
	check("its macros are offered in other blueprints", macts.map(func(a): return String(a.l)) == ["Repeat", "Twice"], str(macts.map(func(a): return String(a.l))))
	R.editing_path = ml_path
	check("but not twice while editing the library itself", R.blueprint_actions(ml, ml.graphs[0]).filter(func(a): return String(a.c) == "Macros|BP_TMacros").is_empty())
	R.editing_path = ""
	var m_tw := Model.add_node(mg, "macro", Vector2(300, 80), {"name": "Twice", "lib": ml_path})
	var m_hit := Model.add_node(mg, "var_inc", Vector2(560, 80), {"name": "hits", "by": 1})
	var m_rep := Model.add_node(mg, "macro", Vector2(560, 300), {"name": "Repeat", "lib": ml_path})
	m_rep.d["i_Times"] = "4"
	var m_get := Model.add_node(mg, "var_get", Vector2(700, 520), {"name": "sum"})
	var m_add := Model.add_node(mg, "math", Vector2(860, 480), {"op": "+", "n": 2})
	var m_set := Model.add_node(mg, "var_set", Vector2(1000, 300), {"name": "sum"})
	var m_done := Model.add_node(mg, "var_set", Vector2(1000, 600), {"name": "done"})
	m_done.d["value"] = "true"
	wire(mg, mg.nodes[0], "then", m_tw, "i_In")
	wire(mg, m_tw, "o_Body", m_hit, "exec")
	wire(mg, m_tw, "o_Done", m_rep, "i_In")
	wire(mg, m_rep, "o_Body", m_set, "exec")
	wire(mg, m_get, "value", m_add, "a0")
	wire(mg, m_rep, "o_Index", m_add, "a1")
	wire(mg, m_add, "ret", m_set, "value")
	wire(mg, m_rep, "o_Done", m_done, "exec")
	var md := R.describe(m_rep, mu, mg)
	check("a library macro node shows the macro's pins and where it comes from", md.err == "" and md.sub == "Macro from BP_TMacros" and md.ins.size() == 2 and md.outs.size() == 3, "%s / %s" % [md.sub, md.err])
	var mu_out := build(mu)
	check("a blueprint using library macros compiles", mu_out[1].is_empty(), str(mu_out[1]))
	var run := func(code: String) -> Array:
		var scr := script_from(code)
		if scr == null:
			return [-1, -1, false]
		var n := Node.new()
		n.set_script(scr)
		root.add_child(n)
		await process_frame
		var got := [n.hits, n.sum, n.done]
		n.queue_free()
		return got
	var got: Array = await run.call(mu_out[0])
	check("it runs: Twice ran its body 2 times, Repeat 4 summed 0+1+2+3, Done fired", got == [2, 6, true], str(got))

	# the library changes: Twice now repeats 3 times. Users pick that up when compiled again.
	tw_rep.d["i_Times"] = "3"
	write("BP_TMacros.gd", ml)
	got = await run.call(build(mu)[0])
	check("after the library changes, recompiling the user picks it up", got == [3, 6, true], str(got))

	# a macro that is gone from the library is reported where it is used
	var gone := mu.duplicate(true)
	gone.graphs[0].nodes[1].p["name"] = "Vanished"
	var gone_errs: Array = build(gone)[1]
	check("a missing library macro is an error that names the library", gone_errs.any(func(m): return m.contains("Vanished") and m.contains("BP_TMacros.gd")), str(gone_errs))

	# clean up
	T._globals.erase("BP_TLib")
	var dir := DirAccess.open(DIR)
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	R.invalidate_libraries()
	print("LIBRARY FAILS: ", fails)
	quit(1 if fails else 0)
