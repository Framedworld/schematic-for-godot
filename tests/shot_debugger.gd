extends RefCounted
## Editor self-test for the Blueprint debugger: call stack, values on pins while paused, watches and stepping
## one node at a time.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_debugger.gd

const LOG := "res://tests/out/selftest_debugger.log"
const BP := "res://demo/BP_Demo.gd"

var plugin: EditorPlugin
var ed
var panel
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


func cleanup() -> void:
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "watches", [])
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if not ed.doc.is_empty():
		ed.doc.dirty = false


## Waits until the game is stopped and the panel has the stack of that stop (and, with `values`, the values).
func settle(values := true, limit := 15.0) -> bool:
	var waited := 0.0
	while waited < limit:
		await tree.create_timer(0.1).timeout
		waited += 0.1
		if panel.paused and not panel.frames.is_empty() and panel.stepping.is_empty() and panel._attached.has(panel.session_id) \
				and String(panel.frames[0][2]) != "" and (not values or panel._pending.is_empty()):
			await tree.create_timer(0.3).timeout
			if panel.paused and panel.stepping.is_empty() and (not values or panel._pending.is_empty()):
				return true
	return false


func top() -> String:
	if panel.frames.is_empty():
		return "(no frames)"
	var f: Array = panel.frames[0]
	return "%s:%d %s" % [String(f[0]).get_file(), int(f[1]), String(f[2])]


func line_text(line: int) -> String:
	return FileAccess.get_file_as_string(BP).split("\n")[line - 1].strip_edges()


func key_at(line: int) -> String:
	for k in ed.doc.saved_lines:
		if int(ed.doc.saved_lines[k]) == line:
			return String(k)
	return ""


