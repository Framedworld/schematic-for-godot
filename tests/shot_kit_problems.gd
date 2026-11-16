extends RefCounted
## Editor self-test for the Kits window (File > Kits...). With the fake "health" kit present and a second, deliberately
## broken kit written at run time (one good node, one with a bad pin type) and a third that needs a newer kit API,
## the window is opened through the function the menu calls. It must list the kits with their state and node
## counts, and the problems with their text and file path. The broken kit's file is then fixed and Reload Kits is
## pressed in the window: the problem goes and the count changes. recheck_all() must leave an open schematic that
## uses the fake kit's node compiling to the same code.
## The kits are written to res://tests/fake_kit/_shot (removed at the end, also by the watchdog); the scratch schematic
## is under res://tests/tmp/kitproblems/. The picture is saved from the editor's own viewport.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_kit_problems.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

const LOG := "res://tests/out/shot_kit_problems_checks.log"
const SHOT := "res://tests/out/shot_kit_problems.png"
const ROOT := "res://tests/fake_kit/_shot"
const BROKEN := ROOT + "/broken/schematic_kit.gd"
const TOO_NEW := ROOT + "/newer/schematic_kit.gd"
const DIR := "res://tests/tmp/kitproblems"
const PATH := DIR + "/SC_KitProblems.gd"

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0


