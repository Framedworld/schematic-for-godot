@tool
class_name DataTable
extends Resource
## A table of named rows that all share one structure (Unreal's Data Table). The structure is any Resource
## script with exported variables, usually a Schematic of type Data Asset; each row is one instance of it,
## stored inside the table's .tres file.
##
## In a graph use the Get Data Table Row node; from GDScript:
##   var sword: ItemRow = preload("res://items.tres").get_row(&"sword")

## The script every row is an instance of.
@export var row_script: Script
## Row name -> row.
@export var rows: Dictionary = {}
## The row names in display order (a saved Dictionary does not keep its order).
@export var order: Array[StringName] = []


func size() -> int:
	return rows.size()


func has_row(row_name: StringName) -> bool:
	return rows.has(row_name)


## The row with this name, or null.
func get_row(row_name: StringName) -> Resource:
	return rows.get(row_name)


func get_row_names() -> Array[StringName]:
	var out: Array[StringName] = []
	var seen := {}
	for key in order:
		if rows.has(key) and not seen.has(key):
			seen[key] = true
			out.append(key)
	for key in rows:   # rows added to the dictionary directly
		if not seen.has(StringName(key)):
			out.append(StringName(key))
	return out


func get_rows() -> Array[Resource]:
	var out: Array[Resource] = []
	for key in get_row_names():
		out.append(rows[key])
	return out


## The name a row is stored under, or &"" when it is not in this table.
func get_row_name(row: Resource) -> StringName:
	for key in get_row_names():
		if rows[key] == row:
			return key
	return &""


## Every row whose field equals the value.
func find_rows(field: StringName, value: Variant) -> Array[Resource]:
	var out: Array[Resource] = []
	for key in get_row_names():
		if rows[key] != null and rows[key].get(field) == value:
			out.append(rows[key])
	return out


## A new row of the table's structure, not yet added.
func make_row() -> Resource:
	if row_script == null:
		return null
	# Built from the native base class so it also works inside the editor, where scripts do not run.
	var row: Resource = ClassDB.instantiate(row_script.get_instance_base_type())
	row.set_script(row_script)
	return row


## Adds a row (a new empty one when none is given) at the end or at `index`. Returns it, or null when the
## name is taken or the table has no structure yet.
func add_row(row_name: StringName, row: Resource = null, index := -1) -> Resource:
	if row_name == &"" or rows.has(row_name):
		return null
	if row == null:
		row = make_row()
	if row == null:
		return null
	var names := get_row_names()
	rows[row_name] = row
	names.insert(index if (index >= 0 and index < names.size()) else names.size(), row_name)
	order = names
	emit_changed()
	return row


func remove_row(row_name: StringName) -> void:
	if rows.erase(row_name):
		order = get_row_names()
		emit_changed()


## Renames a row in place. False when the new name is empty or taken.
func rename_row(old_name: StringName, new_name: StringName) -> bool:
	if new_name == &"" or not rows.has(old_name) or (rows.has(new_name) and new_name != old_name):
		return false
	var names := get_row_names()
	names[names.find(old_name)] = new_name
	var row: Resource = rows[old_name]
	rows.erase(old_name)
	rows[new_name] = row
	order = names
	emit_changed()
	return true


func move_row(row_name: StringName, index: int) -> void:
	if not rows.has(row_name):
		return
	var names := get_row_names()
	names.erase(row_name)
	names.insert(clampi(index, 0, names.size()), row_name)
	order = names
	emit_changed()


## A unique row name starting from `base` ("Row", "Row_1", ...).
func unique_name(base: String = "Row") -> StringName:
	if not rows.has(StringName(base)):
		return StringName(base)
	var i := 1
	while rows.has(StringName("%s_%d" % [base, i])):
		i += 1
	return StringName("%s_%d" % [base, i])


## The table's columns: the exported variables of the row structure, as property info dictionaries.
func get_columns() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if row_script == null:
		return out
	var chain: Array[Script] = []
	var scr := row_script
	while scr != null:
		chain.push_front(scr)
		scr = scr.get_base_script()
	var seen := {}
	for s in chain:
		for prop in s.get_script_property_list():
			var usage := int(prop.usage)
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and not seen.has(prop.name):
				seen[prop.name] = true
				out.append(prop)
	return out


# ---------------------------------------------------------------- CSV

## The table as CSV text: a header line (Name, then the columns) and one line per row. Text columns are
## written as they are; everything else in Godot's own text form, so it reads back exactly.
func to_csv() -> String:
	var columns := get_columns()
	var lines := PackedStringArray()
	var header := PackedStringArray(["Name"])
	for col in columns:
		header.append(String(col.name))
	lines.append(_csv_line(header))
	for key in get_row_names():
		var cells := PackedStringArray([String(key)])
		for col in columns:
			cells.append(value_to_text(rows[key].get(col.name) if rows[key] != null else null, col))
		lines.append(_csv_line(cells))
	return "\n".join(lines) + "\n"


