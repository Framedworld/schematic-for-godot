@tool
extends GraphNode
## Visual for one blueprint node: Unreal-style header colour, exec arrows, typed pins, inline defaults.

const T := preload("res://addons/blueprints/core/bp_types.gd")
const W := preload("res://addons/blueprints/editor/bp_widgets.gd")

var node_id: int
var kind: String
var desc: Dictionary
var in_pins: Array = []    # pin dict per left port index
var out_pins: Array = []   # pin dict per right port index
var _view: Node
var _slot_in: Dictionary = {}    # slot index -> [pin, wired]
var _slot_out: Dictionary = {}
var _headless := false
var _head_bottom := 4.0
var _inset := 1.0
var _breakpoint := false

var _in_rows: Dictionary = {}       # input pin id -> its row, for the live value labels
var _watch_labels: Dictionary = {}
var _bubble_text := ""
var _ghost := false

const EVENT_KINDS := ["event", "custom_event", "input_action", "key_event", "signal_event"]
const GHOST_TEXT := "This node is disabled and will not be called.\nDrag off pins to build functionality."


## Title icons drawn as vectors in Unreal's shapes (event diamond, italic f, branch fork...).
class Glyph extends Control:
	var shape := ""
	var tint := Color(1, 1, 1, 0.95)

	func _init(p_shape: String) -> void:
		shape = p_shape
		custom_minimum_size = Vector2(16, 16)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		var o := (size - Vector2(16, 16)) * 0.5
		match shape:
			"event":
				var d := PackedVector2Array([o + Vector2(8, 0.5), o + Vector2(15.5, 8), o + Vector2(8, 15.5), o + Vector2(0.5, 8), o + Vector2(8, 0.5)])
				draw_polyline(d, tint, 1.7, true)
				draw_line(o + Vector2(4.5, 8), o + Vector2(10.5, 8), tint, 1.7, true)
				draw_colored_polygon(PackedVector2Array([o + Vector2(8.2, 4.8), o + Vector2(11.8, 8), o + Vector2(8.2, 11.2)]), tint)
			"function":
				var f := get_theme_font("bold", "EditorFonts") if has_theme_font("bold", "EditorFonts") else get_theme_default_font()
				draw_set_transform_matrix(Transform2D(Vector2(1, 0), Vector2(-0.28, 1), o + Vector2(7.5, 0)))
				draw_string(f, Vector2(0, 13.5), "f", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, tint)
				draw_set_transform_matrix(Transform2D.IDENTITY)
			"branch":
				draw_rect(Rect2(o + Vector2(0.5, 5.5), Vector2(5, 5)), tint)
				draw_polyline(PackedVector2Array([o + Vector2(5, 8), o + Vector2(8.5, 8), o + Vector2(8.5, 3.5), o + Vector2(15, 3.5)]), tint, 1.6, true)
				draw_polyline(PackedVector2Array([o + Vector2(8.5, 8), o + Vector2(8.5, 12.5), o + Vector2(15, 12.5)]), tint, 1.6, true)
			"sequence":
				draw_line(o + Vector2(2, 2), o + Vector2(2, 14), tint, 1.6, true)
				for y in [3.0, 8.0, 13.0]:
					draw_line(o + Vector2(2, y), o + Vector2(9, y), tint, 1.6, true)
					draw_rect(Rect2(o + Vector2(10, y - 2), Vector2(4.5, 4)), tint)
			"loop":
				draw_arc(o + Vector2(8, 8), 5.5, deg_to_rad(-60), deg_to_rad(220), 20, tint, 1.7, true)
				draw_colored_polygon(PackedVector2Array([o + Vector2(8.2, 0.2), o + Vector2(13.6, 2.6), o + Vector2(9.2, 6.2)]), tint)
			"cast":
				draw_rect(Rect2(o + Vector2(0.5, 6), Vector2(4, 4)), tint)
				draw_line(o + Vector2(6, 8), o + Vector2(12, 8), tint, 1.6, true)
				draw_colored_polygon(PackedVector2Array([o + Vector2(11, 4.5), o + Vector2(15.5, 8), o + Vector2(11, 11.5)]), tint)
			"gate":
				draw_line(o + Vector2(1, 8), o + Vector2(6, 8), tint, 1.6, true)
				draw_line(o + Vector2(6, 8), o + Vector2(11.5, 3.5), tint, 1.6, true)
				draw_line(o + Vector2(11, 8), o + Vector2(15, 8), tint, 1.6, true)
				draw_circle(o + Vector2(6, 8), 1.7, tint, true, -1.0, true)
				draw_circle(o + Vector2(11, 8), 1.7, tint, true, -1.0, true)


