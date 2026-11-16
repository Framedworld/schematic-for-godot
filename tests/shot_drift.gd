extends RefCounted
## Editor self-test for changes made to a Schematic's file outside the Schematic editor: the editor notices them
## (code edited by hand, the whole file replaced, the file deleted), shows a bar above the graph, and never
## overwrites such a file until the person chooses to: not on Save, Save All, close, a breakpoint toggle, or a macro
## library's save that recompiles the schematics using it. Files it just wrote itself, line-ending and trailing
## whitespace differences, files from before the code fingerprint and the game running with Show Flow and Values
## on are not reported.
## Scratch files go to res://tests/tmp/drift/ (not scanned by the editor) and, for the file system signal, to
## res://tests/drift_scan/ (scanned; removed at the end). The running-game case uses res://demo/SC_Demo.gd and
## puts its bytes back (run `git checkout -q -- demo/SC_Demo.gd` after it anyway).
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_drift.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const W := preload("res://addons/schematic/editor/sc_widgets.gd")

const LOG := "res://tests/out/shot_drift_checks.log"
const SHOT := "res://tests/out/shot_drift.png"
const DIR := "res://tests/tmp/drift"
const PATH := DIR + "/SC_Drift.gd"
const LIB := DIR + "/SC_DriftMacros.gd"
const USER1 := DIR + "/SC_DriftUser1.gd"
const USER2 := DIR + "/SC_DriftUser2.gd"
const OLD := DIR + "/SC_DriftOld.gd"
const CLOSED := DIR + "/SC_DriftClosed.gd"
const SCAN_DIR := "res://tests/drift_scan"
const SCAN := SCAN_DIR + "/SC_DriftScan.gd"
const DEMO := "res://demo/SC_Demo.gd"

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0
var demo_bytes := PackedByteArray()


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


func bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


## A small schematic: Ready -> Print String, and optionally a variable.
func probe_bp(var_name := "") -> Dictionary:
	var bp := Model.new_schematic("Node", "")
	var g: Dictionary = bp.graphs[0]
	var pr := Model.add_node(g, "print", Vector2(340, 80), {})
	g.wires.append([int(g.nodes[0].id), "then", int(pr.id), "exec"])
	if var_name != "":
		bp.variables.append({"name": var_name, "type": "int", "default": "7", "export": false, "category": "", "tooltip": ""})
	return bp


func source_of(bp: Dictionary) -> String:
	return Model.build_source(Compiler.new().compile(bp), bp)


## Edits one line of the code part of a file, as a person would by hand: returns [old line, new line].
func hand_edit(path: String) -> Array:
	var text := FileAccess.get_file_as_string(path)
	var cut := Model.graph_block_at(text)
	var lines := text.substr(0, cut).split("\n")
	for i in lines.size():
		if lines[i].contains("print("):
			var old := lines[i]
			lines[i] = old.replace("print(", "print(\"edited by hand\", ")
			write_file(path, "\n".join(lines) + text.substr(cut))
			return [old, lines[i]]
	return ["", ""]


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


func bar_shown() -> bool:
	return ed._drift_bar.is_visible_in_tree()


func toast_has(s: String) -> bool:
	return String(ed._toast.text).contains(s)


func touch_graph() -> void:
	ed.mutate("Move node", func(): ed.doc.bp.graphs[0].nodes[0].x = float(ed.doc.bp.graphs[0].nodes[0].x) + 20.0)


