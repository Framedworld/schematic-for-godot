extends RefCounted
## Editor self-test for the Generated Code tab while the game runs: the line the game is stopped at, the link between
## lines and nodes while stopped, the code that is running when the graph has unsaved changes or the file was changed
## outside Schematic, and breakpoints toggled from the code view's gutter.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_code_link_run.gd

const LOG := "res://tests/out/shot_code_link_run.log"
const BP := "res://demo/SC_Demo.gd"
const PNG := "res://tests/out/shot_code_link_run.png"
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

var plugin: EditorPlugin
var ed
var panel
var tree: SceneTree
var fails := 0
var original := ""
var done := false


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


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Ends the game if it runs and waits until the editor has seen it end. Every way out of the test goes through here.
func stop_game() -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	var waited := 0.0
	while ed._game_on and waited < 6.0:
		await tree.create_timer(0.1).timeout
		waited += 0.1
	await tree.create_timer(0.3).timeout


func cleanup() -> void:
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if ed != null and not ed.doc.is_empty():
		ed.doc.dirty = false
		ed._right_tabs.custom_minimum_size.x = 340
	if original != "":
		write_file(BP, original)


func finish() -> void:
	if done:
		return
	done = true
	cleanup()
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()


## Waits until the game is stopped and the panel has the stack of that stop and its values (as shot_debugger does).
func settle(limit := 15.0) -> bool:
	var waited := 0.0
	while waited < limit:
		await tree.create_timer(0.1).timeout
		waited += 0.1
		if panel.paused and not panel.frames.is_empty() and panel.stepping.is_empty() and panel._attached.has(panel.session_id) \
				and String(panel.frames[0][2]) != "" and panel._pending.is_empty():
			await tree.create_timer(0.3).timeout
			if panel.paused and panel.stepping.is_empty() and panel._pending.is_empty():
				await frames(4)   # (the deferred scroll to the stop line)
				return true
	return false


# ---------------------------------------------------------------- reading the file and the code view

func file_text() -> String:
	return FileAccess.get_file_as_string(BP)


func file_line(line: int) -> String:
	var lines := file_text().split("\n")
	return lines[line - 1].strip_edges() if line >= 1 and line <= lines.size() else ""


## The 1-based line of the file whose stripped text is `text`, -1 when none.
func line_of(text: String) -> int:
	var lines := file_text().split("\n")
	for i in lines.size():
		if lines[i].strip_edges() == text:
			return i + 1
	return -1


func view_line_of(text: String) -> int:
	for i in ed._code.get_line_count():
		if ed._code.get_line(i).strip_edges() == text:
			return i + 1
	return -1


func view_line(line: int) -> String:
	return ed._code.get_line(line - 1).strip_edges() if line >= 1 and line <= ed._code.get_line_count() else ""


func key_at(line: int) -> String:
	for k in ed.doc.saved_lines:
		if int(ed.doc.saved_lines[k]) == line:
			return String(k)
	return ""


## 1-based lines of the code view carrying the executing arrow.
func exec_lines() -> Array:
	var out := []
	for l in ed._code.get_executing_lines():
		out.append(int(l) + 1)
	return out


## 1-based lines painted with the stop line's colour.
func exec_painted() -> Array:
	var out := []
	for i in ed._code.get_line_count():
		if ed._code.get_line_background_color(i) == ed.EXEC_BG:
			out.append(i + 1)
	return out


func strong_lines() -> Array:
	var out := []
	for i in ed._code.get_line_count():
		if ed._code.get_line_background_color(i) == ed.LINK_STRONG:
			out.append(i + 1)
	return out


func in_view(line: int) -> bool:
	return line - 1 >= ed._code.get_first_visible_line() and line - 1 <= ed._code.get_last_full_visible_line()


func top_line() -> int:
	return int(panel.frames[0][1]) if not panel.frames.is_empty() else -1


func label_text() -> String:
	return String(ed._code_label.text)


func notice_shown() -> bool:
	return ed._code_notice.visible and String(ed._code_notice.text) != ""


func select_only(ids: Array) -> void:
	for c in ed._view.get_children():
		if c is GraphElement and not c.has_meta("gone"):
			c.selected = ids.has(int(String(c.name).trim_prefix("n")))
	await frames(4)


func selected() -> Array:
	var s: Array = ed._view.selected_ids()
	s.sort()
	return s


