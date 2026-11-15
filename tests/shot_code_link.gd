extends RefCounted
## Editor self-test for the code <-> node link: selecting nodes in the graph paints the generated code lines they
## produced (strong for the lines a node wrote itself, soft for the lines it only takes part in), and moving the
## caret in the generated code selects the node that wrote the line (showing its graph first when it is another one).
## The script is converted at run time under res://tests/tmp/codelink/ (git-ignored) and removed again.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_code_link.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const CodeLink := preload("res://addons/schematic/editor/sc_code_link.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

const LOG := "res://tests/out/shot_code_link_checks.log"
const PNG := "res://tests/out/shot_code_link.png"
const DIR := "res://tests/tmp/codelink"
const PATH := DIR + "/SC_CodeLink.gd"

const HEAD := """extends Node

var counter: int = 0
var step: int = 3
var out: Array = []


func _ready() -> void:
	var base := 10
	var add_base := func(x):
		var y = x + base
		return y
	out.append(add_base.call(1))
	bump(5)

"""

const TAIL := """
func bump(n: int) -> void:
	if n > step:
		counter += n
		out.append(counter)
	else:
		counter -= step
		out.append(step)
	for i in range(n):
		counter += step
		out.append(i)


func other() -> int:
	return counter * 2
"""

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0
var view
var g_ready := {}
var g_bump := {}
var g_other := {}
var g_lam := {}
var id_comment := 0
var id_knot := 0
var id_print := 0


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


## Long enough for the caret debounce and the frames after it.
func settle() -> void:
	await tree.create_timer(0.4).timeout
	await frames(3)


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func history() -> UndoRedo:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(ed))


func cleanup() -> void:
	if ed != null:
		ed._right_tabs.custom_minimum_size.x = 340
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


# ---------------------------------------------------------------- reading the code view

func code_line(i: int) -> String:
	return ed._code.get_line(i).strip_edges()


## The first 1-based line at or after `from` whose stripped text begins with `begins` and contains `has`; 0 when none.
func line_q(begins: String, has := "", from := 1) -> int:
	for i in range(from - 1, ed._code.get_line_count()):
		var t := code_line(i)
		if t.begins_with(begins) and (has == "" or t.contains(has)):
			return i + 1
	return 0


## What is painted on the code view: {strong: [1-based lines], soft: [...], stray: [lines painted some other colour]}.
func painted() -> Dictionary:
	var out := {"strong": [], "soft": [], "stray": []}
	for i in ed._code.get_line_count():
		var c: Color = ed._code.get_line_background_color(i)
		if c == ed.LINK_STRONG:
			out.strong.append(i + 1)
		elif c == ed.LINK_SOFT:
			out.soft.append(i + 1)
		elif c.a > 0.0:
			out.stray.append(i + 1)
	return out


func is_blank_paint(pt: Dictionary) -> bool:
	return pt.strong.is_empty() and pt.soft.is_empty() and pt.stray.is_empty()


func sorted(a: Array) -> Array:
	var c := a.duplicate()
	c.sort()
	return c


func first_visible() -> int:
	return ed._code.get_first_visible_line() + 1


func last_visible() -> int:
	return ed._code.get_last_full_visible_line() + 1


# ---------------------------------------------------------------- driving the graph

func gnode(id: int):
	return view.get_node_or_null("n%d" % id)


func select_only(ids: Array) -> void:
	for c in view.get_children():
		if c is GraphElement and not c.has_meta("gone"):
			c.selected = ids.has(int(String(c.name).trim_prefix("n")))
	await frames(4)


func selected() -> Array:
	return sorted(view.selected_ids())


func show_graph(g: Dictionary) -> void:
	ed.doc.graph_id = int(g.id)
	ed._refresh_graph()
	ed._refresh_graph_tabs()
	ed._refresh_members()
	await frames(4)


func inside_view(id: int) -> bool:
	var c = gnode(id)
	return c != null and view.get_global_rect().encloses(c.get_global_rect())


