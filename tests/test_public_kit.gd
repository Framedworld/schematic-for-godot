extends SceneTree
## Public kits: an addon ships res://addons/<addon>/schematic_kit.gd and its nodes appear in Schematic. This
## finds the fake addon in tests/fake_kit/ (the scan is pointed there with Kits.set_kit_roots), builds a graph
## with its three nodes, compiles it, runs the script, then checks namespacing, reload, the placeholder while the
## kit is gone, every validation message, versioning and broken kit scripts.
## The broken kits are written by this test under res://tests/tmp/ (git-ignored) and removed at the end.
## Run: godot --headless --path . --script res://tests/test_public_kit.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const GraphView := preload("res://addons/schematic/editor/sc_graph_view.gd")

const GOOD := "res://tests/fake_kit"
const TMP := "res://tests/tmp/public_kit"
const LIVE := TMP + "/live"       # a copy of the fake kit, to take away and put back
const TWIN := TMP + "/twin"       # a second kit using the same ids
const BAD := TMP + "/bad"         # kits with problems
const HEALTH := "res://tests/fake_kit/health/health.gd"

var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail if not ok else ""])
	if not ok:
		fails += 1


func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		remove_tree(path.path_join(sub))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func reload(roots: Array) -> void:
	Kits.set_kit_roots(PackedStringArray(roots))
	R.reload_kits()


func compile(bp: Dictionary) -> Array:
	var c := Compiler.new()
	var code := c.compile(bp)
	return [code, c.errors.filter(func(e): return not e.w)]


## The whole template table and the problem list, as text, in a fixed order.
func dump() -> String:
	var keys := R.templates.keys()
	keys.sort()
	var out := PackedStringArray()
	for k in keys:
		out.append("%s = %s" % [k, var_to_str(R.templates[k])])
	for p in R.kit_problems:
		out.append("problem: " + String(p.message))
	return "\n".join(out)


func builtin_dump() -> String:
	var keys := R.templates.keys().filter(func(k): return not Kits.kit_template_ids().has(k) and not String(k).contains(":"))
	keys.sort()
	return "\n".join(keys.map(func(k): return "%s = %s" % [k, var_to_str(R.templates[k])]))


func tpl_ids(actions: Array) -> Array:
	return actions.filter(func(a): return a.k == "tpl" and a.p.has("id")).map(func(a): return String(a.p.id))


func problems_of(addon: String) -> Array:
	return R.kit_problems.filter(func(p): return String(p.addon) == addon)


func prune(bp: Dictionary, g: Dictionary) -> void:
	var v = GraphView.new()
	v.bp = bp
	v.graph = g
	v.prune_wires()
	v.free()


func wire_keys(g: Dictionary) -> Array:
	var out: Array = g.wires.map(func(w): return str([int(w[0]), String(w[1]), int(w[2]), String(w[3])]))
	out.sort()
	return out


func all_wire_keys(bp: Dictionary) -> Array:
	var out := []
	for g in bp.graphs:
		out.append_array(wire_keys(g).map(func(k): return "%d %s" % [int(g.id), k]))
	return out


