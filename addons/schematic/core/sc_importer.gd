@tool
extends RefCounted
## Turns a hand-written GDScript into a Schematic: members become variables and dispatchers, engine callbacks
## become events, other functions become function graphs, and each statement becomes nodes. A statement it
## cannot express as nodes is carried over unchanged in a "GDScript" code node, so the result always behaves
## like the source; the report says how much went each way.
##
##   var imp := Importer.new()
##   var out := imp.convert(source, {"path": "res://player.gd"})   # -> {bp, report, lines, writers}
##   report = {lines, as_nodes, as_code, notes: [String]}
##   lines   = {graph id: {node id: line}}: for every node a statement became (its execution node, the data nodes
##             feeding it, a code node it was kept as), the 1-based line in `source` of that statement (in a lambda's
##             graph, the line its parser gave the statement: within the lambda's text, 0 for a one-line lambda).
##             Nodes of no statement (entry nodes, reroute nodes the layout adds) are not listed.
##   writers = {graph id: {node id: line}}: the first node each statement became (the one the path enters it by),
##             with the same line. Two-way editing (core/sc_sync.gd) uses both to tell which nodes belong to which
##             line. They are kept out of the schematic itself: nothing saved depends on them.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Parser := preload("res://addons/schematic/core/sc_gd_parser.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

const FAR := 900.0     # further than this from the entry node, a parameter is read through a node of its own
const ROUTE_DROP := 100.0    # an execution wire that goes this far down...
const ROUTE_REACH := 420.0   # ...and this far right is given a reroute node
const ROUTE_STEP := 235.0    # how far right of the node it leaves that reroute node stands
const COL := 290.0     # horizontal step between a node and the node feeding it
const ROW := 135.0     # vertical step between data nodes of one statement
const CONSTANTS := {"PI": "float", "TAU": "float", "INF": "float", "NAN": "float"}
## What GDScript's `breakpoint` statement becomes: an execution node whose line is `breakpoint`. The node carries
## its template itself (p.t, see SCRegistry.template_of), so the registry needs no entry for it.
const BREAKPOINT := {"title": "Breakpoint", "cat": "Utilities|Debug", "search": "debugger stop pause break",
	"tip": "Stops the running game in the debugger here (GDScript's breakpoint). Does nothing when no debugger is attached.",
	"ins": [], "outs": [], "lines": ["breakpoint"]}
## Enums of the global scope: a variable of one of these types starts at 0, not at null.
const GLOBAL_ENUMS := ["Side", "Corner", "Orientation", "ClockDirection", "HorizontalAlignment", "VerticalAlignment", "InlineAlignment",
	"EulerOrder", "Key", "KeyModifierMask", "KeyLocation", "MouseButton", "MouseButtonMask", "JoyButton", "JoyAxis", "MIDIMessage", "Error",
	"PropertyHint", "PropertyUsageFlags", "MethodFlags"]

var bp: Dictionary
var notes: Array = []
var lines_total := 0
var lines_code := 0

var _cls := ""                 # parent class
var _members: Dictionary = {}  # name -> type
var _typed_members: Dictionary = {}  # members whose type the script declares
var _alias: Dictionary = {}    # @onready name -> {path, cls}
var _raw: Dictionary = {}      # member name -> its declaration exactly as written
var _consts: Dictionary = {}   # constant name -> type
var _const_init: Dictionary = {}
var _enum_names: Dictionary = {}  # enum or inner class name -> true when it is a class
var _assigned: Dictionary = {}
var _funcs: Dictionary = {}    # name -> {params: [[name, type]], ret, event: bool}
var _signals: Dictionary = {}  # name -> params
var _nodes_cls: Dictionary = {}  # node path -> class (from the scene that uses the script)
var _conn_params: Dictionary = {}  # method -> [types] (from scene signal connections)

var _g: Dictionary             # graph being filled
var _is_fn := false
var _entry: Dictionary
var _scope: Dictionary = {}    # name -> {k: local|param|pin, t, name / n, pin}
var _cursor: Array = []        # [node, exec out pin] the next exec node hangs off; [] when the path has ended
var _pending: Array = []       # data nodes of the statement being lowered: [node, depth]
var _cx := 0.0
var _cy := 0.0
var _low := 0.0
var _failed := ""              # why the statement being lowered could not become nodes
var _inline_mode := 0          # > 0 while lowering something that must run where it is read (right of `and`, a later argument...)
var _awaits := false           # the function being lowered waits somewhere
var _last_call: Dictionary = {}  # the call node _finish made last
var _lambda_queue: Array = []  # lambdas found while lowering, each to become a function graph: [{f, graph}]
var _fn_name := ""             # the function or event being lowered
var _keep_step := false        # the value being lowered goes straight into a Set or Return node: a call there stays a step
var _clash: Dictionary = {}    # names used both for a local and for a loop variable in the function being lowered
var _clash_abort := false      # a statement kept as text mentions one of them: the function is kept whole instead
var _loop_depth := 0           # how many loops the statement being lowered is inside
var _synthetic_fail := ""      # why a part of an if made from an expression statement could not become nodes
var _decls: Dictionary = {}    # local name -> how many times the function being lowered declares it
var _event_names: Dictionary = {}   # name -> how many events declare it (a local, a parameter or a loop variable)
var _source := ""              # the script being converted
var _inferred_members: Dictionary = {}   # members declared with := (statically typed by their value)
var _setget: Dictionary = {}   # members declared with set / get: reading one may run code
var _last_exec: Dictionary = {}   # the execution node added to the path last (see _block: where `after` comments go)
var _src_lines: Dictionary = {}   # graph id -> {node id: line of its statement} (returned as `lines`, see the top)
var _src_writers: Dictionary = {}   # graph id -> {node id: line}: each statement's first node (returned as `writers`)
var _src_top: Dictionary = {}   # graph id -> the highest node id recorded in those two


## True for a note that only says how something became nodes (a lambda became a function, a signal's Call
## node got a pin): worth having in a full report, not something the person converting has to act on.
static func is_detail(note: String) -> bool:
	return note.begins_with("a lambda in ") or note.contains("is emitted with more arguments") or note.begins_with("expression kept as a Math Expression node")


# ---------------------------------------------------------------- entry point

func convert(source: String, opts := {}) -> Dictionary:
	R.ensure_api()
	_source = source
	_src_lines = {}
	_src_writers = {}
	_src_top = {}
	var parser := Parser.new()
	var ast := parser.parse(source)
	notes = parser.notes.duplicate()
	_nodes_cls = opts.get("nodes", {}).duplicate()
	_conn_params = opts.get("params", {}).duplicate()
	var parent := String(ast.extends) if String(ast.extends) != "" else "RefCounted"
	if parent.ends_with(".gd") and not parent.begins_with("res://") and String(opts.get("path", "")) != "":
		parent = String(opts.path).get_base_dir().path_join(parent).simplify_path()   # a path beside the script
	if parent.begins_with("res://"):
		# a parent named by its path: by its class name if it has one, else by the path, as written
		# (by its class name only when that name means this very file: a project can hold a second script that
		# declares the same name, and then the name is the other file)
		var base := (load(parent) as Script) if ResourceLoader.exists(parent) else null
		var known_as := String(base.get_global_name()) if base != null else ""
		if known_as != "" and String(T.globals().get(known_as, {}).get("path", "")) == parent:
			parent = known_as
		elif base != null:
			parent = "\"%s\"" % parent
		else:
			notes.append("extends %s, which is not in this project: the schematic extends Node" % parent)
			parent = "Node"
	_cls = parent
	var cn := String(opts.get("class_name", ast.class_name))
	bp = Model.new_schematic(parent, cn)
	bp.tool = bool(ast.tool)
	if bool(ast.crlf):
		bp["crlf"] = true
	if not ast.class_pre.is_empty():
		bp["class_pre"] = ast.class_pre.duplicate()   # @icon(...) and the like, written above the class
	# the script's own comments: above the class (note), its doc comment (description), after everything (end_note)
	if not ast.head_note.is_empty():
		bp["note"] = ast.head_note.duplicate()
	if String(ast.description) != "":
		bp.description = String(ast.description)
	if not ast.end_note.is_empty():
		bp["end_note"] = ast.end_note.duplicate()
	var eg: Dictionary = bp.graphs[0]
	eg.nodes.clear()
	eg.next_id = 1
	if String(opts.get("path", "")) != "":
		_read_scenes(String(opts.path), ast)

	# enums, constants and inner classes are carried over exactly as written; the graphs refer to them by name
	var extra := PackedStringArray()
	for en in ast.enums:
		if String(en.name) != "":
			_enum_names[String(en.name)] = bool(en.get("class", false))
		else:
			for value in en.values:
				_consts[String(value)] = "int"
	for text in ast.extra:
		extra.append(String(text))
	# an @abstract function has no body to make a graph of: its declaration is carried over as written
	var with_body := []
	for f in ast.funcs:
		if not bool(f.get("abstract", false)):
			with_body.append(f)
			continue
		var decl := PackedStringArray(f.get("pre", []))
		var header := String(f.text)
		decl.append(("static " if bool(f.get("static", false)) else "") + header.substr(maxi(header.find("func "), 0)) + String(f.get("tail", "")))
		extra.append(_with_note(f, "\n".join(decl)))
		notes.append("abstract function kept as written: %s" % f.name)
	ast.funcs = with_body
	_assigned = {}
	for f in ast.funcs:
		_scan_targets(f.body)
	_declare_functions(ast)
	_declare_members(ast)
	for v in ast.vars:
		if bool(v.const):
			extra.append(_with_note(v, String(v.get("text_tail", v.text))))   # (carried as written: its comments in its text)
	if not extra.is_empty():
		bp["extra_code"] = "\n".join(extra)
	_infer_member_types(ast)
	if _float_params(ast):
		_infer_member_types(ast)
	_declare_signals(ast)
	_fill_variables(ast)

	_low = 0.0
	var graphs := {}
	for f in ast.funcs:
		var fi: Dictionary = _funcs[String(f.name)]
		if not bool(fi.event):
			var fg := Model.new_graph(bp, String(f.name), "function")
			fg.inputs = fi.params.duplicate(true)
			if String(fi.ret) != "":
				fg.outputs = [["result", String(fi.ret)]]
			if bool(f.get("static", false)):
				fg["static"] = true
			if not f.get("pre", []).is_empty():
				fg["pre"] = f.pre.duplicate()
			if String(f.ret) != "void" and _loses(String(f.ret)):
				fg["ret_hint"] = String(f.ret)   # a return type the schematic has no pin type for: kept in the signature
				fg["ret_default"] = ("(0 as %s)" % String(f.ret)) if _is_enum_type(String(f.ret)) else "null"
			elif String(f.ret) == "":
				# Written without a return type: other scripts may use what it returns (nothing, which reads as
				# null), which a stated "void" would forbid. The signature stays as it was written.
				fg["ret_hint"] = "-"
			fg.nodes.remove_at(1)
			_entry_comments(fg.nodes[0], f)
			graphs[String(f.name)] = fg
	# The events share one graph, and so its locals: a name only one event declares keeps the name the script gave
	# it; one that several declare (as a local, a parameter or a loop variable) needs a local per event.
	_event_names = {}
	for f in ast.funcs:
		if _funcs[String(f.name)].event:
			var own := {}
			_count_decls(f.body, own)
			var loops := {}
			_collect_names(f.body, loops, {})
			own.merge(loops)
			for prm in f.params:
				own[String(prm.name)] = 1
			for nm in own:
				_event_names[nm] = int(_event_names.get(nm, 0)) + 1
	for f in ast.funcs:
		if _funcs[String(f.name)].event:
			_event(eg, f)
	for f in ast.funcs:
		if not _funcs[String(f.name)].event:
			_function(f, graphs[String(f.name)])
	# lambdas are functions of the schematic; one lambda may hold another
	while not _lambda_queue.is_empty():
		var item: Dictionary = _lambda_queue.pop_front()
		_function(item.f, item.graph)
	for g in bp.graphs:
		_route_wires(g)
	# The schematic exactly as it is when read back from its file (the fields a loaded one always has, and
	# numbers as the file gives them), so that the file written now is the file the editor writes when it is
	# opened and saved with nothing changed.
	var as_read: Variant = JSON.parse_string(JSON.stringify(bp))
	if as_read is Dictionary:
		bp = Model.normalize(as_read)
	return {"bp": bp, "report": {"lines": lines_total, "as_nodes": lines_total - lines_code, "as_code": lines_code, "notes": notes},
		"lines": _src_lines, "writers": _src_writers}


## A declaration carried over as written, with the comment lines written above it (its `note`).
static func _with_note(decl: Dictionary, text: String) -> String:
	var note: Array = decl.get("note", [])
	return text if note.is_empty() else "\n".join(PackedStringArray(note)) + "\n" + text


## Tidies the execution wires that drop to a lower row a long way to the right (what follows an if, the
## else of a branch, the cases of a match, what comes after a loop): each gets a reroute node under the node
## it leaves, level with the node it reaches, so it goes down first and then runs along that row instead of
## cutting across the nodes in between. Only where a wire goes changes; the script is the same.
func _route_wires(g: Dictionary) -> void:
	var by_id := {}
	for n in g.nodes:
		by_id[int(n.id)] = n
	var described := {}
	var count: int = g.wires.size()
	for wi in count:
		var w: Array = g.wires[wi]
		var a: Dictionary = by_id.get(int(w[0]), {})
		var b: Dictionary = by_id.get(int(w[2]), {})
		if a.is_empty() or b.is_empty() or String(w[3]) != "exec":
			continue
		if float(b.y) - float(a.y) < ROUTE_DROP or float(b.x) - float(a.x) < ROUTE_REACH:
			continue
		if not described.has(int(b.id)):
			described[int(b.id)] = R.describe(b, bp, g)
		var d: Dictionary = described[int(b.id)]
		# where the target's execution pin is, below its top: lower when the node has a line under its title
		var pin_y := 84.0 if String(d.get("sub", "")) != "" else 54.0
		var knot := Model.add_node(g, "reroute", Vector2(float(a.x) + ROUTE_STEP, float(b.y) + pin_y - 13.0), {"t": "exec"})
		by_id[int(knot.id)] = knot
		g.wires[wi] = [int(a.id), String(w[1]), int(knot.id), "i"]
		g.wires.append([int(knot.id), "o", int(b.id), "exec"])


# ---------------------------------------------------------------- declarations

func _declare_functions(ast: Dictionary) -> void:
	for f in ast.funcs:
		var info := R.find_method(_cls, String(f.name))
		var is_event: bool = not info.is_empty() and bool(int(info.get("flags", 0)) & METHOD_FLAG_VIRTUAL) \
			and T.from_info(info.get("return", {}), true) == "" and info.args.size() == f.params.size()
		var params := []
		for i in f.params.size():
			var prm: Dictionary = f.params[i]
			var pt := _norm(String(prm.type))
			if pt == "" and is_event:
				pt = T.from_info(info.args[i])
			if pt == "" and _conn_params.has(String(f.name)) and i < _conn_params[String(f.name)].size():
				pt = String(_conn_params[String(f.name)][i])
			if pt == "" and prm.default != null and bool(prm.get("infer", false)):   # only ":=" states a type
				pt = _type(prm.default)
			var entry := [String(prm.name), pt if pt != "" else "any"]
			if prm.default != null:
				entry.append(Parser.unparse(prm.default))
			if _loses(String(prm.type)) or (String(prm.type) == "Variant" and not is_event):
				entry[1] = "any"
				while entry.size() < 3:
					entry.append("")
				entry.append(String(prm.type))   # a type the schematic has no pin type for (or `Variant`): kept in the signature
			if bool(prm.get("rest", false)):
				# ...args: the further arguments of a call, as an array; written back the same way
				entry = [String(prm.name), "Array", "", "..." + String(prm.type)]
			elif String(prm.type) == "" and not is_event:
				# Written without a type: it takes whatever a caller passes, and so it does after conversion.
				# The pin may show the type the script always uses it with; the signature does not state one.
				while entry.size() < 3:
					entry.append("")
				entry.append(":=" if bool(prm.get("infer", false)) else "-")
			params.append(entry)
		var required := 0
		for prm in f.params:
			if prm.default == null:
				required += 1
		if is_event and (bool(f.get("static", false)) or not f.get("pre", []).is_empty()):
			is_event = false
		_funcs[String(f.name)] = {"params": params, "ret": _norm(String(f.ret)), "event": is_event, "void": String(f.ret) == "void", "required": required,
			"declared_ret": _norm(String(f.ret))}


## An untyped parameter that every call inside the script feeds a float (delta, typically) is typed float.
## Only float is inferred: an int from another script still fits it, where a narrower guess could break callers.
func _float_params(ast: Dictionary) -> bool:
	var seen := {}   # "fn:index" -> widened type of the arguments passed
	for f in ast.funcs:
		_scope = {}
		for prm in _funcs[String(f.name)].params:
			_scope[String(prm[0])] = {"k": "param", "t": String(prm[1])}
		_local_types(f.body)
		_scan_calls(f.body, seen)
	_scope = {}
	var changed := false
	for f in ast.funcs:
		var fi: Dictionary = _funcs[String(f.name)]
		if bool(fi.event):
			continue
		for i in fi.params.size():
			var declared := String(f.params[i].type) != "" or f.params[i].default != null
			if not declared and String(fi.params[i][1]) == "any" and String(seen.get("%s:%d" % [f.name, i], "")) == "float" \
					and not _conn_params.has(String(f.name)):
				fi.params[i][1] = "float"
				changed = true
	if changed:
		for nm in _members:
			if String(_members[nm]) == "any" and not _typed_members.has(nm):
				_members[nm] = ""
	return changed


## Names of the script's own functions whose result is read somewhere (a call that is a statement of its own
## reads nothing).
func _scan_used_results(node: Variant, used: Dictionary) -> void:
	if node is Array:
		for it in node:
			_scan_used_results(it, used)
	elif node is Dictionary:
		if node.get("k", "") == "expr" and node.get("e") is Dictionary:
			var inner: Dictionary = node.e
			while inner.get("k", "") in ["paren", "await"] and inner.get("a") is Dictionary:
				inner = inner.a
			if inner.get("k", "") == "call":
				_scan_used_results(inner.args, used)
				if inner.fn is Dictionary and inner.fn.get("k", "") == "attr":
					_scan_used_results(inner.fn.obj, used)
				return
		if node.get("k", "") == "call" and node.get("fn") is Dictionary:
			if node.fn.get("k", "") == "name":
				used[String(node.fn.v)] = true
			elif node.fn.get("k", "") == "attr" and node.fn.obj is Dictionary and node.fn.obj.get("k", "") == "self":
				used[String(node.fn.name)] = true
		for key in node:
			if node[key] is Array or node[key] is Dictionary:
				_scan_used_results(node[key], used)


