@tool
extends RefCounted
## Compiles a blueprint document into plain, readable GDScript.
##
## Execution wires become structured code (if/for/match), pure nodes become inline expressions that are
## re-evaluated by each consumer (Blueprint semantics), impure node outputs become locals, latent nodes
## become `await`, and per-node state (Do Once, Flip Flop, Gate, Delay...) becomes per-instance members.

const T := preload("res://addons/blueprints/core/bp_types.gd")
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")

const MAX_STATEMENTS := 20000

var bp: Dictionary
var errors: Array = []      # [{g, n, m, w}]
var line_map: Dictionary = {}  # 1-based line -> [graph_id, node_id]
var node_lines: Dictionary = {}  # "gid:nid" -> first line
## For the debugger: the expression each wired input pin reads, per function of the generated script
## (function name -> "gid:nid" -> {pin id: expression}), and the lines each function covers ([first, last, name]).
var pin_exprs: Dictionary = {}
var block_lines: Array = []
var _cur_block := ""
var _chain_from := 0   # the node whose exec pin leads to the chain about to be written (0: not known)

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
var _construct := false   # blueprint has a Construction Script graph
var _want: Dictionary = {}    # "gid:name" -> type, values that must persist beyond their local scope
var _hoist: Dictionary = {}   # the same set, applied on the second pass
var _pass2 := false
var _inline: Dictionary = {}   # call node id -> its expression, when the very next node stores the result
var _lib := false              # function library: everything compiles as static
var _data := false             # data asset: every variable is a field (exported)
var _headers: Dictionary = {}  # "nid:pin" exec entry points that a wire loops back to
var _active: Dictionary = {}   # loop headers currently being emitted -> lambda depth
var _lam := 0


## Compiles in up to two passes: the first finds values that are read outside the execution path that
## produced them (another event's outputs, a node on a different branch); the second stores exactly those
## in per-instance members, which is how Blueprints behave (the last value written is what you read).
func compile(blueprint: Dictionary) -> String:
	var code := _compile_once(blueprint)
	if _want.is_empty():
		return code
	var second = get_script().new()
	second._hoist = _want.duplicate()
	second._pass2 = true
	code = second._compile_once(blueprint)
	errors = second.errors
	line_map = second.line_map
	node_lines = second.node_lines
	pin_exprs = second.pin_exprs
	block_lines = second.block_lines
	return code


