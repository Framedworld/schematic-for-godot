extends RefCounted
## Editor self-test for the look of the graph: saves full-resolution crops of the canvas, the action menu and
## the side panels so the styling can be compared with Unreal's.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_look.gd

var plugin: EditorPlugin
var tree: SceneTree
var ed


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_look.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func crop(name: String, c: Control, grow := 0.0) -> void:
	await tree.create_timer(0.45).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	var r := Rect2(c.get_global_rect()).grow(grow).intersection(Rect2(Vector2.ZERO, img.get_size()))
	img.get_region(Rect2i(r)).save_png("res://tests/out/%s.png" % name)
	note("saved %s %s" % [name, r])


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	tree.create_timer(60.0).timeout.connect(func():
		note("watchdog quit")
		if ed and ed.doc:
			ed.doc.dirty = false
		tree.quit())
	await tree.create_timer(2.5).timeout
	ed = p.editor
	ed.open_schematic("res://demo/SC_Demo.gd")
	EditorInterface.set_main_screen_editor("Schematic")
	EditorInterface.open_scene_from_path("res://demo/demo.tscn")
	await tree.create_timer(1.0).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	var view: GraphEdit = ed._view
	await crop("look_1_graph", view)
	# live values, as the running game would report them
	for wn in ed.cur_graph().nodes:
		if wn.kind == "call" and String(wn.p.get("method", "")) == "rotate_y":
			view.show_watch(int(wn.id), {"angle": "0.1221730476396"})
		if wn.kind == "var_set":
			view.show_watch(int(wn.id), {"value": "12.48"})
	await crop("look_1b_live_values", view)
	view.watch.clear()
	ed._refresh_graph()
	# selection, a breakpoint, a comment and a reroute
	var g: Dictionary = ed.cur_graph()
	var first_print := -1
	for n in g.nodes:
		if n.kind == "print" and first_print == -1:
			first_print = int(n.id)
	ed.toggle_breakpoints([first_print])
	for c in view.get_children():
		if c is GraphNode:
			c.selected = String(c.name) == "n%d" % first_print or c.kind == "sequence"
	await tree.process_frame
	view.comment_selection()
	await tree.create_timer(0.3).timeout
	view.spawn("branch", {}, Vector2(200, 560))
	view.spawn("for_each", {}, Vector2(430, 560))
	view.spawn("make_array", {"n": 2}, Vector2(200, 700))
	view.spawn("cast", {"cls": "Node3D"}, Vector2(700, 640))
	view.spawn("reroute", {"t": "float"}, Vector2(560, 760))
	await tree.create_timer(0.3).timeout
	# node comment bubble, an unwired (greyed) event, hide unrelated
	var cn: Dictionary = ed.cur_graph().nodes.filter(func(x): return x.kind == "delay")[0]
	ed.mutate("Edit Node Comment", func(): cn["c"] = "Wait a second before the second print")
	view.spawn("event", {"name": "_physics_process"}, Vector2(60, 520))
	await tree.create_timer(0.3).timeout
	var ghost: GraphNode = view.get_node("n%d" % int(ed.cur_graph().nodes[-1].id))
	note("%s  unwired event is greyed with Unreal's note (%s)" % ["PASS" if ghost._ghost and ghost._bubble_text.begins_with("This node is disabled") else "FAIL", ghost.title])
	note("%s  node comment shows as a bubble" % ("PASS" if view.get_node("n%d" % int(cn.id))._bubble_text == "Wait a second before the second print" else "FAIL"))
	await crop("look_2b_bubbles", view)
	view.hide_unrelated = true
	for c in view.get_children():
		if c is GraphNode:
			c.selected = c == ghost
	view.apply_unrelated()
	var dimmed := 0
	for c in view.get_children():
		if c is GraphNode and c.modulate.a < 0.5:
			dimmed += 1
	note("%s  Hide Unrelated fades the other nodes (%d faded, selected one kept: %s)" % ["PASS" if dimmed > 5 and ghost.modulate.a == 1.0 else "FAIL", dimmed, ghost.modulate.a == 1.0])
	view.hide_unrelated = false
	view.apply_unrelated()
	await crop("look_2_marks", view)
	view.zoom = 1.5
	view.scroll_offset = Vector2(80, 120) * 1.5
	await crop("look_3_zoomed", view)
	view.zoom = 0.5
	view.scroll_offset = Vector2(-200, -100)
	await crop("look_4_far", view)
	view.zoom = 1.0
	view.scroll_offset = Vector2(0, 100)
	# action menu
	view._open_palette(Vector2(420, 120), {})
	await tree.create_timer(0.6).timeout
	ed._palette.get_texture().get_image().save_png("res://tests/out/look_5_menu.png")
	ed._palette._search.text = "print"
	ed._palette._fill()
	await tree.create_timer(0.4).timeout
	ed._palette.get_texture().get_image().save_png("res://tests/out/look_6_menu_search.png")
	ed._palette.hide()
	view._on_connection_to_empty("n8", 0, Vector2(700, 500))
	await tree.create_timer(0.5).timeout
	ed._palette.get_texture().get_image().save_png("res://tests/out/look_7_menu_context.png")
	ed._palette.hide()
	# side panels
	ed._select({"kind": "var", "name": "spin_speed"})
	await crop("look_8_panels", ed)
	# Details: categories collapse, search filters rows
	var dpanel: Control = ed._right_tabs
	await crop("look_9_details_var", dpanel)
	var cats: Array = ed._details.get_children().filter(func(c): return c.has_meta("category"))
	var cat_names := cats.map(func(c): return c.get_meta("category"))
	note("%s  variable details has Variable and Default Value categories %s" % ["PASS" if cat_names == ["Variable", "Default Value"] else "FAIL", cat_names])
	cats[0].get_child(0).pressed.emit()
	await tree.process_frame
	note("%s  clicking a category header collapses it" % ("PASS" if not cats[0].get_child(1).visible else "FAIL"))
	cats[0].get_child(0).pressed.emit()
	ed._details_search.text = "tool"
	ed._details_search.text_changed.emit("tool")
	await tree.process_frame
	var shown := []
	for r in cats[0].get_child(1).get_children():
		if r.visible:
			shown.append(r.get_meta("row_label", "?"))
	note("%s  search 'tool' leaves only the Description (tooltip) row %s, Default Value hidden: %s" % ["PASS" if shown == ["description (## doc, shown as tooltip)"] and not cats[1].visible else "FAIL", shown, not cats[1].visible])
	ed._details_search.text = ""
	ed._details_search.text_changed.emit("")
	ed._select({"kind": "graph", "id": int(ed.doc.bp.graphs[1].id), "name": ed.doc.bp.graphs[1].name})
	await crop("look_10_details_graph", dpanel)
	ed._select({"kind": "class"})
	await crop("look_11_details_class", dpanel)
	ed._defaults_btn.pressed.emit()
	await crop("look_12_details_defaults", dpanel)
	var arrows: Array = ed._details.find_children("*", "Button", true, false).filter(func(x): return x.has_meta("reset_arrow"))
	var with_default: int = ed.doc.bp.variables.filter(func(v): return String(v.get("default", "")) != "").size()
	note("%s  reset arrows only on changed defaults (%d arrows, %d changed)" % ["PASS" if arrows.size() == with_default and with_default > 0 else "FAIL", arrows.size(), with_default])
	arrows[0].pressed.emit()
	await tree.process_frame
	note("%s  reset arrow clears the default" % ("PASS" if ed.doc.bp.variables.filter(func(v): return String(v.get("default", "")) != "").size() == with_default - 1 else "FAIL"))
	var drows: int = ed._details.find_children("*", "PanelContainer", true, false).filter(func(x): return x.has_meta("row_label")).size()
	note("%s  Class Defaults lists a row per variable (%d rows, %d variables, showing %s)" % ["PASS" if drows == ed.doc.bp.variables.size() else "FAIL", drows, ed.doc.bp.variables.size(), ed._sel])
	await crop("look_13_toolbar", ed._toolbar.get_parent().get_parent(), 0.0)
	var start_graph: int = int(ed.doc.graph_id)
	ed.open_member_graph("wave")
	await tree.process_frame
	ed._nav_step(-1)
	await tree.process_frame
	note("%s  back arrow returns to the previous graph" % ("PASS" if int(ed.doc.graph_id) == start_graph else "FAIL"))
	ed._nav_step(1)
	await tree.process_frame
	note("%s  forward arrow goes to the function graph (%s)" % ["PASS" if ed.cur_graph().name == "wave" else "FAIL", ed.cur_graph().name])
	ed._nav_step(-1)
	ed._members_search.text = "spin"
	ed._members_search.text_changed.emit("spin")
	await tree.process_frame
	var vis := []
	var mit: TreeItem = ed._members.get_root().get_next_in_tree()
	while mit:
		if mit.visible and typeof(mit.get_metadata(0)) == TYPE_DICTIONARY:
			vis.append(mit.get_text(0))
		mit = mit.get_next_in_tree()
	note("%s  My Schematic search 'spin' shows %s" % ["PASS" if vis == ["spin_speed"] else "FAIL", vis])
	ed._members_search.text = ""
	ed._members_search.text_changed.emit("")
	ed._select({"kind": "var", "name": "spin_speed"})
	# timeline curve editor: drag a key, double-click to add one, right-click to remove it
	var tl_node: Dictionary = {}
	for tg in ed.doc.bp.graphs:
		for tn in tg.nodes:
			if tn.kind == "timeline":
				tl_node = tn
				ed.doc.graph_id = int(tg.id)
	ed._refresh_graph()
	ed._select({"kind": "node", "id": int(tl_node.id)})
	await tree.create_timer(0.3).timeout
	var curves: Array = ed._details.find_children("*", "Control", true, false).filter(func(x): return x.has_meta("curve_edit"))
	var track: Dictionary = tl_node.p.tracks.filter(func(x): return x.get("type", "float") == "float")[0]
	var keys_before: int = track.keys.size()
	var cv = curves[0]
	var from_pt: Vector2 = cv.to_point(cv.keys[0][0], cv.keys[0][1])
	var old_val: float = cv.keys[0][1]
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from_pt
	cv._gui_input(press)
	var move := InputEventMouseMotion.new()
	move.position = from_pt + Vector2(0, -30)
	cv._gui_input(move)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = move.position
	cv._gui_input(up)
	await tree.create_timer(0.3).timeout
	var new_val: float = float(str_to_var(String(track.keys[0][1])))
	note("%s  dragging a key up raises its value (%s -> %s)" % ["PASS" if new_val > old_val else "FAIL", old_val, new_val])
	cv = ed._details.find_children("*", "Control", true, false).filter(func(x): return x.has_meta("curve_edit"))[0]
	await crop("look_14_curve", cv, 6.0)
	var dbl := InputEventMouseButton.new()
	dbl.button_index = MOUSE_BUTTON_LEFT
	dbl.pressed = true
	dbl.double_click = true
	dbl.position = cv.to_point(cv.length * 0.37, (cv._lo + cv._hi) * 0.5)
	cv._gui_input(dbl)
	await tree.create_timer(0.3).timeout
	note("%s  double-click adds a key (%d -> %d)" % ["PASS" if track.keys.size() == keys_before + 1 else "FAIL", keys_before, track.keys.size()])
	cv = ed._details.find_children("*", "Control", true, false).filter(func(x): return x.has_meta("curve_edit"))[0]
	var rc := InputEventMouseButton.new()
	rc.button_index = MOUSE_BUTTON_RIGHT
	rc.pressed = true
	rc.position = cv.to_point(cv.keys[1][0], cv.keys[1][1])
	cv._gui_input(rc)
	await tree.create_timer(0.3).timeout
	note("%s  right-click removes a key (back to %d)" % ["PASS" if track.keys.size() == keys_before else "FAIL", track.keys.size()])
	note("%s  timeline still compiles: %s" % ["PASS" if ed.compile_doc(ed.doc, false) and ed.doc.errors.is_empty() else "FAIL", ed.doc.errors])
	# bookmarks
	var bm_graph: int = int(ed.doc.graph_id)
	view.zoom = 0.75
	view.scroll_offset = Vector2(120, 80)
	ed.add_bookmark()
	ed.open_member_graph("wave")
	await tree.process_frame
	ed.goto_bookmark(0)
	await tree.process_frame
	note("%s  bookmark returns to the graph and view (graph ok %s, zoom %s, scroll %s)" % ["PASS" if int(ed.doc.graph_id) == bm_graph and is_equal_approx(view.zoom, 0.75) and view.scroll_offset.distance_to(Vector2(120, 80)) < 2.0 else "FAIL", int(ed.doc.graph_id) == bm_graph, view.zoom, view.scroll_offset])
	ed._on_bookmark(1001)
	note("%s  Remove All Bookmarks clears them" % ("PASS" if not ed.doc.bp.has("bookmarks") else "FAIL"))
	ed._select({"kind": "var", "name": "spin_speed"})
	# the eye on a variable row toggles Instance Editable
	var row: TreeItem = null
	var it: TreeItem = ed._members.get_root().get_next_in_tree()
	while it:
		var m: Variant = it.get_metadata(0)
		if typeof(m) == TYPE_DICTIONARY and m.get("kind", "") == "var" and m.get("name", "") == "time":
			row = it
		it = it.get_next_in_tree()
	var before: bool = ed.doc.bp.variables.filter(func(v): return v.name == "time")[0].get("export", false)
	ed._members.button_clicked.emit(row, 0, 200, MOUSE_BUTTON_LEFT)
	await tree.create_timer(0.3).timeout
	var after: bool = ed.doc.bp.variables.filter(func(v): return v.name == "time")[0].get("export", false)
	note("%s  eye toggles Instance Editable (%s -> %s)" % ["PASS" if before != after else "FAIL", before, after])
	note("%s  schematic still compiles: %s" % ["PASS" if ed.compile_doc(ed.doc, false) else "FAIL", ed.doc.errors])
	var ur: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	for i in 18:
		ur.undo()
	ed.toggle_breakpoints([first_print])
	ed.doc.dirty = false
	note("done")
	tree.quit()