## Moves the caret of the code view to a 1-based line, as a click would, and waits for the editor to react.
func click_line(line: int) -> void:
	ed._code.set_caret_line(line - 1)
	ed._code.set_caret_column(0)
	await tree.create_timer(0.4).timeout
	await frames(3)


func show_graph(gid: int) -> void:
	ed.doc.graph_id = gid
	ed._refresh_graph()
	ed._refresh_graph_tabs()
	ed._refresh_members()
	await frames(4)


## Clicks the breakpoint gutter of a 1-based line of the code view with the mouse (a real input event).
func click_gutter(line: int) -> void:
	var code: CodeEdit = ed._code
	if line - 1 < code.get_first_visible_line() or line - 1 > code.get_last_full_visible_line():
		code.set_line_as_first_visible(maxi(line - 4, 0))
		await frames(3)
	var r: Rect2i = code.get_rect_at_line_column(line - 1, 0)
	var left := code.get_theme_stylebox("normal").get_margin(SIDE_LEFT)
	var at := code.get_global_rect().position + Vector2(left + code.get_gutter_width(0) * 0.5, r.position.y + r.size.y * 0.5)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		code.get_viewport().push_input(ev)
		await frames(2)
	await frames(4)


func breaks() -> Array:
	var all: Variant = EditorInterface.get_editor_settings().get_project_metadata("schematics", "breakpoints", {})
	return all.get(BP, []) if typeof(all) == TYPE_DICTIONARY else []


# ---------------------------------------------------------------- the test

