@tool
extends RefCounted
## Reuse: finds groups of nodes that repeat, inside one Schematic or across a project's Schematics, and turns
## each group into a macro that every place then uses.
##
## A macro is expanded where it is used when the Schematic is compiled, so this never costs anything at run
## time. That is also how the result is checked: a Schematic is only changed when the script generated from it
## afterwards is the script generated before (apart from the numbers in loop variables, which come from node
## ids). A Schematic that fails that check is put back as it was.
##
## What counts as a group: a run of steps on one execution path (each step with the value nodes that feed it
## and everything inside its branches or loop body), entered at one place and left at one place.
## What differs between the places becomes an input pin: a literal, a variable read, a value from outside.
## A local variable the group itself sets becomes a local of the macro; each use says which local of its own
## graph that is (`names` on the macro node), so the generated lines keep their names.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")

const LOOPS := ["for", "for_each", "for_each_dict", "while"]
const LEAVES := ["local_get", "var_get", "const", "self", "autoload"]
## Never part of a group: they leave the function or loop they are in, hold state per node, or are text.
const NEVER := ["fn_return", "loop_break", "loop_continue", "macro_in", "macro_out", "fn_entry", "timeline", "comment",
	"code", "expr", "delay", "flip_flop", "do_n", "do_once", "gate", "multigate", "retriggerable_delay", "event", "custom_event",
	"signal_event", "input_action", "key_event"]
## Not in a macro shared between Schematics: these belong to the Schematic they are in.
const OWN := ["var_set", "var_get", "var_inc", "call_self", "call_parent", "emit", "event_ref", "closure", "bind_signal", "unbind_signal",
	"get_node", "fn_ref"]

var min_save := 8      # a macro has to remove at least this many nodes over all its uses
var min_body := 4      # ... and hold at least this many nodes
var max_pins := 6      # value inputs
var max_outs := 2      # value outputs
var max_len := 10      # steps in a group
var notes: Array = []  # what was done, one line each

var _used: Dictionary = {}   # "graph key:node id" -> true, nodes already given to a macro in this pass
var _gas: Array = []
var _globals: Dictionary = {}


## `files` is [{path, bp}]; the schematics are changed in place. `library_path` ("" for none) is where macros
## shared between files are written. Returns {macros, library, uses, before, after, changed: [paths], undone: [paths]}.
## A library this made earlier is added to; its macros stay while one of `files` or a name in `used_elsewhere`
## (macro name -> true, for Schematics that are not in `files`) uses them. A file at that path that reuse did
## not make is left alone, and nothing is shared.
func run(files: Array, library_path := "", used_elsewhere := {}) -> Dictionary:
	R.ensure_api()
	var rep := {"macros": 0, "library": 0, "uses": 0, "before": 0, "after": 0, "changed": [], "undone": []}
	var live := []
	for f in files:
		var c := Compiler.new()
		var code: String = c.compile(f.bp)
		if c.errors.any(func(e): return not e.w):
			continue   # it does not compile as it is: nothing to compare against
		live.append({"path": f.path, "bp": f.bp, "code": code, "start": _count(f.bp)})
		rep.before += _count(f.bp)

	# 1. groups found in more than one file go to the macro library
	var lib := {}
	if library_path != "" and live.size() > 1:
		if not FileAccess.file_exists(library_path):
			lib = _new_library()
		else:
			lib = Model.load_file(library_path)
			if lib.is_empty() or not bool(lib.get("reuse", false)) or String(lib.get("library", "")) != "macro":
				lib = {}
				notes.append("%s is there already and reuse did not make it: no macros are shared between files" % library_path)
			else:
				rep.before += _count(lib)   # what an earlier run put there counts as there before
	if not lib.is_empty():
		var keep := []
		for f in live:
			keep.append(f.bp.duplicate(true))
		var made := _pass(live, true, lib, library_path)
		if made > 0:
			_write(library_path, lib)
			for i in live.size():
				if not _verify(live[i]):
					_restore(live[i].bp, keep[i])
					notes.append("%s: shared macros taken out again (%s)" % [live[i].path, _why])
					rep.undone.append(live[i].path)

	# 2. groups that repeat inside one file become macros of that file
	for f in live:
		var keep: Dictionary = f.bp.duplicate(true)
		var made := _pass([f], false, f.bp, "")
		if made > 0 and not _verify(f):
			# find the macro at fault: take them one at a time
			_restore(f.bp, keep)
			_one_at_a_time(f)

	# 3. library macros nobody uses any more are dropped
	if not lib.is_empty():
		var wanted: Dictionary = used_elsewhere.duplicate()
		for f in live:
			for g in f.bp.graphs:
				for n in g.nodes:
					if n.kind == "macro" and String(n.p.get("lib", "")) == library_path:
						wanted[String(n.p.name)] = true
		for i in range(lib.graphs.size() - 1, -1, -1):
			if lib.graphs[i].kind == "macro" and bool(lib.graphs[i].get("reuse", false)) and not wanted.has(String(lib.graphs[i].name)):
				lib.graphs.remove_at(i)
		rep.library = lib.graphs.filter(func(g): return g.kind == "macro").size()
		if rep.library > 0:
			_write(library_path, lib)
			rep.after += _count(lib)
		elif FileAccess.file_exists(library_path):
			DirAccess.remove_absolute(library_path)
			R.invalidate_libraries()

	for f in live:
		var now := _count(f.bp)
		rep.after += now
		for g in f.bp.graphs:
			if g.kind == "macro" and bool(g.get("reuse", false)):
				rep.macros += 1
			for n in g.nodes:
				if n.kind == "macro":
					rep.uses += 1
		if now != int(f.start):
			rep.changed.append(f.path)
	return rep


