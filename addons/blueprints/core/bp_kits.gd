@tool
extends RefCounted
## Kits: nodes and starters for other graph tools installed in the project, so their graphs and Blueprints
## can drive each other. A kit is offered only when its addon is present.
##
##   LimboAI    behavior-tree tasks and state-machine states written as Blueprints, blackboard nodes
##              (one per variable the project uses), status values. Trees call Blueprint functions with
##              LimboAI's own Call Method task.
##   FlowNodes  run a flow graph from a Blueprint (one node per graph, with the graph's inputs and outputs
##              as pins), read and build point data, write a flow node as a Blueprint, and a "Call Blueprint"
##              flow node that hands a graph's data to a Blueprint function.
##   Parley     dialogue actions and facts written as Blueprints, Run Dialogue (one node per dialogue file),
##              the dialogue's data, and the project's facts, actions and characters as nodes.
##
## Everything here compiles to ordinary GDScript that names the other addon's classes directly; nothing of
## this plugin is needed when the game runs.

const REGISTRY_PATH := "res://addons/blueprints/core/bp_registry.gd"
const IMPORTER_PATH := "res://addons/blueprints/core/bp_importer.gd"
const MODEL_PATH := "res://addons/blueprints/core/bp_model.gd"

## Where the FlowNodes bridge is written in the project (see flow_setup()).
const FLOW_DIR := "res://blueprint_kits/flow_nodes"
const FLOW_AUTOLOAD := "BlueprintFlowNodes"
const FLOW_AUTOLOAD_PATH := "res://blueprint_kits/flow_nodes_bridge.gd"
const FLOW_FOLDERS_SETTING := "blueprints/kits/flow_node_folders"

static var _scanned := false
static var _bb_vars: Dictionary = {}      # blackboard variable name -> blueprint type ("any" when unknown)
static var _flow_graphs: Array = []       # [{path, name, ins: [[name, type, default]], outs: [name]}]
static var _has_flow := -1
static var _has_parley := -1
static var _dialogues: Array = []         # paths of Parley dialogue files
static var _parley_items: Array = []      # [{kind: "fact"|"action"|"character", id, name, path}]


static func has_limbo() -> bool:
	return ClassDB.class_exists("BTTask") and ClassDB.class_exists("Blackboard")


static func has_flow() -> bool:
	if _has_flow == -1:
		_has_flow = 0
		for c in ProjectSettings.get_global_class_list():
			if String(c.get("class", "")) == "FlowNodeBase":
				_has_flow = 1
	return _has_flow == 1


static func has_parley() -> bool:
	if _has_parley == -1:
		_has_parley = 0
		for c in ProjectSettings.get_global_class_list():
			if String(c.get("class", "")) == "ParleyActionInterface":
				_has_parley = 1
	return _has_parley == 1


## Forget what was read from the project (blackboard variables, flow graphs); it is read again when needed.
static func invalidate() -> void:
	_scanned = false
	_has_flow = -1
	_has_parley = -1


# ---------------------------------------------------------------- templates

## Registers the fixed nodes of every kit whose addon is present. `registry` is the registry script.
static func register(registry: Script) -> void:
	if has_limbo():
		_limbo_templates(registry)
	if has_flow():
		_flow_templates(registry)
	if has_parley():
		_parley_templates(registry)


const PARLEY_RUN_LINES := ["var __ctx_{id}: ParleyContext = ParleyContext.create({sequence} as ParleyDialogueSequenceAst, {data})",
	# a dialogue can end before anything gets to wait for it, so the context remembers that it has
	"__ctx_{id}.dialogue_ended.connect(__ctx_{id}.set_meta.bind(&\"bp_ended\", true), CONNECT_ONE_SHOT)",
	# (the balloon frees the context when it closes, as Parley's own balloon does)
	"var __balloon_{id}: Node = Parley.run_dialogue(__ctx_{id}, __ctx_{id}.dialogue_sequence_ast)"]
const PARLEY_FACT_HELPER := ["__bp_parley_fact", "func __bp_parley_fact(script_path: String, ctx: Variant) -> Variant:", [
	[1, "var fact: Object = (load(script_path) as GDScript).new()"], [1, "var own: Object = ParleyContext.new() if ctx == null else null"],
	[1, "var value: Variant = fact.call(&\"evaluate\", own if ctx == null else ctx, [])"], [1, "fact.free()"],
	[1, "if own != null:"], [2, "own.free()"], [1, "return value"]]]
const PARLEY_ACTION_HELPER := ["__bp_parley_action", "func __bp_parley_action(script_path: String, ctx: Variant, values: Array) -> void:", [
	[1, "var action: Object = (load(script_path) as GDScript).new()"], [1, "var own: Object = ParleyContext.new() if ctx == null else null"],
	[1, "action.call(&\"run\", own if ctx == null else ctx, values)"], [1, "action.free()"],
	[1, "if own != null:"], [2, "own.free()"]]]


static func _parley_templates(r: Script) -> void:
	r.register_template("parley_run", {"title": "Run Dialogue", "cat": "Parley",
		"search": "parley dialogue conversation start talk speak balloon", "tip": "Starts a Parley dialogue with the project's dialogue balloon. Data is what the dialogue's facts and actions can read (its context data). Context is what to wait on or read afterwards; the balloon frees it when it closes, so read its data right after the dialogue ends.",
		"ins": [["sequence", "Dialogue", "Resource", ""], ["data", "Data", "Dictionary", "{}"]],
		"outs": [["ctx", "Context", "Object"], ["balloon", "Balloon", "Node"]],
		"lines": PARLEY_RUN_LINES, "exprs": {"ctx": "__ctx_{id}", "balloon": "__balloon_{id}"}})
	r.register_template("parley_wait", {"title": "Wait for Dialogue to End", "cat": "Parley", "latent": true,
		"search": "parley dialogue finished ended await", "tip": "Continues when the dialogue started with this context has ended.",
		"ins": [["ctx", "Context", "Object", ""]], "outs": [], "lines": ["if not {ctx}.has_meta(&\"bp_ended\"):", "	await {ctx}.dialogue_ended"]})
	r.register_template("parley_data_get", {"title": "Get Dialogue Data", "cat": "Parley", "pure": true,
		"search": "parley context data read value", "tip": "A value of the running dialogue's data (Default when it is not there). In an action or a fact, Context is the ctx input.",
		"ins": [["ctx", "Context", "any", ""], ["key", "Key", "String", "\"\""], ["default", "Default", "any", ""]], "outs": [["ret", "Value", "any"]],
		"exprs": {"ret": "{ctx}.p_data.get({key}, {default})"}})
	r.register_template("parley_data_set", {"title": "Set Dialogue Data", "cat": "Parley",
		"search": "parley context data write value", "tip": "Stores a value in the running dialogue's data, where later facts, actions and the Blueprint that started it can read it.",
		"ins": [["ctx", "Context", "any", ""], ["key", "Key", "String", "\"\""], ["value", "Value", "any", ""]], "outs": [],
		"lines": ["{ctx}.p_data[{key}] = {value}"]})
	r.register_template("parley_group_node", {"title": "Get First Node In Group (from anywhere)", "cat": "Parley", "pure": true,
		"search": "parley action fact find node group scene tree player", "tip": "A node of the running game, for blueprints that are not nodes themselves (dialogue actions and facts).",
		"ins": [["group", "Group", "StringName", "&\"player\""]], "outs": [["ret", "Node", "Node"]],
		"exprs": {"ret": "(Engine.get_main_loop() as SceneTree).get_first_node_in_group({group})"}})


