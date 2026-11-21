@tool
extends RefCounted
## Schematic document model. A schematic is a plain Dictionary (JSON-safe) that is stored inside the
## generated .gd file as a trailing comment block, so one file is both the graph and the script.
##
## schematic = {
##   version, parent, class_name, tool, description,
##   variables:   [{name, type, default(literal), export, category, tooltip}],
##   dispatchers: [{name, params:[[name,type],...]}],
##   graphs: [{id, name, kind:"event"|"function", inputs:[[name,type]], outputs:[[name,type]], pure,
##             locals:[{name,type,default}], next_id,
##             nodes:[{id, kind, x, y, p:{...}, d:{pin_id: literal}}],
##             wires:[[from_node, from_pin, to_node, to_pin], ...], zoom, sx, sy,
##             lambda (a function graph a converted script's lambda became: how many of its last inputs are the
##                     values it captures; the compiler writes it back as a lambda where it is used)}]
## }
##
## Comments a converted script wrote (the compiler writes them back where they were; a graph made in the editor
## has none of these fields; the editor does not show them yet). A note line is "" (a blank line) or a comment
## from its `#` on, with a tab before the `#` for each block it is indented deeper than its owner and a "<" for
## each block shallower:
##   schematic.note [lines above the class lines], schematic.end_note [lines after everything],
##   schematic.description (a `## ` block right below extends, as before);
##   variables[i].note / dispatchers[i].note [lines above], .tail (the comment at the end of its line, spaces
##     before it included; a variable kept as written has it in its `raw` text instead);
##   node.p.note [lines above the statement], p.tail, p.after [lines that end the block after it], on the nodes a
##     statement became (see the importer's _block); an entry node's p.note / p.tail are its function's, p.end
##     the `#endregion` lines right below the function; p.empty {exec pin: {note, tail}} a block of nothing but
##     `pass` (written with the `pass` for that pin); a Branch's p.else_tail the end of its `else:` line (the
##     end of an `elif` line is the p.tail of the Branch it became). A code node's text holds the comments
##     inside its statement.

const Types := preload("res://addons/schematic/core/sc_types.gd")
const MARKER := "# @schematic"
## The plugin was called Blueprints before it was called Schematic. Files it wrote then start with this marker
## and name their graph block differently; they still open, and are written the new way when saved.
const OLD_MARKER := "# @blueprint"
const GRAPH_BLOCK := "\n#region Schematic graph data"
const OLD_GRAPH_BLOCK := "\n#region Blueprint graph data"
const DATA_PREFIX := "#~ "
## The line in the graph data that holds the fingerprint of the code above it (see code_hash()). It starts with
## "#~" but not "#~ ", so parse_source() of this and of older versions passes over it.
const CODE_HASH_PREFIX := "#~code "
## The line the project converter adds to the graph data of a script it converted (see is_as_converted()). Like
## the fingerprint line it starts with "#~" but not "#~ ", so every reader of the graph passes over it.
const CONVERTED_MARK := "#~converted"
const VERSION := 1
## The Data Table class (runtime/data_table.gd). Up to 0.3.3 it was called DataTable, a name a project may well
## use for a class of its own; graph data that names it the old way is read as naming it the present way.
const TABLE_CLASS := "SchematicDataTable"
const TABLE_CLASS_WAS := "DataTable"


static func new_schematic(parent: String, cls_name := "") -> Dictionary:
	var bp := {
		"version": VERSION, "parent": parent, "class_name": cls_name, "tool": false, "description": "",
		"variables": [], "dispatchers": [], "graphs": [],
	}
	var g := new_graph(bp, "EventGraph", "event")
	if ClassDB.class_exists(parent) and ClassDB.is_parent_class(parent, "Node"):
		add_node(g, "event", Vector2(80, 80), {"name": "_ready"})
		add_node(g, "event", Vector2(80, 260), {"name": "_process"})
	return bp


static func new_graph(bp: Dictionary, name: String, kind: String) -> Dictionary:
	var gid := 1
	for g in bp.graphs:
		gid = maxi(gid, int(g.id) + 1)
	var g := {"id": gid, "name": name, "kind": kind, "inputs": [], "outputs": [], "pure": false,
		"locals": [], "next_id": 1, "nodes": [], "wires": [], "zoom": 1.0, "sx": 0.0, "sy": 0.0}
	if kind == "macro":
		g.inputs = [["In", "exec"]]
		g.outputs = [["Out", "exec"]]
		add_node(g, "macro_in", Vector2(80, 120), {})
		add_node(g, "macro_out", Vector2(620, 120), {})
	if kind == "function":
		add_node(g, "fn_entry", Vector2(80, 120), {})
		add_node(g, "fn_return", Vector2(520, 120), {})
	bp.graphs.append(g)
	return g


static func add_node(g: Dictionary, kind: String, pos: Vector2, p: Dictionary) -> Dictionary:
	var n := {"id": int(g.next_id), "kind": kind, "x": pos.x, "y": pos.y, "p": p, "d": {}}
	g.next_id = int(g.next_id) + 1
	g.nodes.append(n)
	return n


static func find_node(g: Dictionary, id: int) -> Dictionary:
	for n in g.nodes:
		if int(n.id) == id:
			return n
	return {}


static func find_graph(bp: Dictionary, id: int) -> Dictionary:
	for g in bp.graphs:
		if int(g.id) == id:
			return g
	return {}


static func graph_named(bp: Dictionary, name: String) -> Dictionary:
	for g in bp.graphs:
		if g.name == name:
			return g
	return {}


static func find_var(bp: Dictionary, name: String) -> Dictionary:
	for v in bp.variables:
		if v.name == name:
			return v
	return {}


static func find_dispatcher(bp: Dictionary, name: String) -> Dictionary:
	for v in bp.dispatchers:
		if v.name == name:
			return v
	return {}


## Finds a custom event node by name across event graphs.
static func find_custom_event(bp: Dictionary, name: String) -> Dictionary:
	for g in bp.graphs:
		if g.kind != "event":
			continue
		for n in g.nodes:
			if n.kind == "custom_event" and n.p.get("name", "") == name:
				return n
	return {}


## A name node (a const the converter made for a parameter or for a name a Match case binds) remembers where its
## name belongs (`p.of`, `p.in`, `p.bound`, `p.arm`), and the compiler checks it is read there. A copy that goes
## into a macro, or comes out of one, is no longer in that place: the note is dropped and the copy is a plain name.
static func forget_place(node: Dictionary) -> void:
	if String(node.get("kind", "")) == "const" and node.get("p", {}).has("of"):
		for key in ["of", "in", "bound", "arm"]:
			node.p.erase(key)


static func remove_node(g: Dictionary, id: int) -> void:
	for i in range(g.nodes.size() - 1, -1, -1):
		if int(g.nodes[i].id) == id:
			g.nodes.remove_at(i)
	for i in range(g.wires.size() - 1, -1, -1):
		var w: Array = g.wires[i]
		if int(w[0]) == id or int(w[2]) == id:
			g.wires.remove_at(i)


static func unique_name(base: String, taken: Array) -> String:
	if not taken.has(base):
		return base
	var i := 1
	while taken.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]


static func member_names(bp: Dictionary) -> Array:
	var out := []
	for v in bp.variables:
		out.append(v.name)
	for v in bp.dispatchers:
		out.append(v.name)
	for en in bp.get("enums", []):
		out.append(en.name)
	for g in bp.graphs:
		if g.kind == "function" or g.kind == "macro":
			out.append(g.name)
		for tn in g.nodes:
			if tn.kind == "timeline":
				out.append(tn.p.get("name", ""))
		for n in g.nodes:
			if n.kind == "custom_event":
				out.append(n.p.get("name", ""))
	return out


# ---------------------------------------------------------------- persistence

static func is_schematic_source(src: String) -> bool:
	return src.begins_with(MARKER) or src.begins_with(OLD_MARKER)


