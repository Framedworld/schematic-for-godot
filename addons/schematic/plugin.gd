@tool
extends EditorPlugin
## Schematic: visual scripting for Godot that compiles to plain GDScript.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Editor := preload("res://addons/schematic/editor/sc_editor.gd")
const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const TableEditor := preload("res://addons/schematic/editor/sc_table_editor.gd")
const TableScript := preload("res://addons/schematic/runtime/data_table.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")

var editor: Editor
var table_editor: TableEditor
var _showing_table := false
var _screen: VBoxContainer
var _fs_menu: EditorContextMenuPlugin
var _fs_file_menu: EditorContextMenuPlugin
var _tree_menu: EditorContextMenuPlugin
var _debugger: EditorDebuggerPlugin
var _export_check: EditorExportPlugin


class FsMenu extends EditorContextMenuPlugin:
	var owner_plugin: EditorPlugin
	func _popup_menu(_paths: PackedStringArray) -> void:
		add_context_menu_item("Schematic Class...", func(_p): owner_plugin.editor.new_schematic_dialog(), W.icon("GraphEdit"))
		add_context_menu_item("Data Table...", func(p): owner_plugin.new_table_dialog(String(p[0]) if p.size() > 0 else "res://"), W.icon("Tree"))


class FsFileMenu extends EditorContextMenuPlugin:
	var owner_plugin: EditorPlugin
	func _popup_menu(paths: PackedStringArray) -> void:
		if paths.size() == 1 and paths[0].get_extension() == "gd" and not Model.is_schematic_file(paths[0]):
			add_context_menu_item("Convert to Schematic...", func(p): owner_plugin.editor.convert_script_dialog(String(p[0])), W.icon("GraphEdit"))


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
		if scr and Model.is_schematic_file(scr.resource_path):
			add_context_menu_item("Open Schematic", func(_n): owner_plugin.open_path(scr.resource_path), W.icon("GraphEdit"))
		elif scr == null:
			add_context_menu_item("Attach New Schematic...", func(_n): owner_plugin.editor.new_schematic_dialog(node), W.icon("GraphEdit"))
		elif scr is GDScript and scr.resource_path.get_extension() == "gd":
			add_context_menu_item("Convert Script to Schematic...", func(_n): owner_plugin.editor.convert_script_dialog(scr.resource_path), W.icon("GraphEdit"))


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
	add_tool_menu_item("New Schematic Class...", func(): editor.new_schematic_dialog())
	add_tool_menu_item("New Data Table...", func(): new_table_dialog("res://"))
	# kits: other graph addons found in the project
	var kits: Script = load("res://addons/schematic/core/sc_kits.gd")
	kits.flow_register_folders()
	_flow_menu = kits.has_flow()
	if _flow_menu:
		add_tool_menu_item("Schematics: Set Up FlowNodes Bridge", func():
			var did: PackedStringArray = kits.flow_setup()
			editor.toast("FlowNodes bridge: %s" % (", ".join(did) if not did.is_empty() else "already set up")))
	scene_changed.connect(func(_root): editor._refresh_components())
	_debugger = load("res://addons/schematic/editor/sc_debugger.gd").new()
	_debugger.editor = editor
	editor.debugger = _debugger
	editor.debug_panel.plugin_debugger = _debugger
	add_debugger_plugin(_debugger)
	_export_check = load("res://addons/schematic/editor/sc_export_check.gd").new()
	add_export_plugin(_export_check)
	_watch_file_dock()
	_watch_kits()
	# a script saved in Godot (its script editor) may be an open Schematic edited there by hand
	resource_saved.connect(_on_resource_saved)
	main_screen_changed.connect(_on_main_screen_changed)
	EditorInterface.get_editor_settings().settings_changed.connect(_on_editor_settings_changed)
	editor.update_float_button()
	if bool(_float_saved().get("on", false)):
		_restore_floating.call_deferred()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sc-selftest="):
			_selftest.call_deferred(arg.trim_prefix("--sc-selftest="))


func _exit_tree() -> void:
	remove_tool_menu_item("New Schematic Class...")
	remove_tool_menu_item("New Data Table...")
	if _flow_menu:
		remove_tool_menu_item("Schematics: Set Up FlowNodes Bridge")
	var es := EditorInterface.get_editor_settings()
	if es and es.settings_changed.is_connected(_on_editor_settings_changed):
		es.settings_changed.disconnect(_on_editor_settings_changed)
	if _float:
		# (still floating the next time: closing the editor or switching the plugin off is not docking it)
		_save_float_place()
		_float.unpark()
		_float.hide()
		_float.queue_free()
		_float = null
		_floating = false
	if _screen:
		_screen.queue_free()
	if _debugger:
		remove_debugger_plugin(_debugger)
	if _export_check:
		remove_export_plugin(_export_check)
		_export_check = null
	_unwatch_file_dock()
	_unwatch_kits()
	if _fs_menu:
		remove_context_menu_plugin(_fs_menu)
	if _fs_file_menu:
		remove_context_menu_plugin(_fs_file_menu)
	if _tree_menu:
		remove_context_menu_plugin(_tree_menu)
	if editor:
		editor.save_all()
		editor.queue_free()


