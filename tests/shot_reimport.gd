extends RefCounted
## Editor self-test for Re-import Code: a Schematic whose GDScript was edited by hand gets the bar above the graph;
## its Re-import Code button (and File > Re-import Code From File...) shows what will happen, applies it as one undo
## step, and leaves the document in a state where saving is allowed and writes the file. Refused edits change
## nothing. Breakpoints on rebuilt nodes go, the others keep mapping to their lines. Unsaved graph changes are kept
## where the file did not change that function.
## Scratch files go to res://tests/tmp/reimport_ui/ (not scanned by the editor).
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_reimport.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Sync := preload("res://addons/schematic/core/sc_sync.gd")

const LOG := "res://tests/out/shot_reimport_checks.log"
const SHOT_PREVIEW := "res://tests/out/shot_reimport_preview.png"
const SHOT_REFUSED := "res://tests/out/shot_reimport_refused.png"
const DIR := "res://tests/tmp/reimport_ui"
const PLAIN := DIR + "/plain_source.gd"
const PATH := DIR + "/SC_Reimport.gd"
const HAND := DIR + "/SC_PlayerCopy.gd"
const DEMO_COPY := DIR + "/SC_DemoCopy.gd"

const SRC := """extends Node

signal scored(points: int)

var speed := 2.0
var count: int = 0

func _ready() -> void:
	var start := 3
	count = start
	print("ready ", count)

func _process(delta: float) -> void:
	var step := speed * delta
	if step > 1.0:
		count += 1

func total(items: Array) -> int:
	var sum := 0
	for it in items:
		sum += it
	return sum

func bump(items: Array) -> Array:
	return items.map(func(v): return v + 1)

func helper() -> void:
	print(total([1, 2]))
	count += 1
"""

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0
var converted := ""   # the converted sample's whole text


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
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func source_of(bp: Dictionary) -> String:
	return Model.build_source(Compiler.new().compile(bp), bp)


## Edits the code part of a file by hand: each [find, replace] once. False (and a FAIL) when a find is not there.
func hand_edit(path: String, pairs: Array, label: String) -> bool:
	var text := read(path)
	var cut := Model.graph_block_at(text)
	var code := text.substr(0, cut)
	for p in pairs:
		if not code.contains(String(p[0])):
			check(false, label + ": the edit applies", "not found: " + String(p[0]).c_escape())
			return false
		code = code.replace(String(p[0]), String(p[1]))
	write_file(path, code + text.substr(cut))
	return true


## The text of one function of a file's code, as the block splitter cuts it.
func func_text(path: String, name: String) -> String:
	for b in Sync.new().split(Model.code_part(read(path))):
		if String(b.kind) == "func" and String(b.name) == name:
			return String(b.text)
	return ""


## A copy without what only the view keeps (zoom and scroll), which drawing a graph may update.
func strip_view(bp: Dictionary) -> Dictionary:
	var out := bp.duplicate(true)
	for g in out.get("graphs", []):
		for k in ["zoom", "sx", "sy"]:
			g.erase(k)
	return out


## Same code by the re-import's own check (functions by name; comments and blank lines aside).
func same_code(a: String, b: String) -> bool:
	var s := Sync.new()
	return s._compare(s._canon(s.split(Model.normalize_code(Model.code_part(a)))), s._canon(s.split(Model.code_part(b))), {}, {"renamed_locals": [], "reformatted": []}).is_empty()


## Where two values first differ ("" when equal), for a failure's detail.
func first_diff(a: Variant, b: Variant, at := "") -> String:
	if typeof(a) != typeof(b):
		return "%s: %s (%s) vs %s (%s)" % [at, str(a).left(60), type_string(typeof(a)), str(b).left(60), type_string(typeof(b))]
	if a is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s.%s missing on the right" % [at, k]
			var d := first_diff(a[k], b[k], "%s.%s" % [at, k])
			if d != "":
				return d
		for k in b:
			if not a.has(k):
				return "%s.%s missing on the left" % [at, k]
		return ""
	if a is Array:
		if a.size() != b.size():
			return "%s: %d items vs %d" % [at, a.size(), b.size()]
		for i in a.size():
			var d := first_diff(a[i], b[i], "%s[%d]" % [at, i])
			if d != "":
				return d
		return ""
	return "" if a == b else "%s: %s vs %s" % [at, str(a).left(60), str(b).left(60)]


func graph_of(bp: Dictionary, name: String) -> Dictionary:
	for g in bp.graphs:
		if String(g.name) == name:
			return g
	return {}


