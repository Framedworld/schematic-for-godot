@tool
extends EditorDebuggerPlugin
## Bridges Godot's script debugger to the graph: breakpoints, stack frames and errors land on nodes.

var editor: Node


func _has_capture(capture: String) -> bool:
	return capture == "blueprint"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if editor == null:
		return false
	match message:
		"blueprint:exec":
			if data.size() >= 2:
				editor.debug_flow(String(data[0]), data[1], data[2] if data.size() > 2 else {}, data[3] if data.size() > 3 else [])
			return true
		"blueprint:attached":
			editor.debug_panel.attached(_session_id)
			return true
		"blueprint:frames":
			editor.debug_panel.got_frames(_session_id, data)
			return true
		"blueprint:values":
			editor.debug_panel.got_values(_session_id, data)
			return true
	return false


func _setup_session(session_id: int) -> void:
	var s := get_session(session_id)
	if s == null:
		return
	s.started.connect(func():
		editor.debug_panel.session_started(session_id)
		editor.debug_started())
	s.breaked.connect(func(can_debug: bool): editor.debug_panel.breaked(session_id, can_debug))
	s.continued.connect(func(): editor.debug_panel.resumed(session_id))
	s.stopped.connect(func():
		editor.debug_panel.session_stopped(session_id)
		editor.debug_resume())


## The debugger passes a 0-based line.
func _goto_script_line(script: Script, line: int) -> void:
	if script and editor:
		editor.debug_goto(script.resource_path, line + 1)