const PIN_X := 16          # how far inside the node edge a pin sits (Unreal draws pins inside the body)
const ROW_H := 24


func setup(view: Node, node: Dictionary, d: Dictionary, wired_in: Dictionary, wired_out: Dictionary, error: String, mark := "") -> void:
	_view = view
	node_id = int(node.id)
	kind = node.kind
	desc = d
	name = "n%d" % node_id
	position_offset = Vector2(node.x, node.y)
	title = d.title
	tooltip_text = _wrap(d.tip)
	_style(d, error != "")
	_header(d)

	var ins: Array = d.ins.filter(func(p): return not p.get("const", false))
	var consts: Array = d.ins.filter(func(p): return p.get("const", false))
	var outs: Array = d.outs
	var rows := maxi(ins.size(), outs.size())
	if rows == 0 and consts.is_empty():
		rows = 1
	for i in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.custom_minimum_size.y = ROW_H
		var pi: Dictionary = ins[i] if i < ins.size() else {}
		var po: Dictionary = outs[i] if i < outs.size() else {}
		if not pi.is_empty():
			if String(pi.name) != "":
				row.add_child(_label(pi.name, false))
			if pi.type != "exec" and not wired_in.has(pi.id):
				var ed := W.make_value_editor(String(pi.get("ed", pi.type)), pi.get("enum", ""), String(node.d.get(pi.id, pi.get("def", ""))),
					func(lit): _view.pin_default_changed(node_id, pi.id, lit))
				if ed:
					row.add_child(ed)
				elif pi.get("self", false):
					var sl := _label("self", false)
					sl.add_theme_color_override("font_color", Color(0.45, 0.75, 1.0, 0.8))
					row.add_child(sl)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.custom_minimum_size.x = 14
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(spacer)
		if d.compact and i == 0 and d.title != "" and (kind == "op" or kind == "math"):
			var sym := Label.new()
			sym.text = d.title
			sym.add_theme_font_size_override("font_size", 26)
			sym.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
			row.add_child(sym)
			var sp2 := Control.new()
			sp2.custom_minimum_size.x = 10
			row.add_child(sp2)
		if not po.is_empty() and String(po.name) != "":
			row.add_child(_label(po.name, true))
		add_child(row)
		var has_in := not pi.is_empty()
		var has_out := not po.is_empty()
		# Port type 1 marks exec pins so the canvas can draw exec wires thicker than data wires.
		set_slot(i, has_in, 1 if has_in and pi.type == "exec" else 0, _pin_color(pi) if has_in else Color.WHITE,
			has_out, 1 if has_out and po.type == "exec" else 0, _pin_color(po) if has_out else Color.WHITE)
		row.tooltip_text = _pin_tip(pi, po)
		if has_in:
			in_pins.append(pi)
			_slot_in[i] = [pi, wired_in.has(pi.get("id", ""))]
			_in_rows[String(pi.id)] = row
		if has_out:
			out_pins.append(po)
			_slot_out[i] = [po, wired_out.has(po.get("id", ""))]
	for pc in consts:
		var row := HBoxContainer.new()
		row.add_child(_label(pc.name, false))
		var ed := W.make_value_editor(pc.type, "", String(node.d.get(pc.id, pc.get("def", ""))),
			func(lit): _view.pin_default_changed(node_id, pc.id, lit))
		if ed:
			row.add_child(ed)
		add_child(row)
	if kind in ["sequence", "make_array", "make_dict", "switch", "multigate"] or (kind == "math" and String(node.p.get("op", "")) in ["+", "*", "and", "or"]):
		var add := Button.new()
		add.text = "Add pin"
		add.icon = W.icon("Add")
		add.flat = true
		add.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add.add_theme_font_size_override("font_size", 11)
		add.pressed.connect(func(): _view.add_pin_requested(node_id))
		add_child(add)
	_breakpoint = mark.contains("bp")
	# Node comment bubble; built-in events that are not wired to anything are shown greyed out with Unreal's note.
	_bubble_text = String(node.get("c", ""))
	if _bubble_text == "" and kind == "event" and wired_in.is_empty() and wired_out.is_empty():
		_ghost = true
		_bubble_text = GHOST_TEXT
	if _ghost:
		self_modulate = Color(1, 1, 1, 0.5)
		for ch in get_children():
			if ch is CanvasItem:
				ch.modulate = Color(1, 1, 1, 0.5)
		for ch in get_titlebar_hbox().get_children():
			ch.modulate = Color(1, 1, 1, 0.5)
	if _bubble_text != "":
		var bubble := Control.new()
		bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bubble.custom_minimum_size = Vector2.ZERO
		bubble.draw.connect(_draw_bubble.bind(bubble))
		get_titlebar_hbox().add_child(bubble)
	if mark.contains("paused"):
		var pl := Label.new()
		pl.text = "> Execution paused here"
		pl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		pl.add_theme_font_size_override("font_size", 11)
		add_child(pl)
		for sb_name in ["panel", "panel_selected", "titlebar", "titlebar_selected"]:
			var sb := get_theme_stylebox(sb_name).duplicate() as StyleBoxFlat
			if sb:
				_inset = 3.0
				sb.border_color = Color(1.0, 0.85, 0.2)
				sb.set_border_width_all(3)
				if sb_name.begins_with("panel"):
					sb.border_width_top = 0
				else:
					sb.border_width_bottom = 0
				add_theme_stylebox_override(sb_name, sb)
	if error != "":
		var el := Label.new()
		el.text = "ERROR!\n" + error
		el.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		el.custom_minimum_size.x = 180
		el.add_theme_color_override("font_color", Color(1, 0.45, 0.4))
		el.add_theme_font_size_override("font_size", 11)
		add_child(el)