static func _limbo_templates(r: Script) -> void:
	var own := ["BTTask", "LimboState"]
	r.register_template("limbo_bb_get_own", {"title": "Get Blackboard Var", "cat": "LimboAI|Blackboard", "pure": true, "for": own,
		"search": "blackboard read variable limbo behavior tree", "tip": "A variable of this task's (or state's) blackboard. Default is returned when it does not exist.",
		"ins": [["var", "Variable", "StringName", "&\"target\""], ["default", "Default", "any", ""]], "outs": [["ret", "Value", "any"]],
		"exprs": {"ret": "blackboard.get_var({var}, {default}, false)"}})
	r.register_template("limbo_bb_set_own", {"title": "Set Blackboard Var", "cat": "LimboAI|Blackboard", "for": own,
		"search": "blackboard write variable limbo behavior tree", "tip": "Stores a value in this task's (or state's) blackboard.",
		"ins": [["var", "Variable", "StringName", "&\"target\""], ["value", "Value", "any", ""]], "outs": [],
		"lines": ["blackboard.set_var({var}, {value})"]})
	r.register_template("limbo_bb_has_own", {"title": "Has Blackboard Var", "cat": "LimboAI|Blackboard", "pure": true, "for": own,
		"search": "blackboard exists variable limbo", "ins": [["var", "Variable", "StringName", "&\"target\""]], "outs": [["ret", "Return Value", "bool"]],
		"exprs": {"ret": "blackboard.has_var({var})"}})
	r.register_template("limbo_bb_get", {"title": "Get Blackboard Var (of a BT Player or State)", "cat": "LimboAI|Blackboard", "pure": true,
		"search": "blackboard read variable limbo behavior tree btplayer hsm", "tip": "A blackboard variable of a BTPlayer, LimboHSM or LimboState node. Default is returned when it does not exist.",
		"ins": [["owner", "BT Player or State", "Node", ""], ["var", "Variable", "StringName", "&\"target\""], ["default", "Default", "any", ""]],
		"outs": [["ret", "Value", "any"]], "exprs": {"ret": "{owner}.blackboard.get_var({var}, {default}, false)"}})
	r.register_template("limbo_bb_set", {"title": "Set Blackboard Var (of a BT Player or State)", "cat": "LimboAI|Blackboard",
		"search": "blackboard write variable limbo behavior tree btplayer hsm", "tip": "Stores a value in the blackboard of a BTPlayer, LimboHSM or LimboState node, where its tree or states read it.",
		"ins": [["owner", "BT Player or State", "Node", ""], ["var", "Variable", "StringName", "&\"target\""], ["value", "Value", "any", ""]], "outs": [],
		"lines": ["{owner}.blackboard.set_var({var}, {value})"]})
	r.register_template("limbo_bb_bind", {"title": "Bind Blackboard Var to My Variable", "cat": "LimboAI|Blackboard",
		"search": "blackboard bind link property variable limbo", "tip": "From now on the blackboard variable IS this blueprint's variable: the tree reads and writes it directly.",
		"ins": [["owner", "BT Player or State", "Node", ""], ["var", "Blackboard Variable", "StringName", "&\"target\""], ["property", "My Variable", "StringName", "&\"\""]],
		"outs": [], "lines": ["{owner}.blackboard.bind_var_to_property({var}, self, {property}, true)"]})
	r.register_template("limbo_dispatch", {"title": "Dispatch State Machine Event", "cat": "LimboAI|State Machine",
		"search": "hsm dispatch event transition limbo state", "tip": "Sends an event to a LimboHSM or LimboState; a transition registered for it changes the active state.",
		"ins": [["target", "State Machine", "LimboState", "self"], ["event", "Event", "StringName", "&\"\""], ["cargo", "Cargo", "any", ""]],
		"outs": [["ret", "Was Consumed", "bool"]], "always": true, "exprs": {"ret": "{target}.dispatch({event}, {cargo})"}})


