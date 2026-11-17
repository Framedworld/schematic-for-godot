extends SceneTree
## Bulk-tool regressions run under a unique directory and compare the actual destination bytes.

const Files := preload("res://addons/schematic/core/sc_project_files.gd")
const Orchestrator := preload("res://addons/schematic/tools/import_orchestrator.gd")
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

var failures := 0
var folder_path := "res://tests/tool_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
var written: Array[String] = []


func put(name: String, text: String) -> void:
	var path := folder_path.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	written.append(path)


func check(label: String, ok: bool) -> void:
	print("PASS  " if ok else "FAIL  ", label)
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
	tool.free()
	for folder in ["ignored", "nested"]:
		var sub := folder_path.path_join(folder + "/sub")
		var paths := []
		Files.find(sub, ["torch"], paths)
		check("direct and recursive scans respect " + folder, paths.is_empty() and not FileAccess.file_exists(sub + "/Other.gd"))
	for path in written:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for dir in ["ignored/sub", "nested/sub", "ignored", "nested", ""]:
		DirAccess.remove_absolute(folder_path.path_join(dir))
	quit(1 if failures else 0)