func bar_shown() -> bool:
	return ed._drift_bar.is_visible_in_tree()


func toast_has(s: String) -> bool:
	return String(ed._toast.text).contains(s)


func dialog() -> AcceptDialog:
	var v: Variant = ed._reimport_dialog
	if v == null or not is_instance_valid(v) or not (v as AcceptDialog).visible:
		return null
	return v


func words() -> String:
	var d := dialog()
	if d == null:
		return ""
	var rt: RichTextLabel = d.find_child("Words", true, false)
	return rt.get_parsed_text() if rt else ""


func find_button(root: Node, text: String) -> Button:
	if root == null:
		return null
	for b in root.find_children("*", "Button", true, false):
		if String(b.text) == text and b.visible:
			return b
	return null


func press_reimport() -> AcceptDialog:
	ed._drift_btns.reimport.pressed.emit()
	await frames(4)
	return dialog()


func confirm() -> void:
	var d := dialog()
	if d:
		d.get_ok_button().pressed.emit()
	await frames(4)


func cancel() -> void:
	var d := dialog()
	if d and d is ConfirmationDialog:
		(d as ConfirmationDialog).get_cancel_button().pressed.emit()
	elif d:
		d.get_ok_button().pressed.emit()
	await frames(4)


func not_kept(pv: Dictionary) -> Dictionary:
	var out := {}
	for x in pv.result.report.functions:
		if String(x.action) != "kept":
			out[String(x.name)] = String(x.action)
	return out


func history() -> UndoRedo:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(ed))


func doc_of(path: String) -> Dictionary:
	return ed._find_doc(path)


func close_clean(path: String) -> void:
	var d: Dictionary = doc_of(path)
	if not d.is_empty():
		d.dirty = false
		ed._close_doc(ed.docs.find(d))


func open(path: String) -> bool:
	var ok: bool = ed.open_schematic(path)
	EditorInterface.set_main_screen_editor("Schematic")
	await frames(4)
	return ok


## The converted sample written fresh and opened (closing an earlier copy first).
func fresh() -> void:
	close_clean(PATH)
	await frames(2)
	write_file(PATH, converted)
	await open(PATH)


func notice() -> void:
	ed._drift_check(ed.doc, true)
	await frames(2)


func shoot(win: Window, path: String) -> void:
	await tree.create_timer(0.4).timeout
	if win == null:
		return
	var img: Image = win.get_texture().get_image() if not win.is_embedded() else EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	img.save_png(path)
	note("saved " + path)


## A node of a graph that has a line of its own in the code (a breakpoint can go on it), other than the entry.
func line_node(gname: String) -> int:
	var g := graph_of(ed.doc.bp, gname)
	for n in g.nodes:
		var key := "%d:%d" % [int(g.id), int(n.id)]
		if ed.doc.node_lines.has(key) and not String(n.kind) in ["fn_entry", "event"]:
			return int(n.id)
	return -1


## Changes a literal of a graph (a node's value or a local's default) from `from` to `to` as an unsaved edit.
func graph_literal(gname: String, from: String, to: String) -> bool:
	var did := [false]
	ed.open_member_graph(gname)
	ed.mutate("Change value", func():
		var g := graph_of(ed.doc.bp, gname)
		for n in g.nodes:
			for k in n.get("d", {}):
				if String(n.d[k]) == from and not did[0]:
					n.d[k] = to
					did[0] = true
		for l in g.get("locals", []):
			if String(l.get("default", "")) == from and not did[0]:
				l["default"] = to
				did[0] = true)
	return did[0]


func remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func cleanup() -> void:
	if ed != null:
		for i in range(ed.docs.size() - 1, -1, -1):
			if String(ed.docs[i].path).begins_with(DIR):
				ed.docs[i].dirty = false
				ed._close_doc(i)
		for dlg in [ed._reimport_dialog, ed._diff_dialog, ed._close_dialog]:
			if dlg and is_instance_valid(dlg):
				dlg.hide()
	var all: Dictionary = EditorInterface.get_editor_settings().get_project_metadata("schematics", "breakpoints", {})
	for p in [PATH, HAND, DEMO_COPY]:
		all.erase(p)
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", all)
	remove_dir(DIR)


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	remove_dir(DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(500.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await frames(4)

	write_file(PLAIN, SRC)
	var conv: Dictionary = ed.convert_script(PLAIN)
	check(bool(conv.ok), "the sample script (two events, three functions, a lambda, a loop, members) converts", str(conv.get("errors", [])))
	converted = String(conv.get("text", ""))
	if converted == "":
		cleanup()
		tree.quit()
		return

	await case_preview_cancel()
	await case_apply_undo_save()
	await case_comments_style()
	await case_refused()
	await case_add_remove_rename()
	await case_breakpoints()
	await case_unsaved_graph()
	await case_changed_again()
	await case_menu()
	await case_hand_made()
	await case_no_drift()

	cleanup()
	await tree.create_timer(1.0).timeout
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()


# 1. one function edited on disk: the bar, the preview names exactly it; Cancel changes nothing
func case_preview_cancel() -> void:
	note("--- 1. preview, then Cancel")
	await fresh()
	check(ed.doc.drift == "" and not bar_shown() and ed.doc.errors.filter(func(e): return not e.w).is_empty(), "the converted sample opens in sync, without errors", str(ed.doc.errors))
	var before := strip_view(ed.doc.bp)
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 5\n\tprint(\"counting\")\n"]], "case 1")
	var edited := read(PATH)
	await notice()
	check(ed.doc.drift == "code" and bar_shown(), "the edit is noticed: the bar shows", str(ed.doc.drift))
	var b: Button = ed._drift_btns.reimport
	check(b.visible and not b.disabled, "Re-import Code is shown and enabled")
	check(b.tooltip_text == "Bring the changed code into the graph. Only the functions that changed are rebuilt.", "its tooltip says what it does", b.tooltip_text)
	var dlg := await press_reimport()
	check(dlg != null and dlg is ConfirmationDialog, "pressing it opens the preview window")
	var pv: Dictionary = ed.reimport_last
	check(bool(pv.result.ok) and not_kept(pv) == {"total": "rebuilt"}, "the preview: exactly total rebuilt", str(not_kept(pv)))
	var w := words()
	check(w.contains("Function total: rebuilt from the code") and w.contains("4 other functions and events are unchanged"), "the window lists total and counts the others", w.left(400))
	check(find_button(dlg, "Re-import") != null and find_button(dlg, "Cancel") != null, "with Re-import and Cancel")
	await cancel()
	check(dialog() == null, "Cancel closes it")
	check(strip_view(ed.doc.bp) == before and bar_shown() and read(PATH) == edited and ed.doc.drift == "code", "after Cancel: the graph deep-equals what it was, the bar is still there, the file is untouched")


# 2 and 3. Re-import: only total changes; bar gone, unsaved; undo brings back the old graph and the bar; redo; save
func case_apply_undo_save() -> void:
	note("--- 2. Re-import, 3. undo and redo, then save and reopen")
	var before := strip_view(ed.doc.bp)
	var total_id := int(graph_of(ed.doc.bp, "total").id)
	ed.open_member_graph("helper")
	var shown_graph := int(ed.doc.graph_id)
	await press_reimport()
	await confirm()
	var file_code := Model.code_part(read(PATH))
	var after := strip_view(ed.doc.bp)
	check(Model.normalize_code(String(ed.doc.preview)) == file_code, "the graph's code now equals the file's code part")
	var others_same := true
	var differs := []
	for g in before.graphs:
		var now := graph_of(after, String(g.name))
		if int(g.id) == total_id:
			continue
		if now != g:
			others_same = false
			differs.append(g.name)
	check(others_same and before.graphs.size() == after.graphs.size(), "every other graph (the EventGraph with both events, helper, bump and its lambda) is unchanged down to ids and positions", str(differs))
	check(int(graph_of(after, "total").id) == total_id and graph_of(after, "total") != graph_of(before, "total"), "total kept its id and was rebuilt")
	check(after.variables == before.variables and after.dispatchers == before.dispatchers, "members unchanged")
	check(not bar_shown() and ed.doc.drift == "" and ed.doc.dirty, "the bar is gone, the document shows unsaved changes", "drift=%s dirty=%s" % [ed.doc.drift, ed.doc.dirty])
	check(int(ed.doc.graph_id) == shown_graph, "the graph on screen is still the one shown before (helper)")
	check(ed._view.selected_ids().is_empty(), "nothing is selected")
	check(toast_has("Code re-imported") and toast_has("total rebuilt"), "a toast says what was done", String(ed._toast.text))
	check(ed._may_write(ed.doc), "saving is allowed again")
	# 3. undo, redo
	history().undo()
	await frames(3)
	check(strip_view(ed.doc.bp) == before, "undo restores the old graph exactly")
	check(ed.doc.drift == "code" and bar_shown(), "and the bar comes back (the file still holds the edit)", str(ed.doc.drift))
	check(not ed._may_write(ed.doc), "with saving refused again")
	history().redo()
	await frames(3)
	check(strip_view(ed.doc.bp) == after and ed.doc.drift == "" and not bar_shown(), "redo applies it again and the bar goes", str(ed.doc.drift))
	# save, reopen
	check(ed.compile_doc(ed.doc, true), "Save writes the file")
	var text := read(PATH)
	check(Model.code_part(text) == file_code, "with the same code part")
	# (as the file stores it: a number in the graph data reads back as a float, 2 as 2.0)
	var stored := func(bp: Dictionary) -> Variant: return JSON.parse_string(JSON.stringify(strip_view(bp)))
	check(stored.call(Model.load_file(PATH)) == stored.call(ed.doc.bp), "and the new graph data", first_diff(stored.call(Model.load_file(PATH)), stored.call(ed.doc.bp)))
	close_clean(PATH)
	await frames(2)
	await open(PATH)
	check(stored.call(ed.doc.bp) == stored.call(after) and ed.doc.drift == "" and not bar_shown() and not ed.doc.dirty, "reopened: the same graph, in sync", first_diff(stored.call(ed.doc.bp), stored.call(after)))


