extends SceneTree
## Blueprint Interfaces: the interface asset, a blueprint that implements one, Message nodes and
## Does Implement Interface. Run: godot --headless --path . --script res://tests/test_interfaces.gd
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const Compiler := preload("res://addons/blueprints/core/bp_compiler.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const Starters := preload("res://addons/blueprints/core/bp_starters.gd")

const DIR := "res://tests/tmp/iface/"
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func build(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	return [code, c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))]


func write(file: String, bp: Dictionary) -> String:
	var out := build(bp)
	var f := FileAccess.open(DIR + file, FileAccess.WRITE)
	f.store_string(Model.build_source(out[0], bp))
	f.close()
	R.invalidate_libraries()
	return out[0]


## The script, with its class name taken off and the interface named by file (nothing registers global
## classes in a headless run).
func script_from(code: String) -> GDScript:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			lines[i] = "#"
	var scr := GDScript.new()
	scr.source_code = "\n".join(lines).replace("BPI_Test.", "preload(\"%sBPI_Test.gd\")." % DIR)
	return scr if scr.reload() == OK else null


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()

	# ================================================================ the interface
	var iface := Model.new_blueprint("RefCounted", "BPI_Test")
	iface["library"] = "interface"
	var i_interact := Model.new_graph(iface, "interact", "function")
	i_interact.inputs = [["instigator", "Node"]]
	var i_prompt := Model.new_graph(iface, "get_prompt", "function")
	i_prompt.outputs = [["prompt", "String"]]
	var i_stats := Model.new_graph(iface, "stats", "function")
	i_stats.outputs = [["count", "int"], ["weight", "float"]]
	var iface_code := write("BPI_Test.gd", iface)
	print(iface_code)
	check("interface compiles", build(iface)[1].is_empty(), str(build(iface)[1]))
	check("it lists its functions", iface_code.contains("const FUNCTIONS: Array[StringName] = [&\"interact\", &\"get_prompt\", &\"stats\"]"))
	check("it has no function bodies of its own", not iface_code.contains("func interact"))
	var iface_scr := script_from(iface_code)
	check("interface script loads", iface_scr != null)
	check("the registry finds it", R.interfaces().has("BPI_Test") and R.interface_functions("BPI_Test").size() == 3, str(R.interfaces()))
	var nameless := Model.new_blueprint("RefCounted", "")
	nameless["library"] = "interface"
	check("an interface without a class name is an error", not build(nameless)[1].is_empty())

	# ================================================================ a blueprint that implements it
	var door := Model.new_blueprint("Node", "BP_TDoor")
	door["interfaces"] = ["BPI_Test"]
	var d_prompt := Model.new_graph(door, "get_prompt", "function")
	d_prompt.outputs = [["prompt", "String"]]
	d_prompt.nodes[1].d["r_prompt"] = "\"Open\""
	wire(d_prompt, d_prompt.nodes[0], "then", d_prompt.nodes[1], "exec")
	var door_out := build(door)
	var door_code: String = door_out[0]
	print(door_code)
	check("implementer compiles", door_out[1].is_empty(), str(door_out[1]))
	check("a function it did not fill in is written empty", door_code.contains("func interact(_instigator: Node) -> void:\n\tpass"))
	check("an empty one with outputs returns defaults", door_code.contains("func stats() -> Array:\n\treturn [0, 0.0]"))
	check("its own get_prompt is kept", door_code.count("func get_prompt(") == 1 and door_code.contains("return \"Open\""))
	var door_scr := script_from(door_code)
	check("implementer script loads", door_scr != null)

	var wrong := Model.new_blueprint("Node", "BP_TWrong")
	wrong["interfaces"] = ["BPI_Test"]
	var w_prompt := Model.new_graph(wrong, "get_prompt", "function")
	w_prompt.outputs = [["prompt", "int"]]
	var wrong_errs: Array = build(wrong)[1]
	check("a function with other outputs than the interface is an error", wrong_errs.size() == 1 and String(wrong_errs[0]).contains("() -> (String)"), str(wrong_errs))
	var missing := Model.new_blueprint("Node", "BP_TMissing")
	missing["interfaces"] = ["BPI_Nowhere"]
	check("implementing an interface that does not exist is an error", build(missing)[1].size() == 1)
	var by_event := Model.new_blueprint("Node", "BP_TByEvent")
	by_event["interfaces"] = ["BPI_Test"]
	Model.add_node(by_event.graphs[0], "custom_event", Vector2(100, 100), {"name": "interact", "params": [["instigator", "Node"]]})
	var ev_out := build(by_event)
	check("a custom event can stand in for an interface function", ev_out[1].is_empty() and String(ev_out[0]).count("func interact(") == 1, str(ev_out[1]))

	# ================================================================ calling through the interface
	var user := Model.new_blueprint("Node", "BP_TUser")
	var ask := Model.new_graph(user, "ask", "function")
	ask.inputs = [["target", "Object"]]
	ask.outputs = [["text", "String"], ["yes", "bool"], ["weight", "float"]]
	var m_interact := Model.add_node(ask, "iface_call", Vector2(300, 120), {"iface": "BPI_Test", "fn": "interact"})
	var m_prompt := Model.add_node(ask, "iface_call", Vector2(520, 120), {"iface": "BPI_Test", "fn": "get_prompt"})
	var m_stats := Model.add_node(ask, "iface_call", Vector2(740, 120), {"iface": "BPI_Test", "fn": "stats"})
	var has := Model.add_node(ask, "iface_has", Vector2(520, 320), {"iface": "BPI_Test"})
	var a_in: Dictionary = ask.nodes[0]
	var a_out: Dictionary = ask.nodes[1]
	wire(ask, a_in, "then", m_interact, "exec")
	wire(ask, m_interact, "then", m_prompt, "exec")
	wire(ask, m_prompt, "then", m_stats, "exec")
	wire(ask, m_stats, "then", a_out, "exec")
	for m in [m_interact, m_prompt, m_stats, has]:
		wire(ask, a_in, "p_target", m, "target")
	wire(ask, m_prompt, "r_prompt", a_out, "r_text")
	wire(ask, has, "ret", a_out, "r_yes")
	wire(ask, m_stats, "r_weight", a_out, "r_weight")
	var d_call := R.describe(m_prompt, user, ask)
	check("a Message node has the interface function's pins", d_call.err == "" and d_call.outs.any(func(o): return o.id == "r_prompt" and o.type == "String") and d_call.ins.any(func(i): return i.id == "target"), str(d_call))
	var user_out := build(user)
	var user_code: String = user_out[0]
	print(user_code)
	check("caller compiles", user_out[1].is_empty(), str(user_out[1]))
	check("a message is a guarded call", user_code.contains("if is_instance_valid(target) and target.has_method(&\"interact\"):\n\t\ttarget.interact(null)"))
	var user_scr := script_from(user_code)
	check("caller script loads", user_scr != null)
	if user_scr != null and door_scr != null:
		var u: Node = user_scr.new()
		var d: Node = door_scr.new()
		var plain := Node.new()
		check("message to an implementer returns its values", u.ask(d) == ["Open", true, 0.0], str(u.ask(d)))
		check("message to an object without the functions does nothing", u.ask(plain) == ["", false, 0.0], str(u.ask(plain)))
		check("message to null does nothing", u.ask(null) == ["", false, 0.0], str(u.ask(null)))
		var hand := GDScript.new()
		hand.source_code = "extends RefCounted\nvar hit := 0\nfunc interact(_who: Node) -> void:\n\thit += 1\nfunc get_prompt() -> String:\n\treturn \"Hand\"\nfunc stats() -> Array:\n\treturn [3, 2.5]\n"
		hand.reload()
		var h: RefCounted = hand.new()
		check("a hand-written script with the functions counts as implementing", u.ask(h) == ["Hand", true, 2.5] and h.hit == 1, "%s hit=%d" % [u.ask(h), h.hit])
		u.free()
		d.free()
		plain.free()

	# ================================================================ starter and action menu
	var starter := Starters.build("interface", "BP_Interactable")
	check("the Blueprint Interface starter compiles", build(starter)[1].is_empty() and String(starter.get("library", "")) == "interface", str(build(starter)[1]))
	var labels := []
	for act in R.blueprint_actions(user, ask):
		labels.append(String(act.l))
	check("the action menu offers the messages", labels.has("Get Prompt (Message)") and labels.has("Does Implement Interface: BPI_Test"))

	print("INTERFACE FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