func _wrap(s: String) -> String:
	if s.length() < 70:
		return s
	var out := ""
	var col := 0
	for word in s.split(" "):
		if col + word.length() > 64:
			out += "\n"
			col = 0
		out += word + " "
		col += word.length() + 1
	return out.strip_edges()


func _label(text: String, right: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


func _pin_color(pin: Dictionary) -> Color:
	return T.color(String(pin.get("ed", pin.type)), String(pin.get("enum", "")) != "")


## Live values from the running game, shown beside the input pins they arrived on (Unreal's watch values).
func set_watch(values: Dictionary) -> void:
	for pid in values:
		var row: HBoxContainer = _in_rows.get(String(pid))
		if row == null:
			continue
		var lab: Label = _watch_labels.get(String(pid))
		if lab == null or not is_instance_valid(lab):
			lab = Label.new()
			lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
			lab.add_theme_font_size_override("font_size", 11)
			lab.add_theme_color_override("font_color", Color(1.0, 0.9, 0.55))
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.16, 0.13, 0.03, 0.95)
			sb.set_border_width_all(1)
			sb.border_color = Color(0.85, 0.65, 0.15, 0.9)
			sb.set_corner_radius_all(3)
			sb.content_margin_left = 5
			sb.content_margin_right = 5
			lab.add_theme_stylebox_override("normal", sb)
			lab.set_meta("watch", true)
			row.add_child(lab)
			row.move_child(lab, mini(1, row.get_child_count() - 1))
			_watch_labels[String(pid)] = lab
		var text := String(values[pid])
		lab.text = text if text.length() <= 28 else text.left(27) + "..."
		lab.tooltip_text = text


func _pin_tip(pi: Dictionary, po: Dictionary) -> String:
	var lines := PackedStringArray()
	for pin in [pi, po]:
		if pin.is_empty():
			continue
		var t := String(pin.type)
		var nice := "Exec" if t == "exec" else ("Wildcard" if t == "any" else t)
		if T.is_object(t):
			nice += " Object Reference"
		var nm := String(pin.name) if String(pin.name) != "" else ("Execute" if t == "exec" else "Value")
		lines.append("%s\n%s" % [nm, nice])
	return "\n\n".join(lines)