## True when the two generated scripts are the same but for the numbers in names the compiler numbers by node
## id (a loop variable `item_12`). Such a name may only change inside a function, to one new name that the
## function did not use before, and never when it is also a member or a function of the script.
static func same_code(a: String, b: String) -> bool:
	if a == b:
		return true
	var la := a.split("\n")
	var lb := b.split("\n")
	if la.size() != lb.size():
		return false
	var rx := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	# everything outside function bodies has to be the same text; its names are not to be touched anywhere
	var fixed := {}
	for i in la.size():
		if la[i].begins_with("\t"):
			continue
		if la[i] != lb[i]:
			return false
		for m in rx.search_all(la[i]):
			fixed[m.get_string()] = true
	var fwd := {}
	var back := {}
	var same := {}
	for i in la.size() + 1:
		if i == la.size() or not la[i].begins_with("\t"):
			# a function ends here: the names that changed in it must be new to it
			for ta in fwd:
				if same.has(ta) or same.has(fwd[ta]) or fwd.has(fwd[ta]) or fixed.has(ta) or fixed.has(fwd[ta]):
					return false
			fwd = {}
			back = {}
			same = {}
			continue
		if la[i] == lb[i]:
			for m in rx.search_all(la[i]):
				same[m.get_string()] = true
			continue
		var ma := rx.search_all(la[i])
		var mb := rx.search_all(lb[i])
		if ma.size() != mb.size():
			return false
		var pa := 0
		var pb := 0
		for k in ma.size():
			if la[i].substr(pa, ma[k].get_start() - pa) != lb[i].substr(pb, mb[k].get_start() - pb):
				return false
			var ta := ma[k].get_string()
			var tb := mb[k].get_string()
			pa = ma[k].get_end()
			pb = mb[k].get_end()
			if ta == tb:
				same[ta] = true
				continue
			var ua := ta.rfind("_")
			var ub := tb.rfind("_")
			if ua <= 0 or ub <= 0 or ta.substr(0, ua) != tb.substr(0, ub):
				return false
			if not ta.substr(ua + 1).is_valid_int() or not tb.substr(ub + 1).is_valid_int():
				return false
			if String(fwd.get(ta, tb)) != tb or String(back.get(tb, ta)) != ta:
				return false
			fwd[ta] = tb
			back[tb] = ta
		if la[i].substr(pa) != lb[i].substr(pb):
			return false
	return true


# ---------------------------------------------------------------- one pass

## Finds and applies macros over `files`. `shared`: only groups seen in two or more files, written to `target`
## (the library schematic); otherwise `target` is the one file's own schematic. Returns how many were made.
func _pass(files: Array, shared: bool, target: Dictionary, lib_path: String, only := -1) -> int:
	_used = {}
	_gas = []
	var table := {}
	for fi in files.size():
		for g in files[fi].bp.graphs:
			if g.kind == "macro":
				continue
			var ga := _analyse(fi, files[fi].bp, g)
			if not bool(ga.ok):
				continue
			var gi := _gas.size()
			_gas.append(ga)
			for bi in ga.blocks.size():
				var stmts: Array = ga.blocks[bi].s
				for i in stmts.size():
					var key := ""
					var count := 0
					for length in range(1, max_len + 1):
						if i + length > stmts.size():
							break
						var st: Dictionary = stmts[i + length - 1]
						if not bool(st.ok):
							break
						key = String(st.key) if length == 1 else (key + String(st.key)).md5_text()
						count += st.nodes.size()
						if count >= min_body:
							if not table.has(key):
								table[key] = []
							table[key].append([gi, bi, i, length, count])
	var cands := []
	for key in table:
		var occs: Array = table[key]
		# the most this could save, before looking closer
		if occs.size() < 2 or (occs.size() - 1) * int(occs[0][4]) - occs.size() - 2 < min_save:
			continue
		var c := _evaluate(occs, shared)
		if not c.is_empty():
			cands.append(c)
	cands.sort_custom(func(x, y): return int(x.save) > int(y.save) if int(x.save) != int(y.save) else int(x.body) > int(y.body))
	var made := 0
	var chosen := []
	for c in cands:
		var again := _evaluate(c.occs, shared)
		if again.is_empty():
			continue
		for f in again.flats:
			for id in f.nodes:
				_used["%d:%d" % [int(f.gi), int(id)]] = true
		chosen.append(again)
	for ci in chosen.size():
		if only != -1 and ci != only:
			continue
		_apply(chosen[ci], target, lib_path)
		made += 1
	return made if only == -1 else chosen.size()


## The file pass again, one macro at a time, keeping each only if the generated script stays the same.
func _one_at_a_time(f: Dictionary) -> void:
	var index := 0
	var guard := 0
	while guard < 200:
		guard += 1
		var keep: Dictionary = f.bp.duplicate(true)
		var total := _pass([f], false, f.bp, "", index)
		if index >= total:
			_restore(f.bp, keep)
			break
		if _verify(f):
			continue   # kept: the list is worked out again without the nodes it took, so the same index is the next one
		_restore(f.bp, keep)
		notes.append("%s: one macro left out (%s)" % [f.path, _why])
		index += 1


