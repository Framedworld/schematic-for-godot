@tool
extends RefCounted
## Node registry: turns a node record ({kind, p}) into pins/title/colour (`describe`) and produces the
## searchable action list for the palette. Everything callable comes from reflection (ClassDB, script
## classes, the bundled built-in type table), so new engine/project API shows up as nodes automatically.

const T := preload("res://addons/schematic/core/sc_types.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Aliases := preload("res://addons/schematic/core/sc_aliases.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")

const COL_EVENT := Color(0.62, 0.07, 0.07)
const COL_CALL := Color(0.12, 0.33, 0.62)
const COL_PURE := Color(0.27, 0.5, 0.2)
const COL_FLOW := Color(0.38, 0.38, 0.4)
const COL_VAR := Color(0.16, 0.45, 0.36)
const COL_CAST := Color(0.0, 0.42, 0.47)
const COL_FN := Color(0.45, 0.22, 0.62)
const COL_LATENT := Color(0.1, 0.42, 0.66)
const COL_ERR := Color(0.75, 0.1, 0.1)

const OP_WORDS := {"+": "add plus", "-": "subtract minus", "*": "multiply times", "/": "divide", "%": "modulo remainder",
	"<": "less", ">": "greater", "<=": "less equal", ">=": "greater equal", "==": "equal", "!=": "not equal",
	"**": "power", "<<": "shift left", ">>": "shift right", "&": "bitwise and", "|": "bitwise or", "^": "bitwise xor",
	"and": "and &&", "or": "or ||", "xor": "xor", "not": "not !", "unary-": "negate", "~": "bitwise not", "in": "in contains"}

static var api: Dictionary = {}

## Template nodes: small table-driven nodes that expand to a line or expression of GDScript.
## Other plugins can add their own with register_template() - the Schematic equivalent of a custom K2 node.
##   {title, cat, tip, search, pure, latent, node (needs a Node schematic), always (run even if outputs unused),
##    ins:  [[pin_id, label, type, default_literal or "self"]],
##    outs: [[pin_id, label, type]],
##    lines: ["statement using {pin_id}"],            # impure only
##    exprs: {out_pin_id: "expression using {pin_id}"},
##    helper: [name, "func header:", [[indent, "line"], ...]]}   # optional shared helper function
static var templates: Dictionary = {}
## Problems found while loading kits (see sc_kits.gd and docs/KITS.md), for the editor to show:
## [{addon, path, template, problem, message}]. Each is also written once to the Output.
static var kit_problems: Array = []


static func register_template(id: String, t: Dictionary) -> void:
	templates[id] = t


## Loads every kit again (an addon was switched on or off, added or removed, or its kit file changed).
static func reload_kits() -> void:
	Kits.reload_kits()


## The template a template node stands for: a registered one (by id), or one the node carries itself (nodes
## made for one thing in the project, such as a blackboard variable or a particular flow graph).
static func template_of(p: Dictionary) -> Dictionary:
	if p.get("t") is Dictionary:
		return p.t
	return templates.get(String(p.get("id", "")), {})


static func _builtin_templates() -> void:
	if templates.has("get_nodes_in_group"):
		return
	register_template("get_nodes_in_group", {"title": "Get All Nodes In Group", "cat": "Game|Groups", "pure": true, "node": true,
		"search": "get all actors with tag of class find", "tip": "Every node in the scene tree that belongs to the group.",
		"ins": [["group", "Group", "StringName", "&\"enemies\""]], "outs": [["ret", "Nodes", "Array[Node]"]],
		"exprs": {"ret": "get_tree().get_nodes_in_group({group})"}})
	register_template("get_first_node_in_group", {"title": "Get First Node In Group", "cat": "Game|Groups", "pure": true, "node": true,
		"search": "get actor with tag find player", "tip": "The first node in the group, or null.",
		"ins": [["group", "Group", "StringName", "&\"player\""]], "outs": [["ret", "Node", "Node"]],
		"exprs": {"ret": "get_tree().get_first_node_in_group({group})"}})
	register_template("tween_property", {"title": "Tween Property", "cat": "Game|Animation", "latent": true, "node": true,
		"search": "move component to interp lerp animate ease", "tip": "Smoothly animates a property to a value, then continues. Uses a Godot Tween.",
		"ins": [["target", "Target", "Object", "self"], ["property", "Property", "String", "\"position\""], ["final", "Final Value", "any", ""],
			["duration", "Duration", "float", "1.0"]],
		"outs": [], "lines": ["await create_tween().tween_property({target}, {property}, {final}, {duration}).finished"]})
	register_template("open_scene", {"title": "Open Scene (by Path)", "cat": "Game", "node": true, "search": "open level load map change scene",
		"tip": "Replaces the running scene with another one.",
		"ins": [["path", "Scene Path", "String", "\"res://\""]], "outs": [], "lines": ["get_tree().change_scene_to_file({path})"]})
	register_template("open_packed_scene", {"title": "Open Scene (Packed)", "cat": "Game", "node": true, "search": "open level load map change scene",
		"ins": [["scene", "Scene", "PackedScene", ""]], "outs": [], "lines": ["get_tree().change_scene_to_packed({scene})"]})
	register_template("reload_scene", {"title": "Reload Current Scene", "cat": "Game", "node": true, "search": "restart level",
		"ins": [], "outs": [], "lines": ["get_tree().reload_current_scene()"]})
	register_template("quit_game", {"title": "Quit Game", "cat": "Game", "node": true, "search": "exit close",
		"ins": [], "outs": [], "lines": ["get_tree().quit()"]})
	register_template("set_paused", {"title": "Set Game Paused", "cat": "Game", "node": true, "search": "pause",
		"ins": [["paused", "Paused", "bool", "true"]], "outs": [], "lines": ["get_tree().paused = {paused}"]})
	register_template("is_paused", {"title": "Is Game Paused", "cat": "Game", "pure": true, "node": true,
		"ins": [], "outs": [["ret", "Return Value", "bool"]], "exprs": {"ret": "get_tree().paused"}})
	register_template("destroy_node", {"title": "Destroy Node", "cat": "Game", "search": "destroy actor queue free delete remove kill",
		"tip": "Removes the node at the end of the frame (queue_free).",
		"ins": [["target", "Target", "Node", "self"]], "outs": [], "lines": ["{target}.queue_free()"]})
	register_template("delta_seconds", {"title": "Get World Delta Seconds", "cat": "Game|Time", "pure": true, "node": true, "search": "delta time frame",
		"ins": [], "outs": [["ret", "Return Value", "float"]], "exprs": {"ret": "get_process_delta_time()"}})
	register_template("game_time", {"title": "Get Game Time in Seconds", "cat": "Game|Time", "pure": true, "search": "time since start now ticks",
		"ins": [], "outs": [["ret", "Return Value", "float"]], "exprs": {"ret": "(Time.get_ticks_msec() / 1000.0)"}})
	register_template("set_timer", {"title": "Set Timer by Event", "cat": "Game|Time", "node": true, "always": true,
		"search": "timer repeat interval looping delay", "tip": "Calls an event after Time seconds, optionally repeating. Returns the Godot Timer node.",
		"ins": [["event", "Event", "Callable", ""], ["time", "Time", "float", "1.0"], ["looping", "Looping", "bool", "false"]],
		"outs": [["ret", "Return Value", "Timer"]], "exprs": {"ret": "__sc_set_timer({event}, {time}, {looping})"},
		"helper": ["__sc_set_timer", "func __sc_set_timer(event: Callable, time: float, looping: bool) -> Timer:", [
			[1, "var timer := Timer.new()"], [1, "timer.wait_time = maxf(time, 0.001)"], [1, "timer.one_shot = not looping"],
			[1, "add_child(timer)"], [1, "timer.timeout.connect(event)"],
			[1, "if not looping:"], [2, "timer.timeout.connect(timer.queue_free)"],
			[1, "timer.start()"], [1, "return timer"]]]})
	register_template("clear_timer", {"title": "Clear and Invalidate Timer", "cat": "Game|Time", "search": "stop timer",
		"ins": [["timer", "Timer", "Timer", ""]], "outs": [],
		"lines": ["if is_instance_valid({timer}):", "\t{timer}.queue_free()"]})
	register_template("add_to_group", {"title": "Add To Group", "cat": "Game|Groups", "search": "tag actor",
		"ins": [["target", "Target", "Node", "self"], ["group", "Group", "StringName", "&\"\""]], "outs": [], "lines": ["{target}.add_to_group({group})"]})
	register_template("is_in_group", {"title": "Is In Group", "cat": "Game|Groups", "pure": true, "search": "actor has tag",
		"ins": [["target", "Target", "Node", "self"], ["group", "Group", "StringName", "&\"\""]], "outs": [["ret", "Return Value", "bool"]],
		"exprs": {"ret": "{target}.is_in_group({group})"}})
	register_template("call_message", {"title": "Call Function If Present (Message)", "cat": "Utilities|Interface", "always": true,
		"search": "interface message duck has method", "tip": "Calls a function by name only if the target has it; silently does nothing otherwise (like an interface message).",
		"ins": [["target", "Target", "Object", ""], ["fn", "Function Name", "StringName", "&\"interact\""], ["arg", "Argument", "any", ""]],
		"outs": [["ret", "Return Value", "any"]],
		"exprs": {"ret": "__sc_message({target}, {fn}, {arg})"},
		"helper": ["__sc_message", "func __sc_message(target: Variant, fn: StringName, arg: Variant) -> Variant:", [
			[1, "if not is_instance_valid(target) or not target.has_method(fn):"], [2, "return null"],
			[1, "return target.call(fn) if target.get_method_argument_count(fn) == 0 else target.call(fn, arg)"]]]})
	register_template("range", {"title": "Range", "cat": "Utilities|Array", "pure": true, "search": "count step sequence numbers",
		"tip": "The whole numbers from Start up to (not including) Stop, Step apart. Step may be negative.",
		"ins": [["from", "Start", "int", "0"], ["to", "Stop", "int", "10"], ["step", "Step", "int", "1"]], "outs": [["ret", "Numbers", "Array[int]"]],
		"exprs": {"ret": "range({from}, {to}, {step})"}})
	# GDScript's own functions (the ones that are not in the global scope's list)
	register_template("gd_len", {"title": "Length", "cat": "Utilities", "pure": true, "search": "len size count length of string array dictionary",
		"tip": "How many characters a text has, or how many items an array or dictionary holds (GDScript's len).",
		"ins": [["value", "Value", "any", ""]], "outs": [["ret", "Length", "int"]], "exprs": {"ret": "len({value})"}})
	register_template("gd_char", {"title": "Character From Code", "cat": "Utilities|String", "pure": true, "search": "char unicode code point letter",
		"ins": [["code", "Code", "int", "65"]], "outs": [["ret", "Character", "String"]], "exprs": {"ret": "char({code})"}})
	register_template("gd_ord", {"title": "Code Of Character", "cat": "Utilities|String", "pure": true, "search": "ord unicode code point letter",
		"ins": [["text", "Character", "String", "\"A\""]], "outs": [["ret", "Code", "int"]], "exprs": {"ret": "ord({text})"}})
	register_template("gd_is_instance_of", {"title": "Is Instance Of", "cat": "Utilities", "pure": true, "search": "is a type class check",
		"tip": "True when the value is of the given type (a type number, a class or a script).",
		"ins": [["value", "Value", "any", ""], ["type", "Type", "any", ""]], "outs": [["ret", "Return Value", "bool"]],
		"exprs": {"ret": "is_instance_of({value}, {type})"}})
	register_template("gd_type_exists", {"title": "Type Exists", "cat": "Utilities", "pure": true, "search": "class exists",
		"ins": [["type", "Type Name", "StringName", "&\"Node\""]], "outs": [["ret", "Return Value", "bool"]], "exprs": {"ret": "type_exists({type})"}})
	register_template("gd_get_stack", {"title": "Get Call Stack", "cat": "Utilities|Debug", "pure": true, "search": "stack trace backtrace",
		"ins": [], "outs": [["ret", "Stack", "Array"]], "exprs": {"ret": "get_stack()"}})
	register_template("gd_print_stack", {"title": "Print Call Stack", "cat": "Utilities|Debug", "search": "stack trace backtrace",
		"ins": [], "outs": [], "lines": ["print_stack()"]})
	register_template("gd_assert", {"title": "Assert", "cat": "Utilities|Debug", "search": "ensure check verify must condition",
		"tip": "Stops with an error when the condition is false. It only does anything in debug builds, like GDScript's assert.",
		"ins": [["cond", "Condition", "bool", "true"], ["message", "Message", "String", "\"\""]], "outs": [], "lines": ["assert({cond}, {message})"]})
	register_template("wait", {"title": "Wait", "cat": "Game|Time", "latent": true, "node": true,
		"search": "delay sleep timer seconds await", "tip": "Waits this many seconds, then continues. Unlike Delay it keeps no state: every time it is reached it waits.",
		"ins": [["duration", "Seconds", "float", "1.0"]], "outs": [], "lines": ["await get_tree().create_timer({duration}).timeout"]})
	register_template("is_server", {"title": "Is Server (Has Authority)", "cat": "Game|Multiplayer", "pure": true, "node": true,
		"search": "switch has authority network host", "tip": "True on the server / host, and in single player.",
		"ins": [], "outs": [["ret", "Return Value", "bool"]], "exprs": {"ret": "multiplayer.is_server()"}})
	register_template("input_vector", {"title": "Get Input Vector", "cat": "Input", "pure": true,
		"search": "input axis movement wasd move direction", "tip": "A direction from four input actions, e.g. for top-down or left/right movement.",
		"ins": [["left", "Left Action", "StringName", "&\"ui_left\""], ["right", "Right Action", "StringName", "&\"ui_right\""],
			["up", "Up Action", "StringName", "&\"ui_up\""], ["down", "Down Action", "StringName", "&\"ui_down\""]],
		"outs": [["ret", "Return Value", "Vector2"]], "exprs": {"ret": "Input.get_vector({left}, {right}, {up}, {down})"}})
	register_template("input_axis", {"title": "Get Input Axis", "cat": "Input", "pure": true, "search": "input axis value",
		"ins": [["neg", "Negative Action", "StringName", "&\"ui_left\""], ["pos", "Positive Action", "StringName", "&\"ui_right\""]],
		"outs": [["ret", "Return Value", "float"]], "exprs": {"ret": "Input.get_axis({neg}, {pos})"}})
	register_template("action_pressed", {"title": "Is Input Action Pressed", "cat": "Input", "pure": true, "search": "input key down held",
		"ins": [["action", "Action", "StringName", "&\"ui_accept\""]], "outs": [["ret", "Return Value", "bool"]],
		"exprs": {"ret": "Input.is_action_pressed({action})"}})
	register_template("load_async", {"title": "Async Load Asset", "cat": "Utilities|Asset", "latent": true, "node": true, "always": true,
		"search": "load asset async streaming background resource", "tip": "Loads a resource in the background and continues when it is ready.",
		"ins": [["path", "Path", "String", "\"res://\""]], "outs": [["ret", "Object", "Resource"]],
		"exprs": {"ret": "await __sc_load_async({path})"},
		"helper": ["__sc_load_async", "func __sc_load_async(path: String) -> Resource:", [
			[1, "ResourceLoader.load_threaded_request(path)"],
			[1, "while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:"],
			[2, "await get_tree().process_frame"],
			[1, "return ResourceLoader.load_threaded_get(path)"]]]})
	register_template("load_sync", {"title": "Load Asset", "cat": "Utilities|Asset", "pure": true, "search": "load resource",
		"ins": [["path", "Path", "String", "\"res://\""]], "outs": [["ret", "Object", "Resource"]], "exprs": {"ret": "load({path})"}})
	register_template("anim_travel", {"title": "Travel To Animation State", "cat": "Game|Animation",
		"search": "animation schematic state machine transition anim tree play", "tip": "Asks an AnimationTree's state machine to travel to a state (Godot's equivalent of driving an Anim Schematic state machine).",
		"ins": [["tree", "Animation Tree", "AnimationTree", ""], ["state", "State", "StringName", "&\"idle\""]], "outs": [],
		"lines": ["({tree}.get(\"parameters/playback\") as AnimationNodeStateMachinePlayback).travel({state})"]})
	register_template("anim_state", {"title": "Get Current Animation State", "cat": "Game|Animation", "pure": true,
		"search": "animation schematic state machine anim tree", "ins": [["tree", "Animation Tree", "AnimationTree", ""]],
		"outs": [["ret", "State", "StringName"]],
		"exprs": {"ret": "({tree}.get(\"parameters/playback\") as AnimationNodeStateMachinePlayback).get_current_node()"}})
	register_template("anim_set_param", {"title": "Set Animation Parameter", "cat": "Game|Animation",
		"search": "animation schematic blend space anim tree variable", "tip": "Sets an AnimationTree parameter such as a blend position or a transition condition.",
		"ins": [["tree", "Animation Tree", "AnimationTree", ""], ["name", "Parameter", "String", "\"blend_position\""], ["value", "Value", "any", "0.0"]],
		"outs": [], "lines": ["{tree}.set(\"parameters/\" + {name}, {value})"]})
	register_template("anim_get_param", {"title": "Get Animation Parameter", "cat": "Game|Animation", "pure": true,
		"search": "animation schematic anim tree variable", "ins": [["tree", "Animation Tree", "AnimationTree", ""], ["name", "Parameter", "String", "\"blend_position\""]],
		"outs": [["ret", "Value", "any"]], "exprs": {"ret": "{tree}.get(\"parameters/\" + {name})"}})
	register_template("implements", {"title": "Does Implement (has function)", "cat": "Utilities|Interface", "pure": true,
		"search": "interface has method", "ins": [["target", "Target", "Object", ""], ["fn", "Function Name", "StringName", "&\"interact\""]],
		"outs": [["ret", "Return Value", "bool"]], "exprs": {"ret": "(is_instance_valid({target}) and {target}.has_method({fn}))"}})
static var _cls_cache: Dictionary = {}   # class -> {m:{}, p:{}, s:{}}
static var _static_actions: Array = []
static var _class_actions: Dictionary = {}  # class -> Array (own members only)
static var _all_class_actions: Array = []


static func ensure_api() -> void:
	if not api.is_empty():
		return
	var f := FileAccess.open("res://addons/schematic/data/api.json", FileAccess.READ)
	if f:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			api = parsed
	if api.is_empty():
		api = {"utils": [], "types": {}, "enums": {}, "docs": {}}
	# The utility functions and built-in type methods offered as nodes come from this file, made from one Godot
	# version (tools/gen_api.py, from the oldest version supported). On an older engine some of them do not exist.
	var made_for: Array = api.get("engine", [])
	var running := Engine.get_version_info()
	if made_for.size() == 2 and (int(running.major) < int(made_for[0]) or (int(running.major) == int(made_for[0]) and int(running.minor) < int(made_for[1]))):
		push_warning("Schematic: its list of built-in functions was made for Godot %d.%d and this is Godot %d.%d. A node for a function this version does not have gives code that does not load." % [
			int(made_for[0]), int(made_for[1]), int(running.major), int(running.minor)])
	_builtin_templates()
	Kits.register(load("res://addons/schematic/core/sc_registry.gd"))


static func invalidate_scripts() -> void:
	T.refresh_globals()
	for c in _cls_cache.keys():
		if not ClassDB.class_exists(c):
			_cls_cache.erase(c)
	for key in _class_actions.keys():
		if not ClassDB.class_exists(String(key).get_slice("@", 0)):
			_class_actions.erase(key)


# ---------------------------------------------------------------- libraries
# A schematic with "library": "function" compiles its functions as static, so any schematic can call them
# without an instance (Unreal's Blueprint Function Library). One with "library": "macro" publishes its macros
# to every schematic in the project (Schematic Macro Library); they are expanded from the library file at
# compile time.

static var editing_path := ""            # the file open in the editor: its own macros are not listed twice
static var _lib_cache: Dictionary = {}   # path -> {mt, bp}
static var _lib_list: Array = []         # [{path, kind, name}]
static var _lib_scanned := false


## Call after schematic files were saved, added or removed.
static func invalidate_libraries() -> void:
	_lib_scanned = false
	Kits.invalidate()
	_lib_cache.clear()


## The schematic stored in a file ({} when it is not a schematic), cached until the file changes.
static func library_bp(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var mt := FileAccess.get_modified_time(path)
	if _lib_cache.has(path) and int(_lib_cache[path].mt) == mt:
		return _lib_cache[path].bp
	var lbp := Model.load_file(path)
	# a library macro that uses another macro of the same library keeps pointing at that library
	for g in lbp.get("graphs", []):
		for n in g.nodes:
			if n.kind == "macro" and not n.p.has("lib"):
				n.p["lib"] = path
	_lib_cache[path] = {"mt": mt, "bp": lbp}
	return lbp


## Every function or macro library in the project: [{path, kind: "function"|"macro", name}].
static func libraries() -> Array:
	if not _lib_scanned:
		_lib_list = []
		_scan_libraries("res://")
		_lib_scanned = true
	return _lib_list


static func _scan_libraries(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# another project kept inside this one is not part of this project
	if dir_path != "res://" and dir.file_exists("project.godot"):
		return
	for f in dir.get_files():
		var path := dir_path.path_join(f)
		if f.get_extension() == "gd" and Model.is_schematic_file(path):
			var lbp := library_bp(path)
			if String(lbp.get("library", "")) != "":
				var cn := String(lbp.get("class_name", ""))
				_lib_list.append({"path": path, "kind": String(lbp.library), "name": cn if cn != "" else f.get_basename()})
	for sub in dir.get_directories():
		if not sub.begins_with(".") and not (dir_path == "res://" and sub == "addons"):
			_scan_libraries(dir_path.path_join(sub))


## The macro graph a macro node stands for: one of this schematic's own, or one from a macro library.
static func macro_graph(bp: Dictionary, p: Dictionary) -> Dictionary:
	var lib := String(p.get("lib", ""))
	var owner := bp if lib == "" else library_bp(lib)
	if not owner.has("graphs"):
		return {}   # the library file is gone
	var g := Model.graph_named(owner, String(p.get("name", "")))
	return g if (not g.is_empty() and g.kind == "macro") else {}


## The function graph behind a function-library call, or {} when `cls` is not a function library.
static func library_function(cls: String, method: String) -> Dictionary:
	var info: Dictionary = T.globals().get(cls, {})
	if info.is_empty():
		return {}
	var lbp := library_bp(String(info.path))
	if String(lbp.get("library", "")) != "function":
		return {}
	var g := Model.graph_named(lbp, method)
	return g if (not g.is_empty() and g.kind == "function") else {}


# ---------------------------------------------------------------- interfaces
# A schematic with "library": "interface" is a Schematic Interface: a named list of functions (name, inputs,
# outputs, no body). A schematic that lists it under Class Settings > Interfaces has to have those functions.
# GDScript has no interfaces, so "implements" means "has every one of those functions", which is also true of a
# hand-written script that defines them.

## The class names of every Schematic Interface in the project.
static func interfaces() -> Array:
	var out := []
	for lib in libraries():
		if lib.kind == "interface":
			out.append(String(lib.name))
	return out


static func interface_bp(iface: String) -> Dictionary:
	for lib in libraries():
		if lib.kind == "interface" and String(lib.name) == iface:
			return library_bp(String(lib.path))
	return {}


## The function graphs of an interface: each gives a name, inputs and outputs.
static func interface_functions(iface: String) -> Array:
	var out := []
	for g in interface_bp(iface).get("graphs", []):
		if g.kind == "function":
			out.append(g)
	return out


static func interface_function(iface: String, fn: String) -> Dictionary:
	for g in interface_functions(iface):
		if String(g.name) == fn:
			return g
	return {}


static func nice(s: String) -> String:
	return s.trim_prefix("_").capitalize()


static func api_type(t: String) -> String:
	if t == "Variant" or t == "":
		return "any" if t == "Variant" else ""
	if t.begins_with("enum::") or t.begins_with("bitfield::"):
		return "int"
	if t.begins_with("typedarray::"):
		return "Array"
	return t


static func doc(cls: String, key: String) -> String:
	ensure_api()
	var guard := 0
	while cls != "" and guard < 64:
		var d: Dictionary = api.docs.get(cls, {})
		if d.has(key):
			return d[key]
		cls = T.parent_of(cls)
		guard += 1
	return ""


# ---------------------------------------------------------------- reflection

static func cls_info(cls: String) -> Dictionary:
	if _cls_cache.has(cls):
		return _cls_cache[cls]
	var out := {"m": {}, "p": {}, "s": {}}
	if ClassDB.class_exists(cls):
		for m in ClassDB.class_get_method_list(cls, true):
			out.m[String(m.name)] = m
		for p in ClassDB.class_get_property_list(cls, true):
			if int(p.usage) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP):
				continue
			if String(p.name).contains("/"):
				continue
			out.p[String(p.name)] = p
		for s in ClassDB.class_get_signal_list(cls, true):
			out.s[String(s.name)] = s
	elif not T.script_entry(cls).is_empty():
		var scr: Script = load(T.script_entry(cls).path) as Script
		if scr:
			for m in scr.get_script_method_list():
				if not out.m.has(String(m.name)):
					out.m[String(m.name)] = m
			for p in scr.get_script_property_list():
				if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					out.p[String(p.name)] = p
			for s in scr.get_script_signal_list():
				out.s[String(s.name)] = s
	_cls_cache[cls] = out
	return out


static func _find(cls: String, bucket: String, name: String) -> Dictionary:
	var guard := 0
	while cls != "" and guard < 64:
		var b: Dictionary = cls_info(cls)[bucket]
		if b.has(name):
			return b[name]
		cls = T.parent_of(cls)
		guard += 1
	return {}


static func find_method(cls: String, name: String) -> Dictionary:
	return _find(cls, "m", name)


static func find_property(cls: String, name: String) -> Dictionary:
	return _find(cls, "p", name)


static func find_signal(cls: String, name: String) -> Dictionary:
	return _find(cls, "s", name)


static func enum_values(en: String) -> Array:
	ensure_api()
	if en.begins_with("@"):   # an enum declared in the schematic being described
		var out_local := []
		for be in _ctx_enums:
			if String(be.name) == en.substr(1):
				for i in be.values.size():
					out_local.append([String(be.values[i]), i])
		return out_local
	if en.contains("."):
		var parts := en.split(".")
		var out := []
		if ClassDB.class_exists(parts[0]):
			for c in ClassDB.class_get_enum_constants(parts[0], parts[1], true):
				out.append([String(c), ClassDB.class_get_integer_constant(parts[0], c)])
		return out
	return api.enums.get(en, [])


static func builtin_method(type: String, name: String) -> Dictionary:
	ensure_api()
	for m in api.types.get(type, {}).get("m", []):
		if m.n == name:
			return m
	return {}


static func util(name: String) -> Dictionary:
	ensure_api()
	for u in api.utils:
		if u.n == name:
			return u
	return {}


# ---------------------------------------------------------------- describe

static func _pin(id: String, name: String, type: String, extra := {}) -> Dictionary:
	var p := {"id": id, "name": name, "type": type}
	p.merge(extra)
	return p


static func _exec_in() -> Dictionary:
	return _pin("exec", "", "exec")


static func _exec_out(id := "then", name := "") -> Dictionary:
	return _pin(id, name, "exec")


static func _params(list: Array, prefix := "") -> Array:
	var out := []
	for i in list.size():
		var extra := {"def": String(list[i][2])} if (list[i].size() > 2 and String(list[i][2]) != "" and prefix == "a_") else {}
		out.append(_pin(prefix + T.ident(String(list[i][0])), String(list[i][0]), String(list[i][1]), extra))
	return out


static func _method_arg_pins(info: Dictionary) -> Array:
	var out := []
	var args: Array = info.get("args", [])
	var defs: Array = info.get("default_args", [])
	for i in args.size():
		var a: Dictionary = args[i]
		var extra := {}
		var en := T.enum_from_info(a)
		if en != "":
			extra["enum"] = en
		var di := i - (args.size() - defs.size())
		if di >= 0:
			extra["def"] = T.to_literal(defs[di])
		out.append(_pin("a%d" % i, String(a.name), T.from_info(a), extra))
	return out


## The class a schematic's `self` belongs to for type checks.
static func self_class(bp: Dictionary) -> String:
	return String(bp.get("parent", "Node"))


## Returns {title, sub, color, pure, compact, latent, ins:[pin], outs:[pin], tip, err}.
static var _ctx_enums: Array = []

## Struct types whose pins can be split into their members (Unreal's "Split Struct Pin").
const SPLIT := {"Vector2": [["x", "y"], "float"], "Vector2i": [["x", "y"], "int"], "Vector3": [["x", "y", "z"], "float"],
	"Vector3i": [["x", "y", "z"], "int"], "Vector4": [["x", "y", "z", "w"], "float"], "Vector4i": [["x", "y", "z", "w"], "int"],
	"Color": [["r", "g", "b", "a"], "float"], "Quaternion": [["x", "y", "z", "w"], "float"]}


## Returns {title, sub, color, pure, compact, latent, ins:[pin], outs:[pin], tip, err}, with split pins expanded.
static func describe(node: Dictionary, bp: Dictionary, graph: Dictionary = {}) -> Dictionary:
	_ctx_enums = bp.get("enums", [])
	var d := describe_raw(node, bp, graph)
	var split: Dictionary = node.get("split", {})
	if split.is_empty():
		return d
	for side in ["ins", "outs"]:
		var pins := []
		for pin in d[side]:
			if split.has(pin.id) and SPLIT.has(String(pin.type)):
				var label := String(pin.name) if String(pin.name) != "" else String(pin.type)
				for m in SPLIT[String(pin.type)][0]:
					pins.append(_pin("%s~%s" % [pin.id, m], "%s %s" % [label, String(m).to_upper()], String(SPLIT[String(pin.type)][1]),
						{"def": "1" if (m in ["a", "w"] and String(pin.type) in ["Color", "Quaternion"]) else "0"} if side == "ins" else {}))
			else:
				pins.append(pin)
		d[side] = pins
	return d


## Call nodes that can be told to run in place (`inline`) or to wait for what they call (`await`).
const CALL_KINDS := ["call", "bcall", "util", "call_self", "call_parent", "dyn_call"]


static func describe_raw(node: Dictionary, bp: Dictionary, graph: Dictionary = {}) -> Dictionary:
	var d := _describe_kind(node, bp, graph)
	if bool(d.get("missing", false)):
		_placeholder_pins(d, node, bp, graph)
		return d
	var p: Dictionary = node.get("p", {})
	if node.kind in CALL_KINDS:
		if bool(p.get("await", false)):
			# waits for a function that itself waits (a coroutine), exactly like `await f()`
			d.latent = true
			d.color = COL_LATENT
			d.sub = (String(d.sub) + "  -  waits for it").trim_prefix("  -  ")
		if bool(p.get("exec", false)) and bool(d.pure):
			# a call the engine marks as changing nothing, used as a step all the same (calling a Callable, say)
			d.pure = false
			d.color = COL_CALL
			d.ins.push_front(_exec_in())
			d.outs.push_front(_exec_out())
		if bool(p.get("inline", false)) and not bool(d.pure) and d.outs.any(func(o): return o.type != "exec"):
			# runs where its value is read, not on the execution wire: what `a and f()` or `g(x, f())` needs
			d.pure = true
			d.ins = d.ins.filter(func(i): return i.type != "exec")
			d.outs = d.outs.filter(func(o): return o.type != "exec")
			d.sub = (String(d.sub) + "  -  runs in place").trim_prefix("  -  ")
	elif node.kind in ["sequence", "for", "for_each", "for_each_dict", "while"] and bool(p.get("wait", false)):
		d.sub = "waits for each step"
	if node.kind in ["set_prop", "var_set", "local_set", "dyn_set"] and String(p.get("op", "")) != "":
		# changes what is there by an amount (`x += ...`, `scale *= ...`) instead of replacing it
		for pin in d.ins:
			if pin.id == "value":
				pin["type"] = "any"
				pin["name"] = "%s=" % p.op
				pin.erase("enum")
		d.outs = d.outs.filter(func(o): return o.id != "out")
		d.title = "%s  %s=" % [d.title, p.op]
	if node.kind in ["set_prop", "var_set", "local_set"] and String(p.get("part", "")) != "":
		# sets one member of a struct value in place (`velocity.x = ...`)
		for pin in d.ins:
			if pin.id == "value" and SPLIT.has(String(pin.type)):
				pin["type"] = String(SPLIT[String(pin.type)][1])
				pin["name"] = "%s %s" % [pin.name, String(p.part).to_upper()]
				pin.erase("enum")
			elif pin.id == "value" and String(p.get("op", "")) != "":
				pin["name"] = "%s %s" % [String(p.part).to_upper(), pin.name]
		d.outs = d.outs.filter(func(o): return o.id != "out")
		d.title = "%s %s" % [d.title, String(p.part).to_upper()]
	return d


## A node this editor cannot describe (its addon is not installed or enabled, a newer version of the plugin
## wrote it, the library or class it uses is gone) is a placeholder: it gets a pin for every wire the graph has
## on it, named by the pin id the wire stores and typed from the other end of the wire where that is known, so
## its wires stay in the graph exactly as loaded (the graph view prunes only wires to pins that are really
## gone). The pins are marked `orphan`: the graph accepts no new connections to them. When the node can be
## described again, it is a normal node with the same pins and wires.
static var _placeholder_depth := 0


static func _placeholder_pins(d: Dictionary, node: Dictionary, bp: Dictionary, graph: Dictionary) -> void:
	d.ins = []
	d.outs = []
	d.pure = false
	d.latent = false
	d.compact = false
	d.color = COL_ERR
	if graph.is_empty():
		return
	var id := int(node.get("id", -1))
	var seen_in := {}
	var seen_out := {}
	for w in graph.get("wires", []):
		if int(w[2]) == id and not seen_in.has(String(w[3])):
			seen_in[String(w[3])] = true
			d.ins.append(_pin(String(w[3]), String(w[3]), _far_type(int(w[0]), String(w[1]), true, bp, graph), {"orphan": true}))
		if int(w[0]) == id and not seen_out.has(String(w[1])):
			seen_out[String(w[1])] = true
			d.outs.append(_pin(String(w[1]), String(w[1]), _far_type(int(w[2]), String(w[3]), false, bp, graph), {"orphan": true}))
	# exec pins first, as on every other node
	for side in ["ins", "outs"]:
		d[side] = d[side].filter(func(x): return x.type == "exec") + d[side].filter(func(x): return x.type != "exec")


## The type of the pin at the other end of a placeholder's wire ("any" when that is not known, for instance when
## the other end is a placeholder too).
static func _far_type(other_id: int, pin_id: String, other_is_output: bool, bp: Dictionary, graph: Dictionary) -> String:
	if _placeholder_depth > 0:
		return "any"
	var other := Model.find_node(graph, other_id)
	if other.is_empty():
		return "any"
	_placeholder_depth += 1
	var od := describe(other, bp, graph)
	_placeholder_depth -= 1
	if bool(od.get("missing", false)):
		return "any"
	for pin in (od.outs if other_is_output else od.ins):
		if String(pin.id) == pin_id:
			return String(pin.type)
	return "any"


static func _describe_kind(node: Dictionary, bp: Dictionary, graph: Dictionary = {}) -> Dictionary:
	ensure_api()
	var p: Dictionary = node.get("p", {})
	var d := {"title": node.kind, "sub": "", "color": COL_CALL, "pure": false, "compact": false, "latent": false,
		"ins": [], "outs": [], "tip": "", "err": ""}
	match node.kind:
		"event":
			var m := find_method(self_class(bp), p.name)
			d.title = "Event " + nice(p.name)
			d.color = COL_EVENT
			d.outs.append(_exec_out())
			if m.is_empty():
				d.err = "'%s' is not an overridable function of %s" % [p.name, self_class(bp)]
			else:
				var own: Array = p.get("names", [])   # the names a converted script gave the parameters
				for ai in m.args.size():
					var a: Dictionary = m.args[ai]
					var label := String(own[ai]) if ai < own.size() and String(own[ai]) != "" else String(a.name)
					d.outs.append(_pin("p_" + T.ident(String(a.name)), nice(label), T.from_info(a)))
			d.tip = doc(self_class(bp), p.name)
		"custom_event":
			d.title = p.get("name", "CustomEvent")
			d.sub = "Custom Event" + {"server": " (Run on Server)", "multicast": " (Multicast)", "owner": " (Run on Owning Client)"}.get(String(p.get("rpc", "")), "")
			d.color = COL_EVENT
			d.outs.append(_exec_out())
			d.outs.append_array(_params(p.get("params", []), "p_"))
		"input_action":
			d.title = "InputAction " + String(p.get("action", ""))
			d.color = COL_EVENT
			d.outs = [_exec_out("pressed", "Pressed"), _exec_out("released", "Released")]
		"signal_event":
			d.title = "On %s (%s)" % [nice(p.signal), "self" if p.get("path", ".") == "." else String(p.path).get_file()]
			d.sub = "Signal"
			d.color = COL_EVENT
			d.outs.append(_exec_out())
			d.outs.append_array(_params(p.get("args", []), "p_"))
			d.tip = doc(p.get("cls", ""), "!" + String(p.signal))
		"tpl":
			var t: Dictionary = template_of(p)
			if t.is_empty():
				var was := String(p.get("title", "")) if String(p.get("title", "")) != "" else String(p.get("id", "?"))
				d.title = "%s (missing)" % was
				d.sub = "Missing addon node: %s" % p.get("id", "")
				d.err = "This node comes from an addon that is not installed or enabled: %s" % p.get("id", "")
				if String(p.get("id", "")).contains(":"):
					d.err += " (addons/%s)" % String(p.id).get_slice(":", 0)
				d.tip = "The addon (kit) that provides '%s' is not installed or not enabled in this project. The node and its wires are kept as they were; enable the addon and reopen the graph to use it again." % p.get("id", "")
				d["missing"] = true
				return d
			d.title = String(t.title)
			d.pure = bool(t.get("pure", false))
			d.latent = bool(t.get("latent", false))
			d.color = COL_PURE if d.pure else (COL_LATENT if d.latent else COL_CALL)
			d.tip = String(t.get("tip", ""))
			if not d.pure:
				d.ins.append(_exec_in())
				d.outs.append(_exec_out("then", "Completed" if d.latent else ""))
			for i in t.get("ins", []):
				var extra := {}
				if i.size() > 3 and String(i[3]) == "self":
					extra["self"] = true
				elif i.size() > 3 and String(i[3]) != "":
					extra["def"] = String(i[3])
				d.ins.append(_pin(String(i[0]), String(i[1]), String(i[2]), extra))
			for o in t.get("outs", []):
				d.outs.append(_pin(String(o[0]), String(o[1]), String(o[2])))
		"autoload":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_VAR
			d.outs = [_pin("value", String(p.get("name", "")), String(p.get("cls", "Node")))]
			d.tip = "The '%s' autoload (a global singleton node set up in Project Settings > Globals)." % p.get("name", "")
			if not ProjectSettings.has_setting("autoload/" + String(p.get("name", ""))):
				d.err = "Autoload '%s' is not set up in Project Settings" % p.get("name", "")
		"macro":
			var mg := macro_graph(bp, p)
			var mlib := String(p.get("lib", ""))
			d.title = String(p.get("name", "Macro"))
			d.sub = "Macro" if mlib == "" else "Macro from %s" % mlib.get_file().get_basename()
			d.color = COL_FLOW
			if mg.is_empty():
				d.err = ("Macro '%s' no longer exists" % p.get("name", "")) if mlib == "" else ("Macro '%s' is not in the library %s" % [p.get("name", ""), mlib])
				# a macro of another file (a library missing or changed outside this editor) keeps its wires;
				# one of this schematic that was removed here loses the pins it had, as any removed pin does
				if mlib != "":
					d.title = "%s (missing)" % d.title
					d["missing"] = true
			else:
				d.ins = _params(mg.inputs, "i_")
				d.outs = _params(mg.outputs, "o_")
		"macro_in":
			d.title = "Inputs"
			d.color = COL_FN
			d.outs = _params(graph.get("inputs", []), "i_")
		"macro_out":
			d.title = "Outputs"
			d.color = COL_FN
			d.ins = _params(graph.get("outputs", []), "o_")
		"timeline":
			d.title = String(p.get("name", "Timeline"))
			d.sub = "Timeline"
			d.color = COL_LATENT
			d.ins = [_pin("play", "Play", "exec"), _pin("play_start", "Play from Start", "exec"), _pin("stop", "Stop", "exec"),
				_pin("reverse", "Reverse", "exec"), _pin("reverse_end", "Reverse from End", "exec"),
				_pin("set_time", "Set New Time", "exec"), _pin("new_time", "New Time", "float", {"def": "0.0"})]
			d.outs = [_exec_out("update", "Update"), _exec_out("finished", "Finished")]
			for tr in p.get("tracks", []):
				if String(tr.get("type", "float")) == "event":
					d.outs.append(_exec_out("e_" + T.ident(String(tr.name)), String(tr.name)))
				else:
					d.outs.append(_pin("t_" + T.ident(String(tr.name)), String(tr.name), String(tr.get("type", "float"))))
			d.outs.append(_pin("time", "Time", "float"))
			d.tip = "Plays keyframed tracks over time. Update fires every frame while playing; track outputs hold the current values."
		"fn_entry":
			d.title = graph.get("name", "Function")
			d.color = COL_FN
			d.outs.append(_exec_out())
			d.outs.append_array(_params(graph.get("inputs", []), "p_"))
		"fn_return":
			d.title = "Return Node"
			d.color = COL_FN
			d.ins.append(_exec_in())
			d.ins.append_array(_params(graph.get("outputs", []), "r_"))
		"call":
			_describe_call(d, p, bp)
		"bcall":
			var m := builtin_method(p.type, p.method)
			d.title = nice(p.method)
			d.sub = "Target is %s" % p.type
			if m.is_empty():
				d.err = "%s has no method '%s'" % [p.type, p.method]
				d["missing"] = true
				return d
			d.pure = bool(m.c) or bool(m.s)
			d.color = COL_PURE if d.pure else COL_CALL
			if not d.pure:
				d.ins.append(_exec_in())
				d.outs.append(_exec_out())
			if not bool(m.s):
				d.ins.append(_pin("target", "Target", p.type))
			for i in m.a.size():
				var extra := {}
				if m.a[i].size() > 2:
					extra["def"] = String(m.a[i][2])
				d.ins.append(_pin("a%d" % i, nice(m.a[i][0]), api_type(m.a[i][1]), extra))
			if bool(m.v):
				for i in int(p.get("n", 0)):
					d.ins.append(_pin("v%d" % i, "Arg %d" % i, "any"))
			var rt := api_type(m.r)
			if rt != "":
				d.outs.append(_pin("ret", "Return Value", rt))
			d.tip = m.d
		"util":
			var u := util(p.name)
			d.title = nice(p.name)
			if u.is_empty():
				d.err = "Unknown utility function '%s'" % p.name
				d["missing"] = true
				return d
			var rt := api_type(u.r)
			d.pure = rt != ""
			d.color = COL_PURE if d.pure else COL_CALL
			if not d.pure:
				d.ins.append(_exec_in())
				d.outs.append(_exec_out())
			for i in u.a.size():
				d.ins.append(_pin("a%d" % i, nice(u.a[i][0]), api_type(u.a[i][1])))
			if bool(u.v):
				for i in maxi(int(p.get("n", 1)) - u.a.size(), 0):
					d.ins.append(_pin("v%d" % i, "Arg %d" % (i + u.a.size()), "any"))
			if rt != "":
				d.outs.append(_pin("ret", "Return Value", rt))
			d.tip = u.d
		"ctor":
			d.title = "Make " + String(p.type)
			d.pure = true
			d.color = COL_PURE
			var ctors: Array = api.types.get(p.type, {}).get("ctor", [])
			var i := int(p.get("i", 0))
			if i < ctors.size():
				for j in ctors[i].size():
					d.ins.append(_pin("a%d" % j, nice(ctors[i][j][0]), api_type(ctors[i][j][1])))
			d.outs.append(_pin("ret", String(p.type), p.type))
		"break":
			d.title = "Break " + String(p.type)
			d.pure = true
			d.color = COL_PURE
			d.ins.append(_pin("v", String(p.type), p.type))
			for m in struct_members(p.type):
				d.outs.append(_pin("m_" + String(m[0]), nice(m[0]), api_type(m[1])))
		"make_data":
			d.title = "Make " + String(p.cls)
			d.pure = true
			d.color = COL_PURE
			var fields := data_fields(String(p.cls))
			if fields.is_empty():
				d.err = "'%s' is not a data class (a Resource script with exported variables)" % p.cls
				if not T.class_known(String(p.cls)):
					d.err = "Class '%s' no longer exists" % p.cls
					d["missing"] = true   # the data class's script is gone: its field wires are kept
			for fld in fields:
				d.ins.append(_pin("f_" + String(fld[0]), nice(fld[0]), String(fld[1]), {"def": String(fld[2])} if String(fld[2]) != "" else {}))
			d.outs = [_pin("ret", String(p.cls), String(p.cls))]
			d.tip = "Creates a new %s. Each use makes its own copy." % p.cls
		"table_row":
			d.title = "Get Data Table Row"
			d.sub = String(p.get("table", "")).get_file() if String(p.get("table", "")) != "" else "no table set"
			d.ins = [_exec_in(), _pin("table", "Data Table", Model.TABLE_CLASS), _pin("row", "Row Name", "StringName", {"def": "&\"\""})]
			d.outs = [_exec_out("found", "Row Found"), _exec_out("not_found", "Row Not Found"), _pin("row_out", "Out Row", String(p.get("cls", "Resource")))]
			d.tip = "Finds a row of a Data Table by name. Out Row has the table's row structure when the table is set on the node."
		"math":
			_describe_math(d, node, bp, graph)
		"multigate":
			d.title = "MultiGate"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("reset", "Reset", "exec"), _pin("random", "Is Random", "bool", {"def": "false"}),
				_pin("loop", "Loop", "bool", {"def": "false"}), _pin("start", "Start Index", "int", {"def": "-1"})]
			for i in int(p.get("n", 2)):
				d.outs.append(_exec_out("out_%d" % i, "Out %d" % i))
			d.tip = "Each time it is entered it fires the next output (or a random unused one). With Loop it starts over after the last."
		"format":
			d.title = "Format String"
			d.sub = String(p.get("text", ""))
			d.pure = true
			d.color = COL_PURE
			for nm in format_args(String(p.get("text", ""))):
				d.ins.append(_pin("f_" + nm, nm, "any", {"def": "\"\""}))
			d.outs = [_pin("ret", "Result", "String")]
			d.tip = "Builds a string from a pattern. Every {name} in the pattern becomes an input pin."
		"key_event":
			d.title = "Keyboard " + String(p.get("key", "")).trim_prefix("KEY_").capitalize()
			d.color = COL_EVENT
			d.outs = [_exec_out("pressed", "Pressed"), _exec_out("released", "Released")]
			d.tip = "Fires when this key is pressed or released. For shipping games prefer Input Action events (Project Settings > Input Map)."
		"for_each_dict":
			d.title = "For Each Loop (Dictionary)"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("dict", "Dictionary", "Dictionary")]
			d.outs = [_exec_out("body", "Loop Body"), _pin("key", "Key", "any"), _pin("value", "Value", "any"), _exec_out("completed", "Completed")]
		"var_inc":
			var iv := Model.find_var(bp, p.name)
			d.title = ("Increment " if int(p.get("by", 1)) > 0 else "Decrement ") + String(p.name)
			d.color = COL_VAR
			d.ins = [_exec_in()]
			d.outs = [_exec_out(), _pin("value", String(p.name), String(iv.get("type", "int")))]
			if iv.is_empty():
				d.err = "Variable '%s' no longer exists" % p.name
		"op":
			d.title = String(p.op).trim_prefix("unary")
			d.pure = true
			d.compact = true
			d.color = COL_PURE
			d.ins.append(_pin("a", "", p.l))
			if String(p.get("r", "")) != "":
				d.ins.append(_pin("b", "", p.r))
			d.outs.append(_pin("ret", "", p.ret))
		"get_prop":
			var info := find_property(p.cls, p.prop)
			d.title = "Get " + nice(p.prop)
			d.sub = "Target is %s" % p.cls
			d.pure = true
			d.color = COL_VAR
			d.ins.append(_target_pin(p.cls, bp))
			d.outs.append(_pin("value", nice(p.prop), T.from_info(info) if not info.is_empty() else "any",
				{"enum": T.enum_from_info(info)} if T.enum_from_info(info) != "" else {}))
			if info.is_empty():
				d.err = "%s has no property '%s'" % [p.cls, p.prop]
			d.tip = doc(p.cls, "." + String(p.prop))
		"set_prop":
			var info := find_property(p.cls, p.prop)
			var pt := T.from_info(info) if not info.is_empty() else "any"
			d.title = "Set " + nice(p.prop)
			d.sub = "Target is %s" % p.cls
			d.color = COL_VAR
			d.ins = [_exec_in(), _target_pin(p.cls, bp), _pin("value", nice(p.prop), pt,
				{"enum": T.enum_from_info(info)} if T.enum_from_info(info) != "" else {})]
			d.outs = [_exec_out(), _pin("out", "", pt)]
			if info.is_empty():
				d.err = "%s has no property '%s'" % [p.cls, p.prop]
			d.tip = doc(p.cls, "." + String(p.prop))
		"var_get", "var_set":
			var v := Model.find_var(bp, p.name)
			var vt: String = v.get("type", "any")
			d.color = COL_VAR
			if v.is_empty():
				d.err = "Variable '%s' no longer exists" % p.name
			var ven := {"enum": "@" + String(v.enum)} if (vt == "int" and String(v.get("enum", "")) != "") else {}
			if node.kind == "var_get":
				d.title = ""
				d.pure = true
				d.compact = true
				d.outs.append(_pin("value", String(p.name), vt, ven))
			else:
				d.title = "Set"
				d.ins = [_exec_in(), _pin("value", String(p.name), vt, ven)]
				d.outs = [_exec_out(), _pin("out", "", vt, ven)]
			d.tip = v.get("tooltip", "")
		"local_get", "local_set":
			var vt := "any"
			var found := false
			for l in graph.get("locals", []):
				if l.name == p.name:
					vt = l.type
					found = true
			d.color = COL_VAR
			if not found:
				d.err = "Local variable '%s' no longer exists" % p.name
			if node.kind == "local_get":
				d.title = ""
				d.pure = true
				d.compact = true
				d.outs.append(_pin("value", String(p.name), vt))
			else:
				d.title = "Set (local)"
				d.ins = [_exec_in(), _pin("value", String(p.name), vt)]
				d.outs = [_exec_out(), _pin("out", "", vt)]
		"self":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_VAR
			d.outs.append(_pin("self", "Self", self_type(bp)))
		"get_node":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_VAR
			d.outs.append(_pin("node", String(p.get("path", ".")), p.get("cls", "Node")))
			d.tip = "Reference to the scene node at '%s' (relative to this schematic's node)." % p.get("path", ".")
		"branch":
			d.title = "Branch"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("cond", "Condition", "bool", {"def": "true"})]
			d.outs = [_exec_out("true", "True"), _exec_out("false", "False")]
			d.tip = "If Condition is true, execution goes to True, otherwise it goes to False."
		"sequence":
			d.title = "Sequence"
			d.color = COL_FLOW
			d.ins = [_exec_in()]
			for i in int(p.get("n", 2)):
				d.outs.append(_exec_out("then_%d" % i, "Then %d" % i))
			d.tip = "Executes a series of pins in order. Later pins do not wait for latent actions started by earlier ones."
		"for":
			d.title = "For Loop"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("first", "First Index", "int", {"def": "0"}), _pin("last", "Last Index", "int", {"def": "0"})]
			d.outs = [_exec_out("body", "Loop Body"), _pin("index", "Index", "int"), _exec_out("completed", "Completed")]
		"for_each":
			d.title = "Reverse For Each Loop" if p.get("rev", false) else "For Each Loop"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("array", "Array", "Array")]
			d.outs = [_exec_out("body", "Loop Body"), _pin("element", "Array Element", p.get("t", "any")),
				_pin("index", "Array Index", "int"), _exec_out("completed", "Completed")]
		"while":
			d.title = "While Loop"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("cond", "Condition", "bool")]
			d.outs = [_exec_out("body", "Loop Body"), _exec_out("completed", "Completed")]
		"loop_break":
			d.title = "Break Loop"
			d.color = COL_FLOW
			d.ins = [_exec_in()]
		"loop_continue":
			d.title = "Continue Loop"
			d.color = COL_FLOW
			d.ins = [_exec_in()]
		"delay":
			d.title = "Delay"
			d.color = COL_LATENT
			d.latent = true
			d.ins = [_exec_in(), _pin("duration", "Duration", "float", {"def": "0.2"})]
			d.outs = [_exec_out("then", "Completed")]
			d.tip = "Latent delay in seconds. Calling again while it is counting down is ignored."
		"retriggerable_delay":
			d.title = "Retriggerable Delay"
			d.color = COL_LATENT
			d.latent = true
			d.ins = [_exec_in(), _pin("duration", "Duration", "float", {"def": "0.2"})]
			d.outs = [_exec_out("then", "Completed")]
			d.tip = "Latent delay in seconds. Calling again restarts the countdown."
		"do_once":
			d.title = "Do Once"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("reset", "Reset", "exec"), _pin("closed", "Start Closed", "bool", {"def": "false", "const": true})]
			d.outs = [_exec_out("then", "Completed")]
		"do_n":
			d.title = "Do N"
			d.color = COL_FLOW
			d.ins = [_pin("exec", "Enter", "exec"), _pin("n", "N", "int", {"def": "1"}), _pin("reset", "Reset", "exec")]
			d.outs = [_exec_out("then", "Exit"), _pin("counter", "Counter", "int")]
		"flip_flop":
			d.title = "Flip Flop"
			d.color = COL_FLOW
			d.ins = [_exec_in()]
			d.outs = [_exec_out("a", "A"), _exec_out("b", "B"), _pin("is_a", "Is A", "bool")]
		"gate":
			d.title = "Gate"
			d.color = COL_FLOW
			d.ins = [_pin("exec", "Enter", "exec"), _pin("open", "Open", "exec"), _pin("close", "Close", "exec"),
				_pin("toggle", "Toggle", "exec"), _pin("closed", "Start Closed", "bool", {"def": "true", "const": true})]
			d.outs = [_exec_out("then", "Exit")]
		"is_valid":
			d.title = "Is Valid"
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("obj", "Input Object", "Object")]
			d.outs = [_exec_out("valid", "Is Valid"), _exec_out("invalid", "Is Not Valid")]
		"cast":
			d.title = "Cast To " + String(p.cls)
			d.color = COL_CAST
			if p.get("pure", false):
				d.pure = true
				d.ins = [_pin("obj", "Object", "Object")]
				d.outs = [_pin("as", "As " + nice(p.cls), p.cls), _pin("ok", "Success", "bool")]
			else:
				d.ins = [_exec_in(), _pin("obj", "Object", "Object")]
				d.outs = [_exec_out("then", ""), _exec_out("fail", "Cast Failed"), _pin("as", "As " + nice(p.cls), p.cls)]
			if not T.class_known(p.cls):
				d.err = "Class '%s' no longer exists" % p.cls
		"switch":
			d.title = "Switch on " + nice(String(p.get("t", "int")))
			d.color = COL_FLOW
			d.ins = [_exec_in(), _pin("sel", "Selection", p.get("t", "int"), {"enum": p.get("enum", "")} if p.get("enum", "") != "" else {})]
			var cases: Array = p.get("cases", [])
			for i in cases.size():
				d.outs.append(_exec_out("case_%d" % i, String(cases[i][0])))
			d.outs.append(_exec_out("default", "Default"))
		"select":
			d.title = "Select"
			d.pure = true
			d.color = COL_PURE
			d.ins = [_pin("a", "A", p.get("t", "any")), _pin("b", "B", p.get("t", "any")), _pin("pick", "Pick A", "bool")]
			d.outs = [_pin("ret", "Return Value", p.get("t", "any"))]
		"emit":
			var disp := Model.find_dispatcher(bp, p.name)
			d.title = "Call " + String(p.name)
			d.sub = "Event Dispatcher"
			d.ins = [_exec_in()]
			d.ins.append_array(_params(disp.get("params", []), "a_"))
			d.outs = [_exec_out()]
			if disp.is_empty():
				d.err = "Event dispatcher '%s' no longer exists" % p.name
		"bind_signal":
			d.title = "Bind Event to " + nice(p.signal)
			d.sub = "Target is %s" % p.cls
			d.ins = [_exec_in(), _target_pin(p.cls, bp), _pin("fn", "Event", "Callable")]
			d.outs = [_exec_out()]
			d.tip = "Connects a function or custom event to this signal. " + doc(p.cls, "!" + String(p.signal))
		"unbind_signal":
			d.title = "Unbind Event from " + nice(p.signal)
			d.sub = "Target is %s" % p.cls
			d.ins = [_exec_in(), _target_pin(p.cls, bp), _pin("fn", "Event", "Callable")]
			d.outs = [_exec_out()]
		"await_signal":
			d.title = "Wait for " + nice(p.signal)
			d.sub = "Target is %s" % p.cls
			d.color = COL_LATENT
			d.latent = true
			d.ins = [_exec_in(), _target_pin(p.cls, bp)]
			d.outs = [_exec_out("then", "Completed")]
		"event_ref":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_EVENT
			d.outs = [_pin("fn", "Event: " + String(p.get("fn", "")), "Callable")]
			if Model.find_custom_event(bp, p.get("fn", "")).is_empty() and Model.graph_named(bp, p.get("fn", "")).is_empty():
				d.err = "'%s' is not a function or custom event of this schematic" % p.get("fn", "")
		"call_self":
			_describe_call_self(d, p, bp)
		"call_parent":
			var m := find_method(self_class(bp), p.method)
			d.title = "Parent: " + nice(p.method)
			d.color = Color(0.7, 0.4, 0.1)
			d.ins = [_exec_in()]
			d.outs = [_exec_out()]
			if not m.is_empty() and not p.has("n"):
				d.ins.append_array(_method_arg_pins(m))
				var rt := T.from_info(m["return"], true)
				if rt != "":
					d.outs.append(_pin("ret", "Return Value", rt))
			else:
				# a parent function this editor can't look up (or one called with its own argument count)
				for i in int(p.get("n", 0)):
					d.ins.append(_pin("a%d" % i, "Arg %d" % i, "any"))
				if bool(p.get("ret", false)):
					d.outs.append(_pin("ret", "Return Value", "any"))
		"closure":
			# A function of this schematic handed over as a new, separate Callable each time (what a lambda is):
			# connecting it twice gives two connections, where the function itself can be connected only once.
			var cg := Model.graph_named(bp, String(p.get("fn", "")))
			d.title = "Lambda"
			d.sub = String(p.get("fn", ""))
			d.pure = true
			d.color = COL_EVENT
			if cg.is_empty() or String(cg.kind) != "function":
				d.err = "'%s' is not a function of this schematic" % p.get("fn", "")
			else:
				for i in range(int(p.get("n", 0)), cg.inputs.size()):
					d.ins.append(_pin("c%d" % (i - int(p.get("n", 0))), String(cg.inputs[i][0]), String(cg.inputs[i][1])))
			d.outs = [_pin("fn", "Callable", "Callable")]
			d.tip = "Makes a Callable that calls the function, with the wired values passed after the caller's own arguments."
		"dyn_get":
			d.title = "Get " + nice(String(p.get("name", "")))
			d.sub = "by name"
			d.pure = true
			d.color = COL_VAR
			d.ins = [_pin("target", "Target", "any")]
			d.outs = [_pin("value", nice(String(p.get("name", ""))), String(p.get("t", "any")))]
			d.tip = "Reads '%s' from whatever is wired in, found by name when the game runs (the target's type is not known here)." % p.get("name", "")
		"dyn_set":
			d.title = "Set " + nice(String(p.get("name", "")))
			d.sub = "by name"
			d.color = COL_VAR
			d.ins = [_exec_in(), _pin("target", "Target", "any"), _pin("value", nice(String(p.get("name", ""))), "any")]
			d.outs = [_exec_out()]
			d.tip = "Sets '%s' on whatever is wired in, found by name when the game runs." % p.get("name", "")
		"dyn_call":
			d.title = nice(String(p.get("method", "")))
			d.sub = "by name"
			d.ins = [_exec_in(), _pin("target", "Target", "any")]
			for i in int(p.get("n", 0)):
				d.ins.append(_pin("v%d" % i, "Arg %d" % i, "any"))
			d.outs = [_exec_out(), _pin("ret", "Return Value", String(p.get("t", "any")))]
			d.tip = "Calls '%s' on whatever is wired in, found by name when the game runs (the target's type is not known here)." % p.get("method", "")
		"is_type":
			d.title = "Is %s" % p.get("type", "?")
			d.pure = true
			d.compact = true
			d.color = COL_CAST
			d.ins = [_pin("v", "", "any")]
			d.outs = [_pin("ret", "", "bool")]
			d.tip = "True when the value is a %s." % p.get("type", "?")
		"as_type":
			d.title = "As %s" % p.get("type", "?")
			d.pure = true
			d.compact = true
			d.color = COL_CAST
			d.ins = [_pin("v", "", "any")]
			d.outs = [_pin("ret", "", String(p.get("type", "any")) if T.hint(String(p.get("type", "any"))) != "" else "any")]
			d.tip = "The value as a %s (null if it is not one)." % p.get("type", "?")
		"await_value":
			d.title = "Wait For"
			d.color = COL_LATENT
			d.latent = true
			d.ins = [_exec_in(), _pin("v", "Signal", "any")]
			d.outs = [_exec_out("then", "Completed"), _pin("ret", "Result", "any")]
			d.tip = "Waits for a signal (or anything else that can be awaited), then continues. Result is what the signal carried."
		"iface_call":
			var ig := interface_function(String(p.get("iface", "")), String(p.get("fn", "")))
			d.title = nice(String(p.get("fn", "")))
			d.sub = "Message  -  %s" % String(p.get("iface", ""))
			d.ins = [_exec_in(), _pin("target", "Target", "Object", {"self": true})]
			d.outs = [_exec_out()]
			if ig.is_empty():
				d.err = "The interface %s has no function '%s'" % [p.get("iface", ""), p.get("fn", "")]
				d["missing"] = true   # the interface is another file: its call keeps its wires until it is back
			else:
				d.ins.append_array(_params(ig.inputs, "a_"))
				d.outs.append_array(_params(ig.outputs, "r_"))
			d.tip = "Calls this function of the interface on the target if the target has it. Does nothing otherwise, and the outputs keep their default values."
		"iface_has":
			d.title = "Does Implement Interface"
			d.sub = String(p.get("iface", ""))
			d.pure = true
			d.color = COL_PURE
			d.ins = [_pin("target", "Target", "Object", {"self": true})]
			d.outs = [_pin("ret", "Return Value", "bool")]
			if interface_bp(String(p.get("iface", ""))).is_empty():
				d.err = "There is no Schematic Interface named '%s'" % p.get("iface", "")
			d.tip = "True when the target has every function of the interface."
		"message":
			d.title = "Call If Present"
			d.ins = [_exec_in(), _pin("target", "Target", "Object"), _pin("fn", "Function Name", "StringName", {"def": "&\"interact\""})]
			for i in int(p.get("n", 0)):
				d.ins.append(_pin("v%d" % i, "Arg %d" % i, "any"))
			d.outs = [_exec_out()]
			d.tip = "Calls the function only if the target has it; does nothing otherwise."
		"reroute":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_FLOW
			var rt: String = p.get("t", "any")
			d.ins = [_pin("i", "", rt)]
			d.outs = [_pin("o", "", rt)]
		"expr":
			d.title = "Math Expression"
			d.sub = String(p.get("code", ""))
			d.pure = true
			d.color = COL_PURE
			for nm in p.get("ins", []):
				d.ins.append(_pin("x_" + String(nm), String(nm), "any"))
			d.outs = [_pin("ret", "Return Value", String(p.get("t", "any")))]
			d.tip = "Evaluates a GDScript expression. Inputs are available by name."
		"code":
			var code_text := String(p.get("code", "pass"))
			d.title = "GDScript"
			d.sub = code_text.get_slice("\n", 0).left(46) + (" ..." if code_text.contains("\n") or code_text.length() > 46 else "")
			d.color = COL_FLOW
			d.ins = [_exec_in()]
			for nm in p.get("ins", []):
				d.ins.append(_pin("x_" + String(nm), String(nm), "any"))
			d.outs = [_exec_out()]
			d.tip = "Runs GDScript exactly as written (the importer uses it for lines it could not turn into nodes). Inputs replace their names in the code; variables and functions of this schematic are available by name.\n\n" + code_text
		"new":
			d.title = "Construct " + String(p.cls)
			d.ins = [_exec_in()]
			d.outs = [_exec_out(), _pin("ret", "Return Value", p.cls)]
		"spawn":
			d.title = "Spawn Scene"
			d.ins = [_exec_in(), _pin("scene", "Scene", "PackedScene"), _pin("parent", "Parent", "Node", {"self": true}),
				_pin("xform", "Spawn Transform", p.get("xt", "Transform3D"))]
			var si := spawn_info(String(node.get("d", {}).get("scene", "")))
			for sv in si.vars:
				d.ins.append(_pin("x_" + T.ident(String(sv.name)), String(sv.name), String(sv.type), {"def": String(sv.get("default", ""))} if String(sv.get("default", "")) != "" else {}))
			d.outs = [_exec_out(), _pin("ret", "Return Value", String(si.cls))]
			d.tip = "Instantiates a scene, sets its transform and adds it as a child of Parent (self by default). Variables marked Expose on Spawn in the scene's schematic appear as pins and are set before its Ready event runs."
		"print":
			d.title = "Print String"
			d.ins = [_exec_in(), _pin("text", "In String", "String", {"def": "\"Hello\""})]
			d.outs = [_exec_out()]
			d.tip = "Prints a string to the Output log."
		"make_dict":
			d.title = "Make Dictionary"
			d.pure = true
			d.color = COL_PURE
			for i in int(p.get("n", 1)):
				d.ins.append(_pin("k%d" % i, "Key %d" % i, "any", {"def": "\"key%d\"" % i}))
				d.ins.append(_pin("v%d" % i, "Value %d" % i, "any", {"def": "0"}))
			d.outs = [_pin("ret", "Dictionary", "Dictionary")]
		"make_array":
			d.title = "Make Array"
			d.pure = true
			d.color = COL_PURE
			for i in int(p.get("n", 1)):
				d.ins.append(_pin("e%d" % i, "[%d]" % i, "any"))
			d.outs = [_pin("ret", "Array", "Array")]
		"index":
			d.title = "Get"
			d.pure = true
			d.color = COL_PURE
			d.ins = [_pin("c", "Container", "any"), _pin("k", "Index / Key", "any", {"def": "0"})]
			d.outs = [_pin("ret", "", "any")]
		"set_index":
			d.title = "Set Element"
			d.ins = [_exec_in(), _pin("c", "Container", "any"), _pin("k", "Index / Key", "any", {"def": "0"}), _pin("v", "Value", "any")]
			d.outs = [_exec_out()]
		"const":
			d.title = ""
			d.pure = true
			d.compact = true
			d.color = COL_PURE
			d.outs = [_pin("value", String(p.get("label", p.expr)), p.get("t", "int"))]
		"comment":
			d.title = String(p.get("text", "Comment"))
			d.color = Color(0.3, 0.3, 0.3)
		_:
			d.title = "%s (missing)" % node.kind
			d.sub = "Unknown node kind"
			d.err = "Unknown node kind '%s' (written by a newer version of Schematic, or by an addon that is not installed or enabled)" % node.kind
			d["missing"] = true
	return d