## Where the stored graph begins in a script's text (the generated code is everything before it), or -1.
static func graph_block_at(text: String) -> int:
	var at := maxi(text.rfind(GRAPH_BLOCK), text.rfind(OLD_GRAPH_BLOCK))
	if at < 0:
		return -1
	var first := text.find("\n", at + 1)
	if first < 0 or text.substr(first + 1, 2) != "#~":
		return -1
	var end := text.rfind("\n#endregion")
	if end < first or text.substr(end).strip_edges() != "#endregion":
		return -1
	# The complete footer contains only machine comment lines, even if the script itself quotes a fake footer.
	for line in text.substr(first + 1, end - first - 1).split("\n"):
		if not line.begins_with("#~"):
			return -1
	return at


static func is_schematic_file(path: String) -> bool:
	if path.get_extension() != "gd" or not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var first := f.get_line()
	return first.begins_with(MARKER) or first.begins_with(OLD_MARKER)


## The schematic's own fields (parent, class name, library kind, variables...: everything but its graphs) read from
## a Schematic's text without reading the graphs, which are most of a large file. {} when the graph data is not
## laid out the way graph_lines() writes it (an older file); parse_source() reads those. Nothing is checked or
## filled in: it is for a quick look at many files (which of them are libraries), not for opening one.
static func peek_head(src: String) -> Dictionary:
	if not is_schematic_source(src):
		return {}
	var at := maxi(src.rfind(GRAPH_BLOCK), src.rfind(OLD_GRAPH_BLOCK))
	if at < 0:
		return {}
	var first := src.find("\n" + DATA_PREFIX, at)
	if first < 0:
		return {}
	var end := src.find("\n", first + 1)
	var line := src.substr(first + 1 + DATA_PREFIX.length(), (end if end != -1 else src.length()) - first - 1 - DATA_PREFIX.length()).strip_edges()
	if not line.ends_with("\"graphs\":["):
		return {}
	var reader := JSON.new()
	if reader.parse(line + "]}") != OK or typeof(reader.data) != TYPE_DICTIONARY:
		return {}
	return reader.data


## Returns the schematic dictionary embedded in a script's source, or {} if there is none that this version can
## read (unreadable_reason() says why).
static func parse_source(src: String) -> Dictionary:
	return _read(src)[0]


## Why parse_source() returns {} for this text, as the end of a sentence about the file ("" when it reads fine).
static func unreadable_reason(src: String) -> String:
	return String(_read(src)[1])


## [the schematic, ""] or [{}, why not].
static func _read(src: String) -> Array:
	if not is_schematic_source(src):
		return [{}, "is not a Schematic script"]
	src = src.replace("\r\n", "\n")
	var json := PackedStringArray()
	var at := graph_block_at(src)
	if at < 0:
		return [{}, "has no graph data: the block at the end of the file is missing or was edited"]
	for line in src.substr(at).split("\n"):
		if line.begins_with(DATA_PREFIX):
			json.append(line.substr(DATA_PREFIX.length()))
		elif line == "#~":
			json.append("")
	if json.is_empty():
		return [{}, "has no graph data"]   # generated code without its graph
	var reader := JSON.new()
	if reader.parse("\n".join(json)) != OK or typeof(reader.data) != TYPE_DICTIONARY:
		return [{}, "has damaged graph data (it does not read as JSON)"]
	var parsed: Dictionary = reader.data
	# A file a newer version of the plugin wrote may hold things this one does not know and would drop on saving.
	var written_by: Variant = parsed.get("version", VERSION)
	if typeof(written_by) in [TYPE_INT, TYPE_FLOAT] and int(written_by) > VERSION:
		return [{}, "was saved by a newer version of Schematic (file format %d, this plugin reads up to %d): update the plugin to open it" % [int(written_by), VERSION]]
	var wrong := shape_problem(parsed)
	if wrong != "":
		return [{}, "has damaged graph data (%s)" % wrong]
	return [normalize(parsed), ""]