var _why := ""   # how the last script that failed the check differed

func _verify(f: Dictionary) -> bool:
	var c := Compiler.new()
	var code: String = c.compile(f.bp)
	_why = ""
	for e in c.errors:
		if not e.w:
			_why = "error: " + String(e.m)
			return false
	if same_code(String(f.code), code):
		return true
	var was := String(f.code).split("\n")
	var now := code.split("\n")
	_why = "%d lines became %d" % [was.size(), now.size()]
	for i in mini(was.size(), now.size()):
		if was[i] != now[i] and not same_code("\t" + was[i], "\t" + now[i]):
			_why = "line %d: `%s` became `%s`" % [i + 1, was[i].strip_edges(), now[i].strip_edges()]
			break
	return false


func _restore(bp: Dictionary, kept: Dictionary) -> void:
	bp.clear()
	bp.merge(kept.duplicate(true))


func _count(bp: Dictionary) -> int:
	var total := 0
	for g in bp.graphs:
		total += g.nodes.size()
	return total


func _new_library() -> Dictionary:
	var bp := Model.new_schematic("Node", "")
	bp["library"] = "macro"
	bp["reuse"] = true
	bp.description = "Groups of nodes that repeat in this project's Schematics, as macros every Schematic can use.\nMade when the project was converted; a macro is expanded where it is used, so it costs nothing at run time."
	bp.graphs[0].nodes.clear()
	return bp


func _write(path: String, bp: Dictionary) -> void:
	var c := Compiler.new()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Model.build_source(c.compile(bp), bp))
	f.close()
	R.invalidate_libraries()


# ---------------------------------------------------------------- reading a graph

func _analyse(fi: int, bp: Dictionary, g: Dictionary) -> Dictionary:
	var ga := {"fi": fi, "bp": bp, "g": g, "nodes": {}, "desc": {}, "flow": {}, "xo": {}, "xsrc": {}, "vin": {}, "vout": {}, "fan": {},
		"blocks": [], "seen": {}, "ok": true}
	for n in g.nodes:
		var id := int(n.id)
		ga.nodes[id] = n
		var d := R.describe(n, bp, g)
		ga.desc[id] = d
		for pin in d.ins + d.outs:
			if String(pin.type) == "exec":
				ga.flow[id] = true
	for w in g.wires:
		var a := int(w[0])
		var b := int(w[2])
		if not ga.nodes.has(a) or not ga.nodes.has(b):
			ga.ok = false
			return ga
		var kind := ""
		for pin in ga.desc[a].outs:
			if String(pin.id) == String(w[1]):
				kind = String(pin.type)
		if kind == "":
			ga.ok = false   # a wire from a pin the node does not have: leave this graph alone
			return ga
		if kind == "exec":
			if not ga.xo.has(a):
				ga.xo[a] = {}
			if ga.xo[a].has(String(w[1])):
				ga.ok = false
				return ga
			ga.xo[a][String(w[1])] = [b, String(w[3])]
			if not ga.xsrc.has(b):
				ga.xsrc[b] = []
			ga.xsrc[b].append(a)
		else:
			if not ga.vin.has(b):
				ga.vin[b] = {}
			ga.vin[b][String(w[3])] = [a, String(w[1])]
			if not ga.vout.has(a):
				ga.vout[a] = []
			ga.vout[a].append([String(w[1]), b, String(w[3])])
			ga.fan[a] = int(ga.fan.get(a, 0)) + 1
	for n in g.nodes:
		var id := int(n.id)
		if ga.flow.has(id) and not ga.xsrc.has(id):
			for pin in ga.xo.get(id, {}):
				_block(ga, int(ga.xo[id][pin][0]))
	return ga


## The steps that run one after another from `start`. {s: [step], leak: true when the path runs into a node
## another path already reached (two paths merging), which no group may then contain}.
func _block(ga: Dictionary, start: int) -> Dictionary:
	var blk := {"s": [], "leak": false}
	var cur := start
	while cur != -1:
		if ga.seen.has(cur):
			blk.leak = true
			break
		ga.seen[cur] = true
		var st := _statement(ga, cur)
		blk.s.append(st)
		cur = int(st.next)
	ga.blocks.append(blk)
	return blk


## One step: the node on the execution path, the value nodes that feed only it, and every step inside the
## paths it starts (its branches, its loop body), other than the one path that carries on after it.
func _statement(ga: Dictionary, id: int) -> Dictionary:
	var n: Dictionary = ga.nodes[id]
	var d: Dictionary = ga.desc[id]
	var st := {"head": id, "nodes": [id], "execs": [id], "slots": [], "sets": [], "selfs": [], "ok": true, "exit": [], "next": -1, "key": ""}
	if String(d.err) != "" or n.kind in NEVER:
		st.ok = false
	var key := _tree(ga, id, st)
	var outs := []
	var ins := 0
	for pin in d.outs:
		if String(pin.type) == "exec":
			outs.append(String(pin.id))
	for pin in d.ins:
		if String(pin.type) == "exec":
			ins += 1
	if ins != 1:
		st.ok = false
	var inner := outs
	if n.kind == "sequence" and not outs.is_empty():
		st.exit = [id, outs[-1]]
		inner = outs.slice(0, outs.size() - 1)
	elif outs.size() == 1:
		st.exit = [id, outs[0]]
		inner = []
	elif n.kind in LOOPS and outs.has("completed"):
		st.exit = [id, "completed"]
		inner = outs.filter(func(o): return o != "completed")
	for pin in inner:
		key += "{" + pin + ":"
		if ga.xo.get(id, {}).has(pin):
			var sub := _block(ga, int(ga.xo[id][pin][0]))
			if bool(sub.leak):
				st.ok = false
			for s in sub.s:
				st.nodes.append_array(s.nodes)
				st.execs.append_array(s.execs)
				st.slots.append_array(s.slots)
				st.sets.append_array(s.sets)
				st.selfs.append_array(s.selfs)
				if not bool(s.ok):
					st.ok = false
				key += String(s.key) + ";"
		key += "}"
	if not st.exit.is_empty() and ga.xo.get(id, {}).has(String(st.exit[1])):
		st.next = int(ga.xo[id][String(st.exit[1])][0])
	st.key = key.md5_text()
	return st


