extends RefCounted
## Answers the Blueprint editor's questions about a game that is stopped at a breakpoint: which functions are
## on the call stack, and what the values on a node's pins are.
##
## Nothing loads this file in a game that runs on its own. The editor asks the paused game to load it (through
## the debugger's own Evaluate request) the first time it needs an answer, so it costs nothing until then and
## nothing at all outside a debugging session.

static var _instance: Object = null   # `self` of the frame the editor last asked about (see at())
static var _has_instance := false


## Called by the editor through the debugger's Evaluate request, which runs with the paused function's `self`.
## That is the only way to learn which object a stack frame belongs to.
static func at(instance: Object) -> String:
	_instance = instance
	_has_instance = true
	if not EngineDebugger.has_capture("blueprint"):
		EngineDebugger.register_message_capture("blueprint", _on_message)
	EngineDebugger.send_message("blueprint:attached", [])
	return "(used by the Blueprint editor to read pin values)"


static func _on_message(message: String, data: Array) -> bool:
	match message.get_slice(":", message.get_slice_count(":") - 1):
		"frames":
			# [request id] -> [request id, [[file, line, function, number of member variables], ...]]
			var out := []
			var trace := _trace(true)
			if trace != null:
				for i in range(_skip(trace), trace.get_frame_count()):
					out.append([trace.get_frame_file(i), trace.get_frame_line(i), trace.get_frame_function(i), trace.get_member_variable_count(i)])
			EngineDebugger.send_message("blueprint:frames", [data[0] if data.size() > 0 else 0, out])
			return true
		"eval":
			# [request id, frame, expressions, frame the stored `self` belongs to (-1: none)]
			# -> [request id, frame, {local: text}, {member: text}, [text or null for each expression]]
			var frame := int(data[1])
			var exprs: Array = data[2]
			var base: Object = null
			if _has_instance and int(data[3]) == frame and is_instance_valid(_instance):
				base = _instance
			_instance = null
			_has_instance = false
			var locals := {}
			var members := {}
			var names := PackedStringArray()
			var values := []
			var trace := _trace(true)
			if trace != null:
				var at_frame := frame + _skip(trace)
				if at_frame < trace.get_frame_count():
					for i in trace.get_local_variable_count(at_frame):
						var n := trace.get_local_variable_name(at_frame, i)
						var v: Variant = trace.get_local_variable_value(at_frame, i)
						if not locals.has(n):
							names.append(n)
							values.append(v)
						locals[n] = _text(v)
					for i in trace.get_member_variable_count(at_frame):
						var n := trace.get_member_variable_name(at_frame, i)
						if n.begins_with("@"):
							continue
						var v: Variant = trace.get_member_variable_value(at_frame, i)
						members[n] = _text(v)
						if not locals.has(n):
							names.append(n)
							values.append(v)
			var results := []
			for e in exprs:
				results.append(_evaluate(String(e), names, values, base))
			EngineDebugger.send_message("blueprint:values", [data[0], frame, locals, members, results])
			return true
	return false


## The value of one expression in the paused frame, as text, or null when it cannot be worked out without
## running code that might change something (only calls that cannot change anything are made).
static func _evaluate(text: String, names: PackedStringArray, values: Array, base: Object) -> Variant:
	var ex := Expression.new()
	if ex.parse(text, names) != OK:
		return null
	var v: Variant = ex.execute(values, base, false, true)
	if ex.has_execute_failed():
		return null
	return _text(v)


static func _text(v: Variant) -> String:
	var s := ""
	if typeof(v) == TYPE_OBJECT and not is_instance_valid(v):
		s = "null" if v == null else "<freed object>"
	elif typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME:
		s = "\"%s\"" % String(v).c_escape()
	else:
		s = str(v)
	return s if s.length() <= 200 else s.left(197) + "..."


static func _trace(with_variables: bool) -> ScriptBacktrace:
	for t in Engine.capture_script_backtraces(with_variables):
		if t.get_language_name() == "GDScript":
			return t
	return null


## How many frames at the top of the stack are this file's own (the request is being answered from inside it).
static func _skip(trace: ScriptBacktrace) -> int:
	var path: String = "res://addons/blueprints/runtime/bp_debug_probe.gd"
	var n := 0
	while n < trace.get_frame_count() and trace.get_frame_file(n) == path:
		n += 1
	return n
