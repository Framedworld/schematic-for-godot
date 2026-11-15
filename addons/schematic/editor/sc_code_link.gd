@tool
extends RefCounted
## The lookup between the lines of a compiled script and the graph nodes they came from, both ways.
##
##   var link = SCCodeLink.new().build(compiler, code)    # `compiler` has just run compile(), `code` is its text
##
## It has no UI and no editor dependency, so it runs headless. Everything is read from what the compiler
## already records (`line_map`, `line_kinds`, `block_lines`) and the wires of the graphs; it is built in one
## pass and every query after that is a lookup.
##
## Words used here:
##   writer       a node that wrote a line of its own (a call, a set, a branch, a loop; an event or function entry
##                wrote its header; a macro call node wrote the lines its expansion produced). `line_map` says so.
##   transparent  a node that wrote no line: a pure node (getter, math, literal, reroute, name node) or a node
##                whose result the compiler folded into the next line. Its expression sits inside the lines of
##                the writers that read it, possibly through other transparent nodes.
##
## Decisions (the tests pin each one):
##   - A writer's lines_of is exactly its own lines, in order: for an entry node the header, then whatever else
##     it wrote (locals declared at the top, the closing `return`, hoisted members); for a Branch the `if` and
##     the `else:`; with trace on, the `__sc_trace(...)` line too.
##   - A transparent node's lines_of is the lines of every writer that reads it directly or through other
##     transparent nodes, except the lines of such a writer that hold no expression at all (`else:`, `pass`,
##     `break`, `continue`, `_:`, a lone `)`, a `__sc_trace` line with no watched value). So a value feeding a
##     Branch condition takes part in the `if` line, not in the `else:`.
##   - An execution reroute (a knot on an execution wire) wrote nothing and carries no value: lines_of is empty.
##     The line of whatever follows it belongs to that node, and the reroute is not listed in nodes_at.
##   - A macro call node is the writer of every line its expansion wrote. The nodes inside the macro's own graph
##     have no lines (a macro may be used many times; the user sees the call node). A value wired into the macro
##     call node takes part in all of the macro's lines.
##   - An inline lambda's body lines belong to the lambda graph's nodes. The line holding `func(...):` belongs to
##     the outer node that uses the lambda, and also to the lambda graph's entry node (its "header"): nodes_at
##     lists the entry last.
##   - A line is never claimed by more than one writer: the first node on the line is the one the compiler
##     recorded. Pure nodes can take part in many lines, and a line can hold many pure nodes.

const R := preload("res://addons/schematic/core/sc_registry.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")

## What kind_of_line answers. "" is answered for a line number outside the script.
##   node         a line written by a graph node (call, set, branch, loop header, `else:`, `pass`, locals declared at
##                the top of a function...). nodes_at is never empty for it.
##   trace        an `__sc_trace(...)` line (only when the schematic's trace is on); it belongs to the node it reports.
##   header       the script's first lines: the generated comment, @tool, @icon, class_name, extends, description.
##   declaration  an enum, signal, variable or a member the compiler added (a timeline's state, a Do Once flag).
##                A member written for a node has that node; the others have none.
##   function     a function's header line, and the annotation lines above it (@rpc). It has the entry node when
##                the function came from one.
##   helper       written by the compiler for its own use: __sc_trace, __sc_sample and friends, the guard a
##                Construction Script adds, the stubs of an interface, a line of any function the compiler made.
##   carried      code kept as written from an imported script (extra_code).
##   blank        an empty line.
const KINDS := ["node", "trace", "header", "declaration", "function", "helper", "carried", "blank"]
## A short label for each kind, for a tooltip or a status line.
const LABELS := {
	"node": "Node", "trace": "Debug trace", "header": "Script header", "declaration": "Declaration",
	"function": "Function header", "helper": "Written by the compiler", "carried": "Code kept as written", "blank": "",
}
## Lines that hold no expression: a value wired into the node that wrote them does not take part in them.
const NO_EXPRESSION := ["else:", "pass", "break", "continue", "_:", "return"]

var line_count := 0

