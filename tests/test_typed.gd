extends SceneTree
## The places where generated code used to leave a type out, and what they cost, are in the 0.4.0 type audit.
## This checks that the type is written where the graph knows it, left out where it does not, and that the
## code still does what it did.
## Run: godot --headless --path . --script res://tests/test_typed.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func wire(g: Dictionary, a: Dictionary, a_pin: String, b: Dictionary, b_pin: String) -> void:
	g.wires.append([a.id, a_pin, b.id, b_pin])


## Compiles, checks that the Schematic survives a save, loads the script. Returns [code, instance or null].
func build(bp: Dictionary, label: String) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	var problems := PackedStringArray()
	for e in c.errors:
		problems.append(String(e.m))
	check(label + ": compiles without errors or warnings", problems.is_empty(), ", ".join(problems))
	var gs := GDScript.new()
	gs.source_code = Model.build_source(code, bp)
	var err := gs.reload()
	check(label + ": the generated script loads", err == OK, "error %d\n%s" % [err, code])
	return [code, gs.new() if err == OK else null]


## The line of `code` that declares `name` (a member or a local), without its indent.
func declaration(code: String, name: String) -> String:
	for line in code.split("\n"):
		var text := line.strip_edges()
		if text.begins_with("var " + name + " ") or text.begins_with("var " + name + ":") or text == "var " + name:
			return text
	return ""


## A custom event that walks `variable` backwards and appends every element to `log`. Returns the loop node.
func reverse_loop(g: Dictionary, event: String, variable: String, element_type: String) -> Dictionary:
	var ev := Model.add_node(g, "custom_event", Vector2(), {"name": event, "params": []})
	var source := Model.add_node(g, "var_get", Vector2(), {"name": variable})
	var p := {"rev": true}
	if element_type != "":
		p["t"] = element_type
	var loop := Model.add_node(g, "for_each", Vector2(), p)
	wire(g, ev, "then", loop, "exec")
	wire(g, source, "value", loop, "array")
	var log_get := Model.add_node(g, "var_get", Vector2(), {"name": "log"})
	var add := Model.add_node(g, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g, loop, "body", add, "exec")
	wire(g, log_get, "value", add, "target")
	wire(g, loop, "element", add, "a0")
	return loop


