extends RefCounted
## Editor self-test: the Convert to Blueprint command on a hand-written script.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_import.gd
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const DIR := "res://demo/tmp_import"
const SOURCE := """extends Node2D

signal landed(height)

@export var speed := 120.0
var fuel = 10
var log: Array = []

func _ready():
	position = Vector2(10, 20)
	burn(3)

func _process(delta):
	position.x += speed * delta
	if fuel <= 0:
		landed.emit(position.y)

func burn(amount: int):
	fuel -= amount
	log.append("burn %d" % amount)
	match amount:
		3:
			log.append("three")
"""

var passed := 0
var failed := 0
var tree: SceneTree
var ed


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_import.log"
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


func run(p: EditorPlugin) -> void:
	tree = p.get_tree()
	ed = p.editor
	note("--- start")
	tree.create_timer(70.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Blueprint")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var path := DIR + "/lander.gd"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(SOURCE)
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.5).timeout

	var result: Dictionary = ed.convert_script(path)
	check("a script converts and the result compiles", bool(result.ok), str(result.get("errors", [])))
	check("nothing is written until it is applied", FileAccess.get_file_as_string(path) == SOURCE and not FileAccess.file_exists(path + ".orig"))
	if result.ok:
		var rep: Dictionary = result.report
		check("the report counts nodes and carried-over code", int(rep.lines) == 10 and int(rep.as_code) == 3 and rep.notes.any(func(n): return String(n).contains("match")), "%d lines, %d as code" % [rep.lines, rep.as_code])

	# the dialog explains what will happen before anything changes
	ed.convert_script_dialog(path)
	await frames(8)
	var dlg: ConfirmationDialog = null
	for c in EditorInterface.get_base_control().get_children():
		if c is ConfirmationDialog and c.visible and c.title == "Convert to Blueprint":
			dlg = c
	check("Convert to Blueprint asks first and says what happens", dlg != null and dlg.dialog_text.contains("7 of 10 lines become nodes") and dlg.dialog_text.contains("lander.gd.orig"), dlg.dialog_text.get_slice("\n", 0) if dlg else "")
	if dlg:
		await tree.create_timer(0.4).timeout
		(dlg as Window).get_texture().get_image().save_png("res://tests/out/look_19_convert_dialog.png")
		dlg.get_ok_button().pressed.emit()
		await frames(10)
	var text := FileAccess.get_file_as_string(path)
	check("confirming replaces the file with a Blueprint and keeps the original", Model.is_blueprint_source(text) and FileAccess.get_file_as_string(path + ".orig") == SOURCE)
	check("the Blueprint is open with no errors", ed.doc.path == path and ed.doc.errors.is_empty(), str(ed.doc.errors))
	var kinds := {}
	for g in ed.doc.bp.graphs:
		for n in g.nodes:
			kinds[n.kind] = int(kinds.get(n.kind, 0)) + 1
	check("it has events, a function, a dispatcher call and one code node", int(kinds.get("event", 0)) == 2 and int(kinds.get("emit", 0)) == 1 and int(kinds.get("code", 0)) == 1
		and ed.doc.bp.graphs.size() == 2 and ed.doc.bp.dispatchers.size() == 1 and ed.doc.bp.variables.size() == 3, str(kinds))
	check("exports survive", text.contains("@export var speed: float = 120.0"))
	ed.open_member_graph("burn")
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/look_20_converted.png")
	var again: Dictionary = ed.convert_script(path)
	check("a Blueprint is not converted twice", not bool(again.ok))

	for i in range(ed.docs.size() - 1, -1, -1):
		if String(ed.docs[i].path).begins_with(DIR):
			ed.docs[i].dirty = false
			ed._close_doc(i)
	var dir := DirAccess.open(DIR)
	if dir:
		for file in dir.get_files():
			dir.remove(file)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.0).timeout
	note("passed %d, failed %d" % [passed, failed])
	tree.quit()