# 4. a comment and a line written without Schematic's brackets: both told in the preview; after save, Schematic's form
func case_comments_style() -> void:
	note("--- 4. a comment and a reformatted line")
	await fresh()
	hand_edit(PATH, [["\tvar sum := 0\n", "\t# counting up\n\tvar sum := 0\n"], ["print(\"ready \", count)", "print(\"ready \", count + 1)"]], "case 4")
	await notice()
	var dlg := await press_reimport()
	var pv: Dictionary = ed.reimport_last
	var rep: Dictionary = pv.result.report
	check(dlg != null and bool(pv.result.ok) and not_kept(pv) == {"_ready": "rebuilt", "total": "rebuilt"}, "the preview: the _ready event and the function with the new comment are rebuilt",str(not_kept(pv)) + str(rep.refused))
	var w := words()
	check(int(rep.comments_dropped) == 0 and not w.contains("not kept yet"), "the comment is kept, so there is no warning about it", w)
	check(not rep.reformatted.is_empty() and w.contains("1 line will be written in Schematic's style") and w.contains("print(\"ready \", count + 1)") and w.contains("print(\"ready \", (count + 1))"), "it shows the line that will be written differently, before and after", str(rep.reformatted))
	await shoot(dlg, SHOT_PREVIEW)
	await confirm()
	check(not bar_shown() and ed.doc.drift == "" and ed.doc.dirty, "re-imported: in sync, unsaved")
	check(ed.compile_doc(ed.doc, true), "saved")
	var text := read(PATH)
	check(text.contains("print(\"ready \", (count + 1))") and text.contains("\t# counting up\n\tvar sum := 0\n") and not text.contains("count + 1)\n"), "the file has the line in Schematic's form and the comment where it was written")
	await notice()
	check(ed.doc.drift == "" and not bar_shown(), "in sync")


