extends RefCounted
## Editor self-test for a node whose addon (kit) is missing: the node opens as a placeholder that keeps every
## wire (in the model and on screen), the results panel names the problem, editing elsewhere, undo, redo, save,
## close and reopen keep the wires, the graph data on disk keeps them, and once the template is registered again
## the script compiles to exactly the code it had before.
## It writes its scratch schematic under res://tests/tmp/kitmissing/ (git-ignored) and registers a throwaway
## template, so no addon is needed.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_kit_missing.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

const LOG := "res://tests/out/shot_kit_missing_checks.log"
const SHOT := "res://tests/out/shot_kit_missing.png"
const DIR := "res://tests/tmp/kitmissing"
const PATH := DIR + "/SC_KitMissing.gd"
const TPL_ID := "k3_shot_probe"
const TPL := {"title": "K3 Probe", "cat": "Tests", "tip": "A throwaway template for the missing-kit self-test.",
	"ins": [["amount", "Amount", "int", "1"]], "outs": [["ret", "Result", "int"]],
	"lines": ["print(\"k3 probe\", {amount})"], "exprs": {"ret": "({amount} * 2)"}}

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0
var pid := 0         # the template node
var id_print := 0    # a node elsewhere, to move
var id_set := 0
var all_wires: Array = []
var good_code := ""


func note(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE if FileAccess.file_exists(LOG) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(ok: bool, what: String, detail := "") -> void:
	if not ok:
		fails += 1
	note("%s  %s%s" % ["PASS" if ok else "FAIL", what, ("  [" + detail + "]") if detail != "" and not ok else ""])


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func history() -> UndoRedo:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(ed))


func key(w: Array) -> String:
	return str([int(w[0]), String(w[1]), int(w[2]), String(w[3])])


func model_wires() -> Array:
	return ed.doc.bp.graphs[0].wires


func has_all_wires(wires: Array) -> bool:
	var have := {}
	for w in wires:
		have[key(w)] = true
	for w in all_wires:
		if not have.has(key(w)):
			return false
	return wires.size() == all_wires.size()


## The connections the canvas draws that touch the template node.
func drawn_probe_wires() -> int:
	var count := 0
	for c in ed._view.get_connection_list():
		if String(c.from_node) == "n%d" % pid or String(c.to_node) == "n%d" % pid:
			count += 1
	return count


func panel_text() -> String:
	var lines := []
	for i in ed._results.item_count:
		lines.append(ed._results.get_item_text(i))
	return " | ".join(lines)


func gnode(id: int):
	return ed._view.get_node_or_null("n%d" % id)


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func close_doc() -> void:
	for i in range(ed.docs.size() - 1, -1, -1):
		if ed.docs[i].path == PATH:
			ed._close_doc(i)


func open_doc() -> bool:
	var ok: bool = ed.open_schematic(PATH)
	EditorInterface.set_main_screen_editor("Schematic")
	await frames(6)
	return ok


func fit_view() -> void:
	var g: Dictionary = ed.cur_graph()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		lo = Vector2(minf(lo.x, float(n.x)), minf(lo.y, float(n.y)))
		hi = Vector2(maxf(hi.x, float(n.x) + 260.0), maxf(hi.y, float(n.y) + 200.0))
	var view = ed._view
	var z := minf(1.0, minf((view.size.x - 60.0) / (hi.x - lo.x), (view.size.y - 60.0) / (hi.y - lo.y)))
	view.zoom = maxf(z, 0.5)
	view.scroll_offset = lo * view.zoom - Vector2(30, 30)


func cleanup() -> void:
	R.templates.erase(TPL_ID)
	if ed != null:
		for i in range(ed.docs.size() - 1, -1, -1):
			if String(ed.docs[i].path).begins_with(DIR):
				ed.docs[i].dirty = false
				ed._close_doc(i)
	var dir := DirAccess.open(DIR)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	EditorInterface.get_resource_filesystem().scan()