func find_button(root: Node, text: String) -> Button:
	for b in root.find_children("*", "Button", true, false):
		if String(b.text) == text:
			return b
	return null


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
			var p := String(ed.docs[i].path)
			if p.begins_with(DIR) or p.begins_with(SCAN_DIR) or p == DEMO:
				ed.docs[i].dirty = false
				ed._close_doc(i)
		if ed._close_dialog and is_instance_valid(ed._close_dialog):
			ed._close_dialog.hide()
		if ed._diff_dialog and is_instance_valid(ed._diff_dialog):
			ed._diff_dialog.hide()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	var all: Dictionary = EditorInterface.get_editor_settings().get_project_metadata("schematics", "breakpoints", {})
	all.erase(PATH)
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", all)
	if not demo_bytes.is_empty():
		var f := FileAccess.open(DEMO, FileAccess.WRITE)
		f.store_buffer(demo_bytes)
		f.close()
	remove_dir(DIR)
	remove_dir(SCAN_DIR)
	EditorInterface.get_resource_filesystem().scan()


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
	tree.create_timer(420.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await frames(4)

	await case_untouched()
	await case_code_edit()
	await case_keep_graph()
	await case_close_both()
	await case_replaced()
	await case_deleted()
	await case_no_false_alarms()
	await case_library()
	await case_old_file()
	await case_scan_signal()
	await case_game()

	cleanup()
	await tree.create_timer(1.5).timeout
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()


# 1. open, save untouched, reopen: in sync throughout, no banner, file byte-identical
func case_untouched() -> void:
	note("--- 1. untouched")
	write_file(PATH, source_of(probe_bp()))
	check(await open(PATH), "the probe opens")
	check(ed.doc.drift == "" and not bar_shown(), "just opened: in sync, no bar", str(ed.doc.drift))
	check(ed.compile_doc(ed.doc, true), "saving it works")
	var first := bytes(PATH)
	await frames(3)
	ed.check_drift_all()
	check(ed.doc.drift == "" and not bar_shown(), "after its own save: in sync, no bar (the file system's reaction included)", str(ed.doc.drift))
	check(ed.compile_doc(ed.doc, true) and bytes(PATH) == first, "a second save with nothing changed writes the same bytes")
	close_clean(PATH)
	await frames(2)
	check(await open(PATH), "it reopens")
	check(ed.doc.drift == "" and not bar_shown(), "reopened: in sync, no bar", str(ed.doc.drift))
	check(ed.compile_doc(ed.doc, true) and bytes(PATH) == first, "saved again after reopening: byte-identical")


# 2. edit one line of the code on disk: code drift, bar; save, Save All and a breakpoint toggle leave the file alone
func case_code_edit() -> void:
	note("--- 2. code edited outside")
	var edit := hand_edit(PATH)
	check(edit[0] != "", "a line of the code part was edited on disk", str(edit))
	var edited := bytes(PATH)
	ed.check_drift_all()
	await frames(3)
	check(ed.doc.drift == "code", "the state is code drift", str(ed.doc.drift))
	check(bar_shown() and String(ed._drift_label.text).contains("code was changed outside Schematic"), "the bar shows above the graph", String(ed._drift_label.text))
	check(ed._drift_btns.show.visible and ed._drift_btns.keep.visible and ed._drift_btns.reimport.visible and not ed._drift_btns.reload.visible, "it offers Show Changes, Keep Graph and Re-import Code")
	check(not ed._drift_btns.reimport.disabled and String(ed._drift_btns.reimport.tooltip_text).begins_with("Bring the changed code into the graph"), "Re-import Code is there and enabled, with its tooltip (tests/shot_reimport.gd tests what it does)")
	var tab_icon: Texture2D = ed._doc_tabs.get_tab_icon(ed.docs.find(ed.doc))
	check(tab_icon == W.icon("StatusWarning"), "the document's tab carries a warning icon")
	await tree.create_timer(0.3).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(SHOT)
	note("saved " + SHOT)
	check(not ed.compile_doc(ed.doc, true), "an explicit save reports that it did not save")
	check(bytes(PATH) == edited, "an explicit save does not change the file")
	check(toast_has("Not saved") and toast_has("SC_Drift.gd"), "a toast says the file was not saved and why", String(ed._toast.text))
	touch_graph()
	ed.save_all()
	check(bytes(PATH) == edited and ed.doc.dirty, "Save All (save on run, Ctrl+S) does not change it either, and the edit stays unsaved")
	check(toast_has("not rewritten"), "with a toast", String(ed._toast.text))
	var pid := int(ed.doc.bp.graphs[0].nodes[2].id)
	ed.toggle_breakpoints([pid])
	check(bytes(PATH) == edited, "a breakpoint toggle does not rewrite it")
	check(ed._breaks(PATH).size() == 1 and toast_has("not rewritten"), "the breakpoint is still set, and a toast says the file was not rewritten", "%s / %s" % [ed._breaks(PATH), ed._toast.text])
	ed.toggle_breakpoints([pid])
	var diff: Array = ed.drift_diff(ed.doc)
	check(diff.size() == 2 and diff[0].op == "-" and String(diff[0].text) == edit[1] and diff[1].op == "+" and String(diff[1].text) == edit[0], "Show Changes lists exactly the edited line (on disk, and in the graph's code)", str(diff))
	ed._drift_btns.show.pressed.emit()
	await frames(3)
	var view: CodeEdit = ed._diff_dialog.find_child("Diff", true, false) if ed._diff_dialog else null
	check(view != null and ed._diff_dialog.visible and view.get_line_count() == 2 and view.get_line(0).contains("edited by hand") and not view.editable, "the Show Changes view opens, read-only, with those two lines", view.text if view else "-")
	if ed._diff_dialog:
		ed._diff_dialog.hide()
	await frames(2)


# 3. Keep Graph, then save: the file holds the graph's code, in sync, bar gone
func case_keep_graph() -> void:
	note("--- 3. Keep Graph")
	ed._drift_btns.keep.pressed.emit()
	await frames(2)
	check(ed.doc.drift == "code" and ed._keep_chosen(ed.doc) and String(ed._drift_label.text).contains("next save replaces"), "after Keep Graph the bar says the next save replaces the code", String(ed._drift_label.text))
	check(ed.compile_doc(ed.doc, true), "the save goes through")
	var text := FileAccess.get_file_as_string(PATH)
	check(Model.code_part(text) == Model.normalize_code(String(ed.doc.preview)) and not text.contains("edited by hand"), "the file now holds the graph's code")
	await frames(2)
	check(ed.doc.drift == "" and not bar_shown(), "in sync, bar gone", str(ed.doc.drift))


# 4. an unsaved graph change and a code edit on disk: both shown; close asks and by default leaves the file
func case_close_both() -> void:
	note("--- 4. unsaved graph change and outside edit")
	ed.mutate("Add variable", func(): ed.doc.bp.variables.append({"name": "unsaved_one", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""}))
	hand_edit(PATH)
	var edited := bytes(PATH)
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.dirty and ed.doc.drift == "code", "both facts are known: unsaved, and code drift")
	check(String(ed._drift_label.text).contains("changed outside Schematic") and String(ed._drift_label.text).contains("unsaved changes"), "the bar names both", String(ed._drift_label.text))
	ed._close_doc(ed.docs.find(ed.doc))
	await frames(3)
	var dlg: AcceptDialog = ed._close_dialog
	check(dlg != null and is_instance_valid(dlg) and dlg.visible and not doc_of(PATH).is_empty(), "closing asks (and the document is still open)")
	if dlg and is_instance_valid(dlg):
		check(String(dlg.dialog_text).contains("unsaved changes") and String(dlg.dialog_text).contains("outside Schematic"), "the question names both facts", dlg.dialog_text)
		check(dlg.get_ok_button().text == "Keep Open" and dlg.get_ok_button().has_focus(), "the default answer (Enter) is Keep Open", "%s focus=%s" % [dlg.get_ok_button().text, dlg.get_ok_button().has_focus()])
		dlg.get_ok_button().pressed.emit()
		await frames(3)
	check(not doc_of(PATH).is_empty() and bytes(PATH) == edited, "the default keeps it open and leaves the file as it is on disk")
	ed._close_doc(ed.docs.find(doc_of(PATH)))
	await frames(3)
	dlg = ed._close_dialog
	var discard := find_button(dlg, "Close Without Saving") if dlg and is_instance_valid(dlg) else null
	check(discard != null, "the question offers Close Without Saving")
	if discard:
		discard.pressed.emit()
		await frames(3)
	check(doc_of(PATH).is_empty() and bytes(PATH) == edited, "Close Without Saving closes it and leaves the file as it is on disk")
	# and the third answer overwrites
	write_file(PATH, source_of(probe_bp()))
	await open(PATH)
	ed.mutate("Add variable", func(): ed.doc.bp.variables.append({"name": "kept_one", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""}))
	hand_edit(PATH)
	ed._close_doc(ed.docs.find(ed.doc))
	await frames(3)
	dlg = ed._close_dialog
	var over := find_button(dlg, "Overwrite File and Close") if dlg and is_instance_valid(dlg) else null
	var offered := over != null
	if over:
		over.pressed.emit()
		await frames(3)
	check(offered and doc_of(PATH).is_empty() and Model.load_file(PATH).variables.any(func(v): return v.name == "kept_one") and not FileAccess.get_file_as_string(PATH).contains("edited by hand"), "Overwrite File and Close writes the graph and closes",
		"button=%s open=%s vars=%s edited=%s toast=%s" % [offered, not doc_of(PATH).is_empty(), Model.load_file(PATH).variables, FileAccess.get_file_as_string(PATH).contains("edited by hand"), ed._toast.text])