# 5. refused: a line inside a helper, and a syntax error: the reason and line; no Re-import; nothing changes
func case_refused() -> void:
	note("--- 5. refused")
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	demo.class_name = ""
	write_file(DEMO_COPY, source_of(demo))
	await open(DEMO_COPY)
	var before := strip_view(ed.doc.bp)
	hand_edit(DEMO_COPY, [["\treturn keys[-1][1]", "\treturn keys[0][1]"]], "helper edit")
	var edited := read(DEMO_COPY)
	await notice()
	var dlg := await press_reimport()
	var w := words()
	check(dlg != null and not (dlg is ConfirmationDialog) and not bool(ed.reimport_last.result.ok), "a helper line edited: the window says it can't be done")
	check(w.contains("can't be brought into the graph") and w.contains("written by Schematic") and w.contains("Line "), "with the reason and its line", w.left(500))
	check(find_button(dlg, "Re-import") == null and find_button(dlg, "Close") != null, "there is no Re-import button")
	var show: Button = dlg.find_child("ShowLine", true, false) if dlg else null
	check(show != null and show.text.begins_with("Show Line"), "there is a Show Line button")
	if show:
		show.pressed.emit()
		await frames(4)
		var view: CodeEdit = ed._diff_dialog.find_child("Diff", true, false) if ed._diff_dialog and is_instance_valid(ed._diff_dialog) else null
		check(view != null and ed._diff_dialog.visible and view.get_line(view.get_caret_line()).contains("keys[0][1]"), "Show Line opens the changes at that line", view.get_line(view.get_caret_line()) if view else "-")
		if ed._diff_dialog and is_instance_valid(ed._diff_dialog):
			ed._diff_dialog.hide()
		await frames(2)
	await cancel()
	check(strip_view(ed.doc.bp) == before and bar_shown() and read(DEMO_COPY) == edited, "the graph untouched, the bar stays, the file as edited")
	check(not ed.compile_doc(ed.doc, true) and read(DEMO_COPY) == edited, "saving is still refused")
	close_clean(DEMO_COPY)
	# a prelude line
	write_file(DEMO_COPY, source_of(demo))
	await open(DEMO_COPY)
	hand_edit(DEMO_COPY, [["func _ready() -> void:\n\t__tl_pulse_1_27_run()\n", "func _ready() -> void:\n\t__tl_pulse_1_27_sample()\n"]], "prelude edit")
	await notice()
	await press_reimport()
	check(not bool(ed.reimport_last.result.ok) and words().contains("written by Schematic") and find_button(dialog(), "Re-import") == null, "a prelude line edited: refused the same way", words().left(300))
	await cancel()
	close_clean(DEMO_COPY)
	# a syntax error
	await fresh()
	before = strip_view(ed.doc.bp)
	hand_edit(PATH, [["\tcount += 1\n\n", "\tcount += \n\n"]], "syntax error")
	edited = read(PATH)
	await notice()
	dlg = await press_reimport()
	w = words()
	check(dlg != null and not bool(ed.reimport_last.result.ok) and w.contains("does not load") and w.contains("Line "), "a syntax error: the window says the file does not load, with the line", w.left(400))
	check(find_button(dlg, "Re-import") == null and dlg.find_child("ShowLine", true, false) != null, "no Re-import button; Show Line is there")
	await shoot(dlg, SHOT_REFUSED)
	await cancel()
	check(strip_view(ed.doc.bp) == before and bar_shown() and read(PATH) == edited and not ed.compile_doc(ed.doc, true) and read(PATH) == edited, "the graph untouched, the bar stays, saving refused")


# 6. a function added (and called), one removed, one renamed with its caller
func case_add_remove_rename() -> void:
	note("--- 6. added, removed, renamed")
	await fresh()
	var total_id := int(graph_of(ed.doc.bp, "total").id)
	var bump := func_text(PATH, "bump")
	check(bump != "", "the text of bump is found")
	hand_edit(PATH, [[bump, ""], ["func total(", "func sum_all("], ["print(total(", "print(sum_all("], ["\tcount += 1\n\n", "\tcount += 1\n\textra()\n\n"]], "case 6")
	var text := read(PATH)
	var cut := Model.graph_block_at(text)
	write_file(PATH, text.substr(0, cut).strip_edges(false, true) + "\n\n\nfunc extra() -> void:\n\tprint(\"extra\")\n\n\n" + text.substr(cut))
	await notice()
	await press_reimport()
	var pv: Dictionary = ed.reimport_last
	var acts := not_kept(pv)
	check(bool(pv.result.ok) and acts.get("extra") == "added" and acts.get("bump") == "removed" and String(acts.get("sum_all", "")).begins_with("renamed") and acts.get("helper") == "rebuilt", "the preview: extra added, bump removed, total renamed to sum_all, helper rebuilt", str(acts) + str(pv.result.report.refused))
	var w := words()
	check(w.contains("Function extra: added (new in the file)") and w.contains("Function bump: removed (no longer in the file)") and w.contains("sum_all: renamed from total"), "each with the right words", w.left(600))
	await confirm()
	var bp: Dictionary = ed.doc.bp
	check(not graph_of(bp, "extra").is_empty() and graph_of(bp, "bump").is_empty() and graph_of(bp, "_bump_lambda").is_empty() and int(graph_of(bp, "sum_all").id) == total_id and graph_of(bp, "total").is_empty(), "applied: extra is there, bump and its lambda are gone, sum_all is total's graph renamed", str(bp.graphs.map(func(g): return g.name)))
	check(same_code(String(ed.doc.preview), read(PATH)) and not bar_shown(), "the graph's code is the file's (blank lines aside); bar gone")


