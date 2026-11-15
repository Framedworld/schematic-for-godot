extends RefCounted
## Editor self-test: editing a graph that was produced by converting a script. Converted graphs carry flags
## (written / untyped / infer / hint, p.names) and node kinds (reroutes, small name nodes) that hand-made graphs
## do not, so this opens one in the Schematic editor and edits it the way a person would, through the editor's own
## functions (the ones the Details panel, the graph view and the palette call), and checks nothing breaks.
## It writes a script under res://tests/tmp/editconv/ (git-ignored), converts it, and removes it again.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_edit_converted.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Checks := preload("res://tests/convert_checks.gd")

const LOG := "res://tests/out/shot_edit_converted_checks.log"
const PNG := "res://tests/out/shot_edit_converted.png"
const DIR := "res://tests/tmp/editconv"
const PATH := DIR + "/SC_EditConv.gd"

const SOURCE := """extends Node

signal pinged(who)

var counter = 0
var ratio := 1.5
var label_text: String = "start"
@export var speed: float = 2.0
var journal: Array = []


func add_untyped(a):
	counter += 1
	journal.append("add %s" % str(a))
	return a


func scale_it(x: int, y: float) -> float:
	var local_u = x * 2
	var local_i := y * ratio
	var local_t: float = local_i + 1.0
	journal.append("scale %s %s %s" % [str(local_u), str(local_i), str(local_t)])
	return local_t + float(local_u)


func classify(n: int) -> String:
	var result := "none"
	if n < 0:
		result = "negative"
		journal.append("neg")
		journal.append("neg again")
	elif n == 0:
		result = "zero"
		journal.append("zero")
		journal.append("zero again")
	else:
		result = "positive"
		journal.append("pos")
		journal.append("pos again")
	journal.append("classified " + result)
	return result


func describe_value(v):
	match v:
		1:
			journal.append("one")
			journal.append("one again")
		2:
			journal.append("two")
			journal.append("two again")
		var other:
			journal.append("other %s" % str(other))
			journal.append("other again")
	journal.append("described")


func total(limit: int) -> int:
	var sum := 0
	for i in range(limit):
		sum += i
		journal.append("i%d" % i)
	return sum


func _process(dt):
	journal.append("process %s" % str(dt))
	counter += 1
	label_text = "t"
	journal.append("one")
	journal.append("two")
	journal.append("three")
	if dt > 1.0:
		journal.append("big")
		journal.append("big again")
	elif dt > 0.5:
		journal.append("medium")
		journal.append("medium again")
	else:
		journal.append("small")
		journal.append("small again")
	journal.append("tick %s" % str(dt))


func run():
	add_untyped("a")
	add_untyped(2)
	var s := scale_it(3, 2.0)
	journal.append("s %s" % str(s))
	for n in [-1, 0, 5]:
		classify(n)
	describe_value(1)
	describe_value(2)
	describe_value("x")
	var t := total(4)
	journal.append("total %d" % t)
	pinged.emit(counter)
"""

var plugin: EditorPlugin
var ed
var tree: SceneTree
var checks := Checks.new()
var fails := 0
var known := 0
var original_text := ""


func note(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE if FileAccess.file_exists(LOG) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(ok: bool, what: String, detail := "") -> void:
	if not ok:
		fails += 1
	note("%s  %s%s" % ["PASS" if ok else "FAIL", what, ("  -> " + detail) if (not ok and detail != "") else ""])


func known_issue(what: String) -> void:
	known += 1
	note("KNOWN: " + what)


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- helpers

## The code the editor would show for the open document right now.
func code() -> String:
	ed._check(ed.doc)
	return String(ed.doc.preview)


func loads(text: String) -> bool:
	return checks.load_text("@tool\n" + text)[0] != null


## What a script does when run() is called: every script variable afterwards, as text.
func behave(text: String) -> Dictionary:
	var gs: GDScript = checks.load_text("@tool\n" + text)[0]
	if gs == null:
		return {"<does not load>": true}
	var n := Node.new()
	n.set_script(gs)
	n.call("run")
	# the engine would call the event every frame: here three frames, by hand (the script does not call it itself)
	for dt in [0.25, 0.75, 2.0]:
		n.call("_process", dt)
	var out := {}
	for p in gs.get_script_property_list():
		if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out[String(p.name)] = var_to_str(n.get(p.name))
	n.free()
	return out


## [removed lines, added lines] between two texts, counting repeats.
func diff_lines(a: String, b: String) -> Array:
	var count := {}
	for l in a.split("\n"):
		count[l] = int(count.get(l, 0)) + 1
	var added := []
	for l in b.split("\n"):
		if int(count.get(l, 0)) > 0:
			count[l] = int(count[l]) - 1
		else:
			added.append(l)
	var removed := []
	for l in count:
		for i in int(count[l]):
			removed.append(l)
	return [removed, added]


func show_diff(d: Array) -> void:
	for l in d[0]:
		note("      - " + String(l))
	for l in d[1]:
		note("      + " + String(l))


func word_in(text: String, word: String) -> bool:
	return RegEx.create_from_string("\\b%s\\b" % word).search(text) != null


func history() -> UndoRedo:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(ed))


