extends SceneTree
## Headless test of core/sc_sync.gd: a Schematic's code split into blocks, whose each block is, and what changed.
## Run: godot --headless --path . --script res://tests/test_sync.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Parser := preload("res://addons/schematic/core/sc_gd_parser.gd")
const Sync := preload("res://addons/schematic/core/sc_sync.gd")

const DEMO_DIRS := ["res://demo/", "res://demo/game/", "res://demo/arcade/", "res://demo/arcade/art/", "res://demo/machine/", "res://demo/data/"]
const SAMPLES := "res://tests/convert/"
const SCRATCH := "res://tests/tmp/sync/"
const ENTRY_KINDS := ["event", "custom_event", "signal_event", "input_action", "key_event", "fn_entry"]

var fails := 0
var sync := Sync.new()
var info := {}   # informational counters


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
	test_coverage()
	test_hard_text()
	test_diff()
	test_speed()
	print("informational: %s" % str(info))
	print("SYNC FAILS: ", fails)
	quit(1 if fails else 0)


# ================================================================ helpers

## {code, c} for a schematic compiled with trace on or off.
func compiled(bp: Dictionary, trace: bool) -> Dictionary:
	bp["trace"] = trace
	var c := Compiler.new()
	var code := c.compile(bp)
	return {"code": code, "c": c}


func block_names(blocks: Array, kind := "func") -> Array:
	return blocks.filter(func(b): return b.kind == kind).map(func(b): return String(b.name))


func find(blocks: Array, kind: String, name: String) -> Dictionary:
	for b in blocks:
		if b.kind == kind and String(b.name) == name:
			return b
	return {}


## Every line exactly once, in order, and the texts joined give the input back.
func check_cover(label: String, code: String, blocks: Array) -> void:
	var n := code.split("\n").size()
	var next := 1
	var gaps := []
	for b in blocks:
		if int(b.from) != next or int(b.to) < int(b.from):
			gaps.append("%s %d-%d (expected from %d)" % [b.kind, b.from, b.to, next])
		next = int(b.to) + 1
	var joined := "\n".join(blocks.map(func(b): return String(b.text)))
	check("cover %s: %d lines in %d blocks, each line once, joined texts give the input back" % [label, n, blocks.size()],
		gaps.is_empty() and next == n + 1 and joined == code, "%s next=%d n=%d same=%s" % [str(gaps.slice(0, 4)), next, n, str(joined == code)])


## Each func block is one function as sc_gd_parser sees it: same names and header lines, and the block ends where
## the parser's function ends (only blank and comment lines between the block's end and the next declaration).
func check_parser(label: String, code: String, blocks: Array) -> void:
	var p := Parser.new()
	var ast: Dictionary = p.parse(code)
	var mine := blocks.filter(func(b): return b.kind == "func")
	var theirs: Array = ast.funcs
	var a := mine.map(func(b): return "%s@%d" % [b.name, b.head])
	var b2 := theirs.map(func(f): return "%s@%d" % [f.name, f.line])
	var bad := []
	var lines := code.replace("\r\n", "\n").split("\n")
	var logical: Array = p._lines
	if a == b2:
		for i in mine.size():
			var f: Dictionary = theirs[i]
			var at := -1
			for k in logical.size():
				if int(logical[k].line) == int(f.line):
					at = k
					break
			if at == -1:
				bad.append("%s: no logical line" % f.name)
				continue
			var bound := lines.size()
			for k in range(at + 1, logical.size()):
				if int(logical[k].indent) <= int(logical[at].indent):
					bound = int(logical[k].line) - 1
					break
			var blk: Dictionary = mine[i]
			if int(blk.to) > bound:
				bad.append("%s ends at %d, parser at %d" % [f.name, blk.to, bound])
				continue
			for ln in range(int(blk.to) + 1, bound + 1):
				var t := lines[ln - 1].strip_edges()
				if t != "" and not t.begins_with("#"):
					bad.append("%s: line %d after the block is code (%s)" % [f.name, ln, t])
					break
	check("parser %s: %d functions, same names, header lines and ends as sc_gd_parser" % [label, theirs.size()], a == b2 and bad.is_empty(),
		"mine %s\nparser %s\n%s" % [str(a), str(b2), str(bad.slice(0, 5))])


## How many functions the compiler wrote for an entry the user made (event, custom event, signal or input event,
## a function, a timeline's update / finished / event track), read from its records and the graph.
func entry_count(c: Compiler) -> int:
	var n := 0
	for b in c.block_lines:
		var head := int(b[0])
		if not c.line_map.has(head) or String(c.line_kinds.get(head, "")) == "helper":
			continue
		var at: Array = c.line_map[head]
		var g := Model.find_graph(c.bp, int(at[0]))
		var node := Model.find_node(g, int(at[1])) if not g.is_empty() else {}
		if node.is_empty():
			continue
		if String(node.kind) in ENTRY_KINDS:
			n += 1
		elif String(node.kind) == "timeline" and not (String(b[2]).ends_with("_sample") or String(b[2]).ends_with("_run")):
			n += 1
	return n


