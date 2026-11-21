extends Node
## Turns Orchestrator visual scripts (.torch / .os) into Schematics, so a project can drop Orchestrator.
##
##   godot --headless --path <project> res://addons/schematic/tools/import_orchestrator.tscn
##   (add `-- --dry` to only print what would happen)
##
## Each graph becomes <name>.gd beside the original, and every scene and script that named the .torch file
## is pointed at the new one. It reads the text form of the graph files, so Orchestrator need not be installed.
## Node kinds it knows: events, function entries, branches, autoloads, member function calls, variable gets,
## scene nodes and operators. A graph that uses anything else is reported and left alone.
## A call on an autoload is typed by the autoload's script, so it keeps the function's own pins; a call
## whose target cannot be worked out becomes a Call (by name).

const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")


func _find(dir_path: String, exts: Array, out: Array) -> void:
	ProjectFiles.find(dir_path, exts, out)


func _type_name(info: Dictionary) -> String:
	var t := T.from_info(info)
	return t if t != "" else "any"


## The class an autoload's functions are found on: its script's class name, or the script's path in quotes
## when it has none (the way `extends "res://base.gd"` names a script). "" when there is no such autoload.
func _autoload_class(autoload: String) -> String:
	var setting := "autoload/" + autoload
	if autoload == "" or not ProjectSettings.has_setting(setting):
		return ""
	var path := String(ProjectSettings.get_setting(setting)).trim_prefix("*")
	if path.get_extension() != "gd" or not ResourceLoader.exists(path):
		return "Node"
	var scr := load(path) as Script
	if scr == null:
		return "Node"
	return String(scr.get_global_name()) if scr.get_global_name() != &"" else "\"%s\"" % path


## Reads an Orchestrator text file into plain dictionaries:
## {base_type, brief_description, variables: [..], functions: [..], nodes: [..], connections: [..]}.
func parse_torch(path: String) -> Dictionary:
	var out := {"base_type": "Node", "brief_description": "", "variables": [], "functions": [], "nodes": [], "connections": []}
	var is_key := RegEx.create_from_string("^([A-Za-z_][A-Za-z0-9_]*) = (.*)$")
	var sections := []        # every [obj] / [resource] block as {__class, key: value text}
	var section := {}
	var key := ""
	for raw_line in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw_line.trim_suffix("\r")   # a file saved with Windows line endings reads the same
		if line.begins_with("[obj type=\"") or line == "[resource]":
			section = {"__class": "resource" if line == "[resource]" else line.get_slice("\"", 1)}
			sections.append(section)
			key = ""
			continue
		if line.begins_with("[orchestration") or section.is_empty():
			continue
		var m := is_key.search(line)
		# a new "name = value" line starts only when the previous value is complete
		if m != null and (key == "" or _balanced(String(section[key]))):
			key = m.get_string(1)
			section[key] = m.get_string(2)
		elif key != "":
			section[key] = String(section[key]) + "\n" + line
	for sec in sections:
		var cls := String(sec["__class"])
		for k in sec.keys():
			if k == "__class" or (cls == "resource" and k in ["variables", "functions", "nodes", "graphs"]):
				continue
			var text := String(sec[k]).strip_edges()
			var parsed: Variant = str_to_var(text)
			sec[k] = parsed if (parsed != null or text == "null") else text
		if cls == "resource":
			for k in ["base_type", "brief_description", "connections"]:
				if sec.has(k):
					out[k] = sec[k]
		elif cls == "OScriptVariable":
			out.variables.append(sec)
		elif cls == "OScriptFunction":
			out.functions.append(sec)
		elif cls.begins_with("OScriptNode"):
			out.nodes.append(sec)
	return out


func _balanced(text: String) -> bool:
	var depth := 0
	var quoted := false
	var i := 0
	while i < text.length():
		var c := text[i]
		if quoted:
			if c == "\\":
				i += 1
			elif c == "\"":
				quoted = false
		elif c == "\"":
			quoted = true
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		i += 1
	return depth <= 0 and not quoted


