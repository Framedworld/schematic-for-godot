@tool
extends HSplitContainer
## The Schematic debugger: call stack, watches, values on pins while the game is paused, and stepping one
## node at a time. Everything is asked of the paused game through Godot's own debugger connection (see
## runtime/sc_debug_probe.gd), so it needs no engine change and adds nothing to the generated scripts.

const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const PROBE := "res://addons/schematic/runtime/sc_debug_probe.gd"
const MAX_AUTO_STEPS := 400   # generated lines one step may pass over before it gives up and stops
const MAX_EXPRESSIONS := 800

var editor: Node
var plugin_debugger: EditorDebuggerPlugin

var paused := false
var session_id := -1
var pause_id := 0
var frames: Array = []        # [[file, line, function, member count], ...], innermost first
var frame := 0
var stepping: Dictionary = {} # {cmd, path, g, n, line, depth, count} while a node step is under way
var steps_sent := 0           # debugger steps sent by the last node step (for the tests)
var watches: Array = []       # [{label, expr}] or [{label, path, key, pin}]

var _attached: Dictionary = {}    # session id -> true once the game has loaded the probe
var _goto_seen := -1              # pause whose first "go to line" has been handled
var _swallow := -1                # pause the editor should not show (a step is passing through it)
var _queued: Array = []           # [pause, command, line]: the step to send once Godot has asked its own questions
var _self_sent: Array = [-1, -1]  # [pause, frame] whose `self` the game is holding for the next values request
var _req := 0
var _pending: Dictionary = {}     # the values request that is out: {id, frame, items}
var _values: Dictionary = {}      # path -> graph id -> node id -> {pin: text} for the frame being shown
var _locals: Dictionary = {}
var _members: Dictionary = {}
var _watch_values: Array = []
var _files: Dictionary = {}       # path -> PackedStringArray of the script's lines (as the game runs it)

var _stack: Tree
var _vars: Tree
var _add: LineEdit
var _hint: Label


func build_ui() -> void:
	custom_minimum_size.y = 170
	var v: Variant = EditorInterface.get_editor_settings().get_project_metadata("schematics", "watches", [])
	if typeof(v) == TYPE_ARRAY:
		watches = v.duplicate(true)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 260
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(left)
	left.add_child(editor._header("Call Stack"))
	_stack = Tree.new()
	_stack.hide_root = true
	_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.item_selected.connect(_on_stack_selected)
	_stack.item_activated.connect(_on_stack_activated)
	_stack.tooltip_text = "The functions that are running, innermost first. Click one to see its node and values; double-click a script line to open it."
	left.add_child(_stack)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.6
	add_child(right)
	var top := HBoxContainer.new()
	right.add_child(top)
	var title: Label = editor._header("Watches")
	top.add_child(title)
	_add = LineEdit.new()
	_add.placeholder_text = "Watch a variable or expression, then Enter"
	_add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add.text_submitted.connect(func(t: String):
		if t.strip_edges() != "":
			add_watch({"label": t.strip_edges(), "expr": t.strip_edges()})
		_add.text = "")
	top.add_child(_add)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	top.add_child(_hint)
	_vars = Tree.new()
	_vars.hide_root = true
	_vars.columns = 2
	_vars.set_column_expand(0, true)
	_vars.set_column_expand(1, true)
	_vars.set_column_expand_ratio(1, 2)
	_vars.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vars.button_clicked.connect(func(item: TreeItem, _c: int, _id: int, _mb: int):
		var i := int(item.get_metadata(0))
		if i >= 0 and i < watches.size():
			watches.remove_at(i)
			_save_watches()
			_request_values())
	right.add_child(_vars)
	_fill()


# ---------------------------------------------------------------- session events

func session_started(id: int) -> void:
	_attached.erase(id)
	_files.clear()
	_reset()


func session_stopped(id: int) -> void:
	_attached.erase(id)
	if id == session_id:
		_reset()


func _reset() -> void:
	paused = false
	stepping = {}
	frames = []
	frame = 0
	_pending = {}
	_clear_values()
	_fill()
	editor.debug_panel_changed()


func breaked(id: int, can_debug: bool) -> void:
	session_id = id
	pause_id += 1
	paused = true
	frames = []
	frame = 0
	_pending = {}
	if not can_debug:
		stepping = {}
	if _attached.has(id):
		_send("schematic:frames", [pause_id])
	_fill()
	editor.debug_panel_changed()


func resumed(id: int) -> void:
	if id != session_id:
		return
	paused = false
	_pending = {}
	if stepping.is_empty():
		_after_resume()
	else:
		# a step usually stops again at once: keep what is on screen until then, so it does not flicker
		var mine := pause_id
		get_tree().create_timer(0.3).timeout.connect(func():
			if not paused and pause_id == mine:
				stepping = {}
				_after_resume())


