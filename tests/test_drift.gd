extends SceneTree
## The parts of a Schematic's file that the editor compares to notice changes made outside it: the code part and the
## graph part, normalised so line endings, trailing spaces and trailing blank lines do not count, and the fingerprint
## of the generated code every writer stores in the graph data.
## Run: godot --headless --path . --script res://tests/test_drift.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail if not ok else ""])
	if not ok:
		fails += 1


func _init() -> void:
	var bp := Model.new_schematic("Node", "")
	Model.add_node(bp.graphs[0], "print", Vector2(300, 80), {})
	bp.graphs[0].wires.append([int(bp.graphs[0].nodes[0].id), "then", int(bp.graphs[0].nodes[2].id), "exec"])
	var c := Compiler.new()
	var code := c.compile(bp)
	check("the probe compiles", c.errors.filter(func(e): return not e.w).is_empty(), str(c.errors))
	var text := Model.build_source(code, bp)

	# the fingerprint line
	var stored := Model.stored_code_hash(text)
	check("build_source stores the code's fingerprint", stored.length() == 32 and stored == Model.code_hash(code), stored)
	check("the fingerprint is the fingerprint of the file's own code part", stored == Model.code_hash(Model.code_part(text)))
	check("a file just written is not edited", not Model.code_edited(text))
	check("the fingerprint line is inside the graph data", text.find(Model.CODE_HASH_PREFIX) > Model.graph_block_at(text))
	var lines_with_hash := 0
	for line in text.split("\n"):
		if line.begins_with(Model.CODE_HASH_PREFIX):
			lines_with_hash += 1
	check("there is exactly one fingerprint line", lines_with_hash == 1)

	# readers of the graph pass over it (this version's and the older one's rule: only "#~ " and "#~" lines are data)
	var back := Model.parse_source(text)
	check("the graph reads back with the fingerprint line in it", not back.is_empty() and Compiler.new().compile(back) == code)
	check("the fingerprint is not part of the graph", not back.has("code_hash") and not JSON.stringify(back).contains(stored))
	var json := PackedStringArray()
	for line in text.split("\n"):
		if line.begins_with("#~ "):
			json.append(line.substr(3))
		elif line == "#~":
			json.append("")
	check("an older reader (same rule) gets valid JSON", typeof(JSON.parse_string("\n".join(json))) == TYPE_DICTIONARY)

	# what is and is not a change
	var crlf := text.replace("\n", "\r\n")
	check("CRLF line endings: same code part", Model.code_part(crlf) == Model.code_part(text))
	check("CRLF line endings: same graph part", Model.graph_part(crlf) == Model.graph_part(text))
	check("CRLF line endings: not edited", not Model.code_edited(crlf))
	var trailing := text + "\n\n\n"
	check("trailing blank lines: same parts, not edited", Model.code_part(trailing) == Model.code_part(text) and Model.graph_part(trailing) == Model.graph_part(text) and not Model.code_edited(trailing))
	var cut := Model.graph_block_at(text)
	var spaced := text.substr(0, cut).replace("\n", "  \n") + text.substr(cut)
	check("spaces at line ends in the code: same code part", Model.code_part(spaced) == Model.code_part(text) and not Model.code_edited(spaced))
	var blank_before := text.substr(0, cut) + "\n\n\n" + text.substr(cut)
	check("blank lines before the graph data: same code part", Model.code_part(blank_before) == Model.code_part(text))
	var probe_line := ""
	for line in code.split("\n"):
		if line.contains("print("):
			probe_line = line
	var edited := text.replace(probe_line, probe_line.replace("print(", "print(\"edited\", "))
	check("a probe line was found", probe_line != "", code)
	check("an edited line changes the code part and not the graph part", Model.code_part(edited) != Model.code_part(text) and Model.graph_part(edited) == Model.graph_part(text))
	check("an edited line is caught by the fingerprint", Model.code_edited(edited))
	check("an edited line with CRLF is caught too", Model.code_edited(edited.replace("\n", "\r\n")))
	var bp2: Dictionary = bp.duplicate(true)
	bp2.variables.append({"name": "other", "type": "int", "default": "", "export": false, "category": "", "tooltip": ""})
	var other := Model.build_source(Compiler.new().compile(bp2), bp2)
	check("a different graph changes the graph part", Model.graph_part(other) != Model.graph_part(text))

	# files from before the fingerprint
	var old := text.replace(Model.CODE_HASH_PREFIX + stored + "\n", "")
	check("a file without the fingerprint line has none", Model.stored_code_hash(old) == "" and not old.contains(Model.CODE_HASH_PREFIX))
	check("such a file reads back the same", Compiler.new().compile(Model.parse_source(old)) == code)
	check("such a file, edited, is not said to be edited (nothing to tell by)", not Model.code_edited(old.replace(probe_line, "\tpass")))
	check("not a Schematic: the whole text is the code part, no graph part", Model.code_part("extends Node\r\n") == "extends Node" and Model.graph_part("extends Node\n") == "" and Model.stored_code_hash("extends Node") == "")

	# the file format of a crlf schematic keeps its endings, and its fingerprint is the same as with LF
	var bp_crlf: Dictionary = bp.duplicate(true)
	bp_crlf["crlf"] = true
	var crlf_text := Model.build_source(code, bp_crlf)
	check("a CRLF schematic is written with CRLF and its fingerprint matches", crlf_text.contains("\r\n") and Model.stored_code_hash(crlf_text) == stored and not Model.code_edited(crlf_text))

	print("%s  verdict: %d check%s failed" % ["PASS" if fails == 0 else "FAIL", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)
