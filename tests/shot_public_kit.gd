extends RefCounted
## Editor self-test for public kits (docs/KITS.md): with the fake "health" kit present, its nodes are found in
## the palette search, added to a graph and compiled with no errors. Then the kit file is deleted and the editor's
## own file system rescan (filesystem_changed, the signal the plugin listens to) reloads the kits: the nodes
## become placeholders that keep their wires. The file is put back, the rescan reloads again, and the nodes are
## normal nodes compiling to the same code.
## The kit is copied to res://tests/fake_kit/_shot/health/ (a folder the editor scans; tests/tmp is not
## scanned) and the scan is pointed at res://tests/fake_kit/_shot. Both are undone at the end, also by the
## watchdog. The scratch schematic lives under res://tests/tmp/publickit/.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_public_kit.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

const LOG := "res://tests/out/shot_public_kit_checks.log"
const SHOT := "res://tests/out/shot_public_kit.png"
const ROOT := "res://tests/fake_kit/_shot"
const KIT := ROOT + "/health/schematic_kit.gd"
const DIR := "res://tests/tmp/publickit"
const PATH := DIR + "/SC_KitUser.gd"

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0
var kit_ids := {}     # template id -> node id
var wires_before: Array = []
var code_before := ""


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
		for i in range(ed.docs.size() - 1, -1, -1):
			if String(ed.docs[i].path).begins_with(DIR):
				ed.docs[i].dirty = false
				ed._close_doc(i)
	remove_tree(ROOT)
	remove_tree(DIR)
	Kits.set_kit_roots(PackedStringArray(Kits.DEFAULT_ROOTS))
	plugin.reload_kits()
	EditorInterface.get_resource_filesystem().scan()


func gnode(id: int):
	return ed._view.get_node_or_null("n%d" % id)


func wire_keys() -> Array:
	var out: Array = ed.cur_graph().wires.map(func(w): return str([int(w[0]), String(w[1]), int(w[2]), String(w[3])]))
	out.sort()
	return out


func drawn_kit_wires() -> int:
	var names := kit_ids.values().map(func(id): return "n%d" % id)
	var count := 0
	for c in ed._view.get_connection_list():
		if String(c.from_node) in names or String(c.to_node) in names:
			count += 1
	return count


## Finds a palette entry by search text and template id, and picks it the way a click does.
func pick(query: String, tpl_id: String, at: Vector2) -> int:
	ed._view._open_palette(at, {})
	await frames(3)
	ed._palette._search.text = query
	ed._palette._fill()
	await frames(2)
	var it: TreeItem = ed._palette.first_leaf()
	var found: TreeItem = null
	while it:
		var act: Variant = it.get_metadata(0)
		if act is Dictionary and act.k == "tpl" and String(act.p.get("id", "")) == tpl_id:
			found = it
			break
		it = it.get_next_in_tree()
	check(found != null, "searching '%s' in the palette finds the kit node %s" % [query, tpl_id])
	if found == null:
		ed._palette.hide()
		return -1
	note("    palette: '%s' under '%s'" % [found.get_text(0), found.get_parent().get_text(0)])
	var count: int = ed.cur_graph().nodes.size()
	found.select(0)
	ed._palette._activate()
	await frames(3)
	check(ed.cur_graph().nodes.size() == count + 1, "picking it adds the node to the graph")
	return int(ed.cur_graph().nodes[-1].id)


## Waits for the plugin's own reload (the rescan's filesystem_changed, debounced) to reach `want` for health:heal.
func wait_for_kit(want: bool) -> float:
	EditorInterface.get_resource_filesystem().scan()
	var waited := 0.0
	while waited < 20.0 and R.templates.has("health:heal") != want:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	await frames(4)
	return waited