# ---------------------------------------------------------------- Schematic icon in the FileSystem dock
# The dock gives every .gd file the script icon. Schematic files get their own, set on the dock's rows
# each time it rebuilds them. Nothing is written to the scripts for this.

## Drawn from the SVG's text when the plugin starts, so it does not depend on Godot having imported the file
## yet (it has not, the first time a project with the plugin is opened).
var SC_ICON: Texture2D
var _fs_tree: Tree
var _fs_list: ItemList
var _fs_root_id := 0
var _fs_is_bp: Dictionary = {}   # path -> bool, until the files change
var fs_icons_set := 0            # rows given the icon so far (for the tests)


func _watch_file_dock() -> void:
	var dock := EditorInterface.get_file_system_dock()
	if dock == null:
		return
	var svg := FileAccess.get_file_as_string("res://addons/schematic/icons/schematic.svg")
	var img := Image.new()
	# the drawing is 64 pixels wide; rows show icons at about 16 times the editor scale
	if svg == "" or img.load_svg_from_string(svg, 0.5 * EditorInterface.get_editor_scale()) != OK:
		return
	SC_ICON = ImageTexture.create_from_image(img)
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


func _is_schematic_path(path: String) -> bool:
	if not path.ends_with(".gd"):
		return false
	if not _fs_is_bp.has(path):
		_fs_is_bp[path] = Model.is_schematic_file(path)
	return _fs_is_bp[path]


## The dock makes a new root each time it rebuilds its tree, so the rows are only gone through then. The
## Schematic rows found are kept, because the dock sets a row's icon again when its preview arrives.
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
			if typeof(meta) == TYPE_STRING and _is_schematic_path(meta):
				_fs_rows.append(it)
			todo.append_array(it.get_children())
	var changed := false
	for it in _fs_rows:
		if is_instance_valid(it) and it.get_icon(0) != SC_ICON:
			it.set_icon(0, SC_ICON)
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
		if typeof(meta) == TYPE_STRING and _is_schematic_path(meta):
			_fs_list.set_item_icon(i, SC_ICON)
			_fs_list.queue_redraw.call_deferred()


# ---------------------------------------------------------------- kits
# Addons can ship nodes in res://addons/<addon>/schematic_kit.gd (docs/KITS.md). The kits are loaded again when
# that could have changed what is there: a plugin switched on or off (Project Settings change), or files added,
# removed or edited (the FileSystem dock rescans). Both signals come in bursts, so the check waits until they
# stop, and reloads only when the kit files or the enabled plugins really differ (Kits.signature()).

var _kit_timer: Timer
var _kit_sig := ""


func _watch_kits() -> void:
	R.ensure_api()
	_kit_sig = Kits.signature()
	_kit_timer = Timer.new()
	_kit_timer.one_shot = true
	_kit_timer.wait_time = 0.75
	_kit_timer.timeout.connect(_kits_check)
	add_child(_kit_timer)
	ProjectSettings.settings_changed.connect(_kits_poke)
	var efs := EditorInterface.get_resource_filesystem()
	if efs:
		efs.filesystem_changed.connect(_kits_poke)


func _unwatch_kits() -> void:
	if ProjectSettings.settings_changed.is_connected(_kits_poke):
		ProjectSettings.settings_changed.disconnect(_kits_poke)
	var efs := EditorInterface.get_resource_filesystem()
	if efs and efs.filesystem_changed.is_connected(_kits_poke):
		efs.filesystem_changed.disconnect(_kits_poke)
	if _kit_timer:
		_kit_timer.queue_free()
		_kit_timer = null


func _kits_poke() -> void:
	if _kit_timer and _kit_timer.is_inside_tree():
		_kit_timer.start()


func _kits_check() -> void:
	if Kits.signature() != _kit_sig:
		reload_kits()


## Loads every kit again, then checks and redraws the open Schematics, so nodes of a kit that went away show as
## placeholders (wires kept) and come back as normal nodes when it returns.
func reload_kits() -> void:
	R.reload_kits()
	_kit_sig = Kits.signature()
	if editor == null:
		return
	editor.recheck_all()
	if not R.kit_problems.is_empty():
		editor.toast("Schematic kits: %d problem%s. See Kits... in the File menu." % [R.kit_problems.size(), "" if R.kit_problems.size() == 1 else "s"])