## Everything checked for one compiled script.
func check_compiled(label: String, bp: Dictionary, code: String, c: Compiler) -> void:
	var blocks := sync.split(code)
	check_cover(label, code, blocks)
	check_parser(label, code, blocks)
	sync.classify(blocks, c)
	var user_funcs := blocks.filter(func(b): return b.kind == "func" and b.owner == "user").size()
	var entries := entry_count(c)
	check("count %s: %d user-owned functions = %d entries the compiler wrote a function for" % [label, user_funcs, entries], user_funcs == entries,
		str(blocks.filter(func(b): return b.kind == "func").map(func(b): return "%s:%s" % [b.name, b.owner])))
	# the compiler's records account for every line of a user function: a node's line, or a compiler line
	var unaccounted := []
	var prelude_missed := []
	var nlines := code.split("\n").size()
	check("records %s: text_lines has one entry per line of the text (%d), each a line of the records" % [label, nlines],
		c.text_lines.size() == nlines and Array(c.text_lines).all(func(r): return r != 0))
	for b in blocks:
		if b.kind == "func" and b.owner == "user":
			for ln in range(int(b.head_to) + 1, int(b.to) + 1):
				if Sync._line(b, ln).strip_edges() != "" and not c.line_map.has(absi(c.text_lines[ln - 1])) and not b.compiler_lines.has(ln):
					unaccounted.append("%s:%d" % [b.name, ln])
	var marked := []
	for i in c.text_lines.size():
		if c.text_lines[i] < 0:
			marked.append(i + 1)
	for ln in marked:
		var ok := false
		for b in blocks:
			if int(ln) >= int(b.from) and int(ln) <= int(b.to) and (b.owner == "compiler" or b.compiler_lines.has(int(ln))):
				ok = true
		if not ok:
			prelude_missed.append(ln)
	check("records %s: every line of a user function is a node's or a compiler line; every prelude line is the compiler's" % label,
		unaccounted.is_empty() and prelude_missed.is_empty(), "%s %s" % [str(unaccounted.slice(0, 6)), str(prelude_missed)])
	# the text rules, with the stored graph (the file as saved)
	var file := Model.build_source(code, bp)
	var fblocks := sync.split(file)
	check_cover(label + " (file)", file, fblocks)
	sync.classify_text(fblocks)
	var by_from := {}
	for fb in fblocks:
		by_from[int(fb.from)] = fb
	var differ := []
	for b in blocks:
		if b.kind == "blank":
			continue
		var fb: Dictionary = by_from.get(int(b.from), {})
		if fb.is_empty() or fb.kind != b.kind or String(fb.name) != String(b.name) or int(fb.to) != int(b.to):
			differ.append("%s %s@%d: no such block in the file" % [b.kind, b.name, b.from])
		elif fb.owner != b.owner or Array(fb.compiler_lines) != Array(b.compiler_lines):
			differ.append("%s %s@%d: %s %s vs text %s %s" % [b.kind, b.name, b.from, b.owner, str(b.compiler_lines), fb.owner, str(fb.compiler_lines)])
	var graph_blocks := fblocks.filter(func(x): return x.kind == "graph")
	check("agree %s: classify and classify_text (with the stored graph) give every block the same owner and compiler_lines" % label,
		differ.is_empty() and graph_blocks.size() == 1, str(differ.slice(0, 6)))
	# the text rules without the stored graph: every compiler-written block and line is still recognised
	var bare := sync.split(code)
	sync.classify_text(bare, {})
	var missed := []
	var confused := 0
	for i in blocks.size():
		var b: Dictionary = blocks[i]
		var t: Dictionary = bare[i]
		if (b.owner == "compiler") != (t.owner == "compiler"):
			missed.append("%s %s@%d: %s vs text %s" % [b.kind, b.name, b.from, b.owner, t.owner])
		elif b.owner != t.owner:
			confused += 1
		elif Array(b.compiler_lines) != Array(t.compiler_lines):
			missed.append("%s %s@%d lines %s vs text %s" % [b.kind, b.name, b.from, str(b.compiler_lines), str(t.compiler_lines)])
	info["user/carried told apart only with the stored graph"] = int(info.get("user/carried told apart only with the stored graph", 0)) + confused
	check("text %s: without the stored graph, every block and line the compiler wrote for itself is recognised (and nothing else)" % label,
		missed.is_empty(), str(missed.slice(0, 6)))


# ================================================================ coverage