## Unreal's pin shapes: a pentagon arrow for exec, a ring (filled once connected) with a small nub for data,
## a grid for arrays and dictionaries.
func _draw_port(slot_index: int, pos: Vector2i, left: bool, color: Color) -> void:
	var entry: Array = (_slot_in if left else _slot_out).get(slot_index, [])
	if entry.is_empty():
		return
	var pin: Dictionary = entry[0]
	var wired: bool = entry[1]
	var p := Vector2(pos)
	var t := String(pin.type)
	if t == "exec":
		var pts := PackedVector2Array([p + Vector2(-5.5, -6), p + Vector2(0.5, -6), p + Vector2(6, 0), p + Vector2(0.5, 6), p + Vector2(-5.5, 6)])
		if wired:
			draw_colored_polygon(pts, Color.WHITE)
		else:
			draw_colored_polygon(pts, Color(0, 0, 0, 0.35))
		pts.append(pts[0])
		draw_polyline(pts, Color.WHITE, 1.6, true)
		return
	if kind == "reroute":
		draw_circle(p, 4.5, color, true, -1.0, true)
		return
	if t.begins_with("Array") or t.begins_with("Packed") or t == "Dictionary":
		for gy in range(-1, 2):
			for gx in range(-1, 2):
				if gx == 0 and gy == 0 and not wired:
					continue
				draw_rect(Rect2(p + Vector2(gx * 4 - 1.5, gy * 4 - 1.5), Vector2(3, 3)), color)
		return
	if wired:
		draw_circle(p, 5.0, color, true, -1.0, true)
	else:
		draw_circle(p, 4.4, Color(0, 0, 0, 0.45), true, -1.0, true)
		draw_circle(p, 4.4, color, false, 1.7, true)
	draw_colored_polygon(PackedVector2Array([p + Vector2(6.6, -2.6), p + Vector2(9.4, 0), p + Vector2(6.6, 2.6)]), color)


## Title treatment drawn over the flat header: colour spilling from the left into the dark body, a soft gloss
## along the top edge, and the breakpoint marker on the corner.
func _draw() -> void:
	if not _headless:
		var hb := get_titlebar_hbox()
		var w := size.x
		var h := hb.position.y + hb.size.y + _head_bottom
		var i := _inset
		var r := 7.0
		var outline := PackedVector2Array([Vector2(i, h), Vector2(i, r)])
		for k in range(1, 6):
			var ang := PI + (PI * 0.5) * k / 5.0
			outline.append(Vector2(r, r) + Vector2(cos(ang), sin(ang)) * (r - i))
		for k in range(0, 5):
			var ang := PI * 1.5 + (PI * 0.5) * k / 5.0
			outline.append(Vector2(w - r, r) + Vector2(cos(ang), sin(ang)) * (r - i))
		outline.append(Vector2(w - i, r))
		outline.append(Vector2(w - i, h))
		var spill := PackedColorArray()
		var gloss := PackedColorArray()
		var gloss_pts := PackedVector2Array()
		for pt in outline:
			spill.append(Color(0.035, 0.035, 0.04, 0.78 * pow(clampf(pt.x / maxf(w, 1.0), 0.0, 1.0), 0.75)))
			var gp := Vector2(pt.x, minf(pt.y, h * 0.55))
			gloss_pts.append(gp)
			gloss.append(Color(1, 1, 1, 0.16 * (1.0 - gp.y / (h * 0.55))))
		draw_polygon(outline, spill)
		draw_polygon(gloss_pts, gloss)
	if not _headless and kind in EVENT_KINDS:
		var hb2 := get_titlebar_hbox()
		var cy := hb2.position.y + hb2.size.y * 0.5
		var sq := Rect2(size.x - 19, cy - 4.5, 9, 9)
		draw_rect(sq, Color(0.95, 0.12, 0.1), false, 1.6)
		draw_rect(sq.grow(-2.5), Color(0.95, 0.12, 0.1, 0.85))
	if _breakpoint:
		draw_circle(Vector2(2, 2), 8.0, Color(0.25, 0.02, 0.02), true, -1.0, true)
		draw_circle(Vector2(2, 2), 6.5, Color(0.93, 0.1, 0.08), true, -1.0, true)
		draw_circle(Vector2(0.5, 0.5), 2.2, Color(1, 0.55, 0.5, 0.7), true, -1.0, true)


