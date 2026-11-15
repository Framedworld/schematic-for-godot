@tool
extends GraphEdit
## The graph canvas for one schematic graph. Owns every graph-level edit (wires, spawn, delete, paste).

const T := preload("res://addons/schematic/core/sc_types.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const BPNode := preload("res://addons/schematic/editor/sc_graph_node.gd")

const QUICK_KEYS := {KEY_B: ["branch", {}], KEY_S: ["sequence", {"n": 2}], KEY_D: ["delay", {}], KEY_F: ["for_each", {}],
	KEY_G: ["gate", {}], KEY_O: ["do_once", {}], KEY_N: ["is_valid", {}], KEY_P: ["print", {}]}

static var clipboard: Dictionary = {}

var editor: Node          # sc_editor.gd
var bp: Dictionary
var graph: Dictionary
var _loading := false
var _frame_last: Dictionary = {}
var _pending_select: Array = []
var _node_menu: PopupMenu
var _menu_node := -1
var _menu_pins: Array = []
var _menu_watch: Array = []
const FlowOverlay := preload("res://addons/schematic/editor/sc_flow_overlay.gd")
var flow_overlay: FlowOverlay
var _last_selection := ""
var watch: Dictionary = {}    # node id -> {pin id: text}: last values reported by the running game
var hide_unrelated := false   # Unreal's Hide Unrelated: fade every node not linked to the selection


func _init() -> void:
	right_disconnects = true
	minimap_enabled = false
	show_arrange_button = false
	connection_lines_thickness = EXEC_WIRE
	connection_lines_curvature = 0.6
	snapping_distance = GRID
	# Unreal's graph has no toolbar and draws its own grid (a rule line every 8 cells), so both are replaced.
	show_menu = false
	show_grid = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	add_theme_stylebox_override("panel", bg)
	add_theme_stylebox_override("panel_focus", StyleBoxEmpty.new())
	add_theme_color_override("connection_rim_color", Color(0, 0, 0, 0.0))
	add_theme_color_override("connection_hover_tint_color", Color(1, 1, 1, 0.35))
	add_theme_color_override("selection_fill", Color(1, 1, 1, 0.06))
	add_theme_color_override("selection_stroke", Color(1, 1, 1, 0.75))
	add_theme_color_override("activity", Color(1.0, 0.75, 0.2))
	add_theme_constant_override("port_hotzone_inner_extent", 18)
	add_theme_constant_override("port_hotzone_outer_extent", 14)
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	connection_to_empty.connect(_on_connection_to_empty)
	connection_from_empty.connect(_on_connection_from_empty)
	popup_request.connect(_on_popup_request)
	delete_nodes_request.connect(_on_delete_nodes)
	copy_nodes_request.connect(copy_selection)
	cut_nodes_request.connect(func():
		copy_selection()
		_on_delete_nodes([]))
	paste_nodes_request.connect(func(): paste(_mouse_graph_pos()))
	duplicate_nodes_request.connect(func():
		copy_selection()
		paste(Vector2.INF))
	end_node_move.connect(_on_end_node_move)
	node_selected.connect(func(_n): _selection_changed.call_deferred())
	node_deselected.connect(func(_n): _selection_changed.call_deferred())
	scroll_offset_changed.connect(func(_o):
		_store_view()
		queue_redraw())
	var layer := get_node_or_null("_connection_layer") as Control
	if layer:
		layer.draw.connect(_style_wires.bind(layer))
		flow_overlay = FlowOverlay.new()
		flow_overlay.view = self
		layer.add_child(flow_overlay)
	_node_menu = PopupMenu.new()
	_node_menu.id_pressed.connect(_on_node_menu)
	add_child(_node_menu)


# ---------------------------------------------------------------- look

const GRID := 16
const RULE_PERIOD := 8
const EXEC_WIRE := 3.0
const DATA_WIRE := 1.9
const BG_COLOR := Color(0.149, 0.149, 0.149)
const GRID_LINE := Color(0.2, 0.2, 0.2)
const GRID_RULE := Color(0.09, 0.09, 0.09)
const GRID_CENTRE := Color(0.045, 0.045, 0.045)


## Background grid and the corner texts, drawn the way Unreal's graph panel does.
func _draw() -> void:
	var z := zoom
	var step := GRID * z
	var rule_only := step < 6.0
	if rule_only:
		step *= RULE_PERIOD
	if step >= 3.0:
		var first_x := int(floor(scroll_offset.x / step))
		var first_y := int(floor(scroll_offset.y / step))
		for pass_rule in [false, true]:
			var ix := first_x
			while ix * step - scroll_offset.x <= size.x:
				var x := roundf(ix * step - scroll_offset.x)
				var is_rule := rule_only or posmod(ix, RULE_PERIOD) == 0
				if is_rule == pass_rule:
					draw_line(Vector2(x, 0), Vector2(x, size.y), _grid_color(ix, is_rule), 1.0)
				ix += 1
			var iy := first_y
			while iy * step - scroll_offset.y <= size.y:
				var y := roundf(iy * step - scroll_offset.y)
				var is_rule := rule_only or posmod(iy, RULE_PERIOD) == 0
				if is_rule == pass_rule:
					draw_line(Vector2(0, y), Vector2(size.x, y), _grid_color(iy, is_rule), 1.0)
				iy += 1
	var font := get_theme_font("bold", "EditorFonts") if has_theme_font("bold", "EditorFonts") else get_theme_default_font()
	if graph.is_empty():
		return
	# Unreal's hint on a graph nobody has wired yet.
	if graph.get("wires", []).is_empty():
		var hint := "Right-Click to Create New Nodes."
		var hs := 24
		var hw := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs).x
		var box := Rect2((size.x - hw) * 0.5 - 12, 16, hw + 24, 40)
		draw_style_box(_hint_box(), box)
		draw_string(font, Vector2(box.position.x + 12, box.position.y + 28), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs, Color(1, 1, 1, 0.72))
	var mark := "MACRO" if graph.get("kind", "") == "macro" else ("FUNCTION" if graph.get("kind", "") == "function" else "SCHEMATIC")
	var mark_size := 54
	var mw := font.get_string_size(mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size).x
	draw_string(font, Vector2(size.x - mw - 28, size.y - 30), mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size, Color(1, 1, 1, 0.09))
	var zt := "Zoom 1:1" if is_equal_approx(z, 1.0) else "Zoom %d%%" % int(round(z * 100.0))
	var zw := font.get_string_size(zt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2(size.x - zw - 22, 24), zt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.3))


func _hint_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.065, 0.85)
	sb.set_corner_radius_all(4)
	return sb


func _grid_color(index: int, is_rule: bool) -> Color:
	if index == 0:
		return GRID_CENTRE
	return GRID_RULE if is_rule else GRID_LINE


