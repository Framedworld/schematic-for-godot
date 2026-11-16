extends RefCounted
## Editor self-test: the comments a converted script's nodes carry (p.note, p.tail, ...) are shown on the graph as
## bubbles, can be edited in the Details panel (one undo step each), are found by Find, and are tied to the
## generated code by the code link. tests/convert/comments.gd is copied under res://tests/tmp/nodecomments/
## (git-ignored), converted at run time, opened, and removed again.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_node_comments.gd
## Writes tests/out/shot_node_comments.png (a graph with several bubbles) and the log tests/out/shot_node_comments_checks.log.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const NodeVisual := preload("res://addons/schematic/editor/sc_graph_node.gd")

const SRC := "res://tests/convert/comments.gd"
const LOG := "res://tests/out/shot_node_comments_checks.log"
const PNG := "res://tests/out/shot_node_comments.png"
const PNG2 := "res://tests/out/shot_node_comments_event.png"
const DIR := "res://tests/tmp/nodecomments"
const PATH := DIR + "/SC_NodeComments.gd"
const LARGE := DIR + "/SC_Large.gd"
const BIG := DIR + "/SC_Big.gd"
const BIG_PLAIN := DIR + "/SC_BigPlain.gd"

var plugin: EditorPlugin
var ed
var tree: SceneTree
var view
var fails := 0
var timings := []
# the nodes the checks are about, found by what they carry (set after the file is open)
var n_entry := 0   # move: the function's entry (note and tail)
var n_set := 0     # move: `position.x += ...` (a one-line note and a tail)
var n_ret := 0     # move: `return` in the branch (a note, no tail)
var n_dbg := 0     # EventGraph: `breakpoint` (a tail)
var n_loop := 0    # EventGraph: a statement in a loop (note, tail and an after)
var n_empty := 0   # EventGraph: a branch with the comment of an empty block
var n_last := 0    # EventGraph: the last statement (`moved.emit`, tail "told")
var n_else := 0    # EventGraph: first thing in the else


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


# ---------------------------------------------------------------- helpers

func code() -> String:
	ed._check(ed.doc)
	return String(ed.doc.preview)


func history() -> UndoRedo:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(ed))


func undo() -> void:
	history().undo()
	await frames(4)


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


func graph_named(name: String) -> Dictionary:
	return Model.graph_named(ed.doc.bp, name)


func node_of(g: Dictionary, id: int) -> Dictionary:
	return Model.find_node(g, id)


func gnode(id: int):
	return view.get_node_or_null("n%d" % id)


func show_graph(g: Dictionary) -> void:
	ed.doc.graph_id = int(g.id)
	ed._refresh_graph()
	ed._refresh_graph_tabs()
	ed._refresh_members()
	await frames(4)


func select_only(ids: Array) -> void:
	for c in view.get_children():
		if c is GraphElement and not c.has_meta("gone"):
			c.selected = ids.has(int(String(c.name).trim_prefix("n")))
	await frames(4)


func fit_view(g: Dictionary, top_pad := 70.0) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		lo = Vector2(minf(lo.x, float(n.x)), minf(lo.y, float(n.y)))
		hi = Vector2(maxf(hi.x, float(n.x) + 300.0), maxf(hi.y, float(n.y) + 220.0))
	var z := minf(1.0, minf((view.size.x - 40.0) / (hi.x - lo.x), (view.size.y - 40.0) / (hi.y - lo.y)))
	view.zoom = maxf(z, 0.4)
	view.scroll_offset = lo * view.zoom - Vector2(20, top_pad)


func note_box() -> TextEdit:
	for te in ed._details.find_children("*", "TextEdit", true, false):
		if te.has_meta("node_note"):
			return te
	return null


func tail_line() -> LineEdit:
	for le in ed._details.find_children("*", "LineEdit", true, false):
		if le.has_meta("node_tail"):
			return le
	return null


## Types into the Comment box the way a person does: set the text, leave the box.
func set_box(text: String) -> bool:
	var te := note_box()
	if te == null:
		return false
	te.text = text
	te.focus_exited.emit()
	await frames(4)
	return true


func set_tail(text: String) -> bool:
	var le := tail_line()
	if le == null:
		return false
	le.text = text
	le.focus_exited.emit()
	await frames(4)
	return true


func line_of(text: String, needle: String) -> int:
	var lines := text.split("\n")
	for i in lines.size():
		if lines[i].contains(needle):
			return i
	return -1


func lead_tabs(line: String) -> int:
	var k := 0
	while k < line.length() and line[k] == "\t":
		k += 1
	return k


## The words a node's comments are made of, the way the bubble shows them.
func want_text(n: Dictionary) -> Array:
	return [" ".join(NodeVisual.note_plain(n.p.get("note", []))), NodeVisual.tail_plain(String(n.p.get("tail", "")))]


func shown_text(gn) -> Array:
	return [" ".join(gn._lay_note), String(gn._lay_tail)]


func fits(shown: String, want: String) -> bool:
	want = " ".join(want.split(" ", false))   # (the bubble wraps words: runs of spaces become one)
	return shown == want or (shown.ends_with("...") and want.begins_with(shown.trim_suffix("...")))


func geometry(gn) -> Dictionary:
	var ins := []
	var outs := []
	for i in gn.get_input_port_count():
		ins.append(gn.get_input_port_position(i))
	for i in gn.get_output_port_count():
		outs.append(gn.get_output_port_position(i))
	return {"size": gn.size, "ins": ins, "outs": outs}