## Replaces the rows with the ones in the CSV text. Columns are matched by their header; unknown columns are
## ignored and missing ones keep their default. Returns the problems found (empty when all went well).
func from_csv(text: String) -> PackedStringArray:
	var problems := PackedStringArray()
	var records := _csv_records(text)
	if records.is_empty():
		problems.append("The file is empty.")
		return problems
	if row_script == null:
		problems.append("The table has no row structure.")
		return problems
	var columns := {}
	for col in get_columns():
		columns[String(col.name)] = col
	var header: PackedStringArray = records[0]
	var rebuilt := {}
	var names: Array[StringName] = []
	for r in range(1, records.size()):
		var cells: PackedStringArray = records[r]
		if cells.size() == 1 and cells[0].strip_edges() == "":
			continue
		var row_name := StringName(cells[0].strip_edges())
		if row_name == &"" or rebuilt.has(row_name):
			problems.append("Line %d: the row name '%s' is empty or used twice; skipped." % [r + 1, cells[0]])
			continue
		var row := make_row()
		for c in range(1, mini(cells.size(), header.size())):
			var field := header[c].strip_edges()
			if not columns.has(field):
				continue
			var parsed: Array = text_to_value(cells[c], columns[field])
			if parsed[0]:
				row.set(field, parsed[1])
			else:
				problems.append("Line %d: '%s' is not a valid %s for %s; the default is kept." % [r + 1, cells[c], type_string(int(columns[field].type)), field])
		rebuilt[row_name] = row
		names.append(row_name)
	for c in range(1, header.size()):
		if not columns.has(header[c].strip_edges()):
			problems.append("Column '%s' is not a field of the row structure; ignored." % header[c])
	rows = rebuilt
	order = names
	emit_changed()
	return problems


## One cell as text (also what the table editor shows).
static func value_to_text(value: Variant, column: Dictionary) -> String:
	match typeof(value):
		TYPE_NIL:
			return ""
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(value)
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			if int(column.get("hint", 0)) == PROPERTY_HINT_ENUM:
				var names := String(column.get("hint_string", "")).split(",")
				for i in names.size():
					var parts := names[i].split(":")
					if (int(parts[1]) if parts.size() > 1 else i) == int(value):
						return parts[0]
			return str(value)
		TYPE_FLOAT:
			return str(value)
		TYPE_OBJECT:
			return String(value.resource_path) if (value is Resource and value.resource_path != "") else ""
	return var_to_str(value)


## Parses a cell for a column: [ok, value].
static func text_to_value(text: String, column: Dictionary) -> Array:
	var t := int(column.type)
	var trimmed := text.strip_edges()
	match t:
		TYPE_STRING:
			return [true, text]
		TYPE_STRING_NAME:
			return [true, StringName(text)]
		TYPE_NODE_PATH:
			return [true, NodePath(text)]
		TYPE_BOOL:
			if trimmed.to_lower() in ["true", "yes", "1"]:
				return [true, true]
			if trimmed.to_lower() in ["false", "no", "0", ""]:
				return [true, false]
			return [false, null]
		TYPE_INT:
			if int(column.get("hint", 0)) == PROPERTY_HINT_ENUM:
				var names := String(column.get("hint_string", "")).split(",")
				for i in names.size():
					var parts := names[i].split(":")
					if parts[0].strip_edges().to_lower() == trimmed.to_lower():
						return [true, int(parts[1]) if parts.size() > 1 else i]
			if trimmed == "":
				return [true, 0]
			if trimmed.is_valid_int():
				return [true, trimmed.to_int()]
			return [trimmed.is_valid_float(), int(trimmed.to_float())]
		TYPE_FLOAT:
			if trimmed == "":
				return [true, 0.0]
			return [trimmed.is_valid_float(), trimmed.to_float()]
		TYPE_OBJECT:
			if trimmed == "":
				return [true, null]
			if ResourceLoader.exists(trimmed):
				return [true, load(trimmed)]
			return [false, null]
		TYPE_NIL:
			var any_value: Variant = str_to_var(trimmed)
			return [true, any_value if (any_value != null or trimmed == "null") else text]
	if trimmed == "":
		return [true, null] if t == TYPE_NIL else [false, null]
	var value: Variant = str_to_var(trimmed)
	return [typeof(value) == t, value]


static func _csv_line(cells: PackedStringArray) -> String:
	var out := PackedStringArray()
	for cell in cells:
		if cell.contains(",") or cell.contains("\"") or cell.contains("\n"):
			out.append("\"%s\"" % cell.replace("\"", "\"\""))
		else:
			out.append(cell)
	return ",".join(out)


static func _csv_records(text: String) -> Array:
	var records := []
	var cells := PackedStringArray()
	var cell := ""
	var quoted := false
	var i := 0
	text = text.replace("\r\n", "\n")
	while i < text.length():
		var c := text[i]
		if quoted:
			if c == "\"" and i + 1 < text.length() and text[i + 1] == "\"":
				cell += "\""
				i += 1
			elif c == "\"":
				quoted = false
			else:
				cell += c
		elif c == "\"" and cell == "":
			quoted = true
		elif c == ",":
			cells.append(cell)
			cell = ""
		elif c == "\n":
			cells.append(cell)
			records.append(cells)
			cells = PackedStringArray()
			cell = ""
		else:
			cell += c
		i += 1
	if cell != "" or not cells.is_empty():
		cells.append(cell)
		records.append(cells)
	return records