func test_coverage() -> void:
	print("==== coverage: demos and converted samples, trace off and on ====")
	var n := 0
	for dir in DEMO_DIRS:
		var files := Array(DirAccess.get_files_at(dir))
		files.sort()
		for f in files:
			if f.get_extension() != "gd" or not Model.is_schematic_file(dir + f):
				continue
			var bp := Model.load_file(dir + f)
			if bp.is_empty():
				continue
			for trace in [false, true]:
				var m := compiled(bp, trace)
				check_compiled("%s%s" % [f, " trace" if trace else ""], bp, m.code, m.c)
				n += 1
	var names := Array(DirAccess.get_files_at(SAMPLES)).filter(func(f): return f.get_extension() == "gd")
	names.sort()
	for f in names:
		var src := FileAccess.get_file_as_string(SAMPLES + f)
		# the sample as written: split and the parser agree on a hand-written script too
		var sblocks := sync.split(src)
		check_cover("source " + f, src, sblocks)
		check_parser("source " + f, src, sblocks)
		if f.begins_with("_"):
			continue
		var bp: Dictionary = Importer.new().convert(src, {"path": SAMPLES + f}).bp
		for trace in [false, true]:
			var m := compiled(bp, trace)
			check_compiled("converted %s%s" % [f, " trace" if trace else ""], bp, m.code, m.c)
			n += 1
	for entry in synthetic():
		for trace in [false, true]:
			var m := compiled(entry[1], trace)
			check("synthetic %s compiles without errors" % entry[0], m.c.errors.filter(func(e): return not e.w).is_empty(), str(m.c.errors))
			if entry[0] == "construction+input" and not trace:
				var shapes := ["\tConstructionScript()", "\tif Engine.is_editor_hint():", "is InputEventKey and", "\t\tif not event.pressed:",
					"is_action_pressed(&\"jump\")", "tree_exiting.connect(_on_self_tree_exiting)", "\tset(value):", "\t\t\ton_hp_changed()",
					"\t__p%d_amount_g%d = amount" % [int(entry[1].graphs[0].nodes.filter(func(n): return n.kind == "custom_event")[0].id), int(entry[1].graphs[0].id)]]
				var absent := shapes.filter(func(s): return not String(m.code).contains(s))
				var sb := sync.split(m.code)
				sync.classify(sb, m.c)
				var hp := find(sb, "var", "hp")
				check("synthetic: the code has every shape it is here for, and the notifying variable's setter is compiler lines",
					absent.is_empty() and hp.get("owner", "") == "user" and hp.compiler_lines.size() == 4, "%s %s\n%s" % [str(absent), str(hp), m.code])
			if entry[0] == "prelude-only" and not trace:
				var sb := sync.split(m.code)
				sync.classify(sb, m.c)
				check("synthetic: _ready and _unhandled_input made only for the prelude are the compiler's",
					find(sb, "func", "_ready").get("owner", "") == "compiler" and find(sb, "func", "_unhandled_input").get("owner", "") == "compiler", m.code)
			check_compiled("synthetic %s%s" % [entry[0], " trace" if trace else ""], entry[1], m.code, m.c)
			n += 1
	info["compiled scripts checked"] = n