## The example graph of docs/KITS.md: three functions, one per node of the kit.
func example() -> Dictionary:
	var bp := Model.new_schematic("Node", "")
	bp.graphs[0].nodes.clear()
	bp.variables.append({"name": "saw_death", "type": "bool", "default": "false", "export": false, "category": "", "tooltip": ""})
	# heal_twice(who): Heal 5, then Heal (default 10)
	var g1 := Model.new_graph(bp, "heal_twice", "function")
	g1.inputs = [["who", "Node"]]
	var e1: Dictionary = g1.nodes[0]
	var r1: Dictionary = g1.nodes[1]
	var h1 := Model.add_node(g1, "tpl", Vector2(320, 120), {"id": "health:heal"})
	h1.d["amount"] = "5"
	var h2 := Model.add_node(g1, "tpl", Vector2(620, 120), {"id": "health:heal"})
	r1.x = 920.0
	g1.wires.append_array([[e1.id, "then", h1.id, "exec"], [e1.id, "p_who", h1.id, "target"], [h1.id, "then", h2.id, "exec"],
		[e1.id, "p_who", h2.id, "target"], [h2.id, "then", r1.id, "exec"]])
	# alive(who) -> bool
	var g2 := Model.new_graph(bp, "alive", "function")
	g2.inputs = [["who", "Node"]]
	g2.outputs = [["alive", "bool"]]
	var e2: Dictionary = g2.nodes[0]
	var r2: Dictionary = g2.nodes[1]
	var al := Model.add_node(g2, "tpl", Vector2(300, 260), {"id": "health:is_alive"})
	g2.wires.append_array([[e2.id, "then", r2.id, "exec"], [e2.id, "p_who", al.id, "target"], [al.id, "ret", r2.id, "r_alive"]])
	# wait_dead(who): waits, then sets saw_death
	var g3 := Model.new_graph(bp, "wait_dead", "function")
	g3.inputs = [["who", "Node"]]
	g3["latent"] = true
	var e3: Dictionary = g3.nodes[0]
	var r3: Dictionary = g3.nodes[1]
	var wt := Model.add_node(g3, "tpl", Vector2(320, 120), {"id": "health:wait_until_dead"})
	var st := Model.add_node(g3, "var_set", Vector2(620, 120), {"name": "saw_death"})
	st.d["value"] = "true"
	r3.x = 920.0
	g3.wires.append_array([[e3.id, "then", wt.id, "exec"], [e3.id, "p_who", wt.id, "target"], [wt.id, "then", st.id, "exec"], [st.id, "then", r3.id, "exec"]])
	return bp


