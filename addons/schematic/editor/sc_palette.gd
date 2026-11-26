@tool
extends PopupPanel
## The right-click / drag-off-pin action menu: searchable, categorised, optionally context sensitive.

const W := preload("res://addons/schematic/editor/sc_widgets.gd")

const T := preload("res://addons/schematic/core/sc_types.gd")

const MAX_RESULTS := 250

## Icon and tint per action, following Unreal's menu: a blue "f" for functions, green for pure ones,
## the type colour for variables, red for events.
const BLUE := Color(0.35, 0.62, 1.0)
const GREEN := Color(0.45, 0.85, 0.45)
const RED := Color(1.0, 0.36, 0.3)
const GREY := Color(0.85, 0.85, 0.85)

var _title: Label
var _context: CheckBox
var _search: LineEdit
var _tree: Tree
var _provider: Callable   # func(context_sensitive: bool) -> Array of actions
var _on_pick: Callable
var _actions: Array = []
var _picked := false
var _bold: Font


func _init() -> void:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = W.sv(Vector2(440, 470))
	add_child(vb)
	var frame := StyleBoxFlat.new()
	vb.add_theme_constant_override("separation", W.si(6))
	frame.bg_color = W.CHROME
	frame.set_border_width_all(W.si(1))
	frame.border_color = W.EDGE
	frame.set_corner_radius_all(W.si(9))
	frame.set_content_margin_all(W.si(8))
	frame.shadow_color = Color(0, 0, 0, 0.4)
	frame.shadow_size = 8
	add_theme_stylebox_override("panel", frame)
	var top := HBoxContainer.new()
	vb.add_child(top)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.add_theme_font_size_override("font_size", W.si(13))
	_title.add_theme_color_override("font_color", W.ACCENT)
	top.add_child(_title)
	_context = CheckBox.new()
	_context.text = "Context Sensitive"
	_context.add_theme_font_size_override("font_size", W.si(13))
	_context.button_pressed = true
	_context.toggled.connect(func(_on):
		_reload()
		_search.grab_focus())
	top.add_child(_context)
	_search = LineEdit.new()
	_search.placeholder_text = "Search nodes"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _fill())
	_search.text_submitted.connect(func(_t): _activate())
	_search.gui_input.connect(_on_search_input)
	vb.add_child(_search)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 120)
	_tree.item_activated.connect(_activate)
	_tree.item_collapsed.connect(_on_collapsed)
	_tree.item_mouse_selected.connect(func(_pos, btn):
		if btn == MOUSE_BUTTON_LEFT and _tree.get_selected() and _tree.get_selected().get_metadata(0) != null:
			_activate())
	vb.add_child(_tree)


func open(screen_pos: Vector2, title: String, provider: Callable, on_pick: Callable) -> void:
	if _bold == null and EditorInterface.get_editor_theme():
		_bold = EditorInterface.get_editor_theme().get_font("bold", "EditorFonts")
	_title.text = title
	_provider = provider
	_on_pick = on_pick
	_picked = false
	_search.text = ""
	_search.right_icon = W.icon("Search")
	_reload()
	# (the screen the editor's window is on: the main window's, or its own window's when it floats)
	var host := get_parent().get_window() if get_parent() else null
	var scr := DisplayServer.screen_get_usable_rect(host.current_screen if host else DisplayServer.window_get_current_screen())
	var pos := Vector2i(screen_pos)
	pos.x = mini(pos.x, scr.end.x - W.si(470))
	pos.y = mini(pos.y, scr.end.y - W.si(500))
	popup(Rect2i(pos, Vector2i(W.si(456), W.si(486))))
	_search.grab_focus()


func _reload() -> void:
	_actions = _provider.call(_context.button_pressed)
	_fill()


