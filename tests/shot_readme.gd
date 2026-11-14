extends RefCounted
## Takes the pictures the README shows (docs/images). Every picture is the real editor: nothing is drawn in.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_readme.gd

const Model := preload("res://addons/blueprints/core/bp_model.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const Starters := preload("res://addons/blueprints/core/bp_starters.gd")
const OUT := "res://docs/images/"
const TMP := "res://demo/tmp_readme"
const DEMO := "res://demo/BP_Demo.gd"
const MAX_WIDTH := 1800

const PATROL := """extends CharacterBody2D
## A guard that walks back and forth, and runs at the player when it sees them.

@export var speed := 80.0
@export var sight := 160.0
var direction := 1.0
var target: Node2D


func _physics_process(_delta: float) -> void:
	if target != null and global_position.distance_to(target.global_position) < sight:
		velocity = global_position.direction_to(target.global_position) * speed * 1.5
	else:
		velocity = Vector2(direction * speed, 0.0)
		if is_on_wall():
			direction = -direction
	move_and_slide()
"""

var plugin: EditorPlugin
var tree: SceneTree
var ed
var view
var panel
var log_lines := []


func note(msg: String) -> void:
	log_lines.append(msg)
	var f := FileAccess.open("res://tests/out/shot_readme.log", FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
	f.close()


func wait(sec: float) -> void:
	await tree.create_timer(sec).timeout


func grab() -> Image:
	plugin.hide_bottom_panel()
	EditorInterface.get_base_control().queue_redraw()
	await wait(0.45)
	return EditorInterface.get_base_control().get_viewport().get_texture().get_image()


func save(img: Image, name: String) -> void:
	if img.get_width() > MAX_WIDTH:
		img.resize(MAX_WIDTH, int(round(img.get_height() * float(MAX_WIDTH) / img.get_width())), Image.INTERPOLATE_LANCZOS)
	img.save_png(OUT + name + ".png")
	note("saved %s %s" % [name, img.get_size()])


## The part of the editor a picture shows: "full" (the whole Blueprint editor), "work" (graph and the panel
## on its right) or "graph" (the graph with the panels under it).
func area(part: String) -> Rect2:
	var full: Rect2 = plugin._screen.get_global_rect()
	var mid: Rect2 = (view.get_parent() as Control).get_global_rect()
	match part:
		"work": return Rect2(mid.position.x, mid.position.y, full.end.x - mid.position.x, mid.size.y)
		"graph": return mid
	return full


## The Blueprint editor as it is on screen.
func shot(name: String, of: Control = null, part := "full") -> void:
	var img: Image = await grab()
	var r := Rect2(of.get_global_rect()) if of != null else area(part)
	r = r.intersection(Rect2(Vector2.ZERO, img.get_size()))
	save(img.get_region(Rect2i(r)), name)


## The same, with a popup window (which Godot draws separately) put where it is on screen.
func shot_with_popup(name: String, popup: Window, part := "full") -> void:
	var img: Image = await grab()
	var over := popup.get_texture().get_image()
	var at := Vector2i(popup.position) - DisplayServer.window_get_position()
	if over.get_format() != img.get_format():
		over.convert(img.get_format())
	img.blit_rect(over, Rect2i(Vector2i.ZERO, over.get_size()), at)
	var r := area(part).intersection(Rect2(Vector2.ZERO, img.get_size()))
	save(img.get_region(Rect2i(r)), name)


## Zooms and scrolls the graph so the given nodes (all of them when empty) fill the view.
func frame(ids: Array = [], max_zoom := 1.0, margin := 70.0) -> void:
	await wait(0.2)
	var box := Rect2()
	var first := true
	for c in view.get_children():
		if not (c is GraphElement):
			continue
		if not ids.is_empty() and not ids.has(int(String(c.name).trim_prefix("n"))):
			continue
		var r := Rect2(c.position_offset, c.size)
		box = r if first else box.merge(r)
		first = false
	if first:
		return
	box = box.grow(margin)
	var z := minf(max_zoom, minf(view.size.x / box.size.x, view.size.y / box.size.y))
	view.zoom = z
	await wait(0.1)
	view.scroll_offset = box.get_center() * z - view.size * 0.5
	for c in view.get_children():
		if c is GraphElement:
			c.selected = false
	await wait(0.2)


func settle(limit := 15.0) -> bool:
	var waited := 0.0
	while waited < limit:
		await wait(0.1)
		waited += 0.1
		if panel.paused and not panel.frames.is_empty() and panel.stepping.is_empty() and panel._attached.has(panel.session_id) and panel._pending.is_empty():
			await wait(0.3)
			if panel.paused and panel.stepping.is_empty() and panel._pending.is_empty():
				return true
	return false


func node_at_line(text: String) -> int:
	var lines := FileAccess.get_file_as_string(DEMO).split("\n")
	for i in lines.size():
		if lines[i].strip_edges() == text:
			for k in ed.doc.saved_lines:
				if int(ed.doc.saved_lines[k]) == i + 1:
					return int(String(k).get_slice(":", 1))
	return -1


func open_graph(path: String, graph := "") -> void:
	ed.open_blueprint(path)
	if graph != "":
		ed.open_member_graph(graph)
	else:
		ed.doc.graph_id = int(ed.doc.bp.graphs[0].id)
		ed._refresh_graph_tabs()
		ed._refresh_graph()
	await wait(0.4)


## The panel on the right, made wide enough to read the generated code (or put back).
func wide_code(on: bool) -> void:
	ed._right_tabs.custom_minimum_size.x = 760 if on else 340
	ed._right_tabs.current_tab = 1 if on else 0
	if on:
		ed._update_code()
	await wait(0.4)


func cleanup() -> void:
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "watches", [])
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	for i in range(ed.docs.size() - 1, -1, -1):
		ed.docs[i].dirty = false
		if String(ed.docs[i].path).begins_with(TMP):
			ed._close_doc(i)
	var dir := DirAccess.open(TMP)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	EditorInterface.set_distraction_free_mode(false)
	EditorInterface.get_resource_filesystem().scan()


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	view = ed._view
	panel = ed.debug_panel
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	note("--- start")
	tree.create_timer(170.0).timeout.connect(func():
		note("FAIL watchdog quit")
		cleanup()
		tree.quit())
	await wait(2.5)
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	panel.watches.clear()

	# ---- the FileSystem dock, before the docks are hidden
	EditorInterface.set_main_screen_editor("Blueprint")
	await open_graph(DEMO)
	EditorInterface.get_file_system_dock().navigate_to_path("res://demo/game/BP_Player.gd")
	await wait(1.5)
	await shot("file_icon", EditorInterface.get_file_system_dock())

	EditorInterface.set_distraction_free_mode(true)
	plugin.hide_bottom_panel()
	await wait(0.8)

	# ---- the editor
	ed._right_tabs.current_tab = 0
	ed._select({"kind": "class"})
	await frame([], 1.0)
	await shot("editor")

	# ---- graph and the GDScript it compiles to
	await wide_code(true)
	var rotate := node_at_line("rotate_y((deg_to_rad(spin_speed) * delta))")
	var set_pos := node_at_line("position = Vector3(0.0, wave(time), 0.0)")
	var process_ids := [rotate, set_pos, node_at_line("time = (time + delta)")]
	var process_all := []
	for c in view.get_children():
		if c is GraphNode and absf(c.position_offset.y - view.get_node("n%d" % rotate).position_offset.y) < 220.0:
			process_all.append(int(String(c.name).trim_prefix("n")))
	await frame(process_all, 1.0)
	view.focus_node(rotate)
	await frame(process_all, 1.0)
	for i in ed._code.get_line_count():
		if ed._code.get_line(i).begins_with("func _process("):
			ed._code.set_line_as_first_visible(maxi(i - 14, 0))
	await shot("graph_to_code", null, "work")
	await wide_code(false)

	# ---- the action menu
	await frame(process_all, 1.0)
	view._open_palette(Vector2(view.size.x * 0.56, 40), {})
	await wait(0.6)
	ed._palette._search.text = "rotate"
	ed._palette._fill()
	await wait(0.5)
	await shot_with_popup("action_menu", ed._palette, "graph")
	ed._palette.hide()
	await wait(0.3)

	# ---- a timeline
	for n in ed.cur_graph().nodes:
		if n.kind == "timeline":
			await frame([int(n.id)], 1.0, 260.0)
			view.focus_node(int(n.id))
			ed.graph_selection_changed([int(n.id)])
			await wait(0.5)
			await shot("timeline", null, "work")
	ed._select({"kind": "class"})

	# ---- starters
	ed.new_blueprint_dialog()
	await wait(0.8)
	for w in EditorInterface.get_base_control().find_children("*", "ItemList", true, false):
		var win := (w as Control).get_window()
		if win != EditorInterface.get_base_control().get_window() and win.visible:
			await frame([], 1.0)
			await shot_with_popup("starters", win, "graph")
			win.hide()
			break
	await wait(0.3)

	# ---- debugging: stopped at a breakpoint, values on the pins, the wire the step took
	ed.toggle_breakpoints([rotate])
	panel.add_watch({"label": "time", "expr": "time"})
	panel.add_watch({"label": "spin_speed * 2.0", "expr": "spin_speed * 2.0"})
	panel.add_watch({"label": "position", "expr": "position"})
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	note("stopped: %s" % await settle())
	# let it run a little so the values are not all zero
	for s in p._debugger.get_sessions():
		if s.is_active() and s.is_breaked():
			s.set_breakpoint(DEMO, int(ed.doc.saved_lines["%d:%d" % [int(ed.doc.graph_id), rotate]]), false)
	ed.debug_continue()
	await wait(1.4)
	for s in p._debugger.get_sessions():
		if s.is_active():
			s.set_breakpoint(DEMO, int(ed.doc.saved_lines["%d:%d" % [int(ed.doc.graph_id), rotate]]), true)
	note("stopped again: %s" % await settle())
	EditorInterface.set_distraction_free_mode(true)
	await wait(0.5)
	await frame(process_all, 1.0)
	panel.step("next")
	await settle()
	await frame(process_all, 1.0)
	panel.step("next")
	await settle()
	await frame(process_all, 1.0)
	await shot("debug_values", null, "graph")
	panel.step("step")
	await settle()
	await frame([], 1.0)
	await shot("debug_call_stack", null, "graph")
	EditorInterface.get_editor_settings().set_project_metadata("blueprints", "breakpoints", {})
	EditorInterface.stop_playing_scene()
	await wait(1.0)
	panel.watches.clear()
	panel._save_watches()

	# ---- live flow: the game running, nodes and wires lighting up
	await open_graph(DEMO)
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = true)
	ed.compile_doc(ed.doc, true)
	ed.flow_hits = 0
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var waited := 0.0
	while ed.flow_hits == 0 and waited < 15.0:
		await wait(0.25)
		waited += 0.25
	EditorInterface.set_distraction_free_mode(true)
	plugin.hide_bottom_panel()
	await wait(0.6)
	await frame(process_all, 1.0)
	await wait(0.5)
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	save(img.get_region(Rect2i(area("graph").intersection(Rect2(Vector2.ZERO, img.get_size())))), "live_flow")
	EditorInterface.stop_playing_scene()
	await wait(0.8)
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = false)
	ed.compile_doc(ed.doc, true)

	# ---- interfaces
	var iface := Starters.build("interface", "BPI_Interactable")
	var prompt := Model.new_graph(iface, "get_prompt", "function")
	prompt.outputs = [["prompt", "String"]]
	_write(TMP + "/BPI_Interactable.gd", iface)
	var door := Model.new_blueprint("Node3D", "BP_Door")
	door["description"] = "A door the player can open."
	_write(TMP + "/BP_Door.gd", door)
	var hero := Model.new_blueprint("CharacterBody3D", "BP_Hero")
	_write(TMP + "/BP_Hero.gd", hero)
	R.invalidate_libraries()
	EditorInterface.get_resource_filesystem().scan()
	await wait(1.0)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await wait(0.2)
	await wait(1.5)
	EditorInterface.set_distraction_free_mode(true)
	await open_graph(TMP + "/BP_Door.gd")
	ed.implement_interface("BPI_Interactable")
	ed.compile_doc(ed.doc, true)
	await open_graph(TMP + "/BP_Hero.gd")
	ed.mutate("Use the interface", func():
		var g: Dictionary = ed.cur_graph()
		var ev := Model.add_node(g, "input_action", Vector2(40, 420), {"action": "ui_accept"})
		var looked := Model.add_node(g, "call", Vector2(40, 640), {"cls": "Node", "method": "get_parent"})
		var has := Model.add_node(g, "iface_has", Vector2(400, 640), {"iface": "BPI_Interactable"})
		var br := Model.add_node(g, "branch", Vector2(640, 420), {})
		var ask := Model.add_node(g, "iface_call", Vector2(930, 400), {"iface": "BPI_Interactable", "fn": "get_prompt"})
		var say := Model.add_node(g, "print", Vector2(1230, 400), {})
		var go := Model.add_node(g, "iface_call", Vector2(1530, 400), {"iface": "BPI_Interactable", "fn": "interact"})
		g.wires.append([int(ev.id), "pressed", int(br.id), "exec"])
		g.wires.append([int(looked.id), "ret", int(has.id), "target"])
		g.wires.append([int(has.id), "ret", int(br.id), "cond"])
		g.wires.append([int(br.id), "true", int(ask.id), "exec"])
		g.wires.append([int(looked.id), "ret", int(ask.id), "target"])
		g.wires.append([int(ask.id), "r_prompt", int(say.id), "text"])
		g.wires.append([int(ask.id), "then", int(say.id), "exec"])
		g.wires.append([int(say.id), "then", int(go.id), "exec"])
		g.wires.append([int(looked.id), "ret", int(go.id), "target"]))
	note("hero compiles: %s %s" % [ed.compile_doc(ed.doc, true), ed.doc.errors])
	var ids := []
	for n in ed.cur_graph().nodes:
		if not n.kind == "event":
			ids.append(int(n.id))
	await wide_code(true)
	await frame(ids, 1.0)
	for i in ed._code.get_line_count():
		if ed._code.get_line(i).begins_with("func __ia_ui_accept_pressed"):
			ed._code.set_line_as_first_visible(maxi(i - 2, 0))
	await shot("interface_message", null, "work")
	await wide_code(false)

	# ---- a hand-written script turned into a Blueprint
	var patrol := TMP + "/patrol.gd"
	var f := FileAccess.open(patrol, FileAccess.WRITE)
	f.store_string(PATROL)
	f.close()
	var result: Dictionary = ed.convert_script(patrol)
	note("convert ok: %s  %s" % [result.get("ok", false), result.get("report", {})])
	if bool(result.get("ok", false)) and ed.convert_script_apply(patrol, result):
		await open_graph(patrol)
		await wide_code(true)
		var left := []
		var min_x := INF
		for c in view.get_children():
			if c is GraphNode:
				min_x = minf(min_x, c.position_offset.x)
		for c in view.get_children():
			if c is GraphNode and c.position_offset.x < min_x + 2300.0 and c.position_offset.y < 900.0:
				left.append(int(String(c.name).trim_prefix("n")))
		await frame(left, 1.0, 40.0)
		await shot("converted_script", null, "work")
		await wide_code(false)

	# ---- a game made of Blueprints, and a data table
	await open_graph("res://demo/game/BP_Player.gd")
	ed._select({"kind": "class"})
	await frame([], 1.0)
	await shot("game_blueprint", null, "graph")
	EditorInterface.edit_resource(load("res://demo/data/DT_Items.tres"))
	await wait(1.0)
	EditorInterface.set_distraction_free_mode(true)
	await wait(0.5)
	var rows: Tree = plugin.table_editor._tree
	if rows.get_root() and rows.get_root().get_child_count() > 1:
		rows.get_root().get_child(1).select(0)
		rows.item_selected.emit()
	var table_img: Image = await grab()
	var tr: Rect2 = plugin._screen.get_global_rect()
	tr.size.y = minf(tr.size.y, 470.0)
	save(table_img.get_region(Rect2i(tr)), "data_table")
	plugin.show_table(false)

	cleanup()
	await wait(1.0)
	note("done")
	tree.quit()


func _write(path: String, bp: Dictionary) -> void:
	var c: RefCounted = load("res://addons/blueprints/core/bp_compiler.gd").new()
	var code: String = c.compile(bp)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Model.build_source(code, bp))
	f.close()