static func _flow_templates(r: Script) -> void:
	var run_helper := ["__bp_flow_run", "func __bp_flow_run(graph: Resource, inputs: Dictionary, host: Node) -> Dictionary:", [
		[1, "var ctx := FlowData.EvaluationContext.new()"], [1, "ctx.owner = host as FlowGraphNode3D"],
		[1, "ctx.gedit_nodes_by_name = {}"], [1, "ctx.runtime_params = {}"],
		[1, "return FlowNodeIO.evaluate_graph(graph as FlowGraphResource, inputs, ctx, {}, 0)"]]]
	r.register_template("flow_run", {"title": "Run Flow Graph", "cat": "FlowNodes", "always": true,
		"search": "pcg flow graph generate evaluate execute procedural", "tip": "Runs a flow graph now and returns its outputs by name (each one is flow data). Inputs are given by name. Host is the Flow Graph Node that spawned things are added to; without one the graph can only compute.",
		"ins": [["graph", "Flow Graph", "Resource", ""], ["inputs", "Inputs", "Dictionary", "{}"], ["host", "Host", "Node", ""]],
		"outs": [["ret", "Outputs", "Dictionary"]], "exprs": {"ret": "__bp_flow_run({graph}, {inputs}, {host})"}, "helper": run_helper})
	r.register_template("flow_count", {"title": "Flow Data: Point Count", "cat": "FlowNodes|Data", "pure": true, "search": "pcg points size number",
		"ins": [["data", "Flow Data", "any", ""]], "outs": [["ret", "Count", "int"]], "exprs": {"ret": "{data}.size()"}})
	r.register_template("flow_positions", {"title": "Flow Data: Positions", "cat": "FlowNodes|Data", "pure": true, "search": "pcg points location",
		"ins": [["data", "Flow Data", "any", ""]], "outs": [["ret", "Positions", "PackedVector3Array"]],
		"exprs": {"ret": "{data}.getVector3Container(&\"position\")"}})
	r.register_template("flow_transform", {"title": "Flow Data: Point Transform", "cat": "FlowNodes|Data", "pure": true, "search": "pcg point transform rotation size",
		"tip": "Position, rotation and size of one point as a transform.",
		"ins": [["data", "Flow Data", "any", ""], ["index", "Index", "int", "0"]], "outs": [["ret", "Transform", "Transform3D"]],
		"exprs": {"ret": "{data}.getTransformsStream().atIndex({index})"}})
	r.register_template("flow_values", {"title": "Flow Data: Get Attribute", "cat": "FlowNodes|Data", "pure": true, "search": "pcg attribute stream column values",
		"tip": "Every point's value of one attribute, as an array (empty when the data has no such attribute).",
		"ins": [["data", "Flow Data", "any", ""], ["name", "Attribute", "String", "\"density\""]], "outs": [["ret", "Values", "Array"]],
		"exprs": {"ret": "__bp_flow_values({data}, {name})"},
		"helper": ["__bp_flow_values", "func __bp_flow_values(data: Variant, attribute: String) -> Array:", [
			[1, "var stream: Variant = data.findStream(attribute) if data != null else null"],
			[1, "return Array(stream.container) if stream != null else []"]]]})
	r.register_template("flow_set_values", {"title": "Flow Data: Set Attribute", "cat": "FlowNodes|Data", "search": "pcg attribute stream column write register",
		"tip": "Writes one value per point (or a single value for all of them) under an attribute name, replacing it if it exists.",
		"ins": [["data", "Flow Data", "any", ""], ["name", "Attribute", "String", "\"position\""], ["values", "Values", "any", ""]], "outs": [],
		"lines": ["__bp_flow_set({data}, {name}, {values})"],
		"helper": ["__bp_flow_set", "func __bp_flow_set(data: Variant, attribute: String, values: Variant) -> void:", [
			[1, "if values is Array:"],
			[2, "var kind: int = FlowNodeBase.getFlowDataTypeFromObject(values[0]) if not values.is_empty() else FlowData.DataType.Float"],
			[2, "var packed: Variant = FlowData.Data.newContainerOfType(kind)"],
			[2, "packed.resize(values.size())"],
			[2, "for i in values.size():"], [3, "FlowData.Data.writeValue(packed, i, values[i], kind)"],
			[2, "values = packed"],
			[1, "data.registerStream(attribute, values)"]]]})
	r.register_template("flow_points", {"title": "Make Flow Points", "cat": "FlowNodes|Data", "search": "pcg create points data from positions",
		"tip": "New flow data with one point at each position (rotation zero, size one).",
		"ins": [["positions", "Positions", "PackedVector3Array", "PackedVector3Array()"]], "outs": [["ret", "Flow Data", "any"]],
		"exprs": {"ret": "__bp_flow_points({positions})"},
		"helper": ["__bp_flow_points", "func __bp_flow_points(positions: PackedVector3Array) -> Variant:", [
			[1, "var data := FlowData.Data.new()"], [1, "data.addCommonStreams(positions.size())"],
			[1, "data.registerStream(\"position\", positions, FlowData.DataType.Vector)"], [1, "return data"]]]})
	r.register_template("flow_copy", {"title": "Copy Flow Data", "cat": "FlowNodes|Data", "search": "pcg duplicate clone data",
		"tip": "A copy to change, so the data other nodes of the graph received stays as it was.",
		"ins": [["data", "Flow Data", "any", ""]], "outs": [["ret", "Copy", "any"]], "exprs": {"ret": "{data}.duplicate()"}})
	# writing a flow node as a Blueprint (parent class FlowNodeBase)
	var node := ["FlowNodeBase"]
	r.register_template("flow_define", {"title": "Define Flow Node", "cat": "FlowNodes|Flow Node", "for": node,
		"search": "pcg flow node meta title ports", "tip": "Call it from _init: the title, category and ports this node shows in the flow graph editor. Settings Class is the resource that holds its options (NodeSettings has none).",
		"ins": [["title", "Title", "String", "\"My Node\""], ["category", "Category", "String", "\"Blueprints\""],
			["ins", "Inputs", "PackedStringArray", "PackedStringArray([\"In\"])"], ["outs", "Outputs", "PackedStringArray", "PackedStringArray([\"Out\"])"],
			["tip", "Tooltip", "String", "\"\""], ["settings", "Settings Class", "any", "NodeSettings"]],
		"outs": [],
		"lines": ["meta_node = {\"title\": {title}, \"settings\": {settings}, \"category\": {category}, \"tooltip\": {tip},",
			"\t\"ins\": Array({ins}).map(func(port): return {\"label\": port}), \"outs\": Array({outs}).map(func(port): return {\"label\": port})}"]})
	r.register_template("flow_input", {"title": "Get Flow Input", "cat": "FlowNodes|Flow Node", "for": node, "always": true,
		"search": "pcg flow node input port data require", "tip": "The data wired into one of this node's inputs (null, with an error shown on the node, when nothing is).",
		"ins": [["port", "Port", "int", "0"], ["ctx", "Context", "any", ""]], "outs": [["ret", "Flow Data", "any"]],
		"exprs": {"ret": "require_input({port}, {ctx})"}})
	r.register_template("flow_output", {"title": "Set Flow Output", "cat": "FlowNodes|Flow Node", "for": node,
		"search": "pcg flow node output port data", "ins": [["port", "Port", "int", "0"], ["data", "Flow Data", "any", ""]], "outs": [],
		"lines": ["set_output({port}, {data})"]})


# ---------------------------------------------------------------- what the project has