## Schematics made here for what the demos do not have: a Construction Script (its call and editor guard), key
## and input-action events, a signal event, a variable that notifies, an interface stub.
func synthetic() -> Array:
	var out := []
	# 1. Construction Script, key event, input action, signal event, a notifying variable, engine events
	var bp := Model.new_schematic("Node", "SC_SyncSynth")
	bp.variables.append({"name": "size", "type": "float", "default": "1.0", "export": true, "category": "", "tooltip": ""})
	bp.variables.append({"name": "hp", "type": "int", "default": "3", "export": false, "category": "", "tooltip": "", "notify": true})
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var ready := Model.add_node(g, "event", Vector2(0, 0), {"name": "_ready"})
	var p1 := Model.add_node(g, "print", Vector2(0, 0), {})
	p1.d["text"] = "\"ready\""
	g.wires.append([ready.id, "then", p1.id, "exec"])
	var proc := Model.add_node(g, "event", Vector2(0, 100), {"name": "_process"})
	var p2 := Model.add_node(g, "print", Vector2(0, 0), {})
	p2.d["text"] = "\"tick\""
	g.wires.append([proc.id, "then", p2.id, "exec"])
	# an output of one event read in another: copied to a member when its event runs (`__p<n>_amount_g<g> = amount`)
	bp.variables.append({"name": "last_hit", "type": "int", "default": "0", "export": false, "category": "", "tooltip": ""})
	var hit := Model.add_node(g, "custom_event", Vector2(0, 500), {"name": "hit", "params": [["amount", "int"]]})
	var hp1 := Model.add_node(g, "print", Vector2(0, 0), {})
	hp1.d["text"] = "\"hit\""
	g.wires.append([hit.id, "then", hp1.id, "exec"])
	var keep := Model.add_node(g, "var_set", Vector2(0, 0), {"name": "last_hit"})
	g.wires.append([p2.id, "then", keep.id, "exec"])
	g.wires.append([hit.id, "p_amount", keep.id, "value"])
	var key := Model.add_node(g, "key_event", Vector2(0, 200), {"key": "KEY_SPACE"})
	var p3 := Model.add_node(g, "print", Vector2(0, 0), {})
	p3.d["text"] = "\"space\""
	var p3b := Model.add_node(g, "print", Vector2(0, 0), {})
	p3b.d["text"] = "\"space up\""
	g.wires.append([key.id, "pressed", p3.id, "exec"])
	g.wires.append([key.id, "released", p3b.id, "exec"])
	var act := Model.add_node(g, "input_action", Vector2(0, 300), {"action": "jump"})
	var p4 := Model.add_node(g, "print", Vector2(0, 0), {})
	p4.d["text"] = "\"jump\""
	g.wires.append([act.id, "pressed", p4.id, "exec"])
	var sig := Model.add_node(g, "signal_event", Vector2(0, 400), {"signal": "tree_exiting", "path": ".", "args": []})
	var p5 := Model.add_node(g, "print", Vector2(0, 0), {})
	p5.d["text"] = "\"bye\""
	g.wires.append([sig.id, "then", p5.id, "exec"])
	var cs := Model.new_graph(bp, "ConstructionScript", "function")
	var cp := Model.add_node(cs, "print", Vector2(0, 0), {})
	cp.d["text"] = "\"built\""
	cs.wires.append([cs.nodes[0].id, "then", cp.id, "exec"])
	var on_hp := Model.new_graph(bp, "on_hp_changed", "function")
	var hp_p := Model.add_node(on_hp, "print", Vector2(0, 0), {})
	hp_p.d["text"] = "\"hp\""
	on_hp.wires.append([on_hp.nodes[0].id, "then", hp_p.id, "exec"])
	out.append(["construction+input", bp])
	# 2. a schematic with only an input action and a signal event: _unhandled_input and _ready made for the prelude
	var bp2 := Model.new_schematic("Node", "")
	var g2: Dictionary = bp2.graphs[0]
	g2.nodes.clear()
	var act2 := Model.add_node(g2, "input_action", Vector2(0, 0), {"action": "fire"})
	var q := Model.add_node(g2, "print", Vector2(0, 0), {})
	q.d["text"] = "\"fire\""
	g2.wires.append([act2.id, "released", q.id, "exec"])
	var sig2 := Model.add_node(g2, "signal_event", Vector2(0, 100), {"signal": "renamed", "path": ".", "args": []})
	var q2 := Model.add_node(g2, "print", Vector2(0, 0), {})
	q2.d["text"] = "\"renamed\""
	g2.wires.append([sig2.id, "then", q2.id, "exec"])
	out.append(["prelude-only", bp2])
	return out


# ================================================================ hard text

func hard(name: String, text: String, expect: Array, crlf := false) -> Array:
	if crlf:
		text = text.replace("\n", "\r\n")
	var path := SCRATCH + "hard_%s.gd" % name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	var src := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))   # (read back and gone: an editor scan never sees its class_name)
	var blocks := sync.split(src)
	check_cover("hard " + name, src, blocks)
	check_parser("hard " + name, src, blocks)
	var got := blocks.filter(func(b): return b.kind != "blank").map(func(b): return [String(b.kind), String(b.name), int(b.from), int(b.to)])
	check("hard %s: blocks %s" % [name, str(expect)], got == expect, "got %s" % str(got))
	return blocks


