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
const VERSION := 1


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
	var at := text.find(GRAPH_BLOCK)
	return at if at != -1 else text.find(OLD_GRAPH_BLOCK)


static func is_schematic_file(path: String) -> bool:
	if path.get_extension() != "gd" or not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var first := f.get_line()
	return first.begins_with(MARKER) or first.begins_with(OLD_MARKER)


## Returns the schematic dictionary embedded in a script's source, or {} if there is none.
static func parse_source(src: String) -> Dictionary:
	if not is_schematic_source(src):
		return {}
	src = src.replace("\r\n", "\n")
	var json := PackedStringArray()
	for line in src.split("\n"):
		if line.begins_with(DATA_PREFIX):
			json.append(line.substr(DATA_PREFIX.length()))
		elif line == "#~":
			json.append("")
	if json.is_empty():
		return {}   # generated code without its graph
	var parsed: Variant = JSON.parse_string("\n".join(json))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return normalize(parsed)


## The code part of a Schematic's text (everything before its graph data, or all of it when it has none), in the
## form two texts are compared in: line endings, spaces at the ends of lines and blank lines at the end do not count.
static func code_part(text: String) -> String:
	var cut := graph_block_at(text)
	return normalize_code(text.substr(0, cut) if cut != -1 else text)


## The graph data part of a Schematic's text, normalised like code_part(); "" when there is none.
static func graph_part(text: String) -> String:
	var cut := graph_block_at(text)
	return normalize_code(text.substr(cut)) if cut != -1 else ""


static func normalize_code(code: String) -> String:
	var lines := code.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	for i in lines.size():
		lines[i] = lines[i].rstrip(" \t")
	return "\n".join(lines).strip_edges(false, true)


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
	return stored != "" and stored != code_hash(code_part(text))


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	return parse_source(f.get_as_text())


## JSON turns every number into a float; put ids back to ints and fill in missing fields.
static func normalize(bp: Dictionary) -> Dictionary:
	for key in ["variables", "dispatchers", "graphs", "enums"]:
		if not bp.has(key):
			bp[key] = []
	bp["tool"] = bool(bp.get("tool", false))
	bp["class_name"] = String(bp.get("class_name", ""))
	bp["description"] = String(bp.get("description", ""))
	for g in bp.graphs:
		g.id = int(g.id)
		g.next_id = int(g.get("next_id", 1))
		for key in ["inputs", "outputs", "locals", "nodes", "wires"]:
			if not g.has(key):
				g[key] = []
		g.pure = bool(g.get("pure", false))
		for n in g.nodes:
			n.id = int(n.id)
			if not n.has("p"): n["p"] = {}
			if not n.has("d"): n["d"] = {}
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


## Assembles the final .gd text: marker line + generated code + embedded graph data.
static func build_source(code: String, bp: Dictionary) -> String:
	var out := PackedStringArray()
	out.append(code.strip_edges(false, true))
	out.append("")
	out.append("")
	out.append("#region Schematic graph data (machine-written; edit this file in the Schematic editor)")
	out.append(CODE_HASH_PREFIX + code_hash(code))
	for line in graph_lines(bp):
		out.append(DATA_PREFIX + line)
	out.append("#endregion")
	out.append("")
	# A script converted from one with Windows line endings keeps them: a string that runs over several lines
	# holds the line breaks of its file, so its value would change with them.
	var text := "\n".join(out)
	return text.replace("\n", "\r\n") if bool(bp.get("crlf", false)) else text