static func _scan() -> void:
	if _scanned:
		return
	_scanned = true
	_bb_vars = {}
	_flow_graphs = []
	_dialogues = []
	_parley_items = []
	var limbo := has_limbo()
	var flow := has_flow()
	var parley := has_parley()
	if not limbo and not flow and not parley:
		return
	if parley:
		_read_parley_stores()
	var used := RegEx.create_from_string("(?:get_var|set_var|has_var|erase_var)\\(&?\"([A-Za-z_][A-Za-z0-9_]*)\"")
	var named := RegEx.create_from_string("_var: StringName = &\"([A-Za-z_][A-Za-z0-9_]*)\"")
	var pending := ["res://"]
	var seen_files := 0
	while not pending.is_empty() and seen_files < 6000:
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null or (dir_path != "res://" and dir.file_exists("project.godot")):
			continue
		for sub in dir.get_directories():
			if not sub.begins_with(".") and not (dir_path == "res://" and sub == "addons"):
				pending.append(dir_path.path_join(sub))
		for f in dir.get_files():
			var path := dir_path.path_join(f)
			var ext := f.get_extension()
			if ext == "gd" and limbo:
				seen_files += 1
				var text := FileAccess.get_file_as_string(path)
				if not text.contains("_var"):
					continue
				for m in used.search_all(text) + named.search_all(text):
					if not _bb_vars.has(m.get_string(1)):
						_bb_vars[m.get_string(1)] = "any"
			elif ext == "ds" and parley:
				_dialogues.append(path)
			elif ext == "tres":
				seen_files += 1
				var head := FileAccess.open(path, FileAccess.READ)
				var first := head.get_line() if head != null else ""
				if limbo and (first.contains("type=\"BehaviorTree\"") or first.contains("type=\"BlackboardPlan\"")):
					_read_plan(path)
				elif flow and first.contains("script_class=\"FlowGraphResource\""):
					_read_flow_graph(path)


## The variables a behavior tree's (or a stand-alone) blackboard plan declares, with the type of their values.
static func _read_plan(path: String) -> void:
	var res := ResourceLoader.load(path)
	var plan: Variant = res.get("blackboard_plan") if (res != null and res.is_class("BehaviorTree")) else res
	if plan == null or not (plan is Object) or not plan.is_class("BlackboardPlan"):
		return
	for prop in plan.get_property_list():
		# a plan lists each variable as var/<name>/value (among others)
		var parts := String(prop.name).split("/")
		if parts.size() == 3 and parts[0] == "var" and parts[2] == "value":
			var value: Variant = plan.get(prop.name)
			var t := _value_type(value)
			_bb_vars[parts[1]] = t if t != "" else "any"


