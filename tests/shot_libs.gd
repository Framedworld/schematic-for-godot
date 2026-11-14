extends RefCounted
## Editor self-test: function and macro libraries end to end, with real class registration.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_libs.gd
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const DIR := "res://demo/tmp_libs"

var passed := 0
var failed := 0
var tree: SceneTree
var ed


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_libs.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	note("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	print("STEP after: ", label)


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func create(parent: String, starter: String, file: String) -> String:
	ed._new_blueprint_file(parent, null, starter)
	await frames(6)
	var path := "%s/%s.gd" % [DIR, file]
	for c in EditorInterface.get_base_control().get_children():
		if c is EditorFileDialog and c.visible:
			c.file_selected.emit(path)
			c.hide()
	await frames(10)
	return path


func search(query: String) -> TreeItem:
	ed._palette._search.text = query
	ed._palette._fill()
	return ed._palette.first_leaf()


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func cleanup() -> void:
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


func run(p: EditorPlugin) -> void:
	tree = p.get_tree()
	ed = p.editor
	note("--- start")
	tree.create_timer(100.0).timeout.connect(func():
		note("watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Blueprint")
	await tree.create_timer(0.6).timeout
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))

	# 1. a function library from the starter
	var lib_path := await create("RefCounted", "function_library", "BP_LibMath")
	check("Function Library starter opens with no errors", ed.doc.path == lib_path and ed.doc.errors.is_empty() and ed.doc.bp.get("library", "") == "function", str(ed.doc.errors))
	var type_box: OptionButton = null
	for ob in ed._details.find_children("*", "OptionButton", true, false):
		if ob.item_count == 4 and ob.get_item_text(1) == "Function Library":
			type_box = ob
	check("Class Settings shows Blueprint Type: Function Library", type_box != null and type_box.selected == 1)
	check("generated code is static", FileAccess.get_file_as_string(lib_path).contains("static func percent(value: float, maximum: float) -> float:"))
	# switching the type back and forth through the dropdown
	if type_box:
		type_box.item_selected.emit(0)
		await frames(4)
		check("Blueprint Type dropdown turns it back into a class", not ed.doc.bp.has("library") and not String(ed.doc.preview).contains("static func"))
		ed.undo() if ed.has_method("undo") else p.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY).undo()
		await frames(4)
		check("undo makes it a library again", ed.doc.bp.get("library", "") == "function", str(ed.doc.bp.get("library", "")))
		ed.compile_doc(ed.doc, true)

	# 2. a macro library from the starter
	var mac_path := await create("RefCounted", "macro_library", "BP_LibMacros")
	check("Macro Library starter opens with no errors", ed.doc.path == mac_path and ed.doc.errors.is_empty() and ed.doc.bp.get("library", "") == "macro", str(ed.doc.errors))

	# wait for Godot to register the new class
	EditorInterface.get_resource_filesystem().scan()
	var waited := 0.0
	while waited < 15.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		T.refresh_globals()
		if T.globals().has("BP_LibMath") and not EditorInterface.get_resource_filesystem().is_scanning():
			break
	check("the library's class is registered", T.globals().has("BP_LibMath"), "after %.1fs" % waited)

	# 3. another blueprint finds and uses both
	var user_path := await create("Node", "", "BP_LibUser")
	ed._view._open_palette(Vector2(400, 200), {})
	await tree.create_timer(0.4).timeout
	var hit := search("percent")
	var found_fn := false
	var it := hit
	while it:
		if it.get_text(0) == "Percent" and it.get_parent().get_text(0).contains("BP_LibMath"):
			found_fn = true
		it = it.get_next_in_tree()
	check("'percent' offers the library function under Function Libraries", found_fn, hit.get_text(0) if hit else "none")
	hit = search("repeat")
	var found_macro := false
	it = hit
	while it:
		if it.get_text(0) == "Repeat" and it.get_parent().get_text(0).contains("BP_LibMacros"):
			found_macro = true
		it = it.get_next_in_tree()
	check("'repeat' offers the library macro", found_macro, hit.get_text(0) if hit else "none")
	ed._palette._search.text = "BP_Lib"
	ed._palette._fill()
	await tree.create_timer(0.3).timeout
	ed._palette.get_texture().get_image().save_png("res://tests/out/look_17_library_menu.png")
	ed._palette.hide()

	var ids := {}
	ed.mutate("Use libraries", func():
		var bp: Dictionary = ed.doc.bp
		bp.variables.append({"name": "hits", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
		var g: Dictionary = bp.graphs[0]
		var ready: Dictionary = g.nodes[0]
		var rep := Model.add_node(g, "macro", Vector2(340, 80), {"name": "Repeat", "lib": mac_path})
		rep.d["i_Times"] = "3"
		var inc := Model.add_node(g, "var_inc", Vector2(640, 80), {"name": "hits", "by": 1})
		var pct := Model.add_node(g, "call", Vector2(340, 330), {"cls": "BP_LibMath", "method": "percent"})
		pct.d["a1"] = "3.0"
		var fmt := Model.add_node(g, "format", Vector2(620, 330), {"text": "{p} percent"})
		var pr := Model.add_node(g, "print", Vector2(900, 200), {})
		wire(g, ready, "then", rep, "i_In")
		wire(g, rep, "o_Body", inc, "exec")
		wire(g, rep, "o_Done", pr, "exec")
		wire(g, inc, "value", pct, "a0")
		wire(g, pct, "ret", fmt, "f_p")
		wire(g, fmt, "ret", pr, "text")
		ids["rep"] = int(rep.id)
		ids["pct"] = int(pct.id))
	await frames(6)
	var ok: bool = ed.compile_doc(ed.doc, true)
	var user_code := FileAccess.get_file_as_string(user_path)
	check("a blueprint using both libraries compiles (checked by GDScript with the real class)", ok and ed.doc.errors.is_empty() and user_code.contains("BP_LibMath.percent(") and user_code.contains("for "), str(ed.doc.errors))
	var pct_node: GraphNode = ed._view.get_node_or_null("n%d" % ids.pct)
	var rep_node: GraphNode = ed._view.get_node_or_null("n%d" % ids.rep)
	check("library nodes are drawn", pct_node != null and rep_node != null and rep_node.title == "Repeat")
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/look_18_library_user.png")

	# (Running it is covered by tests/test_libraries.gd: scripts do not execute inside the editor.)

	# 4. double-click on the library macro opens the library at that macro
	ed._view.node_double_clicked(ids.rep)
	await frames(6)
	check("double-click on a library macro opens the library", ed.doc.path == mac_path and ed.cur_graph().name == "Repeat", "%s / %s" % [ed.doc.path, ed.cur_graph().name])

	# 5. change the library and save: the open user is recompiled
	var change := func(lit: String) -> void:
		ed.mutate("Change macro", func():
			for n in ed.cur_graph().nodes:
				if n.kind == "math":
					n.d["a1"] = lit)
	change.call("0")
	ed.compile_doc(ed.doc, true)
	await frames(6)
	check("saving the macro library recompiles an open blueprint that uses it", FileAccess.get_file_as_string(user_path) != user_code and FileAccess.get_file_as_string(user_path).contains("- 0"))
	# ...and a closed one
	var ui: int = ed.docs.find(ed._find_doc(user_path))
	ed._close_doc(ui)
	await frames(4)
	ed.open_blueprint(mac_path)
	ed.open_member_graph("Repeat")
	change.call("2")   # ("1" would compile to range(Times), with nothing to look for)
	ed.compile_doc(ed.doc, true)
	await frames(6)
	var closed_code := FileAccess.get_file_as_string(user_path)
	check("and a closed one", closed_code.contains("- 2") and not closed_code.contains("- 0") and not Model.load_file(user_path).is_empty())

	# 6. Expand Node works on a library macro
	ed.open_blueprint(user_path)
	await frames(6)
	var before: int = ed.cur_graph().nodes.size()
	ed._view.expand_macro(ids.rep)
	await frames(6)
	var ok2: bool = ed.compile_doc(ed.doc, false)
	# the macro node is replaced by the macro's two nodes and its comment box
	check("Expand Node copies a library macro into the graph", ed.cur_graph().nodes.size() == before + 2 and ok2 and not ed.cur_graph().nodes.any(func(n): return n.kind == "macro"), "%d -> %d nodes, errors %s" % [before, ed.cur_graph().nodes.size(), str(ed.doc.errors)])

	cleanup()
	await tree.create_timer(1.0).timeout
	note("passed %d, failed %d" % [passed, failed])
	tree.quit()
