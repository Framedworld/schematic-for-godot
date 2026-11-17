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

const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Reuse := preload("res://addons/schematic/core/sc_reuse.gd")


static func find(dir_path: String, out: Array) -> void:
	ProjectFiles.find(dir_path, ["gd"], out)


## Older documents lack a fingerprint. Compare their embedded graph with the actual script before writing.
static func matches_disk(text: String, bp: Dictionary) -> bool:
	if not Model.is_schematic_source(text) or bp.is_empty():
		return false
	if Model.stored_code_hash(text) != "":
		return not Model.code_edited(text)
	var c := Compiler.new()
	var code := c.compile(bp.duplicate(true))
	return not c.errors.any(func(e): return not e.w) and Model.code_part(text) == Model.normalize_code(Model.file_code(code, bp))


## Runs reuse over `files` ([{path, bp}]) and writes the ones that changed. Returns the report.
static func reuse(candidates: Array, library: String, dry: bool, quiet: bool) -> Dictionary:
	var started := Time.get_ticks_msec()
	var r := Reuse.new()
	var files := []
	var snapshots := {}
	var skipped := []
	for f in candidates:
		var text := FileAccess.get_file_as_string(f.path)
		var bp: Dictionary = f.bp if dry else Model.parse_source(text)
		if (dry and not Model.is_schematic_source(text)) or matches_disk(text, bp):
			files.append({"path": f.path, "bp": bp})
			snapshots[f.path] = text.md5_text()
		else:
			skipped.append(f.path)
			print("SKIP  %s  on-disk code differs from its graph" % f.path)
	if library != "":
		var dir := DirAccess.open(library.get_base_dir())
		if not ProjectFiles.includes_folder(library.get_base_dir()) or (dir != null and dir.is_link(library.get_file())):
			print("SKIP  %s  outside the project scan" % library)
			library = ""
		elif FileAccess.file_exists(library):
			var text := FileAccess.get_file_as_string(library)
			if not matches_disk(text, Model.parse_source(text)):
				print("SKIP  %s  shared library is not safe to rewrite" % library)
				library = ""
	# library macros that Schematics outside this run use have to stay
	var elsewhere := {}
	if library != "" and not dry and FileAccess.file_exists(library):
		# Keep every dependency still present on disk. If a write is skipped or fails, its old macros still work.
		var all := {}
		var paths := []
		find("res://", paths)
		for path in paths:
			all[path] = true
		for f in candidates:
			all[f.path] = true
		for path in all:
			if path == library or not FileAccess.get_file_as_string(path).contains(library):
				continue
			var other := Model.load_file(path)
			for g in other.get("graphs", []):
				for n in g.nodes:
					if n.kind == "macro" and String(n.p.get("lib", "")) == library:
						elsewhere[String(n.p.name)] = true
	var rep := r.run(files, "" if dry else library, elsewhere)
	rep["skipped"] = skipped
	if not quiet:
		for note in r.notes:
			print("      ", note)
	if not dry:
		for f in files:
			if not rep.changed.has(f.path):
				continue
			var c := Compiler.new()
			var code: String = c.compile(f.bp)
			if FileAccess.get_file_as_string(f.path).md5_text() != snapshots[f.path]:
				print("SKIP  %s  changed during reuse" % f.path)
				skipped.append(f.path)
				rep.changed.erase(f.path)
				continue
			var out := FileAccess.open(f.path, FileAccess.WRITE)
			if out == null or not out.store_string(Model.build_source(code, f.bp)):
				rep.changed.erase(f.path)
				skipped.append(f.path)
				push_error("Could not write " + String(f.path))
				continue
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