# 5. the whole file replaced by another Schematic: Keep Mine then save writes the old graph; Reload loads the new
func case_replaced() -> void:
	note("--- 5. file replaced")
	write_file(PATH, source_of(probe_bp()))
	await open(PATH)
	check(ed.doc.drift == "", "a fresh copy opens in sync", str(ed.doc.drift))
	write_file(PATH, source_of(probe_bp("replaced_var")))
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.drift == "replaced", "a different Schematic written over it: file replaced", str(ed.doc.drift))
	check(bar_shown() and String(ed._drift_label.text).contains("was replaced outside Schematic") and ed._drift_btns.reload.visible and ed._drift_btns.mine.visible and not ed._drift_btns.keep.visible, "the bar offers Reload From Disk and Keep Mine", String(ed._drift_label.text))
	var replaced := bytes(PATH)
	check(not ed.compile_doc(ed.doc, true) and bytes(PATH) == replaced, "a save does not overwrite it")
	ed._drift_btns.mine.pressed.emit()
	await frames(2)
	check(ed.compile_doc(ed.doc, true), "after Keep Mine the save goes through")
	check(Model.load_file(PATH).variables.is_empty() and ed.doc.drift == "", "the file holds the graph that was here (the old one), in sync")
	write_file(PATH, source_of(probe_bp("replaced_var")))
	touch_graph()
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.drift == "replaced" and String(ed._drift_btns.reload.text).contains("discard unsaved changes"), "replaced again, with unsaved changes here: the Reload button says it discards them", String(ed._drift_btns.reload.text))
	ed._drift_btns.reload.pressed.emit()
	await frames(4)
	check(ed.doc.bp.variables.any(func(v): return v.name == "replaced_var") and not ed.doc.dirty and ed.doc.drift == "" and not bar_shown(), "Reload From Disk loads the new graph: in sync, nothing unsaved, bar gone")
	check(ed.compile_doc(ed.doc, true) and Model.load_file(PATH).variables.size() == 1, "saving it then keeps the new graph")


