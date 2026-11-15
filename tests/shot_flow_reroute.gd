extends RefCounted
## Editor self-test for the live execution highlight across reroute nodes: the graph view's flow(from, to) has to
## light every piece of a wire that passes through one or two reroutes, and the plain wire next to it.
## It builds a small Schematic under res://tests/tmp/flowrr/ (git-ignored), runs it from the editor with Show Flow
## on, and watches the flow overlay's list of lit wires (a private dictionary, read only).
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_flow_reroute.gd

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

const LOG := "res://tests/out/shot_flow_reroute_checks.log"
const DIR := "res://tests/tmp/flowrr"
const SCRIPT := DIR + "/SC_FlowRR.gd"
const SCENE := DIR + "/flowrr.tscn"

var plugin: EditorPlugin
var ed
var tree: SceneTree
var fails := 0

# node ids in the event graph (see build())
var id_event := 0
var id_a := 0       # Set trail = "A"
var id_k1 := 0      # one reroute
var id_b := 0       # Set trail = trail + "B"
var id_k2 := 0      # two reroutes in a row
var id_k3 := 0
var id_c := 0       # Set trail = trail + "C"
var id_d := 0       # Set trail = trail + "D"
var id_get := 0     # data wire through a reroute (not an execution wire)
var id_k4 := 0
var id_print := 0