static var _spawn_cache: Dictionary = {}


## For a `preload("res://x.tscn")` literal: the scene root's class and its schematic's Expose-on-Spawn variables.
static func spawn_info(scene_literal: String) -> Dictionary:
	var empty := {"cls": "Node", "vars": []}
	if not scene_literal.begins_with("preload(\""):
		return empty
	var path := scene_literal.trim_prefix("preload(\"").trim_suffix("\")")
	if not ResourceLoader.exists(path):
		return empty
	var ps := load(path) as PackedScene
	if ps == null:
		return empty
	var state := ps.get_state()
	if state.get_node_count() == 0:
		return empty
	var out := {"cls": String(state.get_node_type(0)) if String(state.get_node_type(0)) != "" else "Node", "vars": []}
	var scr: Script = null
	for i in state.get_node_property_count(0):
		if String(state.get_node_property_name(0, i)) == "script":
			scr = state.get_node_property_value(0, i) as Script
	if scr == null or scr.resource_path == "":
		return out
	if scr.get_global_name() != &"":
		out.cls = String(scr.get_global_name())
	var stamp := FileAccess.get_modified_time(scr.resource_path)
	var cached: Dictionary = _spawn_cache.get(scr.resource_path, {})
	if cached.get("stamp", -1) != stamp:
		var vars := []
		if Model.is_schematic_file(scr.resource_path):
			for v in Model.load_file(scr.resource_path).get("variables", []):
				if v.get("spawn", false):
					vars.append({"name": v.name, "type": v.type, "default": v.get("default", "")})
		cached = {"stamp": stamp, "vars": vars}
		_spawn_cache[scr.resource_path] = cached
	out.vars = cached.vars
	return out