func _init() -> void:
	# ---------------------------------------------------------------- 1. Reverse For Each Loop
	var bp := Model.new_schematic("Node", "")
	bp.variables.append({"name": "values", "type": "Array[float]", "default": "[1.0, 2.0, 4.0]", "export": false})
	bp.variables.append({"name": "packed", "type": "PackedFloat32Array", "default": "PackedFloat32Array([1.0, 2.0, 4.0])", "export": false})
	bp.variables.append({"name": "loose", "type": "Array", "default": "[1.0, \"two\", 4.0]", "export": false})
	bp.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g: Dictionary = bp.graphs[0]
	g.nodes.clear()
	var typed := reverse_loop(g, "run_typed", "values", "float")
	var from_packed := reverse_loop(g, "run_packed", "packed", "float")
	var untyped := reverse_loop(g, "run_loose", "loose", "")
	var made := build(bp, "reverse loop")
	var code: String = made[0]
	check("reverse loop: the copy of a typed array is an Array", declaration(code, "arr_%d" % typed.id) == "var arr_%d: Array = values" % typed.id, declaration(code, "arr_%d" % typed.id))
	check("reverse loop: its element has the node's type", declaration(code, "item_%d" % typed.id) == "var item_%d: float = arr_%d[idx_%d]" % [typed.id, typed.id, typed.id], declaration(code, "item_%d" % typed.id))
	check("reverse loop: the copy of a packed array has no type (an Array would be a second copy)",
		declaration(code, "arr_%d" % from_packed.id) == "var arr_%d = packed" % from_packed.id, declaration(code, "arr_%d" % from_packed.id))
	check("reverse loop: the packed array's element is still typed", declaration(code, "item_%d" % from_packed.id).begins_with("var item_%d: float = " % from_packed.id))
	check("reverse loop: an element of unknown type is left untyped", declaration(code, "item_%d" % untyped.id) == "var item_%d = arr_%d[idx_%d]" % [untyped.id, untyped.id, untyped.id], declaration(code, "item_%d" % untyped.id))
	var o: Object = made[1]
	if o:
		o.run_typed()
		check("reverse loop: a typed array is walked backwards", str(o.log) == "[4.0, 2.0, 1.0]", str(o.log))
		o.log.clear()
		o.run_packed()
		check("reverse loop: a packed array is walked backwards", str(o.log) == "[4.0, 2.0, 1.0]", str(o.log))
		o.log.clear()
		o.run_loose()
		check("reverse loop: an array of mixed values is walked backwards", str(o.log) == "[4.0, \"two\", 1.0]", str(o.log))
		o.values.append(8.0)
		o.log.clear()
		o.run_typed()
		check("reverse loop: it reads the array as it is now", str(o.log) == "[8.0, 4.0, 2.0, 1.0]", str(o.log))
		o.free()

	# ---------------------------------------------------------------- 2. An event output read by another event
	var b2 := Model.new_schematic("Node", "")
	b2.variables.append({"name": "seen", "type": "float", "default": "", "export": false})
	b2.variables.append({"name": "who_seen", "type": "Node", "default": "", "export": false})
	b2.variables.append({"name": "label_seen", "type": "String", "default": "", "export": false})
	var g2: Dictionary = b2.graphs[0]
	g2.nodes.clear()
	var feed := Model.add_node(g2, "custom_event", Vector2(), {"name": "feed", "params": [["amount", "float"], ["who", "Node"], ["label", "String"]]})
	var use := Model.add_node(g2, "custom_event", Vector2(), {"name": "use", "params": []})
	var set_seen := Model.add_node(g2, "var_set", Vector2(), {"name": "seen"})
	var set_who := Model.add_node(g2, "var_set", Vector2(), {"name": "who_seen"})
	var set_label := Model.add_node(g2, "var_set", Vector2(), {"name": "label_seen"})
	wire(g2, use, "then", set_seen, "exec")
	wire(g2, set_seen, "then", set_who, "exec")
	wire(g2, set_who, "then", set_label, "exec")
	wire(g2, feed, "p_amount", set_seen, "value")
	wire(g2, feed, "p_who", set_who, "value")
	wire(g2, feed, "p_label", set_label, "value")
	var made2 := build(b2, "shared event output")
	var code2: String = made2[0]
	var gid := int(g2.id)
	var amount := "__p%d_amount_g%d" % [feed.id, gid]
	var who := "__p%d_who_g%d" % [feed.id, gid]
	var label := "__p%d_label_g%d" % [feed.id, gid]
	check("shared event output: a number is kept in a typed member", declaration(code2, amount) == "var %s: float = 0.0" % amount, declaration(code2, amount))
	check("shared event output: text is kept in a typed member", declaration(code2, label) == "var %s: String = \"\"" % label, declaration(code2, label))
	check("shared event output: a node is kept in a typed member with nothing in it", declaration(code2, who) == "var %s: Node" % who, declaration(code2, who))
	var o2: Object = made2[1]
	if o2:
		var someone := Node.new()
		o2.use()
		check("shared event output: before the first event runs, the other one reads the empty values", o2.seen == 0.0 and o2.who_seen == null and o2.label_seen == "")
		o2.feed(2.5, someone, "hello")
		o2.use()
		check("shared event output: the other event reads what the first one was given", o2.seen == 2.5 and o2.who_seen == someone and o2.label_seen == "hello",
			"%s %s %s" % [o2.seen, o2.who_seen, o2.label_seen])
		o2.feed(7, null, "")
		o2.use()
		check("shared event output: a whole number and an empty node pass through", o2.seen == 7.0 and o2.who_seen == null, "%s %s" % [o2.seen, o2.who_seen])
		someone.free()
		o2.free()

	# ---------------------------------------------------------------- 3. Call Function If Present (Message)
	var b3 := Model.new_schematic("Node", "")
	b3.variables.append({"name": "log", "type": "Array", "default": "", "export": false})
	var g3: Dictionary = b3.graphs[0]
	g3.nodes.clear()
	var send := Model.add_node(g3, "custom_event", Vector2(), {"name": "send", "params": [["target", "any"], ["fn", "StringName"], ["arg", "any"]]})
	var msg := Model.add_node(g3, "tpl", Vector2(), {"id": "call_message"})
	wire(g3, send, "then", msg, "exec")
	wire(g3, send, "p_target", msg, "target")
	wire(g3, send, "p_fn", msg, "fn")
	wire(g3, send, "p_arg", msg, "arg")
	var log3 := Model.add_node(g3, "var_get", Vector2(), {"name": "log"})
	var add3 := Model.add_node(g3, "bcall", Vector2(), {"type": "Array", "method": "append"})
	wire(g3, msg, "then", add3, "exec")
	wire(g3, log3, "value", add3, "target")
	wire(g3, msg, "ret", add3, "a0")
	var made3 := build(b3, "message")
	var code3: String = made3[0]
	check("message: after the validity check the target is an Object", code3.contains("\tvar to: Object = target\n") and code3.contains("to.has_method(fn)") and not code3.contains("target.call("))
	check("message: the target itself stays untyped, so a freed one can be passed", code3.contains("func __sc_message(target: Variant, fn: StringName, arg: Variant) -> Variant:"))
	var o3: Object = made3[1]
	if o3:
		var other := Node.new()
		other.name = "Before"
		o3.send(other, &"get_name", null)
		check("message: a function that takes nothing is called without the argument", str(o3.log) == "[&\"Before\"]", str(o3.log))
		o3.log.clear()
		o3.send(other, &"set_name", "After")
		check("message: a function that takes one is given the argument", other.name == &"After" and o3.log == [null], "%s %s" % [other.name, str(o3.log)])
		o3.log.clear()
		o3.send(other, &"no_such_function", 1)
		o3.send(null, &"get_name", null)
		o3.send(5, &"get_name", null)
		o3.send("text", &"length", null)
		check("message: a missing function, nothing, and values that are not objects all give null", o3.log == [null, null, null, null], str(o3.log))
		o3.log.clear()
		other.free()
		o3.send(other, &"get_name", null)
		check("message: a freed target gives null", o3.log == [null], str(o3.log))
		o3.free()

	print("TYPED FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
