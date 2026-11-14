@tool
extends RefCounted
## A small GDScript parser for the Blueprint importer. It understands the everyday subset of the language
## (members, functions, if / for / while, assignments, calls, operators) and keeps the source text of anything
## else, so the importer can carry it over as a code node instead of guessing.
##
## parse(source) -> {extends, class_name, tool, signals, vars, funcs, enums, notes}
##   var  = {name, type, init (expr or null), init_src, export, onready, const, group, line}
##   func = {name, params: [{name, type, default (expr or null)}], ret, body: [stmt], static, line}
##   stmt = {k: var|assign|expr|if|for|while|return|pass|break|continue|raw, src, line, ...}
##   expr = {k: num|str|name|bool|null|self|node|un|bin|tern|call|attr|index|array|dict|as|raw, ...}

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


# ---------------------------------------------------------------- tokenizer

## Splits the source into logical lines (brackets and backslashes continue a line) of tokens.
func _tokenize(source: String) -> void:
	_lines = []
	var raw := source.replace("\r\n", "\n").split("\n")
	var i := 0
	while i < raw.size():
		var first := i
		var text := raw[i]
		var lead := raw[first]
		var base_tabs := 0
		while base_tabs < lead.length() and lead[base_tabs] == "\t":
			base_tabs += 1
		# keep taking lines while a bracket, a triple-quoted string or a trailing backslash is open
		while _open(text) and i + 1 < raw.size():
			i += 1
			var more := raw[i]
			var cut := 0
			while cut < base_tabs and cut < more.length() and more[cut] == "\t":
				cut += 1
			if text.strip_edges(false, true).ends_with("\\"):
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
		_lines.append({"indent": indent, "toks": toks, "src": _strip_comment(text).strip_edges(), "line": first + 1})


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
			i = nl
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		if c != " " and c != "\t" and c != "\n":
			last = c
		i += 1
	return depth > 0 or quote != "" or last == "\\"


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
			var close := text.find(text.substr(i, 3), i + 3)
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
	while i < n:
		var c := text[i]
		if c == " " or c == "\t" or c == "\n":
			i += 1
			continue
		if c == "#":
			var line_end := text.find("\n", i)
			if line_end == -1:
				break
			i = line_end
			continue
		# strings, with the &"name" / ^"path" prefixes
		var prefix := ""
		if (c == "&" or c == "^") and i + 1 < n and (text[i + 1] == "\"" or text[i + 1] == "'"):
			prefix = c
			i += 1
			c = text[i]
		if c == "\"" or c == "'":
			if text.substr(i, 3) == c + c + c:
				var close := text.find(c + c + c, i + 3)
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
		# $Node/Path, $"Quoted/Path", %UniqueName
		if c == "$" or (c == "%" and i + 1 < n and (_is_id_start(text[i + 1])) and (toks.is_empty() or _is_operator_tok(toks[-1]))):
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
		if c.is_valid_int() or (c == "." and i + 1 < n and text[i + 1].is_valid_int()):
			var j := i
			var is_float := false
			if c == "0" and i + 1 < n and (text[i + 1] == "x" or text[i + 1] == "b"):
				j = i + 2
				while j < n and (text[j].is_valid_hex_number() or text[j] == "_"):
					j += 1
			else:
				while j < n and (text[j].is_valid_int() or text[j] == "_" or text[j] == "." or text[j] == "e"
						or ((text[j] == "-" or text[j] == "+") and text[j - 1] == "e")):
					if text[j] == "." or text[j] == "e":
						if text[j] == "." and j + 1 < n and _is_id_start(text[j + 1]) and text[j + 1] != "e":
							break   # 1.method()
						is_float = true
					j += 1
			toks.append({"t": "num", "v": text.substr(i, j - i).replace("_", ""), "f": is_float})
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
	return depth


