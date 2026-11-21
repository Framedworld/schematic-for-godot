@tool
extends RefCounted
## Two-way editing: a Schematic's GDScript split into blocks, each marked with whose it is, two versions of a
## script compared block by block, and a person's hand edits brought back into the graph (reimport, at the end).
## No editor dependency (headless).
##
##   var sync = SCSync.new()
##   var blocks := sync.split(code)              # every line of `code` in exactly one block, in file order
##   sync.classify(blocks, compiler)             # `compiler` has just produced `code`: marks from its records
##   sync.classify_text(blocks)                  # or: the same marks from the text alone (see TEXT RULES)
##   var d := sync.diff(old_blocks, new_blocks)  # what changed between two classified splits
##   var e := sync.user_edits(file_code, graph_code, compiler)   # what a person changed by hand (see below)
##
## A BLOCK is {kind, name, from, to, text, owner, head, head_to, compiler_lines, strs}:
##   from, to        1-based first and last line; text is exactly those lines joined with "\n" (a CRLF file keeps
##                   its "\r"), so the texts of all blocks joined with "\n" give the input back exactly.
##   name            the declared name (function, variable, constant, signal, enum, inner class, class_name, region
##                   label) or "".
##   head, head_to   the first and last line of the declaration itself (the line with `func`, `var` ...; a header
##                   continued over several lines ends at head_to); comments and annotations above it come first.
##   compiler_lines  for a block owned by `user`: the lines inside it the compiler wrote for its own purposes (see
##                   COMPILER LINES). Empty otherwise.
##   strs            lines of the block that begin inside a multi-line string (their text is the string's).
##
## KINDS (KINDS below):
##   header       the comments and blank lines the file begins with, before any code
##   class        @tool, @icon, class_name, extends (and annotations on lines of their own above them), plus the
##                doc comment lines right below extends when a blank line follows them
##   signal, enum, const, var    one declaration with its annotations and attached comments; a var takes the
##                indented lines below it (set / get, a lambda value)
##   func         one function: attached comments, annotations, the header (however many lines it spans) and every
##                line indented deeper than the header, up to the next line that is not (lambdas, match, multi-line
##                strings and comment lines inside the body are part of it); comment lines indented deeper than the
##                header right after its last line are part of it too
##   inner_class  `class X:` and everything indented below it (its functions and nested classes stay inside it)
##   region       one `#region` or `#endregion` line. Regions are NOT kept whole: what is between the markers is
##                split as usual, so a function inside a region is still a block of its own.
##   graph        the stored graph: `#region Schematic graph data` to its `#endregion`
##   comment      comment lines standing on their own (not directly above a declaration)
##   blank        a run of blank lines
##   other        anything else (a stray statement), kept verbatim
## Attached comments: comment lines and annotation-only lines directly above a declaration (no blank line between)
## belong to that declaration, so editing a function's doc comment changes that function's block. Blank lines are
## never attached: they are blocks of their own, and diff ignores them.
##
## OWNERS: "user" (comes from what the person edits: an event, a function, a custom event, a variable, signal or
## enum of the schematic, the class line), "carried" (code kept as written from a converted script: extra_code),
## "compiler" (helpers, trace members, members the compiler adds for nodes, interface stubs, timeline machinery,
## a function the compiler made only to hold its prelude, the file's marker comment, the stored graph). Blank
## blocks are "user".
##
## user_edits(file_code, graph_code, compiler) answers: what did a person change by hand? `graph_code` is what
## `compiler` just compiled from the graph; `file_code` is the file on disk. Returns
##   {nothing, functions: {changed, added, removed, renamed, moved}, declarations, carried, compiler,
##    diff, file_blocks, graph_blocks}
## where each list holds diff entries (see diff) of user-owned functions, user-owned declarations (variables,
## signals, enums, the class line, free comments), carried-over code and compiler-owned code (a helper edited, a
## prelude line edited inside _ready: `status` "compiler_lines"). Differences that only come from compile options
## (the trace lines, members and helpers of "Show Flow and Values") are set aside entirely. `nothing` is true
## when every list except functions.moved is empty (a reordering of functions changes nothing GDScript runs).

##
## reimport(bp, file_code, opts) brings a person's hand edits back into the graph. See RE-IMPORT below.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Parser := preload("res://addons/schematic/core/sc_gd_parser.gd")

const KINDS := ["header", "class", "signal", "enum", "const", "var", "func", "inner_class", "region", "graph", "comment", "blank", "other"]
const OWNERS := ["user", "carried", "compiler"]
## Functions whose prelude (input dispatch, signal wiring, timeline autoplay) the compiler merges in.
const PRELUDE_FUNCS := ["_ready", "_init", "_unhandled_input"]
## What "Show Flow and Values" adds: present in one compile and absent in another is not an edit.
const TRACE_MACHINERY := ["__sc_trace", "__sc_flush", "__sc_hits", "__sc_last", "__sc_vals", "__sc_edges", "__sc_wait", "__sc_state"]
const IMPLEMENTED_BY := "static func implemented_by(target) -> bool:\n\tif not is_instance_valid(target):\n\t\treturn false\n\tfor fn in FUNCTIONS:\n\t\tif not target.has_method(fn):\n\t\t\treturn false\n\treturn true"
## Similarity (0..1, by lines) at or above which an unmatched pair of blocks of one kind is taken for a rename.
const RENAME_AT := 0.6

## TEXT RULES: the compiler-written shapes classify_text recognises, collected from sc_compiler.gd. This is the
## one place they are listed; tests/test_sync.gd compiles every demo and sample with trace off and on and checks
## that every line the compiler wrote for itself is recognised by these rules.
##   Whole blocks:
##     func __sc_<anything>                       helpers (_helpers: __sc_trace, __sc_flush, __sc_sample,
##                                                __sc_make_<Class>, and the templates' __sc_ helpers)
##     func <name of a kit template's helper>      helpers that addons' node kits add (read from the registry)
##     func __tl_<timeline>_<g>_<n>_sample / _run  the timeline machinery (_compile_timeline)
##     var __<anything>                            members the compiler adds: trace (__sc_hits ...), hoisted values
##                                                (__p<n>_<pin>_g<g>, __<name>_g<g>), node state (__do_once_,
##                                                __delay_, __gate_open_, __multigate_, __tl_ ...). A variable of the
##                                                schematic's own named so (from the stored graph) stays the user's.
##     _ready / _init / _unhandled_input whose every body line is a compiler line (a function made for the prelude)
##     static func implemented_by + const FUNCTIONS: Array[StringName] (an interface schematic), exactly as written
##     an interface stub: func <name>(_<p>[: T], ...) -> T: with one body line `pass` or `return ...`, when the
##     stored graph lists interfaces and has no function or custom event of that name (needs the stored graph)
##   Lines inside a user function (compiler_lines):
##     __sc_trace(<graph>, <node>...)              a trace call (Show Flow and Values), at any depth
##     __p<n>_<pin>_g<g> = <value>                 an event output copied to its member on entry (_block)
##     At the top of _ready / _init / _unhandled_input, in this order (_merge_prelude, Construction Script):
##       ConstructionScript()                      first line of _ready, when the file has func ConstructionScript
##       if Engine.is_editor_hint(): / return      the editor guard: first two lines of a function, when the file
##                                                has func ConstructionScript (and the stored graph, if there is
##                                                one, is not marked tool: the guard is left out then)
##       <signal>.connect(_on_self_<signal>)       signal wiring (_ready / _init)
##       get_node(^"<path>").<signal>.connect(_on_<node>_<signal>)
##       __tl_<timeline>_<g>_<n>_run()            timeline autoplay (_ready)
##       if <event>.is_action_pressed(&"<a>"):  +  __ia_<a>_pressed()      input actions (_unhandled_input);
##       if <event>.is_action_released(&"<a>"): +  __ia_<a>_released()     <event> is the function's parameter
##       if <event> is InputEventKey and <event>.keycode == KEY_<K> and not <event>.echo:
##         + per edge: if <event>.pressed: / if not <event>.pressed:  +  __key_<k>_pressed() / _released()
##   Variables: the setter the compiler writes for a variable that notifies or re-runs the Construction Script:
##       \tset(value): / \t\t<name> = value / \t\tif is_node_ready(): / on_<name>_changed() / ConstructionScript()
##   With the stored graph (the file's own `#~` lines) the text rules also know which variables, enums and lines
##   of carried code the schematic has; without it, an enum written `enum X { a, b }` counts as the user's and any
##   other enum, every const, inner class and stray statement as carried.
## Not recognisable from the text alone: an interface stub when the stored graph is missing (it looks like any
## empty function), and a kit helper when that kit is not installed. user_edits takes owners from the graph's own
## compile for every block the two texts share, so neither matters there.

var _re_tl_machine := RegEx.create_from_string("^__tl_.+_\\d+_\\d+_(sample|run)$")
var _re_hoist := RegEx.create_from_string("^\\t__p\\d+_\\w+_g\\d+ = ")
var _re_connect := RegEx.create_from_string("^\\t(get_node\\(\\^\"(?:[^\"\\\\]|\\\\.)*\"\\)\\.)?([A-Za-z_]\\w*)\\.connect\\((_on_\\w+)\\)$")
var _re_autoplay := RegEx.create_from_string("^\\t__tl_.+_\\d+_\\d+_run\\(\\)$")
var _re_action := RegEx.create_from_string("^\\tif ([A-Za-z_]\\w*)\\.is_action_(pressed|released)\\(&\"(?:[^\"\\\\]|\\\\.)*\"\\):$")
var _re_action_call := RegEx.create_from_string("^\\t\\t__ia_\\w+_(pressed|released)\\(\\)$")
var _re_key := RegEx.create_from_string("^\\tif ([A-Za-z_]\\w*) is InputEventKey and ([A-Za-z_]\\w*)\\.keycode == \\w+ and not ([A-Za-z_]\\w*)\\.echo:$")
var _re_key_edge := RegEx.create_from_string("^\\t\\tif (not )?([A-Za-z_]\\w*)\\.pressed:$")
var _re_key_call := RegEx.create_from_string("^\\t\\t\\t__\\w+_(pressed|released)\\(\\)$")
var _re_stub := RegEx.create_from_string("^func ([A-Za-z_]\\w*)\\((_[A-Za-z_]\\w*(: [^,=()]+)?(, _[A-Za-z_]\\w*(: [^,=()]+)?)*)?\\) -> [^:]+:$")
var _re_word := RegEx.create_from_string("^([A-Za-z_]\\w*)")
var _re_enum_compact := RegEx.create_from_string("^enum [A-Za-z_]\\w* \\{ [A-Za-z_]\\w*(, [A-Za-z_]\\w*)* \\}$")


# ================================================================ split

## Splits a script into blocks in file order, every line in exactly one. See the top of the file.
func split(code: String) -> Array:
	var footer := Model.graph_block_at(code)
	var graph_line := code.count("\n", 0, footer) + 2 if footer >= 0 else -1
	var lines := code.split("\n")
	var strs := {}
	var ll := _logical(lines, strs)
	var blocks := []
	var n := ll.size()
	var pend := -1   # index in ll where a run of attachable lines (comments, annotation-only lines) begins
	var k := 0
	if n > 0 and ll[0].t != "code" and not _is_region(ll[0]):
		# the comments and blank lines the file begins with
		var jh := 0
		while jh + 1 < n and ll[jh + 1].t != "code" and not _is_region(ll[jh + 1]):
			jh += 1
		_emit(blocks, lines, strs, "header", "", ll[0].first, ll[jh].last, ll[0].first, ll[jh].last)
		k = jh + 1
	while k < n:
		var x: Dictionary = ll[k]
		if x.t == "blank":
			_flush(blocks, lines, strs, ll, pend, k - 1)
			pend = -1
			var jb := k
			while jb + 1 < n and ll[jb + 1].t == "blank":
				jb += 1
			_emit(blocks, lines, strs, "blank", "", x.first, ll[jb].last, x.first, ll[jb].last)
			k = jb + 1
			continue
		if x.t == "comment":
			if _is_region(x):
				_flush(blocks, lines, strs, ll, pend, k - 1)
				pend = -1
				var label: String = x.head.trim_prefix("#region").strip_edges() if x.head.begins_with("#region") else ""
				if int(x.first) == graph_line:
					var j := k
					while j + 1 < n and not (ll[j].t == "comment" and j > k and String(ll[j].head).begins_with("#endregion")):
						j += 1
					_emit(blocks, lines, strs, "graph", "", x.first, ll[j].last, x.first, ll[j].last)
					k = j + 1
				else:
					_emit(blocks, lines, strs, "region", label, x.first, x.last, x.first, x.last)
					k += 1
				continue
			if pend == -1:
				pend = k
			k += 1
			continue
		# a line of code
		var rest := _decl_text(lines, x)
		if rest == "" and x.ind == 0:
			if pend == -1:
				pend = k
			k += 1
			continue
		var start: int = ll[pend].first if pend != -1 else x.first
		pend = -1
		var stat := rest
		if stat.begins_with("static ") or stat.begins_with("static\t"):
			stat = stat.substr(7).strip_edges()
		var m := _re_word.search(stat)
		var kw := m.get_string(1) if m != null else ""
		var kind := "other"
		var name := ""
		match kw:
			"func": kind = "func"
			"var": kind = "var"
			"const": kind = "const"
			"signal": kind = "signal"
			"enum": kind = "enum"
			"class": kind = "inner_class"
			"class_name", "extends": kind = "class"
		if x.ind > 0:
			kind = "other"
		if kind != "other" and kw != "extends":
			var after := stat.substr(kw.length()).strip_edges()
			var nm := _re_word.search(after)
			name = nm.get_string(1) if nm != null else ""
		if kind == "class":
			var j := k
			while j + 1 < n and ll[j + 1].t == "code" and ll[j + 1].ind == 0:
				var r2 := _decl_text(lines, ll[j + 1])
				var w2 := _re_word.search(r2)
				var kw2 := w2.get_string(1) if w2 != null else ""
				if kw2 == "class_name" or kw2 == "extends":
					if kw2 == "class_name":
						var nm2 := _re_word.search(r2.substr(10).strip_edges())
						name = nm2.get_string(1) if nm2 != null else name
					j += 1
				elif r2 == "" and _class_annotations(lines, ll[j + 1]):
					j += 1
				else:
					break
			var mm := j + 1
			while mm < n and ll[mm].t == "comment" and not _is_region(ll[mm]):
				mm += 1
			if mm > j + 1 and (mm == n or ll[mm].t == "blank"):
				j = mm - 1
			_emit(blocks, lines, strs, "class", name, start, ll[j].last, x.first, x.last)
			k = j + 1
			continue
		var end_k := _body_end(ll, k)
		_emit(blocks, lines, strs, kind, name, start, ll[end_k].last, x.first, x.last)
		k = end_k + 1
	_flush(blocks, lines, strs, ll, pend, n - 1)
	return blocks


## Logical lines (1-based): [{first, last, ind, head, t}]; t is "code", "comment" or "blank". A logical line goes on
## while a bracket or a string is open or a line ends with a backslash, as GDScript (and sc_gd_parser) reads it.
## `strs` gets every line that begins inside a string.
func _logical(lines: PackedStringArray, strs: Dictionary) -> Array:
	var out := []
	var n := lines.size()
	var i := 0
	while i < n:
		var first := i
		var line := lines[i]
		var head := line.strip_edges()
		var t := "code"
		if head == "":
			t = "blank"
		elif head.unicode_at(0) == 35:
			t = "comment"
		if t == "code":
			var st := _scan(line, 0, false, 0)
			while (int(st[0]) != 0 or int(st[2]) > 0 or int(st[3]) == 92) and i + 1 < n:
				i += 1
				var more := lines[i]
				if int(st[0]) != 0:
					strs[i + 1] = true
				elif int(st[3]) == 92 and int(st[2]) <= 0 and more.strip_edges().begins_with("#"):
					continue   # a comment between the lines of a statement continued with a backslash
				st = _scan(more, int(st[0]), bool(st[1]), int(st[2]))
		out.append({"first": first + 1, "last": i + 1, "ind": _indent(line), "head": head, "t": t})
		i += 1
	return out


## Scans one physical line from the given state: [quote code (0 outside strings), triple, bracket depth, last code
## character (0 if none)].
static func _scan(text: String, q: int, triple: bool, depth: int) -> Array:
	if q == 0 and not _special(text):
		var s := text.strip_edges(false, true)
		return [0, false, depth, s.unicode_at(s.length() - 1) if s != "" else 0]
	var n := text.length()
	var last := 0
	var i := 0
	while i < n:
		var c := text.unicode_at(i)
		if q != 0:
			if c == 92:
				last = 92
				i += 2
				continue
			if c == q:
				if not triple:
					q = 0
				elif i + 2 < n and text.unicode_at(i + 1) == q and text.unicode_at(i + 2) == q:
					q = 0
					last = c
					i += 3
					continue
			if c != 32 and c != 9 and c != 13:
				last = c
			i += 1
			continue
		if c == 35:
			break
		if c == 34 or c == 39:
			if i + 2 < n and text.unicode_at(i + 1) == c and text.unicode_at(i + 2) == c:
				q = c
				triple = true
				last = c
				i += 3
				continue
			q = c
			triple = false
		elif c == 40 or c == 91 or c == 123:
			depth += 1
		elif c == 41 or c == 93 or c == 125:
			depth -= 1
		if c != 32 and c != 9 and c != 13:
			last = c
		i += 1
	return [q, triple, depth, last]


static func _special(text: String) -> bool:
	for ch in ["\"", "'", "#", "\\", "(", ")", "[", "]", "{", "}"]:
		if text.contains(ch):
			return true
	return false


static func _indent(line: String) -> int:
	var ind := 0
	for i in line.length():
		var c := line.unicode_at(i)
		if c == 9:
			ind += 4
		elif c == 32:
			ind += 1
		else:
			break
	return ind


static func _is_region(x: Dictionary) -> bool:
	return x.t == "comment" and x.ind == 0 and (String(x.head).begins_with("#region") or String(x.head).begins_with("#endregion"))


## The declaration a logical line of code holds, after the annotations it begins with ("" when it is only
## annotations).
func _decl_text(lines: PackedStringArray, x: Dictionary) -> String:
	var s: String = x.head
	if not s.begins_with("@"):
		return s
	if int(x.last) > int(x.first):
		s = "\n".join(lines.slice(int(x.first) - 1, int(x.last))).strip_edges()
	while s.begins_with("@"):
		var j := 1
		while j < s.length() and _is_id(s.unicode_at(j)):
			j += 1
		var k := j
		while k < s.length() and (s.unicode_at(k) == 32 or s.unicode_at(k) == 9):
			k += 1
		if k < s.length() and s.unicode_at(k) == 40:
			var close := _close_paren(s, k)
			if close == -1:
				return ""
			j = close + 1
		s = s.substr(j).strip_edges()
	if s.begins_with("#"):
		return ""
	return s


## True when a logical line holds only annotations of the class (@tool, @icon, @static_unload, @abstract).
func _class_annotations(lines: PackedStringArray, x: Dictionary) -> bool:
	var s: String = x.head
	for word in s.split("@", false):
		var w := word.strip_edges()
		if not (w.begins_with("tool") or w.begins_with("icon") or w.begins_with("static_unload") or w.begins_with("abstract")):
			return false
	return s.begins_with("@")