func _after_resume() -> void:
	frames = []
	_clear_values()
	_fill()
	editor.debug_resume()
	editor.debug_panel_changed()


## The debugger wants a script line shown (the top frame when the game stops, or a frame or error the user
## clicked in Godot's Debugger panel). False when the editor should leave the screen as it is.
func goto(path: String, line: int) -> bool:
	if not paused:
		return true
	if _swallow == pause_id:
		_send_queued(pause_id)
		return false
	var first := _goto_seen != pause_id
	_goto_seen = pause_id
	if not first:
		# another frame picked in Godot's own stack list: show the same one here
		for i in frames.size():
			if String(frames[i][0]) == path and int(frames[i][1]) == line and i != frame:
				frame = i
				_fill()
				_request_values()
				break
		return true
	if _attached.has(session_id):
		return true
	# The probe is not in the game yet, so all that is known is this line.
	if not stepping.is_empty():
		var cmd := _after_step(path, line, -1)
		if cmd != "":
			_step_on(cmd, line)
			return false
		stepping = {}
	frames = [[path, line, "", 0]]
	if _line_has_self(path, line):
		_self_sent = [pause_id, 0]
		_send("evaluate", ["ResourceLoader.load(\"%s\").at(self)" % PROBE, 0])
	_fill()
	return true


func attached(id: int) -> void:
	if _attached.has(id):
		return
	_attached[id] = true
	if paused and id == session_id:
		_send("schematic:frames", [pause_id])


func got_frames(id: int, data: Array) -> void:
	if id != session_id or not paused or data.size() < 2 or int(data[0]) != pause_id:
		return
	frames = data[1]
	frame = 0
	if frames.is_empty():
		stepping = {}
		_fill()
		return
	var stepped := stepping.duplicate()
	if not stepping.is_empty():
		var cmd := _after_step(String(frames[0][0]), int(frames[0][1]), frames.size())
		if cmd != "":
			# Godot's Debugger panel asks the game for this stop's stack and variables as well. The step goes
			# out after those requests (they are sent when the panel shows the line, which is what calls goto),
			# or the answers would arrive during the next stop and be reported as errors.
			_swallow = pause_id
			_queued = [pause_id, cmd, int(frames[0][1])]
			var mine := pause_id
			get_tree().create_timer(0.25).timeout.connect(func(): _send_queued(mine))
			return
		stepping = {}
	_fill()
	_request_values()
	editor.debug_panel_changed()
	if not stepped.is_empty():
		# the step ended on another node of the same graph: show the wire it followed, once the graph is drawn
		var now := _where(String(frames[0][0]), int(frames[0][1]))
		if now.size() == 2 and String(frames[0][0]) == String(stepped.path) and int(now[0]) == int(stepped.g):
			editor.debug_step_flow.call_deferred(String(stepped.path), int(stepped.g), int(stepped.n), int(now[1]))


func got_values(id: int, data: Array) -> void:
	if id != session_id or _pending.is_empty() or data.size() < 5 or int(data[0]) != int(_pending.id):
		return
	var items: Array = _pending.items
	_pending = {}
	_clear_values()
	_locals = data[2]
	_members = data[3]
	_watch_values.resize(watches.size())
	_watch_values.fill(null)
	var res: Array = data[4]
	for i in mini(items.size(), res.size()):
		var it: Array = items[i]
		if res[i] == null:
			continue
		if it[0] == "pin":
			var by_graph: Dictionary = _values.get_or_add(String(it[1]), {})
			var by_node: Dictionary = by_graph.get_or_add(int(it[2]), {})
			var pins: Dictionary = by_node.get_or_add(int(it[3]), {})
			# a pin has little room: floats are shown to four decimals there (watches keep every digit)
			var text := String(res[i])
			if text.is_valid_float() and text.contains(".") and text.get_slice(".", 1).length() > 4:
				text = String.num(text.to_float(), 4)
			pins[String(it[4])] = text
		elif it[0] == "watch" and int(it[1]) < _watch_values.size():
			_watch_values[int(it[1])] = String(res[i])
	_fill()
	editor.debug_panel_changed()


# ---------------------------------------------------------------- stepping

## "step" (into), "next" (over) or "out", counted in nodes instead of generated lines.
func step(cmd: String) -> void:
	if not paused or frames.is_empty():
		return
	var top: Array = frames[0]
	var where := _where(String(top[0]), int(top[1]))
	stepping = {"cmd": cmd, "path": String(top[0]), "g": int(where[0]) if where.size() == 2 else -1,
		"n": int(where[1]) if where.size() == 2 else -1, "line": int(top[1]),
		"depth": frames.size() if _attached.has(session_id) else -1, "count": 0}
	steps_sent = 0
	_step_on(cmd, int(top[1]))


