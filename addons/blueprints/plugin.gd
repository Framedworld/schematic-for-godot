@tool
extends EditorPlugin
## Blueprints for Godot: Unreal-style visual scripting that compiles to plain GDScript.

const Model := preload("res://addons/blueprints/core/bp_model.gd")
const Editor := preload("res://addons/blueprints/editor/bp_editor.gd")
const W := preload("res://addons/blueprints/editor/bp_widgets.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const TableEditor := preload("res://addons/blueprints/editor/bp_table_editor.gd")
const TableScript := preload("res://addons/blueprints/runtime/data_table.gd")

var editor: Editor
var table_editor: TableEditor
var _showing_table := false
var _screen: VBoxContainer
var _fs_menu: EditorContextMenuPlugin
var _fs_file_menu: EditorContextMenuPlugin
var _tree_menu: EditorContextMenuPlugin
var _debugger: EditorDebuggerPlugin


class FsMenu extends EditorContextMenuPlugin:
	var owner_plugin: EditorPlugin
	func _popup_menu(_paths: PackedStringArray) -> void:
		add_context_menu_item("Blueprint Class...", func(_p): owner_plugin.editor.new_blueprint_dialog(), W.icon("GraphEdit"))
		add_context_menu_item("Data Table...", func(p): owner_plugin.new_table_dialog(String(p[0]) if p.size() > 0 else "res://"), W.icon("Tree"))


class FsFileMenu extends EditorContextMenuPlugin:
	var owner_plugin: EditorPlugin
	func _popup_menu(paths: PackedStringArray) -> void:
		if paths.size() == 1 and paths[0].get_extension() == "gd" and not Model.is_blueprint_file(paths[0]):
			add_context_menu_item("Convert to Blueprint...", func(p): owner_plugin.editor.convert_script_dialog(String(p[0])), W.icon("GraphEdit"))


class TreeMenu extends EditorContextMenuPlugin:
	var owner_plugin: EditorPlugin
	func _popup_menu(paths: PackedStringArray) -> void:
		if paths.size() != 1:
			return
		var root := EditorInterface.get_edited_scene_root()
		var node := root.get_node_or_null(paths[0]) if root else null
		if node == null:
			return
		var scr := node.get_script() as Script
		if scr and Model.is_blueprint_file(scr.resource_path):
			add_context_menu_item("Open Blueprint", func(_n): owner_plugin.open_path(scr.resource_path), W.icon("GraphEdit"))
		elif scr == null:
			add_context_menu_item("Attach New Blueprint...", func(_n): owner_plugin.editor.new_blueprint_dialog(node), W.icon("GraphEdit"))
		elif scr is GDScript and scr.resource_path.get_extension() == "gd":
			add_context_menu_item("Convert Script to Blueprint...", func(_n): owner_plugin.editor.convert_script_dialog(scr.resource_path), W.icon("GraphEdit"))


var _flow_menu := false

func _enter_tree() -> void:
	# One container on the main screen holds both editors (each control added to the main screen directly
	# would get a tab of its own).
	_screen = VBoxContainer.new()
	_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_screen.visible = false
	EditorInterface.get_editor_main_screen().add_child(_screen)
	editor = Editor.new()
	editor.plugin = self
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_screen.add_child(editor)
	editor.build_ui()
	table_editor = TableEditor.new()
	table_editor.plugin = self
	table_editor.visible = false
	_screen.add_child(table_editor)
	table_editor.build_ui()
	table_editor.close_requested.connect(func(): show_table(false))
	_fs_menu = FsMenu.new()
	_fs_menu.owner_plugin = self
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM_CREATE, _fs_menu)
	_fs_file_menu = FsFileMenu.new()
	_fs_file_menu.owner_plugin = self
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_file_menu)
	_tree_menu = TreeMenu.new()
	_tree_menu.owner_plugin = self
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _tree_menu)
	add_tool_menu_item("New Blueprint Class...", func(): editor.new_blueprint_dialog())
	add_tool_menu_item("New Data Table...", func(): new_table_dialog("res://"))
	# kits: other graph addons found in the project
	var kits: Script = load("res://addons/blueprints/core/bp_kits.gd")
	kits.flow_register_folders()
	_flow_menu = kits.has_flow()
	if _flow_menu:
		add_tool_menu_item("Blueprints: Set Up FlowNodes Bridge", func():
			var did: PackedStringArray = kits.flow_setup()
			editor.toast("FlowNodes bridge: %s" % (", ".join(did) if not did.is_empty() else "already set up")))
	scene_changed.connect(func(_root): editor._refresh_components())
	_debugger = load("res://addons/blueprints/editor/bp_debugger.gd").new()
	_debugger.editor = editor
	editor.debugger = _debugger
	editor.debug_panel.plugin_debugger = _debugger
	add_debugger_plugin(_debugger)
	_watch_file_dock()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bp-selftest="):
			_selftest.call_deferred(arg.trim_prefix("--bp-selftest="))


