@tool
extends RefCounted
## A small GDScript parser for the Schematic importer. It understands the everyday subset of the language
## (members, functions, if / for / while, assignments, calls, operators) and keeps the source text of anything
## else, so the importer can carry it over as a code node instead of guessing.
##
## parse(source) -> {extends, class_name, tool, signals, vars, funcs, enums, notes}
##   var  = {name, type, init (expr or null), init_src, export, onready, const, group, line}
##   func = {name, params: [{name, type, default (expr or null)}], ret, body: [stmt], static, line}
##   stmt = {k: var|assign|expr|if|for|while|return|pass|break|continue|raw, src, line, ...}
##   expr = {k: num|str|name|bool|null|self|node|un|bin|tern|call|attr|index|array|dict|as|raw, ...}
##
## COMMENTS. Every comment a person wrote goes to the statement or declaration it belongs to (see
## _attach_comments), in these fields:
##   note   [String]  the lines written above it: each a comment line from its `#` on, or "" for a blank line
##   tail   String    the comment at the end of its line, with the spaces written before it ("  # why")
##   after  [String]  (statements) the lines below it that end the block it is the last statement of
##   end    [String]  (functions) `#endregion` lines right below it, which close a region around it
## A comment line indented deeper than its owner has a tab in front of the `#` for each block deeper, one less
## indented a "<" for each block shallower ("<# about the else"). Text kept as written (a statement kept as code,
## an enum, a property's set / get) holds the comments inside it in its text. The script's own: head_note (above
## extends), description (a `## ` block right below extends, followed by a blank line), end_note (after the last
## declaration). The marker line and the stored graph of a Schematic's own file are not comments of the script.

const T := preload("res://addons/schematic/core/sc_types.gd")
const KEYWORDS := ["if", "elif", "else", "for", "while", "match", "break", "continue", "pass", "return", "func", "var", "const",
	"signal", "enum", "class", "class_name", "extends", "static", "await", "and", "or", "not", "in", "is", "as", "self", "true",
	"false", "null", "super"]   # `when` is only a keyword inside a match pattern: elsewhere it is an ordinary name
const OPS3 := ["**=", "<<=", ">>="]
const OPS2 := ["==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", ":=", "->", "&&", "||", "**", "<<", ">>", "&=", "|=", "^="]

var notes: Array = []
var _lines: Array = []   # [{indent, toks, src, line}]
var _li := 0
var _t: Array = []       # tokens of the line being parsed
var _p := 0
var _saw_raw := false
var _lambdas: Dictionary = {}   # placeholder name -> the lambda lifted out of a statement's text
var _open_quote := ""           # the quote the text last given to _open() ends inside, "" when it ends outside any string
var _open_backslash := false    # the text last given to _open() ends with a line-continuation backslash (outside comments)
var _end_items: Array = []      # the comment and blank lines after the last logical line (see _tokenize)


# ---------------------------------------------------------------- tokenizer

## Splits the source into logical lines (brackets and backslashes continue a line) of tokens.
## Comments are kept beside them (see COMMENTS below): each logical line has `pre`, the comment and blank lines
## written above it since the line before ([{text, level}], {blank: true} for a blank line; `text` from the `#`
## on, `level` the block depth the comment is indented to), and `tail`, the comment at its end with the spaces
## before it ("" when none). What follows the last line is in _end_items.
func _tokenize(source: String) -> void:
	_lines = []
	_end_items = []
	var raw := source.replace("\r\n", "\n").split("\n")
	var i := 0
	var widths := [0]   # how far each enclosing block is indented: a line's depth counts blocks, not columns
	var pre := []
	while i < raw.size():
		var first := i
		var text := raw[i]
		var lead := raw[first]
		var base_ws := 0
		while base_ws < lead.length() and (lead[base_ws] == "\t" or lead[base_ws] == " "):
			base_ws += 1
		var bare := text.strip_edges()
		if bare.begins_with("#~"):
			i += 1   # a line of a Schematic's own data (the stored graph), or one re-import set aside: no comment of the script's
			continue
		if bare == "" or bare.begins_with("#"):
			# a blank line or a comment standing on its own line: kept for the next logical line
			if bare == "":
				pre.append({"blank": true})
			else:
				var ci := 0
				for k in base_ws:
					ci += 4 if lead[k] == "\t" else 1
				var level := widths.size() - 1
				if ci > int(widths[-1]):
					# deeper than the block it follows: how deep it is depends on the line after it too (see _deep_level)
					var unit := int(widths[1]) - int(widths[0]) if widths.size() > 1 else 4
					pre.append({"text": bare, "level": level + 1, "ci": ci, "base_w": int(widths[-1]), "base_l": level, "unit": maxi(unit, 1)})
				else:
					while level > 0 and int(widths[level]) > ci:
						level -= 1
					pre.append({"text": bare, "level": level})
			i += 1
			continue
		var inner := PackedStringArray()   # comments on lines a backslash continues past
		# keep taking lines while a bracket, a triple-quoted string or a trailing backslash is open
		while _open(text) and i + 1 < raw.size():
			i += 1
			var more := raw[i]
			var cut := 0
			while cut < base_ws and cut < more.length() and more[cut] == lead[cut]:
				cut += 1
			if _open_quote != "":
				text += "\n" + more   # the rest of a string that runs over several lines: exactly as written
			elif _open_backslash:   # (a backslash at the end of a comment continues nothing)
				if more.strip_edges().begins_with("#"):
					inner.append(more.strip_edges())
					continue   # a comment between the lines of one statement: the statement goes on after it
				text = text.strip_edges(false, true).trim_suffix("\\") + " " + more.strip_edges(true, false)
			else:
				text += "\n" + more.substr(cut)
		i += 1
		var toks := []
		_scan(text, toks, 0)
		if toks.is_empty():
			continue
		var indent := 0
		var col := 0
		while col < lead.length() and (lead[col] == "\t" or lead[col] == " "):
			indent += 4 if lead[col] == "\t" else 1
			col += 1
		while widths.size() > 1 and indent < int(widths[-1]):
			widths.pop_back()
		if indent > int(widths[-1]):
			widths.append(indent)
		var tail := _tail_of(text)
		for more_comment in inner:
			tail += "  " + more_comment
		for it in pre:
			_deep_level(it, indent, widths.size() - 1)
		_lines.append({"indent": indent, "level": widths.size() - 1, "toks": toks, "src": _strip_comment(text).strip_edges(), "line": first + 1,
			"pre": pre, "tail": tail})
		pre = []
	for it in pre:
		_deep_level(it, -1, -1)
	_end_items = pre


## The depth of a comment indented deeper than the block before it, once the line after it is known (indentation
## `indent` at depth `level`; -1 at the end of the file). As deep as that line when it is not indented deeper than
## that line (the first line of a deeper block, however far a block is indented); deeper than both, one block for
## each step of the file's indentation past the deeper of the two (commented-out code keeps its depth wherever it
## is written, so that converting the result again reads it the same).
static func _deep_level(it: Dictionary, indent: int, level: int) -> void:
	if not it.has("ci"):
		return
	var ci := int(it.ci)
	var bw := int(it.base_w)
	var bl := int(it.base_l)
	if indent > bw:
		if ci <= indent:
			it.level = level
			return
		bw = indent
		bl = level
	it.level = bl + maxi(1, roundi(float(ci - bw) / float(it.unit)))


## The comments a logical line's text holds outside its strings, as one trailing comment: the first with the
## spaces written before it, any further ones (on the following lines of a statement that runs over several
## lines) after two spaces each. "" when there are none.
func _tail_of(text: String) -> String:
	if not text.contains("#"):
		return ""
	var out := ""
	var quote := ""
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if quote != "":
			if c == "\\":
				i += 1
			elif quote.length() == 3 and text.substr(i, 3) == quote:
				quote = ""
				i += 2
			elif quote.length() == 1 and c == quote:
				quote = ""
		elif text.substr(i, 3) == "\"\"\"" or text.substr(i, 3) == "'''":
			quote = text.substr(i, 3)
			i += 2
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#":
			var nl := text.find("\n", i)
			var comment := text.substr(i, (nl if nl != -1 else n) - i).strip_edges(false, true)
			var ws := i
			while ws > 0 and text[ws - 1] in [" ", "\t"]:
				ws -= 1
			var gap := text.substr(ws, i - ws)
			if out != "" or ws == 0 or text[ws - 1] == "\n":
				gap = "  "   # a comment on a line of its own inside the statement
			out += gap + comment
			if nl == -1:
				break
			i = nl
			continue
		i += 1
	return out