var _text := PackedStringArray()
var _kinds := {}          # the compiler's line_kinds: line -> kind
var _blocks: Array = []   # the compiler's block_lines: [header line, last line, name]
var _node_at := {}        # line -> key of the writer
var _own := {}            # key -> Array of lines it wrote (ascending)
var _lambda_head := {}    # line -> [key of an inline lambda's entry node whose `func(...):` is on it]
var _data_in := {}        # key -> [[pin index, key of the node feeding it]] along data wires
var _data_out := {}       # key -> [key of the node reading it]
var _at_cache := {}
var _lines_cache := {}
var _closer: RegEx


## Builds the lookup. `compiler` is a compiler that has just run compile(); `code` is the text compile returned.
## Returns self.
func build(compiler: Object, code: String) -> RefCounted:
	_text = code.split("\n")
	line_count = _text.size()
	_kinds = compiler.line_kinds
	_blocks = compiler.block_lines
	_node_at = {}
	_own = {}
	_lambda_head = {}
	_data_in = {}
	_data_out = {}
	_at_cache = {}
	_lines_cache = {}
	_closer = RegEx.create_from_string("^[\\)\\]\\}]+(\\.call\\(\\))?$")
	var line_map: Dictionary = compiler.line_map
	for line in range(1, line_count + 1):
		if not line_map.has(line):
			continue
		var at: Array = line_map[line]
		var key := _key(int(at[0]), int(at[1]))
		_node_at[line] = key
		if not _own.has(key):
			_own[key] = []
		_own[key].append(line)
	var schematic: Dictionary = compiler.bp
	for g in schematic.get("graphs", []):
		if String(g.kind) != "macro":   # (a macro is only ever read where it is called: its nodes have no lines)
			_index_graph(schematic, g)
	_find_lambda_heads(schematic)
	return self


# ---------------------------------------------------------------- queries

## Every line the node is responsible for, ascending. See the decisions at the top.
func lines_of(graph_id: int, node_id: int) -> PackedInt32Array:
	var key := _key(graph_id, node_id)
	if _own.has(key):
		return PackedInt32Array(_own[key])
	if _lines_cache.has(key):
		return _lines_cache[key]
	var found := {}
	var seen := {key: true}
	var queue := [key]
	var i := 0
	while i < queue.size():
		for to in _data_out.get(queue[i], []):
			if seen.has(to):
				continue
			seen[to] = true
			if _own.has(to):
				for line in _own[to]:
					if _reads(line):
						found[line] = true
			else:
				queue.append(to)
		i += 1
	var out := PackedInt32Array(found.keys())
	out.sort()
	_lines_cache[key] = out
	return out


## Only the lines the node wrote itself: empty for a node whose expression is part of another node's line.
func own_lines_of(graph_id: int, node_id: int) -> PackedInt32Array:
	return PackedInt32Array(_own.get(_key(graph_id, node_id), []))


## [[graph id, node id], ...] for a line: the node that wrote it first, then the nodes whose expressions are part of
## it, nearest first (the Set, then the math node it reads, then the getters that math reads); an inline lambda's
## entry node last, on the line that opens the lambda. Empty for a line that belongs to no node.
func nodes_at(line: int) -> Array:
	if _at_cache.has(line):
		return _at_cache[line].duplicate(true)
	var out := []
	if _node_at.has(line):
		var writer: int = _node_at[line]
		out.append(_pair(writer))
		if _reads(line):
			var seen := {writer: true}
			var queue := [writer]
			var i := 0
			while i < queue.size():
				for entry in _data_in.get(queue[i], []):
					var from: int = entry[1]
					if seen.has(from):
						continue
					seen[from] = true
					if not _own.has(from):   # (a node that wrote a line of its own is read through its variable)
						queue.append(from)
						out.append(_pair(from))
				i += 1
	for key in _lambda_head.get(line, []):
		out.append(_pair(key))
	_at_cache[line] = out
	return out.duplicate(true)


## One of KINDS (documented there), or "" for a line number outside the script.
func kind_of_line(line: int) -> String:
	if line < 1 or line > line_count:
		return ""
	if _text[line - 1].strip_edges() == "":
		return "blank"
	if _kinds.has(line):
		return String(_kinds[line])
	if _node_at.has(line):
		return "trace" if _text[line - 1].strip_edges().begins_with("__sc_trace(") else "node"
	return "helper"