func _is_id_start(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c.unicode_at(0) > 127


func _is_id_char(c: String) -> bool:
	return _is_id_start(c) or c.is_valid_int()


func _is_operator_tok(tok: Dictionary) -> bool:
	return (tok.t == "op" and not tok.v in [")", "]", "}"]) or (tok.t == "kw" and tok.v in ["return", "and", "or", "not", "in", "if", "else"])


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
	_tokenize(source)
	_li = 0
	var out := {"extends": "", "class_name": "", "tool": false, "signals": [], "vars": [], "funcs": [], "enums": [], "extra": [],
		"notes": notes, "uses_groups": false}
	var group := ""
	var pending := {"export": false, "onready": false, "plain": true, "text": PackedStringArray()}
	while _li < _lines.size():
		var ln: Dictionary = _lines[_li]
		_t = ln.toks
		_p = 0
		if ln.indent > 0:
			notes.append("line %d: unexpected indented line kept as text: %s" % [ln.line, ln.src])
			out.extra.append(ln.src)
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
			# a line of annotations only: it belongs to the next declaration
			if ln.src != "@tool":
				pending.text.append(ln.src)
			_li += 1
			continue
		var tok := _peek()
		var is_static := false
		if tok.t == "kw" and tok.v == "static":
			_p += 1
			is_static = true
			tok = _peek()
		if tok.t == "kw" and tok.v == "extends":
			_p += 1
			out.extends = String(_next().v).trim_prefix("\"").trim_suffix("\"")
			while _take("."):
				out.extends += "." + String(_next().v)
			_li += 1
		elif tok.t == "kw" and tok.v == "class_name":
			_p += 1
			out.class_name = String(_next().v)
			if _take("extends"):
				out.extends = String(_next().v)
			if not pending.text.is_empty():
				out.extra.append("\n".join(pending.text))   # @icon and friends
				notes.append("line %d: the annotation above class_name is not carried over: %s" % [ln.line, " ".join(pending.text)])
				out.extra.pop_back()
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray()}
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
			# the declaration exactly as written, annotations included
			var text := PackedStringArray(pending.text)
			text.append(_text(start_li, _li))
			v["text"] = "\n".join(text)
			out.vars.append(v)
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray()}
		elif tok.t == "kw" and tok.v == "func":
			var f := _func_decl(ln)
			f["static"] = is_static
			f["pre"] = Array(pending.text)
			var first_line := String(ln.src)
			if ann_start != _p and first_line.begins_with("@"):
				f.pre.append(first_line.substr(0, first_line.find("func ")).strip_edges().trim_suffix("static").strip_edges())
			out.funcs.append(f)
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray()}
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
			var text := PackedStringArray(pending.text)
			text.append(_text(start_li, _li))
			out.extra.append("\n".join(text))
			if what != "enum":
				notes.append("line %d: %s kept as written: %s" % [ln.line, what, ln.src])
			pending = {"export": false, "onready": false, "plain": true, "text": PackedStringArray()}
	return out


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
		if _take(":"):
			if not _is("=") and not _at_end() and not (_peek().t == "id" and String(_peek().v) in ["set", "get"]):
				v.type = _type()
		if _take("="):
			v.init = _expr()
			v.init_src = unparse(v.init)
	v["has_raw"] = _saw_raw
	return v


func _func_decl(ln: Dictionary) -> Dictionary:
	_p += 1
	var f := {"name": String(_next().v), "params": [], "ret": "", "body": [], "line": ln.line}
	_take("(")
	while not _at_end() and not _is(")"):
		var prm := {"name": String(_next().v), "type": "", "default": null}
		if _take(":="):
			prm.default = _expr()
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
	_take(":")
	var body_from := _li + 1
	var inline := not _at_end()
	f.body = _body(int(ln.indent))
	if inline:
		f["body_text"] = String(ln.src).substr(String(ln.src).find(":", String(ln.src).rfind(")")) + 1).strip_edges()
	elif body_from < _li:
		f["body_text"] = _text(body_from, _li)
	else:
		f["body_text"] = "pass"
	return f


## The statements after a header's colon: the rest of the line, or the indented block below.
func _body(indent: int) -> Array:
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
			for part in _text(from, _li).split("\n"):
				body_text.append("\t" + part)
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
				_type()
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
		if _take(":="):
			prm.default = _expr()
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
	var words := PackedStringArray()
	for i in range(at, _p):
		words.append(String(_t[i].v))
	st["src"] = " ".join(words)
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


