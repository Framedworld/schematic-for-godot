extends SceneTree
## Reuse (core/sc_reuse.gd): repeated groups of nodes become macros, and the generated script stays the same.
## Run: godot --headless --path . --script res://tests/test_reuse.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Reuse := preload("res://addons/schematic/core/sc_reuse.gd")

const DIR := "res://tests/tmp/reuse"
const LIB := "res://tests/tmp/reuse/shared_macros.gd"

var fails := 0

## One script, the same steps in four functions: different numbers and texts, and a local with a different name.
const ONE := """extends Node

var hp := 20
var shield := 5
var log: Array = []
var seen: Array = []

func _ready():
	hit(3)
	burn(30)
	freeze(2)
	shock(7)
	count([1, 2, 3])
	count_more([4, 5])
	log.append(first_big([1, 9, 4]))
	log.append(first_small([7, 2, 8]))

func hit(amount: int):
	var left := hp - amount * 2
	if left < 0:
		left = 0
		log.append("down by hit")
	hp = left
	shield = maxi(shield - 1, 0)
	log.append("hit %d" % amount)

func burn(amount: int):
	var rest := hp - amount * 3
	if rest < 0:
		rest = 0
		log.append("down by burn")
	hp = rest
	shield = maxi(shield - 2, 0)
	log.append("burn %d" % amount)

func freeze(amount: int):
	var left := hp - amount * 1
	if left < 0:
		left = 0
		log.append("down by freeze")
	hp = left
	shield = maxi(shield - 3, 0)
	log.append("freeze %d" % amount)

func shock(amount: int):
	var left := hp - amount * 4
	if left < 0:
		left = 0
		log.append("down by shock")
	hp = left
	shield = maxi(shield - 4, 0)
	log.append("shock %d" % amount)

func count(items: Array):
	for item in items:
		if item % 2 == 0:
			seen.append(item * 10)
		else:
			seen.append(item)
		log.append("saw %d" % item)

func count_more(items: Array):
	for item in items:
		if item % 2 == 0:
			seen.append(item * 100)
		else:
			seen.append(item)
		log.append("more %d" % item)

func first_big(items: Array) -> int:
	for item in items:
		if item > 5:
			log.append("big one")
			seen.append(item)
			return item
	return -1

func first_small(items: Array) -> int:
	for item in items:
		if item > 5:
			log.append("small one")
			seen.append(item)
			return item
	return -2
"""

## Two scripts with the same steps on a node they are handed (nothing of their own in it).
const TWO_A := """extends Node

var made: Array = []

func _ready():
	var a := Node3D.new()
	add_child(a)
	place(a, Vector3(1, 2, 3))
	var b := Node3D.new()
	add_child(b)
	drop(b, Vector3(4, 5, 6))
	made.append(a.position + b.position)
	made.append(a.scale + b.scale)
	made.append(a.is_in_group("placed") and b.is_in_group("dropped"))

func place(n: Node3D, at: Vector3):
	n.position = at
	n.rotation = Vector3.ZERO
	n.scale = Vector3.ONE * 2.0
	n.visible = true
	n.add_to_group("placed")
	n.set_meta("order", 1)

func drop(n: Node3D, at: Vector3):
	n.position = at
	n.rotation = Vector3.ZERO
	n.scale = Vector3.ONE * 2.0
	n.visible = true
	n.add_to_group("dropped")
	n.set_meta("order", 1)
"""

const TWO_B := """extends Node

var made: Array = []

func _ready():
	var a := Node3D.new()
	add_child(a)
	stand(a, Vector3(7, 8, 9))
	var b := Node3D.new()
	add_child(b)
	lean(b, Vector3(1, 1, 1))
	made.append(a.position - b.position)
	made.append(a.scale - b.scale)
	made.append(a.get_meta("order") + b.get_meta("order"))

func stand(n: Node3D, at: Vector3):
	n.position = at
	n.rotation = Vector3.ZERO
	n.scale = Vector3.ONE * 2.0
	n.visible = true
	n.add_to_group("standing")
	n.set_meta("order", 1)

func lean(n: Node3D, at: Vector3):
	n.position = at
	n.rotation = Vector3.ZERO
	n.scale = Vector3.ONE * 2.0
	n.visible = true
	n.add_to_group("leaning")
	n.set_meta("order", 1)
"""


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func load_source(code: String) -> GDScript:
	var scr := GDScript.new()
	scr.source_code = code
	return scr if scr.reload() == OK else null


func compiled(bp: Dictionary) -> String:
	var c := Compiler.new()
	var code: String = c.compile(bp)
	for e in c.errors:
		if not e.w:
			return "ERROR " + String(e.m)
	return code


func converted(source: String) -> Dictionary:
	var imp := Importer.new()
	return imp.convert(source, {}).bp


func count(bp: Dictionary) -> int:
	var total := 0
	for g in bp.graphs:
		total += g.nodes.size()
	return total


