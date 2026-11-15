extends SceneTree
## Measures how far the converter is from a fixed point, i.e. whether reading its own output gives it back.
##
##   source  --convert-->  graph1  --compile-->  code1
##   code1   --convert-->  graph2  --compile-->  code2
##   code2   --convert-->  graph3  --compile-->  code3
##
## Per input: code1 and code2 load; code2 == code1 (text); canonical(graph2) == canonical(graph1) (graph);
## code3 == code2 (the round settles); code2 offers what code1 offers (interface); the second conversion keeps
## no more lines as code nodes than the first. A failing text or graph check prints what differs and why
## (a CATEGORY). The test MEASURES: it is expected to fail today, always exits 0, and is not a standing check.
##
## Inputs: every sample in tests/convert/ (as written and with Windows line endings) and the code of the
## repository's own demo schematics (the code the compiler gives for the graph stored in each file).
##
## The canonical form of a graph (what the graph check compares) is: the schematic's header (parent, class
## name, tool flag, description, variables in order, signals, enums) without the line-ending flag; per graph
## (found by name and kind, so the order of the graph list does not matter) its header (inputs, outputs, pure,
## lambda ...), its locals sorted by name, and its nodes, each as kind + p + the literal defaults (d) of the pins
## that nothing is wired to. Node ids, positions, zoom/scroll, comment sizes and empty defaults are ignored;
## they are layout or bookkeeping. Reroute nodes are layout too: a wire through reroutes is the direct wire. The
## nodes are compared as a multiset by repeatedly mixing each node's label with the labels of its neighbours
## (through pin names) until the grouping settles, and the sorted labels plus the sorted wires are the form.
##
##   godot --headless --path . --script res://tests/test_fixed_point.gd [-- --only=<name> --show]
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Checks := preload("res://tests/convert_checks.gd")

const DIR := "res://tests/convert/"
const DEMO_DIRS := ["res://demo/", "res://demo/game/", "res://demo/arcade/", "res://demo/machine/", "res://demo/data/"]
const MAX_SHOWN := 12
## graph keys that are layout or bookkeeping, not part of what a graph is
const GRAPH_SKIP := ["id", "next_id", "nodes", "wires", "zoom", "sx", "sy", "locals"]

var checks := Checks.new()
var word := RegEx.create_from_string("[A-Za-z_][A-Za-z_0-9]*|[0-9][0-9_.xXa-fA-F]*|\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|\\S")
var decl_init := RegEx.create_from_string("^((?:static\\s+)?(?:var|const)\\s+\\w+)\\s*(?::\\s*[^=]*?)?\\s*:?=\\s*")
var decl_bare := RegEx.create_from_string("^((?:static\\s+)?var\\s+\\w+)\\s*:\\s*[\\w\\.\\[\\], ]+$")
var for_var := RegEx.create_from_string("\\bfor\\s+(\\w+)\\s+in\\b")
var func_name := RegEx.create_from_string("(?m)^\\s*(?:static\\s+)?func\\s+(\\w+)")
var counted_name := RegEx.create_from_string("^(.*?)_(\\d+)$")

var fails := 0
var n_inputs := 0
var n_text := 0
var n_graph := 0
var n_settled := 0
## category -> {inputs, lines, nodes}
var table := {}
## per-input category -> {lines, nodes, note}
var found := {}


func check(label: String, ok: bool, detail := "") -> void:
	print("  %s  %s%s" % ["PASS" if ok else "FAIL", label, ("  " + detail) if (detail != "" and not ok) else ""])
	if not ok:
		fails += 1


# ------------------------------------------------------------------------------------- canonical form