## Converts one parsed Orchestrator graph. Returns {bp, problems}.
func convert_graph(res: Dictionary) -> Dictionary:
	var problems := []
	var bp := Model.new_schematic(String(res.get("base_type")), "")
	bp.description = String(res.get("brief_description")) if res.get("brief_description") != null else ""
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	g.next_id = 1
	for v in res.get("variables"):
		var info: Dictionary = v.get("info") if v.get("info") is Dictionary else {"type": int(v.get("type", TYPE_NIL))}
		var def: Variant = v.get("default_value")
		bp.variables.append({"name": String(v.get("name")), "type": _type_name(info), "default": var_to_str(def) if def != null else "",
			"export": bool(v.get("exported")), "category": "" if String(v.get("category")) == "Default" else String(v.get("category")),
			"tooltip": String(v.get("description")) if v.get("description") != null else ""})
	var functions := {}   # guid -> method info
	for f in res.get("functions"):
		functions[String(f.get("guid"))] = f.get("method")

	var kinds := {}       # orchestrator node id -> its section
	for on in res.get("nodes"):
		kinds[int(on.get("id"))] = on
	var feeds := {}       # "to node:to input port" -> orchestrator node id wired into it
	var all_conns: Array = Array(res.get("connections"))
	for i in range(0, all_conns.size() - 3, 4):
		feeds["%d:%d" % [int(all_conns[i + 2]), int(all_conns[i + 3])]] = int(all_conns[i])

	# nodes
	var made := {}        # orchestrator node id -> schematic node
	var ins := {}         # orchestrator node id -> [schematic pin id per input port]
	var outs := {}
	var pure := {}        # nodes that have exec pins there and none here
	for on in res.get("nodes"):
		var oid := int(on.get("id"))
		var pos: Vector2 = on.get("position")
		var kind := String(on.get("__class"))
		var n := {}
		var in_ids := []
		var out_ids := []
		var pin_data: Array = on.get("pin_data")
		match kind:
			"OScriptNodeEvent", "OScriptNodeFunctionEntry":
				var method: Dictionary = functions.get(String(on.get("function_id")), {})
				var mname := String(method.get("name", "event"))
				var info := R.find_method(String(bp.parent), mname)
				if not info.is_empty() and bool(int(info.get("flags", 0)) & METHOD_FLAG_VIRTUAL):
					n = Model.add_node(g, "event", pos, {"name": mname})
				else:
					var params := []
					for a in method.get("args", []):
						params.append([String(a.name), _type_name(a)])
					n = Model.add_node(g, "custom_event", pos, {"name": mname, "params": params})
				for pd in pin_data:
					if int(pd.get("dir", 0)) == 1:
						out_ids.append("then" if String(pd.pin_name) == "ExecOut" else "p_" + T.ident(String(pd.pin_name)))
			"OScriptNodeCallMemberFunction":
				var cls := String(on.get("target_class_name"))
				var method := String(on.get("function_name"))
				var by_name := false
				if R.find_method(cls, method).is_empty():
					# Orchestrator calls it on whatever is wired to Target. An autoload names its script,
					# which gives the call its own pins; anything else is called by name, as it was.
					var port := 0
					var source := -1
					for pd in pin_data:
						if int(pd.get("dir", 0)) == 1:
							continue
						if String(pd.pin_name) == "target":
							source = int(feeds.get("%d:%d" % [oid, port], -1))
						port += 1
					var wired: Dictionary = kinds.get(source, {})
					var found := _autoload_class(String(wired.get("autoload", ""))) if String(wired.get("__class", "")) == "OScriptNodeAutoload" else ""
					if found != "" and not R.find_method(found, method).is_empty():
						cls = found
					else:
						by_name = true
				if by_name:
					var count := 0
					for pd in pin_data:
						if int(pd.get("dir", 0)) != 1 and not String(pd.pin_name) in ["ExecIn", "target"]:
							count += 1
					n = Model.add_node(g, "dyn_call", pos, {"method": method, "n": count})
					pure[oid] = false
				else:
					n = Model.add_node(g, "call", pos, {"cls": cls, "method": method})
					var d := R.describe(n, bp, g)
					if String(d.err) != "":
						problems.append("node %d: %s" % [oid, d.err])
					pure[oid] = bool(d.pure)
				var arg := 0
				for pd in pin_data:
					var pname := String(pd.pin_name)
					if int(pd.get("dir", 0)) == 1:
						out_ids.append("then" if pname == "ExecOut" else "ret")
						continue
					var pin_id := ""
					if pname == "ExecIn":
						pin_id = "exec"
					elif pname == "target":
						pin_id = "target"
					else:
						pin_id = ("v%d" if by_name else "a%d") % arg
						arg += 1
					in_ids.append(pin_id)
					if pd.has("dv") and pin_id != "exec":
						n.d[pin_id] = var_to_str(pd.dv)
			"OScriptNodeBranch":
				n = Model.add_node(g, "branch", pos, {})
				for pd in pin_data:
					var pname := String(pd.pin_name)
					if int(pd.get("dir", 0)) == 1:
						out_ids.append("true" if pname == "true" else "false")
					elif pname == "ExecIn":
						in_ids.append("exec")
					else:
						in_ids.append("cond")
						if pd.has("dv"):
							n.d["cond"] = var_to_str(pd.dv)
			"OScriptNodeAutoload":
				var al := String(on.get("autoload"))
				var al_cls := _autoload_class(al)
				n = Model.add_node(g, "autoload", pos, {"name": al, "cls": al_cls if al_cls != "" else "Node"})
				out_ids = ["value"]
			"OScriptNodeVariableGet":
				n = Model.add_node(g, "var_get", pos, {"name": String(on.get("variable_name"))})
				out_ids = ["value"]
			"OScriptNodeSceneNode":
				n = Model.add_node(g, "get_node", pos, {"path": String(on.get("node_path")), "cls": String(on.get("target_class_name"))})
				out_ids = ["node"]
			"OScriptNodeOperator":
				n = Model.add_node(g, "math", pos, {"op": String(on.get("code")), "n": 2})
				var at := 0
				for pd in pin_data:
					if int(pd.get("dir", 0)) == 1:
						out_ids.append("ret")
					else:
						in_ids.append("a%d" % at)
						if pd.has("dv"):
							n.d["a%d" % at] = var_to_str(pd.dv)
						at += 1
			_:
				problems.append("node %d is a %s, which this tool does not convert" % [oid, kind])
				continue
		made[oid] = n
		ins[oid] = in_ids
		outs[oid] = out_ids

	# wires: [from node, from output port, to node, to input port] by port index
	var conns := all_conns
	var exec_into := {}   # pure node id -> [from node, pin] feeding its exec in
	var exec_out := {}    # pure node id -> [[to node, pin]]
	var wires := []
	for i in range(0, conns.size() - 3, 4):
		var a := int(conns[i])
		var b := int(conns[i + 2])
		if not made.has(a) or not made.has(b):
			continue
		var ap: String = outs[a][int(conns[i + 1])] if int(conns[i + 1]) < outs[a].size() else ""
		var bpin: String = ins[b][int(conns[i + 3])] if int(conns[i + 3]) < ins[b].size() else ""
		if ap == "" or bpin == "":
			problems.append("a wire from node %d to node %d uses a pin this tool could not place" % [a, b])
			continue
		if bpin == "exec" and bool(pure.get(b, false)):
			exec_into[b] = [a, ap]
		elif ap == "then" and bool(pure.get(a, false)):
			if not exec_out.has(a):
				exec_out[a] = []
			exec_out[a].append([b, bpin])
		else:
			wires.append([a, ap, b, bpin])
	# a node that is pure here has no exec pins: execution passes straight through it
	var guard := 0
	var changed := true
	while changed and guard < 100:
		changed = false
		guard += 1
		for p_id in exec_into.keys():
			var src: Array = exec_into[p_id]
			for dst in exec_out.get(p_id, []):
				if bool(pure.get(int(dst[0]), false)) and String(dst[1]) == "exec":
					exec_into[int(dst[0])] = src
					changed = true
				else:
					wires.append([src[0], src[1], dst[0], dst[1]])
			exec_out.erase(p_id)
			exec_into.erase(p_id)
			if changed:
				break
	for w in wires:
		g.wires.append([int(made[w[0]].id), String(w[1]), int(made[w[2]].id), String(w[3])])
	return {"bp": bp, "problems": problems}


