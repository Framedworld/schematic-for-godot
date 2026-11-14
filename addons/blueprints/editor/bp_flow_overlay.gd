@tool
extends Control
## Dots that run along exec wires the game has just followed (Unreal's animated execution flow). Lives inside
## GraphEdit's own wire layer, so it is drawn with the wires and under the nodes, and only redraws while
## something is moving.

const LIFE := 1.1          # seconds a wire stays lit after it was last followed
const SPACING := 46.0      # pixels between dots
const SPEED := 150.0       # pixels a dot travels per second
const COLOR := Color(1.0, 0.72, 0.2)

var view: GraphEdit
var _active: Dictionary = {}   # "node:port>node:port" -> [from node name, from port, to node name, to port, seconds left]
var _time := 0.0
## Set to 0 or more to place the dots for that moment instead of the running clock (used to record evenly spaced frames).
var time_override := -1.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


## Lights the wire between two ports for a moment.
func pulse(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	_active["%s:%d>%s:%d" % [from_node, from_port, to_node, to_port]] = [from_node, from_port, to_node, to_port, LIFE]
	set_process(true)


func clear() -> void:
	_active.clear()
	queue_redraw()


func count() -> int:
	return _active.size()


func _process(delta: float) -> void:
	_time += delta
	for key in _active.keys():
		_active[key][4] = float(_active[key][4]) - delta
		if float(_active[key][4]) <= 0.0:
			_active.erase(key)
	if _active.is_empty():
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if view == null:
		return
	var z := view.zoom
	for key in _active:
		var e: Array = _active[key]
		var a := view.get_node_or_null(NodePath(String(e[0]))) as GraphNode
		var b := view.get_node_or_null(NodePath(String(e[2]))) as GraphNode
		if a == null or b == null or int(e[1]) >= a.get_output_port_count() or int(e[3]) >= b.get_input_port_count():
			continue
		# the same points GraphEdit gives the wire itself (this layer shares the wires' coordinates)
		var from := (a.position_offset + a.get_output_port_position(int(e[1]))) * z
		var to := (b.position_offset + b.get_input_port_position(int(e[3]))) * z
		var pts := view.get_connection_line(from, to)
		if pts.size() < 2:
			continue
		var fade := clampf(float(e[4]) / 0.4, 0.0, 1.0)
		var glow := COLOR
		glow.a = 0.55 * fade
		draw_polyline(pts, glow, maxf(2.0, 5.0 * z), true)
		var length := 0.0
		for i in range(1, pts.size()):
			length += pts[i - 1].distance_to(pts[i])
		var at := fmod((time_override if time_override >= 0.0 else _time) * SPEED, SPACING)
		while at < length:
			var dot := COLOR.lightened(0.45)
			dot.a = fade
			draw_circle(_point_at(pts, at), maxf(2.0, 4.0 * z), dot)
			at += SPACING


func _point_at(pts: PackedVector2Array, distance: float) -> Vector2:
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		if distance <= seg and seg > 0.0:
			return pts[i - 1].lerp(pts[i], distance / seg)
		distance -= seg
	return pts[pts.size() - 1]
