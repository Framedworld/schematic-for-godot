extends RefCounted
## Editor self-test that clicks through the side panels (My Schematic, Details, toolbar) with real input events
## and walks the New Schematic flow.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_panels.gd

var plugin: EditorPlugin
var tree: SceneTree
var ed
var passed := 0
var failed := 0


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_panels.log"
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


func section(title: String) -> TreeItem:
	var it: TreeItem = ed._members.get_root().get_first_child()
	while it:
		if it.get_text(0).begins_with(title):
			return it
		it = it.get_next()
	return null


func item_named(text: String) -> TreeItem:
	var it: TreeItem = ed._members.get_root().get_next_in_tree()
	while it:
		if it.get_text(0) == text:
			return it
		it = it.get_next_in_tree()
	return null


func tree_point(item: TreeItem, button := -1) -> Vector2:
	var r: Rect2 = ed._members.get_item_area_rect(item, 0, button)
	return ed._members.global_position + r.position + r.size * 0.5


## Godot's Tree only accepts a button press when the real OS cursor is over it, so an injected event can't
## press one. This checks that the button really is where the editor draws it, then fires its signal.
func press_tree_button(item: TreeItem, expected_id: int) -> void:
	var local: Vector2 = tree_point(item, 0) - ed._members.global_position
	check("'%s' has its + button under the expected spot" % item.get_text(0), ed._members.get_button_id_at_position(local) == expected_id)
	ed._members.button_clicked.emit(item, 0, expected_id, MOUSE_BUTTON_LEFT)
	await frames(4)


func detail_controls(type_name: String) -> Array:
	return ed._details.find_children("*", type_name, true, false)


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	var finish := func():
		for d in ed.docs:
			d.dirty = false
	tree.create_timer(80.0).timeout.connect(func():
		note("watchdog quit (passed %d, failed %d)" % [passed, failed])
		finish.call()
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

	# 1. "+" on VARIABLES adds a variable and shows it in Details.
	var count: int = ed.doc.bp.variables.size()
	await press_tree_button(section("VARIABLES"), ed.SEC_VARS)
	check("+ on Variables adds a variable", ed.doc.bp.variables.size() == count + 1, str(ed.doc.bp.variables.map(func(v): return v.name)))
	check("Details shows the new variable", ed._details_title.text == "Variable")

	# 2. Rename it by typing in Details.
	var name_edit: LineEdit = detail_controls("LineEdit")[0]
	await click(name_edit.global_position + name_edit.size * 0.5)
	name_edit.select_all()
	await type_into(name_edit, "lives")
	await key_into(name_edit, KEY_ENTER)
	await frames(4)
	check("typing a name renames the variable", ed.doc.bp.variables[-1].name == "lives", ed.doc.bp.variables[-1].name)

	# 3. Change its type through the type picker.
	var type_btn: Button = null
	for b in detail_controls("Button"):
		if b.has_meta("type"):
			type_btn = b
			break
	await click(type_btn.global_position + type_btn.size * 0.5)
	await frames(4)
	var picker_search: LineEdit = null
	for c in type_btn.get_children():
		if c is PopupPanel:
			for le in c.find_children("*", "LineEdit", true, false):
				picker_search = le
	check("type button opens the type picker", picker_search != null)
	if picker_search:
		await type_into(picker_search, "int")
		await key_into(picker_search, KEY_ENTER)
		await frames(4)
	check("picking a type changes the variable", ed.doc.bp.variables[-1].type == "int", ed.doc.bp.variables[-1].type)

	# 4. Tick Instance Editable.
	var boxes := detail_controls("CheckBox")
	await click(boxes[0].global_position + Vector2(10, boxes[0].size.y * 0.5))
	await frames(4)
	check("Instance Editable checkbox works", ed.doc.bp.variables[-1].get("export", false) == true)

	# 5. Type a default value.
	var edits := detail_controls("LineEdit")
	var def_edit: LineEdit = edits[-1]
	await click(def_edit.global_position + def_edit.size * 0.5)
	def_edit.select_all()
	await type_into(def_edit, "3")
	await key_into(def_edit, KEY_ENTER)
	await frames(4)
	check("default value is stored", String(ed.doc.bp.variables[-1].get("default", "")) == "3", String(ed.doc.bp.variables[-1].get("default", "")))

	# 6. Ctrl-drag the variable from My Schematic into the graph -> Get node.
	ed._view.scroll_offset = Vector2(2600, 200)
	await frames(4)
	var nodes_before: int = ed.cur_graph().nodes.size()
	await key(KEY_CTRL, true)
	await drag(tree_point(item_named("lives")), ed._view.global_position + Vector2(400, 300))
	await key(KEY_CTRL, false)
	await frames(4)
	var last: Dictionary = ed.cur_graph().nodes[-1]
	check("Ctrl-dragging a variable into the graph makes a Get node", ed.cur_graph().nodes.size() == nodes_before + 1 and last.kind == "var_get" and last.p.get("name", "") == "lives", "%s" % last.kind)

	# 7. Compile button; the generated code has the exported variable.
	await click(ed._compile_btn.global_position + ed._compile_btn.size * 0.5)
	await frames(6)
	check("Compile button compiles", ed._status.text == "Good to go", ed._status.text)
	check("generated code exports the variable", String(ed.doc.preview).contains("@export var lives: int = 3"))

	# 8. "+" on FUNCTIONS adds a function and opens its graph.
	var graphs_before: int = ed.doc.bp.graphs.size()
	await press_tree_button(section("FUNCTIONS"), ed.SEC_FUNCS)
	check("+ on Functions adds a function graph", ed.doc.bp.graphs.size() == graphs_before + 1 and ed.cur_graph().kind == "function", ed.cur_graph().name)

	# Put the demo back exactly as it was (undo everything, then recompile and save).
	var ur: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	for i in 12:
		if ur.has_undo():
			ur.undo()
	await frames(4)
	ed.compile_doc(ed.doc, true)
	check("undo returns the demo to its original variables", ed.doc.bp.variables.size() == count, str(ed.doc.bp.variables.size()))

	# 9. New Schematic flow: parent class -> file dialog -> file on disk, opened, compiles.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://demo/tmp_new"))
	ed._new_schematic_file("Node2D", null)
	await frames(6)
	var dialog: EditorFileDialog = null
	for c in EditorInterface.get_base_control().get_children():
		if c is EditorFileDialog and c.visible:
			dialog = c
	check("New Schematic opens a save dialog", dialog != null, dialog.title if dialog else "")
	if dialog:
		dialog.file_selected.emit("res://demo/tmp_new/SC_Fresh.gd")
		dialog.hide()
		await frames(8)
		var text := FileAccess.get_file_as_string("res://demo/tmp_new/SC_Fresh.gd")
		check("schematic file is written", text.begins_with("# @schematic") and text.contains("class_name SC_Fresh") and text.contains("extends Node2D"))
		check("new schematic is open with Ready and Process events", ed.doc.path == "res://demo/tmp_new/SC_Fresh.gd" and ed.cur_graph().nodes.size() == 2 and ed.doc.errors.is_empty(), str(ed.doc.errors))
		var idx: int = ed.docs.find(ed.doc)
		ed.doc.dirty = false
		ed._close_doc(idx)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://demo/tmp_new/SC_Fresh.gd"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://demo/tmp_new/SC_Fresh.gd.uid"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://demo/tmp_new"))
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.0).timeout

	note("passed %d, failed %d" % [passed, failed])
	finish.call()
	note("done")
	tree.quit()