static func format_args(text: String) -> Array:
	var out := []
	var re := RegEx.new()
	re.compile("\\{([A-Za-z_][A-Za-z0-9_]*)\\}")
	for m in re.search_all(text):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


const TABLE_GETTERS := ["size", "has_row", "get_row", "get_row_names", "get_rows", "get_row_name", "find_rows", "unique_name", "get_columns", "to_csv", "make_row"]
const MATH_OPS := {"+": ["Add", "0"], "-": ["Subtract", "0"], "*": ["Multiply", "1"], "/": ["Divide", "1"], "%": ["Modulo", "1"],
	"==": ["Equal", "0"], "!=": ["Not Equal", "0"], "<": ["Less", "0"], ">": ["Greater", "0"], "<=": ["Less Equal", "0"], ">=": ["Greater Equal", "0"],
	"and": ["AND", "true"], "or": ["OR", "false"], "not": ["NOT", "false"]}
const MATH_VARIADIC := ["+", "*", "and", "or"]


## Result type of `l op r` according to the built-in operator table.
static func op_result(l: String, op: String, r: String) -> String:
	if l == "any" or r == "any":
		return "any"
	if l == r:
		return l
	for cand in [[l, r], [r, l]]:
		for o in api.types.get(cand[0], {}).get("op", []):
			if o[0] == op and o[1] == cand[1]:
				return api_type(o[2])
	if l in ["int", "float"] and r in ["int", "float"]:
		return "float"
	return l