## What the view shows with node `id` of graph `g` near its top left, at zoom 1.0: a 440 x 300 piece of the window.
func tile(g: Dictionary, id: int) -> Image:
	await show_graph(g)
	view.zoom = 1.0
	var n := node_of(g, id)
	view.scroll_offset = Vector2(float(n.x), float(n.y)) - Vector2(40, 150)
	await tree.create_timer(0.5).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	return img.get_region(Rect2i(Vector2i(view.get_global_rect().position) + Vector2i(10, 30), Vector2i(440, 300)))


func crop(path: String, c: Control) -> void:
	await tree.create_timer(0.5).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	var r := Rect2(c.get_global_rect()).intersection(Rect2(Vector2.ZERO, img.get_size()))
	img.get_region(Rect2i(r)).save_png(path)
	note("    saved %s %s" % [path, r])


# synthetic mouse, as tests/shot_input.gd does it
func mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)
	await frames(2)


func mouse_move(from: Vector2, to: Vector2, held := true) -> void:
	if ed.get_viewport().gui_get_hovered_control() == null:
		ed.get_viewport().notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	for i in range(1, 9):
		var ev := InputEventMouseMotion.new()
		var p := from.lerp(to, i / 8.0)
		ev.position = p
		ev.global_position = p
		ev.relative = (to - from) / 8.0
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
		Input.parse_input_event(ev)
		await frames(1)


func click(pos: Vector2) -> void:
	await mouse_move(pos - Vector2(4, 4), pos, false)
	await mouse_button(pos, true)
	await mouse_button(pos, false)


func drag(from: Vector2, to: Vector2) -> void:
	await mouse_move(from - Vector2(4, 4), from, false)
	await mouse_button(from, true)
	await mouse_move(from, to, true)
	await mouse_button(to, false)
	await frames(3)


func out_port(id: int, pin_id: String) -> Vector2:
	var n = gnode(id)
	return n.global_position + n.get_output_port_position(view._port_of(n.out_pins, pin_id)) * view.zoom


func in_port(id: int, pin_id: String) -> Vector2:
	var n = gnode(id)
	return n.global_position + n.get_input_port_position(view._port_of(n.in_pins, pin_id)) * view.zoom


func title_point(id: int) -> Vector2:
	var n = gnode(id)
	return n.global_position + Vector2(60, 12) * view.zoom


func cleanup() -> void:
	if ed != null:
		ed._right_tabs.custom_minimum_size.x = 340
		ed._comments_btn.button_pressed = false
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


## A script of `statements` statements in one function, a comment above every `every`-th of them (0: none).
func big_source(statements: int, every: int) -> String:
	var src := "extends Node\n\nvar journal: Array = []\nvar total := 0\n\n\nfunc _ready() -> void:\n"
	for i in statements:
		if every > 0 and i % every == 0:
			src += "\t# step %d: what the next line does, written in a few words so it wraps\n" % i
		match i % 3:
			0:
				src += "\tjournal.append(\"line %d\")\n" % i
			1:
				src += "\ttotal += %d\n" % i
			_:
				src += "\tprint(total, %d)\n" % i
	return src


## Opens `path` as a document and times it, up to the first frame drawn: [milliseconds, nodes in the first graph].
func time_open(path: String, hidden: bool) -> Array:
	ed._comments_btn.button_pressed = hidden
	await frames(2)
	var t0 := Time.get_ticks_usec()
	ed.open_schematic(path)
	await RenderingServer.frame_post_draw
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var count: int = ed.cur_graph().nodes.size()
	for i in range(ed.docs.size() - 1, -1, -1):
		if ed.docs[i].path == path:
			ed.docs[i].dirty = false
			ed._close_doc(i)
	await frames(3)
	return [ms, count]


