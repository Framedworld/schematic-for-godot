extends Node
## Converts every hand-written GDScript of a project into a Schematic, in place.
##
##   godot --headless --path <project> res://addons/schematic/tools/convert_project.tscn
##   options after `--`:  --dry (only print the report)   --only=scripts,scenes (convert just these folders)
##                        --list=res://convert_list.txt (and the scripts this file names: one res:// path a line,
##                          `#` starts a comment; with --only, both are converted; with neither, the whole project)
##                        --skip=scripts/tests,scripts/tools (never the scripts in these folders)
##                        --not-extending=BTAction,Limbo*,res://addons/ (never a script whose parent, at any depth,
##                          is one of these: a class, every class whose name begins so, or a script in a folder)
##                        --quiet (one line per script, no notes)
##                        --no-reuse (leave repeated groups of nodes as they are)
##                        --library=res://shared_macros.gd (where macros shared between scripts go)
##                        --again (convert from the kept original even if the Schematic was saved in the editor since)
##                        --drop-originals (remove the kept originals when done: for a project under version control)
##                        --no-autoload-names (do not give an autoload's script the class name SC_<AutoloadName>)
##                        --options=res://convert.options (read options from a file, one a line)
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
## A Schematic that was saved from the editor since it was converted is not converted again (that would write
## over what was changed in its graph): the converter marks what it writes, and a save from the editor takes
## the mark away. --again converts it from its kept original all the same.
## A script whose converted form does not compile is left as it was.

const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const ReuseTool := preload("res://addons/schematic/tools/reuse_project.gd")


func _find(dir_path: String, out: Array) -> void:
	ProjectFiles.find(dir_path, ["gd"], out)


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


## The options given after `--`, with those of every --options=<file> (one option a line, `#` starts a comment)
## put where the file was named, so an option written after it on the command line is the later one.
static func read_args(args: PackedStringArray, depth := 0) -> PackedStringArray:
	var out := PackedStringArray()
	for arg in args:
		if not arg.begins_with("--options=") or depth > 4:
			out.append(arg)
			continue
		var file := arg.trim_prefix("--options=")
		if not FileAccess.file_exists(file):
			print("SKIP  %s  the options file was not found" % file)
			continue
		var lines := PackedStringArray()
		for raw in FileAccess.get_file_as_string(file).split("\n"):
			var line := raw.strip_edges()
			if line != "" and not line.begins_with("#"):
				lines.append(line)
		out.append_array(read_args(lines, depth + 1))
	return out


## The values of every `--name=a,b` in `args`, together.
static func list_arg(args: PackedStringArray, name: String) -> PackedStringArray:
	var out := PackedStringArray()
	for arg in args:
		if arg.begins_with("--%s=" % name):
			out.append_array(arg.trim_prefix("--%s=" % name).split(",", false))
	return out


## True when the script's text gives it a class name (on any line, the first included).
static func has_class_name(source: String) -> bool:
	return source.begins_with("class_name ") or source.contains("\nclass_name ")


## What a script's text says it extends: a script path (res://...), or a class name as written; "RefCounted" when
## it says nothing. `class_paths` (class name -> script path) turns the name of a script class into its path.
static func parent_of(source: String, class_paths: Dictionary) -> String:
	for line in source.split("\n"):
		# `extends Y` on a line of its own, or `class_name X extends Y`
		var at := -1
		if line.begins_with("extends "):
			at = 0
		elif line.begins_with("class_name ") and line.contains(" extends "):
			at = line.find(" extends ") + 1
		if at == -1:
			continue
		var named := line.substr(at + 8).strip_edges().get_slice(" ", 0).get_slice("#", 0)
		if named.begins_with("\""):
			return named.trim_prefix("\"").trim_suffix("\"")
		named = named.get_slice(".", 0)
		return String(class_paths.get(named, named))
	return "RefCounted"


## For --not-extending: the parent (at any depth) that keeps the script at `path` as GDScript, or "" when none does.
## A pattern is a class name (`BTAction`; `BT*` for every name that begins so; a class of the engine also stands
## for the classes derived from it) or a folder (`res://addons/`: any script under it).
func _kept_parent(path: String, patterns: PackedStringArray, class_paths: Dictionary, depth := 0) -> String:
	if patterns.is_empty() or depth > 32:
		return ""
	var kept := path + ".orig"
	var parent := parent_of(FileAccess.get_file_as_string(kept if FileAccess.file_exists(kept) else path), class_paths)
	if parent.begins_with("res://"):
		var parent_name := ""
		for cn in class_paths:
			if String(class_paths[cn]) == parent:
				parent_name = String(cn)
		for pattern in patterns:
			if (pattern.begins_with("res://") and parent.begins_with(pattern)) or (parent_name != "" and _names(pattern, parent_name)):
				return parent_name if parent_name != "" else parent
		return _kept_parent(parent, patterns, class_paths, depth + 1)
	var cls := parent
	while cls != "":
		for pattern in patterns:
			if _names(pattern, cls):
				return cls
		cls = String(ClassDB.get_parent_class(cls)) if ClassDB.class_exists(cls) else ""
	return ""


static func _names(pattern: String, cls: String) -> bool:
	return cls.begins_with(pattern.trim_suffix("*")) if pattern.ends_with("*") else cls == pattern