## True while the text ends inside brackets or a triple-quoted string, or with a line-continuation backslash.
func _open(text: String) -> bool:
	var depth := 0
	var quote := ""
	var i := 0
	var n := text.length()
	var last := ""
	while i < n:
		var c := text[i]
		if quote != "":
			if c == "\\":
				i += 1
			elif quote.length() == 3 and text.substr(i, 3) == quote:
				quote = ""
				i += 2
			elif quote.length() == 1 and c == quote:
				quote = ""
		elif text.substr(i, 3) == "\"\"\"" or text.substr(i, 3) == "'''":
			quote = text.substr(i, 3)
			i += 2
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#":
			var nl := text.find("\n", i)
			if nl == -1:
				break
			i = nl   # (a comment is not the last thing of the line: what ends a line is what stands before it)
			continue
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		if c != " " and c != "\t" and c != "\n" and c != "\r":
			last = c
		i += 1
	_open_quote = quote
	_open_backslash = quote == "" and last == "\\"
	return depth > 0 or quote != "" or last == "\\"


## Where the triple quote `q` that closes a string begins, looking from `from`; a quote after a backslash
## does not close it. -1 when the string does not end in the text.
func _triple_end(text: String, from: int, q: String) -> int:
	var j := from
	var n := text.length()
	while j < n:
		if text[j] == "\\":
			j += 2
			continue
		if text.substr(j, 3) == q:
			return j
		j += 1
	return -1