func _on_resource_saved(res: Resource) -> void:
	if editor and res is Script and res.resource_path != "":
		editor.check_drift_path(res.resource_path)


func _selftest(path: String) -> void:
	var s := load(path) as GDScript
	if s:
		s.new().run(self)


func open_path(path: String) -> void:
	if editor.open_schematic(path):
		show_editor()


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Schematic"


func _get_plugin_icon() -> Texture2D:
	return W.icon("GraphEdit")


var _screen_visible := false

func _make_visible(visible: bool) -> void:
	if _floating:
		# The editor is in its own window, which this neither shows nor hides.
		_show_editors(visible)
		if not _tab_is_dock():
			# Godot 4.6 and 4.7 call this when the Schematic tab is chosen or left. The tab has nothing to show
			# while the editor floats, and _settle_tab leaves it again.
			_screen_visible = false
			_screen.visible = false
			if visible:
				_settle_tab.call_deferred()
		return
	_screen_visible = visible
	if _screen:
		_screen.visible = visible
	_show_editors(visible)


func _show_editors(refresh: bool) -> void:
	if editor:
		editor.visible = not _showing_table
		if refresh and editor.visible:
			editor._refresh_components()
			editor.check_drift_all()
	if table_editor:
		table_editor.visible = _showing_table


## Switches the Schematic main screen between the graph editor and the Data Table editor.
func show_table(on: bool) -> void:
	_showing_table = on and table_editor != null and table_editor.table != null
	if _floating:
		_show_editors(true)
	else:
		_make_visible(_screen_visible)


# ---------------------------------------------------------------- the editor in its own window
# Make Floating (the button at the right of the toolbar) moves the editors into a window of the plugin's own
# (editor/sc_float.gd); closing that window, or the button again, brings them back. Nothing here is made until
# the editor is first floated. Whether it floats and where is kept per project, in the project's .godot folder.

const FloatWindow := preload("res://addons/schematic/editor/sc_float.gd")

var _float: FloatWindow        # made the first time the editor is floated
var _floating := false
var _placeholder: Control      # what the Schematic tab holds while the editor is in its window
var _main_screen := ""         # the main screen tab chosen now, once Godot has said (it has no way to ask)
var _last_screen := ""         # the one used last that is not Schematic's (2D, 3D, Script...)
var _float_written: Variant = null   # what the project's metadata holds (read once)


func is_floating() -> bool:
	return _floating


func float_window() -> Window:
	return _float


func can_float() -> bool:
	return EditorInterface.is_multi_window_enabled()


## Why the editor can't have its own window (the wording follows Godot's own Make Floating buttons).
func cannot_float_reason() -> String:
	if can_float():
		return ""
	var es := EditorInterface.get_editor_settings()
	for key in ["interface/editor/display/single_window_mode", "interface/editor/single_window_mode"]:
		if es.has_setting(key) and bool(es.get_setting(key)):
			return "Not available while Interface > Editor > Single Window Mode is on in the Editor Settings."
	if get_tree().root.gui_embed_subwindows:
		return "Not available: the editor was started with --single-window, or this platform has one window only."
	return "Not available while Interface > Multi Window > Enable is off in the Editor Settings."


## Shows the Schematic editor wherever it is: its window when it floats, its main screen tab when it does not.
func show_editor() -> void:
	if _floating:
		_float.bring_forward()
	else:
		EditorInterface.set_main_screen_editor("Schematic")


## Where a dialog asked for now belongs: over the floating window when that is the window in use.
func dialog_host() -> Control:
	if _floating and _float.has_focus():
		return _float.dialog_host()
	return EditorInterface.get_base_control()


func toggle_floating() -> void:
	set_floating(not _floating)