func _exit_tree() -> void:
	remove_tool_menu_item("New Blueprint Class...")
	remove_tool_menu_item("New Data Table...")
	if _flow_menu:
		remove_tool_menu_item("Blueprints: Set Up FlowNodes Bridge")
	if _screen:
		_screen.queue_free()
	if _debugger:
		remove_debugger_plugin(_debugger)
	_unwatch_file_dock()
	if _fs_menu:
		remove_context_menu_plugin(_fs_menu)
	if _fs_file_menu:
		remove_context_menu_plugin(_fs_file_menu)
	if _tree_menu:
		remove_context_menu_plugin(_tree_menu)
	if editor:
		editor.save_all()
		editor.queue_free()


# ---------------------------------------------------------------- Blueprint icon in the FileSystem dock
# The dock gives every .gd file the script icon. Blueprint files get their own, set on the dock's rows
# each time it rebuilds them. Nothing is written to the scripts for this.

const BP_ICON := preload("res://addons/blueprints/icons/blueprint.svg")
var _fs_tree: Tree
var _fs_list: ItemList
var _fs_root_id := 0
var _fs_is_bp: Dictionary = {}   # path -> bool, until the files change
var fs_icons_set := 0            # rows given the icon so far (for the tests)


func _watch_file_dock() -> void:
	var dock := EditorInterface.get_file_system_dock()
	if dock == null:
		return
	for t in dock.find_children("*", "Tree", true, false):
		if _fs_tree == null and not (t.get_parent() is Window):
			_fs_tree = t
	for l in dock.find_children("*", "ItemList", true, false):
		if _fs_list == null and not (l.get_parent() is Window):
			_fs_list = l
	if _fs_tree:
		_fs_tree.draw.connect(_mark_tree)
	if _fs_list:
		_fs_list.draw.connect(_mark_list)
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_files_changed)


func _files_changed() -> void:
	_fs_is_bp.clear()
	_fs_root_id = 0
	if _fs_tree:
		_fs_tree.queue_redraw()


func _unwatch_file_dock() -> void:
	if _fs_tree and is_instance_valid(_fs_tree) and _fs_tree.draw.is_connected(_mark_tree):
		_fs_tree.draw.disconnect(_mark_tree)
	if _fs_list and is_instance_valid(_fs_list) and _fs_list.draw.is_connected(_mark_list):
		_fs_list.draw.disconnect(_mark_list)
	var efs := EditorInterface.get_resource_filesystem()
	if efs and efs.filesystem_changed.is_connected(_files_changed):
		efs.filesystem_changed.disconnect(_files_changed)


func _is_blueprint_path(path: String) -> bool:
	if not path.ends_with(".gd"):
		return false
	if not _fs_is_bp.has(path):
		_fs_is_bp[path] = Model.is_blueprint_file(path)
	return _fs_is_bp[path]


## The dock makes a new root each time it rebuilds its tree, so the rows are only gone through then. The
## Blueprint rows found are kept, because the dock sets a row's icon again when its preview arrives.
var _fs_rows: Array[TreeItem] = []

func _mark_tree() -> void:
	var root := _fs_tree.get_root()
	if root == null:
		return
	if int(root.get_instance_id()) != _fs_root_id:
		_fs_root_id = int(root.get_instance_id())
		_fs_rows.clear()
		var todo: Array[TreeItem] = [root]
		while not todo.is_empty():
			var it: TreeItem = todo.pop_back()
			var meta: Variant = it.get_metadata(0)
			if typeof(meta) == TYPE_STRING and _is_blueprint_path(meta):
				_fs_rows.append(it)
			todo.append_array(it.get_children())
	var changed := false
	for it in _fs_rows:
		if is_instance_valid(it) and it.get_icon(0) != BP_ICON:
			it.set_icon(0, BP_ICON)
			fs_icons_set += 1
			changed = true
	if changed:
		# a redraw asked for while the tree is drawing is dropped, so ask again once it is done
		_fs_tree.queue_redraw.call_deferred()


## The file list of the split view, where each row carries the script icon (not in thumbnail view).
func _mark_list() -> void:
	var script_icon := W.icon("GDScript")
	for i in _fs_list.item_count:
		if _fs_list.get_item_icon(i) != script_icon:
			continue
		var meta: Variant = _fs_list.get_item_metadata(i)
		if typeof(meta) == TYPE_STRING and _is_blueprint_path(meta):
			_fs_list.set_item_icon(i, BP_ICON)
			_fs_list.queue_redraw.call_deferred()


func _selftest(path: String) -> void:
	var s := load(path) as GDScript
	if s:
		s.new().run(self)