func macro_uses(bp: Dictionary) -> Array:
	var out := []
	for g in bp.graphs:
		for n in g.nodes:
			if n.kind == "macro":
				out.append(n)
	return out


## Runs a script as a node for a few frames and returns its variables as text.
func state_of(code: String) -> String:
	var scr := load_source(code)
	if scr == null:
		return "does not load"
	var n := Node.new()
	n.set_script(scr)
	root.add_child(n)
	await process_frame
	var out := {}
	for p in scr.get_script_property_list():
		if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out[String(p.name)] = n.get(p.name)
	n.queue_free()
	await process_frame
	return str(out)


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	DirAccess.make_dir_recursive_absolute(DIR)
	if FileAccess.file_exists(LIB):
		DirAccess.remove_absolute(LIB)

	# ---------------------------------------------------------------- the check itself
	var a := "var x := 1\n\nfunc f():\n\tfor item_3 in list:\n\t\tprint(item_3)\n\tvar other := 2\n"
	check("same text is the same code", Reuse.same_code(a, a))
	check("a loop variable may get a new number", Reuse.same_code(a, a.replace("item_3", "item_41")))
	check("... but not a new name", not Reuse.same_code(a, a.replace("item_3", "thing_3")))
	check("... and not half of the time", not Reuse.same_code(a, a.replace("print(item_3)", "print(item_4)")))
	check("a changed number is not the same code", not Reuse.same_code(a, a.replace(":= 2", ":= 3")))
	check("a changed line outside functions is not the same code", not Reuse.same_code(a, a.replace("var x := 1", "var x := 2")))
	check("a missing line is not the same code", not Reuse.same_code(a, a.replace("\tvar other := 2\n", "")))
	var b := "func f():\n\tfor item_3 in list:\n\t\tfor item_5 in item_3:\n\t\t\tprint(item_3, item_5)\n"
	check("two loop variables may both be renumbered", Reuse.same_code(b, b.replace("item_3", "item_8").replace("item_5", "item_9")))
	check("... but not onto each other", not Reuse.same_code(b, b.replace("item_5", "item_3")))
	check("... and not onto a name the function uses", not Reuse.same_code(b, b.replace("item_3", "item_9").replace("item_5", "item_3")))
	var c := "var item_7 := 0\n\nfunc f():\n\tfor item_3 in list:\n\t\tprint(item_3)\n"
	check("a loop variable may not take the name of a member", not Reuse.same_code(c, c.replace("item_3", "item_7").replace("var item_7 := 0", "var item_7 := 0")))
	var d := "func f():\n\tfor item_3 in list:\n\t\tprint(item_3)\n\n\nfunc g():\n\tfor item_3 in list:\n\t\tprint(item_3)\n"
	var d2 := "func f():\n\tfor item_6 in list:\n\t\tprint(item_6)\n\n\nfunc g():\n\tfor item_9 in list:\n\t\tprint(item_9)\n"
	check("each function is compared by itself", Reuse.same_code(d, d2))

	# ---------------------------------------------------------------- inside one Schematic
	var bp := converted(ONE)
	var before := compiled(bp)
	var nodes_before := count(bp)
	var r := Reuse.new()
	var rep := r.run([{"path": DIR + "/one.gd", "bp": bp}], "")
	var after := compiled(bp)
	check("one file: macros were made", int(rep.macros) >= 2 and int(rep.uses) >= 6, "%d macros, %d uses: %s" % [int(rep.macros), int(rep.uses), "; ".join(r.notes)])
	check("one file: fewer nodes", count(bp) < nodes_before and int(rep.before) == nodes_before and int(rep.after) == count(bp), "%d -> %d" % [nodes_before, count(bp)])
	check("one file: it still compiles", not after.begins_with("ERROR"), after.left(120))
	check("one file: the generated script is the same", Reuse.same_code(before, after))
	check("one file: reported as changed, nothing put back", rep.changed == [DIR + "/one.gd"] and rep.undone.is_empty())
	var ran_before: String = await state_of(before)
	var ran_after: String = await state_of(after)
	check("one file: it runs to the same state", ran_before == ran_after and ran_before.contains("down by burn"), ran_after.left(200))
	var named := false
	for n in macro_uses(bp):
		if n.p.has("names") and (n.p.names as Dictionary).values().has("rest"):
			named = true
	check("one file: the place whose local has another name says so", named and after.contains("var rest := "))
	var clean := true
	var flagged := true
	for g in bp.graphs:
		if g.kind != "macro":
			continue
		flagged = flagged and bool(g.get("reuse", false))
		for n in g.nodes:
			if n.kind in Reuse.NEVER and not n.kind in ["macro_in", "macro_out"]:
				clean = false
	check("one file: no macro holds a Return, a Break or code", clean)
	check("one file: the macros are marked as made by reuse", flagged)
	check("one file: the loops that end in a Return were left alone", after.contains("return item") and before.count("return item") == after.count("return item"))
	# the stored form reads back to the same script
	var back := Model.parse_source(Model.build_source(after, bp))
	check("one file: saved and loaded, it compiles to the same script", compiled(back) == after)

	# again: nothing more to do, nothing changes
	var again := bp.duplicate(true)
	var r2 := Reuse.new()
	var rep2 := r2.run([{"path": DIR + "/one.gd", "bp": again}], "")
	check("one file: a second run changes nothing", rep2.changed.is_empty() and compiled(again) == after and count(again) == count(bp), "; ".join(r2.notes))

	# ---------------------------------------------------------------- between Schematics
	var fa := {"path": DIR + "/two_a.gd", "bp": converted(TWO_A)}
	var fb := {"path": DIR + "/two_b.gd", "bp": converted(TWO_B)}
	var code_a := compiled(fa.bp)
	var code_b := compiled(fb.bp)
	var total := count(fa.bp) + count(fb.bp)
	var r3 := Reuse.new()
	var rep3 := r3.run([fa, fb], LIB)
	check("two files: a shared macro was made", int(rep3.library) >= 1 and FileAccess.file_exists(LIB), "; ".join(r3.notes))
	var lib := Model.load_file(LIB)
	check("two files: the library is a macro library made by reuse", String(lib.get("library", "")) == "macro" and bool(lib.get("reuse", false)))
	var uses := macro_uses(fa.bp) + macro_uses(fb.bp)
	check("two files: all four places use it", uses.size() == 4 and uses.all(func(n): return String(n.p.get("lib", "")) == LIB), str(uses.size()))
	check("two files: fewer nodes, library counted", int(rep3.after) < total and int(rep3.after) == count(fa.bp) + count(fb.bp) + count(lib), "%d -> %d" % [total, int(rep3.after)])
	check("two files: both generated scripts are the same", compiled(fa.bp) == code_a and compiled(fb.bp) == code_b)
	check("two files: the library file loads as a script", load_source(FileAccess.get_file_as_string(LIB)) != null)
	var own := true
	for g in lib.graphs:
		for n in g.nodes:
			if n.kind in Reuse.OWN:
				own = false
	check("two files: nothing in the library belongs to one Schematic", own)
	var state_a: String = await state_of(compiled(fa.bp))
	check("two files: it runs to the same state", state_a == await state_of(code_a) and state_a.contains("(5.0, 7.0, 9.0)"), state_a)

	# a second run keeps the library and what uses it
	var names_before: Array = lib.graphs.map(func(g): return String(g.name))
	var r4 := Reuse.new()
	var rep4 := r4.run([fa, fb], LIB)
	var lib2 := Model.load_file(LIB)
	check("two files: a second run keeps the library", rep4.changed.is_empty() and lib2.graphs.map(func(g): return String(g.name)) == names_before
		and compiled(fa.bp) == code_a and compiled(fb.bp) == code_b, "; ".join(r4.notes))

	# converted again from the scripts: the old macros go, unless something else uses them
	var fa2 := {"path": DIR + "/two_a.gd", "bp": converted(TWO_A)}
	var fb2 := {"path": DIR + "/two_b.gd", "bp": converted(TWO_B)}
	var r5 := Reuse.new()
	var rep5 := r5.run([fa2, fb2], LIB, {"KeptForSomeoneElse": true})
	var lib3 := Model.load_file(LIB)
	check("converted again: the library holds what is used, once", int(rep5.library) == int(rep3.library) and lib3.graphs.size() == lib.graphs.size()
		and compiled(fa2.bp) == code_a and compiled(fb2.bp) == code_b, "%d macros" % int(rep5.library))
	var r6 := Reuse.new()
	var first_macro := ""
	for g in lib3.graphs:
		if g.kind == "macro":
			first_macro = String(g.name)
	r6.run([{"path": DIR + "/two_a.gd", "bp": converted(TWO_A)}, {"path": DIR + "/two_b.gd", "bp": converted(TWO_B)}], LIB, {first_macro: true})
	var lib4 := Model.load_file(LIB)
	check("converted again: a macro another Schematic uses stays", not Model.graph_named(lib4, first_macro).is_empty() and lib4.graphs.size() == lib3.graphs.size() + 1, str(lib4.graphs.size()))

	# a file that reuse did not make is never written over
	var mine := "extends Node\n# my own script\n"
	var f := FileAccess.open(LIB, FileAccess.WRITE)
	f.store_string(mine)
	f.close()
	R.invalidate_libraries()
	var fa3 := {"path": DIR + "/two_a.gd", "bp": converted(TWO_A)}
	var fb3 := {"path": DIR + "/two_b.gd", "bp": converted(TWO_B)}
	var r7 := Reuse.new()
	var rep7 := r7.run([fa3, fb3], LIB)
	check("a file at the library's place that reuse did not make is left alone", FileAccess.get_file_as_string(LIB) == mine and int(rep7.library) == 0
		and compiled(fa3.bp) == code_a and macro_uses(fa3.bp).all(func(n): return not n.p.has("lib")))
	DirAccess.remove_absolute(LIB)
	R.invalidate_libraries()

	print("\n%s (%d failed)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
