extends SceneTree
## GDScript -> Schematic importer, tested by difference: every sample script is run as written and again
## after conversion, and the two must end in the same state.
## Run: godot --headless --path . --script res://tests/test_import.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")

var fails := 0

const SAMPLES := {
"numbers and branches": ["Node", """extends Node

var total = 0
var speed = 2
var gravity = 0
var label := ""
var steps: Array = []
var best: float = -1.0

func _ready():
	gravity += 2.5 * speed
	for i in 5:
		total += i
	for i in range(2, 6):
		if i % 2 == 0:
			continue
		if i > 4:
			break
		steps.append(i)
	var n := 0
	while n < 3:
		n += 1
		total += n * 10
	if total > 100:
		label = "big"
	elif total > 50:
		label = "medium"
	else:
		label = "small"
	best = biggest(3.5, float(total)) if total > 0 else 0.0
	label += "!" + str(total)
	steps.append(clampi(total, 0, 7))

func biggest(a: float, b: float) -> float:
	if a > b:
		return a
	return b
"""],
"structs and properties": ["Node3D", """extends Node3D

var time = 0.0
var bounce := 1.5
var heading: Vector3
var tint := Color(1, 0, 0)

func _ready():
	position = Vector3(1, 2, 3)
	scale = Vector3(2, 2, 2)

func _process(delta):
	position.y += cos(time * 3) * bounce * delta
	position.x = -position.z
	rotation.y = lerp_angle(rotation.y, 1.0, delta * 4)
	scale = scale.lerp(Vector3(1, 1, 1), delta * 10)
	heading = Vector3(position.x, 0, position.z).normalized() * 2
	tint.g = minf(tint.g + delta, 1.0)
	rotate_x(0.01)
	time += delta
"""],
"functions calling functions": ["Node", """extends Node

var log: Array = []
var hp := 10
var alive = true
var name_tag: String = "hero"

func _ready():
	damage(3)
	damage(4)
	heal()
	damage(20)
	log.append(describe())

func damage(amount: int):
	if not alive:
		return
	hp -= amount
	log.append("hit %d" % amount)
	if hp <= 0:
		hp = 0
		die()

func heal():
	hp = mini(hp + 5, 10)
	log.append("heal")

func die():
	alive = false
	log.append("dead")

func describe() -> String:
	var state := "alive" if alive else "gone"
	return name_tag.to_upper() + ":" + state + ":" + str(hp)
"""],
"signals and callbacks": ["Node", """extends Node

signal scored(points)
signal finished

var score = 0
var events: Array = []

func _ready():
	scored.connect(_on_scored)
	finished.connect(_on_finished)
	scored.emit(5)
	scored.emit(7)
	var t := Timer.new()
	t.name = "Clock"
	add_child(t)
	t.timeout.connect(_on_tick.bind("tick"))
	t.timeout.emit()
	finished.emit()

func _on_scored(points):
	score += points
	events.append(points)

func _on_tick(word):
	events.append(word)

func _on_finished():
	events.append(get_child_count())
"""],
"child nodes": ["Node2D", """extends Node2D

var made = 0
var widths: Array = []

func _ready():
	for i in 3:
		var s := Sprite2D.new()
		s.name = "S%d" % i
		s.position = Vector2(i * 10, 0)
		s.visible = i != 1
		add_child(s)
		made += 1
	var first := get_child(0) as Sprite2D
	first.position.y = 42.0
	first.modulate.a = 0.5
	get_child(2).queue_free()
	for c in get_children():
		widths.append(c.position.x + c.position.y)
"""],
"things kept as code": ["Node", """extends Node

var kind := 2
var word := ""
var doubled: Array = []
var bag = {}
var anything

func _ready():
	match kind:
		1:
			word = "one"
		2:
			word = "two"
		_:
			word = "many"
	doubled = [1, 2, 3].map(func(x): return x * 2)
	bag["a"] = 1
	bag["b"] = bag["a"] + 1
	anything = Node.new()
	anything.name = "Loose"
	anything.set_meta("k", 5)
	word += str(anything.get_meta("k"))
	anything.free()
	anything = null
	if "a" in bag and word.length() > 2:
		word = word.capitalize()
	match bag:
		{"a": var first, ..}:
			word += str(first)
"""],
"forms that used to be code": ["Node", """extends Node

signal done(count)
var kind := 2
var word := ""
var bag = {}
var anything
var tw: Tween
var speed := Vector3.ZERO
var tint := Color.WHITE
var log: Array = []
var waited := 0

func _ready():
	match kind:
		1, 3:
			word = "odd"
		2:
			word = "two"
		_:
			word = "many"
	match kind:
		2 when waited > 100:
			word += "never"
		2 when kind == 2:
			word += " guarded"
	anything = Node.new()
	anything.name = "Loose"
	anything.set_meta("k", 5)
	if tw != null and tw.is_valid():
		tw.kill()
	if helper(7) > 100 and helper(8) > 0:
		word += "?"
	if helper(9) > 0 or helper(10) > 0:
		word += "+"
	speed.x *= 0.5
	speed.y = 2.0
	tint.a = 0.25
	var d := {"a": word, "b": helper(1) + helper(2), "c": [helper(3), kind]}
	log.append(d)
	var v = helper(4) if bag.has("x") else helper(5)
	log.append(v)
	if anything.has_method(&"set_meta"):
		anything.call(&"set_meta", "seen", true)
	if anything.has_method(&"no_such_thing"):
		anything.call(&"no_such_thing", 1)
	log.append(anything.get_meta("seen", false))
	if anything is Node and not (anything is Node3D):
		word += "!"
	var arr = bag.get("list", [4]) as Array
	log.append(arr)
	log.append(Vector3(1, helper(11), helper(12)))
	anything.free()
	anything = null
	done.connect(_on_done)
	helper.call_deferred(20)
	log.append.call_deferred("deferred")
	await get_tree().process_frame
	waited += 1
	await pause(2)
	var got = await answer()
	log.append(got)
	done.emit(log.size())
	while helper(0) < 0:
		break
	shrink(5)

func helper(n: int) -> int:
	log.append(n)
	return n

func pause(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
		waited += 1
		if i > 5:
			return
	log.append("paused")

func answer() -> int:
	await get_tree().process_frame
	return 42

func shrink(n: int) -> void:
	n -= 2
	log.append(n)
	var when := "FLOOR %d - %s" % [n, word]
	log.append(when)

func _on_done(count):
	log.append(["done", count])

func _process(_delta):
	if kind > 5:
		return
	kind += 0
"""],
"lambdas": ["Node", """extends Node

signal poked(n)
var log: Array = []
var items: Array = [3, 1, 2]
var word := "abc"

func _ready():
	var base := 10
	items.sort_custom(func(a, b): return a < b)
	var doubled = items.map(func(x): return x * 2 + base)
	log.append(doubled)
	poked.connect(func(n: int) -> void:
		log.append(n + base)
		if n > 1:
			log.append("big")
	)
	var later := func(tag: String) -> void:
		log.append(tag)
		log.append(base)
	base = 99
	later.call("x")
	for i in 2:
		poked.connect(func(n): log.append([i, n]), CONNECT_ONE_SHOT)
	poked.emit(2)
	poked.emit(1)
	for ch in word:
		log.append(ch)
	for k in range(4, 0, -2):
		log.append(k)
	var pick := func(n: int) -> int:
		var twice := n * 2
		return twice + 1
	log.append(pick.call(4))
	poked.connect(func(n: int) -> void:
		if n > 0:
			log.append(["last", n, base]),
		CONNECT_ONE_SHOT)
	poked.connect(func(n: int) -> void:
		match n:
			1, 2:
				log.append("small")
			_:
				log.append("other")
	)
	poked.connect(
		func(n: int) -> void:
			if n > 5:
				log.append("late"),
		CONNECT_ONE_SHOT
	)
	var held := note(base,
			"x", func() -> void:
		log.append("held")
		log.append(base))
	held.call()
	var place := func(at: int, kind: float = -1.0, tag := "none") -> void:
		log.append([at, kind, tag, base])
	place.call(1)
	place.call(2, 0.5)
	place.call(3, 0.25, "all")
	poked.emit(2)
	poked.emit(7)

func note(_a, _b, cb: Callable) -> Callable:
	return cb
"""],
"code as fast as written": ["Node3D", """extends Node3D

const STEP := 0.25
var samples: PackedFloat32Array = PackedFloat32Array([1.0, 2.5, 4.0])
var partner: Node3D
var total := 0.0
var label := ""
var hits = 0

func _ready():
	partner = Node3D.new()
	partner.name = "Partner"
	add_child(partner)
	total = tally(2)
	label = describe(total)
	position.y += STEP
	partner.position.x = total
	partner.scale.z -= 0.5
	if partner:
		hits += 1
	if not partner or total < 0:
		hits += 10

func tally(scale_by: int) -> float:
	var sum := 0.0
	for s in samples:
		sum += s * scale_by
	var bonus := extra(sum)
	return sum + bonus

func extra(value: float) -> float:
	return value * STEP

static func describe(value: float) -> String:
	var rounded := snappedf(value, 0.5)
	var text := name_for(rounded)
	return text

static func name_for(value: float) -> String:
	return "v%s" % value

func fill(count: int) -> int:
	var made := 0
	for i in range(count):
		made += i
	for j in range(2, count):
		made -= j
	return made

func flip(value: float) -> float:
	return -value * STEP

func tag(index: int) -> String:
	return "cell_%d" % index

func _enter_tree():
	var half := STEP * 0.5
	var names := [tag(3), tag(4)]
	total = half + flip(2.0) + fill(5)
	label = names[1]
"""],
}


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func load_source(code: String) -> GDScript:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			lines[i] = "#"
	var scr := GDScript.new()
	scr.source_code = "\n".join(lines)
	return scr if scr.reload() == OK else null