func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	panel = ed.debug_panel
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(300.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		fails += 1
		finish())
	await tree.create_timer(2.5).timeout
	original = file_text()
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	note("open: %s" % ed.open_schematic(BP))
	EditorInterface.set_main_screen_editor("Schematic")
	ed._right_tabs.custom_minimum_size.x = 620
	ed._right_tabs.current_tab = 1
	await tree.create_timer(0.8).timeout

	var rotate_text := "rotate_y((deg_to_rad(spin_speed) * delta))"
	var time_text := "time = (time + delta)"
	var pos_text := "position = Vector3(0.0, wave(time), 0.0)"
	var ret_text := "return (absf(sin((t * 3.0))) * bounce_height)"
	var rotate_line := line_of(rotate_text)
	var time_line := line_of(time_text)
	var pos_line := line_of(pos_text)
	var ret_line := line_of(ret_text)
	var rotate_key := key_at(rotate_line)
	var rgid := int(rotate_key.get_slice(":", 0))
	var rid := int(rotate_key.get_slice(":", 1))
	var time_id := int(key_at(time_line).get_slice(":", 1))
	var pos_id := int(key_at(pos_line).get_slice(":", 1))
	var wave_g := Model.graph_named(ed.doc.bp, "wave")
	check(rotate_key != "" and time_id > 0 and pos_id > 0 and not wave_g.is_empty() and ret_line > 0,
		"setup: the demo's rotate, time and position nodes and its wave function were found (lines %d %d %d %d)" % [rotate_line, time_line, pos_line, ret_line])
	check(not ed._game_on and not notice_shown() and exec_lines().is_empty(), "setup: no game, no notice, no stop line")

	# ------------------------------------------------ 7. a breakpoint from the code view's gutter
	await show_graph(int(wave_g.id))   # (case 3: the graph on screen before the run is another function)
	await click_gutter(rotate_line)
	var by_click := breaks().has(rotate_key)
	if not by_click:
		note("      (the synthetic mouse click did not reach the gutter; toggling the line as the gutter does)")
		ed._code.set_line_as_breakpoint(rotate_line - 1, true)
		await frames(4)
	check(breaks() == [rotate_key], "7. a click in the gutter of the rotate line set that node's breakpoint (%s, by %s)" % [breaks(), "mouse" if by_click else "gutter call"])
	check(ed._code.is_line_breakpointed(rotate_line - 1), "7. ... and the gutter shows the mark on that line")
	var other_break: int = ed._code.get_breakpointed_lines().size()
	check(other_break == 1, "7. ... and on no other line (%d marked)" % other_break)
	check(ed.breakpoint_lines() == PackedStringArray(["%s:%d" % [BP, rotate_line]]), "7. ... it is the same breakpoint F9 on the node sets: %s" % [ed.breakpoint_lines()])
	await show_graph(int(wave_g.id))

	# ------------------------------------------------ run A: stopped at the rotate node
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var stopped: bool = await settle()
	check(stopped and top_line() == rotate_line, "1. the game stopped at the breakpoint set from the gutter (line %d)" % top_line())
	if not stopped:
		await stop_game()
		finish()
		return
	check(ed._game_on, "the editor knows the game is running")
	check(int(ed.doc.graph_id) == rgid, "3. the graph switched from the wave function to the graph the game stopped in")
	check(exec_lines() == [rotate_line] and exec_painted() == [rotate_line], "1. the code view marks line %d as the stop line (arrow %s, colour %s)" % [rotate_line, exec_lines(), exec_painted()])
	check(view_line(rotate_line) == rotate_text and file_line(rotate_line) == rotate_text, "1. the marked line is the rotate node's statement, the same text as that line of the file (%s)" % view_line(rotate_line))
	check(in_view(rotate_line), "1. the stop line is in view (lines %d..%d)" % [ed._code.get_first_visible_line() + 1, ed._code.get_last_full_visible_line() + 1])
	check(not notice_shown() and ed._code.text == String(ed.doc.preview), "1. the graph is what runs: the tab shows the graph's code and no notice")
	check(label_text().begins_with("Game stopped at line %d" % rotate_line), "1. the label says where the game stopped (%s)" % label_text())
	check(selected() == [rid], "1. the stopped node is selected in the graph beside it (%s)" % [selected()])
	# the picture: stopped, the marked line beside the highlighted node
	EditorInterface.get_base_control().queue_redraw()
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(PNG)
	note("saved " + PNG)

	# ------------------------------------------------ 4. the link while stopped
	var pause_before: int = panel.pause_id
	var paused_before: Array = ed._paused.duplicate()
	var frames_before: Array = panel.frames.duplicate(true)
	await select_only([time_id])
	check(time_line in strong_lines(), "4. selecting the time node while stopped highlights its line (%s)" % [strong_lines()])
	check(exec_lines() == [rotate_line] and exec_painted() == [rotate_line] and not (rotate_line in strong_lines()), "4. ... and the stop line keeps its own mark, apart from the highlight")
	await click_line(pos_line)
	check(selected() == [pos_id], "4. moving the caret to the position line selects the node that wrote it (%s)" % [selected()])
	check(label_text().begins_with("Line %d" % pos_line), "4. ... the label names the line (%s)" % label_text())
	check(exec_lines() == [rotate_line], "4. ... and the stop line did not move (%s)" % [exec_lines()])
	check(panel.paused and panel.pause_id == pause_before and ed._paused == paused_before and panel.frames == frames_before,
		"4. the game is still stopped at the same node: same stop, same stack (%s)" % [panel.frames])
	check(ed.link_stats.selection_runs > 0 and selected() == [pos_id] and ed._code.get_caret_line() == pos_line - 1, "4. the caret and the selection stayed where each side put them")

	# ------------------------------------------------ 1. step over twice, then into wave
	panel.step("next")
	check(await settle() and top_line() == time_line, "1. step over stopped at the time node (line %d)" % top_line())
	check(exec_lines() == [time_line] and exec_painted() == [time_line] and view_line(time_line) == time_text, "1. the stop line followed it: line %d (%s)" % [time_line, view_line(time_line)])
	panel.step("next")
	check(await settle() and top_line() == pos_line, "1. second step over stopped at the position node (line %d)" % top_line())
	check(exec_lines() == [pos_line] and view_line(pos_line) == pos_text and in_view(pos_line), "1. the stop line followed again: line %d, in view" % pos_line)
	panel.step("step")
	check(await settle() and top_line() == ret_line, "3. step into stopped in the wave function (line %d)" % top_line())
	check(String(ed.cur_graph().get("name", "")) == "wave", "3. the graph shows the wave function (%s)" % ed.cur_graph().get("name", ""))
	check(exec_lines() == [ret_line] and view_line(ret_line) == ret_text and in_view(ret_line), "3. the code view scrolled to the wave line and marks it (%s, visible %d..%d)" % [exec_lines(), ed._code.get_first_visible_line() + 1, ed._code.get_last_full_visible_line() + 1])

	if not in_view(ret_line):
		note("      diag: visible count %d, first %d, exec_line0 %d, tab %d" % [ed._code.get_visible_line_count(), ed._code.get_first_visible_line(), ed._exec_line0(), ed._right_tabs.current_tab])
		ed._exec_scroll()
		await frames(3)
		note("      diag: after a direct _exec_scroll, first visible %d" % (ed._code.get_first_visible_line() + 1))

	# ------------------------------------------------ 7. the gutter again removes the breakpoint; continue
	await click_gutter(rotate_line)
	if breaks().has(rotate_key):
		ed._code.set_line_as_breakpoint(rotate_line - 1, false)
		await frames(4)
	check(breaks().is_empty() and not ed._code.is_line_breakpointed(rotate_line - 1), "7. a second click in the gutter removed the breakpoint (%s)" % [breaks()])
	ed.debug_continue()
	await tree.create_timer(1.5).timeout
	check(not panel.paused, "7. ... and the game did not stop there again after Continue")
	check(exec_lines().is_empty() and exec_painted().is_empty(), "1. Continue: the stop line is gone (%s %s)" % [exec_lines(), exec_painted()])
	check(label_text().begins_with("The game is running") and label_text().contains("SC_Demo.gd"), "5. while it plays, the label says the game is running and whose code is shown (%s)" % label_text())
	await stop_game()
	check(not ed._game_on and label_text() == "" and not notice_shown(), "the game ended: the label and notice are empty")

	# ------------------------------------------------ run B: Show Flow and Values on (the file has trace calls)
	await show_graph(rgid)
	ed.mutate("Show Flow and Values (test)", func(): ed.doc.bp["trace"] = true)
	check(ed.compile_doc(ed.doc, true), "2. saved with Show Flow and Values on")
	var t_rotate := line_of(rotate_text)
	var t_key := "%d:%d" % [rgid, rid]
	check(t_rotate > rotate_line and file_text().contains("__sc_trace("), "2. the file has trace lines: the rotate statement moved from line %d to %d" % [rotate_line, t_rotate])
	ed.toggle_breakpoints([rid])
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	stopped = await settle()
	var t_stop := top_line()
	note("      breakpoint line of the node %d (%s), statement line %d" % [int(ed.doc.saved_lines.get(t_key, -1)), file_line(int(ed.doc.saved_lines.get(t_key, -1))), t_rotate])
	check(stopped and t_stop == int(ed.doc.saved_lines.get(t_key, -1)), "2. the game stopped at the node's breakpoint (line %d: %s)" % [t_stop, file_line(t_stop)])
	check(exec_lines() == [t_rotate] and view_line(t_rotate) == rotate_text and file_line(t_rotate) == rotate_text,
		"2. the marked line is the node's statement, line %d of the file, not a trace line (%s)" % [t_rotate, exec_lines()])
	check(not view_line(exec_lines()[0] if not exec_lines().is_empty() else 0).begins_with("__sc_trace"), "2. ... nothing marked is a trace line")
	check(in_view(t_rotate) and not notice_shown(), "2. ... it is in view, and no notice (the graph is what runs)")
	ed.toggle_breakpoints([rid])
	await stop_game()
	ed.mutate("Show Flow and Values off (test)", func(): ed.doc.bp["trace"] = false)
	check(ed.compile_doc(ed.doc, true) and line_of(rotate_text) == rotate_line, "2. saved with it off again: the rotate statement is back on line %d" % rotate_line)

	# ------------------------------------------------ run C: unsaved changes while the game runs
	await show_graph(rgid)
	ed.toggle_breakpoints([rid])
	var saved_code := Model.code_part(file_text())
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	stopped = await settle()
	check(stopped and top_line() == rotate_line, "5. run C stopped at the rotate node (line %d)" % top_line())
	# (Godot saves open Schematics before it runs a game, so the unsaved change is made while the game runs)
	var after_line := line_of("print(\"Sequence does not wait for the Delay\")")
	var after_id := int(key_at(after_line).get_slice(":", 1))
	var g: Dictionary = ed.cur_graph()
	var exec_out := ""
	for pin in R.describe(Model.find_node(g, after_id), ed.doc.bp, g).outs:
		if String(pin.type) == "exec":
			exec_out = String(pin.id)
	var new_id := [0]
	ed.mutate("Add Print (test)", func():
		var pr := Model.add_node(g, "print", Vector2(1400, 300), {})
		new_id[0] = int(pr.id)
		g.wires.append([after_id, exec_out, int(pr.id), "exec"]))
	await frames(6)
	check(ed.doc.dirty and Model.normalize_code(String(ed.doc.preview)) != saved_code, "5. the graph now has an unsaved Print node after line %d" % after_line)
	check(Model.normalize_code(ed._code.text) == saved_code, "5. the tab shows the saved code the game runs (the file's code part), not the graph's")
	check(notice_shown() and String(ed._code_notice.text) == "Showing the saved code the game is running. The graph has unsaved changes.", "5. the notice says so: %s" % ed._code_notice.text)
	check(exec_lines() == [rotate_line] and view_line(rotate_line) == rotate_text, "5. the stop line is on line %d of that code, the rotate statement" % rotate_line)
	await select_only([new_id[0]])
	check(strong_lines().is_empty() and label_text().contains("not in the code the game is running"), "5. selecting the unsaved Print node highlights nothing and the label says why (%s)" % label_text())
	await select_only([time_id])
	check(time_line in strong_lines(), "5. a node that is in the running code highlights its line there (%s)" % [strong_lines()])
	await click_line(rotate_line)
	check(selected() == [rid], "5. a line of the running code selects its node in the graph (%s)" % [selected()])
	ed.toggle_breakpoints([rid])   # (this saves the graph, as F9 does; the game keeps the code it started with)
	check(Model.normalize_code(ed._code.text) == saved_code and exec_lines() == [rotate_line], "5. a save while stopped: the tab still shows the code the game runs, the stop line unmoved")
	check(String(ed._code_notice.text) == "Showing the saved code the game is running. The graph was saved after the game started.", "5. ... and the notice now says the graph was saved since (%s)" % ed._code_notice.text)
	await stop_game()
	check(not notice_shown() and ed._code.text == String(ed.doc.preview) and Model.normalize_code(ed._code.text) != saved_code, "5. the game ended: the tab shows the graph's current code again, with the new line, and no notice")
	check(view_line_of(rotate_text) == rotate_line + 1, "5. ... in which the rotate statement is one line further down (%d)" % view_line_of(rotate_text))
	# put the file and the document back as they were
	write_file(BP, original)
	ed.doc.dirty = false
	ed._drift_check(ed.doc, true)
	ed._close_doc(ed.docs.find(ed.doc))
	EditorInterface.get_resource_filesystem().update_file(BP)
	await frames(4)
	ed.open_schematic(BP)
	ed._right_tabs.current_tab = 1
	await frames(6)
	check(Model.normalize_code(ed._code.text) == Model.code_part(original) and String(ed.doc.drift) == "", "setup: the demo is back as it was and in sync")

	# ------------------------------------------------ run D: the file's code changed outside Schematic
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	var lines := original.split("\n")
	var edited_at := line_of("print(\"Sequence does not wait for the Delay\")")
	lines[edited_at - 1] = lines[edited_at - 1].replace("Sequence does not wait for the Delay", "Edited by hand")
	write_file(BP, "\n".join(lines))
	ed._drift_check(ed.doc, true)
	check(String(ed.doc.drift) == "code", "6. the file's code was edited outside Schematic (drift: %s)" % ed.doc.drift)
	await show_graph(rgid)
	ed.toggle_breakpoints([rid])
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	stopped = await settle()
	check(stopped and top_line() == rotate_line, "6. run D stopped at the rotate breakpoint (line %d)" % top_line())
	check(file_line(edited_at).contains("Edited by hand") and Model.normalize_code(ed._code.text) == Model.code_part(file_text()), "6. the tab shows the file's code as edited, which the game runs")
	check(notice_shown() and String(ed._code_notice.text) == "Showing the saved code the game is running. The file was changed outside Schematic.", "6. the notice says the file was changed outside Schematic (%s)" % ed._code_notice.text)
	check(exec_lines() == [top_line()] and view_line(top_line()) == file_line(top_line()), "6. the stop line is the line the engine reports (%d: %s)" % [top_line(), view_line(top_line())])
	var run_rec: Dictionary = ed._run_rec(BP)
	check(not bool(run_rec.get("exact", true)) and ed._shown_link() == null, "6. the edited code is not what its stored graph makes: the link is off")
	await click_line(pos_line)
	check(selected().is_empty() and label_text().contains("not linked"), "6. a clicked line selects nothing and the label says the lines are not linked (%s)" % label_text())
	await select_only([time_id])
	check(strong_lines().is_empty() and label_text().contains("not linked") and exec_lines() == [top_line()], "6. a selected node highlights nothing, says why, and the stop line stays (%s)" % label_text())
	ed.toggle_breakpoints([rid])
	await stop_game()
	check(not notice_shown() and ed._code.text == String(ed.doc.preview), "6. the game ended: the tab shows the graph's code again")
	write_file(BP, original)
	ed._drift_check(ed.doc, true)

	# ------------------------------------------------ the end
	await stop_game()
	check(not EditorInterface.is_playing_scene() and not ed._game_on, "no game is left running")
	finish()
