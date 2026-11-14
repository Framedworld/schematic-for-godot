extends RefCounted
## Editor self-test: opens the demo schematic, exercises the UI and saves screenshots.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")

var plugin: EditorPlugin


func shot(name: String) -> void:
	EditorInterface.get_base_control().queue_redraw()
	await plugin.get_tree().create_timer(0.4).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	img.save_png("res://tests/out/%s.png" % name)
	note("saved " + name)


func note(msg: String) -> void:
	var f := FileAccess.open("res://tests/out/selftest.log", FileAccess.READ_WRITE if FileAccess.file_exists("res://tests/out/selftest.log") else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func run(p: EditorPlugin) -> void:
	plugin = p
	var tree := p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	tree.create_timer(45.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	var ed = p.editor
	note("open: %s" % ed.open_schematic("res://demo/SC_Demo.gd"))
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(1.0).timeout
	await shot("01_event_graph")
	# palette
	ed._view._open_palette(Vector2(500, 300), {})
	await tree.create_timer(0.5).timeout
	ed._palette._search.text = "delay"
	ed._palette._fill()
	note("palette results for 'delay': %d, total actions: %d" % [ed._palette.leaf_count(), ed._palette._actions.size()])
	ed._palette.hide()
	# context palette: drag from a float output
	var fnode = ed._view.get_node("n8")
	ed._view._on_connection_to_empty("n8", 0, Vector2(700, 600))
	await tree.create_timer(0.3).timeout
	note("float-context actions: %d  (title: %s)" % [ed._palette._actions.size(), ed._palette._title.text])
	ed._palette._search.text = "clamp"
	ed._palette._fill()
	var first: TreeItem = ed._palette.first_leaf()
	note("first 'clamp' hit: %s" % (first.get_text(0) if first else "<none>"))
	ed._palette._activate()
	await tree.create_timer(0.3).timeout
	var g: Dictionary = ed.cur_graph()
	note("after pick: nodes=%d last=%s wires_to_new=%s" % [g.nodes.size(), g.nodes[-1].kind, g.wires[-1]])
	# object-context palette: drag from a Node3D-ish pin is covered by class actions; exec context:
	ed._view._on_connection_to_empty("n1", 0, Vector2(300, 200))
	await tree.create_timer(0.2).timeout
	note("exec-context actions: %d" % ed._palette._actions.size())
	ed._palette.hide()
	# wire two existing nodes through the request path, then delete selection
	ed._view.spawn("print", {}, Vector2(1300, 200))
	await tree.create_timer(0.2).timeout
	var newest: int = int(ed.cur_graph().nodes[-1].id)
	ed._view._on_connection_request("n7", 0, "n%d" % newest, 0)
	await tree.create_timer(0.2).timeout
	note("compile after edits: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("code has extra print: %s" % ed.doc.preview.contains("print(\"Hello\")"))
	await shot("02_after_edits")
	var ur: UndoRedo = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	for i in 3:
		ur.undo()
	await tree.create_timer(0.3).timeout
	note("after 3 undos: nodes=%d" % ed.cur_graph().nodes.size())
	# opening through the editor's normal resource path (double-click in FileSystem)
	EditorInterface.set_main_screen_editor("3D")
	EditorInterface.edit_resource(load("res://demo/SC_Demo.gd"))
	await tree.create_timer(0.6).timeout
	note("edit_resource -> schematic screen visible: %s" % ed.is_visible_in_tree())
	EditorInterface.open_scene_from_path("res://demo/demo.tscn")
	await tree.create_timer(0.8).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.3).timeout
	note("host found: %s, component rows: %d" % [ed.find_host(), ed._components.get_root().get_child_count()])
	await shot("02_with_scene")
	# spawn via palette API + compile
	ed._view.spawn("branch", {}, Vector2(900, 500))
	await tree.create_timer(0.3).timeout
	note("compile ok: %s errors: %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	ed._right_tabs.current_tab = 1
	await shot("03_code")
	plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY).undo()
	await tree.create_timer(0.3).timeout
	ed._right_tabs.current_tab = 0
	# function graph
	if ed.doc.bp.graphs.size() > 1:
		ed.doc.graph_id = int(ed.doc.bp.graphs[1].id)
		ed._refresh_all()
		ed._select({"kind": "graph", "id": ed.doc.graph_id, "name": ed.doc.bp.graphs[1].name})
		await tree.create_timer(0.4).timeout
		await shot("04_function")
	ed.doc.dirty = false
	note("done")
	tree.quit()