## Integral floats become ints (JSON turns every number into a float), keys are sorted by stringify.
func norm(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if (not is_inf(v) and not is_nan(v) and v == floorf(v) and absf(v) < 1e15) else v
		TYPE_ARRAY:
			return (v as Array).map(func(x): return norm(x))
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[k] = norm(v[k])
			return out
	return v


func js(v: Variant) -> String:
	return JSON.stringify(norm(v), "", true)


## Wires with the reroute nodes taken out: [[from, from_pin, to, to_pin], ...] between real nodes only.
func direct_wires(g: Dictionary) -> Array:
	var kind := {}
	for n in g.get("nodes", []):
		kind[int(n.id)] = String(n.kind)
	var into := {}   # "node:pin" -> [from, from_pin] (reroutes only)
	for w in g.get("wires", []):
		if kind.get(int(w[2]), "") == "reroute":
			into["%d:%s" % [int(w[2]), String(w[3])]] = [int(w[0]), String(w[1])]
	var out := []
	for w in g.get("wires", []):
		if kind.get(int(w[2]), "") == "reroute":
			continue
		var from := [int(w[0]), String(w[1])]
		var guard := 0
		while kind.get(from[0], "") == "reroute" and guard < 200:
			guard += 1
			var key := "%d:i" % from[0]
			if not into.has(key):
				from = []
				break
			from = into[key]
		if from.is_empty() or kind.get(from[0], "") == "reroute":
			continue
		out.append([from[0], from[1], int(w[2]), String(w[3])])
	return out


## {"key": "name|kind", "head": String, "sigs": {id: readable signature}, "hash": String, "kinds": {kind: n},
##  "labels": [String], "edges": [String]} for one graph.
func canon_graph(g: Dictionary, ctx := {}, second := false) -> Dictionary:
	var head := {}
	for k in g:
		if not k in GRAPH_SKIP:
			head[k] = g[k]
	var locals := (g.get("locals", []) as Array).map(func(l): return _nl(js(l), ctx, second))
	locals.sort()
	var wires := direct_wires(g)
	var wired := {}
	for w in wires:
		wired["%d:%s" % [w[2], w[3]]] = true
	var sigs := {}
	var kinds := {}
	for n in g.get("nodes", []):
		var k := String(n.kind)
		if k == "reroute":
			continue
		var p: Dictionary = (n.get("p", {}) as Dictionary).duplicate()
		if k == "comment":
			p.erase("w")
			p.erase("h")
		var d := {}
		for pin in (n.get("d", {}) as Dictionary):
			if wired.has("%d:%s" % [int(n.id), String(pin)]) or str(n.d[pin]) == "":
				continue
			d[pin] = n.d[pin]
		sigs[int(n.id)] = _nl("%s %s%s" % [k, js(p), (" d" + js(d)) if not d.is_empty() else ""], ctx, second)
		kinds[k] = int(kinds.get(k, 0)) + 1
	# mix every node's label with its neighbours' until the grouping of nodes into equal labels stops changing
	var label := {}
	for id in sigs:
		label[id] = String(sigs[id]).md5_text()
	var groups := _group_count(label)
	for round in 60:
		var nxt := {}
		var around := {}
		for id in sigs:
			around[id] = []
		for w in wires:
			if around.has(w[0]) and around.has(w[2]):
				around[w[0]].append("o %s>%s %s" % [w[1], w[3], label[w[2]]])
				around[w[2]].append("i %s<%s %s" % [w[3], w[1], label[w[0]]])
		for id in sigs:
			var parts: Array = around[id]
			parts.sort()
			nxt[id] = (String(label[id]) + "|".join(parts)).md5_text()
		label = nxt
		var now := _group_count(label)
		if now == groups and round >= 2:
			break
		groups = now
	var labels := []
	for id in label:
		labels.append(label[id])
	labels.sort()
	var edges := []
	for w in wires:
		if label.has(w[0]) and label.has(w[2]):
			edges.append("%s.%s>%s.%s" % [label[w[0]], w[1], label[w[2]], w[3]])
	edges.sort()
	locals.append(_nl(js(head), ctx, second))
	return {"key": "%s|%s" % [g.get("name", ""), g.get("kind", "")], "head": "\n".join(locals), "sigs": sigs, "kinds": kinds,
		"hash": ("\n".join(labels) + "#" + "\n".join(edges)).md5_text(), "n": sigs.size(), "wires": wires.size()}


func _group_count(label: Dictionary) -> int:
	var seen := {}
	for id in label:
		seen[label[id]] = true
	return seen.size()


## With a naming context the text of a signature has its naming undone (see norm_line); without, as it is.
func _nl(s: String, ctx: Dictionary, second: bool) -> String:
	return s if ctx.is_empty() else String(norm_line(s, ctx, second)[0])


func canon(bp: Dictionary, ctx := {}, second := false) -> Dictionary:
	var head := bp.duplicate()
	head.erase("graphs")
	head.erase("crlf")
	var head_text := _nl(js(head), ctx, second)
	var graphs := {}
	for g in bp.get("graphs", []):
		var c := canon_graph(g, ctx, second)
		var key: String = c.key
		var extra := 2
		while graphs.has(key):
			key = "%s#%d" % [c.key, extra]
			extra += 1
		graphs[key] = c
	return {"head": head_text, "graphs": graphs}


func same_canon(a: Dictionary, b: Dictionary) -> bool:
	if a.head != b.head or a.graphs.size() != b.graphs.size():
		return false
	for k in a.graphs:
		if not b.graphs.has(k) or a.graphs[k].head != b.graphs[k].head or a.graphs[k].hash != b.graphs[k].hash:
			return false
	return true


## How the second graph differs from the first, as short lines: [text, ...], and the node kinds that changed:
## {lost: {kind: n}, gained: {kind: n}, params: n}
func graph_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var lines := []
	var lost := {}
	var gained := {}
	var params := 0
	if a.head != b.head:
		var ha: Dictionary = JSON.parse_string(a.head)
		var hb: Dictionary = JSON.parse_string(b.head)
		for k in ha:
			if js(ha[k]) != js(hb.get(k, null)):
				lines.append("header %s: %s  ->  %s" % [k, _cut(js(ha[k])), _cut(js(hb.get(k, null)))])
		for k in hb:
			if not ha.has(k):
				lines.append("header %s: (none)  ->  %s" % [k, _cut(js(hb[k]))])
	for k in a.graphs:
		if not b.graphs.has(k):
			lines.append("graph %s only in the first" % k)
			continue
		var ga: Dictionary = a.graphs[k]
		var gb: Dictionary = b.graphs[k]
		if ga.head != gb.head:
			var la: PackedStringArray = ga.head.split("\n")
			var lb: PackedStringArray = gb.head.split("\n")
			for x in la:
				if not x in lb:
					lines.append("graph %s: - %s" % [k, _cut(x)])
			for x in lb:
				if not x in la:
					lines.append("graph %s: + %s" % [k, _cut(x)])
		var ca := {}
		for id in ga.sigs:
			ca[ga.sigs[id]] = int(ca.get(ga.sigs[id], 0)) + 1
		var cb := {}
		for id in gb.sigs:
			cb[gb.sigs[id]] = int(cb.get(gb.sigs[id], 0)) + 1
		var only_a := []
		var only_b := []
		for s in ca:
			for i in int(ca[s]) - int(cb.get(s, 0)):
				only_a.append(s)
		for s in cb:
			for i in int(cb[s]) - int(ca.get(s, 0)):
				only_b.append(s)
		for s in only_a:
			lines.append("graph %s: - node %s" % [k, _cut(s)])
		for s in only_b:
			lines.append("graph %s: + node %s" % [k, _cut(s)])
		var ka: Dictionary = ga.kinds
		var kb: Dictionary = gb.kinds
		for kind in ka:
			if int(ka[kind]) > int(kb.get(kind, 0)):
				lost[kind] = int(lost.get(kind, 0)) + int(ka[kind]) - int(kb.get(kind, 0))
		for kind in kb:
			if int(kb[kind]) > int(ka.get(kind, 0)):
				gained[kind] = int(gained.get(kind, 0)) + int(kb[kind]) - int(ka.get(kind, 0))
		if only_a.size() != 0 or only_b.size() != 0:
			params += maxi(only_a.size(), only_b.size())
		if only_a.is_empty() and only_b.is_empty() and ga.hash != gb.hash:
			lines.append("graph %s: same nodes, wired differently (%d and %d wires)" % [k, ga.wires, gb.wires])
	for k in b.graphs:
		if not a.graphs.has(k):
			lines.append("graph %s only in the second" % k)
	return {"lines": lines, "lost": lost, "gained": gained, "params": params}


func _cut(s: String, n := 150) -> String:
	return s if s.length() <= n else s.substr(0, n) + "..."


# ------------------------------------------------------------------------------------- text difference

## Hunks of changed lines between two scripts: [{a: [[line, text]], b: [[line, text]]}, ...].
## `raw_a` and `raw_b` (the lines as written, when a and b are normalised forms of them) are what the hunks
## hold; `matched` is filled with [i, j] for every pair of lines found equal.
func diff_lines(a: PackedStringArray, b: PackedStringArray, raw_a := PackedStringArray(), raw_b := PackedStringArray(), matched := []) -> Array:
	if raw_a.is_empty():
		raw_a = a
		raw_b = b
	var lo := 0
	while lo < a.size() and lo < b.size() and a[lo] == b[lo]:
		matched.append([lo, lo])
		lo += 1
	var ea := a.size()
	var eb := b.size()
	while ea > lo and eb > lo and a[ea - 1] == b[eb - 1]:
		ea -= 1
		eb -= 1
		matched.append([ea, eb])
	var n := ea - lo
	var m := eb - lo
	var hunks := []
	if n == 0 and m == 0:
		return hunks
	if n * m > 2500000:
		return [_hunk(a, b, raw_a, raw_b, lo, ea, lo, eb)]
	# longest common subsequence of the middle
	var w := m + 1
	var t := PackedInt32Array()
	t.resize((n + 1) * w)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a[lo + i] == b[lo + j]:
				t[i * w + j] = t[(i + 1) * w + j + 1] + 1
			else:
				t[i * w + j] = maxi(t[(i + 1) * w + j], t[i * w + j + 1])
	var i := 0
	var j := 0
	var si := 0
	var sj := 0
	while i < n or j < m:
		if i < n and j < m and a[lo + i] == b[lo + j]:
			matched.append([lo + i, lo + j])
			if si < i or sj < j:
				hunks.append(_hunk(a, b, raw_a, raw_b, lo + si, lo + i, lo + sj, lo + j))
			i += 1
			j += 1
			si = i
			sj = j
		elif j < m and (i == n or t[i * w + j + 1] >= t[(i + 1) * w + j]):
			j += 1
		else:
			i += 1
	if si < n or sj < m:
		hunks.append(_hunk(a, b, raw_a, raw_b, lo + si, lo + n, lo + sj, lo + m))
	return hunks


## Lines of a hunk are [line number, line as written, normalised line].
func _hunk(a: PackedStringArray, b: PackedStringArray, raw_a: PackedStringArray, raw_b: PackedStringArray, a0: int, a1: int, b0: int, b1: int) -> Dictionary:
	var ra := []
	for i in range(a0, a1):
		ra.append([i + 1, raw_a[i], a[i]])
	var rb := []
	for j in range(b0, b1):
		rb.append([j + 1, raw_b[j], b[j]])
	return {"a": ra, "b": rb}


func toks(s: String) -> Array:
	var out := []
	for m in word.search_all(s):
		out.append(m.get_string())
	return out


func without_brackets(t: Array) -> Array:
	return t.filter(func(x): return x != "(" and x != ")")


func decl_norm(s: String) -> String:
	var m := decl_init.search(s)
	if m != null:
		return m.get_string(1) + " = " + s.substr(m.get_end())
	var m2 := decl_bare.search(s)
	if m2 != null:
		return m2.get_string(1)
	return s


func jaccard(x: Array, y: Array) -> float:
	var sx := {}
	for t in x:
		sx[t] = true
	var both := 0
	var sy := {}
	for t in y:
		if not sy.has(t) and sx.has(t):
			both += 1
		sy[t] = true
	var total := sx.size() + sy.size() - both
	return 1.0 if total == 0 else float(both) / float(total)


## Which categories explain how line `y` (second script) differs from line `x` (first). Returns [[category, note], ...].
func classify_pair(x: String, y: String, ctx: Dictionary) -> Array:
	var raw_x := x.strip_edges()
	var raw_y := y.strip_edges()
	var cats := []
	var nxr := norm_line(raw_x, ctx)
	var nyr := norm_line(raw_y, ctx, true)
	for c in nxr[1] + nyr[1]:
		if not cats.any(func(k): return k[0] == c[0]):
			cats.append(c)
	# a loop variable counts only when the two lines name it differently (`i_14` and `i_15`)
	var loops_x := toks(raw_x).filter(func(t): return ctx.loops.has(t))
	var loops_y := toks(raw_y).filter(func(t): return ctx.loops.has(t))
	if loops_x != loops_y:
		var shown_pair := "?"
		for i in mini(loops_x.size(), loops_y.size()):
			if loops_x[i] != loops_y[i]:
				shown_pair = "%s -> %s" % [loops_x[i], loops_y[i]]
				break
		cats.append(["loop-variable-name", shown_pair])
	x = nxr[0]
	y = nyr[0]
	if x == y:
		return cats if not cats.is_empty() else [["indentation", ""]]
	var nx := decl_norm(x)
	var ny := decl_norm(y)
	if nx != x or ny != y:
		var before := x.substr(0, x.find("=") + 1) if x.contains("=") else x
		var after := y.substr(0, y.find("=") + 1) if y.contains("=") else y
		if before != after and nx.get_slice(" ", 1) == ny.get_slice(" ", 1):   # the same variable, declared another way
			cats.append(["declaration-form", "%s  ->  %s" % [_cut(before, 60), _cut(after, 60)]])
		x = nx
		y = ny
	var tx := toks(x)
	var ty := toks(y)
	if tx == ty:
		return cats
	var bx := without_brackets(tx)
	var by := without_brackets(ty)
	if bx == by:
		cats.append(["brackets", ""])
		return cats
	# lambdas: an inline `func(` somewhere that is not the start of a declaration
	var lx := _has_lambda(tx)
	var ly := _has_lambda(ty)
	if lx != ly or (lx and ly and bx.size() != by.size()):
		cats.append(["lambda-form", ""])
		return cats
	if tx.size() > 0 and ty.size() > 0 and (tx[0] == "match" or ty[0] == "match"):
		cats.append(["match-form", ""])
		return cats
	if bx.count("as") != by.count("as"):
		cats.append(["cast-form", "%s  ->  %s" % [_cut(x, 80), _cut(y, 80)]])
		return cats
	if tx.size() > 0 and tx[0] == "for" and ty.size() > 0 and ty[0] == "for" and bx.size() == by.size():
		cats.append(["loop-variable-type", "%s  ->  %s" % [_cut(x, 80), _cut(y, 80)]])
		return cats
	if bx.size() == by.size():
		var other := false
		var seen := {}
		for i in bx.size():
			if bx[i] == by[i]:
				continue
			var a: String = bx[i]
			var b: String = by[i]
			var ident_a := a.is_valid_identifier()
			var ident_b := b.is_valid_identifier()
			if ident_a and ident_b:
				var c := classify_ident(a, b, ctx)
				if not seen.has(c[0] + a + b):
					seen[c[0] + a + b] = true
					cats.append(c)
			else:
				other = true
		if other:
			cats.append(["other", "%s  ->  %s" % [_cut(x, 90), _cut(y, 90)]])
		return cats
	cats.append(["other", "%s  ->  %s" % [_cut(x, 90), _cut(y, 90)]])
	return cats


func _has_lambda(t: Array) -> bool:
	for i in t.size():
		if t[i] == "func" and i > 0 and not (t[i - 1] in ["static"]):
			return true
	return false


func classify_ident(a: String, b: String, ctx: Dictionary) -> Array:
	var note := "%s -> %s" % [a, b]
	for e in ctx.events:
		if b == a + "_" + e:
			return ["event-local-suffix", note]
	if ctx.loops.has(a) or ctx.loops.has(b):
		return ["loop-variable-name", note]
	if a.begins_with("awaited_") or b.begins_with("awaited_"):
		return ["compiler-temporary", note + " (the value of an await)"]
	var ma := counted_name.search(a)
	var mb := counted_name.search(b)
	if a.begins_with("__") or b.begins_with("__"):
		return ["compiler-temporary", note]
	if ma != null and mb != null and ma.get_string(1) == mb.get_string(1):
		return ["compiler-temporary", note + " (a node's id in the name)"]
	if (ma != null) != (mb != null) and (b.begins_with(a + "_") or a.begins_with(b + "_")):
		return ["compiler-temporary", note + " (a node's id in the name)"]
	return ["other", "name " + note]


func add_found(name: String, cat: String, lines: int, nodes: int, note: String) -> void:
	var f: Dictionary = found.get(cat, {"lines": 0, "nodes": 0, "notes": []})
	f.lines = int(f.lines) + lines
	f.nodes = int(f.nodes) + nodes
	if note != "" and f.notes.size() < 3 and not note in f.notes:
		f.notes.append(note)
	found[cat] = f


## A line with what is only a matter of naming undone, and which categories that was: the doubled event suffix
## (second script only: `speed_ready_ready` is read as `speed_ready`) and loop variables' numbers (`i_14` is `i`).
## Returns [line, [[category, note], ...]].
func norm_line(s: String, ctx: Dictionary, second := false) -> Array:
	var cats := []
	var out := s
	if second:
		for e in ctx.events:
			var re: RegEx = ctx.event_res[e]
			var guard := 0
			var m := re.search(out)
			while m != null and guard < 6:
				guard += 1
				if guard == 1:
					cats.append(["event-local-suffix", m.get_string()])
				out = re.sub(out, "_" + e, true)
				m = re.search(out)
	for pair in ctx.loop_res:
		var m: RegEx = pair[0]
		var hit := m.search(out)
		if hit != null:
			out = m.sub(out, pair[1], true)
	return [out, cats]


func make_ctx(code1: String, code2: String) -> Dictionary:
	var events := []
	for m in func_name.search_all(code1 + "\n" + code2):
		var e := m.get_string(1).trim_prefix("_")
		if not e in events and e != "":
			events.append(e)
	var event_res := {}
	for e in events:
		event_res[e] = RegEx.create_from_string("_%s_%s\\b" % [e, e])
	var loops := {}
	var loop_res := []
	for m in for_var.search_all(code1 + "\n" + code2):
		var v := m.get_string(1)
		if not loops.has(v):
			loops[v] = true
			var cm := counted_name.search(v)
			if cm != null:
				loop_res.append([RegEx.create_from_string("\\b%s\\b" % v), cm.get_string(1) + "#"])
	return {"events": events, "event_res": event_res, "loops": loops, "loop_res": loop_res}


func print_line(sign: String, r: Array) -> void:
	print("      %s %4d  %s" % [sign, r[0], _cut(String(r[1]).replace("\t", "  "), 110)])


## Prints the first differences (at most MAX_SHOWN changed lines) and collects the categories. Lines that differ
## only by naming (the doubled event suffix, a loop variable's number) are counted, not shown.
func explain_text(name: String, code1: String, code2: String) -> void:
	var a := code1.split("\n")
	var b := code2.split("\n")
	var ctx := make_ctx(code1, code2)
	var na := PackedStringArray()
	for l in a:
		na.append(norm_line(l, ctx)[0])
	var nb := PackedStringArray()
	for l in b:
		nb.append(norm_line(l, ctx, true)[0])
	var matched := []
	var hunks := diff_lines(na, nb, a, b, matched)
	var naming := 0
	for pr in matched:
		if a[pr[0]] != b[pr[1]]:
			naming += 1
			for c in classify_pair(a[pr[0]], b[pr[1]], ctx):
				add_found(name, c[0], 1, 0, c[1])
	if naming > 0:
		print("      (%d lines differ only by a doubled event suffix or a loop variable's number; not shown)" % naming)
	var shown := 0
	var total := 0
	for h in hunks:
		var ra: Array = h.a
		var rb: Array = h.b
		total += ra.size() + rb.size()
		var lambda_hunk := false
		for r in ra + rb:
			if String(r[2]).contains("func(") or String(r[2]).contains("func (") or String(r[2]).contains("_lambda_"):
				lambda_hunk = true
		# pair the removed lines with the added lines that look most like them
		var used := {}
		var pairs := []
		var lone_a := []
		for ri in ra.size():
			var r: Array = ra[ri]
			var best := -1
			var best_score := 0.25
			var tr := toks(String(r[2]))
			for k in rb.size():
				if used.has(k):
					continue
				var sc := jaccard(tr, toks(String(rb[k][2])))
				if ra.size() == rb.size() and k == ri:
					sc += 0.3   # the same place in the hunk is the likeliest partner
				if sc > best_score:
					best_score = sc
					best = k
			if best == -1:
				lone_a.append(r)
			else:
				used[best] = true
				pairs.append([r, rb[best]])
		var lone_b := []
		for k in rb.size():
			if not used.has(k):
				lone_b.append(rb[k])
		for p in pairs:
			if shown < MAX_SHOWN:
				print_line("-", p[0])
				print_line("+", p[1])
				shown += 2
			for c in classify_pair(String(p[0][1]), String(p[1][1]), ctx):
				add_found(name, c[0], 1, 0, c[1])
		for r in lone_a:
			if shown < MAX_SHOWN:
				print_line("-", r)
				shown += 1
			var st := String(r[1]).strip_edges()
			if st.contains(".is_connected("):
				add_found(name, "connect-guard", 1, 0, _cut(st, 80))
			elif lambda_hunk:
				add_found(name, "lambda-lost", 1, 0, "in code1 only: " + _cut(st, 60))   # a lambda (or its body) the second pass no longer has
			elif st.begins_with("#"):
				add_found(name, "comment-lost", 1, 0, _cut(st, 80))
			elif st.begins_with("var "):
				add_found(name, "hoisted-local", 1, 0, "dropped: " + _cut(st, 70))
			elif st == "":
				add_found(name, "blank-lines", 1, 0, "")
			else:
				add_found(name, "other", 1, 0, "line only in code1: " + _cut(st, 80))
		for r in lone_b:
			if shown < MAX_SHOWN:
				print_line("+", r)
				shown += 1
			var st := String(r[1]).strip_edges()
			if st.contains(".is_connected("):
				add_found(name, "connect-guard", 1, 0, _cut(st, 80))
			elif lambda_hunk:
				add_found(name, "lambda-form", 1, 0, _cut(st, 60))
			elif st.begins_with("var "):
				add_found(name, "hoisted-local", 1, 0, "added: " + _cut(st, 70))
			elif st == "":
				add_found(name, "blank-lines", 1, 0, "")
			else:
				add_found(name, "other", 1, 0, "line only in code2: " + _cut(st, 80))
	if total > shown:
		print("      ... %d more changed lines (%d lines in code1, %d in code2)" % [total - shown, a.size(), b.size()])


# ------------------------------------------------------------------------------------- one input

func compile_all(bp: Dictionary) -> Dictionary:
	var made: Array = checks.compile_loaded(bp)
	var c := Compiler.new()
	c.compile(bp)
	var errs := c.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
	return {"code": made[0], "gs": made[1], "said": made[2], "errs": errs}


func judge(name: String, source: String, path: String) -> void:
	var show := OS.get_cmdline_user_args().has("--show")
	print("\n== %s" % name)
	n_inputs += 1
	found = {}
	var out1: Dictionary = Importer.new().convert(source, {"path": path})
	var r1 := compile_all(out1.bp)
	var out2: Dictionary = Importer.new().convert(r1.code, {"path": path})
	var r2 := compile_all(out2.bp)
	var out3: Dictionary = Importer.new().convert(r2.code, {"path": path})
	var r3 := compile_all(out3.bp)
	var code1: String = r1.code
	var code2: String = r2.code
	if show:
		print("---- code1\n%s\n---- code2\n%s\n----" % [code1, code2])
	check("%s: code1 loads" % name, r1.gs != null and r1.errs.is_empty(), "%s %s" % [str(r1.errs), str(r1.said.keys())])
	check("%s: code2 loads" % name, r2.gs != null and r2.errs.is_empty(), "%s %s" % [str(r2.errs), str(r2.said.keys())])
	var text_ok := code2 == code1
	var c1 := canon(out1.bp)
	var c2 := canon(out2.bp)
	var graph_ok := same_canon(c1, c2)
	var settled: bool = r3.code == code2
	var rep1: Dictionary = out1.report
	var rep2: Dictionary = out2.report
	if text_ok:
		n_text += 1
	if graph_ok:
		n_graph += 1
	if settled:
		n_settled += 1
	check("%s: text (code2 == code1)" % name, text_ok)
	if not text_ok:
		explain_text(name, code1, code2)
	check("%s: graph (same canonical graph)" % name, graph_ok)
	if not graph_ok:
		# what is left once the naming differences (doubled event suffix, loop numbers) are undone on both sides
		var ctx := make_ctx(code1, code2)
		var c1n := canon(out1.bp, ctx, false)
		var c2n := canon(out2.bp, ctx, true)
		var gd := graph_diff(c1n, c2n)
		var naming_nodes: int = int(graph_diff(c1, c2).params) - int(gd.params)
		if naming_nodes > 0:
			add_found(name, "event-local-suffix", 0, naming_nodes, "nodes and locals named with the doubled suffix")
		if same_canon(c1n, c2n):
			print("      (the graphs differ only by naming: the doubled event suffix or a loop variable's number)")
		var shown := 0
		for l in gd.lines:
			if shown >= MAX_SHOWN:
				print("      ... %d more graph differences" % (gd.lines.size() - shown))
				break
			print("      %s" % _cut(String(l), 170))
			shown += 1
		if gd.lines.is_empty() and not same_canon(c1n, c2n):
			print("      (no readable difference: the wiring differs)")
		var lost: Dictionary = gd.lost
		var gained: Dictionary = gd.gained
		if not lost.is_empty() or not gained.is_empty():
			var ln := 0
			for k in lost:
				ln += int(lost[k])
			var gn := 0
			for k in gained:
				gn += int(gained[k])
			var cat := "node-kind-changed" if (ln > 0 and gn > 0) else ("nodes-gained" if gn > 0 else "nodes-lost")
			if ln == 0 and gained.has("branch") and gained.has("event_ref"):
				cat = "connect-guard"   # the guard around a connect() is read back as a branch on is_connected()
			elif ln == 0 and gained.has("break"):
				cat = "struct-part-write"   # `t.origin.y = v` is written as a whole new origin, which is read back as Break + Make nodes
			elif ln == 0 and gained.size() == 1 and gained.has("fn_return"):
				cat = "implicit-return"   # a function that ends without a value is written with `return`, which is read back as a return node
			add_found(name, cat, 0, maxi(ln, gn), "lost %s, gained %s" % [var_to_str(lost).replace("\n", " "), var_to_str(gained).replace("\n", " ")])
		elif gd.params > 0:
			var optional := 0
			for l in gd.lines:
				if String(l).contains("+ node tpl") and (String(l).contains("\"step\":\"1\"") or String(l).contains("\"message\"")):
					optional += 1
			if optional > 0:
				add_found(name, "optional-argument", 0, optional, "an argument left out in the source is spelled out in the generated code (range step, assert message)")
			if int(gd.params) > optional:
				add_found(name, "node-parameters-changed", 0, int(gd.params) - optional, "")
		elif text_ok:
			add_found(name, "graph-only", 0, 1, "wiring or header differs, text the same")
	check("%s: third pass settles (code3 == code2)" % name, settled, "" if settled else "lines differing between code2 and code3: see below")
	if not settled:
		var n3 := 0
		for h in diff_lines(code2.split("\n"), r3.code.split("\n")):
			n3 += maxi(h.a.size(), h.b.size())
			if n3 <= 4:
				for r in h.a:
					print("      2- %4d  %s" % [r[0], _cut(String(r[1]).replace("\t", "  "), 110)])
				for r in h.b:
					print("      3+ %4d  %s" % [r[0], _cut(String(r[1]).replace("\t", "  "), 110)])
		print("      (%d lines differ between code2 and code3)" % n3)
	if r1.gs != null and r2.gs != null:
		var changes: Array = checks.interface_changes(checks.interface(r1.gs), checks.interface(r2.gs))
		check("%s: the same functions, variables, signals and constants" % name, changes.is_empty(), _cut(str(changes), 600))
	else:
		check("%s: the same functions, variables, signals and constants" % name, false, "a script did not load")
	check("%s: code nodes (%d lines as code, then %d)" % [name, rep1.as_code, rep2.as_code], int(rep2.as_code) <= int(rep1.as_code))
	if int(rep2.as_code) > int(rep1.as_code):
		add_found(name, "code-node-gained", int(rep2.as_code) - int(rep1.as_code), 0, "%s" % str(rep2.notes.filter(func(n): return String(n).contains("kept as code")).slice(0, 2)))
	if not (text_ok and graph_ok):
		print("    CATEGORIES:")
		var order := found.keys()
		order.sort_custom(func(p, q): return int(found[p].lines) + int(found[p].nodes) > int(found[q].lines) + int(found[q].nodes))
		if order.is_empty():
			print("      (none found)")
		for cat in order:
			var f: Dictionary = found[cat]
			print("      CATEGORY %s: %d lines, %d nodes%s" % [cat, f.lines, f.nodes, ("   e.g. " + " | ".join(f.notes)) if not f.notes.is_empty() else ""])
			var t: Dictionary = table.get(cat, {"inputs": 0, "lines": 0, "nodes": 0})
			t.inputs = int(t.inputs) + 1
			t.lines = int(t.lines) + int(f.lines)
			t.nodes = int(t.nodes) + int(f.nodes)
			table[cat] = t


func _init() -> void:
	var started := Time.get_ticks_msec()
	T.refresh_globals()
	R.ensure_api()
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var names := []
	for f in DirAccess.get_files_at(DIR):
		if f.get_extension() == "gd" and not f.begins_with("_"):
			names.append(f.get_basename())
	names.sort()
	for name in names:
		if only != "" and name != only:
			continue
		var path: String = DIR + name + ".gd"
		var source := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
		if checks.load_text(source)[0] == null:
			print("\n== %s\n  SKIP  the sample itself does not load" % name)
			continue
		judge(name, source, path)
		judge(name + " (crlf)", source.replace("\n", "\r\n"), path)
	for dir in DEMO_DIRS:
		var files := Array(DirAccess.get_files_at(dir))
		files.sort()
		for f in files:
			if f.get_extension() != "gd" or not Model.is_schematic_file(dir + f):
				continue
			var name: String = f.get_basename()
			if only != "" and name != only:
				continue
			var bp := Model.load_file(dir + f)
			if bp.is_empty() or bp.graphs.is_empty():
				print("\n== %s\n  SKIP  no stored graph" % name)
				continue
			var source: String = Compiler.new().compile(bp)
			var loaded: Array = checks.load_text(source)
			if loaded[0] == null:
				print("\n== %s\n  SKIP  its own generated code does not load: %s" % [name, str(loaded[1].keys())])
				continue
			judge(name, source, dir + f)
	print("\n---------------------------------------------------------------- summary")
	print("inputs: %d    text fixed points: %d    graph fixed points: %d    settle by the third pass: %d    other FAIL lines: %d" % [n_inputs, n_text, n_graph, n_settled, fails])
	var cats := table.keys()
	cats.sort_custom(func(p, q): return int(table[p].inputs) > int(table[q].inputs) or (int(table[p].inputs) == int(table[q].inputs) and int(table[p].lines) + int(table[p].nodes) > int(table[q].lines) + int(table[q].nodes)))
	print("%-26s %8s %8s %8s" % ["category", "inputs", "lines", "nodes"])
	for cat in cats:
		print("%-26s %8d %8d %8d" % [cat, table[cat].inputs, table[cat].lines, table[cat].nodes])
	print("(%.1f seconds)" % ((Time.get_ticks_msec() - started) / 1000.0))
	print("FIXED POINT: %d of %d text, %d of %d graph, %d of %d settle" % [n_text, n_inputs, n_graph, n_inputs, n_settled, n_inputs])
	quit(0)