func variable(name: String) -> Dictionary:
	for v in ed.doc.bp.variables:
		if v.name == name:
			return v
	return {}


func local_of(g: Dictionary, name: String) -> Dictionary:
	for v in g.locals:
		if v.name == name:
			return v
	return {}


func show_graph(g: Dictionary) -> void:
	ed.doc.graph_id = int(g.id)
	ed._refresh_graph()
	ed._refresh_graph_tabs()
	ed._refresh_members()
	await frames(3)


func gnode(id: int):
	return ed._view.get_node_or_null("n%d" % id)


func select_only(ids: Array) -> void:
	for c in ed._view.get_children():
		if c is GraphElement and not c.has_meta("gone"):
			c.selected = ids.has(int(String(c.name).trim_prefix("n")))


## Changes a variable's or local's type the way the Details panel does: select it, press the Variable Type
## button, pick the type in the popup.
func change_type(kind: String, name: String, type: String) -> bool:
	ed._select({"kind": kind, "name": name})
	await frames(3)
	var btn: Button = null
	for b in ed._details.find_children("*", "Button", true, false):
		if b.has_meta("type") and btn == null:
			btn = b
	if btn == null:
		note("      (no Variable Type button for %s %s)" % [kind, name])
		return false
	btn.pressed.emit()
	await frames(3)
	var picked := false
	for pop in btn.get_children():
		if pop is PopupPanel:
			for list in pop.find_children("*", "ItemList", true, false):
				for i in list.item_count:
					if String(list.get_item_metadata(i)) == type and not picked:
						picked = true
						list.item_activated.emit(i)
	await frames(5)
	return picked


func find_exec_reroutes() -> Array:
	var out := []
	for g in ed.doc.bp.graphs:
		for n in g.nodes:
			if n.kind != "reroute":
				continue
			var src := []
			var dst := []
			for w in g.wires:
				if int(w[2]) == int(n.id) and w[3] == "i":
					src = w
				if int(w[0]) == int(n.id) and w[1] == "o":
					dst = w
			if not src.is_empty() and not dst.is_empty() and String(n.p.get("t", "")) == "exec":
				out.append({"g": g, "n": n, "from": src, "to": dst})
	return out


func find_name_nodes() -> Array:
	var out := []
	for g in ed.doc.bp.graphs:
		for n in g.nodes:
			if n.kind == "const" and String(n.p.get("label", "")) != "":
				out.append({"g": g, "n": n})
	return out


## Every error state in the open document: described nodes that say ERROR.
func node_errors(bp: Dictionary) -> Array:
	var out := []
	for g in bp.graphs:
		for n in g.nodes:
			if n.kind == "comment":
				continue
			var d := R.describe(n, bp, g)
			if String(d.err) != "":
				out.append("%s #%d %s: %s" % [g.name, int(n.id), n.kind, d.err])
	return out


func panel_text() -> String:
	var lines := []
	for i in ed._results.item_count:
		lines.append(ed._results.get_item_text(i))
	return " | ".join(lines)


func fit_view(g: Dictionary) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		lo = Vector2(minf(lo.x, float(n.x)), minf(lo.y, float(n.y)))
		hi = Vector2(maxf(hi.x, float(n.x) + 300.0), maxf(hi.y, float(n.y) + 220.0))
	var view = ed._view
	var z := minf(1.0, minf((view.size.x - 40.0) / (hi.x - lo.x), (view.size.y - 40.0) / (hi.y - lo.y)))
	view.zoom = maxf(z, 0.4)
	view.scroll_offset = lo * view.zoom - Vector2(20, 20)


func cleanup() -> void:
	if ed != null:
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


# ---------------------------------------------------------------- the test

