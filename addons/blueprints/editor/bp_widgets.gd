@tool
extends RefCounted
## Small reusable editor widgets: inline value editors for pins/defaults, type picker, parameter lists.

const T := preload("res://addons/blueprints/core/bp_types.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")

static var _swatches: Dictionary = {}
static var _exec_icon: Texture2D
static var _exec_icon_hollow: Texture2D


static func icon(name: String) -> Texture2D:
	var th := EditorInterface.get_editor_theme()
	return th.get_icon(name, "EditorIcons") if th and th.has_icon(name, "EditorIcons") else null


static func class_icon(cls: String) -> Texture2D:
	var guard := 0
	while cls != "" and guard < 64:
		var ic := icon(cls)
		if ic:
			return ic
		cls = T.parent_of(cls)
		guard += 1
	return icon("Object")


## Small rounded colour chip used for variable types in lists.
static func swatch(color: Color) -> Texture2D:
	var key := color.to_html()
	if _swatches.has(key):
		return _swatches[key]
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(5, 11):
		for x in range(1, 15):
			var edge := (x == 1 or x == 14) and (y == 5 or y == 10)
			if not edge:
				img.set_pixel(x, y, color)
	var tex := ImageTexture.create_from_image(img)
	_swatches[key] = tex
	return tex


static func dot(color: Color) -> Texture2D:
	var key := "dot" + color.to_html()
	if _swatches.has(key):
		return _swatches[key]
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 14:
		for x in 14:
			var dist := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(7, 7))
			if dist <= 6.0:
				img.set_pixel(x, y, color if dist <= 4.6 else Color(1, 1, 1, 0.9))
	var tex := ImageTexture.create_from_image(img)
	_swatches[key] = tex
	return tex