func _fill() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var q := _search.text.strip_edges().to_lower()
	if q == "":
		_fill_categories(root)
		return
	var terms := q.split(" ", false)
	var scored := []
	for act in _actions:
		var s: String = act.s
		var ok := true
		for t in terms:
			if not s.contains(t):
				ok = false
				break
		if not ok:
			continue
		var l: String = String(act.l).to_lower()
		var score := 3
		if l == q: score = 0
		elif l.begins_with(q): score = 1
		elif l.contains(q): score = 2
		# An Unreal name typed in full (with or without spaces) ranks like an exact match; a partial one like a prefix.
		var via := ""
		var exact_alias := false
		if score > 0 and act.has("ue"):
			var q_tight := q.replace(" ", "")
			for nm in act.ue:
				var low := String(nm).to_lower()
				var tight := low.replace(" ", "")
				if tight == q_tight or tight == "event" + q_tight:
					score = 0
					via = String(nm)
					exact_alias = true
					break
				if via == "" and (low.contains(q) or tight.contains(q_tight)):
					score = mini(score, 1 if (tight.begins_with(q_tight) or low.begins_with(q)) else 2)
					via = String(nm)
		if via != "" and not l.contains(q):
			act = act.duplicate()
			act["via"] = via
		if act.get("pri", false) or act.k in ["branch", "sequence", "for", "for_each", "while", "delay", "print", "tpl", "__promote"]:
			score = maxi(score - 1, 0) if score > 0 else 0
			scored.append([score * 1000 + mini(l.length(), 999) - 500 - (2000 if exact_alias else 0), act])
			continue
		scored.append([score * 1000 + mini(l.length(), 999) - (2000 if exact_alias else 0), act])
	scored.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else String(a[1].l) < String(b[1].l))
	# Unreal lists search hits under their category. Categories appear in order of their best hit.
	var heads := {}
	for i in mini(scored.size(), MAX_RESULTS):
		var act: Dictionary = scored[i][1]
		if not heads.has(act.c):
			var h := _tree.create_item(root)
			h.set_text(0, String(act.c).replace("|", "  >  "))
			h.set_selectable(0, false)
			h.set_selectable(1, false)
			h.set_custom_color(0, Color(1, 1, 1, 0.6))
			if _bold:
				h.set_custom_font(0, _bold)
			h.set_custom_font_size(0, W.si(12))
			heads[act.c] = h
		_leaf(heads[act.c], act, false)
	var first := first_leaf()
	if first:
		first.select(0)


## First selectable action in the tree (skips category headers).
func first_leaf() -> TreeItem:
	var it := _tree.get_root().get_next_in_tree() if _tree.get_root() else null
	while it and it.get_metadata(0) == null:
		it = it.get_next_in_tree()
	return it


func leaf_count() -> int:
	var n := 0
	var it := _tree.get_root().get_next_in_tree() if _tree.get_root() else null
	while it:
		if it.get_metadata(0) != null:
			n += 1
		it = it.get_next_in_tree()
	return n


