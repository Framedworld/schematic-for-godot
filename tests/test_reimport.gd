extends SceneTree
## Headless test of SCSync.reimport (core/sc_sync.gd): a person's hand edits of a Schematic's code brought back
## into the graph, rebuilding only what they changed.
## Run: godot --headless --path . --script res://tests/test_reimport.gd [-- --only=<test> --show]
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Sync := preload("res://addons/schematic/core/sc_sync.gd")
const Reuse := preload("res://addons/schematic/core/sc_reuse.gd")

const DEMO_DIRS := ["res://demo/", "res://demo/game/", "res://demo/arcade/", "res://demo/arcade/art/", "res://demo/machine/", "res://demo/data/"]
const SAMPLES := "res://tests/convert/"
const SCRATCH := "res://tests/tmp/reimport/"
## Refusals that are the rule working (not findings): their reasons start with these words.
const EXPECTED := ["is the code of the", "uses ", "is the custom event"]

var fails := 0
var sync := Sync.new()
var info := {}
var show := false


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("PASS  ", label)
	else:
		print("FAIL  ", label, "  ", detail)
		fails += 1


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
		if arg == "--show":
			show = true
	if sync == null:
		check("core/sc_sync.gd loads", false)
		print("REIMPORT FAILS: ", fails)
		quit(1)
		return
	var inputs := material()
	if only == "" or only == "same":
		test_no_change(inputs)
	if only == "" or only == "forced":
		test_forced(inputs)
	if only == "" or only == "edits":
		test_edits()
		test_sample_edits(inputs)
	if only == "" or only == "events":
		test_events()
	if only == "" or only == "lists":
		test_add_remove_rename()
	if only == "" or only == "decl":
		test_declarations()
	if only == "" or only == "refuse":
		test_refusals()
	if only == "" or only == "comments":
		test_comments()
	if only == "" or only == "hand":
		test_hand_made()
	if only == "" or only == "macros":
		test_macros()
	if only == "" or only == "stable":
		test_stability()
	if only == "" or only == "options":
		test_options()
	if only == "" or only == "speed":
		test_speed(inputs)
	if only == "" or only == "gentle" or only == "one_line":
		test_one_line(inputs)
	if only == "" or only == "gentle":
		test_gentle_edits()
		test_gentle_hand(inputs)
		test_gentle_events()
		test_gentle_lambda()
		test_gentle_fallbacks()
		test_gentle_stability()
		test_gentle_speed(inputs)
	print("informational: %s" % str(info))
	print("REIMPORT FAILS: ", fails)
	quit(1 if fails else 0)


# ================================================================ helpers

## Every demo schematic that loads and every sample converted: [{label, bp, path}].
func material() -> Array:
	var out := []
	for dir in DEMO_DIRS:
		var files := Array(DirAccess.get_files_at(dir))
		files.sort()
		for f in files:
			if f.get_extension() != "gd" or not Model.is_schematic_file(dir + f):
				continue
			var bp := Model.load_file(dir + f)
			if bp.is_empty() or bp.graphs.is_empty():
				continue
			out.append({"label": f, "bp": bp, "path": dir + f, "demo": true})
	var names := Array(DirAccess.get_files_at(SAMPLES)).filter(func(f): return f.get_extension() == "gd" and not f.begins_with("_"))
	names.sort()
	for f in names:
		var src := FileAccess.get_file_as_string(SAMPLES + f)
		var bp: Dictionary = Importer.new().convert(src, {"path": SAMPLES + f}).bp
		out.append({"label": "converted " + f, "bp": bp, "path": SAMPLES + f, "demo": false})
	return out


func compiled(bp: Dictionary) -> String:
	return Model.normalize_code(Compiler.new().compile(bp.duplicate(true)))