func _scan_calls(node: Variant, seen: Dictionary) -> void:
	if node is Array:
		for it in node:
			_scan_calls(it, seen)
	elif node is Dictionary:
		if node.get("k", "") == "call" and node.fn is Dictionary and node.fn.get("k", "") == "name" and _funcs.has(String(node.fn.v)):
			for i in node.args.size():
				var key := "%s:%d" % [node.fn.v, i]
				seen[key] = _widen(String(seen.get(key, "")), _type(node.args[i]))
		for key in node:
			if node[key] is Array or node[key] is Dictionary:
				_scan_calls(node[key], seen)


func _declare_members(ast: Dictionary) -> void:
	for v in ast.vars:
		var nm := String(v.name)
		if bool(v.const):
			_consts[nm] = _norm(String(v.type)) if String(v.type) != "" else ""
			_const_init[nm] = v.init
			continue
		if bool(v.get("setget", false)):
			_setget[nm] = true
		if bool(v.get("infer", false)):
			_inferred_members[nm] = true
		var declared := _norm(String(v.type))
		var known := declared == "" or declared == "any" or T.hint(declared) == declared
		if bool(v.onready) and bool(v.plain) and v.init != null and (v.init.k == "node" or _is_get_node(v.init)) and not _assigned.has(nm) and known:
			# a node shortcut that is never reassigned: every use becomes a node reference
			var path := String(v.init.path) if v.init.k == "node" else String(v.init.args[0].v).trim_prefix("^").trim_prefix("&").trim_prefix("\"").trim_suffix("\"")
			var cls := declared
			if cls == "" or cls == "any":
				cls = String(_nodes_cls.get(path, "Node"))
			# It stays a variable set once when the node is ready (a lookup per use would be slower than the script
			# was); the scene tells the graph what kind of node it holds.
			_members[nm] = cls
			_typed_members[nm] = true
			_raw[nm] = String(v.text)
			continue
		_members[nm] = declared if known else "any"
		if String(v.type) != "":
			_typed_members[nm] = true
		# Anything the variable list can't express (annotations with arguments, set / get, static, @onready
		# values, types the schematic has no pin for) keeps its declaration exactly as written.
		if not bool(v.plain) or bool(v.onready) or not known or bool(v.get("has_raw", false)) or (bool(ast.get("uses_groups", false)) and bool(v.export)):
			_raw[nm] = String(v.text)
	for nm in _consts:
		if String(_consts[nm]) == "":
			var ct := _type(_const_init.get(nm))
			_consts[nm] = ct if ct != "" else "any"


## Names that are assigned somewhere in the script (a node shortcut that is reassigned must stay a variable).
func _has_lambda(node: Variant) -> bool:
	if node is Array:
		for it in node:
			if _has_lambda(it):
				return true
	elif node is Dictionary:
		if String(node.get("k", "")) == "lambda":
			return true
		for key in node:
			if (node[key] is Array or node[key] is Dictionary) and not key in ["body", "branches", "else", "arms"] and _has_lambda(node[key]):
				return true
	return false


func _scan_targets(body: Array) -> void:
	var names := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	for st in body:
		if String(st.k) in ["var", "assign", "expr", "return"] and _has_lambda(st):
			# what a lambda assigns is not followed here: be careful with every name the statement mentions
			for m in names.search_all(String(st.get("text", st.get("line_src", st.src)))):
				_assigned[m.get_string()] = true
		match String(st.k):
			"assign":
				var t: Variant = st.target
				while t != null and t.k in ["attr", "index"]:
					t = t.obj
				if t != null and t.k == "name":
					_assigned[String(t.v)] = true
			"if":
				for br in st.branches:
					_scan_targets(br[1])
				_scan_targets(st["else"])
			"for", "while":
				_scan_targets(st.body)
			"match":
				for arm in st.arms:
					_scan_targets(arm.body)
			"raw":
				# carried-over code may assign anything: be careful with every name it mentions
				var re := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
				for m in re.search_all(String(st.get("text", st.src))):
					_assigned[m.get_string()] = true


func _is_get_node(e: Variant) -> bool:
	return e != null and e.k == "call" and e.fn.k == "name" and e.fn.v == "get_node" and e.args.size() == 1 and e.args[0] != null and e.args[0].k == "str"


## Untyped members take the type every assignment in the script agrees on; disagreement leaves them untyped.
## That includes a variable that starts as the int 0 and is later given floats: typed float it would start
## as 0.0, and -0.0 is not what the script computes with -0.
func _infer_member_types(ast: Dictionary) -> void:
	var fixed := {}
	for nm in _members:
		if String(_members[nm]) != "":
			fixed[nm] = true
	# `var x := value` is statically typed by its value; a plain `var x = value` starts from it
	for pass_no in 2:
		for v in ast.vars:
			var nm := String(v.name)
			if _members.has(nm) and not fixed.has(nm) and v.init != null:
				var it := _type(v.init)
				_members[nm] = it if (it != "any" or pass_no == 1) else ""
				if bool(v.get("infer", false)) and it != "any":
					fixed[nm] = true
	for round in 3:
		var seen := {}
		for v in ast.vars:
			var nm := String(v.name)
			if _members.has(nm) and not fixed.has(nm) and v.init != null:
				seen[nm] = _widen(String(seen.get(nm, "")), _type(v.init))
		for f in ast.funcs:
			_scope = {}
			for prm in _funcs[String(f.name)].params:
				_scope[String(prm[0])] = {"k": "param", "t": String(prm[1])}
			_scan_assignments(f.body, seen, fixed)
		for nm in seen:
			_members[nm] = String(seen[nm])
	for nm in _members:
		if String(_members[nm]) == "":
			_members[nm] = "any"
	# functions without a declared return type: take it from their return statements
	var used_results := {}
	_scan_used_results(ast.funcs, used_results)
	for f in ast.funcs:
		var fi: Dictionary = _funcs[String(f.name)]
		if String(fi.ret) == "" and not bool(fi.void) and not bool(fi.event):
			_scope = {}
			for prm in fi.params:
				_scope[String(prm[0])] = {"k": "param", "t": String(prm[1])}
			_local_types(f.body)
			# no declared type: a function that returns values returns a Variant, exactly as the script does
			# (one that returns nothing, but whose result the script reads all the same, hands back null)
			fi.ret = "any" if (_return_type(f.body) != "" or used_results.has(String(f.name))) else ""
			# ...and one that overrides an engine callback hands back what that callback does (the pin shows that
			# type; the signature stays without one, as it was written)
			var above := R.find_method(_cls, String(f.name))
			if not above.is_empty() and bool(int(above.get("flags", 0)) & METHOD_FLAG_VIRTUAL):
				var rt := T.from_info(above.get("return", {}), true)
				if rt != "" and above.args.size() == f.params.size():
					fi.ret = rt
		if String(fi.ret) == "void":
			fi.ret = ""
	_scope = {}


func _scan_assignments(body: Array, seen: Dictionary, fixed: Dictionary) -> void:
	for st in body:
		match String(st.k):
			"var":
				var lt := _norm(String(st.type))
				if lt == "" and st.init != null:
					lt = _type(st.init)
				_scope[String(st.name)] = {"k": "local", "t": lt if lt != "" else "any"}
			"assign":
				if st.target.k == "name" and _members.has(String(st.target.v)) and not fixed.has(String(st.target.v)) and not _scope.has(String(st.target.v)):
					var nm := String(st.target.v)
					var vt := _type(st.value)
					if st.op != "=":
						vt = _op_type(String(seen.get(nm, _members[nm])), String(st.op).trim_suffix("="), vt)
					seen[nm] = _widen(String(seen.get(nm, "")), vt)
			"if":
				for br in st.branches:
					_scan_assignments(br[1], seen, fixed)
				_scan_assignments(st["else"], seen, fixed)
			"for":
				_scope[String(st["var"])] = {"k": "pin", "t": _iter_type(st.iter)}
				_scan_assignments(st.body, seen, fixed)
			"while":
				_scan_assignments(st.body, seen, fixed)
			"match":
				for arm in st.arms:
					_scan_assignments(arm.body, seen, fixed)


func _return_type(body: Array) -> String:
	var out := ""
	for st in body:
		match String(st.k):
			"return":
				if st.e != null:
					out = _widen(out, _type(st.e))
			"if":
				for br in st.branches:
					out = _widen(out, _return_type(br[1]))
				out = _widen(out, _return_type(st["else"]))
			"for", "while":
				out = _widen(out, _return_type(st.body))
			"match":
				for arm in st.arms:
					out = _widen(out, _return_type(arm.body))
	return out


func _widen(cur: String, new: String) -> String:
	if new == "":
		return cur
	if cur == "" or cur == new:
		return new
	if T.is_object(cur) and T.is_object(new):
		if T.is_a(new, cur):
			return cur
		if T.is_a(cur, new):
			return new
	return "any"


func _declare_signals(ast: Dictionary) -> void:
	var declared_counts := {}
	var signal_pre := {}
	var signal_comments := {}   # name -> {note, tail}: the comments written above and at the end of its line
	for s in ast.signals:
		var params := []
		for prm in s.params:
			var entry := [String(prm[0]), _norm(String(prm[1])) if String(prm[1]) != "" else "any"]
			if _loses(String(prm[1])):
				entry = [String(prm[0]), "any", "", String(prm[1])]   # a type the schematic has no pin type for: kept in the signature
			params.append(entry)
		_signals[String(s.name)] = params
		declared_counts[String(s.name)] = params.size()
		if not s.get("pre", []).is_empty():
			signal_pre[String(s.name)] = s.pre.duplicate()
		for field in ["note", "tail"]:
			if s.has(field):
				signal_comments.get_or_add(String(s.name), {})[field] = s[field]
	# GDScript lets a signal be emitted with more arguments than it declares; dispatchers need them declared
	for f in ast.funcs:
		_scope = {}
		for prm in _funcs[String(f.name)].params:
			_scope[String(prm[0])] = {"k": "param", "t": String(prm[1])}
		_local_types(f.body)
		_scan_emits(f.body)
	_scope = {}
	for nm in _signals:
		var dispatcher := {"name": nm, "params": _signals[nm]}
		if signal_pre.has(nm):
			dispatcher["pre"] = signal_pre[nm]
		dispatcher.merge(signal_comments.get(nm, {}))
		if declared_counts.has(nm) and int(declared_counts[nm]) < _signals[nm].size():
			# emitted with more than it declares: the Call node has a pin for each, the declaration stays as written
			dispatcher["declared"] = int(declared_counts[nm])
		bp.dispatchers.append(dispatcher)


func _scan_emits(body: Array) -> void:
	for st in body:
		if st.k == "expr" and st.e.k == "call" and st.e.fn.k == "attr" and st.e.fn.name == "emit" and st.e.fn.obj.k == "name" and _signals.has(String(st.e.fn.obj.v)):
			var params: Array = _signals[String(st.e.fn.obj.v)]
			for i in range(params.size(), st.e.args.size()):
				params.append(["arg%d" % i, _type(st.e.args[i])])
				notes.append("signal %s is emitted with more arguments than it declares: its Call node has a pin for each (arg%d), the declaration stays as written" % [st.e.fn.obj.v, i])
		elif st.k == "if":
			for br in st.branches:
				_scan_emits(br[1])
			_scan_emits(st["else"])
		elif st.k in ["for", "while"]:
			_scan_emits(st.body)
		elif st.k == "match":
			for arm in st.arms:
				_scan_emits(arm.body)


func _fill_variables(ast: Dictionary) -> void:
	for v in ast.vars:
		var nm := String(v.name)
		if not _members.has(nm):
			continue
		var entry := {"name": nm, "type": String(_members[nm]), "default": String(v.init_src) if v.init != null else "", "export": bool(v.export),
			"category": String(v.group), "tooltip": ""}
		# declared as the script declared it (see the compiler): the type above is only what the pins show
		if String(v.type) == "":
			entry["written"] = "infer" if bool(v.get("infer", false)) else "untyped"
		if bool(v.export) and not _raw.has(nm) and (T.hint(String(entry.type)) == "" or String(entry.type) in ["Callable", "Signal", "RID"]):
			# `@export var hp = 2` exports by its value; the variable list would need a type to export it
			_raw[nm] = String(v.text)
		if _raw.has(nm):
			entry["raw"] = String(v.get("text_tail", _raw[nm]))   # kept as written: the comment at the end of its line in its text
		elif String(v.get("tail", "")) != "":
			entry["tail"] = String(v.tail)
		if not v.get("note", []).is_empty():
			entry["note"] = v.note.duplicate()
		bp.variables.append(entry)


## Node classes for $paths and parameter types for signal callbacks, read from the scenes that use the
## script. Scenes are read through their stored state, not instantiated, so nothing in them runs.
static var _scene_index: Dictionary = {}   # script path -> [scene paths]
static var _scene_index_built := false


static func reset_scene_index() -> void:
	_scene_index.clear()
	_scene_index_built = false


func _read_scenes(script_path: String, _ast: Dictionary) -> void:
	if not _scene_index_built:
		_scene_index_built = true
		_index_scenes("res://")
	for scene_path in _scene_index.get(script_path, []).slice(0, 4):
		var packed := load(scene_path) as PackedScene
		if packed == null:
			continue
		var nodes := {}   # path from the scene root -> {cls, script}
		_collect(packed.get_state(), "", nodes, 0)
		var owners := []
		for path in nodes:
			if String(nodes[path].script) == script_path:
				owners.append(String(path))
		for owner_path in owners:
			var prefix = "" if owner_path == "." else owner_path + "/"
			for path in nodes:
				var rel := ""
				if owner_path == "." and String(path) != ".":
					rel = String(path)
				elif String(path).begins_with(prefix) and prefix != "":
					rel = String(path).substr(prefix.length())
				if rel != "" and not _nodes_cls.has(rel):
					_nodes_cls[rel] = String(nodes[path].cls)
		var state := packed.get_state()
		for i in state.get_connection_count():
			var to := String(state.get_connection_target(i))
			var from := String(state.get_connection_source(i))
			var method := String(state.get_connection_method(i))
			if not owners.has(to) or not nodes.has(from) or _conn_params.has(method):
				continue
			var info := R.find_signal(String(nodes[from].cls), String(state.get_connection_signal(i)))
			if not info.is_empty():
				var types := []
				for a in R.signal_args(info):
					types.append(String(a[1]))
				_conn_params[method] = types


func _collect(state: SceneState, prefix: String, out: Dictionary, depth: int) -> void:
	if state == null or depth > 6:
		return
	for i in state.get_node_count():
		var rel := String(state.get_node_path(i)).trim_prefix("./")   # "./Child" and "Child" are the same node
		var path := rel if prefix == "" else (prefix if rel == "." else prefix + "/" + rel)
		var cls := String(state.get_node_type(i))
		var script_path := ""
		for pi in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, pi)) == "script":
				var scr: Variant = state.get_node_property_value(i, pi)
				if scr is Script:
					script_path = (scr as Script).resource_path
					if (scr as Script).get_global_name() != &"":
						cls = String((scr as Script).get_global_name())
		var inst := state.get_node_instance(i)
		if inst != null:
			var sub := {}
			_collect(inst.get_state(), path, sub, depth + 1)
			if sub.has(path):
				if cls == "":
					cls = String(sub[path].cls)
				if script_path == "":
					script_path = String(sub[path].script)
			for key in sub:
				if not out.has(key):
					out[key] = sub[key]
		if cls == "" and out.has(path):
			continue   # an override of a node that an instanced scene already described
		out[path] = {"cls": cls if cls != "" else "Node", "script": script_path}