## The shape of a node and of the value nodes behind its inputs, as text. Literals, variable reads and values
## from outside are left out of the text (they are the `slots`, compared later): two places with the same
## text differ only in those.
func _tree(ga: Dictionary, id: int, st: Dictionary) -> String:
	var n: Dictionary = ga.nodes[id]
	var d: Dictionary = ga.desc[id]
	var p: Dictionary = n.p
	if n.kind == "local_set":
		p = p.duplicate()
		st.sets.append(String(p.get("name", "")))
		p["name"] = "?"
	var out: String = n.kind + JSON.stringify(p, "", true) + JSON.stringify(n.get("split", {}), "", true) + "("
	var wired: Dictionary = ga.vin.get(id, {})
	var known := 0
	for pin in d.ins:
		if String(pin.type) == "exec":
			continue
		var pid := String(pin.id)
		if wired.has(pid):
			known += 1
			var sid := int(wired[pid][0])
			var s: Dictionary = ga.nodes[sid]
			var slot := {"src": sid, "pin": String(wired[pid][1]), "to": id, "to_pin": pid, "type": String(pin.type), "label": String(pin.name)}
			if ga.flow.has(sid) or int(ga.fan.get(sid, 0)) > 1:
				slot["t"] = "ref"
				st.slots.append(slot)
				out += pid + "=$,"
			elif s.kind in LEAVES and not ga.vin.has(sid):
				slot["t"] = "leaf"
				st.nodes.append(sid)
				st.slots.append(slot)
				if String(ga.desc[sid].err) != "":
					st.ok = false
				out += pid + "=$,"
			else:
				st.nodes.append(sid)
				if String(ga.desc[sid].err) != "" or s.kind in NEVER:
					st.ok = false
				out += "%s=%s:%s," % [pid, String(wired[pid][1]), _tree(ga, sid, st)]
		elif String(n.d.get(pid, "")) != "":
			st.slots.append({"t": "lit", "text": String(n.d[pid]), "to": id, "to_pin": pid, "type": String(pin.type), "label": String(pin.name)})
			out += pid + "=$,"
		else:
			if bool(pin.get("self", false)):
				st.selfs.append(String(pin.type))
			out += pid + "=-,"
	if known != wired.size():
		st.ok = false   # a wire into a pin the node does not have
	return out + ")"


# ---------------------------------------------------------------- weighing a group

func _local(g: Dictionary, name: String) -> Dictionary:
	for l in g.get("locals", []):
		if String(l.name) == name:
			return l
	return {}


## One place a group occurs, laid out flat. {} when a node of it is already taken.
func _flat(occ: Array) -> Dictionary:
	var gi := int(occ[0])
	var ga: Dictionary = _gas[gi]
	var stmts: Array = ga.blocks[int(occ[1])].s.slice(int(occ[2]), int(occ[2]) + int(occ[3]))
	var f := {"gi": gi, "ga": ga, "nodes": {}, "execs": [], "slots": [], "sets": [], "selfs": [], "entry": int(stmts[0].head),
		"exit": stmts[-1].exit, "block": int(occ[1]), "at": int(occ[2]), "len": int(occ[3]), "lmap": {}, "lnames": []}
	for st in stmts:
		for id in st.nodes:
			if _used.has("%d:%d" % [gi, int(id)]):
				return {}
			f.nodes[int(id)] = true
		f.execs.append_array(st.execs)
		f.slots.append_array(st.slots)
		f.sets.append_array(st.sets)
		f.selfs.append_array(st.selfs)
	for nm in f.sets:
		if not f.lmap.has(nm):
			f.lmap[nm] = f.lnames.size()
			f.lnames.append(nm)
	return f


## What a slot holds at one place, as text. Slots that hold the same thing at every place stay inside the
## macro; the others become pins.
func _sig(f: Dictionary, slot: Dictionary) -> String:
	match String(slot.t):
		"lit":
			return "lit:" + String(slot.text)
		"leaf":
			var node: Dictionary = f.ga.nodes[int(slot.src)]
			if node.kind == "local_get":
				var nm := String(node.p.get("name", ""))
				var which := "%s:%s" % [JSON.stringify(node.get("split", {}), "", true), String(slot.pin)]
				return ("L:%d:%s" % [int(f.lmap[nm]), which]) if f.lmap.has(nm) else ("local:%s:%s" % [nm, which])
			# (where a name node's name belongs says nothing about its value: two reads of the same name are the
			# same source wherever the importer noted them)
			var what: Dictionary = node.p
			if node.kind == "const" and what.has("of"):
				what = what.duplicate()
				for key in ["of", "in", "bound", "arm"]:
					what.erase(key)
			return "leaf:%s:%s:%s:%s" % [node.kind, JSON.stringify(what, "", true), JSON.stringify(node.get("split", {}), "", true), String(slot.pin)]
	if f.nodes.has(int(slot.src)):
		return "in:%d:%s" % [f.execs.find(int(slot.src)), String(slot.pin)]
	return "ext:%d:%d:%s" % [int(f.gi), int(slot.src), String(slot.pin)]