func open_path(path: String) -> void:
	if editor.open_blueprint(path):
		EditorInterface.set_main_screen_editor("Blueprint")


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Blueprint"


func _get_plugin_icon() -> Texture2D:
	return W.icon("GraphEdit")


var _screen_visible := false

func _make_visible(visible: bool) -> void:
	_screen_visible = visible
	if _screen:
		_screen.visible = visible
	if editor:
		editor.visible = not _showing_table
		if visible and editor.visible:
			editor._refresh_components()
	if table_editor:
		table_editor.visible = _showing_table


## Switches the Blueprint main screen between the graph editor and the Data Table editor.
func show_table(on: bool) -> void:
	_showing_table = on and table_editor != null and table_editor.table != null
	_make_visible(_screen_visible)


func is_data_table(object: Object) -> bool:
	return object is Resource and object.get_script() == TableScript


func _handles(object: Object) -> bool:
	return is_data_table(object) or (object is GDScript and Model.is_blueprint_source((object as GDScript).source_code))


func _edit(object: Object) -> void:
	if is_data_table(object):
		table_editor.edit(object as Resource)
		show_table(true)
		EditorInterface.set_main_screen_editor.call_deferred("Blueprint")
	elif object is GDScript and (object as GDScript).resource_path != "":
		show_table(false)
		if editor.open_blueprint((object as GDScript).resource_path):
			EditorInterface.set_main_screen_editor.call_deferred("Blueprint")


## New Data Table: pick the row structure, then where to save it.
func new_table_dialog(dir: String) -> void:
	R.invalidate_scripts()
	var items := []
	for cls in R.data_classes():
		items.append({"label": cls, "value": String(T.globals()[cls].path), "icon": W.icon("Object"),
			"tip": "Rows have these fields: " + ", ".join(R.data_fields(cls).map(func(f): return String(f[0])))})
	if items.is_empty():
		var dlg := AcceptDialog.new()
		dlg.title = "New Data Table"
		dlg.dialog_text = "A Data Table needs a row structure first.\n\nCreate one with New Blueprint > Data Asset, add a variable for each column, and compile it. Any Resource script with a class name and exported variables also works."
		dlg.visibility_changed.connect(func():
			if not dlg.visible:
				dlg.queue_free())
		EditorInterface.get_base_control().add_child(dlg)
		dlg.popup_centered()
		return
	W.popup_search(EditorInterface.get_base_control(), items, func(script_path: String): _new_table_file(script_path, dir),
		"New Data Table: row structure", true)


func _new_table_file(script_path: String, dir: String) -> void:
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.add_filter("*.tres", "Data Table")
	fd.title = "Save Data Table"
	if not dir.ends_with("/") and not DirAccess.dir_exists_absolute(dir):
		dir = dir.get_base_dir()
	fd.current_path = dir.path_join("DT_%s.tres" % script_path.get_file().get_basename().trim_prefix("BP_"))
	fd.file_selected.connect(func(path: String): create_table(path, script_path))
	fd.visibility_changed.connect(func():
		if not fd.visible:
			fd.queue_free())
	EditorInterface.get_base_control().add_child(fd)
	fd.popup_file_dialog()


## Creates an empty table file with the given row structure and opens it.
func create_table(path: String, script_path: String) -> Resource:
	var table: Resource = TableScript.new()
	table.row_script = load(script_path)
	if ResourceSaver.save(table, path) != OK:
		return null
	EditorInterface.get_resource_filesystem().update_file(path)
	table = load(path)
	EditorInterface.edit_resource(table)
	return table


func _get_breakpoints() -> PackedStringArray:
	return editor.breakpoint_lines() if editor else PackedStringArray()


func _apply_changes() -> void:
	if editor:
		editor.save_all()


func _save_external_data() -> void:
	if editor:
		editor.save_all()


func _get_unsaved_status(for_scene: String) -> String:
	if for_scene == "" and editor and editor.has_unsaved():
		return "Save changes to open Blueprints before closing?"
	return ""


## While the game is stopped at a node and the Blueprint editor is on screen, the debugger's step keys move
## one node at a time instead of one generated line.
func _input(event: InputEvent) -> void:
	if editor == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if not editor.is_visible_in_tree() or editor.debug_panel == null or not editor.debug_panel.paused:
		return
	var es := EditorInterface.get_editor_settings()
	for pair in [["debugger/step_into", "step"], ["debugger/step_over", "next"], ["debugger/step_out", "out"]]:
		if es.has_shortcut(pair[0]) and es.is_shortcut(pair[0], event):
			editor.debug_panel.step(pair[1])
			get_viewport().set_input_as_handled()
			return


func _shortcut_input(event: InputEvent) -> void:
	if editor and editor.is_visible_in_tree() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		editor.compile_doc(editor.doc, true)
		get_viewport().set_input_as_handled()
