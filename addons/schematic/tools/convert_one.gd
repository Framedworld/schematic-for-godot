extends Node
## Debug helper: converts one script and prints the generated code around each GDScript error.
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")

func _ready() -> void:
	T.refresh_globals()
	R.ensure_api()
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("res://"):
			continue
		var path: String = arg
		var orig := path + ".orig"
		var source := FileAccess.get_file_as_string(orig) if FileAccess.file_exists(orig) else FileAccess.get_file_as_string(path)
		var out := Importer.new().convert(source, {"path": path})
		var c := Compiler.new()
		var code := c.compile(out.bp)
		for e in c.errors:
			if not e.w:
				print("COMPILER ERROR ", e.m)
		var lines := code.split("\n")
		for i in lines.size():
			if lines[i].begins_with("class_name "):
				lines[i] = "#"
		var f := FileAccess.open("user://probe.gd", FileAccess.WRITE)
		f.store_string("\n".join(lines))
		f.close()
		print("=== ", path)
		var probe := GDScript.new()
		probe.source_code = "\n".join(lines)
		print("RELOAD ", probe.reload())
		var numbered := PackedStringArray()
		for i in lines.size():
			numbered.append("%4d| %s" % [i + 1, lines[i]])
		var dump := FileAccess.open("res://../jc_logs/probe_%s.txt" % path.get_file(), FileAccess.WRITE)
		if dump:
			dump.store_string("\n".join(numbered))
			dump.close()
	get_tree().quit()