func note(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE if FileAccess.file_exists(LOG) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(ok: bool, what: String, detail := "") -> void:
	if not ok:
		fails += 1
	note("%s  %s%s" % ["PASS" if ok else "FAIL", what, ("  [" + detail + "]") if detail != "" and not ok else ""])


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func write_file(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		remove_tree(path.path_join(sub))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


var _cleaned := false

func cleanup() -> void:
	if _cleaned:
		return
	_cleaned = true
	if ed != null:
		if ed._kits_dialog and is_instance_valid(ed._kits_dialog):
			ed._kits_dialog.hide()
		for i in range(ed.docs.size() - 1, -1, -1):
			if String(ed.docs[i].path).begins_with(DIR):
				ed.docs[i].dirty = false
				ed._close_doc(i)
	remove_tree(ROOT)
	remove_tree(DIR)
	Kits.set_kit_roots(PackedStringArray(Kits.DEFAULT_ROOTS))
	plugin.reload_kits()
	EditorInterface.get_resource_filesystem().scan()


## Every line of the window's list, with the depth of each, as text.
func listing() -> PackedStringArray:
	var out := PackedStringArray()
	var tl: Tree = ed._kits_tree
	if tl == null or not is_instance_valid(tl):
		return out
	walk(tl.get_root(), 0, out)
	return out


func walk(it: TreeItem, depth: int, out: PackedStringArray) -> void:
	for c in it.get_children():
		out.append("  ".repeat(depth) + c.get_text(0))
		walk(c, depth + 1, out)


func has_line(lines: PackedStringArray, needle: String) -> bool:
	for l in lines:
		if l.contains(needle):
			return true
	return false


func broken_text(fixed: bool) -> String:
	var head := "const KIT_API := 1\nconst KIT_NAME := \"Broken\"\nconst KIT_VERSION := \"0.3\"\n\nstatic func register(kit) -> void:\n"
	var text := head + "\tkit.template(\"fine\", {\"title\": \"Fine\", \"pure\": true, \"outs\": [[\"ret\", \"Value\", \"int\"]], \"exprs\": {\"ret\": \"42\"}})\n"
	if fixed:
		text += "\tkit.template(\"typed\", {\"title\": \"Typed\", \"ins\": [[\"x\", \"X\", \"int\", \"\"]], \"lines\": [\"print({x})\"]})\n"
	else:
		text += "\tkit.template(\"bad_type\", {\"title\": \"Bad Type\", \"ins\": [[\"x\", \"X\", \"Intt\", \"\"]], \"lines\": [\"print({x})\"]})\n"
	return text


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(120.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Schematic")

	# --- the kits: the fake one, a broken one, one that needs a newer API
	for f in ["schematic_kit.gd", "health.gd"]:
		write_file(ROOT + "/health/" + f, FileAccess.get_file_as_string("res://tests/fake_kit/health/" + f))
	write_file(BROKEN, broken_text(false))
	write_file(TOO_NEW, "const KIT_API := 99\n\nstatic func register(kit) -> void:\n\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	Kits.set_kit_roots(PackedStringArray([ROOT]))
	plugin.reload_kits()
	check(R.templates.has("health:heal") and R.templates.has("broken:fine") and not R.templates.has("broken:bad_type"), "the kits are loaded; the bad node is skipped")

	# --- an open schematic that uses the fake kit's node
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "target", "type": "Node", "default": "", "export": true, "category": "", "tooltip": ""})
	write_file(PATH, Model.build_source(Compiler.new().compile(bp), bp))
	check(ed.open_schematic(PATH), "a schematic opens")
	await frames(6)
	ed.mutate("Add heal", func():
		var g: Dictionary = ed.cur_graph()
		var heal := Model.add_node(g, "tpl", Vector2(360, 80), {"id": "health:heal"})
		var get_t := Model.add_node(g, "var_get", Vector2(100, 260), {"name": "target"})
		g.wires.append_array([[g.nodes[0].id, "then", heal.id, "exec"], [get_t.id, "value", heal.id, "target"]]))
	await frames(4)
	check(ed.compile_doc(ed.doc, true) and ed.doc.errors.filter(func(e): return not e.w).is_empty(), "it compiles with the fake kit's node", str(ed.doc.errors))
	var code_before := String(ed.doc.code)
	check(code_before.contains("target.heal(10)"), "the code has the kit's line", code_before)

	# --- the window, opened through the function the menu calls
	check(ed._kits_dialog == null or not is_instance_valid(ed._kits_dialog) or not ed._kits_dialog.visible, "the window is not built before it is opened")
	var file_menu: PopupMenu = null
	for mb in ed._toolbar.get_children():
		if mb is MenuButton and (mb as MenuButton).get_popup().item_count >= 4 and (mb as MenuButton).get_popup().get_item_text(3) == "Kits...":
			file_menu = (mb as MenuButton).get_popup()
	check(file_menu != null, "the File menu has a 'Kits...' entry")
	if file_menu != null:
		file_menu.id_pressed.emit(3)   # what choosing the entry does
	else:
		ed.show_kits_dialog()
	await frames(6)
	check(ed._kits_dialog != null and ed._kits_dialog.visible, "the Kits window is open")
	var lines := listing()
	note("    list:\n        " + "\n        ".join(lines))
	check(has_line(lines, "health") and has_line(lines, "Health 1.0.0") and has_line(lines, "3 nodes") and has_line(lines, "active"), "it lists the fake kit: addon, name, version, 3 nodes, active")
	check(has_line(lines, "broken") and has_line(lines, "Broken 0.3") and has_line(lines, "1 node   -"), "it lists the broken kit with the one node that loaded")
	check(has_line(lines, "Intt") and has_line(lines, "bad_type"), "it gives the bad node's problem in words", "\n".join(lines))
	check(has_line(lines, BROKEN), "it gives the broken kit's file path")
	check(has_line(lines, "newer") and has_line(lines, "kit API 99"), "it lists the kit that needs a newer API and says why it is not active")
	check(has_line(lines, "res://tests/fake_kit/_shot/health/schematic_kit.gd"), "it gives the good kit's file path")

	# --- the picture
	await frames(6)
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(SHOT)
	note("saved %s" % SHOT)
	# the window may be a window of its own (not part of the editor's viewport), so its own picture is saved too
	ed._kits_dialog.get_texture().get_image().save_png(SHOT.replace(".png", "_window.png"))
	note("saved %s" % SHOT.replace(".png", "_window.png"))

	# --- fix the broken kit's file, press Reload Kits in the window
	write_file(BROKEN, broken_text(true))
	var btn: Button = ed._kits_dialog.find_child("ReloadKits", true, false)
	check(btn != null, "the window has a Reload Kits button")
	if btn:
		btn.pressed.emit()
	await frames(6)
	lines = listing()
	note("    list after reload:\n        " + "\n        ".join(lines))
	check(R.templates.has("broken:typed") and R.kit_problems.filter(func(q): return String(q.addon) == "broken").is_empty(), "the reload took the fixed file", str(R.kit_problems))
	check(not has_line(lines, "Intt") and not has_line(lines, "bad_type"), "the problem is gone from the list", "\n".join(lines))
	check(has_line(lines, "2 nodes"), "the broken kit now shows 2 nodes", "\n".join(lines))
	check(has_line(lines, "kit API 99"), "the newer-API kit is still listed with its reason")

	# --- recheck_all
	ed.recheck_all()
	await frames(3)
	check(ed.doc.errors.filter(func(e): return not e.w).is_empty(), "after recheck_all the open schematic has no errors", str(ed.doc.errors))
	check(String(ed.doc.preview) == code_before, "it compiles to the same code as before", String(ed.doc.preview))
	check(not ed.doc.dirty, "recheck_all does not mark the document as changed")
	var heal_node = ed._view.get_node_or_null("n%d" % int(ed.cur_graph().nodes[-2].id))
	check(heal_node != null and String(heal_node.title) == "Heal", "the Heal node is drawn as a normal node", str(heal_node.title if heal_node else "-"))

	cleanup()
	await tree.create_timer(1.5).timeout
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT)), "the written kit folders are gone")
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