static func _index_scenes(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# another project kept inside this one is not part of this project
	if dir_path != "res://" and dir.file_exists("project.godot"):
		return
	for f in dir.get_files():
		if f.get_extension() != "tscn":
			continue
		var text := FileAccess.get_file_as_string(dir_path.path_join(f))
		var at := text.find("type=\"Script\"")
		while at != -1:
			var line_end := text.find("\n", at)
			var line := text.substr(at, line_end - at)
			var ps := line.find("path=\"")
			if ps != -1:
				var script_path := line.substr(ps + 6, line.find("\"", ps + 6) - ps - 6)
				if not _scene_index.has(script_path):
					_scene_index[script_path] = []
				if not _scene_index[script_path].has(dir_path.path_join(f)):
					_scene_index[script_path].append(dir_path.path_join(f))
			at = text.find("type=\"Script\"", line_end)
	for sub in dir.get_directories():
		if not sub.begins_with(".") and sub != "addons":
			_index_scenes(dir_path.path_join(sub))


# ---------------------------------------------------------------- types

func _norm(t: String) -> String:
	return "any" if t == "Variant" else t


## True when a type written in the script says more than any pin type can (an enum, an inner class, a typed
## array or dictionary of them): the declaration keeps the written type.
func _loses(written: String) -> bool:
	var t := _norm(written)
	return t != "" and t != "any" and T.hint(t) != t


func _op_type(l: String, op: String, r: String) -> String:
	if op in ["==", "!=", "<", ">", "<=", ">=", "and", "or", "in"]:
		return "bool"
	if l in ["", "any"] or r in ["", "any"]:
		return "any"
	if l == "int" and r == "int":
		return "int"
	return R.op_result(l, op, r)


func _iter_type(e: Variant) -> String:
	var t := _type(e)
	if t == "int" or (e != null and e.k == "call" and e.fn.k == "name" and e.fn.v == "range"):
		return "int"
	if t.begins_with("Array["):
		return T.element_type(t)
	if t == "String":
		return "String"
	if t.begins_with("Packed"):
		return {"PackedInt32Array": "int", "PackedInt64Array": "int", "PackedFloat32Array": "float", "PackedFloat64Array": "float",
			"PackedStringArray": "String", "PackedVector2Array": "Vector2", "PackedVector3Array": "Vector3", "PackedColorArray": "Color"}.get(t, "any")
	return "any"


## Static type of an expression, "any" when it can't be known.
func _type(e: Variant) -> String:
	if e == null:
		return "any"
	match String(e.k):
		"num":
			return "float" if bool(e.f) else "int"
		"str":
			return "StringName" if String(e.v).begins_with("&") else ("NodePath" if String(e.v).begins_with("^") else "String")
		"bool":
			return "bool"
		"self":
			return _cls
		"paren":
			return _type(e.a)
		"node":
			return String(_nodes_cls.get(String(e.path), "Node"))
		"un":
			return "bool" if e.op == "not" else _type(e.a)
		"bin":
			return _op_type(_type(e.a), String(e.op), _type(e.b))
		"tern":
			var w := _widen(_type(e.a), _type(e.b))
			return w if w != "" else "any"
		"is":
			return "bool"
		"lambda":
			return "Callable"
		"await":
			return _type(e.a) if (e.a != null and e.a.k == "call" and e.a.fn.k == "name" and _funcs.has(String(e.a.fn.v))) else "any"
		"as":
			return String(e.t)
		"array":
			return "Array"
		"dict":
			return "Dictionary"
		"name":
			var nm := String(e.v)
			if _scope.has(nm):
				return String(_scope[nm].t)
			if _alias.has(nm):
				return String(_alias[nm].cls)
			if _members.has(nm):
				return String(_members[nm]) if String(_members[nm]) != "" else "any"
			if CONSTANTS.has(nm):
				return String(CONSTANTS[nm])
			if _consts.has(nm):
				return String(_consts[nm]) if String(_consts[nm]) != "" else "any"
			if _funcs.has(nm):
				return "Callable"
			var prop := R.find_property(_cls, nm)
			if not prop.is_empty():
				return T.from_info(prop)
			for al in R.autoloads():
				if String(al[0]) == nm:
					return String(al[1])
			return "any"
		"attr":
			if e.obj.k == "name" and _enum_names.has(String(e.obj.v)) and not _scope.has(String(e.obj.v)):
				return "any" if bool(_enum_names[String(e.obj.v)]) else "int"
			if e.obj.k == "name" and _is_typeref(String(e.obj.v)):
				for c in R.api.types.get(String(e.obj.v), {}).get("const", []):
					if String(c[0]) == String(e.name):
						return R.api_type(String(c[1]))
				return "int" if ClassDB.class_exists(String(e.obj.v)) and ClassDB.class_has_integer_constant(String(e.obj.v), String(e.name)) else "any"
			var ot := _type(e.obj)
			for m in R.break_members(ot):
				if String(m[0]) == String(e.name):
					return R.api_type(String(m[1]))
			if T.is_object(ot):
				var prop := R.find_property(ot, String(e.name))
				if not prop.is_empty():
					return T.from_info(prop)
			return "any"
		"index":
			var ot := _type(e.obj)
			if ot.begins_with("Array["):
				return T.element_type(ot)
			if ot == "String":
				return "String"
			if R.SPLIT.has(ot):
				return String(R.SPLIT[ot][1])
			return "any"
		"call":
			return _call_type(e)
	return "any"


func _is_typeref(nm: String) -> bool:
	return not _scope.has(nm) and not _members.has(nm) and not _alias.has(nm) and not _consts.has(nm) and (_enum_names.has(nm) or T.class_known(nm) or R.api.types.has(nm) or Engine.has_singleton(nm))


func _call_type(e: Dictionary) -> String:
	var fn: Dictionary = e.fn
	if fn.k == "name":
		var nm := String(fn.v)
		if _funcs.has(nm):
			var rt := String(_funcs[nm].ret)
			return rt if rt != "" else "any"
		if R.api.types.has(nm):
			return nm
		match nm:
			"str": return "String"
			"load", "preload": return "PackedScene" if (e.args.size() == 1 and e.args[0] != null and e.args[0].k == "str" and String(e.args[0].v).contains(".tscn")) else "Resource"
			"int", "float", "bool": return nm
			"range": return "Array"
		var u := R.util(nm)
		if not u.is_empty():
			var rt := R.api_type(String(u.r))
			if rt == "any":
				# clamp, min, max, lerp, abs...: numbers in, a number out
				var num := ""
				for a in e.args:
					var at := _type(a)
					if not at in ["int", "float"]:
						return "any"
					num = _widen(num, at)
				return num if num != "" else "any"
			return rt
		var m := R.find_method(_cls, nm)
		if not m.is_empty():
			var rt := T.from_info(m.get("return", {}), true)
			return rt if rt != "" else "any"
		return "any"
	if fn.k == "attr":
		var m := String(fn.name)
		if fn.obj.k == "name" and _is_typeref(String(fn.obj.v)):
			var tr := String(fn.obj.v)
			if m == "new":
				return tr
			if R.api.types.has(tr):
				var bm := R.builtin_method(tr, m)
				return R.api_type(String(bm.r)) if not bm.is_empty() else "any"
			var sm := R.find_method(tr, m)
			if not sm.is_empty():
				var rt := T.from_info(sm.get("return", {}), true)
				return rt if rt != "" else "any"
			return "any"
		var ot := _type(fn.obj)
		var base := "Array" if ot.begins_with("Array[") else ot
		if T.is_builtin(base):
			var bm := R.builtin_method(base, m)
			if bm.is_empty():
				return "any"
			var rt := R.api_type(String(bm.r))
			return rt if rt != "" else "any"
		if T.is_object(ot):
			var om := R.find_method(ot, m)
			if not om.is_empty():
				var rt := T.from_info(om.get("return", {}), true)
				return rt if rt != "" else "any"
	return "any"


## Declares the types of a body's local variables in _scope (used before lowering and for inference).
func _local_types(body: Array) -> void:
	for round in 2:
		_scan_locals(body)


func _scan_locals(body: Array) -> void:
	for st in body:
		match String(st.k):
			"var":
				var nm := String(st.name)
				var lt := _norm(String(st.type))
				if lt == "" and st.init != null:
					lt = _type(st.init)
				var prev := String(_scope[nm].t) if (_scope.has(nm) and _scope[nm].k == "local") else ""
				# a type with no pin type (an enum, an inner class, an array of them) is kept as written, as long
				# as every declaration of the name agrees on it
				var written := String(st.type) if (String(st.type) != "" and lt != "any" and T.hint(lt) != lt) else ""
				if String(st.type) == "Variant":
					written = "Variant"   # stated, though it says no more than no type does: declared as written
				if prev != "" and String(_scope[nm].get("written", "")) != written:
					written = "-"
				_scope[nm] = {"k": "local", "t": _widen(prev, lt) if lt != "" else (prev if prev != "" else "any"), "name": nm, "typed": String(st.type) != "" or bool(st.get("infer", false)) or (prev != "" and bool(_scope[nm].get("typed", false))), "infer": bool(st.get("infer", false)) or (prev != "" and bool(_scope[nm].get("infer", false))),
					"written": written}
			"assign":
				if st.target.k == "name" and _scope.has(String(st.target.v)) and _scope[String(st.target.v)].k == "local" and not bool(_scope[String(st.target.v)].get("typed", false)):
					var s: Dictionary = _scope[String(st.target.v)]
					var vt := _type(st.value)
					if st.op != "=":
						vt = _op_type(String(s.t), String(st.op).trim_suffix("="), vt)
					s.t = _widen(String(s.t), vt)
			"if":
				for br in st.branches:
					_scan_locals(br[1])
				_scan_locals(st["else"])
			"for":
				var held: Variant = _scope.get(String(st["var"]))
				var stated := _norm(String(st.get("var_type", "")))
				_scope[String(st["var"])] = {"k": "loopvar", "t": stated if (stated != "" and stated != "any" and T.hint(stated) == stated) else _iter_type(st.iter)}
				_scan_locals(st.body)
				if held != null and held.k != "loopvar":
					_scope[String(st["var"])] = held   # a local of the same name declared elsewhere in the function
			"while":
				_scan_locals(st.body)
			"match":
				for arm in st.arms:
					_scan_locals(arm.body)


# ---------------------------------------------------------------- graphs

func _event(eg: Dictionary, f: Dictionary) -> void:
	_g = eg
	_fn_name = String(f.name)
	_is_fn = false
	_scope = {}
	_cx = 80.0
	_cy = _low + (140.0 if _low > 0.0 else 80.0)
	var ev := Model.add_node(eg, "event", Vector2(_cx, _cy), {"name": String(f.name)})
	_entry_comments(ev, f)
	_entry = ev
	_low = maxf(_low, _cy + 120.0)
	var info := R.find_method(_cls, String(f.name))
	var names := []
	var renamed := false
	for i in f.params.size():
		_scope[String(f.params[i].name)] = {"k": "pin", "t": T.from_info(info.args[i]), "n": ev, "pin": "p_" + T.ident(String(info.args[i].name)),
			"written": String(f.params[i].name)}
		names.append(String(f.params[i].name))
		renamed = renamed or String(f.params[i].name) != T.ident(String(info.args[i].name))
	if renamed:
		ev.p["names"] = names   # the parameters keep the names the script gave them (the pins keep the engine's)
	_cursor = [ev, "then"]
	_cx += 320.0
	_body(f)


## A function's comments go on its entry node: the lines above its `func` line (note), the comment at the end of
## that line (tail) and the `#endregion` lines right below the function (end); the compiler writes them there.
func _entry_comments(entry: Dictionary, f: Dictionary) -> void:
	for field in ["note", "tail", "end"]:
		if f.has(field):
			entry.p[field] = f[field].duplicate() if f[field] is Array else f[field]


func _function(f: Dictionary, graph: Dictionary) -> void:
	var fi: Dictionary = _funcs[String(f.name)]
	_g = graph
	_fn_name = String(f.name)
	_is_fn = true
	_entry = _g.nodes[0]
	_scope = {}
	for prm in fi.params:
		_scope[String(prm[0])] = {"k": "param", "t": String(prm[1]), "n": _entry, "pin": "p_" + T.ident(String(prm[0]))}
	_low = 0.0
	_cx = 400.0
	_cy = 120.0
	_cursor = [_entry, "then"]
	_body(f)


## Lowers the body of a function or event whose entry node, parameters and cursor are set up.
## A name used both for a local and for a loop variable (the script keeps them apart by block; a graph's
## locals belong to the whole function) is fine as nodes: the local gets a name of its own and the loop
## variable is a pin. Only text carried over as code could mix the two up, so if a statement that has to stay
## as text mentions such a name, the attempt is undone and the function is kept whole, as written.
func _body(f: Dictionary) -> void:
	var first_node: int = _g.nodes.size()
	_awaits = false
	_loop_depth = 0
	_clash = _clash_names(f.body)
	_decls = {}
	_count_decls(f.body, _decls)
	if _clash.is_empty():
		_declare_locals(f.body, String(f.name))
		_block(f.body)
		_mark_waits(first_node)
		return
	var snap := {"wires": _g.wires.size(), "next": int(_g.next_id), "locals": _g.locals.duplicate(true), "latent": _g.get("latent", null),
		"graphs": bp.graphs.size(), "queue": _lambda_queue.size(), "funcs": _funcs.keys(), "notes": notes.size(),
		"total": lines_total, "code": lines_code, "low": _low, "cx": _cx, "cy": _cy, "scope": _scope.duplicate(true), "cursor": _cursor.duplicate()}
	_clash_abort = false
	_declare_locals(f.body, String(f.name))
	_block(f.body)
	if not _clash_abort:
		_mark_waits(first_node)
		_clash = {}
		return
	_g.nodes.resize(first_node)
	_g.wires.resize(int(snap.wires))
	_g.next_id = int(snap.next)
	_forget_lines(int(snap.next))
	_g.locals = snap.locals
	if snap.latent == null:
		_g.erase("latent")
	bp.graphs.resize(int(snap.graphs))
	_lambda_queue.resize(int(snap.queue))
	for nm in _funcs.keys():
		if not snap.funcs.has(nm):
			_funcs.erase(nm)
	notes.resize(int(snap.notes))
	lines_total = int(snap.total)
	lines_code = int(snap.code)
	_low = float(snap.low)
	_cx = float(snap.cx)
	_cy = float(snap.cy)
	_scope = snap.scope
	_cursor = snap.cursor
	_clash = {}
	_awaits = false
	_declare_locals(f.body, String(f.name))
	_whole(f)
	_mark_waits(first_node)


## A function that waits somewhere runs its steps in order, waiting for each, as GDScript does: its
## Sequence and loop nodes are the waiting kind, and a function graph is marked as one that may wait.
func _mark_waits(first_node: int) -> void:
	if not _awaits:
		return
	for i in range(first_node, _g.nodes.size()):
		if String(_g.nodes[i].kind) in ["sequence", "for", "for_each", "for_each_dict", "while"]:
			_g.nodes[i].p["wait"] = true
	if _is_fn:
		_g["latent"] = true
	_awaits = false


## True when a local variable shares its name with a loop variable elsewhere in the function. The script
## keeps them apart by block; a graph's locals belong to the whole function, so the two would collide.
func _clash_names(body: Array) -> Dictionary:
	var loops := {}
	var locals := {}
	_collect_names(body, loops, locals)
	var out := {}
	for nm in loops:
		if locals.has(nm):
			out[nm] = true
	return out


func _collect_names(body: Array, loops: Dictionary, locals: Dictionary) -> void:
	var re := RegEx.create_from_string("(?m)^\\s*(for|var)\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for st in body:
		match String(st.k):
			"var":
				locals[String(st.name)] = true
			"for":
				loops[String(st["var"])] = true
				_collect_names(st.body, loops, locals)
			"while":
				_collect_names(st.body, loops, locals)
			"match":
				for arm in st.arms:
					_collect_names(arm.body, loops, locals)
			"if":
				for br in st.branches:
					_collect_names(br[1], loops, locals)
				_collect_names(st["else"], loops, locals)
			"raw":
				for m in re.search_all(String(st.get("text", st.src))):
					if m.get_string(1) == "for":
						loops[m.get_string(2)] = true
					else:
						locals[m.get_string(2)] = true


## How many times each local name is declared in a body (a local a graph declares once for the whole function).
func _count_decls(body: Array, out: Dictionary) -> void:
	var re := RegEx.create_from_string("(?m)^\\s*var\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for st in body:
		match String(st.k):
			"var":
				out[String(st.name)] = int(out.get(String(st.name), 0)) + 1
			"for", "while":
				_count_decls(st.body, out)
			"match":
				for arm in st.arms:
					_count_decls(arm.body, out)
			"if":
				for br in st.branches:
					_count_decls(br[1], out)
				_count_decls(st["else"], out)
			"raw":
				for m in re.search_all(String(st.get("text", st.src))):
					out[m.get_string(1)] = int(out.get(m.get_string(1), 0)) + 1


## Carries a whole function body over as one code node.
func _whole(f: Dictionary) -> void:
	var text := String(f.get("body_text", "pass"))
	var count := _line_count({"text": text, "src": text})   # (its comment lines are not lines of code)
	lines_total += count
	lines_code += count
	# the locals made for this body go (in the EventGraph each event has locals of its own: see _declare_locals)
	var own := {}
	for nm in _scope:
		if _scope[nm].k == "local":
			own[String(_scope[nm].get("name", nm))] = true
	var kept := []
	for l in _g.locals:
		if not own.has(String(l.name)):
			kept.append(l)
	_g.locals = kept
	for nm in _scope.keys():
		if _scope[nm].k == "local":
			_scope.erase(nm)
	notes.append("%s is kept whole as code: a local variable and a loop variable share a name in it" % f.name)
	_pending.clear()
	var from: int = _g.nodes.size()
	_code(text)
	var line := int(f.body[0].get("line", 0)) if not f.body.is_empty() else int(f.get("line", 0))
	for i in range(from, _g.nodes.size()):
		_note_line(_g.nodes[i], line, i == from)


## Creates the graph's local variables. In the EventGraph locals are stored on the schematic, so a name that
## is already taken (by a member or by another event's local of a different type) gets the event's name added.
func _declare_locals(body: Array, fn_name: String) -> void:
	var before := _scope.duplicate()
	_local_types(body)
	for nm in _scope:
		var s: Dictionary = _scope[nm]
		if s.k == "loopvar":
			continue
		if s.k != "local" or before.has(nm):
			continue
		var unique := String(nm)
		# A local with the name of a member would make the member's nodes read the local: it gets a name of its own.
		var clash := _members.has(unique) or _alias.has(unique) or _funcs.has(unique) or _clash.has(unique)
		for l in _g.locals:
			if String(l.name) == unique and (String(l.type) != String(s.t) or _is_fn):
				clash = true
		if not _is_fn:
			# The events share the EventGraph and its locals: a name more than one event declares (as a local, a
			# parameter or a loop variable) needs a local for each, so each carries its event's name. So does a name
			# the class already gives something (a constant, a signal, a property or method of the parent class),
			# which the local could not become a member of the script under if it had to (see the compiler's
			# _settle_event_locals). Any other keeps the name the script gave it.
			# A name the script writes as a property's name (set("x"), a tween of self, ".:x") would make the compiler
			# keep the local as a member, which the script's set("x") would then reach: it gets the event's name too.
			clash = clash or int(_event_names.get(unique, 0)) > 1 or _consts.has(unique) or _signals.has(unique) or _enum_names.has(unique) \
				or not R.find_property(_cls, unique).is_empty() or not R.find_method(_cls, unique).is_empty() \
				or Compiler._named_as_property(_source, unique)
			for l in _g.locals:
				if String(l.name) == unique:
					clash = true   # another event's
		if clash and _is_fn:
			unique = "%s_%s" % [nm, T.ident(fn_name).trim_prefix("_")]
		elif clash:
			# the event's name is added once: a name that carries it already gets a number instead
			var suffix := "_" + T.ident(fn_name).trim_prefix("_")
			var stem := unique.trim_suffix(suffix) if unique.ends_with(suffix) else unique
			var more := 1 if stem == unique else 2
			unique = stem + suffix + ("" if more == 1 else "_2")
			while _members.has(unique) or _alias.has(unique) or _funcs.has(unique) or _g.locals.any(func(l): return String(l.name) == unique) \
					or int(_event_names.get(unique, 0)) > 0 or Compiler._named_as_property(_source, unique):
				more += 1
				unique = "%s%s_%d" % [stem, suffix, more]
		s["name"] = unique
		var exists := false
		for l in _g.locals:
			if String(l.name) == unique:
				exists = true
		if not exists:
			var made := {"name": unique, "type": String(s.t), "default": ""}
			if bool(s.get("infer", false)):
				made["infer"] = true   # written as "var x := ...": the type is whatever GDScript infers there
			if not String(s.get("written", "")) in ["", "-"]:
				made["hint"] = String(s.written)   # a type the schematic has no pin for: kept in the declaration
			elif not bool(s.get("typed", false)):
				made["untyped"] = true   # written without a type: declared without one, whatever the pins show
			_g.locals.append(made)
	for nm in _scope.keys():
		if _scope[nm].k == "loopvar":
			_scope.erase(nm)


# ---------------------------------------------------------------- node helpers

func _data(kind: String, p: Dictionary, depth: int) -> Dictionary:
	var n := Model.add_node(_g, kind, Vector2.ZERO, p)
	_pending.append([n, depth])
	return n


## Adds an exec node at the cursor, lays out the data nodes gathered for it, and moves the cursor on.
func _exec(kind: String, p: Dictionary, in_pin := "exec", out_pin := "then") -> Dictionary:
	var n := Model.add_node(_g, kind, Vector2.ZERO, p)
	_last_exec = n
	_place(n)
	if not _cursor.is_empty():
		_g.wires.append([int(_cursor[0].id), String(_cursor[1]), int(n.id), in_pin])
	_cursor = [n, out_pin]
	return n


func _place(n: Dictionary) -> void:
	var deepest := 0
	for it in _pending:
		deepest = maxi(deepest, int(it[1]))
	var count := {}
	for it in _pending:
		var d := int(it[1])
		count[d] = int(count.get(d, 0)) + 1
		it[0].x = _cx + COL * (deepest - d)
		it[0].y = _cy + 150.0 + ROW * (int(count[d]) - 1)
		_low = maxf(_low, float(it[0].y) + ROW)
	n.x = _cx + COL * deepest
	n.y = _cy
	_low = maxf(_low, _cy + 130.0)
	_cx = float(n.x) + 330.0
	_pending.clear()


## Identifies the current end of the execution path, to notice when lowering an expression added to it.
func _at() -> String:
	return "%d:%s" % [int(_cursor[0].id), _cursor[1]] if not _cursor.is_empty() else ""


func _wire(val: Dictionary, n: Dictionary, pin: String) -> bool:
	if val.is_empty():
		return false
	if val.has("lit"):
		n.d[pin] = String(val.lit)
		return true
	if val.has("n"):
		_g.wires.append([int(val.n.id), String(val.pin), int(n.id), pin])
		return true
	return _fail("this can't be used as a value")


func _fail(why: String) -> bool:
	if _failed == "":
		_failed = why
	return false


func _out_pin(n: Dictionary) -> Dictionary:
	for po in R.describe(n, bp, _g).outs:
		if po.type != "exec":
			return po
	return {}


# ---------------------------------------------------------------- statements

## Comments (see the parser's COMMENTS) go onto nodes in these fields of `p`, written back by the compiler:
##   note   [String]  lines above the statement: on the first node it became (the node whose step writes first)
##   tail   String    the comment at the end of its line: on that node too
##   after  [String]  lines that end the block after it: on the node whose step writes last (the first node when
##                    that writes the whole statement: a Branch, Sequence, Switch or loop)
##   empty  {pin: {note, tail}}  comments of a block that became no node at all (`pass  # later`): on the node
##                    the block hangs off, for the exec output pin it hangs off (written with the `pass` there)
## A statement that becomes no node (pass, a declaration without a value, an expression with no effect) hands
## its comments to the next statement's first node, or the last node before it at the end of a block.
## A statement kept as code: on the code node, whose text also holds the comments inside the statement.
const COMPOUND_STARTS := ["branch", "switch", "sequence", "for", "for_each", "for_each_dict", "while"]

func _block(stmts: Array) -> void:
	var carried := PackedStringArray()   # @warning_ignore(...) lines waiting for the statement they are written above
	var start := _cursor.duplicate()
	var start_next := int(_g.next_id)
	var held := {"note": [], "tail": ""}   # comments of statements that became no node, for the next node
	var last_node := {}
	for i in stmts.size():
		var st: Dictionary = stmts[i]
		var last := i == stmts.size() - 1
		var total_before := lines_total
		lines_total += _own_lines(st)
		if st.k == "raw" and String(st.src).begins_with("@warning_ignore") and not String(st.get("text", st.src)).contains("\n") and not last:
			carried.append(String(st.src))
			_hold(held, st)
			continue
		var came_from := _cursor.duplicate()
		if _cursor.is_empty():
			notes.append("line %d: unreachable code after return/break dropped: %s" % [st.get("line", 0), st.src])
			if st.has("note") or st.has("tail") or st.has("after"):
				_hold(held, st)
				notes.append("line %d: its comments are written after the statement before it" % st.get("line", 0))
			continue
		# everything is undone if the statement turns out not to be expressible as nodes
		var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "cursor": _cursor.duplicate(),
			"cx": _cx, "cy": _cy, "low": _low, "code": lines_code, "scope": _scope.duplicate()}
		_failed = ""
		_pending.clear()
		_inline_mode = 0
		_keep_step = false
		var ok := _statement(st, last)
		if not ok and bool(st.get("synthetic", false)):
			# a part of one expression statement: the whole statement stays as code (see _synthetic_if)
			if _synthetic_fail == "":
				_synthetic_fail = _failed if _failed != "" else "not supported"
			continue
		if not ok:
			_g.nodes.resize(int(mark.nodes))
			_g.wires.resize(int(mark.wires))
			_g.next_id = int(mark.next)
			_forget_lines(int(mark.next))
			_cursor = mark.cursor
			_cx = float(mark.cx)
			_cy = float(mark.cy)
			_low = float(mark.low)
			lines_total = total_before + _line_count(st)
			lines_code = int(mark.code) + _line_count(st)
			_scope = mark.scope
			_pending.clear()
			notes.append("line %d kept as code (%s): %s" % [st.get("line", 0), _failed if _failed != "" else String(st.get("why", "not supported")), String(st.src)])
			var text := String(st.get("text", st.src))
			if not carried.is_empty():
				text = "\n".join(carried) + "\n" + text
				carried.clear()
			for clashing in _clash:
				if Compiler._replace_word(text, String(clashing), "") != text:
					_clash_abort = true
			if st.k == "var":
				text = String(st.get("line_src", "var %s = %s" % [st.name, st.init_src]))
			_code(_devar(text))
			if _ends_path(st):
				_cursor = []
		elif not carried.is_empty():
			# the annotation goes with the first step the statement became
			if not came_from.is_empty():
				for wi in range(int(mark.wires), _g.wires.size()):
					var w: Array = _g.wires[wi]
					if int(w[0]) == int(came_from[0].id) and String(w[1]) == String(came_from[1]):
						_made_since(int(mark.nodes), int(w[2])).p["pre"] = Array(carried)
						break
			carried.clear()
		# the nodes the statement became, and the line it is on (nodes of statements inside it have theirs already)
		var line := int(st.get("line", 0))
		for ni in range(int(mark.nodes), _g.nodes.size()):
			_note_line(_g.nodes[ni], line, false)
		# the statement's comments: on the first and the last node it became (see COMPOUND_STARTS above)
		var first := {}
		if not came_from.is_empty():
			for wi in range(int(mark.wires), _g.wires.size()):
				var w: Array = _g.wires[wi]
				if int(w[0]) == int(came_from[0].id) and String(w[1]) == String(came_from[1]):
					first = _made_since(int(mark.nodes), int(w[2]))
					break
		if not first.is_empty() and int(first.id) >= int(mark.next):
			_note_line(first, line, true)
		if first.is_empty():
			_hold(held, st)   # it became no node
			continue
		var note: Array = held.note.duplicate()
		if String(held.tail) != "":
			note.append(String(held.tail).strip_edges())
		note.append_array(st.get("note", []))
		held = {"note": [], "tail": ""}
		if not note.is_empty():
			first.p["note"] = first.p.get("note", []) + note
		if String(st.get("tail", "")) != "":
			first.p["tail"] = String(st.tail)
		var final := first
		if not String(first.kind) in COMPOUND_STARTS:
			if not _cursor.is_empty() and int(_cursor[0].id) >= int(mark.next):
				final = _cursor[0]
			elif not _last_exec.is_empty() and int(_last_exec.id) >= int(mark.next) and is_same(_made_since(int(mark.nodes), int(_last_exec.id)), _last_exec):
				final = _last_exec
		if not st.get("after", []).is_empty():
			final.p["after"] = final.p.get("after", []) + st.after
		last_node = final
	# comments of statements at the end of the block that became no node
	if held.note.is_empty() and String(held.tail) == "":
		return
	if not last_node.is_empty() and int(last_node.id) >= start_next:
		var lines: Array = held.note.duplicate()
		if String(held.tail) != "":
			lines.append(String(held.tail).strip_edges())
		last_node.p["after"] = last_node.p.get("after", []) + lines
	elif not start.is_empty():
		# the block became no node at all: the comments go with the `pass` written for it
		var empty: Dictionary = start[0].p.get("empty", {})
		empty[String(start[1])] = held
		start[0].p["empty"] = empty
	else:
		notes.append("comments dropped: %s" % str(held.note))


## The node `id` among the nodes from index `from` on (the ones the statement being lowered made: ids grow with
## the index), or anywhere in the graph when it is not there. (Looking only at the new nodes keeps a function of
## thousands of statements from taking time that grows with the square of its length.)
func _made_since(from: int, id: int) -> Dictionary:
	for i in range(from, _g.nodes.size()):
		if int(_g.nodes[i].id) == id:
			return _g.nodes[i]
	return Model.find_node(_g, id)


## Records the line of the statement node `n` belongs to (see `lines` and `writers` at the top), unless a
## statement inside that one recorded it already.
func _note_line(n: Dictionary, line: int, writer: bool) -> void:
	var gid := int(_g.id)
	if not _src_lines.has(gid):
		_src_lines[gid] = {}
		_src_writers[gid] = {}
	_src_top[gid] = maxi(int(_src_top.get(gid, 0)), int(n.id))
	if writer:
		if not _src_writers[gid].has(int(n.id)):
			_src_writers[gid][int(n.id)] = line
		_src_lines[gid][int(n.id)] = int(_src_writers[gid][int(n.id)])
	elif not _src_lines[gid].has(int(n.id)):
		_src_lines[gid][int(n.id)] = line


## Forgets the lines recorded for nodes of the graph being filled with ids from `from` on (they were undone).
func _forget_lines(from: int) -> void:
	var gid := int(_g.id)
	if int(_src_top.get(gid, 0)) < from:
		return   # (nothing recorded there: a statement that failed before any statement inside it was lowered)
	_src_top[gid] = from - 1
	for table in [_src_lines, _src_writers]:
		if not table.has(gid):
			continue
		for id in table[gid].keys():
			if int(id) >= from:
				table[gid].erase(id)


## Keeps the comments of a statement that became no node for the next node (see _block).
func _hold(held: Dictionary, st: Dictionary) -> void:
	if String(held.tail) != "":
		held.note.append(String(held.tail).strip_edges())   # (an earlier one's comment at the end of its line)
		held.tail = ""
	held.note.append_array(st.get("note", []))
	held.tail = String(st.get("tail", ""))
	if not st.get("after", []).is_empty():
		if String(held.tail) != "":
			held.note.append(String(held.tail).strip_edges())
			held.tail = ""
		held.note.append_array(st.after)


## The lines of a statement's text that are code (not comment lines, not blank lines; every line of a string
## that runs over several lines counts).
func _line_count(st: Dictionary) -> int:
	var text := String(st.get("text", st.src))
	if not text.contains("#") and not text.contains("\n\n"):
		return text.split("\n").size()
	var inside := T.lines_in_string(text)
	var lines := text.split("\n")
	var count := 0
	for k in lines.size():
		var s := lines[k].strip_edges()
		if inside[k] or (s != "" and not s.begins_with("#")):
			count += 1
	return maxi(count, 1)


## Lines a statement accounts for by itself (the statements inside an if or loop are counted on their own).
func _own_lines(st: Dictionary) -> int:
	if bool(st.get("synthetic", false)):
		return 0   # a part of an expression statement, whose line is already counted
	match String(st.k):
		"if": return st.branches.size() + (0 if st["else"].is_empty() else 1)
		"for", "while": return 1
		"match": return 1 + st.arms.size()
	return _line_count(st)


## Local variables are declared once for the whole graph, so declarations inside carried-over code become
## plain assignments (GDScript does not allow the same local to be declared twice in a function).
func _devar(text: String) -> String:
	var re := RegEx.create_from_string("^(\\t*)var\\s+(\\w+)\\s*(:\\s*[\\w\\[\\], .]+?)?\\s*(:?=\\s*(.*))?$")
	var out := PackedStringArray()
	var inside := T.lines_in_string(text)
	var lines := text.split("\n")
	for k in lines.size():
		var line := lines[k]
		var m := re.search(line) if not inside[k] else null   # (a line of a string is not a declaration)
		if m == null or not _scope.has(m.get_string(2)):
			out.append(line)
		elif m.get_string(5) != "":
			out.append("%s%s = %s" % [m.get_string(1), m.get_string(2), m.get_string(5)])
		else:
			out.append(m.get_string(1) + "pass")
	return "\n".join(out)


## Value nodes the compiler writes in brackets of their own: `(a + b)`, `(x as T)`, `(a if c else b)`...
const BRACKETED := ["math", "op", "as_type", "cast", "get_node", "is_type", "select"]

## A whole right-hand side, return value or condition written without brackets: the node it became is marked
## `unbracketed`, and the compiler leaves out the outer brackets it would write around it there (and only there:
## the same node read inside a larger expression keeps them). Written with brackets, it keeps them.
func _mark_unbracketed(e: Variant, val: Dictionary) -> void:
	if e is Dictionary and String(e.get("k", "")) != "paren" and val.has("n") and String(val.n.kind) in BRACKETED:
		val.n.p["unbracketed"] = true


func _ends_path(st: Dictionary) -> bool:
	return st.k in ["return", "break", "continue"]


func _statement(st: Dictionary, last: bool) -> bool:
	match String(st.k):
		"pass":
			return true
		"raw":
			return false
		"var":
			var first: Variant = st.init
			if first == null:
				# Declared without a value: it starts from its type's default every time the declaration is
				# reached. A graph's local lives for the whole function (in the EventGraph, for as long as the
				# object), so inside a loop or an event it is set back here; elsewhere the local's own default does it.
				if _is_fn and _loop_depth == 0 and int(_decls.get(String(st.name), 0)) <= 1:
					return true   # (another declaration of the name may have given the local a value already)
				first = _default_value(String(st.type))
			if not _scope.has(String(st.name)) or _scope[String(st.name)].k != "local":
				return _fail("a variable declared where the importer does not track locals")
			var s: Dictionary = _scope[String(st.name)]
			_keep_step = true
			var val := _value(first, 1)
			_keep_step = false
			if val.is_empty():
				return false
			if st.init != null:
				_mark_unbracketed(first, val)
			var n := _exec("local_set", {"name": String(s.name)})
			if st.init == null:
				n.p["bare"] = true   # declared without a value: written back that way where it can be
			return _wire(val, n, "value")
		"assign":
			return _assign(st)
		"expr":
			var e: Dictionary = st.e
			while e.k == "paren":
				e = e.a
			if e.k == "await":
				return not _await(e, 0, false).is_empty()
			if e.k == "name" and String(e.v) == "breakpoint" and not _scope.has("breakpoint"):
				# the debugger stops here: a Breakpoint node (a template the node carries, see BREAKPOINT)
				_exec("tpl", {"t": BREAKPOINT.duplicate(true)})
				return true
			if e.k != "call":
				return _effects(st, e, last)
			var before = _g.nodes.size()
			var stood := _at()
			var val := _call(e, 0, false)
			if _failed != "":
				return false
			if _at() == stood and not (val.has("n") and _pending.any(func(it): return it[0] == val.n)):
				return _fail("a call that would not run as a step")   # never drop a statement silently
			if _g.nodes.size() > before and not _pending.is_empty() and val.has("n") and _pending.any(func(it): return it[0] == val.n):
				# a call the engine marks as changing nothing (calling a Callable, say): it is still a step here
				if not String(val.n.kind) in R.CALL_KINDS:
					return _fail("a call with no effect")
				val.n.p["exec"] = true
				for i in range(_pending.size() - 1, -1, -1):
					if _pending[i][0] == val.n:
						_pending.remove_at(i)
				_place(val.n)
				if not _cursor.is_empty():
					_g.wires.append([int(_cursor[0].id), String(_cursor[1]), int(val.n.id), "exec"])
				_cursor = [val.n, "then"]
				_last_exec = val.n
			return true
		"return":
			if not _is_fn and st.e != null:
				return _fail("an event that returns a value")
			var val := {}
			if st.e != null:
				_keep_step = true
				val = _value(st.e, 1)
				_keep_step = false
				if val.is_empty():
					return false
				_mark_unbracketed(st.e, val)
			var n := _exec("fn_return", {})
			if st.e != null and not _g.outputs.is_empty():
				if not _wire(val, n, "r_result"):
					return false
			_cursor = []
			return true
		"break":
			_exec("loop_break", {})
			_cursor = []
			return true
		"continue":
			_exec("loop_continue", {})
			_cursor = []
			return true
		"if":
			return _if(st, last)
		"match":
			return _match(st, last)
		"for":
			return _for(st)
		"while":
			# the condition is asked again before every pass, so whatever it calls runs in place
			_inline_mode += 1
			var cond := _value(st.cond, 1)
			_inline_mode -= 1
			if cond.is_empty():
				return false
			_mark_unbracketed(st.cond, cond)
			var n := _exec("while", {}, "exec", "body")
			if not _wire(cond, n, "cond"):
				return false
			return _loop_body(n, st.body)
	return false


## An expression statement that is not a call: whatever in it has an effect still runs, in GDScript's order.
## `a and b` is "if a: b", `a or b` is "if not a: b", `x if c else y` is a branch; the items of a list or a
## dictionary and the operand of `not` (none of which can fail) run one after another. Only an expression
## with nothing in it that could do anything (no call, no await, no property read) is dropped.
func _effects(st: Dictionary, e: Dictionary, last: bool) -> bool:
	if _pure(e):
		if not bool(st.get("synthetic", false)):
			notes.append("line %d: expression without effect dropped: %s" % [st.get("line", 0), st.src])
		return true
	match String(e.k):
		"paren":
			return _effects(st, e.a, last)
		"call", "await":
			return _statement({"k": "expr", "e": e, "src": Parser.unparse(e), "line": st.get("line", 0), "synthetic": true}, last)
		"bin":
			if String(e.op) in ["and", "or"]:
				if _pure(e.b):
					return _effects(st, e.a, last)
				var cond: Dictionary = e.a if String(e.op) == "and" else {"k": "un", "op": "not", "a": e.a}
				return _synthetic_if(st, [[cond, [_effect_stmt(st, e.b)]]], [], last)
		"tern":
			if _pure(e.a) and _pure(e.b):
				return _effects(st, e.c, last)
			if _pure(e.a):
				return _synthetic_if(st, [[{"k": "un", "op": "not", "a": e.c}, [_effect_stmt(st, e.b)]]], [], last)
			return _synthetic_if(st, [[e.c, [_effect_stmt(st, e.a)]]], [] if _pure(e.b) else [_effect_stmt(st, e.b)], last)
		"array", "dict", "un":
			if String(e.k) != "un" or String(e.op) == "not":
				var parts := []
				if e.k == "array":
					parts = e.items
				elif e.k == "dict":
					for pr in e.pairs:
						parts.append_array(pr)
				else:
					parts = [e.a]
				parts = parts.filter(func(x): return x != null and not _pure(x))
				for i in parts.size():
					if not _effects(st, parts[i], last and i == parts.size() - 1):
						return false
				return true
	return _fail("an expression statement whose value is not used, with a call in it")


func _effect_stmt(st: Dictionary, e: Dictionary) -> Dictionary:
	return {"k": "expr", "e": e, "src": Parser.unparse(e), "line": st.get("line", 0), "synthetic": true}


## An if made from one expression statement: its branches belong to that statement's line, and if any part
## of it cannot be nodes the whole statement stays as code.
func _synthetic_if(st: Dictionary, branches: Array, else_body: Array, last: bool) -> bool:
	_synthetic_fail = ""
	var ok := _if({"k": "if", "branches": branches, "else": else_body, "src": st.src, "line": st.get("line", 0), "synthetic": true}, last)
	if _synthetic_fail != "":
		var why := _synthetic_fail
		_synthetic_fail = ""
		_failed = ""
		return _fail(why)
	return ok


## An if that became one node (a Bind Event, a message): the comments of the statement inside it go after it
## (one block deeper, as they were written), since that statement has no node of its own.
func _absorb_comments(st: Dictionary) -> void:
	var lines := []
	for inner in st.branches[0][1]:
		for l in inner.get("note", []):
			lines.append(_one_deeper(String(l)))
		if String(inner.get("tail", "")) != "":
			lines.append("\t" + String(inner.tail).strip_edges())
		for l in inner.get("after", []):
			lines.append(_one_deeper(String(l)))
	if not lines.is_empty():
		st["after"] = lines + st.get("after", [])


## A comment line of the parser's COMMENTS form, said relative to a statement one block shallower.
static func _one_deeper(line: String) -> String:
	if line == "":
		return line
	return line.substr(1) if line.begins_with("<") else "\t" + line


## True for an expression whose evaluation can have no effect: no call, no await, no property read that
## could run a getter, no node lookup.
func _pure(e: Variant) -> bool:
	if e == null:
		return true
	match String(e.k):
		"num", "str", "bool", "null", "self", "lambda":
			return true
		"name":
			return not _setget.has(String(e.v)) or _scope.has(String(e.v))
		"paren", "un", "is", "as":
			return _pure(e.a)
		"bin":
			return _pure(e.a) and _pure(e.b)
		"tern":
			return _pure(e.a) and _pure(e.b) and _pure(e.c)
		"array":
			return e.items.all(func(x): return _pure(x))
		"dict":
			return e.pairs.all(func(pr): return _pure(pr[0]) and _pure(pr[1]))
	return false


func _if(st: Dictionary, last: bool) -> bool:
	if _is_message(st):
		if _message(st):
			_absorb_comments(st)
			return true
		return false
	if _is_guarded_connect(st):
		# what a Bind (or Unbind) Event node is written as: the node itself, if the connect becomes one
		var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "cursor": _cursor.duplicate(),
			"cx": _cx, "cy": _cy, "low": _low, "scope": _scope.duplicate(), "total": lines_total, "code": lines_code}
		var want_kind := "bind_signal" if String(st.branches[0][1][0].e.fn.name) == "connect" else "unbind_signal"
		lines_total += 1
		if _statement(st.branches[0][1][0], last) and _g.nodes.size() > int(mark.nodes) \
				and _g.nodes.slice(int(mark.nodes)).any(func(n): return String(n.kind) == want_kind):
			_absorb_comments(st)
			return true
		_g.nodes.resize(int(mark.nodes))
		_g.wires.resize(int(mark.wires))
		_g.next_id = int(mark.next)
		_cursor = mark.cursor
		_cx = float(mark.cx)
		_cy = float(mark.cy)
		_low = float(mark.low)
		_scope = mark.scope
		lines_total = int(mark.total)
		lines_code = int(mark.code)
		_pending.clear()
		_failed = ""
	# code after the if continues from a Sequence, so neither branch has to be wired back together
	var seq := {}
	if not last:
		seq = _exec("sequence", {"n": 2}, "exec", "then_0")
		_cx = float(seq.x) + 250.0
	var branches: Array = st.branches
	var ok := _if_chain(branches, 0, st["else"])
	if not ok:
		return false
	if not last:
		_cx = float(seq.x) + 250.0
		_cy = _low + 70.0
		_cursor = [seq, "then_1"]
	else:
		_cursor = []
	return true


## `if not s.is_connected(f): s.connect(f)` (or `if s.is_connected(f): s.disconnect(f)`) and nothing else, the
## same signal and callable in both: the guard the compiler writes around a Bind (Unbind) Event node.
func _is_guarded_connect(st: Dictionary) -> bool:
	if st.branches.size() != 1 or not st["else"].is_empty() or st.branches[0][1].size() != 1:
		return false
	var body: Dictionary = st.branches[0][1][0]
	if body.k != "expr" or body.e == null or body.e.k != "call" or body.e.fn.k != "attr" or not String(body.e.fn.name) in ["connect", "disconnect"] \
			or body.e.args.size() != 1 or body.e.args[0] == null:
		return false
	var cond: Variant = st.branches[0][0]
	while cond is Dictionary and cond.k == "paren":
		cond = cond.a
	if String(body.e.fn.name) == "connect":
		if not (cond is Dictionary and cond.k == "un" and String(cond.op) == "not"):
			return false
		cond = cond.a
		while cond is Dictionary and cond.k == "paren":
			cond = cond.a
	if not (cond is Dictionary and cond.k == "call" and cond.fn.k == "attr" and String(cond.fn.name) == "is_connected" and cond.args.size() == 1 and cond.args[0] != null):
		return false
	return Parser.unparse(cond.fn.obj) == Parser.unparse(body.e.fn.obj) and Parser.unparse(cond.args[0]) == Parser.unparse(body.e.args[0])


## `if x.has_method(m): x.call(m, ...)` and nothing else: one Call If Present node.
func _is_message(st: Dictionary) -> bool:
	if st.branches.size() != 1 or not st["else"].is_empty() or st.branches[0][1].size() != 1:
		return false
	var cond: Variant = st.branches[0][0]
	var body: Dictionary = st.branches[0][1][0]
	if cond == null or cond.k != "call" or cond.fn.k != "attr" or String(cond.fn.name) != "has_method" or cond.args.size() != 1:
		return false
	if body.k != "expr" or body.e.k != "call" or body.e.fn.k != "attr" or String(body.e.fn.name) != "call" or body.e.args.is_empty():
		return false
	if cond.args[0] == null or body.e.args.has(null) or not _simple(cond.fn.obj) or not _simple(cond.args[0]):
		return false
	return Parser.unparse(cond.fn.obj) == Parser.unparse(body.e.fn.obj) and Parser.unparse(cond.args[0]) == Parser.unparse(body.e.args[0])


func _message(st: Dictionary) -> bool:
	var call: Dictionary = st.branches[0][1][0].e
	lines_total += 1
	var target := _value(call.fn.obj, 1)
	var fn := _value(call.args[0], 1)
	if target.is_empty() or fn.is_empty():
		return false
	var vals := _ordered(call.args.slice(1), 1, not target.has("lit") or not fn.has("lit"))
	if vals.size() != call.args.size() - 1:
		return false
	var n := _exec("message", {"n": vals.size()})
	if not (_wire(target, n, "target") and _wire(fn, n, "fn")):
		return false
	for i in vals.size():
		if not _wire(vals[i], n, "v%d" % i):
			return false
	return true


## Values for a list that GDScript works out left to right (arguments, array items, dictionary entries).
## A call that has to run as a step runs before the statement; once something has been read by wire, a later
## call must not run ahead of it, so from there on calls run in place. Returns fewer values on failure.
func _ordered(items: Array, depth: int, read_before := false) -> Array:
	var out := []
	var guard := read_before
	for it in items:
		if guard:
			_inline_mode += 1
		var v := _value(it, depth)
		if guard:
			_inline_mode -= 1
		if v.is_empty():
			return out
		out.append(v)
		guard = guard or v.has("n")
	return out


## `match value:` as a Switch node: one output per pattern, the `_` arm on Default.
func _match(st: Dictionary, last: bool) -> bool:
	var cases := []
	var default_at := -1
	for i in st.arms.size():
		var arm: Dictionary = st.arms[i]
		var pattern := String(arm.pattern)
		for nm in _scope:
			if Compiler._replace_word(pattern, String(nm), "\u0001") != pattern:
				return _fail("a match pattern that uses a local variable")
		# `var name` in a pattern: the arm's own variable, which the nodes under it read by name
		arm["binds"] = []
		if not bool(arm.plain):
			for found in RegEx.create_from_string("\\bvar\\s+([A-Za-z_][A-Za-z_0-9]*)").search_all(Parser.new()._blank_strings(pattern)):
				var bound := found.get_string(1)
				if _clash.has(bound) or _g.locals.any(func(l): return String(l.name) == bound):
					return _fail("a match pattern that binds a name the function also uses for a variable")
				arm.binds.append(bound)
		if pattern == "_":
			default_at = i
		else:
			cases.append([pattern, pattern])
	if default_at != -1 and default_at != st.arms.size() - 1:
		return _fail("a match with patterns after the catch-all")
	var sel := _value(st.subject, 1)
	if sel.is_empty():
		return false
	var seq := {}
	if not last:
		seq = _exec("sequence", {"n": 2}, "exec", "then_0")
		_cx = float(seq.x) + 250.0
	var st_type := String(sel.get("t", "any"))
	var n := _exec("switch", {"t": st_type if st_type in ["int", "String", "StringName", "bool", "float"] else "any", "cases": cases}, "exec", "case_0")
	if not _wire(sel, n, "sel"):
		return false
	var bx := float(n.x) + 320.0
	var case_no := 0
	for i in st.arms.size():
		var arm_pin := "default" if i == default_at else "case_%d" % case_no
		_cursor = [n, arm_pin]
		if i != default_at:
			case_no += 1
		_cx = bx
		if i > 0:
			_cy = _low + 70.0
		for bound in st.arms[i].binds:
			_scope[bound] = {"k": "bound", "name": bound, "t": "any", "of": int(n.id), "arm": arm_pin}
		_block(st.arms[i].body)
		for bound in st.arms[i].binds:
			_scope.erase(bound)
	if not last:
		_cx = float(seq.x) + 250.0
		_cy = _low + 70.0
		_cursor = [seq, "then_1"]
	else:
		_cursor = []
	return true


## `await something`. A call that waits becomes that call node told to wait; the usual timer wait becomes a
## Wait node; anything else that can be waited for (a signal) goes into a Wait For node.
func _await(e: Dictionary, depth: int, want: bool) -> Dictionary:
	_awaits = true
	var a: Variant = e.a
	while a != null and a.k == "paren":
		a = a.a
	if a == null:
		_fail("an await the parser did not understand")
		return {}
	if a.k == "call":
		_last_call = {}
		var before: int = _g.nodes.size()
		var out := _call(a, depth, want)
		if _failed != "" or out.is_empty():
			return {}
		if _last_call.is_empty() or not String(_last_call.kind) in R.CALL_KINDS:
			_fail("await on something that is not a function call")
			return {}
		var n: Dictionary = _last_call
		n.p["await"] = true
		if _pending.any(func(it): return it[0] == n) and _inline_mode == 0 and not bool(n.p.get("inline", false)):
			# marked as changing nothing, but it has to be waited for: it is a step
			# (a call told to run where its value is read is waited for there, and must not also run as a step)
			n.p["exec"] = true
			for i in range(_pending.size() - 1, -1, -1):
				if _pending[i][0] == n:
					_pending.remove_at(i)
			_place(n)
			if not _cursor.is_empty():
				_g.wires.append([int(_cursor[0].id), String(_cursor[1]), int(n.id), "exec"])
			_cursor = [n, "then"]
			_last_exec = n
		if out.has("n"):
			out["t"] = "any" if String(n.kind) != "call_self" else out.t
		return out if (want or not out.is_empty()) else {"none": true}
	if _inline_mode > 0:
		_fail("waiting for a signal in the middle of an expression")
		return {}
	# await get_tree().create_timer(seconds).timeout
	if not want and a.k == "attr" and String(a.name) == "timeout" and a.obj.k == "call" and a.obj.fn.k == "attr" and String(a.obj.fn.name) == "create_timer" \
			and a.obj.args.size() == 1 and a.obj.fn.obj.k == "call" and a.obj.fn.obj.fn.k == "name" and String(a.obj.fn.obj.fn.v) == "get_tree" \
			and a.obj.fn.obj.args.is_empty() and T.is_a(_cls, "Node") and not _funcs.has("get_tree"):
		var secs := _value(a.obj.args[0], 1)
		if secs.is_empty():
			return {}
		var w := _exec("tpl", {"id": "wait"})
		return {"none": true} if _wire(secs, w, "duration") else {}
	# what is waited for is worked out right there, in place
	_inline_mode += 1
	var sig := _signal_value(a, 1)
	_inline_mode -= 1
	if sig.is_empty():
		return {}
	var n2 := _exec("await_value", {})
	if not _wire(sig, n2, "v"):
		return {}
	return {"n": n2, "pin": "ret", "t": "any"} if want else {"none": true}


## A value for an expression that may name a signal (signals are not ordinary values to the other helpers).
func _signal_value(e: Variant, depth: int) -> Dictionary:
	var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "pending": _pending.size(), "failed": _failed}
	var v := _lower(e, depth)
	if v.has("n") or v.has("lit"):
		return v
	if v.has("sig"):
		return _sig_node(v, depth)
	if v.has("fnref"):
		return {"n": _data("event_ref", {"fn": String(v.fnref)}, depth), "pin": "fn", "t": "Callable"}
	if _failed == "":
		_fail("this can't be waited for")
	return {}


