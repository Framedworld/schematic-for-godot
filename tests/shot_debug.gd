extends RefCounted
## Editor self-test for node breakpoints: sets one, runs the demo scene, expects the game to stop on that node.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_debug.gd

var plugin: EditorPlugin


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_debug.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func shot(name: String) -> void:
	EditorInterface.get_base_control().queue_redraw()
	await plugin.get_tree().create_timer(0.4).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/%s.png" % name)
	note("saved " + name)


func cleanup(ed) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if not ed.doc.is_empty():
		ed.doc.dirty = false


func run(p: EditorPlugin) -> void:
	plugin = p
	var tree := p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	var ed = p.editor
	tree.create_timer(50.0).timeout.connect(func():
		note("watchdog quit")
		cleanup(ed)
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	note("open: %s" % ed.open_schematic("res://demo/SC_Demo.gd"))
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	# node 3 is the first Print String after Event Ready; node 8 is a pure variable getter
	ed.toggle_breakpoints([8])
	note("pure node rejected: %s" % ed._breaks("res://demo/SC_Demo.gd").is_empty())
	ed.toggle_breakpoints([3])
	var lines: PackedStringArray = p._get_breakpoints()
	note("breakpoints: %s" % [lines])
	if lines.size() == 1:
		var ln := int(lines[0].get_slice(":", lines[0].get_slice_count(":") - 1))
		var text := FileAccess.get_file_as_string("res://demo/SC_Demo.gd").split("\n")[ln - 1]
		note("that line is: %s" % text.strip_edges())
	await shot("08_breakpoint")
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var waited := 0.0
	while ed._paused.is_empty() and waited < 20.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	note("paused at: %s after %.1fs" % [ed._paused, waited])
	await tree.create_timer(0.5).timeout
	note("schematic screen visible while paused: %s" % ed.is_visible_in_tree())
	await shot("09_paused_on_node")
	for s in p._debugger.get_sessions():
		if s.is_active():
			note("session breaked: %s" % s.is_breaked())
			s.send_message("continue", [])
	await tree.create_timer(1.0).timeout
	note("after continue, paused cleared: %s" % ed._paused.is_empty())
	EditorInterface.stop_playing_scene()
	await tree.create_timer(0.8).timeout
	# Live execution flow: turn it on, run again without breakpoints, expect the game to report running nodes.
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = true)
	ed.compile_doc(ed.doc, true)
	ed.flow_hits = 0
	ed.flow_edges = 0
	EditorInterface.set_main_screen_editor("Schematic")
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	waited = 0.0
	while ed.flow_hits == 0 and waited < 15.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	await tree.create_timer(0.6).timeout
	note("execution flow reports received: %d node hits after %.1fs" % [ed.flow_hits, waited])
	# live values: the wired input pins of running nodes report what they received
	var shown := 0
	var sample := ""
	for c in ed._view.get_children():
		if c is GraphNode:
			for lab in c.find_children("*", "Label", true, false):
				if lab.has_meta("watch"):
					shown += 1
					if sample == "":
						sample = "%s: %s" % [c.title, lab.text]
	note("%s  live values: %d pin values received, %d shown on pins (e.g. %s)" % ["PASS" if ed.watch_hits > 0 and shown > 0 else "FAIL", ed.watch_hits, shown, sample])
	note("%s  followed wires: %d reported, %d animated now" % ["PASS" if ed.flow_edges > 0 and ed._view.flow_overlay.count() > 0 else "FAIL", ed.flow_edges, ed._view.flow_overlay.count()])
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/12_live_values.png")
	EditorInterface.stop_playing_scene()
	await tree.create_timer(0.8).timeout
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = false)
	ed.compile_doc(ed.doc, true)
	note("flow off again, file has no trace calls: %s" % (not FileAccess.get_file_as_string("res://demo/SC_Demo.gd").contains("__sc_trace(")))
	var head := FileAccess.get_file_as_string("res://demo/SC_Demo.gd")
	note("%s  nothing about the icon is written into the script" % ["PASS" if not head.contains("@icon") else "FAIL"])
	EditorInterface.get_file_system_dock().navigate_to_path("res://demo/SC_Demo.gd")
	await tree.create_timer(1.5).timeout
	var sel: TreeItem = plugin._fs_tree.get_selected()
	note("%s  the FileSystem dock shows the Schematic icon on SC_Demo.gd (%d rows marked)" % ["PASS" if sel != null and String(sel.get_metadata(0)) == "res://demo/SC_Demo.gd" and sel.get_icon(0) == plugin.SC_ICON else "FAIL", plugin.fs_icons_set])
	var plain: TreeItem = (sel.get_next() if sel.get_next() else sel.get_prev()) if sel else null
	note("%s  other files keep their own icon (%s)" % ["PASS" if plain != null and plain.get_icon(0) != plugin.SC_ICON else "FAIL", plain.get_text(0) if plain else "-"])
	await shot("20_schematic_icon")
	var after: TreeItem = plugin._fs_tree.get_selected()
	note("%s  the icon is still there after the dock's previews arrived" % ["PASS" if after != null and after.get_icon(0) == plugin.SC_ICON else "FAIL"])
	cleanup(ed)
	note("done")
	tree.quit()
