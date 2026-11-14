@tool
extends Logger
## Captures script errors while the generated code is test-compiled, so they can be shown on nodes.

var items: Array = []
var _mutex := Mutex.new()


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array) -> void:
	_mutex.lock()
	items.append({"line": line, "msg": rationale if rationale != "" else code, "file": file, "fn": function})
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass
