extends RefCounted
## Editor self-test for macros and timelines.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_macros.gd

var plugin: EditorPlugin


func shot(name: String) -> void:
	EditorInterface.get_base_control().queue_redraw()
	await plugin.get_tree().create_timer(0.4).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	img.save_png("res://tests/out/%s.png" % name)
	note("saved " + name)


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_macros.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
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
	await tree.create_timer(0.8).timeout
	# select the demo's timeline node -> details shows the track editor
	var g: Dictionary = ed.cur_graph()
	var tl_id := -1
	for n in g.nodes:
		if n.kind == "timeline":
			tl_id = int(n.id)
	ed._view.focus_node(tl_id)
	await tree.create_timer(0.4).timeout
	await shot("05_timeline")
	# add a key and a track through the same paths the buttons use
	var tl: Dictionary = {}
	for n in ed.cur_graph().nodes:
		if n.kind == "timeline":
			tl = n
	ed.mutate("Add Track", func(): tl.p.tracks.append({"name": "Tint", "type": "Color", "smooth": false, "keys": [[0.0, "Color(1, 1, 1, 1)"], [2.0, "Color(1, 0, 0, 1)"]]}))
	ed._refresh_details()
	await tree.create_timer(0.3).timeout
	note("compile with 2 tracks: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("code samples Tint: %s" % ed.doc.preview.contains("_Tint = __sc_sample("))
	await shot("06_timeline_two_tracks")
	# macro graph
	ed.open_member_graph("LogTwice")
	ed._select({"kind": "graph", "id": int(ed.doc.graph_id), "name": "LogTwice"})
	await tree.create_timer(0.4).timeout
	await shot("07_macro_graph")
	# new macro via the + button path, then use it and rename it
	ed._on_member_button(null, 0, ed.SEC_MACROS, 0)
	await tree.create_timer(0.3).timeout
	var new_name: String = ed.cur_graph().name
	note("new macro: %s kind=%s nodes=%d" % [new_name, ed.cur_graph().kind, ed.cur_graph().nodes.size()])
	ed.doc.graph_id = int(ed.doc.bp.graphs[0].id)
	ed._refresh_all()
	ed._view.spawn("macro", {"name": new_name}, Vector2(1400, 900))
	await tree.create_timer(0.3).timeout
	ed._rename_member("macro", new_name, "Renamed")
	var last: Dictionary = ed.cur_graph().nodes[-1]
	note("call node follows rename: %s" % (last.kind == "macro" and last.p.name == "Renamed"))
	note("compile with empty macro: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("macros now: %s" % [ed.doc.bp.graphs.filter(func(x): return x.kind == "macro").map(func(x): return x.name)])
	ed.doc.dirty = false
	note("done")
	tree.quit()