## What is wrong with the shape of stored graph data ("" when it is what every reader here relies on). A bad merge
## or a hand edit can leave text that is still JSON but no longer a schematic; that must not reach normalize() or
## the editor, which read these fields without asking.
static func shape_problem(bp: Dictionary) -> String:
	for key in ["variables", "dispatchers", "graphs", "enums"]:
		if bp.has(key) and typeof(bp[key]) != TYPE_ARRAY:
			return "'%s' is not a list" % key
	for key in ["variables", "dispatchers", "enums"]:
		for item in bp.get(key, []):
			if typeof(item) != TYPE_DICTIONARY or typeof(item.get("name")) != TYPE_STRING:
				return "an entry of '%s' has no name" % key
	var number := [TYPE_INT, TYPE_FLOAT]
	for g in bp.get("graphs", []):
		if typeof(g) != TYPE_DICTIONARY:
			return "a graph is not an object"
		if not typeof(g.get("id")) in number or typeof(g.get("name")) != TYPE_STRING or typeof(g.get("kind")) != TYPE_STRING:
			return "a graph has no id, name or kind"
		for key in ["inputs", "outputs", "locals", "nodes", "wires"]:
			if g.has(key) and typeof(g[key]) != TYPE_ARRAY:
				return "'%s' of graph '%s' is not a list" % [key, g.name]
		for n in g.get("nodes", []):
			if typeof(n) != TYPE_DICTIONARY or not typeof(n.get("id")) in number or typeof(n.get("kind")) != TYPE_STRING:
				return "a node of graph '%s' has no id or kind" % g.name
			for key in ["p", "d"]:
				if n.has(key) and typeof(n[key]) != TYPE_DICTIONARY:
					return "node %d of graph '%s' has a damaged '%s'" % [int(n.id), g.name, key]
		for w in g.get("wires", []):
			if typeof(w) != TYPE_ARRAY or w.size() < 4 or not typeof(w[0]) in number or not typeof(w[2]) in number:
				return "a wire of graph '%s' is not [node, pin, node, pin]" % g.name
	return ""


## The code part of a Schematic's text (everything before its graph data, or all of it when it has none), in the
## form used for drift checks. Whitespace inside a string belongs to its value.
static func code_part(text: String) -> String:
	var cut := graph_block_at(text)
	return normalize_code(text.substr(0, cut) if cut != -1 else text)


## The graph data part of a Schematic's text, normalised like code_part(); "" when there is none.
static func graph_part(text: String) -> String:
	var cut := graph_block_at(text)
	return normalize_code(text.substr(cut)) if cut != -1 else ""


static func normalize_code(code: String) -> String:
	# Preserve the physical line ending and any spaces that belong to a string value.
	var lines := code.split("\n")
	var states := []
	if has_multiline_syntax(code):
		states = Types.lines_in_string(code)
	for i in lines.size():
		if i + 1 < states.size() and states[i + 1]:
			continue
		lines[i] = lines[i].rstrip(" \t\r")
	return "\n".join(lines).rstrip(" \t\r\n")


static func has_multiline_syntax(code: String) -> bool:
	return code.contains("\"\"\"") or code.contains("'''") or code.contains("\\\n") or code.contains("\\\r\n")


## Compiler output uses LF internally. Apply the document's line endings before comparing literal values.
static func file_code(code: String, bp: Dictionary) -> String:
	return code.replace("\r\n", "\n").replace("\n", "\r\n") if bool(bp.get("crlf", false)) else code


## A fingerprint of generated code. Every writer stores it in the graph data (a `#~code ` line, which readers of
## the graph skip), so a file whose code no longer matches it was edited by hand or by another tool.
static func code_hash(code: String) -> String:
	return normalize_code(code).md5_text()


## The code fingerprint stored in a Schematic's text, or "" (files written before it was stored have none).
static func stored_code_hash(text: String) -> String:
	var cut := graph_block_at(text)
	if cut == -1:
		return ""
	var at := text.find("\n" + CODE_HASH_PREFIX, cut)
	if at == -1:
		return ""
	return text.substr(at + 1 + CODE_HASH_PREFIX.length(), 32)


