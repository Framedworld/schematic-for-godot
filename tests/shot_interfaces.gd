extends RefCounted
## Editor self-test for Blueprint Interfaces: Class Settings > Interfaces, the functions it adds, and the
## Message nodes in the action menu. Uses the interface test_interfaces.gd writes, so run that first.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_interfaces.gd

const Model := preload("res://addons/blueprints/core/bp_model.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const LOG := "res://tests/out/selftest_interfaces.log"
const DIR := "res://tests/tmp/iface/"

var tree: SceneTree
var fails := 0


func note(msg: String) -> void:
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE if FileAccess.file_exists(LOG) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	note("%s  %s" % ["PASS" if ok else "FAIL", what])


func shot(name: String) -> void:
	EditorInterface.get_base_control().queue_redraw()
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/%s.png" % name)
	note("saved " + name)


func run(p: EditorPlugin) -> void:
	tree = p.get_tree()
	var ed = p.editor
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(60.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	# a plain blueprint to implement the interface in
	var path := DIR + "BP_TShelf.gd"
	var bp := Model.new_blueprint("Node", "")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Model.build_source("# @blueprint v1\nextends Node\n", bp))
	f.close()
	R.invalidate_libraries()
	T.refresh_globals()
	check(R.interfaces().has("BPI_Test"), "the editor knows the interface BPI_Test: %s" % [R.interfaces()])
	check(ed.open_blueprint(path), "opened the blueprint")
	EditorInterface.set_main_screen_editor("Blueprint")
	await tree.create_timer(0.6).timeout
	ed._select({"kind": "class"})
	await shot("16_interfaces_before")
	ed.implement_interface("BPI_Test")
	await tree.create_timer(0.4).timeout
	var names := []
	for g in ed.doc.bp.graphs:
		names.append(String(g.name))
	check(ed.doc.bp.get("interfaces", []) == ["BPI_Test"], "Class Settings lists the interface")
	check(names.has("interact") and names.has("get_prompt") and names.has("stats"), "its three functions were added: %s" % [names])
	var gp: Dictionary = Model.graph_named(ed.doc.bp, "get_prompt")
	check(gp.outputs == [["prompt", "String"]], "with the interface's outputs: %s" % [gp.get("outputs", [])])
	check(ed.compile_doc(ed.doc, true), "the blueprint compiles and saves: %s" % [ed.doc.errors])
	check(FileAccess.get_file_as_string(path).contains("func interact(instigator: Node) -> void:"), "the saved script has interact(instigator: Node)")
	ed._select({"kind": "class"})
	await shot("17_interfaces_added")
	# a Message node placed in the event graph
	ed.doc.graph_id = int(ed.doc.bp.graphs[0].id)
	ed.mutate("Add Message", func():
		var g: Dictionary = ed.cur_graph()
		var m := Model.add_node(g, "iface_call", Vector2(420, 260), {"iface": "BPI_Test", "fn": "get_prompt"})
		var h := Model.add_node(g, "iface_has", Vector2(420, 420), {"iface": "BPI_Test"})
		var ready := {}
		for n in g.nodes:
			if n.kind == "event" and String(n.p.name) == "_ready":
				ready = n
		if not ready.is_empty():
			g.wires.append([int(ready.id), "then", int(m.id), "exec"]))
	ed._refresh_graph_tabs()
	ed._refresh_graph()
	check(ed.compile_doc(ed.doc, true), "with a Message node it still compiles: %s" % [ed.doc.errors])
	await shot("18_interface_message_nodes")
	# changing the interface's type shows in the implementer as an error
	gp.outputs = [["prompt", "int"]]
	check(not ed.compile_doc(ed.doc, false), "a function changed away from the interface is reported: %s" % [ed.doc.errors.map(func(e): return e.m)])
	gp.outputs = [["prompt", "String"]]
	ed.doc.dirty = false
	note("done: %d failed" % fails)
	tree.quit()
