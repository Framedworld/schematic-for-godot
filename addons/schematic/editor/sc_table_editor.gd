@tool
extends VBoxContainer
## Data Table editor (Unreal's Data Table view): one line per row, one column per field of the row structure.
## Text, numbers, checkboxes and enums are edited in the grid; the selected row is also shown in the Row Editor
## beside it, where every kind of field (textures, colours, vectors, other resources) can be edited. Every
## change is saved to the table's file and can be undone.

const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const TableScript := preload("res://addons/schematic/runtime/data_table.gd")

signal close_requested

var plugin: EditorPlugin
var table: Resource            # the Data Table being edited
var columns: Array = []        # property info of each field column
var problems: PackedStringArray = []

var _title: Label
var _struct_btn: Button
var _search: LineEdit
var _tree: Tree
var _status: Label
var _filling := false
var _inspected: Resource
var _inspector: EditorInspector
var _row_title: Label


func build_ui() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	add_child(bar)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", W.si(16))
	bar.add_child(_title)
	bar.add_child(VSeparator.new())
	_struct_btn = Button.new()
	_struct_btn.flat = true
	_struct_btn.tooltip_text = "The row structure: a Resource script whose exported variables are the columns. Click to change it."
	_struct_btn.pressed.connect(_pick_structure)
	bar.add_child(_struct_btn)
	bar.add_child(VSeparator.new())
	bar.add_child(_button("Add", "Add", "Add a row", func(): add_row()))
	bar.add_child(_button("Duplicate", "Duplicate", "Duplicate the selected row", func(): duplicate_row(selected_row())))
	bar.add_child(_button("Remove", "Remove", "Delete the selected row", func(): delete_row(selected_row())))
	bar.add_child(_button("", "MoveUp", "Move the selected row up", func(): move_row(selected_row(), -1)))
	bar.add_child(_button("", "MoveDown", "Move the selected row down", func(): move_row(selected_row(), 1)))
	bar.add_child(VSeparator.new())
	bar.add_child(_button("Import CSV", "Load", "Replace the rows with the contents of a CSV file", func(): _csv_dialog(true)))
	bar.add_child(_button("Export CSV", "Save", "Write the table to a CSV file", func(): _csv_dialog(false)))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_search = LineEdit.new()
	_search.placeholder_text = "Search rows"
	_search.right_icon = W.icon("Search")
	_search.clear_button_enabled = true
	_search.custom_minimum_size = W.sv(Vector2(220, 0))
	_search.text_changed.connect(func(_t): refresh())
	bar.add_child(_search)
	bar.add_child(_button("Close", "Close", "Back to the Schematic editor", func(): close_requested.emit()))
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.column_titles_visible = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.allow_reselect = true
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_selected.connect(_on_item_selected)
	_tree.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_DELETE and selected_row() != &"":
			delete_row(selected_row())
			_tree.accept_event())
	# the grid on the left, the selected row's own editor on the right (Unreal's Row Editor)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_tree)
	var side := VBoxContainer.new()
	side.custom_minimum_size = W.sv(Vector2(340, 0))
	split.add_child(side)
	_row_title = Label.new()
	_row_title.text = "Row Editor"
	side.add_child(_row_title)
	if Engine.is_editor_hint():
		_inspector = EditorInspector.new()
		_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_inspector.property_edited.connect(_on_inspector_edit)
		side.add_child(_inspector)
	_status = Label.new()
	_status.modulate = Color(1, 1, 1, 0.7)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)