## Unreal's wire shape: a Hermite spline whose horizontal tangent grows with the distance between the pins,
## with a stronger pull when the wire runs backwards (values from Unreal's graph editor settings).
func _get_connection_line(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
	var z := maxf(zoom, 0.01)
	var d := (to_position - from_position) / z
	var forward := d.x >= 0.0
	var limit := 1000.0 if forward else 200.0
	var tx := minf(absf(d.x), limit)
	var ty := minf(absf(d.y), limit)
	var tangent := ((tx + ty) if forward else (2.0 * tx + 1.5 * ty)) * z
	var curve := Curve2D.new()
	curve.add_point(from_position, Vector2.ZERO, Vector2(tangent / 3.0, 0))
	curve.add_point(to_position, Vector2(-tangent / 3.0, 0), Vector2.ZERO)
	return curve.tessellate(5, 2.0)


## Exec wires are drawn thicker than data wires, as in Unreal. GraphEdit has one thickness for all wires, so the
## width of each data wire is narrowed right after GraphEdit lays the wires out.
func _style_wires(layer: Control) -> void:
	# the moving dots are drawn after the wires (over them) and before the nodes
	if flow_overlay != null and flow_overlay.get_index() != layer.get_child_count() - 1:
		layer.move_child(flow_overlay, -1)
	var ratio := DATA_WIRE / EXEC_WIRE
	for line in layer.get_children():
		var l2 := line as Line2D
		if l2 == null:
			continue
		var mat := l2.material as ShaderMaterial
		if mat == null or int(mat.get_shader_parameter("from_type")) == 1:
			continue
		var full := float(mat.get_shader_parameter("line_width"))
		if full <= 0.0:
			continue
		var hovered := l2.width > full * 1.01
		l2.width = full * ratio * (1.35 if hovered else 1.0)


# ---------------------------------------------------------------- build

func show_graph(p_bp: Dictionary, p_graph: Dictionary, errors: Dictionary = {}, marks: Dictionary = {}) -> void:
	_loading = true
	var selected := _pending_select if not _pending_select.is_empty() else selected_ids()
	_pending_select = []
	var same := not graph.is_empty() and not p_graph.is_empty() and int(graph.get("id", -1)) == int(p_graph.id)
	bp = p_bp
	graph = p_graph
	clear_connections()
	# Comment frames are reused across rebuilds: GraphEdit defers a reorder when a frame is added, which
	# logs an error if that frame has already been replaced.
	var keep := {}
	for kn in graph.get("nodes", []):
		if kn.kind == "comment":
			keep[int(kn.id)] = true
	# Keyboard focus sits on the clicked node; when that node is replaced, the canvas takes the focus over
	# so Delete, Ctrl+C and the other shortcuts keep working.
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var had_focus: bool = focused != null and (focused == self or is_ancestor_of(focused))
	for c in get_children():
		if not c is GraphElement or c.has_meta("gone"):
			continue
		if c is GraphFrame and keep.has(int(c.get_meta("node_id", -1))):
			continue
		if not c is GraphFrame:
			remove_child(c)
			c.queue_free()
			continue
		# A comment frame is not removed right away: it stays a hidden, renamed child for a few frames, because
		# GraphEdit reorders frames with deferred calls that log an error for one that has left or died.
		c.name = "gone_%d" % c.get_instance_id()
		c.set_meta("node_id", -1)
		c.set_meta("gone", true)
		c.hide()
		_retire(c)
	_frame_last.clear()
	if graph.is_empty():
		_loading = false
		return
	prune_wires()
	var wired_in := {}
	var wired_out := {}
	for w in graph.wires:
		if not wired_out.has(int(w[0])): wired_out[int(w[0])] = {}
		if not wired_in.has(int(w[2])): wired_in[int(w[2])] = {}
		wired_out[int(w[0])][w[1]] = true
		wired_in[int(w[2])][w[3]] = true
	for n in graph.nodes:
		if n.kind == "comment":
			_add_frame(n)
			continue
		var d := R.describe(n, bp, graph)
		var gn := BPNode.new()
		var err := String(errors.get(int(n.id), d.err))
		gn.setup(self, n, d, wired_in.get(int(n.id), {}), wired_out.get(int(n.id), {}), err, String(marks.get(int(n.id), "")))
		add_child(gn)
		gn.selected = selected.has(int(n.id))
	for w in graph.wires:
		var a := get_node_or_null("n%d" % int(w[0])) as BPNode
		var b := get_node_or_null("n%d" % int(w[2])) as BPNode
		if a == null or b == null:
			continue
		var fp := _port_of(a.out_pins, w[1])
		var tp := _port_of(b.in_pins, w[3])
		if fp >= 0 and tp >= 0:
			connect_node(a.name, fp, b.name, tp)
	if not same:
		zoom = float(graph.get("zoom", 1.0))
		scroll_offset = Vector2(float(graph.get("sx", 0.0)), float(graph.get("sy", 0.0)))
	_loading = false
	if had_focus and get_viewport().gui_get_focus_owner() == null:
		grab_focus()
	for wid in watch:
		show_watch(int(wid), watch[wid])
	apply_unrelated()
	queue_redraw()


func _retire(c: Node) -> void:
	if not is_inside_tree():
		c.queue_free()
		return
	for i in 3:
		await get_tree().process_frame
	if is_instance_valid(c):
		c.queue_free()


func _add_frame(n: Dictionary) -> void:
	var id := int(n.id)
	var f := get_node_or_null("n%d" % id) as GraphFrame
	var fresh := f == null
	if fresh:
		f = GraphFrame.new()
		f.name = "n%d" % id
		f.autoshrink_enabled = false
		f.tint_color_enabled = false
		f.resizable = true
		# Unreal comment box: a translucent pane with a stronger title band and large title text.
		for sel in [false, true]:
			var pane := StyleBoxFlat.new()
			pane.bg_color = Color(1, 1, 1, 0.06)
			pane.set_border_width_all(2 if sel else 1)
			pane.border_width_top = 0
			pane.border_color = Color(1.0, 0.72, 0.1) if sel else Color(1, 1, 1, 0.28)
			pane.corner_radius_bottom_left = 4
			pane.corner_radius_bottom_right = 4
			var band := StyleBoxFlat.new()
			band.bg_color = Color(1, 1, 1, 0.22)
			band.set_border_width_all(2 if sel else 1)
			band.border_width_bottom = 0
			band.border_color = pane.border_color
			band.corner_radius_top_left = 4
			band.corner_radius_top_right = 4
			band.content_margin_left = 10
			band.content_margin_right = 10
			band.content_margin_top = 5
			band.content_margin_bottom = 5
			f.add_theme_stylebox_override("panel_selected" if sel else "panel", pane)
			f.add_theme_stylebox_override("titlebar_selected" if sel else "titlebar", band)
		for tc in f.get_titlebar_hbox().get_children():
			if tc is Label:
				tc.add_theme_font_size_override("font_size", 18)
				tc.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
				tc.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		f.set_meta("node_id", id)
	f.title = String(n.p.get("text", "Comment"))
	f.position_offset = Vector2(n.x, n.y)
	f.size = Vector2(float(n.p.get("w", 400)), float(n.p.get("h", 200)))
	_frame_last[id] = f.position_offset
	if not fresh:
		return
	add_child(f)
	f.position_offset_changed.connect(_on_frame_moved.bind(f))
	f.resize_end.connect(func(new_size: Vector2):
		var apply := func():
			var cur := Model.find_node(graph, id)
			if not cur.is_empty():
				cur.p["w"] = new_size.x
				cur.p["h"] = new_size.y
		editor.mutate("Resize Comment", apply, false))
	f.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.double_click and ev.button_index == MOUSE_BUTTON_LEFT:
			node_double_clicked(id))