## Execution enters only at the first node and leaves only by the last step's way on.
func _closed(f: Dictionary) -> bool:
	var ga: Dictionary = f.ga
	for id in f.execs:
		for pin in ga.xo.get(id, {}):
			if not f.nodes.has(int(ga.xo[id][pin][0])):
				if f.exit.is_empty() or int(f.exit[0]) != int(id) or String(f.exit[1]) != String(pin):
					return false
		if int(id) != int(f.entry):
			for src in ga.xsrc.get(id, []):
				if not f.nodes.has(int(src)):
					return false
	return true


## Is this group worth a macro? {} when not, else what `_apply` needs.
func _evaluate(occs: Array, shared: bool) -> Dictionary:
	var by_shape := {}
	var taken := {}   # "graph:block" -> [[from, to]], so two places never overlap
	for occ in occs:
		var f := _flat(occ)
		if f.is_empty() or not _closed(f):
			continue
		var spot := "%d:%d" % [int(f.gi), int(f.block)]
		var clash := false
		for span in taken.get(spot, []):
			if int(f.at) < int(span[1]) and int(span[0]) < int(f.at) + int(f.len):
				clash = true
		if clash:
			continue
		# the locals it sets, and which slots read them or read a node of the group: these must agree
		var shape := PackedStringArray()
		var fine := true
		for nm in f.sets:
			shape.append(str(int(f.lmap[nm])))
		for nm in f.lnames:
			var l := _local(f.ga.g, nm)
			if l.is_empty() or bool(l.get("param", false)):
				fine = false
				break
			shape.append("%s/%s/%s" % [String(l.type), str(l.get("infer", false)), String(l.get("default", ""))])
		if not fine:
			continue
		f["sigs"] = []
		for slot in f.slots:
			var sig := _sig(f, slot)
			f.sigs.append(sig)
			shape.append(sig if (sig.begins_with("in:") or sig.begins_with("L:")) else "x")
			# a value that comes from, or goes to, nodes another macro has taken: leave it
			if sig.begins_with("ext:") and _used.has("%d:%d" % [int(f.gi), int(slot.src)]):
				fine = false
		for id in f.execs:
			for vo in f.ga.vout.get(id, []):
				if not f.nodes.has(int(vo[1])) and _used.has("%d:%d" % [int(f.gi), int(vo[1])]):
					fine = false
		if not fine:
			continue
		var sk := "|".join(shape)
		if not by_shape.has(sk):
			by_shape[sk] = []
		by_shape[sk].append(f)
		if not taken.has(spot):
			taken[spot] = []
		taken[spot].append([int(f.at), int(f.at) + int(f.len)])
	var flats := []
	for sk in by_shape:
		if by_shape[sk].size() > flats.size():
			flats = by_shape[sk]
	if flats.size() < 2:
		return {}
	var ref: Dictionary = flats[0]
	if shared:
		var paths := {}
		for f in flats:
			paths[int(f.ga.fi)] = true
		if paths.size() < 2:
			return {}
		for id in ref.nodes:
			var node: Dictionary = ref.ga.nodes[int(id)]
			if node.kind in OWN and not node.kind in LEAVES:
				return {}
			if node.kind == "macro" and String(node.p.get("lib", "")) == "":
				return {}
		for cls in ref.selfs:
			if not T.is_a("Node", String(cls)):
				return {}   # uses the Schematic it is in as a more particular class than every Schematic is

	# pins: the slots that do not hold the same thing everywhere
	var pins := []
	for si in ref.slots.size():
		var first := String(ref.sigs[si])
		if first.begins_with("in:") or first.begins_with("L:"):
			continue
		var inside := not (first.begins_with("ext:") or first.begins_with("local:"))
		var vector := PackedStringArray()
		for f in flats:
			vector.append(String(f.sigs[si]))
			if String(f.sigs[si]) != first:
				inside = false
		if inside and shared and first.begins_with("leaf:"):
			var node: Dictionary = ref.ga.nodes[int(ref.slots[si].src)]
			if node.kind == "var_get" or (node.kind == "const" and not _global_const(String(node.p.get("expr", "")))):
				inside = false
		if inside:
			continue
		# Slots fed by the same thing at every place share a pin. Typed-in values only share one between pins
		# of the same type; a variable or a wire also when one of the two pins takes anything.
		var stype := String(ref.slots[si].type)
		var open := stype == "any" or stype == ""
		var typed_in := false
		for sig in vector:
			if sig.begins_with("lit:"):
				typed_in = true
		var joined := "\u0001".join(vector)
		var found := -1
		for pi in pins.size():
			if String(pins[pi].vector) != joined:
				continue
			var ptype := String(pins[pi].type)
			if ptype == stype or (not typed_in and (open or ptype == "any" or ptype == "")):
				found = pi
				break
		if found != -1:
			pins[found].slots.append(si)
			if not open and String(pins[found].type) in ["any", ""]:
				pins[found].type = stype
				pins[found].label = String(ref.slots[si].label)
		else:
			pins.append({"slots": [si], "type": stype, "label": String(ref.slots[si].label), "vector": joined})
	if pins.size() > max_pins:
		return {}

	# values other nodes read from the group
	var outs := {}
	for f in flats:
		for ei in f.execs.size():
			for vo in f.ga.vout.get(f.execs[ei], []):
				if not f.nodes.has(int(vo[1])):
					outs["%d:%s" % [ei, String(vo[0])]] = [ei, String(vo[0])]
	if outs.size() > max_outs:
		return {}

	# what it saves
	var before := 0
	var after := 0
	var pin_leaves := 0
	for f in flats:
		before += f.nodes.size()
		var kept := 0
		for pin in pins:
			if String(f.slots[int(pin.slots[0])].t) == "leaf":
				kept += 1
		after += 1 + kept
	for pin in pins:
		for si in pin.slots:
			if String(ref.slots[int(si)].t) == "leaf":
				pin_leaves += 1
	var body: int = ref.nodes.size() - pin_leaves
	after += body + 2
	if body < min_body or before - after < min_save or pins.size() >= body:
		return {}
	# few nodes behind many pins is no easier to read than the nodes were
	if pins.size() * 2 > body and flats.size() < 5:
		return {}
	if ref.execs.size() < 2 and body < 6:
		return {}
	return {"occs": occs, "flats": flats, "pins": pins, "outs": outs.values(), "save": before - after, "body": body, "shared": shared}