func note(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE if FileAccess.file_exists(LOG) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	note("%s  %s" % ["PASS" if ok else "FAIL", what])


func cleanup() -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if ed != null and not ed.doc.is_empty():
		ed.doc.dirty = false


func pair(a: int, b: int) -> String:
	return "n%d>n%d" % [a, b]


## What is lit right now, as "nA>nB" pairs (the overlay keys are "node:port>node:port").
func lit() -> Array:
	var out := []
	for key in ed._view.flow_overlay._active:
		var halves := String(key).split(">")
		out.append("%s>%s" % [halves[0].get_slice(":", 0), halves[1].get_slice(":", 0)])
	out.sort()
	return out


func sorted(a: Array) -> Array:
	var c := a.duplicate()
	c.sort()
	return c


func build() -> Dictionary:
	var bp := Model.new_schematic("Node", "SC_FlowRR")
	bp.variables.append({"name": "trail", "type": "String", "default": "", "export": false, "category": "", "tooltip": ""})
	var g: Dictionary = bp.graphs[0]
	var ev := {}
	for n in g.nodes:
		if n.kind == "event" and n.p.get("name", "") == "_process":
			ev = n
	id_event = int(ev.id)
	var a := Model.add_node(g, "var_set", Vector2(300, 260), {"name": "trail"})
	a.d["value"] = "\"A\""
	var k1 := Model.add_node(g, "reroute", Vector2(520, 300), {"t": "exec"})
	var b := Model.add_node(g, "var_set", Vector2(640, 260), {"name": "trail"})
	b.d["value"] = "trail + \"B\""
	var k2 := Model.add_node(g, "reroute", Vector2(860, 300), {"t": "exec"})
	var k3 := Model.add_node(g, "reroute", Vector2(960, 330), {"t": "exec"})
	var c := Model.add_node(g, "var_set", Vector2(1060, 260), {"name": "trail"})
	c.d["value"] = "trail + \"C\""
	var d := Model.add_node(g, "var_set", Vector2(1380, 260), {"name": "trail"})
	d.d["value"] = "trail + \"D\""
	var gt := Model.add_node(g, "var_get", Vector2(300, 520), {"name": "trail"})
	var k4 := Model.add_node(g, "reroute", Vector2(520, 540), {"t": "String"})
	var pr := Model.add_node(g, "print", Vector2(700, 500), {})
	id_a = int(a.id); id_k1 = int(k1.id); id_b = int(b.id); id_k2 = int(k2.id); id_k3 = int(k3.id)
	id_c = int(c.id); id_d = int(d.id); id_get = int(gt.id); id_k4 = int(k4.id); id_print = int(pr.id)
	g.wires.append([id_event, "then", id_a, "exec"])      # control: plain exec wire
	g.wires.append([id_a, "then", id_k1, "i"])            # one reroute
	g.wires.append([id_k1, "o", id_b, "exec"])
	g.wires.append([id_b, "then", id_k2, "i"])            # two reroutes in a row
	g.wires.append([id_k2, "o", id_k3, "i"])
	g.wires.append([id_k3, "o", id_c, "exec"])
	g.wires.append([id_c, "then", id_d, "exec"])          # control: plain exec wire
	g.wires.append([id_get, "value", id_k4, "i"])         # a DATA wire through a reroute
	g.wires.append([id_k4, "o", id_print, "text"])
	return bp


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Flows with the game stopped: calls flow() and reads what was lit.
func direct(a: int, b: int) -> Array:
	ed._view.flow_overlay.clear()
	ed._view.flow(a, b)
	var got := lit()
	ed._view.flow_overlay.clear()
	return got


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if FileAccess.file_exists(LOG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOG))
	note("--- start")
	tree.create_timer(100.0).timeout.connect(func():
		note("FAIL  watchdog quit")
		cleanup()
		tree.quit())
	await tree.create_timer(2.5).timeout

	# --- build the graph and compile it, once without the flow tracing and once with
	var bp := build()
	var plain: Dictionary = bp.duplicate(true)
	var cp := Compiler.new()
	var code := cp.compile(plain)
	check(cp.errors.is_empty(), "the graph compiles without errors: %s" % [cp.errors])

	# --- static: the reroutes add no line, the script runs A then B then C then D
	var body := []
	var in_process := false
	for line in code.split("\n"):
		if line.begins_with("func _process"):
			in_process = true
			continue
		if in_process:
			if line.strip_edges() == "":
				continue
			if not line.begins_with("\t") and not line.begins_with(" "):
				break
			body.append(line.strip_edges())
	note("_process body: %s" % [body])
	check(body.size() == 4, "_process has one statement per node (4) and none for the 3 reroutes: %d" % body.size())
	var order := ""
	for line in body:
		if line.contains("\"A\""):
			order += "A"
		elif line.contains("\"B\""):
			order += "B"
		elif line.contains("\"C\""):
			order += "C"
		elif line.contains("\"D\""):
			order += "D"
	check(order == "ABCD", "the generated lines are in the order A, B, C, D: %s" % order)
	var scr := GDScript.new()
	scr.source_code = "@tool\n" + code   # in the editor a script without @tool only gets a placeholder instance
	var rc := scr.reload()
	check(rc == OK, "the generated script loads (reload returned %d)" % rc)
	if rc == OK:
		var inst := Node.new()
		inst.set_script(scr)
		inst.call("_process", 0.0)
		check(String(inst.get("trail")) == "ABCD", "running _process leaves trail = \"ABCD\" (got \"%s\")" % String(inst.get("trail")))
		inst.free()

	# --- the script the game will run (with Show Flow on), and a scene for it
	var traced: Dictionary = bp.duplicate(true)
	traced["trace"] = true
	var cp2 := Compiler.new()
	var tcode := cp2.compile(traced)
	check(cp2.errors.is_empty(), "the graph compiles with tracing on: %s" % [cp2.errors])
	for tline in tcode.split("\n"):
		if tline.contains("__sc_trace(") and not tline.contains("func "):
			note("trace call: %s" % tline.strip_edges())
	# what the trace names as the node execution came from, for each traced node
	var origin := {}
	var re := RegEx.create_from_string("^__sc_trace\\((\\d+), (\\d+)(?:, \\{.*\\})?(?:, (\\d+))?\\)$")
	for tline in tcode.split("\n"):
		var s := tline.strip_edges()
		if s.begins_with("__sc_trace("):
			var m := re.search(s)
			if m != null:
				origin[int(m.get_string(2))] = int(m.get_string(3)) if m.get_string(3) != "" else 0
	note("trace origins (node -> came from): %s" % [origin])
	check(origin.get(id_b, -1) == id_a, "static: the trace says B was reached from A (it says %s; the knot is %d)" % [origin.get(id_b, "?"), id_k1])
	check(origin.get(id_c, -1) == id_b, "static: the trace says C was reached from B (it says %s; the knots are %d, %d)" % [origin.get(id_c, "?"), id_k2, id_k3])
	check(origin.get(id_a, -1) == id_event, "static: the trace says A was reached from the event (it says %s)" % origin.get(id_a, "?"))
	check(origin.get(id_d, -1) == id_c, "static: the trace says D was reached from C (it says %s)" % origin.get(id_d, "?"))
	write_file(SCRIPT, Model.build_source(tcode, traced))
	write_file(SCENE, "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1\")\n" % SCRIPT)
	EditorInterface.get_resource_filesystem().update_file(SCRIPT)
	await tree.create_timer(0.5).timeout

	# --- open it in the editor
	check(ed.open_schematic(SCRIPT), "the schematic opens in the editor")
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	ed.doc.graph_id = int(ed.doc.bp.graphs[0].id)
	ed._refresh_graph()
	await tree.create_timer(0.5).timeout
	var view = ed._view
	check(view.flow_overlay != null and view.get_node_or_null("n%d" % id_k2) != null, "the graph is on screen with its reroute nodes")
	check(not EditorInterface.is_playing_scene(), "the game is stopped")

	# --- flow() called directly, game stopped
	var want_one := sorted([pair(id_a, id_k1), pair(id_k1, id_b)])
	var want_two := sorted([pair(id_b, id_k2), pair(id_k2, id_k3), pair(id_k3, id_c)])
	var got := direct(id_a, id_b)
	check(got == want_one, "flow(A, B) through one reroute lights A>knot and knot>B: %s" % [got])
	got = direct(id_b, id_c)
	check(got == want_two, "flow(B, C) through two reroutes lights B>knot, knot>knot, knot>C: %s" % [got])
	got = direct(id_event, id_a)
	check(got == [pair(id_event, id_a)], "flow(event, A) on a plain wire lights that wire: %s" % [got])
	got = direct(id_c, id_d)
	check(got == [pair(id_c, id_d)], "flow(C, D) on a plain wire lights that wire: %s" % [got])

	# --- the negatives: nothing lit, no error
	got = direct(id_a, id_c)
	check(got.is_empty(), "flow(A, C), not connected (a node lies between), lights nothing: %s" % [got])
	got = direct(id_b, id_a)
	check(got.is_empty(), "flow(B, A), against the wire, lights nothing: %s" % [got])
	got = direct(id_event, id_d)
	check(got.is_empty(), "flow(event, D), far apart, lights nothing: %s" % [got])
	got = direct(id_a, 9999)
	check(got.is_empty(), "flow(A, a node that does not exist) lights nothing: %s" % [got])
	got = direct(id_get, id_print)
	check(got.is_empty(), "flow(getter, Print) through a reroute on a data wire lights nothing (not an execution wire): %s" % [got])
	got = direct(id_k1, id_b)
	note("flow(knot, B) starting on the knot itself lights: %s" % [got])
	got = direct(id_a, id_k1)
	note("flow(A, knot) ending on the knot itself lights: %s" % [got])

	# --- the game runs: watch what the traced run lights
	ed.flow_hits = 0
	ed.flow_edges = 0
	view.flow_overlay.clear()
	EditorInterface.play_custom_scene(SCENE)
	var seen := {}
	var want_all := sorted(want_one + want_two + [pair(id_event, id_a), pair(id_c, id_d)])
	var waited := 0.0
	var shot_done := false
	while waited < 20.0:
		await tree.create_timer(0.03).timeout
		waited += 0.03
		for k in lit():
			seen[k] = true
		var have := true
		for w in want_all:
			if not seen.has(w):
				have = false
		if have and not shot_done:
			shot_done = true
			# the picture while the wires are still lit, from the editor's own viewport
			await tree.process_frame
			await tree.process_frame
			EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/shot_flow_reroute.png")
			note("saved shot_flow_reroute (lit at that moment: %s)" % [lit()])
		if have and waited > 3.0:
			break
		if not have and ed.flow_hits > 0 and waited > 6.0:
			break
	var seen_list := seen.keys()
	seen_list.sort()
	note("the game reported %d node hits and %d followed wires; wires lit at some moment: %s" % [ed.flow_hits, ed.flow_edges, seen_list])
	check(ed.flow_hits > 0, "the running game reported nodes to the editor (%d hits): the trace reaches the editor" % ed.flow_hits)
	check(ed.flow_edges > 0, "the running game reported followed wires (%d)" % ed.flow_edges)
	for w in want_all:
		check(seen.has(w), "running: wire piece %s was lit by the live trace" % w)
	if not shot_done:
		EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/shot_flow_reroute.png")
		note("saved shot_flow_reroute (not all wires had lit)")
	var extra := []
	for k in seen_list:
		if not want_all.has(k):
			extra.append(k)
	check(extra.is_empty(), "running: nothing else was lit (stray: %s)" % [extra])
	EditorInterface.stop_playing_scene()
	await tree.create_timer(0.8).timeout
	cleanup()
	note("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	tree.quit()