## Unreal's comment bubble above the node. Drawn by a child of the title row so greying the node leaves it readable.
func _draw_bubble(bubble: Control) -> void:
	var hb := get_titlebar_hbox()
	var origin := -(hb.position + bubble.position)   # node's top-left in the bubble's space
	var font := get_theme_default_font()
	var fs := 12
	var lines := _bubble_text.split("\n")
	var w := 0.0
	for ln in lines:
		w = maxf(w, font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var lh := font.get_height(fs) + 1.0
	var box := Rect2(origin + Vector2(0, -(lines.size() * lh + 22)), Vector2(w + 20, lines.size() * lh + 10))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.33, 0.33, 0.34, 0.88)
	sb.set_corner_radius_all(5)
	bubble.draw_style_box(sb, box)
	bubble.draw_colored_polygon(PackedVector2Array([box.position + Vector2(10, box.size.y - 0.5), box.position + Vector2(22, box.size.y - 0.5), box.position + Vector2(13, box.size.y + 7)]), sb.bg_color)
	for i in lines.size():
		bubble.draw_string(font, box.position + Vector2(10, 5 + font.get_ascent(fs) + i * lh), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))


func _glyph_shape() -> String:
	if kind in EVENT_KINDS:
		return "event"
	if kind in ["call", "bcall", "util", "call_self", "iface_call", "call_parent", "ctor", "tpl", "print", "delay", "retriggerable_delay", "fn_entry", "fn_return", "spawn", "new", "emit", "bind_signal", "unbind_signal", "await_signal", "await_value", "dyn_call", "dyn_set", "message"]:
		return "function"
	if kind in ["branch", "switch"]:
		return "branch"
	if kind in ["sequence", "multigate"]:
		return "sequence"
	if kind in ["for", "for_each", "for_each_dict", "while", "do_n"]:
		return "loop"
	if kind == "cast":
		return "cast"
	if kind in ["gate", "do_once", "flip_flop"]:
		return "gate"
	return ""


func _title_icon() -> Texture2D:
	match kind:
		"event", "custom_event", "input_action", "key_event", "signal_event":
			return W.icon("MemberSignal")
		"call", "bcall", "util", "call_self", "iface_call", "call_parent", "ctor", "tpl", "print", "delay", "retriggerable_delay", "fn_entry", "fn_return", "spawn", "new", "emit", "bind_signal", "unbind_signal", "await_signal", "await_value", "dyn_call", "dyn_set", "message":
			return W.icon("MemberMethod")
		"macro", "macro_in", "macro_out":
			return W.icon("GraphEdit")
		"timeline":
			return W.icon("Animation")
		"for", "for_each", "for_each_dict", "while":
			return W.icon("Loop")
		"branch", "switch", "sequence", "gate", "multigate", "do_once", "do_n", "flip_flop":
			return W.icon("AnimationTrackList")
		"cast":
			return W.icon("ArrowRight")
		"get_node", "self", "autoload":
			return W.icon("Node")
	return null


func _header(d: Dictionary) -> void:
	var hb := get_titlebar_hbox()
	if d.compact and kind != "op" and kind != "math" and d.title == "":
		return
	var bold := EditorInterface.get_editor_theme().get_font("bold", "EditorFonts") if EditorInterface.get_editor_theme() else null
	for c in hb.get_children():
		if c is Label:
			if bold:
				c.add_theme_font_override("font", bold)
			c.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))
			c.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
			c.add_theme_constant_override("shadow_offset_y", 1)
	var shape := _glyph_shape()
	if shape != "" and not _headless:
		var gl := Glyph.new(shape)
		hb.add_child(gl)
		hb.move_child(gl, 0)
	var ic := _title_icon() if shape == "" else null
	if ic and not _headless:
		var tr := TextureRect.new()
		tr.texture = ic
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.modulate = Color(1, 1, 1, 0.92)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(tr)
		hb.move_child(tr, 0)
	if d.sub != "" or d.latent:
		for c in hb.get_children():
			if c is Label:
				c.visible = false
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", -3)
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tl := Label.new()
		tl.text = d.title
		tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if bold:
			tl.add_theme_font_override("font", bold)
		vb.add_child(tl)
		if d.sub != "":
			var sl := Label.new()
			sl.text = d.sub
			sl.add_theme_font_size_override("font_size", 10)
			sl.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			sl.clip_text = true
			sl.custom_minimum_size.x = 120
			vb.add_child(sl)
		hb.add_child(vb)
		if d.latent:
			var clock := TextureRect.new()
			clock.texture = W.icon("Timer")
			clock.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			clock.tooltip_text = "Latent: execution continues later"
			hb.add_child(clock)