# 6. the file deleted from outside: said so; save writes it again
func case_deleted() -> void:
	note("--- 6. file deleted")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.drift == "missing" and bar_shown() and String(ed._drift_label.text).contains("deleted or moved"), "the state says the file is gone, and the bar says so", String(ed._drift_label.text))
	check(ed.compile_doc(ed.doc, true) and FileAccess.file_exists(PATH), "saving writes it again")
	await frames(2)
	check(ed.doc.drift == "" and not bar_shown(), "then in sync", str(ed.doc.drift))


# 7. no false alarms: identical content, CRLF, trailing blank lines, trailing spaces, Godot saving the script
func case_no_false_alarms() -> void:
	note("--- 7. no false alarms")
	var text := FileAccess.get_file_as_string(PATH)
	write_file(PATH, text)
	check(ed._drift_check(ed.doc, true) == "", "the same content written again: in sync")
	write_file(PATH, text.replace("\n", "\r\n"))
	check(ed._drift_check(ed.doc, true) == "", "CRLF line endings: in sync")
	write_file(PATH, text + "\n\n\n")
	check(ed._drift_check(ed.doc, true) == "", "trailing blank lines: in sync")
	var cut := Model.graph_block_at(text)
	write_file(PATH, text.substr(0, cut).replace("\n", " \t\n") + text.substr(cut))
	check(ed._drift_check(ed.doc, true) == "", "spaces at the ends of code lines: in sync")
	write_file(PATH, text)
	# Godot saving the script resource (what its script editor does on save) right after the editor wrote it
	check(ed.compile_doc(ed.doc, true), "saved by Schematic")
	var scr := ResourceLoader.load(PATH, "", ResourceLoader.CACHE_MODE_REUSE) as Script
	var saved := ResourceSaver.save(scr, PATH) if scr else ERR_CANT_OPEN
	plugin.resource_saved.emit(scr)
	await frames(2)
	check(saved == OK and ed.doc.drift == "" and not bar_shown(), "then saved by Godot as a script resource: in sync", "save=%s drift=%s" % [saved, ed.doc.drift])
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.drift == "" and not bar_shown(), "and still in sync when the file system is looked at again", str(ed.doc.drift))
	close_clean(PATH)