## Unreal-style execution pin arrow.
static func exec_icon(filled := true) -> Texture2D:
	if filled and _exec_icon:
		return _exec_icon
	if not filled and _exec_icon_hollow:
		return _exec_icon_hollow
	var s := 16
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var poly := PackedVector2Array([Vector2(2, 2), Vector2(8, 2), Vector2(14, 8), Vector2(8, 14), Vector2(2, 14)])
	for y in s:
		for x in s:
			var pt := Vector2(x + 0.5, y + 0.5)
			if Geometry2D.is_point_in_polygon(pt, poly):
				var inner := Geometry2D.is_point_in_polygon(pt, PackedVector2Array([Vector2(4, 4), Vector2(7.2, 4), Vector2(11.2, 8), Vector2(7.2, 12), Vector2(4, 12)]))
				if filled or not inner:
					img.set_pixel(x, y, Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	if filled:
		_exec_icon = tex
	else:
		_exec_icon_hollow = tex
	return tex


static func _small_line(text: String, width: float) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.custom_minimum_size.x = width
	le.add_theme_font_size_override("font_size", 12)
	le.select_all_on_focus = true
	le.context_menu_enabled = false
	# Unreal's inline pin value box: near-black with a thin light outline.
	for state in ["normal", "focus", "read_only"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.02, 0.02, 0.022, 0.6)
		box.set_border_width_all(1)
		box.border_color = Color(0.78, 0.78, 0.78, 0.85) if state != "focus" else Color(0.3, 0.6, 1.0)
		box.set_corner_radius_all(4)
		box.content_margin_left = 6
		box.content_margin_right = 6
		box.content_margin_top = 1
		box.content_margin_bottom = 1
		le.add_theme_stylebox_override(state, box)
	return le


static func _commit_line(le: LineEdit, fn: Callable) -> void:
	le.text_submitted.connect(func(_t): fn.call(); le.release_focus())
	le.focus_exited.connect(fn)


static func _fmt(v: float) -> String:
	return String.num(v, 4) if not is_equal_approx(v, roundf(v)) else str(int(roundf(v)))


## Builds an editor for a literal of the given pin type, or null when the type has no inline editor.
## `on_change` receives the new literal (GDScript source text).
static func make_value_editor(type: String, enum_name: String, literal: String, on_change: Callable, compact := true) -> Control:
	if enum_name != "":
		var values := R.enum_values(enum_name)
		if not values.is_empty():
			var ob := OptionButton.new()
			ob.add_theme_font_size_override("font_size", 12)
			ob.fit_to_longest_item = false
			var cur := int(T.parse_literal(literal, values[0][1]))
			for i in values.size():
				ob.add_item(String(values[i][0]).capitalize(), i)
				if int(values[i][1]) == cur:
					ob.select(i)
			ob.item_selected.connect(func(i): on_change.call(str(int(values[i][1]))))
			return ob
	match type:
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = literal == "true"
			cb.toggled.connect(func(on): on_change.call("true" if on else "false"))
			return cb
		"int":
			var le := _small_line(literal if literal != "" else "0", 44)
			_commit_line(le, func():
				var v := int(le.text.to_float()) if le.text.is_valid_float() else 0
				le.text = str(v)
				on_change.call(str(v)))
			return le
		"float":
			var le := _small_line(_fmt(float(T.parse_literal(literal, 0.0))), 44)
			_commit_line(le, func():
				var v := le.text.to_float() if le.text.is_valid_float() else 0.0
				le.text = _fmt(v)
				on_change.call(T.to_literal(v)))
			return le
		"String", "StringName", "NodePath":
			var le := _small_line(str(T.parse_literal(literal, "")), 70 if compact else 140)
			le.expand_to_text_length = compact
			var prefix := "" if type == "String" else ("&" if type == "StringName" else "^")
			_commit_line(le, func(): on_change.call(prefix + var_to_str(le.text)))
			return le
		"Vector2", "Vector3", "Vector4", "Vector2i", "Vector3i", "Vector4i", "Quaternion":
			var n := 2 if type.begins_with("Vector2") else (3 if type.begins_with("Vector3") else 4)
			var is_int := type.ends_with("i")
			var cur: Variant = T.parse_literal(literal, null)
			if cur != null and not typeof(cur) in [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I, TYPE_QUATERNION]:
				# a plain number beside a vector (`direction * 3.0`): edit it as the value it is
				return make_value_editor("any", "", literal, on_change, compact)
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 2)
			var edits: Array[LineEdit] = []
			var commit := func():
				var parts := PackedStringArray()
				for e in edits:
					var v := e.text.to_float() if e.text.is_valid_float() else 0.0
					e.text = _fmt(v)
					parts.append(str(int(v)) if is_int else T.to_literal(v))
				on_change.call("%s(%s)" % [type, ", ".join(parts)])
			for i in n:
				var lab := Label.new()
				lab.text = "XYZW"[i]
				lab.add_theme_font_size_override("font_size", 10)
				lab.add_theme_color_override("font_color", [Color(0.9, 0.35, 0.35), Color(0.45, 0.85, 0.35), Color(0.4, 0.6, 1.0), Color(0.8, 0.8, 0.8)][i])
				box.add_child(lab)
				var le := _small_line(_fmt(float(cur[i])) if cur != null else ("1" if (type == "Quaternion" and i == 3) else "0"), 34)
				edits.append(le)
				_commit_line(le, commit)
				box.add_child(le)
			return box
		"Color":
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(48, 20)
			var c: Variant = T.parse_literal(literal, Color.WHITE)
			cp.color = c if typeof(c) == TYPE_COLOR else Color.WHITE
			cp.popup_closed.connect(func(): on_change.call(var_to_str(cp.color)))
			return cp
		"any":
			var le := _small_line(literal, 50)
			le.placeholder_text = "value"
			le.expand_to_text_length = true
			le.tooltip_text = "Any GDScript literal or expression, e.g. 3, \"text\", Vector2(1, 2)"
			_commit_line(le, func(): on_change.call(le.text.strip_edges()))
			return le
	if T.is_object(type) and T.is_a(type, "Resource") and ClassDB.class_exists(T.native_of(type)):
		var picker := EditorResourcePicker.new()
		picker.base_type = T.native_of(type)
		picker.custom_minimum_size.x = 130
		if literal.begins_with("preload(\""):
			var path := literal.trim_prefix("preload(\"").trim_suffix("\")")
			if ResourceLoader.exists(path):
				picker.edited_resource = load(path)
		picker.resource_changed.connect(func(res: Resource):
			if res == null or res.resource_path == "" or res.resource_path.contains("::"):
				if res != null:
					push_warning("Blueprints: only saved resource files can be used as pin defaults.")
					picker.edited_resource = null
				on_change.call("")
			else:
				on_change.call("preload(\"%s\")" % res.resource_path))
		return picker
	return null


# ---------------------------------------------------------------- type picker

static func all_types() -> Array:
	var out: Array = T.COMMON.duplicate()
	for t in T.BUILTIN:
		if not out.has(t):
			out.append(t)
	var g := T.globals().keys()
	g.sort()
	for t in g:
		if not out.has(t):
			out.append(t)
	var cl := Array(ClassDB.get_class_list())
	cl.sort()
	for t in cl:
		if not out.has(String(t)):
			out.append(String(t))
	return out


## A button that shows a pin type and opens a searchable list of every type when pressed.
static func make_type_button(type: String, on_change: Callable, allow_array := true, allow_exec := false) -> Button:
	var b := Button.new()
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size.x = 110
	var apply := func(t: String):
		b.text = "Wildcard" if t == "any" else ("Exec" if t == "exec" else t)
		b.icon = swatch(T.color(t))
		b.set_meta("type", t)
	apply.call(type)
	b.pressed.connect(func():
		var items := []
		for t in all_types():
			items.append({"label": "Wildcard (any)" if t == "any" else t, "value": t, "icon": swatch(T.color(t))})
		if allow_array:
			var cur := String(b.get_meta("type"))
			var elem := T.element_type(cur) if cur.begins_with("Array[") else cur
			if elem != "any" and not elem.begins_with("Array") and not cur.begins_with("Array["):
				items.push_front({"label": "Array of %s" % elem, "value": "Array[%s]" % elem, "icon": swatch(T.COLORS["Array"])})
		if allow_exec:
			items.push_front({"label": "Exec (execution pin)", "value": "exec", "icon": exec_icon(true)})
		popup_search(b, items, func(v):
			apply.call(v)
			on_change.call(v)))
	return b