## Takes lambdas that span several lines out of a statement's text: each becomes a placeholder name that
## _atom turns back into the parsed lambda. Returns the shortened text, or "" when there is nothing to lift.
func _lift_lambdas(text: String) -> String:
	if not text.contains("func"):
		return ""
	var lines := text.split("\n")
	var header := RegEx.create_from_string("func\\s*[A-Za-z_0-9]*\\s*\\(")
	var out := PackedStringArray()
	var found := false
	var i := 0
	while i < lines.size():
		var line := lines[i]
		var stripped := line.strip_edges(false, true)
		var at := -1
		if stripped.ends_with(":") and i + 1 < lines.size():
			for m in header.search_all(stripped):
				at = m.get_start()
		if at == -1:
			out.append(line)
			i += 1
			continue
		# Everything after the header belongs to the body until the call the lambda sits in goes on (see
		# _unopened_close). How far the header's own line is indented says nothing: it may be a continuation line.
		var j := lines.size()
		var taken := lines.slice(i + 1)
		# The bracket that closes the call the lambda sits in may come straight after its last statement
		# (`... false))` or `... x), CONNECT_ONE_SHOT)`): from the first bracket the body does not open, the
		# text belongs to the statement around it.
		var joined := "\n".join(taken)
		var cut := _unopened_close(joined)
		var tail := ""
		if cut != -1:
			tail = joined.substr(cut)
			joined = joined.substr(0, cut)
		var body := PackedStringArray()
		var base := -1
		for body_line in joined.split("\n"):
			if body_line.strip_edges() == "":
				continue
			if base == -1:
				base = _tabs(body_line)
			body.append("\t" + body_line.substr(mini(base, _tabs(body_line))).strip_edges(false, true))
		var head := stripped.substr(at)
		var open := head.find("(")
		var sub: Dictionary = {}
		if not body.is_empty() and open != -1:
			var parser = get_script().new()
			sub = parser.parse("func __bp_lambda%s\n%s\n" % [head.substr(open), "\n".join(body)])
		if sub.is_empty() or sub.funcs.size() != 1 or not sub.extra.is_empty():
			out.append(line)
			i += 1
			continue
		var fn: Dictionary = sub.funcs[0]
		var key := "__bp_lambda_%d__" % _lambdas.size()
		_lambdas[key] = {"k": "lambda", "params": fn.params, "ret": fn.ret, "body": fn.body, "body_text": String(fn.get("body_text", "pass")),
			"src": head + "\n" + "\n".join(body)}
		out.append(line.substr(0, at) + key + tail)
		found = true
		i = j
	return "\n".join(out) if found else ""


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


## Source text of logical lines [from, to), re-indented relative to the first one.
func _text(from: int, to: int) -> String:
	var out := PackedStringArray()
	var base := int(_lines[from].indent)
	for i in range(from, mini(to, _lines.size())):
		var pad := "\t".repeat(maxi((int(_lines[i].indent) - base) / 4, 0))
		for part in String(_lines[i].src).split("\n"):
			out.append(pad + part)
	return "\n".join(out)


func _if_stmt(ln: Dictionary) -> Dictionary:
	var indent := int(ln.indent)
	var start := _li
	var st := {"k": "if", "branches": [], "else": [], "src": ln.src, "line": ln.line}
	_p += 1
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

func _expr() -> Variant:
	var e: Variant = _or()
	if _is("if"):
		_p += 1
		var c: Variant = _or()
		_take("else")
		var other: Variant = _expr()
		return {"k": "tern", "c": c, "a": e, "b": other}
	return e


func _or() -> Variant:
	var a: Variant = _and()
	while _is("or") or _is("||"):
		_p += 1
		a = {"k": "bin", "op": "or", "a": a, "b": _and()}
	return a


func _and() -> Variant:
	var a: Variant = _not()
	while _is("and") or _is("&&"):
		_p += 1
		a = {"k": "bin", "op": "and", "a": a, "b": _not()}
	return a


func _not() -> Variant:
	if _is("not") or (_is("!") and not (_peek(1).t == "op" and _peek(1).v == "=")):
		_p += 1
		return {"k": "un", "op": "not", "a": _not()}
	return _compare()


func _compare() -> Variant:
	var a: Variant = _bit_or()
	while true:
		var tok := _peek()
		if tok.t == "op" and String(tok.v) in ["==", "!=", "<", ">", "<=", ">="]:
			_p += 1
			a = {"k": "bin", "op": String(tok.v), "a": a, "b": _bit_or()}
		elif _is("in"):
			_p += 1
			a = {"k": "bin", "op": "in", "a": a, "b": _bit_or()}
		elif _is("not") and _peek(1).t == "kw" and _peek(1).v == "in":
			_p += 2
			a = {"k": "un", "op": "not", "a": {"k": "bin", "op": "in", "a": a, "b": _bit_or()}}
		elif _is("is"):
			_p += 1
			var neg := _take("not")
			a = {"k": "is", "a": a, "t": _type()}
			if neg:
				a = {"k": "un", "op": "not", "a": a}
		else:
			break
	return a