# 8. a macro library used by two schematics, one hand-edited and not open: saving the library skips that one
func case_library() -> void:
	note("--- 8. macro library users")
	var lib := Starters.build("macro_library", "")
	write_file(LIB, source_of(lib))
	for path in [USER1, USER2]:
		var bp := probe_bp()
		var g: Dictionary = bp.graphs[0]
		var rep := Model.add_node(g, "macro", Vector2(340, 300), {"name": "Repeat", "lib": LIB})
		rep.d["i_Times"] = "3"
		g.wires = [[int(g.nodes[0].id), "then", int(rep.id), "i_In"], [int(rep.id), "o_Body", int(g.nodes[2].id), "exec"]]
		var c := Compiler.new()
		var code := c.compile(bp)
		check(c.errors.filter(func(e): return not e.w).is_empty(), "%s compiles with the library macro" % path.get_file(), str(c.errors))
		write_file(path, Model.build_source(code, bp))
	hand_edit(USER2)
	var user2 := bytes(USER2)
	var user1_before := FileAccess.get_file_as_string(USER1)
	check(await open(LIB), "the library opens")
	ed.open_member_graph("Repeat")
	var changed := [false]
	ed.mutate("Change macro", func():
		for n in ed.cur_graph().nodes:
			if n.kind == "math":
				n.d["a1"] = "2"
				changed[0] = true)
	check(changed[0], "the macro was changed")
	ed.compile_doc(ed.doc, true)
	await frames(3)
	var user1 := FileAccess.get_file_as_string(USER1)
	check(user1 != user1_before and user1.contains("- 2"), "the clean user is rewritten with the changed macro")
	check(bytes(USER2) == user2, "the hand-edited user's bytes are unchanged")
	check(ed.recompile_skipped == [USER2], "it is the one reported as skipped", str(ed.recompile_skipped))
	check(toast_has("Not rewritten") and toast_has("SC_DriftUser2.gd") and not toast_has("SC_DriftUser1.gd"), "the toast names it, once", String(ed._toast.text))
	# the same with the edited user open (and not dirty)
	check(await open(USER2), "the edited user opens")
	check(ed.doc.drift == "code" and bool(ed.doc.drift_at_open) and String(ed._drift_label.text).contains("while it was closed"), "opened, it shows the edit made while it was closed", "%s %s" % [ed.doc.drift, ed._drift_label.text])
	ed.open_schematic(LIB)
	ed.open_member_graph("Repeat")
	ed.mutate("Change macro", func():
		for n in ed.cur_graph().nodes:
			if n.kind == "math":
				n.d["a1"] = "3")
	ed.compile_doc(ed.doc, true)
	await frames(3)
	check(bytes(USER2) == user2 and ed.recompile_skipped == [USER2] and FileAccess.get_file_as_string(USER1).contains("- 3"), "open and drifted, it is skipped too; the clean one is rewritten", str(ed.recompile_skipped))
	close_clean(USER2)
	close_clean(LIB)


# 9. a file saved before the fingerprint: opens with no bar; a later outside edit is still caught
func case_old_file() -> void:
	note("--- 9. file from before the fingerprint")
	var text := source_of(probe_bp())
	var stored := Model.stored_code_hash(text)
	var old := text.replace(Model.CODE_HASH_PREFIX + stored + "\n", "")
	write_file(OLD, old)
	check(not old.contains(Model.CODE_HASH_PREFIX), "the file has no fingerprint")
	check(await open(OLD), "it opens")
	check(ed.doc.drift == "" and not bar_shown(), "with no bar", str(ed.doc.drift))
	hand_edit(OLD)
	ed.check_drift_all()
	await frames(2)
	check(ed.doc.drift == "code" and bar_shown(), "a later outside edit is caught", str(ed.doc.drift))
	close_clean(OLD)
	# an old file edited while closed cannot be told from an older plugin's code: no bar on open
	write_file(OLD, old.replace("print(", "print(\"older\", "))
	check(await open(OLD) and ed.doc.drift == "", "an old file whose code differs opens without a bar (nothing to tell a hand edit by)", str(ed.doc.drift))
	close_clean(OLD)
	# a file with the fingerprint, edited while closed: shown on open, and protected on save
	write_file(CLOSED, text)
	hand_edit(CLOSED)
	var edited := bytes(CLOSED)
	check(await open(CLOSED) and ed.doc.drift == "code" and bar_shown(), "a fingerprinted file edited while closed shows the bar on open", str(ed.doc.drift))
	check(not ed.compile_doc(ed.doc, true) and bytes(CLOSED) == edited, "and a save does not overwrite it")
	close_clean(CLOSED)