func set_floating(on: bool) -> void:
	if on == _floating or editor == null or _screen == null:
		return
	if on:
		if not can_float():
			editor.toast(cannot_float_reason())
			editor.update_float_button()
			return
		var saved := _float_saved()
		var rect := _float_rect(saved)
		if _float == null:
			_float = FloatWindow.new()
			_float.plugin = self
			_float.close_requested.connect(set_floating.bind(false))
			_float.focus_entered.connect(_on_float_focus)
			_float.focus_exited.connect(_save_float_place)
			_screen.add_child(_float)
			_placeholder = _make_placeholder()
			_screen.add_child(_placeholder)
		_move_editors(_float.box)
		var maximize := bool(saved.get("max", false))
		var es := EditorInterface.get_editor_settings()
		if not saved.has("rect") and es.has_setting("interface/multi_window/maximize_window"):
			maximize = bool(es.get_setting("interface/multi_window/maximize_window"))
		_float.open(rect, maximize)
		# (Godot has no way to ask which tab is chosen: it says when that changes, and before it first has, the
		# tab is the chosen one if what it holds is on screen)
		var on_tab := _on_schematic_tab() or (_main_screen == "" and _screen.is_visible_in_tree())
		_floating = true
		_placeholder.visible = true
		if not _tab_is_dock():
			_screen_visible = false
			_screen.visible = false
		_show_editors(true)
		if on_tab:
			_main_screen = _get_plugin_name()
			_settle_tab.call_deferred()
	else:
		_save_float_place()
		_float.close_dialogs()
		_move_editors(_screen)
		_float.hide()
		_float.unpark()
		_floating = false
		_placeholder.visible = false
		EditorInterface.set_main_screen_editor("Schematic")
		if _on_schematic_tab():
			_make_visible(true)   # (Godot 4.8 does not call it for a tab, nor does any when the tab was already chosen)
	_write_float(_float_saved().merged({"on": _floating}, true))
	editor.update_float_button()


func _move_editors(to: Node) -> void:
	var at := 0
	for c in [editor, table_editor]:
		if c == null:
			continue
		if c.get_parent() != to:
			c.get_parent().remove_child(c)
			to.add_child(c)
		to.move_child(c, at)
		at += 1


func _make_placeholder() -> Control:
	var center := CenterContainer.new()
	center.name = "FloatingPlaceholder"
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.visible = false
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", W.si(10))
	center.add_child(rows)
	var label := Label.new()
	label.text = "The Schematic editor is in its own window."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.add_child(label)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", W.si(8))
	rows.add_child(buttons)
	var show_btn := Button.new()
	show_btn.text = "Show the Window"
	show_btn.pressed.connect(func():
		if _floating:
			_float.bring_forward())
	buttons.add_child(show_btn)
	var dock_btn := Button.new()
	dock_btn.text = "Dock It Back Here"
	dock_btn.pressed.connect(set_floating.bind(false))
	buttons.add_child(dock_btn)
	return center


func _on_main_screen_changed(screen_name: String) -> void:
	_main_screen = screen_name
	if screen_name != _get_plugin_name():
		_last_screen = screen_name
	elif _floating:
		_settle_tab.call_deferred()


func _on_schematic_tab() -> bool:
	return _main_screen == _get_plugin_name()


## Godot 4.8 puts what a plugin adds to the main screen into a dock of its own, shows and hides that dock with
## the tab, and no longer calls _make_visible for tabs. Before 4.8 the plugin shows and hides its own control.
func _tab_is_dock() -> bool:
	return _screen.get_parent() != EditorInterface.get_editor_main_screen()


## The Schematic tab was chosen while the editor is in its own window: bring the window forward and put the main
## window back on the screen it showed before (as Godot's Game tab does when it floats). If the main window can't
## leave the tab, the tab says where the editor is and has a button to dock it back.
func _settle_tab() -> void:
	if not _floating or not _on_schematic_tab():
		return
	_float.bring_forward()
	var to := _last_screen
	if to == "":
		to = "3D" if EditorInterface.get_edited_scene_root() is Node3D else "2D"
	EditorInterface.set_main_screen_editor(to)
	if _on_schematic_tab():
		_screen_visible = true
		_screen.visible = true


func _on_float_focus() -> void:
	if _floating and editor and editor.visible:
		editor._refresh_components()
		editor.check_drift_all()


func _on_editor_settings_changed() -> void:
	if editor:
		editor.update_float_button()


func _float_saved() -> Dictionary:
	if _float_written == null:
		var read: Variant = EditorInterface.get_editor_settings().get_project_metadata("schematics", "floating_window", {})
		_float_written = read if read is Dictionary else {}
	return _float_written


func _write_float(state: Dictionary) -> void:
	if state != _float_saved():
		_float_written = state
		EditorInterface.get_editor_settings().set_project_metadata("schematics", "floating_window", state)


## Remembers where the window is now (asked for whenever it may have moved: the window has no signal for that).
func _save_float_place() -> void:
	if _floating and _float:
		_write_float(_float.placement(_float_saved()))


