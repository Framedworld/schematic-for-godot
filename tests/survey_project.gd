extends SceneTree
## Dry run of the GDScript -> Blueprint converter over another project's folders (reads only, writes nothing).
##   godot --headless --path . --script res://tests/survey_project.gd -- <project dir> <folder> [<folder>...]
const Importer := preload("res://addons/blueprints/core/bp_importer.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")

func find(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			find(dir_path.path_join(sub), out)

func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	var args := OS.get_cmdline_user_args()
	var root_dir := String(args[0]).trim_suffix("/") + "/"
	var files := []
	for i in range(1, args.size()):
		find(root_dir + args[i], files)
	var lines := 0
	var code := 0
	var src_lines := 0
	var why := {}
	var decl := {"inner class": 0, "set/get": 0, "static function": 0, "const ": 0}
	for path in files:
		var src := FileAccess.get_file_as_string(path)
		src_lines += src.count("\n")
		var out: Dictionary = Importer.new().convert(src, {})
		lines += int(out.report.lines)
		code += int(out.report.as_code)
		for note in out.report.notes:
			var s := String(note)
			for key in decl:
				if s.contains(key):
					decl[key] += 1
			if s.contains("kept as code ("):
				var reason := s.get_slice("kept as code (", 1).get_slice("):", 0)
				for cut in [" (", " '", "'"]:
					if reason.find(cut) > 0:
						reason = reason.substr(0, reason.find(cut))
				if reason.begins_with("'") or reason == "":
					reason = "a name or property the dry run can't see (autoload, class or scene)"
				why[reason] = int(why.get(reason, 0)) + 1
	print("SURVEY %d scripts, %d source lines, %d statement lines: %d as nodes (%.0f%%), %d as code" % [files.size(), src_lines, lines, lines - code, 100.0 * (lines - code) / maxf(lines, 1), code])
	print("SURVEY declarations needing care: ", decl)
	var reasons := why.keys()
	reasons.sort_custom(func(a, b): return why[a] > why[b])
	for r in reasons.slice(0, 10):
		print("SURVEY why %5d  %s" % [why[r], r])
	quit()