## Type of whatever is wired into an input pin, or "" when nothing is.
static func wired_type(node: Dictionary, pin_id: String, bp: Dictionary, graph: Dictionary, depth := 0) -> String:
	if graph.is_empty() or depth > 16 or not node.has("id"):
		return ""
	for w in graph.get("wires", []):
		if int(w[2]) == int(node.id) and w[3] == pin_id:
			var src := Model.find_node(graph, int(w[0]))
			if src.is_empty():
				return ""
			if src.kind == "math":
				var md := {"ins": [], "outs": [], "title": "", "compact": true, "pure": true, "color": COL_PURE}
				_describe_math(md, src, bp, graph, depth + 1)
				return md.outs[0].type
			for o in describe(src, bp, graph).outs:
				if o.id == w[1]:
					return o.type
			return ""
	return ""


## Wildcard operator (Unreal's promotable operator): pins take whatever is connected, the result type follows.
static func _describe_math(d: Dictionary, node: Dictionary, bp: Dictionary, graph: Dictionary, depth := 0) -> void:
	var p: Dictionary = node.get("p", {})
	var op := String(p.get("op", "+"))
	var info: Array = MATH_OPS.get(op, ["?", "0"])
	var logic := op in ["and", "or", "not"]
	var compare := op in ["==", "!=", "<", ">", "<=", ">="]
	var count := 1 if op == "not" else maxi(int(p.get("n", 2)), 2)
	d.title = "!" if op == "not" else ("==" if op == "==" else op)
	d.pure = true
	d.compact = true
	d.color = COL_PURE
	d.tip = "%s. Pins adapt to whatever you connect." % info[0]
	var types := []
	var acc := ""
	var first := ""
	for i in count:
		var t := "bool" if logic else wired_type(node, "a%d" % i, bp, graph, depth)
		types.append(t)
		if t != "":
			if first == "":
				first = t
			acc = t if acc == "" else op_result(acc, op, t)
	# formatting a string always gives a string, whatever is formatted into it
	if op == "%" and (String(types[0]) == "String" or (String(types[0]) == "" and String(node.get("d", {}).get("a0", "")).begins_with("\""))):
		acc = "String"
	for i in count:
		var shown := "bool" if logic else (first if first != "" else "any")
		var def := String(info[1])
		if shown != "any" and not shown in ["int", "float", "bool"]:
			def = T.default_literal(shown)
		d.ins.append(_pin("a%d" % i, "", "bool" if logic else "any", {"def": def, "ed": shown}))
	d.outs = [_pin("ret", "", "bool" if (logic or compare) else (acc if acc != "" else "any"))]