func fit_view(g: Dictionary) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		lo = Vector2(minf(lo.x, float(n.x)), minf(lo.y, float(n.y)))
		hi = Vector2(maxf(hi.x, float(n.x) + 300.0), maxf(hi.y, float(n.y) + 220.0))
	var z := minf(1.0, minf((view.size.x - 40.0) / (hi.x - lo.x), (view.size.y - 40.0) / (hi.y - lo.y)))
	view.zoom = maxf(z, 0.4)
	view.scroll_offset = lo * view.zoom - Vector2(20, 20)


## Moves the caret of the code view to a 1-based line, as a click would, and waits for the editor to react.
func click_line(line: int) -> void:
	ed._code.set_caret_line(line - 1)
	ed._code.set_caret_column(0)
	await settle()


func caret_line() -> int:
	return ed._code.get_caret_line() + 1


func find_graph(name: String) -> Dictionary:
	return Model.graph_named(ed.doc.bp, name)


## The id of the node that wrote a line of the open document's current compile.
func writer_at(link, line: int) -> int:
	var at: Array = link.nodes_at(line)
	return int(at[0][1]) if not at.is_empty() else -1


func fresh_link() -> Array:
	var c := Compiler.new()
	var code := c.compile(ed.doc.bp)
	return [CodeLink.new().build(c, code), code]


