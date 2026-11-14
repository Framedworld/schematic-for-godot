extends SceneTree
## The converter's torture test. Every script in tests/convert/ is a small program that uses one corner of
## GDScript and records what it sees in its variables. Each is run as written and again after conversion, and
## the two must agree on every value; the converted script must also offer other scripts exactly what the
## original did, and must still contain every string, number, node path and name the source wrote.
## Each sample is put through it twice: as the file is, and with Windows line endings.
##
##   godot --headless --path . --script res://tests/test_convert.gd [-- --only=<name> --show]
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Checks := preload("res://tests/convert_checks.gd")

const DIR := "res://tests/convert/"
const FRAMES := 14
## Statement lines each sample may leave as code nodes. Anything not listed must become nodes entirely; a
## number going up is a regression, a number going down should be lowered here.
const AS_CODE := {
	"functions": 1,   # a call that passes a varying number of arguments to "...rest"
	"control_flow": 4,   # a loop over a float, and one over a Vector2i
	"scoping": 2,   # giving a loop variable a new value
	"tree": 2,   # calling _input() and _unhandled_input() by hand
}

var fails := 0
var checks := Checks.new()


func check(label: String, ok: bool, detail := "") -> void:
	print("  %s  %s%s" % ["PASS" if ok else "FAIL", label, ("  " + detail) if (detail != "" and not ok) else ""])
	if not ok:
		fails += 1


func plain(v: Variant, depth := 0) -> Variant:
	if depth > 12:
		return "<deep>"
	match typeof(v):
		TYPE_FLOAT:
			return "nan" if is_nan(v) else (str(v) if is_inf(v) else snappedf(v, 0.0001))
		TYPE_ARRAY:
			return (v as Array).map(func(x): return plain(x, depth + 1))
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[str(plain(k, depth + 1))] = plain(v[k], depth + 1)
			return out
		TYPE_OBJECT:
			if not is_instance_valid(v):
				return "<freed>"
			if v is Node:
				return "<%s %s>" % [(v as Node).get_class(), (v as Node).name]
			return "<%s>" % (v as Object).get_class()
		TYPE_CALLABLE:
			return "<callable>"
		TYPE_SIGNAL:
			return "<signal %s>" % (v as Signal).get_name()
		TYPE_RID:
			return "<rid>"
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_QUATERNION, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_RECT2, TYPE_AABB, TYPE_PLANE:
			return "%s%s" % [type_string(typeof(v)), str(v)]
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			return [type_string(typeof(v))] + Array(v).map(func(x): return plain(x, depth + 1))
	return "%s:%s" % [type_string(typeof(v)), str(v)] if typeof(v) in [TYPE_INT, TYPE_STRING_NAME, TYPE_NODE_PATH, TYPE_BOOL, TYPE_NIL] else v


func snapshot(n: Object) -> Dictionary:
	var out := {}
	for p in (n.get_script() as Script).get_script_property_list():
		if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE and not String(p.name).begins_with("__"):
			out[String(p.name)] = plain(n.get(p.name))
	if n is Node:
		out["#children"] = (n as Node).get_children().map(func(c): return "%s %s" % [c.name, c.get_class()])
		out["#groups"] = (n as Node).get_groups().map(func(g): return String(g))
	if n is Node3D:
		out["#transform"] = plain((n as Node3D).transform)
	if n is Node2D:
		out["#transform"] = plain((n as Node2D).transform)
	return out


## Runs both scripts side by side through the same frames and returns their two snapshots.
func run_pair(a: GDScript, b: GDScript) -> Array:
	var made := []
	for scr in [a, b]:
		var base := String(scr.get_instance_base_type())
		var obj: Object = ClassDB.instantiate(base)
		obj.set_script(scr)
		made.append(obj)
	for obj in made:
		if obj is Node:
			var holder := Node.new()   # each in a parent of its own, so neither sees the other
			root.add_child(holder)
			holder.add_child(obj)
		elif obj.has_method("run"):
			obj.call("run")
	for i in FRAMES:
		await process_frame
	var snaps := [snapshot(made[0]), snapshot(made[1])]
	for obj in made:
		if obj is Node:
			(obj as Node).get_parent().queue_free()
	await process_frame
	return snaps


func judge(name: String, source: String, path: String) -> void:
	var original: Array = checks.load_text(source)
	if original[0] == null:
		check("%s: the sample itself loads" % name, false, str(original[1].keys()))
		return
	var imp := Importer.new()
	var out: Dictionary = imp.convert(source, {"path": path})
	var rep: Dictionary = out.report
	var c := Compiler.new()
	c.compile(out.bp)
	var errs := c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
	var made: Array = checks.compile_loaded(out.bp) if errs.is_empty() else ["", null, {}]
	var code: String = made[0]
	var show := OS.get_cmdline_user_args().has("--show")
	check("%s: converts and loads" % name, made[1] != null, "%s %s" % [str(errs), str(made[2].keys())])
	if made[1] == null or show:
		for note in rep.notes:
			print("    note: ", note)
		print(Compiler.new().compile(out.bp))
	if made[1] == null:
		return
	var allowed := int(AS_CODE.get(name.trim_suffix(" (crlf)"), 0))
	check("%s: %d of %d lines are nodes" % [name, rep.as_nodes, rep.lines], int(rep.as_code) <= allowed,
		"%d as code, %d allowed: %s" % [rep.as_code, allowed, str(rep.notes.filter(func(n): return String(n).contains("kept as code")))])
	if int(rep.as_code) < allowed:
		print("    (fewer lines stay as code than AS_CODE allows for %s: %d, not %d)" % [name, rep.as_code, allowed])
	var gone: Array = checks.missing(source.replace("\r\n", "\n"), code)
	check("%s: nothing written in it is missing" % name, gone.is_empty(), str(gone))
	# the file that would be written, read back
	var text := Model.build_source(code, out.bp)
	var again := Model.parse_source(text)
	check("%s: the same script after save and load" % name, not again.is_empty() and Compiler.new().compile(again) == code)
	var saved: Array = checks.load_text(text)
	check("%s: the saved file loads" % name, saved[0] != null, str(saved[1].keys()))
	if saved[0] == null:
		return
	var changes: Array = checks.interface_changes(checks.interface(original[0]), checks.interface(saved[0]))
	check("%s: the same functions, variables, signals and constants" % name, changes.is_empty(), str(changes))
	var snaps: Array = await run_pair(original[0], saved[0])
	var want: Dictionary = snaps[0]
	var got: Dictionary = snaps[1]
	var diff := []
	for k in want:
		if var_to_str(want[k]) != var_to_str(got.get(k, "<missing>")):
			diff.append("\n      %s\n        was %s\n        now %s" % [k, var_to_str(want[k]).replace("\n", " "), var_to_str(got.get(k, "<missing>")).replace("\n", " ")])
	check("%s: behaves the same (%d values)" % [name, want.size()], diff.is_empty(), "".join(diff))
	if not diff.is_empty() and not show:
		print(code)


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var names := []
	for f in DirAccess.get_files_at(DIR):
		if f.get_extension() == "gd" and not f.begins_with("_"):   # (files starting with "_" are what samples lean on)
			names.append(f.get_basename())
	names.sort()
	for name in names:
		if only != "" and name != only:
			continue
		var path: String = DIR + name + ".gd"
		var source := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
		await judge(name, source, path)
		await judge(name + " (crlf)", source.replace("\n", "\r\n"), path)
	print("\nCONVERT FAILS: %d" % fails)
	quit()
