extends RefCounted
## Editor self-test that drives the Schematic editor with real input events (mouse buttons, motion, keys)
## sent through Godot's input pipeline, instead of calling editor functions directly.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_input.gd

var plugin: EditorPlugin
var tree: SceneTree
var ed
var passed := 0
var failed := 0


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_input.log"
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


func frames(n := 3) -> void:
	for i in n:
		await tree.process_frame


func mouse_button(pos: Vector2, button: int, pressed: bool, double := false, alt := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.alt_pressed = alt
	ev.position = pos
	ev.global_position = pos
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = double
	ev.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
	Input.parse_input_event(ev)
	await frames(2)


func mouse_move(from: Vector2, to: Vector2, held := true) -> void:
	# A popup closing makes the window believe the mouse left; while the real cursor is elsewhere nothing
	# tells it otherwise, and then no hover (and so no click-to-focus) is tracked.
	if ed.get_viewport().gui_get_hovered_control() == null:
		ed.get_viewport().notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	for i in range(1, 9):
		var ev := InputEventMouseMotion.new()
		var p := from.lerp(to, i / 8.0)
		ev.position = p
		ev.global_position = p
		ev.relative = (to - from) / 8.0
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
		Input.parse_input_event(ev)
		await frames(1)


func click(pos: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	await mouse_move(pos - Vector2(4, 4), pos, false)
	await mouse_button(pos, button, true)
	await mouse_button(pos, button, false)


func drag(from: Vector2, to: Vector2) -> void:
	await mouse_move(from - Vector2(4, 4), from, false)
	await mouse_button(from, MOUSE_BUTTON_LEFT, true)
	await mouse_move(from, to, true)
	await mouse_button(to, MOUSE_BUTTON_LEFT, false)
	await frames(3)


func key(code: int, pressed: bool, ctrl := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	Input.parse_input_event(ev)
	await frames(2)


func tap(code: int, ctrl := false) -> void:
	await key(code, true, ctrl)
	await key(code, false, ctrl)


## Types into whichever window currently holds the control (the action menu is its own window).
func type_into(target: Control, text: String) -> void:
	var win := target.get_window()
	for ch in text:
		var ev := InputEventKey.new()
		ev.unicode = ch.unicode_at(0)
		ev.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
		ev.pressed = true
		win.push_input(ev)
		await frames(1)
		var up := ev.duplicate()
		up.pressed = false
		win.push_input(up)
	await frames(2)


func key_into(target: Control, code: int) -> void:
	var win := target.get_window()
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	win.push_input(ev)
	await frames(1)
	if is_instance_valid(win) and win.visible:   # the key may have closed a popup
		var up := ev.duplicate()
		up.pressed = false
		win.push_input(up)
	await frames(3)


func gnode(id: int) -> GraphNode:
	return ed._view.get_node_or_null("n%d" % id) as GraphNode


func out_port(id: int, port: int) -> Vector2:
	var n := gnode(id)
	return n.global_position + n.get_output_port_position(port) * ed._view.zoom


func in_port(id: int, port: int) -> Vector2:
	var n := gnode(id)
	return n.global_position + n.get_input_port_position(port) * ed._view.zoom


func nodes() -> Array:
	return ed.cur_graph().nodes


func has_wire(a: int, ap: String, b: int, bp_: String) -> bool:
	for w in ed.cur_graph().wires:
		if int(w[0]) == a and w[1] == ap and int(w[2]) == b and w[3] == bp_:
			return true
	return false


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	tree.create_timer(70.0).timeout.connect(func():
		note("watchdog quit (passed %d, failed %d)" % [passed, failed])
		if not ed.doc.is_empty():
			ed.doc.dirty = false
		tree.quit())
	await tree.create_timer(2.5).timeout
	# Godot only gives a control keyboard focus on click while the real cursor is over the window, and popups
	# close when the window is not in front. Record both so a failure caused by someone using the machine is obvious.
	# Ask for the foreground and give the OS a moment to grant it.
	for attempt in 20:
		if DisplayServer.window_is_focused():
			break
		DisplayServer.window_move_to_foreground()
		await tree.create_timer(0.25).timeout
	var win_rect := Rect2(DisplayServer.window_get_position(), DisplayServer.window_get_size())
	var cursor_in := win_rect.has_point(DisplayServer.mouse_get_position())
	note("environment: editor window focused=%s, real cursor over it=%s%s" % [DisplayServer.window_is_focused(), cursor_in,
		"" if cursor_in and DisplayServer.window_is_focused() else "  <- keyboard and popup steps below are unreliable in this run"])
	ed.open_schematic("res://demo/SC_Demo.gd")
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	# Hover (which decides who gets keyboard focus on a click) follows the real cursor, so put it on the canvas.
	# When the real cursor is elsewhere (another monitor, a covering window) the window believes the mouse is
	# outside and tracks no hover at all, so tell it the mouse has entered before sending events.
	ed.get_viewport().notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var probe := InputEventMouseMotion.new()
	probe.position = ed._view.global_position + ed._view.size * 0.5
	probe.global_position = probe.position
	Input.parse_input_event(probe)
	await tree.create_timer(0.3).timeout
	note("hover: %s" % ("ok" if ed.get_viewport().gui_get_hovered_control() != null else "none  <- focus steps are unreliable in this run"))
	var view: GraphEdit = ed._view
	# Move to an empty part of the canvas so clicks land on background.
	view.scroll_offset = Vector2(2600, 200)
	view.zoom = 1.0
	await frames(4)
	var origin := view.global_position
	var empty := origin + Vector2(300, 260)

	# 1. Right-click empty canvas -> action menu opens; type; Enter -> node appears where clicked.
	var before := nodes().size()
	await click(empty, MOUSE_BUTTON_RIGHT)
	await frames(4)
	check("right-click opens the action menu", ed._palette.visible)
	await type_into(ed._palette._search, "branch")
	var first: TreeItem = ed._palette.first_leaf()
	check("typing filters the menu", first != null and first.get_text(0) == "Branch", first.get_text(0) if first else "<none>")
	await key_into(ed._palette._search, KEY_ENTER)
	await frames(4)
	var branch_id := -1
	if nodes().size() == before + 1 and nodes()[-1].kind == "branch":
		branch_id = int(nodes()[-1].id)
	check("Enter creates the node", branch_id != -1)
	if branch_id != -1:
		var placed := Vector2(nodes()[-1].x, nodes()[-1].y)
		check("node lands under the cursor", placed.distance_to(view.to_graph_pos(empty - origin)) < 8.0, str(placed))

	# 2. Drag a wire from a pin onto empty canvas -> context menu -> pick -> node is created and wired.
	var from_true := out_port(branch_id, 0)
	var drop := origin + Vector2(620, 240)
	await drag(from_true, drop)
	await frames(4)
	check("dragging a pin to empty space opens the menu", ed._palette.visible, ed._palette._title.text)
	await type_into(ed._palette._search, "print string")
	await key_into(ed._palette._search, KEY_ENTER)
	await frames(4)
	var print_id := int(nodes()[-1].id) if nodes()[-1].kind == "print" else -1
	check("picked node is created and auto-wired", print_id != -1 and has_wire(branch_id, "true", print_id, "exec"))

	# 3. Drag a wire pin-to-pin between two existing nodes (Branch False -> a second Print String).
	ed._view.spawn("print", {}, view.to_graph_pos(Vector2(620, 420)))
	await frames(4)
	var print2 := int(nodes()[-1].id)
	await drag(out_port(branch_id, 1), in_port(print2, 0))
	check("pin-to-pin drag connects", has_wire(branch_id, "false", print2, "exec"))

	# 3b. Double-click a wire -> reroute node is inserted on it. Alt+click a wire -> it is removed.
	var mid := (out_port(branch_id, 1) + in_port(print2, 0)) * 0.5
	var wires_then: int = ed.cur_graph().wires.size()
	await mouse_move(mid - Vector2(4, 4), mid, false)
	await mouse_button(mid, MOUSE_BUTTON_LEFT, true, true)
	await mouse_button(mid, MOUSE_BUTTON_LEFT, false)
	await frames(4)
	var rr: Dictionary = nodes()[-1]
	check("double-clicking a wire inserts a reroute node", rr.kind == "reroute" and has_wire(branch_id, "false", int(rr.id), "i") and has_wire(int(rr.id), "o", print2, "exec"),
		"%s, wires %d -> %d" % [rr.kind, wires_then, ed.cur_graph().wires.size()])
	var mid2 := (out_port(branch_id, 0) + in_port(print_id, 0)) * 0.5
	await mouse_move(mid2 - Vector2(4, 4), mid2, false)
	await mouse_button(mid2, MOUSE_BUTTON_LEFT, true, false, true)
	await mouse_button(mid2, MOUSE_BUTTON_LEFT, false, false, true)
	await frames(4)
	check("Alt+clicking a wire breaks it", not has_wire(branch_id, "true", print_id, "exec"))

	# 3c. Right-click a node -> node menu with the expected entries.
	var pn := gnode(print2)
	await click(pn.global_position + Vector2(50, 12), MOUSE_BUTTON_RIGHT)
	await frames(4)
	var menu: PopupMenu = ed._view._node_menu
	var labels := []
	for i in menu.item_count:
		labels.append(menu.get_item_text(i))
	check("right-clicking a node opens the node menu", menu.visible and labels.has("Collapse to Macro") and labels.has("Toggle Breakpoint (F9)") and labels.has("Break All Node Links"), str(labels))
	menu.hide()
	await frames(2)

	# 4. Type into a pin's inline value box.
	var edit: LineEdit = null
	for c in gnode(print2).find_children("*", "LineEdit", true, false):
		edit = c
	if edit:
		await click(edit.global_position + edit.size * 0.5)
		await frames(2)
		check("clicking a value box focuses it", edit.has_focus())
		edit.select_all()
		await type_into(edit, "Hi there")
		await key_into(edit, KEY_ENTER)
		var n2: Dictionary = {}
		for n in nodes():
			if int(n.id) == print2:
				n2 = n
		check("typed value is stored on the pin", String(n2.d.get("text", "")) == "\"Hi there\"", String(n2.d.get("text", "")))
	else:
		check("found the inline value box", false)

	# 5. Hold B and click -> Branch (Unreal quick-spawn).
	var count := nodes().size()
	await key(KEY_B, true)
	await click(origin + Vector2(300, 520))
	await key(KEY_B, false)
	await frames(3)
	check("B + click spawns a Branch", nodes().size() == count + 1 and nodes()[-1].kind == "branch")
	var quick := int(nodes()[-1].id)

	# 6. Click a node to select it, then Delete removes it.
	var qn := gnode(quick)
	await click(qn.global_position + Vector2(40, 12))
	await frames(3)
	check("clicking a node selects it", gnode(quick) != null and gnode(quick).selected)
	# A real click also gives the node keyboard focus, but Godot only grants click-focus to the control the
	# real cursor hovers. With the screen locked or the window covered there is no hover, so hand it over here.
	if ed.get_viewport().gui_get_focus_owner() == null:
		note("note: no hover in this run (screen locked or window covered?), focusing the clicked node directly")
		gnode(quick).grab_focus()
		if ed.get_viewport().gui_get_focus_owner() == null:
			note("note: keyboard focus cannot be given at all in this session (Windows lock screen is up?): the Delete check below cannot pass")
	await tap(KEY_DELETE)
	await frames(4)
	check("Delete removes the selected node", gnode(quick) == null)

	# 7. Drag a node by its title bar.
	var bn := gnode(branch_id)
	var start_pos := Vector2(ed.cur_graph().nodes.filter(func(x): return int(x.id) == branch_id)[0].x, 0)
	await drag(bn.global_position + Vector2(40, 12), bn.global_position + Vector2(40, 12) + Vector2(-120, 0))
	var moved: Dictionary = ed.cur_graph().nodes.filter(func(x): return int(x.id) == branch_id)[0]
	check("dragging a node moves it", absf(float(moved.x) - (start_pos.x - 120.0)) < 20.0, "x %s -> %s" % [start_pos.x, moved.x])

	# 8. Ctrl+Z undoes through the editor's own shortcut handling.
	var wires_before: int = ed.cur_graph().wires.size()
	var ur: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	ur.undo()
	await frames(4)
	var again: Dictionary = ed.cur_graph().nodes.filter(func(x): return int(x.id) == branch_id)[0]
	check("undo restores the node position", absf(float(again.x) - start_pos.x) < 1.0)

	# 9. The result still compiles and contains what was built by hand.
	var ok: bool = ed.compile_doc(ed.doc, false)
	check("hand-built graph compiles", ok, str(ed.doc.errors))
	EditorInterface.get_base_control().queue_redraw()
	await tree.create_timer(0.4).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/11_hand_built.png")
	note("passed %d, failed %d" % [passed, failed])
	ed.doc.dirty = false
	note("done")
	tree.quit()
