extends Node
## Brings code that was changed outside Schematic back into the graphs of a whole project, without the editor:
## what Re-import Code does in the editor for the one file that is open.
##
##   godot --headless --path <project> res://addons/schematic/tools/reimport_project.tscn
##   options after `--`:  --check (write nothing: say which Schematics' code is not their graph's, and whether
##                          it could be brought in; the exit code is then 1 if there is any, for a test run)
##                        --only=scripts,scenes (look in just these folders)
##                        --list=res://convert_list.txt (and at the scripts this file names, one res:// path a line)
##                        --quiet (one line per script, no details)
##                        --options=res://convert.options (read options from a file, one a line)
##
## A Schematic's file holds its code and, below it, the graph the code was written from. When the code is edited
## as text (by hand, by a merge, by another tool) the graph still says what the code said before. The script
## runs as edited, but the next save from the Schematic editor would write the graph's code over the edit.
## For each such file this tool rebuilds the functions and events whose code changed (SCSync.reimport, which
## accepts the result only if the new graph compiles to the file's code) and writes the file with its new graph.
## A file it cannot bring in is left exactly as it is and reported with the reason: open it in the editor, where
## Re-import Code shows the same reason beside the code.
##
## The exit code is 0 when every Schematic's code is its graph's when the tool is done, 1 otherwise.
## It runs as a scene of the project (not with --script) so the project's autoloads exist while scripts load.

const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Sync := preload("res://addons/schematic/core/sc_sync.gd")
const ConvertTool := preload("res://addons/schematic/tools/convert_project.gd")


## The Schematics among the scripts of the --only folders and the --list files (the whole project with neither).
static func scope(args: PackedStringArray) -> Array:
	var found := []
	var only := ConvertTool.list_arg(args, "only")
	var lists := ConvertTool.list_arg(args, "list")
	if only.is_empty() and lists.is_empty():
		ProjectFiles.find("res://", ["gd"], found)
	for folder in only:
		ProjectFiles.find("res://" + folder.trim_prefix("res://").trim_suffix("/"), ["gd"], found)
	for list in lists:
		for raw in FileAccess.get_file_as_string(list).split("\n"):
			var line := raw.strip_edges()
			if line != "" and not line.begins_with("#") and FileAccess.file_exists(line) and not found.has(line):
				found.append(line)
	return found.filter(func(path): return Model.is_schematic_file(path))


## True when the code in a Schematic's text is not the code its graph was last written with (a file from before
## the fingerprint was stored is compared with what its graph compiles to).
static func is_stale(text: String, bp: Dictionary) -> bool:
	if Model.stored_code_hash(text) != "":
		return Model.code_edited(text)
	var c := Compiler.new()
	var code := c.compile(bp.duplicate(true))
	return c.errors.any(func(e): return not e.w) or Model.code_part(text) != Model.normalize_code(Model.file_code(code, bp))


## Re-imports the code of the Schematic at `path` into its graph. Returns {state, why, report}: state is "same"
## (nothing to do), "done" (written, or with `check` could be), "refused" (left as it is: `why`), "unreadable".
static func reimport_file(path: String, check: bool) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var bp := Model.parse_source(text)
	if bp.is_empty():
		return {"state": "unreadable", "why": "it " + Model.unreadable_reason(text), "report": {}}
	if not is_stale(text, bp):
		return {"state": "same", "why": "", "report": {}}
	var r: Dictionary = Sync.new().reimport(bp, Model.code_part(text), {"dry": check, "path": path})
	var rep: Dictionary = r.report
	if not bool(r.ok):
		var reasons := PackedStringArray()
		for refusal in rep.get("refused", []):
			reasons.append("line %d (%s): %s" % [int(refusal.get("line", 0)), String(refusal.get("name", "")), String(refusal.get("reason", ""))])
		for d in rep.get("first_difference", []):
			reasons.append("%s, line %d: the file has `%s`, the rebuilt graph writes `%s`" % [String(d.get("name", "")), int(d.get("line", 0)),
				String(d.get("file", "")).strip_edges(), String(d.get("graph", "")).strip_edges()])
		if reasons.is_empty():
			reasons.append("the rebuilt graph does not compile to the file's code")
		return {"state": "refused", "why": "; ".join(reasons), "report": rep}
	if check:
		return {"state": "done", "why": "", "report": rep}
	var c := Compiler.new()
	var code := c.compile((r.bp as Dictionary).duplicate(true))
	var errors := c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
	if not errors.is_empty():
		return {"state": "refused", "why": "the rebuilt graph has errors: " + "; ".join(errors), "report": rep}
	if FileAccess.get_file_as_string(path) != text:
		return {"state": "refused", "why": "the file changed while it was being re-imported", "report": rep}
	var problem := Model.write_text(path, Model.build_source(code, r.bp))
	if problem != "":
		return {"state": "refused", "why": problem, "report": rep}
	return {"state": "done", "why": "", "report": rep}


## One line saying what a re-import did to the functions and declarations of a file.
static func summary(rep: Dictionary) -> String:
	var counts := {}
	for f in rep.get("functions", []) + rep.get("declarations", []):
		var action := String(f.get("action", "kept"))
		if action != "kept":
			counts[action] = int(counts.get(action, 0)) + 1
	var parts := PackedStringArray()
	for action in counts:
		parts.append("%d %s" % [int(counts[action]), action])
	if int(rep.get("comments_dropped", 0)) > 0:
		parts.append("%d comment(s) with nowhere to go in the graph" % int(rep.comments_dropped))
	if not (rep.get("reformatted", []) as Array).is_empty():
		parts.append("%d line(s) written in Schematic's style" % (rep.reformatted as Array).size())
	return ", ".join(parts) if not parts.is_empty() else "the graph already says the same"


func _ready() -> void:
	var args := ConvertTool.read_args(OS.get_cmdline_user_args())
	var check := args.has("--check")
	var quiet := args.has("--quiet")
	T.refresh_globals()
	R.ensure_api()
	var files := scope(args)
	var done := 0
	var left := 0
	for path in files:
		var result := reimport_file(path, check)
		match String(result.state):
			"same":
				continue
			"done":
				done += 1
				print("%s  %s  %s" % ["STALE" if check else "ok   ", path, ("can be re-imported: " if check else "") + summary(result.report)])
				if not quiet:
					for f in result.report.get("functions", []):
						if String(f.get("action", "kept")) != "kept":
							print("        %s %s: %s" % [String(f.get("kind", "function")), String(f.get("name", "")), String(f.get("action", ""))])
					for note in result.report.get("notes", []):
						print("        ", note)
			_:
				left += 1
				print("%s  %s  %s" % ["STALE" if check else "LEFT ", path, ("cannot be re-imported: " if check else "left as it is: ") + String(result.why)])
	if check:
		print("%d Schematic(s) checked; in %d the code is not the graph's (%d of them cannot be re-imported as they are)" % [files.size(), done + left, left])
	else:
		print("%d Schematic(s) checked; %d re-imported, %d left as they are" % [files.size(), done, left])
	get_tree().quit(1 if (left > 0 or (check and done > 0)) else 0)
