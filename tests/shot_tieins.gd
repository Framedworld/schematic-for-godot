extends RefCounted
## Editor self-test for Promote to Variable and the Godot tie-in nodes in the action menu.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_tieins.gd

var plugin: EditorPlugin


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_tieins.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func first_hit(ed, query: String) -> String:
	ed._palette._search.text = query
	ed._palette._fill()
	var it: TreeItem = ed._palette.first_leaf()
	return it.get_text(0) if it else "<none>"


func run(p: EditorPlugin) -> void:
	plugin = p
	var tree := p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	tree.create_timer(40.0).timeout.connect(func():
		note("watchdog quit")
		p.editor.doc.dirty = false
		tree.quit())
	await tree.create_timer(2.5).timeout
	var ed = p.editor
	note("open: %s" % ed.open_blueprint("res://demo/BP_Demo.gd"))
	EditorInterface.set_main_screen_editor("Blueprint")
	await tree.create_timer(0.8).timeout
	ed._view._open_palette(Vector2(500, 300), {})
	await tree.create_timer(0.3).timeout
	note("'get all actors' -> %s" % first_hit(ed, "get all actors"))
	note("'open level' -> %s" % first_hit(ed, "open level"))
	note("'destroy actor' -> %s" % first_hit(ed, "destroy actor"))
	note("'set timer' -> %s" % first_hit(ed, "set timer"))
	note("'add' -> %s" % first_hit(ed, "add"))
	note("'multiply' -> %s" % first_hit(ed, "multiply"))
	note("'keyboard w' -> %s" % first_hit(ed, "keyboard w"))
	note("'multigate' -> %s" % first_hit(ed, "multigate"))
	note("'format text' -> %s" % first_hit(ed, "format text"))
	ed._palette.hide()
	# Promote the Delay node's Duration input (node 5, input port 1) to a variable.
	var vars_before: int = ed.doc.bp.variables.size()
	ed._view._on_connection_from_empty("n5", 1, Vector2(600, 400))
	await tree.create_timer(0.3).timeout
	note("promote offered first: %s" % first_hit(ed, "promote"))
	ed._palette._activate()
	await tree.create_timer(0.3).timeout
	var nv: Dictionary = ed.doc.bp.variables[-1]
	var g: Dictionary = ed.cur_graph()
	note("variables %d -> %d, new: %s : %s = %s, wire: %s" % [vars_before, ed.doc.bp.variables.size(), nv.name, nv.type, nv.default, g.wires[-1]])
	note("compile: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("code uses variable: %s" % ed.doc.preview.contains("create_timer(%s)" % nv.name))
	ed.doc.dirty = false
	note("done")
	tree.quit()