func test_hard_text() -> void:
	print("==== hard text ====")
	var b := hard("multiline_string", "extends Node\n\nfunc a():\n\tvar s = \"\"\"\nfunc x():\n\tpass\n\"\"\"\n\treturn s\n\nfunc b():\n\tpass\n",
		[["class", "", 1, 1], ["func", "a", 3, 8], ["func", "b", 10, 11]])
	check("hard multiline_string: the string's lines are marked as inside a string", Array(find(b, "func", "a").strs) == [5, 6, 7], str(find(b, "func", "a").strs))
	hard("lambda_call", "extends Node\n\nfunc a(items):\n\titems.map(func(x):\n\t\tvar y = x * 2\n\t\treturn y\n\t)\n\tprint(\"done\")\n\nfunc b():\n\tpass\n",
		[["class", "", 1, 1], ["func", "a", 3, 8], ["func", "b", 10, 11]])
	hard("match", "func m(v):\n\tmatch v:\n\t\t1:\n\t\t\tif v > 0:\n\t\t\t\tprint(\"a\")\n\t\t[2, var w]:\n\t\t\tprint(w)\n\t\t_:\n\t\t\tpass\n\tprint(\"end\")\nfunc n():\n\tpass\n",
		[["func", "m", 1, 10], ["func", "n", 11, 12]])
	hard("setget", "var hp: int = 10:\n\tset(value):\n\t\thp = clampi(value, 0, 100)\n\tget:\n\t\treturn hp\n\nfunc f():\n\tpass\n",
		[["var", "hp", 1, 5], ["func", "f", 7, 8]])
	hard("inner_class", "class Inner:\n\tvar x := 1\n\tfunc f():\n\t\treturn x\n\tclass Deeper:\n\t\tfunc g():\n\t\t\tpass\nclass Other extends RefCounted:\n\tfunc h():\n\t\tpass\n\nfunc outer():\n\tpass\n",
		[["inner_class", "Inner", 1, 7], ["inner_class", "Other", 8, 10], ["func", "outer", 12, 13]])
	b = hard("annotations", "extends Node\n\n@export_range(0, 10)\n@export var level := 1\n\n@rpc(\"any_peer\")\n@warning_ignore(\"unused_parameter\")\nfunc ping(x):\n\tpass\n@export_enum(\"A\",\n\t\"B\") var pick: int\n",
		[["class", "", 1, 1], ["var", "level", 3, 4], ["func", "ping", 6, 9], ["var", "pick", 10, 11]])
	check("hard annotations: head is the declaration's line", int(find(b, "var", "level").head) == 4 and int(find(b, "func", "ping").head) == 8)
	hard("trailing_comments", "func a():\n\tpass\n\t# still a's\n# a free note\n\n# about b\nfunc b():\n\tpass\n\n\n# the end\n",
		[["func", "a", 1, 3], ["comment", "", 4, 4], ["func", "b", 6, 8], ["comment", "", 11, 11]])
	hard("comment_in_body", "func a():\n\tvar x = 1\n# commented out\n\n\tx += 1\n\nfunc b():\n\tpass\n",
		[["func", "a", 1, 5], ["func", "b", 7, 8]])
	b = hard("crlf", "extends Node\n\nfunc a():\n\tvar s = \"\"\"\nfunc x():\n\"\"\"\n\treturn s\n\nfunc b():\n\tpass\n",
		[["class", "", 1, 1], ["func", "a", 3, 7], ["func", "b", 9, 10]], true)
	check("hard crlf: block text keeps the \\r", String(find(b, "func", "b").text) == "func b():\r\n\tpass\r")
	hard("two_spaces", "extends Node\nfunc a():\n  if true:\n    print(1)\n  return\nfunc b():\n  pass\n",
		[["class", "", 1, 1], ["func", "a", 2, 5], ["func", "b", 6, 7]])
	b = hard("no_newline", "func a():\n\tpass", [["func", "a", 1, 2]])
	hard("regions", "#region Movement\nfunc a():\n\tpass\n#endregion\n\nfunc b():\n\tpass\n",
		[["region", "Movement", 1, 1], ["func", "a", 2, 3], ["region", "", 4, 4], ["func", "b", 6, 7]])
	b = hard("backslash_header", "func long_name(a, b) \\\n\t\t-> int:\n\treturn a + b\n\nfunc c():\n\tpass\n",
		[["func", "long_name", 1, 3], ["func", "c", 5, 6]])
	check("hard backslash_header: the header runs over two lines", int(find(b, "func", "long_name").head_to) == 2)
	hard("static_and_lambda_default", "static func s() -> int:\n\treturn 1\n\nfunc with_cb(cb = func(x): return x * 2):\n\treturn cb.call(3)\nfunc one_line(): return 1\n@abstract func later()\n",
		[["func", "s", 1, 2], ["func", "with_cb", 4, 5], ["func", "one_line", 6, 6], ["func", "later", 7, 7]])
	b = hard("header_and_class", "# a file comment\n\n@tool\n@icon(\"res://x.svg\")\nclass_name Thing\nextends Node\n## The thing.\n\nconst A := 1\nenum E { X, Y }\nsignal s(a: int)\nstatic var counter := 0\nvar d := {\n\t\"k\": 1,\n}\n",
		[["header", "", 1, 2], ["class", "Thing", 3, 7], ["const", "A", 9, 9], ["enum", "E", 10, 10], ["signal", "s", 11, 11], ["var", "counter", 12, 12], ["var", "d", 13, 15]])
	# the text rules on hand-written text
	sync.classify_text(b, {})
	check("hard header_and_class: by text alone a plain header is the user's, const carried, enum written { X, Y } the user's",
		b[0].owner == "user" and find(b, "const", "A").owner == "carried" and find(b, "enum", "E").owner == "user" and find(b, "var", "counter").owner == "user")
	b = hard("no_body", "@abstract func later()\nfunc now():\n\tpass\n", [["func", "later", 1, 1], ["func", "now", 2, 3]])
	sync.classify_text(b, {})
	check("hard no_body: a function with no body is carried, the other the user's", find(b, "func", "later").owner == "carried" and find(b, "func", "now").owner == "user")
	test_interface_stub()