func _step_on(cmd: String, line: int) -> void:
	stepping["count"] = int(stepping.get("count", 0)) + 1
	stepping["line"] = line
	steps_sent += 1
	_send.call_deferred(cmd, [])


func _send_queued(for_pause: int) -> void:
	if _queued.size() == 3 and int(_queued[0]) == for_pause:
		var q := _queued
		_queued = []
		if paused and pause_id == for_pause and not stepping.is_empty():
			_step_on(String(q[1]), int(q[2]))


## Decides what a step that has just stopped at (path, line) does next: "" to stay here, or the debugger
## command that carries it on, because the line is still part of the node the step started from or belongs to
## no node at all. `depth` is the number of stack frames, -1 when it is not known.
func _after_step(path: String, line: int, depth: int) -> String:
	if int(stepping.count) >= MAX_AUTO_STEPS:
		return ""
	var info: Dictionary = editor.debug_info(path)
	if info.is_empty():
		return ""   # a script written by hand: show it
	var start_depth := int(stepping.depth)
	var known := depth != -1 and start_depth != -1
	var where: Array = info.map.get(line, [])
	var glue := where.size() != 2 or int(where[1]) == 0
	var same: bool = not glue and path == String(stepping.path) and int(where[0]) == int(stepping.g) and int(where[1]) == int(stepping.n) \
		and line > int(stepping.line) and (not known or depth == start_depth)
	match String(stepping.cmd):
		"next":
			if known and depth > start_depth:
				return ""   # a breakpoint inside something this step was passing over
			if glue or same:
				return "next"
		"step":
			if glue:
				return "next"
			if same:
				return "step"
		"out":
			if glue:
				return "next"
	return ""


# ---------------------------------------------------------------- values

func _clear_values() -> void:
	_values = {}
	_locals = {}
	_members = {}
	_watch_values = []


## Values for the pins of one graph, for the frame being shown: {node id: {pin: text}}.
func pin_values(path: String, gid: int) -> Dictionary:
	return _values.get(path, {}).get(gid, {})


func add_watch(w: Dictionary) -> void:
	if watches.has(w):
		return
	watches.append(w)
	_save_watches()
	_fill()
	_request_values()


func toggle_watch(w: Dictionary) -> void:
	if watches.has(w):
		watches.erase(w)
		_save_watches()
		_request_values()
	else:
		add_watch(w)


func _save_watches() -> void:
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "watches", watches)
	_fill()


## Asks the game for the values of everything on screen for the selected frame.
func _request_values() -> void:
	if not paused or not _attached.has(session_id) or frame >= frames.size():
		return
	var f: Array = frames[frame]
	var path := String(f[0])
	var line := int(f[1])
	var info: Dictionary = editor.debug_info(path)
	var fn_pins: Dictionary = {}
	if not info.is_empty():
		for b in info.blocks:
			if line >= int(b[0]) and line <= int(b[1]):
				fn_pins = info.pins.get(String(b[2]), {})
				break
	var items := []
	var exprs := []
	for key in fn_pins:
		var parts := String(key).split(":")
		for pin in fn_pins[key]:
			if exprs.size() >= MAX_EXPRESSIONS:
				break
			items.append(["pin", path, int(parts[0]), int(parts[1]), String(pin)])
			exprs.append(String(fn_pins[key][pin]))
	for i in watches.size():
		var w: Dictionary = watches[i]
		var e := String(w.get("expr", ""))
		if e == "" and String(w.get("path", "")) == path:
			e = String(fn_pins.get(String(w.get("key", "")), {}).get(String(w.get("pin", "")), ""))
		if e != "":
			items.append(["watch", i])
			exprs.append(e)
	var held := _self_sent == [pause_id, frame]
	var with_self := held or (not exprs.is_empty() and _frame_has_self(f))
	if with_self and not held:
		_send("evaluate", ["ResourceLoader.load(\"%s\").at(self)" % PROBE, frame])
	_self_sent = [-1, -1]
	_req += 1
	_pending = {"id": _req, "frame": frame, "items": items}
	_send("schematic:eval", [_req, frame, exprs, frame if with_self else -1])


## True when the function running in this frame certainly has a `self`. Godot's Evaluate request lets the
## game run on if it is sent for a frame that has none, so it is only sent when this says yes.
func _frame_has_self(f: Array) -> bool:
	if int(f[3]) > 0:
		return true   # the frame listed member variables, which only an object has
	if String(f[2]).contains("lambda"):
		return false
	return _line_has_self(String(f[0]), int(f[1]))


