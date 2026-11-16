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


## The same loop in three functions, each written with a variable of its own. Only the numbers and texts differ.
const LOOPS := """extends Node

var total := 0
var log: Array = []

func _ready():
	a([1, 2, 3, 4, 5])
	b([6, 7, 8])
	c([2, 9])

func a(items: Array):
	for x in items:
		total += x * 2
		log.append(x + 1)
		log.append("a %d" % x)
		if x > 3:
			log.append(x * x)

func b(items: Array):
	for col in items:
		total += col * 3
		log.append(col + 1)
		log.append("b %d" % col)
		if col > 6:
			log.append(col * col)

func c(items: Array):
	for cell in items:
		total += cell * 4
		log.append(cell + 1)
		log.append("c %d" % cell)
		if cell > 1:
			log.append(cell * cell)
"""

## Loops inside loops, written with other variable names in each function.
const NESTED := """extends Node

var total := 0
var log: Array = []

func _ready():
	a([[1, 2], [3, 4]])
	b([[5, 6], [7]])
	c([[8], [9, 1]])

func a(rows: Array):
	for r in rows:
		for k in r:
			total += k * 2
			log.append(k + 1)
			log.append("a %d" % k)
			if k > 2:
				log.append(k * k)

func b(rows: Array):
	for row in rows:
		for cell in row:
			total += cell * 3
			log.append(cell + 1)
			log.append("b %d" % cell)
			if cell > 5:
				log.append(cell * cell)

func c(rows: Array):
	for line in rows:
		for item in line:
			total += item * 4
			log.append(item + 1)
			log.append("c %d" % item)
			if item > 8:
				log.append(item * item)
"""

## A lambda made in the loop reads the loop variable by its name.
const LAMBDAS := """extends Node

var total := 0
var log: Array = []
var calls: Array = []

func _ready():
	a([1, 2, 3])
	b([4, 5])
	c([6, 7, 8])
	for f in calls:
		log.append(f.call())

func a(items: Array):
	for x in items:
		var f := func(): return x * 10
		calls.append(f)
		total += x * 2
		log.append(x + 1)
		log.append("a %d" % x)

func b(items: Array):
	for col in items:
		var g := func(): return col * 10
		calls.append(g)
		total += col * 3
		log.append(col + 1)
		log.append("b %d" % col)

func c(items: Array):
	for cell in items:
		var h := func(): return cell * 10
		calls.append(h)
		total += cell * 4
		log.append(cell + 1)
		log.append("c %d" % cell)
"""

## The steps at the start of each loop body are the same, the rest of the bodies are not: a group made of the
## body only, the variable of the loop outside it coming in as a value.
const BODIES := """extends Node

var total := 0
var log: Array = []

func _ready():
	a([1, 2, 3])
	b([4, 5])
	c([6, 7, 8])

func a(items: Array):
	for x in items:
		total += x * 2
		log.append(x + 1)
		log.append("a %d" % x)
		if x > 1:
			log.append(x * x)
		log.append("after a")

func b(items: Array):
	for col in items:
		total += col * 3
		log.append(col + 1)
		log.append("b %d" % col)
		if col > 4:
			log.append(col * col)
		total -= 1

func c(items: Array):
	for cell in items:
		total += cell * 4
		log.append(cell + 1)
		log.append("c %d" % cell)
		if cell > 6:
			log.append(cell * cell)
		log.append(cell)
"""

## Four functions with the same steps, for the comment cases (see commented()).
const NOTE_HEAD := "extends Node\n\nvar total := 0\nvar log: Array = []\n\nfunc _ready():\n"
const NOTE_STEPS := "func NAME(x: int):\nFIRST\ttotal += x * K\n\tlog.append(x + 1)TAIL\nMID\tlog.append(\"NAME %d\" % x)\n\tif x > K:\nIFBODY\n\tlog.append(x - K)\nLAST\n\n"