## An interface stub cannot be told from an empty function by its text: with the stored graph it can.
func test_interface_stub() -> void:
	var iface := Model.new_schematic("RefCounted", "SCI_SyncProbe")
	iface["library"] = "interface"
	var ig := Model.new_graph(iface, "poke", "function")
	ig.inputs = [["who", "Node"]]
	ig.outputs = [["ok", "bool"]]
	var ic := Compiler.new()
	var icode := ic.compile(iface)
	var path := SCRATCH + "SCI_SyncProbe.gd"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Model.build_source(icode, iface))
	f.close()
	R.invalidate_libraries()
	var iblocks := sync.split(icode)
	sync.classify(iblocks, ic)
	var tblocks := sync.split(icode)
	sync.classify_text(tblocks, {})
	check("interface: implemented_by and FUNCTIONS are the compiler's, by records and by text",
		find(iblocks, "func", "implemented_by").owner == "compiler" and find(iblocks, "const", "FUNCTIONS").owner == "compiler"
		and find(tblocks, "func", "implemented_by").owner == "compiler" and find(tblocks, "const", "FUNCTIONS").owner == "compiler", icode)
	var door := Model.new_schematic("Node", "")
	door["interfaces"] = ["SCI_SyncProbe"]
	var m := compiled(door, false)
	var blocks := sync.split(m.code)
	sync.classify(blocks, m.c)
	var with_graph := sync.split(Model.build_source(m.code, door))
	sync.classify_text(with_graph)
	var bare := sync.split(m.code)
	sync.classify_text(bare, {})
	check("interface stub: the compiler's by its records (%s) and by text with the stored graph (%s)" % [find(blocks, "func", "poke").get("owner", "?"), find(with_graph, "func", "poke").get("owner", "?")],
		find(blocks, "func", "poke").get("owner", "") == "compiler" and find(with_graph, "func", "poke").get("owner", "") == "compiler", m.code)
	info["interface stub by text without the stored graph"] = find(bare, "func", "poke").get("owner", "?")
	# user_edits takes the owner from the graph's compile, so an edited stub is a compiler edit
	var file: String = String(m.code).replace("return false", "return true")
	var e := sync.user_edits(file, m.code, m.c)
	check("interface stub: editing it is a compiler edit, not a user function", e.compiler.size() == 1 and e.functions.changed.is_empty(), str(e.compiler))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	R.invalidate_libraries()


# ================================================================ diff

func names_of(list: Array) -> Array:
	return list.map(func(x): return String(x.name))


