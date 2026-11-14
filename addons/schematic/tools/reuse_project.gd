extends Node
## Finds groups of nodes that repeat in a project's Schematics and turns them into macros.
##
##   godot --headless --path <project> res://addons/schematic/tools/reuse_project.tscn
##   options after `--`:  --only=scripts,scenes (just these folders)   --dry (report only, write nothing)
##                        --library=res://shared_macros.gd (where macros shared between files go; "" for none)
##                        --quiet (no line per macro)
##
## A Schematic is only changed when the script generated from it stays the same (see core/sc_reuse.gd), so
## this is safe to run on a working project, and to run again. convert_project.tscn runs it after converting.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Reuse := preload("res://addons/schematic/core/sc_reuse.gd")


static func find(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
	for sub in dir.get_directories():
		if not sub.begins_with(".") and not (dir_path == "res://" and sub == "addons"):
			find(dir_path.path_join(sub), out)


## Runs reuse over `files` ([{path, bp}]) and writes the ones that changed. Returns the report.
static func reuse(files: Array, library: String, dry: bool, quiet: bool) -> Dictionary:
	var started := Time.get_ticks_msec()
	var r := Reuse.new()
	# library macros that Schematics outside this run use have to stay
	var elsewhere := {}
	if library != "" and not dry and FileAccess.file_exists(library):
		var mine := {}
		for f in files:
			mine[String(f.path)] = true
		var all := []
		find("res://", all)
		for path in all:
			if mine.has(path) or path == library or not FileAccess.get_file_as_string(path).contains(library):
				continue
			var other := Model.load_file(path)
			for g in other.get("graphs", []):
				for n in g.nodes:
					if n.kind == "macro" and String(n.p.get("lib", "")) == library:
						elsewhere[String(n.p.name)] = true
	var rep := r.run(files, "" if dry else library, elsewhere)
	if not quiet:
		for note in r.notes:
			print("      ", note)
	if not dry:
		for f in files:
			if not rep.changed.has(f.path):
				continue
			var c := Compiler.new()
			var code: String = c.compile(f.bp)
			var out := FileAccess.open(f.path, FileAccess.WRITE)
			out.store_string(Model.build_source(code, f.bp))
			out.close()
	print("reuse%s: %d macros in %d files, %d shared macros%s; %d uses; %d nodes before, %d after (%.1f%% fewer); %d files put back; %.1f s" % [
		" (dry run: macros shared between files are not looked for)" if dry else "",
		int(rep.macros), rep.changed.size(), int(rep.library), (" in " + library) if int(rep.library) > 0 else "", int(rep.uses),
		int(rep.before), int(rep.after), 100.0 * (int(rep.before) - int(rep.after)) / maxf(float(rep.before), 1.0), rep.undone.size(),
		(Time.get_ticks_msec() - started) / 1000.0])
	return rep


func _ready() -> void:
	T.refresh_globals()
	R.ensure_api()
	var args := OS.get_cmdline_user_args()
	var only := PackedStringArray()
	var library := "res://shared_macros.gd"
	for arg in args:
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=").split(",", false)
		if arg.begins_with("--library="):
			library = arg.trim_prefix("--library=")
	var paths := []
	if only.is_empty():
		find("res://", paths)
	for folder in only:
		find("res://" + folder.trim_suffix("/"), paths)
	var files := []
	for path in paths:
		if path == library or not Model.is_schematic_file(path):
			continue
		var bp := Model.load_file(path)
		if not bp.is_empty() and String(bp.get("library", "")) != "macro":
			files.append({"path": path, "bp": bp})
	reuse(files, library, args.has("--dry"), args.has("--quiet"))
	get_tree().quit()