## True when the code part of `text` is not the code its stored fingerprint was taken of. A file with no
## fingerprint is never said to be edited (there is nothing to tell a hand edit from an older plugin by).
static func code_edited(text: String) -> bool:
	var stored := stored_code_hash(text)
	if stored == "":
		return false
	var code := code_part(text)
	if text.find("\n#~hash-v2", graph_block_at(text)) >= 0 or not has_multiline_syntax(code):
		return stored != code_hash(code)
	# Legacy fingerprints discarded literal whitespace. Recover the expected literal from the embedded graph.
	var bp := parse_source(text)
	if bp.is_empty():
		return true
	var compiler = load("res://addons/schematic/core/sc_compiler.gd").new()
	return code != normalize_code(file_code(compiler.compile(bp), bp))


## Writes a whole text file so that a failure never loses what was there. A Schematic's file is the only copy of its
## graph, so the text first goes to a copy beside it (<file>.sc_tmp) and is read back; only then is the file itself
## written and read back, and the copy removed. If the disk is full the file is not touched; if writing the file
## itself fails, the copy stays and the message says where it is. Returns "" or what went wrong.
static func write_text(path: String, text: String) -> String:
	var copy := path + ".sc_tmp"
	var wrote := _store(copy, text)
	if wrote != "":
		if FileAccess.file_exists(copy):
			DirAccess.remove_absolute(copy)
		return "%s was not written: %s" % [path.get_file(), wrote]
	wrote = _store(path, text)
	if wrote != "":
		return "%s could not be written (%s). What should be in it is in %s" % [path.get_file(), wrote, copy.get_file()]
	DirAccess.remove_absolute(copy)
	return ""