static func self_type(bp: Dictionary) -> String:
	var cn := String(bp.get("class_name", ""))
	return cn if cn != "" and T.class_known(cn) else self_class(bp)


static func _target_pin(cls: String, bp: Dictionary) -> Dictionary:
	return _pin("target", "Target", cls, {"self": true} if T.is_a(self_class(bp), cls) else {})


static func is_singleton(cls: String) -> bool:
	return Engine.has_singleton(cls)


static func _describe_call(d: Dictionary, p: Dictionary, bp: Dictionary) -> void:
	var m := find_method(p.cls, p.method)
	d.title = nice(p.method)
	if m.is_empty():
		# the class is gone (a script renamed or deleted, an addon switched off) or no longer has the function:
		# the node keeps every wire it has until it can be described again
		d.err = ("Class '%s' no longer exists (the call to %s is kept as it was)" % [p.cls, p.method]) if not T.class_known(String(p.cls)) else "%s has no function '%s'" % [p.cls, p.method]
		d.sub = "Target is %s" % p.cls
		d["missing"] = true
		return
	var flags := int(m.get("flags", 0))
	var rt := T.from_info(m.get("return", {}), true)
	var is_static := bool(flags & METHOD_FLAG_STATIC) or is_singleton(p.cls)
	d.pure = bool(flags & METHOD_FLAG_CONST) and rt != ""
	if String(p.cls) == Model.TABLE_CLASS and rt != "" and String(p.method) in TABLE_GETTERS:
		d.pure = true   # reading a table changes nothing, so these have no exec pins
	var lib_fn := library_function(String(p.cls), String(p.method))
	if not lib_fn.is_empty():
		d.pure = bool(lib_fn.pure) and rt != ""   # a library function marked Pure has no exec pins, as in Unreal
		is_static = true
	d.color = COL_PURE if d.pure else COL_CALL
	if not d.pure:
		d.ins.append(_exec_in())
		d.outs.append(_exec_out())
	if is_static:
		d.sub = String(p.cls)
	else:
		d.sub = "Target is %s" % p.cls
		d.ins.append(_target_pin(p.cls, bp))
	d.ins.append_array(_method_arg_pins(m))
	if flags & METHOD_FLAG_VARARG:
		for i in int(p.get("n", 0)):
			d.ins.append(_pin("v%d" % i, "Arg %d" % i, "any"))
	if rt != "":
		var extra := {}
		if T.enum_from_info(m["return"]) != "":
			extra["enum"] = T.enum_from_info(m["return"])
		d.outs.append(_pin("ret", "Return Value", rt, extra))
	d.tip = doc(p.cls, p.method)