## The scripts this run looks at: the whole project, or the --only folders and the --list files, without the
## --skip folders and the scripts --not-extending keeps.
func _scope(args: PackedStringArray) -> Array:
	var found := []
	var only := list_arg(args, "only")
	var lists := list_arg(args, "list")
	if only.is_empty() and lists.is_empty():
		_find("res://", found)
	for folder in only:
		_find("res://" + folder.trim_prefix("res://").trim_suffix("/"), found)
	for list in lists:
		if not FileAccess.file_exists(list):
			print("SKIP  %s  the list was not found" % list)
			continue
		for raw in FileAccess.get_file_as_string(list).split("\n"):
			var line := raw.strip_edges()
			if line == "" or line.begins_with("#"):
				continue
			if line.get_extension() != "gd" or not FileAccess.file_exists(line):
				print("SKIP  %s  listed in %s, but there is no such script" % [line, list.get_file()])
			elif not found.has(line):
				found.append(line)
	var skip := PackedStringArray()
	for folder in list_arg(args, "skip"):
		skip.append("res://" + folder.trim_prefix("res://").trim_suffix("/") + "/")
	var not_extending := list_arg(args, "not-extending")
	var class_paths := {}
	for entry in ProjectSettings.get_global_class_list():
		class_paths[String(entry["class"])] = String(entry["path"])
	var files := []
	var left := {}   # why -> how many scripts
	for path in found:
		var why := ""
		for folder in skip:
			if String(path).begins_with(folder):
				why = "in " + folder
		if why == "":
			var parent := _kept_parent(path, not_extending, class_paths)
			if parent != "":
				why = "extends " + parent
		if why == "":
			files.append(path)
		else:
			left[why] = int(left.get(why, 0)) + 1
	for why in left:
		print("left as GDScript: %d script(s) %s" % [int(left[why]), why])
	return files


func _ready() -> void:
	run(read_args(OS.get_cmdline_user_args()))
	get_tree().quit()


## Converts the scripts the options name. Returns {converted: [paths], failed: [paths], skipped: [paths]}.
func run(args: PackedStringArray) -> Dictionary:
	var dry := args.has("--dry")
	T.refresh_globals()
	R.ensure_api()
	var autoload_of := {}   # script path -> autoload name
	for prop in ProjectSettings.get_property_list():
		if String(prop.name).begins_with("autoload/"):
			autoload_of[String(ProjectSettings.get_setting(prop.name)).trim_prefix("*")] = String(prop.name).substr(9)
	var files := _scope(args)
	var quiet := args.has("--quiet")
	var again := args.has("--again")
	var library := "res://shared_macros.gd"
	for arg in args:
		if arg.begins_with("--library="):
			library = arg.trim_prefix("--library=")
	var converted := []   # [{path, bp}] for reuse
	var failed := []
	var skipped := []
	var lines := 0
	var as_code := 0
	var done := 0
	for path in files:
		var orig: String = path + ".orig"
		var current := FileAccess.get_file_as_string(path)
		var source := current
		if FileAccess.file_exists(orig):
			source = FileAccess.get_file_as_string(orig)
			if current != source and not ReuseTool.matches_disk(current, Model.parse_source(current)):
				print("SKIP  %s  edited since conversion" % path)
				skipped.append(path)
				continue
			# Converting from the kept original again would write over a graph that was changed in the editor.
			if current != source and not again and Model.is_schematic_source(current) and not Model.is_as_converted(current):
				print("SKIP  %s  saved from the Schematic editor since it was converted (or converted by Schematic 0.4.0 or older); --again converts it from %s anyway" % [path, orig.get_file()])
				skipped.append(path)
				continue
		if Model.is_schematic_source(source):
			continue   # made in the Schematic editor (or the macro library), nothing to convert
		var opts := {"path": path}
		# an autoload is reached by its name; giving its script a class name lets other schematics name its type
		# (they call it with nodes either way: without a class name it is known by its script's path)
		if autoload_of.has(path) and not has_class_name(source) and not args.has("--no-autoload-names"):
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
		if not dry:
			if FileAccess.get_file_as_string(path) != current:
				print("SKIP  %s  changed during conversion" % path)
				continue
			# (an .orig that is already there is the source this run converted from, so there is nothing to keep again)
			var problem := "" if FileAccess.file_exists(orig) else Model.write_text(orig, source)
			if problem == "":
				problem = Model.write_text(path, Model.build_source(code, out.bp, true))
			if problem != "":
				push_error("Not converted: " + problem)
				print("FAIL  %s  %s" % [path, problem])
				failed.append(path)
				continue
		lines += int(rep.lines)
		as_code += int(rep.as_code)
		done += 1
		converted.append({"path": path, "bp": out.bp})
	print("converted %d of %d scripts; %d of %d lines became nodes, %d were carried over as code" % [done, files.size(), lines - as_code, lines, as_code])
	for path in failed:
		print("left as GDScript: ", path)
	if not args.has("--no-reuse") and not converted.is_empty():
		ReuseTool.reuse(converted, library, dry, quiet)
	if args.has("--drop-originals") and not dry:
		var dropped := 0
		for path in files:
			if FileAccess.file_exists(String(path) + ".orig") and Model.is_schematic_file(path) \
					and DirAccess.remove_absolute(ProjectSettings.globalize_path(String(path) + ".orig")) == OK:
				dropped += 1
		print("removed the kept original of %d converted script(s)" % dropped)
	return {"converted": converted.map(func(c): return String(c.path)), "failed": failed, "skipped": skipped}