func snapshot(n: Node) -> Dictionary:
	var out := {}
	for p in (n.get_script() as Script).get_script_property_list():
		if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE and not String(p.name).begins_with("__"):
			out[String(p.name)] = _plain(n.get(p.name))
	if n is Node3D:
		out["#position"] = _plain(n.position)
		out["#rotation"] = _plain(n.rotation)
		out["#scale"] = _plain(n.scale)
	out["#children"] = n.get_children().map(func(c): return "%s %s" % [c.name, c.get_class()])
	for c in n.get_children():
		if c is Node2D:
			out["#" + c.name] = _plain([c.position, c.visible, c.modulate])
	return out


func _plain(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT: return snappedf(v, 0.0001)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR: return str(v.snapped(Vector2.ONE * 0.0001) if v is Vector2 else (v.snapped(Vector3.ONE * 0.0001) if v is Vector3 else v))
		TYPE_ARRAY: return v.map(func(x): return _plain(x))
		TYPE_OBJECT: return "<object>" if is_instance_valid(v) else "<null>"
	return v


## Runs both scripts through the same frames (so they see the same delta) and returns their two snapshots.
func run_pair(a: GDScript, b: GDScript, parent: String) -> Array:
	var nodes := []
	for scr in [a, b]:
		var n: Node = ClassDB.instantiate(parent)
		n.set_script(scr)
		nodes.append(n)
	for n in nodes:
		root.add_child(n)
	for i in 6:
		await process_frame
	var snaps := [snapshot(nodes[0]), snapshot(nodes[1])]
	for n in nodes:
		n.queue_free()
	await process_frame
	return snaps


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	var all_lines := 0
	var all_code := 0
	for name in SAMPLES:
		var parent: String = SAMPLES[name][0]
		var source: String = SAMPLES[name][1]
		var original := load_source(source)
		if original == null:
			check("%s: the sample itself loads" % name, false)
			continue
		var imp := Importer.new()
		var out := imp.convert(source, {})
		var bp: Dictionary = out.bp
		var rep: Dictionary = out.report
		var c := Compiler.new()
		var code := c.compile(bp)
		var errs := c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
		var converted := load_source(code) if errs.is_empty() else null
		check("%s: converts and compiles" % name, converted != null, "%d of %d lines as nodes  %s" % [rep.as_nodes, rep.lines, str(errs)])
		all_lines += int(rep.lines)
		all_code += int(rep.as_code)
		if converted == null:
			print(code)
			continue
		# the schematic survives a save and load
		var again := Model.parse_source(Model.build_source(code, bp))
		var c2 := Compiler.new()
		check("%s: same code after save and load" % name, c2.compile(again) == code)
		var snaps: Array = await run_pair(original, converted, parent)
		var want: Dictionary = snaps[0]
		var got: Dictionary = snaps[1]
		var diff := []
		for k in want:
			if str(want[k]) != str(got.get(k, "<missing>")):
				diff.append("%s: %s -> %s" % [k, str(want[k]), str(got.get(k, "<missing>"))])
		check("%s: behaves the same (%d values compared)" % [name, want.size()], diff.is_empty(), "; ".join(diff))
		if not diff.is_empty() or OS.get_cmdline_user_args().has("--show"):
			for note in rep.notes:
				print("    note: ", note)
			print(code)

	# the generated code keeps the cheap shapes the script had
	var fast := Importer.new().convert(SAMPLES["code as fast as written"][1], {})
	var fc := Compiler.new()
	var fast_code := fc.compile(fast.bp)
	check("a changed struct member is assigned directly", fast_code.contains("position.y += STEP") and fast_code.contains("partner.position.x = total") and fast_code.contains("partner.scale.z -= 0.5") and not fast_code.contains("= Vector3("))
	check("a packed array is looped over without a copy", fast_code.contains("in samples:") and not fast_code.contains("Array(samples)"))
	check("an object in a condition is tested as written", fast_code.contains("if partner:") and not fast_code.contains("is_instance_valid(partner)"))
	check("locals are declared where they are first set, inferred as written", fast_code.contains("\tvar sum := 0.0\n") and fast_code.contains("\tvar rounded := snappedf(value, 0.5)\n") and fast_code.contains("\tvar made := 0\n"))
	check("a call that feeds the next variable needs no temporary", fast_code.contains("var bonus := extra(sum)") and fast_code.contains("var text := name_for(rounded)") and fast_code.contains("total = tally(2)"))
	check("a counted loop is written as range(count)", fast_code.contains(" in range(count):") and fast_code.contains(" in range(2, count):") and not fast_code.contains("+ 1"))
	check("a negation stays a negation", fast_code.contains("return ((-value) * STEP)") and not fast_code.contains("* -1"))
	check("a formatted string needs no conversion", fast_code.contains("return (\"cell_%d\" % index)") and not fast_code.contains("str("))
	check("a local of an event is a local, not a member", fast_code.contains("\tvar half_enter_tree := STEP * 0.5\n") and fast_code.contains("\tvar names_enter_tree := [") and not fast_code.contains("\nvar half_enter_tree") and not fast_code.contains("\nvar names_enter_tree"))
	# an event local that carries a value from one run to the next has to stay a member
	var keeps := Importer.new().convert("extends Node\nvar seen := 0\nfunc _process(_delta):\n\tvar last := seen\n\tseen = last + 1\nfunc _ready():\n\tvar tw := create_tween()\n\tvar fade := 1.0\n\ttw.tween_property(self, \"fade_ready\", 0.0, 1.0)\n\tseen = int(fade)\n", {})
	var keeps_code := Compiler.new().compile(keeps.bp)
	check("a local named in a string stays a member", keeps_code.contains("\nvar fade_ready") and keeps_code.contains("\tvar last_process := seen\n"), keeps_code if not keeps_code.contains("\nvar fade_ready") else "")
	# where GDScript cannot infer, the local falls back to the type the graph knows
	var guess := Importer.new().convert("extends Node\nvar out := 0.0\nfunc run(box: Dictionary) -> void:\n\tvar first := 2.5\n\tvar second := first * 2.0\n\tout = second\n", {})
	var guess_code := Compiler.new().compile(guess.bp)
	var first_line := 0
	var guess_lines := guess_code.split("\n")
	for li in guess_lines.size():
		if guess_lines[li].contains("var first := "):
			first_line = li + 1
	var dropped := Compiler.drop_inferred(guess.bp, guess_code, [first_line])
	var guess_again := Compiler.new().compile(guess.bp)
	check("a local GDScript cannot infer is declared with its known type", first_line > 0 and dropped == 1 and guess_again.contains("var first: float = 2.5") and guess_again.contains("var second := "), guess_again if dropped != 1 else "")
	check("with no line to blame every inferred local is given up", Compiler.drop_inferred(guess.bp, guess_again, []) == 1 and Compiler.new().compile(guess.bp).contains("var second: float = "))
	# the graph is stored one node to a line and reads back the same
	var fast_text := Model.build_source(fast_code, fast.bp)
	var data_lines := 0
	var nodes_total := 0
	for gl in fast_text.split("\n"):
		if gl.begins_with("#~"):
			data_lines += 1
	for fg in fast.bp.graphs:
		nodes_total += fg.nodes.size()
	var read_back := Model.parse_source(fast_text)
	check("the stored graph is one node to a line and reads back the same", data_lines < nodes_total + fast.bp.graphs.size() * 12 + 8 and Compiler.new().compile(read_back) == fast_code, "%d data lines for %d nodes" % [data_lines, nodes_total])
	check("static functions stay static", fast_code.contains("static func describe(value: float) -> String:") and fast_code.contains("static func name_for(value: float) -> String:"))

	# a node shortcut takes its class from the scene that uses the script
	DirAccess.make_dir_recursive_absolute("res://tests/tmp/imp")
	var lamp_src := "extends Node3D\n@onready var lamp = $Lamp\n@onready var bulb = $Holder/Bulb\nvar seen := 0.0\nfunc _ready():\n\tlamp.light_energy = 2.0\n\tbulb.visible = false\n\tseen = lamp.light_energy\n"
	var lamp_file := FileAccess.open("res://tests/tmp/imp/lamp_owner.gd", FileAccess.WRITE)
	lamp_file.store_string(lamp_src)
	lamp_file.close()
	var lamp_root := Node3D.new()
	lamp_root.name = "LampOwner"
	lamp_root.set_script(load("res://tests/tmp/imp/lamp_owner.gd"))
	var lamp_light := OmniLight3D.new()
	lamp_light.name = "Lamp"
	lamp_root.add_child(lamp_light)
	lamp_light.owner = lamp_root
	var lamp_holder := Node3D.new()
	lamp_holder.name = "Holder"
	lamp_root.add_child(lamp_holder)
	lamp_holder.owner = lamp_root
	var lamp_bulb := MeshInstance3D.new()
	lamp_bulb.name = "Bulb"
	lamp_holder.add_child(lamp_bulb)
	lamp_bulb.owner = lamp_root
	var lamp_scene := PackedScene.new()
	lamp_scene.pack(lamp_root)
	ResourceSaver.save(lamp_scene, "res://tests/tmp/imp/lamp_owner.tscn")
	lamp_root.free()
	Importer.reset_scene_index()
	var lamp_out := Importer.new().convert(lamp_src, {"path": "res://tests/tmp/imp/lamp_owner.gd"})
	var lamp_types := {}
	for lv in lamp_out.bp.variables:
		lamp_types[String(lv.name)] = String(lv.type)
	var lamp_code := Compiler.new().compile(lamp_out.bp)
	check("a node shortcut takes its class from the scene", lamp_types.get("lamp", "") == "OmniLight3D" and lamp_types.get("bulb", "") == "MeshInstance3D" and int(lamp_out.report.as_code) == 0 and lamp_code.contains("lamp.light_energy = 2.0"), "%s, %d line(s) kept as code" % [lamp_types, int(lamp_out.report.as_code)])
	check("a node shortcut is still looked up once, when the node is ready", lamp_code.contains("@onready var lamp = $Lamp") and lamp_code.contains("@onready var bulb = $Holder/Bulb"))

	# what must not be nodes is reported, not silently dropped
	var imp2 := Importer.new()
	var rep2: Dictionary = imp2.convert("extends Node\nvar out: Array = []\nfunc _ready():\n\tfor f in 2.5:\n\t\tout.append(f)\n\tout.append(1)\n", {}).report
	check("unconvertible lines are counted and explained", int(rep2.as_code) == 2 and rep2.notes.any(func(n): return String(n).contains("a loop over a float")), "%d as code: %s" % [rep2.as_code, str(rep2.notes)])
	var rep_match: Dictionary = Importer.new().convert(SAMPLES["things kept as code"][1], {}).report
	check("a match that binds names is nodes too", int(rep_match.as_code) == 0, "%d as code: %s" % [rep_match.as_code, str(rep_match.notes)])
	for sample_name in ["forms that used to be code", "lambdas"]:
		var rep3: Dictionary = Importer.new().convert(SAMPLES[sample_name][1], {}).report
		check("%s: every line is nodes" % sample_name, int(rep3.as_code) == 0, "%d as code: %s" % [rep3.as_code, str(rep3.notes.filter(func(n): return String(n).contains("kept as code")))])
	check("ordinary scripts convert almost entirely to nodes", all_code * 4 < all_lines, "%d of %d lines kept as code overall" % [all_code, all_lines])
	print("IMPORT FAILS: ", fails)
	quit(1 if fails else 0)