static func _describe_call_self(d: Dictionary, p: Dictionary, bp: Dictionary) -> void:
	d.title = String(p.fn)
	var g := Model.graph_named(bp, p.fn)
	if not g.is_empty() and g.kind == "function":
		d.pure = bool(g.pure)
		d.color = COL_PURE if d.pure else COL_CALL
		d.sub = "Function"
		if not d.pure:
			d.ins.append(_exec_in())
			d.outs.append(_exec_out())
		d.ins.append_array(_params(g.inputs, "a_"))
		d.outs.append_array(_params(g.outputs, "r_"))
		return
	var ev := Model.find_custom_event(bp, p.fn)
	if ev.is_empty():
		d.err = "'%s' is not a function or custom event of this schematic" % p.fn
		d.ins = [_exec_in()]
		d.outs = [_exec_out()]
		return
	d.sub = "Custom Event"
	d.ins = [_exec_in()]
	d.ins.append_array(_params(ev.p.get("params", []), "a_"))
	d.outs = [_exec_out()]


# ---------------------------------------------------------------- data assets and tables
# A data class is any global script class that extends Resource and has exported variables (a Schematic of
# type Data Asset, or a hand-written Resource). It works like an Unreal struct: Make / Break nodes, typed
# pins, and rows of a Data Table.