func _compile_once(blueprint: Dictionary) -> String:
	bp = blueprint
	errors.clear()
	line_map.clear()
	node_lines.clear()
	pin_exprs.clear()
	block_lines.clear()
	R.ensure_api()
	var is_node := T.is_a(R.self_class(bp), "Node")
	if not T.class_known(R.self_class(bp)):
		_err(0, 0, "Parent class '%s' does not exist" % R.self_class(bp))
	_lib = String(bp.get("library", "")) == "function"
	if _lib and String(bp.get("class_name", "")) == "":
		_err(0, 0, "A function library needs a Class Name (Class Settings): other blueprints call its functions through that name")
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
	for src_graph in bp.graphs:
		if src_graph.kind == "macro":
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
					for a in m.args:
						var h := T.hint(T.from_info(a))
						args.append(T.ident(String(a.name)) + ((": " + h) if h != "" else ""))
					if _block(String(n.p.name), "func %s(%s) -> void:" % [n.p.name, ", ".join(args)], n, "then"):
						_blocks[-1]["event"] = true
				"custom_event":
					var nm := T.ident(String(n.p.get("name", "")))
					if _block(nm, "func %s(%s) -> void:" % [nm, _param_list(n.p.get("params", []))], n, "then"):
						var rpc_mode := String(n.p.get("rpc", ""))
						if rpc_mode != "" and not is_node:
							_err(_gid, n.id, "Replicated events need a Node-derived blueprint")
						elif rpc_mode != "":
							_blocks[-1]["pre"] = ["@rpc(\"%s\", \"call_local\", \"%s\")" % ["any_peer" if rpc_mode == "server" else "authority",
								"reliable" if n.p.get("reliable", true) else "unreliable"]]
				"key_event":
					if not is_node:
						_err(_gid, n.id, "Keyboard events need a Node-derived blueprint")
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
						_err(_gid, n.id, "Input action events need a Node-derived blueprint")
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
						_err(_gid, n.id, "Node signal events need a Node-derived blueprint")
						continue
					var path := String(n.p.get("path", "."))
					var fn := "_on_%s_%s" % ["self" if path == "." else T.ident(path.get_file()), T.ident(String(n.p.signal))]
					if _block(fn, "func %s(%s) -> void:" % [fn, _param_list(n.p.get("args", []))], n, "then"):
						var src := "" if path == "." else "get_node(^\"%s\")." % path.c_escape()
						_ready_pre.append([1, "%s%s.connect(%s)" % [src, n.p.signal, fn], _gid, n.id])

	_implement_interfaces()
	_settle_event_locals(event_locals)
	_merge_prelude("_ready" if is_node else "_init", "func %s() -> void:" % ("_ready" if is_node else "_init"), _ready_pre)
	_merge_prelude("_unhandled_input", "func _unhandled_input(event: InputEvent) -> void:", _input_pre)
	# Construction Script: runs when the node becomes ready (in game and in the editor) and again whenever an
	# instance-editable variable changes. Gameplay events stay out of the editor unless Run in Editor is on.
	var cg := Model.graph_named(bp, "ConstructionScript")
	_construct = not cg.is_empty() and cg.kind == "function"
	if _construct and not is_node:
		_err(int(cg.id), 0, "A Construction Script needs a Node-derived blueprint")
		_construct = false
	if _construct:
		var guard := [] if bp.get("tool", false) else [[1, "if Engine.is_editor_hint():", 0, 0], [2, "return", 0, 0]]
		var ready := {}
		for b in _blocks:
			if b.name == "_ready":
				ready = b
		if ready.is_empty():
			ready = {"name": "_ready", "header": "func _ready() -> void:", "lines": [], "gid": 0, "nid": 0}
			_blocks.push_front(ready)
		ready.lines = [[1, "ConstructionScript()", 0, 0]] + guard + ready.lines
		for b in _blocks:
			if b.name != "_ready" and (b.get("event", false) or b.name == "_unhandled_input"):
				b.lines = guard + b.lines
	return _assemble()


# ---------------------------------------------------------------- interfaces

## A Blueprint Interface compiles to its list of function names and a check for "has all of them". The
## graphs only describe each function's inputs and outputs; they have no body to compile.
func _compile_interface() -> String:
	if String(bp.get("class_name", "")) == "":
		_err(0, 0, "A Blueprint Interface needs a Class Name (Class Settings): blueprints refer to it by that name")
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