func fit_view() -> void:
	var g: Dictionary = ed.cur_graph()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		lo = Vector2(minf(lo.x, float(n.x)), minf(lo.y, float(n.y)))
		hi = Vector2(maxf(hi.x, float(n.x) + 260.0), maxf(hi.y, float(n.y) + 180.0))
	var view = ed._view
	var z := minf(1.0, minf((view.size.x - 60.0) / (hi.x - lo.x), (view.size.y - 60.0) / (hi.y - lo.y)))
	view.zoom = maxf(z, 0.5)
	view.scroll_offset = lo * view.zoom - Vector2(30, 30)


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(180.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Schematic")

	# --- the kit is there
	for f in ["schematic_kit.gd", "health.gd"]:
		write_file(ROOT + "/health/" + f, FileAccess.get_file_as_string("res://tests/fake_kit/health/" + f))
	Kits.set_kit_roots(PackedStringArray([ROOT]))
	plugin.reload_kits()
	check(R.templates.has("health:heal") and R.templates.has("health:is_alive") and R.templates.has("health:wait_until_dead"), "the fake kit's nodes are registered", str(R.kit_problems))
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.5).timeout

	# --- a schematic that uses them, built through the palette
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "target", "type": "Node", "default": "", "export": true, "category": "", "tooltip": ""})
	bp.variables.append({"name": "alive", "type": "bool", "default": "false", "export": false, "category": "", "tooltip": ""})
	bp.graphs[0].nodes[1].y = 560.0
	write_file(PATH, Model.build_source(Compiler.new().compile(bp), bp))
	check(ed.open_schematic(PATH), "a new schematic opens")
	await frames(6)
	var heal := await pick("heal", "health:heal", Vector2(380, 80))
	var is_alive := await pick("is alive", "health:is_alive", Vector2(560, 300))
	var wait := await pick("wait until dead", "health:wait_until_dead", Vector2(1000, 80))
	kit_ids = {"health:heal": heal, "health:is_alive": is_alive, "health:wait_until_dead": wait}
	if heal < 0 or is_alive < 0 or wait < 0:
		cleanup()
		note("FAIL  verdict: the kit nodes were not all found")
		tree.quit()
		return
	ed.mutate("Wire kit nodes", func():
		var g: Dictionary = ed.cur_graph()
		var ready: Dictionary = g.nodes[0]
		var get_t := Model.add_node(g, "var_get", Vector2(100, 260), {"name": "target"})
		var set_a := Model.add_node(g, "var_set", Vector2(760, 80), {"name": "alive"})
		for n in g.nodes:
			if int(n.id) == heal:
				n.x = 360.0
				n.y = 80.0
			elif int(n.id) == is_alive:
				n.x = 440.0
				n.y = 320.0
			elif int(n.id) == wait:
				n.x = 1080.0
				n.y = 80.0
		g.wires.append_array([[ready.id, "then", heal, "exec"], [get_t.id, "value", heal, "target"], [heal, "then", set_a.id, "exec"],
			[get_t.id, "value", is_alive, "target"], [is_alive, "ret", set_a.id, "value"], [set_a.id, "then", wait, "exec"],
			[get_t.id, "value", wait, "target"]]))
	await frames(4)
	check(ed.compile_doc(ed.doc, true), "it compiles")
	check(ed.doc.errors.filter(func(e): return not e.w).is_empty(), "with no errors", str(ed.doc.errors))
	code_before = String(ed.doc.code)
	note("    code:\n" + code_before)
	check(code_before.contains("target.heal(10)") and code_before.contains("alive = (target.hp > 0)") and code_before.contains("await target.died"), "the code has the kit's lines", code_before)
	check(Model.load_file(PATH).graphs[0].nodes.any(func(n): return n.kind == "tpl" and String(n.p.get("id", "")) == "health:heal"), "the saved graph stores the node as health:heal")
	wires_before = wire_keys()
	var drawn := drawn_kit_wires()
	check(drawn == 7, "the canvas draws the 7 wires of the kit nodes (%d)" % drawn)
	var gh = gnode(heal)
	check(gh != null and String(gh.title) == "Heal", "the Heal node shows its title", str(gh.title if gh else "-"))

	# --- the picture
	fit_view()
	await frames(6)
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(SHOT)
	note("saved %s" % SHOT)

	# --- the kit goes away: the plugin's own watch reloads
	DirAccess.remove_absolute(ProjectSettings.globalize_path(KIT))
	var waited := await wait_for_kit(false)
	check(not R.templates.has("health:heal"), "after deleting the kit file, the rescan (filesystem_changed) reloads the kits without it (%.2fs)" % waited)
	gh = gnode(heal)
	check(gh != null and String(gh.title).contains("missing"), "the Heal node is a placeholder", str(gh.title if gh else "-"))
	var gw = gnode(wait)
	check(gw != null and String(gw.title).contains("missing"), "the Wait Until Dead node is a placeholder", str(gw.title if gw else "-"))
	check(wire_keys() == wires_before, "every wire is still in the model")
	check(drawn_kit_wires() == drawn, "every wire of the kit nodes is still drawn (%d)" % drawn_kit_wires())
	var errs: Array = ed.doc.errors.filter(func(e): return not e.w)
	check(not errs.is_empty() and errs.all(func(e): return String(e.m).contains("not installed or enabled")), "the results name the missing addon", str(errs.map(func(e): return e.m)))
	check(not ed.doc.dirty, "the reload does not mark the document as changed")

	# --- the kit comes back
	write_file(KIT, FileAccess.get_file_as_string("res://tests/fake_kit/health/schematic_kit.gd"))
	waited = await wait_for_kit(true)
	check(R.templates.has("health:heal"), "after putting the file back, the rescan reloads the kit (%.2fs)" % waited)
	gh = gnode(heal)
	check(gh != null and String(gh.title) == "Heal", "the Heal node is a normal node again", str(gh.title if gh else "-"))
	check(wire_keys() == wires_before and drawn_kit_wires() == drawn, "with every wire")
	check(ed.compile_doc(ed.doc, false) and String(ed.doc.preview) == code_before, "it compiles to the same code as before")

	cleanup()
	await tree.create_timer(1.5).timeout
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT)), "the copied kit folder is gone")
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