## The graph a line belongs to, so the editor can show that graph: the writer's graph (a line inside an inline lambda
## is the lambda graph's), or for a line inside a function but written by no node, the graph of that function.
## -1 for a line that is in no graph (header, declarations, carried code, helper functions, blank lines).
func graph_of_line(line: int) -> int:
	if _node_at.has(line):
		return int(_node_at[line]) >> 32
	for b in _blocks:
		if line >= int(b[0]) and line <= int(b[1]):
			return int(_node_at[int(b[0])]) >> 32 if _node_at.has(int(b[0])) else -1
	return -1


## The text of a line (1-based), "" outside the script.
func text_of_line(line: int) -> String:
	return _text[line - 1] if line >= 1 and line <= line_count else ""


# ---------------------------------------------------------------- building

static func _key(graph_id: int, node_id: int) -> int:
	return (graph_id << 32) | node_id


func _pair(key: int) -> Array:
	return [key >> 32, key & 0xFFFFFFFF]


## True when a node's value, wired into the node that wrote this line, is part of what the line says.
func _reads(line: int) -> bool:
	var t := _text[line - 1].strip_edges()
	if t.begins_with("__sc_trace("):
		return t.contains("{\"")   # (the values arriving at the node are written into its trace line)
	return not (t in NO_EXPRESSION or _closer.search(t) != null)


## Records the data wires of a graph: the ones whose source pin is not an execution pin.
func _index_graph(schematic: Dictionary, g: Dictionary) -> void:
	var gid := int(g.id)
	var nodes := {}
	for n in g.nodes:
		nodes[int(n.id)] = n
	var descs := {}
	var touched := {}
	for w in g.wires:
		var a := int(w[0])
		var b := int(w[2])
		if not nodes.has(a) or not nodes.has(b):
			continue
		var from := _pin(schematic, g, nodes[a], descs, String(w[1]), "outs")
		var to := _pin(schematic, g, nodes[b], descs, String(w[3]), "ins")
		var kind := String(from.get("type", to.get("type", "any")))
		if kind == "exec":
			continue
		var ka := _key(gid, a)
		var kb := _key(gid, b)
		if not _data_in.has(kb):
			_data_in[kb] = []
		_data_in[kb].append([int(to.get("index", 0)), ka])
		touched[kb] = true
		if not _data_out.has(ka):
			_data_out[ka] = []
		_data_out[ka].append(kb)
	for tk in touched:
		_data_in[tk].sort_custom(func(x, y): return int(x[0]) < int(y[0]))


## {type, index} of a pin of a node, {} when the node has no such pin.
func _pin(schematic: Dictionary, g: Dictionary, n: Dictionary, descs: Dictionary, pin_id: String, side: String) -> Dictionary:
	var id := int(n.id)
	if not descs.has(id):
		descs[id] = R.describe(n, schematic, g)
	var pins: Array = descs[id][side]
	for i in pins.size():
		if String(pins[i].id) == pin_id:
			return {"type": String(pins[i].type), "index": i}
	return {}


## An inline lambda's body starts on the line after the one that opens it. The first line of the lambda graph that is
## not a function header of its own tells where that is: that line is the lambda entry's header.
func _find_lambda_heads(schematic: Dictionary) -> void:
	var seen := {}
	for line in range(2, line_count + 1):
		if not _node_at.has(line):
			continue
		var gid := int(_node_at[line]) >> 32
		if seen.has(gid):
			continue
		seen[gid] = true
		var g := Model.find_graph(schematic, gid)
		if g.is_empty() or String(g.kind) != "function" or not g.has("lambda") or _kinds.get(line, "") == "function":
			continue
		var opens := line - 1
		if _text[opens - 1].strip_edges() == "" or (int(_node_at.get(opens, 0)) >> 32) == gid:
			continue
		for n in g.nodes:
			if String(n.kind) == "fn_entry":
				var key := _key(gid, int(n.id))
				if not _own.has(key):
					_own[key] = []
				_own[key].append(opens)
				_own[key].sort()
				_lambda_head[opens] = _lambda_head.get(opens, []) + [key]
				break