func _ready() -> void:
	var dry := OS.get_cmdline_user_args().has("--dry")
	T.refresh_globals()
	R.ensure_api()
	import_folder("res://", dry)
	get_tree().quit()


func import_folder(root: String, dry: bool) -> void:
	var graphs := []
	_find(root, ["torch", "os"], graphs)
	var renamed := {}
	var owners := {}
	for path: String in graphs:
		var key := path.get_basename().to_lower()
		owners[key] = int(owners.get(key, 0)) + 1
	for path: String in graphs:
		if owners[path.get_basename().to_lower()] > 1:
			print("SKIP  %s  multiple graphs share this script destination" % path)
			continue
		var res := parse_torch(path)
		if res.is_empty() or res.nodes.is_empty():
			print("FAIL  %s  could not be read as an Orchestrator text file" % path)
			continue
		var out := convert_graph(res)
		var c := Compiler.new()
		var code := c.compile(out.bp)
		var problems: Array = out.problems
		for e in c.errors:
			if not e.w:
				problems.append(String(e.m))
		if problems.is_empty():
			var probe := GDScript.new()
			probe.source_code = code
			if probe.reload() != OK:
				problems.append("GDScript rejected the generated code")
		var target := path.get_basename() + ".gd"
		var source := Model.build_source(code, out.bp)
		var dir := DirAccess.open(target.get_base_dir())
		if dir.is_link(target.get_file()):
			print("SKIP  %s  destination is a link" % path)
			continue
		var exists := FileAccess.file_exists(target)
		if exists and FileAccess.get_file_as_bytes(target) != source.to_utf8_buffer():
			print("SKIP  %s  %s already contains different content" % [path, target])
			continue
		var count := 0
		for gr in out.bp.graphs:
			count += gr.nodes.size()
		print("%s  %s  %d nodes, %d variables%s" % ["ok  " if problems.is_empty() else "FAIL", path, count, out.bp.variables.size(),
			"" if problems.is_empty() else "  -> left alone: " + "; ".join(problems)])
		if not problems.is_empty() or dry:
			continue
		if not exists:
			var problem := Model.write_text(target, source)
			if problem != "":
				push_error("Schematic: " + problem)
				continue
		renamed[path] = target
	# point everything that named the old file at the new one
	if not dry and not renamed.is_empty():
		var texts := []
		_find(root, ["tscn", "tres", "gd"], texts)
		var touched := 0
		for file in texts:
			var text := FileAccess.get_file_as_string(file)
			var before := text
			for old in renamed:
				text = text.replace(old, renamed[old])
			if text != before:
				var problem := Model.write_text(String(file), text)
				if problem != "":
					push_error("Could not update references: " + problem)
					continue
				touched += 1
		print("converted %d graph(s); updated %d file(s) that referred to them" % [renamed.size(), touched])
