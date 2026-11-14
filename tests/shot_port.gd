extends RefCounted
## Editor self-test for the converted platformer: every converted script opens as a Schematic with no errors.
var tree: SceneTree
var ed

func note(msg: String) -> void:
	var path := "res://selftest_port.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()

func shot(name: String) -> void:
	await tree.create_timer(0.6).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://shot_%s.png" % name)

func run(p: EditorPlugin) -> void:
	tree = p.get_tree()
	ed = p.editor
	note("--- start")
	tree.create_timer(90.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(3.0).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	for path in ["res://objects/cloud.gd", "res://objects/coin.gd", "res://objects/platform_falling.gd", "res://scripts/audio.gd", "res://scripts/hud.gd", "res://scripts/view.gd", "res://scripts/player.gd"]:
		var ok: bool = ed.open_schematic(path)
		await tree.create_timer(0.5).timeout
		var nodes := 0
		var code_nodes := 0
		for g in ed.doc.bp.graphs:
			for n in g.nodes:
				nodes += 1
				if n.kind == "code":
					code_nodes += 1
		note("%s  %s  graphs %d nodes %d (code nodes %d) errors %s" % ["PASS" if ok and ed.doc.errors.is_empty() else "FAIL", path, ed.doc.bp.graphs.size(), nodes, code_nodes, str(ed.doc.errors)])
	# pictures of the player
	ed._view.zoom = 0.5
	ed._view.scroll_offset = Vector2(0, 0)
	await shot("player_events")
	ed.open_member_graph("handle_controls")
	await tree.create_timer(0.3).timeout
	ed._view.zoom = 0.5
	ed._view.scroll_offset = Vector2(0, 0)
	await shot("player_handle_controls")
	ed.open_member_graph("jump")
	await tree.create_timer(0.3).timeout
	ed._view.zoom = 0.8
	ed._view.scroll_offset = Vector2(0, 0)
	await shot("player_jump")
	ed.open_schematic("res://objects/coin.gd")
	ed.open_member_graph("_on_body_entered")
	await tree.create_timer(0.3).timeout
	ed._view.zoom = 0.7
	ed._view.scroll_offset = Vector2(0, 0)
	await shot("coin")
	for d in ed.docs:
		d.dirty = false
	note("done")
	tree.quit()
