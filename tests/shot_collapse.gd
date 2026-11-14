extends RefCounted
## Editor self-test for Collapse to Macro: collapsing nodes must not change the generated code.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_collapse.gd

var plugin: EditorPlugin


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_collapse.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func body(code: String) -> String:
	# Compare everything except member names that embed node ids.
	var out := PackedStringArray()
	for line in code.split("\n"):
		if line.strip_edges() != "":
			out.append(line)
	return "\n".join(out)


func select(ed, ids: Array) -> void:
	for c in ed._view.get_children():
		if c is GraphElement:
			c.selected = ids.has(int(String(c.name).trim_prefix("n")))


func run(p: EditorPlugin) -> void:
	plugin = p
	var tree := p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	var ed = p.editor
	tree.create_timer(40.0).timeout.connect(func():
		note("watchdog quit")
		if not ed.doc.is_empty():
			ed.doc.dirty = false
		tree.quit())
	await tree.create_timer(2.5).timeout
	note("open: %s" % ed.open_schematic("res://demo/SC_Demo.gd"))
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	ed.compile_doc(ed.doc, false)
	var before: String = body(ed.doc.preview)
	var g: Dictionary = ed.cur_graph()
	# 1) an exec-only node: the first Print String after Event Ready
	var print_id := -1
	var math_ids := []
	for n in g.nodes:
		if n.kind == "print" and print_id == -1:
			print_id = int(n.id)
		if n.kind == "util" and n.p.name == "deg_to_rad":
			math_ids.append(int(n.id))
		if n.kind == "op" and n.p.op == "*" and n.p.l == "float" and not n.d.has("b"):
			math_ids.append(int(n.id))
	select(ed, [print_id])
	ed._view.collapse_selection()
	await tree.create_timer(0.4).timeout
	note("after collapsing Print: macros=%s compile=%s errors=%s" % [ed.doc.bp.graphs.filter(func(x): return x.kind == "macro").map(func(x): return x.name),
		ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("code unchanged: %s" % (body(ed.doc.preview) == before))
	# 2) a pure data chain: deg_to_rad -> multiply
	select(ed, math_ids)
	ed._view.collapse_selection()
	await tree.create_timer(0.4).timeout
	var last_macro: Dictionary = ed.doc.bp.graphs[-1]
	note("after collapsing math %s: inputs=%s outputs=%s compile=%s errors=%s" % [math_ids, last_macro.inputs, last_macro.outputs, ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("code unchanged: %s" % (body(ed.doc.preview) == before))
	EditorInterface.get_base_control().queue_redraw()
	await tree.create_timer(0.4).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/10_collapsed.png")
	# 3) Expand Node is the inverse: expanding both collapsed macros gives the original code again
	var expanded := 0
	for round in 2:
		for n in ed.cur_graph().nodes:
			if n.kind == "macro" and String(n.p.name).begins_with("Collapsed"):
				ed._view.expand_macro(int(n.id))
				expanded += 1
				break
		await tree.create_timer(0.3).timeout
	var left: int = ed.cur_graph().nodes.filter(func(x): return x.kind == "macro" and String(x.p.name).begins_with("Collapsed")).size()
	note("%s  expanded %d collapsed nodes, %d left, compile=%s errors=%s" % ["PASS" if expanded == 2 and left == 0 else "FAIL", expanded, left, ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("%s  code after expanding is unchanged" % ("PASS" if body(ed.doc.preview) == before else "FAIL"))
	# 4) expanding the demo's own macro (typed pin value, two prints) still compiles and prints the same text
	var had_literal: bool = before.contains("speed toggled")
	for n in ed.cur_graph().nodes:
		if n.kind == "macro" and n.p.name == "LogTwice":
			ed._view.expand_macro(int(n.id))
			break
	await tree.create_timer(0.3).timeout
	var ok4: bool = ed.compile_doc(ed.doc, false)
	note("%s  expanding LogTwice compiles (errors=%s), literal kept: %s" % ["PASS" if ok4 and ed.doc.errors.is_empty() and (not had_literal or body(ed.doc.preview).contains("speed toggled")) else "FAIL", ed.doc.errors, body(ed.doc.preview).contains("speed toggled")])
	var ur0: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	for i in 3:
		ur0.undo()
	await tree.create_timer(0.3).timeout
	# undo both
	var ur: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	ur.undo()
	ur.undo()
	await tree.create_timer(0.3).timeout
	ed.compile_doc(ed.doc, false)
	note("after undo: macros=%d, code unchanged: %s" % [ed.doc.bp.graphs.filter(func(x): return x.kind == "macro").size(), body(ed.doc.preview) == before])
	# 5) Collapse to Function: an exec node becomes a function call, a pure chain becomes a pure function
	select(ed, [print_id])
	await tree.process_frame
	ed._view.collapse_selection(true)
	await tree.create_timer(0.4).timeout
	var fg: Dictionary = ed.doc.bp.graphs[-1]
	var okf: bool = ed.compile_doc(ed.doc, false)
	var calls: int = ed.cur_graph().nodes.filter(func(x): return x.kind == "call_self" and x.p.fn == fg.name).size()
	note("%s  collapse Print to function: kind=%s pure=%s call nodes=%d compile=%s errors=%s" % ["PASS" if okf and ed.doc.errors.is_empty() and fg.kind == "function" and not fg.pure and calls == 1 and ed.doc.preview.contains("func %s(" % fg.name) and ed.doc.preview.contains("%s()" % fg.name) else "FAIL", fg.kind, fg.pure, calls, okf, ed.doc.errors])
	select(ed, math_ids)
	await tree.process_frame
	ed._view.collapse_selection(true)
	await tree.create_timer(0.4).timeout
	var pg: Dictionary = ed.doc.bp.graphs[-1]
	var okp: bool = ed.compile_doc(ed.doc, false)
	note("%s  collapse maths to function: pure=%s inputs=%s outputs=%s compile=%s errors=%s" % ["PASS" if okp and ed.doc.errors.is_empty() and pg.kind == "function" and pg.pure and pg.inputs.size() == 2 and pg.outputs.size() == 1 else "FAIL", pg.pure, pg.inputs, pg.outputs, okp, ed.doc.errors])
	# a Delay cannot go into a function: nothing must change
	var delay_id: int = int(ed.cur_graph().nodes.filter(func(x): return x.kind == "delay")[0].id)
	var graphs_before: int = ed.doc.bp.graphs.size()
	select(ed, [delay_id])
	await tree.process_frame
	ed._view.collapse_selection(true)
	await tree.create_timer(0.3).timeout
	note("%s  a latent node is refused (graphs %d -> %d)" % ["PASS" if ed.doc.bp.graphs.size() == graphs_before else "FAIL", graphs_before, ed.doc.bp.graphs.size()])
	var ur5: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	ur5.undo()
	ur5.undo()
	await tree.create_timer(0.3).timeout
	ed.compile_doc(ed.doc, false)
	note("%s  after undoing the function collapses the code is the original again" % ("PASS" if body(ed.doc.preview) == before else "FAIL"))
	ed.doc.dirty = false
	note("done")
	tree.quit()