## Each function of an interface this blueprint implements must exist with the interface's inputs and outputs.
## One the blueprint has no graph for is written as an empty function that returns default values (as in
## Unreal), so the object still answers it. A custom event of that name also counts.
func _implement_interfaces() -> void:
	for iname in bp.get("interfaces", []):
		if R.interface_bp(String(iname)).is_empty():
			_err(0, 0, "There is no Blueprint Interface named '%s' (Class Settings > Interfaces)" % iname)
			continue
		if _lib or _data:
			_err(0, 0, "Only a Blueprint Class can implement an interface")
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
	var add := func(text: String, gid := 0, nid := 0) -> void:
		lines.append(text)
		if nid != 0:
			line_map[lines.size()] = [gid, nid]
			var key := "%d:%d" % [gid, nid]
			if not node_lines.has(key):
				node_lines[key] = lines.size()
	add.call(Model.MARKER + " v%d - generated from a Blueprint graph. Edit it in the Blueprint editor, not by hand." % Model.VERSION)
	if bp.get("tool", false) or _construct:
		add.call("@tool")
	if String(bp.get("class_name", "")) != "":
		add.call("class_name " + T.ident(bp.class_name))
	add.call("extends " + R.self_class(bp))
	for dl in String(bp.get("description", "")).split("\n", false):
		add.call("## " + dl)
	add.call("")
	for be in bp.get("enums", []):
		var names := PackedStringArray()
		for bv in be.values:
			names.append(T.ident(String(bv)))
		add.call("enum %s { %s }" % [T.ident(String(be.name)), ", ".join(names)])
	if not bp.get("enums", []).is_empty():
		add.call("")
	for dsp in bp.dispatchers:
		add.call("signal %s(%s)" % [T.ident(dsp.name), _param_list(dsp.get("params", []))])
	if not bp.dispatchers.is_empty():
		add.call("")
	# enums, constants and inner classes carried over from an imported script, exactly as written
	if String(bp.get("extra_code", "")) != "":
		for extra_line in String(bp.extra_code).split("\n"):
			add.call(extra_line)
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
			for raw_line in String(v.raw).split("\n"):
				add.call(raw_line)
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
				add.call("@export_group(\"%s\")" % group.c_escape())
		for tl in String(v.get("tooltip", "")).split("\n", false):
			add.call("## " + tl)
		var lit := String(v.get("default", ""))
		if lit == "":
			lit = T.default_literal(vt)
		# Variables typed with one of this blueprint's enums get the enum type (so the Inspector shows a dropdown).
		if vt == "int" and String(v.get("enum", "")) != "":
			for be in bp.get("enums", []):
				if String(be.name) == String(v.enum) and not be.values.is_empty():
					h = T.ident(String(be.name))
					var idx := clampi(int(lit) if lit.is_valid_int() else 0, 0, be.values.size() - 1)
					lit = "%s.%s" % [h, T.ident(String(be.values[idx]))]
		var decl := "%svar %s%s" % ["static " if _lib else "", vn, (": " + h) if h != "" else ""]
		if not (T.is_object(vt) and lit == "null"):
			decl += " = " + lit
		var exported: bool = (v.get("export", false) or _data) and exportable and not _lib
		var notify_fn := "on_%s_changed" % vn
		var notify: bool = v.get("notify", false) and not _lib and not Model.graph_named(bp, notify_fn).is_empty()
		var rerun: bool = _construct and exported
		add.call(("@export " if exported else "") + decl + (":" if (notify or rerun) else ""))
		if notify or rerun:
			var is_node_bp := T.is_a(R.self_class(bp), "Node")
			add.call("\tset(value):")
			add.call("\t\t%s = value" % vn)
			if is_node_bp:
				add.call("\t\tif is_node_ready():")
			var deep := "\t\t\t" if is_node_bp else "\t\t"
			if notify:
				add.call("%s%s()" % [deep, notify_fn])
			if rerun:
				add.call("%sConstructionScript()" % deep)
	if not bp.variables.is_empty():
		add.call("")
	for m in _members:
		add.call(("static " + String(m[0])) if (_lib and String(m[0]).begins_with("var ")) else m[0], m[1], m[2])
	if not _members.is_empty():
		add.call("")
	for hname in _helpers:
		_blocks.append({"name": hname, "header": _helpers[hname][0], "lines": _helpers[hname][1], "gid": 0, "nid": 0})
	for b in _blocks:
		add.call("")
		for pre_line in b.get("pre", []):
			add.call(pre_line, b.gid, b.nid)
		add.call(("static " + String(b.header)) if (_lib and String(b.header).begins_with("func ")) else b.header, b.gid, b.nid)
		var first_line := lines.size()
		if b.lines.is_empty():
			add.call("\tpass", b.gid, b.nid)
		for l in b.lines:
			add.call("\t".repeat(l[0]) + l[1], l[2], l[3])
		block_lines.append([first_line, lines.size(), String(b.name)])
		add.call("")
	return "\n".join(lines)


func _merge_prelude(fn: String, header: String, pre: Array) -> void:
	if pre.is_empty():
		return
	for b in _blocks:
		if b.name == fn:
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
		if infer:
			lines[i][1] = "var %s := %s" % [name, value]
		else:
			lines[i][1] = "var %s%s = %s" % [name, (": " + hint) if hint != "" else "", value]
	return true


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
			var users := []
			var named_in_text := false
			for blk in _blocks:
				var uses := false
				for l in blk.lines:
					var text := String(l[1])
					if not text.contains(name):
						continue
					# reached by name (set(), a tween, an animation track): it has to be a real member
					if text.contains("\"" + name + "\"") or text.contains("'" + name + "'"):
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
			var known := false
			for m in _members:
				if m[0] == text:
					known = true
			if not known:
				_members.append([text, gid, 0])


