@tool
extends EditorExportPlugin
## Says so when a release is exported while Show Flow and Values is still on in some Schematics.
##
## That option is a debug aid saved with each file: it writes a tracing call before every node. In a game run from
## the editor the calls report to the Schematic editor; in an exported game they report to nobody but are still
## made, which is work a hand-written script would not do. Nothing is changed in the export: the warning names the
## files, and the option is turned off in each one's Class Settings.

const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")


func _get_name() -> String:
	return "SchematicExportCheck"


func _export_begin(_features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
	if is_debug:
		return
	var traced := files_with_trace()
	if traced.is_empty():
		return
	var message := warning_text(traced)
	push_warning("Schematic: " + message)
	var platform := get_export_platform()
	if platform != null:
		platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_WARNING, "Schematic", message)


## The project's Schematics that have Show Flow and Values on.
static func files_with_trace(root := "res://") -> PackedStringArray:
	var out := PackedStringArray()
	var files := []
	ProjectFiles.find(root, ["gd"], files)
	files.sort()
	for path: String in files:
		if not Model.is_schematic_file(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		# (the cheap look first: the option is written as "trace":true in the first line of the graph data)
		if text.contains("\"trace\":true") and bool(Model.parse_source(text).get("trace", false)):
			out.append(path)
	return out


static func warning_text(traced: PackedStringArray) -> String:
	var shown := ", ".join(Array(traced).slice(0, 8))
	if traced.size() > 8:
		shown += " and %d more" % (traced.size() - 8)
	return "Show Flow and Values is on in %d Schematic%s, so the exported game makes a tracing call at every node of %s: %s. Turn it off in Class Settings and save." % [
		traced.size(), "" if traced.size() == 1 else "s", "it" if traced.size() == 1 else "them", shown]