## A constant every Schematic can name: `Class.NAME` of an engine class, or an engine-wide one.
func _global_const(text: String) -> bool:
	if _globals.has(text):
		return bool(_globals[text])
	var known: bool = T.globals().has(text.get_slice(".", 0))
	if not known:
		# engine classes and engine-wide constants are names an expression can work out with nothing to stand on
		var probe := Expression.new()
		if probe.parse(text) == OK:
			probe.execute([], null, false)
			known = not probe.has_execute_failed()
	_globals[text] = known
	return known


# ---------------------------------------------------------------- making the macro

func _pascal(s: String) -> String:
	var out := ""
	for part in T.ident(s).split("_", false):
		out += part[0].to_upper() + part.substr(1)
	return out


## A name for the macro, from what its first steps do.
func _name(f: Dictionary, taken: Array) -> String:
	var labels := []
	var worked := []
	var guard := ""
	for id in f.nodes:
		var vn: Dictionary = f.ga.nodes[int(id)]
		if vn.kind in ["call", "dyn_call"] and String(vn.p.get("method", "")) == "has_method":
			guard = "IfPresent"
	var first: Dictionary = f.ga.nodes[int(f.execs[0])]
	if first.kind == "sequence" and f.execs.size() > 1:
		first = f.ga.nodes[int(f.execs[1])]
	if guard == "" and first.kind == "branch":
		var cond: Array = f.ga.vin.get(int(first.id), {}).get("cond", [])
		if not cond.is_empty():
			var cn: Dictionary = f.ga.nodes[int(cond[0])]
			var checks := [cn]
			if cn.kind == "math" and String(cn.p.get("op", "")) == "and":
				for w in f.ga.vin.get(int(cn.id), {}).values():
					checks.append(f.ga.nodes[int(w[0])])
			for ch in checks:
				if (ch.kind == "math" and String(ch.p.get("op", "")) == "!=" and String(ch.d.get("a1", "")) == "null") \
						or (ch.kind == "util" and String(ch.p.get("name", "")) == "is_instance_valid"):
					guard = "IfValid"
	for id in f.execs:
		var n: Dictionary = f.ga.nodes[int(id)]
		var p: Dictionary = n.p
		var label := ""
		match n.kind:
			"call", "bcall":
				label = _pascal(String(p.get("method", "")))
				if not String(p.get("method", "")).contains("_") and String(p.get("cls", p.get("type", ""))) != "":
					label += _pascal(String(p.get("cls", p.get("type", ""))))
			"dyn_call", "message": label = _pascal(String(p.get("method", p.get("name", "Call"))))
			"await_value":
				label = "Wait"
				var awaited: Array = f.ga.vin.get(int(id), {}).get("v", [])
				if not awaited.is_empty() and f.ga.nodes[int(awaited[0])].kind == "dyn_get":
					label = "WaitFor" + _pascal(String(f.ga.nodes[int(awaited[0])].p.get("name", "")))
			"call_self": label = _pascal(String(p.get("fn", "")))
			"util": label = _pascal(String(p.get("name", "")))
			"set_prop": label = "Set" + _pascal(String(p.get("prop", "")))
			"dyn_set": label = "Set" + _pascal(String(p.get("name", "")))
			"var_set": label = "Set" + _pascal(String(p.get("name", "")))
			"new": label = "New" + _pascal(String(p.get("cls", "")))
			"macro": label = _pascal(String(p.get("name", "")))
			"tpl": label = _pascal(String(p.get("id", "")))
			"emit": label = "Emit" + _pascal(String(p.get("name", "")))
			"local_set":
				if String(p.get("op", "")) == "" and String(p.get("part", "")) == "" and not worked.has(_pascal(String(p.get("name", "")))):
					worked.append(_pascal(String(p.get("name", ""))))
		if label in ["CallNode", "CallObject", "Call"] or label.begins_with("CallNode"):
			label = "Call"
		if label != "" and not labels.has(label):
			labels.append(label)
	if labels.is_empty():
		# nothing but working values out: named after the locals it fills in
		for i in worked.size():
			labels.append(("WorkOut" if i == 0 else "") + String(worked[i]))
	if labels.is_empty():
		labels.append("Steps")
	# as many of the labels as it takes to tell it from the macros there already are
	var name := ""
	for count in range(mini(2, labels.size()), mini(4, labels.size()) + 1):
		name = "And".join(labels.slice(0, count)) + guard
		if count == 2 and name.length() > 40:
			name = String(labels[0]) + guard
		if not taken.has(name):
			return name
	return Model.unique_name(name, taken)