func test_diff() -> void:
	print("==== diff and user_edits ====")
	var bp := Model.load_file("res://demo/SC_Demo.gd")
	var m := compiled(bp, false)
	var base: String = m.code
	var c: Compiler = m.c
	var e := sync.user_edits(base, base, c)
	check("same text: nothing", e.nothing and e.diff.changed.is_empty() and e.diff.added.is_empty() and e.diff.removed.is_empty(), str(e))

	# a number inside one function
	var t := base.replace("sin((t * 3.0))", "sin((t * 5.0))")
	e = sync.user_edits(t, base, c)
	check("number: one func changed (wave), everything else unchanged", names_of(e.functions.changed) == ["wave"] and e.diff.changed.size() == 1
		and e.diff.added.is_empty() and e.diff.removed.is_empty() and e.diff.renamed.is_empty() and not e.nothing and e.functions.changed[0].change == "code",
		str(e.diff.changed))
	check("number: the hunk is the user's, on the line that changed", e.functions.changed[0].hunks.size() == 1 and e.functions.changed[0].hunks[0].owner == "user")

	# a statement added
	t = base.replace("\ttime = (time + delta)\n", "\ttime = (time + delta)\n\tprint(\"tick\")\n")
	e = sync.user_edits(t, base, c)
	check("statement added: _process changed", names_of(e.functions.changed) == ["_process"] and e.declarations.is_empty() and e.compiler.is_empty(), str(e.functions))

	# a function added
	t = base.replace("\n\nfunc wave(", "\n\nfunc extra_fn() -> void:\n\tprint(\"extra\")\n\n\nfunc wave(")
	e = sync.user_edits(t, base, c)
	check("function added", names_of(e.functions.added) == ["extra_fn"] and e.functions.changed.is_empty() and e.functions.removed.is_empty(), str(e.functions))

	# a function deleted
	var wave_text := String(find(sync.split(base), "func", "wave").text)
	t = base.replace(wave_text + "\n", "")
	e = sync.user_edits(t, base, c)
	check("function deleted", names_of(e.functions.removed) == ["wave"] and e.functions.added.is_empty() and e.functions.changed.is_empty(), str(e.functions))

	# renamed, body the same
	t = base.replace("func wave(t: float) -> float:", "func ripple(t: float) -> float:")
	e = sync.user_edits(t, base, c)
	check("rename: reported as renamed wave -> ripple with high confidence", e.functions.renamed.size() == 1 and String(e.functions.renamed[0].old_name) == "wave"
		and String(e.functions.renamed[0].name) == "ripple" and float(e.functions.renamed[0].confidence) >= 0.99 and e.functions.added.is_empty() and e.functions.removed.is_empty(),
		str(e.functions))
	# renamed and the body rewritten
	t = base.replace(wave_text, "func ripple(t: float) -> float:\n\tvar a := t * t\n\tvar b := a + 1.0\n\tprint(a, b)\n\treturn b * bounce_height")
	e = sync.user_edits(t, base, c)
	check("rename with a new body: remove + add", names_of(e.functions.removed) == ["wave"] and names_of(e.functions.added) == ["ripple"] and e.functions.renamed.is_empty(), str(e.functions))

	# two functions reordered
	var blocks := sync.split(base)
	var proc := String(find(blocks, "func", "_process").text)
	var jump := String(find(blocks, "func", "__ia_jump_pressed").text)
	t = base.replace(proc, "\u0001").replace(jump, proc).replace("\u0001", jump)
	e = sync.user_edits(t, base, c)
	check("reorder: moved, not changed (and nothing to bring in)", not e.functions.moved.is_empty() and e.functions.changed.is_empty() and e.nothing
		and e.diff.moved.all(func(x): return x.kind == "func" and x.change == ""), str(e.diff.moved))

	# only a comment inside a function
	t = base.replace("\ttime = (time + delta)\n", "\t# keep time\n\ttime = (time + delta)  # accumulate\n")
	e = sync.user_edits(t, base, c)
	check("comment only: _process changed, comment_only", names_of(e.functions.changed) == ["_process"] and e.functions.changed[0].change == "comment_only", str(e.functions.changed))

	# a blank line and trailing spaces
	t = base.replace("\ttime = (time + delta)\n", "\ttime = (time + delta)   \n\n").replace("func wave(t: float) -> float:", "func wave(t: float) -> float:\t ")
	e = sync.user_edits(t, base, c)
	check("blank line and trailing spaces: nothing", e.nothing and e.diff.changed.is_empty(), str(e.diff.changed))
	# but a changed indent is a change
	t = base.replace("\ttime = (time + delta)\n", "\t\ttime = (time + delta)\n")
	e = sync.user_edits(t, base, c)
	check("a changed leading tab is a change", names_of(e.functions.changed) == ["_process"])

	# a member's default value
	t = base.replace("var time: float = 0.0", "var time: float = 1.0")
	e = sync.user_edits(t, base, c)
	check("member default: a declaration", names_of(e.declarations) == ["time"] and e.functions.changed.is_empty() and not e.nothing, str(e.declarations))
	t = base.replace("signal speed_changed(new_speed: float)", "signal speed_changed(new_speed: float, old: float)")
	e = sync.user_edits(t, base, c)
	check("signal: a declaration", names_of(e.declarations) == ["speed_changed"], str(e.declarations))

	# a helper edited
	t = base.replace("\treturn keys[-1][1]", "\treturn keys[0][1]")
	e = sync.user_edits(t, base, c)
	check("helper edited: compiler", names_of(e.compiler) == ["__sc_sample"] and e.functions.changed.is_empty() and e.declarations.is_empty() and not e.nothing, str(e.compiler))
	t = base.replace("\t__tl_pulse_1_27_playing = true\n", "\t__tl_pulse_1_27_playing = false\n")
	e = sync.user_edits(t, base, c)
	check("timeline machinery edited: compiler", names_of(e.compiler) == ["__tl_pulse_1_27_run"] and e.functions.changed.is_empty(), str(e.compiler))
	t = base.replace("var __delay_1_5: bool = false", "var __delay_1_5: bool = true")
	e = sync.user_edits(t, base, c)
	check("state member edited: compiler", names_of(e.compiler) == ["__delay_1_5"] and e.declarations.is_empty(), str(e.compiler))

	# a line of the _ready prelude
	t = base.replace("func _ready() -> void:\n\t__tl_pulse_1_27_run()\n", "func _ready() -> void:\n\t__tl_pulse_1_27_sample()\n")
	e = sync.user_edits(t, base, c)
	check("prelude line edited: a compiler-owned line edit inside _ready, not a user edit of _ready",
		e.compiler.size() == 1 and String(e.compiler[0].name) == "_ready" and e.compiler[0].status == "compiler_lines" and e.functions.changed.is_empty() and not e.nothing,
		"%s %s" % [str(e.compiler), str(e.functions.changed)])
	t = base.replace("func _ready() -> void:\n\t__tl_pulse_1_27_run()\n", "func _ready() -> void:\n")
	e = sync.user_edits(t, base, c)
	check("prelude line deleted: compiler", e.compiler.size() == 1 and e.functions.changed.is_empty(), str(e.compiler))
	t = base.replace("\tprint(\"Hello from a Schematic!\")\n", "\tprint(\"Hello from a Schematic!\")\n\tprint(\"mine\")\n").replace("\t__tl_pulse_1_27_run()\n\tprint(\"Hello", "\t__tl_pulse_1_27_sample()\n\tprint(\"Hello")
	e = sync.user_edits(t, base, c)
	check("prelude line and a user line edited: both reported", e.compiler.size() == 1 and names_of(e.functions.changed) == ["_ready"], "%s %s" % [str(e.compiler), str(e.functions.changed)])
	# the prelude of a signal event, in another demo
	var coin := Model.load_file("res://demo/game/SC_Coin.gd")
	var mc := compiled(coin, false)
	t = String(mc.code).replace("body_entered.connect(_on_self_body_entered)", "body_exited.connect(_on_self_body_entered)")
	e = sync.user_edits(t, mc.code, mc.c)
	check("signal wiring edited (SC_Coin): compiler", e.compiler.size() == 1 and e.functions.changed.is_empty() and t != String(mc.code), str(e.compiler))
	# an _unhandled_input made only for the prelude
	t = base.replace("\tif event.is_action_pressed(&\"jump\"):", "\tif event.is_action_pressed(&\"leap\"):")
	e = sync.user_edits(t, base, c)
	check("input dispatch edited: compiler", names_of(e.compiler) == ["_unhandled_input"] and e.functions.changed.is_empty(), str(e.compiler))

	# carried code
	var cls: Dictionary = Importer.new().convert(FileAccess.get_file_as_string(SAMPLES + "classes.gd"), {"path": SAMPLES + "classes.gd"}).bp
	var mk := compiled(cls, false)
	t = String(mk.code).replace("const LIMIT := 4", "const LIMIT := 5")
	e = sync.user_edits(t, mk.code, mk.c)
	check("carried code edited: carried", names_of(e.carried) == ["LIMIT"] and e.declarations.is_empty() and e.functions.changed.is_empty() and t != String(mk.code), str(e.carried))
	t = String(mk.code).replace("\tfunc grow(by: int) -> Holder:\n\t\tamount += by", "\tfunc grow(by: int) -> Holder:\n\t\tamount += by * 2")
	e = sync.user_edits(t, mk.code, mk.c)
	check("inner class edited: carried", names_of(e.carried) == ["Holder"] and t != String(mk.code), str(e.carried))

	# trace on against trace off, both ways
	for label in ["SC_Demo", "control_flow"]:
		var sbp: Dictionary = bp if label == "SC_Demo" else Importer.new().convert(FileAccess.get_file_as_string(SAMPLES + "control_flow.gd"), {}).bp
		var off := compiled(sbp, false)
		var on := compiled(sbp, true)
		var e1 := sync.user_edits(on.code, off.code, off.c)
		var e2 := sync.user_edits(off.code, on.code, on.c)
		check("trace on (file) vs off (graph), %s: nothing" % label, e1.nothing and String(on.code) != String(off.code), str([e1.functions, e1.compiler, e1.declarations]))
		check("trace off (file) vs on (graph), %s: nothing" % label, e2.nothing, str([e2.functions, e2.compiler, e2.declarations]))
		var changed_funcs: Array = e1.diff.changed.filter(func(x): return x.kind == "func")
		check("trace %s: the functions that differ differ only in compiler lines, trace lines at that" % label,
			not changed_funcs.is_empty() and changed_funcs.all(func(x): return x.change == "compiler_only" and x.trace_only), str(changed_funcs.map(func(x): return [x.name, x.change, x.trace_only])))
	# the file as saved (with its stored graph) against the graph's code: nothing
	var saved := Model.build_source(base, bp)
	e = sync.user_edits(saved, base, c)
	check("the saved file against its own graph: nothing", e.nothing, str([e.functions, e.compiler, e.declarations, e.carried]))
	e = sync.user_edits(saved.replace("\n", "\r\n"), base, c)
	check("the same with CRLF line endings: nothing", e.nothing, str([e.functions, e.compiler, e.declarations, e.carried]))