# 7. breakpoints: a node on a line that did not change keeps its breakpoint, on its (moved) line; a node whose own
# line was edited is rebuilt, and its breakpoint goes and is reported
func case_breakpoints() -> void:
	note("--- 7. breakpoints")
	await fresh()
	ed.open_member_graph("total")
	var n1 := line_node("total")
	ed.toggle_breakpoints([n1])
	var g1 := int(ed.doc.graph_id)
	ed.open_member_graph("helper")
	var n2 := line_node("helper")
	ed.toggle_breakpoints([n2])
	var g2 := int(ed.doc.graph_id)
	var k1 := "%d:%d" % [g1, n1]
	var k2 := "%d:%d" % [g2, n2]
	check(n1 != -1 and n2 != -1 and ed._breaks(PATH).has(k1) and ed._breaks(PATH).has(k2) and ed.doc.drift == "", "a breakpoint on a node of total and one on a node of helper", str(ed._breaks(PATH)))
	var line_before: int = ed._node_line(ed.doc, k2)
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 0\n\tprint(\"one more line\")\n"]], "case 7")
	await notice()
	await press_reimport()
	await confirm()
	var breaks: Array = ed._breaks(PATH)
	check(breaks.has(k1) and breaks.has(k2), "a line added beside them: both breakpoints are still there (their nodes were kept)", str(breaks))
	check(not toast_has("breakpoint"), "nothing is said about breakpoints, since none was removed", String(ed._toast.text))
	var line_now: int = ed._node_line(ed.doc, k2)
	var code_lines := Model.code_part(read(PATH)).split("
")
	var gen_lines := Model.normalize_code(String(ed.doc.preview)).split("
")
	var bl: PackedStringArray = ed.breakpoint_lines()
	check(line_now == line_before + 1 and bl.has("%s:%d" % [PATH, line_now]), "the debugger's line map puts the second on its new line (%d, was %d)" % [line_now, line_before], str(bl))
	check(line_now >= 1 and line_now <= code_lines.size() and code_lines[line_now - 1] == gen_lines[line_now - 1] and code_lines[line_now - 1].strip_edges() != "", "that line of the file is that node's line (%s)" % (code_lines[line_now - 1].strip_edges() if line_now >= 1 and line_now <= code_lines.size() else "?"))
	var k1_line: int = ed._node_line(ed.doc, k1)
	check(k1_line >= 1 and bl.has("%s:%d" % [PATH, k1_line]) and code_lines[k1_line - 1] == gen_lines[k1_line - 1], "the first is on its node's line too (%d: %s)" % [k1_line, code_lines[k1_line - 1].strip_edges() if k1_line >= 1 else "?"], str(bl))
	history().undo()
	await frames(3)
	check(ed._breaks(PATH).has(k1) and ed._breaks(PATH).has(k2), "undo keeps both breakpoints")
	history().redo()
	await frames(3)
	# now change the very line the first breakpoint's node writes: that node is rebuilt, so its breakpoint goes
	check(ed.compile_doc(ed.doc, true), "saved before the second edit")
	await notice()
	var its_line := String(Model.code_part(read(PATH)).split("
")[ed._node_line(ed.doc, k1) - 1])
	var changed := its_line.replace(":= 0", ":= 7") if its_line.contains(":= 0") else (its_line + " * 1" if its_line.contains("+= ") else "")
	if changed == "" or changed == its_line:
		note("    (the first breakpoint's line is '%s': no edit prepared for it, removal not checked)" % its_line.strip_edges())
		return
	hand_edit(PATH, [[its_line + "
", changed + "
"]], "case 7, the breakpoint's own line")
	await notice()
	await press_reimport()
	await confirm()
	breaks = ed._breaks(PATH)
	check(not breaks.has(k1) and breaks.has(k2), "its own line edited: the first breakpoint is gone, the second is still there", str(breaks))
	check(toast_has("1 breakpoint on rebuilt nodes was removed"), "the removal is reported", String(ed._toast.text))
	history().undo()
	await frames(3)
	check(not ed._breaks(PATH).has(k1), "undo does not bring the removed breakpoint back (as documented)")
	history().redo()
	await frames(3)


# 8. an unsaved graph edit and a file edit in another function: both kept; both in the same function: the file's
func case_unsaved_graph() -> void:
	note("--- 8. unsaved graph changes")
	await fresh()
	var did := graph_literal("helper", "1", "7")
	check(did and String(ed.doc.preview).contains("count += 7"), "an unsaved graph edit in helper (count += 7)", String(ed.doc.preview).substr(String(ed.doc.preview).find("func helper"), 80))
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 5\n"]], "case 8")
	await notice()
	await press_reimport()
	var pv: Dictionary = ed.reimport_last
	check(bool(pv.result.ok) and not_kept(pv) == {"total": "rebuilt"} and pv.graph_only.has("helper"), "the preview: total rebuilt, helper kept as the graph has it", str(not_kept(pv)) + " " + str(pv.graph_only) + str(pv.result.report.refused))
	check(words().contains("Kept as they are in the graph (not changed in the file): helper"), "the window says helper is kept from the graph", words().left(600))
	await confirm()
	var code := String(ed.doc.preview)
	check(code.contains("count += 7") and code.contains("var sum := 5"), "after re-import both are there: helper as edited in the graph, total from the file")
	check(not bar_shown() and ed.doc.dirty and ed._may_write(ed.doc), "bar gone, unsaved, saving allowed")
	ed.compile_doc(ed.doc, true)
	check(read(PATH).contains("count += 7") and read(PATH).contains("var sum := 5"), "saving writes both")
	# the same function edited in both
	await fresh()
	did = graph_literal("total", "0", "9")
	check(did and String(ed.doc.preview).contains("var sum := 9"), "an unsaved graph edit in total (sum := 9)")
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 5\n"]], "case 8b")
	await notice()
	await press_reimport()
	pv = ed.reimport_last
	check(bool(pv.result.ok) and pv.both.has("total") and words().contains("Changed in both the graph and the file, so taken from the file") and words().contains("total"), "the preview says total changed in both and the file's is taken", str(pv.both) + words().left(500))
	await confirm()
	check(String(ed.doc.preview).contains("var sum := 5") and not String(ed.doc.preview).contains("var sum := 9"), "after re-import total is the file's")


# 9. the file changes again while the preview is open: nothing stale is applied; the preview is made again
func case_changed_again() -> void:
	note("--- 9. changed again before Re-import is pressed")
	await fresh()
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 5\n"]], "case 9 first")
	await notice()
	var before := strip_view(ed.doc.bp)
	var first := await press_reimport()
	hand_edit(PATH, [["\tcount += 1\n\n", "\tcount += 2\n\n"]], "case 9 second")
	var second := read(PATH)
	await confirm()
	await frames(4)
	var again := dialog()
	check(strip_view(ed.doc.bp) == before, "pressing Re-import did not apply the stale preview")
	check(toast_has("changed again on disk"), "a toast says the file changed again", String(ed._toast.text))
	check(again != null and again != first and String(ed.reimport_last.text) == second and not_kept(ed.reimport_last).has("helper") and not_kept(ed.reimport_last).has("total"), "a new preview of the file as it is now is shown (total and helper)", str(not_kept(ed.reimport_last)))
	await confirm()
	check(String(ed.doc.preview).contains("var sum := 5") and String(ed.doc.preview).contains("count += 2") and not bar_shown(), "Re-import in the new preview brings both in")
	# after apply and before save the file changes again: caught as a new change
	hand_edit(PATH, [["\tcount += 2\n\n", "\tcount += 3\n\n"]], "case 9 after apply")
	await notice()
	check(ed.doc.drift == "code" and bar_shown() and not ed._may_write(ed.doc), "an edit made after re-import and before saving is caught as a new change")
	ed._drift_btns.reimport.pressed.emit()
	await frames(4)
	await confirm()
	check(String(ed.doc.preview).contains("count += 3") and not bar_shown(), "and can be re-imported in turn")


# 10. File > Re-import Code From File... after Keep Graph does the same; after a save it is disabled
func case_menu() -> void:
	note("--- 10. File > Re-import Code From File...")
	await fresh()
	var pop: PopupMenu = ed._file_menu.get_popup()
	var idx := pop.get_item_index(ed.FILE_REIMPORT)
	check(pop.get_item_text(idx) == "Re-import Code From File...", "the File menu has the entry", pop.get_item_text(idx))
	hand_edit(PATH, [["\tvar sum := 0\n", "\tvar sum := 4\n"]], "case 10")
	await notice()
	ed._drift_btns.keep.pressed.emit()
	await frames(2)
	check(ed._keep_chosen(ed.doc) and bar_shown(), "Keep Graph chosen")
	ed._file_menu.about_to_popup.emit()
	check(not pop.is_item_disabled(idx), "the entry is enabled (the file still differs from the graph)")
	pop.id_pressed.emit(ed.FILE_REIMPORT)
	await frames(4)
	check(dialog() != null and not_kept(ed.reimport_last) == {"total": "rebuilt"}, "it opens the same preview", str(not_kept(ed.reimport_last)))
	await confirm()
	check(String(ed.doc.preview).contains("var sum := 4") and not bar_shown() and ed.doc.drift == "" and not ed._keep_chosen(ed.doc), "Re-import works the same; in sync")
	ed._file_menu.about_to_popup.emit()
	check(pop.is_item_disabled(idx), "afterwards the entry is disabled")
	# Keep Graph, then a save that overwrites the file: nothing left to re-import
	hand_edit(PATH, [["\tvar sum := 4\n", "\tvar sum := 6\n"]], "case 10b")
	await notice()
	ed._drift_btns.keep.pressed.emit()
	await frames(2)
	check(ed.compile_doc(ed.doc, true), "Keep Graph and save overwrite the file")
	ed._file_menu.about_to_popup.emit()
	check(pop.is_item_disabled(idx) and not read(PATH).contains("sum := 6"), "then the entry is disabled")


# 11. a hand-made schematic: one event's code edited; the other graphs' positions and comment boxes are identical
func case_hand_made() -> void:
	note("--- 11. hand-made schematic")
	close_clean(PATH)
	var player := Model.load_file("res://demo/game/SC_Player.gd")
	player.class_name = ""
	# comment boxes a person drew, around the nodes of each graph
	for g in player.graphs:
		var minx := 1e9
		var miny := 1e9
		for n in g.nodes:
			minx = minf(minx, float(n.x))
			miny = minf(miny, float(n.y))
		Model.add_node(g, "comment", Vector2(minx - 40, miny - 60), {"text": "Drawn by hand: %s" % g.name, "w": 900.0, "h": 360.0})
	write_file(HAND, source_of(player))
	await open(HAND)
	var before := strip_view(ed.doc.bp)
	hand_edit(HAND, [["* speed)\n", "* (speed * 2.0))\n"]], "case 11")
	await notice()
	await press_reimport()
	check(not_kept(ed.reimport_last) == {"_physics_process": "rebuilt"}, "the preview: _physics_process rebuilt", str(not_kept(ed.reimport_last)) + str(ed.reimport_last.result.report.refused))
	await confirm()
	var after := strip_view(ed.doc.bp)
	var eg_b: Dictionary = before.graphs[0]
	var eg_a: Dictionary = after.graphs[0]
	var gone := {}
	for id in ed.reimport_last.result.report.replaced.get(int(eg_b.id), []):
		gone[int(id)] = true
	var boxes_b: Array = eg_b.nodes.filter(func(n): return String(n.kind) == "comment")
	var others_same := true
	for g in before.graphs.slice(1):
		if graph_of(after, String(g.name)) != g:
			others_same = false
	check(others_same and before.graphs.size() == after.graphs.size(), "the other graphs (add_score) are identical, comment box and positions")
	var kept: Array = eg_b.nodes.filter(func(n): return not gone.has(int(n.id)) and not (String(n.kind) == "event" and String(n.p.get("name", "")) == "_physics_process"))
	check(not boxes_b.is_empty() and boxes_b.all(func(n): return Model.find_node(eg_a, int(n.id)) == n), "in the EventGraph the comment box is identical")
	check(kept.all(func(n): return Model.find_node(eg_a, int(n.id)) == n), "and every node of the other event (_ready) is identical: id, position, everything (%d nodes)" % kept.size())
	close_clean(HAND)


# 12. no drift: no bar, the menu entry disabled; editing, undo and save as before
func case_no_drift() -> void:
	note("--- 12. no drift")
	await fresh()
	check(not bar_shown() and not ed.can_reimport(ed.doc), "in sync: no bar, nothing to re-import")
	ed._file_menu.about_to_popup.emit()
	var pop: PopupMenu = ed._file_menu.get_popup()
	check(pop.is_item_disabled(pop.get_item_index(ed.FILE_REIMPORT)), "the menu entry is disabled")
	var before := strip_view(ed.doc.bp)
	ed.mutate("Move node", func(): ed.doc.bp.graphs[0].nodes[0].x = float(ed.doc.bp.graphs[0].nodes[0].x) + 20.0)
	check(ed.doc.dirty and not bar_shown() and not ed.can_reimport(ed.doc), "an ordinary edit: unsaved, still no bar, still nothing to re-import")
	history().undo()
	await frames(2)
	check(strip_view(ed.doc.bp) == before, "undo works as before")
	check(ed.compile_doc(ed.doc, true) and ed.doc.drift == "" and not bar_shown(), "save works as before")
	ed.reimport_dialog(ed.doc)
	await frames(3)
	check(dialog() == null and toast_has("Nothing to re-import"), "asking to re-import anyway opens no window and says why", String(ed._toast.text))