## The name of the variable that feeds this slot at more than half of the places, "" when there is none.
func _fed_by(flats: Array, si: int) -> String:
	var votes := {}
	for f in flats:
		var slot: Dictionary = f.slots[si]
		if String(slot.t) == "lit":
			continue
		var src: Dictionary = f.ga.nodes[int(slot.src)]
		var nm := ""
		if src.kind in ["local_get", "var_get"]:
			nm = String(src.p.get("name", ""))
		elif String(slot.pin).begins_with("p_"):
			nm = String(slot.pin).trim_prefix("p_")
		if nm != "":
			votes[nm] = int(votes.get(nm, 0)) + 1
	for nm in votes:
		if int(votes[nm]) * 2 > flats.size():
			return _pascal(nm)
	return ""


func _apply(c: Dictionary, target: Dictionary, lib_path: String) -> void:
	var flats: Array = c.flats
	var ref: Dictionary = flats[0]
	var name := _name(ref, Model.member_names(target))
	var mg := Model.new_graph(target, name, "macro")
	mg["reuse"] = true
	var m_in: Dictionary = mg.nodes[0]
	var m_out: Dictionary = mg.nodes[1]

	# pins and outputs get names
	var taken := ["In", "Out"]
	for pin in c.pins:
		var base := _fed_by(flats, int(pin.slots[0]))
		if base == "":
			base = _pascal(String(pin.label))
		if base == "":
			base = _pascal(String(ref.slots[int(pin.slots[0])].to_pin))
		if base == "" or (base.length() == 2 and base[0] in ["A", "V", "E"] and base[1].is_valid_int()):
			base = "Value"
			# a value written on the pin at every place: named after what kind of value it is
			var first: Dictionary = ref.slots[int(pin.slots[0])]
			if String(first.t) == "lit":
				var text := String(first.text).strip_edges()
				if text.begins_with("\"") or text.begins_with("&\"") or text.begins_with("^\""):
					base = "Text"
				elif text.is_valid_float():
					base = "Number"
				elif text in ["true", "false"]:
					base = "Flag"
		pin["name"] = Model.unique_name(base, taken)
		taken.append(pin.name)
		mg.inputs.append([pin.name, pin.type if String(pin.type) != "" else "any"])
	var out_names := {}
	for o in c.outs:
		var src: Dictionary = ref.ga.nodes[int(ref.execs[int(o[0])])]
		var otype := "any"
		for pin in ref.ga.desc[int(src.id)].outs:
			if String(pin.id) == String(o[1]):
				otype = String(pin.type)
		var base := _pascal(String(o[1]).trim_prefix("r_").trim_prefix("p_"))
		if base == "" or base == "Ret":
			base = "Result"
		var oname := Model.unique_name(base, taken)
		taken.append(oname)
		out_names["%d:%s" % [int(o[0]), String(o[1])]] = oname
		mg.outputs.append([oname, otype])

	# the body: the first place's nodes, without the ones that feed pins
	var pin_of := {}    # slot index -> pin
	var feeders := {}   # leaf node id (first place) that stays outside
	for pin in c.pins:
		for si in pin.slots:
			pin_of[int(si)] = pin
			if String(ref.slots[int(si)].t) == "leaf":
				feeders[int(ref.slots[int(si)].src)] = true
	var remap := {}
	var low := Vector2(INF, INF)
	var high := -INF
	var g0: Dictionary = ref.ga.g
	for n in g0.nodes:
		var id := int(n.id)
		if not ref.nodes.has(id) or feeders.has(id):
			continue
		var copy: Dictionary = n.duplicate(true)
		Model.forget_place(copy)   # inside a macro a name is just a name
		copy.id = int(mg.next_id)
		mg.next_id = int(mg.next_id) + 1
		remap[id] = int(copy.id)
		mg.nodes.append(copy)
		low = Vector2(minf(low.x, float(n.x)), minf(low.y, float(n.y)))
		high = maxf(high, float(n.x))
	for n in mg.nodes:
		if n.kind in ["macro_in", "macro_out"]:
			continue
		n.x = float(n.x) - low.x + 400.0
		n.y = float(n.y) - low.y + 120.0
	m_out.x = high - low.x + 400.0 + 330.0
	for w in g0.wires:
		if remap.has(int(w[0])) and remap.has(int(w[2])):
			mg.wires.append([remap[int(w[0])], w[1], remap[int(w[2])], w[3]])
	var entry_pin := "exec"
	for pin in ref.ga.desc[int(ref.entry)].ins:
		if String(pin.type) == "exec":
			entry_pin = String(pin.id)
	mg.wires.append([int(m_in.id), "i_In", remap[int(ref.entry)], entry_pin])
	if not ref.exit.is_empty():
		mg.wires.append([remap[int(ref.exit[0])], String(ref.exit[1]), int(m_out.id), "o_Out"])
	for si in pin_of:
		var slot: Dictionary = ref.slots[int(si)]
		var inner: Dictionary = Model.find_node(mg, remap[int(slot.to)])
		inner.d.erase(String(slot.to_pin))
		mg.wires.append([int(m_in.id), "i_" + T.ident(String(pin_of[si].name)), int(inner.id), String(slot.to_pin)])
	for key in out_names:
		var o: Array = [int(String(key).get_slice(":", 0)), String(key).substr(String(key).find(":") + 1)]
		mg.wires.append([remap[int(ref.execs[int(o[0])])], String(o[1]), int(m_out.id), "o_" + T.ident(String(out_names[key]))])
	for nm in ref.lnames:
		mg.locals.append(_local(g0, nm).duplicate(true))

	# every place: one macro node instead of the group
	for f in flats:
		_replace(f, c, name, lib_path, out_names)
	notes.append("%s%s: %d nodes, %d pins, used %d times, %d nodes fewer" % ["shared " if bool(c.shared) else "", name, int(c.body), c.pins.size(), flats.size(), int(c.save)])


