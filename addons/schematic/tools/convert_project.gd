extends Node
## Converts every hand-written GDScript of a project into a Schematic, in place.
##
##   godot --headless --path <project> res://addons/schematic/tools/convert_project.tscn
##   options after `--`:  --dry (only print the report)   --only=scripts,scenes (convert just these folders)
##                        --quiet (one line per script, no notes)
##                        --no-reuse (leave repeated groups of nodes as they are)
##                        --library=res://shared_macros.gd (where macros shared between scripts go)
##
## After converting, groups of nodes that repeat become macros (tools/reuse_project.gd). That changes the
## graphs only: the generated scripts stay the same.
##
## It runs as a scene of the project (not with --script) so the project's autoloads exist while its scripts
## are loaded and checked.
##
## The original of each script is kept next to it as <name>.gd.orig, and conversion always starts from that
## copy, so the tool can be run again. Run it, let Godot import the project (godot --headless --import), and
## run it a second time: the second run can use the classes the first one registered, so calls between
## scripts (to an autoload, for instance) become nodes instead of carried-over code.
## A script whose converted form does not compile is left as it was.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const ReuseTool := preload("res://addons/schematic/tools/reuse_project.gd")


func _find(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
	for sub in dir.get_directories():
		if not sub.begins_with(".") and not (dir_path == "res://" and sub == "addons"):
			_find(dir_path.path_join(sub), out)


## Does GDScript load this generated code? Fills `bad_lines` with the lines it complained about.
func _accepts(code: String, path: String, dry: bool, bad_lines: Array) -> bool:
	var logger: Object = null
	if ClassDB.class_exists("Logger"):
		logger = load("res://addons/schematic/editor/sc_logger.gd").new()
		OS.add_logger(logger)
	var accepted := _loads(code, path, dry)
	if logger != null:
		OS.remove_logger(logger)
		for it in logger.items:
			bad_lines.append(int(it.line))
	return accepted


func _loads(code: String, path: String, dry: bool) -> bool:
	var probe := GDScript.new()
	var probe_lines := code.split("\n")
	var own_name := ""
	for i in probe_lines.size():
		if probe_lines[i].begins_with("class_name "):
			own_name = probe_lines[i].trim_prefix("class_name ").strip_edges()
			probe_lines[i] = "#"
	var probe_text := "\n".join(probe_lines)
	if own_name != "":
		# It is checked without its class name (the file on disk holds that name), so references to its own
		# enums and constants through the name must point at this copy.
		probe_text = RegEx.create_from_string("\\b%s\\.(?!new\\b)" % own_name).sub(probe_text, "", true)
	probe.source_code = probe_text
	if probe.reload() == OK:
		return true
	# A script with a class name can fail this check only because the copy is not that class (its enums are
	# not the ones other scripts expect). Try it as the real thing, and put it back if it fails.
	var live := (load(path) as GDScript) if own_name != "" else null
	if live == null:
		return false
	var before := live.source_code
	live.source_code = code
	var accepted := live.reload(true) == OK
	if not accepted or dry:
		live.source_code = before
		live.reload(true)
	return accepted


func _ready() -> void:
	var dry := OS.get_cmdline_user_args().has("--dry")
	T.refresh_globals()
	R.ensure_api()
	var autoload_of := {}   # script path -> autoload name
	for prop in ProjectSettings.get_property_list():
		if String(prop.name).begins_with("autoload/"):
			autoload_of[String(ProjectSettings.get_setting(prop.name)).trim_prefix("*")] = String(prop.name).substr(9)
	var files := []
	var quiet := OS.get_cmdline_user_args().has("--quiet")
	var only := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=").split(",", false)
	if only.is_empty():
		_find("res://", files)
	for folder in only:
		_find("res://" + folder.trim_suffix("/"), files)
	var library := "res://shared_macros.gd"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--library="):
			library = arg.trim_prefix("--library=")
	var converted := []   # [{path, bp}] for reuse
	var failed := []
	var lines := 0
	var as_code := 0
	var done := 0
	for path in files:
		var orig: String = path + ".orig"
		var source := FileAccess.get_file_as_string(orig) if FileAccess.file_exists(orig) else FileAccess.get_file_as_string(path)
		if Model.is_schematic_source(source):
			continue   # made in the Schematic editor (or the macro library), nothing to convert
		var opts := {"path": path}
		# an autoload is reached by its name; giving its script a class name lets other schematics call it with nodes
		if autoload_of.has(path) and not source.contains("\nclass_name "):
			opts["class_name"] = "SC_" + String(autoload_of[path])
		var imp := Importer.new()
		var out := imp.convert(source, opts)
		var rep: Dictionary = out.report
		var code := ""
		var errs := []
		var given_up := 0   # locals written with ":=" that had to fall back to a stated type
		var accepted := false
		for attempt in 8:
			var c := Compiler.new()
			code = c.compile(out.bp)
			errs = c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
			if not errs.is_empty():
				break
			var bad_lines := []
			if _accepts(code, path, dry, bad_lines):
				accepted = true
				break
			var dropped := Compiler.drop_inferred(out.bp, code, bad_lines)
			given_up += dropped
			if dropped == 0:
				errs.append("GDScript rejected the generated code")
				break
		if errs.is_empty() and not accepted:
			errs.append("GDScript rejected the generated code")
		if given_up > 0 and not quiet:
			rep.notes.append("%d local(s) written with := are declared with a stated type instead" % given_up)
		print("%s  %s  %d of %d lines as nodes%s" % ["ok  " if errs.is_empty() else "FAIL", path, rep.as_nodes, rep.lines,
			"" if errs.is_empty() else "  -> left unchanged: " + "; ".join(errs)])
		if not quiet:
			for note in rep.notes:
				print("      ", note)
		if not errs.is_empty():
			failed.append(path)
			continue
		lines += int(rep.lines)
		as_code += int(rep.as_code)
		done += 1
		converted.append({"path": path, "bp": out.bp})
		if dry:
			continue
		if not FileAccess.file_exists(orig):
			var keep := FileAccess.open(orig, FileAccess.WRITE)
			keep.store_string(source)
			keep.close()
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(Model.build_source(code, out.bp))
		f.close()
	print("converted %d of %d scripts; %d of %d lines became nodes, %d were carried over as code" % [done, files.size(), lines - as_code, lines, as_code])
	for path in failed:
		print("left as GDScript: ", path)
	if not OS.get_cmdline_user_args().has("--no-reuse") and not converted.is_empty():
		ReuseTool.reuse(converted, library, dry, quiet)
	get_tree().quit()