func _bit_or() -> Variant:
	var a: Variant = _bit_xor()
	while _is("|"):
		_p += 1
		a = {"k": "bin", "op": "|", "a": a, "b": _bit_xor()}
	return a


func _bit_xor() -> Variant:
	var a: Variant = _bit_and()
	while _is("^"):
		_p += 1
		a = {"k": "bin", "op": "^", "a": a, "b": _bit_and()}
	return a


func _bit_and() -> Variant:
	var a: Variant = _shift()
	while _is("&"):
		_p += 1
		a = {"k": "bin", "op": "&", "a": a, "b": _shift()}
	return a


func _shift() -> Variant:
	var a: Variant = _sum()
	while _is("<<") or _is(">>"):
		var op := String(_next().v)
		a = {"k": "bin", "op": op, "a": a, "b": _sum()}
	return a


func _sum() -> Variant:
	var a: Variant = _product()
	while _is("+") or _is("-"):
		var op := String(_next().v)
		a = {"k": "bin", "op": op, "a": a, "b": _product()}
	return a


func _product() -> Variant:
	var a: Variant = _unary()
	while _is("*") or _is("/") or _is("%"):
		var op := String(_next().v)
		a = {"k": "bin", "op": op, "a": a, "b": _unary()}
	return a


func _unary() -> Variant:
	if _is("-") or _is("+") or _is("~"):
		var op := String(_next().v)
		var a: Variant = _unary()
		if op == "+":
			return a
		if op == "-" and a != null and a.k == "num":
			return {"k": "num", "v": "-" + String(a.v), "f": a.f}
		return {"k": "un", "op": op, "a": a}
	return _power()


func _power() -> Variant:
	var a: Variant = _as()
	if _is("**"):
		_p += 1
		return {"k": "bin", "op": "**", "a": a, "b": _unary()}
	return a


func _as() -> Variant:
	var a: Variant = _postfix()
	while _is("as"):
		_p += 1
		a = {"k": "as", "a": a, "t": _type()}
	return a


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
					var parts := PackedStringArray([String(tok.v)])
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
						parts.append(String(_next().v))
					_saw_raw = true
					var stop := _p
					var text := " ".join(parts)
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
						if not (_take(":") or _take("=")):
							break
						pairs.append([key, _expr()])
						if not _take(","):
							break
					_take("}")
					return {"k": "dict", "pairs": pairs}
	_p -= 1
	return null


# ---------------------------------------------------------------- back to text

static func unparse(e: Variant) -> String:
	if e == null:
		return "null"
	match String(e.k):
		"num", "str", "bool":
			return String(e.v)
		"null":
			return "null"
		"self":
			return "self"
		"name":
			return String(e.v)
		"node":
			var path := String(e.path)
			if path.begins_with("%"):
				return path
			return "$" + (path if path.is_valid_identifier() or not path.contains(" ") else "\"%s\"" % path)
		"paren":
			return "(%s)" % unparse(e.a)
		"un":
			return ("not %s" if e.op == "not" else String(e.op) + "%s") % unparse(e.a)
		"bin":
			return "%s %s %s" % [unparse(e.a), e.op, unparse(e.b)]
		"tern":
			return "%s if %s else %s" % [unparse(e.a), unparse(e.c), unparse(e.b)]
		"await":
			return "await %s" % unparse(e.a)
		"lambda":
			return String(e.src)
		"is":
			return "%s is %s" % [unparse(e.a), e.t]
		"as":
			return "%s as %s" % [unparse(e.a), e.t]
		"attr":
			return "%s.%s" % [unparse(e.obj), e.name]
		"index":
			return "%s[%s]" % [unparse(e.obj), unparse(e.i)]
		"call":
			var args := PackedStringArray()
			for a in e.args:
				args.append(unparse(a))
			return "%s(%s)" % [unparse(e.fn), ", ".join(args)]
		"array":
			var items := PackedStringArray()
			for a in e.items:
				items.append(unparse(a))
			return "[%s]" % ", ".join(items)
		"dict":
			var pairs := PackedStringArray()
			for pr in e.pairs:
				pairs.append("%s: %s" % [unparse(pr[0]), unparse(pr[1])])
			return "{%s}" % ", ".join(pairs)
		"raw":
			return String(e.src)
	return "null"