## Generic searchable list popup anchored under `anchor`.
## Items are {label, value, icon?, tip?}. With `wide` the list is roomier and opens centred on the anchor.
static func popup_search(anchor: Control, items: Array, on_pick: Callable, title := "", wide := false) -> void:
	var pop := PopupPanel.new()
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(440, 420) if wide else Vector2(280, 360)
	pop.add_child(vb)
	if title != "":
		var tl := Label.new()
		tl.text = title
		vb.add_child(tl)
	var search := LineEdit.new()
	search.placeholder_text = "Search"
	search.right_icon = icon("Search")
	search.clear_button_enabled = true
	vb.add_child(search)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(list)
	var fill := func(q: String):
		list.clear()
		q = q.to_lower()
		var starts := []
		var rest := []
		for it in items:
			var l := String(it.label).to_lower()
			if q == "" or l.begins_with(q):
				starts.append(it)
			elif l.contains(q):
				rest.append(it)
		for it in (starts + rest).slice(0, 400):
			var idx := list.add_item(it.label, it.get("icon"))
			list.set_item_metadata(idx, it.value)
			if String(it.get("tip", "")) != "":
				list.set_item_tooltip(idx, String(it.tip))
		if list.item_count > 0:
			list.select(0)
	fill.call("")
	var pick := func(idx: int):
		if idx < 0 or idx >= list.item_count:
			return
		var v: Variant = list.get_item_metadata(idx)
		pop.hide()
		# Deferred: picking often rebuilds the panel that owns this popup, which must not happen mid-input-event.
		on_pick.call_deferred(v)
	search.text_changed.connect(fill)
	search.text_submitted.connect(func(_t):
		var sel := list.get_selected_items()
		pick.call(sel[0] if not sel.is_empty() else 0))
	search.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventKey and ev.pressed and (ev.keycode == KEY_DOWN or ev.keycode == KEY_UP) and list.item_count > 0:
			var sel := list.get_selected_items()
			var i := clampi((sel[0] if not sel.is_empty() else -1) + (1 if ev.keycode == KEY_DOWN else -1), 0, list.item_count - 1)
			list.select(i)
			list.ensure_current_is_visible()
			search.accept_event())
	list.item_activated.connect(pick)
	list.item_clicked.connect(func(idx, _pos, btn):
		if btn == MOUSE_BUTTON_LEFT:
			pick.call(idx))
	pop.popup_hide.connect(pop.queue_free)
	anchor.add_child(pop)
	if wide:
		pop.popup(Rect2i(Vector2i(anchor.get_screen_position() + (anchor.size - Vector2(440, 440)) / 2.0), Vector2i(440, 440)))
	else:
		var r := anchor.get_screen_position() + Vector2(0, anchor.size.y)
		pop.popup(Rect2i(Vector2i(r), Vector2i(280, 380)))
	search.grab_focus()


## Editable list of [name, type] pairs. `on_change` receives the new Array.
static func make_param_list(params: Array, on_change: Callable, add_label := "Add Parameter", allow_exec := false) -> Control:
	var vb := VBoxContainer.new()
	var data: Array = params.duplicate(true)
	for i in data.size():
		var row := HBoxContainer.new()
		var name_edit := LineEdit.new()
		name_edit.text = String(data[i][0])
		name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		_commit_line(name_edit, func():
			var nn := T.ident(name_edit.text.strip_edges())
			if nn != String(data[idx][0]) and nn != "_":
				data[idx][0] = nn
				on_change.call(data))
		row.add_child(name_edit)
		row.add_child(make_type_button(String(data[i][1]), func(t):
			data[idx][1] = t
			on_change.call(data), true, allow_exec))
		var del := Button.new()
		del.icon = icon("Remove")
		del.flat = true
		del.tooltip_text = "Remove"
		del.pressed.connect(func():
			data.remove_at(idx)
			on_change.call(data))
		row.add_child(del)
		vb.add_child(row)
	var add := Button.new()
	add.text = add_label
	add.icon = icon("Add")
	add.pressed.connect(func():
		var names := []
		for prm in data:
			names.append(prm[0])
		var nm := "param"
		var k := 1
		while names.has(nm):
			nm = "param_%d" % k
			k += 1
		data.append([nm, "bool"])
		on_change.call(data))
	vb.add_child(add)
	return vb