## Stores text and reads it back: "" when the file now holds exactly that text.
static func _store(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "can't open %s for writing (%s)" % [path.get_file(), error_string(FileAccess.get_open_error())]
	var stored := f.store_string(text)
	f.close()
	if not stored or FileAccess.get_file_as_string(path) != text:
		return "the disk did not take all of it (is it full?)"
	return ""


## Keeps the hand-written script a conversion replaces, beside it as <name>.gd.orig. A different copy already there
## (from converting an earlier version of the script) is moved to <name>.gd.orig.1, .2 ... first, so nothing written
## by hand is ever overwritten. Returns "" or what went wrong.
static func keep_original(path: String, source: String) -> String:
	var keep := path + ".orig"
	if FileAccess.file_exists(keep):
		if FileAccess.get_file_as_string(keep) == source:
			return ""
		var n := 1
		while FileAccess.file_exists("%s.%d" % [keep, n]):
			n += 1
		if DirAccess.rename_absolute(keep, "%s.%d" % [keep, n]) != OK:
			return "the older %s could not be moved out of the way" % keep.get_file()
	return write_text(keep, source)


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	return parse_source(f.get_as_text())


static var _table_was: RegEx


## True when text names the Data Table class the old way (as a whole word).
static func names_old_table_class(text: String) -> bool:
	if not text.contains(TABLE_CLASS_WAS):
		return false
	if _table_was == null:
		_table_was = RegEx.create_from_string("(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % TABLE_CLASS_WAS)
	return _table_was.search(text) != null


## A stored type or class name, with the Data Table class named the present way.
static func _present_type(t: Variant) -> Variant:
	if typeof(t) != TYPE_STRING or not names_old_table_class(String(t)):
		return t
	return _table_was.sub(String(t), TABLE_CLASS, true)


## JSON turns every number into a float; put ids back to ints and fill in missing fields.
static func normalize(bp: Dictionary) -> Dictionary:
	for key in ["variables", "dispatchers", "graphs", "enums"]:
		if not bp.has(key):
			bp[key] = []
	bp["tool"] = bool(bp.get("tool", false))
	bp["class_name"] = String(bp.get("class_name", ""))
	bp["description"] = String(bp.get("description", ""))
	for v in bp.variables:
		if v.has("type"):
			v["type"] = _present_type(v.type)
	for sig in bp.dispatchers:
		for prm in sig.get("params", []):
			if typeof(prm) == TYPE_ARRAY and prm.size() > 1:
				prm[1] = _present_type(prm[1])
	for g in bp.graphs:
		g.id = int(g.id)
		g.next_id = int(g.get("next_id", 1))
		for key in ["inputs", "outputs", "locals", "nodes", "wires"]:
			if not g.has(key):
				g[key] = []
		g.pure = bool(g.get("pure", false))
		for key in ["inputs", "outputs"]:
			for io in g[key]:
				if typeof(io) == TYPE_ARRAY and io.size() > 1:
					io[1] = _present_type(io[1])
		for local in g.locals:
			if typeof(local) == TYPE_DICTIONARY and local.has("type"):
				local["type"] = _present_type(local.type)
		for n in g.nodes:
			n.id = int(n.id)
			if not n.has("p"): n["p"] = {}
			if not n.has("d"): n["d"] = {}
			if not n.has("x"): n["x"] = 0.0
			for key in ["cls", "t", "type"]:
				if n.p.has(key):
					n.p[key] = _present_type(n.p[key])
			if not n.has("y"): n["y"] = 0.0
			g.next_id = maxi(g.next_id, n.id + 1)
		for w in g.wires:
			w[0] = int(w[0])
			w[2] = int(w[2])
	return bp


## The schematic as JSON, laid out with one node to a line. Joined with newlines it is one JSON document.
## (GDScript has to read past every one of these comment lines each time the script loads, so they are kept
## short: an indented layout made a large script take several times longer to load.)
static func graph_lines(bp: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var head: Dictionary = bp.duplicate()
	head.erase("graphs")
	lines.append(JSON.stringify(head, "", true).trim_suffix("}") + ("," if not head.is_empty() else "") + "\"graphs\":[")
	var graphs: Array = bp.get("graphs", [])
	for gi in graphs.size():
		var g: Dictionary = graphs[gi]
		var graph_head: Dictionary = g.duplicate()
		graph_head.erase("nodes")
		graph_head.erase("wires")
		lines.append(JSON.stringify(graph_head, "", true).trim_suffix("}") + ("," if not graph_head.is_empty() else "") + "\"nodes\":[")
		var nodes: Array = g.get("nodes", [])
		for ni in nodes.size():
			lines.append(JSON.stringify(nodes[ni], "", true) + ("," if ni < nodes.size() - 1 else ""))
		lines.append("],\"wires\":[")
		var wires: Array = g.get("wires", [])
		for wi in range(0, wires.size(), 8):
			var row := PackedStringArray()
			for w in wires.slice(wi, wi + 8):
				row.append(JSON.stringify(w, "", true))
			lines.append(",".join(row) + ("," if wi + 8 < wires.size() else ""))
		lines.append("]}" + ("," if gi < graphs.size() - 1 else ""))
	lines.append("]}")
	return lines


## True when the Schematic's text is as the project converter (or its reuse pass) wrote it: it holds the
## converter's mark, which no save from the editor writes. The converter converts such a file from its kept
## original again when asked to; one without the mark has a graph somebody may have changed.
static func is_as_converted(text: String) -> bool:
	var cut := graph_block_at(text)
	if cut == -1:
		return false
	var at := text.find("\n" + CONVERTED_MARK, cut)
	return at != -1 and text.substr(at + 1 + CONVERTED_MARK.length(), 1) in ["\n", "\r"]


## Assembles the final .gd text: marker line + generated code + embedded graph data. `as_converted` adds the
## project converter's mark (see is_as_converted): only the converter and its reuse pass ask for it.
static func build_source(code: String, bp: Dictionary, as_converted := false) -> String:
	var out := PackedStringArray()
	out.append(code.strip_edges(false, true))
	out.append("")
	out.append("")
	out.append("#region Schematic graph data (machine-written; edit this file in the Schematic editor)")
	out.append(CODE_HASH_PREFIX + code_hash(file_code(code, bp)))
	out.append("#~hash-v2")
	if as_converted:
		out.append(CONVERTED_MARK)
	for line in graph_lines(bp):
		out.append(DATA_PREFIX + line)
	out.append("#endregion")
	out.append("")
	# A script converted from one with Windows line endings keeps them: a string that runs over several lines
	# holds the line breaks of its file, so its value would change with them.
	var text := "\n".join(out)
	return file_code(text, bp)
