extends RefCounted
## The work of tests/stress_convert.gd (see there), so that it can run as a script or as a scene.
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Checks := preload("res://tests/convert_checks.gd")
const LoggerScript := preload("res://addons/schematic/editor/sc_logger.gd")

const OUT := "res://tests/out/stress/"

var findings := {}     # kind -> {text -> [paths]}
var checks := Checks.new()


func find(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
	for sub in dir.get_directories():
		# (inside a project: not the plugin itself, nor these tests)
		if not sub.begins_with(".") and not dir_path.path_join(sub) in ["res://addons/schematic", "res://tests"]:
			find(dir_path.path_join(sub), out)


func found(kind: String, text: String, path: String) -> void:
	if not findings.has(kind):
		findings[kind] = {}
	if not findings[kind].has(text):
		findings[kind][text] = []
	findings[kind][text].append(path)


## Only the interface is needed after inspection. Release the disposable probe's bytecode while we own it.
func _inspect_probe(probe: GDScript) -> Dictionary:
	if probe == null:
		return {}
	var result := checks.interface(probe)
	probe.source_code = "extends RefCounted\n"
	probe.reload()
	return result


func run() -> void:
	T.refresh_globals()
	R.ensure_api()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var limit := 0
	var tag := "run"
	var files := []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--limit="):
			limit = int(arg.trim_prefix("--limit="))
		elif arg.begins_with("--tag="):
			tag = arg.trim_prefix("--tag=")
		elif arg.ends_with(".gd"):
			files.append(arg)
		else:
			find(String(arg).trim_suffix("/") if String(arg) != "res://" else "res://", files)
	var seen := {}
	var done := 0
	var loads := 0
	var lines := 0
	var as_code := 0
	var needs_project := 0
	var slow := []
	var watch := LoggerScript.new()
	for path in files:
		var src := FileAccess.get_file_as_string(path)
		var key := src.md5_text()
		if src.strip_edges() == "" or seen.has(key) or Model.is_schematic_source(src):
			continue
		seen[key] = true
		if limit > 0 and done >= limit:
			break
		done += 1
		var mark := FileAccess.open(OUT + tag + "_current.txt", FileAccess.WRITE)
		mark.store_string(path)
		mark.close()

		# 1. convert and compile; anything the converter's own scripts raise counts
		watch.items.clear()
		OS.add_logger(watch)
		var began := Time.get_ticks_msec()
		var in_project := String(path).begins_with("res://")
		var out: Variant = Importer.new().convert(src, {"path": path} if in_project else {})
		var c := Compiler.new()
		var code := ""
		if out is Dictionary and out.has("bp"):
			code = c.compile(out.bp)
		var took := Time.get_ticks_msec() - began
		OS.remove_logger(watch)
		for it in watch.items:
			if not String(it.file).contains("addons/schematic"):
				continue   # the engine saying a file of the script's own project is not here
			found("the converter raised an error", "%s:%d  %s" % [String(it.file).get_file(), it.line, checks.digits.sub(String(it.msg), "N", true)], path)
		if code == "":
			found("nothing came out", "no script", path)
			continue
		if took > 3000:
			slow.append("%d ms  %d lines  %s" % [took, src.count("\n"), path])
		var outside := false
		for e in c.errors:
			if not e.w and String(e.m).begins_with("Parent class "):
				outside = true   # it extends a class of its own project
			elif not e.w:
				found("the compiler reported an error", checks.digits.sub(String(e.m), "N", true), path)
		for note in out.report.notes:
			if String(note).contains("which is not in this project"):
				outside = true   # it extends a file of its own project
		if outside:
			needs_project += 1
			continue
		lines += int(out.report.lines)
		as_code += int(out.report.as_code)
		for note in out.report.notes:
			var s := String(note)
			if s.contains("kept as code ("):
				var reason := s.get_slice("kept as code (", 1).get_slice("):", 0)
				for cut in [" (", " '", "'"]:
					if reason.find(cut) > 0:
						reason = reason.substr(0, reason.find(cut))
				found("kept as code", reason if reason != "" and not reason.begins_with("'") else "a name this project does not have", path)

		# 2. nothing written in the source may go missing
		for gone in checks.missing(src, code):
			if gone[0] == "type":
				found("a type of another project left out (not counted)", String(gone[1]), path)
			else:
				found("gone after conversion: " + String(gone[0]), String(gone[1]).left(60), "%s  (%d in the source, %d after)" % [path, gone[2], gone[3]])

		# 3. does GDScript take it, and is it the same script to the rest of the project?
		var first: Array = checks.load_text(src)
		var original := _inspect_probe(first[0])
		var made: Array = checks.compile_loaded(out.bp)
		var as_saved := _inspect_probe(made[1])
		code = made[0]
		if not original.is_empty():
			loads += 1
			if as_saved.is_empty():
				for msg in made[2]:
					found("the original loads, the converted script does not", String(msg), path)
				continue
			# (a file with Windows line endings is saved with them, and a string over several lines holds them: what
			# counts is the file that would be written, not the compiler's text before it is saved)
			if bool(out.bp.get("crlf", false)):
				var written: Array = checks.load_text(Model.build_source(code, out.bp))
				as_saved = _inspect_probe(written[0])
				if as_saved.is_empty():
					for msg in written[1]:
						found("the converted script loads, the saved file does not", String(msg), path)
					continue
			for change in checks.interface_changes(original, as_saved):
				var kind := String(change[1]).get_slice(" ", 0)
				match String(change[0]):
					"missing":
						found("missing after conversion", kind, "%s  %s" % [path, change[1]])
					"added":
						found("added by conversion", kind, "%s  %s" % [path, change[1]])
					"typed":
						found("given a type by conversion", kind, "%s  %s\n        was: %s\n        now: %s" % [path, change[1], change[2], change[3]])
					_:
						found("different after conversion", kind, "%s  %s\n        was: %s\n        now: %s" % [path, change[1], change[2], change[3]])
		else:
			# (a complaint counts when it is still there after a local written with ":=" has gone back to its
			# stated type, which is what the editor does before it gives up on a conversion)
			for msg in made[3]:
				# (a class of the project that cannot be read is complained about in two wordings, depending on
				# whether it is first met as a type or as a call)
				var same_class := String(msg).replace("Could not parse global class ", "Could not resolve class ").get_slice(" from ", 0) + ", because of a parser error."
				if not first[1].has(msg) and not first[1].has(same_class) and made[2].has(msg):
					found("GDScript says something new about the converted script", String(msg), path)

		# 4. the schematic survives being saved
		var again: Variant = Model.parse_source(Model.build_source(code, out.bp))
		if not (again is Dictionary) or Compiler.new().compile(again) != code:
			found("different after save and load", "the script changed", path)

	var report := PackedStringArray()
	report.append("%d scripts converted (%d more extend a class or file of their own project), %d of them load in this project; %d statement lines, %d as nodes (%.2f%%), %d as code" % [
		done - needs_project, needs_project, loads, lines, lines - as_code, 100.0 * (lines - as_code) / maxf(lines, 1), as_code])
	var kinds := findings.keys()
	kinds.sort()
	var bad := 0
	for kind in kinds:
		var texts: Array = findings[kind].keys()
		texts.sort_custom(func(x, y): return findings[kind][x].size() > findings[kind][y].size())
		var total := 0
		for t in texts:
			total += findings[kind][t].size()
		if kind != "kept as code" and not kind.contains("not counted"):
			bad += total
		report.append("")
		report.append("== %s: %d" % [kind, total])
		for t in texts:
			report.append("  %5d  %s" % [findings[kind][t].size(), t])
			for p in findings[kind][t].slice(0, 3 if kind == "kept as code" else 6):
				report.append("           %s" % p)
	if not slow.is_empty():
		report.append("")
		report.append("== slow")
		for s in slow:
			report.append("  " + s)
	var f := FileAccess.open(OUT + tag + ".txt", FileAccess.WRITE)
	f.store_string("\n".join(report))
	f.close()
	print(report[0])
	print("STRESS FINDINGS: %d  (tests/out/stress/%s.txt)" % [bad, tag])