## A signal as a value: the script's own by its name, another object's read from that object by name.
func _sig_node(sig: Dictionary, depth: int) -> Dictionary:
	if bool(sig.get("own", false)):
		return {"n": _data("const", {"expr": String(sig.sig), "label": String(sig.sig), "t": "Signal"}, depth), "pin": "value", "t": "Signal"}
	var g := _data("dyn_get", {"name": String(sig.sig), "t": "Signal"}, depth)
	if not _wire(sig.target, g, "target"):
		return {}
	return {"n": g, "pin": "value", "t": "Signal"}


func _if_chain(branches: Array, at: int, else_body: Array) -> bool:
	var cond := _value(branches[at][0], 1)
	if cond.is_empty():
		return false
	_mark_unbracketed(branches[at][0], cond)
	var br := _exec("branch", {}, "exec", "true")
	if not _wire(cond, br, "cond"):
		return false
	var bx := float(br.x) + 300.0
	var by := float(br.y)
	_cx = bx
	_block(branches[at][1])
	var has_else := at + 1 < branches.size() or not else_body.is_empty()
	if has_else:
		_cursor = [br, "false"]
		_cx = bx
		_cy = _low + 70.0
		if at + 1 < branches.size():
			if not _if_chain(branches, at + 1, else_body):
				return false
		else:
			_block(else_body)
	return true