func _strip_comment(text: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	while i < text.length():
		var c := text[i]
		if quote != "":
			out += c
			if c == "\\" and i + 1 < text.length():
				i += 1
				out += text[i]
			elif c == quote:
				quote = ""
		elif text.substr(i, 3) == "\"\"\"" or text.substr(i, 3) == "'''":
			# a triple-quoted string is copied through whole
			var close := _triple_end(text, i + 3, text.substr(i, 3))
			if close == -1:
				close = text.length() - 3
			out += text.substr(i, close + 3 - i)
			i = close + 2
		elif c == "\"" or c == "'":
			quote = c
			out += c
		elif c == "#":
			# drop to the end of this physical line
			var nl := text.find("\n", i)
			if nl == -1:
				break
			i = nl - 1
		else:
			out += c
		i += 1
	return out


## Appends the tokens of one physical line; returns the bracket depth after it.
func _scan(text: String, toks: Array, depth: int) -> int:
	var i := 0
	var n := text.length()
	# each token also keeps its text as written ("raw") and whether space stood before it ("sp"), so that a
	# range of tokens can be given back as source (see _source)
	var mark := toks.size()
	var tok_start := 0
	var gap := false
	var gap_before := false
	while i < n:
		if toks.size() > mark:
			_mark_tok(toks, mark, text, tok_start, i, gap_before)
			mark = toks.size()
			gap = false
		var c := text[i]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			gap = true
			i += 1
			continue
		if c == "#":
			gap = true
			var line_end := text.find("\n", i)
			if line_end == -1:
				break
			i = line_end
			continue
		tok_start = i
		gap_before = gap
		# strings, with the &"name" / ^"path" / r"raw" prefixes
		var prefix := ""
		if (c == "&" or c == "^" or c == "r") and i + 1 < n and (text[i + 1] == "\"" or text[i + 1] == "'"):   # r"raw"
			prefix = c
			i += 1
			c = text[i]
		if c == "\"" or c == "'":
			if text.substr(i, 3) == c + c + c:
				var close := _triple_end(text, i + 3, c + c + c)
				if close == -1:
					close = n - 3
				toks.append({"t": "str", "v": prefix + text.substr(i, close + 3 - i), "multi": true})
				i = close + 3
				continue
			var j := i + 1
			while j < n and text[j] != c:
				if text[j] == "\\":
					j += 1
				j += 1
			toks.append({"t": "str", "v": prefix + text.substr(i, j - i + 1)})
			i = j + 1
			continue
		# $Node/Path, $"Quoted/Path", %UniqueName: `%` starts a path wherever no value ends before it (the engine's
		# own rule), after an operator, a bracket, a comma or a keyword such as await, elif, while or match
		if c == "$" or (c == "%" and i + 1 < n and _is_id_start(text[i + 1]) and (toks.is_empty() or not _ends_value(toks[-1]))):
			var j := i + 1
			var path := ""
			if j < n and text[j] == "\"":
				var e := text.find("\"", j + 1)
				path = text.substr(j + 1, e - j - 1)
				j = e + 1
			else:
				while j < n:
					if _is_id_char(text[j]) or text[j] == "/" or text[j] == "%":
						j += 1
					elif text[j] == "." and j + 1 < n and text[j + 1] == ".":
						j += 2   # $../Sibling
					else:
						break
				path = text.substr(i + 1, j - i - 1)
			toks.append({"t": "node", "v": ("%" if c == "%" else "") + path})
			i = j
			continue
		if c == "@":
			var j := i + 1
			while j < n and _is_id_char(text[j]):
				j += 1
			toks.append({"t": "ann", "v": text.substr(i, j - i)})
			i = j
			continue
		# A sign straight in front of a digit is part of the number unless something it could be subtracted
		# from stands before it, exactly as in GDScript's tokenizer: "-2 ** 2" is (-2) ** 2, "- 2 ** 2" is not.
		var sign := ""
		if (c == "-" or c == "+") and i + 1 < n and text[i + 1].is_valid_int() and not (not toks.is_empty() and _ends_value(toks[-1])):
			sign = c
			i += 1
			c = text[i]
		if c.is_valid_int() or (c == "." and i + 1 < n and text[i + 1].is_valid_int()):
			var j := i
			var is_float := false
			if c == "0" and i + 1 < n and (text[i + 1] == "x" or text[i + 1] == "b"):
				j = i + 2
				while j < n and (text[j].is_valid_hex_number() or text[j] == "_"):
					j += 1
			else:
				while j < n and (text[j].is_valid_int() or text[j] == "_" or text[j] == "." or text[j] == "e" or text[j] == "E"
						or ((text[j] == "-" or text[j] == "+") and (text[j - 1] == "e" or text[j - 1] == "E"))):
					if text[j] == "." or text[j] == "e" or text[j] == "E":
						if text[j] == "." and j + 1 < n and _is_id_start(text[j + 1]) and not text[j + 1] in ["e", "E"]:
							break   # 1.method()
						if text[j] != "." and not (j + 1 < n and (text[j + 1].is_valid_int() or text[j + 1] in ["-", "+"])):
							break   # not an exponent: a word begins here
						is_float = true
					j += 1
			toks.append({"t": "num", "v": ("-" if sign == "-" else "") + text.substr(i, j - i).replace("_", ""), "f": is_float})
			i = j
			continue
		if _is_id_start(c):
			var j := i + 1
			while j < n and _is_id_char(text[j]):
				j += 1
			var word := text.substr(i, j - i)
			toks.append({"t": "kw" if word in KEYWORDS else "id", "v": word})
			i = j
			continue
		var op := c
		if i + 2 < n and text.substr(i, 3) in OPS3:
			op = text.substr(i, 3)
		elif i + 1 < n and text.substr(i, 2) in OPS2:
			op = text.substr(i, 2)
		if op in ["(", "[", "{"]:
			depth += 1
		elif op in [")", "]", "}"]:
			depth -= 1
		toks.append({"t": "op", "v": op})
		i += op.length()
	if toks.size() > mark:
		_mark_tok(toks, mark, text, tok_start, i, gap_before)
	return depth


func _mark_tok(toks: Array, from: int, text: String, start: int, end: int, gap: bool) -> void:
	toks[from]["raw"] = text.substr(start, end - start)
	toks[from]["sp"] = gap
	for k in range(from + 1, toks.size()):
		toks[k]["raw"] = String(toks[k].v)
		toks[k]["sp"] = false


## The source text of the tokens [from, to) of the line being parsed, as written (comments and line breaks
## between them become single spaces).
func _source(from: int, to: int) -> String:
	var out := ""
	for k in range(from, mini(to, _t.size())):
		var tk: Dictionary = _t[k]
		if k > from and bool(tk.get("sp", true)):
			out += " "
		out += String(tk.get("raw", tk.v))
	return out


func _is_id_start(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c.unicode_at(0) > 127


func _is_id_char(c: String) -> bool:
	return _is_id_start(c) or c.is_valid_int()


## True for a token a binary operator can follow: a name, a literal, self or a closing bracket.
func _ends_value(tok: Dictionary) -> bool:
	match String(tok.t):
		"id", "num", "str", "node":
			return true
		"kw":
			return String(tok.v) in ["self", "true", "false", "null"]
		"op":
			return String(tok.v) in [")", "]", "}"]
	return false


# ---------------------------------------------------------------- token helpers

func _peek(offset := 0) -> Dictionary:
	return _t[_p + offset] if _p + offset < _t.size() else {"t": "end", "v": ""}


func _is(v: String) -> bool:
	var tok := _peek()
	return tok.t in ["op", "kw"] and tok.v == v


func _take(v: String) -> bool:
	if _is(v):
		_p += 1
		return true
	return false


func _next() -> Dictionary:
	_p += 1
	return _t[_p - 1] if _p - 1 < _t.size() else {"t": "end", "v": ""}


func _at_end() -> bool:
	return _p >= _t.size()


# ---------------------------------------------------------------- top level

func parse(source: String) -> Dictionary:
	notes = []
	_tokenize(_own_lines_blanked(source))
	_li = 0
	var out := {"extends": "", "class_name": "", "tool": false, "signals": [], "vars": [], "funcs": [], "enums": [], "extra": [],
		"notes": notes, "uses_groups": false, "crlf": _line_ends(source), "class_pre": [], "head_note": [], "description": "", "end_note": []}
	var group := ""
	var pending := {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
	var below_class := false
	var last_func := {}      # the function the line before ended (an `#endregion` below it closes a region around it)
	var prev_block := false  # the declaration before has lines below its first (a function, a property's set / get) # the line just read was the extends / class_name line
	while _li < _lines.size():
		var ln: Dictionary = _lines[_li]
		_t = ln.toks
		_p = 0
		# the comments above this line that are its own (the ones indented deeper end the block before it, when
		# the declaration before it has a block: they are in its text, or a statement's of its function)
		var items: Array = ln.pre.slice(_deep_prefix(ln.pre, 0) if prev_block else 0)
		prev_block = false
		items = _region_end(items, last_func)
		last_func = {}
		if below_class:
			below_class = false
			items = _class_doc(items, out)
		var note := _note(items, 0)
		if ln.indent > 0:
			notes.append("line %d: unexpected indented line kept as text: %s" % [ln.line, ln.src])
			out.extra.append("\n".join(PackedStringArray(note)) + ("\n" if not note.is_empty() else "") + String(ln.src) + String(ln.tail))
			_li += 1
			continue
		# annotations in front of (or on the line above) a declaration
		var ann_start := _p
		while _peek().t == "ann":
			var ann := String(_next().v)
			var arg := ""
			var has_args := false
			if _take("("):
				has_args = true
				var depth := 1
				while not _at_end() and depth > 0:
					var tk := _next()
					if tk.t == "op" and tk.v == "(":
						depth += 1
					elif tk.t == "op" and tk.v == ")":
						depth -= 1
					elif depth == 1 and tk.t == "str" and arg == "":
						arg = String(tk.v).trim_prefix("&").trim_prefix("\"").trim_suffix("\"")
			match ann:
				"@tool": out.tool = true
				"@onready": pending.onready = true
				"@export": pending.export = true
				"@export_group", "@export_subgroup", "@export_category":
					group = arg
					out.uses_groups = true
					pending.plain = false
				_:
					pending.plain = false
					if ann.begins_with("@export"):
						pending.export = true
		if _at_end():
			# a line of annotations only: it belongs to the class (@icon, @static_unload) or to the next declaration
			var of_class := PackedStringArray()
			for word in String(ln.src).split("@", false):
				var ann_text := "@" + word.strip_edges()
				if ann_text.begins_with("@icon") or ann_text.begins_with("@static_unload"):
					of_class.append(ann_text)
			if not of_class.is_empty() or ln.src == "@tool":
				# (comments above the class's own lines are the script's: written above them)
				out.head_note.append_array(_trimmed(pending.note + note, true))
				_tail_note(out.head_note, String(ln.tail))
				pending.note = []
				note = []
			if not of_class.is_empty():
				out.class_pre.append_array(of_class)
				pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
			elif ln.src != "@tool":
				pending.note.append_array(note)
				pending.text.append(String(ln.src) + String(ln.tail))
			_li += 1
			continue
		var tok := _peek()
		var is_static := false
		if tok.t == "kw" and tok.v == "static":
			_p += 1
			is_static = true
			tok = _peek()
		if tok.t == "kw" and (tok.v == "extends" or tok.v == "class_name"):
			# annotations written above or in front of the class (@icon, @abstract ...) stay with it
			out.class_pre.append_array(pending.text)
			var lead := String(ln.src).substr(0, maxi(String(ln.src).find(String(tok.v)), 0)).replace("@tool", "").strip_edges()
			if lead != "":
				out.class_pre.append(lead)
			out.head_note.append_array(_trimmed(pending.note + note, true))
			_tail_note(out.head_note, String(ln.tail))
			below_class = true
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
			_p += 1
			if tok.v == "class_name":
				out.class_name = String(_next().v)
			if tok.v == "extends" or _take("extends"):
				out.extends = String(_next().v).trim_prefix("\"").trim_suffix("\"")
				while _take("."):
					out.extends += "." + String(_next().v)
			_li += 1
		elif tok.t == "kw" and tok.v == "signal":
			_p += 1
			var sig := {"name": String(_next().v), "params": []}
			if _take("("):
				while not _at_end() and not _is(")"):
					var pn := String(_next().v)
					var pt := ""
					if _take(":"):
						pt = _type()
					sig.params.append([pn, pt])
					_take(",")
			# annotations written above the signal (@warning_ignore ...) stay with it
			sig["pre"] = Array(pending.text)
			var sig_line := String(ln.src)
			if sig_line.begins_with("@"):
				sig.pre.append(sig_line.substr(0, sig_line.find("signal ")).strip_edges())
			_own_comments(sig, _trimmed(pending.note + note, true), String(ln.tail))
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
			out.signals.append(sig)
			_li += 1
		elif tok.t == "kw" and (tok.v == "var" or tok.v == "const"):
			var start_li := _li
			var v := _var_decl()
			v["export"] = pending.export
			v["onready"] = pending.onready
			v["group"] = group if pending.export else ""
			v["static"] = is_static
			v["line"] = ln.line
			v["plain"] = bool(pending.plain) and not is_static and not bool(v.const)
			var has_block := _li + 1 < _lines.size() and int(_lines[_li + 1].indent) > int(ln.indent)
			if not _at_end() or has_block:
				# a property with set / get, or a value ending in a multi-line lambda: the block below belongs to it
				v.plain = false
				v["setget"] = true
				_skip_block(ln.indent)
			else:
				_li += 1
			# the declaration exactly as written, annotations included (and, in `text_tail`, the comment at the end
			# of its line: where it is kept as written, the comment is part of the text)
			# (a declaration of one line ends at that line: comments indented deeper below it go to the next one)
			prev_block = _li - start_li > 1
			var deep := -1 if prev_block else 1000
			var text := PackedStringArray(pending.text)
			text.append(_text(start_li, _li, -1, false, false, deep))
			v["text"] = "\n".join(text)
			var with_tail := PackedStringArray(pending.text)
			with_tail.append(_text(start_li, _li, -1, false, true, deep))
			v["text_tail"] = "\n".join(with_tail)
			_own_comments(v, _trimmed(pending.note + note, true), String(ln.tail))
			out.vars.append(v)
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
		elif tok.t == "kw" and tok.v == "func":
			var f := _func_decl(ln)
			f["static"] = is_static
			f["pre"] = Array(pending.text)
			var first_line := String(ln.src)
			if ann_start != _p and first_line.begins_with("@"):
				f.pre.append(first_line.substr(0, first_line.find("func ")).strip_edges().trim_suffix("static").strip_edges())
			_own_comments(f, _trimmed(pending.note + note, true), String(ln.tail))
			out.funcs.append(f)
			last_func = f
			prev_block = true
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
		else:
			# enums, inner classes and anything else the model has no place for: carried over as written
			var start_li := _li
			var what := "enum" if tok.v == "enum" else ("inner class" if tok.v == "class" else "declaration")
			if tok.t == "kw" and tok.v == "enum":
				_p += 1
				var en := {"name": "", "values": []}
				if _peek().t == "id":
					en.name = String(_next().v)
				if _take("{"):
					while not _at_end() and not _is("}"):
						en.values.append(String(_next().v))
						if _take("="):
							_expr()
						_take(",")
				out.enums.append(en)
			if tok.t == "kw" and tok.v == "class":
				out.enums.append({"name": String(_peek(1).v), "values": [], "class": true})
			_skip_block(ln.indent)
			# kept as written: the comments above it and in it are part of its text
			prev_block = _li - start_li > 1
			var text := PackedStringArray(_trimmed(pending.note + note, true))
			text.append_array(pending.text)
			text.append(_text(start_li, _li, -1, false, true, -1 if prev_block else 1000))
			out.extra.append("\n".join(text))
			if what != "enum":
				notes.append("line %d: %s kept as written: %s" % [ln.line, what, ln.src])
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray(), "note": []}
	# comments after the last declaration (those indented deeper end the function or block before them)
	var end_items := _region_end(_end_items.slice(_deep_prefix(_end_items, 0) if prev_block else 0), last_func)
	if below_class:
		end_items = _class_doc(end_items, out)
	out.end_note = _trimmed(pending.note + _note(end_items, 0))
	_attach_comments(out)
	return out


## The source without what a Schematic's own file adds to a script: its marker line (the first) and its stored
## graph (from the #region that holds it). The lines keep their numbers.
func _own_lines_blanked(source: String) -> String:
	var src := source
	for block in ["\n#region Schematic graph data", "\n#region Blueprint graph data"]:
		var at := src.find(block)
		if at != -1:
			src = src.substr(0, at + 1)
	if src.begins_with("# @schematic") or src.begins_with("# @blueprint"):
		var nl := src.find("\n")
		src = "" if nl == -1 else src.substr(nl)
	return src


## Comment items as note lines of something at block depth `level` (see COMMENTS).
func _note(items: Array, level: int) -> Array:
	var out := []
	for it in items:
		out.append(_enc(it, level))
	return out


func _enc(it: Dictionary, level: int) -> String:
	if bool(it.get("blank", false)):
		return ""
	var rel := int(it.level) - level
	return ("\t".repeat(rel) if rel > 0 else "<".repeat(-rel)) + String(it.text)


## Note lines without the blank lines they begin with (and, unless `leading_only`, end with): what stands
## between declarations is the compiler's to lay out.
func _trimmed(lines: Array, leading_only := false) -> Array:
	var out := lines.duplicate()
	while not out.is_empty() and String(out[0]) == "":
		out.pop_front()
	if not leading_only:
		while not out.is_empty() and String(out[-1]) == "":
			out.pop_back()
	return out


## `#endregion` lines right below a function close a region around it: they are the function's `end` (written
## right after it, wherever the function is written), not the next declaration's note. Returns the items left.
func _region_end(items: Array, f: Dictionary) -> Array:
	if f.is_empty():
		return items
	var taken := -1
	for k in items.size():
		if bool(items[k].get("blank", false)):
			continue
		if int(items[k].level) == 0 and String(items[k].text).begins_with("#endregion"):
			taken = k
			continue
		break
	if taken == -1:
		return items
	var end: Array = f.get("end", [])
	for k in taken + 1:
		if not bool(items[k].get("blank", false)):
			end.append(String(items[k].text))
	f["end"] = end
	return items.slice(taken + 1)


## Gives a declaration its note and tail (only the fields that have something).
func _own_comments(decl: Dictionary, note: Array, tail: String) -> void:
	if not note.is_empty():
		decl["note"] = note
	if tail != "":
		decl["tail"] = tail


## A comment at the end of a line that has nowhere to stand at the end of a line in the converted script: a
## comment line of its own, after `lines`.
func _tail_note(lines: Array, tail: String) -> void:
	if tail != "":
		lines.append(tail.strip_edges())


## Gives every comment inside a function to the statement it belongs to (see COMMENTS at the top):
##   - a comment line above a statement, at its depth or shallower, is its `note` (with the blank lines above it);
##   - a comment line indented deeper than the line below it ends the block above: it is the `after` of the last
##     statement at its depth there (or the deepest one shallower), written after everything that statement wrote;
##   - a comment above an `elif` / `else:` or a match arm is the `after` of the last statement of the branch or arm
##     before it (above the first arm: the `note` of the arm's first statement); so is the comment at the end of
##     a match arm's line. The comment at the end of an `elif` / `else:` line is kept for that line: the if's
##     `arm_tails` ({the branch's place in `branches`, or "else": the comment with the spaces before it});
##   - the comment at the end of a statement's line is its `tail`; the one at the end of the `func` line is the
##     function's;
##   - comments inside a statement whose text is kept as written (a lambda's body) are in that text.
## The comments a statement holds inside (a branch's statements' own) are also in its `text`, which is what a
## statement kept as code is written as; the importer uses one or the other.
func _attach_comments(out: Dictionary) -> void:
	var li_at := {}
	for i in _lines.size():
		li_at[int(_lines[i].line)] = i
	for f in out.funcs:
		if bool(f.get("abstract", false)) or not li_at.has(int(f.line)):
			continue
		var hli: int = li_at[int(f.line)]
		var top := int(_lines[hli].level)
		var fend := hli
		while fend + 1 < _lines.size() and int(_lines[fend + 1].level) > top:
			fend += 1
		var entries := []
		_comment_entries(f.body, li_at, entries)
		for en in entries:
			var e := int(en.li)
			# (an if's lines go on through its elif and else lines, which are as deep as it is)
			while e + 1 <= fend and (int(_lines[e + 1].level) > int(en.level) or (String(en.st.k) == "if" and int(_lines[e + 1].level) == int(en.level) \
					and not _lines[e + 1].toks.is_empty() and _lines[e + 1].toks[0].t == "kw" and String(_lines[e + 1].toks[0].v) in ["elif", "else"])):
				e += 1
			en["end"] = e
		var first_at := {}
		for en in entries:
			if not first_at.has(int(en.li)):
				first_at[int(en.li)] = en
		for li in range(hli + 1, fend + 1):
			if first_at.has(li) and String(_lines[li].tail) != "":
				first_at[li].st["tail"] = String(_lines[li].tail)
		for at in range(hli + 1, fend + 2):
			var items: Array = _lines[at].pre if at < _lines.size() else _end_items
			var inside := at <= fend
			var level := int(_lines[at].level) if inside else top
			var upto := _deep_prefix(items, level)
			var buf := []
			var orphans := []   # (deeper than the line below, with nothing above it to end: above that line after all)
			# (once a comment has gone below a statement, the ones after it go below that one or one around it, never
			# below one inside it, which is written earlier: commented-out code indented deeper stays in order)
			var cap := 1 << 30
			for k in upto:
				var it: Dictionary = items[k]
				buf.append(it)
				if bool(it.get("blank", false)):
					continue
				var owner := _deepest(entries, at - 1, mini(int(it.level), cap))
				if not owner.is_empty() and int(owner.end) >= at:
					owner = {}   # (the statement goes on below it: the comment ends no block, it is above the line below)
				if not owner.is_empty():
					cap = int(owner.level)
				if owner.is_empty():
					orphans.append_array(buf)
				elif not (int(owner.level) < int(it.level) and int(owner.end) > int(owner.li) and not owner.compound):
					_give(owner.st, "after", buf, int(owner.level))
				buf = []
			if not inside:
				continue
			var rest := orphans + items.slice(upto)
			if not first_at.has(at) and String(_lines[at].tail) != "":
				# the end of an `elif` / `else:` line of an if: kept for that line (the if's arm_tails)
				var arm_if := {}
				for en in entries:
					if String(en.st.get("k", "")) == "if" and (en.st.get("arm_lines", {}) as Dictionary).has(int(_lines[at].line)):
						arm_if = en.st
				if arm_if.is_empty():
					rest = rest + [{"text": String(_lines[at].tail).strip_edges(), "level": level}]
				else:
					var arm_tails: Dictionary = arm_if.get("arm_tails", {})
					arm_tails[arm_if.arm_lines[int(_lines[at].line)]] = String(_lines[at].tail)
					arm_if["arm_tails"] = arm_tails
			if rest.is_empty():
				continue
			if first_at.has(at):
				_give(first_at[at].st, "note", rest, int(first_at[at].level))
				continue
			# a line that starts no statement: an elif / else: or a match arm of the statement around it (inside
			# anything else, a lambda's body, the comments are part of that statement's text)
			var around := {}
			for en in entries:
				if int(en.li) < at and at <= int(en.end) and (around.is_empty() or int(en.level) >= int(around.level)):
					around = en
			if around.is_empty() or not around.compound:
				continue
			var before := _deepest(entries, at - 1, level + 1)
			if not before.is_empty() and int(before.li) > int(around.li):
				_give(before.st, "after", rest, int(before.level))
				continue
			for en in entries:
				if int(en.li) > at and int(en.li) <= int(around.end):
					# (written inside the arm now, so as deep as its statements)
					var moved := []
					for it in rest:
						moved.append(it if bool(it.get("blank", false)) else {"text": it.text, "level": maxi(int(it.level), int(en.level))})
					_give(en.st, "note", moved, int(en.level))
					break


## Every statement of a body and of the bodies inside it, in the order they are written: [{st, li, level, compound}].
func _comment_entries(body: Array, li_at: Dictionary, out: Array) -> void:
	for st in body:
		if not st is Dictionary or not li_at.has(int(st.get("line", -1))):
			continue
		var li: int = li_at[int(st.line)]
		var k := String(st.get("k", ""))
		out.append({"st": st, "li": li, "level": int(_lines[li].level), "compound": k in ["if", "for", "while", "match"]})
		match k:
			"if":
				for br in st.branches:
					_comment_entries(br[1], li_at, out)
				_comment_entries(st["else"], li_at, out)
			"for", "while":
				_comment_entries(st.body, li_at, out)
			"match":
				for arm in st.arms:
					_comment_entries(arm.body, li_at, out)


## The statement whose lines hold logical line `at` that is indented deepest, but no deeper than `level` (the
## first such one of those that are equally deep). {} when there is none.
func _deepest(entries: Array, at: int, level: int) -> Dictionary:
	var best := {}
	for en in entries:
		if int(en.li) <= at and at <= int(en.end) and int(en.level) <= level and (best.is_empty() or int(en.level) > int(best.level)):
			best = en
	return best


## Adds comment items to a statement's `note` or `after`, as lines relative to the statement's depth `level`.
func _give(st: Dictionary, field: String, items: Array, level: int) -> void:
	var lines: Array = st.get(field, [])
	lines.append_array(_note(items, level))
	st[field] = lines


## The class's doc comment: a block of `## text` lines right below the extends / class_name line, followed by a
## blank line, is the schematic's description (which the compiler writes there); returns the items left.
func _class_doc(items: Array, out: Dictionary) -> Array:
	var texts := PackedStringArray()
	var k := 0
	while k < items.size() and not bool(items[k].get("blank", false)) and int(items[k].level) == 0 \
			and String(items[k].text).begins_with("## ") and String(items[k].text).substr(3).strip_edges() != "":
		texts.append(String(items[k].text).substr(3))
		k += 1
	if texts.is_empty() or k >= items.size() or not bool(items[k].get("blank", false)):
		return items
	out.description = "\n".join(texts)
	return items.slice(k)


## True when the converted script is to be written with Windows line endings. The script is written with one
## kind of line ending throughout, which is the source's own. In a file that mixes the two, a string that runs
## over several lines keeps its line breaks only if the file is written with the kind it uses, so that kind
## wins; if the strings themselves mix the two kinds, they cannot all be kept, and a note says so.
func _line_ends(source: String) -> bool:
	var crlf := source.contains("\r\n")
	if not crlf or not source.replace("\r\n", "").contains("\n"):
		return crlf   # one kind throughout
	var lines := source.split("\n")
	var inside := T.lines_in_string(source)
	var in_crlf := false
	var in_lf := false
	for k in range(1, mini(lines.size(), inside.size())):
		if inside[k]:
			if lines[k - 1].ends_with("\r"):
				in_crlf = true
			else:
				in_lf = true
	if in_crlf and in_lf:
		notes.append("this script mixes Windows (CRLF) and Unix (LF) line breaks inside its multi-line strings: the converted script uses Windows line breaks throughout, which changes the strings that had Unix ones")
		return true
	if in_lf:
		return false
	return true


func _skip_block(indent: int) -> void:
	_li += 1
	while _li < _lines.size() and int(_lines[_li].indent) > indent:
		_li += 1


func _type() -> String:
	var name := String(_next().v)
	while _take("."):
		name += "." + String(_next().v)
	if _take("["):
		var inner := _type()
		if _take(","):
			inner += ", " + _type()
		_take("]")
		name += "[%s]" % inner
	return name


func _var_decl() -> Dictionary:
	var is_const := String(_next().v) == "const"
	_saw_raw = false
	var v := {"name": String(_next().v), "type": "", "init": null, "init_src": "", "const": is_const, "infer": false}
	if _take(":="):
		v.infer = true
		var start := _p
		v.init = _expr()
		v.init_src = unparse(v.init)
	else:
		var colon := _take(":")
		if colon:
			if not _is("=") and not _at_end() and not (_peek().t == "id" and String(_peek().v) in ["set", "get"]):
				v.type = _type()
		if _take("="):
			v.infer = colon and String(v.type) == ""   # "var x: = value" is ":=" written with a space
			v.init = _expr()
			v.init_src = unparse(v.init)
	v["has_raw"] = _saw_raw
	return v


func _func_decl(ln: Dictionary) -> Dictionary:
	_p += 1
	var f := {"name": String(_next().v), "params": [], "ret": "", "body": [], "line": ln.line}
	_take("(")
	while not _at_end() and not _is(")"):
		var rest := false
		while _take("."):
			rest = true   # ...args: whatever further arguments the caller passes, as an array
		var prm := {"name": String(_next().v), "type": "", "default": null}
		if rest:
			prm["rest"] = true
		if _take(":=") or (_is(":") and _peek(1).t == "op" and _peek(1).v == "=" and _take(":") and _take("=")):   # ":=", or ": ="
			prm.default = _expr()
			prm["infer"] = true
		else:
			if _take(":"):
				prm.type = _type()
			if _take("="):
				prm.default = _expr()
		f.params.append(prm)
		_take(",")
	_take(")")
	if _take("->"):
		f.ret = _type()
	if not _take(":") and _at_end():
		# a header with no colon and nothing under it: an @abstract function, which has no body to convert
		f["abstract"] = true
		f["text"] = String(ln.src)
		f["body_text"] = ""
		_li += 1
		return f
	var body_from := _li + 1
	var inline := not _at_end()
	f.body = _body(int(ln.indent))
	if inline:
		f["body_text"] = String(ln.src).substr(String(ln.src).find(":", String(ln.src).rfind(")")) + 1).strip_edges()
	elif body_from < _li:
		f["body_text"] = _text(body_from, _li, -1, true)   # (with every comment in it: a body kept whole keeps them)
	else:
		f["body_text"] = "pass"
	return f


## The statements after a header's colon: the rest of the line, or the indented block below.
func _body(indent: int) -> Array:
	if not _at_end() and _peek().t == "kw" and _peek().v == "if":
		# `pattern: if condition: statement` on one line (a match arm may be written so), or `else: if condition:`
		# with its block underneath, which the lines that follow at this depth (elif, else) then belong to
		var ln: Dictionary = _lines[_li]
		var start := _li
		_p += 1
		var st := {"k": "if", "branches": [], "else": [], "line": ln.line}
		var cond: Variant = _expr()
		_take(":")
		st.branches.append([cond, _body(indent)])
		while _li < _lines.size() and int(_lines[_li].indent) == indent:
			_t = _lines[_li].toks
			_p = 0
			if _take("elif"):
				var c2: Variant = _expr()
				_take(":")
				st.branches.append([c2, _body(indent)])
			elif _take("else"):
				_take(":")
				st["else"] = _body(indent)
				break
			else:
				break
		var first_line := String(ln.src)
		var text := first_line.substr(maxi(first_line.find("if "), 0))
		if _li > start + 1:
			text += "\n" + _text(start + 1, _li, int(_lines[start].level))
		st["src"] = text.get_slice("\n", 0)
		st["text"] = text
		if cond == null or st.branches[0][1].is_empty():
			return [{"k": "raw", "src": String(st.src), "text": text, "line": ln.line, "why": "syntax"}]
		return [st]
	if not _at_end():
		var out := []
		while not _at_end():
			var st := _simple_stmt(_lines[_li])
			if st != null:
				out.append(st)
			if not _take(";"):
				break
		_li += 1
		return out
	_li += 1
	if _li >= _lines.size() or int(_lines[_li].indent) <= indent:
		return []
	return _block(int(_lines[_li].indent))


func _block(indent: int) -> Array:
	var out := []
	while _li < _lines.size() and int(_lines[_li].indent) >= indent:
		var ln: Dictionary = _lines[_li]
		if int(ln.indent) > indent:
			# an indented block after a plain statement: the body of a lambda that statement ends with
			var from := _li
			while _li < _lines.size() and int(_lines[_li].indent) > indent:
				_li += 1
			var body_text := PackedStringArray()
			var body_src := _text(from, _li, -1, true)   # (the lambda's body with its comments)
			var body_inside := T.lines_in_string(body_src)
			var body_parts := body_src.split("\n")
			for k in body_parts.size():
				body_text.append(body_parts[k] if body_inside[k] else "\t" + body_parts[k])
			if out.is_empty():
				notes.append("line %d: unexpected indented block kept as text" % ln.line)
				out.append({"k": "raw", "src": String(ln.src), "text": _text(from, _li), "line": ln.line, "why": "indentation"})
			else:
				var prev: Dictionary = out[-1]
				var head := String(prev.get("line_src", prev.get("text", prev.src)))
				var whole := head + "\n" + "\n".join(body_text)
				out[-1] = {"k": "raw", "src": String(prev.src), "text": whole, "line": prev.get("line", ln.line), "why": "a multi-line lambda"}
				var lifted := _lift_lambdas(whole)
				if lifted != "":
					var toks := []
					_scan(lifted, toks, 0)
					_t = toks
					_p = 0
					var st: Variant = _simple_stmt({"src": head, "line": prev.get("line", ln.line)})
					if st != null and st.k != "raw" and _at_end():
						st["text"] = whole
						st["src"] = head
						if st.k == "var":
							st["line_src"] = whole
						out[-1] = st
			continue
		_t = ln.toks
		_p = 0
		var tok := _peek()
		if tok.t == "kw" and tok.v == "if":
			out.append(_if_stmt(ln))
		elif tok.t == "kw" and tok.v == "for":
			_p += 1
			var st := {"k": "for", "var": String(_next().v), "iter": null, "body": [], "src": ln.src, "line": ln.line}
			if _take(":"):
				st["var_type"] = _type()   # for item: Type in ...
			_take("in")
			st.iter = _expr()
			_take(":")
			var start := _li
			st.body = _body(indent)
			st["text"] = _text(start, _li)
			out.append(st)
		elif tok.t == "kw" and tok.v == "while":
			_p += 1
			var st := {"k": "while", "cond": _expr(), "body": [], "src": ln.src, "line": ln.line}
			_take(":")
			var start := _li
			st.body = _body(indent)
			st["text"] = _text(start, _li)
			out.append(st)
		elif tok.t == "kw" and tok.v == "match":
			out.append(_match_stmt(ln))
		else:
			var first := out.size()
			if String(ln.src).contains("\n"):
				# lambdas that span lines inside the statement's brackets are parsed on their own
				var lifted := _lift_lambdas(String(ln.src))
				if lifted != "":
					var toks := []
					_scan(lifted, toks, 0)
					_t = toks
					_p = 0
			while not _at_end():
				var st := _simple_stmt(ln)
				if st != null:
					out.append(st)
				if not _take(";"):
					break
			if _at_end() and out.size() == first + 1:
				if out[first].k == "var":
					out[first]["line_src"] = ln.src
				else:
					out[first]["src"] = ln.src   # exactly as written
			if not _at_end():
				# something this parser does not know: keep the whole line as code
				out.pop_back()
				out.append({"k": "raw", "src": ln.src, "text": ln.src, "line": ln.line, "why": "syntax"})
			_li += 1
	return out


## A lambda on one line: `func(a, b) -> T: statement`. Returns null when it is anything else.
func _inline_lambda(text: String) -> Variant:
	var lam := {"k": "lambda", "params": [], "ret": "", "body": [], "body_text": "pass", "src": text}
	if _peek().t == "id":
		_p += 1   # a named lambda: the name is only for error messages
	if not _take("("):
		return null
	while not _at_end() and not _is(")"):
		var prm := {"name": String(_next().v), "type": "", "default": null}
		if _take(":=") or (_is(":") and _peek(1).t == "op" and _peek(1).v == "=" and _take(":") and _take("=")):   # ":=", or ": ="
			prm.default = _expr()
			prm["infer"] = true
		else:
			if _take(":"):
				prm.type = _type()
			if _take("="):
				prm.default = _expr()
		lam.params.append(prm)
		_take(",")
	if not _take(")"):
		return null
	if _take("->"):
		lam.ret = _type()
	if not _take(":"):
		return null
	var at := _p
	var st: Variant = _simple_stmt({"src": "", "line": 0})
	if st == null or st.k == "raw" or _is(";"):
		return null
	st["src"] = _source(at, _p)   # as written: a node path keeps its $, a string its quotes
	lam.body = [st]
	lam.body_text = String(st.src)
	return lam


func _tabs(line: String) -> int:
	var n := 0
	while n < line.length() and line[n] == "\t":
		n += 1
	return n


## Where a lambda's body ends inside the text that follows its header: at the first closing bracket the body
## did not open, or at a comma outside all brackets (the next argument of the call the lambda sits in; a
## `match` pattern line may hold such a comma, and ends in a colon). -1 when the whole text is body.
func _unopened_close(text: String) -> int:
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
		elif c == "#":
			var nl := text.find("\n", i)
			if nl == -1:
				break
			i = nl
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
			if depth < 0:
				return i
		elif c == "," and depth == 0:
			var line_end := text.find("\n", i)
			var rest := text.substr(i, (line_end if line_end != -1 else text.length()) - i)
			if not _strip_comment(rest).strip_edges().ends_with(":"):
				return i
		i += 1
	return -1


## The text with whatever is inside strings and comments replaced, character for character, so that brackets,
## colons and words in them are not taken for code. Quotes and line breaks stay where they are.
func _blank_strings(text: String) -> String:
	var out := PackedStringArray()
	var i := 0
	var n := text.length()
	var from := 0
	while i < n:
		var c := text[i]
		if c == "#":
			var nl := text.find("\n", i)
			if nl == -1:
				nl = n
			out.append(text.substr(from, i - from))
			out.append(" ".repeat(nl - i))
			i = nl
			from = i
			continue
		if c == "\"" or c == "'":
			var q := c
			if text.substr(i, 3) == c + c + c:
				q = c + c + c
			var j := i + q.length()
			while j < n and text.substr(j, q.length()) != q:
				if text[j] == "\\":
					j += 1
				j += 1
			j = mini(j, n)
			out.append(text.substr(from, i + q.length() - from))
			for k in range(i + q.length(), j):
				out.append("\n" if text[k] == "\n" else "_")
			from = j
			i = j + q.length()
			continue
		i += 1
	out.append(text.substr(from))
	return "".join(out)


## Takes lambdas that span several lines out of a statement's text: each becomes a placeholder name that
## _atom turns back into the parsed lambda. Returns the shortened text, or "" when there is nothing to lift.
func _lift_lambdas(text: String) -> String:
	if not text.contains("func"):
		return ""
	var lines := text.split("\n")
	# what is inside a string or a comment is never a lambda: headers are looked for with those blanked out
	var blank_lines := _blank_strings(text).split("\n")
	var inside := T.lines_in_string(text)
	var header := RegEx.create_from_string("func\\s*[A-Za-z_0-9]*\\s*\\(")
	var out := PackedStringArray()
	var found := false
	var i := 0
	while i < lines.size():
		var line := lines[i]
		var stripped := blank_lines[i].strip_edges(false, true)
		var at := -1
		if stripped.ends_with(":") and i + 1 < lines.size():
			for m in header.search_all(stripped):
				at = m.get_start()
		if at == -1:
			out.append(line)
			i += 1
			continue
		stripped = line.substr(0, stripped.length())
		# The body is the lines after the header that are indented deeper than the statement the lambda sits in
		# (the engine's rule: inside brackets a lambda's body is an indented block of its own, and the first line
		# that is not indented deeper than the statement's first line ends it, as `, "next": ...`, `)` or `]`
		# do). How far the header's own line is indented says nothing: it may be a continuation line.
		var end := _body_end(blank_lines, inside, i + 1)
		# The bracket that closes the call the lambda sits in may also come straight after its last statement
		# (`... false))` or `... x), CONNECT_ONE_SHOT)`): from the first bracket the body does not open, the
		# text belongs to the statement around it.
		var joined := "\n".join(lines.slice(i + 1, end))
		var cut := _unopened_close("\n".join(blank_lines.slice(i + 1, end)))
		var after := "\n".join(lines.slice(end))
		var tail := ""
		if cut != -1:
			tail = joined.substr(cut) + (("\n" + after) if end < lines.size() else "")
			joined = joined.substr(0, cut)
		elif end < lines.size():
			tail = "\n" + after
		var body := PackedStringArray()
		var base := -1
		var joined_inside := T.lines_in_string(joined)
		var joined_lines := joined.split("\n")
		for k in joined_lines.size():
			# (how far the body is indented is read from its first line of code, not from a comment above it)
			if not joined_inside[k] and joined_lines[k].strip_edges() != "" and not joined_lines[k].strip_edges().begins_with("#"):
				base = _tabs(joined_lines[k])
				break
		for k in joined_lines.size():
			var body_line := joined_lines[k]
			if joined_inside[k]:
				body.append(body_line)   # a line of a string that runs over several lines: exactly as written
				continue
			if body_line.strip_edges() == "":
				if not body.is_empty():
					body.append("")   # a blank line the person left in the body: kept (see COMMENTS)
				continue
			if base == -1:
				base = _tabs(body_line)
			body_line = body_line.substr(mini(base, _tabs(body_line)))
			body.append("\t" + (body_line if (k + 1 < joined_inside.size() and joined_inside[k + 1]) else body_line.strip_edges(false, true)))
		var head := stripped.substr(at)
		var open := head.find("(")
		var sub: Dictionary = {}
		if not body.is_empty() and open != -1:
			var parser = get_script().new()
			sub = parser.parse("func __sc_lambda%s\n%s\n" % [head.substr(open), "\n".join(body)])
		if sub.is_empty() or sub.funcs.size() != 1 or not sub.extra.is_empty():
			out.append(line)
			i += 1
			continue
		var fn: Dictionary = sub.funcs[0]
		var key := "__sc_lambda_%d__" % _lambdas.size()
		_lambdas[key] = {"k": "lambda", "params": fn.params, "ret": fn.ret, "body": fn.body, "body_text": String(fn.get("body_text", "pass")),
			"src": head + "\n" + "\n".join(body)}
		# what follows the body is the statement again, and may hold more lambdas that span lines
		var more := _lift_lambdas(tail) if tail.contains("func") else ""
		out.append(line.substr(0, at) + key + (more if more != "" else tail))
		found = true
		break
	return "\n".join(out) if found else ""


## The first line from `from` on that ends a lambda body begun on the line before: one that is not inside a
## string, holds code, is outside any bracket the body opened, and is not indented deeper than the statement
## (in a statement's text the lines after the first are indented relative to it). lines.size() if none.
func _body_end(blank_lines: PackedStringArray, inside: Array, from: int) -> int:
	var depth := 0
	for k in range(from, blank_lines.size()):
		var bl := blank_lines[k]
		if not (k < inside.size() and inside[k]) and bl.strip_edges() != "" and depth == 0:
			if bl[0] != "\t" and bl[0] != " ":
				return k
		for c in bl:
			if c in ["(", "[", "{"]:
				depth += 1
			elif c in [")", "]", "}"]:
				depth -= 1
		if depth < 0:
			return k + 1   # the body ends inside this line, at a bracket it did not open (see _unopened_close)
	return blank_lines.size()


## `match subject:` with its arms. Each arm is {pattern (as written), body, plain}; an arm that binds names
## (`var x`) is not plain; a `when` guard is part of the pattern text. If anything is not understood the whole statement is raw text.
func _match_stmt(ln: Dictionary) -> Dictionary:
	var indent := int(ln.indent)
	var start := _li
	_p += 1
	var subject: Variant = _expr()
	var ok := subject != null and _take(":") and _at_end()
	_li += 1
	var arms := []
	if _li < _lines.size() and int(_lines[_li].indent) > indent:
		var arm_indent := int(_lines[_li].indent)
		while _li < _lines.size() and int(_lines[_li].indent) >= arm_indent:
			var al: Dictionary = _lines[_li]
			_t = al.toks
			_p = 0
			var depth := 0
			var colon := -1
			var plain := true
			for i in _t.size():
				var tk: Dictionary = _t[i]
				if tk.t == "op" and String(tk.v) in ["(", "[", "{"]:
					depth += 1
				elif tk.t == "op" and String(tk.v) in [")", "]", "}"]:
					depth -= 1
				elif tk.t == "op" and tk.v == ":" and depth == 0:
					colon = i
					break
				elif tk.t == "kw" and tk.v == "var":
					plain = false   # the pattern binds a name: the arm's body would need it as a variable
			var pattern := _pattern_text(String(al.src))
			if int(al.indent) != arm_indent or colon == -1 or pattern == "":
				ok = false
				_li += 1
				continue
			_p = colon + 1
			arms.append({"pattern": pattern, "body": _body(arm_indent), "plain": plain, "line": al.line})
	else:
		ok = false
	var text := _text(start, _li)
	if not ok or arms.is_empty():
		return {"k": "raw", "src": ln.src, "text": text, "line": ln.line, "why": "match"}
	return {"k": "match", "subject": subject, "arms": arms, "src": ln.src, "text": text, "line": ln.line}


## The pattern of a match arm: its line up to the colon that ends it (not one inside a string or brackets).
func _pattern_text(src: String) -> String:
	var depth := 0
	var quote := ""
	var i := 0
	while i < src.length():
		var c := src[i]
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
		elif c == ":" and depth == 0:
			return src.substr(0, i).strip_edges()
		i += 1
	return ""


## Source text of logical lines [from, to), re-indented with tabs relative to the first one (or to the block
## depth `base_level`), one tab for each block a line is nested in, however the file indents its blocks.
## The comments a person wrote inside the lines are part of the text: those above each line after the first and
## at the end of each line after the first, and those after the last line that are indented deeper than `deep`
## (the end of the last block inside it; default: deeper than the first line). With `with_first`, the comments
## above and at the end of the first line too (a function body, a lambda's body); with `first_tail`, the one at
## the end of the first line (a declaration kept as written).
func _text(from: int, to: int, base_level := -1, with_first := false, first_tail := false, deep := -1) -> String:
	var out := PackedStringArray()
	var base := int(_lines[from].level) if base_level < 0 else base_level
	var last := mini(to, _lines.size())
	for i in range(from, last):
		var ln: Dictionary = _lines[i]
		if i > from or with_first:
			for it in ln.get("pre", []):
				out.append(_comment_line(it, base))
		var pad := "\t".repeat(maxi(int(ln.level) - base, 0))
		var src := String(ln.src)
		if i > from or with_first or first_tail:
			src += String(ln.get("tail", ""))
		var inside := T.lines_in_string(src)
		var parts := src.split("\n")
		for k in parts.size():
			out.append(parts[k] if inside[k] else pad + parts[k])   # the lines of a string stay as they are
	if last > from:
		# (a body's text ends where its block does: what is deeper than the line that opened it)
		var threshold := deep if deep >= 0 else (int(_lines[from].level) - (1 if with_first else 0))
		var after: Array = _lines[last].get("pre", []) if last < _lines.size() else _end_items
		var upto := _deep_prefix(after, threshold)
		for k in upto:
			out.append(_comment_line(after[k], base))
	return "\n".join(out)


## A comment item of a logical line's `pre` as a line of text whose blocks are counted from `base`.
func _comment_line(it: Dictionary, base: int) -> String:
	if bool(it.get("blank", false)):
		return ""
	return "\t".repeat(maxi(int(it.level) - base, 0)) + String(it.text)


## How many of `items` (the comments above a line) end the block before it: the leading comments indented deeper
## than `level`, with the blank lines between them (not the blank lines after the last of them).
func _deep_prefix(items: Array, level: int) -> int:
	var upto := 0
	for k in items.size():
		var it: Dictionary = items[k]
		if bool(it.get("blank", false)):
			continue
		if int(it.level) <= level:
			break
		upto = k + 1
	return upto


func _if_stmt(ln: Dictionary) -> Dictionary:
	var indent := int(ln.indent)
	var start := _li
	var st := {"k": "if", "branches": [], "else": [], "src": ln.src, "line": ln.line}
	_p += 1
	var cond: Variant = _expr()
	_take(":")
	st.branches.append([cond, _body(indent)])
	# the lines of its `elif`s and its `else:` (line -> the branch's place in `branches`, or "else"): the comment at
	# the end of one is kept for that line (arm_tails, same keys; see _attach_comments)
	var arm_lines := {}
	while _li < _lines.size() and int(_lines[_li].indent) == indent:
		_t = _lines[_li].toks
		_p = 0
		var arm_line := int(_lines[_li].line)
		if _take("elif"):
			var c2: Variant = _expr()
			_take(":")
			arm_lines[arm_line] = st.branches.size()
			st.branches.append([c2, _body(indent)])
		elif _take("else"):
			_take(":")
			arm_lines[arm_line] = "else"
			st["else"] = _body(indent)
			break
		else:
			break
	if not arm_lines.is_empty():
		st["arm_lines"] = arm_lines
	st["text"] = _text(start, _li)
	return st


func _simple_stmt(ln: Dictionary) -> Variant:
	var tok := _peek()
	if tok.t == "kw":
		match String(tok.v):
			"pass":
				_p += 1
				return {"k": "pass", "src": "pass", "line": ln.line}
			"break":
				_p += 1
				return {"k": "break", "src": "break", "line": ln.line}
			"continue":
				_p += 1
				return {"k": "continue", "src": "continue", "line": ln.line}
			"return":
				_p += 1
				var e: Variant = null
				if not _at_end() and not _is(";"):
					e = _expr()
				return {"k": "return", "e": e, "src": "return" + ((" " + unparse(e)) if e != null else ""), "line": ln.line}
			"var", "const":
				var v := _var_decl()
				v["k"] = "var"
				v["src"] = "var %s%s%s" % [v.name, (": " + v.type) if v.type != "" else "", (" = " + v.init_src) if v.init != null else ""]
				v["line"] = ln.line
				return v
	var target: Variant = _expr()
	if target == null:
		_p = _t.size()
		return {"k": "raw", "src": ln.src, "text": ln.src, "line": ln.line, "why": "syntax"}
	var op := _peek()
	if op.t == "op" and String(op.v) in ["=", "+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="]:
		_p += 1
		var value: Variant = _expr()
		return {"k": "assign", "target": target, "op": String(op.v), "value": value,
			"src": "%s %s %s" % [unparse(target), op.v, unparse(value)], "line": ln.line}
	return {"k": "expr", "e": target, "src": unparse(target), "line": ln.line}


# ---------------------------------------------------------------- expressions

## Expressions are read the way GDScript reads them: the same order of operators (gdscript_parser.cpp's table),
## each binary operator taking what stands to its left first. `as` binds least of all, then the ternary `if`,
## `or`, `and`, `not`, `in`, the comparisons, `|`, `^`, `&`, the shifts, `+ -`, `* / %`, a sign, `~`, `**`, `is`.
const PREC_CAST := 2
const PREC_TERNARY := 3
const PREC_NOT := 6
const PREC_IN := 7
const PREC_COMPARISON := 8
const PREC_SIGN := 15
const PREC_BIT_NOT := 16
const PREC_POWER := 17
const PREC_IS := 18
const BINARY := {"or": 4, "||": 4, "and": 5, "&&": 5, "in": 7, "==": 8, "!=": 8, "<": 8, ">": 8, "<=": 8, ">=": 8,
	"|": 9, "^": 10, "&": 11, "<<": 12, ">>": 12, "+": 13, "-": 13, "*": 14, "/": 14, "%": 14, "**": 17}


func _expr() -> Variant:
	return _climb(PREC_CAST)


## How tightly the operator at the cursor binds what is to its left; 0 when there is no operator there.
func _binding() -> int:
	var tok := _peek()
	if tok.t != "op" and tok.t != "kw":
		return 0
	var v := String(tok.v)
	if BINARY.has(v):
		return int(BINARY[v])
	match v:
		"as": return PREC_CAST
		"if": return PREC_TERNARY
		"is": return PREC_IS
		"not": return PREC_IN if (_peek(1).t == "kw" and _peek(1).v == "in") else 0
	return 0


func _climb(least: int) -> Variant:
	var a: Variant = _prefix()
	while a != null:
		var prec := _binding()
		if prec == 0 or prec < least:
			break
		var v := String(_next().v)
		match v:
			"as":
				a = {"k": "as", "a": a, "t": _type()}
			"if":
				var c: Variant = _climb(PREC_TERNARY)
				_take("else")
				a = {"k": "tern", "c": c, "a": a, "b": _climb(PREC_TERNARY)}
			"is":
				var negated := _take("not")
				a = {"k": "is", "a": a, "t": _type()}
				if negated:
					a = {"k": "un", "op": "not", "a": a}
			"not":
				_p += 1   # the "in" of "not in"
				a = {"k": "un", "op": "not", "a": {"k": "bin", "op": "in", "a": a, "b": _climb(PREC_IN + 1)}}
			_:
				var op := "or" if v == "||" else ("and" if v == "&&" else v)
				a = {"k": "bin", "op": op, "a": a, "b": _climb(prec + 1)}
	return a


## An operator written in front of its operand, or the operand itself.
func _prefix() -> Variant:
	if _is("not") or (_is("!") and not (_peek(1).t == "op" and _peek(1).v == "=")):
		_p += 1
		return {"k": "un", "op": "not", "a": _climb(PREC_NOT)}
	if _is("-") or _is("+"):
		var op := String(_next().v)
		var a: Variant = _climb(PREC_SIGN)
		return a if op == "+" else {"k": "un", "op": "-", "a": a}
	if _is("~"):
		_p += 1
		return {"k": "un", "op": "~", "a": _climb(PREC_BIT_NOT)}
	return _postfix()


func _postfix() -> Variant:
	var a: Variant = _atom()
	while a != null:
		if _is("."):
			_p += 1
			a = {"k": "attr", "obj": a, "name": String(_next().v)}
		elif _is("("):
			_p += 1
			a = {"k": "call", "fn": a, "args": _list(")")}
		elif _is("["):
			_p += 1
			var i: Variant = _expr()
			_take("]")
			a = {"k": "index", "obj": a, "i": i}
		else:
			break
	return a


func _list(close: String) -> Array:
	var out := []
	while not _at_end() and not _is(close):
		out.append(_expr())
		if not _take(","):
			break
	_take(close)
	return out


func _atom() -> Variant:
	var tok := _next()
	match String(tok.t):
		"num":
			return {"k": "num", "v": String(tok.v), "f": bool(tok.get("f", false))}
		"str":
			return {"k": "str", "v": String(tok.v)}
		"node":
			return {"k": "node", "path": String(tok.v)}
		"id":
			if _lambdas.has(String(tok.v)):
				_saw_raw = true
				return _lambdas[String(tok.v)]
			return {"k": "name", "v": String(tok.v)}
		"kw":
			match String(tok.v):
				"true", "false":
					return {"k": "bool", "v": String(tok.v)}
				"null":
					return {"k": "null"}
				"self":
					return {"k": "self"}
				"super":
					return {"k": "name", "v": "super"}
				"await":
					var awaited: Variant = _postfix()
					if awaited != null:
						return {"k": "await", "a": awaited}
					_saw_raw = true
					return {"k": "raw", "src": "await"}
				"func":
					# a lambda written on one line, up to where the enclosing brackets or argument ends
					var from := _p
					var depth := 0
					while not _at_end():
						var nx := _peek()
						if nx.t == "op" and String(nx.v) in ["(", "[", "{"]:
							depth += 1
						elif nx.t == "op" and String(nx.v) in [")", "]", "}"]:
							if depth == 0:
								break
							depth -= 1
						elif nx.t == "op" and nx.v == "," and depth == 0:
							break
						_p += 1
					_saw_raw = true
					var stop := _p
					var text := _source(from - 1, stop)
					_p = from
					var lam := _inline_lambda(text)
					if lam != null and _p == stop:
						return lam
					_p = stop
					return {"k": "raw", "src": text}
		"op":
			match String(tok.v):
				"(":
					var e: Variant = _expr()
					_take(")")
					return {"k": "paren", "a": e} if e != null else null
				"[":
					return {"k": "array", "items": _list("]")}
				"{":
					var pairs := []
					while not _at_end() and not _is("}"):
						var key: Variant = _expr()
						if _take("="):
							# {name = value}: the key is the name as a string
							if key is Dictionary and key.k == "name":
								key = {"k": "str", "v": "\"%s\"" % String(key.v)}
						elif not _take(":"):
							break
						pairs.append([key, _expr()])
						if not _take(","):
							break
					_take("}")
					return {"k": "dict", "pairs": pairs}
	_p -= 1
	return null


# ---------------------------------------------------------------- back to text

## The expression as GDScript text that reads back as the same expression. `least` is how tightly the place
## it goes binds (0: on its own, as an argument or a value); brackets are added only where the order of
## operators would otherwise change what it means.
static func unparse(e: Variant, least := 0) -> String:
	if e == null:
		return "null"
	var text := ""
	var prec := 99   # how tightly this expression holds together
	match String(e.k):
		"num":
			text = String(e.v)
			if text.begins_with("-"):
				prec = PREC_SIGN   # "-2 ** 2" squares -2, but "(-2).x" and "(-2) is int" need the brackets
		"str", "bool":
			text = String(e.v)
		"null":
			text = "null"
		"self":
			text = "self"
		"name":
			text = String(e.v)
		"node":
			var path := String(e.path)
			if path.begins_with("%"):
				text = path
			else:
				text = "$" + (path if path.is_valid_identifier() or not path.contains(" ") else "\"%s\"" % path)
		"paren":
			text = "(%s)" % unparse(e.a)
		"un":
			if e.op == "not":
				text = "not %s" % unparse(e.a, PREC_NOT)
				prec = PREC_NOT
			elif e.op == "~":
				text = "~%s" % unparse(e.a, PREC_BIT_NOT)
				prec = PREC_BIT_NOT
			else:
				var operand := unparse(e.a, PREC_SIGN)
				# a sign straight in front of a digit would be read as part of that number
				if e.a != null and e.a.k != "num" and operand != "" and (operand[0].is_valid_int() or operand[0] == "."):
					operand = "(%s)" % operand
				text = String(e.op) + operand
				prec = PREC_SIGN
		"bin":
			prec = int(BINARY.get(String(e.op), 1))
			text = "%s %s %s" % [unparse(e.a, prec), e.op, unparse(e.b, prec + 1)]
		"tern":
			text = "%s if %s else %s" % [unparse(e.a, PREC_TERNARY + 1), unparse(e.c, PREC_TERNARY + 1), unparse(e.b, PREC_TERNARY)]
			prec = PREC_TERNARY
		"await":
			text = "await %s" % unparse(e.a, PREC_IS + 1)
			prec = PREC_IS + 1
		"lambda":
			text = String(e.src)
			prec = 1
		"is":
			text = "%s is %s" % [unparse(e.a, PREC_IS), e.t]
			prec = PREC_IS
		"as":
			text = "%s as %s" % [unparse(e.a, PREC_CAST), e.t]
			prec = PREC_CAST
		"attr":
			text = "%s.%s" % [unparse(e.obj, 20), e.name]
		"index":
			text = "%s[%s]" % [unparse(e.obj, 20), unparse(e.i)]
		"call":
			var args := PackedStringArray()
			for a in e.args:
				args.append(unparse(a))
			text = "%s(%s)" % [unparse(e.fn, 20), ", ".join(args)]
		"array":
			var items := PackedStringArray()
			for a in e.items:
				items.append(unparse(a))
			text = "[%s]" % ", ".join(items)
		"dict":
			var pairs := PackedStringArray()
			for pr in e.pairs:
				pairs.append("%s: %s" % [unparse(pr[0]), unparse(pr[1])])
			text = "{%s}" % ", ".join(pairs)
		"raw":
			text = String(e.src)
			prec = 1
		_:
			return "null"
	return "(%s)" % text if (least > 0 and prec < least) else text