## The same loop body in three functions, with comments above and inside every loop and one above each function.
const NOTE_LOOPS := """extends Node

var total := 0
var log: Array = []

func _ready():
	a([1, 2, 3])
	b([4, 5])
	c([6, 7, 8])

# the first function
func a(items: Array):
	# walk a
	for x in items:   # loop a
		total += x * 2
		# bump a
		log.append(x + 1)
		log.append("a %d" % x)
		if x > 1:
			log.append(x * x)   # square a
		log.append("after a")

func b(items: Array):
	for col in items:
		total += col * 3
		log.append(col + 1)   # bump b
		log.append("b %d" % col)
		if col > 4:
			log.append(col * col)
		total -= 1

# the third function
func c(items: Array):
	# walk c
	# (two lines)
	for cell in items:
		# first step c
		total += cell * 4
		log.append(cell + 1)
		log.append("c %d" % cell)
		if cell > 6:
			log.append(cell * cell)
		log.append(cell)
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


## True when a macro that reuse made holds a loop.
func macro_has_loop(bp: Dictionary) -> bool:
	for g in bp.graphs:
		if g.kind == "macro" and bool(g.get("reuse", false)):
			for n in g.nodes:
				if n.kind in Reuse.LOOPVAR:
					return true
	return false


## The four functions of NOTE_STEPS. `slots` is one dictionary per function: "first" (a comment line above the first
## step), "tail" (at the end of the second step), "mid" (above the third), "ifbody" (the lines of the if block, tab
## indented, as written), "last" (a comment line at the end of the function). Whatever a function leaves out it has not.
func commented(slots: Array, count := 4) -> String:
	var out := NOTE_HEAD
	for i in count:
		out += "\t%s(%d)\n" % ["abcdefgh".substr(i, 1), i + 1]
	out += "\n"
	for i in count:
		var s: Dictionary = slots[i] if i < slots.size() else {}
		var t := NOTE_STEPS
		t = t.replace("FIRST", ("\t# " + String(s.first) + "\n") if s.has("first") else "")
		t = t.replace("TAIL", ("   # " + String(s.tail)) if s.has("tail") else "")
		t = t.replace("MID", ("\t# " + String(s.mid) + "\n") if s.has("mid") else "")
		t = t.replace("IFBODY", String(s.get("ifbody", "\t\tlog.append(x * x)")))
		t = t.replace("LAST", ("\t# " + String(s.last)) if s.has("last") else "")
		out += t.replace("NAME", "abcdefgh".substr(i, 1)).replace("K", str(i + 2))
	return out


## True when none of the nodes of the macros that reuse made carries a comment of its own.
func macros_clean(bp: Dictionary) -> bool:
	for g in bp.graphs:
		if g.kind == "macro" and bool(g.get("reuse", false)):
			for n in g.nodes:
				for field in Reuse.COMMENT_FIELDS:
					if n.p.has(field):
						return false
				if n.kind == "macro" and n.p.has("notes"):
					return false
	return true


## Every comment of every use of a macro, as one text (what the macro nodes say: `notes`).
func notes_text(bp: Dictionary) -> String:
	var out := ""
	for n in macro_uses(bp):
		out += JSON.stringify(n.p.get("notes", {}), "", true)
	return out


## One comment case: the four functions of `slots`, run through reuse. The groups of the four must be one macro, the
## macro must carry no comment, the script must be the script it was with every comment in it, and it must run to the
## same state. `texts` are the comments the converted script has to show.
func note_case(label: String, slots: Array, texts: Array, source := "") -> Dictionary:
	var src := source if source != "" else commented(slots)
	var c: Dictionary = await loop_case(label, src)
	var uses := macro_uses(c.bp)
	var named := {}
	for n in uses:
		named[String(n.p.name)] = true
	check(label + ": one macro, used by every function", named.size() == 1 and uses.size() == 4, "%d uses, %d macros; %s" % [uses.size(), named.size(), "; ".join(c.r.notes)])
	check(label + ": the macro carries no comment", macros_clean(c.bp))
	var shown := true
	for t in texts:
		shown = shown and c.before.contains(String(t)) and c.after.contains(String(t))
	check(label + ": every comment is in the script, as written", shown and c.after == c.before, c.after.left(300))
	return c


## Converts a script, runs reuse over it and checks what must hold whatever the loops are written with: nothing
## put back, the same script, the same state when it runs. `mutate` may change the converted Schematic first.
func loop_case(label: String, source: String, mutate := Callable()) -> Dictionary:
	var bp := converted(source)
	if mutate.is_valid():
		mutate.call(bp)
	var before := compiled(bp)
	var r := Reuse.new()
	var rep := r.run([{"path": DIR + "/loops.gd", "bp": bp}], "")
	var after := compiled(bp)
	var ok: bool = not before.begins_with("ERROR") and not after.begins_with("ERROR") and Reuse.same_code(before, after) and rep.undone.is_empty()
	var ran_before: String = await state_of(before)
	var ran_after: String = await state_of(after)
	check(label + ": the script is the same and nothing was put back", ok, "; ".join(r.notes) + " " + after.left(100) if not ok else "")
	check(label + ": it runs to the same state", ran_before == ran_after and ran_before.contains("total"), ran_after.left(160))
	return {"bp": bp, "before": before, "after": after, "rep": rep, "r": r, "per_use": r._per_use()}


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

	# ---------------------------------------------------------------- loop variable names
	# The name of a loop variable is no part of what a group is. Whether groups that differ in it are one macro
	# depends on the compiler being able to write each use's own name (Compiler.PER_USE_LOOP_VARS); when it
	# cannot, they stay apart, and every script is still the script it was.
	var per_use: bool = Reuse.new()._per_use()
	print("-- loop variables: the compiler %s per-use names" % ["writes" if per_use else "does not write"])

	var lc: Dictionary = await loop_case("loops, other names", LOOPS)
	check("loops, other names: one macro for the loop iff each use can keep its name", macro_has_loop(lc.bp) == per_use,
		"%d uses; %s" % [macro_uses(lc.bp).size(), "; ".join(lc.r.notes)])
	check("loops, other names: every function keeps the name it wrote",
		lc.after.contains("for x in items:") and lc.after.contains("for col in items:") and lc.after.contains("for cell in items:") and lc.after == lc.before,
		lc.after.left(200))
	if per_use:
		var seen := []
		for n in macro_uses(lc.bp):
			for v in (n.p.get("vars", {}) as Dictionary).values():
				seen.append(String(v))
		seen.sort()
		check("loops, other names: each use records its own name", seen == ["cell", "col", "x"], str(seen))

	var same_names: String = LOOPS.replace("col", "x").replace("cell", "x")
	var sc: Dictionary = await loop_case("loops, same name", same_names)
	check("loops, same name: one macro for the loop", macro_has_loop(sc.bp) and macro_uses(sc.bp).size() >= 3 and sc.after == sc.before,
		"%d uses; %s" % [macro_uses(sc.bp).size(), "; ".join(sc.r.notes)])

	var nc: Dictionary = await loop_case("nested loops", NESTED)
	check("nested loops: one macro iff each use can keep its names", macro_has_loop(nc.bp) == per_use, "; ".join(nc.r.notes))
	check("nested loops: every function keeps its names", nc.after == nc.before and nc.after.contains("for row in rows:") and nc.after.contains("for item in line:")
		and nc.after.contains("for r in rows:") and nc.after.contains("for k in r:"), nc.after.left(200))

	var lm: Dictionary = await loop_case("loop variable in a lambda", LAMBDAS)
	check("loop variable in a lambda: every function keeps its names", lm.after.contains("for x in items:") and lm.after.contains("for col in items:")
		and lm.after.contains("for cell in items:") and lm.after == lm.before, lm.after.left(300))
	check("loop variable in a lambda: the lambdas read the loop variables", lm.after.contains("x * 10") and lm.after.contains("col * 10") and lm.after.contains("cell * 10"))

	var bc: Dictionary = await loop_case("loop body only", BODIES)
	check("loop body only: groups were made and the names are kept", macro_uses(bc.bp).size() >= 3 and bc.after == bc.before
		and bc.after.contains("for x in items:") and bc.after.contains("for col in items:"), "%d uses; %s" % [macro_uses(bc.bp).size(), "; ".join(bc.r.notes)])

	var ec: Dictionary = await loop_case("loops made in the editor", LOOPS, func(b):
		for g in b.graphs:
			for n in g.nodes:
				if n.kind in Reuse.LOOPVAR:
					n.p.erase("var"))
	var no_vars := true
	for n in macro_uses(ec.bp):
		no_vars = no_vars and not n.p.has("vars")
	check("loops made in the editor: one macro for the loop, nothing to name", macro_has_loop(ec.bp) and no_vars and not ec.after.contains("for x in"),
		"%d uses; %s" % [macro_uses(ec.bp).size(), "; ".join(ec.r.notes)])
	check("loops made in the editor: numbered as before", ec.after.contains("for item_"), ec.after.left(200))

	# a name that would clash where it is written is numbered by the compiler, before and after
	var cl: Dictionary = await loop_case("clashing loop variables", LOOPS, func(b):
		for g in b.graphs:
			for n in g.nodes:
				if n.kind in Reuse.LOOPVAR:
					if g.name == "b":
						n.p["var"] = "total"   # a member of the script
					elif g.name == "c":
						n.p["var"] = "items")  # a parameter of the function
	check("clashing loop variables: written the way the compiler wrote them before",
		not cl.after.contains("for total in") and not cl.after.contains("for items in") and cl.after.contains("for x in items:") and cl.before.contains("for item_"),
		cl.after.left(300))
	# (with per-use names all three are one macro; without, only the two numbered ones could be, which the steps
	# inside the loop may outweigh, so that is not asked for)
	check("clashing loop variables: the loops are one macro when each use can keep its name", macro_has_loop(cl.bp) or not per_use, "; ".join(cl.r.notes))

	# ---------------------------------------------------------------- comments
	# Comments are no part of what a group is either. When the compiler can write each use's own (Compiler.PER_USE_COMMENTS)
	# the groups are one macro, the macro's nodes carry none, and each use says which comments stand on which node.
	var per_comments: bool = Reuse.new()._per_use_comments()
	print("-- comments: the compiler %s per-use comments" % ["writes" if per_comments else "does not write"])
	check("comments: the compiler says it can write each use's comments", per_comments)

	var plain := await note_case("no comments", [], [])
	check("no comments: no use records any", notes_text(plain.bp) == "{}{}{}{}" or notes_text(plain.bp) == "")

	var one := await note_case("one use has comments, the others none", [{"first": "only here", "tail": "only here too"}, {}, {}, {}], ["# only here", "# only here too"])
	check("one use has comments: only that use records them", macro_uses(one.bp).filter(func(n): return n.p.has("notes")).size() == 1, notes_text(one.bp))

	var where := await note_case("comments on different nodes in each use",
		[{"first": "above the first"}, {"mid": "above the third"}, {"last": "end of c"}, {"tail": "end of the second step"}],
		["# above the first", "# above the third", "# end of c", "# end of the second step"])
	var each_one := true
	var spots := {}
	for n in macro_uses(where.bp):
		var nn: Dictionary = n.p.get("notes", {})
		each_one = each_one and nn.size() == 1
		for k in nn:
			spots[k] = true
	check("comments on different nodes: each use records its own node", each_one and spots.size() == 4, notes_text(where.bp))

	var all_in_one := await note_case("first, middle and last comments in one use",
		[{"first": "first of a", "tail": "tail of a", "mid": "middle of a", "last": "last of a"}, {}, {"mid": "middle of c"}, {}],
		["# first of a", "# tail of a", "# middle of a", "# last of a", "# middle of c"])

	var ends := await note_case("comments after a block and in a block of nothing else",
		[{"ifbody": "\t\tpass", "last": "end a"}, {"ifbody": "\t\t# nothing to do in b\n\t\tpass"}, {"ifbody": "\t\t# nothing in c   \n\t\t# second line of c\n\t\tpass", "tail": "t"},
		{"ifbody": "\t\tpass   # d, same line"}],
		["# nothing to do in b", "# nothing in c", "# second line of c", "pass   # d, same line"])
	check("comments in a block of nothing else: recorded as `empty` on the node", notes_text(ends.bp).contains("empty") or not per_comments, notes_text(ends.bp))
	var after_c := await note_case("comments after the last step of a block",
		[{"ifbody": "\t\tlog.append(x * x)\n\t\t# after the step, in a"}, {}, {"ifbody": "\t\tlog.append(x * x)   # tail in c\n\t\t# after, c\n\t\t# after, c again"}, {}],
		["# after the step, in a", "# tail in c", "# after, c again"])
	check("comments after a block: recorded as `after`", notes_text(after_c.bp).contains("after") or not per_comments, notes_text(after_c.bp))

	var odd_a := "say \"hi\" \\\\ back\\slash, café 日本 {\"k\": [1, 2]} 100% $x 'q'"
	var odd := await note_case("comments with quotes, backslashes and unicode",
		[{"first": odd_a, "tail": "tab\there \"quoted\" \\\\n"}, {"mid": "café 日本"}, {"mid": "#~ not a graph line"}, {}],
		["café 日本", "100% $x", "#~ not a graph line"])
	# through the file: written as a Schematic, read back, compiled again
	var written := Model.build_source(odd.after, odd.bp)
	var read_back := Model.parse_source(written)
	var round_trip := compiled(read_back) if not read_back.is_empty() else "does not read"
	check("comments with quotes, backslashes and unicode: the saved Schematic compiles to the same script", Reuse.same_code(odd.before, round_trip), round_trip.left(200))
	check("comments with quotes, backslashes and unicode: the script loads", load_source(odd.after) != null)

	# a loop, with comments on the loop node itself (outside what is shared) and inside its body
	var lp: Dictionary = await loop_case("comments on loops and in their bodies", NOTE_LOOPS)
	check("comments on loops: the script is the script, every comment in place", lp.after == lp.before and lp.after.contains("# walk a") and lp.after.contains("# (two lines)")
		and lp.after.contains("# first step c") and lp.after.contains("# loop a") and lp.after.contains("# square a") and lp.after.contains("# the third function"), lp.after.left(300))
	check("comments on loops: the loop bodies were shared and the macros carry no comment", macro_uses(lp.bp).size() >= 3 and macros_clean(lp.bp), "%d uses; %s" % [macro_uses(lp.bp).size(), "; ".join(lp.r.notes)])
	var loop_kept := true
	for g in lp.bp.graphs:
		for n in g.nodes:
			if n.kind in Reuse.LOOPVAR and g.kind != "macro" and g.name == "a":
				loop_kept = loop_kept and n.p.has("note") and String(n.p.get("tail", "")) != ""
	check("comments on loops: a loop that stayed in its function keeps its own comments", loop_kept)

	# a macro made of macros: the comments are recorded at the level they belong to
	var nested := converted(commented([{"first": "n a", "tail": "n a tail"}, {"mid": "n b"}, {"last": "n c"}, {}, {"first": "n e"}, {}], 6))
	var nested_before := compiled(nested)
	var n1 := Reuse.new()
	n1.max_len = 3
	var rn1 := n1.run([{"path": DIR + "/nested.gd", "bp": nested}], "")
	var inner_uses := macro_uses(nested).size()
	var n2 := Reuse.new()
	n2.min_body = 2
	n2.min_save = -100
	var rn2 := n2.run([{"path": DIR + "/nested.gd", "bp": nested}], "")
	var nested_after := compiled(nested)
	var made_inside := false
	for g in nested.graphs:
		if g.kind == "macro" and bool(g.get("reuse", false)):
			made_inside = made_inside or g.nodes.any(func(n): return n.kind == "macro")
	check("nested macros: the second run made a macro that uses a macro", made_inside, "first run %d uses; %s %s" % [inner_uses, "; ".join(n1.notes), "; ".join(n2.notes)])
	check("nested macros: the script is the script, nothing put back", nested_after == nested_before and rn1.undone.is_empty() and rn2.undone.is_empty(), nested_after.left(300))
	check("nested macros: every macro, outer and inner, carries no comment", macros_clean(nested))
	var outer_notes := ""
	for g in nested.graphs:
		if g.kind != "macro":
			for n in g.nodes:
				if n.kind == "macro":
					outer_notes += JSON.stringify(n.p.get("notes", {}), "", true)
	check("nested macros: the outer uses carry the inner uses' comments inside their own (`notes` in `notes`)", outer_notes.contains("\"notes\""), outer_notes.left(300))
	check("nested macros: the comments are in the script", nested_after.contains("# n a") and nested_after.contains("# n a tail") and nested_after.contains("# n b") and nested_after.contains("# n c"))
	var nested_ran_before: String = await state_of(nested_before)
	var nested_ran_after: String = await state_of(nested_after)
	check("nested macros: it runs to the same state", nested_ran_before == nested_ran_after and nested_ran_before.contains("total"))

	# Expand Node on one use gives that use's own comments, and the code it was
	var xb: Dictionary = where.bp
	var x_call := {}
	var x_graph := {}
	for g in xb.graphs:
		if g.name == "b":
			x_graph = g
			for n in g.nodes:
				if n.kind == "macro":
					x_call = n
	var stub_script := GDScript.new()
	stub_script.source_code = "extends Node\nfunc mutate(_label, fn, _rebuild := true):\n\tfn.call()\n"
	stub_script.reload()
	var stub: Node = stub_script.new()
	var view = preload("res://addons/schematic/editor/sc_graph_view.gd").new()
	view.editor = stub
	view.bp = xb
	view.graph = x_graph
	var before_expand := compiled(xb)
	check("expand node: the use has comments to expand", not x_call.is_empty() and (x_call.p.get("notes", {}) as Dictionary).size() == 1, str(x_call.p) if not x_call.is_empty() else "no macro in b")
	if not x_call.is_empty():
		view.expand_macro(int(x_call.id))
		var expanded := compiled(xb)
		var carried: Array = x_graph.nodes.filter(func(n): return n.p.has("note") and String(n.p.note[0]) == "# above the third")
		check("expand node: the expanded nodes have this use's comments", carried.size() == 1 and not x_graph.nodes.any(func(n): return n.p.has("note") and String(n.p.note[0]) == "# above the first"),
			str(x_graph.nodes.map(func(n): return n.p.get("note", []))))
		check("expand node: the code is the code it was", Reuse.same_code(before_expand, expanded) and expanded.contains("# above the third"), expanded.left(300))
	view.free()
	stub.free()

	# no notes anywhere: what reuse made before comments existed is compiled as before
	var hand := converted(commented([]))
	var hand_before := compiled(hand)
	Reuse.new().run([{"path": DIR + "/hand.gd", "bp": hand}], "")
	var no_notes := true
	for n in macro_uses(hand):
		no_notes = no_notes and not n.p.has("notes")
	check("a macro with no comments anywhere: no use records any, the script is the same", no_notes and compiled(hand) == hand_before and macro_uses(hand).size() == 4)
	# a macro whose author put a comment on one of its nodes: every use shows it, as it always did
	var authored := false
	for g in hand.graphs:
		if g.kind == "macro" and not authored:
			for n in g.nodes:
				if not authored and n.kind in ["var_inc", "var_set", "branch"]:
					n.p["note"] = ["# written by hand in the macro"]
					authored = true
					break
	var hand_after := compiled(hand)
	check("a macro with a comment of its own: every use shows it", not authored or hand_after.count("# written by hand in the macro") == 4, hand_after.left(200))

	print("\n%s (%d failed)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
