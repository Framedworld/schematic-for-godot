extends SceneTree
## Data assets (struct-like Resource schematics), Data Tables and the nodes that read them.
## Run: godot --headless --path . --script res://tests/test_data.gd
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const Table := preload("res://addons/schematic/runtime/data_table.gd")

const DIR := "res://tests/tmp/data/"
var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func wire(g: Dictionary, a: Dictionary, ap: String, b: Dictionary, bp_: String) -> void:
	g.wires.append([a.id, ap, b.id, bp_])


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()

	# ================================================================ the data asset schematic
	var item := Starters.build("data_asset", "SC_TItem")
	item.variables.append({"name": "rarity", "type": "int", "default": "1", "export": false, "category": "", "tooltip": ""})
	item.variables.append({"name": "tint", "type": "Color", "default": "Color(1, 0, 0, 1)", "export": false, "category": "", "tooltip": ""})
	var c := Compiler.new()
	var code := c.compile(item)
	check("data asset compiles", c.errors.filter(func(e): return not e.w).is_empty(), str(c.errors))
	check("every variable is an exported field of a Resource", code.contains("extends Resource") and code.contains("class_name SC_TItem")
		and code.contains("@export var display_name: String") and code.contains("@export var rarity: int = 1") and code.contains("@export var tint: Color"))
	var no_name := item.duplicate(true)
	no_name["class_name"] = ""
	var c2 := Compiler.new()
	c2.compile(no_name)
	check("a data asset without a class name is an error", c2.errors.any(func(e): return String(e.m).contains("needs a Class Name")))
	var item_path := DIR + "SC_TItem.gd"
	var f := FileAccess.open(item_path, FileAccess.WRITE)
	f.store_string(Model.build_source(code, item))
	f.close()
	T._globals["SC_TItem"] = {"base": "Resource", "path": item_path}   # the editor test registers it for real
	var item_script := load(item_path) as Script
	check("the generated script loads", item_script != null)

	# ================================================================ the table at run time
	var table: Resource = Table.new()
	table.row_script = item_script
	var cols: Array = table.get_columns().map(func(col): return String(col.name))
	check("columns are the structure's fields, in order", cols == ["display_name", "icon", "value", "weight", "stackable", "rarity", "tint"], str(cols))
	var sword: Resource = table.add_row(&"sword")
	sword.display_name = "Iron Sword"
	sword.value = 120
	sword.weight = 3.5
	sword.stackable = false
	var potion: Resource = table.add_row(&"potion")
	potion.display_name = "Potion, small"
	potion.value = 15
	var gem: Resource = table.add_row(&"gem")
	gem.display_name = "Gem \"Ruby\""
	gem.value = 120
	gem.tint = Color(0.9, 0.1, 0.2)
	check("rows are instances of the structure with its defaults", sword.get_script() == item_script and potion.weight == 1.0 and potion.stackable == true and potion.rarity == 1)
	check("rows keep their order and are found by name", str(table.get_row_names()) == "[&\"sword\", &\"potion\", &\"gem\"]" and table.get_row(&"potion") == potion and table.get_row(&"nope") == null, str(table.get_row_names()))
	check("a name can't be used twice", table.add_row(&"sword") == null and table.size() == 3)
	check("find rows by a field's value", table.find_rows(&"value", 120) == [sword, gem] and table.get_row_name(gem) == &"gem")
	check("rename keeps the row and its place", table.rename_row(&"potion", &"elixir") and str(table.get_row_names()) == "[&\"sword\", &\"elixir\", &\"gem\"]" and table.get_row(&"elixir") == potion
		and not table.rename_row(&"elixir", &"gem"))
	table.move_row(&"gem", 0)
	check("rows can be moved", str(table.get_row_names()) == "[&\"gem\", &\"sword\", &\"elixir\"]", str(table.get_row_names()))
	check("unique names", table.unique_name("gem") == &"gem_1" and table.unique_name("Row") == &"Row")

	# saved to a file and loaded back
	var table_path := DIR + "DT_TItems.tres"
	check("the table saves", ResourceSaver.save(table, table_path) == OK)
	var loaded: Resource = ResourceLoader.load(table_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check("and loads back with its rows", loaded != null and loaded.size() == 3 and loaded.get_row(&"sword").display_name == "Iron Sword" and loaded.get_row(&"sword").weight == 3.5
		and loaded.get_row(&"gem").tint.is_equal_approx(Color(0.9, 0.1, 0.2)) and str(loaded.get_row_names()) == str(table.get_row_names()))

	# CSV out and back
	var csv: String = table.to_csv()
	check("CSV has a header and quotes what needs it", csv.begins_with("Name,display_name,icon,value,weight,stackable,rarity,tint\n") and csv.contains("\"Potion, small\"") and csv.contains("\"Gem \"\"Ruby\"\"\""), csv.get_slice("\n", 1))
	var copy: Resource = Table.new()
	copy.row_script = item_script
	var problems: PackedStringArray = copy.from_csv(csv)
	var same: bool = problems.is_empty() and copy.size() == 3
	for nm in table.get_row_names():
		for col in table.get_columns():
			if same and str(copy.get_row(nm).get(col.name)) != str(table.get_row(nm).get(col.name)):
				same = false
				problems.append("%s.%s: %s != %s" % [nm, col.name, copy.get_row(nm).get(col.name), table.get_row(nm).get(col.name)])
	check("CSV reads back to the same table", same, str(problems))
	problems = copy.from_csv("Name,value,weight,colour\nbolt,7,heavy,red\nbolt,1,1,\n,2,2,\nnut,x3,0.5,\n")
	check("CSV problems are reported and the rest is imported", copy.size() == 2 and copy.get_row(&"bolt").value == 7 and copy.get_row(&"bolt").weight == 1.0 and copy.get_row(&"nut").weight == 0.5
		and problems.size() == 5, "%d rows, problems: %s" % [copy.size(), str(problems)])

	# ================================================================ nodes
	var fields := R.data_fields("SC_TItem")
	check("the registry sees the data class and its defaults", R.data_classes().has("SC_TItem") and fields.size() == 7 and fields[2] == ["value", "int", "0"] and fields[3] == ["weight", "float", "1.0"], str(fields))
	var labels: Array = R.data_actions().map(func(a): return String(a.l))
	check("Make, Break and Get Data Table Row are offered", labels.has("Make SC_TItem") and labels.has("Break SC_TItem") and labels.has("Get Data Table Row") and labels.has("Get Row Names"), str(labels.slice(0, 6)))
	var info := R.table_info(table_path)
	check("a table file tells its row structure and row names", info.cls == "SC_TItem" and info.rows == ["gem", "sword", "elixir"], str(info))

	var user := Model.new_schematic("Node", "")
	for v in [["found_value", "int"], ["found_name", "String"], ["missing", "bool"], ["made_weight", "float"], ["made_name", "String"], ["count", "int"]]:
		user.variables.append({"name": v[0], "type": v[1], "default": "", "export": false, "category": "", "tooltip": ""})
	var g: Dictionary = user.graphs[0]
	g.nodes.remove_at(1)
	var seq := Model.add_node(g, "sequence", Vector2(300, 80), {"n": 4})
	var look := Model.add_node(g, "table_row", Vector2(560, 80), {"table": table_path, "cls": "SC_TItem"})
	look.d["row"] = "&\"sword\""
	var brk := Model.add_node(g, "break", Vector2(860, 240), {"type": "SC_TItem"})
	var set_value := Model.add_node(g, "var_set", Vector2(1100, 80), {"name": "found_value"})
	var set_name := Model.add_node(g, "var_set", Vector2(1380, 80), {"name": "found_name"})
	var look2 := Model.add_node(g, "table_row", Vector2(560, 480), {"table": table_path, "cls": "SC_TItem"})
	look2.d["row"] = "&\"dragon\""
	var set_missing := Model.add_node(g, "var_set", Vector2(900, 560), {"name": "missing"})
	set_missing.d["value"] = "true"
	var make := Model.add_node(g, "make_data", Vector2(560, 800), {"cls": "SC_TItem"})
	make.d["f_display_name"] = "\"Made here\""
	make.d["f_weight"] = "9.5"
	var brk2 := Model.add_node(g, "break", Vector2(860, 800), {"type": "SC_TItem"})
	var set_weight := Model.add_node(g, "var_set", Vector2(1100, 760), {"name": "made_weight"})
	var set_made := Model.add_node(g, "var_set", Vector2(1380, 760), {"name": "made_name"})
	var tbl := Model.add_node(g, "const", Vector2(300, 1100), {"expr": "preload(\"%s\")" % table_path, "t": "DataTable", "label": "DT_TItems"})
	var size := Model.add_node(g, "call", Vector2(600, 1100), {"cls": "DataTable", "method": "size"})
	var set_count := Model.add_node(g, "var_set", Vector2(900, 1060), {"name": "count"})
	wire(g, g.nodes[0], "then", seq, "exec")
	wire(g, seq, "then_0", look, "exec")
	wire(g, look, "found", set_value, "exec")
	wire(g, look, "row_out", brk, "v")
	wire(g, brk, "m_value", set_value, "value")
	wire(g, set_value, "then", set_name, "exec")
	wire(g, brk, "m_display_name", set_name, "value")
	wire(g, seq, "then_1", look2, "exec")
	wire(g, look2, "not_found", set_missing, "exec")
	wire(g, seq, "then_2", set_weight, "exec")
	wire(g, make, "ret", brk2, "v")
	wire(g, brk2, "m_weight", set_weight, "value")
	wire(g, set_weight, "then", set_made, "exec")
	wire(g, brk2, "m_display_name", set_made, "value")
	wire(g, seq, "then_3", set_count, "exec")
	wire(g, tbl, "value", size, "target")
	wire(g, size, "ret", set_count, "value")
	var ld := R.describe(look, user, g)
	var md := R.describe(make, user, g)
	var bd := R.describe(brk, user, g)
	check("Get Data Table Row: Row Found / Row Not Found and a typed Out Row", ld.err == "" and ld.outs.map(func(p): return String(p.id)) == ["found", "not_found", "row_out"] and ld.outs[2].type == "SC_TItem" and ld.sub == "DT_TItems.tres")
	check("Make has a pin per field with the structure's defaults", md.pure and md.ins.size() == 7 and md.ins[3].get("def", "") == "1.0" and md.outs[0].type == "SC_TItem", str(md.ins.map(func(p): return [p.id, p.get("def", "")])))
	check("Break has a typed pin per field", bd.outs.size() == 7 and bd.outs[2].type == "int" and bd.outs[0].type == "String")
	var cu := Compiler.new()
	var user_code := cu.compile(user)
	var errs := cu.errors.filter(func(e): return not e.w).map(func(e): return String(e.m))
	check("a schematic using them compiles", errs.is_empty() and user_code.contains(".get_row(&\"sword\") as SC_TItem") and user_code.contains("__sc_make_SC_TItem("), str(errs))
	var unset := user.duplicate(true)
	unset.graphs[0].nodes[2].p["table"] = ""
	var cn := Compiler.new()
	cn.compile(unset)
	check("a row lookup with no table is an error on the node", cn.errors.any(func(e): return String(e.m).contains("needs a table")))
	# run it (this process has not registered the class, so its name is swapped for the script)
	var runnable := user_code.replace(": SC_TItem", "").replace(" as SC_TItem", "").replace("-> SC_TItem", "-> Resource").replace("SC_TItem.new()", "load(\"%s\").new()" % item_path)
	var scr := GDScript.new()
	scr.source_code = runnable
	if scr.reload() == OK:
		var n := Node.new()
		n.set_script(scr)
		root.add_child(n)
		await process_frame
		check("it runs: found row, missing row, made struct, table size", n.found_value == 120 and n.found_name == "Iron Sword" and n.missing == true and n.made_weight == 9.5
			and n.made_name == "Made here" and n.count == 3, "%s %s %s %s %s %s" % [n.found_value, n.found_name, n.missing, n.made_weight, n.made_name, n.count])
		n.queue_free()
	else:
		check("the generated code loads", false)
		print(runnable)

	T._globals.erase("SC_TItem")
	var dir := DirAccess.open(DIR)
	for file in dir.get_files():
		dir.remove(file)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	print("DATA FAILS: ", fails)
	quit(1 if fails else 0)