# ================================================================ speed

func test_speed() -> void:
	print("==== speed ====")
	var src := "extends Node\n\nvar total := 0\nvar items: Array = []\n\n"
	for i in 150:
		src += "func work_%d(a: int, b: int) -> int:\n\tvar x := a + b * %d\n\tif x > %d:\n\t\ttotal += x\n\t\titems.append(x * 2)\n\telse:\n\t\ttotal -= 1\n\tfor k in range(3):\n\t\ttotal += k + a\n\tprint(\"work\", x, total)\n\treturn x + total\n\n" % [i, i + 2, i * 3]
	var bp: Dictionary = Importer.new().convert(src, {}).bp
	bp["trace"] = true
	var code := Compiler.new().compile(bp)
	var n := code.split("\n").size()
	var file := Model.build_source(code, bp)
	var nf := file.split("\n").size()
	var best := 1e9
	var best_file := 1e9
	for round_no in 3:
		var t0 := Time.get_ticks_usec()
		var blocks := sync.split(code)
		sync.classify_text(blocks, {})
		var t1 := Time.get_ticks_usec()
		var fblocks := sync.split(file)
		sync.classify_text(fblocks)
		var t2 := Time.get_ticks_usec()
		best = minf(best, (t1 - t0) / 1000.0)
		best_file = minf(best_file, (t2 - t1) / 1000.0)
	var per := best * 1000.0 / n
	print("TIMING split + classify_text: %d lines (trace on) in %.1f ms = %.1f ms per 1,000 lines; the saved file (%d lines, stored graph read) %.1f ms" % [n, best, per, nf, best_file])
	info["ms per 1,000 lines"] = snappedf(per, 0.1)
	check("speed: %d lines, %.1f ms per 1,000 lines (well under 100)" % [n, per], n > 1500 and per < 50.0)