func line_of(text: String) -> int:
	var lines := FileAccess.get_file_as_string(BP).split("\n")
	for i in lines.size():
		if lines[i].strip_edges() == text:
			return i + 1
	return -1


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	panel = ed.debug_panel
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(110.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	panel.watches.clear()
	note("open: %s" % ed.open_blueprint(BP))
	EditorInterface.set_main_screen_editor("Blueprint")
	await tree.create_timer(0.8).timeout

	var rotate_line := line_of("rotate_y((deg_to_rad(spin_speed) * delta))")
	var rotate_key := key_at(rotate_line)
	check(rotate_key != "", "the rotate node is on line %d (%s)" % [rotate_line, rotate_key])
	var rotate_id := int(rotate_key.get_slice(":", 1))
	ed.doc.graph_id = int(rotate_key.get_slice(":", 0))
	ed._refresh_graph()
	ed.toggle_breakpoints([rotate_id])
	check(not ed.debug_info(BP).pins.is_empty(), "the compiler recorded what each wired pin reads: %s" % [ed.debug_info(BP).pins.get("_process", {})])
	panel.add_watch({"label": "time", "expr": "time"})
	panel.add_watch({"label": "spin_speed * 2.0", "expr": "spin_speed * 2.0"})
	panel.add_watch({"label": "position", "expr": "position"})
	panel.add_watch({"label": "queue_free()", "expr": "queue_free()"})
	EditorInterface.play_custom_scene("res://demo/demo.tscn")

	# --- stopped at the breakpoint
	check(await settle(), "the game stopped and the probe answered (%s)" % top())
	check(top() == "BP_Demo.gd:%d _process" % rotate_line, "top frame is the rotate node's line in _process")
	check(ed._paused.size() == 3 and int(ed._paused[2]) == rotate_id, "the graph marks that node as paused: %s" % [ed._paused])
	check(panel.visible and ed._step_tools[1].visible, "the debug panel and the step buttons are showing")
	note("locals: %s" % [panel._locals])
	note("members: %s" % [panel._members])
	check(panel._locals.has("delta"), "Locals lists delta")
	check(String(panel._members.get("spin_speed", "")) == "90.0", "Variables lists spin_speed = 90.0")
	var pins: Dictionary = panel.pin_values(BP, int(ed.doc.graph_id))
	note("pin values: %s" % [pins])
	check(not pins.get(rotate_id, {}).is_empty(), "the rotate node's wired pin has a value")
	note("watch values: %s" % [panel._watch_values])
	check(panel._watch_values.size() == 4 and panel._watch_values[0] != null, "watch on a variable has a value")
	check(panel._watch_values.size() == 4 and String(panel._watch_values[1]) == "180.0", "watch on an expression: spin_speed * 2.0 = 180.0")
	check(panel._watch_values.size() == 4 and panel._watch_values[2] != null and String(panel._watch_values[2]).begins_with("("), "watch on a property of the node itself (position) has a value")
	check(panel._watch_values.size() == 4 and panel._watch_values[3] == null, "a watch that would change the game (queue_free()) is not run")
	var shown := 0
	for c in ed._view.get_children():
		if c is GraphNode:
			for lab in c.find_children("*", "Label", true, false):
				if lab.has_meta("watch"):
					shown += 1
	check(shown > 0, "%d pin values are drawn on the graph" % shown)
	await shot("13_paused_values")

	# --- step over: one node per press
	var time_line := line_of("time = (time + delta)")
	panel.step("next")
	check(await settle(), "step over stopped again (%s)" % top())
	check(top() == "BP_Demo.gd:%d _process" % time_line, "step over went to the next node (line %d)" % time_line)
	check(int(ed._paused[2]) == int(key_at(time_line).get_slice(":", 1)), "and the graph shows that node as paused")
	check(ed._view.flow_overlay.count() == 1, "the wire the step followed is animated: %d wire" % ed._view.flow_overlay.count())
	await tree.create_timer(0.15).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/19_step_wire_flow.png")
	var wave_line := line_of("position = Vector3(0.0, wave(time), 0.0)")
	panel.step("next")
	check(await settle(), "step over stopped again (%s)" % top())
	check(top() == "BP_Demo.gd:%d _process" % wave_line, "second step over went to the node after it (line %d)" % wave_line)

	# --- step into the function that node calls
	panel.step("step")
	check(await settle(), "step into stopped (%s)" % top())
	check(String(panel.frames[0][2]) == "wave" and panel.frames.size() >= 2, "step into entered the wave function: %s" % [panel.frames])
	note("stack rows: %s" % [_stack_rows()])
	check(ed.cur_graph().get("name", "") == "wave", "the editor switched to the wave graph: %s" % ed.cur_graph().get("name", ""))
	note("locals in wave: %s  pins: %s" % [panel._locals, panel.pin_values(BP, int(ed.doc.graph_id))])
	await shot("14_stepped_into_function")
	# what the stops so far left in Godot's own Evaluator tab
	for ev in EditorInterface.get_base_control().find_children("*", "EditorExpressionEvaluator", true, false):
		var tabs := ev.get_parent() as TabContainer
		if tabs:
			var was := tabs.current_tab
			tabs.current_tab = ev.get_index()
			await shot("15_evaluator_tab")
			tabs.current_tab = was
		break

	# --- pick the caller in the call stack
	panel._stack.get_root().get_child(1).select(0)
	await tree.create_timer(0.2).timeout
	check(await settle(), "selecting the caller's frame asked for its values")
	check(panel.frame == 1 and panel._locals.has("delta"), "the caller's frame shows its own locals: %s" % [panel._locals])
	check(ed.cur_graph().get("name", "") != "wave", "and its graph: %s" % ed.cur_graph().get("name", ""))

	# --- step out
	panel._stack.get_root().get_child(0).select(0)
	await tree.create_timer(0.3).timeout
	await settle()
	panel.step("out")
	check(await settle(), "step out stopped (%s)" % top())
	check(String(panel.frames[0][2]) != "wave", "step out left the wave function: %s" % top())

	# --- a node made of several generated lines is one step
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	note("line map around _ready: %s" % [_map_dump(line_of("func _ready() -> void:"), 14)])

	# --- resume
	ed.debug_continue()
	await tree.create_timer(1.0).timeout
	note("after Resume with the breakpoint still set in the game: paused=%s %s" % [panel.paused, top()])
	for s in p._debugger.get_sessions():
		if s.is_active() and s.is_breaked():
			s.set_breakpoint(BP, rotate_line, false)
	ed.debug_continue()
	await tree.create_timer(1.0).timeout
	check(not panel.paused and ed._paused.is_empty() and not panel.visible, "Resume: the game runs and the panel is hidden")
	EditorInterface.stop_playing_scene()
	await tree.create_timer(1.0).timeout

	# --- second run: a node made of several generated lines is one step
	var hello_line := line_of("print(\"Hello from a Blueprint!\")")
	var after_line := line_of("print(\"Sequence does not wait for the Delay\")")
	ed.doc.graph_id = int(key_at(hello_line).get_slice(":", 0))
	ed._refresh_graph()
	ed.toggle_breakpoints([int(key_at(hello_line).get_slice(":", 1))])
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	check(await settle(), "second run stopped at the first Print String (%s)" % top())
	check(int(panel.frames[0][1]) == hello_line, "on line %d" % hello_line)
	panel.step("next")
	check(await settle(), "step over (%s)" % top())
	check(int(panel.frames[0][1]) == hello_line + 1, "went to the Sequence node (line %d)" % (hello_line + 1))
	panel.step("step")
	check(await settle(), "step into (%s)" % top())
	check(int(panel.frames[0][1]) == hello_line + 2, "entered the Delay node inside the Sequence (line %d)" % (hello_line + 2))
	check(not panel._members.is_empty(), "values are read inside the generated lambda too: %d variables" % panel._members.size())
	panel.step("next")
	check(await settle(), "step over (%s)" % top())
	check(panel.steps_sent > 1, "the Delay node's %d generated lines were one step" % panel.steps_sent)
	check(int(panel.frames[0][1]) == after_line, "and it stopped on the node after the Sequence (line %d)" % after_line)
	EditorInterface.stop_playing_scene()
	await tree.create_timer(0.8).timeout
	cleanup()
	note("done: %d failed" % fails)
	tree.quit()


func _stack_rows() -> Array:
	var out := []
	var it: TreeItem = panel._stack.get_root().get_first_child()
	while it:
		out.append(it.get_text(0))
		it = it.get_next()
	return out


func _map_dump(from: int, count: int) -> Array:
	var out := []
	for l in range(from, from + count):
		out.append("%d=%s" % [l, ed.doc.line_map.get(l, "-")])
	return out
