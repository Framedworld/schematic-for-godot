@tool
extends RefCounted
## Files a project-wide editing tool can visit. Explicit subfolders obey the same project boundaries.

static func includes_folder(path: String) -> bool:
	if not path.begins_with("res://"):
		return false
	var parent := "res://"
	for part in path.trim_prefix("res://").replace("\\", "/").split("/", false):
		if part.begins_with(".") or part.contains(":"):
			return false
		var dir := DirAccess.open(parent)
		if dir == null or dir.is_link(part):
			return false
		parent = parent.path_join(part)
		if FileAccess.file_exists(parent.path_join(".gdignore")) or FileAccess.file_exists(parent.path_join("project.godot")):
			return false
	return true


static func find(path: String, extensions: Array, out: Array) -> void:
	if not includes_folder(path):
		return
	var found := {}
	_collect(path, extensions, found)
	for existing in out:
		found.erase(existing)
	out.append_array(found.keys())


static func _collect(path: String, extensions: Array, out: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_files():
		if name.get_extension() in extensions and not dir.is_link(name):
			out[path.path_join(name)] = true
	for name in dir.get_directories():
		if name.begins_with(".") or dir.is_link(name) or (path == "res://" and name == "addons"):
			continue
		var child := path.path_join(name)
		if not FileAccess.file_exists(child.path_join(".gdignore")) and not FileAccess.file_exists(child.path_join("project.godot")):
			_collect(child, extensions, out)