static func _is_id(c: int) -> bool:
	return c == 95 or (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c > 127


## Where the bracket opened at `at` closes (strings skipped), -1 if it does not.
static func _close_paren(s: String, at: int) -> int:
	var depth := 0
	var q := 0
	var i := at
	while i < s.length():
		var c := s.unicode_at(i)
		if q != 0:
			if c == 92:
				i += 1
			elif c == q:
				q = 0
		elif c == 34 or c == 39:
			q = c
		elif c == 40 or c == 91 or c == 123:
			depth += 1
		elif c == 41 or c == 93 or c == 125:
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


## The last logical line of the declaration at `k`: every line indented deeper than it, with the blank and comment
## lines between them, then comment lines indented deeper than it that follow directly.
func _body_end(ll: Array, k: int) -> int:
	var di: int = ll[k].ind
	var end_k := k
	var n := ll.size()
	var j := k + 1
	while j < n:
		if ll[j].t == "code":
			if int(ll[j].ind) > di:
				end_k = j
				j += 1
				continue
			break
		var m := j
		while m < n and ll[m].t != "code":
			m += 1
		if m < n and int(ll[m].ind) > di:
			end_k = m
			j = m + 1
			continue
		for t in range(j, m):
			if ll[t].t == "blank":
				continue
			if int(ll[t].ind) > di:
				end_k = t
			else:
				break
		break
	return end_k


## A run of attachable lines that turned out to be attached to nothing (a blank line or the end came first).
func _flush(blocks: Array, lines: PackedStringArray, strs: Dictionary, ll: Array, pend: int, last: int) -> void:
	if pend == -1 or last < pend:
		return
	var kind := "comment"
	var class_only := true
	for i in range(pend, last + 1):
		if ll[i].t == "code":
			kind = "other"
			if not _class_annotations(lines, ll[i]):
				class_only = false
	if kind == "other" and class_only:
		kind = "class"
	_emit(blocks, lines, strs, kind, "", ll[pend].first, ll[last].last, ll[pend].first, ll[last].last)


func _emit(blocks: Array, lines: PackedStringArray, strs: Dictionary, kind: String, name: String, from: int, to: int, head: int, head_to: int) -> void:
	var in_str := []
	for ln in range(from, to + 1):
		if strs.has(ln):
			in_str.append(ln)
	blocks.append({"kind": kind, "name": name, "from": from, "to": to, "text": "\n".join(lines.slice(from - 1, to)),
		"owner": "", "head": head, "head_to": head_to, "compiler_lines": [], "strs": in_str})


# ================================================================ classify

## Marks each block's owner and compiler_lines from the records of the compiler that produced the code (its
## line_kinds, line_map, block_lines and text_lines, and the schematic it compiled). Lines past the compiled code
## (a file's stored graph) are classified by kind.
func classify(blocks: Array, compiler: Object) -> void:
	var kinds: Dictionary = compiler.line_kinds
	var lmap: Dictionary = compiler.line_map
	var text_lines: PackedInt32Array = compiler.text_lines
	var bp: Dictionary = compiler.bp
	var var_names := _var_names(bp)
	# a line of the text -> the line of the records it belongs to (0: none), and whether it is a prelude line
	var rec := func(ln: int) -> int:
		return absi(text_lines[ln - 1]) if ln >= 1 and ln <= text_lines.size() else 0
	for blk in blocks:
		blk.compiler_lines = []
		var carried := false
		for ln in range(int(blk.from), int(blk.to) + 1):
			if String(kinds.get(rec.call(ln), "")) == "carried":
				carried = true
				break
		match String(blk.kind):
			"blank":
				blk.owner = "user"
			"graph":
				blk.owner = "compiler"
			"header":
				blk.owner = "compiler" if _is_marker(String(blk.text)) else "user"
			"class":
				blk.owner = "user"
			"var":
				if carried:
					blk.owner = "carried"
				elif lmap.has(rec.call(int(blk.head))):
					blk.owner = "compiler"   # a member written for a node (its state, a hoisted value, a timeline's)
				elif var_names.has(String(blk.name)):
					blk.owner = "user"
					var v: Dictionary = var_names[String(blk.name)]
					if String(v.get("raw", "")) == "" and v.has("type"):
						for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
							if _line(blk, ln).strip_edges() != "":
								blk.compiler_lines.append(ln)   # the setter written for a notifying variable
				else:
					blk.owner = "compiler" if String(blk.name).begins_with("__") else "user"
			"const":
				blk.owner = "carried" if carried else "compiler"   # (the compiler's only const is an interface's FUNCTIONS)
			"func":
				if carried:
					blk.owner = "carried"
					continue
				var head: int = rec.call(int(blk.head))
				var own := []
				for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
					var t := _line(blk, ln)
					if t.strip_edges() == "":
						continue
					if (ln <= text_lines.size() and text_lines[ln - 1] < 0) or _trace_or_hoist(t):
						own.append(ln)
				if String(kinds.get(head, "")) == "helper" or not lmap.has(head) or _re_tl_machine.search(String(blk.name)) != null \
						or _all_compiler(blk, own):
					blk.owner = "compiler"
				else:
					blk.owner = "user"
					blk.compiler_lines = own
			"inner_class":
				blk.owner = "carried"   # (the compiler writes no inner class of its own)
			_:   # signal, enum, comment, region, other
				blk.owner = "carried" if carried else "user"


## Marks each block's owner and compiler_lines from the text alone, by the TEXT RULES listed at the top. `bp` is
## the schematic the text was compiled from when the caller has it; otherwise the stored graph in the text (a
## `graph` block) is read, and without one only the name and shape rules apply.
func classify_text(blocks: Array, bp := {}) -> void:
	if bp.is_empty():
		bp = _stored_graph(blocks)
	var has_bp := not bp.is_empty()
	var var_names := _var_names(bp) if has_bp else {}
	var enum_names := {}
	var extra := {}
	var fn_names := {}
	var interfaces := false
	if has_bp:
		for e in bp.get("enums", []):
			enum_names[T.ident(String(e.name))] = true
		for l in String(bp.get("extra_code", "")).split("\n"):
			if l.strip_edges() != "":
				extra[l.strip_edges(false, true)] = true
		for g in bp.get("graphs", []):
			fn_names[T.ident(String(g.name))] = true
			for n in g.get("nodes", []):
				if String(n.kind) == "custom_event":
					fn_names[T.ident(String(n.p.get("name", "")))] = true
		interfaces = not bp.get("interfaces", []).is_empty()
	var has_construct := false
	# (a Construction Script writes @tool itself, so the guard's absence shows only in the stored graph's tool flag)
	var is_tool := has_bp and bool(bp.get("tool", false))
	var is_interface := false
	for blk in blocks:
		if blk.kind == "func" and blk.name == "ConstructionScript":
			has_construct = true
		if blk.kind == "func" and String(blk.text) == IMPLEMENTED_BY:
			is_interface = true
	var helpers := _kit_helpers()
	for blk in blocks:
		blk.compiler_lines = []
		var kind := String(blk.kind)
		var name := String(blk.name)
		if kind in ["blank"]:
			blk.owner = "user"
			continue
		if kind == "graph":
			blk.owner = "compiler"
			continue
		if kind == "header":
			blk.owner = "compiler" if _is_marker(String(blk.text)) else "user"
			continue
		if kind == "class":
			blk.owner = "user"
			continue
		if has_bp and not extra.is_empty() and _all_in(blk, extra):
			blk.owner = "carried"
			continue
		match kind:
			"var":
				if has_bp and var_names.has(name):
					blk.owner = "user"
				elif name.begins_with("__"):
					blk.owner = "compiler"
					continue
				else:
					blk.owner = "user"
				var raw := has_bp and var_names.has(name) and String(var_names[name].get("raw", "")) != ""
				if not raw:
					blk.compiler_lines = _setter_lines(blk)
			"signal":
				blk.owner = "user"
			"enum":
				if has_bp:
					blk.owner = "user" if enum_names.has(name) else "carried"
				else:
					blk.owner = "user" if _re_enum_compact.search(String(blk.text).strip_edges()) != null else "carried"
			"const":
				blk.owner = "compiler" if is_interface and name == "FUNCTIONS" else "carried"
			"func":
				if _is_abstract(blk):
					blk.owner = "carried"   # a function with no body (@abstract): kept as written
					continue
				if name.begins_with("__sc_") or helpers.has(name) or _re_tl_machine.search(name) != null or String(blk.text) == IMPLEMENTED_BY:
					blk.owner = "compiler"
					continue
				if interfaces and not fn_names.has(name) and _is_stub(blk):
					blk.owner = "compiler"
					continue
				var own := _text_compiler_lines(blk, has_construct, is_tool)
				if _all_compiler(blk, own):
					blk.owner = "compiler"
				else:
					blk.owner = "user"
					blk.compiler_lines = own
			"inner_class", "other":
				blk.owner = "carried" if not has_bp or kind == "inner_class" else "user"
			_:
				blk.owner = "user"


## The compiler lines of a function found by the text rules.
func _text_compiler_lines(blk: Dictionary, has_construct: bool, is_tool: bool) -> Array:
	var own := []
	var body := []   # [line number, text] of the body's non-blank lines
	for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
		var t := _line(blk, ln)
		if t.strip_edges() == "":
			continue
		body.append([ln, t])
		if _trace_or_hoist(t):
			own.append(ln)
	var name := String(blk.name)
	var i := 0
	if name == "_ready" and has_construct and i < body.size() and body[i][1] == "\tConstructionScript()":
		own.append(body[i][0])
		i += 1
	if has_construct and not is_tool and name != "ConstructionScript" and i + 1 < body.size() \
			and body[i][1] == "\tif Engine.is_editor_hint():" and body[i + 1][1] == "\t\treturn":
		own.append(body[i][0])
		own.append(body[i + 1][0])
		i += 2
	if name in PRELUDE_FUNCS:
		var param := "event"
		var header := _line(blk, int(blk.head))
		var open := header.find("(")
		if open != -1:
			var first_param := header.substr(open + 1).get_slice(",", 0).get_slice(")", 0).get_slice(":", 0).strip_edges()
			if first_param != "":
				param = first_param
		while i < body.size():
			var t: String = body[i][1]
			if name != "_unhandled_input":
				var m := _re_connect.search(t)
				if m != null:
					var handler := m.get_string(3)
					var sig := m.get_string(2)
					var ok := handler == "_on_self_" + sig if m.get_string(1) == "" else (handler.ends_with("_" + sig) and handler != "_on_self_" + sig)
					if ok:
						own.append(body[i][0])
						i += 1
						continue
				if name == "_ready" and _re_autoplay.search(t) != null:
					own.append(body[i][0])
					i += 1
					continue
				break
			var ma := _re_action.search(t)
			if ma != null and ma.get_string(1) == param and i + 1 < body.size():
				var mc := _re_action_call.search(String(body[i + 1][1]))
				if mc != null and mc.get_string(1) == ma.get_string(2):
					own.append(body[i][0])
					own.append(body[i + 1][0])
					i += 2
					continue
			var mk := _re_key.search(t)
			if mk != null and mk.get_string(1) == param and mk.get_string(2) == param and mk.get_string(3) == param:
				var j := i + 1
				var group := [body[i][0]]
				while j + 1 < body.size():
					var me := _re_key_edge.search(String(body[j][1]))
					var mcall := _re_key_call.search(String(body[j + 1][1]))
					if me == null or mcall == null or me.get_string(2) != param or (me.get_string(1) == "not ") != (mcall.get_string(1) == "released"):
						break
					group.append(body[j][0])
					group.append(body[j + 1][0])
					j += 2
				if group.size() > 1:
					own.append_array(group)
					i = j
					continue
			break
	own.sort()
	return own


func _trace_or_hoist(t: String) -> bool:
	return t.strip_edges().begins_with("__sc_trace(") or _re_hoist.search(t) != null


## True for a prelude function (_ready, _init, _unhandled_input) with every body line written by the compiler.
func _all_compiler(blk: Dictionary, own: Array) -> bool:
	if not String(blk.name) in PRELUDE_FUNCS or own.is_empty():
		return false
	var count := 0
	for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
		if _line(blk, ln).strip_edges() != "":
			count += 1
	return count == own.size()


func _setter_lines(blk: Dictionary) -> Array:
	var out := []
	var name := String(blk.name)
	var shapes := ["\tset(value):", "\t\t%s = value" % name, "\t\tif is_node_ready():", "\t\ton_%s_changed()" % name, "\t\t\ton_%s_changed()" % name,
		"\t\tConstructionScript()", "\t\t\tConstructionScript()"]
	var lines := []
	for ln in range(int(blk.head_to) + 1, int(blk.to) + 1):
		if _line(blk, ln).strip_edges() != "":
			lines.append(ln)
	if lines.is_empty() or _line(blk, lines[0]) != "\tset(value):":
		return []
	for ln in lines:
		if not _line(blk, ln).trim_suffix("\r") in shapes:
			return []
		out.append(ln)
	return out


## True for a function header with no body (an @abstract function): nothing follows it and no colon ends it.
func _is_abstract(blk: Dictionary) -> bool:
	if int(blk.to) > int(blk.head_to):
		return false
	var header := ""
	for ln in range(int(blk.head), int(blk.head_to) + 1):
		header += _line(blk, ln) + "\n"
	header = _strip_comment(header.replace("\n", " ")).strip_edges()
	var open := header.find("(", header.find("func"))
	if open == -1:
		return false
	var close := _close_paren(header, open)
	return close != -1 and not header.substr(close).contains(":")


func _is_stub(blk: Dictionary) -> bool:
	if int(blk.head) != int(blk.from) or int(blk.head_to) != int(blk.head) or int(blk.to) != int(blk.head) + 1:
		return false
	if _re_stub.search(_line(blk, int(blk.head))) == null:
		return false
	var body := _line(blk, int(blk.to))
	return body == "\tpass" or body.begins_with("\treturn ")


func _all_in(blk: Dictionary, extra: Dictionary) -> bool:
	var any := false
	for l in String(blk.text).split("\n"):
		var s := l.strip_edges(false, true)
		if s == "":
			continue
		if not extra.has(s):
			return false
		any = true
	return any


func _is_marker(text: String) -> bool:
	return text.begins_with(Model.MARKER) or text.begins_with(Model.OLD_MARKER)


## name -> the variable's entry, for the schematic's variables and the locals of its event graphs (a local of an
## event graph becomes a member when more than one event uses it; it is still the one the person declared).
func _var_names(bp: Dictionary) -> Dictionary:
	var out := {}
	for g in bp.get("graphs", []):
		if String(g.get("kind", "")) != "function" and String(g.get("kind", "")) != "macro":
			for l in g.get("locals", []):
				out[T.ident(String(l.name))] = {"raw": "", "local": true}
	for v in bp.get("variables", []):
		out[T.ident(String(v.name))] = v
	return out


func _kit_helpers() -> Dictionary:
	var out := {}
	for tid in R.templates:
		var t: Dictionary = R.templates[tid]
		if t.has("helper") and t.helper is Array and not t.helper.is_empty():
			out[String(t.helper[0])] = true
	return out


func _stored_graph(blocks: Array) -> Dictionary:
	for blk in blocks:
		if blk.kind != "graph":
			continue
		var json := PackedStringArray()
		for line in String(blk.text).replace("\r", "").split("\n"):
			if line.begins_with(Model.DATA_PREFIX):
				json.append(line.substr(Model.DATA_PREFIX.length()))
			elif line == "#~":
				json.append("")
		var parsed: Variant = JSON.parse_string("\n".join(json))
		if typeof(parsed) == TYPE_DICTIONARY:
			return Model.normalize(parsed)
	return {}


## The text of an absolute line of a block, without a CRLF file's "\r".
## (The split lines are kept in the block under "_l" so that reading many lines of one block stays cheap.)
static func _line(blk: Dictionary, ln: int) -> String:
	if not blk.has("_l"):
		blk["_l"] = String(blk.text).split("\n")
	var lines: PackedStringArray = blk["_l"]
	var i := ln - int(blk.from)
	return lines[i].trim_suffix("\r") if i >= 0 and i < lines.size() else ""


# ================================================================ diff

## Compares two classified splits (`old` and `new`; diff ignores blank blocks). Returns
##   {unchanged, changed, added, removed, moved, renamed}
## Each entry: {kind, name, old (index into old_blocks, -1 if none), new (index into new_blocks, -1), status,
## change, moved, confidence, compiler_changed, trace_only, hunks}.
##   Blocks are matched by kind + name first (in order when a name repeats), then the unmatched ones of one kind by
##   similarity: a pair at RENAME_AT or above is `renamed` (confidence = similarity of the two with each one's own
##   name blanked out; 1.0 when they are the same but for the name). Unnamed blocks (comments, regions, stray
##   lines) match when equal, else the most similar one of their kind.
##   change: "" (unchanged), "comment_only" (only comments differ), "compiler_only" (a function whose lines that
##   are not compiler_lines are the same on both sides: not a user edit), "code".
##   Text is compared line by line with trailing spaces, "\r" and blank lines set aside; leading whitespace is
##   compared exactly (a changed indent is a change). Lines inside multi-line strings are compared exactly.
##   hunks (for a changed function): [{old: [line...], new: [line...], owner}] where owner is "compiler" when the
##   old side of the hunk is only compiler lines (a compiler line edited or deleted) or, with nothing on the old
##   side, the new side is only compiler lines (one added), else "user". compiler_changed: some hunk is the
##   compiler's; trace_only: every compiler hunk is trace lines only.
##   moved: matched blocks whose order changed (those outside the longest run kept in order); they are also listed
##   under unchanged or changed.
func diff(old_blocks: Array, new_blocks: Array) -> Dictionary:
	var out := {"unchanged": [], "changed": [], "added": [], "removed": [], "moved": [], "renamed": []}
	var on := []
	var nn := []
	for b in old_blocks:
		on.append(_norm(b))
	for b in new_blocks:
		nn.append(_norm(b))
	var pairs := []   # [old index, new index, renamed confidence or -1]
	var used_o := {}
	var used_n := {}
	# 1. kind + name
	var by_key := {}
	for j in new_blocks.size():
		var b: Dictionary = new_blocks[j]
		if b.kind == "blank" or String(b.name) == "":
			continue
		var key := "%s:%s" % [b.kind, b.name]
		if not by_key.has(key):
			by_key[key] = []
		by_key[key].append(j)
	for i in old_blocks.size():
		var b: Dictionary = old_blocks[i]
		if b.kind == "blank" or String(b.name) == "":
			continue
		var key := "%s:%s" % [b.kind, b.name]
		if by_key.has(key) and not by_key[key].is_empty():
			var j: int = by_key[key].pop_front()
			pairs.append([i, j, -1.0])
			used_o[i] = true
			used_n[j] = true
	# 2. unnamed blocks: equal text, then by kind (header / class are one per file)
	for i in old_blocks.size():
		var b: Dictionary = old_blocks[i]
		if used_o.has(i) or b.kind == "blank" or String(b.name) != "":
			continue
		for j in new_blocks.size():
			var c: Dictionary = new_blocks[j]
			if used_n.has(j) or c.kind != b.kind or String(c.name) != "":
				continue
			if on[i].all == nn[j].all or b.kind in ["header", "class", "graph"]:
				pairs.append([i, j, -1.0])
				used_o[i] = true
				used_n[j] = true
				break
	# 3. what is left, by similarity within a kind
	var cands := []
	for i in old_blocks.size():
		var b: Dictionary = old_blocks[i]
		if used_o.has(i) or b.kind == "blank":
			continue
		for j in new_blocks.size():
			var c: Dictionary = new_blocks[j]
			if used_n.has(j) or c.kind != b.kind:
				continue
			if (String(b.name) == "") != (String(c.name) == ""):
				continue
			var s := _similarity(_texts(on[i].code, String(b.name)), _texts(nn[j].code, String(c.name)))
			if s >= RENAME_AT or (String(b.name) == "" and s >= 0.5):
				cands.append([s, i, j])
	cands.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for cd in cands:
		if used_o.has(int(cd[1])) or used_n.has(int(cd[2])):
			continue
		used_o[int(cd[1])] = true
		used_n[int(cd[2])] = true
		pairs.append([int(cd[1]), int(cd[2]), float(cd[0]) if String(old_blocks[int(cd[1])].name) != "" else -1.0])
	# moved: outside the longest run of pairs kept in order
	pairs.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	var in_order := _longest_increasing(pairs.map(func(p): return int(p[1])))
	for pi in pairs.size():
		var p: Array = pairs[pi]
		var ob: Dictionary = old_blocks[int(p[0])]
		var nb: Dictionary = new_blocks[int(p[1])]
		var e := _entry(ob, nb, int(p[0]), int(p[1]), on[int(p[0])], nn[int(p[1])])
		e.moved = not in_order.has(pi)
		if float(p[2]) >= 0.0:
			e.status = "renamed"
			e.confidence = float(p[2])
			e["old_name"] = String(ob.name)
			e.name = String(nb.name)
			out.renamed.append(e)
		elif e.change == "":
			e.status = "unchanged"
			out.unchanged.append(e)
		else:
			e.status = "changed"
			out.changed.append(e)
		if e.moved:
			out.moved.append(e)
	for i in old_blocks.size():
		if not used_o.has(i) and old_blocks[i].kind != "blank":
			out.removed.append(_lone(old_blocks[i], i, -1, "removed"))
	for j in new_blocks.size():
		if not used_n.has(j) and new_blocks[j].kind != "blank":
			out.added.append(_lone(new_blocks[j], -1, j, "added"))
	return out


func _lone(b: Dictionary, i: int, j: int, status: String) -> Dictionary:
	return {"kind": String(b.kind), "name": String(b.name), "old": i, "new": j, "status": status, "change": "code", "moved": false,
		"confidence": 1.0, "compiler_changed": false, "trace_only": true, "hunks": []}


func _entry(ob: Dictionary, nb: Dictionary, i: int, j: int, on: Dictionary, nn: Dictionary) -> Dictionary:
	var e := {"kind": String(nb.kind), "name": String(nb.name), "old": i, "new": j, "status": "", "change": "", "moved": false,
		"confidence": 1.0, "compiler_changed": false, "trace_only": true, "hunks": []}
	if on.all == nn.all:
		return e
	var oc := _texts(on.code, "")
	var nc := _texts(nn.code, "")
	if oc == nc:
		e.change = "comment_only"
		return e
	e.change = "code"
	if ob.kind != "func" or oc.size() * nc.size() > 4000000:
		return e
	var hunks := _hunks(on.code, nn.code)
	var user_hunk := false
	for h in hunks:
		if h.owner == "compiler":
			e.compiler_changed = true
			if not h.trace:
				e.trace_only = false
		else:
			user_hunk = true
		h.erase("trace")
	e.hunks = hunks
	if not user_hunk:
		e.change = "compiler_only"
	return e


## Normalised lines of a block: {all: [text], code: [[text, flag, line]]}; flag 0 user, 1 compiler line, 2 trace.
func _norm(b: Dictionary) -> Dictionary:
	var all := PackedStringArray()
	var code := []
	var strs := {}
	for ln in b.get("strs", []):
		strs[int(ln)] = true
	var own := {}
	for ln in b.get("compiler_lines", []):
		own[int(ln)] = true
	var lines := String(b.text).split("\n")
	for idx in lines.size():
		var ln := int(b.from) + idx
		var raw := lines[idx].trim_suffix("\r")
		if strs.has(ln):
			all.append(raw)
			code.append([raw, 1 if own.has(ln) else 0, ln])
			continue
		var s := raw.strip_edges(false, true)
		if s == "":
			continue
		all.append(s)
		var c := _strip_comment(s) if s.contains("#") else s
		if c.strip_edges() == "":
			continue
		var flag := 0
		if own.has(ln):
			flag = 2 if c.strip_edges().begins_with("__sc_trace(") else 1
		code.append([c, flag, ln])
	return {"all": all, "code": code}


static func _strip_comment(s: String) -> String:
	var q := 0
	var i := 0
	while i < s.length():
		var c := s.unicode_at(i)
		if q != 0:
			if c == 92:
				i += 1
			elif c == q:
				q = 0
		elif c == 34 or c == 39:
			q = c
		elif c == 35:
			return s.substr(0, i).strip_edges(false, true)
		i += 1
	return s


## The texts of normalised code lines; with `name`, that name blanked out as a word.
func _texts(code: Array, name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var re: RegEx = null
	if name != "":
		re = RegEx.create_from_string("\\b%s\\b" % name)
	for c in code:
		out.append(re.sub(String(c[0]), "\u0001", true) if re != null else String(c[0]))
	return out


func _similarity(a: PackedStringArray, b: PackedStringArray) -> float:
	if a.is_empty() and b.is_empty():
		return 1.0
	if a == b:
		return 1.0
	if a.size() * b.size() > 4000000:
		var set := {}
		for x in a:
			set[x] = true
		var common := 0
		for y in b:
			if set.has(y):
				common += 1
		return 2.0 * common / float(a.size() + b.size())
	return 2.0 * _lcs_table(a, b)[a.size() * (b.size() + 1) + b.size()] / float(a.size() + b.size())


## LCS lengths of prefixes: t[i * (m + 1) + j] is the LCS of a[..i) and b[..j); the whole is t[n * (m + 1) + m].
func _lcs_table(a: PackedStringArray, b: PackedStringArray) -> PackedInt32Array:
	var n := a.size()
	var m := b.size()
	var w := m + 1
	var t := PackedInt32Array()
	t.resize((n + 1) * w)
	for i in range(1, n + 1):
		for j in range(1, m + 1):
			if a[i - 1] == b[j - 1]:
				t[i * w + j] = t[(i - 1) * w + j - 1] + 1
			else:
				t[i * w + j] = maxi(t[(i - 1) * w + j], t[i * w + j - 1])
	return t


## The changed runs between two functions' code lines, each with whose it is (see diff).
func _hunks(a: Array, b: Array) -> Array:
	var at := PackedStringArray()
	var bt := PackedStringArray()
	for x in a:
		at.append(String(x[0]))
	for y in b:
		bt.append(String(y[0]))
	var t := _lcs_table(at, bt)
	var w := bt.size() + 1
	# walk back from the end, collecting matched pairs
	var i := at.size()
	var j := bt.size()
	var ops := []   # [kind, index] in reverse: "=", "-", "+"
	while i > 0 or j > 0:
		if i > 0 and j > 0 and at[i - 1] == bt[j - 1]:
			ops.append(["=", i - 1, j - 1])
			i -= 1
			j -= 1
		elif j > 0 and (i == 0 or t[i * w + j - 1] >= t[(i - 1) * w + j]):
			ops.append(["+", -1, j - 1])
			j -= 1
		else:
			ops.append(["-", i - 1, -1])
			i -= 1
	ops.reverse()
	var hunks := []
	var cur := {}
	for op in ops:
		if op[0] == "=":
			if not cur.is_empty():
				hunks.append(cur)
				cur = {}
			continue
		if cur.is_empty():
			cur = {"old": [], "new": [], "of": [], "nf": []}
		if op[0] == "-":
			cur.old.append(int(a[int(op[1])][2]))
			cur.of.append(int(a[int(op[1])][1]))
		else:
			cur.new.append(int(b[int(op[2])][2]))
			cur.nf.append(int(b[int(op[2])][1]))
	if not cur.is_empty():
		hunks.append(cur)
	for h in hunks:
		var old_compiler: bool = not h.of.is_empty() and h.of.all(func(f): return int(f) != 0)
		var new_compiler: bool = h.of.is_empty() and not h.nf.is_empty() and h.nf.all(func(f): return int(f) != 0)
		h["owner"] = "compiler" if old_compiler or new_compiler else "user"
		h["trace"] = (h.of + h.nf).all(func(f): return int(f) == 2)
		h.erase("of")
		h.erase("nf")
	return hunks


## Indices (into `seq`) of one longest strictly increasing subsequence, as a set.
static func _longest_increasing(seq: Array) -> Dictionary:
	var n := seq.size()
	var best := []
	var prev := []
	best.resize(n)
	prev.resize(n)
	var top := -1
	for i in n:
		best[i] = 1
		prev[i] = -1
		for k in i:
			if int(seq[k]) < int(seq[i]) and int(best[k]) + 1 > int(best[i]):
				best[i] = int(best[k]) + 1
				prev[i] = k
		if top == -1 or int(best[i]) > int(best[top]):
			top = i
	var out := {}
	while top != -1:
		out[top] = true
		top = int(prev[top])
	return out


# ================================================================ user edits

## What a person changed by hand in `file_code` against `graph_code`, the code `compiler` just compiled from the
## graph. See the top of the file for what it returns.
func user_edits(file_code: String, graph_code: String, compiler: Object) -> Dictionary:
	var gb := split(graph_code)
	classify(gb, compiler)
	var fb := split(file_code)
	classify_text(fb, compiler.bp)
	# a block both texts have is whoever's the graph's compile says it is
	var owner_of := {}
	for b in gb:
		if String(b.name) != "":
			owner_of["%s:%s" % [b.kind, b.name]] = String(b.owner)
	for b in fb:
		var key := "%s:%s" % [b.kind, b.name]
		if String(b.name) != "" and owner_of.has(key) and String(owner_of[key]) != String(b.owner):
			b.owner = owner_of[key]
			if b.owner != "user":
				b.compiler_lines = []
	var d := diff(gb, fb)
	var out := {"nothing": true, "functions": {"changed": [], "added": [], "removed": [], "renamed": [], "moved": []},
		"declarations": [], "carried": [], "compiler": [], "diff": d, "file_blocks": fb, "graph_blocks": gb}
	for e in d.changed + d.renamed + d.added + d.removed:
		var blk: Dictionary = gb[int(e.old)] if int(e.old) >= 0 else fb[int(e.new)]
		var owner := String(blk.owner)
		e["owner"] = owner
		if e.kind == "graph" or e.kind == "blank":
			continue
		if owner == "compiler":
			if e.status in ["added", "removed"] and String(e.name) in TRACE_MACHINERY:
				continue   # Show Flow and Values on in one, off in the other
			out.compiler.append(e)
		elif owner == "carried":
			out.carried.append(e)
		elif e.kind == "func":
			if e.compiler_changed and not e.trace_only:
				out.compiler.append({"kind": "func", "name": e.name, "old": e.old, "new": e.new, "status": "compiler_lines", "owner": "compiler",
					"hunks": e.hunks.filter(func(h): return h.owner == "compiler")})
			if e.change == "compiler_only":
				continue
			out.functions[e.status].append(e)
		else:
			out.declarations.append(e)
	for e in d.moved:
		if e.kind == "func":
			out.functions.moved.append(e)
	for key in ["changed", "added", "removed", "renamed"]:
		if not out.functions[key].is_empty():
			out.nothing = false
	if not out.declarations.is_empty() or not out.carried.is_empty() or not out.compiler.is_empty():
		out.nothing = false
	return out


# ================================================================ re-import

## RE-IMPORT
##   var r := sync.reimport(bp, file_code, opts)   # -> {ok, bp, report}; `bp` is never modified
## Brings what a person changed by hand in a Schematic's code (`file_code`: the file's text, with or without its
## stored graph) back into the graph `bp`. Only the functions and events whose code differs from what the graph
## compiles to are rebuilt from their code; everything else stays exactly as it was (the same objects, ids,
## positions, comment boxes, editor-only fields). r.bp is a new schematic when ok, else a copy of the input.
##
## THE RULE: the result is accepted only when it compiles to the edited code. Both texts are compared block by
## block (functions by name, so their order does not count; member variables in order), with blank lines, `#`
## comments and the trace lines of Show Flow and Values set aside. Anything else that differs makes ok false, and
## report.first_difference shows where. The comments are compared on their own: the converter keeps them (on the
## nodes of the statements they are written with, see the importer's _block), so a function whose comments
## changed is rebuilt like one whose code changed, a changed comment between declarations is taken into the
## declarations' comment fields, and every comment of the file the result does not write is counted in
## comments_dropped (with its line in comment_lines): one written into Schematic's own code (a helper, a member
## it keeps for a node, the prelude it puts at the top of _ready) and one in a part of the file nothing is
## rebuilt from (a comment edit inside a function that is refused for another reason is not brought in either).
## Two exceptions, both accepted and reported because the next save writes those lines differently from the file:
## a line that means the same written with other brackets (`return v + 3` where Schematic writes `return (v + 3)`,
## `signal done` for `signal done()`: see _norm_line; report.reformatted), and an event local the conversion must
## give its event's name because another event declares the same name (report.renamed_locals).
##
## How each part is brought in:
##   function       its graph is replaced by the graph a conversion of the whole edited file makes of it (the
##                  whole file, so that members, signals, constants and other functions' signatures type it). The
##                  graph keeps its id, name, place in the list and view; the new nodes are placed relative to the
##                  old entry node; a comment box that holds the entry node stays. The lambda graphs it alone
##                  used are replaced by the ones it uses now (reusing their ids, then new ones).
##   event          (one entry node in the shared EventGraph) only its chain is replaced: see _extent for the exact
##                  rule. The entry node keeps its id and place; the other events' nodes are not touched. The
##                  EventGraph locals only the old chain used go, the new chain's locals come in (named as the
##                  conversion of the whole file names them: see renamed_locals). A custom event's code converts
##                  to a function graph; its chain is put under the custom event node the same way (the node keeps
##                  its id, place and settings; its parameters become the file's).
##   added         a new function graph at the end of the list, or a new event entry and chain below everything
##                  in the EventGraph.
##   removed        the graph or the chain goes, with the lambda graphs only it used.
##   renamed        (diff's rename with confidence >= 0.9) the graph or custom event is renamed in place, with
##                  every Call / Event Reference / Lambda node that names it; its body is rebuilt only if it also
##                  differs.
##   declarations   a changed, added or removed variable or signal is merged by name from the conversion,
##                  keeping the fields only the editor uses (tooltip, a category that is not an export group, and
##                  `notify`, whose setter lines are the compiler's); variables and signals follow the file's
##                  order; a changed one-line enum of the schematic's list takes the file's values; `extends`,
##                  `class_name`, `@tool` and class annotations take the file's when their line changed;
##                  carried-over code (extra_code) is the file's when any of it changed.
## Refused (ok false, a reason naming the line in report.refused): an edit to a block or line Schematic writes
## for itself (a helper, a member it keeps for a node, the prelude of _ready / _unhandled_input, a trace line,
## the Construction Script's call and guard, an interface stub); an edit to the function of a Signal event,
## Input Action, Key event or Timeline node (Schematic names and calls those itself); code that uses one of
## Schematic's own names (a Do Once's or Delay's member, a helper); a file that does not load (GDScript's
## message and line); a result that does not compile to the file. A comment written into Schematic's own code is
## not an edit (it is dropped and counted).
## Accepted with a note: a function the converter keeps as code nodes (code_node_lines), a function whose graph
## used macros (macros_expanded: the rebuilt graph has the expanded nodes), dropped comments, an event local that
## must carry its event's name (renamed_locals), lines written with other brackets (reformatted), functions or
## declarations reordered in the file (notes; the next save writes Schematic's order).
## Not handled: a cross-event wire from a replaced chain into another event (a hand-made graph can have one) is
## lost with the chain; the check then refuses, since the other event no longer compiles the same.
##
## opts: dry (bool: check everything, return the input unchanged with the report), only ([names]: rebuild these
## functions or events even if their code is unchanged), path (the script's path: scenes that use it type $nodes),
## gentle (bool, default true: keep the nodes of the lines that did not change, see KEEPING WHAT DID NOT CHANGE;
## false rebuilds each function whole), spoil_gentle (for the self-test only: breaks the kept-nodes result so that
## the fallback to the whole rebuild can be seen).
##
## report: {ok, dry, functions: [{name, action, kind (function | event | custom | lambda), old_name}],
##   declarations: [{kind, name, action}],
##   refused: [{line, name, reason}], comments_dropped, comment_lines, macros_expanded, code_node_lines,
##   renamed_locals: [{function, written, now}], reformatted: [{line, file, graph}],
##   replaced: {graph id: [node ids no longer there]}, first_difference: [{key, name, line, file, graph}],
##   notes: [String], gentle: {name: {path, why, kept_nodes, new_nodes}}, ms}
## replaced lists, per graph, exactly the node ids that went: with nodes kept (see KEEPING WHAT DID NOT CHANGE)
## only those of the lines that changed, and the new nodes get ids above every id the graph had, so a breakpoint
## or watch on an id not listed is on the same node as before. A graph rebuilt whole (opts.gentle false, or one of
## the reasons there) lists every node id it had (its new nodes may reuse those ids for other nodes). An event
## graph lists the ids taken out of it (the entry keeps its id). A graph touched only by an added event is listed
## with no ids.
## action: kept, rebuilt, added, removed, renamed (renamed and rebuilt: "renamed+rebuilt").

## Entry nodes whose function Schematic names and calls itself.
const NODE_FUNCS := {"signal_event": "Signal event", "input_action": "Input Action", "key_event": "Key event", "timeline": "Timeline"}
const EVENT_ENTRIES := ["event", "custom_event", "signal_event", "input_action", "key_event"]
## Nodes that name a function graph in p.fn.
const REF_KINDS := ["call_self", "event_ref", "closure"]
## Variable fields that decide how a declaration is written: the file's when it changed.
const VAR_CODE := ["name", "type", "default", "export", "raw", "written", "enum", "category", "note", "tail"]
## Fields of the converter's that hold the comments a person wrote (see the importer's _block and the parser's
## COMMENTS): a declaration's, a function entry's, and the schematic's own.
const COMMENT_FIELDS := ["note", "tail", "end"]
## Graph fields the conversion decides (the rest of an old graph's fields are the editor's and are kept).
## (`pure` is not one: a converted function never is, and whether callers call it as a pure node is the
## person's choice; the check shows whether the edited body still compiles the same way.)
const GRAPH_CODE := ["inputs", "outputs", "locals", "next_id", "nodes", "wires", "static", "pre", "ret_hint", "ret_default", "latent", "lambda"]
const NEW_EVENT_GAP := 200.0
const RENAME_SURE := 0.9


func reimport(bp: Dictionary, file_code: String, opts := {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var rep := {"ok": false, "dry": bool(opts.get("dry", false)), "functions": [], "declarations": [], "refused": [], "comments_dropped": 0,
		"comment_lines": [], "macros_expanded": 0, "code_node_lines": 0, "renamed_locals": [], "reformatted": [], "replaced": {},
		"first_difference": [], "notes": [], "gentle": {}, "ms": 0.0}
	var out := {"ok": false, "bp": bp.duplicate(true), "report": rep}
	var code := Model.code_part(file_code)
	var c0 := Compiler.new()
	var graph_code := Model.normalize_code(c0.compile(bp.duplicate(true)))
	var e := user_edits(code, graph_code, c0)
	var fb: Array = e.file_blocks
	var gb: Array = e.graph_blocks
	var only := {}
	for nm in opts.get("only", []):
		only[String(nm)] = true

	# 1. edits to what Schematic writes for itself
	var prelude_added := {}
	for ce in e.compiler:
		if String(ce.get("change", "")) == "comment_only":
			continue   # a comment written into Schematic's own code: dropped like any comment (counted below)
		if String(ce.kind) == "func" and String(ce.status) == "changed" and String(ce.name) in PRELUDE_FUNCS and int(ce.old) >= 0 and int(ce.new) >= 0 \
				and _prelude_given_lines(gb[int(ce.old)], fb[int(ce.new)], fb, bool(bp.get("tool", false))):
			prelude_added[String(ce.name)] = true   # a function Schematic made for its prelude, given lines of the person's
			continue
		_refuse_compiler(rep, ce, gb, fb)
	var fcanon := _canon(fb)
	if not rep.refused.is_empty():
		return _done(out, t0)
	var quiet: bool = e.nothing or (e.compiler.all(func(x): return String(x.get("change", "")) == "comment_only") and e.declarations.is_empty()
		and e.carried.is_empty() and e.functions.changed.is_empty() and e.functions.added.is_empty() and e.functions.removed.is_empty() and e.functions.renamed.is_empty())
	if quiet and only.is_empty():
		_comments(rep, fcanon, _canon(gb))
		for nm in fcanon.funcs:
			rep.functions.append({"name": nm, "action": "kept"})
		var moved: Array = e.diff.moved.filter(func(x): return String(x.kind) != "func")
		if not moved.is_empty():
			rep.notes.append("%s reordered in the file; the next save writes them in Schematic's order" % ", ".join(moved.map(func(x): return String(x.name))))
		rep.ok = true
		out.ok = true
		return _done(out, t0)

	# 2. the file must load (where the graph's own code does)
	var err := _load_error(code)
	if not err.is_empty() and _load_error(graph_code).is_empty():
		_refuse(rep, int(err.line), "", "the file does not load: line %d: %s. Fix the code, then re-import" % [int(err.line), String(err.msg).trim_suffix(".")])
		return _done(out, t0)

	# 3. the whole edited file converted, without what Schematic writes for itself
	var entries0 := _entries(gb, c0)
	var reserved := _reserved(gb, entries0)
	var conv: Dictionary = Importer.new().convert(_user_text(code, fb), {"path": String(opts.get("path", ""))})
	var fresh: Dictionary = conv.bp

	# 4. renames and declarations, in a copy
	var cand := bp.duplicate(true)
	var renamed := {}   # new name -> old name
	for re in e.functions.renamed:
		var en: Dictionary = entries0.get(String(re.old_name), {})
		if en.is_empty() or float(re.confidence) < RENAME_SURE:
			continue
		if (String(en.kind) == "fn_entry" and String(en.gkind) == "function" and not bool(en.lambda)) or String(en.kind) == "custom_event":
			_rename(cand, String(re.old_name), String(re.name))
			renamed[String(re.name)] = String(re.old_name)
	var decl_changed := _merge_declarations(cand, fresh, e, fb, gb, rep)
	if not rep.refused.is_empty():
		return _done(out, t0)
	var cand_c: Object = c0
	var cand_blocks: Array = gb
	if not renamed.is_empty() or decl_changed:
		cand_c = Compiler.new()
		cand_blocks = split(Model.normalize_code(cand_c.compile(cand.duplicate(true))))
		classify(cand_blocks, cand_c)
	var entries_c := _entries(cand_blocks, cand_c)
	var ccanon := _canon(cand_blocks)

	# 5. what to rebuild
	var todo := []   # {name, action: rebuild | add | remove, entry}
	var file_owner := {}
	for b in fb:
		if String(b.kind) == "func":
			file_owner[String(b.name)] = String(b.owner)
	for nm in ccanon.funcs:
		if not entries_c.has(nm):
			continue
		var key := "func:" + String(nm)
		if not fcanon.keys.has(key):
			todo.append({"name": nm, "action": "remove", "entry": entries_c[nm]})
		elif fcanon.keys[key] != ccanon.keys[key] or fcanon.cmts.get(key, []) != ccanon.cmts.get(key, []) or only.has(nm) or (renamed.has(nm) and only.has(renamed[nm])):
			# (a function whose comments changed is rebuilt too: the converter keeps comments, on its nodes)
			todo.append({"name": nm, "action": "rebuild", "entry": entries_c[nm]})
	for nm in fcanon.funcs:
		if entries_c.has(nm) or String(file_owner.get(nm, "user")) == "compiler":
			continue
		if not ccanon.keys.has("func:" + String(nm)) or prelude_added.has(nm):
			todo.append({"name": nm, "action": "add", "entry": {}})
	for nm in only:
		if not entries_c.has(nm) and not renamed.values().has(nm):
			rep.notes.append("there is no function or event named %s to rebuild" % nm)

	# 6. what each one is, and what can't be brought in
	var fresh_eg: Dictionary = fresh.graphs[0] if not fresh.graphs.is_empty() else {}
	var items := []
	for t in todo:
		var nm := String(t.name)
		var en: Dictionary = t.entry
		var line := _func_line(fb, nm)
		var where := ("line %d" % line) if line > 0 else "deleted from the file"
		if t.action != "add":
			var ek := String(en.kind)
			if NODE_FUNCS.has(ek):
				_refuse(rep, line, nm, "func %s (%s) is the code of the %s node in %s; Schematic names it and calls it itself, so it can't be edited as code. Change that node's chain in the graph, or undo the edit" % [nm, where, NODE_FUNCS[ek], en.graph])
				continue
			if not ek in ["fn_entry", "event", "custom_event"]:
				_refuse(rep, line, nm, "func %s (%s) comes from a %s node, which can't be rebuilt from code" % [nm, where, ek])
				continue
		if t.action != "remove":
			var used := _reserved_used(fb, nm, reserved)
			if used != "":
				_refuse(rep, line, nm, "func %s (%s) uses %s, %s; rebuilt from code it would no longer have that node. Make this change in the graph instead" % [nm, where, used, reserved[used]])
				continue
		var src := _fresh_source(fresh, fresh_eg, nm)
		if t.action != "remove" and src.is_empty():
			_refuse(rep, line, nm, "func %s (%s) could not be read from the file" % [nm, where])
			continue
		var old_kind := ""
		if t.action != "add":
			old_kind = "custom" if String(en.kind) == "custom_event" else ("event" if String(en.kind) in EVENT_ENTRIES else ("lambda" if bool(en.lambda) else "function"))
		if t.action == "rebuild" and old_kind != String(src.kind) and not (old_kind in ["lambda", "custom"] and src.kind == "function"):
			items.append({"name": nm, "action": "remove", "entry": en, "kind": old_kind, "split": true})
			items.append({"name": nm, "action": "add", "entry": {}, "kind": src.kind, "src": src, "split": true})
			continue
		items.append({"name": nm, "action": t.action, "entry": en, "kind": old_kind if t.action != "add" else String(src.kind), "src": src})
	if not rep.refused.is_empty():
		return _done(out, t0)

	# 7. build, keeping the nodes of the lines that did not change where it can (see KEEPING WHAT DID NOT CHANGE)
	var gctx := {}
	if bool(opts.get("gentle", true)) and items.any(func(it): return String(it.action) == "rebuild"):
		var fc := Compiler.new()
		var fblocks := split(Model.normalize_code(fc.compile(fresh.duplicate(true))))
		classify(fblocks, fc)
		gctx = {"oc": cand_c, "ob": cand_blocks, "nc": fc, "nb": fblocks, "lines": conv.get("lines", {}), "writers": conv.get("writers", {}), "fresh": fresh,
			"spoil": bool(opts.get("spoil_gentle", false))}
	var snap := rep.duplicate(true)
	var cand0: Dictionary = cand.duplicate(true) if not gctx.is_empty() else {}
	var res := cand
	var local_names := _build(res, items, fresh, fb, rep, gctx)

	# 8. the rule: the result compiles to the file
	var rcanon := _check(res, fcanon, local_names, c0, rep)
	if not rep.refused.is_empty() and rep.gentle.values().any(func(x): return int(x.get("hand_kept", 0)) > 0):
		# hand-made nodes kept as they were did not give the file back: only the nodes shaped like the conversion's
		var why0 := String(rep.refused[0].reason)
		var names0: Array = rep.gentle.keys().filter(func(k): return int(rep.gentle[k].get("hand_kept", 0)) > 0)
		rep.clear()
		rep.merge(snap.duplicate(true))
		res = cand0.duplicate(true)
		local_names = _build(res, items, fresh, fb, rep, gctx.merged({"no_hand": true}))
		rcanon = _check(res, fcanon, local_names, c0, rep)
		if rep.refused.is_empty():
			rep.notes.append("%s: keeping hand-made nodes as they were did not compile to the file (%s), so only the nodes shaped like the conversion's were kept" % [", ".join(names0), why0])
	var gentle_used: bool = rep.gentle.values().any(func(x): return String(x.path) == "gentle")
	if not rep.refused.is_empty() and gentle_used:
		# the kept nodes did not give the file back: the whole functions rebuilt, as they always were, if that does
		var tried: Dictionary = rep.gentle.duplicate(true)
		var why := String(rep.refused[0].reason)
		rep.clear()
		rep.merge(snap.duplicate(true))
		res = cand0.duplicate(true)
		local_names = _build(res, items, fresh, fb, rep, {})
		rcanon = _check(res, fcanon, local_names, c0, rep)
		for nm in tried:
			if String(tried[nm].path) == "gentle":
				rep.gentle[nm] = {"path": "full", "why": "keeping the unchanged nodes did not give the file back (%s): the whole function was rebuilt" % why, "kept_nodes": 0,
					"new_nodes": int(tried[nm].kept_nodes) + int(tried[nm].new_nodes)}
		if rep.refused.is_empty():
			rep.notes.append("%s: keeping the unchanged nodes did not compile to the file, so %s rebuilt whole" % [", ".join(tried.keys().filter(func(k): return String(tried[k].path) == "gentle")),
				"it was" if tried.size() == 1 else "they were"])
	_comments(rep, fcanon, rcanon)
	# what was done, per function and declaration
	var done := {}
	for it in items:
		var nm := String(it.name)
		var act: String = {"rebuild": "rebuilt", "add": "added", "remove": "removed"}[String(it.action)]
		if it.get("split", false):
			act = "rebuilt"
		var row := {"name": nm, "kind": it.kind, "action": act}
		if rep.gentle.has(nm) and act == "rebuilt":
			row.merge(rep.gentle[nm])
		if renamed.has(nm):
			row.action = "renamed+rebuilt"
			row["old_name"] = renamed[nm]
		done[nm] = row
	for nm in renamed:
		if not done.has(nm):
			done[nm] = {"name": nm, "kind": "function", "action": "renamed", "old_name": renamed[nm]}
	for nm in fcanon.funcs:
		rep.functions.append(done.get(nm, {"name": nm, "action": "kept"}))
	for nm in done:
		if not fcanon.funcs.has(nm):
			rep.functions.append(done[nm])
	if not e.functions.moved.is_empty():
		rep.notes.append("functions were reordered in the file (%s); Schematic writes them in its own order, so the next save puts them back" % ", ".join(e.functions.moved.map(func(x): return String(x.name))))
	rep.notes.append_array(conv.report.notes.filter(func(n): return String(n).contains("kept whole") or String(n).contains("kept as text")))
	if rep.refused.is_empty():
		rep.ok = true
		out.ok = true
		if not rep.dry:
			out.bp = res
	return _done(out, t0)


## Step 7 of reimport: removes, rebuilds and adds what `items` says, in `res`. `gctx` (empty: every function rebuilt
## whole) holds what keeping the unchanged nodes needs. Returns {event name: [locals its new chain uses]}.
func _build(res: Dictionary, items: Array, fresh: Dictionary, fb: Array, rep: Dictionary, gctx: Dictionary) -> Dictionary:
	var local_names := {}
	# a lambda graph rebuilt by itself is left to its owner when the owner is rebuilt too
	var rebuilt_graphs := {}
	for it in items:
		if it.action != "add" and it.kind == "function":
			rebuilt_graphs[int(it.entry.gid)] = true
	for it in items:
		if it.action == "remove":
			if it.kind in ["event", "custom"]:
				_remove_event(res, int(it.entry.gid), int(it.entry.nid), rep)
			else:
				_remove_graph(res, int(it.entry.gid), rep)
	for it in items:
		if it.action != "rebuild":
			continue
		if it.kind in ["event", "custom"]:
			# (a custom event's code converts to a function graph: its chain goes under the custom event node)
			local_names[String(it.name)] = _put_event(res, int(it.entry.gid), int(it.entry.nid), fresh, it.src, rep, gctx, String(it.name))
		else:
			if it.kind == "lambda" and _owner_rebuilt(res, int(it.entry.gid), rebuilt_graphs):
				continue
			_put_function(res, int(it.entry.gid), fresh, it.src, rep, gctx, String(it.name))
	for it in items:
		if it.action != "add":
			continue
		if it.kind == "event":
			local_names[String(it.name)] = _put_event(res, -1, -1, fresh, it.src, rep)
		else:
			_put_function(res, -1, fresh, it.src, rep)
	_follow_file_order(res, fb, rep)
	return local_names


## Step 8 of reimport, the rule: refuses (in rep) unless `res` compiles to the file. Returns the result's form (_canon).
func _check(res: Dictionary, fcanon: Dictionary, local_names: Dictionary, c0: Object, rep: Dictionary) -> Dictionary:
	var cf := Compiler.new()
	var res_code := Model.normalize_code(cf.compile(res.duplicate(true)))
	var rcanon := _canon(split(res_code))
	var diffs := _compare(fcanon, rcanon, local_names, rep)
	var errs0 := {}
	for x in c0.errors:
		if not bool(x.get("w", false)):
			errs0[String(x.m)] = true
	for x in cf.errors:
		if not bool(x.get("w", false)) and not errs0.has(String(x.m)):
			_refuse(rep, 0, "", "the rebuilt graph has an error: %s" % String(x.m))
	if not diffs.is_empty():
		rep.first_difference = diffs
		var d0: Dictionary = diffs[0]
		_refuse(rep, int(d0.line), String(d0.get("name", "")), "the rebuilt graph does not compile to the file%s: file line %d is `%s`, the graph writes `%s`. Nothing was changed" % [
			(" (in %s)" % d0.name) if String(d0.get("name", "")) != "" else "", int(d0.line), String(d0.file).strip_edges(), String(d0.graph).strip_edges()])
	return rcanon


func _done(out: Dictionary, t0: int) -> Dictionary:
	out.report.ms = (Time.get_ticks_usec() - t0) / 1000.0
	return out


func _refuse(rep: Dictionary, line: int, name: String, reason: String) -> void:
	rep.refused.append({"line": line, "name": name, "reason": reason})


## What a compiler-owned block or line is, in words.
func _compiler_what(kind: String, name: String, text := "") -> String:
	if kind == "func":
		if name.begins_with("__sc_"):
			return "a helper function"
		if _re_tl_machine.search(name) != null:
			return "the machinery of a Timeline node"
		if name in PRELUDE_FUNCS:
			return "the function it makes to connect signals and dispatch input"
		if name == "implemented_by":
			return "the check of a Schematic Interface"
		return "the empty function an interface needs, or a node kit's helper"
	if kind == "var":
		if name in TRACE_MACHINERY:
			return "a member of Show Flow and Values"
		return "a member it keeps for a node (its state, or a value read on another path)"
	if kind == "const":
		return "the function list of a Schematic Interface"
	var t := text.strip_edges()
	if t.begins_with("__sc_trace("):
		return "a trace line of Show Flow and Values"
	if t.contains(".connect("):
		return "the wiring of a Signal event node"
	if t.contains("is_action_") or t.begins_with("__ia_"):
		return "the input dispatch of an Input Action node"
	if t.contains("InputEventKey") or t.ends_with(".pressed:") or t.begins_with("__key_"):
		return "the input dispatch of a Key event node"
	if t.begins_with("__tl_"):
		return "a Timeline's autoplay"
	if t == "ConstructionScript()" or t == "if Engine.is_editor_hint():" or t == "return":
		return "the Construction Script's call or editor guard"
	if t.begins_with("__p"):
		return "a value of this event that another event reads"
	return "the setter of a variable that notifies or re-runs the Construction Script"


func _refuse_compiler(rep: Dictionary, ce: Dictionary, gb: Array, fb: Array) -> void:
	var name := String(ce.name)
	if String(ce.status) == "compiler_lines":
		for h in ce.hunks:
			if not h.new.is_empty():
				var ln := int(h.new[0])
				var t := _line(fb[int(ce.new)], ln)
				_refuse(rep, ln, name, "line %d in %s: `%s` is written by Schematic (%s); change the node that produces it in the graph, or undo the edit" % [ln, name, t.strip_edges(), _compiler_what("", "", t)])
			else:
				var t := _line(gb[int(ce.old)], int(h.old[0]))
				var at := int(fb[int(ce.new)].head) if int(ce.new) >= 0 else 0
				_refuse(rep, at, name, "in %s (line %d), the line `%s` that Schematic writes (%s) was deleted; change the node that produces it in the graph, or undo the edit" % [name, at, t.strip_edges(), _compiler_what("", "", t)])
		return
	var kind := String(ce.kind)
	var what := _compiler_what(kind, name)
	if String(ce.status) == "removed":
		_refuse(rep, 0, name, "%s %s, which Schematic writes (%s), was deleted from the file; change the graph instead, or undo the edit" % [kind, name, what])
	elif String(ce.status) == "added":
		var b: Dictionary = fb[int(ce.new)]
		_refuse(rep, int(b.head), name, "line %d: %s %s has a name Schematic keeps for its own code (%s); give it another name" % [int(b.head), kind, name, what])
	else:
		var b: Dictionary = fb[int(ce.new)] if int(ce.new) >= 0 else gb[int(ce.old)]
		_refuse(rep, int(b.head), name, "line %d: %s %s is written by Schematic (%s); it can't be edited by hand. Change the node that produces it, or undo the edit" % [int(b.head), kind, name, what])


## True when a function Schematic made only for its prelude (_ready, _init, _unhandled_input) still has exactly
## that prelude at its top and lines of the person's below it: those lines are a new event. The file block is
## marked as the user's, its prelude as compiler lines.
func _prelude_given_lines(gblk: Dictionary, fblk: Dictionary, fb: Array, is_tool: bool) -> bool:
	if _line(gblk, int(gblk.head)) != _line(fblk, int(fblk.head)):
		return false
	var has_construct := fb.any(func(b): return String(b.kind) == "func" and String(b.name) == "ConstructionScript")
	var own := _text_compiler_lines(fblk, has_construct, is_tool)
	var mine := []
	for ln in range(int(gblk.head_to) + 1, int(gblk.to) + 1):
		var t := _line(gblk, ln)
		if t.strip_edges() != "":
			mine.append(t)
	var theirs := own.map(func(ln): return _line(fblk, int(ln)))
	if mine != theirs:
		return false
	var body := 0
	for ln in range(int(fblk.head_to) + 1, int(fblk.to) + 1):
		var t := _line(fblk, ln)
		if t.strip_edges() != "" and not t.strip_edges().begins_with("#"):
			body += 1
	if body <= own.size():
		return false
	fblk.owner = "user"
	fblk.compiler_lines = own
	return true


## The text of `code` with every block and line Schematic writes for itself blanked out (line numbers stay).
func _user_text(code: String, blocks: Array) -> String:
	# (a line set aside is "#~", which the converter passes over: a blank line would be taken for one the person left)
	var lines := code.split("\n")
	for b in blocks:
		if String(b.owner) == "compiler":
			for ln in range(int(b.from), int(b.to) + 1):
				lines[ln - 1] = "#~"
		else:
			for ln in b.compiler_lines:
				lines[int(ln) - 1] = "#~"
	return "\n".join(lines)


## name -> {gid, nid, kind (of the entry node), graph, gkind, lambda, line} for every function of the person's in
## compiled code, read from the compiler's records.
func _entries(blocks: Array, comp: Object) -> Dictionary:
	var out := {}
	var tl: PackedInt32Array = comp.text_lines
	for b in blocks:
		if String(b.kind) != "func" or String(b.owner) != "user":
			continue
		var head := int(b.head)
		var rec := absi(tl[head - 1]) if head >= 1 and head <= tl.size() else 0
		var at: Array = comp.line_map.get(rec, [])
		if at.is_empty():
			continue
		var g := Model.find_graph(comp.bp, int(at[0]))
		var n := Model.find_node(g, int(at[1])) if not g.is_empty() else {}
		out[String(b.name)] = {"gid": int(at[0]), "nid": int(at[1]), "kind": String(n.get("kind", "")), "graph": String(g.get("name", "")),
			"gkind": String(g.get("kind", "")), "lambda": g.has("lambda"), "line": head}
	return out


## Names Schematic chooses for its own code -> what they are: compiler-owned blocks and the functions of nodes
## whose function it names.
func _reserved(gb: Array, entries: Dictionary) -> Dictionary:
	var out := {}
	for b in gb:
		if String(b.owner) == "compiler" and String(b.name) != "" and String(b.kind) in ["func", "var"]:
			out[String(b.name)] = "which Schematic writes for itself (%s)" % _compiler_what(String(b.kind), String(b.name))
	for nm in entries:
		var en: Dictionary = entries[nm]
		if NODE_FUNCS.has(String(en.kind)):
			out[String(nm)] = "the function Schematic writes for the %s node" % NODE_FUNCS[String(en.kind)]
	return out


## The first of Schematic's own names the person's lines of a function use, or "".
func _reserved_used(fb: Array, name: String, reserved: Dictionary) -> String:
	if reserved.is_empty():
		return ""
	for b in fb:
		if String(b.kind) != "func" or String(b.name) != name:
			continue
		var own := {}
		for ln in b.compiler_lines:
			own[int(ln)] = true
		for ln in range(int(b.head_to) + 1, int(b.to) + 1):
			if own.has(ln):
				continue
			var t := _strip_comment(_line(b, ln))
			for m in _re_ident.search_all(t):
				var w := m.get_string()
				if reserved.has(w) and w != name:
					return w
	return ""


var _re_ident := RegEx.create_from_string("[A-Za-z_][A-Za-z_0-9]*")


func _func_line(fb: Array, name: String) -> int:
	for b in fb:
		if String(b.kind) == "func" and String(b.name) == name:
			return int(b.head)
	return 0


## Where the conversion has a function or event: {kind: "function" | "event", graph, node} or {}.
func _fresh_source(fresh: Dictionary, eg: Dictionary, name: String) -> Dictionary:
	if not eg.is_empty():
		for n in eg.nodes:
			if String(n.kind) == "event" and String(n.p.get("name", "")) == name:
				return {"kind": "event", "graph": eg, "node": n}
	for g in fresh.graphs:
		if String(g.kind) == "function" and String(g.name) == name:
			return {"kind": "function", "graph": g, "node": _fn_entry(g)}
	return {}


static func _fn_entry(g: Dictionary) -> Dictionary:
	for n in g.nodes:
		if String(n.kind) == "fn_entry":
			return n
	return {}


func _rename(bp: Dictionary, old_name: String, new_name: String) -> void:
	for g in bp.graphs:
		if String(g.kind) == "function" and String(g.name) == old_name:
			g.name = new_name
		for n in g.nodes:
			if String(n.kind) in REF_KINDS and String(n.p.get("fn", "")) == old_name:
				n.p.fn = new_name
			elif String(n.kind) == "custom_event" and String(n.p.get("name", "")) == old_name:
				n.p.name = new_name


# ---------------------------------------------------------------- declarations

## Merges changed declarations from the conversion into `bp`. True when anything changed.
func _merge_declarations(bp: Dictionary, fresh: Dictionary, e: Dictionary, fb: Array, gb: Array, rep: Dictionary) -> bool:
	var changed := false
	for d in e.declarations:
		var kind := String(d.kind)
		var name := String(d.name)
		var status := String(d.status)
		var fblk: Dictionary = fb[int(d.new)] if int(d.new) >= 0 else {}
		var gblk: Dictionary = gb[int(d.old)] if int(d.old) >= 0 else {}
		match kind:
			"var":
				var old_name := String(d.get("old_name", name))
				var old := Model.find_var(bp, old_name) if status != "added" else {}
				var fv: Dictionary = Model.find_var(fresh, name) if status != "removed" else {}
				if status != "added" and old.is_empty():
					rep.notes.append("var %s is not in the variable list (an event's local kept as a member): left to the check" % old_name)
					continue
				if status != "removed" and fv.is_empty():
					_refuse(rep, int(fblk.get("head", 0)), name, "line %d: the declaration of %s could not be read as a variable" % [int(fblk.get("head", 0)), name])
					continue
				if status == "removed":
					bp.variables.erase(old)
					rep.declarations.append({"kind": "var", "name": name, "action": "removed"})
				elif status == "added":
					bp.variables.append(fv.duplicate(true))
					rep.declarations.append({"kind": "var", "name": name, "action": "added"})
				else:
					var merged := fv.duplicate(true)
					for k in old:
						if not k in VAR_CODE and k != "tooltip" and not merged.has(k):
							merged[k] = old[k]
					merged["tooltip"] = old.get("tooltip", "")
					if old.has("notify"):
						merged["notify"] = old.notify   # its setter lines are the compiler's
					if not bool(merged.get("export", false)) and old.has("category"):
						merged["category"] = old.category   # (only an export group is code)
					bp.variables[bp.variables.find(old)] = merged
					rep.declarations.append({"kind": "var", "name": name, "action": "renamed" if status == "renamed" else "rebuilt", "old_name": old_name})
				changed = true
			"signal":
				var old_name := String(d.get("old_name", name))
				var old := Model.find_dispatcher(bp, old_name) if status != "added" else {}
				var fs: Dictionary = Model.find_dispatcher(fresh, name) if status != "removed" else {}
				if (status != "added" and old.is_empty()) or (status != "removed" and fs.is_empty()):
					_refuse(rep, int(fblk.get("head", 0)), name, "line %d: the signal %s could not be read" % [int(fblk.get("head", 0)), name])
					continue
				if status == "removed":
					bp.dispatchers.erase(old)
				elif status == "added":
					bp.dispatchers.append(fs.duplicate(true))
				else:
					var merged := fs.duplicate(true)
					for k in old:
						if not k in ["name", "params", "pre", "declared", "note", "tail"] and not merged.has(k):
							merged[k] = old[k]
					bp.dispatchers[bp.dispatchers.find(old)] = merged
				rep.declarations.append({"kind": "signal", "name": name, "action": {"removed": "removed", "added": "added", "renamed": "renamed"}.get(status, "rebuilt")})
				changed = true
			"enum":
				var at := -1
				for i in bp.get("enums", []).size():
					if T.ident(String(bp.enums[i].name)) == name:
						at = i
				if at == -1:
					continue
				if status == "removed":
					bp.enums.remove_at(at)
				else:
					var text := _strip_comment(String(fblk.text).strip_edges())
					if _re_enum_compact.search(text) == null:
						_refuse(rep, int(fblk.head), name, "line %d: enum %s is no longer written the way Schematic's enum list holds it (enum %s { A, B } on one line); edit it in Class Settings" % [int(fblk.head), name, name])
						continue
					var vals := text.substr(text.find("{") + 1).trim_suffix("}").strip_edges().split(",")
					bp.enums[at].values = Array(vals).map(func(v): return String(v).strip_edges())
				rep.declarations.append({"kind": "enum", "name": name, "action": "removed" if status == "removed" else "rebuilt"})
				changed = true
			"class":
				changed = _merge_class(bp, fresh, gblk, fblk, rep) or changed
			"comment", "region", "header":
				# comments standing between declarations: the converter gives them to the declaration below them (or
				# to the schematic, above its class lines or after everything), so those take the file's comments
				changed = _take_comments(bp, fresh) or changed
			_:
				rep.notes.append("%s %s (line %d) changed outside any function: left to the check" % [kind, name, int(fblk.get("head", gblk.get("head", 0)))])
	if not e.carried.is_empty():
		var extra := _without_enums(String(fresh.get("extra_code", "")), bp)
		if extra != String(bp.get("extra_code", "")):
			if extra == "":
				bp.erase("extra_code")
			else:
				bp["extra_code"] = extra
			changed = true
		for c in e.carried:
			rep.declarations.append({"kind": String(c.kind), "name": String(c.name), "action": String(c.status) if String(c.status) in ["added", "removed"] else "rebuilt", "carried": true})
	return changed


## Every variable's and signal's comments (note, tail) and the schematic's own (note, end_note) as the conversion of
## the file has them. True when anything changed.
func _take_comments(bp: Dictionary, fresh: Dictionary) -> bool:
	var changed := false
	for list in ["variables", "dispatchers"]:
		for item in bp.get(list, []):
			var fi: Dictionary = Model.find_var(fresh, String(item.name)) if list == "variables" else Model.find_dispatcher(fresh, String(item.name))
			if fi.is_empty():
				continue
			for k in ["note", "tail"]:
				if fi.has(k) and item.get(k) != fi[k]:
					item[k] = fi[k].duplicate() if fi[k] is Array else fi[k]
					changed = true
				elif not fi.has(k) and item.has(k):
					item.erase(k)
					changed = true
	for k in ["note", "end_note"]:
		if fresh.has(k) and bp.get(k) != fresh[k]:
			bp[k] = fresh[k].duplicate()
			changed = true
		elif not fresh.has(k) and bp.has(k):
			bp.erase(k)
			changed = true
	return changed


## The class line block: each of @tool, class_name, extends and the other class annotations is the file's when
## its line changed.
func _merge_class(bp: Dictionary, fresh: Dictionary, gblk: Dictionary, fblk: Dictionary, rep: Dictionary) -> bool:
	var g := _class_lines(gblk)
	var f := _class_lines(fblk)
	var changed := false
	if g.tool != f.tool:
		bp.tool = f.tool
		changed = true
	if g.class_name != f.class_name:
		bp.class_name = String(fresh.get("class_name", ""))
		changed = true
	if g.extends != f.extends:
		bp.parent = String(fresh.parent)
		changed = true
	if g.pre != f.pre:
		if fresh.has("class_pre"):
			bp["class_pre"] = fresh.class_pre.duplicate()
		else:
			bp.erase("class_pre")
		changed = true
	if changed:
		rep.declarations.append({"kind": "class", "name": String(bp.class_name), "action": "rebuilt"})
	return changed


func _class_lines(blk: Dictionary) -> Dictionary:
	var out := {"tool": false, "class_name": "", "extends": "", "pre": []}
	if blk.is_empty():
		return out
	for l in String(blk.text).split("\n"):
		var s := _strip_comment(l.strip_edges())
		if s == "":
			continue
		if s == "@tool":
			out.tool = true
		elif s.begins_with("class_name"):
			out.class_name = s
			if s.contains(" extends "):
				out.extends = s.substr(s.find(" extends "))
		elif s.begins_with("extends"):
			out.extends = s
		else:
			out.pre.append(s)
	return out


## Carried code without the enums the schematic's own enum list holds (a conversion carries every enum).
func _without_enums(extra: String, bp: Dictionary) -> String:
	var own := {}
	for en in bp.get("enums", []):
		own[T.ident(String(en.name))] = true
	if own.is_empty() or extra == "":
		return extra
	var keep := PackedStringArray()
	for b in split(extra):
		if String(b.kind) == "enum" and own.has(String(b.name)):
			continue
		keep.append(String(b.text))
	return "\n".join(keep).strip_edges()


## Variables and signals follow the order the file declares them in.
func _follow_file_order(bp: Dictionary, fb: Array, rep: Dictionary) -> void:
	for pair in [["var", "variables"], ["signal", "dispatchers"]]:
		var order := []
		for b in fb:
			if String(b.kind) == pair[0] and String(b.name) != "":
				order.append(String(b.name))
		var list: Array = bp[pair[1]]
		var named := list.filter(func(v): return order.has(T.ident(String(v.name))))
		var sorted := named.duplicate()
		sorted.sort_custom(func(a, b): return order.find(T.ident(String(a.name))) < order.find(T.ident(String(b.name))))
		if sorted == named:
			continue
		var k := 0
		for i in list.size():
			if order.has(T.ident(String(list[i].name))):
				list[i] = sorted[k]
				k += 1
		rep.notes.append("the %s follow the file's order now" % ("member variables" if pair[0] == "var" else "signals"))


# ---------------------------------------------------------------- graphs

## A name node (see Model.forget_place) says which node (`p.of`) of which graph (`p.in`) its name belongs to:
## moved to graph `to_gid` with node ids changed by `map`, it says so again.
static func _regraph(nodes: Array, from_gid: int, to_gid: int, map: Dictionary) -> void:
	for n in nodes:
		var p: Dictionary = n.get("p", {})
		if p.has("of") and map.has(int(p.of)):
			p.of = map[int(p.of)]
		if p.has("in") and int(p["in"]) == from_gid:
			p["in"] = to_gid


static func _ids(nodes: Array) -> Dictionary:
	var out := {}
	for n in nodes:
		out[int(n.id)] = true
	return out


## The names of the lambda graphs the given nodes refer to, and the ones those refer to, in order.
func _lambdas_of(bp: Dictionary, nodes: Array) -> Array:
	var out := []
	var queue := [nodes]
	while not queue.is_empty():
		var batch: Array = queue.pop_front()
		for n in batch:
			if not String(n.kind) in REF_KINDS:
				continue
			var nm := String(n.p.get("fn", ""))
			if out.has(nm):
				continue
			var lg := Model.graph_named(bp, nm)
			if lg.is_empty() or not lg.has("lambda"):
				continue
			out.append(nm)
			queue.append(lg.nodes)
	return out


## The lambda graphs `nodes` (in graph `gid`, or a whole graph when `gid`'s graph is replaced: `skip` holds the
## node ids going) use that nothing staying uses.
func _lambdas_only(bp: Dictionary, gid: int, skip: Dictionary, whole: bool) -> Array:
	var g := Model.find_graph(bp, gid)
	var going: Array = g.nodes if whole else g.nodes.filter(func(n): return skip.has(int(n.id)))
	var mine := _lambdas_of(bp, going)
	if mine.is_empty():
		return []
	var staying := []
	for og in bp.graphs:
		if mine.has(String(og.name)):
			continue
		if int(og.id) == gid:
			if not whole:
				staying.append_array(og.nodes.filter(func(n): return not skip.has(int(n.id))))
			continue
		staying.append_array(og.nodes)
	var others := _lambdas_of(bp, staying)
	return mine.filter(func(nm): return not others.has(nm))


## Takes out the lambda graphs named `old`, puts in copies of the conversion's lambda graphs named `new` where
## the first of the old ones was (ids of the old ones reused), each under a name no other graph has. `nodes` are
## the new nodes that refer to them (renamed with them). Returns [[old graph, the copy that took its place, the
## copy's id in the conversion]] for each old one that a new one replaced.
func _swap_lambdas(bp: Dictionary, old: Array, fresh: Dictionary, new: Array, nodes: Array, rep: Dictionary) -> Array:
	var pairs := []
	var slots := []   # indices of the old ones, in order
	for i in bp.graphs.size():
		var g: Dictionary = bp.graphs[i]
		if old.has(String(g.name)):
			slots.append(i)
			rep.replaced[int(g.id)] = g.nodes.map(func(n): return int(n.id))
	var copies := []
	for g in fresh.get("graphs", []):
		if new.has(String(g.name)):
			copies.append(g.duplicate(true))
	var taken := []
	for i in bp.graphs.size():
		if not slots.has(i):
			taken.append(String(bp.graphs[i].name))
	var rename := {}
	for lg in copies:
		var nm := String(lg.name)
		if taken.has(nm):
			var to := Model.unique_name(nm, taken + new)
			rename[nm] = to
			lg.name = to
		taken.append(String(lg.name))
	if not rename.is_empty():
		var everywhere := nodes.duplicate()
		for lg in copies:
			everywhere.append_array(lg.nodes)
		for n in everywhere:
			if String(n.kind) in REF_KINDS and rename.has(String(n.p.get("fn", ""))):
				n.p.fn = rename[String(n.p.fn)]
	var top := 0
	for g in bp.graphs:
		top = maxi(top, int(g.id))
	# the k-th new one takes the place and id of the k-th old one; more new ones follow the last of those (or go at
	# the end); old ones left over go
	var pos: int = bp.graphs.size() if slots.is_empty() else int(slots[-1]) + 1
	for k in copies.size():
		var lg: Dictionary = copies[k]
		var was := int(lg.id)
		if k < slots.size():
			lg.id = int(bp.graphs[int(slots[k])].id)
			_regraph(lg.nodes, was, int(lg.id), {})
			pairs.append([bp.graphs[int(slots[k])], lg, was])
			bp.graphs[int(slots[k])] = lg
			pos = int(slots[k]) + 1
		else:
			top += 1
			lg.id = top
			_regraph(lg.nodes, was, int(lg.id), {})
			bp.graphs.insert(mini(pos, bp.graphs.size()), lg)
			pos += 1
	if copies.size() < slots.size():
		for k in range(slots.size() - 1, copies.size() - 1, -1):
			bp.graphs.remove_at(int(slots[k]))
	return pairs


func _count_kinds(rep: Dictionary, removed: Array, added: Array) -> void:
	for n in removed:
		if String(n.kind) == "macro":
			rep.macros_expanded = int(rep.macros_expanded) + 1
	for n in added:
		if String(n.kind) == "code":
			rep.code_node_lines = int(rep.code_node_lines) + String(n.p.get("code", "")).split("\n").size()


static func _encloses(box: Dictionary, n: Dictionary) -> bool:
	var x := float(box.x)
	var y := float(box.y)
	return float(n.x) >= x and float(n.y) >= y and float(n.x) <= x + float(box.p.get("w", 0)) and float(n.y) <= y + float(box.p.get("h", 0))


## The comment boxes of `nodes` that hold a node going and no node staying (`going`: ids).
static func _boxes_going(nodes: Array, going: Dictionary) -> Dictionary:
	var out := {}
	for box in nodes:
		if String(box.kind) != "comment":
			continue
		var any_going := false
		var any_staying := false
		for n in nodes:
			if String(n.kind) == "comment" or not _encloses(box, n):
				continue
			if going.has(int(n.id)):
				any_going = true
			else:
				any_staying = true
		if any_going and not any_staying:
			out[int(box.id)] = true
	return out


## Replaces function graph `gid` with the conversion's graph (gid -1: adds it at the end). With `gctx`, the nodes of
## the lines that did not change are kept (see KEEPING WHAT DID NOT CHANGE) when that can be done.
func _put_function(bp: Dictionary, gid: int, fresh: Dictionary, src: Dictionary, rep: Dictionary, gctx := {}, name := "") -> void:
	var fg: Dictionary = src.graph
	var ng: Dictionary = fg.duplicate(true)
	var new_lambdas := _lambdas_of(fresh, fg.nodes)
	if gid == -1:
		var top := 0
		for g in bp.graphs:
			top = maxi(top, int(g.id))
		ng.id = top + 1
		_regraph(ng.nodes, int(fg.id), int(ng.id), {})
		bp.graphs.append(ng)
		_swap_lambdas(bp, [], fresh, new_lambdas, ng.nodes, rep)
		_count_kinds(rep, [], ng.nodes)
		return
	var idx := -1
	for i in bp.graphs.size():
		if int(bp.graphs[i].id) == gid:
			idx = i
	var old: Dictionary = bp.graphs[idx]
	var old_lambdas := _lambdas_only(bp, gid, {}, true)
	var plan := {}
	if not gctx.is_empty():
		plan = _plan(name, gctx, bp, old, _ids(old.nodes.filter(func(n): return String(n.kind) != "comment")), int(_fn_entry(old).get("id", -1)),
			fg, _ids(fg.nodes.filter(func(n): return String(n.kind) != "comment")), int(_fn_entry(fg).get("id", -1)),
			bp.graphs.filter(func(g): return old_lambdas.has(String(g.name))), fresh.graphs.filter(func(g): return new_lambdas.has(String(g.name))))
		rep.gentle[name] = plan.report
	if bool(plan.get("ok", false)) and plan.has("graph"):
		ng = plan.graph.duplicate(true)   # (with hand-made nodes kept in it: _hand_units)
	ng.id = old.id
	ng.name = old.name
	for k in old:
		if not ng.has(k) or k in ["zoom", "sx", "sy", "pure"]:
			if not k in GRAPH_CODE:
				ng[k] = old[k]
	if bool(plan.get("ok", false)):
		var gone := _gentle_graph(bp, old, fresh, ng, int(fg.id), plan.maps[int(old.id)].map, rep.gentle[name])
		rep.replaced[int(old.id)] = gone
		if bool(gctx.get("spoil", false)):
			ng.wires = []   # (opts.spoil_gentle, for the self-test of the fallback: a result that can't compile to the file)
		_count_kinds(rep, old.nodes.filter(func(n): return gone.has(int(n.id))), ng.nodes)
		bp.graphs[idx] = ng
		for pair in _swap_lambdas(bp, old_lambdas, fresh, new_lambdas, ng.nodes, rep):
			if plan.maps.has(int(pair[0].id)) and int(plan.maps[int(pair[0].id)].fresh) == int(pair[2]):
				rep.replaced[int(pair[0].id)] = _gentle_graph(bp, pair[0], fresh, pair[1], int(pair[2]), plan.maps[int(pair[0].id)].map, rep.gentle[name])
		return
	_regraph(ng.nodes, int(fg.id), int(ng.id), {})
	var oe := _fn_entry(old)
	var ne := _fn_entry(ng)
	if not oe.is_empty() and not ne.is_empty():
		var dx := float(oe.x) - float(ne.x)
		var dy := float(oe.y) - float(ne.y)
		for n in ng.nodes:
			n.x = float(n.x) + dx
			n.y = float(n.y) + dy
	# a comment box that holds the entry node stays (it names the function); the others went with their nodes
	var going := {}
	for n in old.nodes:
		if String(n.kind) != "fn_entry":
			going[int(n.id)] = true
	var boxes := _boxes_going(old.nodes, going)
	for n in old.nodes:
		if String(n.kind) == "comment" and not boxes.has(int(n.id)) and not oe.is_empty() and _encloses(n, oe):
			var box: Dictionary = n.duplicate(true)
			box.id = int(ng.next_id)
			ng.next_id = int(ng.next_id) + 1
			ng.nodes.append(box)
	rep.replaced[int(old.id)] = old.nodes.map(func(n): return int(n.id))
	_count_kinds(rep, old.nodes, ng.nodes)
	bp.graphs[idx] = ng
	_swap_lambdas(bp, old_lambdas, fresh, new_lambdas, ng.nodes, rep)


func _remove_graph(bp: Dictionary, gid: int, rep: Dictionary) -> void:
	var old_lambdas := _lambdas_only(bp, gid, {}, true)
	for i in bp.graphs.size():
		if int(bp.graphs[i].id) == gid:
			rep.replaced[gid] = bp.graphs[i].nodes.map(func(n): return int(n.id))
			bp.graphs.remove_at(i)
			break
	_swap_lambdas(bp, old_lambdas, {}, [], [], rep)


func _owner_rebuilt(bp: Dictionary, gid: int, rebuilt: Dictionary) -> bool:
	var lg := Model.find_graph(bp, gid)
	for g in bp.graphs:
		if rebuilt.has(int(g.id)) and _lambdas_of(bp, g.nodes).has(String(lg.get("name", ""))):
			return true
	return false


## The nodes of one event's chain in an event graph (ids, the entry included). The exact rule:
##   1. every node reachable from the entry node by execution wires (following only output pins of type exec),
##      except a node that is also reachable that way from another entry node (shared: it stays, and the
##      rebuilt event gets its own copy);
##   2. then, repeatedly, every pure node (no execution pin: getters, math, data reroutes, name nodes) whose
##      every outgoing wire goes into the chain (a pure node that also feeds something else stays).
## Comment boxes are not part of a chain (see _boxes_going).
func _extent(bp: Dictionary, g: Dictionary, entry_id: int) -> Dictionary:
	var by_id := {}
	var outs := {}
	for n in g.nodes:
		by_id[int(n.id)] = n
	for w in g.wires:
		if not outs.has(int(w[0])):
			outs[int(w[0])] = []
		outs[int(w[0])].append(w)
	var exec_out := {}   # id -> {pin: true}
	var has_exec := {}
	for n in g.nodes:
		if String(n.kind) == "comment":
			continue
		var d := R.describe(n, bp, g)
		var pins := {}
		var any := false
		for po in d.get("outs", []):
			if String(po.type) == "exec":
				pins[String(po.id)] = true
				any = true
		for pi in d.get("ins", []):
			if String(pi.type) == "exec":
				any = true
		exec_out[int(n.id)] = pins
		has_exec[int(n.id)] = any
	var reach := func(start: int) -> Dictionary:
		var seen := {start: true}
		var queue := [start]
		while not queue.is_empty():
			var id: int = queue.pop_back()
			for w in outs.get(id, []):
				if exec_out.get(id, {}).has(String(w[1])) and not seen.has(int(w[2])) and by_id.has(int(w[2])):
					seen[int(w[2])] = true
					queue.append(int(w[2]))
		return seen
	var mine: Dictionary = reach.call(entry_id)
	var others := {}
	for n in g.nodes:
		if int(n.id) != entry_id and String(n.kind) in EVENT_ENTRIES:
			others.merge(reach.call(int(n.id)))
	var chain := {}
	for id in mine:
		if id == entry_id or not others.has(id):
			chain[id] = true
	var more := true
	while more:
		more = false
		for n in g.nodes:
			var id := int(n.id)
			if chain.has(id) or String(n.kind) == "comment" or bool(has_exec.get(id, true)):
				continue
			var ws: Array = outs.get(id, [])
			if ws.is_empty():
				continue
			if ws.all(func(w): return chain.has(int(w[2]))):
				chain[id] = true
				more = true
	return chain


static func _locals_used(nodes: Array) -> Dictionary:
	var out := {}
	for n in nodes:
		if String(n.kind) in ["local_get", "local_set"]:
			out[String(n.p.get("name", ""))] = true
	return out


## Puts the conversion's chain for an event in place of the chain of entry `nid` in event graph `gid` (gid -1:
## adds the event to the first event graph, below everything in it). Returns the names of the locals the new
## chain uses.
func _put_event(bp: Dictionary, gid: int, nid: int, fresh: Dictionary, src: Dictionary, rep: Dictionary, gctx := {}, name := "") -> Array:
	var feg: Dictionary = src.graph
	var fentry: Dictionary = src.node
	var fchain := _extent(fresh, feg, int(fentry.id))
	var fnodes: Array = feg.nodes.filter(func(n): return fchain.has(int(n.id)))
	if not gctx.is_empty() and nid != -1:
		var geg := Model.find_graph(bp, gid)
		var gchain := _extent(bp, geg, nid)
		var lams_old := _lambdas_only(bp, gid, gchain, false)
		var lams_new := _lambdas_of(fresh, fnodes)
		var plan := _plan(name, gctx, bp, geg, gchain, nid, feg, fchain, int(fentry.id),
			bp.graphs.filter(func(g): return lams_old.has(String(g.name))), fresh.graphs.filter(func(g): return lams_new.has(String(g.name))))
		rep.gentle[name] = plan.report
		if bool(plan.ok):
			return _gentle_event(bp, geg, nid, gchain, fresh, feg, fentry, fnodes, plan, rep, rep.gentle[name])
	var eg := Model.find_graph(bp, gid) if gid != -1 else {}
	if eg.is_empty():
		for g in bp.graphs:
			if String(g.kind) == "event":
				eg = g
				break
	if eg.is_empty():
		eg = Model.new_graph(bp, "EventGraph", "event")
		bp.graphs.erase(eg)
		bp.graphs.push_front(eg)
	var going := {}
	var entry: Dictionary = Model.find_node(eg, nid) if nid != -1 else {}
	var old_lambdas := []
	if not entry.is_empty():
		going = _extent(bp, eg, nid)
		going.erase(nid)
		old_lambdas = _lambdas_only(bp, int(eg.id), going, false)
		_take_out(eg, going, rep)
	elif not rep.replaced.has(int(eg.id)):
		rep.replaced[int(eg.id)] = []   # (touched: an event added, nothing taken out)
	var new_lambdas := _lambdas_of(fresh, fnodes)
	# ids: the entry keeps its own, the rest are new to this graph
	var next := int(eg.next_id)
	for n in eg.nodes:
		next = maxi(next, int(n.id) + 1)
	var map := {}
	var at := Vector2.ZERO
	if not entry.is_empty():
		map[int(fentry.id)] = nid
		at = Vector2(float(entry.x), float(entry.y))
		if String(fentry.kind) == "fn_entry":
			entry.p["params"] = feg.inputs.duplicate(true)   # a custom event: its parameters as the file declares them
			for k in COMMENT_FIELDS:   # and its comments (above its func line, at the end of it, an #endregion below it)
				if fentry.p.has(k):
					entry.p[k] = fentry.p[k].duplicate() if fentry.p[k] is Array else fentry.p[k]
				else:
					entry.p.erase(k)
		else:
			entry.p = fentry.p.duplicate(true)
			entry.d = fentry.d.duplicate(true)
	else:
		var bottom := -INF
		var left := INF
		for n in eg.nodes:
			bottom = maxf(bottom, float(n.y) + (float(n.p.get("h", 0)) if String(n.kind) == "comment" else 150.0))
			if String(n.kind) in EVENT_ENTRIES:
				left = minf(left, float(n.x))
		at = Vector2(left if left != INF else 80.0, (bottom + NEW_EVENT_GAP) if bottom != -INF else 80.0)
	var dx := at.x - float(fentry.x)
	var dy := at.y - float(fentry.y)
	var added := []
	for n in fnodes:
		if map.has(int(n.id)):
			continue
		map[int(n.id)] = next
		var c: Dictionary = n.duplicate(true)
		c.id = next
		c.x = float(c.x) + dx
		c.y = float(c.y) + dy
		next += 1
		eg.nodes.append(c)
		added.append(c)
	if entry.is_empty():
		for c in added:
			if int(c.id) == int(map[int(fentry.id)]):
				entry = c
	for w in feg.wires:
		if map.has(int(w[0])) and map.has(int(w[2])):
			eg.wires.append([map[int(w[0])], String(w[1]), map[int(w[2])], String(w[3])])
	_regraph(added, int(feg.id), int(eg.id), map)
	eg.next_id = next
	# locals: those only the old chain used went (in _take_out); the new chain's come in
	var used := _locals_used(added)
	var names := []
	for l in feg.get("locals", []):
		if not used.has(String(l.name)):
			continue
		names.append(String(l.name))
		var have := false
		for k in eg.locals:
			if String(k.name) == String(l.name):
				have = true
				if JSON.stringify(k) != JSON.stringify(l):
					rep.notes.append("the local %s of %s is also another event's, with another type: the other event's is kept" % [l.name, eg.name])
		if not have:
			eg.locals.append(l.duplicate(true))
	_count_kinds(rep, [], added)
	_swap_lambdas(bp, old_lambdas, fresh, new_lambdas, added, rep)
	return names


# ---------------------------------------------------------------- keeping what did not change

## KEEPING WHAT DID NOT CHANGE (opts.gentle, on unless false)
## A function or event that is rebuilt keeps the nodes of the lines that did not change: their ids, places and the
## fields only the editor uses (a comment bubble `c`, anything else that is not id, kind, x, y, p or d), so a graph a
## person arranged stays arranged and breakpoints and watches on those nodes stay. What a node writes still comes
## from the conversion of the file (its p and d are the conversion's, which the checks below show are the same), so
## the result is the conversion's graph with old ids and places put back, and the rule (it compiles to the file)
## decides as always. How:
##   1. Lines. The function's code as the graph compiles to it and as the conversion of the file compiles to it,
##      each line with the node that writes it (the compiler's line_map): blank lines, comment lines, the trace and
##      the prelude set aside, a line's own comment cut off (comments are taken from the conversion either way),
##      indentation kept (a line that moved to another depth is another line). Lines that are the same and in the
##      same order are kept: the longest common subsequence (after the common start and end), and a text that occurs
##      a different number of times on the two sides counts as changed wherever it is.
##   2. Units. The nodes of one line or statement: the node that writes it, an execution node that writes no line
##      of its own (a call written into the next line) with the line it leads to, and the data nodes that feed only
##      those (the rule _extent uses). Wires are read through reroute nodes. Lambda graphs the function uses are
##      matched with the conversion's in order, as _swap_lambdas pairs them, and their lines with them.
##   3. A unit is kept when every line it writes is kept, the lines it is kept as are exactly the lines of one unit
##      of the conversion, the importer's record (`lines` of Importer.convert) puts every node of that unit on one
##      statement, and the two units have the same shape: the same kinds, the same p (comments and the place notes
##      of name nodes aside) and d, wired the same way, read from the same kinds of nodes outside. A unit of the
##      function's own graph whose lines are kept but whose nodes are shaped otherwise (a hand-made graph; one node
##      that writes several lines, such as a macro, when all its lines are kept and in a row) keeps its old nodes as
##      they are, wires among them included, when its edge can be told (see _hand_units); report.gentle[name]
##      .hand_kept counts those nodes. If that result does not compile to the file, the re-import is done again
##      keeping only the nodes shaped like the conversion's (a note says so). Otherwise its lines count as changed.
##      An execution node that writes no line and leads into several (a Sequence) is kept when the conversion has
##      the same one in the same place (_same_place).
##   4. Ids. A kept unit's nodes take the old ids and places; every other node takes an id above every id the
##      graph had. The entry node keeps its id and place. Wires are the conversion's, with those ids.
##   5. Places. A new node goes where the conversion put it relative to the kept execution node before it (walking
##      back the execution wires; a data node goes with the node it feeds), so it keeps the converter's spacing;
##      a group of new nodes that would sit on a node that stays is moved down a row at a time until it does not.
##      Kept nodes never move.
##   6. Reroute nodes. A wire between two kept nodes that went through reroute nodes keeps them (ids and places);
##      every other wire is laid out as Importer._route_wires lays out a new one (a reroute where an execution wire
##      drops a long way to the right), with the final places.
##   7. Locals: the graph's are the conversion's (a function), or as for any rebuilt event.
## The function is rebuilt whole instead (as it always was; report.gentle says why) when more than half of its lines
## changed; when a line that holds others (an if, elif, else, for, while, match or a case, a lambda's first line)
## changed while lines inside it did not (they would be put under another block); when an execution node that
## writes no line leads into several lines and the conversion has nothing in its place (which of them writes a
## line can't be told: a hand-made Sequence); when the function has no lines on either side. A macro node is kept
## (as it is) only when every line it writes is kept and they are in a row; otherwise it goes and its lines get
## new nodes (macros_expanded counts it). When the result with kept nodes does not compile to the file and the
## whole rebuild does, the whole rebuild is used and a note says so.
## report.gentle: {name: {path: "gentle" | "full", why, kept_nodes, new_nodes, hand_kept}} for each function or event rebuilt
## (also on its row in report.functions); kept_nodes and new_nodes count nodes other than the entry and reroutes.

const GENTLE_SHARE := 0.5
const NODE_W := 250.0   # how far apart two nodes must be, across and down, not to sit on each other
const NODE_H := 110.0
const ENTRY_KINDS := ["fn_entry", "event", "custom_event", "signal_event", "input_action", "key_event", "macro_in"]


## What can be kept of function or event `name` (graph `og`, nodes `oset`, entry `oe`) given the conversion's
## (graph `fg`, nodes `fset`, entry `fe`) and the lambda graphs each uses (in order): {ok, maps: {old graph id:
## {fresh: its graph id in the conversion, map: {conversion's node id: old node id}}}, report}.
func _plan(name: String, ctx: Dictionary, bp: Dictionary, og: Dictionary, oset: Dictionary, oe: int, fg: Dictionary, fset: Dictionary, fe: int,
		old_lams: Array, new_lams: Array) -> Dictionary:
	var rep := {"path": "full", "why": "", "kept_nodes": 0, "new_nodes": 0}
	var out := {"ok": false, "maps": {}, "report": rep}
	var a := _code_rows(ctx.ob, ctx.oc, name)
	var b := _code_rows(ctx.nb, ctx.nc, name)
	if a.is_empty() or b.is_empty() or oe == -1 or fe == -1:
		rep.why = "no lines of code to match"
		return out
	var pairs := _match_rows(a, b)
	var ca := {}
	var cb := {}
	for r in a:
		ca[r.t] = int(ca.get(r.t, 0)) + 1
	for r in b:
		cb[r.t] = int(cb.get(r.t, 0)) + 1
	for i in pairs.keys():
		if int(ca[a[i].t]) != int(cb.get(a[i].t, 0)):
			pairs.erase(i)   # the same text a different number of times: which is which can't be told
	var kept_a := {}
	var kept_b := {}
	for i in pairs:
		kept_a[int(i)] = true
		kept_b[int(pairs[i])] = true
	var most := maxi(a.size(), b.size())
	if pairs.size() < GENTLE_SHARE * most:
		rep.why = "more than half of its lines changed (%d of %d kept)" % [pairs.size(), most]
		return out
	for side in [[a, kept_a], [b, kept_b]]:
		var at := _renested(side[0], side[1])
		if at != -1:
			rep.why = "the line `%s` changed but lines inside it did not" % String(side[0][at].t).strip_edges()
			return out
	var gpair := {int(og.id): int(fg.id)}
	var ows := {int(og.id): _wiring(bp, og, oset, oe)}
	var nws := {int(fg.id): _wiring(ctx.fresh, fg, fset, fe)}
	var maps := {int(og.id): {"fresh": int(fg.id), "map": {fe: oe}}}
	for k in mini(old_lams.size(), new_lams.size()):
		var lo: Dictionary = old_lams[k]
		var ln: Dictionary = new_lams[k]
		var le := int(_fn_entry(lo).get("id", -1))
		var lf := int(_fn_entry(ln).get("id", -1))
		if le == -1 or lf == -1:
			continue
		gpair[int(lo.id)] = int(ln.id)
		ows[int(lo.id)] = _wiring(bp, lo, _ids(lo.nodes), le)
		nws[int(ln.id)] = _wiring(ctx.fresh, ln, _ids(ln.nodes), lf)
		maps[int(lo.id)] = {"fresh": int(ln.id), "map": {lf: le}}
	var ou := _units(a, ows)
	var nu := _units(b, nws)
	var lam_old := {}
	var lam_new := {}
	for g in bp.graphs:
		if g.has("lambda"):
			lam_old[String(g.name)] = true
	for g in ctx.fresh.graphs:
		if g.has("lambda"):
			lam_new[String(g.name)] = true
	var side_lines: Dictionary = ctx.lines
	var hand := []   # [old unit, new unit] of the main graph: the same lines, nodes of another shape
	for key in ou.units:
		var u: Dictionary = ou.units[key]
		if not gpair.has(int(u.gid)):
			continue
		var part := []
		for r in u.rows:
			if not pairs.has(r):
				part = []
				break
			part.append(int(pairs[r]))
		if part.is_empty():
			continue
		part.sort()
		var nkeys := []
		for r in part:
			var nk := "%d:%d" % [int(b[int(r)].gid), int(b[int(r)].nid)]
			if not nkeys.has(nk):
				nkeys.append(nk)
		if nkeys.any(func(nk): return not nu.units.has(nk) or int(nu.units[nk].gid) != int(gpair[int(u.gid)])):
			continue
		if nkeys.size() > 1:
			# one old node for several of the conversion's statements (a macro, a hand-made node that writes several
			# lines): kept as it is when all its lines are kept, in a row, and are exactly those statements' lines
			var whole := {"gid": int(gpair[int(u.gid)]), "writer": int(nu.units[nkeys[0]].writer), "nodes": {}, "rows": []}
			for nk in nkeys:
				whole.nodes.merge(nu.units[nk].nodes)
				whole.rows.append_array(nu.units[nk].rows)
			whole.rows.sort()
			# with the nodes that write no line and lead only into those statements (a Sequence running them in turn)
			var wn: Dictionary = nws[int(whole.gid)]
			var grew := true
			while grew:
				grew = false
				for x in nu.multi:
					var xid := int(x[1])
					if int(x[0]) != int(whole.gid) or whole.nodes.has(xid):
						continue
					var outs: Array = wn.louts.get(xid, []).filter(func(lo): return bool(lo[3]))
					if not outs.is_empty() and outs.all(func(lo): return whole.nodes.has(int(lo[0]))):
						whole.nodes[xid] = true
						grew = true
			if whole.rows == part and int(part[-1]) - int(part[0]) == part.size() - 1 and int(u.gid) == int(og.id):
				hand.append([u, whole])
			continue
		var v: Dictionary = nu.units[nkeys[0]]
		var vr: Array = v.rows.duplicate()
		vr.sort()
		if vr != part or not _one_statement(v, side_lines.get(int(v.gid), {})):
			continue
		var so := _shape(ows[int(u.gid)], u, lam_old)
		var sn := _shape(nws[int(v.gid)], v, lam_new)
		if String(so[0]) == "" or so[0] != sn[0] or so[1].size() != u.nodes.size() or sn[1].size() != v.nodes.size():
			if int(u.gid) == int(og.id):
				hand.append([u, v])
			continue
		for i in so[1].size():
			maps[int(u.gid)].map[int(sn[1][i])] = int(so[1][i])
	# lines whose old nodes have another shape (a hand-made graph): their old nodes are kept as they are, in the
	# conversion's graph in place of its own (see _hand_units)
	if not hand.is_empty() and not bool(ctx.get("no_hand", false)):
		var hu := _hand_units(hand, ows[int(og.id)], nws[int(fg.id)], fg, fset, fe, oe, maps[int(og.id)].map)
		if int(hu.kept) > 0:
			out["graph"] = hu.graph
			out["fset"] = hu.fset
			rep["hand_kept"] = int(hu.kept)
			nws[int(fg.id)] = _wiring(ctx.fresh, hu.graph, hu.fset, fe)
			nu.multi = nu.multi.filter(func(x): return int(x[0]) != int(fg.id) or hu.fset.has(int(x[1])))
	# an execution node that writes no line and leads into several (a Sequence) is kept when the conversion has the
	# same node in the same place: entered from the node kept for the one before it, leading to the nodes kept for
	# the ones it leads to. One the conversion has nothing in place of leaves its lines' writers in doubt.
	var pending: Array = ou.multi.duplicate()
	var progress := true
	while progress and not pending.is_empty():
		progress = false
		for item in pending.duplicate():
			var gn := int(gpair.get(int(item[0]), -1))
			if gn == -1:
				continue
			var mp: Dictionary = maps[int(item[0])].map
			var hit := _same_place(ows[int(item[0])], int(item[1]), nws[gn], nu.multi.filter(func(x): return int(x[0]) == gn).map(func(x): return int(x[1])), mp, lam_old, lam_new)
			if hit != -1:
				mp[hit] = int(item[1])
				pending.erase(item)
				progress = true
	if not pending.is_empty():
		var x: Dictionary = ows[int(pending[0][0])].by[int(pending[0][1])]
		rep.why = "node %d (%s) writes no line of its own, leads into several lines and the conversion has nothing in its place (a line with several candidate writers)" % [int(x.id), String(x.kind)]
		return out
	out.ok = true
	out.maps = maps
	rep.path = "gentle"
	return out


## The lines of code of function `name` in compiled code (blocks split and classified, `comp` the compiler that wrote
## them): [{t, ln, gid, nid}], t the line without its comment and trailing spaces (indentation kept), gid / nid the
## node that writes it (0 when none). Blank and comment lines, compiler lines (the prelude) and trace lines are left out.
func _code_rows(blocks: Array, comp: Object, name: String) -> Array:
	var out := []
	var tl: PackedInt32Array = comp.text_lines
	for b in blocks:
		if String(b.kind) != "func" or String(b.name) != name or String(b.owner) != "user":
			continue
		var own := {}
		for ln in b.compiler_lines:
			own[int(ln)] = true
		var strs := {}
		for ln in b.get("strs", []):
			strs[int(ln)] = true
		for ln in range(int(b.head_to) + 1, int(b.to) + 1):
			if own.has(ln):
				continue
			var raw := _line(b, ln)
			var t := raw if strs.has(ln) else (_strip_comment(raw) if raw.contains("#") else raw).strip_edges(false, true)
			if t.strip_edges() == "" or t.strip_edges().begins_with("__sc_trace("):
				continue
			var rec := tl[ln - 1] if ln >= 1 and ln <= tl.size() else 0
			if rec < 0:
				continue
			var at: Array = comp.line_map.get(rec, [])
			out.append({"t": t, "ln": ln, "gid": int(at[0]) if not at.is_empty() else 0, "nid": int(at[1]) if not at.is_empty() else 0})
		break
	return out


## {index in a: index in b} for lines of `a` and `b` (rows) that are the same and in the same order: the common start
## and end, and a longest common subsequence of what is between (when that is not too large to compare).
func _match_rows(a: Array, b: Array) -> Dictionary:
	var pairs := {}
	var n := a.size()
	var m := b.size()
	var lo := 0
	while lo < n and lo < m and a[lo].t == b[lo].t:
		pairs[lo] = lo
		lo += 1
	var hi := 0
	while hi < n - lo and hi < m - lo and a[n - 1 - hi].t == b[m - 1 - hi].t:
		pairs[n - 1 - hi] = m - 1 - hi
		hi += 1
	var at := PackedStringArray()
	var bt := PackedStringArray()
	for i in range(lo, n - hi):
		at.append(String(a[i].t))
	for j in range(lo, m - hi):
		bt.append(String(b[j].t))
	if at.is_empty() or bt.is_empty() or at.size() * bt.size() > 4000000:
		return pairs
	var t := _lcs_table(at, bt)
	var w := bt.size() + 1
	var i := at.size()
	var j := bt.size()
	while i > 0 and j > 0:
		if at[i - 1] == bt[j - 1]:
			pairs[lo + i - 1] = lo + j - 1
			i -= 1
			j -= 1
		elif t[(i - 1) * w + j] >= t[i * w + j - 1]:
			i -= 1
		else:
			j -= 1
	return pairs


## The first row that changed while a row indented deeper right below it (inside it) did not, or -1.
func _renested(rows: Array, kept: Dictionary) -> int:
	for i in rows.size():
		if kept.has(i):
			continue
		var ind := _indent(String(rows[i].t))
		var j := i + 1
		while j < rows.size() and _indent(String(rows[j].t)) > ind:
			if kept.has(j):
				return i
			j += 1
	return -1


## How the nodes `ids` of graph `g` are wired, read through reroute nodes: {by: {id: node}, xin / xout: {id: {pin:
## true}} (execution pins), pure: {id: true} (no execution pin), lins: {id: [[source, its pin, pin, exec]]}, louts:
## {id: [[target, its pin, pin, exec]]}, chains: {"s:pin>t:pin": [[wires], [reroute ids]]} (a wire that went through
## reroute nodes), entry}.
func _wiring(bp: Dictionary, g: Dictionary, ids: Dictionary, entry: int) -> Dictionary:
	var by := {}
	for n in g.nodes:
		if ids.has(int(n.id)) and String(n.kind) != "comment":
			by[int(n.id)] = n
	var xin := {}
	var xout := {}
	var pure := {}
	for id in by:
		var n: Dictionary = by[id]
		var ins := {}
		var outs := {}
		if String(n.kind) == "reroute":
			if String(n.p.get("t", "")) == "exec":
				ins["i"] = true
				outs["o"] = true
		else:
			var d := R.describe(n, bp, g)
			for pi in d.get("ins", []):
				if String(pi.type) == "exec":
					ins[String(pi.id)] = true
			for po in d.get("outs", []):
				if String(po.type) == "exec":
					outs[String(po.id)] = true
			if ins.is_empty() and outs.is_empty():
				pure[id] = true
		if not ins.is_empty():
			xin[id] = ins
		if not outs.is_empty():
			xout[id] = outs
	var phys := {}
	for w in g.wires:
		if by.has(int(w[0])) and by.has(int(w[2])):
			if not phys.has(int(w[0])):
				phys[int(w[0])] = []
			phys[int(w[0])].append(w)
	var lins := {}
	var louts := {}
	var chains := {}
	for s in by:
		if String(by[s].kind) == "reroute":
			continue
		for w in phys.get(s, []):
			var stack := [[w, [w], []]]
			while not stack.is_empty():
				var item: Array = stack.pop_back()
				var t := int(item[0][2])
				if String(by[t].kind) == "reroute":
					if item[2].size() > 64 or item[2].has(t):
						continue
					for w2 in phys.get(t, []):
						stack.append([w2, item[1] + [w2], item[2] + [t]])
					continue
				var sp := String(w[1])
				var tp := String(item[0][3])
				var ex: bool = xin.has(t) and xin[t].has(tp)
				if not lins.has(t):
					lins[t] = []
				lins[t].append([int(s), sp, tp, ex])
				if not louts.has(s):
					louts[s] = []
				louts[s].append([t, tp, sp, ex])
				if not item[2].is_empty():
					chains["%d:%s>%d:%s" % [int(s), sp, t, tp]] = [item[1], item[2]]
	return {"by": by, "xin": xin, "xout": xout, "pure": pure, "lins": lins, "louts": louts, "chains": chains, "entry": entry}


## The units of rows (see KEEPING WHAT DID NOT CHANGE, 2), in the graphs `ws` ({graph id: _wiring}): {units: {"gid:
## writer": {gid, writer, nodes: {id: true}, rows: [row index]}}, multi: [[gid, id]] of the execution nodes that
## write no line and lead into several units (a Sequence)}.
func _units(rows: Array, ws: Dictionary) -> Dictionary:
	var units := {}
	var of := {}   # "gid:id" -> its unit's key
	var multi := []
	for r in rows.size():
		var row: Dictionary = rows[r]
		var gid := int(row.gid)
		if int(row.nid) == 0 or not ws.has(gid) or not ws[gid].by.has(int(row.nid)) or int(row.nid) == int(ws[gid].entry) \
				or String(ws[gid].by[int(row.nid)].kind) in ENTRY_KINDS:
			continue   # (a line the entry node writes, the default `return` at the end, is the entry's: kept with it)
		var key := "%d:%d" % [gid, int(row.nid)]
		if not units.has(key):
			units[key] = {"gid": gid, "writer": int(row.nid), "nodes": {int(row.nid): true}, "rows": []}
			of[key] = key
		units[key].rows.append(r)
	for gid in ws:
		var w: Dictionary = ws[gid]
		for id in w.by:
			var k := "%d:%d" % [int(gid), int(id)]
			if of.has(k) or not w.xin.has(id) or int(id) == int(w.entry) or String(w.by[id].kind) == "reroute" or String(w.by[id].kind) in ENTRY_KINDS:
				continue
			var reached := {}
			var seen := {id: true}
			var todo := [id]
			while not todo.is_empty():
				var c: int = todo.pop_back()
				for lo in w.louts.get(c, []):
					if not bool(lo[3]):
						continue
					var tk := "%d:%d" % [int(gid), int(lo[0])]
					if units.has(tk):
						reached[tk] = true
					elif not seen.has(int(lo[0])) and int(lo[0]) != int(w.entry):
						seen[int(lo[0])] = true
						todo.append(int(lo[0]))
			if reached.size() > 1:
				multi.append([int(gid), int(id)])
				continue
			if reached.size() == 1:
				var uk: String = reached.keys()[0]
				of[k] = uk
				units[uk].nodes[int(id)] = true
	var more := true
	while more:
		more = false
		for gid in ws:
			var w: Dictionary = ws[gid]
			for id in w.pure:
				var k := "%d:%d" % [int(gid), int(id)]
				if of.has(k):
					continue
				var outs: Array = w.louts.get(id, [])
				if outs.is_empty():
					continue
				var to := ""
				for lo in outs:
					var tk := "%d:%d" % [int(gid), int(lo[0])]
					if not of.has(tk) or (to != "" and String(of[tk]) != to):
						to = "-"
						break
					to = String(of[tk])
				if to != "" and to != "-":
					of[k] = to
					units[to].nodes[int(id)] = true
					more = true
	return {"units": units, "multi": multi}


## Units whose lines did not change but whose old nodes are not shaped like the conversion's (`hand`: [[old unit,
## new unit]], a hand-made graph): the old nodes are kept as they are (content, wires among them, the data wires that
## reach them from nodes that are kept or the entry). In a copy of the conversion's graph `fg` the new unit's nodes
## are replaced by copies of the old ones under ids of their own (put in `map`, so they keep the old ids), and the
## conversion's wires at the unit's edge are moved onto them: the execution wire in onto the old node it is entered
## by; each execution output leaving it onto the old one with the same pin (or the only one each side has); a data
## wire out onto the old node of the same kind (the only one in the unit). A unit where any of that can't be told,
## or that reads a value from a node that is not kept, keeps none of its nodes. Returns {kept (old nodes kept so),
## graph (the copy), fset (its node ids)}.
func _hand_units(hand: Array, ow: Dictionary, nw: Dictionary, fg: Dictionary, fset: Dictionary, fe: int, oe: int, map: Dictionary) -> Dictionary:
	var live := hand.duplicate()
	var inv := {}
	for k in map:
		inv[int(map[k])] = int(k)
	while not live.is_empty():
		var top := 1
		for n in fg.nodes:
			top = maxi(top, int(n.id) + 1)
		var removed := {}   # new id -> index in live
		var temp := {}   # old id -> the id of its copy
		for i in live.size():
			for id in live[i][1].nodes:
				removed[int(id)] = i
			var ids: Array = live[i][0].nodes.keys()
			ids.sort()
			for id in ids:
				temp[int(id)] = top
				top += 1
		var tabs := []
		var bad := -1
		for i in live.size():
			var tab := _edge_tables(live[i][0], live[i][1], ow, nw, temp)
			if tab.is_empty():
				bad = i
				break
			tabs.append(tab)
		if bad != -1:
			live.remove_at(bad)
			continue
		# reroute nodes on a wire from a unit back into it go with it
		var inner := {}   # physical wires to drop
		for key in nw.chains:
			var ch: Array = nw.chains[key]
			var cs := int(String(key).get_slice(":", 0))
			var ct := int(String(key).get_slice(">", 1).get_slice(":", 0))
			if removed.has(cs) and removed.has(ct) and int(removed[cs]) == int(removed[ct]):
				for pw in ch[0]:
					inner[str(pw)] = true
				for rid in ch[1]:
					removed[int(rid)] = int(removed[cs])
		var wires := []
		for w in fg.wires:
			var s := int(w[0])
			var t := int(w[2])
			var ns := s
			var nsp := String(w[1])
			var nt := t
			var ntp := String(w[3])
			if inner.has(str(w)) or (removed.has(s) and removed.has(t) and int(removed[s]) == int(removed[t])):
				continue
			if removed.has(t):
				var tab: Dictionary = tabs[int(removed[t])]
				if not nw.xin.get(t, {}).has(ntp):
					continue   # a data wire into the unit: the old nodes keep their own
				if t != int(tab.head_n):
					bad = int(removed[t])
					break
				nt = int(tab.head)
				ntp = String(tab.ip)
			if removed.has(s):
				var tab: Dictionary = tabs[int(removed[s])]
				if nw.xout.get(s, {}).has(nsp):
					var key := "%d:%s" % [s, nsp]
					if not tab.outs.has(key):
						bad = int(removed[s])
						break
					ns = int(tab.outs[key][0])
					nsp = String(tab.outs[key][1])
				else:
					if not tab.data.has(s):
						bad = int(removed[s])
						break
					ns = int(tab.data[s])
			wires.append([ns, nsp, nt, ntp])
		if bad == -1:
			for i in live.size():
				var u: Dictionary = live[i][0]
				for id in u.nodes:
					for li in ow.lins.get(id, []):
						var src := int(li[0])
						if u.nodes.has(src):
							wires.append([int(temp[src]), String(li[1]), int(temp[int(id)]), String(li[2])])
						elif not bool(li[3]):
							var from := fe if src == oe else (int(inv[src]) if inv.has(src) else (int(temp[src]) if temp.has(src) else -1))
							if from == -1:
								bad = i
								break
							wires.append([from, String(li[1]), int(temp[int(id)]), String(li[2])])
					if bad != -1:
						break
				if bad != -1:
					break
		if bad != -1:
			live.remove_at(bad)
			continue
		var g := fg.duplicate(true)
		g.nodes = g.nodes.filter(func(n): return not removed.has(int(n.id)))
		var fs := {}
		for id in fset:
			if not removed.has(int(id)):
				fs[int(id)] = true
		for old_id in temp:
			var c: Dictionary = ow.by[int(old_id)].duplicate(true)
			c.id = int(temp[old_id])
			c["_old"] = true   # (its p is the old graph's: its place notes name old ids already)
			g.nodes.append(c)
			fs[int(c.id)] = true
			map[int(c.id)] = int(old_id)
		g.wires = wires
		g.next_id = top
		return {"kept": temp.size(), "graph": g, "fset": fs}
	return {"kept": 0, "graph": fg, "fset": fset}


## How the edge of new unit `v` maps onto old unit `u` (their nodes' copies named in `temp`), or {} when it can't
## be told: {head_n, head, ip (the old head's execution input), outs: {"new id:pin": [copy id, pin]}, data: {new id:
## copy id}}.
func _edge_tables(u: Dictionary, v: Dictionary, ow: Dictionary, nw: Dictionary, temp: Dictionary) -> Dictionary:
	var heads := []
	for side in [[u, ow], [v, nw]]:
		var hs := []
		for id in side[0].nodes:
			if not side[1].xin.has(id):
				continue
			if not side[1].lins.get(id, []).any(func(li): return bool(li[3]) and side[0].nodes.has(int(li[0]))):
				hs.append(int(id))
		heads.append(hs)
	if heads[0].size() != heads[1].size() or heads[0].size() > 1:
		return {}
	var out := {"head_n": -1, "head": -1, "ip": "", "outs": {}, "data": {}}
	if heads[0].size() == 1:
		# the execution input it is entered by now, else its only one
		var pins := []
		for li in ow.lins.get(int(heads[0][0]), []):
			if bool(li[3]) and not u.nodes.has(int(li[0])) and not pins.has(String(li[2])):
				pins.append(String(li[2]))
		if pins.is_empty():
			pins = ow.xin[int(heads[0][0])].keys()
		if pins.size() != 1:
			return {}
		out.head_n = int(heads[1][0])
		out.head = int(temp[int(heads[0][0])])
		out.ip = String(pins[0])
	# execution outputs that leave the unit: the ones wired out of it, else (a unit at the end) the unwired ones
	var leaving := []
	for side in [[u, ow], [v, nw]]:
		var wired := []
		var loose := []
		for id in side[0].nodes:
			for pin in side[1].xout.get(id, {}):
				var inside := false
				var any := false
				for lo in side[1].louts.get(id, []):
					if bool(lo[3]) and String(lo[2]) == String(pin):
						any = true
						if side[0].nodes.has(int(lo[0])):
							inside = true
				if not any:
					loose.append([int(id), String(pin)])
				elif not inside:
					wired.append([int(id), String(pin)])
		leaving.append(wired if not wired.is_empty() else loose)
	if leaving[0].size() != leaving[1].size():
		return {}
	for nl in leaving[1]:
		var match_ := []
		if leaving[0].size() == 1:
			match_ = leaving[0][0]
		else:
			for ol in leaving[0]:
				if String(ol[1]) == String(nl[1]) and String(ow.by[int(ol[0])].kind) == String(nw.by[int(nl[0])].kind):
					if not match_.is_empty():
						return {}
					match_ = ol
		if match_.is_empty():
			return {}
		out.outs["%d:%s" % [int(nl[0]), String(nl[1])]] = [int(temp[int(match_[0])]), String(match_[1])]
	# data read outside the unit: from the old node of the same kind
	for id in v.nodes:
		if not nw.louts.get(id, []).any(func(lo): return not bool(lo[3]) and not v.nodes.has(int(lo[0]))):
			continue
		var same: Array = u.nodes.keys().filter(func(o): return String(ow.by[int(o)].kind) == String(nw.by[int(id)].kind))
		if same.size() != 1:
			return {}
		out.data[int(id)] = int(temp[int(same[0])])
	return out


## The conversion's node among `cands` (ids in `nw`) in the same place as old node `id` (in `ow`): the same kind and
## p, entered the same way from the node `map` keeps for the one the old node is entered from, its execution outputs
## leading to the nodes kept for the old one's. -1 when there is none (or more than one).
func _same_place(ow: Dictionary, id: int, nw: Dictionary, cands: Array, map: Dictionary, lam_old: Dictionary, lam_new: Dictionary) -> int:
	var inv := {}
	for k in map:
		inv[int(map[k])] = int(k)
	var ins_o: Array = ow.lins.get(id, []).filter(func(li): return bool(li[3]))
	if ins_o.size() != 1 or not inv.has(int(ins_o[0][0])):
		return -1
	var me := _shape_of(ow, {"nodes": {}}, id, {}, [], lam_old).get_slice(" <", 0).get_slice(" [", 0)
	var outs_o := {}
	for lo in ow.louts.get(id, []):
		if bool(lo[3]):
			outs_o[String(lo[2])] = int(lo[0])
	var found := -1
	for c in cands:
		if map.has(int(c)):
			continue
		var ins_n: Array = nw.lins.get(int(c), []).filter(func(li): return bool(li[3]))
		if ins_n.size() != 1 or int(ins_n[0][0]) != int(inv[int(ins_o[0][0])]) or String(ins_n[0][1]) != String(ins_o[0][1]) or String(ins_n[0][2]) != String(ins_o[0][2]):
			continue
		if _shape_of(nw, {"nodes": {}}, int(c), {}, [], lam_new).get_slice(" <", 0).get_slice(" [", 0) != me:
			continue
		var outs_n := {}
		for lo in nw.louts.get(int(c), []):
			if bool(lo[3]):
				outs_n[String(lo[2])] = int(lo[0])
		if outs_n.keys().size() != outs_o.size():
			continue
		var same := true
		for pin in outs_o:
			# (a target kept on one side must be the other's; one that changed has none to be)
			if not outs_n.has(pin) or int(map.get(int(outs_n[pin]), -1)) != (int(outs_o[pin]) if inv.has(int(outs_o[pin])) else -1):
				same = false
		if same:
			if found != -1:
				return -1
			found = int(c)
	return found


## True when the importer's record puts every node of unit `u` on one statement (`side`: {node id: line}).
static func _one_statement(u: Dictionary, side: Dictionary) -> bool:
	var line := -2
	for id in u.nodes:
		if not side.has(int(id)):
			return false
		if line != -2 and int(side[int(id)]) != line:
			return false
		line = int(side[int(id)])
	return true


## A unit's shape as text, and its nodes in the order the text names them (two units with the same text are the
## same nodes in that order): ["", []] when it has no one node execution enters it by.
func _shape(w: Dictionary, u: Dictionary, lams: Dictionary) -> Array:
	var heads := []
	for id in u.nodes:
		if not w.xin.has(id):
			continue
		var inside := false
		for li in w.lins.get(id, []):
			if bool(li[3]) and u.nodes.has(int(li[0])):
				inside = true
		if not inside:
			heads.append(int(id))
	if heads.size() > 1:
		return ["", []]
	var head: int = int(heads[0]) if heads.size() == 1 else int(u.writer)
	var order := []
	var text := _shape_of(w, u, head, {}, order, lams)
	return [text, order]


func _shape_of(w: Dictionary, u: Dictionary, id: int, idx: Dictionary, order: Array, lams: Dictionary) -> String:
	if idx.has(id):
		return "#%d" % int(idx[id])
	idx[id] = order.size()
	order.append(id)
	var n: Dictionary = w.by[id]
	var p: Dictionary = n.get("p", {}).duplicate(true)
	for k in ["note", "tail", "after", "empty", "else_tail", "of", "in"]:
		p.erase(k)
	if String(n.kind) in REF_KINDS and lams.has(String(p.get("fn", ""))):
		p.fn = "(lambda)"
	var s := "%s %s %s" % [String(n.kind), JSON.stringify(p, "", true), JSON.stringify(n.get("d", {}), "", true)]
	var ins: Array = w.lins.get(id, []).filter(func(li): return not bool(li[3]))
	ins.sort_custom(func(x, y): return String(x[2]) + "|" + String(x[1]) < String(y[2]) + "|" + String(y[1]))
	for li in ins:
		if u.nodes.has(int(li[0])):
			s += " <%s=%s>" % [li[2], _shape_of(w, u, int(li[0]), idx, order, lams)]
		else:
			var src: Dictionary = w.by.get(int(li[0]), {})
			var sk := String(src.get("kind", "?"))
			s += " <%s=from %s.%s>" % [li[2], "entry" if sk in ENTRY_KINDS else sk, li[1]]
	var outs: Array = w.louts.get(id, []).filter(func(lo): return bool(lo[3]))
	outs.sort_custom(func(x, y): return String(x[2]) + "|" + str(x[0]) < String(y[2]) + "|" + str(y[0]))
	for lo in outs:
		if u.nodes.has(int(lo[0])):
			s += " [%s>%s:%s]" % [lo[2], lo[1], _shape_of(w, u, int(lo[0]), idx, order, lams)]
		else:
			s += " [%s>]" % lo[2]
	return s


## The conversion's nodes `fset` of graph `fg` (in `fresh`) made into nodes of old graph `og` (nodes `oset`), the ids
## in `map` ({conversion's id: old id}) kept with their places (see KEEPING WHAT DID NOT CHANGE, 4 to 6). The entry
## (`fe`) is among the nodes only `with_entry`. Returns {nodes (in fg's order, then reroutes), wires, kept: {old id:
## true}, made: [new nodes], top (an id above all)}.
func _merge(bp: Dictionary, og: Dictionary, oset: Dictionary, fresh: Dictionary, fg: Dictionary, fset: Dictionary, map: Dictionary, fe: int, with_entry: bool) -> Dictionary:
	var old_by := {}
	var top := int(og.get("next_id", 1))
	for n in og.nodes:
		old_by[int(n.id)] = n
		top = maxi(top, int(n.id) + 1)
	var fw := _wiring(fresh, fg, fset, fe)
	var ow := _wiring(bp, og, oset, int(map.get(fe, -1)))
	var ids := {}   # conversion's id -> the result's
	var out := []
	var made := []
	var kept := {}
	var fpos := {}
	var at := {}   # result id -> the result's node
	for n in fg.nodes:
		var fid := int(n.id)
		if not fset.has(fid) or String(n.kind) in ["reroute", "comment"]:
			continue
		fpos[fid] = Vector2(float(n.x), float(n.y))
		if fid == fe and not with_entry:
			ids[fid] = int(map[fid])
			continue
		var c: Dictionary = n.duplicate(true)
		if map.has(fid) and old_by.has(int(map[fid])):
			var o: Dictionary = old_by[int(map[fid])]
			c.id = int(o.id)
			c.x = float(o.x)
			c.y = float(o.y)
			for k in o:
				if not k in ["id", "kind", "x", "y", "p", "d"]:
					c[k] = o[k].duplicate(true) if (o[k] is Dictionary or o[k] is Array) else o[k]
			kept[int(o.id)] = true
		else:
			c.id = top
			top += 1
			made.append(c)
		ids[fid] = int(c.id)
		out.append(c)
		at[int(c.id)] = c
	var pos_of := func(rid: int) -> Vector2:
		var nd: Dictionary = at.get(rid, old_by.get(rid, {}))
		return Vector2(float(nd.get("x", 0.0)), float(nd.get("y", 0.0)))
	# places: each new node beside the kept node it follows (see 5)
	var anchor := {}
	var groups := {}   # anchor (conversion's id) -> [new nodes]
	var group_order := []
	var rev := {}
	for fid in ids:
		rev[int(ids[fid])] = int(fid)
	for c in made:
		var a := _anchor(fw, int(rev[int(c.id)]), map, fe, anchor)
		if not groups.has(a):
			groups[a] = []
			group_order.append(a)
		groups[a].append(c)
	var fixed := []   # places of nodes that stay
	for n in og.nodes:
		if String(n.kind) == "comment" or (oset.has(int(n.id)) and not kept.has(int(n.id)) and int(n.id) != int(map.get(fe, -1))):
			continue
		fixed.append(Vector2(float(n.x), float(n.y)))
	for a in group_order:
		var ap: Vector2 = pos_of.call(int(ids[a])) if ids.has(a) else Vector2.ZERO
		var fp: Vector2 = fpos.get(a, ap)
		var delta: Vector2 = ap - fp
		var shift := 0.0
		for tries in 400:
			var clear := true
			for c in groups[a]:
				var p: Vector2 = fpos[int(rev[int(c.id)])] + delta + Vector2(0, shift)
				for q in fixed:
					if absf(p.x - q.x) < NODE_W and absf(p.y - q.y) < NODE_H:
						clear = false
						break
				if not clear:
					break
			if clear:
				break
			shift += Importer.ROW + 15.0
		for c in groups[a]:
			var p: Vector2 = fpos[int(rev[int(c.id)])] + delta + Vector2(0, shift)
			c.x = p.x
			c.y = p.y
			fixed.append(p)
	# wires: the conversion's with the result's ids; through the old reroutes between two kept nodes, else laid
	# out as a new wire is (see 6)
	var wires := []
	var have := {}
	var add := func(w: Array) -> void:
		var key := "%d:%s>%d:%s" % [int(w[0]), String(w[1]), int(w[2]), String(w[3])]
		if not have.has(key):
			have[key] = true
			wires.append(w)
	for s in fw.louts:
		if not ids.has(int(s)):
			continue
		for lo in fw.louts[s]:
			if not ids.has(int(lo[0])):
				continue
			var rs := int(ids[int(s)])
			var rt := int(ids[int(lo[0])])
			var sp := String(lo[2])
			var tp := String(lo[1])
			if map.has(int(s)) and map.has(int(lo[0])):
				var chain: Array = ow.chains.get("%d:%s>%d:%s" % [rs, sp, rt, tp], [])
				if not chain.is_empty():
					for rid in chain[1]:
						if not kept.has(int(rid)):
							kept[int(rid)] = true
							var r: Dictionary = old_by[int(rid)].duplicate(true)
							out.append(r)
							at[int(rid)] = r
					for pw in chain[0]:
						add.call([int(pw[0]), String(pw[1]), int(pw[2]), String(pw[3])])
					continue
			var a: Vector2 = pos_of.call(rs)
			var b: Vector2 = pos_of.call(rt)
			if bool(lo[3]) and not (map.has(int(s)) and map.has(int(lo[0]))) and b.y - a.y >= Importer.ROUTE_DROP and b.x - a.x >= Importer.ROUTE_REACH:
				var d := R.describe(fw.by[int(lo[0])], fresh, fg)
				var pin_y := 84.0 if String(d.get("sub", "")) != "" else 54.0
				var knot := {"id": top, "kind": "reroute", "x": a.x + Importer.ROUTE_STEP, "y": b.y + pin_y - 13.0, "p": {"t": "exec"}, "d": {}}
				top += 1
				out.append(knot)
				add.call([rs, sp, int(knot.id), "i"])
				add.call([int(knot.id), "o", rt, tp])
				continue
			add.call([rs, sp, rt, tp])
	# name nodes say which node of which graph their name belongs to (see _regraph); a number keeps the type it was
	# read with, so that a kept node is equal to what it was
	for c in out:
		var p: Dictionary = c.get("p", {})
		if c.has("_old"):
			c.erase("_old")   # (a hand-made node kept as it was: _hand_units)
			continue
		if p.has("of") and ids.has(int(p.of)) and int(ids[int(p.of)]) != int(p.of):
			p.of = float(ids[int(p.of)]) if typeof(p.of) == TYPE_FLOAT else int(ids[int(p.of)])
		if p.has("in") and int(p["in"]) == int(fg.id) and int(fg.id) != int(og.id):
			p["in"] = float(og.id) if typeof(p["in"]) == TYPE_FLOAT else int(og.id)
	return {"nodes": out, "wires": wires, "kept": kept, "made": made, "top": top}


## The conversion's node a new node is placed beside: the kept (or entry) node before it on the execution path, or
## for a data node, its first reader's (memoised in `memo`).
func _anchor(fw: Dictionary, fid: int, map: Dictionary, fe: int, memo: Dictionary) -> int:
	if memo.has(fid):
		return int(memo[fid])
	var cur := fid
	var seen := {}
	var found := fe
	while not seen.has(cur):
		seen[cur] = true
		if cur != fid and map.has(cur):
			found = cur
			break
		var next := -1
		if fw.xin.has(cur):
			for li in fw.lins.get(cur, []):
				if bool(li[3]):
					next = int(li[0])
					break
		else:
			for lo in fw.louts.get(cur, []):
				next = int(lo[0])
				break
		if next == -1:
			break
		cur = next
	memo[fid] = found
	return found


## Puts the merge of the conversion's graph `ng` (a copy of graph `fresh_gid` of the conversion, already given the
## old graph's id) into place of old graph `old`: ng's nodes and wires become the merge's, the old comment boxes that
## hold a node that stays are kept. Returns the old node ids that went.
func _gentle_graph(bp: Dictionary, old: Dictionary, fresh: Dictionary, ng: Dictionary, fresh_gid: int, map: Dictionary, stats: Dictionary) -> Array:
	var oset := _ids(old.nodes.filter(func(n): return String(n.kind) != "comment"))
	var fset := _ids(ng.nodes.filter(func(n): return String(n.kind) != "comment"))
	var fe := int(_fn_entry(ng).get("id", -1))
	var fg := ng.duplicate()
	fg.id = fresh_gid
	var m := _merge(bp, old, oset, fresh, fg, fset, map, fe, true)
	var nodes: Array = m.nodes
	var stay: Array = nodes.filter(func(n): return m.kept.has(int(n.id)))
	for box in old.nodes:
		if String(box.kind) == "comment" and stay.any(func(n): return _encloses(box, n)):
			nodes.append(box.duplicate(true))
			m.kept[int(box.id)] = true
	ng.nodes = nodes
	ng.wires = m.wires
	ng.next_id = int(m.top)
	_tally(stats, m, int(map.get(fe, -1)))
	var gone := []
	for n in old.nodes:
		if not m.kept.has(int(n.id)) and int(n.id) != int(map.get(fe, -1)):
			gone.append(int(n.id))
	return gone


static func _tally(stats: Dictionary, m: Dictionary, entry: int) -> void:
	for n in m.nodes:
		if String(n.kind) in ["reroute", "comment"] or int(n.id) == entry:
			continue
		if m.kept.has(int(n.id)):
			stats.kept_nodes = int(stats.kept_nodes) + 1
	stats.new_nodes = int(stats.new_nodes) + m.made.size()


## _put_event's work when nodes are kept: the chain of entry `nid` in event graph `eg` becomes the merge of the
## conversion's chain; the other events' nodes are not touched. Returns the names of the locals the new chain uses.
func _gentle_event(bp: Dictionary, eg: Dictionary, nid: int, gchain: Dictionary, fresh: Dictionary, feg: Dictionary, fentry: Dictionary, fnodes: Array,
		plan: Dictionary, rep: Dictionary, stats: Dictionary) -> Array:
	var map: Dictionary = plan.maps[int(eg.id)].map
	if plan.has("graph"):
		# (with hand-made nodes kept in it: _hand_units)
		var fs: Dictionary = plan.fset
		feg = plan.graph
		fnodes = feg.nodes.filter(func(n): return fs.has(int(n.id)))
	var going0 := gchain.duplicate()
	going0.erase(nid)
	var old_lambdas := _lambdas_only(bp, int(eg.id), going0, false)
	var new_lambdas := _lambdas_of(fresh, fnodes)
	var m := _merge(bp, eg, gchain, fresh, feg, _ids(fnodes), map, int(fentry.id), false)
	var entry := Model.find_node(eg, nid)
	if String(fentry.kind) == "fn_entry":
		entry.p["params"] = feg.inputs.duplicate(true)
		for k in COMMENT_FIELDS:
			if fentry.p.has(k):
				entry.p[k] = fentry.p[k].duplicate() if fentry.p[k] is Array else fentry.p[k]
			else:
				entry.p.erase(k)
	else:
		entry.p = fentry.p.duplicate(true)
		entry.d = fentry.d.duplicate(true)
	var going := {}
	for id in going0:
		if not m.kept.has(int(id)):
			going[int(id)] = true
	_take_out(eg, going, rep)
	var mine: Dictionary = m.kept.duplicate()
	mine[nid] = true
	eg.wires = eg.wires.filter(func(w): return not mine.has(int(w[0])) and not mine.has(int(w[2])))
	var by := {}
	for c in m.nodes:
		by[int(c.id)] = c
	for i in eg.nodes.size():
		if by.has(int(eg.nodes[i].id)):
			eg.nodes[i] = by[int(eg.nodes[i].id)]
			by.erase(int(eg.nodes[i].id))
	for c in m.nodes:
		if by.has(int(c.id)):
			eg.nodes.append(c)
	eg.wires.append_array(m.wires)
	eg.next_id = maxi(int(eg.next_id), int(m.top))
	_tally(stats, m, nid)
	# locals: as _put_event
	var used := _locals_used(m.nodes)
	var names := []
	for l in feg.get("locals", []):
		if not used.has(String(l.name)):
			continue
		names.append(String(l.name))
		var have := false
		for k in eg.locals:
			if String(k.name) == String(l.name):
				have = true
				if JSON.stringify(k) != JSON.stringify(l):
					rep.notes.append("the local %s of %s is also another event's, with another type: the other event's is kept" % [l.name, eg.name])
		if not have:
			eg.locals.append(l.duplicate(true))
	_count_kinds(rep, [], m.made)
	for pair in _swap_lambdas(bp, old_lambdas, fresh, new_lambdas, m.nodes, rep):
		if plan.maps.has(int(pair[0].id)) and int(plan.maps[int(pair[0].id)].fresh) == int(pair[2]):
			rep.replaced[int(pair[0].id)] = _gentle_graph(bp, pair[0], fresh, pair[1], int(pair[2]), plan.maps[int(pair[0].id)].map, stats)
	return names


## Takes nodes `going` (ids) out of event graph `eg` with their wires, the comment boxes that hold only them and
## the locals only they used.
func _take_out(eg: Dictionary, going: Dictionary, rep: Dictionary) -> void:
	var gone_nodes: Array = eg.nodes.filter(func(n): return going.has(int(n.id)))
	var boxes := _boxes_going(eg.nodes, going)
	var used_going := _locals_used(gone_nodes)
	var used_staying := _locals_used(eg.nodes.filter(func(n): return not going.has(int(n.id))))
	_count_kinds(rep, gone_nodes, [])
	var gone := going.merged(boxes)
	if not rep.replaced.has(int(eg.id)):
		rep.replaced[int(eg.id)] = []
	for id in gone:
		rep.replaced[int(eg.id)].append(int(id))
	eg.nodes = eg.nodes.filter(func(n): return not gone.has(int(n.id)))
	eg.wires = eg.wires.filter(func(w): return not gone.has(int(w[0])) and not gone.has(int(w[2])))
	eg.locals = eg.locals.filter(func(l): return not used_going.has(String(l.name)) or used_staying.has(String(l.name)))


func _remove_event(bp: Dictionary, gid: int, nid: int, rep: Dictionary) -> void:
	var eg := Model.find_graph(bp, gid)
	var going := _extent(bp, eg, nid)
	var old_lambdas := _lambdas_only(bp, gid, going, false)
	_take_out(eg, going, rep)
	_swap_lambdas(bp, old_lambdas, {}, [], [], rep)


# ---------------------------------------------------------------- the check

## A text's blocks in the form the check compares: {keys: {key: lines}, at: {key: line numbers}, order: [member
## variable names in order], funcs: [function names in order], comments: [[text, line]]}. Lines without blank
## lines, `#` comments, trailing spaces and trace lines (and without Show Flow and Values' own blocks); lines
## inside multi-line strings exactly. Keys: "func:<name>", "class", "<kind>:<name>", "<kind>#<n>" (unnamed).
func _canon(blocks: Array) -> Dictionary:
	var out := {"keys": {}, "at": {}, "strs": {}, "order": [], "funcs": [], "comments": [], "cmts": {}}
	var count := {}
	for b in blocks:
		var kind := String(b.kind)
		if kind in ["blank", "graph"]:
			continue
		var name := String(b.name)
		var strs := {}
		for ln in b.get("strs", []):
			strs[int(ln)] = true
		var lines := PackedStringArray()
		var at := PackedInt32Array()
		var in_str := {}   # index in `lines` -> true: a line inside a multi-line string, or one that opens one
		var pieces := PackedStringArray()   # the block's comments in order (see _pieces)
		var src := String(b.text).split("\n")
		for i in src.size():
			var ln := int(b.from) + i
			var raw := src[i].trim_suffix("\r")
			if strs.has(ln) or strs.has(ln + 1):
				in_str[lines.size()] = true
			if strs.has(ln):
				lines.append(raw)
				at.append(ln)
				continue
			var s := raw.strip_edges(false, true)
			if s.strip_edges() == "":
				continue
			var c := _strip_comment(s) if s.contains("#") else s
			if c != s:
				out.comments.append([s.substr(c.length()).strip_edges(), ln])
				pieces.append_array(_pieces(s.substr(c.length())))
			if c.strip_edges() == "" or c.strip_edges().begins_with("__sc_trace("):
				continue
			lines.append(c)
			at.append(ln)
		if lines.is_empty() or (kind in ["func", "var"] and name in TRACE_MACHINERY):
			continue
		var key := "class" if kind == "class" else "%s:%s" % [kind, name]
		if name == "" and kind != "class":
			count[kind] = int(count.get(kind, 0)) + 1
			key = "%s#%d" % [kind, int(count[kind])]
		while out.keys.has(key):
			key += "+"
		out.cmts[key] = pieces
		out.keys[key] = lines
		out.at[key] = at
		out.strs[key] = in_str
		if kind == "var":
			out.order.append(name)
		elif kind == "func":
			out.funcs.append(name)
	return out


## The differences between the file's form and the result's: [{key, name, line, file, graph}], first one first.
## An event whose new chain names a local with its event's name added (see Importer._declare_locals) is compared
## with that name in the file's text too, and the rename is reported.
func _compare(f: Dictionary, r: Dictionary, local_names: Dictionary, rep: Dictionary) -> Array:
	var out := []
	var keys: Array = f.keys.keys()
	for k in r.keys:
		if not f.keys.has(k):
			keys.append(k)
	for key in keys:
		var a: PackedStringArray = f.keys.get(key, PackedStringArray())
		var b: PackedStringArray = r.keys.get(key, PackedStringArray())
		var name := String(key).trim_prefix("func:") if String(key).begins_with("func:") else ""
		if a == b:
			continue
		var pairs := []
		if local_names.has(name):
			var tried := _with_event_names(a, name, local_names[name])
			if not tried[1].is_empty():
				pairs = tried[1]
				if tried[0] == b:
					a = tried[0]
		if a != b and f.keys.has(key) and r.keys.has(key):
			# written another way (brackets): the same once both are put in one form
			var ar: PackedStringArray = _with_event_names(a, name, local_names[name])[0] if not pairs.is_empty() else a
			if _norm_lines(ar, f.strs.get(key, {})) == _norm_lines(b, r.strs.get(key, {})):
				var at: PackedInt32Array = f.at.get(key, PackedInt32Array())
				for i in mini(ar.size(), b.size()):
					if ar[i] != b[i]:
						rep.reformatted.append({"line": at[i] if i < at.size() else 0, "file": a[i].strip_edges(), "graph": b[i].strip_edges()})
				a = b
		if a == b:
			for pair in pairs:
				rep.renamed_locals.append({"function": name, "written": pair[0], "now": pair[1]})
			continue
		var i := 0
		while i < a.size() and i < b.size() and a[i] == b[i]:
			i += 1
		var at: PackedInt32Array = f.at.get(key, PackedInt32Array())
		var line := at[mini(i, at.size() - 1)] if not at.is_empty() else 0
		out.append({"key": key, "name": name, "line": line, "file": a[i] if i < a.size() else "(nothing)", "graph": b[i] if i < b.size() else "(nothing)"})
	if f.order != r.order and out.is_empty():
		out.append({"key": "order", "name": "", "line": 0, "file": "member variables in the order " + ", ".join(f.order), "graph": ", ".join(r.order)})
	out.sort_custom(func(x, y): return (int(x.line) if int(x.line) > 0 else 1 << 30) < (int(y.line) if int(y.line) > 0 else 1 << 30))
	return out


## [lines, [[written, now]]]: the file's lines of event `ev` with each local its new chain names <written>_<event>
## (or _<event>_<n>) written so, where the file declares <written> and never names the other.
func _with_event_names(lines: PackedStringArray, ev: String, locals: Array) -> Array:
	var suffix := "_" + T.ident(ev).trim_prefix("_")
	var text := "\n".join(lines)
	var pairs := []
	for nm in locals:
		var now := String(nm)
		var at := now.rfind(suffix)
		if at <= 0:
			continue
		var tail := now.substr(at + suffix.length())
		if tail != "" and not (tail.begins_with("_") and tail.substr(1).is_valid_int()):
			continue
		var written := now.substr(0, at)
		if Compiler._replace_word(text, now, "\u0001") != text or Compiler._replace_word(text, written, "\u0001") == text:
			continue
		text = Compiler._replace_word(text, written, now)
		pairs.append([written, now])
	return [text.split("\n"), pairs]


## Lines put in one form (see _norm_line); the lines at the indices in `skip` (inside multi-line strings) as they are.
func _norm_lines(lines: PackedStringArray, skip: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for i in lines.size():
		out.append(lines[i] if skip.has(i) else _norm_line(lines[i]))
	return out


const ASSIGN_OPS := ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", "&=", "|=", "^="]

## One line of code in a form that does not depend on the brackets it is written with: each expression of the
## statement is read by sc_gd_parser, its grouping brackets dropped, and written back by Parser.unparse (which
## puts brackets only where the order of operators needs them). Two lines with the same form mean the same. A
## line this does not fully understand (a lambda, a multi-line string, annotations, a match pattern, anything the
## parser keeps as raw text) is given back as it is, so it must match exactly.
func _norm_line(line: String) -> String:
	var body := line.strip_edges(true, false)
	var indent := line.substr(0, line.length() - body.length())
	if body.contains("\"\"\"") or body.contains("'''") or body.contains("func") or body.contains("\\") or body == "":
		return line
	var p := Parser.new()
	var toks := []
	if p._scan(body, toks, 0) != 0 or toks.is_empty():
		return line
	for tk in toks:
		if String(tk.t) == "ann":
			return line
	p._t = toks
	var n := toks.size()
	var parts := []   # [from, to, is_expression]
	var first := String(toks[0].v) if String(toks[0].t) == "kw" else ""
	var last_colon := String(toks[-1].t) == "op" and String(toks[-1].v) == ":"
	var depth := 0
	var at := -1
	match first:
		"signal":
			# `signal done` declares what `signal done()` declares
			if n == 2 and String(toks[1].t) == "id":
				return indent + "signal %s()" % String(toks[1].v)
			return line
		"var", "const":
			for i in n:
				if String(toks[i].t) == "op" and String(toks[i].v) in ["=", ":="]:
					at = i
					break
			if at == -1:
				return line
			parts = [[0, at + 1, false], [at + 1, n, true]]
		"return":
			parts = [[0, 1, false]] + ([[1, n, true]] if n > 1 else [])
		"if", "elif", "while", "match":
			if not last_colon or n < 3:
				return line
			parts = [[0, 1, false], [1, n - 1, true], [n - 1, n, false]]
		"for":
			for i in n:
				if String(toks[i].t) == "kw" and String(toks[i].v) == "in":
					at = i
					break
			if at == -1 or not last_colon:
				return line
			parts = [[0, at + 1, false], [at + 1, n - 1, true], [n - 1, n, false]]
		"":
			if last_colon:
				return line
			for i in n:
				var tk: Dictionary = toks[i]
				if String(tk.t) == "op":
					if String(tk.v) in ["(", "[", "{"]:
						depth += 1
					elif String(tk.v) in [")", "]", "}"]:
						depth -= 1
					elif depth == 0 and String(tk.v) in ASSIGN_OPS:
						at = i
						break
			parts = [[0, at, true], [at, at + 1, false], [at + 1, n, true]] if at != -1 else [[0, n, true]]
		_:
			return line
	var out := PackedStringArray()
	for part in parts:
		if int(part[1]) <= int(part[0]):
			return line
		if not part[2]:
			p._t = toks
			out.append(p._source(int(part[0]), int(part[1])))
			continue
		p._t = toks.slice(int(part[0]), int(part[1]))
		p._p = 0
		var e: Variant = p._expr()
		if e == null or not p._at_end() or not _plain_expr(e):
			return line
		out.append(Parser.unparse(_no_parens(e)))
	return indent + " ".join(out)


## True for an expression tree with nothing kept as raw text and no lambda in it.
static func _plain_expr(e: Variant) -> bool:
	if e is Dictionary:
		if String(e.get("k", "")) in ["raw", "lambda"]:
			return false
		for k in e:
			if not _plain_expr(e[k]):
				return false
	elif e is Array:
		for x in e:
			if not _plain_expr(x):
				return false
	return true


static func _no_parens(e: Variant) -> Variant:
	if e is Dictionary:
		if String(e.get("k", "")) == "paren":
			return _no_parens(e.a)
		var out := {}
		for k in e:
			out[k] = _no_parens(e[k])
		return out
	if e is Array:
		return (e as Array).map(func(x): return _no_parens(x))
	return e


## Comments of the file the result does not write (counted by their text: by each piece between `#` signs, so a
## comment the converter keeps at the end of a line together with another still counts as kept).
func _comments(rep: Dictionary, f: Dictionary, r: Dictionary) -> void:
	var have := {}
	for c in r.comments:
		for piece in _pieces(String(c[0])):
			have[piece] = int(have.get(piece, 0)) + 1
	for c in f.comments:
		var kept := true
		for piece in _pieces(String(c[0])):
			if int(have.get(piece, 0)) > 0:
				have[piece] = int(have[piece]) - 1
			else:
				kept = false
		if not kept:
			rep.comment_lines.append(int(c[1]))
	rep.comments_dropped = rep.comment_lines.size()


## The texts between the `#` signs of a comment, stripped, without empty ones.
static func _pieces(comment: String) -> PackedStringArray:
	var out := PackedStringArray()
	for piece in comment.split("#", false):
		if piece.strip_edges() != "":
			out.append(piece.strip_edges())
	return out


## {line, msg} of the first thing GDScript says when it loads `code`, or {} when it loads.
func _load_error(code: String) -> Dictionary:
	var gs := GDScript.new()
	gs.source_code = _without_class_name(code)
	var logger: Object = null
	if ClassDB.class_exists("Logger"):
		logger = load("res://addons/schematic/editor/sc_logger.gd").new()
		OS.call("add_logger", logger)
	var ok := gs.reload() == OK
	if logger != null:
		OS.call("remove_logger", logger)
	# Replacing the temporary bytecode releases inner classes and static script references on Godot 4.6.
	# The probe has no instances and the reload verdict and diagnostics above belong to the original source.
	gs.source_code = "extends RefCounted\n"
	gs.reload()
	if ok:
		return {}
	if logger != null and not logger.items.is_empty():
		return {"line": int(logger.items[0].line), "msg": String(logger.items[0].msg)}
	return {"line": 0, "msg": "GDScript could not load it"}


## The script without its class name, so that a copy of it loads beside the real one (line numbers kept).
static func _without_class_name(code: String) -> String:
	var lines := code.split("\n")
	var own := ""
	for i in lines.size():
		var at := lines[i].find("class_name ")
		if at != -1 and lines[i].substr(0, at).strip_edges().trim_prefix("@abstract") == "":
			own = lines[i].substr(at + 11).get_slice(" ", 0).strip_edges()
			var rest := lines[i].find(" extends ")
			lines[i] = lines[i].substr(0, at) + (lines[i].substr(rest + 1) if rest > 0 else "")
	var text := "\n".join(lines)
	if own != "":
		text = RegEx.create_from_string("\\b%s\\.(?!new\\b)" % own).sub(text, "", true)
	return text
