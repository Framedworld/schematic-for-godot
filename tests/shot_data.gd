extends RefCounted
## Editor self-test: a Data Asset, a Data Table edited in the table editor, and a graph that reads it.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_data.gd
## With `-- --sc-selftest=res://tests/shot_data.gd --keep-demo` it writes the same things to res://demo/data
## and leaves them there as a sample.
const Scan := preload("res://tests/editor_scan.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")

var run_id := ResourceUID.id_to_text(ResourceUID.create_id()).trim_prefix("uid://")
var DIR := "res://demo/tmp_data_" + run_id
var ROW := "SC_TRow_" + run_id
var keep := false
var passed := 0
var failed := 0
var tree: SceneTree
var ed
var plugin: EditorPlugin


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_data.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	note("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func create(parent: String, starter: String, file: String) -> String:
	ed._new_schematic_file(parent, null, starter)
	await frames(6)
	var path := "%s/%s.gd" % [DIR, file]
	for c in EditorInterface.get_base_control().get_children():
		if c is EditorFileDialog and c.visible:
			c.file_selected.emit(path)
			c.hide()
	await frames(10)
	return path


func rows_shown(te) -> Array:
	var out := []
	for it in te._tree.get_root().get_children():
		out.append(it.get_text(0))
	return out


func cleanup() -> void:
	plugin.show_table(false)
	for i in range(ed.docs.size() - 1, -1, -1):
		if String(ed.docs[i].path).begins_with(DIR):
			ed.docs[i].dirty = false
			ed._close_doc(i)
	if keep:
		return
	await Scan.idle(tree)
	plugin.table_editor.table = null
	var dir := DirAccess.open(DIR)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	await Scan.rescan(tree)


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	keep = OS.get_cmdline_user_args().has("--keep-demo")
	if keep:
		DIR = "res://demo/data"
		ROW = "SC_ItemRow"
	note("--- start%s" % (" (writing the sample to demo/data)" if keep else ""))
	tree.create_timer(110.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit(1))
	await Scan.idle(tree)
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.6).timeout
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var te = p.table_editor

	# 1. the row structure, from the Data Asset starter
	var row_path := await create("Resource", "data_asset", ROW)
	check("Data Asset starter opens with no errors", ed.doc.path == row_path and ed.doc.errors.is_empty() and ed.doc.bp.get("library", "") == "data", str(ed.doc.errors))
	check("its variables compile to exported fields", FileAccess.get_file_as_string(row_path).contains("@export var display_name: String") and FileAccess.get_file_as_string(row_path).contains("extends Resource"))
	await Scan.rescan(tree)
	var waited := 0.0
	while waited < 15.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		T.refresh_globals()
		if T.globals().has(ROW) and T.globals().has("DataTable") and not EditorInterface.get_resource_filesystem().is_scanning():
			break
	check("the structure and DataTable are registered classes", T.globals().has(ROW) and T.globals().has("DataTable"), "after %.1fs" % waited)

	# 2. New Data Table offers the structure
	p.new_table_dialog(DIR)
	await frames(8)
	var offered := []
	for c in EditorInterface.get_base_control().get_children():
		if c is PopupPanel and c.visible:
			for list in c.find_children("*", "ItemList", true, false):
				for i in list.item_count:
					offered.append(list.get_item_text(i))
			c.hide()
	check("New Data Table lists the row structures", offered.has(ROW), str(offered))
	await frames(4)
	var table_path := DIR + ("/DT_Items.tres" if keep else "/DT_T.tres")
	var table: Resource = p.create_table(table_path, row_path)
	await frames(10)
	check("a new table opens in the table editor", table != null and te.visible and not ed.visible and te.table == table and FileAccess.file_exists(table_path), "table editor visible %s" % te.visible)
	check("columns are the structure's fields", te._tree.columns == 6 and te._tree.get_column_title(1) == "Display Name" and te._tree.get_column_title(5) == "Stackable", "%d columns" % te._tree.columns)

	# 3. rows
	var a: StringName = te.add_row()
	var b: StringName = te.add_row()
	te.add_row()
	await frames(4)
	check("Add makes uniquely named rows", rows_shown(te) == ["Row", "Row_1", "Row_2"] and a == &"Row" and b == &"Row_1", str(rows_shown(te)))
	check("renaming to a name in use is refused", not te.rename_row(&"Row", &"Row_1"))
	te.rename_row(&"Row", &"sword")
	te.rename_row(&"Row_1", &"potion")
	te.rename_row(&"Row_2", &"gem")
	te.set_cell(&"sword", &"display_name", "Iron Sword")
	te.set_cell(&"sword", &"value", 120)
	te.set_cell(&"sword", &"weight", 3.5)
	te.set_cell(&"sword", &"stackable", false)
	te.set_cell(&"potion", &"display_name", "Small Potion")
	te.set_cell(&"potion", &"value", 15)
	te.set_cell(&"gem", &"display_name", "Ruby")
	te.set_cell(&"gem", &"value", 400)
	te.set_cell(&"gem", &"weight", 0.1)
	await frames(4)
	var first: TreeItem = te._tree.get_root().get_child(0)
	check("the grid shows the values in editable cells", first.get_text(0) == "sword" and first.get_text(1) == "Iron Sword" and first.get_range(3) == 120.0 and is_equal_approx(first.get_range(4), 3.5)
		and first.is_checked(5) == false and first.is_editable(1) and first.is_editable(3) and first.is_editable(5), "%s %s %s" % [first.get_text(1), first.get_range(3), first.get_range(4)])
	var on_disk: Resource = ResourceLoader.load(table_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check("every change is saved to the file", on_disk != null and on_disk.size() == 3 and on_disk.get_row(&"sword").display_name == "Iron Sword" and on_disk.get_row(&"gem").value == 400
		and str(on_disk.get_row_names()) == "[&\"sword\", &\"potion\", &\"gem\"]", str(on_disk.get_row_names()) if on_disk else "not loadable")

	# 4. undo and redo
	var ur := p.get_undo_redo()
	var history: UndoRedo = ur.get_history_undo_redo(ur.get_object_history_id(table))
	te.edit(table.duplicate(true))
	history.undo()
	await frames(4)
	on_disk = ResourceLoader.load(table_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check("undo saves its original table while another table is open", is_equal_approx(on_disk.get_row(&"gem").weight, 1.0))
	te.edit(table)
	check("undo takes back the last cell edit", is_equal_approx(table.get_row(&"gem").weight, 1.0), str(table.get_row(&"gem").weight))
	history.redo()
	await frames(4)
	check("redo puts it back", is_equal_approx(table.get_row(&"gem").weight, 0.1))

	# 5. duplicate, move, delete, search
	var copy: StringName = te.duplicate_row(&"sword")
	te.set_cell(copy, &"display_name", "Steel Sword")
	te.move_row(&"gem", -2)   # from the end, up past potion and the copy
	await frames(4)
	check("duplicate goes below its source; rows move", rows_shown(te) == ["sword", "gem", "sword_1", "potion"] and table.get_row(copy).value == 120 and table.get_row(copy) != table.get_row(&"sword"), str(rows_shown(te)))
	te._search.text = "sword"
	te.refresh()
	check("search filters by name and by any cell", rows_shown(te) == ["sword", "sword_1"] and te._status.text.contains("2 shown"), str(rows_shown(te)))
	te._search.text = "ruby"
	te.refresh()
	check("search finds text inside cells", rows_shown(te) == ["gem"])
	te._search.text = ""
	te.refresh()
	if not keep:
		te.delete_row(copy)
		await frames(4)
		check("delete removes the row", rows_shown(te) == ["sword", "gem", "potion"] and not table.has_row(copy))
		history.undo()
		await frames(4)
		check("undo brings a deleted row back in its place", rows_shown(te) == ["sword", "gem", "sword_1", "potion"] and table.get_row(copy).display_name == "Steel Sword", str(rows_shown(te)))

	# 6. selecting a row shows it in the Row Editor, and edits made there come back to the grid
	te._select(&"potion")
	te._on_item_selected()
	await frames(6)
	var inspected: Object = te._inspector.get_edited_object()
	check("selecting a row shows it in the Row Editor", inspected == table.get_row(&"potion") and te.visible and te._row_title.text == "Row Editor: potion", str(inspected))
	if inspected:
		inspected.set("weight", 0.25)
		te._inspector.property_edited.emit("weight")
		await frames(6)
		var potion_item: TreeItem = null
		for it in te._tree.get_root().get_children():
			if it.get_text(0) == "potion":
				potion_item = it
		check("a Row Editor edit shows in the grid and is saved", potion_item != null and is_equal_approx(potion_item.get_range(4), 0.25)
			and is_equal_approx(ResourceLoader.load(table_path, "", ResourceLoader.CACHE_MODE_IGNORE).get_row(&"potion").weight, 0.25))
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/look_21_data_table.png")

	# 7. CSV
	var csv: String = table.to_csv()
	if not keep:
		var problems: PackedStringArray = te.import_csv("Name,display_name,value,mood\nbolt,Bolt,7,happy\nnut,Nut,oops,\n")
		await frames(4)
		check("Import CSV replaces the rows and reports problems", rows_shown(te) == ["bolt", "nut"] and table.get_row(&"bolt").value == 7 and problems.size() == 2 and te._status.text.contains("mood"), str(problems))
		history.undo()
		await frames(4)
		check("undo restores the rows from before the import", rows_shown(te) == ["sword", "gem", "sword_1", "potion"], str(rows_shown(te)))
	check("Export CSV text has a header and every row", csv.begins_with("Name,display_name,icon,value,weight,stackable") and csv.count("\n") == 5, csv.get_slice("\n", 0))

	# 8. Close goes back to graphs; opening the file comes back
	te.close_requested.emit()
	await frames(4)
	check("Close returns to the Schematic editor", ed.visible and not te.visible)
	EditorInterface.edit_resource(load(table_path))
	await frames(8)
	check("opening the table file shows the table editor again", te.visible and not ed.visible and te.table.resource_path == table_path)
	plugin.show_table(false)

	# 9. a graph reads the table
	var user_path := await create("Node", "", "SC_Shop" if keep else "SC_TUser_" + run_id)
	var ids := {}
	ed.mutate("Read the table", func():
		var bp: Dictionary = ed.doc.bp
		var g: Dictionary = bp.graphs[0]
		var ready: Dictionary = g.nodes[0]
		var look := Model.add_node(g, "table_row", Vector2(340, 80), {"table": table_path, "cls": ROW})
		var brk := Model.add_node(g, "break", Vector2(680, 240), {"type": ROW})
		var fmt := Model.add_node(g, "format", Vector2(980, 240), {"text": "{name} costs {price}"})
		var pr := Model.add_node(g, "print", Vector2(1280, 80), {})
		var miss := Model.add_node(g, "print", Vector2(680, 460), {})
		miss.d["text"] = "\"No such item\""
		g.wires.append([ready.id, "then", look.id, "exec"])
		g.wires.append([look.id, "found", pr.id, "exec"])
		g.wires.append([look.id, "not_found", miss.id, "exec"])
		g.wires.append([look.id, "row_out", brk.id, "v"])
		g.wires.append([brk.id, "m_display_name", fmt.id, "f_name"])
		g.wires.append([brk.id, "m_value", fmt.id, "f_price"])
		g.wires.append([fmt.id, "ret", pr.id, "text"])
		ids["look"] = int(look.id))
	await frames(6)
	ed._select({"kind": "node", "id": ids.look}, false)
	await frames(6)
	var row_box: OptionButton = null
	for ob in ed._details.find_children("*", "OptionButton", true, false):
		if ob.item_count >= 4 and ob.get_item_text(1) == "sword":
			row_box = ob
	check("the node's Details list the table's rows", row_box != null, "found %s" % (row_box != null))
	if row_box:
		row_box.item_selected.emit(1)
		await frames(6)
		var look_node: Dictionary = Model.find_node(ed.cur_graph(), ids.look)
		check("picking a row sets the Row Name pin", String(look_node.d.get("row", "")) == "&\"sword\"", String(look_node.d.get("row", "")))
	var ok: bool = ed.compile_doc(ed.doc, true)
	var user_code := FileAccess.get_file_as_string(user_path)
	check("the schematic compiles against the real classes", ok and ed.doc.errors.is_empty() and user_code.contains(".get_row(&\"sword\") as " + ROW), str(ed.doc.errors))
	var look_gn: GraphNode = ed._view.get_node_or_null("n%d" % ids.look)
	check("the node is drawn with the table's name", look_gn != null and look_gn.title == "Get Data Table Row")
	await tree.create_timer(0.5).timeout
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png("res://tests/out/look_22_data_graph.png")

	await cleanup()
	note("passed %d, failed %d" % [passed, failed])
	tree.quit(1 if failed else 0)