## The exported fields of a data class: [[name, type, default literal]]; [] when `cls` is not one.
static func data_fields(cls: String) -> Array:
	if cls == Model.TABLE_CLASS or not T.globals().has(cls) or not T.is_a(cls, "Resource"):
		return []
	var chain := []
	var c := cls
	var guard := 0
	while T.globals().has(c) and guard < 32:
		chain.push_front(c)
		c = T.parent_of(c)
		guard += 1
	var out := []
	var seen := {}
	for link in chain:
		var info := cls_info(link)
		var scr := load(String(T.globals()[link].path)) as Script
		for pn in info.p:
			var prop: Dictionary = info.p[pn]
			if not (int(prop.usage) & PROPERTY_USAGE_EDITOR) or seen.has(pn):
				continue
			seen[pn] = true
			var def: Variant = scr.get_property_default_value(pn) if scr else null
			out.append([String(pn), T.from_info(prop), var_to_str(def) if (def != null and typeof(def) != TYPE_OBJECT) else ""])
	return out


static func data_classes() -> Array:
	var out := []
	for g in T.globals():
		if not data_fields(g).is_empty():
			out.append(g)
	out.sort()
	return out


## Members a Break node shows: the parts of a built-in struct type, or the fields of a data class.
static func struct_members(type: String) -> Array:
	var mem := break_members(type)
	return mem if not mem.is_empty() else data_fields(type)


## Row class and row names of the table a Get Data Table Row node points at.
static func table_info(path: String) -> Dictionary:
	var out := {"cls": "Resource", "rows": []}
	if path == "" or not ResourceLoader.exists(path):
		return out
	var table := load(path)
	if table == null or not table.has_method("get_row_names"):
		return out
	var scr: Script = table.get("row_script")
	if scr and scr.get_global_name() != &"":
		out.cls = String(scr.get_global_name())
	for nm in table.get_row_names():
		out.rows.append(String(nm))
	return out


static func data_actions() -> Array:
	var a := []
	for cls in data_classes():
		a.append(_act("Make " + cls, "Data|" + cls, "make_data", {"cls": cls}, "A new %s with these field values." % cls, "struct construct data asset"))
		a.append(_act("Break " + cls, "Data|" + cls, "break", {"type": cls}, "The fields of a %s." % cls, "struct split data asset"))
	if T.globals().has(Model.TABLE_CLASS):
		a.append(_act("Get Data Table Row", "Data Table", "table_row", {"table": "", "cls": "Resource"},
			"Looks a row up by name. Set the table in Details, or drag a Data Table file into the graph.", "datatable lookup row struct"))
		a.append_array(class_actions(Model.TABLE_CLASS, "Data Table"))
	return a


static func break_members(type: String) -> Array:
	ensure_api()
	var mem: Array = api.types.get(type, {}).get("mem", [])
	if type == "Color":
		return mem.slice(0, 4)
	return mem


# ---------------------------------------------------------------- palette actions
# action = {l: label, c: category, k: kind, p: params, s: lowercase search text, tip}

static func _act(label: String, cat: String, kind: String, p: Dictionary, tip := "", extra_search := "") -> Dictionary:
	var act := {"l": label, "c": cat, "k": kind, "p": p, "tip": tip, "s": (label + " " + cat + " " + extra_search).to_lower()}
	# Unreal names for the same thing, so "BeginPlay" or "GetActorLocation" find it.
	var ue := Aliases.names_for(kind, p)
	if not ue.is_empty():
		act["ue"] = ue
		act.s += " " + Aliases.search_text(ue)
	return act


static func static_actions() -> Array:
	if not _static_actions.is_empty():
		return _static_actions
	ensure_api()
	var a: Array = []
	var fc := "Flow Control"
	a.append(_act("Branch", fc, "branch", {}, "", "if"))
	a.append(_act("Sequence", fc, "sequence", {"n": 2}))
	a.append(_act("For Loop", fc, "for", {}))
	a.append(_act("For Each Loop", fc, "for_each", {}, "", "foreach"))
	a.append(_act("Reverse For Each Loop", fc, "for_each", {"rev": true}, "", "foreach backwards"))
	a.append(_act("For Each Loop (Dictionary)", fc, "for_each_dict", {}, "", "foreach map keys values"))
	a.append(_act("MultiGate", fc, "multigate", {"n": 2}, "", "multi gate cycle"))
	a.append(_act("Format String", "Utilities|String", "format", {"text": "Hello {name}"}, "", "format text append build"))
	for mop in MATH_OPS:
		var words := String(OP_WORDS.get(mop, ""))
		var ma := _act("%s (%s)" % [MATH_OPS[mop][0], mop], "Math|Operators", "math", {"op": mop, "n": 2}, "", words + " wildcard")
		ma["pri"] = true
		a.append(ma)
	for kv in api.enums.get("Key", []):
		var kn := String(kv[0])
		if kn in ["KEY_NONE", "KEY_SPECIAL", "KEY_UNKNOWN"]:
			continue
		a.append(_act("Keyboard " + kn.trim_prefix("KEY_").capitalize(), "Input|Keyboard Events", "key_event", {"key": kn}, "", "key press " + kn))
	for en in api.enums:
		for ev in api.enums[en]:
			a.append(_act(String(ev[0]), "Enums|" + String(en), "const", {"expr": String(ev[0]), "t": "int", "label": String(ev[0])}, "", "enum literal"))
	a.append(_act("While Loop", fc, "while", {}))
	a.append(_act("Break Loop", fc, "loop_break", {}))
	a.append(_act("Continue Loop", fc, "loop_continue", {}))
	a.append(_act("Delay", fc, "delay", {}, "", "wait sleep timer"))
	a.append(_act("Retriggerable Delay", fc, "retriggerable_delay", {}, "", "wait"))
	a.append(_act("Do Once", fc, "do_once", {}))
	a.append(_act("Do N", fc, "do_n", {}))
	a.append(_act("Flip Flop", fc, "flip_flop", {}))
	a.append(_act("Gate", fc, "gate", {}))
	a.append(_act("Switch on Int", fc + "|Switch", "switch", {"t": "int", "cases": [["0", "0"], ["1", "1"]]}))
	a.append(_act("Wait For (signal)", fc, "await_value", {}, "", "await signal wait until"))
	a.append(_act("Sequence (waits for each step)", fc, "sequence", {"n": 2, "wait": true}, "", "await in order"))
	a.append(_act("For Each Loop (waits for each step)", fc, "for_each", {"wait": true}, "", "foreach await"))
	a.append(_act("While Loop (waits for each step)", fc, "while", {"wait": true}, "", "await"))
	a.append(_act("Call If Present", "Utilities|Interface", "message", {"n": 1}, "", "interface message duck has method"))
	a.append(_act("Get (by name)", "Utilities|By Name", "dyn_get", {"name": "value"}, "", "property untyped dynamic"))
	a.append(_act("Set (by name)", "Utilities|By Name", "dyn_set", {"name": "value"}, "", "property untyped dynamic"))
	a.append(_act("Call (by name)", "Utilities|By Name", "dyn_call", {"method": "call", "n": 0}, "", "function untyped dynamic"))
	for tn in ["Dictionary", "Array", "String", "int", "float", "bool", "Vector2", "Vector3", "Callable"]:
		a.append(_act("Is %s" % tn, "Utilities|Type", "is_type", {"type": tn}, "", "type check is a"))
		a.append(_act("As %s" % tn, "Utilities|Type", "as_type", {"type": tn}, "", "type convert cast"))
	a.append(_act("Switch on String", fc + "|Switch", "switch", {"t": "String", "cases": [["A", "\"A\""], ["B", "\"B\""]]}))
	a.append(_act("Is Valid", "Utilities", "is_valid", {}, "", "null check ? isvalid"))
	a.append(_act("Select", "Utilities", "select", {}, "", "ternary pick"))
	a.append(_act("Print String", "Utilities|String", "print", {}, "", "log debug"))
	a.append(_act("Math Expression", "Math", "expr", {"code": "a + b", "ins": ["a", "b"]}))
	a.append(_act("GDScript Code", "Utilities", "code", {"code": "pass", "ins": []}, "Runs lines of GDScript as written.", "script custom code raw"))
	a.append(_act("Make Array", "Utilities|Array", "make_array", {"n": 2}))
	a.append(_act("Make Dictionary", "Utilities|Dictionary", "make_dict", {"n": 1}, "", "make map set"))
	a.append(_act("Get (element by index or key)", "Utilities|Array", "index", {}, "", "array dictionary item"))
	a.append(_act("Set Element", "Utilities|Array", "set_index", {}, "", "array dictionary item"))
	a.append(_act("Spawn Scene (3D)", "Game", "spawn", {"xt": "Transform3D"}, "", "instantiate spawn actor from class"))
	a.append(_act("Spawn Scene (2D)", "Game", "spawn", {"xt": "Transform2D"}, "", "instantiate spawn actor from class"))
	a.append(_act("Add Reroute Node", "Utilities", "reroute", {}))
	a.append(_act("Add Comment", "Utilities", "comment", {"text": "Comment", "w": 400, "h": 200}))
	a.append(_act("Equal (==)", "Math|Compare", "op", {"op": "==", "l": "any", "r": "any", "ret": "bool"}, "", "equal"))
	a.append(_act("Not Equal (!=)", "Math|Compare", "op", {"op": "!=", "l": "any", "r": "any", "ret": "bool"}, "", "not equal"))
	a.append(_act("AND Boolean", "Math|Boolean", "op", {"op": "and", "l": "bool", "r": "bool", "ret": "bool"}, "", "&&"))
	a.append(_act("OR Boolean", "Math|Boolean", "op", {"op": "or", "l": "bool", "r": "bool", "ret": "bool"}, "", "||"))
	a.append(_act("NOT Boolean", "Math|Boolean", "op", {"op": "not", "l": "bool", "r": "", "ret": "bool"}, "", "!"))
	for u in api.utils:
		var cat := "Utilities"
		match u.c:
			"math": cat = "Math"
			"random": cat = "Math|Random"
		a.append(_act(nice(u.n), cat, "util", {"name": u.n, "n": maxi(u.a.size(), 1)} if bool(u.v) else {"name": u.n}, u.d, u.n))
	for tn in api.types:
		var t: Dictionary = api.types[tn]
		var cat: String = "Math|" + tn if T.BUILTIN.get(tn, 0) < TYPE_STRING or (T.BUILTIN.get(tn, 0) >= TYPE_VECTOR2 and T.BUILTIN.get(tn, 0) <= TYPE_COLOR) else "Utilities|" + tn
		for i in t.ctor.size():
			var c: Array = t.ctor[i]
			if c.is_empty() or (c.size() == 1 and c[0][1] == tn):
				continue
			var names := PackedStringArray()
			for arg in c:
				names.append(arg[0])
			a.append(_act("Make %s (%s)" % [tn, ", ".join(names)], cat, "ctor", {"type": tn, "i": i}, "", "construct"))
		if not break_members(tn).is_empty():
			a.append(_act("Break " + tn, cat, "break", {"type": tn}, "", "split"))
		for m in t.m:
			a.append(_act(nice(m.n), cat, "bcall", {"type": tn, "method": m.n, "n": 1} if bool(m.v) else {"type": tn, "method": m.n}, m.d, m.n))
		for o in t.op:
			if o[1] == "Variant" or o[0] in ["==", "!=", "and", "or", "xor", "not", "in", "unary+"]:
				continue
			var label := ("%s %s %s" % [tn, o[0], o[1]]) if o[1] != "" else ("%s %s" % [String(o[0]).trim_prefix("unary"), tn])
			a.append(_act(label, cat, "op", {"op": o[0], "l": tn, "r": o[1], "ret": api_type(o[2])}, "", OP_WORDS.get(o[0], "")))
		for c in t.const:
			a.append(_act("%s.%s" % [tn, c[0]], cat + "|Constants", "const", {"expr": "%s.%s" % [tn, c[0]], "t": api_type(c[1]), "label": "%s.%s" % [tn, c[0]]}))
	for cls in ClassDB.get_class_list():
		a.append(_act("Cast To " + cls, "Casting", "cast", {"cls": String(cls)}))
		if ClassDB.can_instantiate(cls) and not ClassDB.is_parent_class(cls, "Node") and not Engine.has_singleton(cls):
			a.append(_act("Construct " + cls, "Construct Object", "new", {"cls": String(cls)}, "", "new create"))
		elif ClassDB.can_instantiate(cls) and ClassDB.is_parent_class(cls, "Node"):
			a.append(_act("Construct " + cls, "Construct Node", "new", {"cls": String(cls)}, "", "new create"))
	for s in Engine.get_singleton_list():
		if ClassDB.class_exists(s):
			a.append_array(class_actions(String(s), "Singletons|" + s))
	_static_actions = a
	return a