func _on_frame_moved(f: GraphFrame) -> void:
	var id := int(f.get_meta("node_id"))
	var last: Vector2 = _frame_last.get(id, f.position_offset)
	var delta := f.position_offset - last
	_frame_last[id] = f.position_offset
	if _loading or delta == Vector2.ZERO or not f.selected:
		return
	var rect := Rect2(last, f.size)
	for c in get_children():
		if c is GraphNode and not c.selected and rect.has_point(c.position_offset + c.size * 0.5 - delta * 0.0):
			c.position_offset += delta


func _port_of(pins: Array, pin_id: String) -> int:
	for i in pins.size():
		if pins[i].id == pin_id:
			return i
	return -1


## Drops wires whose nodes or pins no longer exist (after renames / signature changes).
func prune_wires() -> void:
	var pins := {}
	for n in graph.nodes:
		if n.kind == "comment":
			continue
		var d := R.describe(n, bp, graph)
		var ins := {}
		var outs := {}
		for p in d.ins: ins[p.id] = true
		for p in d.outs: outs[p.id] = true
		pins[int(n.id)] = [ins, outs]
	for i in range(graph.wires.size() - 1, -1, -1):
		var w: Array = graph.wires[i]
		if not pins.has(int(w[0])) or not pins.has(int(w[2])) or not pins[int(w[0])][1].has(w[1]) or not pins[int(w[2])][0].has(w[3]):
			graph.wires.remove_at(i)


func selected_ids() -> Array:
	var out := []
	for c in get_children():
		if c is GraphElement and c.selected and not c.has_meta("gone"):
			out.append(int(String(c.name).trim_prefix("n")))
	return out


func _store_view() -> void:
	if _loading or graph.is_empty():
		return
	graph["zoom"] = zoom
	graph["sx"] = scroll_offset.x
	graph["sy"] = scroll_offset.y


func to_graph_pos(local: Vector2) -> Vector2:
	return (local + scroll_offset) / zoom


func _mouse_graph_pos() -> Vector2:
	return to_graph_pos(get_local_mouse_position())


func _selection_changed() -> void:
	if _loading or not is_inside_tree():
		return
	var ids := selected_ids()
	# A rebuild re-selects the same nodes; only a real change of selection should move the Details panel.
	var key := "%d|%s" % [int(graph.get("id", -1)), ",".join(PackedStringArray(ids.map(func(i): return str(i))))]
	if key != _last_selection:
		_last_selection = key
		editor.graph_selection_changed(ids)
	apply_unrelated()


## Fades the nodes that are not connected (directly or through other nodes) to the selected ones.
func apply_unrelated() -> void:
	var ids := selected_ids()
	var related := {}
	if hide_unrelated and not ids.is_empty() and not graph.is_empty():
		var frontier := ids.duplicate()
		for id in ids:
			related[int(id)] = true
		while not frontier.is_empty():
			var cur := int(frontier.pop_back())
			for w in graph.wires:
				for other in [[int(w[0]), int(w[2])], [int(w[2]), int(w[0])]]:
					if other[0] == cur and not related.has(other[1]):
						related[other[1]] = true
						frontier.append(other[1])
	for c in get_children():
		if c is GraphNode:
			var dim: bool = not related.is_empty() and not related.has(int(String(c.name).trim_prefix("n")))
			c.modulate = Color(1, 1, 1, 0.18) if dim else Color.WHITE


## Briefly lights up nodes that just executed in the running game.
func flash(ids: Array) -> void:
	for id in ids:
		var c := get_node_or_null("n%d" % int(id)) as GraphNode
		if c == null:
			continue
		c.modulate = Color(1.9, 1.6, 0.7)
		var tw := c.create_tween()
		tw.tween_property(c, "modulate", Color.WHITE, 0.45)


## Runs dots along every exec wire that goes from one node to the other (execution just followed it).
func flow(from_id: int, to_id: int) -> void:
	if flow_overlay == null:
		return
	var a := get_node_or_null("n%d" % from_id) as BPNode
	var b := get_node_or_null("n%d" % to_id) as BPNode
	if a == null or b == null:
		return
	for w in graph.wires:
		if int(w[0]) != from_id:
			continue
		# the wire may reach the node through reroute nodes: every piece of it lights up
		var pieces := [w]
		var at := int(w[2])
		var guard := 0
		while at != to_id and guard < 64:
			var knot := Model.find_node(graph, at)
			if knot.is_empty() or String(knot.kind) != "reroute":
				break
			var onward: Array = []
			for w2 in graph.wires:
				if int(w2[0]) == at:
					onward = w2
					break
			if onward.is_empty():
				break
			pieces.append(onward)
			at = int(onward[2])
			guard += 1
		if at != to_id:
			continue
		var is_exec := false
		for piece in pieces:
			var pa := get_node_or_null("n%d" % int(piece[0])) as BPNode
			var pb := get_node_or_null("n%d" % int(piece[2])) as BPNode
			if pa == null or pb == null:
				continue
			var fp := _port_of(pa.out_pins, piece[1])
			var tp := _port_of(pb.in_pins, piece[3])
			if fp < 0 or tp < 0:
				continue
			if is_same(piece, w):
				is_exec = String(pa.out_pins[fp].type) == "exec"
			if is_exec:
				flow_overlay.pulse(pa.name, fp, pb.name, tp)


## Shows the values the running game last sent for a node's input pins.
func show_watch(id: int, values: Dictionary) -> void:
	watch[id] = values
	var c := get_node_or_null("n%d" % id) as BPNode
	if c:
		c.set_watch(values)


func focus_node(id: int) -> void:
	var c := get_node_or_null("n%d" % id) as GraphElement
	if c == null:
		return
	for o in get_children():
		if o is GraphElement:
			o.selected = o == c
	scroll_offset = (c.position_offset + c.size * 0.5) * zoom - size * 0.5
	_selection_changed()


# ---------------------------------------------------------------- wires