func kit_nodes(bp: Dictionary) -> Array:
	var out := []
	for g in bp.graphs:
		for n in g.nodes:
			if n.kind == "tpl" and String(n.p.get("id", "")).begins_with("health:"):
				out.append([g, n])
	return out


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()
	remove_tree(TMP)
	var builtins_before := builtin_dump()
	var len_before := var_to_str(R.templates.get("gd_len"))

	# ================================================================ discovery
	reload([GOOD])
	var kits := Kits.loaded_kits()
	check("discovery finds the fake kit in tests/fake_kit/health", kits.size() == 1 and kits[0].addon == "health", str(kits))
	check("... with its name, version and API from the constants", kits.size() == 1 and kits[0].name == "Health" and kits[0].version == "1.0.0" and kits[0].api == 1, str(kits))
	check("... and no problems", R.kit_problems.is_empty(), str(R.kit_problems))
	check("its three nodes are registered, stored namespaced as <addon>:<id>",
		R.templates.has("health:heal") and R.templates.has("health:is_alive") and R.templates.has("health:wait_until_dead") and not R.templates.has("heal"))
	check("the kit's template ids are known as kit ids", Kits.kit_template_ids().has("health:heal"))

	# ================================================================ palette
	var node_bp := Model.new_schematic("Node", "")
	var acts: Array = R.schematic_actions(node_bp, node_bp.graphs[0])
	var ids := tpl_ids(acts)
	check("palette of a Node schematic offers Heal, Is Alive and Wait Until Dead", ids.has("health:heal") and ids.has("health:is_alive") and ids.has("health:wait_until_dead"), str(ids.filter(func(i): return i.begins_with("health"))))
	check("... each once", ids.count("health:heal") == 1 and ids.count("health:wait_until_dead") == 1)
	var heal_act: Array = acts.filter(func(a): return a.k == "tpl" and a.p.get("id") == "health:heal")
	check("... under the kit's category, findable by its search words", not heal_act.is_empty() and heal_act[0].c == "Health" and String(heal_act[0].s).contains("restore"), str(heal_act))
	var ref_bp := Model.new_schematic("RefCounted", "")
	var ref_ids := tpl_ids(R.schematic_actions(ref_bp, ref_bp.graphs[0]))
	check("palette of a RefCounted schematic offers Heal and Is Alive but not Wait Until Dead (\"for\": [\"Node\"])",
		ref_ids.has("health:heal") and ref_ids.has("health:is_alive") and not ref_ids.has("health:wait_until_dead"))
	var consts := acts.filter(func(a): return a.k == "const" and a.l == "Full Health")
	check("the kit's actions() adds its Full Health value", consts.size() == 1 and consts[0].p.expr == "100" and consts[0].p.t == "int", str(consts))

	# ================================================================ a graph with the kit's nodes
	var bp := example()
	var built := compile(bp)
	var code: String = built[0]
	print("---- generated code ----\n", code, "---- end ----")
	check("the example graph compiles without errors", built[1].is_empty(), str(built[1]))
	check("Heal compiles to the documented call", code.contains("\twho.heal(5)\n\twho.heal(10)\n"), code)
	check("Is Alive compiles to the documented expression", code.contains("return (who.hp > 0)"), code)
	check("Wait Until Dead compiles to the documented wait", code.contains("\tif who.hp > 0:\n\t\tawait who.died\n\tsaw_death = true"), code)
	var gs := GDScript.new()
	gs.source_code = code
	check("the generated script loads", gs.reload() == OK)
	var obj: Node = gs.new()
	var h: Node = load(HEALTH).new()
	h.hp = 50
	obj.heal_twice(h)
	check("running heal_twice heals 5 then 10", h.hp == 65, str(h.hp))
	check("running alive says alive", obj.alive(h) == true)
	obj.wait_dead(h)
	check("wait_dead is waiting while the target lives", obj.saw_death == false)
	h.damage(1000)
	check("... and goes on when the target dies", obj.saw_death == true)
	check("running alive says dead after that", obj.alive(h) == false)
	obj.free()
	h.free()
	var src := Model.build_source(code, bp)
	var back := Model.parse_source(src)
	var stored := kit_nodes(back).map(func(x): return String(x[1].p.id))
	check("ids are saved namespaced in the graph data", stored.size() == 4 and stored.has("health:heal") and src.contains("health:wait_until_dead"), str(stored))

	# ================================================================ starters
	var st := Starters.find("health:regen")
	check("the kit's starter is offered, namespaced", not st.is_empty() and st.parent == "Node" and st.file == "Regen", str(st))
	var sbp := Starters.build("health:regen", "")
	check("... and builds a schematic from the source build_starter() returns", sbp.get("parent", "") == "Node" and compile(sbp)[1].is_empty() and String(compile(sbp)[0]).contains("heal("), str(compile(sbp)))

	# ================================================================ two kits with the same template id
	var kit_text := FileAccess.get_file_as_string(GOOD + "/health/schematic_kit.gd")
	write(TWIN + "/twin/schematic_kit.gd", kit_text.replace("\"lines\": [\"{target}.heal({amount})\"]", "\"lines\": [\"{target}.heal({amount} * 2)\"]")
		.replace("static func register(kit) -> void:", "static func register(kit) -> void:\n\tkit.template(\"gd_len\", {\"title\": \"Not Length\", \"pure\": true, \"outs\": [[\"ret\", \"R\", \"int\"]], \"exprs\": {\"ret\": \"0\"}})"))
	reload([GOOD, TWIN])
	check("two kits with the same id 'heal' both load", R.templates.has("health:heal") and R.templates.has("twin:heal"), str(R.kit_problems))
	check("... each with its own code", R.templates["health:heal"].lines == ["{target}.heal({amount})"] and R.templates["twin:heal"].lines == ["{target}.heal({amount} * 2)"])
	check("a kit's 'gd_len' is 'twin:gd_len' and leaves Schematic's own gd_len alone", R.templates.has("twin:gd_len") and var_to_str(R.templates.get("gd_len")) == len_before)
	check("with another kit loaded, the example graph compiles to the same code", String(compile(example())[0]) == code)

	# ================================================================ the kit goes away and comes back
	for f in ["schematic_kit.gd", "health.gd"]:
		write(LIVE + "/health/" + f, FileAccess.get_file_as_string(GOOD + "/health/" + f))
	reload([LIVE])
	var live_bp := example()
	var live_code: String = compile(live_bp)[0]
	check("the copy of the kit compiles the example to the same code", live_code == code)
	var saved := Model.build_source(live_code, live_bp)
	var wires_before := all_wire_keys(live_bp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LIVE + "/health/schematic_kit.gd"))
	reload([LIVE])
	check("after removing the kit file and reloading, its nodes are gone", not R.templates.has("health:heal") and Kits.loaded_kits().is_empty())
	var gone := Model.parse_source(saved)
	for x in kit_nodes(gone):
		prune(gone, x[0])
	var placeholders := kit_nodes(gone).map(func(x): return R.describe(x[1], gone, x[0]))
	check("each kit node is a placeholder", placeholders.size() == 4 and placeholders.all(func(d): return bool(d.get("missing", false))), str(placeholders.map(func(d): return d.title)))
	check("... whose error names the node and the addon folder", placeholders.all(func(d): return String(d.err).contains("health:") and String(d.err).contains("(addons/health)")), str(placeholders.map(func(d): return d.err)))
	check("... and keeps every wire", all_wire_keys(gone) == wires_before)
	var gone_errs: Array = compile(gone)[1]
	# (a function stops at its first error, so heal_twice reports its first Heal only)
	check("compiling reports the missing node in each of the three functions", gone_errs.size() == 3 and gone_errs.all(func(e): return String(e.m).contains("not installed or enabled")), str(gone_errs.map(func(e): return e.m)))
	write(LIVE + "/health/schematic_kit.gd", kit_text)
	reload([LIVE])
	var back_bp := Model.parse_source(saved)
	var back_built := compile(back_bp)
	check("after putting the kit back and reloading, the graph is whole again", kit_nodes(back_bp).all(func(x): return not R.describe(x[1], back_bp, x[0]).get("missing", false)) and all_wire_keys(back_bp) == wires_before)
	check("... and compiles to the same code as before", back_built[1].is_empty() and String(back_built[0]) == code, str(back_built[1]))

	# ================================================================ problems
	var head := "const KIT_API := 1\n\nstatic func register(kit) -> void:\n"
	write(BAD + "/broken/schematic_kit.gd", head
		+ "\tkit.template(\"fine\", {\"title\": \"Fine\", \"pure\": true, \"outs\": [[\"ret\", \"Value\", \"int\"]], \"exprs\": {\"ret\": \"42\"}})\n"
		+ "\tkit.template(\"typo\", {\"title\": \"Typo\", \"lines\": [\"pass\"], \"colour\": \"red\"})\n"
		+ "\tkit.template(\"no_pin_id\", {\"title\": \"No Pin Id\", \"ins\": [[\"\", \"X\", \"int\", \"\"]], \"lines\": [\"pass\"]})\n"
		+ "\tkit.template(\"bad_type\", {\"title\": \"Bad Type\", \"ins\": [[\"x\", \"X\", \"Intt\", \"\"]], \"lines\": [\"print({x})\"]})\n"
		+ "\tkit.template(\"bad_placeholder\", {\"title\": \"Bad Placeholder\", \"ins\": [[\"x\", \"X\", \"int\", \"\"]], \"lines\": [\"print({nope})\"]})\n"
		+ "\tkit.template(\"no_title\", {\"lines\": [\"pass\"]})\n"
		+ "\tkit.template(\"also_fine\", {\"title\": \"Also Fine\", \"lines\": [\"print(1)\"]})\n")
	write(BAD + "/too_new/schematic_kit.gd", "const KIT_API := 99\n\nstatic func register(kit) -> void:\n\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	write(BAD + "/no_api/schematic_kit.gd", "static func register(kit) -> void:\n\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	write(BAD + "/text_api/schematic_kit.gd", "const KIT_API := \"1\"\n\nstatic func register(kit) -> void:\n\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	write(BAD + "/old_api/schematic_kit.gd", "const KIT_API := 1\n\nstatic func register(kit) -> void:\n\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	write(BAD + "/parse_error/schematic_kit.gd", head + "\tkit.template(\"x\", {\n")
	write(BAD + "/no_register/schematic_kit.gd", "const KIT_API := 1\n")
	write(BAD + "/throws/schematic_kit.gd", head + "\tkit.template(\"before\", {\"title\": \"Before\", \"lines\": [\"pass\"]})\n\tkit.no_such_function()\n\tkit.template(\"after\", {\"title\": \"After\", \"lines\": [\"pass\"]})\n")
	var helper_tpl := "\tkit.template(\"percent\", {\"title\": \"Health Percent\", \"pure\": true, \"ins\": [[\"target\", \"Target\", \"Node\", \"\"]], \"outs\": [[\"ret\", \"Percent\", \"float\"]],\n" \
		+ "\t\t\"helper\": [\"health_percent\", \"func health_percent(node: Node) -> float:\", [\n\t\t\t[1, \"return 100.0 * node.hp / maxf(node.max_hp, 1)\"]]],\n" \
		+ "\t\t\"exprs\": {\"ret\": \"health_percent({target})\"}})\n"
	write(BAD + "/helpers/schematic_kit.gd", head + helper_tpl)
	write(BAD + "/helpers_clash/schematic_kit.gd", head + helper_tpl.replace("return 100.0", "return 1.0"))
	write(BAD + "/disabled/plugin.cfg", "[plugin]\nname=\"Disabled\"\nscript=\"plugin.gd\"\n")
	write(BAD + "/disabled/schematic_kit.gd", head + "\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	print("---- the broken kits below print errors on purpose ----")
	reload([GOOD, BAD])
	print("---- end of the errors on purpose ----")
	for p in R.kit_problems:
		print("    problem: ", p.message)
	var broken := problems_of("broken")
	var by_tpl := {}
	for p in broken:
		by_tpl[String(p.template)] = by_tpl.get(String(p.template), []) + [String(p.problem)]
	check("a broken kit's good nodes still load", R.templates.has("broken:fine") and R.templates.has("broken:also_fine"))
	check("... its bad nodes are skipped", not R.templates.has("broken:typo") and not R.templates.has("broken:no_pin_id") and not R.templates.has("broken:bad_type")
		and not R.templates.has("broken:bad_placeholder") and not R.templates.has("broken:no_title"))
	check("unknown key: reported once, naming the key", by_tpl.get("typo", []).size() == 1 and String(by_tpl.typo[0]).contains("unknown key 'colour'"), str(by_tpl.get("typo")))
	check("pin with no id: reported once", by_tpl.get("no_pin_id", []).size() == 1 and String(by_tpl.no_pin_id[0]).contains("has no id"), str(by_tpl.get("no_pin_id")))
	check("unknown pin type: reported once, naming the type", by_tpl.get("bad_type", []).size() == 1 and String(by_tpl.bad_type[0]).contains("unknown type 'Intt'"), str(by_tpl.get("bad_type")))
	check("placeholder naming no pin: reported once, naming it", by_tpl.get("bad_placeholder", []).size() == 1 and String(by_tpl.bad_placeholder[0]).contains("{nope}"), str(by_tpl.get("bad_placeholder")))
	check("missing title: reported once", by_tpl.get("no_title", []).size() == 1 and String(by_tpl.no_title[0]).contains("no title"), str(by_tpl.get("no_title")))
	check("the good nodes have no problems", not by_tpl.has("fine") and not by_tpl.has("also_fine"))
	check("each message names the addon, the file and the node, and says what happens",
		broken.all(func(p): return String(p.message).contains("'broken'") and String(p.message).contains("broken/schematic_kit.gd") and String(p.message).contains("node '") and String(p.message).contains("skipped")), str(broken.map(func(p): return p.message)))
	var too_new := problems_of("too_new")
	check("a kit with a too-new KIT_API is skipped with the message",
		too_new.size() == 1 and String(too_new[0].problem).contains("kit API 99") and String(too_new[0].problem).contains("understands kit API %d" % Kits.KIT_API) and String(too_new[0].problem).contains(Kits.schematic_version()) and not R.templates.has("too_new:x"), str(too_new))
	check("a kit with no KIT_API is skipped with the message", problems_of("no_api").size() == 1 and String(problems_of("no_api")[0].problem).contains("KIT_API") and not R.templates.has("no_api:x"))
	check("a kit whose KIT_API is not a number is skipped with the message", problems_of("text_api").size() == 1 and not R.templates.has("text_api:x"))
	check("a kit with the current KIT_API (or an older one) loads", R.templates.has("old_api:x") and problems_of("old_api").is_empty())
	var parse := problems_of("parse_error")
	check("a kit script with a parse error is skipped and reported", parse.size() == 1 and String(parse[0].problem).contains("could not be loaded") and Kits.loaded_kits().all(func(k): return k.addon != "parse_error"), str(parse))
	check("a kit script with no register() is reported", problems_of("no_register").size() == 1 and String(problems_of("no_register")[0].problem).contains("register"))
	check("a kit whose register() throws does not stop Schematic: what it added before the error is there", R.templates.has("throws:before") and not R.templates.has("throws:after"))
	check("a kit whose addon has a plugin.cfg that is not enabled is not loaded (and that is not a problem)", not R.templates.has("disabled:x") and problems_of("disabled").is_empty())
	# the helper example of docs/KITS.md
	check("a node with a helper loads", R.templates.has("helpers:percent") and problems_of("helpers").is_empty(), str(problems_of("helpers")))
	var clash := problems_of("helpers_clash")
	check("a second kit's helper with the same name and another body is reported and skipped", clash.size() == 1 and String(clash[0].problem).contains("health_percent") and not R.templates.has("helpers_clash:percent"), str(clash))
	var hb := Model.new_schematic("RefCounted", "")
	var hg := Model.new_graph(hb, "pct", "function")
	hg.inputs = [["who", "Node"]]
	hg.outputs = [["p", "float"]]
	var hn := Model.add_node(hg, "tpl", Vector2(300, 200), {"id": "helpers:percent"})
	hg.wires.append_array([[hg.nodes[0].id, "then", hg.nodes[1].id, "exec"], [hg.nodes[0].id, "p_who", hn.id, "target"], [hn.id, "ret", hg.nodes[1].id, "r_p"]])
	var hbuilt := compile(hb)
	print("---- helper code ----\n", hbuilt[0], "---- end ----")
	var hs := GDScript.new()
	hs.source_code = String(hbuilt[0])
	var hok: bool = hbuilt[1].is_empty() and String(hbuilt[0]).contains("func health_percent(node: Node) -> float:") and hs.reload() == OK
	var hh: Node = load(HEALTH).new()
	hh.hp = 25
	check("... it compiles with the helper written once, and runs", hok and is_equal_approx(float(hs.new().pct(hh)), 25.0), str(hbuilt))
	hh.free()
	check("with the broken kits around, the good kit still loads and compiles the example to the same code", R.templates.has("health:heal") and String(compile(example())[0]) == code)
	var count := R.kit_problems.size()
	var printed: int = Kits._printed.size()
	reload([GOOD, BAD])
	check("reloading reports the same problems, no duplicates", R.kit_problems.size() == count, "%d then %d" % [count, R.kit_problems.size()])
	check("... and writes nothing new to the Output (each message once)", Kits._printed.size() == printed)
	OS.delay_msec(1100)   # file times have a resolution of one second
	write(BAD + "/parse_error/schematic_kit.gd", head + "\tkit.template(\"x\", {\"title\": \"X\", \"lines\": [\"pass\"]})\n")
	reload([GOOD, BAD])
	check("once the parse error is fixed, the kit loads on the next reload", R.templates.has("parse_error:x") and problems_of("parse_error").is_empty())
	OS.delay_msec(1100)
	write(BAD + "/parse_error/schematic_kit.gd", head + "\tkit.template(\"x\", {\n")
	reload([GOOD, BAD])
	check("... and is reported again when it breaks again", not R.templates.has("parse_error:x") and problems_of("parse_error").size() == 1)

	# ================================================================ reload is idempotent
	reload([GOOD, TWIN, BAD])
	var d1 := dump()
	reload([GOOD, TWIN, BAD])
	var d2 := dump()
	reload([GOOD, TWIN, BAD])
	check("reloading twice gives the same template table and problems", d1 == d2 and d2 == dump(), "%d vs %d chars" % [d1.length(), d2.length()])
	reload([GOOD])
	check("reloading with fewer kits leaves no stale entries", not R.templates.has("twin:heal") and not R.templates.has("broken:fine") and R.kit_problems.is_empty() and Kits.kit_template_ids().size() == 3, str(Kits.kit_template_ids()))

	# ================================================================ built-in templates
	check("built-in non-kit templates are all still there, unchanged", builtin_dump() == builtins_before)
	check("gd_len is there and unchanged", R.templates.has("gd_len") and var_to_str(R.templates.gd_len) == len_before)

	# clean up
	remove_tree(TMP)
	reload(Kits.DEFAULT_ROOTS)
	check("back to the default roots, the fake kit is not loaded", not R.templates.has("health:heal"))
	print("PUBLIC KIT FAILS: ", fails)
	quit(1 if fails else 0)