# 11 (extra). In a folder the editor scans, the file system's own signal is what notices the change
func case_scan_signal() -> void:
	note("--- file system signal")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCAN_DIR))
	write_file(SCAN, source_of(probe_bp()))
	var efs := EditorInterface.get_resource_filesystem()
	efs.scan()
	await wait_scan()
	check(await open(SCAN), "a schematic in a scanned folder opens")
	check(ed.doc.drift == "", "in sync", str(ed.doc.drift))
	await tree.create_timer(2.5).timeout   # older than DRIFT_RECENT, so only a changed time makes it look
	hand_edit(SCAN)
	var heard := [0]
	var count := func(): heard[0] += 1
	efs.filesystem_changed.connect(count)
	efs.scan()
	await wait_scan()
	var waited := 0.0
	while heard[0] == 0 and waited < 10.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	await frames(3)
	efs.filesystem_changed.disconnect(count)
	check(heard[0] > 0 and doc_of(SCAN).get("drift", "") == "code", "after the rescan's filesystem_changed the edit is noticed with nothing else asking", "signals=%d drift=%s" % [heard[0], doc_of(SCAN).get("drift", "")])
	close_clean(SCAN)
	remove_dir(SCAN_DIR)
	efs.scan()
	await wait_scan()
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SCAN_DIR)), "the scanned folder is removed again")


func wait_scan() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	var waited := 0.0
	await tree.create_timer(0.3).timeout
	while efs.is_scanning() and waited < 20.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25


# 10. the game running with Show Flow and Values: no drift for the editor's own writes; an edit made meanwhile is
# reported after the game stops and is not overwritten
func case_game() -> void:
	note("--- 10. running game with Show Flow and Values")
	demo_bytes = bytes(DEMO)
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	check(await open(DEMO), "the demo opens")
	check(ed.doc.drift == "", "in sync", str(ed.doc.drift))
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = true)
	check(ed.compile_doc(ed.doc, true), "Show Flow and Values on, saved")
	var traced := bytes(DEMO)
	check(FileAccess.get_file_as_string(DEMO).contains("__sc_trace("), "the file on disk has the trace calls")
	var states := []
	ed.flow_hits = 0
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var waited := 0.0
	while ed.flow_hits == 0 and waited < 20.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25
		ed.check_drift_all()
		states.append(String(doc_of(DEMO).drift))
	ed.save_all()
	states.append(ed._drift_check(doc_of(DEMO), true))
	check(ed.flow_hits > 0, "the game ran and reported flow (%d hits)" % ed.flow_hits)
	check(states.all(func(s): return s == ""), "while it ran, no drift was reported (%d looks)" % states.size(), str(states))
	EditorInterface.stop_playing_scene()
	await tree.create_timer(1.0).timeout
	ed.check_drift_all()
	check(bytes(DEMO) == traced and doc_of(DEMO).drift == "", "after stopping, the file is as before and in sync")
	# run again, and edit the file by hand while it runs
	ed.flow_hits = 0
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	waited = 0.0
	while ed.flow_hits == 0 and waited < 20.0:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	var edit := hand_edit(DEMO)
	var edited := bytes(DEMO)
	check(edit[0] != "", "the demo's code was edited by hand while the game ran")
	EditorInterface.stop_playing_scene()
	await tree.create_timer(1.0).timeout
	ed.check_drift_all()
	await frames(2)
	check(doc_of(DEMO).drift == "code" and bar_shown(), "after it stops, the edit is reported", str(doc_of(DEMO).drift))
	check(bytes(DEMO) == edited, "and the file still holds the edit")
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = false)
	ed.save_all()
	check(bytes(DEMO) == edited, "turning Show Flow and Values off and saving all does not overwrite it")
	close_clean(DEMO)