func _for(st: Dictionary) -> bool:
	if st.iter == null:
		return _fail("a loop the parser did not understand")
	var it: Dictionary = st.iter
	while it.k == "paren":
		it = it.a
	var shadowed: Variant = _scope.get(String(st["var"]))
	var iter_t := _type(it)
	if iter_t == "StringName" or (T.is_builtin(iter_t) and not iter_t in ["int", "Array", "Dictionary", "any", "String"] and not iter_t.begins_with("Array[") and not iter_t.begins_with("Packed")):
		return _fail("a loop over a %s" % iter_t)
	if is_range_step(it):
		# range(start, stop, step): a For Each over a Range node (written into the loop line, so no list is built)
		var rn := _data("tpl", {"id": "range"}, 1)
		var parts := _ordered(it.args, 2)
		if parts.size() != 3:
			return false
		for i in 3:
			if not _wire(parts[i], rn, ["from", "to", "step"][i]):
				return false
		# `for j: float in range(0, 2, 1)`: the loop variable has the type the script gave it
		var step_t := "int"
		var step_written := _norm(String(st.get("var_type", "")))
		if step_written != "" and step_written != "any" and T.hint(step_written) == step_written:
			step_t = step_written
		var each := _exec("for_each", {"t": step_t, "var": String(st["var"])}, "exec", "body")
		if step_written != "" and step_written != "any" and T.hint(step_written) != step_written:
			each.p["hint"] = String(st.var_type)
		_g.wires.append([int(rn.id), "ret", int(each.id), "array"])
		_scope[String(st["var"])] = {"k": "pin", "t": step_t, "n": each, "pin": "element"}
		var done := _loop_body(each, st.body)
		if shadowed != null:
			_scope[String(st["var"])] = shadowed
		else:
			_scope.erase(String(st["var"]))
		return done
	var n: Dictionary
	var is_range: bool = it.k == "call" and it.fn.k == "name" and it.fn.v == "range"
	# A counted loop only for what is surely an int: a loop variable with a type of its own is written as a For
	# Each with that type (`for j: float in range(2)` counts in floats), and a value that only happens to hold
	# an int (an untyped variable) may hold a float or a list when the loop is reached.
	var typed_var := String(st.get("var_type", "")) != ""
	if not typed_var and (is_range or _static_int(it)):
		var first: Variant = {"k": "num", "v": "0", "f": false}
		var stop: Variant = it
		if is_range:
			if it.args.size() == 2:
				first = it.args[0]
				stop = it.args[1]
			elif it.args.size() == 1:
				stop = it.args[0]
			else:
				return _fail("range() with a step")
		# For Loop's Last Index is inclusive
		var last_e: Variant = {"k": "bin", "op": "-", "a": stop, "b": {"k": "num", "v": "1", "f": false}}
		if stop.k == "num" and not bool(stop.f):
			last_e = {"k": "num", "v": str(int(String(stop.v)) - 1), "f": false}
		var fv := _value(first, 1)
		var lv := _value(last_e, 1)
		if fv.is_empty() or lv.is_empty():
			return false
		n = _exec("for", {"var": String(st["var"])}, "exec", "body")
		if not (_wire(fv, n, "first") and _wire(lv, n, "last")):
			return false
		_scope[String(st["var"])] = {"k": "pin", "t": "int", "n": n, "pin": "index"}
	elif _type(it) == "Dictionary" and not typed_var:
		var dv := _value(it, 1)
		if dv.is_empty():
			return false
		n = _exec("for_each_dict", {"var": String(st["var"])}, "exec", "body")
		if not _wire(dv, n, "dict"):
			return false
		_scope[String(st["var"])] = {"k": "pin", "t": "any", "n": n, "pin": "key"}
	else:
		var av := _value(it, 1)
		if av.is_empty():
			return false
		var et := _iter_type(it)
		if et == "int" and not is_range and not _static_int(it) and not _type(it).begins_with("Packed") and not _type(it).begins_with("Array["):
			et = "any"   # counting up to a value that may not be an int: the loop variable takes what the loop gives
		# `for item: Type in list`: the loop variable has the type the script gave it
		var written := _norm(String(st.get("var_type", "")))
		if written != "" and written != "any" and T.hint(written) == written:
			et = written
		n = _exec("for_each", {"t": et, "var": String(st["var"])}, "exec", "body")
		if written != "" and written != "any" and T.hint(written) != written:
			n.p["hint"] = String(st.var_type)   # a type no pin has (an enum, an inner class): kept in the loop's header
		if not _wire(av, n, "array"):
			return false
		_scope[String(st["var"])] = {"k": "pin", "t": et, "n": n, "pin": "element"}
	var ok := _loop_body(n, st.body)
	if shadowed != null:
		_scope[String(st["var"])] = shadowed
	else:
		_scope.erase(String(st["var"]))
	return ok