## The same question answered from the script's text: the line is in a function of the script's own class
## that is not static, and no lambda starts between the function's first line and this one.
func _line_has_self(path: String, line: int) -> bool:
	if not _files.has(path):
		_files[path] = FileAccess.get_file_as_string(path).split("\n") if FileAccess.file_exists(path) else PackedStringArray()
	var lines: PackedStringArray = _files[path]
	if line < 1 or line > lines.size():
		return false
	for i in range(line - 1, -1, -1):
		var text := lines[i]
		var bare := text.strip_edges()
		if bare.begins_with("func ") or bare.begins_with("static func "):
			return not bare.begins_with("static ") and not (text.begins_with("\t") or text.begins_with(" "))
		if bare.begins_with("class ") and not (text.begins_with("\t") or text.begins_with(" ")):
			return false
		if bare.contains("func(") or bare.contains("func ("):
			return false   # inside or after a lambda: it may have been made without a `self`
	return false


func _where(path: String, line: int) -> Array:
	var info: Dictionary = editor.debug_info(path)
	return info.map.get(line, []) if not info.is_empty() else []


func _send(message: String, data: Array) -> void:
	if plugin_debugger == null:
		return
	var s: EditorDebuggerSession = plugin_debugger.get_session(session_id)
	if s == null or not s.is_active():
		return
	# while the game runs, only the plugin's own messages mean anything to it
	if not message.begins_with("schematic:") and not s.is_breaked():
		return
	s.send_message(message, data)


# ---------------------------------------------------------------- lists

func _fill() -> void:
	if _stack == null:
		return
	_stack.clear()
	var root := _stack.create_item()
	for i in frames.size():
		var f: Array = frames[i]
		var path := String(f[0])
		var it := _stack.create_item(root)
		var where := _where(path, int(f[1]))
		var title := ""
		if where.size() == 2 and int(where[1]) != 0:
			title = editor.debug_node_title(path, int(where[0]), int(where[1]))
		var fn := String(f[2])
		if not editor.debug_info(path).is_empty():
			it.set_icon(0, W.icon("GraphEdit"))
			it.set_text(0, "%s  %s%s" % [path.get_file().get_basename(), fn, ("  >  " + title) if title != "" else ""])
		else:
			it.set_icon(0, W.icon("GDScript"))
			it.set_text(0, "%s  %s  (line %d)" % [path.get_file(), fn, int(f[1])])
		it.set_tooltip_text(0, "%s:%d" % [path, int(f[1])])
		it.set_metadata(0, i)
		if i == frame:
			it.select(0)
	_vars.clear()
	var vroot := _vars.create_item()
	if not watches.is_empty():
		var group := _group(vroot, "Watches")
		for i in watches.size():
			var it := _vars.create_item(group)
			it.set_text(0, String(watches[i].get("label", "")))
			it.set_metadata(0, i)
			var val: Variant = _watch_values[i] if i < _watch_values.size() else null
			it.set_text(1, String(val) if val != null else ("" if not paused else "(not available here)"))
			it.set_tooltip_text(1, it.get_text(1))
			if val == null:
				it.set_custom_color(1, Color(1, 1, 1, 0.4))
			it.add_button(0, W.icon("Remove"), 0, false, "Stop watching this value")
	_rows(vroot, "Locals", _locals)
	_rows(vroot, "Variables", _members)
	if _hint:
		if not paused:
			_hint.text = "Values appear when the game stops at a breakpoint."
		elif not _attached.has(session_id):
			_hint.text = "Waiting for a stop inside a function that has a self."
		else:
			_hint.text = ""


func _group(root: TreeItem, text: String) -> TreeItem:
	var g := _vars.create_item(root)
	g.set_text(0, text)
	g.set_selectable(0, false)
	g.set_selectable(1, false)
	g.set_custom_color(0, Color(1, 1, 1, 0.55))
	g.set_metadata(0, -1)
	return g


func _rows(root: TreeItem, text: String, values: Dictionary) -> void:
	if values.is_empty():
		return
	var g := _group(root, text)
	var names := values.keys()
	names.sort()
	for n in names:
		var it := _vars.create_item(g)
		it.set_text(0, String(n))
		it.set_text(1, String(values[n]))
		it.set_tooltip_text(1, String(values[n]))
		it.set_metadata(0, -1)


func _on_stack_selected() -> void:
	var it := _stack.get_selected()
	if it == null:
		return
	var i := int(it.get_metadata(0))
	if i == frame or i >= frames.size():
		return
	frame = i
	_clear_values()
	editor.debug_show(String(frames[i][0]), int(frames[i][1]))
	_request_values()


func _on_stack_activated() -> void:
	var it := _stack.get_selected()
	if it == null:
		return
	var f: Array = frames[int(it.get_metadata(0))]
	if editor.debug_info(String(f[0])).is_empty() and ResourceLoader.exists(String(f[0])):
		EditorInterface.edit_script(load(String(f[0])), int(f[1]))