func _style(d: Dictionary, has_error: bool) -> void:
	var c: Color = d.color
	var edge := Color(0, 0, 0, 0.85) if not has_error else Color(0.9, 0.15, 0.1)
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.055, 0.055, 0.06, 0.9)
	body.set_corner_radius_all(8)
	body.corner_radius_top_left = 0
	body.corner_radius_top_right = 0
	body.set_border_width_all(1)
	body.border_width_top = 0
	body.border_color = edge
	body.content_margin_left = PIN_X + 14
	body.content_margin_right = PIN_X + 14
	body.content_margin_top = 5
	body.content_margin_bottom = 7
	body.shadow_color = Color(0, 0, 0, 0.3)
	body.shadow_size = 9
	body.shadow_offset = Vector2(0, 3)
	body.anti_aliasing_size = 1.0
	var head := StyleBoxFlat.new()
	head.bg_color = Color(c.r, c.g, c.b, 0.97)
	head.set_corner_radius_all(8)
	head.corner_radius_bottom_left = 0
	head.corner_radius_bottom_right = 0
	head.set_border_width_all(1)
	head.border_width_bottom = 0
	head.border_color = edge
	head.content_margin_left = 10
	head.content_margin_right = 26 if kind in ["event", "custom_event", "input_action", "key_event", "signal_event"] else 12
	head.content_margin_top = 5
	head.content_margin_bottom = 5
	head.shadow_color = Color(0, 0, 0, 0.3)
	head.shadow_size = 9
	head.shadow_offset = Vector2(0, 3)
	_head_bottom = 5.0
	_headless = d.compact and (d.title == "" or kind == "op" or kind == "math")
	if _headless:
		head = StyleBoxFlat.new()
		head.bg_color = Color(0, 0, 0, 0)
		head.content_margin_top = 0
		head.content_margin_bottom = 0
		body.set_corner_radius_all(15)
		body.set_border_width_all(1)
		# Unreal's compact nodes: a dark pill carrying a tint of the node colour.
		body.bg_color = Color(0.05 + c.r * 0.28, 0.05 + c.g * 0.28, 0.05 + c.b * 0.28, 0.93)
		body.border_color = Color(c.r * 0.75, c.g * 0.75, c.b * 0.75, 0.9) if not has_error else edge
		if kind == "op" or kind == "math":
			body.bg_color = Color(0.1, 0.1, 0.105, 0.94)
			body.border_color = Color(0.3, 0.3, 0.31, 0.95) if not has_error else edge
			body.set_corner_radius_all(10)
		body.content_margin_top = 3
		body.content_margin_bottom = 3
		if kind == "reroute":
			body.content_margin_left = 20
			body.content_margin_right = 20
			body.bg_color = Color(0, 0, 0, 0.0)
			body.border_color = Color(0, 0, 0, 0.0)
			body.shadow_size = 0
	var body_sel := body.duplicate() as StyleBoxFlat
	var head_sel := head.duplicate() as StyleBoxFlat
	var sel_col := Color(1.0, 0.72, 0.1)
	body_sel.border_color = sel_col
	body_sel.set_border_width_all(2)
	if not _headless:
		body_sel.border_width_top = 0
		head_sel.border_color = sel_col
		head_sel.set_border_width_all(2)
		head_sel.border_width_bottom = 0
	add_theme_stylebox_override("panel", body)
	add_theme_stylebox_override("panel_selected", body_sel)
	add_theme_stylebox_override("panel_focus", StyleBoxEmpty.new())
	add_theme_stylebox_override("titlebar", head)
	add_theme_stylebox_override("titlebar_selected", head_sel)
	add_theme_stylebox_override("slot", StyleBoxEmpty.new())
	add_theme_stylebox_override("slot_selected", StyleBoxEmpty.new())
	add_theme_constant_override("separation", 0)
	add_theme_constant_override("port_h_offset", 12 if kind == "reroute" else PIN_X)
	if _headless:
		for ch in get_titlebar_hbox().get_children():
			ch.visible = false
		get_titlebar_hbox().custom_minimum_size.y = 0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		_view.node_double_clicked(node_id)
		accept_event()
