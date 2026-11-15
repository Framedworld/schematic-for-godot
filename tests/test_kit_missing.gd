extends SceneTree
## A node whose addon (kit) is missing, or that otherwise can no longer be described, keeps its wires: through
## loading, describing, compiling, the graph view's prune pass, saving, and coming back when the addon does.
## Run: godot --headless --path . --script res://tests/test_kit_missing.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const GraphView := preload("res://addons/schematic/editor/sc_graph_view.gd")

const DIR := "res://tests/tmp/kitmissing_h/"
const TPL_ID := "k3_probe"
const TPL := {"title": "K3 Probe", "cat": "Tests", "tip": "A throwaway template for the missing-kit test.",
	"ins": [["amount", "Amount", "int", "1"]], "outs": [["ret", "Result", "int"]],
	"lines": ["print(\"k3 probe\", {amount})"], "exprs": {"ret": "({amount} * 2)"}}
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([int(a.id), ap, int(b.id), bp_])


func build(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	return [code, c.errors.filter(func(e): return not e.w)]


## The graph view's own prune pass (what runs every time the editor shows a graph), run without the editor UI.
func prune(bp: Dictionary, g: Dictionary) -> void:
	var v = GraphView.new()
	v.bp = bp
	v.graph = g
	v.prune_wires()
	v.free()


func wires_of(g: Dictionary, id: int) -> Array:
	return g.wires.filter(func(w): return int(w[0]) == id or int(w[2]) == id)


func same_wires(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var keys := {}
	for w in a:
		keys[str([int(w[0]), String(w[1]), int(w[2]), String(w[3])])] = true
	for w in b:
		if not keys.has(str([int(w[0]), String(w[1]), int(w[2]), String(w[3])])):
			return false
	return true


func text_has_wires(text: String, wires: Array) -> bool:
	for w in wires:
		if not text.contains(JSON.stringify([int(w[0]), String(w[1]), int(w[2]), String(w[3])], "", true)):
			return false
	return true


func node_of(bp: Dictionary, id: int) -> Dictionary:
	return Model.find_node(bp.graphs[0], id)


## A schematic: _ready -> [node under test] -> Set result, with Get count feeding its data input and its data
## output feeding Set result's value, and a Print after the Set. Returns [bp, node under test].
func scaffold(kind: String, p: Dictionary, exec_in: String, exec_out: String, data_in: String, data_out: String) -> Array:
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "count", "type": "int", "default": "3", "export": false, "category": "", "tooltip": ""})
	bp.variables.append({"name": "result", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	var g: Dictionary = bp.graphs[0]
	var ready: Dictionary = g.nodes[0]
	var get_n := Model.add_node(g, "var_get", Vector2(100, 300), {"name": "count"})
	var n := Model.add_node(g, kind, Vector2(340, 80), p)
	var set_n := Model.add_node(g, "var_set", Vector2(640, 80), {"name": "result"})
	var pr := Model.add_node(g, "print", Vector2(900, 80), {})
	wire(g, ready, "then", n, exec_in)
	wire(g, get_n, "value", n, data_in)
	wire(g, n, exec_out, set_n, "exec")
	wire(g, n, data_out, set_n, "value")
	wire(g, set_n, "then", pr, "exec")
	return [bp, n]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()

	# ================================================================ a template node whose addon goes away
	R.register_template(TPL_ID, TPL.duplicate(true))
	var made := scaffold("tpl", {"id": TPL_ID}, "exec", "then", "amount", "ret")
	var bp: Dictionary = made[0]
	var pid := int(made[1].id)
	var good := build(bp)
	var good_code: String = good[0]
	check("with the template registered the schematic compiles", good[1].is_empty(), str(good[1]))
	check("... and the template's code is in it", good_code.contains("print(\"k3 probe\", count)"), good_code)
	var all_wires: Array = bp.graphs[0].wires.duplicate(true)
	var probe_wires := wires_of(bp.graphs[0], pid)
	check("the template node has 4 wires (exec in/out, data in/out)", probe_wires.size() == 4, str(probe_wires))
	var text := Model.build_source(good_code, bp)
	var path := DIR + "probe.gd"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

	# the addon is switched off
	R.templates.erase(TPL_ID)
	var loaded := Model.load_file(path)
	var lg: Dictionary = loaded.graphs[0]
	check("step 1: loading the file keeps every wire (Model.load_file / parse_source / normalize)", same_wires(lg.wires, all_wires), str(lg.wires))
	var d := R.describe(node_of(loaded, pid), loaded, lg)
	check("step 1: describing the node reports it missing", String(d.err) != "", String(d.err))
	check("step 1: describing does not change the wires", same_wires(lg.wires, all_wires))
	var missing_build := build(loaded)
	check("step 1: compiling does not change the wires", same_wires(lg.wires, all_wires))
	prune(loaded, lg)
	check("step 1/2: the graph view's prune pass keeps the wires of the node it cannot describe", same_wires(lg.wires, all_wires), "%d of %d wires left" % [lg.wires.size(), all_wires.size()])

	# what the placeholder looks like to the rest of the editor
	d = R.describe(node_of(loaded, pid), loaded, lg)
	var in_ids: Array = d.ins.map(func(x): return String(x.id))
	var out_ids: Array = d.outs.map(func(x): return String(x.id))
	check("step 3: the placeholder has a pin for every wire, named by the stored pin id", in_ids == ["exec", "amount"] and out_ids == ["then", "ret"], "%s %s" % [in_ids, out_ids])
	var types := {}
	for x in d.ins + d.outs:
		types[String(x.id)] = String(x.type)
	check("step 3: each pin takes its type from the other end of its wire", types == {"exec": "exec", "amount": "int", "then": "exec", "ret": "int"}, str(types))
	check("step 3: the pins are marked as accepting no new connections", (d.ins + d.outs).all(func(x): return bool(x.get("orphan", false))))
	check("step 3: the title says what it was and that it is missing", String(d.title).contains(TPL_ID) and String(d.title).to_lower().contains("missing"), String(d.title))
	check("step 3: a stored title is used when the node has one", String(R.describe({"id": 99, "kind": "tpl", "p": {"id": "zz", "title": "Run Dialogue"}, "d": {}}, loaded, {}).title).contains("Run Dialogue"))

	# compiling reports one clear error, on that node
	var errs: Array = missing_build[1]
	check("step 4: compiling reports exactly one error", errs.size() == 1, str(errs.map(func(e): return e.m)))
	check("step 4: the error is on the missing node and names the template", errs.size() >= 1 and int(errs[0].n) == pid and String(errs[0].m).contains(TPL_ID) and String(errs[0].m).contains("not installed or enabled"), str(errs))

	# editing elsewhere, saving (the editor keeps the last good code when there are errors), reopening
	var pr_node: Dictionary = lg.nodes.filter(func(n): return n.kind == "print")[0]
	pr_node.x = float(pr_node.x) + 120.0
	Model.add_node(lg, "print", Vector2(900, 400), {})
	prune(loaded, lg)
	check("step 2: moving another node and adding one keeps the wires", same_wires(lg.wires, all_wires))
	var undo_snap: Dictionary = loaded.duplicate(true)
	Model.remove_node(lg, int(lg.nodes[-1].id))
	loaded = undo_snap.duplicate(true)   # what the editor's undo does: the snapshot comes back
	lg = loaded.graphs[0]
	prune(loaded, lg)
	check("step 2: undo (snapshot restore) keeps the wires", same_wires(lg.wires, all_wires))
	var saved := Model.build_source(good_code, loaded)
	check("step 4: the saved graph data still holds every wire", text_has_wires(saved, all_wires))
	check("step 4: the saved file keeps the last good code", saved.begins_with(good_code.strip_edges(false, true)))
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(saved)
	f.close()
	var again := Model.load_file(path)
	prune(again, again.graphs[0])
	check("step 2: close and reopen keeps the wires", same_wires(again.graphs[0].wires, all_wires))

	# the addon comes back
	R.register_template(TPL_ID, TPL.duplicate(true))
	var back := Model.load_file(path)
	prune(back, back.graphs[0])
	check("step 5: with the template back, every wire is there", same_wires(back.graphs[0].wires, all_wires))
	var bd := R.describe(node_of(back, pid), back, back.graphs[0])
	check("step 5: the node is a normal node again", String(bd.err) == "" and String(bd.title) == "K3 Probe" and not (bd.ins + bd.outs).any(func(x): return x.get("orphan", false)), "%s %s" % [bd.title, bd.err])
	var back_build := build(back)
	check("step 5: it compiles without errors", back_build[1].is_empty(), str(back_build[1]))
	check("step 5: it compiles to exactly the code it compiled to before", String(back_build[0]) == good_code)
	R.templates.erase(TPL_ID)

	# two missing nodes wired to each other: the types fall back to wildcards, nothing loops
	var two := scaffold("tpl", {"id": "k3_gone_a"}, "exec", "then", "amount", "ret")
	var tg: Dictionary = two[0].graphs[0]
	var other := Model.add_node(tg, "tpl", Vector2(340, 400), {"id": "k3_gone_b"})
	wire(tg, two[1], "ret", other, "x")
	var two_wires: Array = tg.wires.duplicate(true)
	prune(two[0], tg)
	check("two missing nodes wired together keep their wire", same_wires(tg.wires, two_wires))
	var od := R.describe(other, two[0], tg)
	check("... and the pin between them is a wildcard", od.ins.size() == 1 and String(od.ins[0].type) == "any", str(od.ins))

	# ================================================================ step 6: other ways to lose a description
	# (a) a node kind this version does not know (a file saved by a newer version of the plugin)
	var fut := scaffold("k3_future_kind", {}, "exec", "then", "in_value", "out_value")
	var fg: Dictionary = fut[0].graphs[0]
	var fw: Array = fg.wires.duplicate(true)
	var ftext := Model.build_source("", fut[0])
	var fl := Model.parse_source(Model.MARKER + "\n" + ftext)
	prune(fl, fl.graphs[0])
	check("step 6a: an unknown node kind keeps its wires", same_wires(fl.graphs[0].wires, fw), "%d of %d" % [fl.graphs[0].wires.size(), fw.size()])
	var ferrs: Array = build(fl)[1]
	check("step 6a: ... and compiling names the unknown kind", ferrs.any(func(e): return String(e.m).contains("k3_future_kind")), str(ferrs.map(func(e): return e.m)))

	# (b) a macro from a macro library whose file is gone
	var lib := Model.new_schematic("RefCounted", "")
	lib["library"] = "macro"
	var mg := Model.new_graph(lib, "PassOn", "macro")
	mg.inputs = [["In", "exec"], ["x", "int"]]
	mg.outputs = [["Out", "exec"], ["y", "int"]]
	wire(mg, mg.nodes[0], "i_In", mg.nodes[1], "o_Out")
	wire(mg, mg.nodes[0], "i_x", mg.nodes[1], "o_y")
	var lib_path := DIR + "k3_macros.gd"
	var lib_text := Model.build_source(String(build(lib)[0]), lib)
	f = FileAccess.open(lib_path, FileAccess.WRITE)
	f.store_string(lib_text)
	f.close()
	R.invalidate_libraries()
	var mac := scaffold("macro", {"name": "PassOn", "lib": lib_path}, "i_In", "o_Out", "i_x", "o_y")
	var mac_good := build(mac[0])
	check("step 6b: a library macro use compiles while the library is there", mac_good[1].is_empty(), str(mac_good[1]))
	var mw: Array = mac[0].graphs[0].wires.duplicate(true)
	var mtext := Model.build_source(String(mac_good[0]), mac[0])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lib_path))
	R.invalidate_libraries()
	var ml := Model.parse_source(mtext)
	prune(ml, ml.graphs[0])
	check("step 6b: with the library file gone the macro node keeps its wires", same_wires(ml.graphs[0].wires, mw), "%d of %d" % [ml.graphs[0].wires.size(), mw.size()])
	var merrs: Array = build(ml)[1]
	check("step 6b: ... and compiling names the library", merrs.size() == 1 and String(merrs[0].m).contains("k3_macros.gd"), str(merrs.map(func(e): return e.m)))
	f = FileAccess.open(lib_path, FileAccess.WRITE)
	f.store_string(lib_text)
	f.close()
	R.invalidate_libraries()
	var ml2 := Model.parse_source(Model.build_source(String(mac_good[0]), ml))
	prune(ml2, ml2.graphs[0])
	check("step 6b: with the library back it compiles to the same code", same_wires(ml2.graphs[0].wires, mw) and String(build(ml2)[0]) == String(mac_good[0]))

	# (c) a call on a class that no longer exists (a class_name script deleted or renamed)
	var gone := scaffold("call", {"cls": "SC_K3GoneClass", "method": "zap"}, "exec", "then", "a0", "ret")
	var gw: Array = gone[0].graphs[0].wires.duplicate(true)
	var gl := Model.parse_source(Model.build_source("", gone[0]).insert(0, Model.MARKER + "\n"))
	prune(gl, gl.graphs[0])
	check("step 6c: a call on a class that no longer exists keeps all its wires", same_wires(gl.graphs[0].wires, gw), "%d of %d" % [gl.graphs[0].wires.size(), gw.size()])
	var gerrs: Array = build(gl)[1]
	check("step 6c: ... and compiling names the class", gerrs.any(func(e): return String(e.m).contains("SC_K3GoneClass")), str(gerrs.map(func(e): return e.m)))
	# a call on a class that exists, to a method it does not have, keeps its wires the same way
	var nometh := scaffold("call", {"cls": "Node", "method": "k3_no_such_method"}, "exec", "then", "a0", "ret")
	var nw: Array = nometh[0].graphs[0].wires.duplicate(true)
	prune(nometh[0], nometh[0].graphs[0])
	check("step 6c: a call to a method the class does not have keeps its wires", same_wires(nometh[0].graphs[0].wires, nw))

	# (d) a variable getter whose variable was deleted: it keeps its pin, so its wires were never at risk
	R.register_template(TPL_ID, TPL.duplicate(true))
	var vg := scaffold("tpl", {"id": TPL_ID}, "exec", "then", "amount", "ret")
	vg[0].variables = vg[0].variables.filter(func(v): return v.name != "count")
	var vw: Array = vg[0].graphs[0].wires.duplicate(true)
	prune(vg[0], vg[0].graphs[0])
	check("step 6d: a getter of a deleted variable keeps its wire", same_wires(vg[0].graphs[0].wires, vw))
	var verrs: Array = build(vg[0])[1]
	check("step 6d: ... and compiling says the variable no longer exists", verrs.any(func(e): return String(e.m).contains("Variable 'count' no longer exists")), str(verrs.map(func(e): return e.m)))
	R.templates.erase(TPL_ID)

	# (e) things of this same file that the user removes in this session: pruning is what happens, as before
	var own := scaffold("macro", {"name": "Mine"}, "i_In", "o_Out", "i_x", "o_y")
	var own_g: Dictionary = own[0].graphs[0]
	prune(own[0], own_g)
	check("step 6e: a use of a macro this schematic no longer has loses its pin wires (removed in this session, as before)", wires_of(own_g, int(own[1].id)).is_empty(), str(own_g.wires))
	var cs := scaffold("call_self", {"fn": "deleted_fn"}, "exec", "then", "a_x", "r_y")
	var cs_g: Dictionary = cs[0].graphs[0]
	prune(cs[0], cs_g)
	check("step 6e: a call of a function this schematic no longer has keeps only its exec wires (as before)", wires_of(cs_g, int(cs[1].id)).size() == 2, str(wires_of(cs_g, int(cs[1].id))))

	# clean up
	var dir := DirAccess.open(DIR)
	if dir:
		for fn in dir.get_files():
			dir.remove(fn)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	R.invalidate_libraries()
	print("KIT MISSING FAILS: ", fails)
	quit(1 if fails else 0)
