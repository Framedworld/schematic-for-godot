extends RefCounted
## Editor self-test: the New Blueprint picker offers the starter blueprints and a picked one opens, compiles
## and draws. Run: godot --path . --editor -- --bp-selftest=res://tests/shot_starters.gd
const Starters := preload("res://addons/blueprints/core/bp_starters.gd")
const DIR := "res://demo/tmp_starters"

var passed := 0
var failed := 0
var tree: SceneTree
var ed


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_starters.log"
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


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func picker() -> ItemList:
	for c in EditorInterface.get_base_control().get_children():
		if c is PopupPanel and c.visible:
			var lists := c.find_children("*", "ItemList", true, false)
			if not lists.is_empty():
				return lists[0]
	return null


func file_dialog() -> EditorFileDialog:
	for c in EditorInterface.get_base_control().get_children():
		if c is EditorFileDialog and c.visible:
			return c
	return null


func close_popups() -> void:
	for c in EditorInterface.get_base_control().get_children():
		if (c is PopupPanel or c is EditorFileDialog) and c.visible:
			c.hide()
	await frames(4)


func run(p: EditorPlugin) -> void:
	tree = p.get_tree()
	ed = p.editor
	note("--- start")
	tree.create_timer(80.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Blueprint")
	await tree.create_timer(0.6).timeout
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))

	# 1. New Blueprint offers Empty plus every starter
	ed.new_blueprint_dialog()
	await frames(8)
	var list := picker()
	check("New Blueprint opens the starter picker", list != null)
	if list:
		check("picker lists Empty and all %d starters" % Starters.LIST.size(), list.item_count == Starters.LIST.size() + 1 and list.get_item_text(0).begins_with("Empty Blueprint"), "%d items, first '%s'" % [list.item_count, list.get_item_text(0)])
		check("each starter says what it does", list.get_item_tooltip(2).contains("gravity") and list.get_item_tooltip(2).contains("CharacterBody2D"), list.get_item_tooltip(2))
		(list.get_window() as Window).get_texture().get_image().save_png("res://tests/out/look_15_starters.png")
		# typing narrows the list
		var search: LineEdit = list.get_parent().find_children("*", "LineEdit", true, false)[0]
		search.text = "pickup"
		search.text_changed.emit("pickup")
		await frames(2)
		check("search narrows the picker", list.item_count == 2 and list.get_item_text(0) == "Pickup (2D)", "%d items" % list.item_count)
		# picking one goes on to the save dialog with a sensible name
		list.item_activated.emit(0)
		await frames(10)
		var fd := file_dialog()
		check("picking a starter opens the save dialog", fd != null and fd.title.contains("Area2D") and fd.current_file == "BP_Pickup.gd", (fd.title + " / " + fd.current_file) if fd else "")
	await close_popups()

	# 2. every starter can be created through the editor, opens without errors and draws
	for s in Starters.LIST:
		ed._new_blueprint_file(String(s.parent), null, String(s.id))
		await frames(6)
		var fd := file_dialog()
		if fd == null:
			check("%s: save dialog" % s.name, false)
			continue
		var path := "%s/BP_T_%s.gd" % [DIR, s.id]
		fd.file_selected.emit(path)
		fd.hide()
		await frames(10)
		var drawn := 0
		for c in ed._view.get_children():
			if c is GraphElement and c.visible:
				drawn += 1
		var text := FileAccess.get_file_as_string(path)
		check("%s: created, open, no errors" % s.name, ed.doc.path == path and ed.doc.errors.is_empty() and drawn == ed.cur_graph().nodes.size() and text.contains("extends " + String(s.parent)),
			"%d nodes drawn, errors %s" % [drawn, str(ed.doc.errors)])
		if s.id in ["platformer_2d", "pickup_2d", "health"]:
			ed._view.zoom = 0.36 if s.id == "platformer_2d" else 0.8
			await frames(2)
			ed._view.scroll_offset = Vector2(-10, -40) * ed._view.zoom if s.id != "platformer_2d" else Vector2(0, 40)
			await tree.create_timer(0.5).timeout
			EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/look_16_starter_%s.png" % s.id)

	# 3. attaching to a node offers only what fits it
	var body := CharacterBody2D.new()
	body.name = "Hero"
	EditorInterface.get_base_control().add_child(body)
	ed.new_blueprint_dialog(body)
	await frames(8)
	list = picker()
	check("attaching to a CharacterBody2D offers the two 2D characters", list != null and list.item_count == 3 and list.get_item_text(0) == "Empty Blueprint (CharacterBody2D)", ("%d items" % list.item_count) if list else "no picker")
	await close_popups()
	var sprite := Sprite2D.new()
	sprite.name = "Pic"
	EditorInterface.get_base_control().add_child(sprite)
	ed.new_blueprint_dialog(sprite)
	await frames(8)
	var direct := file_dialog()
	check("attaching to a node with no starters goes straight to the save dialog", picker() == null and direct != null and direct.current_file == "BP_Pic.gd", direct.current_file if direct else "")
	await close_popups()
	body.queue_free()
	sprite.queue_free()

	# clean up: close what was opened, delete the files
	for i in range(ed.docs.size() - 1, -1, -1):
		if String(ed.docs[i].path).begins_with(DIR):
			ed.docs[i].dirty = false
			ed._close_doc(i)
	var dir := DirAccess.open(DIR)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.0).timeout
	note("passed %d, failed %d" % [passed, failed])
	tree.quit()
