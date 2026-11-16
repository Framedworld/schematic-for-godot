@tool
extends RefCounted
## Two-way editing, groundwork: a Schematic's GDScript split into blocks, each marked with whose it is, and two
## versions of a script compared block by block. It re-imports nothing and has no editor dependency (headless).
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

const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")

const KINDS := ["header", "class", "signal", "enum", "const", "var", "func", "inner_class", "region", "graph", "comment", "blank", "other"]
const OWNERS := ["user", "carried", "compiler"]
## Functions whose prelude (input dispatch, signal wiring, timeline autoplay) the compiler merges in.
const PRELUDE_FUNCS := ["_ready", "_init", "_unhandled_input"]
## What "Show Flow and Values" adds: present in one compile and absent in another is not an edit.
const TRACE_MACHINERY := ["__sc_trace", "__sc_flush", "__sc_hits", "__sc_last", "__sc_vals", "__sc_edges", "__sc_wait"]
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
				if x.head.begins_with(Model.GRAPH_BLOCK.strip_edges()) or x.head.begins_with(Model.OLD_GRAPH_BLOCK.strip_edges()):
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