func _leaf(parent: TreeItem, act: Dictionary, show_cat: bool) -> void:
	var it := _tree.create_item(parent)
	it.set_text(0, act.l)
	it.set_metadata(0, act)
	it.set_tooltip_text(0, String(act.get("tip", "")))
	if act.has("via"):
		it.set_suffix(0, "   Unreal: %s" % act.via)
		it.set_tooltip_text(0, "%s
Known in Unreal as: %s" % [String(act.get("tip", "")), ", ".join(PackedStringArray(act.ue))])
	var look := _look(act)
	if look[0]:
		it.set_icon(0, look[0])
		it.set_icon_modulate(0, look[1])
	if show_cat:
		it.set_text(1, String(act.c).get_slice("|", String(act.c).get_slice_count("|") - 1))
		it.set_custom_color(1, Color(1, 1, 1, 0.4))
		it.set_tooltip_text(1, String(act.c).replace("|", " > "))


func _look(act: Dictionary) -> Array:
	var k := String(act.k)
	match k:
		"event", "custom_event", "input_action", "key_event", "signal_event", "__assign":
			return [W.icon("MemberSignal"), RED]
		"var_get", "var_set", "var_inc", "local_get", "local_set", "get_prop", "set_prop":
			return [W.swatch(Color.WHITE), T.color(String(act.get("vt", "any")))]
		"emit", "bind_signal", "unbind_signal", "await_signal":
			return [W.icon("MemberSignal"), RED]
		"branch", "sequence", "switch", "gate", "multigate", "do_once", "do_n", "flip_flop", "select", "is_valid":
			return [W.icon("AnimationTrackList"), GREY]
		"for", "for_each", "for_each_dict", "while", "loop_break", "loop_continue":
			return [W.icon("Loop"), GREY]
		"macro":
			return [W.icon("GraphEdit"), GREY]
		"timeline":
			return [W.icon("Animation"), GREY]
		"cast":
			return [W.icon("ArrowRight"), Color(0.3, 0.8, 0.85)]
		"op", "math", "break", "ctor", "make_array", "make_dict", "const", "expr", "format", "index":
			return [W.icon("MemberMethod"), GREEN]
		"self", "get_node", "autoload":
			return [W.icon("Node"), Color(0.3, 0.7, 1.0)]
		"comment", "reroute":
			return [W.icon("Edit"), GREY]
		"__promote":
			return [W.icon("Add"), GREY]
	return [W.icon("MemberMethod"), GREEN if act.get("pure", false) else BLUE]


func _fill_categories(root: TreeItem) -> void:
	var cats := {}   # path -> Array of actions
	for act in _actions:
		if not cats.has(act.c):
			cats[act.c] = []
		cats[act.c].append(act)
	var paths := cats.keys()
	paths.sort()
	var items := {}
	for path in paths:
		var parent := root
		var acc := ""
		for part in String(path).split("|"):
			acc = part if acc == "" else acc + "|" + part
			if not items.has(acc):
				var it := _tree.create_item(parent)
				it.set_text(0, part)
				it.set_selectable(0, true)
				it.set_custom_color(0, Color(1, 1, 1, 0.75))
				it.collapsed = true
				items[acc] = it
			parent = items[acc]
		var holder: TreeItem = items[path]
		holder.set_meta("lazy", cats[path])
		_tree.create_item(holder).set_text(0, "...")


func _on_collapsed(item: TreeItem) -> void:
	if item.collapsed or not item.has_meta("lazy"):
		return
	# Tree items cannot be created during mouse selection.
	# Use an ID because a search/reload may free this item before the deferred population runs.
	_populate_category.call_deferred(item.get_instance_id())


func _populate_category(item_id: int) -> void:
	var item := instance_from_id(item_id) as TreeItem
	if item == null or item.collapsed or not item.has_meta("lazy"):
		return
	var acts: Array = item.get_meta("lazy")
	item.remove_meta("lazy")
	# Remove the placeholder (always the last child created for this holder).
	for ch in item.get_children():
		if ch.get_metadata(0) == null and ch.get_text(0) == "...":
			ch.free()
	acts.sort_custom(func(a, b): return String(a.l).naturalnocasecmp_to(String(b.l)) < 0)
	for act in acts:
		_leaf(item, act, false)


func _activate() -> void:
	var it := _tree.get_selected()
	if it == null:
		return
	var act: Variant = it.get_metadata(0)
	if act == null:
		it.collapsed = not it.collapsed
		return
	if _picked:
		return
	_picked = true
	hide()
	_on_pick.call(act)


func _on_search_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and (ev.keycode == KEY_DOWN or ev.keycode == KEY_UP):
		var cur := _tree.get_selected()
		var nxt: TreeItem = null
		if cur == null:
			nxt = _tree.get_root().get_first_child() if _tree.get_root() else null
		else:
			nxt = cur.get_next_visible() if ev.keycode == KEY_DOWN else cur.get_prev_visible()
		# step over the category headers of a search result
		while nxt and not nxt.is_selectable(0):
			nxt = nxt.get_next_visible() if (ev.keycode == KEY_DOWN or cur == null) else nxt.get_prev_visible()
		if nxt:
			nxt.select(0)
			_tree.scroll_to_item(nxt)
		_search.accept_event()
