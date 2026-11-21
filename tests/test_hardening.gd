extends SceneTree
## What must hold when the plugin meets other people's projects: a debug aid that does not change the game, graph data
## that is damaged or newer than the plugin, saving that never loses the file, originals that are never overwritten.
## Run: godot --headless --path . --script res://tests/test_hardening.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const ExportCheck := preload("res://addons/schematic/editor/sc_export_check.gd")

const DIR := "res://tests/tmp/hardening/"
## (the export check does not look in folders Godot ignores, as tests/tmp is, so its files go here for a moment)
const SCAN := "res://tests/hardening_scan/"
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


## The generated code of a hand-written script, with Show Flow and Values on.
func traced(source: String) -> String:
	var out := Importer.new().convert(source, {"path": DIR + "case.gd"})
	out.bp["trace"] = true
	var c := Compiler.new()
	var code := c.compile(out.bp)
	check("    (compiles)", c.errors.filter(func(e): return not e.w).is_empty(), str(c.errors))
	return code


func loads(code: String) -> bool:
	var gs := GDScript.new()
	gs.source_code = code
	return gs.reload() == OK


func trace_lines(code: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in code.split("\n"):
		if line.strip_edges().begins_with("__sc_trace("):
			out.append(line.strip_edges())
	return out


func file_text(bp_text: String) -> String:
	return "# @schematic v1\nextends Node\n\n\n#region Schematic graph data (machine-written)\n#~ %s\n#endregion\n" % bp_text


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()

	# ================================================================ Show Flow and Values changes nothing
	var code := traced("extends Node\n\nvar q: Array = [1, 2, 3]\nvar speed := 2.0\n\nfunc _ready() -> void:\n\tprint(randi())\n\tprint(q.pop_back())\n\tprint(q.size(), speed * 2.0, absf(speed), q.pick_random())\n")
	var shown := "\n".join(trace_lines(code))
	check("a traced script loads", loads(code))
	check("a random number is not read a second time for the trace", not shown.contains("randi") and code.count("randi()") == 1, shown)
	check("a call that changes its object is not made a second time", not shown.contains("pop_back") and code.count("q.pop_back()") == 1, shown)
	check("a random pick is not made a second time", not shown.contains("pick_random") and code.count("pick_random()") == 1, shown)
	check("values that are safe to read again are still shown", shown.contains("q.size()") and shown.contains("\"v0\": speed * 2.0,") and shown.contains("absf(speed)"), shown)

	code = traced("extends Node\n\nstatic func helper(x: int) -> int:\n\tprint(x)\n\treturn x + 1\n\nfunc other(y: int) -> void:\n\tprint(y)\n")
	check("a script with a static function loads with Show Flow on", loads(code))
	var in_static := false
	var static_traced := false
	for line in code.split("\n"):
		if line.begins_with("static func helper"):
			in_static = true
		elif line.begins_with("func ") or line.begins_with("static func "):
			in_static = false
		elif in_static and line.contains("__sc_trace("):
			static_traced = true
	check("no trace call is written into the static function", not static_traced)
	check("the other functions are still traced", trace_lines(code).size() >= 1, str(trace_lines(code)))

	# ================================================================ graph data that is damaged, or newer
	for bad in ["{\"graphs\":[{\"name\":\"x\"}]}", "{\"graphs\":7}", "[1,2]", "{\"graphs\":[{\"id\":1,\"name\":\"g\",\"kind\":\"event\",\"nodes\":[{\"kind\":\"event\"}]}]}",
			"{\"graphs\":[{\"id\":1,\"name\":\"g\",\"kind\":\"event\",\"wires\":[[1,\"a\"]]}]}", "{\"variables\":[3],\"graphs\":[]}", "{not json"]:
		var text := file_text(bad)
		check("damaged graph data reads as nothing, with a reason: %s" % bad.left(40), Model.parse_source(text).is_empty() and Model.unreadable_reason(text).contains("damaged"),
			Model.unreadable_reason(text))
	var newer := file_text("{\"version\":%d,\"graphs\":[]}" % (Model.VERSION + 1))
	check("a file from a newer plugin is not opened", Model.parse_source(newer).is_empty() and Model.unreadable_reason(newer).contains("newer version"), Model.unreadable_reason(newer))
	var fine := Model.new_schematic("Node", "")
	var fine_text := Model.build_source("# @schematic v1\nextends Node\n", fine)
	check("a file this version wrote reads back", not Model.parse_source(fine_text).is_empty() and Model.unreadable_reason(fine_text) == "", Model.unreadable_reason(fine_text))
	check("a plain script says so", Model.unreadable_reason("extends Node\n") == "is not a Schematic script")

	# ================================================================ the Data Table class under its old name
	var old := Model.new_schematic("Node", "")
	old.variables.append({"name": "items", "type": "DataTable", "default": "", "export": true, "category": "", "tooltip": ""})
	old.variables.append({"name": "many", "type": "Array[DataTable]", "default": "", "export": false, "category": "", "tooltip": ""})
	old.variables.append({"name": "mine", "type": "MyDataTableThing", "default": "", "export": false, "category": "", "tooltip": ""})
	Model.add_node(old.graphs[0], "call", Vector2(300, 300), {"cls": "DataTable", "method": "size"})
	var read := Model.parse_source(Model.build_source("# @schematic v1\nextends Node\n", old))
	check("graph data naming DataTable is read as naming %s" % Model.TABLE_CLASS, String(read.variables[0].type) == Model.TABLE_CLASS and String(read.variables[1].type) == "Array[%s]" % Model.TABLE_CLASS
		and String(read.graphs[0].nodes[-1].p.cls) == Model.TABLE_CLASS, str(read.variables))
	check("a longer name that only contains DataTable is left alone", String(read.variables[2].type) == "MyDataTableThing")
	check("the old name is recognised as a whole word only", Model.names_old_table_class("var t: DataTable = null") and not Model.names_old_table_class("var t: SchematicDataTable")
		and not Model.names_old_table_class("var MyDataTableThing"))

	# ================================================================ saving
	var path := DIR + "saved.gd"
	check("write_text writes the file", Model.write_text(path, "one\n") == "" and FileAccess.get_file_as_string(path) == "one\n")
	check("and replaces it", Model.write_text(path, "two\nlines\n") == "" and FileAccess.get_file_as_string(path) == "two\nlines\n")
	check("no working copy is left behind", not FileAccess.file_exists(path + ".sc_tmp"))
	var nowhere := Model.write_text(DIR + "no_such_folder/x.gd", "text")
	check("a file that cannot be written is reported", nowhere != "", nowhere)

	# ================================================================ the original of a converted script
	var script := DIR + "player.gd"
	check("the original is kept beside the script", Model.keep_original(script, "first\n") == "" and FileAccess.get_file_as_string(script + ".orig") == "first\n")
	check("keeping the same original again changes nothing", Model.keep_original(script, "first\n") == "" and not FileAccess.file_exists(script + ".orig.1"))
	check("a different original moves the older one aside", Model.keep_original(script, "second\n") == "" and FileAccess.get_file_as_string(script + ".orig") == "second\n"
		and FileAccess.get_file_as_string(script + ".orig.1") == "first\n")
	check("and again, to the next free number", Model.keep_original(script, "third\n") == "" and FileAccess.get_file_as_string(script + ".orig") == "third\n"
		and FileAccess.get_file_as_string(script + ".orig.2") == "second\n" and FileAccess.get_file_as_string(script + ".orig.1") == "first\n")

	# ================================================================ the export warning
	var on := Model.new_schematic("Node", "")
	on["trace"] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCAN))
	Model.write_text(SCAN + "flow_on.gd", Model.build_source(Compiler.new().compile(on), on))
	var off := Model.new_schematic("Node", "")
	Model.write_text(SCAN + "flow_off.gd", Model.build_source(Compiler.new().compile(off), off))
	Model.write_text(SCAN + "plain.gd", "extends Node\n# \"trace\":true\n")
	var found := ExportCheck.files_with_trace(SCAN.trim_suffix("/"))
	check("the export check finds the Schematic with Show Flow on, and only that one", found == PackedStringArray([SCAN + "flow_on.gd"]), str(found))
	check("its warning names the file", ExportCheck.warning_text(found).contains("flow_on.gd"))

	# ================================================================ the built-in function list
	check("the built-in function list says which Godot it was made from", R.api.get("engine", []).size() == 2, str(R.api.get("engine", [])))

	for folder in [DIR, SCAN]:
		var dir := DirAccess.open(folder)
		for file in dir.get_files():
			dir.remove(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
	print("HARDENING FAILS: ", fails)
	quit(1 if fails else 0)