func _button(text: String, icon_name: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = W.icon(icon_name)
	b.flat = true
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b


func edit(p_table: Resource) -> void:
	table = p_table
	problems = PackedStringArray()
	refresh()


func selected_row() -> StringName:
	var it := _tree.get_selected() if _tree else null
	return StringName(it.get_metadata(0)) if it else &""


# ---------------------------------------------------------------- showing the table

func refresh() -> void:
	if _tree == null or table == null:
		return
	var keep := selected_row()
	_filling = true
	_tree.clear()
	columns = table.get_columns()
	_title.text = table.resource_path.get_file() if table.resource_path != "" else "(unsaved table)"
	var scr: Script = table.row_script
	_struct_btn.text = "Row structure: %s" % ((String(scr.get_global_name()) if scr.get_global_name() != &"" else scr.resource_path.get_file()) if scr else "none - click to choose")
	_tree.columns = columns.size() + 1
	_tree.set_column_title(0, "Row Name")
	_tree.set_column_custom_minimum_width(0, 150)
	for i in columns.size():
		_tree.set_column_title(i + 1, String(columns[i].name).capitalize())
		_tree.set_column_custom_minimum_width(i + 1, 110)
		_tree.set_column_expand(i + 1, true)
	var root := _tree.create_item()
	var query := _search.text.strip_edges().to_lower()
	var shown := 0
	for row_name in table.get_row_names():
		var row: Resource = table.get_row(row_name)
		if query != "" and not _matches(row_name, row, query):
			continue
		var it := _tree.create_item(root)
		_fill_item(it, row_name, row)
		shown += 1
		if row_name == keep:
			it.select(0)
	_filling = false
	_show_row(selected_row())
	var text := "%d row%s" % [table.size(), "" if table.size() == 1 else "s"]
	if shown != table.size():
		text += ", %d shown" % shown
	if scr == null:
		text = "Choose a row structure to start: any Resource script with exported variables, such as a Schematic of type Data Asset."
	elif columns.is_empty():
		text += ". The row structure has no exported variables yet, so there are no columns."
	if not problems.is_empty():
		text += "\n" + "\n".join(problems)
	_status.text = text


func _matches(row_name: StringName, row: Resource, query: String) -> bool:
	if String(row_name).to_lower().contains(query):
		return true
	for col in columns:
		if TableScript.value_to_text(row.get(col.name) if row else null, col).to_lower().contains(query):
			return true
	return false


func _fill_item(it: TreeItem, row_name: StringName, row: Resource) -> void:
	it.set_metadata(0, row_name)
	it.set_text(0, String(row_name))
	it.set_editable(0, true)
	for i in columns.size():
		var col: Dictionary = columns[i]
		var c := i + 1
		var value: Variant = row.get(col.name) if row else null
		match int(col.type):
			TYPE_BOOL:
				it.set_cell_mode(c, TreeItem.CELL_MODE_CHECK)
				it.set_checked(c, bool(value))
				it.set_editable(c, true)
			TYPE_INT, TYPE_FLOAT:
				it.set_cell_mode(c, TreeItem.CELL_MODE_RANGE)
				if int(col.type) == TYPE_INT and int(col.get("hint", 0)) == PROPERTY_HINT_ENUM:
					var labels := PackedStringArray()
					var index := 0
					var parts := String(col.hint_string).split(",")
					for j in parts.size():
						var bits := parts[j].split(":")
						labels.append(bits[0])
						if (int(bits[1]) if bits.size() > 1 else j) == int(value):
							index = j
					it.set_text(c, ",".join(labels))
					it.set_range(c, index)
				else:
					var is_float := int(col.type) == TYPE_FLOAT
					it.set_range_config(c, -1e12, 1e12, 0.001 if is_float else 1.0)
					it.set_range(c, float(value) if value != null else 0.0)
				it.set_editable(c, true)
			TYPE_STRING, TYPE_STRING_NAME:
				it.set_text(c, String(value) if value != null else "")
				it.set_editable(c, true)
			TYPE_COLOR:
				it.set_text(c, "#" + (value as Color).to_html())
				it.set_custom_bg_color(c, value)
				it.set_custom_color(c, Color.BLACK if (value as Color).get_luminance() > 0.5 else Color.WHITE)
				it.set_tooltip_text(c, "Select the row and edit the colour in the Row Editor.")
			_:
				it.set_text(c, TableScript.value_to_text(value, col).get_file() if int(col.type) == TYPE_OBJECT else TableScript.value_to_text(value, col))
				it.set_tooltip_text(c, "Select the row and edit this field in the Row Editor.")
				if int(col.type) == TYPE_OBJECT and value is Texture2D:
					it.set_icon(c, value)
					it.set_icon_max_width(c, 24)


func _cell_value(it: TreeItem, c: int) -> Variant:
	var col: Dictionary = columns[c - 1]
	match int(col.type):
		TYPE_BOOL:
			return it.is_checked(c)
		TYPE_INT:
			if int(col.get("hint", 0)) == PROPERTY_HINT_ENUM:
				var parts := String(col.hint_string).split(",")
				var index := clampi(int(it.get_range(c)), 0, parts.size() - 1)
				var bits := parts[index].split(":")
				return int(bits[1]) if bits.size() > 1 else index
			return int(it.get_range(c))
		TYPE_FLOAT:
			return float(it.get_range(c))
		TYPE_STRING_NAME:
			return StringName(it.get_text(c))
	return it.get_text(c)


func _on_item_edited() -> void:
	if _filling or table == null:
		return
	var it := _tree.get_edited()
	var c := _tree.get_edited_column()
	var row_name := StringName(it.get_metadata(0))
	if c == 0:
		var wanted := StringName(it.get_text(0).strip_edges())
		if wanted == row_name:
			return
		if not rename_row(row_name, wanted):
			it.set_text(0, String(row_name))
		return
	set_cell(row_name, StringName(columns[c - 1].name), _cell_value(it, c))


func _on_item_selected() -> void:
	if _filling or table == null:
		return
	_show_row(selected_row())


func _show_row(row_name: StringName) -> void:
	_inspected = table.get_row(row_name) if table else null
	_row_title.text = ("Row Editor: %s" % row_name) if _inspected else "Row Editor"
	if _inspector and _inspector.get_edited_object() != _inspected:
		_inspector.edit(_inspected)


func _on_inspector_edit(_property: String) -> void:
	if table == null or _inspected == null:
		return
	_save(table)
	refresh.call_deferred()


# ---------------------------------------------------------------- changing the table

func _commit(title: String, do: Callable, undo: Callable) -> void:
	var ur := plugin.get_undo_redo() if plugin else null
	if ur == null:
		_run(table, do)
		return
	ur.create_action("Data Table: " + title, UndoRedo.MERGE_DISABLE, table)
	ur.add_do_method(self, "_run", table, do)
	ur.add_undo_method(self, "_run", table, undo)
	ur.commit_action()


func _run(target: Resource, change: Callable) -> void:
	change.call()
	_save(target)
	if target == table:
		refresh()


func _save(target: Resource) -> void:
	if target and target.resource_path != "":
		var err := ResourceSaver.save(target, target.resource_path)
		if err != OK:
			push_error("Could not save %s (%s)" % [target.resource_path, error_string(err)])


func add_row(row_name: StringName = &"") -> StringName:
	if table == null or table.row_script == null:
		return &""
	var nm: StringName = row_name if row_name != &"" else table.unique_name("Row")
	if table.has_row(nm):
		return &""
	var row: Resource = table.make_row()
	var t := table
	_commit("Add Row", func(): t.add_row(nm, row), func(): t.remove_row(nm))
	_select(nm)
	return nm


func duplicate_row(row_name: StringName) -> StringName:
	if table == null or not table.has_row(row_name):
		return &""
	var nm: StringName = table.unique_name(String(row_name))
	var copy: Resource = table.get_row(row_name).duplicate(true)
	var at: int = table.get_row_names().find(row_name) + 1
	var t := table
	_commit("Duplicate Row", func(): t.add_row(nm, copy, at), func(): t.remove_row(nm))
	_select(nm)
	return nm


func delete_row(row_name: StringName) -> void:
	if table == null or not table.has_row(row_name):
		return
	var row: Resource = table.get_row(row_name)
	var at: int = table.get_row_names().find(row_name)
	var t := table
	_commit("Delete Row", func(): t.remove_row(row_name), func(): t.add_row(row_name, row, at))


func rename_row(old_name: StringName, new_name: StringName) -> bool:
	if table == null or new_name == &"" or table.has_row(new_name) or not table.has_row(old_name):
		return false
	var t := table
	_commit("Rename Row", func(): t.rename_row(old_name, new_name), func(): t.rename_row(new_name, old_name))
	_select(new_name)
	return true


func move_row(row_name: StringName, delta: int) -> void:
	if table == null or not table.has_row(row_name):
		return
	var from: int = table.get_row_names().find(row_name)
	var to := clampi(from + delta, 0, table.size() - 1)
	if to == from:
		return
	var t := table
	_commit("Move Row", func(): t.move_row(row_name, to), func(): t.move_row(row_name, from))
	_select(row_name)


func set_cell(row_name: StringName, field: StringName, value: Variant) -> void:
	if table == null or not table.has_row(row_name):
		return
	var row: Resource = table.get_row(row_name)
	var before: Variant = row.get(field)
	if typeof(before) == typeof(value) and before == value:
		return
	_commit("Edit %s" % field, func(): row.set(field, value), func(): row.set(field, before))
	_select(row_name)


func set_structure(script: Script) -> void:
	if table == null:
		return
	var before: Script = table.row_script
	var t := table
	_commit("Set Row Structure", func(): t.row_script = script, func(): t.row_script = before)


func import_csv(text: String) -> PackedStringArray:
	if table == null:
		return PackedStringArray()
	var before: Dictionary = table.rows.duplicate()
	var order_before: Array[StringName] = table.get_row_names()
	var t := table
	var result := []
	_commit("Import CSV", func(): result.append(t.from_csv(text)), func():
		t.rows = before.duplicate()
		t.order = order_before.duplicate())
	problems = result[0] if not result.is_empty() else PackedStringArray()
	refresh()
	return problems


func _select(row_name: StringName) -> void:
	var root := _tree.get_root()
	if root == null:
		return
	for it in root.get_children():
		if StringName(it.get_metadata(0)) == row_name:
			it.select(0)
			_tree.scroll_to_item(it)


func _pick_structure() -> void:
	var items := []
	for cls in R.data_classes():
		items.append({"label": cls, "value": String(T.globals()[cls].path), "icon": W.icon("Object")})
	if items.is_empty():
		_status.text = "There is no row structure to choose yet. Create one first: New Schematic > Data Asset, add a variable for each column, compile."
		return
	W.popup_search(_struct_btn, items, func(path: String): set_structure(load(path)), "Row Structure")


func _csv_dialog(importing: bool) -> void:
	if table == null:
		return
	var fd := EditorFileDialog.new()
	fd.access = EditorFileDialog.ACCESS_FILESYSTEM
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE if importing else EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.add_filter("*.csv", "Comma-separated values")
	fd.title = "Import CSV (replaces the rows)" if importing else "Export CSV"
	if not importing:
		fd.current_file = table.resource_path.get_file().get_basename() + ".csv"
	fd.file_selected.connect(func(path: String):
		if importing:
			import_csv(FileAccess.get_file_as_string(path))
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(table.to_csv())
				f.close()
				_status.text = "Exported %d rows to %s" % [table.size(), path])
	fd.visibility_changed.connect(func():
		if not fd.visible:
			fd.queue_free())
	EditorInterface.get_base_control().add_child(fd)
	fd.popup_file_dialog()