func median(a: Array) -> float:
	var c := a.duplicate()
	c.sort()
	return float(c[c.size() / 2])


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
	tree.create_timer(500.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout

	# ------------------------------------------------ set up: convert the sample, open it
	var text := FileAccess.get_file_as_string(SRC)
	check(text != "" and not text.contains("res://tests/convert/"), "setup: the sample is read (%d bytes) and refers to no path" % text.length())
	var out: Dictionary = Importer.new().convert(text, {"path": PATH})
	var bp: Dictionary = out.bp
	write_file(PATH, Model.build_source(Compiler.new().compile(bp), bp))
	EditorInterface.get_resource_filesystem().update_file(PATH)
	await tree.create_timer(0.6).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.5).timeout
	check(ed.open_schematic(PATH) and ed.doc.path == PATH and ed.doc.errors.is_empty(), "setup: the converted file opens in the editor with no error", str(ed.doc.errors))
	view = ed._view
	ed._right_tabs.custom_minimum_size.x = 700
	var g_move := graph_named("move")
	var g_event := graph_named("EventGraph")
	check(not g_move.is_empty() and not g_event.is_empty(), "setup: the event graph and `move` exist")
	var noted := 0
	for g in ed.doc.bp.graphs:
		for n in g.nodes:
			if n.p.has("note") or n.p.has("tail"):
				noted += 1
	check(noted >= 12, "setup: the graphs hold comments (%d nodes carry a note or a tail)" % noted)
	var find := func(g: Dictionary, key: String, needle: String) -> int:
		for n in g.nodes:
			if JSON.stringify(n.p.get(key, "")).contains(needle):
				return int(n.id)
		return 0
	for n in g_move.nodes:
		if n.kind == "fn_entry":
			n_entry = int(n.id)
	n_set = find.call(g_move, "note", "a comment line above a statement")
	n_ret = find.call(g_move, "note", "the only thing in a branch")
	n_dbg = find.call(g_event, "tail", "stops in the debugger")
	n_loop = find.call(g_event, "note", "inside a loop")
	n_empty = find.call(g_event, "empty", "nothing to do yet")
	n_last = find.call(g_event, "tail", "told")
	n_else = find.call(g_event, "note", "first thing in the else")
	check(n_entry > 0 and n_set > 0 and n_ret > 0 and n_dbg > 0 and n_loop > 0 and n_empty > 0 and n_last > 0 and n_else > 0, "setup: the nodes the checks are about are found",
		str([n_entry, n_set, n_ret, n_dbg, n_loop, n_empty, n_last, n_else]))

	# ------------------------------------------------ 1. bubbles
	var with_bubble := 0
	var without := 0
	var bad := []
	var entry_ok := false
	var tail_ok := false
	var blank_only := 0
	for g in ed.doc.bp.graphs:
		await show_graph(g)
		for n in g.nodes:
			if n.kind == "comment":
				continue
			var gn = gnode(int(n.id))
			if gn == null:
				bad.append("%s #%d has no visual" % [g.name, n.id])
				continue
			var want := want_text(n)
			var got := shown_text(gn)
			if want[0] == "" and want[1] == "":
				without += 1
				if n.p.has("note"):
					blank_only += 1
				if gn.comment_shown() or got[0] != "" or got[1] != "" or gn.comment_draws != 0:
					bad.append("%s #%d (%s) has no comment but a bubble" % [g.name, n.id, n.kind])
			else:
				with_bubble += 1
				if not (gn.comment_shown() and gn.comment_draws > 0 and fits(got[0], want[0]) and fits(got[1], want[1])):
					bad.append("%s #%d (%s) wants %s, shows %s (drawn %d times)" % [g.name, n.id, n.kind, want, got, gn.comment_draws])
				if n.kind == "fn_entry" and String(g.name) == "move" and got[0].contains("Comment above a function"):
					entry_ok = true
				if int(n.id) == n_set and String(g.name) == "move" and got[1] == "a trailing comment":
					tail_ok = true
	check(bad.is_empty() and with_bubble >= 12, "1. every node with a note or a tail shows a bubble with its words (%d), the others (%d) show none" % [with_bubble, without], "; ".join(bad.slice(0, 6)))
	check(blank_only >= 1, "1. a note of nothing but a blank line shows no bubble (%d such nodes)" % blank_only)
	check(entry_ok, "1. the function's entry node shows its leading comment")
	check(tail_ok, "1. a node with a tail shows it (\"a trailing comment\")")
	# the tooltip has the rest: after-lines, and the comment of an empty block on its pin
	await show_graph(g_event)
	var gn49 = gnode(n_empty)
	var gn11 = gnode(n_loop)
	var pin_tip := ""
	for row in gn49.get_children():
		pin_tip += String(row.tooltip_text) if row is Control else ""
	check(String(gn11.tooltip_text).contains("end of the loop body") and String(gn11.tooltip_text).contains("inside a loop"), "1. a node's tooltip has its note and the comment below it", gn11.tooltip_text)
	check(pin_tip.contains("nothing to do yet"), "1. the comment of an empty block is in the tooltip of its pin", pin_tip)

	# ------------------------------------------------ the picture: four nodes at the default zoom (1:1), each as the editor draws it
	var arm := 0
	for n in g_event.nodes:
		if JSON.stringify(n.p.get("note", "")).contains("inside an arm"):
			arm = int(n.id)
	var tiles := [await tile(g_move, n_entry), await tile(g_move, n_set), await tile(g_event, arm), await tile(g_event, n_loop)]
	var sheet := Image.create(880, 600, false, Image.FORMAT_RGBA8)
	for i in tiles.size():
		var t: Image = tiles[i]
		t.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(t, Rect2i(Vector2i.ZERO, t.get_size()), Vector2i((i % 2) * 440, (i / 2) * 300))
	sheet.save_png(PNG)
	note("    saved %s: four tiles at zoom 1.0 (the function's entry, a statement with a note and a tail, an arm with two note lines + a tail, a statement in a loop)" % PNG)
	await show_graph(g_move)
	fit_view(g_move)

	# ------------------------------------------------ 2. the bubble moves nothing
	var ids := [n_entry, n_set, n_ret]
	await show_graph(g_move)
	var before_geo := {}
	for id in ids:
		before_geo[id] = geometry(gnode(id))
	var code_with := code()
	ed.mutate("Remove Test Comments", func():
		for id in ids:
			var np: Dictionary = node_of(graph_named("move"), id).p
			for k in ["note", "tail", "after"]:
				np.erase(k))
	await frames(4)
	var geo_same := true
	var details := []
	for id in ids:
		var after_geo := geometry(gnode(id))
		if after_geo != before_geo[id]:
			geo_same = false
			details.append("#%d with %s without %s" % [id, before_geo[id], after_geo])
		if gnode(id).comment_shown():
			geo_same = false
	check(geo_same, "2. pin positions and size of three nodes with bubbles equal those of the same nodes without their comments", "; ".join(details))
	check(code() != code_with, "2. (the comments are really gone from the code in the second state)")
	await undo()
	check(code() == code_with, "2. undo brings the comments back")
	await show_graph(graph_named("move"))

	# ------------------------------------------------ 3. hide toggle
	var bubble_ids := []
	for n in graph_named("move").nodes:
		if gnode(int(n.id)) != null and gnode(int(n.id)).comment_shown():
			bubble_ids.append(int(n.id))
	check(bubble_ids.size() >= 3, "3. `move` shows %d bubbles to start with" % bubble_ids.size())
	var draws_before := {}
	ed._comments_btn.button_pressed = true
	await frames(4)
	var none_shown := true
	for id in bubble_ids:
		draws_before[id] = gnode(id).comment_draws
		if gnode(id).comment_shown():
			none_shown = false
	await frames(4)
	var no_draws := true
	for id in bubble_ids:
		if gnode(id).comment_draws != draws_before[id]:
			no_draws = false
	check(view.hide_comments and none_shown and no_draws, "3. the Hide Comments button hides every bubble (none drawn while hidden)")
	await show_graph(g_event)
	var hidden_all := true
	for n in g_event.nodes:
		if n.kind != "comment" and gnode(int(n.id)) != null and gnode(int(n.id)).comment_shown():
			hidden_all = false
	check(hidden_all, "3. the setting stays when another graph is shown")
	await show_graph(graph_named("move"))
	var draws_hidden := {}
	for id in bubble_ids:
		draws_hidden[id] = gnode(id).comment_draws   # (the graph was rebuilt: its nodes count from zero)
	ed._comments_btn.button_pressed = false
	await frames(4)
	var back := true
	for id in bubble_ids:
		if not gnode(id).comment_shown() or gnode(id).comment_draws <= draws_hidden[id]:
			back = false
	check(not view.hide_comments and back, "3. un-pressing it shows them again (drawn again)")

	# ------------------------------------------------ 4. editing one note
	await show_graph(graph_named("move"))
	await select_only([n_set])
	var tb := note_box()
	var tl := tail_line()
	check(tb != null and tb.text == "a comment line above a statement" and tl != null and tl.text == "a trailing comment", "4. selecting the node shows its note and its tail in the Details panel without the #", "%s / %s" % [tb.text if tb else "no box", tl.text if tl else "no line"])
	await select_only([])
	ed.edit_node_note(n_set)   # what the right-click item "Edit Comment" calls
	await frames(3)
	check(String(ed._sel.kind) == "node" and int(ed._sel.id) == n_set and note_box() != null and note_box().has_focus(), "4. Edit Comment (the right-click item) shows the node's Comment box with the cursor in it", "sel %s focus %s" % [ed._sel, note_box().has_focus() if note_box() else "no box"])
	ed.doc.dirty = false
	var base := code()
	var old_line := line_of(base, "# a comment line above a statement")
	var old_text := base.split("\n")[old_line]
	check(old_line > 0 and lead_tabs(old_text) == 1, "4. the generated code has the comment line (indented one tab) and its statement", old_text)
	await set_box("a comment line, reworded")
	var after := code()
	var d := diff_lines(base, after)
	check(d[0] == [old_text] and d[1] == ["\t# a comment line, reworded"], "4. changing the words changes that one comment line, at the same indentation, and nothing else", str(d))
	check(ed.doc.dirty, "4. the document is marked changed")
	check(node_of(graph_named("move"), n_set).p.note == ["# a comment line, reworded"], "4. the stored note is the one comment line")
	await undo()
	check(code() == base and not (node_of(graph_named("move"), n_set).p.note != ["# a comment line above a statement"]), "4. one undo restores the exact code and the note")
	await select_only([n_set])
	check(note_box() != null and note_box().text == "a comment line above a statement", "4. ... and the box shows the old words again")
	await set_box("first line\nsecond line")
	d = diff_lines(base, code())
	check(d[0] == [old_text] and d[1] == ["\t# first line", "\t# second line"], "4. a second line becomes a second comment line at the same indentation", str(d))
	await undo()
	await select_only([n_set])
	await set_box("")
	d = diff_lines(base, code())
	check(d[0] == [old_text] and d[1].is_empty() and not node_of(graph_named("move"), n_set).p.has("note"), "4. clearing the box removes the comment line (and the note)", str(d))
	await undo()
	check(code() == base, "4. undo again restores the code")
	# a comment after the line on a node that had none (the `return` in the branch, which has a note only)
	await select_only([n_ret])
	var ret_line := line_of(base, "\t\treturn")
	check(tail_line() != null and tail_line().text == "" and ret_line > 0, "4. a node without a tail shows an empty 'Comment after the line'")
	await set_tail("it stays blocked")
	d = diff_lines(base, code())
	check(d[0] == ["\t\treturn"] and d[1] == ["\t\treturn  # it stays blocked"], "4. a Comment after the line adds `  # text` to the generated line", str(d))
	await undo()
	check(code() == base, "4. undo removes it again")
	await select_only([n_set])
	await set_tail("a reworded tail")
	d = diff_lines(base, code())
	check(d[1].size() == 1 and String(d[1][0]).ends_with("# a reworded tail") and d[0].size() == 1 and String(d[0][0]).contains("# a trailing comment"), "4. changing a tail keeps the line and the spacing before the #", str(d))
	check(String(node_of(graph_named("move"), n_set).p.tail).begins_with("   # "), "4. ... (three spaces, as written)")
	await undo()

	# ------------------------------------------------ 5. blank lines and indentation markers are kept
	var stored := ["# one", "", "\t# deeper two", "# three"]
	ed.mutate("Set Test Note", func(): node_of(graph_named("move"), n_set).p["note"] = stored.duplicate())
	ed._select({"kind": "node", "id": n_set}, false)
	await frames(3)
	check(note_box() != null and note_box().text == "one\ndeeper two\nthree", "5. a note with a blank line and a marker shows as three plain lines", note_box().text if note_box() else "")
	var base5 := code()
	await set_box("one\ndeeper TWO\nthree")
	check(node_of(graph_named("move"), n_set).p.note == ["# one", "", "\t# deeper TWO", "# three"], "5. changing one word keeps the blank line and the marker", str(node_of(graph_named("move"), n_set).p.note))
	d = diff_lines(base5, code())
	check(d[0] == ["\t\t# deeper two"] and d[1] == ["\t\t# deeper TWO"], "5. ... and only that comment line of the code changes", str(d))
	await set_box("one\ndeeper TWO\nthree\nfour")
	check(node_of(graph_named("move"), n_set).p.note == ["# one", "", "\t# deeper TWO", "# three", "# four"], "5. a line added at the end keeps the others as they were", str(node_of(graph_named("move"), n_set).p.note))
	await set_box("deeper TWO\nthree\nfour")
	check(node_of(graph_named("move"), n_set).p.note == ["\t# deeper TWO", "# three", "# four"], "5. a line removed at the start keeps the others as they were", str(node_of(graph_named("move"), n_set).p.note))
	await set_box("# own marker\nplain")
	check(node_of(graph_named("move"), n_set).p.note == ["# own marker", "# plain"], "5. a different number of lines in the middle is written new at the statement's depth; a line that starts with # is taken as typed", str(node_of(graph_named("move"), n_set).p.note))
	ed.mutate("Set Test Note", func(): node_of(graph_named("move"), n_set).p["note"] = ["## doc one", "# two"])
	ed._select({"kind": "node", "id": n_set}, false)
	await frames(3)
	await set_box("doc ONE\ntwo")
	check(node_of(graph_named("move"), n_set).p.note == ["## doc ONE", "# two"], "5. a ## line stays ##", str(node_of(graph_named("move"), n_set).p.note))
	await set_box("## doc ONE\ntwo")
	check(node_of(graph_named("move"), n_set).p.note == ["## doc ONE", "# two"], "5. a line typed with ## is taken as typed (and an unchanged one is kept)")
	# the pure functions
	check(NodeVisual.note_from_text([], "a\n\n b ") == ["# a", "# b"] and NodeVisual.note_from_text(["# x"], " \n") == [], "5. note_from_text: blank lines of the box are dropped, an empty box gives no note")
	check(NodeVisual.tail_from_text("", "why") == "  # why" and NodeVisual.tail_from_text("   # old", "new") == "   # new" and NodeVisual.tail_from_text("  # old", "old") == "  # old" and NodeVisual.tail_from_text("  # old", "") == "", "5. tail_from_text: spacing kept, unchanged kept, empty removes")
	ed.mutate("Restore Test Note", func(): node_of(graph_named("move"), n_set).p["note"] = ["# a comment line above a statement"])
	await frames(3)

	# ------------------------------------------------ 6. a node made in the editor
	await show_graph(g_event)
	var last := node_of(graph_named("EventGraph"), n_last)
	var last_pin := {}
	for pin in R.describe(last, ed.doc.bp, graph_named("EventGraph")).outs:
		if pin.type == "exec":
			last_pin = pin
	var act := {}
	for a in R.static_actions():
		if a.k == "print":
			act = a
	check(not last.is_empty() and not last_pin.is_empty() and not act.is_empty(), "6. the end of _ready's chain (emit) and a Print String action are found")
	var ids_before: Array = graph_named("EventGraph").nodes.map(func(n): return int(n.id))
	view.spawn(act.k, act.p, Vector2(float(last.x) + 330.0, float(last.y)), {"type": "exec", "out": true, "node": int(last.id), "pin": last_pin})
	await frames(4)
	var printer := {}
	for n in graph_named("EventGraph").nodes:
		if not ids_before.has(int(n.id)):
			printer = n
	check(not printer.is_empty(), "6. a Print String node was added to _ready")
	var pid := int(printer.id)
	view.pin_default_changed(pid, "text", "\"added in the editor\"")
	await frames(3)
	var base6 := code()
	await select_only([pid])
	check(note_box() != null and note_box().text == "", "6. its Comment box is empty")
	await set_box("added by hand")
	var c6 := code().split("\n")
	var pl := -1
	for i in c6.size():
		if c6[i].contains("added in the editor"):
			pl = i
	check(pl > 0 and c6[pl - 1] == "\t# added by hand" and lead_tabs(c6[pl]) == 1, "6. a hand-made node given a comment has the comment above its line, at its indentation", "%s | %s" % [c6[pl - 1] if pl > 0 else "", c6[pl] if pl >= 0 else "none"])
	d = diff_lines(base6, code())
	check(d[0].is_empty() and d[1] == ["\t# added by hand"], "6. nothing else changed", str(d))
	await show_graph(graph_named("EventGraph"))
	check(gnode(pid).comment_shown() and fits(shown_text(gnode(pid))[0], "added by hand"), "6. and it shows a bubble")
	# a second hand-made node, free: for the interaction checks below
	view.spawn(act.k, act.p, Vector2(float(last.x) + 330.0, float(last.y) + 230.0))
	await frames(4)
	var second := {}
	for n in graph_named("EventGraph").nodes:
		if not ids_before.has(int(n.id)) and int(n.id) != pid:
			second = n
	check(not second.is_empty(), "6. a second Print String was added, wired to nothing")
	var sid := int(second.id)

	# ------------------------------------------------ 3b. the graph still works with bubbles shown
	view.zoom = 1.0
	view.scroll_offset = Vector2(float(last.x) - 80.0, float(last.y) - 200.0)
	await frames(4)
	var vr: Rect2 = view.get_global_rect()
	check(vr.encloses(gnode(pid).get_global_rect()) and vr.encloses(gnode(sid).get_global_rect()), "3. the two nodes are inside the view for the mouse checks")
	var shown_now := 0
	for c in view.get_children():
		if c is GraphNode and c.comment_shown():
			shown_now += 1
	check(shown_now >= 3 and not view.hide_comments, "3. bubbles are shown during these checks (%d of them in this graph)" % shown_now)
	await select_only([])
	await click(title_point(pid))
	check(view.selected_ids() == [pid], "3. a click on a node with a bubble selects it", str(view.selected_ids()))
	await click(title_point(sid))
	check(view.selected_ids() == [sid], "3. ... and a click on another node moves the selection", str(view.selected_ids()))
	var wires_before: int = graph_named("EventGraph").wires.size()
	var from_pin := String(last_pin.id)
	var printer_out := ""
	for pin in R.describe(node_of(graph_named("EventGraph"), pid), ed.doc.bp, graph_named("EventGraph")).outs:
		if pin.type == "exec":
			printer_out = String(pin.id)
	var second_in := ""
	for pin in R.describe(node_of(graph_named("EventGraph"), sid), ed.doc.bp, graph_named("EventGraph")).ins:
		if pin.type == "exec":
			second_in = String(pin.id)
	await drag(out_port(pid, printer_out), in_port(sid, second_in))
	var wired := false
	for w in graph_named("EventGraph").wires:
		if int(w[0]) == pid and int(w[2]) == sid and String(w[1]) == printer_out and String(w[3]) == second_in:
			wired = true
	check(wired and graph_named("EventGraph").wires.size() == wires_before + 1, "3. dragging a wire from a pin of a node with a bubble makes the connection", "%d wires before, %d after" % [wires_before, graph_named("EventGraph").wires.size()])
	var y_before := float(node_of(graph_named("EventGraph"), sid).y)
	var x_before := float(node_of(graph_named("EventGraph"), sid).x)
	await drag(title_point(sid), title_point(sid) + Vector2(60, 70))
	var moved_by := Vector2(float(node_of(graph_named("EventGraph"), sid).x) - x_before, float(node_of(graph_named("EventGraph"), sid).y) - y_before)
	check(moved_by.length() > 30.0, "3. dragging a node moves it (by %s)" % moved_by)
	var code_wired := code()
	check(code_wired.contains("added in the editor") and code_wired.contains("\t# added by hand"), "3. the wired graph compiles with the comment still above its line")
	ed.compile_doc(ed.doc, false)

	# ------------------------------------------------ 7. a variable's comment
	ed._select({"kind": "var", "name": "blocked"})
	await frames(3)
	var base7 := code()
	check(note_box() != null and note_box().text == "", "7. a variable's Details panel has a Comment box (empty for `blocked`)")
	var desc_row: Control = null
	for r in ed._details.find_children("*", "PanelContainer", true, false):
		if r.has_meta("row_label") and String(r.get_meta("row_label")).begins_with("description"):
			desc_row = r
	var cmt_row: Control = null
	for r in ed._details.find_children("*", "PanelContainer", true, false):
		if r.has_meta("row_label") and String(r.get_meta("row_label")).begins_with("comment"):
			cmt_row = r
	check(desc_row != null and cmt_row != null, "7. the rows are labelled 'Comment (# above the line)' and 'Description (## doc, shown as tooltip)'", "%s %s" % [desc_row != null, cmt_row != null])
	await set_box("true while the mover is stopped")
	var v7: Dictionary = {}
	for v in ed.doc.bp.variables:
		if v.name == "blocked":
			v7 = v
	var c7 := code().split("\n")
	var vl := -1
	for i in c7.size():
		if c7[i].begins_with("var blocked"):
			vl = i
	check(v7.get("note", []) == ["# true while the mover is stopped"] and vl > 0 and c7[vl - 1] == "# true while the mover is stopped", "7. a variable's Comment box writes its note, and the code has the comment above the declaration", str(v7.get("note")))
	desc_row = null   # (the panel was rebuilt after the edit: look the row up again)
	for r in ed._details.find_children("*", "PanelContainer", true, false):
		if r.has_meta("row_label") and String(r.get_meta("row_label")).begins_with("description"):
			desc_row = r
	var dle: LineEdit = desc_row.find_children("*", "LineEdit", true, false)[0]
	dle.text = "Is the mover stopped"
	dle.focus_exited.emit()
	await frames(4)
	c7 = code().split("\n")
	for i in c7.size():
		if c7[i].begins_with("var blocked"):
			vl = i
	var tooltip_set := String(v7.get("tooltip", "")) == "Is the mover stopped"
	check(tooltip_set and v7.get("note", []) == ["# true while the mover is stopped"] and c7.slice(vl - 2, vl).has("## Is the mover stopped") and c7.slice(vl - 2, vl).has("# true while the mover is stopped"),
		"7. the Description still writes the ## line, beside the # comment", str(c7.slice(vl - 3, vl + 1)))
	check(code().count("\n") == base7.count("\n") + 1 or code().count("\n") == base7.count("\n") + 2, "7. exactly the comment and the description lines were added")
	# a signal's comment
	ed._select({"kind": "dispatcher", "name": "moved"})
	await frames(3)
	check(note_box() != null and note_box().text.contains("A free comment between declarations"), "7. a signal's Comment box shows the comment above it", note_box().text if note_box() else "no box")

	# ------------------------------------------------ 8. the code link
	ed._right_tabs.current_tab = 1
	await show_graph(graph_named("move"))
	await select_only([n_set])
	await tree.create_timer(0.3).timeout
	var cl: TextEdit = ed._code
	var comment_line := -1
	var stmt_line := -1
	for i in cl.get_line_count():
		if cl.get_line(i).strip_edges() == "# a comment line above a statement":
			comment_line = i + 1
		if cl.get_line(i).strip_edges().begins_with("position.x += speed"):
			stmt_line = i + 1
	check(comment_line > 0 and stmt_line == comment_line + 1, "8. the generated code view shows the comment and its statement", "%d %d" % [comment_line, stmt_line])
	var strong := []
	var soft := []
	var stray := []
	for i in cl.get_line_count():
		var col: Color = cl.get_line_background_color(i)
		if col == ed.LINK_STRONG:
			strong.append(i + 1)
		elif col == ed.LINK_SOFT:
			soft.append(i + 1)
		elif col.a > 0.0:
			stray.append(i + 1)
	check(strong == [stmt_line] and soft.has(comment_line) and stray.is_empty(), "8. selecting the node paints its statement strongly and its comment line softly", "strong %s soft %s stray %s" % [strong, soft, stray])
	await select_only([])
	cl.set_caret_line(comment_line - 1)
	cl.set_caret_column(0)
	await tree.create_timer(0.5).timeout
	await frames(3)
	check(view.selected_ids() == [n_set], "8. moving the caret to the comment line selects its node", str(view.selected_ids()))
	check(String(ed._code_label.text).contains("Comment on") and String(ed._code_label.text).contains("Line %d" % comment_line), "8. ... and the label says it is a comment on the node: '%s'" % ed._code_label.text)
	var decl_comment := -1
	for i in cl.get_line_count():
		if cl.get_line(i).strip_edges() == "# above a variable that keeps its declaration as written":
			decl_comment = i + 1
	cl.set_caret_line(decl_comment - 1)
	cl.set_caret_column(0)
	await tree.create_timer(0.5).timeout
	await frames(3)
	check(decl_comment > 0 and String(ed._code_label.text).ends_with("Comment") and view.selected_ids().is_empty(), "8. a comment above a declaration is named a comment and selects no node: '%s'" % ed._code_label.text)

	# ------------------------------------------------ 9. Find
	ed._right_tabs.current_tab = 0
	await show_graph(graph_named("move"))
	ed._find_in_schematic()
	await frames(4)
	var pop: PopupPanel = null
	for c in ed._graph_tabs.get_children():
		if c is PopupPanel:
			pop = c
	check(pop != null, "9. Find opens its list")
	if pop != null:
		var search: LineEdit = pop.find_children("*", "LineEdit", true, false)[0]
		var list: ItemList = pop.find_children("*", "ItemList", true, false)[0]
		search.text = "debugger"
		search.text_changed.emit("debugger")
		await frames(2)
		check(list.item_count == 1 and list.get_item_text(0).contains("stops in the debugger"), "9. a word that is only in a comment finds that node (%d hit: %s)" % [list.item_count, list.get_item_text(0) if list.item_count > 0 else ""])
		search.text_submitted.emit("debugger")
		await frames(6)
		check(int(ed.doc.graph_id) == int(g_event.id) and view.selected_ids() == [n_dbg], "9. picking it shows its graph and selects the node", "graph %s selected %s" % [ed.doc.graph_id, view.selected_ids()])

	# ------------------------------------------------ 10. save, close, reopen
	await show_graph(graph_named("EventGraph"))
	ed.compile_doc(ed.doc, true)
	await frames(3)
	var saved_a := FileAccess.get_file_as_bytes(PATH)
	var code_a := code()
	var sig_a := ""
	for g in ed.doc.bp.graphs:
		await show_graph(g)
		for n in g.nodes:
			if n.kind != "comment" and gnode(int(n.id)) != null:
				sig_a += "%s#%d:%s|%s;" % [g.name, n.id, gnode(int(n.id))._lay_note, gnode(int(n.id))._lay_tail]
	for i in range(ed.docs.size() - 1, -1, -1):
		if ed.docs[i].path == PATH:
			ed.docs[i].dirty = false
			ed._close_doc(i)
	await frames(3)
	check(ed._find_doc(PATH).is_empty(), "10. the document is closed")
	check(ed.open_schematic(PATH), "10. the file reopens")
	await frames(6)
	ed.compile_doc(ed.doc, true)   # (saved at once, before the view is touched: it stores where each graph is scrolled to)
	await frames(3)
	var saved_b := FileAccess.get_file_as_bytes(PATH)
	var where := ""
	if saved_a != saved_b:
		var la := saved_a.get_string_from_utf8().split("\n")
		var lb := saved_b.get_string_from_utf8().split("\n")
		for i in mini(la.size(), lb.size()):
			if la[i] != lb[i]:
				where = "first difference at line %d (%d and %d lines):\n   was  %s\n   now  %s" % [i + 1, la.size(), lb.size(), la[i].left(300), lb[i].left(300)]
				break
		if where == "":
			where = "the files have %d and %d lines" % [la.size(), lb.size()]
	var sig_b := ""
	for g in ed.doc.bp.graphs:
		await show_graph(g)
		for n in g.nodes:
			if n.kind != "comment" and gnode(int(n.id)) != null:
				sig_b += "%s#%d:%s|%s;" % [g.name, n.id, gnode(int(n.id))._lay_note, gnode(int(n.id))._lay_tail]
	check(sig_a == sig_b and sig_a.length() > 200, "10. after reopening every node shows the same bubble (%d characters compared)" % sig_a.length())
	check(code() == code_a, "10. ... and the code is the same")
	# Where each graph is scrolled to (sx, sy) is saved with it and follows the view, which has been moved since: that is
	# view state, not content. The file must be the same byte for byte once those two numbers are left out.
	var scroll_rx := RegEx.create_from_string("\"s[xy]\":-?[0-9.]+")
	var content_a := scroll_rx.sub(saved_a.get_string_from_utf8(), "", true)
	var content_b := scroll_rx.sub(saved_b.get_string_from_utf8(), "", true)
	check(content_a == content_b and content_a.length() > 5000, "10. saving again writes a byte-identical file apart from the scroll position (%d bytes; raw files %s)" % [saved_a.size(), "identical" if saved_a == saved_b else "differ in sx/sy only"], where)
	check(Model.load_file(PATH).variables.filter(func(v): return v.name == "blocked")[0].get("note", []) == ["# true while the mover is stopped"], "10. the variable's comment is in the saved file")

	# ------------------------------------------------ 11. speed
	# (the converter overflows its stack on one function of 1,200 statements, so the graph is made twice as large by
	# copying its nodes in: they are unwired, which costs the editor the same to build and to draw)
	var big: Dictionary = Importer.new().convert(big_source(580, 4), {"path": BIG}).bp
	var plain: Dictionary = Importer.new().convert(big_source(580, 0), {"path": BIG_PLAIN}).bp
	for b in [big, plain]:
		var bg: Dictionary = b.graphs[0]
		var copies: Array = []
		for cn in bg.nodes:
			if cn.kind in ["event", "fn_entry"]:
				continue
			var c2: Dictionary = cn.duplicate(true)
			c2.id = int(cn.id) + 100000
			c2.y = float(cn.y) + 20000.0
			copies.append(c2)
		bg.nodes.append_array(copies)
	write_file(BIG, Model.build_source(Compiler.new().compile(big), big))
	write_file(BIG_PLAIN, Model.build_source(Compiler.new().compile(plain), plain))
	var counts := [0, 0]
	for g in big.graphs:
		for n in g.nodes:
			counts[0] += 1
			if n.p.has("note"):
				counts[1] += 1
	var largest: Dictionary = Importer.new().convert(FileAccess.get_file_as_string("res://tests/convert/values.gd"), {"path": LARGE}).bp
	write_file(LARGE, Model.build_source(Compiler.new().compile(largest), largest))
	EditorInterface.get_resource_filesystem().scan()
	await tree.create_timer(1.0).timeout
	for entry in [["values.gd (the largest converted sample)", LARGE], ["synthetic: %d nodes, %d with a comment" % [counts[0], counts[1]], BIG], ["the same synthetic script with no comments", BIG_PLAIN]]:
		var shown_ms := []
		var hidden_ms := []
		var nodes := 0
		for rep in 3:
			var a := await time_open(String(entry[1]), false)
			var b := await time_open(String(entry[1]), true)
			shown_ms.append(a[0])
			hidden_ms.append(b[0])
			nodes = a[1]
		note("TIMING  open %s: first graph has %d nodes: bubbles shown %.0f ms (median of 3: %s), hidden %.0f ms (%s)" % [entry[0], nodes, median(shown_ms), str(shown_ms.map(func(v): return int(v))), median(hidden_ms), str(hidden_ms.map(func(v): return int(v)))])
		timings.append([entry[0], nodes, median(shown_ms), median(hidden_ms)])
	var syn: Array = timings[1]
	var syn_plain: Array = timings[2]
	check(float(syn[2]) < float(syn_plain[2]) * 1.5 + 150.0, "11. opening the %d-node graph with %d comments takes %.0f ms shown against %.0f ms with no comments in it" % [syn[1], counts[1], syn[2], syn_plain[2]])
	ed._comments_btn.button_pressed = false

	# ------------------------------------------------ tidy up
	cleanup()
	await tree.create_timer(1.0).timeout
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR)), "12. the scratch folder is removed")
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