func _float_rect(saved: Dictionary) -> Rect2i:
	var screens := []
	for i in DisplayServer.get_screen_count():
		screens.append(DisplayServer.screen_get_usable_rect(i))
	var main_window := EditorInterface.get_base_control().get_window()
	var rect := FloatWindow.fit_rect(saved, screens, main_window.current_screen, W.si(32))
	if rect.size.x > 0:
		return rect
	# the first time: where the editor is now, as Godot's own floating editors open
	if _screen.is_visible_in_tree() and _screen.size.x > 0 and _screen.size.y > 0:
		return Rect2i(Vector2i(_screen.get_screen_position()), Vector2i(_screen.size))
	# (floated while another tab is showing: over the middle of the main window)
	var over := Rect2i(main_window.position, main_window.size)
	return Rect2i(over.position + over.size / 8, over.size * 3 / 4)


## When the project is opened with the editor floating as it was left (unless Godot is set not to bring windows
## back, or can't have them now).
func _restore_floating() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	var waited := 0
	while is_inside_tree() and efs != null and efs.is_scanning() and waited < 3600:
		await get_tree().process_frame
		waited += 1
	if not is_inside_tree() or _floating or not can_float():
		return
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("interface/multi_window/restore_windows_on_load") and not bool(es.get_setting("interface/multi_window/restore_windows_on_load")):
		return
	set_floating(true)


func _get_window_layout(_configuration: ConfigFile) -> void:
	_save_float_place()   # (Godot is saving its own windows' places: the moment to note this one's)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_float_place()


func is_data_table(object: Object) -> bool:
	return object is Resource and object.get_script() == TableScript


func _handles(object: Object) -> bool:
	return is_data_table(object) or (object is GDScript and Model.is_schematic_source((object as GDScript).source_code))


func _edit(object: Object) -> void:
	if is_data_table(object):
		table_editor.edit(object as Resource)
		show_table(true)
		show_editor.call_deferred()
	elif object is GDScript and (object as GDScript).resource_path != "":
		show_table(false)
		if editor.open_schematic((object as GDScript).resource_path):
			show_editor.call_deferred()


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
		dlg.dialog_text = "A Data Table needs a row structure first.\n\nCreate one with New Schematic > Data Asset, add a variable for each column, and compile it. Any Resource script with a class name and exported variables also works."
		dlg.visibility_changed.connect(func():
			if not dlg.visible:
				dlg.queue_free())
		dialog_host().add_child(dlg)
		dlg.popup_centered()
		return
	W.popup_search(dialog_host(), items, func(script_path: String): _new_table_file(script_path, dir),
		"New Data Table: row structure", true)


func _new_table_file(script_path: String, dir: String) -> void:
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.add_filter("*.tres", "Data Table")
	fd.title = "Save Data Table"
	if not dir.ends_with("/") and not DirAccess.dir_exists_absolute(dir):
		dir = dir.get_base_dir()
	fd.current_path = dir.path_join("DT_%s.tres" % script_path.get_file().get_basename().trim_prefix("SC_"))
	fd.file_selected.connect(func(path: String): create_table(path, script_path))
	fd.visibility_changed.connect(func():
		if not fd.visible:
			fd.queue_free())
	dialog_host().add_child(fd)
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
	_save_float_place()


func _get_unsaved_status(for_scene: String) -> String:
	if for_scene == "" and editor and editor.has_unsaved():
		var changed: Array = editor.unsaved_and_changed_outside()
		if not changed.is_empty():
			return "Save changes to open Schematics before closing?\n%s also changed outside Schematic: saving does not overwrite %s, so %s graph changes will be lost. Cancel to choose in the Schematic editor." % [
				", ".join(changed.map(func(p): return String(p).get_file())), "it" if changed.size() == 1 else "them", "its" if changed.size() == 1 else "their"]
		return "Save changes to open Schematics before closing?"
	return ""


## While the game is stopped at a node and the Schematic editor is on screen, the debugger's step keys move
## one node at a time instead of one generated line.
func _input(event: InputEvent) -> void:
	if editor == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if not editor.is_visible_in_tree() or editor.debug_panel == null or not editor.debug_panel.paused:
		return
	if _floating and not _float.forwarding:
		return   # a key pressed in the main window while the editor floats is the main window's
	var es := EditorInterface.get_editor_settings()
	for pair in [["debugger/step_into", "step"], ["debugger/step_over", "next"], ["debugger/step_out", "out"]]:
		if es.has_shortcut(pair[0]) and es.is_shortcut(pair[0], event):
			editor.debug_panel.step(pair[1])
			get_viewport().set_input_as_handled()
			return


func _shortcut_input(event: InputEvent) -> void:
	if _floating and not _float.forwarding:
		return
	if editor and editor.is_visible_in_tree() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		editor.compile_doc(editor.doc, true)
		get_viewport().set_input_as_handled()