## GDScript could not accept some "var x := ..." lines (it could not infer a type there, or the type it
## inferred does not suit a later line): stop inferring those locals, so they are declared with the type the
## graph knows instead. `bad_lines` are 1-based line numbers of `code`; when none of them is such a
## declaration, every inferred local is given up. Returns how many locals changed (0: nothing left to try).
static func drop_inferred(blueprint: Dictionary, code: String, bad_lines: Array) -> int:
	var names := {}
	var lines := code.split("\n")
	var decl := RegEx.create_from_string("^\\s*var ([A-Za-z_][A-Za-z0-9_]*) := ")
	for ln in bad_lines:
		if int(ln) >= 1 and int(ln) <= lines.size():
			var m := decl.search(lines[int(ln) - 1])
			if m != null:
				names[m.get_string(1)] = true
	var changed := 0
	for g in blueprint.get("graphs", []):
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
		if prm.size() > 3 and String(prm[3]) != "":
			h = String(prm[3])   # a type written in the imported script that has no pin type
		var text := T.ident(String(prm[0])) + ((": " + h) if h != "" else "")
		if prm.size() > 2 and String(prm[2]) != "":
			text += " = " + String(prm[2])
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


func _line(ind: int, text: String, nid: int) -> void:
	_out.append([ind, text, _gid, int(_origin.get(nid, nid))])
	_stmts += 1


func _member(text: String, nid: int) -> void:
	for m in _members:
		if m[0] == text:
			return
	_members.append([text, _gid, int(_origin.get(nid, nid))])


# ---------------------------------------------------------------- function blocks