func _pins_for(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> Array:
	var a := get_node_or_null(String(from_node)) as BPNode
	var b := get_node_or_null(String(to_node)) as BPNode
	if a == null or b == null or from_port >= a.out_pins.size() or to_port >= b.in_pins.size():
		return []
	return [a, a.out_pins[from_port], b, b.in_pins[to_port]]


func _is_node_hover_valid(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> bool:
	var r := _pins_for(from_node, from_port, to_node, to_port)
	if r.is_empty() or from_node == to_node:
		return false
	return T.can_connect(r[1].type, r[3].type)


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var r := _pins_for(from_node, from_port, to_node, to_port)
	if r.is_empty() or not T.can_connect(r[1].type, r[3].type):
		return
	editor.mutate("Connect Pins", func(): add_wire(r[0].node_id, r[1], r[2].node_id, r[3]))


## Model-level connect. Enforces one wire per exec output and per data input; resolves wildcard pins.
func add_wire(from_id: int, from_pin: Dictionary, to_id: int, to_pin: Dictionary) -> void:
	if from_id == to_id:
		return
	for i in range(graph.wires.size() - 1, -1, -1):
		var w: Array = graph.wires[i]
		if from_pin.type == "exec" and int(w[0]) == from_id and w[1] == from_pin.id:
			graph.wires.remove_at(i)
		elif from_pin.type != "exec" and int(w[2]) == to_id and w[3] == to_pin.id:
			graph.wires.remove_at(i)
	graph.wires.append([from_id, from_pin.id, to_id, to_pin.id])
	var tn := Model.find_node(graph, to_id)
	var fn := Model.find_node(graph, from_id)
	match tn.get("kind", ""):
		"for_each":
			if to_pin.id == "array":
				tn.p["t"] = T.element_type(from_pin.type)
		"reroute":
			tn.p["t"] = from_pin.type
		"select":
			if to_pin.id in ["a", "b"] and String(tn.p.get("t", "any")) == "any":
				tn.p["t"] = from_pin.type
	if fn.get("kind", "") == "reroute" and String(fn.p.get("t", "any")) == "any" and to_pin.type != "any":
		fn.p["t"] = to_pin.type


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var r := _pins_for(from_node, from_port, to_node, to_port)
	if r.is_empty():
		return
	editor.mutate("Break Link", func():
		for i in range(graph.wires.size() - 1, -1, -1):
			var w: Array = graph.wires[i]
			if int(w[0]) == r[0].node_id and w[1] == r[1].id and int(w[2]) == r[2].node_id and w[3] == r[3].id:
				graph.wires.remove_at(i))


func _on_connection_to_empty(from_node: StringName, from_port: int, release_position: Vector2) -> void:
	var a := get_node_or_null(String(from_node)) as BPNode
	if a == null or from_port >= a.out_pins.size():
		return
	var pin: Dictionary = a.out_pins[from_port]
	_open_palette(release_position, {"type": pin.type, "out": true, "node": a.node_id, "pin": pin})


func _on_connection_from_empty(to_node: StringName, to_port: int, release_position: Vector2) -> void:
	var b := get_node_or_null(String(to_node)) as BPNode
	if b == null or to_port >= b.in_pins.size():
		return
	var pin: Dictionary = b.in_pins[to_port]
	_open_palette(release_position, {"type": pin.type, "out": false, "node": b.node_id, "pin": pin})


# ---------------------------------------------------------------- palette / spawning

func _open_palette(local_pos: Vector2, ctx: Dictionary) -> void:
	var gpos := to_graph_pos(local_pos)
	editor.open_palette(get_screen_position() + local_pos, ctx, func(act: Dictionary): spawn(act.k, act.p, gpos, ctx))


func _element_at(local_pos: Vector2) -> GraphElement:
	var best: GraphElement = null
	for c in get_children():
		if c is GraphElement and c.visible and Rect2(c.position, c.size * c.scale).has_point(local_pos):
			if best == null or c is GraphNode:
				best = c
	return best


func _on_popup_request(at_position: Vector2) -> void:
	var el := _element_at(at_position)
	if el != null and (el is GraphNode or el.selected):
		if not el.selected:
			for c in get_children():
				if c is GraphElement:
					c.selected = c == el
		_menu_node = int(String(el.name).trim_prefix("n"))
		_node_menu.clear()
		_node_menu.add_icon_item(W.icon("Remove"), "Delete", 0)
		_node_menu.add_icon_item(W.icon("Duplicate"), "Duplicate", 1)
		_node_menu.add_icon_item(W.icon("ActionCopy"), "Copy", 2)
		_node_menu.add_separator()
		_node_menu.add_icon_item(W.icon("Unlinked"), "Break All Node Links", 3)
		_node_menu.add_icon_item(W.dot(Color(0.95, 0.12, 0.1)), "Toggle Breakpoint (F9)", 7)
		_node_menu.add_icon_item(W.icon("GraphEdit"), "Collapse to Macro", 8)
		_node_menu.add_icon_item(W.icon("MemberMethod"), "Collapse to Function", 14)
		if selected_ids().size() > 1:
			_node_menu.add_item("Align Left", 10)
			_node_menu.add_item("Align Top", 11)
		if Model.find_node(graph, _menu_node).get("kind", "") == "cast":
			_node_menu.add_item("Convert to Impure Cast" if Model.find_node(graph, _menu_node).p.get("pure", false) else "Convert to Pure Cast", 9)
		var n := Model.find_node(graph, _menu_node)
		if n.get("kind", "") in ["sequence", "make_array", "make_dict", "switch", "multigate", "math"]:
			_node_menu.add_separator()
			_node_menu.add_item("Add Pin", 4)
			_node_menu.add_item("Remove Last Pin", 5)
		if n.get("kind", "") in ["call", "bcall", "util"] and n.p.has("n"):
			_node_menu.add_separator()
			_node_menu.add_item("Add Argument Pin", 4)
			_node_menu.add_item("Remove Argument Pin", 5)
		if n.get("kind", "") in ["call_self", "macro"]:
			_node_menu.add_separator()
			_node_menu.add_item("Open Graph", 6)
		if n.get("kind", "") == "macro":
			_node_menu.add_item("Expand Node", 12)
		_node_menu.add_separator()
		_node_menu.add_icon_item(W.icon("Edit"), "Node Comment...", 13)
		_menu_pins = []
		var raw := R.describe_raw(n, bp, graph)
		var split_now: Dictionary = n.get("split", {})
		for side in ["ins", "outs"]:
			for pd in raw[side]:
				if not R.SPLIT.has(String(pd.type)):
					continue
				if _menu_pins.is_empty():
					_node_menu.add_separator()
				var is_split := split_now.has(pd.id)
				var label := String(pd.name) if String(pd.name) != "" else String(pd.type)
				_node_menu.add_item(("Recombine Struct Pin: %s" if is_split else "Split Struct Pin: %s") % label, 100 + _menu_pins.size())
				_menu_pins.append(String(pd.id))
		# Watch This Value, for each input pin that has a wire (the value is read while the game is paused)
		_menu_watch = []
		for pd in raw.ins:
			if String(pd.type) == "exec":
				continue
			var wired := false
			for w in graph.wires:
				if int(w[2]) == _menu_node and String(w[3]) == String(pd.id):
					wired = true
			if not wired:
				continue
			if _menu_watch.is_empty():
				_node_menu.add_separator()
			var pin_label := String(pd.name) if String(pd.name) != "" else String(pd.id)
			var entry: Dictionary = editor.pin_watch(_menu_node, String(pd.id), pin_label)
			_node_menu.add_icon_item(W.icon("GuiVisibilityVisible"), ("Stop Watching: %s" if editor.debug_panel.watches.has(entry) else "Watch This Value: %s") % pin_label, 200 + _menu_watch.size())
			_menu_watch.append(entry)
		_node_menu.position = Vector2i(get_screen_position() + at_position)
		_node_menu.reset_size()
		_node_menu.popup()
		return
	_open_palette(at_position, {})


func _on_node_menu(id: int) -> void:
	match id:
		0: _on_delete_nodes([])
		1:
			copy_selection()
			paste(Vector2.INF)
		2: copy_selection()
		3:
			var ids := selected_ids()
			editor.mutate("Break Node Links", func():
				for i in range(graph.wires.size() - 1, -1, -1):
					if ids.has(int(graph.wires[i][0])) or ids.has(int(graph.wires[i][2])):
						graph.wires.remove_at(i))
		4: add_pin_requested(_menu_node)
		5: add_pin_requested(_menu_node, -1)
		7: editor.toggle_breakpoints(selected_ids())
		8: collapse_selection()
		14: collapse_selection(true)
		12: expand_macro(_menu_node)
		13: editor.edit_node_comment(_menu_node)
		10, 11:
			var align_ids := selected_ids()
			var horizontal := id == 10
			editor.mutate("Align Nodes", func():
				var edge := INF
				for n in graph.nodes:
					if align_ids.has(int(n.id)):
						edge = minf(edge, float(n.x) if horizontal else float(n.y))
				for n in graph.nodes:
					if align_ids.has(int(n.id)):
						if horizontal:
							n.x = edge
						else:
							n.y = edge)
		9:
			var cast_id := _menu_node
			editor.mutate("Convert Cast", func():
				var cn := Model.find_node(graph, cast_id)
				cn.p["pure"] = not cn.p.get("pure", false))
		_:
			if id >= 200 and id - 200 < _menu_watch.size():
				editor.debug_panel.toggle_watch(_menu_watch[id - 200])
			elif id >= 100 and id - 100 < _menu_pins.size():
				toggle_split(_menu_node, _menu_pins[id - 100])
		6: node_double_clicked(_menu_node)


## Creates a node from a palette action and (optionally) wires it to the pin the user dragged from.
func spawn(kind: String, params: Dictionary, gpos: Vector2, ctx: Dictionary = {}) -> void:
	if kind == "__promote":
		_promote(gpos, ctx)
		return
	if kind == "__assign":
		_assign(params, gpos, ctx)
		return
	var new_id := [-1]
	editor.mutate("Add Node", func():
		var p: Dictionary = params.duplicate(true)
		match kind:
			"custom_event":
				p["name"] = Model.unique_name(String(p.get("name", "CustomEvent")), Model.member_names(bp))
			"timeline":
				p["name"] = Model.unique_name(String(p.get("name", "Timeline")), Model.member_names(bp))
			"event":
				for n in graph.nodes:
					if n.kind == "event" and n.p.name == p.name:
						new_id[0] = int(n.id)  # already exists: just focus it (Unreal behaviour)
						return
			"reroute":
				if not ctx.is_empty():
					p["t"] = ctx.type
			"switch":
				if not ctx.is_empty() and ctx.out and String(ctx.pin.get("enum", "")) != "":
					p = {"t": "int", "enum": ctx.pin.enum, "cases": []}
					for v in R.enum_values(ctx.pin.enum):
						p.cases.append([String(v[0]).capitalize(), str(int(v[1]))])
		var n := Model.add_node(graph, kind, gpos, p)
		new_id[0] = int(n.id)
		if ctx.is_empty():
			return
		var d := R.describe(n, bp, graph)
		var pins: Array = d.ins if ctx.out else d.outs
		var chosen := {}
		for strict in [true, false]:
			for pin in pins:
				if not chosen.is_empty():
					break
				if (pin.type == "exec") != (ctx.type == "exec"):
					continue
				var ok: bool
				if ctx.out:
					ok = T.matches(ctx.type, pin.type) if strict else T.can_connect(ctx.type, pin.type)
				else:
					ok = T.matches(pin.type, ctx.type) if strict else T.can_connect(pin.type, ctx.type)
				if ctx.type == "exec" or ok:
					chosen = pin
		if chosen.is_empty():
			return
		if ctx.out:
			add_wire(int(ctx.node), ctx.pin, int(n.id), chosen)
		else:
			add_wire(int(n.id), chosen, int(ctx.node), ctx.pin))
	if new_id[0] != -1:
		_pending_select = [new_id[0]]
		for c in get_children():
			if c is GraphElement:
				c.selected = String(c.name) == "n%d" % new_id[0]
		_selection_changed.call_deferred()


## Unreal's "Assign <dispatcher>": a Bind node plus a new custom event with the signal's parameters, wired up.
func _assign(params: Dictionary, gpos: Vector2, ctx: Dictionary) -> void:
	var apply := func():
		var ev_name := Model.unique_name("On" + String(params.signal).to_pascal_case(), Model.member_names(bp))
		var bind := Model.add_node(graph, "bind_signal", gpos, {"cls": params.cls, "signal": params.signal})
		var ev := Model.add_node(graph, "custom_event", gpos + Vector2(0, 170), {"name": ev_name, "params": params.get("args", []).duplicate(true)})
		var ref := Model.add_node(graph, "event_ref", gpos + Vector2(-230, 90), {"fn": ev_name})
		graph.wires.append([int(ref.id), "fn", int(bind.id), "fn"])
		if not ctx.is_empty() and ctx.out:
			var d := R.describe(bind, bp, graph)
			for pin in d.ins:
				if (ctx.type == "exec" and pin.type == "exec") or (ctx.type != "exec" and pin.id == "target" and T.can_connect(String(ctx.type), String(pin.type))):
					add_wire(int(ctx.node), ctx.pin, int(bind.id), pin)
					break
		if ev.is_empty():
			return
	editor.mutate("Assign Event", apply)


## Unreal's "Promote to Variable": makes a variable from a pin and wires a Get (input pin) or Set (output pin).
func _promote(gpos: Vector2, ctx: Dictionary) -> void:
	if ctx.is_empty() or String(ctx.type) == "exec":
		return
	var pin: Dictionary = ctx.pin
	var base := T.ident(String(pin.name).strip_edges().replace(" ", "_")) if String(pin.name).strip_edges() != "" else "NewVar"
	var vname := Model.unique_name(base if base != "_" else "NewVar", Model.member_names(bp))
	var apply := func():
		var vtype := String(pin.type)
		var def := ""
		if not ctx.out:
			var src_node := Model.find_node(graph, int(ctx.node))
			def = String(src_node.get("d", {}).get(pin.id, pin.get("def", "")))
		bp.variables.append({"name": vname, "type": vtype, "default": def, "export": false, "category": "", "tooltip": ""})
		var n := Model.add_node(graph, "var_set" if ctx.out else "var_get", gpos, {"name": vname})
		if ctx.out:
			add_wire(int(ctx.node), pin, int(n.id), {"id": "value", "type": vtype})
		else:
			add_wire(int(n.id), {"id": "value", "type": vtype}, int(ctx.node), pin)
	editor.mutate("Promote to Variable", apply)


## Unreal's "Collapse Nodes": moves the selection into a new macro and leaves one node in its place.
## Every wire crossing the selection boundary becomes a macro input or output.
func collapse_selection(as_function := false) -> void:
	var ids := selected_ids()
	var moved := []
	for n in graph.nodes:
		if ids.has(int(n.id)):
			if n.kind in ["event", "custom_event", "input_action", "signal_event", "key_event", "fn_entry", "fn_return", "macro_in", "macro_out", "timeline"]:
				editor.toast("Events, timelines and entry/return nodes can't be collapsed. Deselect them first.")
				return
			if n.kind != "comment":
				moved.append(n)
	if moved.is_empty():
		return
	var descs := {}
	for n in moved:
		descs[int(n.id)] = R.describe(n, bp, graph)
	var pin_of := func(nid: int, pid: String, outputs: bool) -> Dictionary:
		for pd in (descs[nid].outs if outputs else descs[nid].ins):
			if pd.id == pid:
				return pd
		return {"id": pid, "name": pid, "type": "any"}
	if as_function:
		# A function has one way in and one way out, and cannot wait: check before changing anything.
		var sel := {}
		for n in moved:
			sel[int(n.id)] = true
			if descs[int(n.id)].latent:
				editor.toast("A function can't contain latent nodes such as Delay. Use Collapse to Macro instead.")
				return
		var exec_in := {}
		var exec_out := {}
		for w in graph.wires:
			var a_in := sel.has(int(w[0]))
			var b_in := sel.has(int(w[2]))
			if b_in and not a_in and pin_of.call(int(w[2]), String(w[3]), false).type == "exec":
				exec_in["%d:%s" % [w[2], w[3]]] = true
			if a_in and not b_in and pin_of.call(int(w[0]), String(w[1]), true).type == "exec":
				exec_out["%d:%s" % [w[0], w[1]]] = true
		var pure_ok := exec_in.is_empty() and exec_out.is_empty()
		for n in moved:
			if pure_ok and not descs[int(n.id)].pure:
				pure_ok = false
				if exec_in.is_empty() and exec_out.is_empty():
					editor.toast("Wire the selection into an execution path first, or use Collapse to Macro.")
					return
		if not pure_ok and not (exec_in.size() == 1 and exec_out.size() == 1):
			editor.toast("Collapse to Function needs exactly one exec wire going in and one coming out. Use Collapse to Macro for anything else.")
			return
	var apply := func():
		var mids := {}
		var centre := Vector2.ZERO
		var low := Vector2(INF, INF)
		for n in moved:
			mids[int(n.id)] = true
			centre += Vector2(n.x, n.y)
			low = Vector2(minf(low.x, n.x), minf(low.y, n.y))
		centre /= moved.size()
		var mg := Model.new_graph(bp, Model.unique_name("NewFunction" if as_function else "Collapsed", Model.member_names(bp)), "macro")
		mg.inputs = []
		mg.outputs = []
		var max_id := 0
		for n in moved:
			max_id = maxi(max_id, int(n.id))
		var m_in: Dictionary = mg.nodes[0]
		var m_out: Dictionary = mg.nodes[1]
		m_in.id = max_id + 1
		m_out.id = max_id + 2
		mg.next_id = max_id + 3
		var call := Model.add_node(graph, "macro", centre, {"name": mg.name})
		var in_names := {}    # key -> macro input name
		var out_names := {}
		var taken_in := []
		var taken_out := []
		var keep := []
		for w in graph.wires:
			var a_in := mids.has(int(w[0]))
			var b_in := mids.has(int(w[2]))
			if a_in and b_in:
				mg.wires.append(w)
			elif b_in:
				var pd: Dictionary = pin_of.call(int(w[2]), String(w[3]), false)
				var key := ("x%d:%s" % [w[2], w[3]]) if pd.type == "exec" else ("d%d:%s" % [w[0], w[1]])
				if not in_names.has(key):
					var base := T.ident(String(pd.name) if String(pd.name) != "" else ("In" if pd.type == "exec" else "Value"))
					var nm := Model.unique_name(base if base != "_" else "In", taken_in)
					taken_in.append(nm)
					in_names[key] = nm
					var src_type := String(pd.type)
					if src_type != "exec":
						var sn := Model.find_node(graph, int(w[0]))
						for so in R.describe(sn, bp, graph).outs:
							if so.id == w[1]:
								src_type = so.type
					mg.inputs.append([nm, src_type])
				mg.wires.append([int(m_in.id), "i_" + String(in_names[key]), int(w[2]), w[3]])
				keep.append([int(w[0]), w[1], int(call.id), "i_" + String(in_names[key])])
			elif a_in:
				var pd: Dictionary = pin_of.call(int(w[0]), String(w[1]), true)
				var key := "%d:%s" % [w[0], w[1]]
				if not out_names.has(key):
					var base := T.ident(String(pd.name) if String(pd.name) != "" else ("Out" if pd.type == "exec" else "Result"))
					var nm := Model.unique_name(base if base != "_" else "Out", taken_out)
					taken_out.append(nm)
					out_names[key] = nm
					mg.outputs.append([nm, String(pd.type)])
				mg.wires.append([int(w[0]), w[1], int(m_out.id), "o_" + String(out_names[key])])
				keep.append([int(call.id), "o_" + String(out_names[key]), int(w[2]), w[3]])
			else:
				keep.append(w)
		# de-duplicate wires created for shared inputs/outputs
		var seen := {}
		var uniq := []
		for w in keep:
			var k := "%s|%s|%s|%s" % [w[0], w[1], w[2], w[3]]
			if not seen.has(k):
				seen[k] = true
				uniq.append(w)
		graph.wires = uniq
		seen = {}
		uniq = []
		for w in mg.wires:
			var k := "%s|%s|%s|%s" % [w[0], w[1], w[2], w[3]]
			if not seen.has(k):
				seen[k] = true
				uniq.append(w)
		mg.wires = uniq
		graph.nodes = graph.nodes.filter(func(n): return not mids.has(int(n.id)))
		var shift := Vector2(320, 120) - low
		for n in moved:
			n.x += shift.x
			n.y += shift.y
			mg.nodes.append(n)
		var far := 0.0
		for n in moved:
			far = maxf(far, n.x)
		m_out.x = far + 360
		if as_function:
			_macro_to_function(mg, m_in, m_out, call)
	editor.mutate("Collapse to Function" if as_function else "Collapse to Macro", apply)


## Turns a freshly collapsed macro into a function: exec pins become the function's own entry and return
## execution, data pins become its inputs and outputs, and the node that replaced the selection calls it.
func _macro_to_function(mg: Dictionary, m_in: Dictionary, m_out: Dictionary, call: Dictionary) -> void:
	var exec_in := ""
	var exec_out := ""
	for prm in mg.inputs:
		if String(prm[1]) == "exec":
			exec_in = String(prm[0])
	for prm in mg.outputs:
		if String(prm[1]) == "exec":
			exec_out = String(prm[0])
	mg.kind = "function"
	mg.pure = exec_in == "" and exec_out == ""
	mg.inputs = mg.inputs.filter(func(prm): return String(prm[1]) != "exec")
	mg.outputs = mg.outputs.filter(func(prm): return String(prm[1]) != "exec")
	m_in.kind = "fn_entry"
	m_out.kind = "fn_return"
	for w in mg.wires:
		if int(w[0]) == int(m_in.id):
			w[1] = "then" if String(w[1]) == "i_" + exec_in else "p_" + String(w[1]).trim_prefix("i_")
		if int(w[2]) == int(m_out.id):
			w[3] = "exec" if String(w[3]) == "o_" + exec_out else "r_" + String(w[3]).trim_prefix("o_")
	for w in graph.wires:
		if int(w[2]) == int(call.id):
			w[3] = "exec" if String(w[3]) == "i_" + exec_in else "a_" + String(w[3]).trim_prefix("i_")
		if int(w[0]) == int(call.id):
			w[1] = "then" if String(w[1]) == "o_" + exec_out else "r_" + String(w[1]).trim_prefix("o_")
	call.kind = "call_self"
	call.p = {"fn": mg.name}


## Unreal's "Expand Node": replaces a macro node with a copy of the macro's nodes, wired the same way.
func expand_macro(nid: int) -> void:
	var call := Model.find_node(graph, nid)
	if call.is_empty() or call.kind != "macro":
		return
	var mg := R.macro_graph(bp, call.p)
	if mg.is_empty():
		return
	var new_ids := []
	var apply := func():
		var remap := {}
		var in_id := -1
		var out_id := -1
		var low := Vector2(INF, INF)
		for src in mg.nodes:
			if src.kind == "macro_in":
				in_id = int(src.id)
			elif src.kind == "macro_out":
				out_id = int(src.id)
			else:
				low = Vector2(minf(low.x, src.x), minf(low.y, src.y))
		if low.x == INF:
			low = Vector2.ZERO
		var copies := {}
		for src in mg.nodes:
			if src.kind in ["macro_in", "macro_out"]:
				continue
			var c: Dictionary = src.duplicate(true)
			Model.forget_place(c)   # where the name belonged was a place in the graph the macro was made from
			c.id = int(graph.next_id)
			graph.next_id = int(graph.next_id) + 1
			c.x = float(call.x) + float(src.x) - low.x
			c.y = float(call.y) + float(src.y) - low.y
			remap[int(src.id)] = int(c.id)
			copies[int(c.id)] = c
			graph.nodes.append(c)
			new_ids.append(int(c.id))
		# the macro's locals become locals of this graph: the one this use names, or a new one
		var names: Dictionary = call.p.get("names", {})
		var renamed := {}
		for ml in mg.get("locals", []):
			var held: Array = graph.locals.map(func(l): return String(l.name))
			var local_name := String(names.get(String(ml.name), ""))
			if local_name == "":
				local_name = Model.unique_name(String(ml.name), held)
			if not held.has(local_name):
				var own: Dictionary = ml.duplicate(true)
				own["name"] = local_name
				graph.locals.append(own)
			renamed[String(ml.name)] = local_name
		for c in copies.values():
			if c.kind in ["local_get", "local_set"] and renamed.has(String(c.p.get("name", ""))):
				c.p["name"] = renamed[String(c.p.name)]
		var fed := {}   # macro input pins that have a wire coming in from outside
		var wires := []
		for w in graph.wires:
			if int(w[2]) == nid:
				fed[String(w[3])] = true
				for mw in mg.wires:
					if int(mw[0]) != in_id or String(mw[1]) != String(w[3]):
						continue
					if remap.has(int(mw[2])):
						wires.append([w[0], w[1], remap[int(mw[2])], mw[3]])
					elif int(mw[2]) == out_id:
						# input wired straight to an output: join the outer wires on both sides
						for ow in graph.wires:
							if int(ow[0]) == nid and String(ow[1]) == String(mw[3]):
								wires.append([w[0], w[1], ow[2], ow[3]])
			elif int(w[0]) == nid:
				for mw in mg.wires:
					if int(mw[2]) == out_id and String(mw[3]) == String(w[1]) and remap.has(int(mw[0])):
						wires.append([remap[int(mw[0])], mw[1], w[2], w[3]])
			else:
				wires.append(w)
		for mw in mg.wires:
			if remap.has(int(mw[0])) and remap.has(int(mw[2])):
				wires.append([remap[int(mw[0])], mw[1], remap[int(mw[2])], mw[3]])
			elif int(mw[0]) == in_id and remap.has(int(mw[2])) and not fed.has(String(mw[1])) and call.get("d", {}).has(mw[1]):
				# a value typed on the macro node's pin moves onto the pin it fed
				copies[remap[int(mw[2])]].d[mw[3]] = call.d[mw[1]]
		graph.wires = wires
		Model.remove_node(graph, nid)
	editor.mutate("Expand Node", apply)
	_pending_select = new_ids


## Splits a struct pin into one pin per member, or recombines it. Wires on the affected pin are dropped.
func toggle_split(nid: int, pin_id: String) -> void:
	editor.mutate("Split Struct Pin", func():
		var n := Model.find_node(graph, nid)
		if n.is_empty():
			return
		var split: Dictionary = n.get("split", {})
		if split.has(pin_id):
			split.erase(pin_id)
			for k in n.d.keys():
				if String(k).begins_with(pin_id + "~"):
					n.d.erase(k)
		else:
			split[pin_id] = true
			# Carry an existing inline default over to the member pins.
			var cur: Variant = T.parse_literal(String(n.d.get(pin_id, "")), null)
			for rp in R.describe_raw(n, bp, graph).ins:
				if rp.id == pin_id and cur != null and R.SPLIT.has(String(rp.type)):
					var members: Array = R.SPLIT[String(rp.type)][0]
					for i in members.size():
						n.d["%s~%s" % [pin_id, members[i]]] = T.to_literal(cur[i])
			n.d.erase(pin_id)
		if split.is_empty():
			n.erase("split")
		else:
			n["split"] = split)


func add_pin_requested(nid: int, delta := 1) -> void:
	editor.mutate("Change Pins", func():
		var n := Model.find_node(graph, nid)
		if n.is_empty():
			return
		if n.kind == "switch":
			var cases: Array = n.p.get("cases", [])
			if delta > 0:
				var is_str := String(n.p.get("t", "int")) == "String"
				var k := cases.size()
				cases.append([str(k), "\"%d\"" % k] if is_str else [str(k), str(k)])
			elif not cases.is_empty():
				cases.pop_back()
			n.p["cases"] = cases
		else:
			n.p["n"] = maxi(int(n.p.get("n", 1)) + delta, 2 if n.kind in ["math", "multigate"] else (0 if n.kind != "sequence" else 1)))


func pin_default_changed(nid: int, pin_id: String, literal: String) -> void:
	var n := Model.find_node(graph, nid)
	if n.is_empty() or String(n.d.get(pin_id, "\u0000")) == literal:
		return
	var apply := func():
		if literal == "":
			n.d.erase(pin_id)
		else:
			n.d[pin_id] = literal
	editor.mutate("Change Pin Value", apply, false)


func node_double_clicked(nid: int) -> void:
	var n := Model.find_node(graph, nid)
	if n.is_empty():
		return
	match n.kind:
		"call_self":
			editor.open_member_graph(String(n.p.fn))
		"macro":
			if String(n.p.get("lib", "")) != "":
				editor.open_library_macro(String(n.p.lib), String(n.p.name))
			else:
				editor.open_member_graph(String(n.p.name))
		"event_ref":
			editor.open_member_graph(String(n.p.fn))
		_:
			editor.focus_details()


# ---------------------------------------------------------------- delete / clipboard / move

func _on_delete_nodes(_nodes: Array) -> void:
	var ids := selected_ids()
	ids = ids.filter(func(id): return Model.find_node(graph, id).get("kind", "") not in ["fn_entry", "macro_in", "macro_out"])
	if ids.is_empty():
		return
	editor.mutate("Delete Nodes", func():
		for id in ids:
			# a reroute is a knot on a wire: taking it out leaves the wire, joined straight through
			if String(Model.find_node(graph, id).get("kind", "")) == "reroute":
				var into := []
				var out_of := []
				for w in graph.wires:
					if int(w[2]) == id and String(w[3]) == "i":
						into.append(w)
					elif int(w[0]) == id and String(w[1]) == "o":
						out_of.append(w)
				for a in into:
					for b in out_of:
						graph.wires.append([int(a[0]), String(a[1]), int(b[2]), String(b[3])])
			Model.remove_node(graph, id))


func copy_selection() -> void:
	var ids := selected_ids()
	var nodes := []
	for n in graph.nodes:
		if ids.has(int(n.id)) and not n.kind in ["fn_entry", "macro_in", "macro_out"]:
			nodes.append(n.duplicate(true))
	var wires := []
	for w in graph.wires:
		if ids.has(int(w[0])) and ids.has(int(w[2])):
			wires.append(w.duplicate())
	clipboard = {"nodes": nodes, "wires": wires}


func paste(at: Vector2) -> void:
	if clipboard.is_empty() or clipboard.nodes.is_empty():
		return
	var origin := Vector2(INF, INF)
	for n in clipboard.nodes:
		origin.x = minf(origin.x, n.x)
		origin.y = minf(origin.y, n.y)
	var offset := Vector2(24, 24) if at == Vector2.INF else at - origin
	var new_ids := []
	editor.mutate("Paste Nodes", func():
		var remap := {}
		for src in clipboard.nodes:
			if src.kind == "event" or (src.kind == "fn_return" and graph.kind != "function"):
				var dup := false
				for e in graph.nodes:
					if e.kind == src.kind and e.p.get("name", "") == src.p.get("name", ""):
						dup = true
				if dup or src.kind == "fn_return" and graph.kind != "function":
					continue
			var n: Dictionary = src.duplicate(true)
			n.id = int(graph.next_id)
			graph.next_id = int(graph.next_id) + 1
			n.x += offset.x
			n.y += offset.y
			if n.kind == "custom_event" or n.kind == "timeline":
				n.p["name"] = Model.unique_name(String(n.p.name), Model.member_names(bp))
			remap[int(src.id)] = int(n.id)
			graph.nodes.append(n)
			new_ids.append(int(n.id))
		for w in clipboard.wires:
			if remap.has(int(w[0])) and remap.has(int(w[2])):
				graph.wires.append([remap[int(w[0])], w[1], remap[int(w[2])], w[3]]))
	_pending_select = new_ids
	for c in get_children():
		if c is GraphElement:
			c.selected = new_ids.has(int(String(c.name).trim_prefix("n")))


func _on_end_node_move() -> void:
	var moved := {}
	for c in get_children():
		if not c is GraphElement:
			continue
		var n := Model.find_node(graph, int(String(c.name).trim_prefix("n")))
		if not n.is_empty() and (not is_equal_approx(n.x, c.position_offset.x) or not is_equal_approx(n.y, c.position_offset.y)):
			moved[int(n.id)] = c.position_offset
	if moved.is_empty():
		return
	var apply := func():
		for id in moved:
			var n := Model.find_node(graph, id)
			n.x = moved[id].x
			n.y = moved[id].y
	editor.mutate("Move Nodes", apply, false)


func comment_selection() -> void:
	var rect := Rect2()
	var first := true
	for c in get_children():
		if c is GraphNode and c.selected and not c.has_meta("gone"):
			var r := Rect2(c.position_offset, c.size)
			rect = r if first else rect.merge(r)
			first = false
	if first:
		rect = Rect2(_mouse_graph_pos(), Vector2(400, 200))
	else:
		rect = rect.grow_individual(30, 60, 30, 30)
	spawn("comment", {"text": "Comment", "w": rect.size.x, "h": rect.size.y}, rect.position)


# ---------------------------------------------------------------- input

func _gui_input(event: InputEvent) -> void:
	if graph.is_empty():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and (event.double_click or event.alt_pressed):
		# Unreal wire gestures: double-click a wire to add a reroute node, Alt+click a wire to break it.
		var conn := get_closest_connection_at_point(event.position)
		if not conn.is_empty():
			var r := _pins_for(conn.from_node, int(conn.from_port), conn.to_node, int(conn.to_port))
			if not r.is_empty():
				var gpos := to_graph_pos(event.position)
				var breaking: bool = event.alt_pressed
				editor.mutate("Break Link" if breaking else "Add Reroute Node", func():
					for i in range(graph.wires.size() - 1, -1, -1):
						var w: Array = graph.wires[i]
						if int(w[0]) == r[0].node_id and w[1] == r[1].id and int(w[2]) == r[2].node_id and w[3] == r[3].id:
							graph.wires.remove_at(i)
					if not breaking:
						var rn := Model.add_node(graph, "reroute", gpos - Vector2(20, 14), {"t": String(r[1].type)})
						graph.wires.append([r[0].node_id, r[1].id, int(rn.id), "i"])
						graph.wires.append([int(rn.id), "o", r[2].node_id, r[3].id]))
				accept_event()
				return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		for key in QUICK_KEYS:
			if Input.is_key_pressed(key) and not event.ctrl_pressed and not event.alt_pressed:
				spawn(QUICK_KEYS[key][0], QUICK_KEYS[key][1], to_graph_pos(event.position))
				accept_event()
				return
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and not event.alt_pressed:
		if event.keycode == KEY_C and not event.shift_pressed:
			comment_selection()
			accept_event()
		elif event.keycode == KEY_TAB:
			_open_palette(get_local_mouse_position(), {})
			accept_event()
		elif event.keycode == KEY_F9:
			editor.toggle_breakpoints(selected_ids())
			accept_event()


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if graph.is_empty() or typeof(data) != TYPE_DICTIONARY:
		return false
	return String(data.get("type", "")) in ["nodes", "files", "bp_member", "bp_component"]


func _drop_data(at: Vector2, data: Variant) -> void:
	var gpos := to_graph_pos(at)
	match String(data.get("type", "")):
		"bp_member":
			match String(data.kind):
				"var", "local":
					var get_kind := "var_get" if data.kind == "var" else "local_get"
					var set_kind := "var_set" if data.kind == "var" else "local_set"
					if Input.is_key_pressed(KEY_CTRL):
						spawn(get_kind, {"name": data.name}, gpos)
					elif Input.is_key_pressed(KEY_ALT):
						spawn(set_kind, {"name": data.name}, gpos)
					else:
						var m := PopupMenu.new()
						m.add_item("Get " + String(data.name), 0)
						m.add_item("Set " + String(data.name), 1)
						m.id_pressed.connect(func(id): spawn(get_kind if id == 0 else set_kind, {"name": data.name}, gpos))
						m.popup_hide.connect(m.queue_free)
						add_child(m)
						m.position = Vector2i(get_screen_position() + at)
						m.popup()
				"fn", "event":
					spawn("call_self", {"fn": data.name}, gpos)
				"macro":
					if String(data.name) == String(graph.get("name", "")):
						editor.toast("A macro can't use itself.")
					else:
						spawn("macro", {"name": data.name}, gpos)
				"dispatcher":
					spawn("emit", {"name": data.name}, gpos)
		"bp_component":
			spawn("get_node", {"path": data.path, "cls": data.cls}, gpos)
		"nodes":
			var host: Node = editor.find_host()
			if host == null:
				editor.toast("Open the scene that uses this schematic to drag its nodes in.")
				return
			var i := 0
			for np in data.nodes:
				var node := get_node_or_null(np)
				if node == null:
					continue
				spawn("get_node", editor.node_ref_params(host, node), gpos + Vector2(0, 50 * i))
				i += 1
		"files":
			var i := 0
			for f in data.files:
				# asked of the editor's file list: ResourceLoader.get_resource_type is not in Godot 4.7
				var rt := String(EditorInterface.get_resource_filesystem().get_file_type(f)) if ResourceLoader.exists(f) else ""
				if rt == "":
					continue
				var info := R.table_info(f) if f.get_extension() == "tres" else {}
				if not info.is_empty() and (load(f) as Resource).has_method("get_row_names"):
					# a Data Table file becomes a row lookup already pointed at it
					spawn("table_row", {"table": f, "cls": String(info.cls)}, gpos + Vector2(0, 110 * i))
					i += 1
					continue
				spawn("const", {"expr": "preload(\"%s\")" % f, "t": rt, "label": String(f).get_file()}, gpos + Vector2(0, 50 * i))
				i += 1