func build() -> Dictionary:
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "count", "type": "int", "default": "3", "export": false, "category": "", "tooltip": ""})
	bp.variables.append({"name": "result", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	var g: Dictionary = bp.graphs[0]
	var ready: Dictionary = g.nodes[0]
	ready.x = 60.0
	ready.y = 80.0
	g.nodes[1].x = 60.0     # _process, out of the way
	g.nodes[1].y = 420.0
	var get_n := Model.add_node(g, "var_get", Vector2(120, 260), {"name": "count"})
	var n := Model.add_node(g, "tpl", Vector2(380, 80), {"id": TPL_ID})
	var set_n := Model.add_node(g, "var_set", Vector2(720, 80), {"name": "result"})
	var pr := Model.add_node(g, "print", Vector2(1000, 80), {})
	pid = int(n.id)
	id_set = int(set_n.id)
	id_print = int(pr.id)
	g.wires.append([int(ready.id), "then", pid, "exec"])
	g.wires.append([int(get_n.id), "value", pid, "amount"])
	g.wires.append([pid, "then", id_set, "exec"])
	g.wires.append([pid, "ret", id_set, "value"])
	g.wires.append([id_set, "then", id_print, "exec"])
	return bp


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(150.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout

	# --- the schematic, written while the template is registered
	R.register_template(TPL_ID, TPL.duplicate(true))
	var bp := build()
	all_wires = bp.graphs[0].wires.duplicate(true)
	var c := Compiler.new()
	good_code = c.compile(bp)
	check(c.errors.filter(func(e): return not e.w).is_empty(), "the schematic compiles while the template is registered", str(c.errors))
	write_file(PATH, Model.build_source(good_code, bp))
	EditorInterface.get_resource_filesystem().update_file(PATH)
	await frames(3)

	# --- the addon goes away; the file is opened in the editor
	R.templates.erase(TPL_ID)
	check(await open_doc(), "the schematic opens in the editor with the template missing")
	await frames(4)
	check(has_all_wires(model_wires()), "on open every wire is still in the model (%d)" % all_wires.size(), str(model_wires()))
	check(drawn_probe_wires() == 4, "all 4 wires of the missing node are drawn on the canvas (drawn: %d)" % drawn_probe_wires())
	var gn = gnode(pid)
	check(gn != null, "the missing node is on the canvas")
	if gn != null:
		var labels := []
		for lab in gn.find_children("*", "Label", true, false):
			labels.append(String(lab.text))
		note("    placeholder title: [%s]; labels: %s" % [gn.title, labels])
		check(String(gn.title).contains(TPL_ID) and String(gn.title).contains("missing"), "the placeholder's title names the template and says it is missing", gn.title)
		check(labels.any(func(s): return s.contains("ERROR!") and s.contains("not installed or enabled")), "the placeholder shows the error in the node's error style", str(labels))
		check(gn.in_pins.map(func(x): return String(x.id)) == ["exec", "amount"] and gn.out_pins.map(func(x): return String(x.id)) == ["then", "ret"],
			"the placeholder has a pin per wire, named by the stored pin id", "%s %s" % [gn.in_pins, gn.out_pins])
		check(gn.in_pins.all(func(x): return x.get("orphan", false)) and String(gn.in_pins[1].type) == "int" and String(gn.out_pins[0].type) == "exec",
			"its pins are typed from the other end and marked as taking no new connections", str(gn.in_pins))
		# a new connection onto a placeholder pin is refused
		var other = gnode(id_print)
		check(not ed._view._is_node_hover_valid(StringName("n%d" % id_set), 0, StringName("n%d" % pid), 0), "a new wire onto the placeholder's exec pin is refused")
		check(other != null, "the other nodes are there")
	var pt := panel_text()
	note("    results panel: %s" % pt)
	check(pt.contains("not installed or enabled") and pt.contains(TPL_ID), "the results panel names the problem", pt)
	check(not ed.doc.dirty, "opening does not mark the document as changed")

	# --- the picture, from the editor's own viewport
	fit_view()
	await frames(4)
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(SHOT)
	note("saved %s" % SHOT)

	# --- move another node
	var el = gnode(id_print)
	if el != null:
		el.position_offset = el.position_offset + Vector2(60, 40)
	ed._view._on_end_node_move()
	await frames(3)
	check(float(Model.find_node(ed.cur_graph(), id_print).x) == 1060.0, "moving another node changed its position in the model")
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "after moving another node every wire is kept and drawn")

	# --- add a node elsewhere
	var count_before: int = ed.cur_graph().nodes.size()
	ed._view.spawn("print", {}, Vector2(1000, 400))
	await frames(3)
	check(ed.cur_graph().nodes.size() == count_before + 1, "a node was added elsewhere")
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "after adding a node every wire is kept and drawn")

	# --- undo, redo
	history().undo()
	await frames(3)
	check(ed.cur_graph().nodes.size() == count_before, "undo removes the added node")
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "after undo every wire is kept and drawn")
	history().redo()
	await frames(3)
	check(ed.cur_graph().nodes.size() == count_before + 1, "redo adds it again")
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "after redo every wire is kept and drawn")

	# --- one of its wires deleted on purpose, then undone
	var view = ed._view
	var a = gnode(pid)
	var b = gnode(id_set)
	if a != null and b != null:
		view._on_disconnection_request(StringName(a.name), view._port_of(a.out_pins, "ret"), StringName(b.name), view._port_of(b.in_pins, "value"))
		await frames(3)
		check(model_wires().size() == all_wires.size() - 1 and drawn_probe_wires() == 3, "a wire of the placeholder can be deleted on purpose (%d left on it)" % drawn_probe_wires())
		history().undo()
		await frames(3)
		check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "undo brings that wire back")

	# --- compile and save while the node is missing
	var ok: bool = ed.compile_doc(ed.doc, false)
	check(not ok, "compiling reports an error while the node is missing")
	var errs: Array = ed.doc.errors.filter(func(e): return not e.w)
	check(errs.size() == 1 and int(errs[0].n) == pid, "exactly one error, on the missing node", str(errs))
	ed.compile_doc(ed.doc, true)
	await frames(3)
	var disk := FileAccess.get_file_as_string(PATH)
	var disk_code := disk.substr(0, Model.graph_block_at(disk))
	var all_on_disk := true
	for w in all_wires:
		if not disk.contains(JSON.stringify([int(w[0]), String(w[1]), int(w[2]), String(w[3])], "", true)):
			all_on_disk = false
	check(all_on_disk, "the graph data on disk holds every wire after saving")
	check(Model.load_file(PATH).graphs[0].nodes.size() == count_before + 1, "the graph data on disk holds the edits (the added node)")
	check(disk_code.strip_edges(false, true) == good_code.strip_edges(false, true), "the code on disk is still the last good code (a document with errors keeps it)")
	check(not ed.doc.dirty, "saving cleared the unsaved mark")

	# --- close and reopen, still missing
	close_doc()
	await frames(3)
	check(ed._find_doc(PATH).is_empty(), "the document is closed")
	check(await open_doc(), "it reopens")
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "after close and reopen every wire is kept and drawn")
	# a breakpoint toggle saves a changed document too
	var el2 = gnode(id_print)
	if el2 != null:
		el2.position_offset = el2.position_offset + Vector2(0, 30)
	ed._view._on_end_node_move()
	await frames(3)
	check(ed.doc.dirty, "moving a node marked the reopened document as changed")
	ed.toggle_breakpoints([id_print])
	await frames(3)
	check(not ed.doc.dirty, "toggling a breakpoint saved it")
	await frames(3)
	ed.toggle_breakpoints([id_print])
	await frames(3)
	check(has_all_wires(Model.load_file(PATH).graphs[0].wires), "toggling a breakpoint (which saves) keeps every wire on disk")

	# --- the addon comes back
	close_doc()
	await frames(3)
	R.register_template(TPL_ID, TPL.duplicate(true))
	check(await open_doc(), "with the template registered again the schematic reopens")
	var gn2 = gnode(pid)
	check(gn2 != null and String(gn2.title) == "K3 Probe", "the node is a normal node again", str(gn2.title if gn2 != null else "-"))
	check(has_all_wires(model_wires()) and drawn_probe_wires() == 4, "with the template back every wire is there and drawn")
	check(String(ed.doc.preview) == good_code, "the code equals the code it compiled to before the template went missing")
	check(ed.compile_doc(ed.doc, false), "it compiles without errors")

	cleanup()
	await tree.create_timer(1.0).timeout
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