## True when an expression is an int whatever happens when the script runs: a literal, a variable, constant or
## parameter declared (or inferred with :=) as int, a loop's counter, a function or property typed int, or
## arithmetic on those. An untyped variable that holds an int is not: it could hold anything later.
func _static_int(e: Variant) -> bool:
	if e == null:
		return false
	match String(e.k):
		"num":
			return not bool(e.f)
		"paren":
			return _static_int(e.a)
		"un":
			return String(e.op) in ["-", "~"] and _static_int(e.a)
		"bin":
			return String(e.op) in ["+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^"] and _static_int(e.a) and _static_int(e.b)
		"tern":
			return _static_int(e.a) and _static_int(e.b)
		"as":
			return String(e.t) == "int"
		"name":
			var nm := String(e.v)
			if _scope.has(nm):
				var s: Dictionary = _scope[nm]
				if String(s.t) != "int":
					return false
				match String(s.k):
					"local":
						return bool(s.get("typed", false))
					"param":
						for prm in _funcs.get(_fn_name, {}).get("params", []):
							if String(prm[0]) == nm:
								return prm.size() < 4 or not String(prm[3]) in ["-", ""]
						return false
					"pin":
						return true   # an engine callback's parameter, or a loop's counter
				return false
			if _members.has(nm):
				return String(_members[nm]) == "int" and (_typed_members.has(nm) or _inferred_members.has(nm))
			if _consts.has(nm):
				return String(_consts[nm]) == "int"
			return _type(e) == "int"   # a property of the class: the engine declares its type
		"call":
			if e.fn.k == "name" and _funcs.has(String(e.fn.v)):
				return String(_funcs[String(e.fn.v)].get("declared_ret", "")) == "int"
			return _type(e) == "int"
		"attr":
			if e.obj.k == "name" and (_members.has(String(e.obj.v)) or _scope.has(String(e.obj.v))) and not _static_typed(e.obj):
				return false
			return _type(e) == "int"
	return false


## True when a variable read by name has a type the script declares (so what it holds is of that type).
func _static_typed(e: Dictionary) -> bool:
	var nm := String(e.v)
	if _scope.has(nm):
		return String(_scope[nm].k) == "pin" or bool(_scope[nm].get("typed", false))
	return _typed_members.has(nm) or _inferred_members.has(nm)


func is_range_step(it: Dictionary) -> bool:
	return it.k == "call" and it.fn.k == "name" and String(it.fn.v) == "range" and it.args.size() == 3 and not _funcs.has("range")


## True when a type written in the script is an enum: one of the script's own, of an engine class, of a class
## of the project (Class.Enum), or of the global scope.
func _is_enum_type(written: String) -> bool:
	var t := _norm(written)
	if t in GLOBAL_ENUMS or (_enum_names.has(t) and not bool(_enum_names[t])):
		return true
	if ClassDB.class_exists(_cls) and ClassDB.class_has_enum(_cls, t):
		return true
	if not t.contains("."):
		return false
	var owner := t.get_slice(".", 0)
	var last := t.get_slice(".", t.get_slice_count(".") - 1)
	if ClassDB.class_exists(owner):
		return ClassDB.class_has_enum(owner, last)
	var path := String(T.script_entry(owner).get("path", ""))
	if path == "" and _const_init.get(owner) is Dictionary and _const_init[owner].get("k", "") == "call" and not _const_init[owner].args.is_empty() 			and _const_init[owner].args[0] is Dictionary and _const_init[owner].args[0].get("k", "") == "str":
		path = String(_const_init[owner].args[0].v).trim_prefix("\"").trim_suffix("\"")   # const Owner := preload("res://owner.gd")
	if path != "" and ResourceLoader.exists(path):
		var scr := load(path) as Script
		if scr != null:
			var guard := 0
			while scr != null and guard < 16:
				var consts := scr.get_script_constant_map()
				if consts.has(last):
					return consts[last] is Dictionary
				scr = scr.get_base_script()
				guard += 1
	return false


## What a variable declared as `var x: type` with no value holds, as an expression.
func _default_value(written: String) -> Dictionary:
	var t := _norm(written)
	var base := t.get_slice("[", 0)
	match base:
		"", "any":
			return {"k": "null"}
		"int":
			return {"k": "num", "v": "0", "f": false}
		"float":
			return {"k": "num", "v": "0.0", "f": true}
		"bool":
			return {"k": "bool", "v": "false"}
		"String":
			return {"k": "str", "v": "\"\""}
		"StringName":
			return {"k": "str", "v": "&\"\""}
		"NodePath":
			return {"k": "str", "v": "^\"\""}
		"Array":
			return {"k": "array", "items": []}
		"Dictionary":
			return {"k": "dict", "pairs": []}
	if _is_enum_type(t):
		return {"k": "const_text", "src": "(0 as %s)" % t, "t": "int"}   # an enum starts at 0, stated as that enum
	if T.hint(base) != "" and not T.is_object(base):
		return {"k": "call", "fn": {"k": "name", "v": base}, "args": []}   # Vector3(), Color(), PackedInt32Array() ...
	return {"k": "null"}


func _loop_body(n: Dictionary, body: Array) -> bool:
	_cx = float(n.x) + 320.0
	_loop_depth += 1
	_block(body)
	_loop_depth -= 1
	_cursor = [n, "completed"]
	_cx = float(n.x) + 320.0
	_cy = _low + 70.0
	return true


# ---------------------------------------------------------------- assignment

func _assign(st: Dictionary) -> bool:
	var target: Dictionary = st.target
	var value: Variant = st.value
	if st.op != "=":
		if not _simple(target):
			return _fail("compound assignment to something that is not a plain variable or property")
		# `x += amount`: a Set node that changes what is there. The amount is worked out in place, as written.
		var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "pending": _pending.size(), "failed": _failed,
			"cursor": _cursor.duplicate(), "cx": _cx, "cy": _cy, "low": _low, "locals": _g.locals.duplicate(true)}
		_inline_mode += 1
		var amount := _value(st.value, 1)
		_inline_mode -= 1
		if not amount.is_empty():
			_mark_unbracketed(st.value, amount)
			var done := _store_op(target, String(st.op).trim_suffix("="), amount)
			if done == 1:
				return true
		_g.nodes.resize(int(mark.nodes))
		_g.wires.resize(int(mark.wires))
		_g.next_id = int(mark.next)
		_pending.resize(int(mark.pending))
		_failed = String(mark.failed)
		_cursor = mark.cursor
		_cx = float(mark.cx)
		_cy = float(mark.cy)
		_low = float(mark.low)
		_g.locals = mark.locals
		value = {"k": "bin", "op": String(st.op).trim_suffix("="), "a": target, "b": {"k": "paren", "a": st.value}}
	var plain: Dictionary = target
	while plain.k == "paren":
		plain = plain.a
	_keep_step = plain.k == "name" or (plain.k == "attr" and plain.obj.k == "self")
	var val := _value(value, 1)
	_keep_step = false
	if val.is_empty():
		return false
	if st.op == "=":
		_mark_unbracketed(value, val)
	return _store(target, val)


## `target op= amount` as one Set node, for a variable, a property, or one member of a vector held in either.
## 1 done, 0 not one of these cases (nothing was added to the execution path in that case).
func _store_op(target: Dictionary, op: String, amount: Dictionary) -> int:
	var t: Dictionary = target
	while t.k == "paren":
		t = t.a
	if t.k == "attr" and t.obj.k == "self":
		t = {"k": "name", "v": t.name}
	if t.k == "name":
		var nm := String(t.v)
		var n := {}
		if _scope.has(nm):
			if _scope[nm].k == "param" and _is_fn:
				_param_local(nm, String(_scope[nm].t))
				n = _exec("local_set", {"name": nm, "op": op})
			elif _scope[nm].k == "local":
				n = _exec("local_set", {"name": String(_scope[nm].name), "op": op})
			else:
				return 0
		elif _members.has(nm):
			n = _exec("var_set", {"name": nm, "op": op})
		elif not R.find_property(_cls, nm).is_empty():
			n = _exec("set_prop", {"cls": _cls, "prop": nm, "op": op})
		else:
			return 0
		return 1 if _wire(amount, n, "value") else 0
	if t.k != "attr":
		return 0
	var bt := _type(t.obj)
	if R.SPLIT.has(bt) and String(t.name) in R.SPLIT[bt][0]:
		return 1 if _store_part(t.obj, String(t.name), amount, op) == 1 else 0
	if T.is_object(bt) and not R.find_property(bt, String(t.name)).is_empty():
		var obj := _value(t.obj, 1)
		if obj.is_empty():
			return 0
		var n := _exec("set_prop", {"cls": bt, "prop": String(t.name), "op": op})
		return 1 if (_wire(obj, n, "target") and _wire(amount, n, "value")) else 0
	return 0


## True when reading the expression twice is harmless (names, members, $nodes).
func _simple(e: Variant) -> bool:
	if e == null:
		return false
	match String(e.k):
		"name", "self", "node", "num", "str", "bool":
			return true
		"attr":
			return _simple(e.obj)
		"index":
			return _simple(e.obj) and _simple(e.i)
		"paren", "as":
			return _simple(e.a)   # `x as T` changes nothing: reading it twice is harmless
	return false


func _store(target: Dictionary, val: Dictionary) -> bool:
	match String(target.k):
		"name":
			return _store_name(String(target.v), val)
		"attr":
			if target.obj.k == "self":
				return _store_name(String(target.name), val)
			var bt := _type(target.obj)
			var members := R.break_members(bt)
			var member_at := -1
			for i in members.size():
				if String(members[i][0]) == String(target.name):
					member_at = i
			if member_at != -1 and R.SPLIT.has(bt) and _simple(target.obj):
				# one member of a vector or colour held in a variable or property: set in place
				var part := _store_part(target.obj, String(target.name), val)
				if part != 0:
					return part == 1
			if member_at != -1 and not R.SPLIT.has(bt) and _simple(target.obj):
				# a member of a transform, a rectangle...: set on the place it is held, by name (`xform.origin = ...`)
				var place := _holder(target.obj, 1)
				if place.is_empty():
					return false
				var sn := _exec("dyn_set", {"name": String(target.name)})
				return _wire(place, sn, "target") and _wire(val, sn, "value")
			if member_at != -1:
				# a struct is a value: build the changed struct, then store it back where it came from
				if not R.SPLIT.has(bt) or not _simple(target.obj):
					return _fail("setting one member of a %s" % bt)
				var names: Array = R.SPLIT[bt][0]
				var ci := _ctor_index(bt, names.size())
				if ci == -1:
					return _fail("no constructor for %s" % bt)
				var cur := _value(target.obj, 3)
				if cur.is_empty():
					return false
				var brk := _data("break", {"type": bt}, 2)
				if not _wire(cur, brk, "v"):
					return false
				var made := _data("ctor", {"type": bt, "i": ci}, 1)
				for i in names.size():
					if String(names[i]) == String(target.name):
						if not _wire(val, made, "a%d" % i):
							return false
					else:
						_g.wires.append([int(brk.id), "m_" + String(names[i]), int(made.id), "a%d" % i])
				return _store(target.obj, {"n": made, "pin": "ret", "t": bt})
			if T.is_object(bt) and not R.find_property(bt, String(target.name)).is_empty():
				var obj := _value(target.obj, 1)
				if obj.is_empty():
					return false
				var n := _exec("set_prop", {"cls": bt, "prop": String(target.name)})
				return _wire(obj, n, "target") and _wire(val, n, "value")
			# the type is not known here: set it by name, as the script does
			var holder := _holder(target.obj, 1)
			if holder.is_empty():
				return false
			var dn := _exec("dyn_set", {"name": String(target.name)})
			return _wire(holder, dn, "target") and _wire(val, dn, "value")
		"index":
			var c := _value(target.obj, 1)
			var k := _value(target.i, 1)
			if c.is_empty() or k.is_empty():
				return false
			var n := _exec("set_index", {})
			return _wire(c, n, "c") and _wire(k, n, "k") and _wire(val, n, "v")
	return _fail("can't assign to this")


## Sets one member (x, y, r...) of a struct held in a local, a variable or a property. 1 done, -1 failed, 0 not this case.
func _store_part(holder: Dictionary, part: String, val: Dictionary, op := "") -> int:
	var extra := {"op": op} if op != "" else {}
	var h: Dictionary = holder
	while h.k == "paren":
		h = h.a
	if h.k == "attr" and h.obj.k == "self":
		h = {"k": "name", "v": h.name}
	if h.k == "name":
		var nm := String(h.v)
		if _scope.has(nm):
			if _scope[nm].k == "param" and _is_fn:
				_param_local(nm, String(_scope[nm].t))
				var pn := _exec("local_set", {"name": nm, "part": part}.merged(extra))
				return 1 if _wire(val, pn, "value") else -1
			if _scope[nm].k != "local":
				return 0
			var n := _exec("local_set", {"name": String(_scope[nm].name), "part": part}.merged(extra))
			return 1 if _wire(val, n, "value") else -1
		if _members.has(nm):
			var n := _exec("var_set", {"name": nm, "part": part}.merged(extra))
			return 1 if _wire(val, n, "value") else -1
		if not R.find_property(_cls, nm).is_empty():
			var n := _exec("set_prop", {"cls": _cls, "prop": nm, "part": part}.merged(extra))
			return 1 if _wire(val, n, "value") else -1
		return 0
	if h.k == "attr":
		var ot := _type(h.obj)
		if T.is_object(ot) and not R.find_property(ot, String(h.name)).is_empty():
			var obj := _value(h.obj, 1)
			if obj.is_empty():
				return -1
			var n := _exec("set_prop", {"cls": ot, "prop": String(h.name), "part": part}.merged(extra))
			return 1 if (_wire(obj, n, "target") and _wire(val, n, "value")) else -1
	return 0


## The thing a member is read from or set on, when its type is not known: a value, or a class, singleton or
## constant referred to by its name.
func _holder(e: Variant, depth: int) -> Dictionary:
	var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "pending": _pending.size(), "failed": _failed}
	var v := _lower(e, depth)
	if v.has("n") or v.has("lit"):
		return v
	if v.has("typeref"):
		return {"n": _data("const", {"expr": String(v.typeref), "label": String(v.typeref), "t": "any"}, depth), "pin": "value", "t": "any"}
	if v.has("sig"):
		return _sig_node(v, depth)
	if v.has("fnref"):
		return {"n": _data("event_ref", {"fn": String(v.fnref)}, depth), "pin": "fn", "t": "Callable"}
	return {}


## A parameter the function assigns to is listed among the graph's locals (marked as a parameter, so it is
## not declared a second time): Set nodes can then write to it, and reading it still comes off the entry node.
func _param_local(nm: String, type: String) -> void:
	for l in _g.locals:
		if String(l.name) == nm:
			return
	_g.locals.append({"name": nm, "type": type, "default": "", "param": true})


func _store_name(nm: String, val: Dictionary) -> bool:
	if _scope.has(nm):
		var s: Dictionary = _scope[nm]
		if s.k == "param" and _is_fn:
			_param_local(nm, String(s.t))
			var pn := _exec("local_set", {"name": nm})
			return _wire(val, pn, "value")
		if s.k != "local":
			return _fail("assigning to a loop variable or an event's parameter")
		var n := _exec("local_set", {"name": String(s.name)})
		return _wire(val, n, "value")
	if _members.has(nm):
		var n := _exec("var_set", {"name": nm})
		return _wire(val, n, "value")
	if not R.find_property(_cls, nm).is_empty():
		var n := _exec("set_prop", {"cls": _cls, "prop": nm})
		return _wire(val, n, "value")
	return _fail("'%s' is not a variable of this script" % nm)