func _replace(f: Dictionary, c: Dictionary, name: String, lib_path: String, out_names: Dictionary) -> void:
	var ga: Dictionary = f.ga
	var g: Dictionary = ga.g
	var head: Dictionary = ga.nodes[int(f.entry)]
	var p := {"name": name}
	if lib_path != "":
		p["lib"] = lib_path
	if not f.lnames.is_empty():
		var names := {}
		var ref: Dictionary = c.flats[0]
		for i in f.lnames.size():
			names[String(ref.lnames[i])] = String(f.lnames[i])
		p["names"] = names
	var mnode := Model.add_node(g, "macro", Vector2(float(head.x), float(head.y)), p)
	var mid := int(mnode.id)
	var gone: Dictionary = f.nodes.duplicate()
	var add := []
	var row := 0
	for pin in c.pins:
		var slot: Dictionary = f.slots[int(pin.slots[0])]
		var pid := "i_" + T.ident(String(pin.name))
		match String(slot.t):
			"lit":
				mnode.d[pid] = String(slot.text)
			"leaf":
				gone.erase(int(slot.src))
				var leaf: Dictionary = ga.nodes[int(slot.src)]
				leaf.x = float(head.x) - 40.0
				leaf.y = float(head.y) + 170.0 + 64.0 * row
				row += 1
				add.append([int(slot.src), String(slot.pin), mid, pid])
			_:
				add.append([int(slot.src), String(slot.pin), mid, pid])
	var kept := []
	var next_id := -1
	var entry_pin := "exec"
	for pin in ga.desc[int(f.entry)].ins:
		if String(pin.type) == "exec":
			entry_pin = String(pin.id)
	for w in g.wires:
		var a_in := gone.has(int(w[0]))
		var b_in := gone.has(int(w[2]))
		if a_in and b_in:
			continue
		if not a_in and not b_in:
			kept.append(w)
		elif b_in:
			# into the group: execution goes to the macro's In; value wires were handled as pins
			if int(w[2]) == int(f.entry) and String(w[3]) == entry_pin:
				kept.append([w[0], w[1], mid, "i_In"])
		else:
			if not f.exit.is_empty() and int(w[0]) == int(f.exit[0]) and String(w[1]) == String(f.exit[1]):
				kept.append([mid, "o_Out", w[2], w[3]])
				next_id = int(w[2])
			else:
				var key := "%d:%s" % [f.execs.find(int(w[0])), String(w[1])]
				if out_names.has(key):
					kept.append([mid, "o_" + T.ident(String(out_names[key])), w[2], w[3]])
	kept.append_array(add)
	g.wires = kept
	for i in range(g.nodes.size() - 1, -1, -1):
		if gone.has(int(g.nodes[i].id)):
			g.nodes.remove_at(i)
	# close the gap the group leaves: what runs after it moves up to the macro node
	if next_id != -1:
		var after := Model.find_node(g, next_id)
		var shift: float = float(after.x) - (float(head.x) + 330.0)
		if shift > 1.0:
			_shift(g, next_id, mid, shift)


## Moves everything that runs from `start` on (and the value nodes feeding those nodes) left by `dx`.
func _shift(g: Dictionary, start: int, stop: int, dx: float) -> void:
	var forward := {}
	var feeds := {}
	for w in g.wires:
		if not forward.has(int(w[0])):
			forward[int(w[0])] = []
		forward[int(w[0])].append(int(w[2]))
		if not feeds.has(int(w[2])):
			feeds[int(w[2])] = []
		feeds[int(w[2])].append(int(w[0]))
	var moved := {stop: true}
	for w in g.wires:
		if int(w[2]) == stop:
			moved[int(w[0])] = true   # what feeds the macro node stays with it
	var todo := [start]
	while not todo.is_empty():
		var id: int = todo.pop_back()
		if moved.has(id):
			continue
		moved[id] = true
		var n := Model.find_node(g, id)
		if n.is_empty():
			continue
		n.x = float(n.x) - dx
		todo.append_array(forward.get(id, []))
		for src in feeds.get(id, []):
			var s := Model.find_node(g, int(src))
			# value nodes to the right of where the group started belong to what follows
			if not s.is_empty() and not moved.has(int(src)) and float(s.x) > float(Model.find_node(g, stop).x):
				todo.append(int(src))