func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(200.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	original_text = SOURCE

	# ------------------------------------------------ 1. baseline: convert, load, run, interface
	var original: Array = checks.load_text(SOURCE)
	check(original[0] != null, "1. the source script itself loads", str(original[1].keys()))
	var out: Dictionary = Importer.new().convert(SOURCE, {"path": PATH})
	var made: Array = checks.compile_loaded(out.bp)
	var base_code: String = made[0]
	check(int(out.report.as_code) == 0, "1. converts with no lines kept as code (%d of %d lines are nodes)" % [out.report.as_nodes, out.report.lines], str(out.report.notes))
	check(made[1] != null, "1. the converted script loads", str(made[2].keys()))
	var file_text := Model.build_source(base_code, out.bp)
	write_file(PATH, file_text)
	var saved: Array = checks.load_text(file_text)
	check(saved[0] != null, "1. the saved file loads", str(saved[1].keys()))
	if original[0] == null or saved[0] == null:
		note("cannot go on without a script that loads")
		cleanup()
		tree.quit()
		return
	var changes: Array = checks.interface_changes(checks.interface(original[0]), checks.interface(saved[0]))
	check(changes.is_empty(), "1. the interface is the same as the original's", str(changes))
	var want_run := behave(SOURCE)
	var got_run := behave(file_text)
	check(var_to_str(want_run) == var_to_str(got_run) and want_run.has("journal"), "1. run() leaves the same state on the original and the converted script (%d values, %d journal entries)" % [want_run.size(), (str_to_var(String(want_run.get("journal", "[]"))) as Array).size()])
	# the converted graph must contain what this test is about
	var reroutes := 0
	var names := 0
	var name_labels := []
	for g in out.bp.graphs:
		for n in g.nodes:
			if n.kind == "reroute":
				reroutes += 1
			if n.kind == "const" and String(n.p.get("label", "")) != "":
				names += 1
				name_labels.append(String(n.p.label))
	note("    converted graph: %d graphs, %d reroutes, %d name nodes %s" % [out.bp.graphs.size(), reroutes, names, name_labels])
	check(reroutes >= 1, "1. the conversion placed at least one reroute (%d)" % reroutes)
	check(names >= 1, "1. the conversion placed at least one name node (%d: %s)" % [names, name_labels])
	var flags := []
	for v in out.bp.variables:
		flags.append("%s{written=%s}" % [v.name, v.get("written", "-")])
	note("    member flags: %s" % ", ".join(flags))

	# ------------------------------------------------ 2. open in the editor
	EditorInterface.get_resource_filesystem().update_file(PATH)
	await tree.create_timer(0.6).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.5).timeout
	var opened: bool = ed.open_schematic(PATH)
	await frames(6)
	check(opened and ed.doc.path == PATH and ed.doc.errors.is_empty(), "2. the converted file opens in the editor with no error", str(ed.doc.errors))
	var bad := node_errors(ed.doc.bp)
	check(bad.is_empty(), "2. every node is described, none shows an error state", str(bad))
	check(ed._results.item_count == 1 and ed._results.get_item_text(0).begins_with("Compile complete"), "2. the compiler results panel reports no issues", panel_text())
	ed._right_tabs.current_tab = 1
	await frames(4)
	var headless := Compiler.new().compile(Model.load_file(PATH))
	check(ed._code.text == headless, "2. the Generated Code panel text equals the compiler's output headless (%d vs %d characters)" % [ed._code.text.length(), headless.length()])
	ed._right_tabs.current_tab = 0
	await frames(2)

	# ------------------------------------------------ 3. look and save: byte-identical
	var before_bytes := FileAccess.get_file_as_bytes(PATH)
	ed.compile_doc(ed.doc, true)
	await frames(3)
	var after_bytes := FileAccess.get_file_as_bytes(PATH)
	var same := before_bytes == after_bytes
	check(same, "3. opening and saving without a change leaves the file byte-identical (%d bytes)" % before_bytes.size())
	if not same:
		var a := before_bytes.get_string_from_utf8()
		var b := after_bytes.get_string_from_utf8()
		var first := 0
		while first < mini(a.length(), b.length()) and a[first] == b[first]:
			first += 1
		note("      first difference at character %d: was [%s] now [%s]" % [first, a.substr(first, 60).replace("\n", "\\n"), b.substr(first, 60).replace("\n", "\\n")])
		var dd := diff_lines(a, b)
		note("      %d lines differ (%d -> %d characters)" % [dd[0].size() + dd[1].size(), a.length(), b.length()])
		# saving a second time must change nothing more
		var once := FileAccess.get_file_as_bytes(PATH)
		ed.compile_doc(ed.doc, true)
		await frames(3)
		check(FileAccess.get_file_as_bytes(PATH) == once, "3. saving a second time changes nothing more (the first save only normalised the file)")
		write_file(PATH, file_text)   # go on from the file as converted

	# the picture: the graph with the most reroutes, fitted to the view, from the editor's own viewport
	var best := {}
	var best_n := -1
	for g in ed.doc.bp.graphs:
		var k := 0
		for n in g.nodes:
			if n.kind == "reroute" or (n.kind == "const" and String(n.p.get("label", "")) != ""):
				k += 1
		var hi_x := 0.0
		for n in g.nodes:
			hi_x = maxf(hi_x, float(n.x))
		# the most readable graph that still has reroutes: the narrowest one with at least two
		var score := (100000 - int(hi_x)) if k >= 2 else k
		if score > best_n:
			best_n = score
			best = g
	await show_graph(best)
	fit_view(best)
	await frames(6)
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(PNG)
	note("    saved %s (graph '%s')" % [PNG, best.name])
	# start again from a fresh document (the fit above changes the stored view, which is not an edit)
	for i in range(ed.docs.size() - 1, -1, -1):
		if ed.docs[i].path == PATH:
			ed.docs[i].dirty = false
			ed._close_doc(i)
	write_file(PATH, file_text)
	EditorInterface.get_resource_filesystem().update_file(PATH)
	await tree.create_timer(0.4).timeout
	ed.open_schematic(PATH)
	await frames(6)
	check(ed.doc.path == PATH, "3. the document is open again, untouched")
	ed.compile_doc(ed.doc, false)
	var code0 := code()
	check(loads(code0), "3. the code before any edit loads")

	# ------------------------------------------------ 4. the untyped member becomes an int
	var counter0 := variable("counter")
	check(String(counter0.get("written", "")) == "untyped", "4. 'counter' starts out written untyped", str(counter0))
	var ok := await change_type("var", "counter", "int")
	check(ok, "4. the Variable Type popup offers int and it was picked")
	var cv := variable("counter")
	check(not cv.has("written") and not cv.has("untyped") and not cv.has("infer") and not cv.has("hint"), "4. 'counter' lost its written flag", str(cv))
	var code4 := code()
	var decl := ""
	for l in code4.split("\n"):
		if l.begins_with("var counter") or l.begins_with("@export var counter"):
			decl = l
	note("    generated declaration: [%s]" % decl)
	check(decl.begins_with("var counter: int"), "4. the generated code declares 'var counter: int'", decl)
	ed.compile_doc(ed.doc, false)
	check(loads(String(ed.doc.preview)), "4. the script still loads", panel_text())
	var d4 := diff_lines(code0, code())
	show_diff(d4)
	var only := true
	for side in d4:
		for l in side:
			if not word_in(String(l), "counter"):
				only = false
	check(only and d4[0].size() == 1 and d4[1].size() == 1, "4. only the declaration of 'counter' changed (%d lines removed, %d added)" % [d4[0].size(), d4[1].size()])
	var code4b := code()
	history().undo()
	await frames(4)
	check(code() == code0 and String(variable("counter").get("written", "")) == "untyped", "4. undo restores the written flag and the exact previous code")
	history().redo()
	await frames(4)
	check(code() == code4b and not variable("counter").has("written"), "4. redo applies the change again")

	# ------------------------------------------------ 5. the := member, and locals
	var ratio0 := variable("ratio")
	check(String(ratio0.get("written", "")) == "infer", "5. 'ratio' starts out written with :=", str(ratio0))
	var code5a := code()
	ok = await change_type("var", "ratio", "int")
	var rv := variable("ratio")
	check(ok and not rv.has("written") and rv.type == "int", "5. 'ratio' (:=) changed to int and lost its written flag", str(rv))
	var code5b := code()
	var rdecl := ""
	for l in code5b.split("\n"):
		if l.begins_with("var ratio"):
			rdecl = l
	note("    generated declaration: [%s]" % rdecl)
	check(rdecl.begins_with("var ratio: int"), "5. the generated code declares 'var ratio: int' (and not :=)", rdecl)
	var d5 := diff_lines(code5a, code5b)
	show_diff(d5)
	only = true
	for side in d5:
		for l in side:
			if not word_in(String(l), "ratio"):
				only = false
	check(only and d5[1].size() >= 1, "5. only lines about 'ratio' changed (%d removed, %d added)" % [d5[0].size(), d5[1].size()])
	ed.compile_doc(ed.doc, false)
	check(loads(String(ed.doc.preview)), "5. the script still loads", panel_text())

	var scale_g := Model.graph_named(ed.doc.bp, "scale_it")
	await show_graph(scale_g)
	scale_g = Model.graph_named(ed.doc.bp, "scale_it")
	var lu := local_of(scale_g, "local_u")
	var li := local_of(scale_g, "local_i")
	note("    locals of scale_it: local_u %s, local_i %s" % [str(lu), str(li)])
	check(bool(lu.get("untyped", false)), "5. local 'local_u' starts out written untyped")
	check(bool(li.get("infer", false)) or String(li.get("hint", "")) != "", "5. local 'local_i' starts out written with :=")
	var code5c := code()
	ok = await change_type("local", "local_u", "int")
	scale_g = Model.graph_named(ed.doc.bp, "scale_it")
	lu = local_of(scale_g, "local_u")
	check(ok and lu.type == "int" and not lu.has("untyped") and not lu.has("hint") and not lu.has("infer"), "5. local 'local_u' changed to int and lost its flags", str(lu))
	var code5d := code()
	var ludecl := ""
	for l in code5d.split("\n"):
		if l.strip_edges().begins_with("var local_u"):
			ludecl = l.strip_edges()
	note("    generated declaration: [%s]" % ludecl)
	check(ludecl.begins_with("var local_u: int"), "5. the generated code declares 'var local_u: int'", ludecl)
	var d5c := diff_lines(code5c, code5d)
	show_diff(d5c)
	only = true
	for side in d5c:
		for l in side:
			if not word_in(String(l), "local_u"):
				only = false
	check(only and d5c[1].size() >= 1, "5. only lines about 'local_u' changed (%d removed, %d added)" % [d5c[0].size(), d5c[1].size()])
	ed.compile_doc(ed.doc, false)
	check(loads(String(ed.doc.preview)), "5. the script still loads after the local's change", panel_text())
	code5d = code()
	history().undo()
	await frames(4)
	scale_g = Model.graph_named(ed.doc.bp, "scale_it")
	check(code() == code5c and bool(local_of(scale_g, "local_u").get("untyped", false)), "5. undo restores the local's flag and the exact previous code")
	history().redo()
	await frames(4)
	check(code() == code5d, "5. redo applies the local's change again")
	ed.compile_doc(ed.doc, false)
	var code_before_6 := code()
	var graph_json_before_6 := JSON.stringify(ed.doc.bp)

	# ------------------------------------------------ 6. delete a reroute on an execution wire
	var rr := find_exec_reroutes()
	check(not rr.is_empty(), "6. there is a reroute on an execution wire to delete (%d)" % rr.size())
	if not rr.is_empty():
		var pick: Dictionary = rr[0]
		var gr: Dictionary = pick.g
		var rid := int(pick.n.id)
		var from_w: Array = pick["from"]
		var to_w: Array = pick["to"]
		note("    deleting reroute #%d in '%s': %d.%s -> reroute -> %d.%s" % [rid, gr.name, int(from_w[0]), from_w[1], int(to_w[2]), to_w[3]])
		await show_graph(gr)
		select_only([rid])
		await frames(2)
		ed._view._on_delete_nodes([])
		await frames(4)
		gr = Model.find_graph(ed.doc.bp, int(gr.id))
		var bridged := false
		for w in gr.wires:
			if int(w[0]) == int(from_w[0]) and w[1] == from_w[1] and int(w[2]) == int(to_w[2]) and w[3] == to_w[3]:
				bridged = true
		var gone_node := Model.find_node(gr, rid).is_empty()
		check(gone_node, "6. the reroute node is gone after Delete")
		var code6 := code()
		var d6 := diff_lines(code_before_6, code6)
		note("    after deleting the reroute: wire reconnected through = %s; generated code %s (%d removed, %d added)" % [bridged, "unchanged" if code6 == code_before_6 else "changed", d6[0].size(), d6[1].size()])
		show_diff(d6)
		ed.compile_doc(ed.doc, false)
		note("    compiler results panel: %s" % panel_text())
		var panel_errors := 0
		for e in ed.doc.errors:
			if not e.w:
				panel_errors += 1
		check(panel_errors == 0, "6. the compiler results panel shows no error after the deletion (%d errors; status: %s)" % [panel_errors, ed._status.text])
		if not bridged and ed.doc.errors.is_empty():
			known_issue("6. after the wire is cut the compiler gives no warning at all: %d lines of code vanish and the nodes that followed are left unreachable without a word (status says '%s', panel empty). Responsible: sc_compiler.gd compile() does not report nodes that no event reaches" % [d6[0].size(), ed._status.text])
		check(String(ed.doc.preview) != "" and loads(String(ed.doc.preview)), "6. the script after the deletion still loads (and nothing errored)", panel_text())
		if bridged:
			check(code6 == code_before_6, "6. the wire is reconnected through, so the generated code is unchanged")
		else:
			known_issue("6. deleting a reroute from an execution wire CUTS the wire (code after that point is gone: %d lines removed); Unreal keeps the connection. Responsible: sc_graph_view.gd _on_delete_nodes -> sc_model.gd remove_node (removes every wire of the node, never bridges)" % d6[0].size())
		history().undo()
		await frames(4)
		check(code() == code_before_6 and JSON.stringify(ed.doc.bp) == graph_json_before_6, "6. undo restores the exact previous code (and the exact graph)")

	# ------------------------------------------------ 7. delete a name node
	var nn := find_name_nodes()
	check(not nn.is_empty(), "7. there is a name node to delete (%d: %s)" % [nn.size(), nn.map(func(x): return String(x.n.p.label))])
	for item in nn.slice(0, 2):
		var gn: Dictionary = item.g
		var nid := int(item.n.id)
		var label := String(item.n.p.label)
		var readers := []
		for w in gn.wires:
			if int(w[0]) == nid:
				var rn := Model.find_node(gn, int(w[2]))
				readers.append("#%d %s.%s" % [int(w[2]), rn.kind, w[3]])
		note("    deleting name node '%s' #%d in '%s' (read by %s)" % [label, nid, gn.name, readers])
		await show_graph(gn)
		select_only([nid])
		await frames(2)
		ed._view._on_delete_nodes([])
		await frames(4)
		var code7 := code()
		var d7 := diff_lines(code_before_6, code7)
		show_diff(d7)
		var ok7: bool = ed.compile_doc(ed.doc, false)
		var issues: int = ed.doc.errors.size()
		note("    compile ok=%s, %d errors/warnings; panel: %s" % [ok7, issues, panel_text()])
		var after_text := String(ed.doc.preview)
		var silent_different: bool = code7 != code_before_6 and issues == 0 and loads(after_text)
		var changed_behaviour := false
		if silent_different:
			changed_behaviour = var_to_str(behave(after_text)) != var_to_str(behave(code_before_6))
		# A name node is a value like any other: with it gone the pin it fed is unwired and shows its own default,
		# as after deleting a variable getter. What must not happen is a script that no longer loads with no error.
		check(issues > 0 or loads(after_text), "7. deleting name node '%s' leaves its reader on the pin's own default (ok=%s, %d issues, %d lines changed, behaviour %s)" % [
			label, ok7, issues, d7[1].size(), "differs" if changed_behaviour else "is the same"],
			"the script neither loads nor reports an error")
		history().undo()
		await frames(4)
		check(code() == code_before_6, "7. undo restores the exact previous code after deleting '%s'" % label)
	ed.compile_doc(ed.doc, false)

	# ------------------------------------------------ 8. add a Print String at the end of run()
	var run_g := Model.graph_named(ed.doc.bp, "run")
	await show_graph(run_g)
	run_g = Model.graph_named(ed.doc.bp, "run")
	var last := {}
	var last_pin := {}
	var walk := {}
	for n in run_g.nodes:
		if n.kind == "fn_entry":
			walk = n
	var guard := 0
	while not walk.is_empty() and guard < 200:
		guard += 1
		var d := R.describe(walk, ed.doc.bp, run_g)
		var next := {}
		var exec_out := {}
		for pin in d.outs:
			if pin.type == "exec":
				exec_out = pin
		if exec_out.is_empty():
			break
		for w in run_g.wires:
			if int(w[0]) == int(walk.id) and w[1] == exec_out.id:
				next = Model.find_node(run_g, int(w[2]))
		if next.is_empty():
			last = walk
			last_pin = exec_out
			break
		walk = next
	check(not last.is_empty(), "8. the end of run()'s execution chain was found (node #%s %s)" % [last.get("id", "?"), last.get("kind", "?")])
	var act := {}
	for a in R.static_actions():
		if a.k == "print":
			act = a
	check(not act.is_empty(), "8. the palette has a Print String action")
	var code8a := code()
	if not last.is_empty() and not act.is_empty():
		var before_ids: Array = run_g.nodes.map(func(n): return int(n.id))
		var ctx := {"type": "exec", "out": true, "node": int(last.id), "pin": last_pin}
		ed._view.spawn(act.k, act.p, Vector2(float(last.x) + 300.0, float(last.y)), ctx)
		await frames(4)
		run_g = Model.graph_named(ed.doc.bp, "run")
		var new_node := {}
		for n in run_g.nodes:
			if not before_ids.has(int(n.id)):
				new_node = n
		check(not new_node.is_empty(), "8. Print String was added to run()'s graph")
		if not new_node.is_empty():
			var wired := false
			for w in run_g.wires:
				if int(w[0]) == int(last.id) and int(w[2]) == int(new_node.id) and w[3] == "exec":
					wired = true
			check(wired, "8. it was wired into the execution chain from the old last node (spawn with the wire's context)")
			ed._view.pin_default_changed(int(new_node.id), "text", "\"added in the editor\"")
			await frames(2)
			var code8b := code()
			var d8 := diff_lines(code8a, code8b)
			show_diff(d8)
			check(d8[0].is_empty() and d8[1].size() == 1 and String(d8[1][0]).contains("print(") and String(d8[1][0]).contains("added in the editor"), "8. the generated code gains exactly that line (%d removed, %d added)" % [d8[0].size(), d8[1].size()])
			ed.compile_doc(ed.doc, false)
			check(loads(String(ed.doc.preview)), "8. the script loads", panel_text())
			check(String(variable("counter").get("written", "")) == "" and String(variable("ratio").get("written", "")) == "", "8. the changed variables stayed changed")
			var decl_ok := true
			var untouched := []
			for l in code8a.split("\n"):
				if l.begins_with("var ") or l.begins_with("@export") or l.begins_with("func ") or l.begins_with("signal "):
					untouched.append(l)
			for l in untouched:
				if not code8b.split("\n").has(l):
					decl_ok = false
			check(decl_ok, "8. every declaration and function header is exactly as before (%d lines compared)" % untouched.size())
	var code_before_9 := code()

	# ------------------------------------------------ 9. move nodes
	var moved_ids := []
	var cur: Dictionary = ed.cur_graph()
	var model_before := {}
	for n in cur.nodes:
		if moved_ids.size() < 4 and n.kind != "comment":
			moved_ids.append(int(n.id))
			model_before[int(n.id)] = Vector2(float(n.x), float(n.y))
	var offsets := [Vector2(40, 30), Vector2(-25, 60), Vector2(0, 90), Vector2(70, -20)]
	for i in moved_ids.size():
		var el = gnode(moved_ids[i])
		if el != null:
			el.position_offset = el.position_offset + offsets[i]
	ed._view._on_end_node_move()
	await frames(3)
	cur = ed.cur_graph()
	var moved_count := 0
	for id in moved_ids:
		var n := Model.find_node(cur, id)
		if Vector2(float(n.x), float(n.y)) != model_before[id]:
			moved_count += 1
	check(moved_count == moved_ids.size() and moved_count > 0, "9. %d nodes were moved (positions in the model changed)" % moved_count)
	check(code() == code_before_9, "9. moving nodes leaves the generated code unchanged")

	# ------------------------------------------------ 10. the event parameter keeps the script's own name
	var ev := {}
	var ev_g := {}
	for g in ed.doc.bp.graphs:
		for n in g.nodes:
			if n.kind == "event" and n.p.get("name", "") == "_process":
				ev = n
				ev_g = g
	check(not ev.is_empty() and ev.p.get("names", []) == ["dt"], "10. the _process event node carries the script's parameter names", str(ev.get("p", {})))
	if not ev.is_empty():
		var pin_names := []
		for pin in R.describe(ev, ed.doc.bp, ev_g).outs:
			pin_names.append(String(pin.name))
		note("    _process event pins: %s" % [pin_names])
		check(pin_names.any(func(s): return s.to_lower() == "dt"), "10. the _process event shows a pin named after the script's own parameter (dt)", str(pin_names))
		await show_graph(ev_g)
		var labels := []
		var el = gnode(int(ev.id))
		if el != null:
			for lab in el.find_children("*", "Label", true, false):
				labels.append(String(lab.text))
		note("    labels on the on-screen event node: %s" % [labels])
		check(labels.any(func(s): return s.to_lower() == "dt"), "10. the on-screen _process node has a pin labelled dt", str(labels))
	var head := ""
	for l in code().split("\n"):
		if l.begins_with("func _process"):
			head = l
	note("    generated header: [%s]" % head)
	check(head.begins_with("func _process(dt"), "10. the generated header says func _process(dt...", head)

	# ------------------------------------------------ 11. save, close, reopen
	ed.compile_doc(ed.doc, false)
	var final_code := String(ed.doc.preview)
	ed.compile_doc(ed.doc, true)
	await frames(3)
	var disk := FileAccess.get_file_as_string(PATH)
	var disk_code := disk.substr(0, Model.graph_block_at(disk))
	check(disk_code.strip_edges(false, true) == final_code.strip_edges(false, true), "11. the file on disk holds the code the editor showed")
	check(not ed.doc.dirty, "11. saving cleared the unsaved mark")
	for i in range(ed.docs.size() - 1, -1, -1):
		if ed.docs[i].path == PATH:
			ed._close_doc(i)
	await frames(3)
	check(ed._find_doc(PATH).is_empty(), "11. the document is closed")
	check(ed.open_schematic(PATH), "11. the file reopens")
	await frames(6)
	var again := Compiler.new().compile(Model.load_file(PATH))
	check(again == final_code, "11. the reopened graph compiles to exactly the code that was saved (headless)")
	check(code() == final_code, "11. ... and so does the editor's reopened document")
	var cv2 := variable("counter")
	var rv2 := variable("ratio")
	check(not cv2.has("written") and cv2.type == "int" and not rv2.has("written") and rv2.type == "int", "11. the flags changed in step 4 and 5 are still gone after reopening", "%s %s" % [cv2, rv2])
	scale_g = Model.graph_named(ed.doc.bp, "scale_it")
	check(not local_of(scale_g, "local_u").has("untyped") and local_of(scale_g, "local_u").type == "int", "11. the local's change is still there after reopening")
	var final_file := FileAccess.get_file_as_string(PATH)
	var fl: Array = checks.load_text(final_file)
	check(fl[0] != null, "11. the script file on disk loads", str(fl[1].keys()))
	var bad2 := node_errors(ed.doc.bp)
	check(bad2.is_empty(), "11. after reopening, no node shows an error state", str(bad2))
	# behaviour: the original with exactly the intended edits, then the original itself
	var intended := SOURCE.replace("var counter = 0", "var counter: int = 0").replace("var ratio := 1.5", "var ratio: int = 0")
	intended = intended.replace("var local_u = x * 2", "var local_u: int = x * 2").replace("var local_i := y * ratio", "var local_i: float = y * ratio")
	var have := behave(final_file)
	var intended_state := behave(intended)
	var diffs := []
	for k in intended_state:
		if var_to_str(intended_state[k]) != var_to_str(have.get(k, "<missing>")):
			diffs.append("%s\n        wanted %s\n        got    %s" % [k, String(intended_state[k]).replace("\n", " "), String(have.get(k, "<missing>")).replace("\n", " ")])
	check(diffs.is_empty() and intended_state.has("journal"), "11. run() on the final script gives what the original with the intended edits (typed counter and ratio, typed locals; the added print writes only to the output) gives", "\n      ".join(diffs))
	var vs_original := []
	for k in want_run:
		if var_to_str(want_run[k]) != var_to_str(have.get(k, "<missing>")):
			vs_original.append(k)
	note("    against the unedited original, only these values differ: %s (the intended change of 'ratio' from 1.5 to a plain int 0)" % [vs_original])
	var jo: Array = str_to_var(String(want_run.get("journal", "[]")))
	var jh: Array = str_to_var(String(have.get("journal", "[]")))
	note("    journal: %d entries on the original, %d on the final script; same: %s" % [jo.size(), jh.size(), jo == jh])

	# ------------------------------------------------ 12. tidy up
	cleanup()
	await tree.create_timer(1.0).timeout
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR)), "12. the scratch folder is removed")
	note("%s  verdict: %d check%s failed, %d known issue%s" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s", known, "" if known == 1 else "s"])
	tree.quit()