func _ctor_index(type: String, count: int) -> int:
	var ctors: Array = R.api.types.get(type, {}).get("ctor", [])
	for want in ["float", "int"]:
		for i in ctors.size():
			if ctors[i].size() == count and ctors[i].all(func(a): return String(a[1]) == want):
				return i
	return -1


# ---------------------------------------------------------------- expressions

## A value for an input pin: {lit, t} for a literal typed straight onto the pin, or {n, pin, t} for a wire.
## When the expression can't be built from nodes but is free of calls, it becomes one Math Expression node.
func _value(e: Variant, depth: int) -> Dictionary:
	var lit := _literal(e)
	if lit != "":
		return {"lit": lit, "t": _type(e)}
	var mark := {"nodes": _g.nodes.size(), "wires": _g.wires.size(), "next": int(_g.next_id), "pending": _pending.size(), "failed": _failed}
	var val := _lower(e, depth)
	if not val.is_empty() and (val.has("n") or val.has("lit")):
		return val
	if val.has("fnref"):
		return {"n": _data("event_ref", {"fn": String(val.fnref)}, depth), "pin": "fn", "t": "Callable"}
	if not val.is_empty():
		_fail("this can't be used as a value")
	if not _call_free(e):
		return {}
	_g.nodes.resize(int(mark.nodes))
	_g.wires.resize(int(mark.wires))
	_g.next_id = int(mark.next)
	_pending.resize(int(mark.pending))
	_failed = String(mark.failed)
	return _expr_node(e, depth)


func _call_free(e: Variant) -> bool:
	if e == null:
		return true
	match String(e.k):
		"call", "raw", "await", "lambda":
			return false
		"un", "paren", "is", "as":
			return _call_free(e.a)
		"bin":
			return _call_free(e.a) and _call_free(e.b)
		"tern":
			return _call_free(e.a) and _call_free(e.b) and _call_free(e.c)
		"attr":
			return _call_free(e.obj)
		"index":
			return _call_free(e.obj) and _call_free(e.i)
		"array":
			return e.items.all(func(it): return _call_free(it))
		"dict":
			return e.pairs.all(func(pr): return _call_free(pr[0]) and _call_free(pr[1]))
	return true


## Text for a pin default when the expression is a constant, "" otherwise.
func _literal(e: Variant) -> String:
	if e == null:
		return ""
	match String(e.k):
		"num", "str", "bool":
			return String(e.v)
		"null":
			return "null"
		"paren":
			var inner := _literal(e.a)
			return ("(%s)" % inner) if inner != "" else ""
		"un":
			var a := _literal(e.a)
			return Parser.unparse(e) if a != "" else ""
		"bin":
			return Parser.unparse(e) if (_literal(e.a) != "" and _literal(e.b) != "") else ""
		"array":
			return Parser.unparse(e) if e.items.all(func(it): return _literal(it) != "") else ""
		"dict":
			return Parser.unparse(e) if e.pairs.all(func(pr): return _literal(pr[0]) != "" and _literal(pr[1]) != "") else ""
		"name":
			return String(e.v) if ((CONSTANTS.has(String(e.v)) or _consts.has(String(e.v))) and not _scope.has(String(e.v)) and not _members.has(String(e.v))) else ""
		"attr":
			if e.obj.k == "name" and _is_typeref(String(e.obj.v)) and _type(e) != "any":
				return Parser.unparse(e)
		"call":
			if e.fn.k == "name" and (R.api.types.has(String(e.fn.v)) or String(e.fn.v) == "preload") and not _funcs.has(String(e.fn.v)) \
					and e.args.all(func(a): return _literal(a) != ""):
				return Parser.unparse(e)
	return ""


func _expr_node(e: Variant, depth: int) -> Dictionary:
	var text := Parser.unparse(e)
	var ins := []
	var wires := []
	text = _bind_names(text, ins, wires, depth + 1)
	var n := _data("expr", {"code": text, "ins": ins, "t": _type(e)}, depth)
	for w in wires:
		_wire(w[1], n, "x_" + String(w[0]))
	notes.append("expression kept as a Math Expression node: %s" % text)
	return {"n": n, "pin": "ret", "t": _type(e)}


## Makes source text usable inside an expression or code node: names that are wires in the graph (loop
## variables, event parameters, $node shortcuts) become inputs; renamed locals are renamed in the text.
func _bind_names(text: String, ins: Array, wires: Array, depth: int) -> String:
	var compiler := Compiler
	for nm in _scope:
		var s: Dictionary = _scope[nm]
		if compiler._replace_word(text, String(nm), "\u0001") == text:
			continue
		if s.k == "pin":
			ins.append(String(nm))
			wires.append([String(nm), {"n": s.n, "pin": s.pin, "t": s.t}])
		elif s.k == "local" and String(s.name) != String(nm):
			text = compiler._replace_word(text, String(nm), String(s.name))
	for nm in _alias:
		if compiler._replace_word(text, String(nm), "\u0001") == text:
			continue
		ins.append(String(nm))
		var gn := _data("get_node", {"path": String(_alias[nm].path), "cls": String(_alias[nm].cls)}, depth)
		wires.append([String(nm), {"n": gn, "pin": "node", "t": String(_alias[nm].cls)}])
	return text


func _code(text: String) -> void:
	if text.contains("await "):
		_awaits = true
	var ins := []
	var wires := []
	_pending.clear()
	text = _bind_names(text, ins, wires, 1)
	var n := _exec("code", {"code": text, "ins": ins})
	for w in wires:
		_wire(w[1], n, "x_" + String(w[0]))


## Builds nodes for an expression. Returns {} when it can't; may also return a non-value reference
## ({typeref}, {sig}, {fnref}) that only makes sense as part of a larger expression.
func _lower(e: Variant, depth: int) -> Dictionary:
	if e == null:
		_fail("an expression the parser did not understand")
		return {}
	match String(e.k):
		"paren":
			return _lower(e.a, depth)
		"const_text":
			return {"n": _data("const", {"expr": String(e.src), "label": String(e.src), "t": String(e.get("t", "any"))}, depth), "pin": "value", "t": String(e.get("t", "any"))}
		"num", "str", "bool":
			return {"lit": String(e.v), "t": _type(e)}
		"null":
			return {"lit": "null", "t": "any"}
		"self":
			return {"n": _data("self", {}, depth), "pin": "self", "t": _cls}
		"node":
			var path := String(e.path)
			var cls := String(_nodes_cls.get(path, "Node"))
			return {"n": _data("get_node", {"path": path, "cls": cls}, depth), "pin": "node", "t": cls}
		"name":
			return _name(String(e.v), depth)
		"attr":
			return _attr(e, depth)
		"index":
			var c := _value(e.obj, depth + 1)
			var k := _value(e.i, depth + 1)
			if c.is_empty() or k.is_empty():
				return {}
			var n := _data("index", {}, depth)
			if not (_wire(c, n, "c") and _wire(k, n, "k")):
				return {}
			return {"n": n, "pin": "ret", "t": _type(e)}
		"un":
			var a := _value(e.a, depth + 1)
			if a.is_empty():
				return {}
			if e.op == "not":
				var n := _data("math", {"op": "not", "n": 1}, depth)
				return {"n": n, "pin": "ret", "t": "bool"} if _wire(a, n, "a0") else {}
			if e.op in ["-", "~"]:
				var negated := _type(e)
				var n := _data("op", {"op": "unary" + String(e.op), "l": String(a.get("t", "any")), "r": "", "ret": negated}, depth)
				return {"n": n, "pin": "ret", "t": negated} if _wire(a, n, "a") else {}
			_fail("the %s operator" % e.op)
			return {}
		"bin":
			var a := _value(e.a, depth + 1)
			if a.is_empty():
				return {}
			# Whatever the right side calls must not run before the left side is read, and after `and` / `or`
			# it must only run when the left side says so: it runs in place.
			var guard: bool = a.has("n") or String(e.op) in ["and", "or"]
			if guard:
				_inline_mode += 1
			var b := _value(e.b, depth + 1)
			if guard:
				_inline_mode -= 1
			if b.is_empty():
				return {}
			if not R.MATH_OPS.has(String(e.op)):
				# in, the bit operators, **: an operator node of exactly that kind
				var on := _data("op", {"op": String(e.op), "l": String(a.get("t", "any")), "r": String(b.get("t", "any")), "ret": _type(e)}, depth)
				if not (_wire(a, on, "a") and _wire(b, on, "b")):
					return {}
				return {"n": on, "pin": "ret", "t": _type(e)}
			var n := _data("math", {"op": String(e.op), "n": 2}, depth)
			if not (_wire(a, n, "a0") and _wire(b, n, "a1")):
				return {}
			return {"n": n, "pin": "ret", "t": _type(e)}
		"tern":
			# only the chosen side may run, after the condition: all three run in place
			_inline_mode += 1
			var c := _value(e.c, depth + 1)
			var a := _value(e.a, depth + 1) if not c.is_empty() else {}
			var b := _value(e.b, depth + 1) if not a.is_empty() else {}
			_inline_mode -= 1
			if a.is_empty() or b.is_empty() or c.is_empty():
				return {}
			var n := _data("select", {"t": _type(e)}, depth)
			if not (_wire(a, n, "a") and _wire(b, n, "b") and _wire(c, n, "pick")):
				return {}
			return {"n": n, "pin": "ret", "t": _type(e)}
		"array":
			var n := _data("make_array", {"n": e.items.size()}, depth)
			var items := _ordered(e.items, depth + 1)
			if items.size() != e.items.size():
				return {}
			for i in items.size():
				if not _wire(items[i], n, "e%d" % i):
					return {}
			return {"n": n, "pin": "ret", "t": "Array"}
		"dict":
			var flat := []
			for pr in e.pairs:
				flat.append(pr[0])
				flat.append(pr[1])
			var n := _data("make_dict", {"n": e.pairs.size()}, depth)
			var vals := _ordered(flat, depth + 1)
			if vals.size() != flat.size():
				return {}
			for i in e.pairs.size():
				if not (_wire(vals[i * 2], n, "k%d" % i) and _wire(vals[i * 2 + 1], n, "v%d" % i)):
					return {}
			return {"n": n, "pin": "ret", "t": "Dictionary"}
		"call":
			return _call(e, depth, true)
		"await":
			return _await(e, depth, true)
		"lambda":
			return _lambda(e, depth)
		"is":
			var tested := _value(e.a, depth + 1)
			if tested.is_empty():
				return {}
			var n := _data("is_type", {"type": String(e.t)}, depth)
			return {"n": n, "pin": "ret", "t": "bool"} if _wire(tested, n, "v") else {}
		"as":
			if not T.class_known(String(e.t)):
				# a built-in type (Dictionary, Array, Vector3...) or a class this editor has no pin for
				var src := _value(e.a, depth + 1)
				if src.is_empty():
					return {}
				var an := _data("as_type", {"type": String(e.t)}, depth)
				return {"n": an, "pin": "ret", "t": String(e.t) if T.hint(String(e.t)) != "" else "any"} if _wire(src, an, "v") else {}
			var obj := _value(e.a, depth + 1)
			if obj.is_empty():
				return {}
			var looked_up: Variant = e.a
			while looked_up is Dictionary and looked_up.k == "paren":
				looked_up = looked_up.a
			if obj.has("n") and String(obj.n.kind) == "get_node" and String(e.t) != "Node" and T.hint(String(e.t)) != "" \
					and looked_up is Dictionary and (looked_up.k == "node" or _is_get_node(looked_up)):
				# `get_node(path) as T` (or `$Path as T`) is what a Get Node node of class T is written as
				obj.n.p["cls"] = String(e.t)
				return {"n": obj.n, "pin": "node", "t": String(e.t)}
			var n := _data("cast", {"cls": String(e.t), "pure": true}, depth)
			return {"n": n, "pin": "as", "t": String(e.t)} if _wire(obj, n, "obj") else {}
	_fail("'%s' expressions" % e.k)
	return {}


func _name(nm: String, depth: int) -> Dictionary:
	if _scope.has(nm):
		var s: Dictionary = _scope[nm]
		if s.k == "local":
			return {"n": _data("local_get", {"name": String(s.name)}, depth), "pin": "value", "t": String(s.t)}
		if s.k in ["pin", "param"] and s.get("n") is Dictionary and is_same(s.n, _entry) and String(s.get("pin", "")).begins_with("p_") 				and (_cx - float(_entry.x) > FAR or _cy - float(_entry.y) > FAR * 0.5):
			# A parameter of the event or function, read a long way from where it comes in: a small node
			# with its name stands next to the reader, instead of a wire running the length of the graph.
			# (It is written as the bare name, which is what the wire would have been written as.)
			var param_name := String(s.get("written", String(s.pin).trim_prefix("p_")))
			# `of` / `in`: the entry node this is a parameter of, and the graph it is in. The compiler refuses
			# to write the name anywhere the entry's own nodes do not run (see Compiler._name_place).
			return {"n": _data("const", {"expr": param_name, "label": param_name, "t": String(s.t), "of": int(_entry.id), "in": int(_g.id)}, depth), "pin": "value", "t": String(s.t)}
		if s.k == "bound":
			# a name a match pattern binds: it exists where the arm's nodes are written, and is read by name
			# `bound`: the name belongs to one case of a Match. `of`: that Match node (a Switch), `arm`: the output
			# pin of the case on it (case_N or default), `in`: the graph.
			return {"n": _data("const", {"expr": String(s.name), "label": String(s.name), "t": "any", "bound": true, "of": int(s.of), "arm": String(s.arm), "in": int(_g.id)}, depth), "pin": "value", "t": "any"}
		return {"n": s.n, "pin": String(s.pin), "t": String(s.t)}
	if _alias.has(nm):
		var a: Dictionary = _alias[nm]
		return {"n": _data("get_node", {"path": String(a.path), "cls": String(a.cls)}, depth), "pin": "node", "t": String(a.cls)}
	if _members.has(nm):
		return {"n": _data("var_get", {"name": nm}, depth), "pin": "value", "t": String(_members[nm])}
	if _signals.has(nm):
		return {"sig": nm, "own": true}
	if _funcs.has(nm):
		return {"fnref": nm}
	if CONSTANTS.has(nm):
		return {"lit": nm, "t": String(CONSTANTS[nm])}
	if _consts.has(nm):
		return {"lit": nm, "t": String(_consts[nm])}
	if _enum_names.has(nm):
		return {"typeref": nm}
	if not R.find_property(_cls, nm).is_empty():
		return {"n": _data("get_prop", {"cls": _cls, "prop": nm}, depth), "pin": "value", "t": T.from_info(R.find_property(_cls, nm))}
	if not R.find_signal(_cls, nm).is_empty():
		return {"sig": nm, "own": true, "cls": _cls}   # a signal of the parent class
	if not R.find_method(_cls, nm).is_empty():
		# a function of the parent class, named without calling it: a reference to it
		return {"n": _data("const", {"expr": nm, "label": nm, "t": "Callable"}, depth), "pin": "value", "t": "Callable"}
	for al in R.autoloads():
		if String(al[0]) == nm:
			return {"n": _data("autoload", {"name": nm, "cls": String(al[1])}, depth), "pin": "value", "t": String(al[1])}
	if T.class_known(nm) or R.api.types.has(nm) or Engine.has_singleton(nm):
		return {"typeref": nm}
	if nm == nm.to_upper() and nm.is_valid_identifier() and not nm.is_valid_int():
		# a constant of the engine or of a parent class (OK, KEY_ESCAPE, CONNECT_ONE_SHOT, SUCCESS...)
		return {"n": _data("const", {"expr": nm, "label": nm, "t": "any"}, depth), "pin": "value", "t": "any"}
	_fail("'%s' is not something this script declares" % nm)
	return {}


func _attr(e: Dictionary, depth: int) -> Dictionary:
	if e.obj.k == "self":
		return _name(String(e.name), depth)
	var obj := _lower(e.obj, depth + 1)
	if obj.is_empty():
		return {}
	var nm := String(e.name)
	if obj.has("typeref"):
		var tr := String(obj.typeref)
		var ct := _type(e)
		if ct != "any" or _enum_names.has(tr) or R.api.types.has(tr):
			return {"n": _data("const", {"expr": "%s.%s" % [tr, nm], "t": ct, "label": "%s.%s" % [tr, nm]}, depth), "pin": "value", "t": ct}
		if T.class_known(tr) and not R.find_signal(tr, nm).is_empty():
			return {"sig": nm, "cls": tr, "target": {"n": _data("const", {"expr": tr, "label": tr, "t": "any"}, depth + 1), "pin": "value", "t": "any"}}
		# a property of a singleton, or a constant of a class: read by name
		var from := _data("const", {"expr": tr, "label": tr, "t": "any"}, depth + 1)
		var got := _data("dyn_get", {"name": nm}, depth)
		_g.wires.append([int(from.id), "value", int(got.id), "target"])
		return {"n": got, "pin": "value", "t": "any"}
	if obj.has("sig"):
		obj = _sig_node(obj, depth + 1)
	elif obj.has("fnref"):
		obj = {"n": _data("event_ref", {"fn": String(obj.fnref)}, depth + 1), "pin": "fn", "t": "Callable"}
	if not obj.has("n") and not obj.has("lit"):
		_fail("a member of something that is not a value")
		return {}
	var ot := String(obj.t)
	for m in R.break_members(ot):
		if String(m[0]) == nm:
			# a vector or colour read straight off the getter that was just made: split that pin
			if R.SPLIT.has(ot) and obj.has("n") and String(obj.pin) == "value" and String(obj.n.kind) in ["var_get", "local_get", "get_prop"] \
					and _pending.any(func(it): return it[0] == obj.n) and nm in R.SPLIT[ot][0]:
				if not obj.n.has("split"):
					obj.n["split"] = {}
				obj.n.split["value"] = true
				return {"n": obj.n, "pin": "value~" + nm, "t": String(R.SPLIT[ot][1])}
			var brk := _data("break", {"type": ot}, depth)
			if not _wire(obj, brk, "v"):
				return {}
			return {"n": brk, "pin": "m_" + nm, "t": R.api_type(String(m[1]))}
	if T.is_object(ot):
		if not R.find_property(ot, nm).is_empty():
			var gp := _data("get_prop", {"cls": ot, "prop": nm}, depth)
			if not _wire(obj, gp, "target"):
				return {}
			return {"n": gp, "pin": "value", "t": T.from_info(R.find_property(ot, nm))}
		if not R.find_signal(ot, nm).is_empty():
			return {"sig": nm, "cls": ot, "target": obj}
	# the type is not known here (an untyped value, or a member a script adds): read by name, as the script does
	var dg := _data("dyn_get", {"name": nm}, depth)
	if not _wire(obj, dg, "target"):
		return {}
	return {"n": dg, "pin": "value", "t": "any"}


