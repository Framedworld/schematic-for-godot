@tool
extends RefCounted
## Compiles a schematic document into plain, readable GDScript.
##
## Execution wires become structured code (if/for/match), pure nodes become inline expressions that are
## re-evaluated by each consumer (Schematic semantics), impure node outputs become locals, latent nodes
## become `await`, and per-node state (Do Once, Flip Flop, Gate, Delay...) becomes per-instance members.

const T := preload("res://addons/schematic/core/sc_types.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Parser := preload("res://addons/schematic/core/sc_gd_parser.gd")

const MAX_STATEMENTS := 20000
## A macro use can say what each loop inside the macro calls its variable at that use (`p.vars`: loop node id in
## the macro -> name); the reuse step looks for this constant before it shares loops whose names differ.
const PER_USE_LOOP_VARS := true
## ... and the comments of the nodes (`p.notes`: node id in the macro -> {note, tail, after, empty}).
const PER_USE_COMMENTS := true

var bp: Dictionary
var errors: Array = []      # [{g, n, m, w}]
var line_map: Dictionary = {}  # 1-based line -> [graph_id, node_id]
var node_lines: Dictionary = {}  # "gid:nid" -> first line
## For the code link (editor/sc_code_link.gd): what a line outside any function body is. 1-based line ->
## "header" (comment, @tool, class_name, extends, description), "declaration" (enum, signal, variable, member),
## "carried" (code kept as written), "function" (a function's header and the annotations above it) or "helper"
## (a function the compiler wrote for its own use). Lines not listed are function bodies (or blank).
var line_kinds: Dictionary = {}
## For the debugger: the expression each wired input pin reads, per function of the generated script
## (function name -> "gid:nid" -> {pin id: expression}), and the lines each function covers ([first, last, name]).
var pin_exprs: Dictionary = {}
var block_lines: Array = []
## For two-way editing (core/sc_sync.gd), one entry per line of the generated text as it reads (index = line - 1;
## a string that runs over several lines counts each of its lines): the line of line_map / line_kinds / block_lines
## it belongs to (those count a statement holding such a string as one line). Negative (that line negated) for a
## line the compiler put at the top of a function that is no node's code: the prelude merged into _ready, _init or
## _unhandled_input (input-action and key dispatch, signal wiring, timeline autoplay) and the Construction
## Script's call and editor guard.
var text_lines := PackedInt32Array()
## The lines that are comments an imported script wrote (see COMMENTS): 1-based line -> true. A comment line written
## with a statement is that statement's node's in line_map (and has no line_kinds entry, so the code link counts it
## a line of the node), but node_lines gives the statement's own line; one written with a declaration or a function
## has that one's kind ("declaration", "function"; "header" above the class lines).
var comment_lines: Dictionary = {}
var _cur_block := ""
var _chain_from := 0   # the node whose exec pin leads to the chain about to be written (0: not known)
var _arm_traces := {}  # a Branch written as an `elif` -> the trace lines its arms begin with (see _fold_elif)

var _members: Array = []    # [text, gid, nid]
var _blocks: Array = []     # [{name, header, lines, gid, nid}]
var _ready_pre: Array = []
var _input_pre: Array = []
var _fn_names: Dictionary = {}

var _g: Dictionary
var _gid: int
var _nodes: Dictionary
var _inw: Dictionary
var _outw: Dictionary
var _desc: Dictionary
var _out: Array
var _entry_id: int
var _stmts: int
var _path: Dictionary
var _in_function: bool
var _loop: int
var _depth: int
var _origin: Dictionary = {}   # expanded (macro-cloned) node id -> the macro call node the user sees
var _helpers: Dictionary = {}
var _construct := false   # schematic has a Construction Script graph
var _want: Dictionary = {}    # "gid:name" -> type, values that must persist beyond their local scope
var _hoist: Dictionary = {}   # the same set, applied on the second pass
var _pass2 := false
var _inline: Dictionary = {}   # call node id -> its expression, when the very next node stores the result
var _lib := false              # function library: everything compiles as static
var _data := false             # data asset: every variable is a field (exported)
var _headers: Dictionary = {}  # "nid:pin" exec entry points that a wire loops back to
var _active: Dictionary = {}   # loop headers currently being emitted -> lambda depth
var _static_fn := false       # the function being written is static: it cannot call the trace helper, which is the object's own
var _lam := 0

# Lambdas written back as lambdas. The importer marks the function graph a lambda became with `lambda` (how
# many of its last inputs are values it captured). Where such a graph is used from exactly one place (an
# Event Reference, with a Bind of the captured values when there are some, or a Lambda node), that place is
# written as the lambda itself, capturing by name, and the graph is not written as a function of its own.
# Anywhere that can't be proved to mean the same, the function and its bound reference are written as before.
const LAM_OPEN := "\u0002"     # an inline lambda stands in an expression as LAM_OPEN + its number + LAM_CLOSE,
const LAM_CLOSE := "\u0003"    # and _line spreads it over the lines of its body
const KEYWORDS := ["null", "true", "false", "self", "super", "PI", "TAU", "INF", "NAN", "and", "or", "not", "in", "is", "as"]
## The scope of a loop's body holds the name its variable is written with under this key (a loop node's id in
## it; not a name a variable could have)
const LOOP_MARK := "\u0001loop %d"
## What a captured value may come from to be captured by name: something that is a local of the generated function
const CAPTURE_SOURCES := ["local_get", "local_set", "fn_entry", "event", "custom_event", "signal_event", "for", "for_each", "for_each_dict",
	"call", "bcall", "util", "call_parent", "dyn_call", "call_self", "iface_call", "cast", "new", "spawn", "table_row", "await_value", "tpl", "const"]
var _no_inline: Dictionary = {}    # lambda graph names never written inline ("*": none at all)
var _lam_graphs: Dictionary = {}   # lambda graph name -> graph, for those that may be written inline
var _lam_done: Dictionary = {}     # ... written inline at least once
var _lam_failed: Dictionary = {}   # ... that some use could not write inline (the function is written)
var _lam_texts: Array = []         # [{head, lines}] for each inline lambda made
var _lam_seq := 0
var _rename: Dictionary = {}       # while writing a lambda inline: captured parameter -> the name it is read by
var _visible: Array = []           # while writing a lambda inline: the names of every function around it
var _ev_caps: Array = []           # [EventGraph local, lambda name]: captured by name, so it must stay a local
var _redo: Dictionary = {}         # lambdas to write as functions after all (a capture became a member)
var lambda_notes: Dictionary = {}  # lambda graph name -> why it was written as a function instead of inline
var _cap_kind := ""                # the kind of node the last value _capture_name accepted comes from
var _lv_nodes: Dictionary = {}     # the graph's nodes (_nodes) that _lv_taken is for
var _lv_taken: Dictionary = {}     # names a loop variable may not be written with in that graph (see _loop_var)


## Compiles in up to two passes: the first finds values that are read outside the execution path that
## produced them (another event's outputs, a node on a different branch); the second stores exactly those
## in per-instance members, which is how Unreal Blueprints behave (the last value written is what you read).
## A lambda that turned out not to be writable inline after all is written again as a function.
func compile(schematic: Dictionary) -> String:
	var code := _compile_once(schematic)
	var redo := _redo.duplicate()
	if code.contains(LAM_OPEN) or code.contains(LAM_CLOSE):
		redo = {"*": true}   # an inline lambda ended up somewhere it can't be spread over lines
	if not redo.is_empty():
		var again = get_script().new()
		again._no_inline = _no_inline.merged(redo)
		again._hoist = _hoist.duplicate()
		again._pass2 = _pass2
		return _take(again, again.compile(schematic))
	if _want.is_empty() or _pass2:
		return code
	var second = get_script().new()
	second._hoist = _want.duplicate()
	second._pass2 = true
	second._no_inline = _no_inline.duplicate()
	return _take(second, second.compile(schematic))


func _take(other: Object, code: String) -> String:
	errors = other.errors
	line_map = other.line_map
	node_lines = other.node_lines
	line_kinds = other.line_kinds
	pin_exprs = other.pin_exprs
	block_lines = other.block_lines
	text_lines = other.text_lines
	comment_lines = other.comment_lines
	lambda_notes = lambda_notes.merged(other.lambda_notes, true)
	return code


func _compile_once(schematic: Dictionary) -> String:
	bp = schematic
	errors.clear()
	line_map.clear()
	node_lines.clear()
	line_kinds.clear()
	pin_exprs.clear()
	block_lines.clear()
	text_lines.clear()
	comment_lines.clear()
	R.ensure_api()
	var is_node := T.is_a(R.self_class(bp), "Node")
	if not T.class_known(R.self_class(bp)):
		_err(0, 0, "Parent class '%s' does not exist" % R.self_class(bp))
	_lib = String(bp.get("library", "")) == "function"
	if _lib and String(bp.get("class_name", "")) == "":
		_err(0, 0, "A function library needs a Class Name (Class Settings): other schematics call its functions through that name")
	_data = String(bp.get("library", "")) == "data"
	if _data and String(bp.get("class_name", "")) == "":
		_err(0, 0, "A data asset needs a Class Name (Class Settings): tables and Make / Break nodes refer to it by that name")
	if _data and not T.is_a(R.self_class(bp), "Resource"):
		_err(0, 0, "A data asset must extend Resource (Class Settings > Parent Class)")
	if String(bp.get("library", "")) == "interface":
		return _compile_interface()
	if _lib and not bp.dispatchers.is_empty():
		_err(0, 0, "A function library can't have event dispatchers: it is never instanced, so nothing could bind to them")

	var event_locals := []
	_find_inline_lambdas()
	for src_graph in bp.graphs:
		if src_graph.kind == "macro" or _lam_graphs.has(String(src_graph.name)):
			continue
		_load_graph(_expand(src_graph))
		var g: Dictionary = _g
		if g.kind == "function":
			_compile_function(g)
			continue
		_in_function = false
		event_locals.append([int(g.id), g.get("locals", [])])
		for tn in g.nodes:
			if tn.kind == "timeline":
				_compile_timeline(tn, is_node)
		var entries: Array = g.nodes.filter(func(n): return n.kind in ["event", "custom_event", "input_action", "signal_event", "key_event"])
		entries.sort_custom(func(a, b): return a.y < b.y)
		for n in entries:
			if _lib:
				_err(_gid, n.id, "A function library has only functions: it is never instanced, so this event would never run")
				continue
			_in_function = false
			match n.kind:
				"event":
					var m := R.find_method(R.self_class(bp), n.p.name)
					if m.is_empty():
						_err(_gid, n.id, _d(n).err)
						continue
					var args := PackedStringArray()
					var arg_names := []
					for ai in m.args.size():
						var a: Dictionary = m.args[ai]
						var h := T.hint(T.from_info(a))
						arg_names.append(_event_arg(n, ai, String(a.name)))
						args.append(String(arg_names[-1]) + ((": " + h) if h != "" else ""))
					if _block(String(n.p.name), "func %s(%s) -> void:" % [n.p.name, ", ".join(args)], n, "then"):
						_blocks[-1]["event"] = true
						_blocks[-1]["arg_names"] = arg_names
				"custom_event":
					var nm := T.ident(String(n.p.get("name", "")))
					if _block(nm, "func %s(%s) -> void:" % [nm, _param_list(n.p.get("params", []))], n, "then"):
						var rpc_mode := String(n.p.get("rpc", ""))
						if rpc_mode != "" and not is_node:
							_err(_gid, n.id, "Replicated events need a Node-derived schematic")
						elif rpc_mode != "":
							_blocks[-1]["pre"] = ["@rpc(\"%s\", \"call_local\", \"%s\")" % ["any_peer" if rpc_mode == "server" else "authority",
								"reliable" if n.p.get("reliable", true) else "unreliable"]]
				"key_event":
					if not is_node:
						_err(_gid, n.id, "Keyboard events need a Node-derived schematic")
						continue
					var key := String(n.p.get("key", "KEY_SPACE"))
					var opened := false
					for edge in ["pressed", "released"]:
						if _follow(n.id, edge)[0] == -1:
							continue
						var kfn := "__%s_%s" % [key.to_lower(), edge]
						if _block(kfn, "func %s() -> void:" % kfn, n, edge):
							if not opened:
								_input_pre.append([1, "if event is InputEventKey and event.keycode == %s and not event.echo:" % key, _gid, n.id])
								opened = true
							_input_pre.append([2, "if %sevent.pressed:" % ("" if edge == "pressed" else "not "), _gid, n.id])
							_input_pre.append([3, "%s()" % kfn, _gid, n.id])
				"input_action":
					if not is_node:
						_err(_gid, n.id, "Input action events need a Node-derived schematic")
						continue
					var act := String(n.p.get("action", ""))
					for edge in ["pressed", "released"]:
						if _follow(n.id, edge)[0] == -1:
							continue
						var fn := "__ia_%s_%s" % [T.ident(act), edge]
						if _block(fn, "func %s() -> void:" % fn, n, edge):
							_input_pre.append([1, "if event.is_action_%s(&\"%s\"):" % [edge, act.c_escape()], _gid, n.id])
							_input_pre.append([2, "%s()" % fn, _gid, n.id])
				"signal_event":
					if not is_node and n.p.get("path", ".") != ".":
						_err(_gid, n.id, "Node signal events need a Node-derived schematic")
						continue
					var path := String(n.p.get("path", "."))
					var fn := "_on_%s_%s" % ["self" if path == "." else T.ident(path.get_file()), T.ident(String(n.p.signal))]
					if _block(fn, "func %s(%s) -> void:" % [fn, _param_list(n.p.get("args", []))], n, "then"):
						var src := "" if path == "." else "get_node(^\"%s\")." % path.c_escape()
						_ready_pre.append([1, "%s%s.connect(%s)" % [src, n.p.signal, fn], _gid, n.id])

	_lambda_functions()
	_implement_interfaces()
	_settle_event_locals(event_locals)
	for cap in _ev_caps:
		# an EventGraph local a lambda captured by name became a member: the lambda would read it when called,
		# where the original took its value when the lambda was made
		for m in _members:
			var text := String(m[0])
			if text.begins_with("var ") and text.substr(4).get_slice(" ", 0).get_slice(":", 0) == String(cap[0]):
				_redo[String(cap[1])] = true
				lambda_notes[String(cap[1])] = "%s, which it captures, is a member of the script" % cap[0]
	_merge_prelude("_ready" if is_node else "_init", "func %s() -> void:" % ("_ready" if is_node else "_init"), _ready_pre)
	_merge_prelude("_unhandled_input", "func _unhandled_input(event: InputEvent) -> void:", _input_pre)
	# Construction Script: runs when the node becomes ready (in game and in the editor) and again whenever an
	# instance-editable variable changes. Gameplay events stay out of the editor unless Run in Editor is on.
	var cg := Model.graph_named(bp, "ConstructionScript")
	_construct = not cg.is_empty() and cg.kind == "function"
	if _construct and not is_node:
		_err(int(cg.id), 0, "A Construction Script needs a Node-derived schematic")
		_construct = false
	if _construct:
		var guard := [] if bp.get("tool", false) else [[1, "if Engine.is_editor_hint():", 0, 0, "guard"], [2, "return", 0, 0, "guard"]]
		var ready := {}
		for b in _blocks:
			if b.name == "_ready":
				ready = b
		if ready.is_empty():
			ready = {"name": "_ready", "header": "func _ready() -> void:", "lines": [], "gid": 0, "nid": 0}
			_blocks.push_front(ready)
		ready.lines = [[1, "ConstructionScript()", 0, 0, "guard"]] + guard + ready.lines
		for b in _blocks:
			if b.name != "_ready" and (b.get("event", false) or b.name == "_unhandled_input"):
				b.lines = guard + b.lines
	return _assemble()


# ---------------------------------------------------------------- interfaces

## A Schematic Interface compiles to its list of function names and a check for "has all of them". The
## graphs only describe each function's inputs and outputs; they have no body to compile.
func _compile_interface() -> String:
	if String(bp.get("class_name", "")) == "":
		_err(0, 0, "A Schematic Interface needs a Class Name (Class Settings): schematics refer to it by that name")
	var names := PackedStringArray()
	var seen := {}
	for g in bp.graphs:
		if g.kind != "function":
			continue
		var fname := T.ident(String(g.name))
		if seen.has(fname):
			_err(int(g.id), 0, "'%s' is in this interface more than once" % fname)
		seen[fname] = true
		names.append("&\"%s\"" % fname)
	_members.append(["const FUNCTIONS: Array[StringName] = [%s]" % ", ".join(names), 0, 0])
	_blocks.append({"name": "implemented_by", "header": "static func implemented_by(target) -> bool:", "gid": 0, "nid": 0, "lines": [
		[1, "if not is_instance_valid(target):", 0, 0], [2, "return false", 0, 0],
		[1, "for fn in FUNCTIONS:", 0, 0], [2, "if not target.has_method(fn):", 0, 0], [3, "return false", 0, 0],
		[1, "return true", 0, 0]]})
	return _assemble()


## Each function of an interface this schematic implements must exist with the interface's inputs and outputs.
## One the schematic has no graph for is written as an empty function that returns default values (as in
## Unreal), so the object still answers it. A custom event of that name also counts.
func _implement_interfaces() -> void:
	for iname in bp.get("interfaces", []):
		if R.interface_bp(String(iname)).is_empty():
			_err(0, 0, "There is no Schematic Interface named '%s' (Class Settings > Interfaces)" % iname)
			continue
		if _lib or _data:
			_err(0, 0, "Only a Schematic Class can implement an interface")
			continue
		for ig in R.interface_functions(String(iname)):
			var fname := T.ident(String(ig.name))
			var mine := Model.graph_named(bp, String(ig.name))
			if not mine.is_empty() and mine.kind == "function":
				if _types_of(mine.inputs) != _types_of(ig.inputs) or _types_of(mine.outputs) != _types_of(ig.outputs):
					_err(int(mine.id), 0, "'%s' implements the interface %s, so it must have these inputs and outputs: (%s) -> (%s)" % [
						fname, iname, ", ".join(_types_of(ig.inputs)), ", ".join(_types_of(ig.outputs))])
				continue
			if _fn_names.has(fname):
				continue
			_fn_names[fname] = true
			var ret := "void"
			var body := "pass"
			var outs: Array = ig.outputs
			if outs.size() == 1:
				ret = T.hint(String(outs[0][1]))
				if ret == "":
					ret = "Variant"
				body = "return " + T.default_literal(String(outs[0][1]))
			elif outs.size() > 1:
				ret = "Array"
				var defs := PackedStringArray()
				for o in outs:
					defs.append(T.default_literal(String(o[1])))
				body = "return [%s]" % ", ".join(defs)
			var params := []
			for prm in ig.inputs:
				params.append(["_" + String(prm[0]), String(prm[1])])
			_blocks.append({"name": fname, "header": "func %s(%s) -> %s:" % [fname, _param_list(params), ret], "gid": 0, "nid": 0,
				"lines": [[1, body, 0, 0]]})


func _types_of(params: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for prm in params:
		out.append(String(prm[1]))
	return out


# ---------------------------------------------------------------- assembly

func _assemble() -> String:
	var lines := PackedStringArray()
	# Line numbers are those of the text as it is written: a piece that runs over several lines (a string with
	# line breaks in a declaration or a statement) takes that many, and every one of them is recorded.
	var at := [0]
	# (a comment line, `comment`, is listed in comment_lines; one written with a node is in line_map as that node's,
	# but it is not where the node's code starts: node_lines, which the debugger stops at, gives the statement's line)
	var add := func(text: String, gid := 0, nid := 0, kind := "", own := false, comment := false) -> void:
		lines.append(text)
		var first: int = int(at[0]) + 1
		var span := text.count("\n") + 1
		at[0] = int(at[0]) + span
		for k in span:
			text_lines.append(-first if own else first)
			if kind != "":
				line_kinds[first + k] = kind
			if nid != 0:
				line_map[first + k] = [gid, nid]
			if comment:
				comment_lines[first + k] = true
		if nid != 0 and not comment:
			var key := "%d:%d" % [gid, nid]
			if not node_lines.has(key):
				node_lines[key] = first
	# comment lines written with a declaration or a function line (see COMMENTS): `note` lines above it
	var notes := func(owner: Dictionary, kind: String, gid := 0, nid := 0) -> void:
		for nl in owner.get("note", []):
			var c := _comment_at(String(nl), 0)
			if String(c[1]) == "":
				add.call("")
			else:
				add.call("\t".repeat(int(c[0])) + String(c[1]), gid, nid, kind, false, true)
	add.call(Model.MARKER + " v%d - generated from a Schematic graph. Edit it in the Schematic editor, not by hand." % Model.VERSION, 0, 0, "header")
	notes.call(bp, "header")   # comments written above an imported script's class lines
	if bp.get("tool", false) or _construct:
		add.call("@tool", 0, 0, "header")
	for class_ann in bp.get("class_pre", []):
		add.call(String(class_ann), 0, 0, "header")   # @icon(...) and the like, carried over from an imported script
	if String(bp.get("class_name", "")) != "":
		add.call("class_name " + T.ident(bp.class_name), 0, 0, "header")
	add.call("extends " + R.self_class(bp), 0, 0, "header")
	for dl in String(bp.get("description", "")).split("\n", false):
		add.call("## " + dl, 0, 0, "header")
	add.call("")
	for be in bp.get("enums", []):
		var names := PackedStringArray()
		for bv in be.values:
			names.append(T.ident(String(bv)))
		add.call("enum %s { %s }" % [T.ident(String(be.name)), ", ".join(names)], 0, 0, "declaration")
	if not bp.get("enums", []).is_empty():
		add.call("")
	for dsp in bp.dispatchers:
		notes.call(dsp, "declaration")
		for sig_ann in dsp.get("pre", []):
			add.call(String(sig_ann), 0, 0, "declaration")   # @warning_ignore(...) and the like, carried over from an imported script
		var sig_params: Array = dsp.get("params", [])
		if dsp.has("declared"):
			sig_params = sig_params.slice(0, int(dsp.declared))   # an imported signal emitted with more than it declares
		add.call("signal %s%s" % [T.ident(dsp.name), ("(%s)" % _param_list(sig_params)) if not (sig_params.is_empty() and dsp.has("declared")) else ""] \
			+ String(dsp.get("tail", "")), 0, 0, "declaration")
	if not bp.dispatchers.is_empty():
		add.call("")
	# enums, constants and inner classes carried over from an imported script, exactly as written
	if String(bp.get("extra_code", "")) != "":
		for extra_line in String(bp.extra_code).split("\n"):
			add.call(extra_line, 0, 0, "carried" if extra_line.strip_edges() != "" else "")
		add.call("")
	var group := ""
	var seen := {}
	for v in bp.variables:
		var vn := T.ident(String(v.name))
		if seen.has(vn):
			_err(0, 0, "Duplicate variable name '%s'" % vn)
			continue
		seen[vn] = true
		if String(v.get("raw", "")) != "":
			# a declaration kept as written (annotations with arguments, set / get, static, @onready ...)
			notes.call(v, "declaration")
			for raw_line in String(v.raw).split("\n"):
				add.call(raw_line, 0, 0, "declaration")
				var marker := raw_line.find("@export_group(\"")
				if marker != -1:
					group = raw_line.substr(marker + 15, raw_line.find("\"", marker + 15) - marker - 15)
			continue
		var vt := String(v.get("type", "any"))
		var h := T.hint(vt)
		var exportable := h != "" and not vt in ["Callable", "Signal", "RID"]
		if (v.get("export", false) or _data) and exportable:
			if String(v.get("category", "")) != group:
				group = String(v.get("category", ""))
				add.call("@export_group(\"%s\")" % group.c_escape(), 0, 0, "declaration")
		notes.call(v, "declaration")
		for tl in String(v.get("tooltip", "")).split("\n", false):
			add.call("## " + tl, 0, 0, "declaration")
		var lit := String(v.get("default", ""))
		if lit == "":
			lit = T.default_literal(vt)
		# Variables typed with one of this schematic's enums get the enum type (so the Inspector shows a dropdown).
		if vt == "int" and String(v.get("enum", "")) != "":
			for be in bp.get("enums", []):
				if String(be.name) == String(v.enum) and not be.values.is_empty():
					h = T.ident(String(be.name))
					var idx := clampi(int(lit) if lit.is_valid_int() else 0, 0, be.values.size() - 1)
					lit = "%s.%s" % [h, T.ident(String(be.values[idx]))]
		var decl := "%svar %s%s" % ["static " if _lib else "", vn, (": " + h) if h != "" else ""]
		if not (T.is_object(vt) and lit == "null"):
			decl += " = " + lit
		# A variable of an imported script is declared the way the script declared it: one written without a
		# type takes any value (another script may give it one this script never does), one written with ":="
		# has whatever type GDScript infers. The type in the variable list is what the pins show.
		var as_written := String(v.get("written", ""))
		if as_written == "bare" and h != "" and String(v.get("default", "")) == "":
			decl = "%svar %s: %s" % ["static " if _lib else "", vn, h]
		elif as_written == "untyped":
			decl = "%svar %s" % ["static " if _lib else "", vn] + ((" = " + String(v.default)) if String(v.get("default", "")) != "" else "")
		elif as_written == "infer" and String(v.get("default", "")) != "":
			decl = "%svar %s := %s" % ["static " if _lib else "", vn, String(v.default)]
		var exported: bool = (v.get("export", false) or _data) and exportable and not _lib
		var notify_fn := "on_%s_changed" % vn
		var notify: bool = v.get("notify", false) and not _lib and not Model.graph_named(bp, notify_fn).is_empty()
		var rerun: bool = _construct and exported
		add.call(("@export " if exported else "") + decl + (":" if (notify or rerun) else "") + String(v.get("tail", "")), 0, 0, "declaration")
		if notify or rerun:
			var is_node_bp := T.is_a(R.self_class(bp), "Node")
			add.call("\tset(value):", 0, 0, "declaration")
			add.call("\t\t%s = value" % vn, 0, 0, "declaration")
			if is_node_bp:
				add.call("\t\tif is_node_ready():", 0, 0, "declaration")
			var deep := "\t\t\t" if is_node_bp else "\t\t"
			if notify:
				add.call("%s%s()" % [deep, notify_fn], 0, 0, "declaration")
			if rerun:
				add.call("%sConstructionScript()" % deep, 0, 0, "declaration")
	if not bp.variables.is_empty():
		add.call("")
	for m in _members:
		add.call(("static " + String(m[0])) if (_lib and String(m[0]).begins_with("var ")) else m[0], m[1], m[2], "declaration")
	if not _members.is_empty():
		add.call("")
	for hname in _helpers:
		_blocks.append({"name": hname, "header": _helpers[hname][0], "lines": _helpers[hname][1], "gid": 0, "nid": 0, "helper": true})
	for b in _blocks:
		add.call("")
		notes.call(b, "function", b.gid, b.nid)
		for pre_line in b.get("pre", []):
			add.call(pre_line, b.gid, b.nid, "function")
		add.call((("static " + String(b.header)) if (_lib and String(b.header).begins_with("func ")) else String(b.header)) + String(b.get("tail", "")), b.gid, b.nid,
			"helper" if b.get("helper", false) else "function")
		var first_line := int(at[0])
		if b.lines.is_empty():
			add.call("\tpass", b.gid, b.nid, "helper" if b.get("helper", false) else "")
		for l in b.lines:
			var cm: Dictionary = l[5] if l.size() > 5 and l[5] is Dictionary else {}
			for c in cm.get("above", []):
				if String(c[1]) == "":
					add.call("")
				else:
					add.call(_comment_text(int(l[0]) + int(c[0]), String(c[1])), l[2], l[3], "", false, true)
			add.call("\t".repeat(l[0]) + l[1] + String(cm.get("tail", "")), l[2], l[3], "helper" if b.get("helper", false) else "", l.size() > 4 and typeof(l[4]) == TYPE_STRING)
			for c in cm.get("below", []):
				if String(c[1]) == "":
					add.call("")
				else:
					add.call(_comment_text(int(l[0]) + int(c[0]), String(c[1])), l[2], l[3], "", false, true)
		block_lines.append([first_line, int(at[0]), String(b.name)])
		for end_line in b.get("end", []):
			add.call(String(end_line), b.gid, b.nid, "function", false, true)   # an `#endregion` that closed a region around the function
		add.call("")
	# comments written after everything in an imported script
	for el in bp.get("end_note", []):
		add.call(String(el), 0, 0, "declaration" if String(el) != "" else "", false, String(el) != "")
	return "\n".join(lines)


## A comment line of a function body at `tabs` tabs ("" for a blank line, which is written empty).
static func _comment_text(tabs: int, text: String) -> String:
	return "" if text == "" else "\t".repeat(maxi(tabs, 0)) + text


func _merge_prelude(fn: String, header: String, pre: Array) -> void:
	if pre.is_empty():
		return
	pre = pre.map(func(l): return [l[0], l[1], l[2], l[3], "prelude"])   # (the mark is read by _assemble: text_lines)
	for b in _blocks:
		if b.name == fn:
			# the prelude reads the engine's parameter names; an event may call its parameters otherwise
			var own: Array = b.get("arg_names", [])
			if fn == "_unhandled_input" and not own.is_empty() and String(own[0]) != "event":
				pre = pre.map(func(l): return [l[0], _replace_word(String(l[1]), "event", String(own[0])), l[2], l[3], l[4]])
			b.lines = pre + b.lines
			return
	_blocks.push_front({"name": fn, "header": header, "lines": pre, "gid": 0, "nid": 0})


## Declares a local on the line that first gives it a value ("var x: int = ..."), as a person would write it,
## instead of at the top of the function with a throwaway default. A local may be given its first value in
## several separate blocks (each branch of an if, say): then each of them declares it, as the blocks of a
## hand-written function would. Only when every such first line is a plain assignment that does not read the
## local, and every other use lies inside the block that line is in. True when done.
## With `infer` the declaration is written "var x := ...", so its type is whatever GDScript infers.
func _declare_in_place(lines: Array, name: String, hint: String, infer := false) -> bool:
	var starts := []        # indices of the lines that become declarations
	var depth := -1         # indentation of the declaration the current lines belong to, -1 outside any
	var used := false
	for i in lines.size():
		var text := String(lines[i][1])
		if depth != -1 and int(lines[i][0]) < depth:
			depth = -1   # that block has ended
		if not text.contains(name) or _replace_word(text, name, "\u0001") == text:
			continue
		used = true
		if depth != -1:
			continue
		if not text.begins_with(name + " = "):
			return false
		var value := text.substr(name.length() + 3)
		if value.contains(name) and _replace_word(value, name, "\u0001") != value:
			return false
		starts.append(i)
		depth = int(lines[i][0])
	if not used:
		return true   # never used: nothing to declare
	for i in starts:
		# a value that continues on the following lines (a multi-line literal) is still one statement
		var value := String(lines[i][1]).substr(name.length() + 3)
		# (a declaration written "var x: Type" stays that, even where another block declares the name with ":=";
		# an enum's starts at its first value, which the importer gives as `(0 as Enum)`)
		var bare_default := _declared_bare(lines[i]) and hint != "" and (value == T.default_literal(hint) or value == "(0 as %s)" % hint)
		if infer and not bare_default:
			lines[i][1] = "var %s := %s" % [name, value]
		elif bare_default:
			lines[i][1] = "var %s: %s" % [name, hint]   # written as "var x: Vector3": that already starts at Vector3()
		elif _declared_bare(lines[i]) and hint == "" and value == "null":
			lines[i][1] = "var %s" % name
		else:
			lines[i][1] = "var %s%s = %s" % [name, (": " + hint) if hint != "" else "", value]
	return true


## True when the line comes from a Set node an imported `var x` / `var x: Type` (no value) became.
func _declared_bare(line: Array) -> bool:
	if line.size() < 4:
		return false
	var graph := Model.find_graph(bp, int(line[2]))
	if graph.is_empty():
		return false
	var node := Model.find_node(graph, int(line[3]))
	return not node.is_empty() and String(node.kind) == "local_set" and bool(node.p.get("bare", false))


## A local of the EventGraph belongs to the whole graph, so it can carry a value from one event to another
## and is normally a member of the script. Most are used by one event only and always given a value before
## they are read: those become ordinary locals of that event's function (faster, and nothing lingers on
## the object). `pending` is [[graph id, locals], ...]; run once every function body exists.
func _settle_event_locals(pending: Array) -> void:
	for entry in pending:
		var gid := int(entry[0])
		for ml in entry[1]:
			var name := T.ident(String(ml.name))
			var hint := T.hint(String(ml.type))
			var written := String(ml.get("hint", ""))
			if written != "":
				hint = written
			elif bool(ml.get("untyped", false)):
				hint = ""
			var users := []
			var named_in_text := false
			for blk in _blocks:
				# A function that has a parameter, local or loop variable of that name of its own (another event's
				# parameter, a function's own local) means its own by it: it does not use this one.
				if _shadows(blk, name, int(blk.gid) != gid):
					continue
				var uses := false
				for l in blk.lines:
					var text := String(l[1])
					if not text.contains(name):
						continue
					# A lambda written in place has names of its own: a line of its body, or its parameter list in
					# the line that opens it, means the lambda's `name`, not this local.
					if l.size() > 2 and int(l[2]) != int(blk.gid) and _lambda_declares(int(l[2]), name):
						continue
					text = _without_lambda_params(text, name)
					if not text.contains(name):
						continue
					# reached by name (set(), a tween, an animation track): it has to be a real member
					if _named_as_property(text, name):
						named_in_text = true
					if not uses and _replace_word(text, name, "\u0001") != text:
						uses = true
				if uses:
					users.append(blk)
			var local := false
			if users.size() == 1 and not named_in_text and int(users[0].gid) == gid:
				# a body the compiler wrapped in a lambda could not hand a new value back out of it
				var wrapped := false
				for l in users[0].lines:
					if String(l[1]).begins_with("(func() -> void:"):
						wrapped = true
				if not wrapped:
					local = _declare_in_place(users[0].lines, name, hint, bool(ml.get("infer", false)))
			if local:
				continue
			var lit := String(ml.get("default", ""))
			var text := "var %s%s = %s" % [name, (": " + hint) if hint != "" else "", lit if lit != "" else T.default_literal(String(ml.type))]
			if written != "":
				text = "var %s: %s" % [name, written]
			elif bool(ml.get("untyped", false)):
				text = "var %s = null" % name
			var known := false
			for m in _members:
				if m[0] == text:
					known = true
			if not known:
				_members.append([text, gid, 0])


## True when the lambda graph `lgid` declares `name` itself: as one of its own parameters (not a value it
## captures, which is the name outside), a local, or a loop variable.
func _lambda_declares(lgid: int, name: String) -> bool:
	for g in bp.get("graphs", []):
		if int(g.id) != lgid:
			continue
		var own: int = g.inputs.size() - int(g.get("lambda", 0))
		for i in maxi(own, 0):
			if T.ident(String(g.inputs[i][0])) == name:
				return true
		for loc in g.get("locals", []):
			if T.ident(String(loc.name)) == name:
				return true
		for n in g.nodes:
			if String(n.get("p", {}).get("var", "")) == name:
				return true
	return false


## The text with the parameter list of every `func(...)` that has a parameter called `name` emptied, so that
## the parameter is not taken for a use of an outer variable of that name.
func _without_lambda_params(text: String, name: String) -> String:
	var at := text.find("func(")
	while at != -1:
		var close := text.find(")", at)
		if close == -1:
			break
		var has := false
		for part in text.substr(at + 5, close - at - 5).split(","):
			if part.strip_edges().get_slice(":", 0).get_slice("=", 0).strip_edges() == name:
				has = true
		if has:
			text = text.substr(0, at + 5) + text.substr(close)
			close = at + 5
		at = text.find("func(", close)
	return text


## True when a function written has a name of its own that is `name`: a parameter in its header or, with
## `deep` (a function of another graph, which cannot read this graph's locals at all), a local or loop variable
## it declares.
func _shadows(blk: Dictionary, name: String, deep: bool) -> bool:
	var header := String(blk.get("header", ""))
	var open := header.find("(")
	var close := header.rfind(")")
	if open != -1 and close > open:
		for part in header.substr(open + 1, close - open - 1).split(","):
			var pn := part.strip_edges().trim_prefix("...").get_slice(":", 0).get_slice("=", 0).strip_edges()
			if pn == name:
				return true
	if not deep:
		return false
	for l in blk.lines:
		var text := String(l[1])
		if text.begins_with("var " + name) or text.begins_with("for " + name):
			var after := text.substr(4 + name.length(), 1)
			if after == "" or after in [" ", ":", "="]:
				return true
	return false


## True when `name` is written as a string that reaches the property of that name (set("name"), a tween of
## self, a node path to it): then it has to be a member. Any other string (a label, a dictionary key) does not.
static func _named_as_property(text: String, name: String) -> bool:
	for q in ["\"", "'"]:
		if text.contains(":" + name + q):
			return true   # ".:name", a property path
		var quoted: String = q + name + q
		if not text.contains(quoted):
			continue
		for lead in ["set(", "get(", "set_deferred(", "set_indexed(", "get_indexed(", "self, ", "^", "&", "NodePath("]:
			if text.contains(lead + quoted):
				return true
	return false


## GDScript could not accept some "var x := ..." lines (it could not infer a type there, or the type it
## inferred does not suit a later line): stop inferring those locals, so they are declared with the type the
## graph knows instead. `bad_lines` are 1-based line numbers of `code`; when none of them is such a
## declaration, every inferred local is given up. Returns how many locals changed (0: nothing left to try).
static func drop_inferred(schematic: Dictionary, code: String, bad_lines: Array) -> int:
	var names := {}
	var lines := code.split("\n")
	var decl := RegEx.create_from_string("^\\s*var ([A-Za-z_][A-Za-z0-9_]*) := ")
	for ln in bad_lines:
		if int(ln) >= 1 and int(ln) <= lines.size():
			var m := decl.search(lines[int(ln) - 1])
			if m != null:
				names[m.get_string(1)] = true
	var changed := 0
	for g in schematic.get("graphs", []):
		for l in g.get("locals", []):
			if bool(l.get("infer", false)) and (names.is_empty() or names.has(T.ident(String(l.name)))):
				l.erase("infer")
				changed += 1
	return changed


## "(count - 1)" -> "count": the last index of a loop written as a count, so the loop can say range(count).
func _counted(last: String) -> String:
	if not (last.begins_with("(") and last.ends_with(" - 1)")) or last.contains("\"") or last.contains("'"):
		return ""
	var inner := last.substr(1, last.length() - 6)
	var depth := 0
	for ch in inner:
		if ch in ["(", "[", "{"]:
			depth += 1
		elif ch in [")", "]", "}"]:
			depth -= 1
			if depth < 0:
				return ""
	return inner if depth == 0 and inner.strip_edges() != "" else ""


func _param_list(params: Array) -> String:
	var out := PackedStringArray()
	for prm in params:
		var h := T.hint(String(prm[1]))
		var infer := false
		if prm.size() > 3 and String(prm[3]).begins_with("..."):
			# the rest of a call's arguments, as an imported script declared it
			var rest_type := String(prm[3]).substr(3)
			out.append("...%s%s" % [T.ident(String(prm[0])), (": " + rest_type) if rest_type != "" else ""])
			continue
		if prm.size() > 3 and String(prm[3]) == "-":
			h = ""   # written without a type in the imported script: it stays that way, whatever the pin shows
		elif prm.size() > 3 and String(prm[3]) == ":=":
			infer = prm.size() > 2 and String(prm[2]) != ""
			h = "" if infer else h
		elif prm.size() > 3 and String(prm[3]) != "":
			h = String(prm[3])   # a type written in the imported script that has no pin type
		var text := T.ident(String(prm[0])) + ((": " + h) if h != "" else "")
		if prm.size() > 2 and String(prm[2]) != "":
			text += (" := " if infer else " = ") + String(prm[2])
		out.append(text)
	return ", ".join(out)


# ---------------------------------------------------------------- graph loading

func _load_graph(g: Dictionary) -> void:
	_g = g
	_gid = int(g.id)
	_inline = {}
	_nodes = {}
	_inw = {}
	_outw = {}
	_desc = {}
	for n in g.nodes:
		_nodes[int(n.id)] = n
	for w in g.wires:
		if not _nodes.has(int(w[0])) or not _nodes.has(int(w[2])):
			continue
		_inw["%d:%s" % [w[2], w[3]]] = [int(w[0]), String(w[1])]
		var k := "%d:%s" % [w[0], w[1]]
		if not _outw.has(k):
			_outw[k] = []
		_outw[k].append([int(w[2]), String(w[3])])


func _d(n: Dictionary) -> Dictionary:
	if not _desc.has(int(n.id)):
		_desc[int(n.id)] = R.describe(n, bp, _g)
	return _desc[int(n.id)]


func _pin_in(n: Dictionary, pid: String) -> Dictionary:
	for pin in _d(n).ins:
		if pin.id == pid:
			return pin
	return {"id": pid, "name": pid, "type": "any"}


func _out_type(n: Dictionary, pid: String) -> String:
	for pin in _d(n).outs:
		if pin.id == pid:
			return pin.type
	return "any"


func _follow(nid: int, pin: String) -> Array:
	var l: Array = _outw.get("%d:%s" % [nid, pin], [])
	return l[0] if not l.is_empty() else [-1, ""]


func _wired_out(nid: int, pin: String) -> bool:
	if _outw.has("%d:%s" % [nid, pin]):
		return true
	var split_prefix := "%d:%s~" % [nid, pin]
	for k in _outw:
		if String(k).begins_with(split_prefix):
			return true
	return false


func _err(gid: int, nid: int, msg: String, warn := false) -> void:
	nid = int(_origin.get(nid, nid))
	for e in errors:
		if e.g == gid and e.n == nid and e.m == msg:
			return
	errors.append({"g": gid, "n": nid, "m": msg, "w": warn})


## With `keep_tail`, comments waiting for the next line (see COMMENTS) give it only the lines above it: the
## comment at the end of a statement's line waits for the statement's own line (not an annotation above it).
func _line(ind: int, text: String, nid: int, keep_tail := false) -> void:
	var cm := _take_carry(ind, keep_tail)
	if text.contains(LAM_OPEN):
		_lambda_lines(ind, text, _gid, int(_origin.get(nid, nid)), 0, cm)
	else:
		_out.append(_with_comments([ind, text, _gid, int(_origin.get(nid, nid))], cm))
	_stmts += 1


# ---------------------------------------------------------------- comments
# COMMENTS. A node an imported script's statement became carries the comments written with it (see the importer's
# _block and the parser's COMMENTS): p.note (lines above), p.tail (the end of its line), p.after (lines below),
# p.empty ({exec pin: {note, tail}}: comments of a block that became no node, written with its `pass`); a Branch's
# p.else_tail (the end of its `else:` line; the end of an `elif` line is the p.tail of the Branch it became). A line
# of `note` or `after` is "" (a blank line) or a comment from its `#`, with a tab in front for each block it is
# indented deeper than the statement and a "<" for each block shallower. A graph made in the editor has none of
# these and is written exactly as before.
# While a function is written, the lines above the next line and the comment at its end wait in _carry (each
# line with its indentation in tabs); the next line written takes them. A line that has comments carries them
# as its sixth item, {above: [[tabs relative to the line, text]], tail, below: [[tabs, text]]} (the fifth item is
# null when it has no mark of its own), and _assemble writes them around it. They are kept out of the line's text
# so that nothing that reads the lines (where a local is declared, whether a function ends in a return) sees them.

var _carry := {"above": [], "tail": ""}


## [indentation in tabs, text] of one line of a note written for a statement at indentation `ind`.
static func _comment_at(line: String, ind: int) -> Array:
	var k := 0
	var depth := ind
	while k < line.length() and line[k] == "\t":
		depth += 1
		k += 1
	while k < line.length() and line[k] == "<":
		depth -= 1
		k += 1
	return [maxi(depth, 0), line.substr(k)]


## The comments waiting for a line at indentation `ind`, as that line's comments ({} when none), taken from _carry.
func _take_carry(ind: int, keep_tail: bool) -> Dictionary:
	if _carry.above.is_empty() and (keep_tail or String(_carry.tail) == ""):
		return {}
	var cm := {"above": [], "tail": "", "below": []}
	for a in _carry.above:
		cm.above.append([int(a[0]) - ind, String(a[1])])
	_carry.above = []
	if not keep_tail:
		cm.tail = String(_carry.tail)
		_carry.tail = ""
	return cm


## A line entry of _out with comments `cm` added to those it may have.
static func _with_comments(entry: Array, cm: Dictionary) -> Array:
	if cm.is_empty():
		return entry
	while entry.size() < 5:
		entry.append(null)
	if entry.size() == 5:
		entry.append({"above": [], "tail": "", "below": []})
	var have: Dictionary = entry[5]
	have.above.append_array(cm.get("above", []))
	if String(cm.get("tail", "")) != "":
		have.tail = (String(have.tail) + "  " + String(cm.tail).strip_edges()) if String(have.tail) != "" else String(cm.tail)
	have.below.append_array(cm.get("below", []))
	return entry


## Adds the node's lines above and the comment at the end of its line to what waits for the next line.
func _carry_node(p: Dictionary, ind: int) -> void:
	for l in p.get("note", []):
		_carry.above.append(_comment_at(String(l), ind))
	if String(p.get("tail", "")) != "":
		if String(_carry.tail) != "":
			_carry.above.append([ind, String(_carry.tail).strip_edges()])
		_carry.tail = String(p.tail)


## Lines to write below everything written so far (the last line), or, when nothing has been written since `at`,
## above the next line.
func _comments_below(lines: Array, ind: int, at: int) -> void:
	if lines.is_empty():
		return
	if _out.size() <= at:
		for l in lines:
			_carry.above.append(_comment_at(String(l), ind))
		return
	var last: Array = _out[-1]
	var below := []
	for l in lines:
		var c := _comment_at(String(l), ind)
		below.append([int(c[0]) - int(last[0]), String(c[1])])
	_with_comments(last, {"below": below})


## What waits in _carry when a function's lines are all written goes below its last line.
func _flush_carry() -> void:
	if _carry.above.is_empty() and String(_carry.tail) == "":
		return
	if not _out.is_empty():
		var last: Array = _out[-1]
		var below := []
		for a in _carry.above:
			below.append([int(a[0]) - int(last[0]), String(a[1])])
		if String(_carry.tail) != "":
			below.append([0, String(_carry.tail).strip_edges()])
		_with_comments(last, {"below": below})
	_carry = {"above": [], "tail": ""}


## A line holding an inline lambda: the line runs up to the lambda's header, the lambda's body follows on lines
## of its own (each still the line of the node in the lambda's graph it came from, for the debugger), and what
## came after the lambda goes on on the next line. Inside brackets GDScript reads that as one statement; outside
## them, the lambda is put in brackets of its own.
func _lambda_lines(ind: int, text: String, gid: int, nid: int, open := 0, cm := {}) -> void:
	var a := text.find(LAM_OPEN)
	var b := text.find(LAM_CLOSE, a)
	var lam: Dictionary = _lam_texts[int(text.substr(a + 1, b - a - 1))]
	var before := text.substr(0, a)
	var after := text.substr(b + 1)
	var depth := open + _open_brackets(before)
	var rest := after.strip_edges()
	if rest != "" and (depth <= 0 or rest[0] in [".", "(", "["]):   # (something done with the lambda itself, like .call())
		before += "("
		after = ")" + after
		depth += 1
	# (the statement's comments go with its first line, the one that opens the lambda)
	_out.append(_with_comments([ind, before + String(lam.head), gid, nid, true] if open != 0 else [ind, before + String(lam.head), gid, nid], cm))
	for l in lam.lines:
		_out.append([ind + int(l[0])] + l.slice(1))
	if after.contains(LAM_OPEN):
		_lambda_lines(ind, after, gid, nid, depth)
	elif after != "":
		_out.append([ind, after, gid, nid, true])


## How many brackets are open at the end of a piece of GDScript text (strings skipped).
static func _open_brackets(text: String) -> int:
	var depth := 0
	var quote := ""
	var i := 0
	while i < text.length():
		var c := text[i]
		if quote != "":
			if c == "\\":
				i += 1
			elif c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		i += 1
	return depth


func _member(text: String, nid: int) -> void:
	for m in _members:
		if m[0] == text:
			return
	_members.append([text, _gid, int(_origin.get(nid, nid))])


# ---------------------------------------------------------------- function blocks

func _block(name: String, header: String, entry: Dictionary, start_pin: String) -> bool:
	if _fn_names.has(name):
		_err(_gid, entry.id, "'%s' is defined more than once in this schematic" % name)
		return false
	_fn_names[name] = true
	_cur_block = name
	_out = []
	_entry_id = int(entry.id)
	_stmts = 0
	_path = {}
	_loop = 0
	_lam = 0
	_active = {}
	_headers = {}
	var tgt := _follow(entry.id, start_pin)
	_mark_headers(tgt[0], tgt[1], {}, {})
	# Outputs of this event that another event reads are copied to members on entry.
	var prefix := "%d:p%d_" % [_gid, int(entry.id)]
	for hk in _hoist:
		if String(hk).begins_with(prefix):
			var pname := String(hk).substr(prefix.length())
			var mname := "__p%d_%s_g%d" % [int(entry.id), pname, _gid]
			_member("var %s = %s" % [mname, T.default_literal(String(_hoist[hk]))], int(entry.id))
			_line(1, "%s = %s" % [mname, _event_pin_name(entry, pname)], int(entry.id))
	_chain_from = int(entry.id)
	_carry = {"above": [], "tail": ""}
	if not _chain(tgt[0], tgt[1], 1, {}) and entry.get("p", {}).get("empty", {}).has(start_pin):
		_empty_comments(int(entry.id), start_pin, 1)   # an imported function of nothing but `pass  # later`
		_line(1, "pass", int(entry.id))
	_flush_carry()
	_cur_block = ""
	_blocks.append({"name": name, "header": header, "lines": _out, "gid": _gid, "nid": int(_origin.get(int(entry.id), int(entry.id)))})
	# the function's own comments: the lines above its `func` line and the one at the end of it (see COMMENTS)
	var ep: Dictionary = entry.get("p", {})
	if ep.has("note"):
		_blocks[-1]["note"] = ep.note
	if String(ep.get("tail", "")) != "":
		_blocks[-1]["tail"] = String(ep.tail)
	if ep.has("end"):
		_blocks[-1]["end"] = ep.end
	return true


# ---------------------------------------------------------------- macros

## Returns a copy of `g` with every macro call replaced by a private clone of the macro's nodes.
## Each call site gets fresh node ids, so stateful nodes inside a macro keep separate state per use.
func _expand(g: Dictionary) -> Dictionary:
	_origin = {}
	var has := false
	for n in g.nodes:
		if n.kind == "macro":
			has = true
	if not has:
		return g
	var x: Dictionary = g.duplicate(true)
	var guard := 0
	while true:
		var ci := -1
		for i in x.nodes.size():
			if x.nodes[i].kind == "macro":
				ci = i
				break
		if ci == -1:
			break
		var call: Dictionary = x.nodes[ci]
		var cid := int(call.id)
		var root := int(_origin.get(cid, cid))
		x.nodes.remove_at(ci)
		var ins_w := []
		var outs_w := []
		var rest := []
		for w in x.wires:
			if int(w[2]) == cid:
				ins_w.append(w)
			elif int(w[0]) == cid:
				outs_w.append(w)
			else:
				rest.append(w)
		x.wires = rest
		guard += 1
		if guard > 300:
			_err(int(g.id), root, "Macros are nested too deeply (a macro can't use itself)")
			break
		var m := R.macro_graph(bp, call.p)
		if m.is_empty():
			_err(int(g.id), root, ("Macro '%s' no longer exists" % call.p.get("name", "")) if String(call.p.get("lib", "")) == ""
				else ("Macro '%s' is not in the library %s" % [call.p.get("name", ""), call.p.lib]))
			continue
		var remap := {}
		var kinds := {}
		var clones := {}
		var use_vars: Dictionary = call.p.get("vars", {})
		var use_notes: Dictionary = call.p.get("notes", {})
		for mn in m.nodes:
			kinds[int(mn.id)] = mn.kind
			if mn.kind in ["macro_in", "macro_out", "comment"]:
				continue
			var c: Dictionary = mn.duplicate(true)
			if use_vars.has(str(int(mn.id))):
				c.p["var"] = String(use_vars[str(int(mn.id))])   # this use's name for the loop variable
			if use_notes.has(str(int(mn.id))):
				var said: Dictionary = use_notes[str(int(mn.id))]   # this use's comments on the node
				for field in said:
					c.p[field] = said[field].duplicate(true) if (said[field] is Array or said[field] is Dictionary) else said[field]
			c.id = int(x.next_id)
			x.next_id = int(x.next_id) + 1
			remap[int(mn.id)] = int(c.id)
			clones[int(c.id)] = c
			_origin[int(c.id)] = root
			x.nodes.append(c)
		# A local of the macro is a separate variable at each use, unless the use names the local of its own
		# graph that it stands for (`names`): that is how a macro made from existing nodes keeps their lines.
		var names: Dictionary = call.p.get("names", {})
		var renamed := {}
		for ml in m.get("locals", []):
			var unique := "%s_m%d" % [T.ident(String(ml.name)), cid]
			if names.has(String(ml.name)):
				unique = String(names[String(ml.name)])
			renamed[String(ml.name)] = unique
			if not x.locals.any(func(xl): return String(xl.name) == unique):
				var own: Dictionary = ml.duplicate(true)
				own["name"] = unique
				x.locals.append(own)
		# all at once: one local's new name may be another local's old one
		for c in clones.values():
			if c.kind in ["local_get", "local_set"] and renamed.has(String(c.p.get("name", ""))):
				c.p["name"] = renamed[String(c.p.name)]
		for w in m.wires:
			var fk := String(kinds.get(int(w[0]), ""))
			var tk := String(kinds.get(int(w[2]), ""))
			if fk == "macro_in" and tk == "macro_out":
				for iw in ins_w:
					for ow in outs_w:
						if iw[3] == w[1] and ow[1] == w[3]:
							x.wires.append([iw[0], iw[1], ow[2], ow[3]])
			elif fk == "macro_in":
				if not remap.has(int(w[2])):
					continue
				var found := false
				for iw in ins_w:
					if iw[3] == w[1]:
						x.wires.append([iw[0], iw[1], remap[int(w[2])], w[3]])
						found = true
				if not found and call.d.has(w[1]):
					clones[remap[int(w[2])]].d[w[3]] = call.d[w[1]]
			elif tk == "macro_out":
				if not remap.has(int(w[0])):
					continue
				for ow in outs_w:
					if ow[1] == w[3]:
						x.wires.append([remap[int(w[0])], w[1], ow[2], ow[3]])
			elif remap.has(int(w[0])) and remap.has(int(w[2])):
				x.wires.append([remap[int(w[0])], w[1], remap[int(w[2])], w[3]])
	return x


# ---------------------------------------------------------------- timelines

func _tl(n: Dictionary) -> String:
	return "__tl_%s_%d_%d" % [T.ident(String(n.p.get("name", "tl"))).to_lower(), _gid, int(n.id)]


func _compile_timeline(n: Dictionary, is_node: bool) -> void:
	var id := int(n.id)
	var shown := int(_origin.get(id, id))
	if not is_node:
		_err(_gid, id, "Timelines need a Node-derived schematic")
		return
	var p: Dictionary = n.p
	var tl := _tl(n)
	var length := T.to_literal(maxf(float(p.get("length", 1.0)), 0.0001))
	_member("var %s_time: float = 0.0" % tl, id)
	_member("var %s_dir: float = 1.0" % tl, id)
	_member("var %s_playing: bool = false" % tl, id)
	var sample := []
	var events := []   # [track ident, [key times]]
	var names := {}
	for tr in p.get("tracks", []):
		var tn := T.ident(String(tr.name))
		if names.has(tn):
			_err(_gid, id, "Timeline '%s' has two tracks named '%s'" % [p.get("name", ""), tn])
			continue
		names[tn] = true
		var tt := String(tr.get("type", "float"))
		var keys: Array = tr.get("keys", []).duplicate()
		keys.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		if tt == "event":
			var times := PackedStringArray()
			for k in keys:
				times.append(T.to_literal(float(k[0])))
			events.append([tn, times])
			continue
		var parts := PackedStringArray()
		for k in keys:
			var lit := String(k[1])
			parts.append("[%s, %s]" % [T.to_literal(float(k[0])), lit if lit != "" else T.default_literal(tt)])
		var first := T.default_literal(tt)
		if not keys.is_empty() and String(keys[0][1]) != "":
			first = String(keys[0][1])
		_member("var %s_%s: %s = %s" % [tl, tn, tt, first], id)
		sample.append([1, "%s_%s = __sc_sample([%s], %s_time, %s)" % [tl, tn, ", ".join(parts), tl, "true" if tr.get("smooth", false) else "false"], _gid, shown])
	if sample.is_empty():
		sample.append([1, "pass", _gid, shown])
	_blocks.append({"name": tl + "_sample", "header": "func %s_sample() -> void:" % tl, "lines": sample, "gid": _gid, "nid": shown})
	_block(tl + "_update", "func %s_update() -> void:" % tl, n, "update")
	_block(tl + "_finished", "func %s_finished() -> void:" % tl, n, "finished")
	var run := [
		[1, "if %s_playing:" % tl], [2, "return"],
		[1, "%s_playing = true" % tl],
		[1, "while %s_playing:" % tl],
		[2, "await get_tree().process_frame"],
		[2, "if not %s_playing:" % tl], [3, "break"],
		[2, "var prev: float = %s_time" % tl],
		[2, "%s_time += get_process_delta_time() * %s_dir" % [tl, tl]],
		[2, "var raw: float = %s_time" % tl],
		[2, "var tl_done := false"],
		[2, "if %s_dir > 0.0 and %s_time >= %s:" % [tl, tl, length]],
	]
	if p.get("loop", false):
		run.append([3, "%s_time = fmod(%s_time, %s)" % [tl, tl, length]])
	else:
		run.append([3, "%s_time = %s" % [tl, length]])
		run.append([3, "tl_done = true"])
	run.append([2, "elif %s_dir < 0.0 and %s_time <= 0.0:" % [tl, tl]])
	if p.get("loop", false):
		run.append([3, "%s_time = %s + fmod(%s_time, %s)" % [tl, length, tl, length]])
	else:
		run.append([3, "%s_time = 0.0" % tl])
		run.append([3, "tl_done = true"])
	run.append_array([[2, "%s_sample()" % tl], [2, "%s_update()" % tl]])
	for ev in events:
		# An event key fires when playback crosses its time, in either direction.
		_block("%s_ev_%s" % [tl, ev[0]], "func %s_ev_%s() -> void:" % [tl, ev[0]], n, "e_" + String(ev[0]))
		if ev[1].is_empty():
			continue
		run.append([2, "for key_time in [%s]:" % ", ".join(ev[1])])
		run.append([3, "if (%s_dir > 0.0 and prev < key_time and raw >= key_time) or (%s_dir < 0.0 and prev > key_time and raw <= key_time):" % [tl, tl]])
		run.append([4, "%s_ev_%s()" % [tl, ev[0]]])
	run.append_array([[2, "if tl_done:"], [3, "%s_playing = false" % tl], [3, "%s_finished()" % tl]])
	for l in run:
		l.append(_gid)
		l.append(shown)
	_blocks.append({"name": tl + "_run", "header": "func %s_run() -> void:" % tl, "lines": run, "gid": _gid, "nid": shown})
	if p.get("autoplay", false):
		_ready_pre.append([1, "%s_run()" % tl, _gid, shown])
	if not _helpers.has("__sc_sample"):
		_helpers["__sc_sample"] = ["func __sc_sample(keys: Array, t: float, smooth: bool) -> Variant:", [
			[1, "if keys.is_empty():", 0, 0], [2, "return 0.0", 0, 0],
			[1, "if t <= keys[0][0]:", 0, 0], [2, "return keys[0][1]", 0, 0],
			[1, "for i in range(1, keys.size()):", 0, 0],
			[2, "if t <= keys[i][0]:", 0, 0],
			[3, "var w: float = (t - keys[i - 1][0]) / maxf(keys[i][0] - keys[i - 1][0], 0.00001)", 0, 0],
			[3, "return lerp(keys[i - 1][1], keys[i][1], smoothstep(0.0, 1.0, w) if smooth else w)", 0, 0],
			[1, "return keys[-1][1]", 0, 0]]]


func _compile_function(g: Dictionary) -> void:
	var entry := {}
	for n in g.nodes:
		if n.kind == "fn_entry":
			entry = n
	var fname := T.ident(String(g.name))
	if entry.is_empty():
		_err(_gid, 0, "Function '%s' has no entry node" % g.name)
		return
	_in_function = true
	var ret := _function_ret(g)
	var header := "%sfunc %s(%s) -> %s:" % ["static " if (bool(g.get("static", false)) and not _lib) else "", fname, _param_list(g.inputs), ret]
	if ret == "-":
		header = header.replace(" -> -:", ":")   # an imported function written without a return type stays without one
	_static_fn = bool(g.get("static", false))
	var written := _block(fname, header, entry, "then")
	_static_fn = false
	if not written:
		return
	var b: Dictionary = _blocks[-1]
	if not g.get("pre", []).is_empty():
		b["pre"] = g.pre.duplicate()
	b.lines = _function_body(g, entry, b.lines)
	_in_function = false


# ---------------------------------------------------------------- lambdas written inline

## The lambda graphs (see LAM_OPEN) that may be written where they are used: used from one place only, by an
## Event Reference or a Lambda node in a graph that is not a macro, and named nowhere else (text nodes,
## variables, code carried over as written). Anything else about them is checked where they are used.
func _find_inline_lambdas() -> void:
	_lam_graphs = {}
	if _no_inline.has("*") or _lib:
		return
	for g in bp.graphs:
		if String(g.kind) == "function" and g.has("lambda") and not _no_inline.has(String(g.name)) and g.get("pre", []).is_empty() \
				and int(g.lambda) >= 0 and int(g.lambda) <= g.inputs.size():
			_lam_graphs[String(g.name)] = g
	if _lam_graphs.is_empty():
		return
	var uses := {}
	var bad := {}
	var texts := PackedStringArray([String(bp.get("extra_code", ""))])
	for v in bp.variables:
		texts.append(String(v.get("raw", "")))
		texts.append(String(v.get("default", "")))
	for g in bp.graphs:
		for n in g.nodes:
			var fn := String(n.get("p", {}).get("fn", ""))
			if _lam_graphs.has(fn):
				uses[fn] = int(uses.get(fn, 0)) + 1
				if String(g.kind) == "macro" or not String(n.kind) in ["event_ref", "closure"]:
					bad[fn] = true
			if String(n.kind) in ["code", "expr"]:
				texts.append(String(n.get("p", {}).get("code", "")))
	var all_text := "\n".join(texts)
	for nm in _lam_graphs.keys():
		if int(uses.get(nm, 0)) != 1 or bad.has(nm) or (all_text.contains(nm) and _replace_word(all_text, nm, "\u0001") != all_text):
			_lam_graphs.erase(nm)
			lambda_notes[nm] = "it is used from %d places, or from a macro or text" % int(uses.get(nm, 0))


## The lambda graphs that some use did not write inline, or that nothing wrote, are written as functions, as
## they always were.
func _lambda_functions() -> void:
	var written := {}
	for round_no in 2:
		var again := true
		while again:
			again = false
			for g in bp.graphs:
				var nm := String(g.name)
				if not _lam_graphs.has(nm) or written.has(nm):
					continue
				if _lam_failed.has(nm) or (round_no == 1 and not _lam_done.has(nm)):
					written[nm] = true
					if not _lam_failed.has(nm):
						lambda_notes[nm] = "the place it is used is never written"
					again = true
					_load_graph(_expand(g))
					_compile_function(_g)


## A Bind of a lambda graph's captured values onto an Event Reference to it, written as the lambda. "" if not.
func _lambda_from_bind(n: Dictionary, scope: Dictionary) -> String:
	var tk := "%d:target" % int(n.id)
	if not _inw.has(tk) or _origin.has(int(n.id)):
		return ""
	var ref: Dictionary = _nodes.get(int(_inw[tk][0]), {})
	if ref.is_empty() or String(ref.kind) != "event_ref" or _origin.has(int(ref.id)) or _outw.get("%d:fn" % int(ref.id), []).size() != 1:
		return ""
	var lg: Dictionary = _lam_graphs.get(String(ref.p.get("fn", "")), {})
	if lg.is_empty() or int(lg.lambda) == 0 or int(n.p.get("n", 0)) != int(lg.lambda):
		return ""
	var exprs := []
	var pins := []
	for i in int(lg.lambda):
		pins.append("v%d" % i)
		exprs.append(_in(n, "v%d" % i, scope))
	return _inline_lambda(lg, exprs, [n, pins], scope)


## A Lambda node (a lambda with default values, or one handed to connect()) written as the lambda. "" if not.
func _lambda_from_closure(n: Dictionary, scope: Dictionary) -> String:
	var lg: Dictionary = _lam_graphs.get(String(n.p.get("fn", "")), {})
	if lg.is_empty():
		return ""
	if _origin.has(int(n.id)) or lg.inputs.size() - int(n.p.get("n", 0)) != int(lg.lambda):
		_lam_failed[String(lg.name)] = true
		lambda_notes[String(lg.name)] = "its Lambda node is inside a macro" if _origin.has(int(n.id)) else "its Lambda node does not pass the values it captures"
		return ""
	var exprs := []
	var pins := []
	for i in int(lg.lambda):
		pins.append("c%d" % i)
		exprs.append(_in(n, "c%d" % i, scope))
	var made := _inline_lambda(lg, exprs, [n, pins], scope)
	return made


## The name a captured value is read by, when it is one the inline lambda can capture by that name: a local,
## parameter or loop variable of the generated function around it (not a member, which a lambda would read when
## it is called rather than when it is made). "" if not.
func _capture_name(n: Dictionary, pin: String, expr: String) -> String:
	var key := "%d:%s" % [int(n.id), pin]
	if not _inw.has(key) or not expr.is_valid_identifier() or expr.begins_with("__") or expr in KEYWORDS:
		return ""
	var src: Dictionary = _nodes.get(int(_inw[key][0]), {})
	var guard := 0
	while not src.is_empty() and String(src.kind) == "reroute" and guard < 100:
		guard += 1
		var rk := "%d:i" % int(src.id)
		src = _nodes.get(int(_inw[rk][0]), {}) if _inw.has(rk) else {}
	if src.is_empty() or not String(src.kind) in CAPTURE_SOURCES:
		return ""
	if String(src.kind) == "const" and not src.p.has("of"):
		return ""   # a name node only (a parameter, or a name a Match case binds)
	if String(src.kind) == "tpl" and _d(src).pure:
		return ""   # a template's value written out where it is read, which may be any name
	for v in bp.variables:
		if T.ident(String(v.name)) == expr and not String(src.kind) in ["local_get", "local_set", "fn_entry", "const"]:
			return ""
	_cap_kind = String(src.kind)
	return expr


## Writes a lambda graph as the lambda it was: its body compiled in place, its captured parameters read by
## the names the code around it has for them (`outer`, one expression per captured parameter; `at` is
## [node, [pin per captured value]] they came from). Returns the expression standing for it, or "" (and the
## graph is then written as a function) when the inline lambda could not be shown to mean the same.
func _inline_lambda(lg: Dictionary, outer: Array, at: Array, scope: Dictionary) -> String:
	var name := String(lg.name)
	var k := int(lg.lambda)
	var own_n: int = lg.inputs.size() - k
	var fail := func() -> String:
		_lam_failed[name] = true
		return ""
	if outer.size() != k or own_n < 0:
		lambda_notes[name] = "its captured values do not match its inputs"
		return fail.call()
	var own := {}
	for i in own_n:
		own[T.ident(String(lg.inputs[i][0]))] = true
	# the names the lambda's captured parameters are read by
	var seq := _lam_seq
	_lam_seq += 1
	var rename := {}
	var outer_names := {}
	var pairs := []
	var ev_caps := []
	for i in k:
		var cap := T.ident(String(lg.inputs[own_n + i][0]))
		var o := _capture_name(at[0], String(at[1][i]), String(outer[i]))
		if o == "" or own.has(o):
			lambda_notes[name] = "the captured value %s is `%s` where it is made, not a local of its own" % [cap, String(outer[i])] if o == "" \
				else "a parameter of its own is called %s, the name it captures %s by" % [o, cap]
			return fail.call()
		outer_names[o] = cap
		pairs.append([cap, o])
		if o != cap:
			rename[cap] = "zz_sccap_%d_%d" % [seq, i]
		if _cap_kind in ["local_get", "local_set"] and String(_g.kind) != "function":
			ev_caps.append([o, name])
	# every name the code around the lambda has declared where the lambda is made: the lambda may not declare one
	var visible := {}
	for key in scope:
		if not String(key).begins_with("\u0001"):
			visible[String(key)] = true
	for l in _g.locals:
		visible[T.ident(String(l.name))] = true
	if String(_g.kind) == "function":
		for inp in _g.inputs:
			visible[T.ident(String(inp[0]))] = true
	for before in _visible:
		visible.merge(before)
	for o in outer_names:
		visible[o] = true
	# compile the lambda's graph in place of the code around it
	var saved := [_g, _gid, _nodes, _inw, _outw, _desc, _out, _entry_id, _stmts, _path, _in_function, _loop, _origin, _inline,
		_headers, _active, _lam, _chain_from, _rename, _depth]
	_visible.append(visible)
	var saved_carry := _carry   # (the comments waiting for the line around the lambda wait for it still)
	_carry = {"above": [], "tail": ""}
	_load_graph(_expand(lg))
	var gid := _gid
	var entry := {}
	for n in _g.nodes:
		if String(n.kind) == "fn_entry":
			entry = n
	var lines := []
	var head := ""
	if not entry.is_empty():
		_in_function = true
		_out = []
		_entry_id = int(entry.id)
		_stmts = 0
		_path = {}
		_loop = 0
		_lam = 0
		_active = {}
		_headers = {}
		_depth = 0
		_rename = rename
		var tgt := _follow(int(entry.id), "then")
		_mark_headers(tgt[0], tgt[1], {}, {})
		_chain_from = int(entry.id)
		if not _chain(tgt[0], tgt[1], 1, {}) and entry.get("p", {}).get("empty", {}).has("then"):
			_empty_comments(int(entry.id), "then", 1)
			_line(1, "pass", int(entry.id))
		_flush_carry()
		lines = _function_body(_g, entry, _out)
		if lines.is_empty():
			lines = [[1, "pass", _gid, int(entry.id)]]   # a lambda that does nothing (`func(): pass`) still needs a body
		var ret := _function_ret(_g)
		head = "func(%s)%s:" % [_param_list(_g.inputs.slice(0, own_n)), "" if ret == "-" else " -> " + ret]
	var made_stmts := _stmts
	_carry = saved_carry
	_visible.pop_back()
	_g = saved[0]
	_gid = saved[1]
	_nodes = saved[2]
	_inw = saved[3]
	_outw = saved[4]
	_desc = saved[5]
	_out = saved[6]
	_entry_id = saved[7]
	_stmts = int(saved[8]) + made_stmts
	_path = saved[9]
	_in_function = saved[10]
	_loop = saved[11]
	_origin = saved[12]
	_inline = saved[13]
	_headers = saved[14]
	_active = saved[15]
	_lam = saved[16]
	_chain_from = saved[17]
	_rename = saved[18]
	_depth = saved[19]
	var exprs: Dictionary = pin_exprs.get(_cur_block, {})
	var prefix := "%d:" % gid
	var why := "it has no entry node" if entry.is_empty() else ""
	# A name the lambda declares that the code around it has declared already (a loop variable both number by node
	# id, say) is one GDScript refuses: the lambda's own is given a name of its own. Every use of that name in the
	# lambda is its own (what it reads from outside comes in under the captured names).
	var declared := RegEx.create_from_string("(?:^|[^A-Za-z0-9_.])(?:var|for)\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var renames := {}
	var all_text := "\n".join(lines.map(func(l): return String(l[1])))
	for l in lines:
		for m in declared.search_all(String(l[1])):
			var dn := m.get_string(1)
			if visible.has(dn) and not renames.has(dn):
				var fresh := "%s_l%d" % [dn, seq]
				var more := 0
				while visible.has(fresh) or all_text.contains(fresh):
					more += 1
					fresh = "%s_l%d_%d" % [dn, seq, more]
				renames[dn] = fresh
	# The lambda's body must mean the same with the captured names in it: no captured parameter left under its
	# own name (in text carried over as written, say), and no name of the lambda's own that is also a name it
	# captures.
	for l in lines:
		var text := _lambda_names(String(l[1]), renames, {})
		if text.contains(LAM_OPEN) or text.contains(LAM_CLOSE):
			why = "a lambda inside it could not be written"
		for cap in rename:
			if text.contains(cap) and _replace_word(text, cap, "\u0001") != text:
				why = "its body names the captured value %s directly" % cap
		for o in outer_names:
			if rename.has(String(outer_names[o])) and text.contains(o) and _replace_word(text, o, "\u0001") != text:
				why = "its body has a name of its own that is also %s, which it captures" % o
		if why != "":
			break
	if why != "":
		for key in exprs.keys():
			if String(key).begins_with(prefix):
				exprs.erase(key)
		lambda_notes[name] = why
		return fail.call()
	# the captured parameters are read by the outer names
	var tokens := {}
	for pair in pairs:
		if rename.has(String(pair[0])):
			tokens[String(rename[String(pair[0])])] = String(pair[1])
	if not tokens.is_empty() or not renames.is_empty():
		for l in lines:
			l[1] = _lambda_names(String(l[1]), renames, tokens)
		for key in exprs:
			if String(key).begins_with(prefix):
				for pid in exprs[key]:
					exprs[key][pid] = _lambda_names(String(exprs[key][pid]), renames, tokens)
	_ev_caps.append_array(ev_caps)
	_lam_done[name] = true
	_lam_texts.append({"head": head, "lines": lines})
	return LAM_OPEN + str(_lam_texts.size() - 1) + LAM_CLOSE


func _lambda_names(text: String, renames: Dictionary, tokens: Dictionary) -> String:
	for dn in renames:
		if text.contains(dn):
			text = _replace_word(text, dn, String(renames[dn]))
	for tok in tokens:
		text = text.replace(tok, String(tokens[tok]))
	return text


## The return type a function graph is written with ("-": none written).
func _function_ret(g: Dictionary) -> String:
	var outs: Array = g.outputs
	var ret := "void"
	if outs.size() == 1:
		ret = T.hint(String(outs[0][1]))
		if ret == "":
			ret = "Variant"
	elif outs.size() > 1:
		ret = "Array"
	if String(g.get("ret_hint", "")) != "":
		ret = String(g.ret_hint)
	return ret


## A function's lines with its locals declared and, when it returns something, a last return.
func _function_body(g: Dictionary, entry: Dictionary, lines: Array) -> Array:
	var outs: Array = g.outputs
	var b := {"lines": lines}
	var pre := []
	for l in g.locals:
		if bool(l.get("param", false)):
			continue   # a parameter the function assigns to: it is already declared, in the signature
		var h := T.hint(String(l.type))
		var written := String(l.get("hint", ""))   # a type of the imported script that has no pin type (an enum, an inner class)
		if bool(l.get("untyped", false)):
			h = ""   # written without a type in the imported script: it holds whatever it is given, as it did there
		if _declare_in_place(b.lines, T.ident(String(l.name)), written if written != "" else h, bool(l.get("infer", false))):
			continue
		if written != "":
			pre.append([1, "var %s: %s" % [T.ident(String(l.name)), written], _gid, int(entry.id)])
			continue
		if bool(l.get("untyped", false)):
			pre.append([1, "var %s = null" % T.ident(String(l.name)), _gid, int(entry.id)])
			continue
		var lit := String(l.get("default", ""))
		if lit == "":
			lit = T.default_literal(String(l.type))
		pre.append([1, "var %s%s = %s" % [T.ident(String(l.name)), (": " + h) if h != "" else "", lit], _gid, int(entry.id)])
	b.lines = pre + b.lines
	# A function an imported script wrote without a return type gives back null where it ends without a return,
	# as GDScript does: no last `return null` is written for it (the script did not have one).
	var falls_off := String(g.get("ret_hint", "")) == "-" and outs.size() == 1 and String(g.get("ret_default", "")) == "" \
		and T.default_literal(String(outs[0][1])) == "null"
	if not outs.is_empty() and not falls_off and not _ends_in_return(b.lines, 0, b.lines.size(), 1):
		var defs := PackedStringArray()
		for o in outs:
			defs.append(T.default_literal(String(o[1])))
		if String(g.get("ret_default", "")) != "" and defs.size() == 1:
			defs[0] = String(g.ret_default)   # an imported function that returns one of its script's enums
		b.lines.append([1, "return " + (defs[0] if defs.size() == 1 else "[" + ", ".join(defs) + "]"), _gid, int(entry.id)])
	return b.lines


## A complete if/else or match also returns when each arm returns. Loops and partial branches may fall through.
func _ends_in_return(lines: Array, first: int, end: int, indent: int) -> bool:
	var statements := []
	for i in range(first, end):
		var row: Array = lines[i]
		if int(row[0]) == indent and not (row.size() > 4 and row[4] is bool and row[4]):
			var text := String(row[1]).strip_edges()
			if not text.is_empty() and not text.begins_with("#"):
				statements.append(i)
	if statements.is_empty():
		return false
	var last := int(statements.back())
	var tail := String(lines[last][1])
	if tail == "return" or tail.begins_with("return "):
		return true
	if tail == "else:" and statements.size() >= 2:
		var branch := int(statements[-2])
		return String(lines[branch][1]).begins_with("if ") and _ends_in_return(lines, branch + 1, last, indent + 1) \
			and _ends_in_return(lines, last + 1, end, indent + 1)
	if tail.begins_with("match "):
		var arm_end := end
		var has_default := false
		for i in range(end - 1, last, -1):
			if int(lines[i][0]) != indent + 1:
				continue
			var pattern := String(lines[i][1]).strip_edges()
			if pattern.is_empty() or pattern.begins_with("#"):
				continue
			if not pattern.ends_with(":") or not _ends_in_return(lines, i + 1, arm_end, indent + 2):
				return false
			has_default = has_default or pattern == "_:"
			arm_end = i
		return has_default
	return false


# ---------------------------------------------------------------- exec flow

## (Both walks below keep their own stack, so a chain of thousands of steps does not overflow the engine's.)
func _latent_reach(start: int) -> bool:
	var seen := {}
	var todo := [start]
	while not todo.is_empty():
		var nid: int = todo.pop_back()
		if nid == -1 or seen.has(nid) or not _nodes.has(nid):
			continue
		seen[nid] = true
		var n: Dictionary = _nodes[nid]
		if _d(n).latent:
			return true
		for pin in _d(n).outs:
			if pin.type != "exec":
				continue
			for tgt in _outw.get("%d:%s" % [nid, pin.id], []):
				todo.append(tgt[0])
	return false


## Finds exec entry points that some wire loops back to (they become `while` loops): a depth-first walk, in the
## order of the node's exec outputs and their wires.
func _mark_headers(nid: int, pin: String, stack: Dictionary, done: Dictionary) -> void:
	var frames := [[nid, pin, null, 0, ""]]   # [node, pin, targets (null: not entered yet), next target, key]
	while not frames.is_empty():
		var f: Array = frames[-1]
		if f[2] == null:
			var fid: int = f[0]
			if fid == -1 or not _nodes.has(fid):
				frames.pop_back()
				continue
			var key := "%d:%s" % [fid, f[1]]
			if stack.has(key):
				_headers[key] = true
				frames.pop_back()
				continue
			if done.has(key):
				frames.pop_back()
				continue
			stack[key] = true
			var tgts := []
			var n: Dictionary = _nodes[fid]
			if not f[1] in ["reset", "open", "close", "toggle"] and n.kind != "timeline":
				for o in _d(n).outs:
					if o.type != "exec":
						continue
					tgts.append_array(_outw.get("%d:%s" % [fid, o.id], []))
			f[2] = tgts
			f[4] = key
			continue
		if int(f[3]) < f[2].size():
			var tgt: Array = f[2][int(f[3])]
			f[3] = int(f[3]) + 1
			frames.append([int(tgt[0]), String(tgt[1]), null, 0, ""])
			continue
		stack.erase(f[4])
		done[f[4]] = true
		frames.pop_back()


func _again(nid: int, pin: String) -> String:
	return "again_%d" % nid if pin == "exec" else "again_%d_%s" % [nid, T.ident(pin)]


## Emits the chain starting at (nid, pin). Returns true if at least one statement was written.
func _chain(nid: int, pin: String, ind: int, scope: Dictionary) -> bool:
	var before := _out.size()
	var visited := []
	var from := _chain_from
	_chain_from = 0
	while nid != -1 and _nodes.has(nid):
		var key := "%d:%s" % [nid, pin]
		if _path.has(key):
			if _active.has(key) and int(_active[key]) == _lam:
				_line(ind, "%s = true" % _again(nid, pin), nid)
			elif _active.has(key):
				_err(_gid, nid, "This wire loops back out of a Sequence or loop body that contains a latent node. Move the loop inside that branch.")
			else:
				_err(_gid, nid, "Execution wire loops back in a way that can't be expressed. Use a loop node (For / While) instead.")
			break
		if _headers.has(key) and not _active.has(key):
			# A wire loops back to this point: run it as a loop that repeats while the back wire is taken.
			var flag := _again(nid, pin)
			_decl(flag, "bool", "true", ind, nid, scope)
			_line(ind, "while %s:" % flag, nid)
			_line(ind + 1, "%s = false" % flag, nid)
			_active[key] = _lam
			var saved_loop := _loop
			_loop = 0
			_chain_from = from
			_chain(nid, pin, ind + 1, scope.duplicate())
			_loop = saved_loop
			_active.erase(key)
			break
		if _stmts > MAX_STATEMENTS:
			_err(_gid, nid, "Graph is too large to expand (too many merged execution paths)")
			break
		_path[key] = true
		visited.append(key)
		if bp.get("trace", false) and not _lib and not _static_fn and not _d(_nodes[nid]).pure:
			# Opt-in debug aid: tells the editor which nodes are running so it can light them up.
			_member("var __sc_hits: Dictionary = {}", 0)
			_member("var __sc_vals: Dictionary = {}", 0)
			_member("var __sc_edges: Dictionary = {}", 0)
			_member("var __sc_state: Dictionary = {\"last\": 0, \"wait\": false}", 0)
			_helpers["__sc_trace"] = ["func __sc_trace(graph_id: int, node_id: int, values: Dictionary = {}, from: int = 0) -> void:", [
				[1, "if not EngineDebugger.is_active():", 0, 0], [2, "return", 0, 0],
				[1, "__sc_hits[graph_id * 100000 + node_id] = true", 0, 0],
				[1, "if from != 0 and from != node_id:", 0, 0],
				[2, "__sc_edges[(graph_id * 100000 + from) * 100000 + node_id] = true", 0, 0],
				[1, "if not values.is_empty():", 0, 0],
				[2, "__sc_vals[graph_id * 100000 + node_id] = values", 0, 0],
				# at most ten messages a second: the first node is reported at once, the ones after it a moment later
				[1, "var path := (get_script() as Script).resource_path", 0, 0],
				[1, "if Time.get_ticks_msec() - int(__sc_state.last) > 100:", 0, 0],
				[2, "__sc_flush(path, __sc_hits, __sc_vals, __sc_edges, __sc_state)", 0, 0],
				[1, "elif not __sc_state.wait:", 0, 0],
				[2, "var loop := Engine.get_main_loop() as SceneTree", 0, 0],
				[2, "if loop != null:", 0, 0],
				[3, "__sc_state.wait = true", 0, 0],
				# The later report is a call on the script, not on this object, and is handed what to report: an object
				# that frees itself (a pickup that is collected) is gone by then, and a call on it would never be made.
				[3, "loop.create_timer(0.1).timeout.connect(Callable(get_script(), &\"__sc_flush\").bind(path, __sc_hits, __sc_vals, __sc_edges, __sc_state))", 0, 0]]]
			_helpers["__sc_flush"] = ["static func __sc_flush(path: String, hits: Dictionary, vals: Dictionary, edges: Dictionary, state: Dictionary) -> void:", [
				[1, "state.wait = false", 0, 0],
				[1, "if hits.is_empty():", 0, 0], [2, "return", 0, 0],
				[1, "state.last = Time.get_ticks_msec()", 0, 0],
				[1, "var shown := {}", 0, 0],
				[1, "for key in vals:", 0, 0],
				[2, "var row := {}", 0, 0],
				[2, "for pin in vals[key]:", 0, 0],
				[3, "row[pin] = str(vals[key][pin]).left(60)", 0, 0],
				[2, "shown[key] = row", 0, 0],
				[1, "EngineDebugger.send_message(\"schematic:exec\", [path, hits.keys(), shown, edges.keys()])", 0, 0],
				[1, "hits.clear()", 0, 0],
				[1, "edges.clear()", 0, 0],
				[1, "vals.clear()", 0, 0]]]
			# The values arriving on this node's wired input pins go along, so the editor can show them on the pins.
			# (Not for nodes inside an expanded macro: their pins are not the ones on screen.)
			var watch := ""
			if not _origin.has(nid):
				var parts := PackedStringArray()
				for wpin in _d(_nodes[nid]).ins:
					# (not a value written straight into this node's line, a call or await the step before left to it:
					# shown here it would run twice)
					# and only a value that can be read a second time without changing anything (see _repeat_safe)
					var wkey := "%d:%s" % [nid, wpin.id]
					if wpin.type != "exec" and _inw.has(wkey) and not _inline.has(int(_inw[wkey][0])) and _repeat_safe(nid, String(wpin.id), 0):
						var shown_value := _in(_nodes[nid], String(wpin.id), scope)
						if not shown_value.contains(LAM_OPEN):   # (a lambda being made is not shown: it would be made twice)
							parts.append("\"%s\": %s" % [wpin.id, shown_value])
				if not parts.is_empty():
					watch = ", {%s}" % ", ".join(parts)
			# and the node execution came from, so the editor can light the wire that was followed
			var came := int(_origin.get(from, from))
			if came != 0 and came != int(_origin.get(nid, nid)):
				watch = (watch if watch != "" else ", {}") + ", %d" % came
			var trace_line := "__sc_trace(%d, %d%s)" % [_gid, int(_origin.get(nid, nid)), watch]
			if _arm_traces.has(nid):
				# (a Branch that is an `elif`: a line above its `if` would make it an else with an if inside, so the
				# line is written first thing in each of its arms instead; the code is the same with the trace on or off)
				_arm_traces[nid].append(trace_line)
			else:
				_line(ind, trace_line, nid)
		# (a reroute is a knot on the wire, not a place execution stops at: what comes after it was reached from
		# the node before it, and the editor lights every piece of the wire between the two)
		if String(_nodes[nid].kind) != "reroute":
			from = nid
		# the node's comments (see COMMENTS): its lines above and the end of its line go with the first line its
		# step writes, its lines below after the last
		var np: Dictionary = _nodes[nid].get("p", {})
		var commented := np.has("note") or np.has("tail") or np.has("after")
		if commented:
			_carry_node(np, ind)
		var at := _out.size()
		var nxt := _step(_nodes[nid], pin, ind, scope)
		if commented:
			_comments_below(np.get("after", []), ind, at)
		nid = nxt[0]
		pin = nxt[1]
	for k in visited:
		_path.erase(k)
	return _out.size() > before


## Emits an indented sub-chain for an exec output; writes `pass` if it is empty.
func _sub(nid: int, out_pin: String, ind: int, scope: Dictionary) -> void:
	var tgt := _follow(nid, out_pin)
	_chain_from = nid
	if not _chain(tgt[0], tgt[1], ind, scope.duplicate()):
		_empty_comments(nid, out_pin, ind)
		_line(ind, "pass", nid)


## The comments of a block an imported script wrote with nothing but `pass` in it (p.empty, see COMMENTS), for the
## `pass` written for exec pin `out_pin` of node `nid`.
func _empty_comments(nid: int, out_pin: String, ind: int) -> void:
	var empty: Dictionary = _nodes.get(nid, {}).get("p", {}).get("empty", {})
	if empty.has(out_pin):
		_carry_node(empty[out_pin], ind)


## The Branch that an imported script wrote as an `elif` of Branch `id` (the importer marks it so): the node the
## False pin of `id` leads to, past any reroutes. -1 when it leads to anything else.
func _elif_head(id: int) -> int:
	var tgt := _follow(id, "false")
	var knots := 0
	while _nodes.has(int(tgt[0])) and String(_nodes[int(tgt[0])].kind) == "reroute" and knots < 100:
		tgt = _follow(int(tgt[0]), "o")
		knots += 1
	if not _nodes.has(int(tgt[0])):
		return -1
	var inner: Dictionary = _nodes[int(tgt[0])]
	return int(inner.id) if String(inner.kind) == "branch" and bool(inner.p.get("elif", false)) else -1


## Writes `else:` and, inside it, a Branch that an imported script wrote as an `elif` (see _elif_head) as an `elif`
## again. `at` is where the lines the else of Branch `id` wrote begin (its `else:` line, at indentation `ind`, is
## the one before). It is done only where the text shows it is still an elif: the marked Branch's `if` is the
## first line the else wrote and everything after it belongs to that `if`, and neither line has comment lines
## that would then stand between the branches. Those lines move up one block and the `else:` line goes.
## A Branch made in the editor has no mark, so a graph made there is written exactly as before.
## (With Show Flow and Values on, the trace line of such a Branch is written inside its arms, not above its `if`:
## see _arm_traces.)
func _fold_elif(id: int, ind: int, at: int) -> void:
	var inner_id := _elif_head(id)
	if at < 1 or at >= _out.size() or inner_id == -1:
		return
	var inner: Dictionary = _nodes[inner_id]
	var else_line: Array = _out[at - 1]
	var head: Array = _out[at]
	if else_line.size() > 5 or int(else_line[0]) != ind or String(else_line[1]) != "else:":
		return
	if int(head[0]) != ind + 1 or not String(head[1]).begins_with("if ") or int(head[3]) != int(_origin.get(int(inner.id), int(inner.id))):
		return
	if head.size() > 5 and head[5] is Dictionary and not (head[5] as Dictionary).get("above", []).is_empty():
		return
	for k in range(at + 1, _out.size()):
		var line: Array = _out[k]
		var same_block := int(line[0]) == ind + 1
		var goes_on: bool = line.size() > 4 and line[4] is bool and bool(line[4])   # (the rest of a line that holds a lambda)
		if int(line[0]) < ind + 1 or (same_block and not goes_on and String(line[1]) != "else:" and not String(line[1]).begins_with("elif ")):
			return
	_out.remove_at(at - 1)
	for k in range(at - 1, _out.size()):
		_out[k][0] = int(_out[k][0]) - 1
	_out[at - 1][1] = "el" + String(_out[at - 1][1])


## Like _sub, but runs the chain as a detached coroutine when it contains latent nodes, so the caller
## continues immediately (Sequence / loop semantics from Unreal Blueprints).
func _sub_detached(nid: int, out_pin: String, ind: int, scope: Dictionary, own_block: bool) -> void:
	var tgt := _follow(nid, out_pin)
	# A node marked `wait` runs its pins in order and waits for each, as GDScript does.
	var waits := bool(_nodes[nid].p.get("wait", false)) if _nodes.has(nid) else false
	if tgt[0] != -1 and not waits and _latent_reach(tgt[0]):
		var saved := _loop
		_loop = 0
		_lam += 1
		_line(ind, "(func() -> void:", nid)
		_chain_from = nid
		if not _chain(tgt[0], tgt[1], ind + 1, scope.duplicate()):
			_line(ind + 1, "pass", nid)
		_line(ind, ").call()", nid)
		_lam -= 1
		_loop = saved
	elif own_block:
		_sub(nid, out_pin, ind, scope)
	else:
		_chain_from = nid
		_chain(tgt[0], tgt[1], ind, scope)


func _decl(name: String, type: String, expr: String, ind: int, nid: int, scope: Dictionary) -> void:
	var hk := "%d:%s" % [_gid, name]
	if _hoist.has(hk):
		var hh := T.hint(type)
		var hdef := T.default_literal(type)
		_member("var __%s_g%d%s%s" % [name, _gid, (": " + hh) if hh != "" else "", (" = " + hdef) if not (T.is_object(type) and hh != "") else ""], nid)
		_line(ind, "__%s_g%d = %s" % [name, _gid, expr], nid)
		scope[name] = true
		return
	if scope.has(name):
		_line(ind, "%s = %s" % [name, expr], nid)
		return
	scope[name] = true
	var h := T.hint(type)
	_line(ind, "var %s%s = %s" % [name, (": " + h) if h != "" else "", expr], nid)


func _ovar(n: Dictionary) -> String:
	var p: Dictionary = n.p
	match n.kind:
		"call", "bcall", "call_parent", "dyn_call": return "%s_%d" % [T.ident(String(p.method)).to_lower().trim_prefix("_"), n.id]
		"util": return "%s_%d" % [T.ident(String(p.name)), n.id]
		"call_self": return "%s_%d" % [T.ident(String(p.fn)).to_lower(), n.id]
		"iface_call": return "%s_%d" % [T.ident(String(p.fn)).to_lower().trim_prefix("_"), n.id]
		"cast": return "as_%s_%d" % [T.ident(String(p.cls)).to_snake_case(), n.id]
		"new": return "new_%s_%d" % [T.ident(String(p.cls)).to_snake_case(), n.id]
		"spawn": return "spawned_%d" % n.id
		"table_row": return "row_%d" % n.id
	return "v_%d" % n.id


const STOP := [-1, ""]
## Functions GDScript itself defines (the global scope's are in the API data): a script's own function of
## the same name does not hide them.
const GD_FUNCTIONS := ["assert", "char", "convert", "dict_to_inst", "get_stack", "inst_to_dict", "is_instance_of", "len", "load", "ord",
	"preload", "print_debug", "print_stack", "range", "type_exists"]

func _step(n: Dictionary, pin: String, ind: int, scope: Dictionary) -> Array:
	var id := int(n.id)
	var p: Dictionary = n.p
	var d := _d(n)
	if d.err != "":
		_err(_gid, id, d.err)
		return STOP
	if d.latent and _in_function and not bool(_g.get("latent", false)):
		_err(_gid, id, "Latent nodes (%s) can't be used inside functions. Use the Event Graph or a custom event, or mark the function as one that waits." % d.title)
		return STOP
	for pre_line in p.get("pre", []):
		_line(ind, String(pre_line), id, true)   # @warning_ignore(...) written above the statement in an imported script
	match n.kind:
		"call", "bcall", "util", "call_self", "call_parent", "dyn_call":
			var e := _call_expr(n, scope)
			if bool(p.get("await", false)):
				e = "await " + e
			var has_ret := false
			for o in d.outs:
				if o.type != "exec" and _wired_out(id, o.id):
					has_ret = true
			if has_ret and _feeds_next_store(n, d):
				# "x = f()" is written as that, not as "var t = f()" then "x = t"
				_inline[id] = e
			elif has_ret:
				var rt: String = d.outs[-1].type
				if bool(p.get("await", false)) and n.kind != "call_self":
					rt = "any"   # what a waited-for call hands back is not known until it runs
				if n.kind == "call_self":
					rt = "Array" if _data_outs(d).size() > 1 else _data_outs(d)[0].type
				_decl(_ovar(n), rt, e, ind, id, scope)
			else:
				_line(ind, e, id)
			return _follow(id, "then")
		"dyn_set":
			_line(ind, "%s.%s %s= %s" % [_in(n, "target", scope), T.ident(String(p.name)), String(p.get("op", "")), _in(n, "value", scope)], id)
			return _follow(id, "then")
		"await_value":
			if _wired_out(id, "ret") and _feeds_next_store(n, d):
				# "x = await s" is written as that: the next step stores what was waited for, and nothing else reads it
				_inline[id] = "await " + _in(n, "v", scope)
			elif _wired_out(id, "ret"):
				_decl("awaited_%d" % id, "any", "await " + _in(n, "v", scope), ind, id, scope)
			else:
				_line(ind, "await " + _in(n, "v", scope), id)
			return _follow(id, "then")
		"iface_call":
			# if the target has the function, call it; otherwise the outputs keep their defaults
			var ig := R.interface_function(String(p.get("iface", "")), String(p.get("fn", "")))
			var it := _in(n, "target", scope)
			if not it.is_valid_identifier() and it != "self":
				_decl("target_%d" % id, "Object", it, ind, id, scope)
				it = _scoped("target_%d" % id, n, scope, id)
			var iargs := PackedStringArray()
			for prm in ig.inputs:
				iargs.append(_in(n, "a_" + T.ident(String(prm[0])), scope))
			var icall := "%s.%s(%s)" % [it, T.ident(String(p.fn)), ", ".join(iargs)]
			var iouts := _data_outs(d)
			var iwired := false
			for o in iouts:
				if _wired_out(id, o.id):
					iwired = true
			if iwired:
				if iouts.size() == 1:
					_decl(_ovar(n), String(iouts[0].type), T.default_literal(String(iouts[0].type)), ind, id, scope)
				else:
					var idefs := PackedStringArray()
					for o in iouts:
						idefs.append(T.default_literal(String(o.type)))
					_decl(_ovar(n), "Array", "[%s]" % ", ".join(idefs), ind, id, scope)
				icall = "%s = %s" % [_scoped(_ovar(n), n, scope, id), icall]
			_line(ind, "if is_instance_valid(%s) and %s.has_method(&\"%s\"):" % [it, it, T.ident(String(p.fn))], id)
			_line(ind + 1, icall, id)
			return _follow(id, "then")
		"message":
			var mt := _in(n, "target", scope)
			var mf := _in(n, "fn", scope)
			var margs := PackedStringArray([mf])
			for i in int(p.get("n", 0)):
				margs.append(_in(n, "v%d" % i, scope))
			_line(ind, "if %s.has_method(%s):" % [mt, mf], id)
			_line(ind + 1, "%s.call(%s)" % [mt, ", ".join(margs)], id)
			return _follow(id, "then")
		"set_prop":
			if String(p.get("part", "")) != "" or String(p.get("op", "")) != "":
				var place := _prop_expr(n, scope) + (("." + String(p.part)) if String(p.get("part", "")) != "" else "")
				_line(ind, "%s %s= %s" % [place, String(p.get("op", "")), _in(n, "value", scope)], id)
				return _follow(id, "then")
			var prop_change := _member_change(n, scope)
			if prop_change.is_empty():
				_line(ind, "%s = %s" % [_prop_expr(n, scope), _in(n, "value", scope)], id)
			else:
				_line(ind, "%s.%s = %s" % [_prop_expr(n, scope), prop_change[0], prop_change[1]], id)
			return _follow(id, "then")
		"var_set", "local_set":
			var set_name := T.ident(String(p.name))
			if n.kind == "local_set":
				set_name = String(_rename.get(set_name, set_name))   # a captured value the lambda being written inline changes
			if String(p.get("part", "")) != "" or String(p.get("op", "")) != "":
				var held := set_name + (("." + String(p.part)) if String(p.get("part", "")) != "" else "")
				_line(ind, "%s %s= %s" % [held, String(p.get("op", "")), _in(n, "value", scope)], id)
				return _follow(id, "then")
			var var_change := _member_change(n, scope)
			if var_change.is_empty():
				_line(ind, "%s = %s" % [set_name, _in(n, "value", scope)], id)
			else:
				_line(ind, "%s.%s = %s" % [set_name, var_change[0], var_change[1]], id)
			return _follow(id, "then")
		"set_index":
			_line(ind, "%s[%s] = %s" % [_in(n, "c", scope), _in(n, "k", scope), _in(n, "v", scope)], id)
			return _follow(id, "then")
		"print":
			_line(ind, "print(%s)" % _in(n, "text", scope), id)
			return _follow(id, "then")
		"code":
			var text := String(p.get("code", "pass"))
			for nm in p.get("ins", []):
				text = _replace_word(text, String(nm), _bracketed(_in(n, "x_" + String(nm), scope)))
			var code_lines := text.split("\n")
			var in_string := T.lines_in_string(text)
			var li := 0
			while li < code_lines.size():
				var code_line := code_lines[li]
				var tabs := 0
				while tabs < code_line.length() and code_line[tabs] == "\t":
					tabs += 1
				# a string that runs over several lines is passed on as it is: its lines are part of its value
				var whole := code_line.strip_edges(true, false)
				var runs_on := false
				while li + 1 < code_lines.size() and in_string[li + 1]:
					li += 1
					whole += "\n" + code_lines[li]
					runs_on = true
				if not runs_on:
					whole = whole.strip_edges()
				if whole != "":
					_line(ind + tabs, whole, id)
				li += 1
			return _follow(id, "then")
		"emit":
			var args := PackedStringArray()
			for pi in d.ins:
				if pi.type != "exec":
					args.append(_in(n, pi.id, scope))
			_line(ind, "%s.emit(%s)" % [T.ident(String(p.name)), ", ".join(args)], id)
			return _follow(id, "then")
		"bind_signal", "unbind_signal":
			var tg := _in(n, "target", scope)
			var verb := "connect" if n.kind == "bind_signal" else "disconnect"
			if not _inw.has("%d:fn" % id):
				_err(_gid, id, "Connect an event to the Event pin (drag from it and pick 'Event reference')")
				return _follow(id, "then")
			var fn := _in(n, "fn", scope)
			var sig := ("" if tg == "self" else tg + ".") + String(p.signal)
			if n.kind == "bind_signal":
				_line(ind, "if not %s.is_connected(%s):" % [sig, fn], id)
				_line(ind + 1, "%s.%s(%s)" % [sig, verb, fn], id)
			else:
				_line(ind, "if %s.is_connected(%s):" % [sig, fn], id)
				_line(ind + 1, "%s.%s(%s)" % [sig, verb, fn], id)
			return _follow(id, "then")
		"await_signal":
			var tg := _in(n, "target", scope)
			_line(ind, "await %s%s" % ["" if tg == "self" else tg + ".", p.signal], id)
			return _follow(id, "then")
		"new":
			if _feeds_next_store(n, d) or (bool(p.get("inline", false)) and _feeds_next_step(n)):
				# "x = Thing.new()" is written as that, with no temporary; so is `f(Thing.new())` where an imported
				# script made it in the middle of the next step (the importer marks that `inline`)
				_inline[id] = "%s.new()" % p.cls
			else:
				_decl(_ovar(n), String(p.cls), "%s.new()" % p.cls, ind, id, scope)
			return _follow(id, "then")
		"spawn":
			var v := _ovar(n)
			var scls := _out_type(n, "ret")
			var inst := "(%s as PackedScene).instantiate()" % _in(n, "scene", scope)
			_decl(v, scls, inst if (scls == "Node" or T.hint(scls) == "") else "%s as %s" % [inst, scls], ind, id, scope)
			for pi in d.ins:
				if String(pi.id).begins_with("x_") and (_inw.has("%d:%s" % [id, pi.id]) or n.d.has(pi.id)):
					_line(ind, "%s.set(&\"%s\", %s)" % [v, String(pi.id).trim_prefix("x_"), _in(n, pi.id, scope)], id)
			if _inw.has("%d:xform" % id) or n.d.has("xform"):
				_line(ind, "%s.transform = %s" % [v, _in(n, "xform", scope)], id)
			var par := _in(n, "parent", scope)
			_line(ind, "%sadd_child(%s)" % ["" if par == "self" else par + ".", v], id)
			return _follow(id, "then")
		"branch":
			var arm_traces: Array = _arm_traces.get(id, [])
			_arm_traces.erase(id)
			_line(ind, "if %s:" % _in(n, "cond", scope), id)
			for trace_line in arm_traces:
				_line(ind + 1, String(trace_line), id)
			_sub(id, "true", ind + 1, scope)
			# (an imported `else:` of nothing but `pass` and comments is written for its comments: see COMMENTS)
			if _wired_out(id, "false") or p.get("empty", {}).has("false"):
				_line(ind, "else:", id)
				if String(p.get("else_tail", "")) != "":
					_with_comments(_out[-1], {"tail": String(p.else_tail)})   # the comment an imported script ended its `else:` line with
				var else_at := _out.size()
				var next_elif := _elif_head(id) if bp.get("trace", false) else -1
				if next_elif != -1:
					_arm_traces[next_elif] = arm_traces.duplicate()   # (it adds its own, and its arms begin with them all)
				else:
					for trace_line in arm_traces:
						_line(ind + 1, String(trace_line), id)
				_sub(id, "false", ind + 1, scope)
				_arm_traces.erase(next_elif)
				_fold_elif(id, ind, else_at)
			return STOP
		"sequence":
			var cnt := int(p.get("n", 2))
			var last := -1
			for i in cnt:
				if _wired_out(id, "then_%d" % i):
					last = i
			for i in cnt:
				if not _wired_out(id, "then_%d" % i):
					continue
				if i == last:
					return _follow(id, "then_%d" % i)
				_sub_detached(id, "then_%d" % i, ind, scope, false)
			return STOP
		"for":
			var iv := _loop_var(n, "i_%d" % id, scope)
			var last := _in(n, "last", scope)
			var stop := str(int(last) + 1) if last.is_valid_int() else "%s + 1" % last
			if _counted(last) != "":
				stop = _counted(last)
			var from := _in(n, "first", scope)
			_line(ind, ("for %s in range(%s):" % [iv, stop]) if from == "0" else ("for %s in range(%s, %s):" % [iv, from, stop]), id)
			var body := scope.duplicate()
			body[iv] = true
			body[LOOP_MARK % id] = iv
			_loop += 1
			_sub_detached(id, "body", ind + 1, body, true)
			_loop -= 1
			return _follow(id, "completed")
		"for_each_dict":
			var dk := _loop_var(n, "key_%d" % id, scope)
			_line(ind, "for %s in %s:" % [dk, _in(n, "dict", scope)], id)
			var dbody := scope.duplicate()
			dbody[dk] = true
			dbody[LOOP_MARK % id] = dk
			_loop += 1
			_sub_detached(id, "body", ind + 1, dbody, true)
			_loop -= 1
			return _follow(id, "completed")
		"var_inc":
			_line(ind, "%s %s 1" % [T.ident(String(p.name)), "+=" if int(p.get("by", 1)) > 0 else "-="], id)
			return _follow(id, "then")
		"multigate":
			var q := "__multigate_%d_%d" % [_gid, id]
			var started := q + "_started"
			_member("var %s: Array = []" % q, id)
			_member("var %s: bool = false" % started, id)
			if pin == "reset":
				_line(ind, "%s = []" % q, id)
				_line(ind, "%s = false" % started, id)
				return STOP
			var outs_n := int(p.get("n", 2))
			_line(ind, "if %s.is_empty() and (not %s or %s):" % [q, started, _in(n, "loop", scope)], id)
			_line(ind + 1, "%s = range(0 if %s else clampi(%s, 0, %d), %d)" % [q, started, _in(n, "start", scope), outs_n - 1, outs_n], id)
			_line(ind + 1, "if %s:" % _in(n, "random", scope), id)
			_line(ind + 2, "%s.shuffle()" % q, id)
			_line(ind, "%s = true" % started, id)
			_line(ind, "if not %s.is_empty():" % q, id)
			_line(ind + 1, "match %s.pop_front():" % q, id)
			for i in outs_n:
				_line(ind + 2, "%d:" % i, id)
				_sub(id, "out_%d" % i, ind + 3, scope)
			return STOP
		"for_each":
			if p.get("rev", false):
				var rarr := "arr_%d" % id
				var ridx := "idx_%d" % id
				var ritem := _loop_var(n, "item_%d" % id, scope)
				_decl(rarr, "any", _in(n, "array", scope), ind, id, scope)
				_line(ind, "for %s in range(%s.size() - 1, -1, -1):" % [ridx, rarr], id)
				_line(ind + 1, "var %s = %s[%s]" % [ritem, rarr, ridx], id)
				var rbody := scope.duplicate()
				rbody[ridx] = true
				rbody[ritem] = true
				rbody[LOOP_MARK % id] = ritem
				_loop += 1
				_sub_detached(id, "body", ind + 1, rbody, false)
				_loop -= 1
				return _follow(id, "completed")
			var item := _loop_var(n, "item_%d" % id, scope)
			var idx := "idx_%d" % id
			var use_idx := _wired_out(id, "index")
			if use_idx:
				_decl(idx, "int", "-1", ind, id, scope)
			var h := T.hint(String(p.get("t", "any")))
			if String(p.get("hint", "")) != "":
				h = String(p.hint)   # the type an imported script gave its loop variable, when no pin has that type
			_line(ind, "for %s%s in %s:" % [item, (": " + h) if h != "" else "", _in(n, "array", scope)], id)
			var body := scope.duplicate()
			body[item] = true
			body[LOOP_MARK % id] = item
			if use_idx:
				_line(ind + 1, "%s += 1" % idx, id)
			_loop += 1
			_sub_detached(id, "body", ind + 1, body, not use_idx)
			_loop -= 1
			return _follow(id, "completed")
		"while":
			_line(ind, "while %s:" % _in(n, "cond", scope), id)
			_loop += 1
			_sub_detached(id, "body", ind + 1, scope, true)
			_loop -= 1
			return _follow(id, "completed")
		"loop_break", "loop_continue":
			if _loop <= 0:
				_err(_gid, id, "%s must be inside a loop body (and not after a latent node)" % d.title)
				return STOP
			_line(ind, "break" if n.kind == "loop_break" else "continue", id)
			return STOP
		"delay":
			var flag := "__delay_%d_%d" % [_gid, id]
			_member("var %s: bool = false" % flag, id)
			_line(ind, "if %s:" % flag, id)
			_line(ind + 1, "return", id)
			_line(ind, "%s = true" % flag, id)
			_await_timeout(n, ind, scope)
			_line(ind, "%s = false" % flag, id)
			return _follow(id, "then")
		"retriggerable_delay":
			var ctr := "__rdelay_%d_%d" % [_gid, id]
			var tok := "rdelay_token_%d" % id
			_member("var %s: int = 0" % ctr, id)
			_line(ind, "%s += 1" % ctr, id)
			_decl(tok, "int", ctr, ind, id, scope)
			_await_timeout(n, ind, scope)
			_line(ind, "if %s != %s:" % [tok, ctr], id)
			_line(ind + 1, "return", id)
			return _follow(id, "then")
		"do_once":
			var flag := "__do_once_%d_%d" % [_gid, id]
			_member("var %s: bool = %s" % [flag, _in(n, "closed", scope)], id)
			if pin == "reset":
				_line(ind, "%s = false" % flag, id)
				return STOP
			_line(ind, "if not %s:" % flag, id)
			_line(ind + 1, "%s = true" % flag, id)
			_sub(id, "then", ind + 1, scope)
			return STOP
		"do_n":
			var ctr := "__do_n_%d_%d" % [_gid, id]
			_member("var %s: int = 0" % ctr, id)
			if pin == "reset":
				_line(ind, "%s = 0" % ctr, id)
				return STOP
			_line(ind, "if %s < %s:" % [ctr, _in(n, "n", scope)], id)
			_line(ind + 1, "%s += 1" % ctr, id)
			_sub(id, "then", ind + 1, scope)
			return STOP
		"flip_flop":
			var flag := "__flip_flop_%d_%d" % [_gid, id]
			_member("var %s: bool = false" % flag, id)
			_line(ind, "%s = not %s" % [flag, flag], id)
			_line(ind, "if %s:" % flag, id)
			_sub(id, "a", ind + 1, scope)
			if _wired_out(id, "b"):
				_line(ind, "else:", id)
				_sub(id, "b", ind + 1, scope)
			return STOP
		"gate":
			var flag := "__gate_open_%d_%d" % [_gid, id]
			_member("var %s: bool = not %s" % [flag, _in(n, "closed", scope)], id)
			match pin:
				"open": _line(ind, "%s = true" % flag, id)
				"close": _line(ind, "%s = false" % flag, id)
				"toggle": _line(ind, "%s = not %s" % [flag, flag], id)
				_:
					_line(ind, "if %s:" % flag, id)
					_sub(id, "then", ind + 1, scope)
			return STOP
		"is_valid":
			_line(ind, "if is_instance_valid(%s):" % _in(n, "obj", scope), id)
			_sub(id, "valid", ind + 1, scope)
			if _wired_out(id, "invalid"):
				_line(ind, "else:", id)
				_sub(id, "invalid", ind + 1, scope)
			return STOP
		"cast":
			var v := _ovar(n)
			if not _inw.has("%d:obj" % id):
				_err(_gid, id, "Cast needs an Object input")
				return STOP
			_decl(v, String(p.cls), "%s as %s" % [_in(n, "obj", scope), p.cls], ind, id, scope)
			_line(ind, "if %s != null:" % v, id)
			_sub(id, "then", ind + 1, scope)
			if _wired_out(id, "fail"):
				_line(ind, "else:", id)
				_sub(id, "fail", ind + 1, scope)
			return STOP
		"table_row":
			var rv := _ovar(n)
			var table_expr := ""
			if _inw.has("%d:table" % id):
				table_expr = _in(n, "table", scope)
			elif String(p.get("table", "")) != "":
				table_expr = "preload(\"%s\")" % String(p.table).c_escape()
			else:
				_err(_gid, id, "Get Data Table Row needs a table: set one in Details or wire the Data Table pin")
				return STOP
			var row_cls := String(p.get("cls", "Resource"))
			_decl(rv, row_cls, "%s.get_row(%s)%s" % [table_expr, _in(n, "row", scope), (" as " + row_cls) if (row_cls != "Resource" and T.class_known(row_cls)) else ""], ind, id, scope)
			_line(ind, "if %s != null:" % rv, id)
			_sub(id, "found", ind + 1, scope)
			if _wired_out(id, "not_found"):
				_line(ind, "else:", id)
				_sub(id, "not_found", ind + 1, scope)
			return STOP
		"switch":
			_line(ind, "match %s:" % _in(n, "sel", scope), id)
			var cases: Array = p.get("cases", [])
			for i in cases.size():
				_line(ind + 1, "%s:" % String(cases[i][1]), id)
				_sub(id, "case_%d" % i, ind + 2, _arm_scope(scope, id, "case_%d" % i))
			_line(ind + 1, "_:", id)
			_sub(id, "default", ind + 2, _arm_scope(scope, id, "default"))
			return STOP
		"fn_return":
			var vals := PackedStringArray()
			for pi in d.ins:
				if pi.type != "exec":
					vals.append(_in(n, pi.id, scope))
			if vals.is_empty():
				_line(ind, "return", id)
			elif vals.size() == 1:
				_line(ind, "return " + vals[0], id)
			else:
				_line(ind, "return [%s]" % ", ".join(vals), id)
			return STOP
		"reroute":
			return _follow(id, "o")
		"tpl":
			var t: Dictionary = R.template_of(p)
			if t.get("node", false) and not T.is_a(R.self_class(bp), "Node"):
				_err(_gid, id, "'%s' needs a Node-derived schematic" % d.title)
				return STOP
			var subs := _tpl_subs(n, t, scope)
			for l in t.get("lines", []):
				var text := String(l)
				var extra := 0
				while text.begins_with("\t"):
					text = text.substr(1)
					extra += 1
				_line(ind + extra, text.format(subs), id)
			for o in t.get("outs", []):
				var e := String(t.get("exprs", {}).get(o[0], "null")).format(subs)
				if _wired_out(id, String(o[0])):
					_decl("%s_%d" % [o[0], id], String(o[2]), e, ind, id, scope)
				elif t.get("always", false):
					_line(ind, e, id)
			return _follow(id, "then")
		"timeline":
			if _in_function:
				_err(_gid, id, "Timelines can't be used inside functions. Use the Event Graph.")
				return STOP
			var tl := _tl(n)
			var tlen := T.to_literal(maxf(float(p.get("length", 1.0)), 0.0001))
			match pin:
				"play":
					_line(ind, "%s_dir = 1.0" % tl, id)
					_line(ind, "%s_run()" % tl, id)
				"play_start":
					_line(ind, "%s_time = 0.0" % tl, id)
					_line(ind, "%s_dir = 1.0" % tl, id)
					_line(ind, "%s_run()" % tl, id)
				"reverse":
					_line(ind, "%s_dir = -1.0" % tl, id)
					_line(ind, "%s_run()" % tl, id)
				"reverse_end":
					_line(ind, "%s_time = %s" % [tl, tlen], id)
					_line(ind, "%s_dir = -1.0" % tl, id)
					_line(ind, "%s_run()" % tl, id)
				"stop":
					_line(ind, "%s_playing = false" % tl, id)
				"set_time":
					_line(ind, "%s_time = clampf(%s, 0.0, %s)" % [tl, _in(n, "new_time", scope), tlen], id)
					_line(ind, "%s_sample()" % tl, id)
			return STOP
	_err(_gid, id, "'%s' can't be executed" % (d.title if d.title != "" else n.kind))
	return STOP


func _tree() -> String:
	return "get_tree()" if T.is_a(R.self_class(bp), "Node") else "(Engine.get_main_loop() as SceneTree)"


func _data_outs(d: Dictionary) -> Array:
	return d.outs.filter(func(o): return o.type != "exec")


# ---------------------------------------------------------------- expressions

## Keep only the signal across the suspension. In 4.6 a temporary SceneTreeTimer in the await expression
## can outlive the waiting node when that node is freed before timeout.
## Await the signal on its own so freeing the owner during a delay releases the temporary SceneTreeTimer on 4.6.
func _await_timeout(n: Dictionary, ind: int, scope: Dictionary) -> void:
	var signal_name := "__delay_timeout_%d_%d" % [_gid, int(n.id)]
	_decl(signal_name, "Signal", "%s.create_timer(%s).timeout" % [_tree(), _in(n, "duration", scope)], ind, int(n.id), scope)
	_line(ind, "await " + signal_name, int(n.id))


## Expression for the value arriving at an input pin (wire or inline default).
func _in(n: Dictionary, pid: String, scope: Dictionary) -> String:
	if n.get("split", {}).has(pid):
		# A split struct input: rebuild the struct from its member pins.
		for rp in R.describe_raw(n, bp, _g).ins:
			if rp.id == pid and R.SPLIT.has(String(rp.type)):
				var parts := PackedStringArray()
				for m in R.SPLIT[String(rp.type)][0]:
					parts.append(_in(n, "%s~%s" % [pid, m], scope))
				return "%s(%s)" % [rp.type, ", ".join(parts)]
	var pin := _pin_in(n, pid)
	var key := "%d:%s" % [n.id, pid]
	if _inw.has(key):
		var w: Array = _inw[key]
		var src: Dictionary = _nodes[w[0]]
		_depth += 1
		var e := "null"
		if _depth > 200:
			_err(_gid, n.id, "Data wires form a loop")
		else:
			e = _out_expr(src, w[1], scope, int(n.id))
		_depth -= 1
		if _cur_block != "" and not _origin.has(int(n.id)) and not e.contains(LAM_OPEN):
			# remembered for the debugger, which shows this value on the pin while the game is paused
			var fn_pins: Dictionary = pin_exprs.get_or_add(_cur_block, {})
			var node_pins: Dictionary = fn_pins.get_or_add("%d:%d" % [_gid, int(n.id)], {})
			node_pins[pid] = e
		var from_type := _out_type(src, w[1])
		# A loop walks whatever it is given (a packed array need not be copied into an Array first), and a
		# condition takes an object (null is false) or a number (0 is false) as it is, exactly as hand-written
		# GDScript does.
		if n.kind in ["for_each", "for_each_dict"] and pid in ["array", "dict"]:
			return e
		if String(pin.type) == "bool" and (T.is_object(from_type) or from_type in ["int", "float"]) \
				and (n.kind in ["branch", "while", "select"] or (n.kind == "math" and String(n.p.get("op", "")) in ["and", "or", "not"])):
			return _unbracket(n, pid, src, e)
		# a String given to a StringName or NodePath property is converted by the assignment itself
		if n.kind == "set_prop" and pid == "value" and from_type == "String" and String(pin.type) in ["StringName", "NodePath"]:
			return _unbracket(n, pid, src, e)
		var coerced := T.coerce(e, from_type, pin.type)
		return _unbracket(n, pid, src, e) if coerced == e else coerced
	var lit := String(n.d.get(pid, pin.get("def", "")))
	if lit == "":
		if pin.get("self", false):
			return "self"
		if pid == "target" and T.is_object(pin.type):
			_err(_gid, n.id, "'%s' needs a Target (this schematic is not a %s)" % [_d(n).title, pin.type])
		return T.default_literal(pin.type)
	return lit


## The pins whose value is a whole right-hand side, return value or condition: what is read there needs no
## brackets of its own.
const WHOLE_PINS := {"local_set": ["value"], "var_set": ["value"], "set_prop": ["value"], "dyn_set": ["value"], "set_index": ["v"],
	"branch": ["cond"], "while": ["cond"], "fn_return": ["r_result"]}

## Nodes whose inputs (all but `target`) are written between commas inside brackets, as arguments or items: what
## is read there needs no brackets of its own either.
const LISTED_KINDS := ["call", "bcall", "util", "dyn_call", "call_parent", "call_self", "ctor", "make_array", "make_dict", "print", "emit"]
## Operators that are read from the left: `a - b - c` is `(a - b) - c`.
const LEFT_TO_RIGHT := ["+", "-", "*", "/", "%", "and", "or", "&", "|", "^", "<<", ">>"]

## `e` without the outer brackets the value node `src` writes around it, when an imported script wrote it so (the
## importer marks such a node `unbracketed`) and the place it is read in needs none: it is read whole here
## (WHOLE_PINS), as an argument or item (LISTED_KINDS) or an index, or by an operator that it binds tighter than
## (_binds_tighter). `e` as it is otherwise.
## A graph made in the editor never has the mark, so it is written exactly as before.
func _unbracket(n: Dictionary, pid: String, src: Dictionary, e: String) -> String:
	if not bool(src.p.get("unbracketed", false)):
		return e
	if e.length() < 2 or e[0] != "(" or not _closes_at_end(e):
		return e
	return e.substr(1, e.length() - 2) if reads_bare(src, n, pid) else e


## True when value node `src`, read on pin `pid` of node `n`, needs no brackets around what it writes there.
static func reads_bare(src: Dictionary, n: Dictionary, pid: String) -> bool:
	var kind := String(n.kind)
	return WHOLE_PINS.get(kind, []).has(pid) or (kind in LISTED_KINDS and pid != "target") or (kind in ["index", "set_index"] and pid == "k") \
		or _binds_tighter(src, n, pid)


## The operator an operator node writes, as [operator, how tightly it binds (the parser's scale), true for one
## with a single operand]; [] for any other node.
static func _operator_of(n: Dictionary) -> Array:
	var op := String(n.p.get("op", ""))
	if String(n.kind) == "math":
		return ["not", Parser.PREC_NOT, true] if op == "not" else [op, int(Parser.BINARY.get(op, 0)), false]
	if String(n.kind) != "op":
		return []
	if String(n.p.get("r", "")) != "":
		return [op, int(Parser.BINARY.get(op, 0)), false]
	match op:
		"not": return ["not", Parser.PREC_NOT, true]
		"unary-": return ["-", Parser.PREC_SIGN, true]
		"unary~": return ["~", Parser.PREC_BIT_NOT, true]
	return []


## True when operator node `src`, read on pin `pid` of operator node `n`, means the same without brackets around
## it: its operator binds tighter than the one of `n`, or as tightly on the left side of one read from the left.
static func _binds_tighter(src: Dictionary, n: Dictionary, pid: String) -> bool:
	var inner := _operator_of(src)
	var outer := _operator_of(n)
	if inner.is_empty() or outer.is_empty() or int(inner[1]) == 0 or int(outer[1]) == 0:
		return false
	if int(inner[1]) > int(outer[1]):
		return true
	return int(inner[1]) == int(outer[1]) and pid in ["a0", "a"] and not bool(inner[2]) and not bool(outer[2]) \
		and String(inner[0]) in LEFT_TO_RIGHT and String(outer[0]) in LEFT_TO_RIGHT


## Replaces every whole-word use of `word` in GDScript text, leaving string literals, comments and `.member` names alone.
static func _replace_word(text: String, word: String, with: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if quote != "":
			out += c
			if c == "\\" and i + 1 < n:
				i += 1
				out += text[i]
			elif c == quote:
				quote = ""
			i += 1
			continue
		if c == "\"" or c == "'":
			quote = c
			out += c
			i += 1
			continue
		if c == "#":
			# a comment, to the end of its line: no word in it is a use, and a quote in it (the director's) opens no string
			var nl := text.find("\n", i)
			if nl == -1:
				nl = n
			out += text.substr(i, nl - i)
			i = nl
			continue
		if text.substr(i, word.length()) == word:
			var before := text[i - 1] if i > 0 else " "
			var after := text[i + word.length()] if i + word.length() < n else " "
			var is_word := func(ch: String) -> bool: return ch == "_" or ch.is_valid_int() or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")
			if not is_word.call(before) and before != "." and not is_word.call(after):
				out += with
				i += word.length()
				continue
		out += c
		i += 1
	return out


## An expression put in place of a name in text (a code or expression node's input): in brackets, so that the
## operators around the name cannot take it apart, unless it holds together already (a name, a plain string, or
## something in brackets of its own; a number stays in brackets: `(2).x` is not `2.x`).
static func _bracketed(e: String) -> String:
	var s := e.strip_edges()
	if s.is_valid_identifier():
		return s
	if s.length() >= 2 and s[0] in ["\"", "'"] and s[-1] == s[0] and not s.substr(1, s.length() - 2).contains(s[0]) and not s.contains("\\"):
		return s
	if s.length() >= 2 and s[0] in ["(", "[", "{"] and _closes_at_end(s):
		return s
	return "(%s)" % e


## True when the bracket that opens `s` is closed by its last character (strings skipped).
static func _closes_at_end(s: String) -> bool:
	var depth := 0
	var quote := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if quote != "":
			if c == "\\":
				i += 1
			elif c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
			if depth == 0:
				return i == s.length() - 1
		i += 1
	return false


## What a loop variable is called inside its loop (the scope holds it under LOOP_MARK); outside it, the numbered
## name, which _scoped reports as not available there.
func _loop_ref(src: Dictionary, numbered: String, scope: Dictionary, consumer: int) -> String:
	var mark := LOOP_MARK % int(src.id)
	if scope.has(mark):
		return String(scope[mark])
	return _scoped(numbered, src, scope, consumer)


## The name a loop node's variable is written with: the one the imported script gave it (`p.var`), as written,
## unless GDScript would refuse it or read something else by it here: a name declared already where the loop is
## (an outer loop's variable, a value the compiler stored), a local of the generated function (declared at its top,
## a loop variable may not shadow it), a parameter, a member the function reads or writes by name (inside the
## loop the name would mean the loop variable), or the numbered name the compiler gives another loop. Then, and
## for a loop made in the editor (no `var`), it is `numbered` (i_12, item_12, key_12), as before.
func _loop_var(n: Dictionary, numbered: String, scope: Dictionary) -> String:
	var w := String(n.p.get("var", ""))
	if w == "" or w == numbered:
		return numbered
	if not w.is_valid_identifier() or w in KEYWORDS or w.begins_with("__") or scope.has(w):
		return numbered
	for l in _g.locals:
		if T.ident(String(l.name)) == w:
			return numbered
	if String(_g.kind) == "function":
		for inp in _g.inputs:
			if T.ident(String(inp[0])) == w:
				return numbered
	var entry: Dictionary = _nodes.get(_entry_id, {})
	if not entry.is_empty():
		for po in _d(entry).outs:
			if String(po.id).trim_prefix("p_") == w:
				return numbered
		for given in entry.get("p", {}).get("names", []):
			if String(given) == w:
				return numbered
	if not is_same(_lv_nodes, _nodes):
		_lv_nodes = _nodes
		_lv_taken = {}
		for other in _nodes.values():
			match String(other.kind):
				"var_get", "var_set", "var_inc":
					_lv_taken[T.ident(String(other.p.get("name", "")))] = true
				"for", "for_each", "for_each_dict":
					if String(other.p.get("var", "")) == "":
						for stem in ["i", "item", "key"]:
							_lv_taken["%s_%d" % [stem, int(other.id)]] = true
					if String(other.kind) == "for_each":
						_lv_taken["idx_%d" % int(other.id)] = true
						_lv_taken["arr_%d" % int(other.id)] = true
	return numbered if _lv_taken.has(w) else w


func _scoped(name: String, src: Dictionary, scope: Dictionary, consumer: int) -> String:
	var hk := "%d:%s" % [_gid, name]
	if _hoist.has(hk):
		return "__%s_g%d" % [name, _gid]
	if not scope.has(name):
		var is_loop_var := name.begins_with("i_") or name.begins_with("item_") or name.begins_with("idx_") or name.begins_with("key_")
		if _pass2 or is_loop_var:
			_err(_gid, consumer, "The value from '%s' isn't available on this execution path (that node hasn't run here)" % _title(src))
		else:
			var outs := _data_outs(_d(src))
			_want[hk] = String(outs[0].type) if not outs.is_empty() else "any"
		return T.default_literal("any")
	return name


## The scope for the nodes under one case of a Match: the scope the Match is in, plus a mark (not a name a
## variable could have) that says which case of which Match the code being written is inside.
func _arm_scope(scope: Dictionary, match_id: int, arm: String) -> Dictionary:
	var inside := scope.duplicate()
	inside["\u0001arm %d:%s" % [match_id, arm]] = true
	return inside


## A "name node" (a const the converter made to stand for a parameter of an event or function, or for a name a
## Match case binds: `p.of` says where the name belongs) is only written where that name exists. Returns "" when
## it does, else the message. A const without `p.of` (made in the editor, or saved before this) is never checked,
## and nor is one that came out of an expanded macro: its `of` is that of the graph the macro was made from.
func _name_place(src: Dictionary, scope: Dictionary) -> String:
	var p: Dictionary = src.p
	var nm := String(p.get("expr", ""))
	var home: Variant = _nodes.get(int(p.of))
	var bound := bool(p.get("bound", false))
	var elsewhere: bool = p.has("in") and int(p["in"]) != _gid
	if bound:
		if elsewhere or home == null or home.kind != "switch":
			return "'%s' was a name set by a Match case that is not in this graph any more." % nm
		if not scope.has("\u0001arm %d:%s" % [int(p.of), String(p.get("arm", ""))]):
			return "'%s' is a name set by one case of a Match. It can only be read inside that case." % nm
		return ""
	if elsewhere or home == null or not home.kind in ["event", "custom_event", "signal_event", "fn_entry"]:
		return "'%s' was a parameter of an event or function that is not in this graph any more." % nm
	if int(p.of) != _entry_id:
		return "'%s' is a parameter of %s. It can only be read by nodes that run from that event." % [nm, _title(home)]
	return ""


func _title(n: Dictionary) -> String:
	var d := _d(n)
	return d.title if d.title != "" else String(n.kind)


func _out_expr(src: Dictionary, pin: String, scope: Dictionary, consumer: int) -> String:
	if pin.contains("~"):   # member of a split struct output
		return "%s.%s" % [_out_expr(src, pin.get_slice("~", 0), scope, consumer), pin.get_slice("~", 1)]
	var p: Dictionary = src.p
	var d := _d(src)
	if d.err != "":
		_err(_gid, src.id, d.err)
		return "null"
	match src.kind:
		"reroute":
			return _in(src, "i", scope)
		"event", "custom_event", "signal_event", "fn_entry":
			if int(src.id) != _entry_id:
				var pk := "%d:p%d_%s" % [_gid, int(src.id), pin.trim_prefix("p_")]
				if _hoist.has(pk):
					return "__p%d_%s_g%d" % [int(src.id), pin.trim_prefix("p_"), _gid]
				if _pass2:
					_err(_gid, consumer, "'%s' is an output of a different event and can't be read here" % pin.trim_prefix("p_"))
				else:
					_want[pk] = _out_type(src, pin)
				return "null"
			var param_name := _event_pin_name(src, pin.trim_prefix("p_"))
			return String(_rename.get(param_name, param_name)) if src.kind == "fn_entry" else param_name
		"var_get", "var_set":
			return T.ident(String(p.name))
		"local_get", "local_set":
			var local_name := T.ident(String(p.name))
			return String(_rename.get(local_name, local_name))
		"set_prop", "get_prop":
			return _prop_expr(src, scope)
		"self":
			return "self"
		"get_node":
			var path := String(p.get("path", "."))
			if path == ".":
				return "self"
			var e := "get_node(^\"%s\")" % path.c_escape()
			var cls := String(p.get("cls", "Node"))
			return "(%s as %s)" % [e, cls] if (cls != "Node" and T.hint(cls) != "") else e
		"const":
			if p.has("of") and not _origin.has(int(src.id)):
				var misplaced := _name_place(src, scope)
				if misplaced != "":
					_err(_gid, int(src.id), misplaced)
					return "null"
			if p.has("of") and not bool(p.get("bound", false)) and _rename.has(String(p.expr)):
				return String(_rename[String(p.expr)])   # a parameter of the lambda being written inline that it captured
			return String(p.expr)
		"closure":
			var as_lambda := _lambda_from_closure(src, scope)
			if as_lambda != "":
				return as_lambda
			var cg := Model.graph_named(bp, String(p.fn))
			var own := mini(int(p.get("n", 0)), cg.inputs.size())
			var heads := PackedStringArray()
			var passed := PackedStringArray()
			for i in own:
				var inp: Array = cg.inputs[i]
				heads.append(T.ident(String(inp[0])) + ((" = " + String(inp[2])) if (inp.size() > 2 and String(inp[2]) != "") else ""))
				passed.append(T.ident(String(inp[0])))
			for i in range(own, cg.inputs.size()):
				passed.append(_in(src, "c%d" % (i - own), scope))
			return "(func(%s): %s%s(%s))" % [", ".join(heads), "" if cg.outputs.is_empty() else "return ", T.ident(String(p.fn)), ", ".join(passed)]
		"dyn_get":
			return "%s.%s" % [_in(src, "target", scope), T.ident(String(p.name))]
		"is_type":
			return "(%s is %s)" % [_in(src, "v", scope), p.type]
		"as_type":
			return "(%s as %s)" % [_in(src, "v", scope), p.type]
		"await_value":
			if _inline.has(int(src.id)):
				return String(_inline[int(src.id)])
			return _scoped("awaited_%d" % src.id, src, scope, consumer)
		"event_ref":
			var lg: Dictionary = _lam_graphs.get(String(p.fn), {})
			if not lg.is_empty() and int(lg.lambda) == 0 and not _origin.has(int(src.id)) and _outw.get("%d:fn" % int(src.id), []).size() == 1:
				var made := _inline_lambda(lg, [], [], scope)
				if made != "":
					return made
			if not lg.is_empty():
				_lam_failed[String(p.fn)] = true   # referred to as a function after all: it is written as one
				if not lambda_notes.has(String(p.fn)):
					lambda_notes[String(p.fn)] = "its reference (or the Bind of what it captures) is inside a macro or used twice" if _origin.has(int(src.id)) or int(lg.lambda) == 0 \
						else "it is bound to values that are not all simply what it captures (or inside a macro)"
			return T.ident(String(p.fn))
		"op":
			var op := String(p.op)
			if String(p.get("r", "")) == "":
				return "(%s%s)" % ["not " if op == "not" else op.trim_prefix("unary"), _in(src, "a", scope)]
			return "(%s %s %s)" % [_in(src, "a", scope), op, _in(src, "b", scope)]
		"ctor":
			var args := PackedStringArray()
			for pi in d.ins:
				args.append(_in(src, pi.id, scope))
			return "%s(%s)" % [p.type, ", ".join(args)]
		"break":
			return "%s.%s" % [_in(src, "v", scope), pin.trim_prefix("m_")]
		"select":
			return "(%s if %s else %s)" % [_in(src, "a", scope), _in(src, "pick", scope), _in(src, "b", scope)]
		"make_dict":
			var pairs := PackedStringArray()
			for i in int(p.get("n", 1)):
				pairs.append("%s: %s" % [_in(src, "k%d" % i, scope), _in(src, "v%d" % i, scope)])
			return "{%s}" % ", ".join(pairs)
		"make_array":
			var items := PackedStringArray()
			for pi in d.ins:
				items.append(_in(src, pi.id, scope))
			return "[%s]" % ", ".join(items)
		"index":
			return "%s[%s]" % [_in(src, "c", scope), _in(src, "k", scope)]
		"expr":
			# written straight into the line (no call): each input name is replaced by what is wired to it
			var expr_text := String(p.get("code", "null"))
			for nm in p.get("ins", []):
				expr_text = _replace_word(expr_text, T.ident(String(nm)), _bracketed(_in(src, "x_" + String(nm), scope)))
			return "(%s)" % expr_text
		"tpl":
			var t: Dictionary = R.template_of(p)
			if d.pure:
				if t.get("node", false) and not T.is_a(R.self_class(bp), "Node"):
					_err(_gid, src.id, "'%s' needs a Node-derived schematic" % d.title)
					return "null"
				return String(t.get("exprs", {}).get(pin, "null")).format(_tpl_subs(src, t, scope))
			return _scoped("%s_%d" % [pin, src.id], src, scope, consumer)
		"autoload":
			return T.ident(String(p.get("name", "")))
		"timeline":
			if pin == "time":
				return _tl(src) + "_time"
			return _tl(src) + "_" + pin.trim_prefix("t_")
		"flip_flop":
			return "__flip_flop_%d_%d" % [_gid, src.id]
		"do_n":
			return "__do_n_%d_%d" % [_gid, src.id]
		"for":
			return _loop_ref(src, "i_%d" % src.id, scope, consumer)
		"for_each":
			if pin == "element":
				return _loop_ref(src, "item_%d" % src.id, scope, consumer)
			return _scoped("idx_%d" % src.id, src, scope, consumer)
		"for_each_dict":
			var dkey := _loop_ref(src, "key_%d" % src.id, scope, consumer)
			return dkey if pin == "key" else "%s[%s]" % [_in(src, "dict", scope), dkey]
		"var_inc":
			return T.ident(String(p.name))
		"math":
			var mop := String(p.get("op", "+"))
			if mop == "not":
				return "(not %s)" % _in(src, "a0", scope)
			var parts := PackedStringArray()
			for pi in d.ins:
				parts.append(_in(src, pi.id, scope))
			return "(%s)" % (" %s " % mop).join(parts)
		"format":
			var fargs := PackedStringArray()
			for nm in R.format_args(String(p.get("text", ""))):
				fargs.append("\"%s\": %s" % [nm, _in(src, "f_" + String(nm), scope)])
			return "%s.format({%s})" % [var_to_str(String(p.get("text", ""))), ", ".join(fargs)]
		"make_data":
			var mcls := T.ident(String(p.cls))
			var names := PackedStringArray()
			var mlines := [[1, "var made: %s = %s.new()" % [mcls, mcls], 0, 0]]
			var margs := PackedStringArray()
			for fld in R.data_fields(String(p.cls)):
				names.append(T.ident(String(fld[0])))
				mlines.append([1, "made.%s = %s" % [T.ident(String(fld[0])), T.ident(String(fld[0]))], 0, 0])
				margs.append(_in(src, "f_" + String(fld[0]), scope))
			mlines.append([1, "return made", 0, 0])
			_helpers["__sc_make_" + mcls] = ["func __sc_make_%s(%s) -> %s:" % [mcls, ", ".join(names), mcls], mlines]
			return "__sc_make_%s(%s)" % [mcls, ", ".join(margs)]
		"cast", "new", "spawn", "table_row":
			if src.kind == "cast" and p.get("pure", false):
				var cast_expr := "(%s as %s)" % [_in(src, "obj", scope), p.cls]
				return cast_expr if pin == "as" else "(%s != null)" % cast_expr
			if src.kind == "new" and _inline.has(int(src.id)):
				return String(_inline[int(src.id)])
			return _scoped(_ovar(src), src, scope, consumer)
		"call", "bcall", "util", "call_parent", "dyn_call":
			if d.pure:
				return ("(await %s)" % _call_expr(src, scope)) if bool(p.get("await", false)) else _call_expr(src, scope)
			if _inline.has(int(src.id)):
				return String(_inline[int(src.id)])
			return _scoped(_ovar(src), src, scope, consumer)
		"call_self":
			var outs := _data_outs(d)
			var idx := 0
			for i in outs.size():
				if outs[i].id == pin:
					idx = i
			var base := _call_expr(src, scope) if d.pure else (String(_inline[int(src.id)]) if _inline.has(int(src.id)) else _scoped(_ovar(src), src, scope, consumer))
			if d.pure and bool(p.get("await", false)):
				base = "(await %s)" % base
			return base if outs.size() <= 1 else "%s[%d]" % [base, idx]
		"iface_call":
			var iouts := _data_outs(d)
			var iidx := 0
			for i in iouts.size():
				if iouts[i].id == pin:
					iidx = i
			var ibase := _scoped(_ovar(src), src, scope, consumer)
			return ibase if iouts.size() <= 1 else "%s[%d]" % [ibase, iidx]
		"iface_has":
			return "%s.implemented_by(%s)" % [T.ident(String(p.get("iface", ""))), _in(src, "target", scope)]
	_err(_gid, consumer, "Can't read a value from '%s'" % _title(src))
	return "null"


func _tpl_subs(n: Dictionary, t: Dictionary, scope: Dictionary) -> Dictionary:
	var subs := {"id": str(int(n.id))}   # {id} makes a name unique to this node
	for pi in _d(n).ins:
		if pi.type != "exec":
			subs[pi.id] = _in(n, pi.id, scope)
	if t.has("helper"):
		var lines := []
		for l in t.helper[2]:
			lines.append([int(l[0]), String(l[1]), 0, 0])
		_helpers[String(t.helper[0])] = [String(t.helper[1]), lines]
	return subs


## True when a call's result goes down exactly one wire, straight into the value pin of the Set or Return
## node that runs next. Then nothing can come between the call and the store, and no temporary is needed.
## True when what node `n` gives is read once, by the step that comes straight after it (no split pin, no
## value kept for another execution path).
func _feeds_next_step(n: Dictionary) -> bool:
	var id := int(n.id)
	var wired := []
	for k in _outw:
		if String(k).begins_with("%d:" % id):
			if String(k).contains("~"):
				return false
			for dst in _outw[k]:
				if String(k).get_slice(":", 1) != "then":
					wired.append(dst)
	if wired.size() != 1 or _hoist.has("%d:%s" % [_gid, _ovar(n)]):
		return false
	var next := _follow(id, "then")
	return int(next[0]) == int(wired[0][0]) and String(next[1]) == "exec"


func _feeds_next_store(n: Dictionary, d: Dictionary) -> bool:
	var id := int(n.id)
	if n.kind == "call_self" and _data_outs(d).size() != 1:
		return false
	var wired := []
	for o in d.outs:
		if o.type == "exec":
			continue
		var prefix := "%d:%s~" % [id, o.id]
		for k in _outw:
			if String(k).begins_with(prefix):
				return false   # a split pin
		for dst in _outw.get("%d:%s" % [id, o.id], []):
			wired.append(dst)
	if wired.size() != 1:
		return false
	var next := _follow(id, "then")
	var cid := int(wired[0][0])
	if int(next[0]) != cid or String(next[1]) != "exec" or not _nodes.has(cid):
		return false
	if _hoist.has("%d:%s" % [_gid, ("awaited_%d" % id) if n.kind == "await_value" else _ovar(n)]):
		return false
	var c: Dictionary = _nodes[cid]
	var pin := String(wired[0][1])
	match String(c.kind):
		"var_set", "local_set":
			return pin == "value"
		"set_prop":
			return pin == "value" and not _inw.has("%d:target" % cid)
		"fn_return":
			return _d(c).ins.filter(func(pi): return pi.type != "exec").size() == 1
	return false


## When the value stored is "what is already there, with one member replaced" (Make Vector3 fed by Break
## Vector3 of the same variable or property, one pin wired to something else), returns [member, expression]
## so the compiler can write `position.y = ...` instead of building a whole new value. [] otherwise.
func _member_change(n: Dictionary, scope: Dictionary) -> Array:
	var key := "%d:value" % int(n.id)
	if not _inw.has(key) or n.get("split", {}).has("value"):
		return []
	var made: Dictionary = _nodes[_inw[key][0]]
	if made.kind != "ctor" or not R.SPLIT.has(String(made.p.get("type", ""))):
		return []
	var names: Array = R.SPLIT[String(made.p.type)][0]
	if _d(made).ins.size() != names.size():
		return []
	var changed := -1
	for i in names.size():
		var pin_key := "%d:a%d" % [int(made.id), i]
		var kept := false
		if _inw.has(pin_key):
			var src: Dictionary = _nodes[_inw[pin_key][0]]
			kept = src.kind == "break" and String(_inw[pin_key][1]) == "m_" + String(names[i]) and _reads_place(src, n)
		if not kept:
			if changed != -1:
				return []   # two members change at once: the new value has to be built whole
			changed = i
	if changed == -1:
		return []
	return [String(names[changed]), _in(made, "a%d" % changed, scope)]


## Does this Break node take apart the very variable or property that `store` writes to?
func _reads_place(brk: Dictionary, store: Dictionary) -> bool:
	var key := "%d:v" % int(brk.id)
	if not _inw.has(key):
		return false
	var getter: Dictionary = _nodes[_inw[key][0]]
	match String(store.kind):
		"var_set":
			return getter.kind == "var_get" and String(getter.p.get("name", "")) == String(store.p.get("name", ""))
		"local_set":
			return getter.kind == "local_get" and String(getter.p.get("name", "")) == String(store.p.get("name", ""))
		"set_prop":
			if getter.kind != "get_prop" or String(getter.p.get("prop", "")) != String(store.p.get("prop", "")):
				return false
			return _same_value("%d:target" % int(getter.id), "%d:target" % int(store.id), getter, store, 0)
	return false


## True when what is wired to an input pin can be worked out a second time without changing anything. Show Flow and
## Values reads a wired input once more to show it on the pin, so it only shows the ones this is true of: a random
## number would come out different (and move the sequence on), `queue.pop_back()` would take a second item.
## Safe: variables, the result of a step that already ran, operators, properties, and calls the engine marks as
## changing nothing. Not safe: a call written to run in place (the converter's `f(g())`), an await, anything random,
## and code carried over as text that makes a call.
func _repeat_safe(nid: int, pin_id: String, depth: int) -> bool:
	var key := "%d:%s" % [nid, pin_id]
	if not _inw.has(key):
		return true   # the pin's own value
	if depth > 24:
		return false
	var src: Dictionary = _nodes[_inw[key][0]]
	var sid := int(src.id)
	if _inline.has(sid):
		return false   # written straight into the line that uses it
	if String(src.kind) == "reroute":
		return _repeat_safe(sid, "i", depth + 1)
	var d := _d(src)
	if not d.pure:
		return true   # a step that ran before this one: its result is in a variable
	var p: Dictionary = src.get("p", {})
	match String(src.kind):
		"call", "bcall", "util", "call_parent", "dyn_call", "call_self":
			if bool(p.get("inline", false)) or bool(p.get("await", false)):
				return false
			if src.kind == "util" and String(R.util(String(p.get("name", ""))).get("c", "")) == "random":
				return false
			if String(p.get("method", "")).contains("random"):
				return false
		"expr":
			if String(p.get("code", "")).contains("("):
				return false
		"tpl":
			for text in R.template_of(p).get("exprs", {}).values():
				if String(text).contains("rand") or String(text).contains("await "):
					return false
		"await_value":
			return false
	for pin in d.ins:
		if pin.type != "exec" and not _repeat_safe(sid, String(pin.id), depth + 1):
			return false
	return true


## Two input pins that are sure to carry the same value: both unwired with the same default, the same wire,
## or wires from side-effect-free getters that are themselves the same all the way down.
func _same_value(key_a: String, key_b: String, node_a: Dictionary, node_b: Dictionary, depth: int) -> bool:
	if not _inw.has(key_a) and not _inw.has(key_b):
		return String(node_a.d.get(key_a.get_slice(":", 1), "")) == String(node_b.d.get(key_b.get_slice(":", 1), ""))
	if not _inw.has(key_a) or not _inw.has(key_b) or depth > 8:
		return false
	var wa: Array = _inw[key_a]
	var wb: Array = _inw[key_b]
	if int(wa[0]) == int(wb[0]):
		return String(wa[1]) == String(wb[1])
	var a: Dictionary = _nodes[wa[0]]
	var c: Dictionary = _nodes[wb[0]]
	if a.kind != c.kind or String(wa[1]) != String(wb[1]) or not a.kind in ["get_prop", "var_get", "local_get", "get_node", "self", "break", "autoload"]:
		return false
	if str(a.p) != str(c.p) or str(a.d) != str(c.d):
		return false
	for pin in _d(a).ins:
		if not _same_value("%d:%s" % [int(a.id), pin.id], "%d:%s" % [int(c.id), pin.id], a, c, depth + 1):
			return false
	return true


func _prop_expr(n: Dictionary, scope: Dictionary) -> String:
	var tg := _in(n, "target", scope)
	return String(n.p.prop) if tg == "self" else "%s.%s" % [tg, n.p.prop]


func _call_expr(n: Dictionary, scope: Dictionary) -> String:
	var p: Dictionary = n.p
	if n.kind == "bcall" and String(p.get("type", "")) == "Callable" and String(p.get("method", "")) == "bind":
		var as_lambda := _lambda_from_bind(n, scope)
		if as_lambda != "":
			return as_lambda
	var d := _d(n)
	var pins: Array = d.ins.filter(func(pi): return pi.type != "exec" and pi.id != "target")
	# Drop trailing arguments that are still at their declared default.
	while not pins.is_empty():
		var lastp: Dictionary = pins[-1]
		if lastp.has("def") and not _inw.has("%d:%s" % [n.id, lastp.id]) and not n.d.has(lastp.id) and not String(lastp.id).begins_with("v"):
			pins.pop_back()
		else:
			break
	var args := PackedStringArray()
	for pi in pins:
		args.append(_in(n, pi.id, scope))
	var arg_s := ", ".join(args)
	match n.kind:
		"call":
			var m := R.find_method(p.cls, p.method)
			# (a singleton reached through something the script calls, such as its own get_editor(), is still
			# reached that way: the call it makes may do more than hand the singleton back)
			if (int(m.get("flags", 0)) & METHOD_FLAG_STATIC) or (R.is_singleton(p.cls) and not _inw.has("%d:target" % int(n.id))):
				if String(p.cls).begins_with("\""):
					# a script known only by its path: its static function is the schematic's own when it extends
					# that script, and is reached through the loaded script otherwise
					if T.is_a(R.self_class(bp), String(p.cls)):
						return "%s(%s)" % [p.method, arg_s]
					return "preload(%s).%s(%s)" % [p.cls, p.method, arg_s]
				return "%s.%s(%s)" % [p.cls, p.method, arg_s]
			var tg := _in(n, "target", scope)
			if tg == "self" and bool(p.get("self", false)):
				return "self.%s(%s)" % [p.method, arg_s]   # an imported script wrote `self.` here
			return "%s(%s)" % [p.method, arg_s] if tg == "self" else "%s.%s(%s)" % [tg, p.method, arg_s]
		"bcall":
			var m := R.builtin_method(p.type, p.method)
			if bool(m.get("s", false)):
				return "%s.%s(%s)" % [p.type, p.method, arg_s]
			return "%s.%s(%s)" % [_in(n, "target", scope), p.method, arg_s]
		"util":
			return "%s(%s)" % [p.name, arg_s]
		"dyn_call":
			return "%s.%s(%s)" % [_in(n, "target", scope), T.ident(String(p.method)), arg_s]
		"call_parent":
			return "super.%s(%s)" % [p.method, arg_s] if String(p.method) != _blocks_current_name() else "super(%s)" % arg_s
		"call_self":
			# Replicated custom events are sent over the network (and also run locally).
			var rpc_mode := String(Model.find_custom_event(bp, String(p.fn)).get("p", {}).get("rpc", ""))
			match rpc_mode:
				"multicast":
					return "%s.rpc(%s)" % [T.ident(String(p.fn)), arg_s]
				"server":
					return "%s.rpc_id(1%s)" % [T.ident(String(p.fn)), (", " + arg_s) if arg_s != "" else ""]
				"owner":
					return "%s.rpc_id(get_multiplayer_authority()%s)" % [T.ident(String(p.fn)), (", " + arg_s) if arg_s != "" else ""]
			# a function named like one of GDScript's own (log, range, print ...) is only reached through self
			var own_fn := T.ident(String(p.fn))
			# (and an imported script that wrote `self.` there keeps it)
			if (GD_FUNCTIONS.has(own_fn) or not R.util(own_fn).is_empty() or bool(p.get("self", false))) and not bool(_g.get("static", false)):
				return "self.%s(%s)" % [own_fn, arg_s]
			return "%s(%s)" % [own_fn, arg_s]
	return "null"


func _blocks_current_name() -> String:
	var e: Dictionary = _nodes.get(_entry_id, {})
	return String(e.get("p", {}).get("name", "")) if e.get("kind", "") == "event" else ""


## The name the parameter behind an entry node's output pin (`engine_name`, the pin id without its "p_") has
## in the code: for an event of a converted script, the name that script gave it.
func _event_pin_name(n: Dictionary, engine_name: String) -> String:
	if String(n.get("kind", "")) == "event" and n.get("p", {}).has("names"):
		var m := R.find_method(R.self_class(bp), String(n.p.name))
		for ai in m.get("args", []).size():
			if T.ident(String(m.args[ai].name)) == engine_name:
				return _event_arg(n, ai, String(m.args[ai].name))
	return engine_name


## The name an event's parameter has in its header: the one the script it came from gave it (kept on the node
## by the importer), else the engine's own.
func _event_arg(n: Dictionary, index: int, engine_name: String) -> String:
	var names: Array = n.get("p", {}).get("names", [])
	if index < names.size() and String(names[index]).is_valid_identifier():
		return String(names[index])
	return T.ident(engine_name)