func _block(name: String, header: String, entry: Dictionary, start_pin: String) -> bool:
	if _fn_names.has(name):
		_err(_gid, entry.id, "'%s' is defined more than once in this blueprint" % name)
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
			_line(1, "%s = %s" % [mname, pname], int(entry.id))
	_chain_from = int(entry.id)
	_chain(tgt[0], tgt[1], 1, {})
	_cur_block = ""
	_blocks.append({"name": name, "header": header, "lines": _out, "gid": _gid, "nid": int(_origin.get(int(entry.id), int(entry.id)))})
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
		for mn in m.nodes:
			kinds[int(mn.id)] = mn.kind
			if mn.kind in ["macro_in", "macro_out", "comment"]:
				continue
			var c: Dictionary = mn.duplicate(true)
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
		_err(_gid, id, "Timelines need a Node-derived blueprint")
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
		sample.append([1, "%s_%s = __bp_sample([%s], %s_time, %s)" % [tl, tn, ", ".join(parts), tl, "true" if tr.get("smooth", false) else "false"], _gid, shown])
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
	if not _helpers.has("__bp_sample"):
		_helpers["__bp_sample"] = ["func __bp_sample(keys: Array, t: float, smooth: bool) -> Variant:", [
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
	var header := "%sfunc %s(%s) -> %s:" % ["static " if (bool(g.get("static", false)) and not _lib) else "", fname, _param_list(g.inputs), ret]
	if not _block(fname, header, entry, "then"):
		return
	var b: Dictionary = _blocks[-1]
	if not g.get("pre", []).is_empty():
		b["pre"] = g.pre.duplicate()
	var pre := []
	for l in g.locals:
		if bool(l.get("param", false)):
			continue   # a parameter the function assigns to: it is already declared, in the signature
		var h := T.hint(String(l.type))
		if _declare_in_place(b.lines, T.ident(String(l.name)), h, bool(l.get("infer", false))):
			continue
		var lit := String(l.get("default", ""))
		if lit == "":
			lit = T.default_literal(String(l.type))
		pre.append([1, "var %s%s = %s" % [T.ident(String(l.name)), (": " + h) if h != "" else "", lit], _gid, int(entry.id)])
	b.lines = pre + b.lines
	if not outs.is_empty():
		var last_is_return := false
		for l in b.lines:
			if l[0] == 1:
				last_is_return = String(l[1]).begins_with("return")
		if not last_is_return:
			var defs := PackedStringArray()
			for o in outs:
				defs.append(T.default_literal(String(o[1])))
			b.lines.append([1, "return " + (defs[0] if defs.size() == 1 else "[" + ", ".join(defs) + "]"), _gid, int(entry.id)])
	_in_function = false


# ---------------------------------------------------------------- exec flow

func _latent_reach(nid: int, seen := {}) -> bool:
	if nid == -1 or seen.has(nid) or not _nodes.has(nid):
		return false
	seen[nid] = true
	var n: Dictionary = _nodes[nid]
	if _d(n).latent:
		return true
	for pin in _d(n).outs:
		if pin.type != "exec":
			continue
		for tgt in _outw.get("%d:%s" % [nid, pin.id], []):
			if _latent_reach(tgt[0], seen):
				return true
	return false


## Finds exec entry points that some wire loops back to (they become `while` loops).
func _mark_headers(nid: int, pin: String, stack: Dictionary, done: Dictionary) -> void:
	if nid == -1 or not _nodes.has(nid):
		return
	var key := "%d:%s" % [nid, pin]
	if stack.has(key):
		_headers[key] = true
		return
	if done.has(key):
		return
	stack[key] = true
	var n: Dictionary = _nodes[nid]
	if not pin in ["reset", "open", "close", "toggle"] and n.kind != "timeline":
		for o in _d(n).outs:
			if o.type != "exec":
				continue
			for tgt in _outw.get("%d:%s" % [nid, o.id], []):
				_mark_headers(tgt[0], tgt[1], stack, done)
	stack.erase(key)
	done[key] = true


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
		if bp.get("trace", false) and not _lib and not _d(_nodes[nid]).pure:
			# Opt-in debug aid: tells the editor which nodes are running so it can light them up.
			_member("var __bp_hits: Dictionary = {}", 0)
			_member("var __bp_last: int = 0", 0)
			_member("var __bp_vals: Dictionary = {}", 0)
			_member("var __bp_edges: Dictionary = {}", 0)
			_helpers["__bp_trace"] = ["func __bp_trace(graph_id: int, node_id: int, values: Dictionary = {}, from: int = 0) -> void:", [
				[1, "if not EngineDebugger.is_active():", 0, 0], [2, "return", 0, 0],
				[1, "__bp_hits[graph_id * 100000 + node_id] = true", 0, 0],
				[1, "if from != 0 and from != node_id:", 0, 0],
				[2, "__bp_edges[(graph_id * 100000 + from) * 100000 + node_id] = true", 0, 0],
				[1, "if not values.is_empty():", 0, 0],
				[2, "__bp_vals[graph_id * 100000 + node_id] = values", 0, 0],
				[1, "var now := Time.get_ticks_msec()", 0, 0],
				[1, "if now - __bp_last > 100:", 0, 0],
				[2, "__bp_last = now", 0, 0],
				[2, "var shown := {}", 0, 0],
				[2, "for key in __bp_vals:", 0, 0],
				[3, "var row := {}", 0, 0],
				[3, "for pin in __bp_vals[key]:", 0, 0],
				[4, "row[pin] = str(__bp_vals[key][pin]).left(60)", 0, 0],
				[3, "shown[key] = row", 0, 0],
				[2, "EngineDebugger.send_message(\"blueprint:exec\", [(get_script() as Script).resource_path, __bp_hits.keys(), shown, __bp_edges.keys()])", 0, 0],
				[2, "__bp_hits.clear()", 0, 0],
				[2, "__bp_edges.clear()", 0, 0],
				[2, "__bp_vals.clear()", 0, 0]]]
			# The values arriving on this node's wired input pins go along, so the editor can show them on the pins.
			# (Not for nodes inside an expanded macro: their pins are not the ones on screen.)
			var watch := ""
			if not _origin.has(nid):
				var parts := PackedStringArray()
				for wpin in _d(_nodes[nid]).ins:
					if wpin.type != "exec" and _inw.has("%d:%s" % [nid, wpin.id]):
						parts.append("\"%s\": %s" % [wpin.id, _in(_nodes[nid], String(wpin.id), scope)])
				if not parts.is_empty():
					watch = ", {%s}" % ", ".join(parts)
			# and the node execution came from, so the editor can light the wire that was followed
			var came := int(_origin.get(from, from))
			if came != 0 and came != int(_origin.get(nid, nid)):
				watch = (watch if watch != "" else ", {}") + ", %d" % came
			_line(ind, "__bp_trace(%d, %d%s)" % [_gid, int(_origin.get(nid, nid)), watch], nid)
		from = nid
		var nxt := _step(_nodes[nid], pin, ind, scope)
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
		_line(ind, "pass", nid)


## Like _sub, but runs the chain as a detached coroutine when it contains latent nodes, so the caller
## continues immediately (Sequence / loop semantics from Blueprints).
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
			_line(ind, "%s.%s = %s" % [_in(n, "target", scope), T.ident(String(p.name)), _in(n, "value", scope)], id)
			return _follow(id, "then")
		"await_value":
			if _wired_out(id, "ret"):
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
			if String(p.get("part", "")) != "" or String(p.get("op", "")) != "":
				var held := T.ident(String(p.name)) + (("." + String(p.part)) if String(p.get("part", "")) != "" else "")
				_line(ind, "%s %s= %s" % [held, String(p.get("op", "")), _in(n, "value", scope)], id)
				return _follow(id, "then")
			var var_change := _member_change(n, scope)
			if var_change.is_empty():
				_line(ind, "%s = %s" % [T.ident(String(p.name)), _in(n, "value", scope)], id)
			else:
				_line(ind, "%s.%s = %s" % [T.ident(String(p.name)), var_change[0], var_change[1]], id)
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
				text = _replace_word(text, String(nm), "(%s)" % _in(n, "x_" + String(nm), scope))
			for code_line in text.split("\n"):
				var tabs := 0
				while tabs < code_line.length() and code_line[tabs] == "\t":
					tabs += 1
				if code_line.strip_edges() != "":
					_line(ind + tabs, code_line.strip_edges(), id)
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
			if _feeds_next_store(n, d):
				_inline[id] = "%s.new()" % p.cls   # "x = Thing.new()" is written as that, with no temporary
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
			_line(ind, "if %s:" % _in(n, "cond", scope), id)
			_sub(id, "true", ind + 1, scope)
			if _wired_out(id, "false"):
				_line(ind, "else:", id)
				_sub(id, "false", ind + 1, scope)
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
			var iv := "i_%d" % id
			var last := _in(n, "last", scope)
			var stop := str(int(last) + 1) if last.is_valid_int() else "%s + 1" % last
			if _counted(last) != "":
				stop = _counted(last)
			var from := _in(n, "first", scope)
			_line(ind, ("for %s in range(%s):" % [iv, stop]) if from == "0" else ("for %s in range(%s, %s):" % [iv, from, stop]), id)
			var body := scope.duplicate()
			body[iv] = true
			_loop += 1
			_sub_detached(id, "body", ind + 1, body, true)
			_loop -= 1
			return _follow(id, "completed")
		"for_each_dict":
			var dk := "key_%d" % id
			_line(ind, "for %s in %s:" % [dk, _in(n, "dict", scope)], id)
			var dbody := scope.duplicate()
			dbody[dk] = true
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
				var ritem := "item_%d" % id
				_decl(rarr, "any", _in(n, "array", scope), ind, id, scope)
				_line(ind, "for %s in range(%s.size() - 1, -1, -1):" % [ridx, rarr], id)
				_line(ind + 1, "var %s = %s[%s]" % [ritem, rarr, ridx], id)
				var rbody := scope.duplicate()
				rbody[ridx] = true
				rbody[ritem] = true
				_loop += 1
				_sub_detached(id, "body", ind + 1, rbody, false)
				_loop -= 1
				return _follow(id, "completed")
			var item := "item_%d" % id
			var idx := "idx_%d" % id
			var use_idx := _wired_out(id, "index")
			if use_idx:
				_decl(idx, "int", "-1", ind, id, scope)
			var h := T.hint(String(p.get("t", "any")))
			_line(ind, "for %s%s in %s:" % [item, (": " + h) if h != "" else "", _in(n, "array", scope)], id)
			var body := scope.duplicate()
			body[item] = true
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
			_line(ind, "await %s.create_timer(%s).timeout" % [_tree(), _in(n, "duration", scope)], id)
			_line(ind, "%s = false" % flag, id)
			return _follow(id, "then")
		"retriggerable_delay":
			var ctr := "__rdelay_%d_%d" % [_gid, id]
			var tok := "rdelay_token_%d" % id
			_member("var %s: int = 0" % ctr, id)
			_line(ind, "%s += 1" % ctr, id)
			_decl(tok, "int", ctr, ind, id, scope)
			_line(ind, "await %s.create_timer(%s).timeout" % [_tree(), _in(n, "duration", scope)], id)
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
				_sub(id, "case_%d" % i, ind + 2, scope)
			_line(ind + 1, "_:", id)
			_sub(id, "default", ind + 2, scope)
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
				_err(_gid, id, "'%s' needs a Node-derived blueprint" % d.title)
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
		if _cur_block != "" and not _origin.has(int(n.id)):
			# remembered for the debugger, which shows this value on the pin while the game is paused
			var fn_pins: Dictionary = pin_exprs.get_or_add(_cur_block, {})
			var node_pins: Dictionary = fn_pins.get_or_add("%d:%d" % [_gid, int(n.id)], {})
			node_pins[pid] = e
		var from_type := _out_type(src, w[1])
		# A loop walks whatever it is given (a packed array need not be copied into an Array first), and a
		# condition takes an object as it is (null is false), exactly as hand-written GDScript does.
		if n.kind in ["for_each", "for_each_dict"] and pid in ["array", "dict"]:
			return e
		if String(pin.type) == "bool" and T.is_object(from_type) and (n.kind in ["branch", "while", "select"] or (n.kind == "math" and String(n.p.get("op", "")) in ["and", "or", "not"])):
			return e
		return T.coerce(e, from_type, pin.type)
	var lit := String(n.d.get(pid, pin.get("def", "")))
	if lit == "":
		if pin.get("self", false):
			return "self"
		if pid == "target" and T.is_object(pin.type):
			_err(_gid, n.id, "'%s' needs a Target (this blueprint is not a %s)" % [_d(n).title, pin.type])
		return T.default_literal(pin.type)
	return lit


## Replaces every whole-word use of `word` in GDScript text, leaving string literals and `.member` names alone.
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
			return pin.trim_prefix("p_")
		"var_get", "local_get", "var_set", "local_set":
			return T.ident(String(p.name))
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
			return String(p.expr)
		"closure":
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
			return _scoped("awaited_%d" % src.id, src, scope, consumer)
		"event_ref":
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
				expr_text = _replace_word(expr_text, T.ident(String(nm)), "(%s)" % _in(src, "x_" + String(nm), scope))
			return "(%s)" % expr_text
		"tpl":
			var t: Dictionary = R.template_of(p)
			if d.pure:
				if t.get("node", false) and not T.is_a(R.self_class(bp), "Node"):
					_err(_gid, src.id, "'%s' needs a Node-derived blueprint" % d.title)
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
			return _scoped("i_%d" % src.id, src, scope, consumer)
		"for_each":
			return _scoped(("item_%d" if pin == "element" else "idx_%d") % src.id, src, scope, consumer)
		"for_each_dict":
			var dkey := _scoped("key_%d" % src.id, src, scope, consumer)
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
			_helpers["__bp_make_" + mcls] = ["func __bp_make_%s(%s) -> %s:" % [mcls, ", ".join(names), mcls], mlines]
			return "__bp_make_%s(%s)" % [mcls, ", ".join(margs)]
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
	if _hoist.has("%d:%s" % [_gid, _ovar(n)]):
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
			if (int(m.get("flags", 0)) & METHOD_FLAG_STATIC) or R.is_singleton(p.cls):
				return "%s.%s(%s)" % [p.cls, p.method, arg_s]
			var tg := _in(n, "target", scope)
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
			return "%s(%s)" % [T.ident(String(p.fn)), arg_s]
	return "null"


func _blocks_current_name() -> String:
	var e: Dictionary = _nodes.get(_entry_id, {})
	return String(e.get("p", {}).get("name", "")) if e.get("kind", "") == "event" else ""