## Finishes a call-like node: feeds the arguments and returns its value. Pure nodes stay data nodes; nodes
## with an exec pin are placed on the execution path right here, before whatever uses their result.
func _finish(n: Dictionary, args: Array, depth: int, target: Dictionary, want: bool, is_data: bool) -> Dictionary:
	var d := R.describe(n, bp, _g)
	if String(d.err) != "":
		_fail(String(d.err))
		return {}
	var pins := []
	for pi in d.ins:
		if pi.type != "exec" and pi.id != "target":
			pins.append(String(pi.id))
	if args.size() > pins.size():
		# variadic: ask the node for more pins
		match String(n.kind):
			"util": n.p["n"] = args.size()
			"call", "bcall": n.p["n"] = args.size() - pins.size() + int(n.p.get("n", 0))
			_:
				_fail("too many arguments")
				return {}
		d = R.describe(n, bp, _g)
		pins = []
		for pi in d.ins:
			if pi.type != "exec" and pi.id != "target":
				pins.append(String(pi.id))
		if args.size() > pins.size():
			_fail("too many arguments")
			return {}
	if not target.is_empty() and not _wire(target, n, "target"):
		return {}
	var vals := _ordered(args, depth + 1)
	if vals.size() != args.size():
		return {}
	for i in vals.size():
		if not _wire(vals[i], n, pins[i]):
			return {}
	_last_call = n
	# A call whose value is used runs where it is read, exactly as the script has it, with no temporary. The
	# exception is a call that is the whole value of a Set or Return (the compiler writes `x = f()` for that).
	var in_place: bool = _inline_mode > 0 or (want and not (_keep_step and depth <= 1))
	if not bool(d.pure) and in_place and d.outs.any(func(o): return o.type != "exec"):
		# it has to run where its value is read: it stays a value node, told to run in place
		n.p["inline"] = true
		d = R.describe(n, bp, _g)
	if bool(d.pure) and String(n.kind) in R.CALL_KINDS and not d.outs.any(func(o): return o.type != "exec"):
		# It gives nothing back, so nothing would ever ask it to run (call_deferred on a function reference, say):
		# it is a step.
		n.p["exec"] = true
		d = R.describe(n, bp, _g)
	if not bool(d.pure):
		# it was created as a data node: move it onto the execution path
		for i in range(_pending.size() - 1, -1, -1):
			if _pending[i][0] == n:
				_pending.remove_at(i)
		_place(n)
		if not _cursor.is_empty():
			_g.wires.append([int(_cursor[0].id), String(_cursor[1]), int(n.id), "exec"])
		_cursor = [n, "then"]
		_last_exec = n
	var out := _out_pin(n)
	if out.is_empty():
		if want:
			_fail("this call returns nothing")
		return {"none": true} if not want else {}
	return {"n": n, "pin": String(out.id), "t": String(out.type)}


## A lambda becomes a function of the schematic. What it captures from the function around it (locals,
## parameters, loop variables) is handed over as extra parameters bound to the reference, which is what
## GDScript does too: a lambda takes a copy of each at the moment it is made.
func _lambda(e: Dictionary, depth: int) -> Dictionary:
	var text := String(e.src)
	var own := {}
	for prm in e.params:
		own[String(prm.name)] = true
	var loops := {}
	var locals := {}
	_collect_names(e.body, loops, locals)
	var captured := []
	for nm in _scope:
		if own.has(nm) or locals.has(nm) or loops.has(nm):
			continue
		if Compiler._replace_word(text, String(nm), "\u0001") != text:
			captured.append(String(nm))
	captured.sort()
	var taken := Model.member_names(bp)
	taken.append_array(_funcs.keys())
	taken.append_array(_members.keys())
	var fname := Model.unique_name("_%s_lambda" % _fn_name.trim_prefix("_"), taken)
	var params := []
	var ast_params: Array = e.params.duplicate()
	for prm in e.params:
		var pt := _norm(String(prm.type))
		if pt == "" and prm.default != null and bool(prm.get("infer", false)):
			pt = _type(prm.default)
		var entry := [String(prm.name), pt if pt != "" else "any"]
		if prm.default != null:
			entry.append(Parser.unparse(prm.default))
		if _loses(String(prm.type)):
			entry[1] = "any"
			while entry.size() < 3:
				entry.append("")
			entry.append(String(prm.type))
		elif String(prm.type) == "":
			while entry.size() < 3:
				entry.append("")
			entry.append(":=" if bool(prm.get("infer", false)) else "-")   # untyped as written (see _declare_functions)
		params.append(entry)
	var has_default: bool = e.params.any(func(prm): return prm.default != null)
	for nm in captured:
		var ct := String(_scope[nm].t)
		if has_default:
			# a parameter without a default can't follow one with a default
			params.append([nm, "any", "null"])
		else:
			params.append([nm, ct if (ct == "any" or T.hint(ct) != "") else "any"])
		ast_params.append({"name": nm, "type": "", "default": null})
	var declared := _norm(String(e.ret))
	var returns := declared != "" and declared != "void"
	if declared == "":
		var saved := _scope
		_scope = {}
		returns = _return_type(e.body) != ""
		_scope = saved
	var required := 0
	for prm in e.params:
		if prm.default == null:
			required += 1
	_funcs[fname] = {"params": params, "ret": (declared if declared != "" else "any") if returns else "", "event": false, "void": not returns,
		"required": required + captured.size()}
	var keep := {"g": _g}
	var fg := Model.new_graph(bp, fname, "function")
	fg.inputs = params.duplicate(true)
	if returns:
		fg.outputs = [["result", String(_funcs[fname].ret)]]
		if _loses(declared):
			fg["ret_hint"] = declared
			fg.outputs = [["result", "any"]]
			_funcs[fname].ret = "any"
	if declared == "":
		fg["ret_hint"] = "-"   # written without a return type
	if bool(keep.g.get("static", false)):
		fg["static"] = true
	# `lambda`: this graph is a lambda of the script, and its last N inputs are the values it captures. The compiler
	# writes such a graph back as a lambda where it is used (capturing those values by name), when it can show
	# that means the same; otherwise as this function with the captured values bound, as it always did.
	fg["lambda"] = captured.size()
	fg.nodes.remove_at(1)
	_lambda_queue.append({"f": {"name": fname, "params": ast_params, "ret": String(e.ret), "body": e.body, "body_text": String(e.get("body_text", "pass"))}, "graph": fg})
	notes.append("a lambda in %s became the function %s%s" % [_fn_name, fname, (", bound to " + ", ".join(captured)) if not captured.is_empty() else ""])
	if bool(e.get("wrap", false)) or (has_default and not captured.is_empty()):
		# Handed straight to connect(), it must stay a Callable of its own, as every lambda is. And bound
		# values are added after whatever the caller passes, so they can't follow a parameter the caller may
		# leave out: the Lambda node passes every parameter itself.
		var cl := _data("closure", {"fn": fname, "n": e.params.size()}, depth)
		for i in captured.size():
			var cv := _name(String(captured[i]), depth + 1)
			if cv.is_empty() or not _wire(cv, cl, "c%d" % i):
				return {}
		return {"n": cl, "pin": "fn", "t": "Callable"}
	var ref := _data("event_ref", {"fn": fname}, depth + (1 if not captured.is_empty() else 0))
	if captured.is_empty():
		return {"n": ref, "pin": "fn", "t": "Callable"}
	var bound := []
	for nm in captured:
		bound.append({"k": "name", "v": nm})
	return _finish(_data("bcall", {"type": "Callable", "method": "bind"}, depth), bound, depth, {"n": ref, "pin": "fn", "t": "Callable"}, true, true)


## A call found by name when the game runs: the target's type is not known here.
func _dyn_call(target: Dictionary, method: String, args: Array, depth: int, want: bool) -> Dictionary:
	var n := _data("dyn_call", {"method": method, "n": args.size()}, depth)
	var out := _finish(n, args, depth, target, want, false)
	if out.is_empty() and not want and _failed == "":
		return {"none": true}
	return out


func _call(e: Dictionary, depth: int, want: bool) -> Dictionary:
	var fn: Dictionary = e.fn
	var args: Array = e.args
	if fn.k == "attr" and String(fn.name) == "connect":
		for a in args:
			if a != null and a.k == "lambda":
				a["wrap"] = true
	# super.method(...) and super(...): the parent's version
	if (fn.k == "attr" and fn.obj.k == "name" and String(fn.obj.v) == "super") or (fn.k == "name" and String(fn.v) == "super"):
		var pm := String(fn.name) if fn.k == "attr" else String(_entry.p.get("name", _g.get("name", "")))
		var info := R.find_method(_cls, pm)
		var pp := {"method": pm}
		if info.is_empty() or info.args.size() != args.size():
			pp["n"] = args.size()
			pp["ret"] = want
		return _finish(_data("call_parent", pp, depth), args, depth, {}, want, false)
	if fn.k == "name":
		var nm := String(fn.v)
		if _scope.has(nm) or _members.has(nm):
			_fail("calling a variable")
			return {}
		# A function of the script named like one of GDScript's own (log, range, len ...) does not hide it: the
		# bare name is still GDScript's, and only self.name() reaches the script's.
		var gd_own := _funcs.has(nm) and not bool(fn.get("own", false)) and (Compiler.GD_FUNCTIONS.has(nm) or not R.util(nm).is_empty())
		if _funcs.has(nm) and not gd_own:
			if bool(_funcs[nm].event):
				_fail("calling an event directly")
				return {}
			if args.size() > _funcs[nm].params.size() or args.size() < int(_funcs[nm].get("required", 0)):
				_fail("a call with the wrong number of arguments")
				return {}
			var n := _data("call_self", {"fn": nm}, depth)
			if bool(fn.get("own", false)):
				n.p["self"] = true   # written `self.name(...)`: written back that way
			var out := _finish(n, args, depth, {}, want, false)
			if not out.is_empty() and out.has("n"):
				out.t = String(_funcs[nm].ret) if String(_funcs[nm].ret) != "" else "any"
			return out
		if R.api.types.has(nm):
			var ci := _pick_ctor(nm, args)
			if ci == -1:
				_fail("no %s constructor takes these arguments" % nm)
				return {}
			return _finish(_data("ctor", {"type": nm, "i": ci}, depth), args, depth, {}, want, true)
		match nm:
			"load":
				if args.size() == 1:
					return _finish(_data("tpl", {"id": "load_sync"}, depth), args, depth, {}, want, true)
			"get_node":
				if _is_get_node(e):
					return _lower({"k": "node", "path": String(args[0].v).trim_prefix("^").trim_prefix("\"").trim_suffix("\"")}, depth)
			"range":
				# range() as a value (not the list a loop goes through): the Range node, which always has all three
				if args.size() >= 1 and args.size() <= 3:
					var bounds := args.duplicate()
					if bounds.size() == 1:
						bounds.push_front({"k": "num", "v": "0", "f": false})
					var rn := _data("tpl", {"id": "range"}, depth)
					if bounds.size() == 2:
						rn.d["step"] = "1"   # what the node writes when no step is given (so reading that back is the same node)
					return _finish(rn, bounds, depth, {}, want, true)
				_fail("range()")
				return {}
			"len", "char", "ord", "is_instance_of", "type_exists", "get_stack", "print_stack", "assert":
				var gd_node := _data("tpl", {"id": "gd_" + nm}, depth)
				if nm == "assert" and args.size() == 1:
					gd_node.d["message"] = "\"\""   # what the node writes when no message is given
				return _finish(gd_node, args, depth, {}, want, not nm in ["print_stack", "assert"])
			"int", "float", "bool", "preload", "super":
				_fail("%s()" % nm)
				return {}
		if not R.util(nm).is_empty():
			return _finish(_data("util", {"name": nm}, depth), args, depth, {}, want, true)
		if not R.find_method(_cls, nm).is_empty():
			var own_call := {"cls": _cls, "method": nm}
			if bool(fn.get("own", false)):
				own_call["self"] = true   # written `self.name(...)`: written back that way
			return _finish(_data("call", own_call, depth), args, depth, {}, want, true)
		_fail("'%s' is not a function this script can see" % nm)
		return {}
	if fn.k != "attr":
		_fail("calling the result of an expression")
		return {}
	var m := String(fn.name)
	var obj := {"n": {}, "pin": "", "t": _cls, "self": true} if fn.obj.k == "self" else {}
	if obj.is_empty() and fn.obj.k == "call" and _literal(fn.obj) != "":
		obj = {"lit": _literal(fn.obj), "t": _type(fn.obj)}   # preload("...").function(...)
	if obj.is_empty():
		obj = _lower(fn.obj, depth + 1)
	if obj.is_empty():
		return {}
	if obj.has("self"):
		return _call({"k": "call", "fn": {"k": "name", "v": m, "own": true}, "args": args}, depth, want)
	if obj.has("typeref"):
		var tr := String(obj.typeref)
		if m == "new" and args.is_empty():
			return _finish(_data("new", {"cls": tr}, depth), [], depth, {}, want, false)
		if m == "new":
			# a class whose _init takes arguments: called by name on the class
			var cls_ref := {"n": _data("const", {"expr": tr, "label": tr, "t": "any"}, depth + 1), "pin": "value", "t": "any"}
			var made := _dyn_call(cls_ref, "new", args, depth, want)
			if made.has("n") and T.hint(tr) != "":
				made.n.p["t"] = tr
				made["t"] = tr
			return made
		if R.api.types.has(tr):
			if R.builtin_method(tr, m).is_empty():
				_fail("%s has no function %s" % [tr, m])
				return {}
			return _finish(_data("bcall", {"type": tr, "method": m}, depth), args, depth, {}, want, true)
		if R.find_method(tr, m).is_empty() or (not Engine.has_singleton(tr) and not bool(int(R.find_method(tr, m).get("flags", 0)) & METHOD_FLAG_STATIC)):
			# a function this editor can't look up on that class (an inner class, a script's static function)
			var named := {"n": _data("const", {"expr": tr, "label": tr, "t": "any"}, depth + 1), "pin": "value", "t": "any"}
			return _dyn_call(named, m, args, depth, want)
		return _finish(_data("call", {"cls": tr, "method": m}, depth), args, depth, {}, want, true)
	if obj.has("sig"):
		if bool(obj.get("own", false)) and m == "emit" and _signals.has(String(obj.sig)):
			return _finish(_data("emit", {"name": String(obj.sig)}, depth), args, depth, {}, want, false)
		if m in ["connect", "disconnect"] and args.size() == 1 and _inline_mode == 0 and not want and _is_fnref(args[0]) \
				and not _reads_in_place(obj.get("target", {})):
			var n := _data("bind_signal" if m == "connect" else "unbind_signal", {"cls": String(obj.get("cls", _cls)), "signal": String(obj.sig)}, depth)
			var cb := _value(args[0], depth + 1)
			if cb.is_empty() or not _wire(cb, n, "fn"):
				return {}
			return _finish(n, [], depth, obj.get("target", {}), want, false)
		# emit, is_connected, connect with flags...: the signal's own function, called on the signal
		var sv := _sig_node(obj, depth + 1)
		if sv.is_empty():
			return {}
		return _dyn_call(sv, m, args, depth, want)
	if obj.has("fnref"):
		var ref := _data("event_ref", {"fn": String(obj.fnref)}, depth + 1)
		if not R.builtin_method("Callable", m).is_empty():
			return _finish(_data("bcall", {"type": "Callable", "method": m}, depth), args, depth, {"n": ref, "pin": "fn", "t": "Callable"}, want, true)
		_fail("%s on a function reference" % m)
		return {}
	var ot := String(obj.t)
	var base := "Array" if ot.begins_with("Array[") else ot
	if T.is_builtin(base) and base != "any":
		if R.builtin_method(base, m).is_empty():
			_fail("%s has no function %s" % [base, m])
			return {}
		return _finish(_data("bcall", {"type": base, "method": m}, depth), args, depth, obj, want, true)
	if T.is_object(ot) and not R.find_method(ot, m).is_empty():
		return _finish(_data("call", {"cls": ot, "method": m}, depth), args, depth, obj, want, true)
	# The type is not known here, or the function comes from a script attached to the object: call it by
	# name, as the script does.
	return _dyn_call(obj, m, args, depth, want)


## True when working this value out runs a call in place (so it must be read exactly once).
func _reads_in_place(val: Dictionary) -> bool:
	if not val.has("n"):
		return false
	var seen := {}
	var todo := [int(val.n.id)]
	while not todo.is_empty():
		var id: int = todo.pop_back()
		if seen.has(id):
			continue
		seen[id] = true
		var node := Model.find_node(_g, id)
		if node.is_empty():
			continue
		if bool(node.p.get("inline", false)):
			return true
		for w in _g.wires:
			if int(w[2]) == id and String(w[3]) != "exec":
				todo.append(int(w[0]))
	return false


func _is_fnref(e: Variant) -> bool:
	return e != null and e.k == "name" and _funcs.has(String(e.v)) and not _scope.has(String(e.v)) and not _members.has(String(e.v))


## The constructor of a built-in type that fits the arguments best (same count, closest types).
func _pick_ctor(type: String, args: Array) -> int:
	var ctors: Array = R.api.types.get(type, {}).get("ctor", [])
	var best := -1
	var best_score := -1
	for i in ctors.size():
		if ctors[i].size() != args.size():
			continue
		var score := 0
		for j in args.size():
			var want := R.api_type(String(ctors[i][j][1]))
			var have := _type(args[j])
			if want == have:
				score += 3
			elif want in ["int", "float"] and have in ["int", "float"]:
				score += 2 if want == "float" else 1
			elif have == "any":
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best