func label_text() -> String:
	return String(ed._code_label.text)


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

	# ------------------------------------------------ set up: a converted script with filler functions so the code scrolls
	var source := HEAD
	for i in 9:
		source += "\nfunc filler_%d(v: int) -> int:\n\tvar w := v + %d\n\treturn w * 2\n\n" % [i, i]
	source += TAIL
	for i in 9:
		source += "\n\nfunc after_%d(v: int) -> int:\n\tvar w := v - %d\n\treturn w * 3\n" % [i, i]
	var out: Dictionary = Importer.new().convert(source, {"path": PATH})
	var bp: Dictionary = out.bp
	check(int(out.report.as_code) == 0, "setup: the script converts with no line kept as code (%d lines)" % out.report.lines, str(out.report.notes))
	var gb := Model.graph_named(bp, "bump")
	# a getter read by two nodes: the `step` that feeds the Branch's comparison also feeds `counter += step`
	var getters := []
	for n in gb.nodes:
		if n.kind == "var_get" and String(n.p.get("name", "")) == "step":
			getters.append(n)
	var feed: Dictionary = getters[0]
	var feed_pin := ""
	for w in gb.wires:
		if int(w[0]) == int(feed.id):
			feed_pin = String(w[1])
	var moved := false
	for w in gb.wires:
		for other in getters.slice(1):
			if int(w[0]) == int(other.id) and not moved and Model.find_node(gb, int(w[2])).p.get("op", "") == "+":
				w[0] = int(feed.id)
				w[1] = feed_pin
				moved = true
				gb.nodes.erase(other)
	check(moved, "setup: one `step` getter is wired into two nodes (the comparison and `counter += step`)")
	var comment := Model.add_node(gb, "comment", Vector2(-300, 40), {"text": "Comment", "w": 240, "h": 120})
	id_comment = int(comment.id)
	var code := Compiler.new().compile(bp)
	write_file(PATH, Model.build_source(code, bp))
	EditorInterface.get_resource_filesystem().update_file(PATH)
	await tree.create_timer(0.6).timeout
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.5).timeout
	check(ed.open_schematic(PATH) and ed.doc.path == PATH and ed.doc.errors.is_empty(), "setup: the file opens in the editor with no error", str(ed.doc.errors))
	view = ed._view
	g_ready = find_graph("EventGraph")
	g_bump = find_graph("bump")
	g_other = find_graph("other")
	for g in ed.doc.bp.graphs:
		if g.has("lambda"):
			g_lam = g
	check(not g_ready.is_empty() and not g_bump.is_empty() and not g_other.is_empty() and not g_lam.is_empty(), "setup: the event graph, two functions and a lambda graph exist")
	ed._right_tabs.custom_minimum_size.x = 700
	ed._right_tabs.current_tab = 1
	await show_graph(g_bump)
	await frames(3)
	var knots := []
	for n in g_bump.nodes:
		if n.kind == "reroute" and String(n.p.get("t", "")) == "exec":
			knots.append(int(n.id))
	id_knot = knots[0] if not knots.is_empty() else -1
	check(id_knot > 0, "setup: the bump graph has an execution reroute")

	var line_if := line_q("if ", "step")
	var line_else := line_q("else:", "", line_if)
	var line_addn := line_q("counter += n")
	var line_adds := line_q("counter += step")
	var line_subs := line_q("counter -= step")
	var line_bump := line_q("func bump(")
	var line_other := line_q("func other(")
	var line_ret := line_q("return", "counter", line_other)
	var line_lam_open := line_q("var add_base", "func(")
	var line_lam_body := line_q("var y")
	var line_decl := line_q("var step")
	check(line_if > 0 and line_else > line_if and line_addn > 0 and line_adds > 0 and line_subs > 0 and line_bump > 0 and line_ret > 0 and line_lam_open > 0 and line_lam_body > 0 and line_decl > 0,
		"setup: the generated code has the lines the test looks for", str([line_if, line_else, line_addn, line_adds, line_subs, line_bump, line_ret, line_lam_open, line_lam_body, line_decl]))
	check(ed._code.get_line_count() > ed._code.get_visible_line_count() + 10, "setup: the code is longer than the view (%d lines, %d visible), so scrolling matters" % [ed._code.get_line_count(), ed._code.get_visible_line_count()])
	var link: RefCounted = fresh_link()[0]
	var id_if := writer_at(link, line_if)
	var id_addn := writer_at(link, line_addn)
	var id_adds := writer_at(link, line_adds)
	var id_subs := writer_at(link, line_subs)
	var id_getter := -1
	for e in link.nodes_at(line_if):
		if Model.find_node(g_bump, int(e[1])).get("kind", "") == "var_get":
			id_getter = int(e[1])
	var id_sub_getter := -1
	for e in link.nodes_at(line_subs).slice(1):
		if Model.find_node(g_bump, int(e[1])).get("kind", "") == "var_get":
			id_sub_getter = int(e[1])
	check(id_if > 0 and id_getter > 0 and id_sub_getter > 0 and id_addn > 0 and id_adds > 0 and id_subs > 0, "setup: found the Branch, the shared getter and the Sets in the graph", str([id_if, id_getter, id_sub_getter, id_addn, id_adds, id_subs]))
	var base_version := history().get_version()
	var base_stats: Dictionary = ed.link_stats.duplicate()
	var builds0 := int(ed.link_stats.builds)

	# ------------------------------------------------ 1. an execution node: its own lines, strongly, scrolled into view
	await select_only([])
	ed._code.set_line_as_first_visible(0)
	await frames(2)
	var pt := painted()
	check(is_blank_paint(pt), "1. with nothing selected, nothing is painted", str(pt))
	await select_only([id_if])
	pt = painted()
	check(sorted(pt.strong) == sorted([line_if, line_else]) and pt.soft.is_empty() and pt.stray.is_empty(), "1. the Branch paints exactly its `if` and `else:` lines strongly, and nothing else", str(pt))
	check(first_visible() <= line_if and line_if <= last_visible(), "1. the first painted line is scrolled into view (visible %d..%d, line %d)" % [first_visible(), last_visible(), line_if])
	check(first_visible() > 1 and line_if - first_visible() >= 2 and line_if - first_visible() <= 5, "1. ... with a few lines of context above it (view starts at line %d)" % first_visible())
	check(not ed._code.has_focus(), "1. the code view did not take the keyboard focus")
	check(ed.link_stats.builds == builds0 + 1, "1. the lookup was built once, when first needed (%d builds)" % (int(ed.link_stats.builds) - builds0))

	# ------------------------------------------------ 2. a getter read by two nodes: both lines, softly
	await select_only([id_getter])
	pt = painted()
	check(sorted(pt.soft) == sorted([line_if, line_adds]) and pt.strong.is_empty() and pt.stray.is_empty(), "2. the shared getter paints the lines of both readers softly and none strongly", str(pt))

	# ------------------------------------------------ 3. two nodes: the union; clearing clears
	await select_only([id_if, id_addn])
	pt = painted()
	check(sorted(pt.strong) == sorted([line_if, line_else, line_addn]) and pt.soft.is_empty(), "3. two nodes paint the union of their lines", str(pt))
	await select_only([id_if, id_getter])
	pt = painted()
	check(sorted(pt.strong) == sorted([line_if, line_else]) and sorted(pt.soft) == [line_adds], "3. a node and a getter: the getter's extra line is soft, the line they share stays strong", str(pt))
	await select_only([])
	pt = painted()
	check(is_blank_paint(pt), "3. clearing the selection clears every highlight (scanned all %d lines)" % ed._code.get_line_count(), str(pt))

	# ------------------------------------------------ 4. nodes with no line of their own: nothing painted, nothing scrolled
	ed._code.set_line_as_first_visible(12)
	await frames(2)
	var top_before := first_visible()
	await select_only([id_comment])
	pt = painted()
	check(selected() == [id_comment] and is_blank_paint(pt) and first_visible() == top_before, "4. a comment box paints nothing and does not scroll (view starts at %d)" % first_visible(), str(pt))
	await select_only([id_knot])
	pt = painted()
	check(selected() == [id_knot] and is_blank_paint(pt) and first_visible() == top_before, "4. an execution reroute paints nothing and does not scroll", str(pt))
	await select_only([])

	# ------------------------------------------------ 6. caret -> node, same graph
	var runs0 := int(ed.link_stats.selection_runs)
	await click_line(line_subs)
	check(selected() == [id_subs] and ed.doc.graph_id == g_bump.id, "6. a caret on the `counter -= step` line selects exactly the node that wrote it", str(selected()))
	check(inside_view(id_subs), "6. ... and the node is centred in the graph view")
	check(view.soft_ids() == [id_sub_getter] and not gnode(id_sub_getter).selected, "6. ... the getter feeding that line is marked softly, not selected", str(view.soft_ids()))
	pt = painted()
	check(pt.strong == [line_subs] and pt.soft.is_empty(), "6. the selected node's line is painted strongly in the code view too", str(pt))
	check(caret_line() == line_subs, "6. the caret is still on the line the test put it on (%d)" % caret_line())
	check(label_text().begins_with("Line %d" % line_subs), "6. the label under the code names the line (%s)" % label_text())

	# ------------------------------------------------ 7. another function / the lambda / the function header
	await click_line(line_ret)
	check(ed.doc.graph_id == g_other.id and selected().size() == 1 and writer_at(fresh_link()[0], line_ret) == selected()[0], "7. a caret in another function shows that function's graph and selects the node", "graph %s selected %s" % [ed.doc.graph_id, selected()])
	check(inside_view(selected()[0]), "7. ... centred in view")
	check(caret_line() == line_ret, "7. ... and the caret stayed put")
	await click_line(line_lam_body)
	var lam_writer := writer_at(fresh_link()[0], line_lam_body)
	check(ed.doc.graph_id == g_lam.id and selected() == [lam_writer] and lam_writer > 0, "7. a caret inside the inline lambda's body shows the lambda's graph and selects its node", "graph %s selected %s want %s" % [ed.doc.graph_id, selected(), lam_writer])
	await click_line(line_lam_open)
	var outer_writer := writer_at(fresh_link()[0], line_lam_open)
	check(ed.doc.graph_id == g_ready.id and selected() == [outer_writer], "7. the line that opens the lambda selects the outer node that uses it, in the outer graph", "graph %s selected %s" % [ed.doc.graph_id, selected()])
	check(view.soft_ids().size() >= 1 and not view.soft_ids().has(outer_writer), "7. ... and its feeding nodes are marked softly (%s)" % [view.soft_ids()])
	await click_line(line_bump)
	check(ed.doc.graph_id == g_bump.id and selected().size() == 1 and Model.find_node(g_bump, selected()[0]).kind == "fn_entry", "7. a function's header line shows its graph and selects its entry node", "graph %s selected %s" % [ed.doc.graph_id, selected()])
	check(inside_view(selected()[0]), "7. ... centred in view")

	# ------------------------------------------------ 8. lines no node wrote: nothing selected, a label says what they are
	await click_line(line_subs)
	check(selected() == [id_subs], "8. (a node is selected first)")
	await click_line(line_decl)
	check(selected().is_empty() and label_text().contains(CodeLink.LABELS.declaration), "8. a declaration line selects nothing and the label says so (%s)" % label_text(), str(selected()))
	await click_line(line_subs)
	await click_line(3)
	check(code_line(1) == "extends Node" and code_line(2) == "" and selected().is_empty(), "8. a blank line selects nothing")
	check(label_text().to_lower().contains("blank"), "8. ... and the label says it is blank (%s)" % label_text())
	await click_line(line_subs)
	await click_line(2)
	check(selected().is_empty() and label_text().contains(CodeLink.LABELS.header), "8. the script's header lines select nothing and the label says so (%s)" % label_text(), str(selected()))
	pt = painted()
	check(is_blank_paint(pt), "8. ... and no line is painted", str(pt))

	# ------------------------------------------------ 9. the loop guard: five rounds of each direction, alternating
	await select_only([])
	var drift := 0
	var worst_runs := 0
	var worst_events := 0
	var targets := [[line_subs, id_subs], [line_adds, id_adds], [line_addn, id_addn], [line_subs, id_subs], [line_adds, id_adds]]
	var picks := [id_addn, id_subs, id_adds, id_if, id_addn]
	for r in 5:
		var s0: Dictionary = ed.link_stats.duplicate()
		await click_line(int(targets[r][0]) if int(targets[r][0]) != caret_line() else line_if)
		var want_line := caret_line()
		var s1: Dictionary = ed.link_stats.duplicate()
		var want_id := writer_at(link, want_line)
		if selected() != [want_id]:
			drift += 1
		if caret_line() != want_line:
			drift += 1
		worst_runs = maxi(worst_runs, int(s1.selection_runs) - int(s0.selection_runs))
		worst_events = maxi(worst_events, int(s1.caret_acts) - int(s0.caret_acts))
		# now the other direction: a node chosen in the graph must not move the caret
		await select_only([int(picks[r])])
		var s2: Dictionary = ed.link_stats.duplicate()
		if caret_line() != want_line:
			drift += 1
			note("      caret jumped from %d to %d" % [want_line, caret_line()])
		worst_runs = maxi(worst_runs, int(s2.selection_runs) - int(s1.selection_runs))
		worst_events = maxi(worst_events, int(s2.caret_acts) - int(s1.caret_acts))
		await settle()
		var s3: Dictionary = ed.link_stats.duplicate()
		if int(s3.caret_acts) != int(s2.caret_acts) or caret_line() != want_line or selected() != [int(picks[r])]:
			drift += 1
	var s_end: Dictionary = ed.link_stats.duplicate()
	check(drift == 0, "9. five rounds of caret -> node and node -> caret: no drift (caret and selection stayed where each side put them)")
	check(worst_runs <= 2, "9. the selection handler ran at most %d time(s) per step" % worst_runs)
	check(worst_events <= 1, "9. a caret move was acted on at most %d time(s) per move" % worst_events)
	note("      handler runs over the 10 steps: %d, caret moves acted on: %d, caret events seen: %d" % [int(s_end.selection_runs) - int(base_stats.selection_runs), int(s_end.caret_acts) - int(base_stats.caret_acts), int(s_end.caret_events) - int(base_stats.caret_events)])

	# a drag over many lines acts once, on the line where it ends
	var acts0 := int(ed.link_stats.caret_acts)
	for l in range(line_if, line_if + 6):
		ed._code.set_caret_line(l - 1)
		await tree.process_frame
	await settle()
	check(int(ed.link_stats.caret_acts) - acts0 == 1 and caret_line() == line_if + 5, "9. moving the caret down six lines in quick succession acted once, on the last line (%d acts)" % (int(ed.link_stats.caret_acts) - acts0))

	# ------------------------------------------------ 10. none of that edited the document
	check(not ed.doc.dirty, "10. the document is not marked changed")
	check(history().get_version() == base_version, "10. the undo history did not change (version %d -> %d)" % [base_version, history().get_version()])

	# ------------------------------------------------ 11. the Details tab: nothing built, nothing painted; back on the code tab it shows
	await select_only([id_if])
	ed._right_tabs.current_tab = 0
	await frames(3)
	ed._check(ed.doc)   # a compile while the code tab is hidden
	builds0 = int(ed.link_stats.builds)
	await select_only([id_subs])
	await select_only([id_if, id_addn])
	check(int(ed.link_stats.builds) == builds0 and ed.doc.get("link") == null, "11. with the Details tab showing, selecting nodes does not build the lookup")
	ed._right_tabs.current_tab = 1
	await frames(4)
	pt = painted()
	check(sorted(pt.strong) == sorted([line_if, line_else, line_addn]) and pt.soft.is_empty(), "11. back on the code tab the highlight for the current selection is shown", str(pt))
	check(int(ed.link_stats.builds) == builds0 + 1, "11. ... and the lookup was built then, once (%d)" % (int(ed.link_stats.builds) - builds0))

	# ------------------------------------------------ 5. an edit through the editor, then undo: highlights follow the text
	await select_only([id_if])
	var text_before: String = ed._code.text
	var line_if_before := line_if
	var call_bump := -1
	for n in g_ready.nodes:
		if n.kind == "call_self" and String(n.p.get("fn", "")) == "bump":
			call_bump = int(n.id)
	var exec_out := ""
	for pin in R.describe(Model.find_node(g_ready, call_bump), ed.doc.bp, g_ready).outs:
		if String(pin.type) == "exec":
			exec_out = String(pin.id)
	ed.mutate("Add Print (test)", func():
		var pr := Model.add_node(g_ready, "print", Vector2(1200, 300), {})
		id_print = int(pr.id)
		g_ready.wires.append([call_bump, exec_out, id_print, "exec"]))
	await frames(4)
	var line_if_after := line_q("if ", "step")
	pt = painted()
	check(line_if_after == line_if_before + 1 or line_if_after > line_if_before, "5. the edit added a line before the function (the Branch moved from line %d to %d)" % [line_if_before, line_if_after])
	check(sorted(pt.strong) == sorted([line_if_after, line_q("else:", "", line_if_after)]) and pt.soft.is_empty() and pt.stray.is_empty(), "5. after the edit the highlights are on the Branch's new lines and nowhere else (no stale line)", str(pt))
	check(ed.doc.dirty and history().get_version() > base_version, "5. the edit itself did mark the document changed and made an undo step")
	var fresh: Array = fresh_link()
	check(ed._code.text == String(fresh[1]), "5. the code view shows the new compile")
	history().undo()
	await frames(6)
	pt = painted()
	check(ed._code.text == text_before and sorted(pt.strong) == sorted([line_if_before, line_q("else:", "", line_if_before)]) and pt.soft.is_empty() and pt.stray.is_empty(), "5. after undo the code and the highlights are back, no stale line", str(pt))
	check(selected() == [id_if], "5. ... and the Branch is still the selected node", str(selected()))
	ed.doc.dirty = false

	# ------------------------------------------------ the picture
	await show_graph(g_bump)
	fit_view(g_bump)
	await select_only([id_if, id_getter])
	pt = painted()
	note("picture: strong lines %s, soft lines %s, first visible %d" % [pt.strong, pt.soft, first_visible()])
	ed._code.set_line_as_first_visible(maxi(line_if - 8, 0))
	await frames(3)
	ed._refresh_all()
	await frames(3)
	EditorInterface.get_base_control().queue_redraw()
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(PNG)
	note("saved " + PNG)

	await select_only([])
	cleanup()
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