## The functions of the person's in a schematic's code (the ones re-import can rebuild), in file order.
func user_functions(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := Model.normalize_code(c.compile(bp.duplicate(true)))
	var blocks := sync.split(code)
	sync.classify(blocks, c)
	return blocks.filter(func(b): return b.kind == "func" and b.owner == "user").map(func(b): return String(b.name))


## name -> {gid, nid, kind ...} of each function of the person's (see SCSync._entries).
func entries_of(bp: Dictionary) -> Dictionary:
	var c := Compiler.new()
	var code := Model.normalize_code(c.compile(bp.duplicate(true)))
	var blocks := sync.split(code)
	sync.classify(blocks, c)
	return sync._entries(blocks, c)


func reasons(r: Dictionary) -> String:
	return " | ".join(r.report.refused.map(func(x): return String(x.reason)))


func expected_refusal(r: Dictionary) -> bool:
	if r.report.refused.is_empty():
		return false
	for x in r.report.refused:
		var ok := false
		for w in EXPECTED:
			if String(x.reason).contains(w):
				ok = true
		if not ok:
			return false
	return true


func graph_ids(bp: Dictionary) -> Array:
	return bp.graphs.map(func(g): return int(g.id))


## Graphs of `a` and `b` that differ (by id), leaving out `skip` (ids).
func graphs_differing(a: Dictionary, b: Dictionary, skip: Dictionary) -> Array:
	var out := []
	for g in a.graphs:
		if skip.has(int(g.id)):
			continue
		var h := Model.find_graph(b, int(g.id))
		if h != g:
			out.append(String(g.name))
	return out


## Nodes of graph `gid` in `a` that are not in `b` exactly (same id, same everything), leaving out `skip` (ids).
func nodes_moved(a: Dictionary, b: Dictionary, gid: int, skip: Dictionary) -> Array:
	var out := []
	var ga := Model.find_graph(a, gid)
	var gb := Model.find_graph(b, gid)
	for n in ga.nodes:
		if skip.has(int(n.id)):
			continue
		if Model.find_node(gb, int(n.id)) != n:
			out.append(int(n.id))
	return out


## The schematic's own parts other than graphs: equal in a and b.
func head_same(a: Dictionary, b: Dictionary) -> bool:
	var x := a.duplicate()
	var y := b.duplicate()
	x.erase("graphs")
	y.erase("graphs")
	return x == y


# ================================================================ 1. no change

func test_no_change(inputs: Array) -> void:
	print("==== 1. no change: reimport(bp, compile(bp)) keeps everything ====")
	var n := 0
	for inp in inputs:
		var bp: Dictionary = inp.bp
		var before := bp.duplicate(true)
		var code := compiled(bp)
		var r := sync.reimport(bp, Model.build_source(code, bp), {"path": inp.path})
		var all_kept: bool = r.report.functions.all(func(x): return String(x.action) == "kept") and r.report.declarations.is_empty()
		check("same %s: ok, everything kept, the result deep-equals the input, the input untouched (%d functions, %.1f ms)" % [inp.label, r.report.functions.size(), float(r.report.ms)],
			r.ok and all_kept and r.bp == bp and bp == before and r.report.comments_dropped == 0, "%s %s" % [reasons(r), str(r.report.functions.filter(func(x): return x.action != "kept"))])
		n += 1
	info["1. inputs"] = n


# ================================================================ 2. forced rebuild of each function

func test_forced(inputs: Array) -> void:
	print("==== 2. forced rebuild (opts.only) of every function of every input ====")
	var covered := 0
	var good := 0
	var refused := 0
	var findings := []
	for inp in inputs:
		var bp: Dictionary = inp.bp
		var code := compiled(bp)
		var file := Model.build_source(code, bp)
		for fname in user_functions(bp):
			covered += 1
			var r := sync.reimport(bp, file, {"only": [fname], "path": inp.path})
			if not r.ok:
				if expected_refusal(r):
					refused += 1
					print("      refused (by rule) %s %s: %s" % [inp.label, fname, reasons(r)])
					continue
				# the check refused it: nothing wrong was returned, but the rebuilt function does not give the same
				# code (the function-level fixed point): a finding, listed at the end
				findings.append("%s %s: %s" % [inp.label, fname, reasons(r)])
				check("forced %s %s: refused, the input returned unchanged" % [inp.label, fname], r.bp == bp, reasons(r))
				continue
			var again := compiled(r.bp)
			var rebuilt: Array = r.report.functions.filter(func(x): return x.action != "kept")
			var touched := {}
			for k in r.report.replaced:
				touched[int(k)] = true
			var other := graphs_differing(bp, r.bp, touched)
			# in an event graph that was touched, the other events' nodes stay as they were
			var moved := []
			for gid in touched:
				var g := Model.find_graph(bp, int(gid))
				if not g.is_empty() and String(g.kind) == "event":
					var gone := {}
					for id in r.report.replaced[gid]:
						gone[int(id)] = true
					var entry: Dictionary = entries_of(bp).get(fname, {})
					if not entry.is_empty():
						gone[int(entry.nid)] = true
					moved.append_array(nodes_moved(bp, r.bp, int(gid), gone))
			var ok: bool = again == code and other.is_empty() and moved.is_empty() and graph_ids(r.bp) == graph_ids(bp) and head_same(bp, r.bp)
			var detail := ""
			if not ok and again != code and not r.report.reformatted.is_empty() and other.is_empty() and moved.is_empty() and graph_ids(r.bp) == graph_ids(bp) and head_same(bp, r.bp):
				# accepted because the lines mean the same written with other brackets, and reported: the function-level
				# fixed point is not reached (the next save would rewrite those lines): a finding
				findings.append("%s %s: accepted, but the next save writes %d line(s) differently: %s" % [inp.label, fname, r.report.reformatted.size(),
					"; ".join(r.report.reformatted.map(func(x): return "line %d `%s` -> `%s`" % [int(x.line), x.file, x.graph]))])
				print("      reformatted %s" % findings[-1])
				continue
			if ok:
				good += 1
			else:
				detail = "other graphs differ: %s; moved nodes: %s; ids %s -> %s; head same %s" % [str(other), str(moved), str(graph_ids(bp)), str(graph_ids(r.bp)), str(head_same(bp, r.bp))]
				if again != code:
					detail += "\n" + first_diff(code, again)
			check("forced %s %s: ok, the same code, other graphs and events untouched, ids and order the same (%s)" % [inp.label, fname, str(rebuilt.map(func(x): return x.action))], ok, detail)
	info["2. functions covered"] = covered
	info["2. rebuilt to the same code"] = good
	info["2. refused by rule"] = refused
	info["2. findings"] = findings.size()
	for f in findings:
		print("FINDING  ", f)


# ================================================================ edits

const SRC := """extends Node

signal hit(amount: int)

var speed := 2.0
var count: int = 0
var names: Array = []
var unused_flag := false
const LIMIT := 4

func _ready() -> void:
	var start := 3
	for i in range(start):
		names.append("n%d" % i)
	var pick := func(x): return x * 2
	count = pick.call(start)
	print("ready ", count)

func _process(delta: float) -> void:
	var step := speed * delta
	if step > 1.0:
		count += 1
	print(step)

func _physics_process(delta: float) -> void:
	var step := delta * 2.0
	print(step)

func grade(score: int) -> String:
	match score:
		0:
			return "none"
		1, 2:
			return "few"
		_:
			return "many"

func total(items: Array) -> int:
	var sum := 0
	for it in items:
		sum += it
	return sum

func apply(items: Array) -> Array:
	return items.map(func(v): return v + 1)

func helper() -> void:
	print(total([1, 2]))
	count += 1
	print(LIMIT)
"""


## {bp, code}: SRC (or another source) converted, and the code its graph compiles to.
func base(src := SRC) -> Dictionary:
	var bp: Dictionary = Importer.new().convert(src, {}).bp
	return {"bp": bp, "code": compiled(bp)}


## `code` with each [find, replace] applied; "" (and a FAIL) when a find is not there.
func apply_edits(label: String, code: String, pairs: Array) -> String:
	var t := code
	for p in pairs:
		if not t.contains(String(p[0])):
			check(label + ": the edit applies", false, "not found: %s" % String(p[0]).c_escape())
			return ""
		t = t.replace(String(p[0]), String(p[1]))
	return t


## True when two texts are the same code by the re-import's check (functions by name, comments and blank lines
## set aside).
func same_code(a: String, b: String) -> bool:
	return sync._compare(sync._canon(sync.split(Model.normalize_code(a))), sync._canon(sync.split(Model.normalize_code(b))), {}, {"renamed_locals": [], "reformatted": []}).is_empty()


## Re-imports an edited file and checks: ok; the result compiles to the edited code; the functions reported as
## not kept are exactly expect.actions ({name: action}); every graph not reported as replaced deep-equals the
## input's (except expect.other); in an event graph that was touched, every node of the other events is the same
## object (id, place, everything); the schematic's head is the same unless expect.head. Returns the result.
func edited(label: String, bp: Dictionary, file: String, expect: Dictionary, opts := {}) -> Dictionary:
	if file == "":
		return {}
	var before := bp.duplicate(true)
	var r := sync.reimport(bp, file, opts)
	if not r.ok:
		check(label + ": ok", false, reasons(r) + " " + str(r.report.first_difference))
		return r
	var again := compiled(r.bp)
	var same := same_code(again, file)
	var acts := {}
	for x in r.report.functions:
		if String(x.action) != "kept":
			acts[String(x.name)] = String(x.action)
	var touched := {}
	for k in r.report.replaced:
		touched[int(k)] = true
	var other := graphs_differing(bp, r.bp, touched).filter(func(nm): return not expect.get("other", []).has(nm))
	var moved := []
	var entries := entries_of(bp)
	for gid in touched:
		var g := Model.find_graph(bp, int(gid))
		if g.is_empty() or String(g.kind) != "event":
			continue
		var skip := {}
		for id in r.report.replaced[gid]:
			skip[int(id)] = true
		for nm in acts:
			var en: Dictionary = entries.get(nm, {})
			if not en.is_empty() and int(en.gid) == int(gid):
				skip[int(en.nid)] = true
				var now := Model.find_node(Model.find_graph(r.bp, int(gid)), int(en.nid))
				var was := Model.find_node(g, int(en.nid))
				if acts[nm] != "removed" and (now.is_empty() or float(now.x) != float(was.x) or float(now.y) != float(was.y)):
					moved.append("entry of %s" % nm)
		moved.append_array(nodes_moved(bp, r.bp, int(gid), skip))
	var head_ok: bool = head_same(bp, r.bp) or bool(expect.get("head", false))
	var want: Dictionary = expect.get("actions", {})
	var ok: bool = same and acts == want and other.is_empty() and moved.is_empty() and head_ok and bp == before
	check("%s: ok, compiles to the edited code, %s, nothing else changed" % [label, str(acts)], ok,
		"same code %s (%s); actions %s, wanted %s; other graphs %s; nodes of other events moved %s; head same %s" % [same, "" if same else first_diff(file, again), str(acts), str(want), str(other), str(moved), head_ok])
	if show:
		print(again)
	return r


func test_edits() -> void:
	print("==== 3. one edit at a time ====")
	var b := base()
	var bp: Dictionary = b.bp
	var code: String = b.code
	edited("literal", bp, apply_edits("literal", code, [["\tvar sum := 0\n", "\tvar sum := 5\n"]]), {"actions": {"total": "rebuilt"}})
	edited("statement added", bp, apply_edits("statement added", code, [["\tvar sum := 0\n", "\tvar sum := 0\n\tprint(\"start\")\n"]]), {"actions": {"total": "rebuilt"}})
	edited("statement deleted", bp, apply_edits("statement deleted", code, [["\tcount += 1\n\tprint(LIMIT)", "\tprint(LIMIT)"]]), {"actions": {"helper": "rebuilt"}})
	edited("local added", bp, apply_edits("local added", code, [["\tmatch score:\n", "\tvar bonus := 1\n\tmatch (score + bonus):\n"]]), {"actions": {"grade": "rebuilt"}})
	edited("local renamed", bp, apply_edits("local renamed", code, [["\tvar sum := 0\n\tfor it in items:\n\t\tsum += it\n\treturn sum", "\tvar acc := 0\n\tfor it in items:\n\t\tacc += it\n\treturn acc"]]), {"actions": {"total": "rebuilt"}})
	edited("wrapped in an if", bp, apply_edits("wrapped in an if", code, [["\tfor it in items:\n\t\tsum += it\n", "\tif not items.is_empty():\n\t\tfor it in items:\n\t\t\tsum += it\n"]]), {"actions": {"total": "rebuilt"}})
	edited("loop added", bp, apply_edits("loop added", code, [["\tprint(LIMIT)", "\tprint(LIMIT)\n\tfor k in range(2):\n\t\tprint(k)"]]), {"actions": {"helper": "rebuilt"}})
	edited("match arm", bp, apply_edits("match arm", code, [["\t\t1, 2:\n\t\t\treturn \"few\"", "\t\t1, 2, 3:\n\t\t\treturn \"some\""]]), {"actions": {"grade": "rebuilt"}})
	var r := edited("inside a lambda", bp, apply_edits("inside a lambda", code, [["\t\treturn v + 1", "\t\treturn v + 2"]]), {"actions": {"apply": "rebuilt"}})
	if r.get("ok", false):
		var lg := Model.graph_named(bp, "_apply_lambda")
		var lg2 := Model.graph_named(r.bp, "_apply_lambda")
		check("inside a lambda: the lambda graph was replaced and kept its id and place", not lg.is_empty() and not lg2.is_empty() and int(lg.id) == int(lg2.id)
			and bp.graphs.find(lg) == r.bp.graphs.find(lg2) and lg != lg2 and str(r.report.replaced.keys()).contains(str(int(lg.id))), str(r.report.replaced.keys()))
	r = edited("new lambda", bp, apply_edits("new lambda", code, [["\tprint(LIMIT)", "\tprint(LIMIT)\n\tvar twice := func(n):\n\t\treturn (n * 2)\n\tprint(twice.call(4))"]]), {"actions": {"helper": "rebuilt"}})
	if r.get("ok", false):
		var lg := Model.graph_named(r.bp, "_helper_lambda")
		var top := 0
		for g in bp.graphs:
			top = maxi(top, int(g.id))
		check("new lambda: a lambda graph was added with an id no other graph has", not lg.is_empty() and int(lg.id) > top and r.bp.graphs.size() == bp.graphs.size() + 1, str(graph_ids(r.bp)))
	# what the converter can only keep as a code node comes back as one, and the report says how much
	r = edited("kept as a code node", bp, apply_edits("code node", code, [["\t\t_:\n\t\t\treturn \"many\"\n", "\t\t_:\n\t\t\treturn \"many\"\n\t\t9:\n\t\t\treturn \"nine\"\n"]]), {"actions": {"grade": "rebuilt"}})
	if r.get("ok", false):
		check("kept as a code node: code_node_lines reported", int(r.report.code_node_lines) > 0, str(r.report.code_node_lines))
	# breakpoint is a node of its own now: it comes back
	r = edited("breakpoint", bp, apply_edits("breakpoint", code, [["\tcount += 1\n\tprint(LIMIT)", "\tcount += 1\n\tbreakpoint\n\tprint(LIMIT)"]]), {"actions": {"helper": "rebuilt"}})
	if r.get("ok", false):
		check("breakpoint: the rebuilt graph writes it", compiled(r.bp).contains("\tcount += 1\n\tbreakpoint\n\tprint(LIMIT)"))
	# a statement the converter drops (an expression with no effect): the check sees the graph would not write it, and refuses
	r = sync.reimport(bp, apply_edits("dropped statement", code, [["\tcount += 1\n\tprint(LIMIT)", "\tcount += 1\n\tcount\n\tprint(LIMIT)"]]))
	check("a statement the converter drops: refused by the check, the first difference named (%s)" % reasons(r), not r.ok and r.bp == bp and not r.report.first_difference.is_empty()
		and String(r.report.first_difference[0].file).strip_edges() == "count" and int(r.report.first_difference[0].line) > 0)
	# a comment inside Schematic's own code is only a comment
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	var dcode := compiled(demo)
	r = sync.reimport(demo, apply_edits("comment in a helper", dcode, [["\tif keys.is_empty():\n", "\t# nothing to sample\n\tif keys.is_empty():\n"]]))
	check("a comment in a helper: ok, nothing changed, the comment counted", r.ok and r.bp == demo and int(r.report.comments_dropped) == 1, reasons(r))
	# formatting: a whole value written without brackets is written back so; brackets the person leaves out inside a
	# larger expression are the ones Schematic writes, and the next save adds them
	r = edited("written without brackets", bp, apply_edits("written without brackets", code, [["\t\treturn v + 1", "\t\treturn v + 3"], ["\tvar sum := 0\n", "\tvar sum := items.size() * 3 + 1\n"]]),
		{"actions": {"apply": "rebuilt", "total": "rebuilt"}})
	if r.get("ok", false):
		check("written without brackets: the lines the next save writes differently are reported", r.report.reformatted.size() == 1 and r.report.reformatted.any(func(x): return String(x.file) == "var sum := items.size() * 3 + 1" and String(x.graph) == "var sum := (items.size() * 3) + 1" and int(x.line) > 0), str(r.report.reformatted))


## A literal in each function of each converted sample changed by one: every one should come back.
func test_sample_edits(inputs: Array) -> void:
	print("==== 3. a literal changed in every function of every converted sample ====")
	var num := RegEx.create_from_string("(?<![\\w.\"'])(\\d+)(?![\\w.\"'])")
	var tried := 0
	var good := 0
	for inp in inputs:
		if inp.demo:
			continue
		var bp: Dictionary = inp.bp
		var code := compiled(bp)
		var blocks := sync.split(code)
		var c := Compiler.new()
		c.compile(bp.duplicate(true))
		sync.classify(blocks, c)
		for blk in blocks:
			if blk.kind != "func" or blk.owner != "user":
				continue
			var lines := String(blk.text).split("\n")
			var at := -1
			var m: RegExMatch = null
			for i in range(1, lines.size()):
				var t := lines[i]
				if t.contains("\"") or t.contains("'") or t.contains("#"):
					continue
				m = num.search(t)
				if m != null:
					at = i
					break
			if at == -1:
				continue
			tried += 1
			var line := lines[at]
			lines[at] = line.substr(0, m.get_start(1)) + str(int(m.get_string(1)) + 1) + line.substr(m.get_end(1))
			var file := code.replace(String(blk.text), "\n".join(lines))
			var r := sync.reimport(bp, file, {"path": inp.path})
			var ok: bool = r.ok and same_code(compiled(r.bp), file) and graphs_differing(bp, r.bp, _keys(r.report.replaced)).is_empty()
			if ok:
				good += 1
			check("literal in %s %s (line %d: %s): ok, compiles to the file, nothing else changed" % [inp.label, blk.name, int(blk.from) + at, lines[at].strip_edges()], ok, reasons(r) + " " + str(r.report.first_difference))
	info["3. sample literal edits"] = "%d of %d" % [good, tried]


func _keys(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[int(k)] = true
	return out


# ================================================================ 4. events

func test_events() -> void:
	print("==== 4. events in the shared EventGraph ====")
	var b := base()
	var bp: Dictionary = b.bp
	var code: String = b.code
	edited("event literal (_ready)", bp, apply_edits("event literal", code, [["\tvar start := 3\n", "\tvar start := 4\n"]]), {"actions": {"_ready": "rebuilt"}})
	edited("event statement (_process)", bp, apply_edits("event statement", code, [["\t\tcount += 1\n", "\t\tcount += 1\n\t\tprint(\"tick\")\n"]]), {"actions": {"_process": "rebuilt"}})
	var r := edited("lambda in an event (_ready)", bp, apply_edits("lambda in an event", code, [["\t\treturn x * 2", "\t\treturn x * 3"]]), {"actions": {"_ready": "rebuilt"}})
	if r.get("ok", false):
		var lg := Model.graph_named(bp, "_ready_lambda")
		var lg2 := Model.graph_named(r.bp, "_ready_lambda")
		check("lambda in an event: its graph replaced in place, same id", not lg.is_empty() and not lg2.is_empty() and int(lg.id) == int(lg2.id) and lg != lg2, str(bp.graphs.map(func(g): return g.name)))
	# a local whose name another event declares: the conversion gives it the event's name
	var file := apply_edits("clashing local", code, [["\tprint(\"ready \", count)\n", "\tprint(\"ready \", count)\n\tvar step_process := 1\n\tprint(step_process)\n"]])
	r = sync.reimport(bp, file)
	var again := compiled(r.bp) if r.ok else ""
	check("clashing local: ok, the rename is reported, the code is the file with that name", r.ok and r.report.renamed_locals.size() == 1
		and String(r.report.renamed_locals[0].written) == "step_process" and String(r.report.renamed_locals[0].now) == "step_process_ready"
		and again.contains("\tvar step_process_ready := 1\n\tprint(step_process_ready)") and same_code(again, file.replace("var step_process := 1\n\tprint(step_process)", "var step_process_ready := 1\n\tprint(step_process_ready)")),
		reasons(r) + " " + str(r.report.get("renamed_locals", [])) + " " + str(r.report.first_difference))
	# the ids and places of the other events' nodes, asserted directly
	r = sync.reimport(bp, apply_edits("event ids", code, [["\tvar start := 3\n", "\tvar start := 6\n"]]))
	if r.ok:
		var eg: Dictionary = bp.graphs[0]
		var eg2: Dictionary = r.bp.graphs[0]
		var going := _keys({})
		for id in r.report.replaced.get(int(eg.id), []):
			going[int(id)] = true
		var kept: Array = eg.nodes.filter(func(n): return not going.has(int(n.id)))
		var same: bool = kept.all(func(n): var m := Model.find_node(eg2, int(n.id)); return not m.is_empty() and float(m.x) == float(n.x) and float(m.y) == float(n.y) and String(m.kind) == String(n.kind))
		var procs: Array = eg.nodes.filter(func(n): return String(n.kind) == "event" and String(n.p.name) != "_ready")
		check("event ids: the %d nodes of _process and _physics_process keep their ids and coordinates (%d replaced)" % [kept.size(), going.size()],
			same and procs.size() == 2 and procs.all(func(n): return not going.has(int(n.id))) and int(eg.id) == int(eg2.id))


# ================================================================ 5. added, removed, renamed

func test_add_remove_rename() -> void:
	print("==== 5. added, removed, renamed ====")
	var b := base()
	var bp: Dictionary = b.bp
	var code: String = b.code
	var r := edited("function added", bp, code + "\n\nfunc extra() -> void:\n\tprint(\"extra\")\n", {"actions": {"extra": "added"}})
	if r.get("ok", false):
		check("function added: a new graph at the end", String(r.bp.graphs[-1].name) == "extra" and r.bp.graphs.size() == bp.graphs.size() + 1)
	r = edited("event added", bp, code + "\n\nfunc _enter_tree() -> void:\n\tprint(\"in\")\n", {"actions": {"_enter_tree": "added"}})
	if r.get("ok", false):
		var eg: Dictionary = r.bp.graphs[0]
		var entry: Dictionary = eg.nodes.filter(func(n): return String(n.kind) == "event" and String(n.p.name) == "_enter_tree")[0]
		var lowest := 0.0
		for n in bp.graphs[0].nodes:
			lowest = maxf(lowest, float(n.y))
		check("event added: its entry is below every node that was there", float(entry.y) > lowest, "%s vs %s" % [entry.y, lowest])
	var apply_text := ""
	for blk in sync.split(code):
		if blk.kind == "func" and blk.name == "apply":
			apply_text = String(blk.text)
	r = edited("function removed", bp, code.replace(apply_text, ""), {"actions": {"apply": "removed"}})
	if r.get("ok", false):
		check("function removed: its graph and its lambda graph are gone", Model.graph_named(r.bp, "apply").is_empty() and Model.graph_named(r.bp, "_apply_lambda").is_empty()
			and r.bp.graphs.size() == bp.graphs.size() - 2)
	var phys := ""
	for blk in sync.split(code):
		if blk.kind == "func" and blk.name == "_physics_process":
			phys = String(blk.text)
	r = edited("event removed", bp, code.replace(phys, ""), {"actions": {"_physics_process": "removed"}})
	if r.get("ok", false):
		var eg: Dictionary = r.bp.graphs[0]
		check("event removed: its entry, its chain and its local are gone", eg.nodes.all(func(n): return not (String(n.kind) == "event" and String(n.p.name) == "_physics_process"))
			and eg.locals.all(func(l): return String(l.name) != "step_physics_process") and eg.nodes.size() < bp.graphs[0].nodes.size())
	var total_text := ""
	for blk in sync.split(code):
		if blk.kind == "func" and blk.name == "total":
			total_text = String(blk.text)
	r = sync.reimport(bp, code.replace(total_text, ""))
	check("removed but still called: refused, the input returned, the reason names the line of the call", not r.ok and r.bp == bp
		and r.report.refused.size() >= 1 and String(r.report.refused[0].reason).contains("line ") and int(r.report.refused[0].line) > 0, reasons(r))
	r = edited("renamed, callers updated", bp, code.replace("func total(", "func sum_all(").replace("print(total(", "print(sum_all("), {"actions": {"sum_all": "renamed"}, "other": ["helper", "total"]})
	if r.get("ok", false):
		var old := Model.graph_named(bp, "total")
		var now := Model.graph_named(r.bp, "sum_all")
		var renamed_copy := old.duplicate(true)
		renamed_copy.name = "sum_all"
		var helper := Model.graph_named(r.bp, "helper")
		check("renamed, callers updated: the same graph (id, nodes) under the new name, and the caller's node names it",
			now == renamed_copy and helper.nodes.any(func(n): return String(n.kind) == "call_self" and String(n.p.fn) == "sum_all"), "")
	r = sync.reimport(bp, code.replace("func total(", "func sum_all("))
	check("renamed, callers not updated: refused, the reason names the line", not r.ok and r.bp == bp and String(reasons(r)).contains("line "), reasons(r))


# ================================================================ 6. declarations

func test_declarations() -> void:
	print("==== 6. declarations ====")
	var b := base()
	var bp: Dictionary = b.bp
	var code: String = b.code
	var r := edited("member added and used", bp, apply_edits("member added", code, [["var unused_flag := false\n", "var unused_flag := false\nvar bonus: int = 5\n"], ["\treturn sum\n", "\treturn (sum + bonus)\n"]]),
		{"actions": {"total": "rebuilt"}, "head": true})
	if r.get("ok", false):
		var v := Model.find_var(r.bp, "bonus")
		check("member added: in the variable list after unused_flag, the others as they were", not v.is_empty() and r.bp.variables.size() == bp.variables.size() + 1
			and r.bp.variables.find(v) == bp.variables.find(Model.find_var(bp, "unused_flag")) + 1 and r.bp.variables.filter(func(x): return x.name != "bonus") == bp.variables, str(r.bp.variables))
	# a tooltip and a category the editor keeps survive a change of type and default
	var bp2 := bp.duplicate(true)
	Model.find_var(bp2, "speed")["tooltip"] = "how fast"
	Model.find_var(bp2, "speed")["category"] = "Motion"
	var code2 := compiled(bp2)
	r = edited("member type and default", bp2, apply_edits("member type", code2, [["var speed := 2.0", "var speed: float = 3.5"]]), {"actions": {}, "head": true})
	if r.get("ok", false):
		var v := Model.find_var(r.bp, "speed")
		check("member type and default: the file's, the tooltip and category kept", String(v.type) == "float" and String(v.default) == "3.5" and String(v.get("tooltip", "")) == "how fast"
			and String(v.get("category", "")) == "Motion" and r.report.declarations.size() == 1, str(v) + " " + str(r.report.declarations))
	r = edited("unused member removed", bp, apply_edits("member removed", code, [["var unused_flag := false\n", ""]]), {"actions": {}, "head": true})
	if r.get("ok", false):
		check("unused member removed: gone from the list", Model.find_var(r.bp, "unused_flag").is_empty() and r.bp.variables.size() == bp.variables.size() - 1)
	r = edited("signal added and emitted", bp, apply_edits("signal added", code, [["signal hit(amount: int)\n", "signal hit(amount: int)\nsignal done\n"], ["\tprint(LIMIT)", "\tprint(LIMIT)\n\tdone.emit()"]]),
		{"actions": {"helper": "rebuilt"}, "head": true})
	if r.get("ok", false):
		check("signal added: in the list after hit", r.bp.dispatchers.size() == 2 and String(r.bp.dispatchers[1].name) == "done")
	r = edited("carried code", bp, apply_edits("carried code", code, [["const LIMIT := 4", "const LIMIT := 5"]]), {"actions": {}, "head": true})
	if r.get("ok", false):
		check("carried code: extra_code is the file's", String(r.bp.get("extra_code", "")) == "const LIMIT := 5", String(r.bp.get("extra_code", "")))
	r = edited("extends changed", bp, apply_edits("extends", code, [["extends Node\n", "extends Node2D\n"]]), {"actions": {}, "head": true})
	if r.get("ok", false):
		check("extends changed: the parent is the file's", String(r.bp.parent) == "Node2D")


# ================================================================ 7. refusals

func refused(label: String, bp: Dictionary, file: String, words := "") -> void:
	if file == "":
		return
	var before := bp.duplicate(true)
	var r := sync.reimport(bp, file)
	var named: bool = r.report.refused.all(func(x): return String(x.reason).contains("line ") and int(x.line) > 0)
	check("%s: refused, the input returned unchanged, the reason names the line (%s)" % [label, reasons(r)], not r.ok and r.bp == bp and bp == before
		and not r.report.refused.is_empty() and named and (words == "" or reasons(r).contains(words)))


func test_refusals() -> void:
	print("==== 7. refusals ====")
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	var dcode := compiled(demo)
	refused("helper edited", demo, apply_edits("helper", dcode, [["\treturn keys[-1][1]", "\treturn keys[0][1]"]]), "written by Schematic")
	refused("prelude line edited", demo, apply_edits("prelude", dcode, [["func _ready() -> void:\n\t__tl_pulse_1_27_run()\n", "func _ready() -> void:\n\t__tl_pulse_1_27_sample()\n"]]), "written by Schematic")
	refused("input action function edited", demo, apply_edits("input action", dcode, [["\t\tspin_speed = (spin_speed / 4.0)", "\t\tspin_speed = (spin_speed / 5.0)"]]), "Input Action")
	var b := base()
	refused("syntax error", b.bp, apply_edits("syntax", b.code, [["\tcount += 1\n\tprint(LIMIT)", "\tcount += \n\tprint(LIMIT)"]]), "does not load")
	refused("state member edited", demo, apply_edits("state member", dcode, [["var __delay_1_5: bool = false", "var __delay_1_5: bool = true"]]), "written by Schematic")


# ================================================================ 8. comments

func test_comments() -> void:
	print("==== 8. comments ====")
	var b := base()
	var bp: Dictionary = b.bp
	var file := apply_edits("comments", b.code, [["\n\nfunc total(", "\n\n# adds them up\nfunc total("], ["\tvar sum := 0\n", "\tvar sum := 0  # start at nothing\n"], ["\tcount += 1\n\tprint(LIMIT)", "\tcount += 1\n\t# and show the limit\n\tprint(LIMIT)"]])
	# the converter keeps comments: a function whose only change is a comment is rebuilt, and the result writes the
	# comment where the file has it
	var r := sync.reimport(bp, file)
	var rebuilt: Array = r.report.functions.filter(func(x): return x.action != "kept").map(func(x): return x.name)
	rebuilt.sort()
	var again := compiled(r.bp) if r.ok else ""
	check("three comments: ok, none dropped, total and helper rebuilt, the result writes the file's code exactly (comments on their lines)", r.ok
		and int(r.report.comments_dropped) == 0 and rebuilt == ["helper", "total"] and same_code(again, file) and Model.normalize_code(again) == Model.normalize_code(Model.code_part(file)),
		"%s %s %s %s\n%s" % [reasons(r), r.report.comments_dropped, str(r.report.comment_lines), str(rebuilt), again])
	if r.ok:
		var total_g := Model.graph_named(r.bp, "total")
		var entry: Dictionary = total_g.nodes.filter(func(n): return String(n.kind) == "fn_entry")[0] if not total_g.is_empty() else {}
		check("three comments: the comment above func total is its entry node's note", entry.get("p", {}).get("note", []) == ["# adds them up"], str(entry.get("p", {})))
		var tails: Array = total_g.nodes.filter(func(n): return String(n.p.get("tail", "")) == "  # start at nothing")
		check("three comments: the trailing comment is the tail of the node that writes `var sum := 0`", tails.size() == 1 and String(tails[0].kind) == "local_set", str(tails))
		var again2 := sync.reimport(r.bp, Model.build_source(again, r.bp))
		check("three comments: re-importing the result keeps everything", again2.ok and again2.bp == r.bp and again2.report.functions.all(func(x): return x.action == "kept"), reasons(again2))
		# a comment changed, nothing else: the function is rebuilt and writes the new comment
		var r2 := sync.reimport(r.bp, apply_edits("comment changed", again, [["# start at nothing", "# start empty"]]))
		check("a comment changed: ok, total rebuilt, the new comment written", r2.ok and r2.report.functions.filter(func(x): return x.action != "kept").map(func(x): return x.name) == ["total"]
			and compiled(r2.bp).contains("\tvar sum := 0  # start empty\n") and int(r2.report.comments_dropped) == 0, reasons(r2) + str(r2.report.functions))
	r = sync.reimport(bp, apply_edits("comments and an edit", file, [["\tvar sum := 0  # start at nothing\n", "\tvar sum := 1  # start at one\n"]]))
	rebuilt = r.report.functions.filter(func(x): return x.action != "kept").map(func(x): return x.name)
	rebuilt.sort()
	check("comments and an edit: ok, the edit brought in, no comment dropped", r.ok and int(r.report.comments_dropped) == 0
		and rebuilt == ["helper", "total"] and compiled(r.bp).contains("\tvar sum := 1  # start at one\n"), reasons(r) + str(r.report.functions))
	# what the converter can't keep is still counted: a comment written into Schematic's own code (see test 3) and a
	# comment between declarations that is given to the variable below it
	r = sync.reimport(bp, apply_edits("comment above a variable", b.code, [["var unused_flag := false\n", "# not used yet\nvar unused_flag := false\n"]]))
	check("a comment above a variable: ok, the variable's note, written back", r.ok and Model.find_var(r.bp, "unused_flag").get("note", []) == ["# not used yet"]
		and compiled(r.bp).contains("# not used yet\nvar unused_flag := false\n") and int(r.report.comments_dropped) == 0, reasons(r) + str(Model.find_var(r.bp, "unused_flag")))


# ================================================================ 9. hand-made graphs

func test_hand_made() -> void:
	print("==== 9. hand-made graphs (positions and comment boxes a person arranged) ====")
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	var dcode := compiled(demo)
	var r := edited("SC_Demo function wave", demo, apply_edits("wave", dcode, [["sin((t * 3.0))", "sin((t * 5.0))"]]), {"actions": {"wave": "rebuilt"}})
	if r.get("ok", false):
		var boxes: Array = demo.graphs[0].nodes.filter(func(n): return String(n.kind) == "comment")
		check("SC_Demo wave: the EventGraph with its comment boxes deep-equals the original", r.bp.graphs[0] == demo.graphs[0] and not boxes.is_empty())
	r = edited("SC_Demo event _process", demo, apply_edits("_process", dcode, [["\ttime = (time + delta)\n", "\ttime = (time + (delta * 2.0))\n"]]), {"actions": {"_process": "rebuilt"}})
	if r.get("ok", false):
		var eg: Dictionary = demo.graphs[0]
		var eg2: Dictionary = r.bp.graphs[0]
		var boxes: Array = eg.nodes.filter(func(n): return String(n.kind) == "comment")
		check("SC_Demo _process: every comment box is still there, unchanged", boxes.all(func(n): return Model.find_node(eg2, int(n.id)) == n))
	var player := Model.load_file("res://demo/game/SC_Player.gd")
	var pcode := compiled(player)
	r = edited("SC_Player event _physics_process", player, apply_edits("_physics_process", pcode, [["* speed)\n", "* (speed * 2.0))\n"]]), {"actions": {"_physics_process": "rebuilt"}})
	var arcade := Model.load_file("res://demo/arcade/SC_ArcadeHUD.gd")
	var acode := compiled(arcade)
	# a custom event: its code converts to a function; the chain goes back under the custom event node
	r = edited("SC_ArcadeHUD custom event OnScoreChanged", arcade, apply_edits("custom event", acode, [["\"Score: {score}\"", "\"Points: {score}\""]]), {"actions": {"OnScoreChanged": "rebuilt"}})
	if r.get("ok", false):
		var ce := func(bp: Dictionary) -> Array: return bp.graphs[0].nodes.filter(func(n): return String(n.kind) == "custom_event")
		var was: Array = ce.call(arcade)
		var now: Array = ce.call(r.bp)
		check("custom event: still one custom event node, same id and place, and no function graph made for it", was.size() == 1 and now.size() == 1 and int(was[0].id) == int(now[0].id)
			and float(was[0].x) == float(now[0].x) and float(was[0].y) == float(now[0].y) and Model.graph_named(r.bp, "OnScoreChanged").is_empty() and r.bp.graphs.size() == arcade.graphs.size())
	# a _ready Schematic made only to connect a signal, given a line of the person's: a new _ready event
	var coin := Model.load_file("res://demo/game/SC_Coin.gd")
	var ccode := compiled(coin)
	r = edited("SC_Coin prelude-only _ready given a line", coin, apply_edits("prelude given", ccode, [["\tbody_entered.connect(_on_self_body_entered)\n", "\tbody_entered.connect(_on_self_body_entered)\n\tprint(\"coin ready\")\n"]]), {"actions": {"_ready": "added"}})
	if r.get("ok", false):
		check("SC_Coin: the connect line is still written first, by the Signal event node", compiled(r.bp).contains("func _ready() -> void:\n\tbody_entered.connect(_on_self_body_entered)\n\tprint(\"coin ready\")"))
	var first_event := ""
	for nm in user_functions(arcade):
		if entries_of(arcade)[nm].kind == "event":
			first_event = nm
			break
	r = sync.reimport(arcade, Model.build_source(acode, arcade), {"only": [first_event]})
	check("SC_ArcadeHUD event %s rebuilt as it was: ok, the same code" % first_event, r.ok and compiled(r.bp) == acode, reasons(r))


# ================================================================ 10. macros

const MACRO_SRC := """extends Node

var hp := 20
var shield := 5
var log: Array = []

func hit(amount: int):
	var left := hp - amount * 2
	if left < 0:
		left = 0
		log.append("down by hit")
	hp = left
	shield = maxi(shield - 1, 0)
	log.append("hit %d" % amount)

func burn(amount: int):
	var left := hp - amount * 3
	if left < 0:
		left = 0
		log.append("down by burn")
	hp = left
	shield = maxi(shield - 2, 0)
	log.append("burn %d" % amount)

func freeze(amount: int):
	var left := hp - amount * 1
	if left < 0:
		left = 0
		log.append("down by freeze")
	hp = left
	shield = maxi(shield - 3, 0)
	log.append("freeze %d" % amount)
"""


func test_macros() -> void:
	print("==== 10. macros ====")
	var bp: Dictionary = Importer.new().convert(MACRO_SRC, {}).bp
	var before := compiled(bp)
	var rep: Dictionary = Reuse.new().run([{"path": SCRATCH + "macro_one.gd", "bp": bp}], "")
	var code := compiled(bp)
	var uses := func(g: Dictionary) -> int: return g.nodes.filter(func(n): return String(n.kind) == "macro").size()
	check("macros: reuse made macros used by the three functions, the code the same", int(rep.macros) >= 1 and Reuse.same_code(before, code)
		and ["hit", "burn", "freeze"].all(func(nm): return uses.call(Model.graph_named(bp, nm)) > 0), str(rep))
	var burn := ""
	for blk in sync.split(code):
		if blk.kind == "func" and blk.name == "burn":
			burn = String(blk.text)
	var lines := burn.split("\n")
	var changed := burn.replace("\"down by burn\"", "\"burnt down\"")
	var r := edited("macro function edited", bp, code.replace(burn, changed), {"actions": {"burn": "rebuilt"}})
	if r.get("ok", false):
		check("macro function edited: macros_expanded reported, burn uses no macro now, hit and freeze still do (untouched), the macro graphs kept",
			int(r.report.macros_expanded) > 0 and uses.call(Model.graph_named(r.bp, "burn")) == 0 and Model.graph_named(r.bp, "hit") == Model.graph_named(bp, "hit")
			and Model.graph_named(r.bp, "freeze") == Model.graph_named(bp, "freeze") and bp.graphs.filter(func(g): return g.kind == "macro").all(func(g): return Model.find_graph(r.bp, int(g.id)) == g),
			"macros_expanded %d" % int(r.report.macros_expanded))
	if lines.size() < 2:
		check("macros: burn found", false)


# ================================================================ 11. stability

func test_stability() -> void:
	print("==== 11. stability ====")
	var b := base()
	var file := apply_edits("stability", b.code, [["\tvar sum := 0\n", "\tvar sum := 7\n"], ["\tvar start := 3\n", "\tvar start := 9\n"]])
	var r1 := sync.reimport(b.bp, file)
	var r2 := sync.reimport(r1.bp, file)
	check("twice in a row: the second result deep-equals the first and keeps everything", r1.ok and r2.ok and r2.bp == r1.bp
		and r2.report.functions.all(func(x): return x.action == "kept") and r2.report.declarations.is_empty(), reasons(r1) + reasons(r2))
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	file = apply_edits("stability demo", compiled(demo), [["sin((t * 3.0))", "sin((t * 4.0))"]])
	r1 = sync.reimport(demo, file)
	r2 = sync.reimport(r1.bp, file)
	check("twice in a row (SC_Demo): the same", r1.ok and r2.ok and r2.bp == r1.bp and r2.report.functions.all(func(x): return x.action == "kept"), reasons(r1) + reasons(r2))


# ================================================================ options

func test_options() -> void:
	print("==== options ====")
	var b := base()
	var file := apply_edits("dry", b.code, [["\tvar sum := 0\n", "\tvar sum := 8\n"]])
	var r := sync.reimport(b.bp, file, {"dry": true})
	check("dry: ok, the report says what it would do, the input returned unchanged", r.ok and r.report.dry and r.bp == b.bp
		and r.report.functions.filter(func(x): return x.action != "kept").map(func(x): return x.name) == ["total"], reasons(r))
	r = sync.reimport(b.bp, b.code, {"only": ["grade", "_process"]})
	check("only: the two named are rebuilt, ok, the same code", r.ok and compiled(r.bp) == b.code
		and r.report.functions.filter(func(x): return x.action == "rebuilt").map(func(x): return x.name) == ["_process", "grade"], reasons(r) + str(r.report.functions))
	r = sync.reimport(b.bp, b.code.replace("\n", "\r\n"))
	check("a file with Windows line endings: nothing to do", r.ok and r.bp == b.bp and r.report.functions.all(func(x): return x.action == "kept"), reasons(r))
	r = sync.reimport(b.bp, file.replace("\n", "\r\n"))
	check("an edit in a file with Windows line endings: brought in", r.ok and r.report.functions.filter(func(x): return x.action != "kept").map(func(x): return x.name) == ["total"], reasons(r))
	# Show Flow and Values on: the trace lines carry node ids, which a rebuilt function changes
	var traced: Dictionary = b.bp.duplicate(true)
	traced["trace"] = true
	var tcode := compiled(traced)
	r = edited("trace on, an edit", traced, apply_edits("trace", tcode, [["\tvar start := 3\n", "\tvar start := 5\n"], ["\tvar sum := 0\n", "\tvar sum := 2\n"]]), {"actions": {"_ready": "rebuilt", "total": "rebuilt"}})
	r = sync.reimport(traced, apply_edits("trace line", tcode, [["\t__sc_trace(", "\t__sc_trace( "]]))
	check("trace on: a trace line edited is not a re-import (set aside like the trace itself), nothing changes", r.ok and r.bp == traced, reasons(r))


# ================================================================ 12. speed

func test_speed(inputs: Array) -> void:
	print("==== 12. speed ====")
	var biggest := {}
	var size := 0
	for inp in inputs:
		if inp.demo:
			continue
		var n := FileAccess.get_file_as_string(inp.path).length()
		if n > size:
			size = n
			biggest = inp
	var bp: Dictionary = biggest.bp
	var code := compiled(bp)
	var blocks := sync.split(code)
	var c := Compiler.new()
	c.compile(bp.duplicate(true))
	sync.classify(blocks, c)
	var target: Dictionary = {}
	for blk in blocks:
		if blk.kind == "func" and blk.owner == "user" and String(blk.text).contains(" 1"):
			target = blk
	if target.is_empty():
		check("speed: a function to edit", false)
		return
	var file := code.replace(String(target.text), String(target.text).replace(" 1", " 2"))
	var best := 1e9
	var conv_best := 1e9
	var ok := true
	for i in 3:
		var t0 := Time.get_ticks_usec()
		var r := sync.reimport(bp, file, {"path": biggest.path})
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		ok = ok and r.ok
		var t1 := Time.get_ticks_usec()
		Importer.new().convert(file, {"path": biggest.path})
		conv_best = minf(conv_best, (Time.get_ticks_usec() - t1) / 1000.0)
	print("TIMING reimport of a one-function edit (%s in %s, %d lines): %.1f ms; one whole-file conversion: %.1f ms" % [target.name, biggest.label, code.split("\n").size(), best, conv_best])
	info["12. reimport ms"] = snappedf(best, 0.1)
	info["12. conversion ms"] = snappedf(conv_best, 0.1)
	check("speed: ok, and under three whole-file conversions (%.1f ms vs %.1f ms)" % [best, conv_best], ok and best < conv_best * 3.0)


# ================================================================ 13. keeping what did not change (opts.gentle)

const LONG_SRC := """extends Node

var hp := 10
var mp := 5
var log: Array = []

func step(n: int) -> int:
	var a := n + 1
	var b := a * 2
	hp -= 1
	log.append("first")
	print(a, b)
	var c := b - 3
	hp += c
	log.append("second")
	print(hp)
	mp = mp + 2
	var d := c * 4
	print("done", d)
	return d + a

func _ready() -> void:
	var x := 1
	print("one")
	x += 2
	print("two", x)
	log.append(x)
	x *= 3
	print("three")
	hp = x
	print("four")
	mp = 7

func _process(delta: float) -> void:
	var t := delta * 2.0
	print(t)
	hp += 1
	print("p")

func _physics_process(delta: float) -> void:
	mp += 1
	print("phys", delta)

func each(items: Array) -> void:
	for it in items:
		print(it)
		hp += it
	print("after")
	log.append("each")
	mp = 3
	print(hp)

func lam(items: Array) -> Array:
	var k := 3
	print(k)
	var f := func(v):
		var w = v * 2
		print(w)
		hp += 1
		return w + 1
	print("made")
	log.append("lam")
	return items.map(f)

func twins() -> void:
	print("x")
	hp += 1
	print("x")
	mp += 1
	print("y")
	log.append("t")
"""


## The nodes of graph `g` that may go when the line written by node `writer` changes: that node, the execution
## nodes that write no line of their own and lead straight into it, the data nodes that feed only those, and any
## reroute node. (Worked out here from the wires, not with the re-import's own code.)
func line_nodes(bp: Dictionary, g: Dictionary, writer: int, node_lines: Dictionary) -> Dictionary:
	var has_exec := {}
	for n in g.nodes:
		if String(n.kind) == "comment":
			continue
		var d := R.describe(n, bp, g)
		has_exec[int(n.id)] = d.get("ins", []).any(func(x): return String(x.type) == "exec") or d.get("outs", []).any(func(x): return String(x.type) == "exec")
	var set := {writer: true}
	for w in g.wires:
		if int(w[2]) == writer and bool(has_exec.get(int(w[0]), false)) and not node_lines.has("%d:%d" % [int(g.id), int(w[0])]):
			set[int(w[0])] = true
	var outs := {}
	for w in g.wires:
		if not outs.has(int(w[0])):
			outs[int(w[0])] = []
		outs[int(w[0])].append(int(w[2]))
	var more := true
	while more:
		more = false
		for n in g.nodes:
			var id := int(n.id)
			if set.has(id) or String(n.kind) == "comment" or bool(has_exec.get(id, true)) or not outs.has(id):
				continue
			if outs[id].all(func(t): return set.has(t)):
				set[id] = true
				more = true
	return set


## The nodes a re-import of function `name` could keep: its graph's (an event: its chain), and of the lambda graphs
## the report lists as replaced.
func considered(bp: Dictionary, name: String, replaced: Dictionary) -> Dictionary:
	var out := {}   # gid -> {id: true}
	var en: Dictionary = entries_of(bp).get(name, {})
	if en.is_empty():
		return out
	for gid in [int(en.gid)] + replaced.keys().map(func(k): return int(k)):
		var g := Model.find_graph(bp, int(gid))
		if g.is_empty() or out.has(int(gid)):
			continue
		var ids := {}
		if String(g.kind) == "event" and int(gid) == int(en.gid):
			ids = sync._extent(bp, g, int(en.nid))
		else:
			for n in g.nodes:
				ids[int(n.id)] = true
		for n in g.nodes:
			if String(n.kind) == "comment":
				ids.erase(int(n.id))
		out[int(gid)] = ids
	return out


## Every node of the graphs `r` touched that is not listed as replaced is in the result with the same id, kind and
## place; and no two nodes of a touched graph sit exactly on each other. "" when so, else what is wrong.
func kept_in_place(bp: Dictionary, r: Dictionary) -> String:
	var bad := []
	for k in r.report.replaced:
		var g := Model.find_graph(bp, int(k))
		var h := Model.find_graph(r.bp, int(k))
		if g.is_empty() or h.is_empty():
			continue
		var gone := {}
		for id in r.report.replaced[k]:
			gone[int(id)] = true
		for n in g.nodes:
			if gone.has(int(n.id)):
				continue
			var m := Model.find_node(h, int(n.id))
			if m.is_empty() or String(m.kind) != String(n.kind) or float(m.x) != float(n.x) or float(m.y) != float(n.y):
				bad.append("g%d n%d %s" % [int(k), int(n.id), "gone" if m.is_empty() else "moved or changed kind"])
		var at := {}
		for m in h.nodes:
			var key := "%s,%s" % [m.x, m.y]
			if at.has(key):
				bad.append("g%d n%d and n%d sit on each other" % [int(k), int(at[key]), int(m.id)])
			at[key] = int(m.id)
	return ", ".join(bad.slice(0, 6))


## Re-imports `file` with and without keeping nodes and checks both: ok, both compile to the file (so to the same
## code), every node not listed as replaced kept in place. Returns the gentle result (with "full": the other).
func gentle_case(label: String, bp: Dictionary, file: String, fname: String, want_path := "gentle") -> Dictionary:
	if file == "":
		return {}
	var before := bp.duplicate(true)
	var r := sync.reimport(bp, file)
	var rf := sync.reimport(bp, file, {"gentle": false})
	var row: Dictionary = r.report.gentle.get(fname, {})
	var ok: bool = r.ok and rf.ok
	var same := ok and same_code(compiled(r.bp), file) and same_code(compiled(rf.bp), file) and same_code(compiled(r.bp), compiled(rf.bp))
	var placed := kept_in_place(bp, r) if r.ok else "not ok"
	check("%s: ok with and without keeping nodes, both compile to the edited code, kept nodes in place, path %s (%s; %d kept, %d new)" % [label, want_path,
		row.get("path", "?"), int(row.get("kept_nodes", 0)), int(row.get("new_nodes", 0))],
		same and placed == "" and String(row.get("path", "")) == want_path and bp == before and String(rf.report.gentle.get(fname, {}).get("path", "full")) == "full",
		"%s | %s | same %s | placed: %s | why: %s" % [reasons(r), reasons(rf), same, placed, row.get("why", "")])
	r["full"] = rf
	return r


## The share of a function's nodes a one-line edit kept: [kept, considered].
func kept_share(bp: Dictionary, name: String, r: Dictionary) -> Array:
	var cons := considered(bp, name, r.report.replaced)
	var total := 0
	var kept := 0
	for gid in cons:
		var gone := {}
		for id in r.report.replaced.get(gid, []):
			gone[int(id)] = true
		for id in cons[gid]:
			total += 1
			if not gone.has(int(id)):
				kept += 1
	return [kept, total]


## Test 1: one literal changed in the middle of every function of the demos and samples with 6 or more lines.
func test_one_line(inputs: Array) -> void:
	print("==== 13.1 one line changed in the middle of every function with 6+ lines: the other lines' nodes stay ====")
	var num := RegEx.create_from_string("(?<![\\w.\"'])(\\d+)(?![\\w.\"'])")
	var strre := RegEx.create_from_string("\"([A-Za-z ]+)\"")
	var shares := []
	var below := []
	var all_kept := 0
	var all_total := 0
	var tried := 0
	var skipped := 0
	for inp in inputs:
		var bp: Dictionary = inp.bp
		var c := Compiler.new()
		var code := Model.normalize_code(c.compile(bp.duplicate(true)))
		var blocks := sync.split(code)
		sync.classify(blocks, c)
		var entries := entries_of(bp)
		for blk in blocks:
			if blk.kind != "func" or blk.owner != "user" or not entries.has(String(blk.name)) or not String(entries[blk.name].kind) in ["fn_entry", "event", "custom_event"]:
				continue
			var own := {}
			for ln in blk.compiler_lines:
				own[int(ln)] = true
			var body := []
			for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
				var t := sync._line(blk, ln)
				if t.strip_edges() != "" and not t.strip_edges().begins_with("#") and not own.has(ln):
					body.append(ln)
			if body.size() < 6:
				continue
			# the line with a literal nearest the middle (not a line that holds others, not a lambda's first line)
			var pick := -1
			var best := 1 << 30
			for i in body.size():
				var t := sync._line(blk, int(body[i]))
				if t.strip_edges().ends_with(":") or t.contains("func") or t.contains("'") or t.contains("#") or t.contains("\\"):
					continue
				if num.search(t) == null and strre.search(t) == null:
					continue
				var dist := absi(i - body.size() / 2)
				if dist < best:
					best = dist
					pick = int(body[i])
			if pick == -1:
				skipped += 1
				continue
			var line := sync._line(blk, pick)
			var m := num.search(line)
			var now := ""
			if m != null:
				now = line.substr(0, m.get_start(1)) + str(int(m.get_string(1)) + 1) + line.substr(m.get_end(1))
			else:
				var ms := strre.search(line)
				now = line.substr(0, ms.get_end(1)) + "Z" + line.substr(ms.get_end(1))
			var lines := code.split("\n")
			lines[pick - 1] = now
			var file := "\n".join(lines)
			tried += 1
			var label := "one line in %s %s (line %d: %s -> %s)" % [inp.label, blk.name, pick, line.strip_edges(), now.strip_edges()]
			var r := sync.reimport(bp, Model.build_source(file, bp), {"path": inp.path})
			if not r.ok:
				check(label + ": ok", expected_refusal(r), reasons(r))
				continue
			var row: Dictionary = r.report.gentle.get(String(blk.name), {})
			var c2 := Compiler.new()
			var code2 := Model.normalize_code(c2.compile(r.bp.duplicate(true)))
			var problems := []
			if not same_code(code2, file):
				problems.append("does not compile to the edited code")
			var placed := kept_in_place(bp, r)
			if placed != "":
				problems.append(placed)
			# every other line: its writer, unless replaced, writes the same line now, from the same place
			var gone := {}
			for k in r.report.replaced:
				for id in r.report.replaced[k]:
					gone["%d:%d" % [int(k), int(id)]] = true
			for ln in body:
				if int(ln) == pick:
					continue
				var was: Array = c.line_map.get(absi(c.text_lines[int(ln) - 1]), [])
				if was.is_empty() or gone.has("%d:%d" % [int(was[0]), int(was[1])]):
					continue
				var is_now: Array = c2.line_map.get(absi(c2.text_lines[int(ln) - 1]), []) if int(ln) <= c2.text_lines.size() else []
				if is_now != was:
					problems.append("line %d was written by %s, now by %s" % [int(ln), str(was), str(is_now)])
					break
			# only the edited line's nodes went
			var wr: Array = c.line_map.get(absi(c.text_lines[pick - 1]), [])
			if String(row.get("path", "")) == "gentle" and not wr.is_empty():
				var g := Model.find_graph(bp, int(wr[0]))
				var mine := line_nodes(bp, g, int(wr[1]), c.node_lines)
				var extra := []
				for k in r.report.replaced:
					for id in r.report.replaced[k]:
						var n := Model.find_node(Model.find_graph(bp, int(k)), int(id))
						if int(k) == int(wr[0]) and (mine.has(int(id)) or String(n.get("kind", "")) == "reroute"):
							continue
						extra.append("g%d n%d %s" % [int(k), int(id), n.get("kind", "?")])
				if not extra.is_empty():
					below.append("%s %s: also replaced %s" % [inp.label, blk.name, str(extra.slice(0, 5))])
			var share := kept_share(bp, String(blk.name), r)
			all_kept += int(share[0])
			all_total += int(share[1])
			var pct := 100.0 * int(share[0]) / maxf(1.0, float(share[1]))
			shares.append(pct)
			if pct < 90.0:
				below.append("%s %s: %.0f%% kept (%d of %d), path %s%s" % [inp.label, blk.name, pct, int(share[0]), int(share[1]), row.get("path", "?"),
					(": " + String(row.why)) if String(row.get("why", "")) != "" else ""])
			check("%s: ok, compiles to it, other lines' nodes kept in place (%s, %.0f%% of %d nodes kept)" % [label, row.get("path", "?"), pct, int(share[1])], problems.is_empty(), "; ".join(problems))
	shares.sort()
	var median: float = shares[shares.size() / 2] if not shares.is_empty() else 0.0
	var overall := 100.0 * all_kept / maxf(1.0, float(all_total))
	print("KEPT SHARE over %d one-line edits (%d functions with no literal to change skipped): overall %.1f%% (%d of %d nodes), min %.0f%%, median %.0f%%" % [
		tried, skipped, overall, all_kept, all_total, shares[0] if not shares.is_empty() else 0.0, median])
	for b in below:
		print("      below 90%% or more than the line replaced: %s" % b)
	info["13.1 kept share"] = "%.1f%% of %d nodes over %d edits, min %.0f%%, median %.0f%%" % [overall, all_total, tried, shares[0] if not shares.is_empty() else 0.0, median]
	check("one line: at least 90%% of the node ids are kept over the whole set (%.1f%%)" % overall, overall >= 90.0 and tried >= 40)


## Test 2 and 8: inserts, deletes, a block, a wrap, a swap.
func test_gentle_edits() -> void:
	print("==== 13.2 lines inserted, deleted, wrapped and swapped ====")
	var b := base(LONG_SRC)
	var bp: Dictionary = b.bp
	var code: String = b.code
	var r := gentle_case("insert one line", bp, apply_edits("insert", code, [["\thp += c\n", "\thp += c\n\tprint(\"inserted\")\n"]]), "step")
	if r.get("ok", false):
		var others := 0
		var sg := Model.graph_named(bp, "step")
		for k in r.report.replaced:
			for id in r.report.replaced[k]:
				if String(Model.find_node(sg, int(id)).get("kind", "")) != "reroute":
					others += 1
		check("insert one line: one new writer and nothing replaced but reroutes", int(r.report.gentle.step.new_nodes) <= 2 and others == 0,
			str(r.report.replaced) + " " + str(r.report.gentle))
	r = gentle_case("delete one line", bp, apply_edits("delete", code, [["\tlog.append(\"second\")\n", ""]]), "step")
	if r.get("ok", false):
		check("delete one line: only its nodes go (%s)" % str(r.report.replaced), r.report.replaced.values().all(func(ids): return ids.size() <= 3) and int(r.report.gentle.step.new_nodes) == 0)
	r = gentle_case("insert a block", bp, apply_edits("block", code, [["\tprint(hp)\n\tmp = mp + 2\n", "\tprint(hp)\n\tif hp > 3:\n\t\tprint(\"high\")\n\t\tmp += 1\n\tmp = mp + 2\n"]]), "step")
	if r.get("ok", false):
		check("insert a block: the branch and its two statements new, nothing else replaced but reroutes", int(r.report.gentle.step.new_nodes) >= 3, str(r.report.gentle))
	r = gentle_case("wrap two lines in an if", bp, apply_edits("wrap", code, [["\thp += c\n\tlog.append(\"second\")\n", "\tif c > 0:\n\t\thp += c\n\t\tlog.append(\"second\")\n"]]), "step")
	if r.get("ok", false):
		var g := Model.graph_named(bp, "step")
		var gone: Array = r.report.replaced.get(int(g.id), [])
		var wrapped := []
		for n in g.nodes:
			if gone.has(int(n.id)) and ((String(n.kind) == "var_set" and String(n.p.get("name", "")) == "hp") or String(n.kind) == "bcall"):
				wrapped.append(int(n.id))
		check("wrap two lines in an if: those two lines' nodes are new, the rest kept (%d replaced)" % gone.size(), wrapped.size() >= 2 and gone.size() <= 8, str(gone))
	gentle_case("swap two adjacent statements", bp, apply_edits("swap", code, [["\tlog.append(\"first\")\n\tprint(a, b)\n", "\tprint(a, b)\n\tlog.append(\"first\")\n"]]), "step")
	gentle_case("change a local on its declaration", bp, apply_edits("local", code, [["\tvar c := b - 3\n", "\tvar c := b - 4\n"]]), "step")
	r = gentle_case("a new local declared on an added line", bp, apply_edits("new local", code, [["\tmp = mp + 2\n", "\tvar e := mp * 2\n\tmp = e + 2\n"]]), "step")
	if r.get("ok", false):
		var g := Model.graph_named(r.bp, "step")
		check("a new local: the graph's locals are the conversion's", g.locals.any(func(l): return String(l.name) == "e"), str(g.locals))


## One literal of a line of function block `blk` changed (a number +3, else a word added to a string); "" when the
## line has none.
func edit_literal(code: String, blk: Dictionary, at: int) -> String:
	var num := RegEx.create_from_string("(?<![\\w.\"'])(\\d+)(?![\\w.\"'])")
	var strre := RegEx.create_from_string("\"([A-Za-z .!]+)\"")
	var lines := String(blk.text).split("\n")
	var line := lines[at]
	if line.strip_edges().ends_with(":") or line.contains("#") or line.contains("func") or line.contains("__"):
		return ""
	var m := num.search(line)
	if m != null:
		lines[at] = line.substr(0, m.get_start(1)) + str(int(m.get_string(1)) + 3) + line.substr(m.get_end(1))
	else:
		var ms := strre.search(line)
		if ms == null:
			return ""
		lines[at] = line.substr(0, ms.get_end(1)) + " now" + line.substr(ms.get_end(1))
	return code.replace(String(blk.text), "\n".join(lines))


## Moves ten nodes of graph `gid` that a trial re-import of `file` kept, puts a comment bubble on two, re-imports the
## edit again and checks that the ten keep their places, the bubbles survive and none of them is listed as replaced.
## False when the graph has not ten such nodes.
func arranged_case(label: String, bp: Dictionary, file: String, fname: String, gid: int, path: String) -> bool:
	var trial := sync.reimport(bp, file, {"path": path})
	if not trial.ok or String(trial.report.gentle.get(fname, {}).get("path", "")) != "gentle":
		return false
	var g := Model.find_graph(bp, gid)
	var gone: Array = trial.report.replaced.get(gid, [])
	var movable: Array = g.nodes.filter(func(n): return not gone.has(int(n.id)) and not String(n.kind) in ["comment", "fn_entry", "event", "reroute"])
	if String(g.kind) == "event":
		var en: Dictionary = entries_of(bp)[fname]
		var chain := sync._extent(bp, g, int(en.nid))
		movable = movable.filter(func(n): return chain.has(int(n.id)))
	if movable.size() < 10:
		return false
	var arranged := bp.duplicate(true)
	var ag := Model.find_graph(arranged, gid)
	var moved := {}
	for i in 10:
		var n := Model.find_node(ag, int(movable[i].id))
		n.x = 7000.0 + 37.0 * i
		n.y = -4000.0 - 53.0 * i
		moved[int(n.id)] = Vector2(n.x, n.y)
		if i < 2:
			n["c"] = "bubble %d" % i
	var r := gentle_case(label, arranged, file, fname)
	if r.get("ok", false):
		var rg := Model.find_graph(r.bp, gid)
		var good := true
		for id in moved:
			var n := Model.find_node(rg, int(id))
			if n.is_empty() or Vector2(float(n.x), float(n.y)) != moved[id]:
				good = false
		var bubbles: Array = rg.nodes.filter(func(n): return String(n.get("c", "")).begins_with("bubble "))
		check("%s: the ten moved nodes keep their places and the two bubbles survive" % label, good and bubbles.size() == 2, str(bubbles))
		# breakpoints: replaced holds only the changed line's nodes; a node of a line that did not change is not in it
		var rep_ids: Array = r.report.replaced.get(gid, [])
		check("%s: replaced lists none of the ten (a breakpoint or watch on them stays), only the edited line's (%d)" % [label, rep_ids.size()],
			moved.keys().all(func(id): return not rep_ids.has(int(id))) and rep_ids.size() <= 6, str(r.report.replaced))
	return true


## Test 3 (and 4): a graph a person arranged keeps its arrangement and comment bubbles.
func test_gentle_hand(inputs: Array) -> void:
	print("==== 13.3 a hand-arranged function; hand-made nodes kept as they are ====")
	var done := false
	var hand_kept := 0
	var hand_tried := []
	for inp in inputs:
		if not inp.demo:
			continue
		var bp: Dictionary = inp.bp
		var code := compiled(bp)
		var entries := entries_of(bp)
		for blk in sync.split(code):
			if blk.kind != "func" or not entries.has(String(blk.name)) or not String(entries[blk.name].kind) in ["fn_entry", "event", "custom_event"]:
				continue
			var lines := String(blk.text).split("\n")
			for at in range(1, lines.size()):
				var file := edit_literal(code, blk, at)
				if file == "":
					continue
				var r := sync.reimport(bp, file, {"path": inp.path})
				var row: Dictionary = r.report.gentle.get(String(blk.name), {})
				if r.ok and same_code(compiled(r.bp), file):
					hand_kept += int(row.get("hand_kept", 0))
					if int(row.get("hand_kept", 0)) > 0:
						hand_tried.append("%s %s line %d: %d hand-made kept, %s" % [inp.label, blk.name, at, int(row.hand_kept), kept_in_place(bp, r)])
				if not done and arranged_case("hand-arranged %s %s" % [inp.label, blk.name], bp, file, String(blk.name), int(entries[blk.name].gid), inp.path):
					done = true
	for h in hand_tried:
		print("      ", h)
	check("hand-made demo nodes: a line edited next to hand-made nodes keeps some of them as they are, in place (%d kept over %d edits)" % [hand_kept, hand_tried.size()],
		hand_kept > 0 and hand_tried.all(func(h): return String(h).ends_with(", ")))
	if not done:
		# (no demo function has ten nodes a one-line edit keeps: the demos are small and made of nodes the converter
		# does not make; a converted function arranged by hand stands in)
		print("      no demo function has ten nodes to move that a one-line edit keeps; a converted function arranged by hand instead")
		var b := base(LONG_SRC)
		var g := Model.graph_named(b.bp, "step")
		done = arranged_case("hand-arranged converted step", b.bp, apply_edits("arranged", b.code, [["\tlog.append(\"second\")\n", "\tlog.append(\"2nd\")\n"]]), "step", int(g.id), "")
	check("hand-arranged: a function with ten nodes to move was found", done)


## Test 5: an event among several.
func test_gentle_events() -> void:
	print("==== 13.5 events ====")
	var b := base(LONG_SRC)
	var r := edited("one line in _ready (gentle)", b.bp, apply_edits("event", b.code, [["\tprint(\"three\")\n", "\tprint(\"three!\")\n"]]), {"actions": {"_ready": "rebuilt"}})
	if r.get("ok", false):
		var eg: Dictionary = b.bp.graphs[0]
		var gone: Array = r.report.replaced.get(int(eg.id), [])
		var en: Dictionary = entries_of(b.bp)["_ready"]
		var chain := sync._extent(b.bp, eg, int(en.nid))
		var stay := chain.keys().filter(func(id): return not gone.has(int(id)))
		check("one line in _ready: %d of %d nodes of its chain keep their ids, %d replaced, path gentle" % [stay.size(), chain.size(), gone.size()],
			gone.size() <= 3 and String(r.report.gentle._ready.path) == "gentle" and kept_in_place(b.bp, r) == "", str(r.report.gentle) + " " + str(gone))
	gentle_case("an event: a line inserted in _process", b.bp, apply_edits("event insert", b.code, [["\thp += 1\n\tprint(\"p\")\n", "\thp += 1\n\tmp -= 1\n\tprint(\"p\")\n"]]), "_process")


## Test 6: inside a lambda.
func test_gentle_lambda() -> void:
	print("==== 13.6 a line inside a lambda ====")
	var b := base(LONG_SRC)
	var bp: Dictionary = b.bp
	var r := gentle_case("a line inside a multi-line lambda", bp, apply_edits("lambda", b.code, [["\t\tprint(w)\n", "\t\tprint(w, 1)\n"]]), "lam")
	if r.get("ok", false):
		var owner := Model.graph_named(bp, "lam")
		var lg: Dictionary = {}
		for g in bp.graphs:
			if g.has("lambda") and String(g.name).begins_with("_lam_lambda"):
				lg = g
		var lg2 := Model.find_graph(r.bp, int(lg.get("id", -1)))
		var gone: Array = r.report.replaced.get(int(lg.get("id", -1)), [])
		check("lambda: the owner's nodes all kept, the lambda graph keeps its id and all but the edited line's nodes (%d replaced of %d)" % [gone.size(), lg.get("nodes", []).size()],
			not lg.is_empty() and not lg2.is_empty() and r.report.replaced.get(int(owner.id), []).is_empty() and gone.size() >= 1 and gone.size() <= 3, str(r.report.replaced))
	r = gentle_case("an inline lambda's body", base(SRC).bp, apply_edits("inline lambda", base(SRC).code, [["\t\treturn v + 1", "\t\treturn v + 5"]]), "apply")


## Test 7: when the whole function is rebuilt instead.
func test_gentle_fallbacks() -> void:
	print("==== 13.7 fallbacks to the whole rebuild ====")
	var b := base(LONG_SRC)
	var bp: Dictionary = b.bp
	var code: String = b.code
	# identical lines: one more of a text that occurs twice; all of that text counts as changed, the rest is kept
	var r := gentle_case("identical lines, a third added", bp, apply_edits("twins", code, [["\tprint(\"y\")\n", "\tprint(\"x\")\n\tprint(\"y\")\n"]]), "twins")
	if r.get("ok", false):
		var g := Model.graph_named(bp, "twins")
		var xs: Array = g.nodes.filter(func(n): return String(n.kind) == "util" and n.d.values().has("\"x\""))
		var gone: Array = r.report.replaced.get(int(g.id), [])
		check("identical lines: both old print(\"x\") nodes were replaced, other lines kept", not xs.is_empty() and xs.all(func(n): return gone.has(int(n.id)))
			and Model.graph_named(r.bp, "twins").nodes.any(func(n): return String(n.kind) == "var_set"), "%s %s" % [str(xs.map(func(n): return n.id)), str(gone)])
	# more than half the lines changed
	r = gentle_case("more than half changed", bp, apply_edits("half", code, [["\tprint(\"phys\", delta)\n", "\tprint(\"phys!\", delta)\n"], ["\tmp += 1\n\tprint(\"phys", "\tmp += 2\n\tprint(\"phys"]]), "_physics_process", "full")
	if r.get("ok", false):
		check("more than half changed: the reason says so", String(r.report.gentle._physics_process.why).contains("more than half"), str(r.report.gentle))
	# a loop's header changed, its body not
	r = gentle_case("for header changed", bp, apply_edits("for", code, [["\tfor it in items:\n", "\tfor it in items.slice(1):\n"]]), "each", "full")
	if r.get("ok", false):
		check("for header changed: the reason names the line", String(r.report.gentle.each.why).contains("for it in"), str(r.report.gentle))
	# a hand-made graph where one execution node writes no line and leads into two (a Sequence)
	var seq_src := "extends Node\n\nvar n := 0\n\nfunc three() -> void:\n\tprint(\"a\")\n\tprint(\"b\")\n\tn += 1\n\tprint(\"c\")\n"
	var hb := base(seq_src)
	var hand: Dictionary = hb.bp.duplicate(true)
	var g := Model.graph_named(hand, "three")
	var entry: Dictionary = g.nodes.filter(func(x): return String(x.kind) == "fn_entry")[0]
	var first_w: Array = g.wires.filter(func(w): return int(w[0]) == int(entry.id) and String(w[1]) == "then")[0]
	var second_w: Array = g.wires.filter(func(w): return int(w[0]) == int(first_w[2]) and String(w[1]) == "then")[0]
	var seq := Model.add_node(g, "sequence", Vector2(250, 300), {"n": 2})
	g.wires.erase(first_w)
	g.wires.erase(second_w)
	g.wires.append([int(entry.id), "then", int(seq.id), "exec"])
	g.wires.append([int(seq.id), "then_0", int(first_w[2]), "exec"])
	g.wires.append([int(seq.id), "then_1", int(second_w[2]), "exec"])
	var hcode := compiled(hand)
	check("hand-made Sequence: compiles to the same lines as before", same_code(hcode, hb.code), first_diff(hb.code, hcode))
	r = gentle_case("several candidate writers (a Sequence that writes no line)", hand, apply_edits("seq", hcode, [["\tprint(\"c\")", "\tprint(\"d\")"]]), "three", "full")
	if r.get("ok", false):
		check("several candidate writers: the reason says so", String(r.report.gentle.three.why).contains("several candidate writers"), str(r.report.gentle))
	# a macro: its lines get new nodes, the rest is kept
	var mbp: Dictionary = Importer.new().convert(MACRO_SRC, {}).bp
	Reuse.new().run([{"path": SCRATCH + "macro_gentle.gd", "bp": mbp}], "")
	var mcode := compiled(mbp)
	r = gentle_case("a function that uses a macro, another line edited", mbp, apply_edits("macro", mcode, [["\tlog.append((\"burn %d\" % amount))", "\tlog.append((\"burnt %d\" % amount))"]]), "burn")
	var bg := Model.graph_named(mbp, "burn")
	var macros: Array = bg.nodes.filter(func(x): return String(x.kind) == "macro")
	if r.get("ok", false):
		var gone: Array = r.report.replaced.get(int(bg.id), [])
		check("macro, a line inside it edited: the macro node went (its lines are new nodes, macros_expanded counts it)", not macros.is_empty() and macros.all(func(x): return gone.has(int(x.id)))
			and int(r.report.macros_expanded) > 0, "%s %s" % [str(gone), str(r.report.gentle)])
	# every line of the macro kept, in a row: the macro node stays (kept as it is), a line added after it is new
	r = gentle_case("a function that uses a macro, a line added after it", mbp, mcode.replace("\tlog.append((\"burn %d\" % amount))\n", "\tlog.append((\"burn %d\" % amount))\n\tprint(\"after\")\n"), "burn")
	if r.get("ok", false):
		var gone: Array = r.report.replaced.get(int(bg.id), [])
		check("macro, every line of it kept: the macro node stays with its id (%s)" % str(r.report.gentle.burn), not macros.is_empty()
			and macros.all(func(x): return not gone.has(int(x.id)) and not Model.find_node(Model.graph_named(r.bp, "burn"), int(x.id)).is_empty()) and int(r.report.macros_expanded) == 0,
			str(gone))
	# the guard: when the result with kept nodes does not compile to the file, the whole rebuild is used. The test
	# option spoil_gentle breaks the kept-nodes result on purpose (its wires are dropped) to show that path.
	var nb := base(SRC)
	var gfile := apply_edits("guard", nb.code, [["\tvar sum := 0\n", "\tvar sum := 9\n"]])
	r = gentle_case("the guard path stays quiet when the gentle result is good", nb.bp, gfile, "total")
	check("the guard: no note about falling back when the gentle result compiles", r.get("ok", false) and not r.report.notes.any(func(x): return String(x).contains("rebuilt whole")), str(r.get("report", {}).get("notes", [])))
	r = sync.reimport(nb.bp, gfile, {"spoil_gentle": true})
	check("the guard: a kept-nodes result that does not compile gives way to the whole rebuild (ok, the file's code, reported)", r.ok and same_code(compiled(r.bp), gfile)
		and String(r.report.gentle.get("total", {}).get("path", "")) == "full" and String(r.report.gentle.total.why).contains("did not give the file back")
		and r.report.notes.any(func(x): return String(x).contains("rebuilt whole")), reasons(r) + " " + str(r.report.get("gentle", {})))


## Test 9: stability, and the way back.
func test_gentle_stability() -> void:
	print("==== 13.9 stability ====")
	var b := base(LONG_SRC)
	var bp: Dictionary = b.bp
	var file := apply_edits("stable", b.code, [["\tlog.append(\"second\")\n", "\tlog.append(\"second!\")\n"], ["\tprint(\"three\")\n", "\tprint(\"3\")\n"]])
	var r1 := sync.reimport(bp, file)
	var r2 := sync.reimport(r1.bp, file)
	check("gentle twice: the second deep-equals the first and keeps everything", r1.ok and r2.ok and r2.bp == r1.bp and r2.report.functions.all(func(x): return x.action == "kept"), reasons(r1) + reasons(r2))
	var back := sync.reimport(r1.bp, Model.build_source(b.code, r1.bp))
	var ok: bool = back.ok and same_code(compiled(back.bp), b.code)
	var stayed := 0
	var total := 0
	if ok:
		for g in bp.graphs:
			var gone1: Array = r1.report.replaced.get(int(g.id), [])
			var gone2: Array = back.report.replaced.get(int(g.id), [])
			var h := Model.find_graph(back.bp, int(g.id))
			for n in g.nodes:
				total += 1
				if gone1.has(int(n.id)) or gone2.has(int(n.id)):
					continue
				var m := Model.find_node(h, int(n.id))
				if not m.is_empty() and float(m.x) == float(n.x) and float(m.y) == float(n.y):
					stayed += 1
				else:
					ok = false
	check("the original file again: compiles to the original code, the nodes never replaced still in place (%d of %d)" % [stayed, total], ok and stayed >= total * 0.9, reasons(back))
	# a hand-arranged demo: the same twice
	var demo := Model.load_file("res://demo/SC_Demo.gd")
	var dfile := apply_edits("stable demo", compiled(demo), [["sin((t * 3.0))", "sin((t * 4.0))"]])
	var d1 := sync.reimport(demo, dfile)
	var d2 := sync.reimport(d1.bp, dfile)
	check("gentle twice (SC_Demo): the same", d1.ok and d2.ok and d2.bp == d1.bp, reasons(d1) + reasons(d2))


## Test 10: speed.
func test_gentle_speed(inputs: Array) -> void:
	print("==== 13.10 speed ====")
	var biggest := {}
	var size := 0
	for inp in inputs:
		if inp.demo:
			continue
		var n := FileAccess.get_file_as_string(inp.path).length()
		if n > size:
			size = n
			biggest = inp
	var bp: Dictionary = biggest.bp
	var code := compiled(bp)
	var target := {}
	for blk in sync.split(code):
		if blk.kind == "func" and String(blk.text).contains(" 1") and String(blk.text).split("\n").size() >= 6:
			target = blk
	if target.is_empty():
		check("gentle speed: a function to edit", false)
		return
	var file := code.replace(String(target.text), String(target.text).replace(" 1", " 2"))
	var times := {}
	for mode in [true, false]:
		var best := 1e9
		for i in 3:
			var t0 := Time.get_ticks_usec()
			var r := sync.reimport(bp, file, {"path": biggest.path, "gentle": mode})
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
			if not r.ok:
				best = -1.0
				break
		times[mode] = best
	print("TIMING one-line edit of %s in %s: keeping nodes %.1f ms, whole rebuild %.1f ms" % [target.name, biggest.label, float(times[true]), float(times[false])])
	info["13.10 gentle ms"] = snappedf(float(times[true]), 0.1)
	info["13.10 full ms"] = snappedf(float(times[false]), 0.1)
	check("gentle speed: both ok, keeping nodes under twice the whole rebuild (%.1f ms vs %.1f ms)" % [float(times[true]), float(times[false])],
		float(times[true]) > 0.0 and float(times[false]) > 0.0 and float(times[true]) < 2.0 * float(times[false]))


func first_diff(a: String, b: String) -> String:
	var x := a.split("\n")
	var y := b.split("\n")
	for i in maxi(x.size(), y.size()):
		var p := x[i] if i < x.size() else "(end)"
		var q := y[i] if i < y.size() else "(end)"
		if p != q:
			return "      line %d before: %s\n      line %d after:  %s" % [i + 1, p, i + 1, q]
	return "(same)"