## Actions for the *own* members of one class.
static func class_actions(cls: String, cat := "") -> Array:
	var key := cls + "@" + cat
	if _class_actions.has(key):
		return _class_actions[key]
	if cat == "":
		cat = "Class|" + cls
	var out := []
	var info := cls_info(cls)
	var prop_accessors := {}
	if ClassDB.class_exists(cls):
		for pn in info.p:
			prop_accessors[String(ClassDB.class_get_property_getter(cls, pn))] = true
			prop_accessors[String(ClassDB.class_get_property_setter(cls, pn))] = true
	for mn in info.m:
		var m: Dictionary = info.m[mn]
		if String(mn).begins_with("_") or String(mn).begins_with("@") or (int(m.get("flags", 0)) & METHOD_FLAG_VIRTUAL):
			continue
		if prop_accessors.has(mn) and (m.args as Array).size() <= 1:
			continue  # exposed as Get/Set property nodes instead
		var p := {"cls": cls, "method": mn}
		if int(m.get("flags", 0)) & METHOD_FLAG_VARARG:
			p["n"] = 1
		out.append(_act(nice(mn), cat, "call", p, "", mn))
	for pn in info.p:
		var ptype := type_string(int(info.p[pn].get("type", 0)))
		out.append(_act("Get " + nice(pn), cat + "|Variables", "get_prop", {"cls": cls, "prop": pn}, "", pn))
		out[-1]["vt"] = ptype
		if not (int(info.p[pn].usage) & PROPERTY_USAGE_READ_ONLY):
			out.append(_act("Set " + nice(pn), cat + "|Variables", "set_prop", {"cls": cls, "prop": pn}, "", pn))
			out[-1]["vt"] = ptype
	if ClassDB.class_exists(cls):
		for en in ClassDB.class_get_enum_list(cls, true):
			for ec in ClassDB.class_get_enum_constants(cls, en, true):
				out.append(_act("%s.%s" % [cls, ec], cat + "|Enums|" + String(en), "const",
					{"expr": "%s.%s" % [cls, ec], "t": "int", "label": String(ec)}, "", "enum literal " + String(en)))
	for sn in info.s:
		out.append(_act("Bind Event to " + nice(sn), cat + "|Event Dispatchers", "bind_signal", {"cls": cls, "signal": sn}, "", sn + " connect assign"))
		out.append(_act("Unbind Event from " + nice(sn), cat + "|Event Dispatchers", "unbind_signal", {"cls": cls, "signal": sn}, "", sn + " disconnect"))
		out.append(_act("Wait for " + nice(sn), cat + "|Event Dispatchers", "await_signal", {"cls": cls, "signal": sn}, "", sn + " await"))
		out.append(_act("Assign " + nice(sn), cat + "|Event Dispatchers", "__assign", {"cls": cls, "signal": sn, "args": signal_args(info.s[sn])},
			"Binds the signal and creates a matching custom event in one step.", sn + " bind event create"))
	_class_actions[key] = out
	return out


static func chain_actions(cls: String) -> Array:
	var out := []
	var guard := 0
	while cls != "" and guard < 64:
		out.append_array(class_actions(cls))
		cls = T.parent_of(cls)
		guard += 1
	return out


static func all_class_actions() -> Array:
	if _all_class_actions.is_empty():
		for cls in ClassDB.get_class_list():
			_all_class_actions.append_array(class_actions(String(cls)))
	var out := _all_class_actions.duplicate()
	var fn_libs := {}
	for lib in libraries():
		if lib.kind == "function":
			fn_libs[String(lib.name)] = true
	for g in T.globals():
		out.append_array(class_actions(g, ("Function Libraries|" + g) if fn_libs.has(g) else ""))
	return out


## The functions of every function library: offered in every schematic, whatever its class.
static func function_library_actions() -> Array:
	var out := []
	for lib in libraries():
		if lib.kind == "function" and T.globals().has(String(lib.name)):
			out.append_array(class_actions(String(lib.name), "Function Libraries|" + String(lib.name)))
	return out


static func signal_args(info: Dictionary) -> Array:
	var out := []
	for a in info.get("args", []):
		out.append([String(a.name), T.from_info(a)])
	return out


## Engine virtuals, plus every function of a script (schematic) parent class, can be overridden.
static func is_overridable(cls: String, m: Dictionary) -> bool:
	if int(m.get("flags", 0)) & METHOD_FLAG_VIRTUAL:
		return true
	var mn := String(m.get("name", ""))
	return not ClassDB.class_exists(cls) and not mn.begins_with("__") and not mn.begins_with("@") and not mn.begins_with("_on_")


static func autoloads() -> Array:
	var out := []
	for prop in ProjectSettings.get_property_list():
		var pn := String(prop.name)
		if not pn.begins_with("autoload/"):
			continue
		var path := String(ProjectSettings.get_setting(pn)).trim_prefix("*")
		var cls := "Node"
		if path.get_extension() == "gd" and ResourceLoader.exists(path):
			var scr := load(path) as Script
			if scr:
				cls = String(scr.get_global_name()) if scr.get_global_name() != &"" else String(scr.get_instance_base_type())
		out.append([pn.substr(9), cls])
	return out


## Actions that depend on the schematic being edited.
static func schematic_actions(bp: Dictionary, graph: Dictionary) -> Array:
	var a := []
	var sc := self_class(bp)
	a.append(_act("Get a reference to self", "Variables", "self", {}, "", "this"))
	a.append(_act("Add Custom Event...", "Add Event", "custom_event", {"name": "CustomEvent", "params": []}))
	a.append(_act("Get Node (by path)", "Variables|Scene", "get_node", {"path": ".", "cls": "Node"}, "", "$ component reference"))
	var seen := {}
	var cls := sc
	var guard := 0
	while cls != "" and guard < 64:
		var info := cls_info(cls)
		for mn in info.m:
			var m: Dictionary = info.m[mn]
			if not is_overridable(cls, m) or seen.has(mn):
				continue
			seen[mn] = true
			if T.from_info(m.get("return", {}), true) == "":
				a.append(_act("Event " + nice(mn), "Add Event", "event", {"name": mn}, doc(cls, mn), mn + " begin play tick" if mn in ["_ready", "_process"] else mn))
			a.append(_act("Parent: " + nice(mn), "Call Parent Function", "call_parent", {"method": mn}, "", "super " + mn))
		for sn in info.s:
			a.append(_act("On " + nice(sn) + " (self)", "Add Event|Signals", "signal_event",
				{"path": ".", "signal": sn, "cls": cls, "args": signal_args(info.s[sn])}, doc(cls, "!" + sn), sn))
		cls = T.parent_of(cls)
		guard += 1
	for prop in ProjectSettings.get_property_list():
		var pn := String(prop.name)
		if pn.begins_with("input/"):
			a.append(_act("InputAction " + pn.substr(6), "Input|Action Events", "input_action", {"action": pn.substr(6)}))
	for an in ["ui_accept", "ui_cancel", "ui_left", "ui_right", "ui_up", "ui_down", "ui_select"]:
		a.append(_act("InputAction " + an, "Input|Action Events", "input_action", {"action": an}))
	for v in bp.variables:
		a.append(_act("Get " + v.name, "Variables", "var_get", {"name": v.name}))
		a[-1]["vt"] = String(v.type)
		a.append(_act("Set " + v.name, "Variables", "var_set", {"name": v.name}))
		a[-1]["vt"] = String(v.type)
		if String(v.type) in ["int", "float"]:
			a.append(_act("Increment %s (++)" % v.name, "Variables", "var_inc", {"name": v.name, "by": 1}, "", "add one plus"))
			a.append(_act("Decrement %s (--)" % v.name, "Variables", "var_inc", {"name": v.name, "by": -1}, "", "subtract one minus"))
	for l in graph.get("locals", []):
		a.append(_act("Get " + l.name, "Variables|Local", "local_get", {"name": l.name}))
		a[-1]["vt"] = String(l.type)
		a.append(_act("Set " + l.name, "Variables|Local", "local_set", {"name": l.name}))
		a[-1]["vt"] = String(l.type)
	for dsp in bp.dispatchers:
		a.append(_act("Call " + dsp.name, "Event Dispatchers", "emit", {"name": dsp.name}, "", "broadcast emit"))
	for g in bp.graphs:
		if g.kind == "function":
			a.append(_act(g.name, "Call Function", "call_self", {"fn": g.name}))
			a.append(_act("Event reference: " + g.name, "Event Dispatchers|Create Event", "event_ref", {"fn": g.name}, "", "callable delegate"))
		for n in g.nodes:
			if n.kind == "custom_event":
				a.append(_act(n.p.name, "Call Function", "call_self", {"fn": n.p.name}))
				a.append(_act("Event reference: " + n.p.name, "Event Dispatchers|Create Event", "event_ref", {"fn": n.p.name}, "", "callable delegate"))
	for be in bp.get("enums", []):
		for bv in be.values:
			a.append(_act("%s.%s" % [be.name, bv], "Enums|" + String(be.name), "const",
				{"expr": "%s.%s" % [T.ident(String(be.name)), T.ident(String(bv))], "t": "int", "label": "%s.%s" % [be.name, bv]}, "", "enum literal"))
	a.append_array(data_actions())
	a.append_array(Kits.actions(sc))
	for tid in templates:
		var t: Dictionary = templates[tid]
		if t.has("for"):
			continue   # only for schematics of certain classes: offered by Kits.actions()
		a.append(_act(String(t.title), String(t.get("cat", "Utilities")), "tpl", {"id": tid}, String(t.get("tip", "")), String(t.get("search", ""))))
	for al in autoloads():
		a.append(_act("Get " + String(al[0]), "Autoloads", "autoload", {"name": al[0], "cls": al[1]}, "", "singleton global game instance"))
	for mg in bp.graphs:
		if mg.kind == "macro" and int(mg.id) != int(graph.get("id", -1)):
			a.append(_act(mg.name, "Macros", "macro", {"name": mg.name}))
	for iname in interfaces():
		a.append(_act("Does Implement Interface: %s" % iname, "Interface Messages|" + String(iname), "iface_has", {"iface": iname},
			"True when the target has every function of %s." % iname, "interface implements"))
		for ig in interface_functions(String(iname)):
			a.append(_act("%s (Message)" % nice(String(ig.name)), "Interface Messages|" + String(iname), "iface_call", {"iface": iname, "fn": String(ig.name)},
				"Calls %s on the target if the target has it; does nothing otherwise." % ig.name, "interface message call " + String(ig.name)))
	for lib in libraries():
		if lib.kind != "macro" or String(lib.path) == editing_path:
			continue
		for lg in library_bp(String(lib.path)).get("graphs", []):
			if lg.kind == "macro":
				a.append(_act(String(lg.name), "Macros|" + String(lib.name), "macro", {"name": lg.name, "lib": lib.path},
					"From the macro library %s." % lib.path, "macro library"))
	if graph.get("kind", "") != "function":
		a.append(_act("Add Timeline...", "Add Timeline", "timeline", {"name": "Timeline", "length": 1.0, "loop": false, "autoplay": false,
			"tracks": [{"name": "Alpha", "type": "float", "smooth": false, "keys": [[0.0, "0.0"], [1.0, "1.0"]]}]}))
	for gname in T.globals():
		a.append(_act("Cast To " + gname, "Casting", "cast", {"cls": gname}))
		a.append(_act("Construct " + gname, "Construct Object", "new", {"cls": gname}, "", "new create"))
	return a


## Does a freshly created node of this action have a pin that can take a wire from/to `ctx`?
## ctx = {type: pin type, out: true if dragging from an output pin}
static func action_fits(act: Dictionary, bp: Dictionary, graph: Dictionary, ctx: Dictionary) -> bool:
	var d := describe({"kind": act.k, "p": act.p}, bp, graph)
	var pins: Array = d.ins if ctx.out else d.outs
	for pin in pins:
		if ctx.type == "exec" or pin.type == "exec":
			if ctx.type == pin.type:
				return true
			continue
		if ctx.out and T.matches(ctx.type, pin.type):
			return true
		if not ctx.out and T.matches(pin.type, ctx.type):
			return true
		if pin.type == "any" and act.k in ["print", "select", "reroute", "index", "set_index", "make_array", "op", "expr"]:
			return true
		if ctx.out and pin.type == "String" and act.k == "print":
			return true
	return false