static func _value_type(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_COLOR: return "Color"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_OBJECT: return (value as Object).get_class() if value != null else "any"
	return "any"


## A flow graph's declared inputs and outputs. DataType: Bool, Int, Float, Vector, String, Resource, .., Color.
static func _read_flow_graph(path: String) -> void:
	var res := ResourceLoader.load(path)
	if res == null or res.get("in_params") == null:
		return
	var type_names := {0: "bool", 1: "int", 2: "float", 3: "Vector3", 4: "String", 5: "Resource", 8: "Color"}
	var ins := []
	for param in res.in_params:
		if param == null or String(param.name) == "":
			continue
		var t := String(type_names.get(int(param.data_type), "any"))
		var def: Variant = param.get_default_value()
		# [name, kind of value it expects, default]: the pin itself takes anything, because an input can also be
		# fed flow data (a whole set of points) instead of one value
		ins.append([String(param.name), t, var_to_str(def) if (def != null and not (def is Object)) else ""])
	var outs := []
	for param in res.get("out_params"):
		if param != null and String(param.name) != "":
			outs.append(String(param.name))
	_flow_graphs.append({"path": path, "name": path.get_file().get_basename(), "ins": ins, "outs": outs})


static func dialogues() -> Array:
	_scan()
	return _dialogues


## The facts, actions and characters registered in the project's Parley stores.
static func parley_items() -> Array:
	_scan()
	return _parley_items


static func _read_parley_stores() -> void:
	for spec in [["fact", "parley/stores/fact_store_path", "facts"], ["action", "parley/stores/action_store_path", "actions"], ["character", "parley/stores/character_store_path", "characters"]]:
		var store_path := String(ProjectSettings.get_setting(spec[1], ""))
		if store_path == "" or not ResourceLoader.exists(store_path):
			continue
		var store := ResourceLoader.load(store_path)
		if store == null or not (store.get(spec[2]) is Array):
			continue
		for item in store.get(spec[2]):
			if item == null:
				continue
			var ref: Variant = item.get("ref")
			var path := String((ref as Resource).resource_path) if ref is Resource else ""
			if spec[0] != "character" and path == "":
				continue
			_parley_items.append({"kind": spec[0], "id": String(item.get("id")), "name": String(item.get("name")), "path": path})


static func blackboard_vars() -> Dictionary:
	_scan()
	return _bb_vars


static func flow_graphs() -> Array:
	_scan()
	return _flow_graphs


# ---------------------------------------------------------------- the action menu

static func _ident(text: String) -> String:
	var out := ""
	for ch in text:
		out += ch if (ch == "_" or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9")) else "_"
	return out if out != "" else "x"


static func _fits(self_cls: String, classes: Array) -> bool:
	var types: Script = load("res://addons/blueprints/core/bp_types.gd")
	for c in classes:
		if types.is_a(self_cls, String(c)):
			return true
	return false


## A blackboard node for one named variable. `own`: this blueprint's own blackboard (a task or a state).
static func blackboard_template(name: String, type: String, setter: bool, own: bool) -> Dictionary:
	var base := "blackboard" if own else "{owner}.blackboard"
	var t := {"title": ("Set %s" if setter else "Get %s") % name, "cat": "LimboAI|Blackboard Variables",
		"search": "blackboard limbo variable " + name, "ins": [], "outs": []}
	if not own:
		t.ins.append(["owner", "BT Player or State", "Node", ""])
	if setter:
		t.ins.append(["value", name, type, ""])
		t["lines"] = ["%s.set_var(&\"%s\", {value})" % [base, name]]
		t["tip"] = "Stores the blackboard variable '%s'." % name
	else:
		t["pure"] = true
		t.outs.append(["ret", name, type])
		t["exprs"] = {"ret": "%s.get_var(&\"%s\", null, false)" % [base, name]}
		t["tip"] = "The blackboard variable '%s' (null when it has not been set)." % name
	return t


## The node that runs one particular flow graph: its inputs and outputs are the node's pins.
static func flow_graph_template(info: Dictionary) -> Dictionary:
	var t := {"title": "Run Flow Graph: " + String(info.name), "cat": "FlowNodes|Graphs",
		"search": "pcg flow graph run generate " + String(info.name),
		"tip": "Runs %s. Host is the Flow Graph Node that spawned things are added to; without one the graph can only compute." % String(info.path),
		"ins": [], "outs": []}
	var pairs := PackedStringArray()
	for input in info.ins:
		var pin := "a_" + _ident(String(input[0]))
		var label := String(input[0]) if String(input[1]) == "any" else "%s (%s)" % [input[0], input[1]]
		t.ins.append([pin, label, "any", String(input[2])])
		pairs.append("\"%s\": {%s}" % [String(input[0]).c_escape(), pin])
	t.ins.append(["host", "Host", "Node", ""])
	t["lines"] = ["var __flow_{id}: Dictionary = __bp_flow_run(preload(\"%s\"), {%s}, {host})" % [String(info.path).c_escape(), ", ".join(pairs)]]
	t["exprs"] = {}
	for out_name in info.outs:
		var pin := "o_" + _ident(String(out_name))
		t.outs.append([pin, String(out_name), "any"])
		t.exprs[pin] = "__flow_{id}.get(\"%s\")" % String(out_name).c_escape()
	t.outs.append(["all", "All Outputs", "Dictionary"])
	t.exprs["all"] = "__flow_{id}"
	var r: Script = load(REGISTRY_PATH)
	t["helper"] = r.templates.get("flow_run", {}).get("helper", [])
	return t


## Menu entries that depend on this blueprint's class and on what the project contains.
static func actions(self_cls: String) -> Array:
	var out := []
	var r: Script = load(REGISTRY_PATH)
	# nodes that only make sense in a blueprint of a certain class
	for tid in r.templates:
		var t: Dictionary = r.templates[tid]
		if t.has("for") and _fits(self_cls, t["for"]):
			out.append(r._act(String(t.title), String(t.get("cat", "Utilities")), "tpl", {"id": tid}, String(t.get("tip", "")), String(t.get("search", ""))))
	if has_limbo():
		var own := _fits(self_cls, ["BTTask", "LimboState"])
		if _fits(self_cls, ["BTTask"]):
			for status in [["SUCCESS", "Success"], ["FAILURE", "Failure"], ["RUNNING", "Running"]]:
				out.append(r._act("Status: " + String(status[1]), "LimboAI|Status", "const", {"expr": status[0], "t": "int", "label": status[1]},
					"What _tick returns: the task %s." % ("is still working" if status[0] == "RUNNING" else ("succeeded" if status[0] == "SUCCESS" else "failed")), "bt status result return"))
		var vars := blackboard_vars()
		var names := vars.keys()
		names.sort()
		for name in names:
			for setter in [false, true]:
				var t := blackboard_template(String(name), String(vars[name]), setter, own)
				out.append(r._act(String(t.title) + (" (blackboard)" if own else " (blackboard of...)"), String(t.cat), "tpl", {"t": t}, String(t.tip), String(t.search)))
	if has_flow():
		for info in flow_graphs():
			var t := flow_graph_template(info)
			out.append(r._act(String(t.title), String(t.cat), "tpl", {"t": t}, String(t.tip), String(t.search)))
	if has_parley():
		for path in dialogues():
			var t := dialogue_template(String(path))
			out.append(r._act(String(t.title), String(t.cat), "tpl", {"t": t}, String(t.tip), String(t.search)))
		for item in parley_items():
			if item.kind == "character":
				out.append(r._act("Character: " + String(item.name), "Parley|Characters", "const", {"expr": "\"%s\"" % String(item.id).c_escape(), "t": "String", "label": String(item.name)},
					"The id of the Parley character '%s'." % item.name, "parley character speaker " + String(item.id)))
			else:
				var t := parley_item_template(item)
				out.append(r._act(String(t.title), String(t.cat), "tpl", {"t": t}, String(t.tip), String(t.search)))
	return out


## The node that starts one particular dialogue file.
static func dialogue_template(path: String) -> Dictionary:
	var lines := []
	for l in PARLEY_RUN_LINES:
		lines.append(String(l).replace("{sequence}", "load(\"%s\")" % path.c_escape()))
	return {"title": "Run Dialogue: " + path.get_file().get_basename(), "cat": "Parley|Dialogues",
		"search": "parley dialogue conversation start " + path.get_file().get_basename(),
		"tip": "Starts %s with the project's dialogue balloon. Data is what its facts and actions can read." % path,
		"ins": [["data", "Data", "Dictionary", "{}"]], "outs": [["ctx", "Context", "Object"], ["balloon", "Balloon", "Node"]],
		"lines": lines, "exprs": {"ctx": "__ctx_{id}", "balloon": "__balloon_{id}"}}


## A node that asks one of the project's dialogue facts, or runs one of its dialogue actions, from a Blueprint.
static func parley_item_template(item: Dictionary) -> Dictionary:
	var script_path := String(item.path).c_escape()
	if item.kind == "fact":
		return {"title": "Dialogue Fact: " + String(item.name), "cat": "Parley|Facts", "pure": true,
			"search": "parley fact condition " + String(item.name), "tip": "What the dialogue fact '%s' says right now, the same answer a dialogue's condition gets. Context is optional." % item.name,
			"ins": [["ctx", "Context", "any", ""]], "outs": [["ret", String(item.name), "any"]],
			"exprs": {"ret": "__bp_parley_fact(\"%s\", {ctx})" % script_path}, "helper": PARLEY_FACT_HELPER}
	return {"title": "Run Dialogue Action: " + String(item.name), "cat": "Parley|Actions",
		"search": "parley action run " + String(item.name), "tip": "Runs the dialogue action '%s' as a dialogue would. Context is optional." % item.name,
		"ins": [["ctx", "Context", "any", ""], ["values", "Values", "Array", "[]"]], "outs": [],
		"lines": ["__bp_parley_action(\"%s\", {ctx}, {values})" % script_path], "helper": PARLEY_ACTION_HELPER}


# ---------------------------------------------------------------- starters

const LIMBO_ACTION := """@tool
extends BTAction
## A behavior-tree action. Moves the agent toward the position stored in a blackboard variable and succeeds
## when it is close enough. Use it in a tree like any other task.

## Blackboard variable that holds the position to reach (a Vector3).
@export var target_var: StringName = &"target_position"
@export var speed: float = 4.0
## How close counts as arrived.
@export var tolerance: float = 0.5

func _generate_name() -> String:
	return "Move To  %s" % target_var

func _tick(delta: float) -> Status:
	var body: Node3D = agent as Node3D
	if body == null or not blackboard.has_var(target_var):
		return FAILURE
	var target: Vector3 = blackboard.get_var(target_var, Vector3.ZERO, false)
	if body.global_position.distance_to(target) <= tolerance:
		return SUCCESS
	body.global_position = body.global_position.move_toward(target, speed * delta)
	return RUNNING
"""

const LIMBO_CONDITION := """@tool
extends BTCondition
## A behavior-tree condition. Succeeds while the agent is within range of the position stored in a
## blackboard variable.

## Blackboard variable that holds the position to compare with (a Vector3).
@export var target_var: StringName = &"target_position"
@export var max_distance: float = 5.0

func _generate_name() -> String:
	return "In Range Of  %s" % target_var

func _tick(_delta: float) -> Status:
	var body: Node3D = agent as Node3D
	if body == null or not blackboard.has_var(target_var):
		return FAILURE
	var target: Vector3 = blackboard.get_var(target_var, Vector3.ZERO, false)
	if body.global_position.distance_to(target) <= max_distance:
		return SUCCESS
	return FAILURE
"""

const LIMBO_STATE := """extends LimboState
## A state of a LimboHSM state machine. Counts how long it has been active and, after a while, sends an
## event so the machine can move on (add a transition for that event on the LimboHSM).

## Event dispatched when the time is up.
@export var done_event: StringName = &"finished"
@export var duration: float = 2.0
var elapsed: float = 0.0

func _enter() -> void:
	elapsed = 0.0

func _update(delta: float) -> void:
	elapsed += delta
	if elapsed >= duration:
		dispatch(done_event)

func _exit() -> void:
	elapsed = 0.0
"""


const PARLEY_ACTION := """extends ParleyActionInterface
## A dialogue action: something a Parley dialogue does to the game. This one tells the player node which
## values the dialogue passed, and notes it in the dialogue's data. Add it to an Action node of a dialogue.

func run(ctx: ParleyContext, values: Array) -> int:
	var target: Node = (Engine.get_main_loop() as SceneTree).get_first_node_in_group(&"player")
	if target != null and target.has_method(&"on_dialogue_action"):
		target.call(&"on_dialogue_action", values)
	ctx.p_data["last_action"] = values
	return OK
"""

const PARLEY_FACT := """extends ParleyFactInterface
## A dialogue fact: something a Parley dialogue can ask about the game, in a Condition or Match node.
## This one answers from the dialogue's own data: whether "door_open" was set to true.

func evaluate(ctx: ParleyContext, _values: Array) -> Variant:
	return bool(ctx.p_data.get("door_open", false))

func available_values() -> Array:
	return [true, false]
"""


static func starters() -> Array:
	var out := []
	if has_parley():
		out.append({"id": "parley_action", "name": "Dialogue Action (Parley)", "file": "DialogueAction", "parent": "ParleyActionInterface", "kit": true,
			"desc": "Something a Parley dialogue does to the game: an Action node of a dialogue runs it. It is added to the project's action store."})
		out.append({"id": "parley_fact", "name": "Dialogue Fact (Parley)", "file": "DialogueFact", "parent": "ParleyFactInterface", "kit": true,
			"desc": "Something a Parley dialogue can ask about the game, in a Condition or Match node. It is added to the project's fact store."})
	if has_limbo():
		out.append({"id": "limbo_action", "name": "Behavior Tree Action (LimboAI)", "file": "MoveTo", "parent": "BTAction", "kit": true,
			"desc": "A task for LimboAI behavior trees: moves the agent toward a blackboard position. Save it where your tree tasks live and it appears in the tree editor."})
		out.append({"id": "limbo_condition", "name": "Behavior Tree Condition (LimboAI)", "file": "InRange", "parent": "BTCondition", "kit": true,
			"desc": "A condition for LimboAI behavior trees: succeeds while the agent is near a blackboard position."})
		out.append({"id": "limbo_state", "name": "State (LimboAI state machine)", "file": "TimedState", "parent": "LimboState", "kit": true,
			"desc": "A LimboHSM state: runs for a while, then dispatches an event so the machine can change state."})
	if has_flow():
		out.append({"id": "flow_node", "name": "Flow Node (FlowNodes)", "file": "lift_points", "parent": "FlowNodeBase", "kit": true, "plain_name": true,
			"desc": "A node for FlowNodes graphs, written as a Blueprint: moves every point of its input by an offset. Its file name is the node's id in graphs."})
	return out


## The starter's blueprint; {} for an id that is not a kit starter.
static func build_starter(id: String, cls_name: String) -> Dictionary:
	var source := ""
	match id:
		"limbo_action": source = LIMBO_ACTION
		"limbo_condition": source = LIMBO_CONDITION
		"limbo_state": source = LIMBO_STATE
		"parley_action": source = PARLEY_ACTION
		"parley_fact": source = PARLEY_FACT
		"flow_node": return _flow_node_starter(cls_name)
		_: return {}
	var importer: Script = load(IMPORTER_PATH)
	var made: Dictionary = importer.new().convert(source, {"class_name": cls_name} if cls_name != "" else {})
	return made.bp


static func _flow_node_starter(cls_name: String) -> Dictionary:
	var model: Script = load(MODEL_PATH)
	var bp: Dictionary = model.new_blueprint("FlowNodeBase", cls_name)
	bp.tool = true
	bp.description = "A flow node written as a Blueprint: moves every point of its input by Offset."
	bp.variables.append({"name": "offset", "type": "Vector3", "default": "Vector3(0, 1, 0)", "export": false, "category": "", "tooltip": "How far every point is moved."})
	var eg: Dictionary = bp.graphs[0]
	eg.nodes.clear()
	eg.next_id = 1
	model.add_node(eg, "comment", Vector2(40, 40), {"w": 900, "h": 150,
		"text": "FlowNodes finds this node by its file name, in addons/flow_nodes_editor/nodes or in a folder listed in Project Settings > Blueprints > Kits > Flow Node Folders (Project > Tools > Blueprints: Set Up FlowNodes Bridge adds this file's folder)."})
	# _init: what the node looks like in the flow graph editor
	var init: Dictionary = model.new_graph(bp, "_init", "function")
	init.nodes.remove_at(1)
	var define: Dictionary = model.add_node(init, "tpl", Vector2(360, 80), {"id": "flow_define"})
	define.d = {"title": "\"Lift Points\"", "category": "\"Blueprints\"", "tip": "\"Moves every point by this node's offset (a Blueprint flow node).\""}
	init.wires.append([int(init.nodes[0].id), "then", int(define.id), "exec"])
	# execute(ctx): input 0 -> moved copy -> output 0
	var run: Dictionary = model.new_graph(bp, "execute", "function")
	run.inputs = [["ctx", "any"]]
	run.nodes.remove_at(1)
	run.locals = [{"name": "moved", "type": "PackedVector3Array", "default": ""}]
	var entry: Dictionary = run.nodes[0]
	var input: Dictionary = model.add_node(run, "tpl", Vector2(340, 80), {"id": "flow_input"})
	var valid: Dictionary = model.add_node(run, "math", Vector2(640, 260), {"op": "!=", "n": 2})
	valid.d = {"a1": "null"}
	var branch: Dictionary = model.add_node(run, "branch", Vector2(860, 80), {})
	var copy: Dictionary = model.add_node(run, "tpl", Vector2(1120, 80), {"id": "flow_copy"})
	var positions: Dictionary = model.add_node(run, "tpl", Vector2(1400, 260), {"id": "flow_positions"})
	var store: Dictionary = model.add_node(run, "local_set", Vector2(1700, 80), {"name": "moved"})
	var count: Dictionary = model.add_node(run, "tpl", Vector2(1700, 300), {"id": "flow_count"})
	var last: Dictionary = model.add_node(run, "math", Vector2(1960, 300), {"op": "-", "n": 2})
	last.d = {"a1": "1"}
	var loop: Dictionary = model.add_node(run, "for", Vector2(2200, 80), {})
	var moved_a: Dictionary = model.add_node(run, "local_get", Vector2(2460, 320), {"name": "moved"})
	var at: Dictionary = model.add_node(run, "index", Vector2(2700, 320), {})
	var off: Dictionary = model.add_node(run, "var_get", Vector2(2700, 460), {"name": "offset"})
	var add: Dictionary = model.add_node(run, "math", Vector2(2940, 360), {"op": "+", "n": 2})
	var put: Dictionary = model.add_node(run, "set_index", Vector2(3180, 140), {})
	var moved_b: Dictionary = model.add_node(run, "local_get", Vector2(2460, 620), {"name": "moved"})
	var write: Dictionary = model.add_node(run, "tpl", Vector2(2500, 760), {"id": "flow_set_values"})
	write.d = {"name": "\"position\""}
	var output: Dictionary = model.add_node(run, "tpl", Vector2(2860, 760), {"id": "flow_output"})
	for w in [[entry, "then", input, "exec"], [entry, "p_ctx", input, "ctx"], [input, "then", branch, "exec"], [input, "ret", valid, "a0"],
			[valid, "ret", branch, "cond"], [branch, "true", copy, "exec"], [input, "ret", copy, "data"], [copy, "then", store, "exec"],
			[copy, "ret", positions, "data"], [positions, "ret", store, "value"], [store, "then", loop, "exec"], [copy, "ret", count, "data"],
			[count, "ret", last, "a0"], [last, "ret", loop, "last"], [loop, "body", put, "exec"], [moved_a, "value", put, "c"], [loop, "index", put, "k"],
			[moved_a, "value", at, "c"], [loop, "index", at, "k"], [at, "ret", add, "a0"], [off, "value", add, "a1"], [add, "ret", put, "v"],
			[loop, "completed", write, "exec"], [copy, "ret", write, "data"], [moved_b, "value", write, "values"], [write, "then", output, "exec"],
			[copy, "ret", output, "data"]]:
		run.wires.append([int(w[0].id), String(w[1]), int(w[2].id), String(w[3])])
	return bp


# ---------------------------------------------------------------- Parley stores

## Adds a dialogue action or fact written as a Blueprint to the project's Parley store, so dialogue nodes can
## pick it. `kind` is "action" or "fact". Returns a line for a message ("" when nothing was done).
static func parley_register(script_path: String, kind: String) -> String:
	if not has_parley() or not kind in ["action", "fact"]:
		return ""
	var store_path := String(ProjectSettings.get_setting("parley/stores/%s_store_path" % kind, ""))
	if store_path == "" or not ResourceLoader.exists(store_path):
		return "no Parley %s store is set in Project Settings, so add it to a store by hand" % kind
	var store := ResourceLoader.load(store_path)
	var list: Variant = store.get(kind + "s") if store != null else null
	if not (list is Array):
		return ""
	var script := ResourceLoader.load(script_path)
	for item in list:
		if item != null and item.get("ref") == script:
			return ""
	var entry: Variant = store.call("add_" + kind, script_path.get_file().get_basename().trim_prefix("BP_").capitalize())
	if entry == null:
		return ""
	entry.set("ref", script)
	# the project refers to its stores by uid: saving must not lose it
	var real_path := String(store.resource_path)
	var uid := ResourceLoader.get_resource_uid(real_path)
	ResourceSaver.save(store, real_path)
	if uid != ResourceUID.INVALID_ID and not FileAccess.get_file_as_string(real_path).get_slice("
", 0).contains(ResourceUID.id_to_text(uid)):
		ResourceSaver.set_uid(real_path, uid)
	invalidate()
	return "added to the Parley %s store as '%s'" % [kind, entry.get("name")]


# ---------------------------------------------------------------- FlowNodes bridge (written into the project)

const FLOW_CALL_NODE := """@tool
extends FlowNodeBase
## Hands this graph's data to a function of a Blueprint (or any script) and passes on what it returns.
## Written by the Blueprints plugin (Project > Tools > Blueprints: Set Up FlowNodes Bridge).

const CallSettings := preload("%s/blueprint_call_settings.gd")

func _init():
	meta_node = {
		"title" : "Call Blueprint",
		"settings" : CallSettings,
		"ins" : [{ "label" : "In" }],
		"outs" : [{ "label" : "Out" }],
		"tooltip" : "Calls a function on scene nodes with this node's input data.\\nIf the function returns flow data, that becomes the output; otherwise the input passes through.",
		"aliases" : ["Call Blueprint", "Call Function", "Call Method"],
		"category" : "Blueprints",
	}

func getTitle() -> String:
	return "Call Blueprint (%%s)" %% settings.function_name if settings and settings.function_name != "" else "Call Blueprint"

func _targets(ctx : FlowData.EvaluationContext, in_data : FlowData.Data) -> Array:
	var host : Node = ctx.owner
	match settings.target_mode:
		CallSettings.eTargetMode.Host:
			return [host] if host else []
		CallSettings.eTargetMode.HostParent:
			return [host.get_parent()] if host and host.get_parent() else []
		CallSettings.eTargetMode.Group:
			var tree : SceneTree = host.get_tree() if host and host.is_inside_tree() else null
			return tree.get_nodes_in_group(settings.group_name) if tree else []
		CallSettings.eTargetMode.NodePath:
			var found : Node = host.get_node_or_null(settings.target_node_path) if host else null
			return [found] if found else []
		CallSettings.eTargetMode.FromNodeStream:
			var out : Array = []
			var stream = in_data.findStream(settings.target_stream_attribute) if in_data else null
			if stream:
				for value in stream.container:
					if value is Node and not out.has(value):
						out.append(value)
			return out
	return []

func execute(ctx : FlowData.EvaluationContext):
	var in_data : FlowData.Data = get_optional_input(0)
	if in_data == null:
		in_data = FlowData.Data.new()
	var method : StringName = StringName(settings.function_name.strip_edges())
	if method == &"":
		setError("Function name is empty")
		return
	var targets := _targets(ctx, in_data)
	if targets.is_empty():
		# nothing to call while editing a graph with no scene behind it: pass the data on
		set_output(0, in_data)
		return
	var out_data : FlowData.Data = in_data
	var called := 0
	for target in targets:
		if target == null or not target.has_method(method):
			continue
		called += 1
		var result = target.call(method, out_data) if target.get_method_argument_count(method) > 0 else target.call(method)
		if result is FlowData.Data:
			out_data = result
	if called == 0:
		setError("No target has a function named '%%s'" %% method)
		return
	set_output(0, out_data)
"""

const FLOW_CALL_SETTINGS := """@tool
extends NodeSettings
## Options of the Call Blueprint flow node (written by the Blueprints plugin).

@export_group("Call Blueprint")

enum eTargetMode {
	## The Flow Graph Node that runs this graph.
	Host,
	## The parent of that node: usually the actor whose Blueprint owns the graph.
	HostParent,
	## Every node in a group.
	Group,
	## A node found by path from the Flow Graph Node.
	NodePath,
	## Nodes held in an attribute of the input data.
	FromNodeStream,
}

## Which nodes the function is called on.
@export var target_mode : eTargetMode = eTargetMode.HostParent:
	set(value):
		target_mode = clampi(value, 0, eTargetMode.size() - 1)
		notify_property_list_changed()
## The function to call. It may take the flow data as its one input, and may return flow data.
@export var function_name : String = "on_flow_data"
@export var group_name : String = ""
@export_node_path("Node") var target_node_path : NodePath
@export var target_stream_attribute : String = "node"

func _init():
	super._init()
	resource_name = "Call Blueprint Settings"

func exposeParam(name : String) -> bool:
	if name == "group_name":
		return target_mode == eTargetMode.Group
	if name == "target_node_path":
		return target_mode == eTargetMode.NodePath
	if name == "target_stream_attribute":
		return target_mode == eTargetMode.FromNodeStream
	return true
"""

const FLOW_BRIDGE := """extends Node
## Tells FlowNodes where flow nodes written as Blueprints (and the Call Blueprint node) are kept.
## Written by the Blueprints plugin; the folders are listed in Project Settings > Blueprints > Kits.

func _enter_tree() -> void:
	for folder in ProjectSettings.get_setting("%s", PackedStringArray(["%s"])):
		FlowNodeRegistry.register_node_directory(String(folder))
"""


static func flow_folders() -> PackedStringArray:
	return PackedStringArray(ProjectSettings.get_setting(FLOW_FOLDERS_SETTING, PackedStringArray()))


## Makes every listed folder known to FlowNodes in this process (the editor; games use the autoload).
static func flow_register_folders() -> void:
	if not has_flow():
		return
	var registry: Script = null
	for c in ProjectSettings.get_global_class_list():
		if String(c.get("class", "")) == "FlowNodeRegistry":
			registry = load(String(c.path))
	if registry == null:
		return
	for folder in flow_folders():
		registry.register_node_directory(String(folder))


## Writes the bridge into the project: the Call Blueprint flow node, and an autoload that tells FlowNodes
## which folders hold flow nodes. `extra_folder` (a folder with Blueprint flow nodes) is added to the list.
## Returns what it did, for a message; [] when everything was already in place.
static func flow_setup(extra_folder := "") -> PackedStringArray:
	var did := PackedStringArray()
	if not has_flow():
		return did
	DirAccess.make_dir_recursive_absolute(FLOW_DIR)
	var files := {
		FLOW_DIR + "/blueprint_call.gd": FLOW_CALL_NODE % FLOW_DIR,
		FLOW_DIR + "/blueprint_call_settings.gd": FLOW_CALL_SETTINGS,
		FLOW_AUTOLOAD_PATH: FLOW_BRIDGE % [FLOW_FOLDERS_SETTING, FLOW_DIR],
	}
	for path in files:
		if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == String(files[path]):
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string(String(files[path]))
		f.close()
		did.append("wrote " + String(path))
	var folders := flow_folders()
	for folder in [FLOW_DIR, extra_folder.trim_suffix("/")]:
		if folder != "" and folder != "res://addons/flow_nodes_editor/nodes" and not folders.has(folder):
			folders.append(folder)
			did.append("listed " + folder)
	var changed := not did.is_empty()
	ProjectSettings.set_setting(FLOW_FOLDERS_SETTING, folders)
	ProjectSettings.set_initial_value(FLOW_FOLDERS_SETTING, PackedStringArray())
	if not ProjectSettings.has_setting("autoload/" + FLOW_AUTOLOAD):
		ProjectSettings.set_setting("autoload/" + FLOW_AUTOLOAD, "*" + FLOW_AUTOLOAD_PATH)
		did.append("added the %s autoload" % FLOW_AUTOLOAD)
		changed = true
	if changed:
		ProjectSettings.save()
	flow_register_folders()
	return did
