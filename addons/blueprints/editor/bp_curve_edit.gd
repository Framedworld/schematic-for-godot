@tool
extends Control
## Timeline float-track editor in the style of Unreal's curve view: drag keys, double-click to add one,
## right-click (or Delete) to remove. Calls `on_change` with the new key list when an edit is finished.

const T := preload("res://addons/blueprints/core/bp_types.gd")

const PAD := Vector2(34, 14)   # room for the axis labels
const HIT := 9.0

var keys: Array = []           # [[time, value]] as floats, kept sorted by time
var length := 1.0
var smooth := false
var on_change: Callable

var _lo := 0.0
var _hi := 1.0
var _drag := -1
var _hover := -1
var _selected := -1
var _moved := false


func setup(p_keys: Array, p_length: float, p_smooth: bool, p_on_change: Callable) -> void:
	keys = []
	for k in p_keys:
		keys.append([float(k[0]), float(T.parse_literal(String(k[1]), 0.0))])
	keys.sort_custom(func(a, b): return a[0] < b[0])
	length = maxf(p_length, 0.01)
	smooth = p_smooth
	on_change = p_on_change
	custom_minimum_size = Vector2(0, 150)
	focus_mode = Control.FOCUS_CLICK
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	tooltip_text = "Drag a key to move it. Double-click to add a key. Right-click a key (or press Delete) to remove it."
	_fit_range()


func _fit_range() -> void:
	var lo := INF
	var hi := -INF
	for k in keys:
		lo = minf(lo, k[1])
		hi = maxf(hi, k[1])
	if keys.is_empty():
		lo = 0.0
		hi = 1.0
	var pad := maxf((hi - lo) * 0.25, 0.25)
	_lo = lo - pad
	_hi = hi + pad


func _area() -> Rect2:
	return Rect2(PAD, size - PAD - Vector2(8, 8))


func to_point(time: float, value: float) -> Vector2:
	var a := _area()
	return Vector2(a.position.x + clampf(time / length, 0.0, 1.0) * a.size.x, a.end.y - (value - _lo) / (_hi - _lo) * a.size.y)


func from_point(pt: Vector2) -> Array:
	var a := _area()
	var time := clampf((pt.x - a.position.x) / a.size.x, 0.0, 1.0) * length
	var value := _lo + clampf((a.end.y - pt.y) / a.size.y, 0.0, 1.0) * (_hi - _lo)
	return [snappedf(time, 0.01), snappedf(value, 0.01)]


func key_at(pt: Vector2) -> int:
	var best := -1
	var best_d := HIT
	for i in keys.size():
		var d := to_point(keys[i][0], keys[i][1]).distance_to(pt)
		if d <= best_d:
			best_d = d
			best = i
	return best


func sample(time: float) -> float:
	if keys.is_empty():
		return 0.0
	if time <= keys[0][0]:
		return keys[0][1]
	for i in range(1, keys.size()):
		if time <= keys[i][0]:
			var span: float = keys[i][0] - keys[i - 1][0]
			var w: float = 0.0 if span <= 0.0 else (time - keys[i - 1][0]) / span
			if smooth:
				w = w * w * (3.0 - 2.0 * w)
			return lerpf(keys[i - 1][1], keys[i][1], w)
	return keys[-1][1]


func _commit() -> void:
	var out := []
	for k in keys:
		out.append([k[0], T.to_literal(float(k[1]))])
	if on_change.is_valid():
		on_change.call(out)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var hit := key_at(event.position)
			if event.double_click and hit == -1:
				var nk := from_point(event.position)
				keys.append(nk)
				keys.sort_custom(func(a, b): return a[0] < b[0])
				_selected = keys.find(nk)
				_fit_range()
				_commit()
			else:
				_drag = hit
				_selected = hit
				_moved = false
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if _drag != -1 and _moved:
				_fit_range()
				_commit()
			_drag = -1
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var hit := key_at(event.position)
			if hit != -1:
				remove_key(hit)
			accept_event()
	elif event is InputEventMouseMotion:
		if _drag != -1:
			var moved := from_point(event.position)
			# a key cannot pass its neighbours in time
			var t_min: float = keys[_drag - 1][0] + 0.01 if _drag > 0 else 0.0
			var t_max: float = keys[_drag + 1][0] - 0.01 if _drag < keys.size() - 1 else length
			keys[_drag] = [clampf(moved[0], t_min, maxf(t_min, t_max)), moved[1]]
			_moved = true
			queue_redraw()
		else:
			var h := key_at(event.position)
			if h != _hover:
				_hover = h
				queue_redraw()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_DELETE and _selected != -1:
		remove_key(_selected)
		accept_event()


func remove_key(index: int) -> void:
	if index < 0 or index >= keys.size() or keys.size() <= 1:
		return
	keys.remove_at(index)
	_selected = -1
	_hover = -1
	_fit_range()
	_commit()
	queue_redraw()


func _draw() -> void:
	var a := _area()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.06, 0.065))
	var font := get_theme_default_font()
	# grid: five value lines, time lines every tenth of the length
	for i in 5:
		var v := lerpf(_lo, _hi, i / 4.0)
		var y := to_point(0.0, v).y
		draw_line(Vector2(a.position.x, y), Vector2(a.end.x, y), Color(1, 1, 1, 0.07))
		draw_string(font, Vector2(2, y + 4), String.num(v, 2), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.45))
	for i in 11:
		var x := a.position.x + a.size.x * i / 10.0
		draw_line(Vector2(x, a.position.y), Vector2(x, a.end.y), Color(1, 1, 1, 0.12 if i % 5 == 0 else 0.05))
		if i % 5 == 0:
			draw_string(font, Vector2(x - 8, size.y - 1), String.num(length * i / 10.0, 2), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.45))
	if keys.is_empty():
		return
	var pts := PackedVector2Array()
	var steps := 64 if smooth else 0
	if steps > 0:
		for i in steps + 1:
			var t := length * i / steps
			pts.append(to_point(t, sample(t)))
	else:
		pts.append(to_point(0.0, keys[0][1]))
		for k in keys:
			pts.append(to_point(k[0], k[1]))
		pts.append(to_point(length, keys[-1][1]))
	if pts.size() >= 2:
		draw_polyline(pts, Color(0.62, 1.0, 0.27), 2.0, true)
	for i in keys.size():
		var c := to_point(keys[i][0], keys[i][1])
		var r := 6.0 if (i == _hover or i == _drag) else 5.0
		var col := Color(1.0, 0.72, 0.1) if i == _selected else Color.WHITE
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]), col)
		if i == _drag or i == _selected:
			draw_string(font, c + Vector2(9, -7), "%s, %s" % [String.num(keys[i][0], 2), String.num(keys[i][1], 2)], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.9))
