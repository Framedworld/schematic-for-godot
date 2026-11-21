extends SceneTree
## Bulk-tool regressions run under a unique directory and compare the actual destination bytes.

const Files := preload("res://addons/schematic/core/sc_project_files.gd")
const Orchestrator := preload("res://addons/schematic/tools/import_orchestrator.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const ConvertTool := preload("res://addons/schematic/tools/convert_project.gd")
const ReimportTool := preload("res://addons/schematic/tools/reimport_project.gd")
const TORCH := """[obj type="OScriptFunction"]
guid = "sample"
method = {"name":"_ready","args":[]}
[obj type="OScriptNodeEvent"]
id = 1
position = Vector2(0, 0)
function_id = "sample"
pin_data = []
[resource]
base_type = "Node"
connections = []
"""

const RULES_TORCH := """[obj type="OScriptVariable" id="v"]
name = "open_angle"
category = "Default"
exported = true
type = 3
default_value = 110.0
description = "Degrees."
[obj type="OScriptFunction" id="f"]
guid = "rules"
method = {"name": &"on_event", "args": [{"name": &"event_id", "type": 4}, {"name": &"payload", "type": 27}]}
[obj type="OScriptNodeFunctionEntry" id="entry"]
function_id = "rules"
id = 0
position = Vector2(0, 0)
pin_data = Array[Dictionary]([{"pin_name": &"ExecOut", "dir": 1}, {"pin_name": &"event_id", "type": 4, "dir": 1}, {"pin_name": &"payload", "type": 27, "dir": 1}])
[obj type="OScriptNodeOperator" id="eq"]
code = &"=="
id = 1
position = Vector2(200, 100)
pin_data = Array[Dictionary]([{"pin_name": &"a", "type": 4}, {"pin_name": &"b", "type": 4, "dv": "door_breached"}, {"pin_name": &"result", "type": 1, "dir": 1}])
[obj type="OScriptNodeBranch" id="b"]
id = 2
position = Vector2(400, 0)
pin_data = Array[Dictionary]([{"pin_name": &"ExecIn"}, {"pin_name": &"condition", "type": 1}, {"pin_name": &"true", "dir": 1}, {"pin_name": &"false", "dir": 1}])
[obj type="OScriptNodeAutoload" id="api"]
autoload = "ToolTestApi"
id = 3
position = Vector2(400, 200)
pin_data = Array[Dictionary]([{"pin_name": &"value", "type": 24, "dir": 1}])
[obj type="OScriptNodeCallMemberFunction" id="typed"]
function_name = &"narrate"
target_class_name = "Node"
id = 4
position = Vector2(600, 0)
pin_data = Array[Dictionary]([{"pin_name": &"ExecIn"}, {"pin_name": &"target", "type": 24}, {"pin_name": &"title", "type": 4, "dv": "Loud"}, {"pin_name": &"ExecOut", "dir": 1}])
[obj type="OScriptNodeCallMemberFunction" id="named"]
function_name = &"not_on_the_script"
target_class_name = "Node"
id = 5
position = Vector2(800, 0)
pin_data = Array[Dictionary]([{"pin_name": &"ExecIn"}, {"pin_name": &"target", "type": 24}, {"pin_name": &"amount", "type": 2, "dv": 2}, {"pin_name": &"ExecOut", "dir": 1}])
[resource]
base_type = &"Node"
connections = Array[int]([0, 1, 1, 0, 0, 0, 2, 0, 1, 0, 2, 1, 2, 0, 4, 0, 3, 0, 4, 1, 4, 0, 5, 0, 3, 0, 5, 1])
"""

var failures := 0
var folder_path := "res://tests/tool_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
var written: Array[String] = []


func put(name: String, text: String) -> void:
	var path := folder_path.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	written.append(path)


func check(label: String, ok: bool, detail := "") -> void:
	print("PASS  " if ok else "FAIL  ", label, "" if ok or detail == "" else "  " + detail)
	if not ok:
		failures += 1


func _init() -> void:
	var handwritten := "extends Node\nconst KEEP := true\n"
	put("Pilot.torch", TORCH)
	put("Pilot.gd", handwritten)
	put("Twin.torch", TORCH)
	put("Twin.os", TORCH)
	put("Clear.torch", TORCH)
	put("ignored/.gdignore", "")
	put("nested/project.godot", "config_version=5\n")
	for folder in ["ignored", "nested"]:
		put(folder + "/sub/Other.torch", TORCH)
	var refs := folder_path + "/Pilot.torch\n" + folder_path + "/Twin.os\n" + folder_path + "/Clear.torch"
	put("refs.tres", refs)
	var tool := Orchestrator.new()
	tool.import_folder(folder_path, true)
	check("dry run leaves targets and references alone", not FileAccess.file_exists(folder_path + "/Clear.gd") and FileAccess.get_file_as_string(folder_path + "/refs.tres") == refs)
	tool.import_folder(folder_path, false)
	check("existing script survives import", FileAccess.get_file_as_bytes(folder_path + "/Pilot.gd") == handwritten.to_utf8_buffer())
	check("both owners of a collision are skipped", not FileAccess.file_exists(folder_path + "/Twin.gd"))
	check("only successful destinations change references", FileAccess.get_file_as_string(folder_path + "/refs.tres") == refs.replace("/Clear.torch", "/Clear.gd"))
	var generated := folder_path + "/Clear.gd"
	check("uncontested graph becomes a script", FileAccess.file_exists(generated))
	written.append(generated)
	put("refs.tres", refs)
	tool.import_folder(folder_path, false)
	check("a repeated import can repair references", FileAccess.get_file_as_string(folder_path + "/refs.tres") == refs.replace("/Clear.torch", "/Clear.gd"))
	# a graph of rules: a function entry, a branch, an autoload and calls on it
	put("api.gd", "extends Node
func narrate(title: String) -> void:
	pass
")
	put("Rules.torch", RULES_TORCH)
	ProjectSettings.set_setting("autoload/ToolTestApi", "*" + folder_path + "/api.gd")
	var rules: Dictionary = tool.convert_graph(tool.parse_torch(folder_path + "/Rules.torch"))
	var rules_compiler := preload("res://addons/schematic/core/sc_compiler.gd").new()
	var rules_code: String = rules_compiler.compile(rules.bp)
	ProjectSettings.set_setting("autoload/ToolTestApi", null)
	check("branches, autoloads and function entries convert", rules.problems.is_empty() and rules_compiler.errors.filter(func(e): return not e.w).is_empty())
	check("a function entry is the function the graph defined", rules_code.contains("func on_event(event_id: String, payload: Dictionary) -> void:"))
	check("a branch reads its condition", rules_code.contains("if (event_id == \"door_breached\"):"))
	check("a call on an autoload keeps the function's own pins", rules_code.contains("ToolTestApi.narrate(\"Loud\")"))
	check("a call the autoload's script does not have is made by name", rules_code.contains("not_on_the_script") and rules_code.contains("2"))
	check("a variable written with a bare type keeps it", rules_code.contains("@export var open_angle: float = 110.0"))
	tool.free()
	for folder in ["ignored", "nested"]:
		var sub := folder_path.path_join(folder + "/sub")
		var paths := []
		Files.find(sub, ["torch"], paths)
		check("direct and recursive scans respect " + folder, paths.is_empty() and not FileAccess.file_exists(sub + "/Other.gd"))
	convert_scope_tests()
	converted_mark_tests()
	reimport_tool_tests()
	wipe(folder_path.path_join("scope"))
	wipe(folder_path.path_join("mark"))
	for path in written:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for dir in ["ignored/sub", "nested/sub", "ignored", "nested", ""]:
		DirAccess.remove_absolute(folder_path.path_join(dir))
	quit(1 if failures else 0)


## Removes a folder made by these tests, with everything in it.
func wipe(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute(dir_path.path_join(name))
	for name in dir.get_directories():
		wipe(dir_path.path_join(name))
	DirAccess.remove_absolute(dir_path)


## What the project converter is told to convert: --only, --list, --skip, --not-extending, --options.
func convert_scope_tests() -> void:
	var root := folder_path.path_join("scope")
	var plain := "extends Node\nvar n := 1\n"
	put("scope/a/One.gd", plain)
	put("scope/a/skip/Two.gd", plain)
	put("scope/kept/Base.gd", "extends Node\n")
	put("scope/b/Three.gd", "extends \"%s/kept/Base.gd\"\n" % root)
	put("scope/b/Four.gd", plain)
	put("scope/b/Five.gd", "extends Timer\n")
	put("scope/b/Six.gd", "class_name ScToolSix extends HTTPRequest\n")
	put("scope/b/Seven.gd", plain)
	put("scope/list.txt", "# the scripts of b that are converted\n%s/b/Three.gd\n\n%s/b/Four.gd\n%s/b/Five.gd\n%s/b/Six.gd\n%s/b/Missing.gd\n" % [root, root, root, root, root])
	put("scope/convert.options", "# options\n--only=%s/a\n--skip=%s/a/skip\n" % [root.trim_prefix("res://"), root])
	var args := ConvertTool.read_args(PackedStringArray(["--quiet", "--options=%s/convert.options" % root, "--list=%s/list.txt" % root]))
	check("--options puts a file's options where it was named", args == PackedStringArray(["--quiet", "--only=%s/a" % root.trim_prefix("res://"),
		"--skip=%s/a/skip" % root, "--list=%s/list.txt" % root]))
	check("the same option given twice adds up", ConvertTool.list_arg(PackedStringArray(["--skip=a,b", "--dry", "--skip=c"]), "skip") == PackedStringArray(["a", "b", "c"]))
	check("a class name on the first line is seen", ConvertTool.has_class_name("class_name A\nextends Node\n") and ConvertTool.has_class_name("extends Node\nclass_name A\n")
		and not ConvertTool.has_class_name("extends Node\n# class_name A\n"))
	check("what a script extends is read from either form", ConvertTool.parent_of("# note\nextends Timer\n", {}) == "Timer"
		and ConvertTool.parent_of("class_name A extends \"res://x.gd\"\n", {}) == "res://x.gd"
		and ConvertTool.parent_of("class_name A\nextends B  # why\n", {"B": "res://b.gd"}) == "res://b.gd" and ConvertTool.parent_of("var n := 1\n", {}) == "RefCounted")
	var tool := ConvertTool.new()
	var files: Array = tool._scope(args)
	files.sort()
	check("--only, --list and --skip together give the scripts to convert",
		files == [root + "/a/One.gd", root + "/b/Five.gd", root + "/b/Four.gd", root + "/b/Six.gd", root + "/b/Three.gd"], str(files))
	args.append("--not-extending=%s/kept/,Timer" % root)
	files = tool._scope(args)
	files.sort()
	check("--not-extending leaves children of a script folder and of an engine class", files == [root + "/a/One.gd", root + "/b/Four.gd", root + "/b/Six.gd"], str(files))
	files = tool._scope(PackedStringArray(["--only=%s/b" % root, "--not-extending=HTTP*"]))
	files.sort()
	check("--not-extending takes the start of a class name", files == [root + "/b/Five.gd", root + "/b/Four.gd", root + "/b/Seven.gd", root + "/b/Three.gd"], str(files))
	tool.free()


## The converter's mark: a Schematic saved from the editor since it was converted is not converted again.
func converted_mark_tests() -> void:
	var root := folder_path.path_join("mark")
	var hand := "extends Node\nvar n := 1\n\n\nfunc bump(by: int) -> void:\n\tif by > 2:\n\t\tn += by\n\telif by > 1:\n\t\tn += 2\n\telse:\n\t\tn += 1\n"
	put("mark/Hand.gd", hand)
	put("mark/Named.gd", "class_name ScToolNamed\nextends Node\nvar n := 1\n")
	var path := root + "/Hand.gd"
	var bp := Model.new_schematic("Node", "")
	var code := Compiler.new().compile(bp.duplicate(true))
	var marked := Model.build_source(code, bp, true)
	var unmarked := Model.build_source(code, bp)
	check("the converter's mark is told from a file without it", Model.is_as_converted(marked) and not Model.is_as_converted(unmarked) and not Model.is_as_converted(hand))
	check("a marked file reads as before", Model.parse_source(marked) == Model.parse_source(unmarked) and not Model.code_edited(marked)
		and Model.code_part(marked) == Model.code_part(unmarked))
	ProjectSettings.set_setting("autoload/ScToolAuto", "*" + root + "/Named.gd")
	var tool := ConvertTool.new()
	var args := PackedStringArray(["--only=" + root, "--no-reuse", "--quiet"])
	var first: Dictionary = tool.run(args)
	var text1 := FileAccess.get_file_as_string(path)
	check("a hand-written script is converted, its original kept", first.converted.has(path) and Model.is_as_converted(text1) and FileAccess.get_file_as_string(path + ".orig") == hand)
	check("an elif stays an elif", Model.code_part(text1).contains("\n\telif by > 1:\n") and not Model.code_part(text1).contains("\n\t\tif by > 1:"), Model.code_part(text1))
	var named := FileAccess.get_file_as_string(root + "/Named.gd")
	check("an autoload whose class name is on the first line keeps that name", named.contains("\nclass_name ScToolNamed\n") and not named.contains("SC_ScToolAuto"), named.left(200))
	ProjectSettings.set_setting("autoload/ScToolAuto", null)   # (this, not clear(), also takes it off the list of autoloads to start)
	var second: Dictionary = tool.run(args)
	check("a script as the converter left it converts again from its original", second.converted.has(path) and FileAccess.get_file_as_string(path) == text1)
	# what a save from the Schematic editor writes: the same graph and code, without the converter's mark
	var saved_bp := Model.parse_source(text1)
	var saved := Model.build_source(Compiler.new().compile(saved_bp.duplicate(true)), saved_bp)
	Model.write_text(path, saved)
	var third: Dictionary = tool.run(args)
	check("a Schematic saved from the editor is not converted again", third.skipped.has(path) and not third.converted.has(path) and FileAccess.get_file_as_string(path) == saved)
	var fourth: Dictionary = tool.run(args + PackedStringArray(["--again"]))
	check("--again converts it from its original all the same", fourth.converted.has(path) and Model.is_as_converted(FileAccess.get_file_as_string(path)))
	tool.run(args + PackedStringArray(["--drop-originals"]))
	check("--drop-originals removes the kept originals of converted scripts", not FileAccess.file_exists(path + ".orig") and Model.is_schematic_file(path))
	var fifth: Dictionary = tool.run(args)
	check("with no original a Schematic is passed over", fifth.converted.is_empty() and fifth.failed.is_empty())
	tool.free()


## Code edited as text is brought back into its graph without the editor (tools/reimport_project.gd).
func reimport_tool_tests() -> void:
	var path := folder_path.path_join("mark/Hand.gd")
	var fresh := FileAccess.get_file_as_string(path)
	check("a Schematic as written is not stale", ReimportTool.reimport_file(path, false).state == "same" and FileAccess.get_file_as_string(path) == fresh)
	check("the tool finds the Schematics of a folder", ReimportTool.scope(PackedStringArray(["--only=" + folder_path.path_join("mark")])).has(path))
	var edited := fresh.replace("\t\tn += 2\n", "\t\tn += 20\n\t\tprint(n)\n")
	Model.write_text(path, edited)
	check("an edit of the code makes it stale", edited != fresh and ReimportTool.is_stale(edited, Model.parse_source(edited)))
	var looked: Dictionary = ReimportTool.reimport_file(path, true)
	check("--check says it can be re-imported and writes nothing", looked.state == "done" and FileAccess.get_file_as_string(path) == edited, str(looked.why))
	var did: Dictionary = ReimportTool.reimport_file(path, false)
	var now := FileAccess.get_file_as_string(path)
	var now_bp := Model.parse_source(now)
	check("the edit is brought into the graph", did.state == "done" and not ReimportTool.is_stale(now, now_bp) and Model.code_part(now).contains("\t\tn += 20\n\t\tprint(n)\n"), str(did.why))
	check("the stored graph compiles to the file's code", not now_bp.is_empty() and Model.normalize_code(Compiler.new().compile(now_bp.duplicate(true))) == Model.code_part(now))
	var broken := now.replace("\t\tn += 20\n", "\t\tn +=* 20\n")
	Model.write_text(path, broken)
	var refused: Dictionary = ReimportTool.reimport_file(path, false)
	check("code that cannot be brought in leaves the file as it is", refused.state == "refused" and String(refused.why) != "" and FileAccess.get_file_as_string(path) == broken, str(refused.state))
