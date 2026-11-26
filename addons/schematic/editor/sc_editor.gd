@tool
extends VBoxContainer
## The Schematic main screen: open documents, graph canvas, My Schematic, Components, Details, compiler.

const T := preload("res://addons/schematic/core/sc_types.gd")
const ProjectFiles := preload("res://addons/schematic/core/sc_project_files.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Kits := preload("res://addons/schematic/core/sc_kits.gd")
const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const GraphView := preload("res://addons/schematic/editor/sc_graph_view.gd")
const Palette := preload("res://addons/schematic/editor/sc_palette.gd")
const CurveEdit := preload("res://addons/schematic/editor/sc_curve_edit.gd")
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const DebugPanel := preload("res://addons/schematic/editor/sc_debug_panel.gd")
const CodeLink := preload("res://addons/schematic/editor/sc_code_link.gd")
const Sync := preload("res://addons/schematic/core/sc_sync.gd")
const NodeVisual := preload("res://addons/schematic/editor/sc_graph_node.gd")   # (its static helpers turn comments into text and back)

## Generated-code highlights for the selected nodes: the amber the graph draws a selected node's outline in, as a
## wash over the code view's own background (so it reads on light and dark themes alike). A line the node itself
## wrote is the strong one; a line it only takes part in (a getter read by that line) is the soft one.
const LINK_STRONG := Color(1.0, 0.72, 0.1, 0.36)
const LINK_SOFT := Color(1.0, 0.72, 0.1, 0.12)
const LINK_NONE := Color(0, 0, 0, 0)
const CARET_DEBOUNCE := 0.12   # seconds the caret rests before the clicked line selects its node

var plugin: EditorPlugin
var docs: Array = []          # [{path, bp, graph_id, dirty, errors, code, line_map, node_lines}]
var doc: Dictionary = {}
var _sel: Dictionary = {"kind": "class"}

var _doc_tabs: TabBar
var _graph_tabs: TabBar
var _view: GraphView
var _members: Tree
var _components: Tree
var _details: VBoxContainer
var _details_title: Label
var _details_search: LineEdit
var _cat_body: VBoxContainer          # rows of the category being filled
var _cat_collapsed: Dictionary = {}   # category name -> true, remembered while the editor is open
var _results: ItemList
var _status: Label
var _compile_btn: Button
var _code: CodeEdit
var _code_label: Label
var _code_notice: Label     # above the code view while it shows the code the game runs and that is not the graph's code
var _comments_btn: Button   # Hide Comments (a session setting: the graph view keeps it from graph to graph)
var _right_tabs: TabContainer
var _empty: Control
var _body: Control
var _palette: Palette
var _crumb: Label
var _toast: Label
var _toolbar: HBoxContainer
var _float_btn: Button      # Make Floating / dock back (the window itself is the plugin's)
var _parent_btn: Button
var _class_btn: Button
var _defaults_btn: Button
var _members_search: LineEdit
var _suppress_tabs := false
var debugger: EditorDebuggerPlugin
var _paused: Array = []   # [path, graph_id, node_id] while the game is stopped at a node
var debug_panel: DebugPanel
var _step_tools: Array = []   # toolbar buttons shown only while the game is paused
var _debug_cache: Dictionary = {}   # path -> line maps of schematics that are not open (see debug_info)
# Changes made to a document's file outside this editor (see "changes made outside Schematic" below).
var _drift_bar: PanelContainer
var _drift_label: Label
var _drift_btns: Dictionary = {}    # name -> Button
var _close_dialog: AcceptDialog     # the question asked when closing a changed document whose file changed too
var _diff_dialog: AcceptDialog      # Show Changes
var recompile_skipped: Array = []   # files a macro library's save did not rewrite, because they were edited outside
var _file_menu: MenuButton
const FILE_REIMPORT := 4            # File > Re-import Code From File...
var _reimport_dialog: AcceptDialog  # the Re-import Code preview (or why it can't be done)
var reimport_last: Dictionary = {}  # the last preview: {path, text, code, both, graph_only, result} (the self-test reads it)


func _init() -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().filesystem_changed.connect(func():
			R.invalidate_libraries()
			check_drift_all.call_deferred())
	name = "Schematic"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func build_ui() -> void:
	# --- document tabs, with the parent class on the right (as in Unreal's asset tab row)
	var tab_row := HBoxContainer.new()
	add_child(tab_row)
	_doc_tabs = TabBar.new()
	_doc_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_doc_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	_doc_tabs.tab_changed.connect(_on_doc_tab)
	_doc_tabs.tab_close_pressed.connect(_close_doc)
	tab_row.add_child(_doc_tabs)
	var filler := Control.new()
	filler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.add_child(filler)
	_toast = Label.new()
	_toast.add_theme_color_override("font_color", Color(1, 0.8, 0.35))
	tab_row.add_child(_toast)
	_parent_btn = Button.new()
	_parent_btn.flat = true
	_parent_btn.focus_mode = Control.FOCUS_NONE
	_parent_btn.add_theme_font_size_override("font_size", W.si(13))
	_parent_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_parent_btn.tooltip_text = "The class this schematic extends. Click to open Class Settings."
	_parent_btn.pressed.connect(func(): _select({"kind": "class"}))
	tab_row.add_child(_parent_btn)

	# --- workspace toolbar
	var strip := PanelContainer.new()
	var strip_bg := StyleBoxFlat.new()
	strip_bg.bg_color = W.CHROME
	strip_bg.border_width_bottom = W.si(1)
	strip_bg.border_color = W.EDGE
	strip_bg.content_margin_left = W.si(6)
	strip_bg.content_margin_right = W.si(6)
	strip_bg.content_margin_top = W.si(3)
	strip_bg.content_margin_bottom = W.si(3)
	strip.add_theme_stylebox_override("panel", strip_bg)
	add_child(strip)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", W.si(2))
	strip.add_child(bar)
	_toolbar = bar
	bar.add_child(_tool("", "Save", "Save this schematic (compiles it first). Ctrl+S", func(): compile_doc(doc, true)))
	bar.add_child(_tool("", "ShowInFileSystem", "Browse: show this schematic in the FileSystem dock", func():
		if not doc.is_empty():
			EditorInterface.get_file_system_dock().navigate_to_path(doc.path)))
	_file_menu = _tool_menu("File", ["New Schematic Class...", "Open Schematic...", "Close Schematic", "Kits...", "Re-import Code From File..."], func(i: int):
		if i == 0:
			new_schematic_dialog()
		elif i == 1:
			_open_dialog()
		elif i == 3:
			show_kits_dialog()
		elif i == FILE_REIMPORT:
			reimport_dialog(doc)
		elif not doc.is_empty():
			_close_doc(docs.find(doc)), "Create, open or close schematics; Kits... lists the nodes other addons add", "Add")
	_file_menu.get_popup().set_item_tooltip(FILE_REIMPORT, "Bring code changed outside Schematic into the graph (available while the file's code differs from the graph's)")
	_file_menu.about_to_popup.connect(func(): _file_menu.get_popup().set_item_disabled(FILE_REIMPORT, not can_reimport(doc)))
	bar.add_child(_file_menu)
	bar.add_child(_tool_sep())
	_compile_btn = _tool("Compile", "StatusSuccess", "Compile this schematic to GDScript and save it (F7)", func(): compile_doc(doc, true))
	bar.add_child(_compile_btn)
	bar.add_child(_tool_menu("", ["Compile All Open Schematics", "Show Generated Code"], func(i: int):
		if i == 0:
			for d in docs:
				compile_doc(d, true)
		else:
			_right_tabs.current_tab = 1, "Compile options"))
	_status = Label.new()
	_status.visible = false   # the Compile icon carries the status, as in Unreal; the text is its tooltip
	bar.add_child(_status)
	bar.add_child(_tool_sep())
	bar.add_child(_tool("Find", "Search", "Search the nodes of this schematic (Ctrl+F)", _find_in_schematic))
	var unrelated := _tool("Hide Unrelated", "GuiVisibilityHidden", "Fade every node that is not connected to the selected nodes", func(): pass)
	unrelated.toggle_mode = true
	unrelated.toggled.connect(func(on: bool):
		_view.hide_unrelated = on
		_view.apply_unrelated())
	bar.add_child(unrelated)
	_comments_btn = _tool("Hide Comments", "NodeInfo", "Hide the comment bubbles above the nodes (the comments a script's # lines became)", func(): pass)
	_comments_btn.toggle_mode = true
	_comments_btn.toggled.connect(func(on: bool): _view.set_comments_hidden(on))
	bar.add_child(_comments_btn)
	bar.add_child(_tool_menu("", ["Find in All Schematics"], func(_i: int): find_in_all_schematics(), "More search options"))
	bar.add_child(_tool_sep())
	_class_btn = _tool("Class Settings", "Tools", "Parent class, class name, run in editor, execution flow", func(): _select({"kind": "class"}))
	_class_btn.toggle_mode = true
	bar.add_child(_class_btn)
	_defaults_btn = _tool("Class Defaults", "Edit", "Default values of this schematic's variables", func(): _select({"kind": "defaults"}))
	_defaults_btn.toggle_mode = true
	bar.add_child(_defaults_btn)
	bar.add_child(_tool_sep())
	var play := _tool("", "MainPlay", "Play the current scene (compiles first)", func():
		save_all()
		EditorInterface.play_current_scene())
	play.add_theme_color_override("icon_normal_color", Color(0.35, 0.9, 0.4))
	play.add_theme_color_override("icon_hover_color", Color(0.5, 1.0, 0.55))
	bar.add_child(play)
	bar.add_child(_tool("", "Stop", "Stop the running game", func(): EditorInterface.stop_playing_scene()))
	# Shown while the game is stopped at a node, as in Unreal. The steps move one node at a time.
	_step_tools = [_tool_sep(),
		_tool("Resume", "DebugContinue", "Let the game run on (F12)", debug_continue),
		_tool("", "DebugStep", "Step Into: go to the next node, entering the function or macro this node calls (F11)", func(): debug_panel.step("step")),
		_tool("", "DebugNext", "Step Over: go to the next node in this graph (F10)", func(): debug_panel.step("next")),
		_tool("", "DebugOut", "Step Out: run until this function returns to the node that called it (Alt+F11)", func(): debug_panel.step("out"))]
	for st in _step_tools:
		st.visible = false
		bar.add_child(st)
	var bar_gap := Control.new()
	bar_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(bar_gap)
	_float_btn = _tool("", "MakeFloating", "", func():
		if plugin:
			plugin.toggle_floating())
	_float_btn.toggle_mode = true
	bar.add_child(_float_btn)
	update_float_button()

	# --- empty state
	_empty = CenterContainer.new()
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var ev := VBoxContainer.new()
	_empty.add_child(ev)
	var el := Label.new()
	el.text = "No Schematic open.\nCreate one, or double-click a Schematic script in the FileSystem dock."
	el.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ev.add_child(el)
	var eb := Button.new()
	eb.text = "New Schematic Class..."
	eb.icon = W.icon("Add")
	eb.pressed.connect(func(): new_schematic_dialog())
	ev.add_child(eb)
	add_child(_empty)

	# --- body
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body = split
	add_child(split)

	var left := VSplitContainer.new()
	left.custom_minimum_size.x = W.s(250)
	split.add_child(left)
	var comp_box := VBoxContainer.new()
	comp_box.custom_minimum_size.y = W.s(150)
	left.add_child(comp_box)
	comp_box.add_child(_header("Scene nodes"))
	_components = Tree.new()
	_components.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_components.hide_root = false
	_components.allow_rmb_select = true
	_components.item_mouse_selected.connect(_on_component_clicked)
	_components.set_drag_forwarding(_component_drag, Callable(), Callable())
	_components.tooltip_text = "Scene nodes owned by this schematic's node. Drag into the graph for a reference; right-click to add a signal event."
	comp_box.add_child(_components)
	var mem_box := VBoxContainer.new()
	left.add_child(mem_box)
	mem_box.add_child(_header("Members"))
	var mem_top := HBoxContainer.new()
	mem_box.add_child(mem_top)
	var mem_add := _tool_menu("Add", ["Variable", "Function", "Macro", "Custom Event", "Event Dispatcher", "Enumeration"], func(i: int):
		_on_member_button(null, 0, [SEC_VARS, SEC_FUNCS, SEC_MACROS, SEC_GRAPHS, SEC_DISP, SEC_ENUMS][i], 0), "Add a new member to this schematic", "Add")
	mem_top.add_child(mem_add)
	_members_search = LineEdit.new()
	_members_search.placeholder_text = "Search"
	_members_search.right_icon = W.icon("Search")
	_members_search.clear_button_enabled = true
	_members_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_members_search.text_changed.connect(func(_t): _filter_members())
	mem_top.add_child(_members_search)
	_members = Tree.new()
	_members.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_members.hide_root = true
	_members.allow_rmb_select = true
	_members.item_selected.connect(_on_member_selected)
	_members.item_activated.connect(_on_member_activated)
	_members.button_clicked.connect(_on_member_button)
	_members.item_mouse_selected.connect(_on_member_rmb)
	_members.gui_input.connect(_on_members_input)
	_members.set_drag_forwarding(_member_drag, Callable(), Callable())
	mem_box.add_child(_members)

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right_split)

	var center := VSplitContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.add_child(center)
	var gbox := VBoxContainer.new()
	gbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(gbox)
	var grow := HBoxContainer.new()
	gbox.add_child(grow)
	_graph_tabs = TabBar.new()
	_graph_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_tabs.tab_changed.connect(_on_graph_tab)
	grow.add_child(_graph_tabs)
	var nav := PanelContainer.new()
	var nav_bg := StyleBoxFlat.new()
	nav_bg.bg_color = W.INSET
	nav_bg.content_margin_left = W.si(6)
	nav_bg.content_margin_right = W.si(6)
	nav_bg.content_margin_top = W.si(2)
	nav_bg.content_margin_bottom = W.si(2)
	nav.add_theme_stylebox_override("panel", nav_bg)
	gbox.add_child(nav)
	var nav_row := HBoxContainer.new()
	nav.add_child(nav_row)
	var marks := MenuButton.new()
	marks.icon = W.icon("Bookmark") if W.icon("Bookmark") else W.icon("Favorites")
	marks.flat = true
	marks.tooltip_text = "Bookmarks: remember this view of the graph and jump back to it"
	marks.about_to_popup.connect(_fill_bookmarks.bind(marks.get_popup()))
	marks.get_popup().id_pressed.connect(_on_bookmark)
	nav_row.add_child(marks)
	nav_row.add_child(_tool("", "Back", "Go back to the previous graph", func(): _nav_step(-1)))
	nav_row.add_child(_tool("", "Forward", "Go forward to the next graph", func(): _nav_step(1)))
	var crumb_icon := TextureRect.new()
	crumb_icon.texture = W.icon("GraphEdit")
	crumb_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	crumb_icon.modulate = W.ACCENT
	nav_row.add_child(crumb_icon)
	_crumb = Label.new()
	_crumb.add_theme_font_size_override("font_size", W.si(14))
	_crumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_crumb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_crumb.add_theme_color_override("font_color", W.TEXT)
	nav_row.add_child(_crumb)
	_build_drift_bar(gbox)
	_view = GraphView.new()
	_view.editor = self
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gbox.add_child(_view)
	debug_panel = DebugPanel.new()
	debug_panel.editor = self
	debug_panel.visible = false
	gbox.add_child(debug_panel)
	debug_panel.build_ui()
	var res_box := VBoxContainer.new()
	res_box.custom_minimum_size.y = W.s(90)
	center.add_child(res_box)
	res_box.add_child(_header("Compiler Results"))
	_results = ItemList.new()
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.item_activated.connect(_on_result_activated)
	_results.item_clicked.connect(func(i, _p, _b): _on_result_activated(i))
	res_box.add_child(_results)
	center.split_offset = 2000

	_right_tabs = TabContainer.new()
	_right_tabs.custom_minimum_size.x = W.s(340)
	right_split.add_child(_right_tabs)
	right_split.split_offset = 2000
	var dscroll := ScrollContainer.new()
	dscroll.name = "Details"
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_tabs.add_child(dscroll)
	var dbox := VBoxContainer.new()
	dbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dscroll.add_child(dbox)
	_details_search = LineEdit.new()
	_details_search.placeholder_text = "Search"
	_details_search.right_icon = W.icon("Search")
	_details_search.clear_button_enabled = true
	_details_search.text_changed.connect(func(_t): _filter_details())
	dbox.add_child(_details_search)
	# Kept for its text (the first category is named after it); Unreal has no separate title line.
	_details_title = _header("")
	_details_title.visible = false
	dbox.add_child(_details_title)
	_details = VBoxContainer.new()
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dbox.add_child(_details)
	# The code view with a one-line label under it (what a clicked line is, when no node wrote it).
	var code_box := VBoxContainer.new()
	code_box.name = "Generated Code"
	code_box.add_theme_constant_override("separation", W.si(2))
	_right_tabs.add_child(code_box)
	# While the game runs code that is not the graph's current code: a one-line notice saying so (see _shown()).
	_code_notice = Label.new()
	_code_notice.name = "CodeRunNotice"
	_code_notice.visible = false
	_code_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_code_notice.add_theme_font_size_override("font_size", W.si(12))
	var ed_theme := EditorInterface.get_editor_theme()
	_code_notice.add_theme_color_override("font_color", ed_theme.get_color("warning_color", "Editor") if ed_theme and ed_theme.has_color("warning_color", "Editor") else Color(1, 0.8, 0.35))
	code_box.add_child(_code_notice)
	_code = CodeEdit.new()
	_code.name = "Code"
	_code.editable = false
	_code.gutters_draw_line_numbers = true
	_code.gutters_draw_breakpoints_gutter = true   # a click there toggles the breakpoint of the line's node
	_code.gutters_draw_executing_lines = true      # the arrow on the line the game is stopped at
	_code.draw_tabs = false
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if ClassDB.class_exists("GDScriptSyntaxHighlighter"):
		_code.syntax_highlighter = ClassDB.instantiate("GDScriptSyntaxHighlighter")
	_code.caret_changed.connect(_on_code_caret)
	_code.breakpoint_toggled.connect(_on_code_breakpoint)
	code_box.add_child(_code)
	_code_label = Label.new()
	_code_label.name = "CodeLineLabel"
	_code_label.custom_minimum_size.y = W.s(20)
	_code_label.clip_text = true
	_code_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_code_label.add_theme_font_size_override("font_size", W.si(12))
	_code_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	code_box.add_child(_code_label)
	_right_tabs.tab_changed.connect(func(_i): _update_code(true))

	_palette = Palette.new()
	add_child(_palette)
	_refresh_all()


## A toolbar command with a distinct persistent state for toggles.
func _tool(text: String, icon_name: String, tip: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = W.icon(icon_name)
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", W.si(13))
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.82))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(W.si(4))
		sb.content_margin_left = W.si(7)
		sb.content_margin_right = W.si(7)
		sb.content_margin_top = W.si(4)
		sb.content_margin_bottom = W.si(4)
		match state:
			"normal", "disabled": sb.bg_color = Color(0, 0, 0, 0)
			"hover": sb.bg_color = Color(1, 1, 1, 0.1)
			_: sb.bg_color = W.ACTIVE
		b.add_theme_stylebox_override(state, sb)
	b.pressed.connect(on_press)
	return b


func _tool_menu(text: String, items: Array, on_pick: Callable, tip := "", icon_name := "GuiTabMenuHl") -> MenuButton:
	var mb := MenuButton.new()
	mb.text = text
	mb.icon = W.icon(icon_name)
	mb.flat = true
	mb.tooltip_text = tip
	mb.add_theme_font_size_override("font_size", W.si(13))
	mb.add_theme_color_override("font_color", Color(1, 1, 1, 0.82))
	for i in items.size():
		mb.get_popup().add_item(items[i], i)
	mb.get_popup().id_pressed.connect(on_pick)
	return mb


func _tool_sep() -> Control:
	var c := ColorRect.new()
	c.color = Color(1, 1, 1, 0.12)
	c.custom_minimum_size = W.sv(Vector2(1, 18))
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", W.si(6))
	m.add_theme_constant_override("margin_right", W.si(6))
	m.add_child(c)
	return m


func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", W.si(13))
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	var bold := EditorInterface.get_editor_theme().get_font("bold", "EditorFonts") if EditorInterface.get_editor_theme() else null
	if bold:
		l.add_theme_font_override("font", bold)
	var band := StyleBoxFlat.new()
	band.bg_color = W.CHROME
	band.border_width_left = W.si(3)
	band.border_color = W.ACCENT
	band.set_corner_radius_all(W.si(3))
	band.content_margin_left = W.si(8)
	band.content_margin_right = W.si(8)
	band.content_margin_top = W.si(4)
	band.content_margin_bottom = W.si(4)
	l.add_theme_stylebox_override("normal", band)
	return l


## The Make Floating button follows where the editor is and whether Godot can give it a window of its own.
func update_float_button() -> void:
	if _float_btn == null:
		return
	var floating: bool = plugin != null and plugin.is_floating()
	var reason: String = plugin.cannot_float_reason() if plugin != null else "Not available."
	_float_btn.set_pressed_no_signal(floating)
	_float_btn.disabled = reason != "" and not floating
	if floating:
		_float_btn.tooltip_text = "Dock the Schematic editor back into the main editor window (closing its window does the same)"
	elif reason != "":
		_float_btn.tooltip_text = "Make Floating: open the Schematic editor in its own window.\n" + reason
	else:
		_float_btn.tooltip_text = "Make Floating: open the Schematic editor in its own window, for a second monitor"


## Shows the Schematic editor: its own window when it floats, else its main screen tab.
func _show_screen() -> void:
	if plugin:
		plugin.show_editor()
	else:
		EditorInterface.set_main_screen_editor("Schematic")


## Where dialogs go: over the window the editor is used in.
func _dialog_host() -> Control:
	return plugin.dialog_host() if plugin else EditorInterface.get_base_control()


func toast(msg: String) -> void:
	_toast.text = msg
	var t := get_tree().create_timer(4.0)
	t.timeout.connect(func():
		if _toast.text == msg:
			_toast.text = "")


# ---------------------------------------------------------------- documents

func cur_graph() -> Dictionary:
	if doc.is_empty():
		return {}
	var g := Model.find_graph(doc.bp, int(doc.graph_id))
	if g.is_empty() and not doc.bp.graphs.is_empty():
		g = doc.bp.graphs[0]
		doc.graph_id = int(g.id)
	return g


func _find_doc(path: String) -> Dictionary:
	for d in docs:
		if d.path == path:
			return d
	return {}


func open_schematic(path: String) -> bool:
	var d := _find_doc(path)
	if d.is_empty():
		var text := FileAccess.get_file_as_string(path)
		var bp := Model.parse_source(text)
		if bp.is_empty():
			toast("%s %s" % [path.get_file(), Model.unreadable_reason(text)])
			return false
		d = {"path": path}
		_load_into(d, bp, text)
		docs.append(d)
	else:
		_drift_check(d)
	doc = d
	_sel = {"kind": "class"}
	_refresh_all()
	return true


## Fills a document from its file's text (opening it, or Reload From Disk), and remembers what was read.
func _load_into(d: Dictionary, bp: Dictionary, text: String) -> void:
	var cut := Model.graph_block_at(text)
	d.merge({"bp": bp, "graph_id": int(bp.graphs[0].id) if not bp.graphs.is_empty() else 0, "dirty": false,
		"errors": [], "code": text.substr(0, cut) if cut > 0 else "", "line_map": {}, "node_lines": {}}, true)
	_check(d)
	var on_disk := _file_maps(bp, String(d.code))
	d["saved_lines"] = on_disk.lines
	d["saved_map"] = on_disk.map
	d["saved_pins"] = on_disk.pins
	d["saved_blocks"] = on_disk.blocks
	_disk_remember(d, text)
	# Code edited while the file was closed: its code is not the code its graph data says was generated. (A file
	# whose code is what this version generates is fine whatever the fingerprint says.)
	if Model.code_edited(text) and Model.code_part(text) != Model.normalize_code(Model.file_code(String(d.preview), bp)):
		var expected := Model.stored_code_hash(text)
		if expected == d.disk_code:
			# A legacy hash can match after literal spaces were deleted.
			expected = Model.code_hash(Model.file_code(String(d.preview), bp))
		d["disk_code"] = expected
		d["drift_at_open"] = true
		_drift_check(d, true)
	# A file saved when the Data Table class was still called DataTable: its graph is read with the present name, its
	# code on disk still has the old one and no longer loads. Saving writes the new name.
	elif Model.names_old_table_class(String(d.code)) and not Model.names_old_table_class(String(d.preview)):
		d.dirty = true
		toast("%s names the Data Table class the old way (%s). Save it to write the new name, %s." % [String(d.path).get_file(), Model.TABLE_CLASS_WAS, Model.TABLE_CLASS])


func _on_doc_tab(i: int) -> void:
	if _suppress_tabs or i < 0 or i >= docs.size():
		return
	doc = docs[i]
	_drift_check(doc)
	_sel = {"kind": "class"}
	_refresh_all()


func _close_doc(i: int) -> void:
	if i < 0 or i >= docs.size():
		return
	var d: Dictionary = docs[i]
	if d.dirty:
		# Unsaved graph changes, and the file changed outside too: saving would overwrite that, so ask.
		if not _may_write(d):
			_ask_close(d)
			return
		compile_doc(d, true, true)
		if d.dirty:
			return
	_remove_doc(d)


func _remove_doc(d: Dictionary) -> void:
	var i := docs.find(d)
	if i < 0:
		return
	docs.remove_at(i)
	if doc == d or doc.is_empty():
		doc = docs[mini(i, docs.size() - 1)] if not docs.is_empty() else {}
	_refresh_all()


## Closing a document with unsaved graph changes whose file was changed outside Schematic. Enter keeps it open, so
## nothing is lost by default; the file is overwritten only when that is picked.
func _ask_close(d: Dictionary) -> void:
	if _close_dialog and is_instance_valid(_close_dialog):
		_close_dialog.queue_free()
	var dlg := AcceptDialog.new()
	_close_dialog = dlg
	dlg.title = "Close %s" % String(d.path).get_file()
	var outside := "its code was changed outside Schematic" if d.drift == "code" else "the file was replaced outside Schematic"
	dlg.dialog_text = "%s has unsaved changes in the graph, and %s since it was opened.\n\nSaving now would overwrite the file on disk, losing the outside changes. Closing without saving keeps the file as it is on disk and loses the graph changes." % [String(d.path).get_file(), outside]
	dlg.ok_button_text = "Keep Open"
	dlg.add_button("Close Without Saving", false, "discard")
	dlg.add_button("Overwrite File and Close", false, "overwrite")
	dlg.custom_action.connect(func(action: StringName):
		dlg.hide()
		if action == &"overwrite":
			drift_keep(d)
			compile_doc(d, true, true)
			if d.dirty:
				return
		_remove_doc(d))
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	_dialog_host().add_child(dlg)
	dlg.popup_centered(Vector2i(W.si(560), 0))
	dlg.get_ok_button().grab_focus.call_deferred()


func _open_dialog() -> void:
	var items := []
	_scan("res://", items)
	if items.is_empty():
		toast("This project has no Schematic scripts yet.")
		return
	W.popup_search(_doc_tabs, items, func(path): open_schematic(path), "Open Schematic")


func _scan(dir_path: String, out: Array) -> void:
	var files := []
	ProjectFiles.find(dir_path, ["gd"], files)
	for path: String in files:
		if Model.is_schematic_file(path):
			out.append({"label": path.trim_prefix("res://"), "value": path, "icon": W.icon("GDScript")})


## Converts a hand-written GDScript to a Schematic. Returns {ok, source, text, report, errors} without
## touching the file; convert_script_apply() writes it.
func convert_script(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	if Model.is_schematic_source(source):
		return {"ok": false, "errors": ["%s is already a Schematic" % path.get_file()]}
	R.invalidate_scripts()
	var imp := Importer.new()
	var out := imp.convert(source, {"path": path})
	var probe := {"bp": out.bp, "errors": [], "line_map": {}, "node_lines": {}, "preview": ""}
	var errs := []
	if not _check_valid(probe):
		for e in probe.errors:
			if not e.w:
				errs.append(String(e.m))
	return {"ok": errs.is_empty(), "source": source, "text": Model.build_source(String(probe.preview), out.bp), "report": out.report, "errors": errs}


## Writes a conversion made by convert_script(): the original is kept beside it as <name>.gd.orig.
func convert_script_apply(path: String, result: Dictionary) -> bool:
	if not bool(result.get("ok", false)):
		return false
	# A Schematic still open for this path (its file was replaced by plain GDScript outside the editor): the
	# conversion replaces the document, so it must not hold graph changes that would be lost.
	var open_doc := _find_doc(path)
	if not open_doc.is_empty():
		if open_doc.dirty:
			toast("%s is open in Schematic with unsaved changes: save or close it before converting the file." % path.get_file())
			return false
		_remove_doc(open_doc)
	if FileAccess.get_file_as_string(path) != String(result.source):
		toast("%s changed since it was read for converting: convert it again." % path.get_file())
		return false
	# The original is kept before the file is replaced. An .orig left by converting an earlier version of this
	# script is not this script: it is moved aside, never overwritten and never taken for the backup.
	var keep_path := path + ".orig"
	var older := ""
	if FileAccess.file_exists(keep_path) and FileAccess.get_file_as_string(keep_path) != String(result.source):
		var n := 1
		while FileAccess.file_exists("%s.%d" % [keep_path, n]):
			n += 1
		older = "%s.%d" % [keep_path.get_file(), n]
	var problem := Model.keep_original(path, String(result.source))
	if problem == "":
		problem = Model.write_text(path, String(result.text))
	if problem != "":
		toast("Not converted: %s." % problem)
		return false
	if older != "":
		toast("%s held an older version of this script: that one is now %s." % [keep_path.get_file(), older])
	var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as GDScript
	if scr:
		scr.source_code = String(result.text)
		scr.reload(true)
	EditorInterface.get_resource_filesystem().update_file(path)
	R.invalidate_libraries()
	return open_schematic(path)


func convert_script_dialog(path: String) -> void:
	var result := convert_script(path)
	var dlg := AcceptDialog.new() if not bool(result.ok) else ConfirmationDialog.new()
	dlg.title = "Convert to Schematic"
	var lines := PackedStringArray()
	if not bool(result.ok):
		lines.append("%s could not be converted and was left as it is:" % path.get_file())
		for e in result.errors:
			lines.append("  " + String(e))
	else:
		var rep: Dictionary = result.report
		lines.append("%s: %d of %d lines become nodes, %d are carried over as GDScript code nodes." % [path.get_file(), rep.as_nodes, rep.lines, rep.as_code])
		lines.append("The file is replaced by the Schematic; the original is kept as %s.orig." % path.get_file())
		# what the person converting should know about: lines that stay code, declarations kept as written.
		# (How each thing was turned into nodes is in the full report the command-line tool prints.)
		var worth: Array = rep.notes.filter(func(note): return not Importer.is_detail(String(note)))
		if not worth.is_empty():
			lines.append("")
			for note in worth.slice(0, 14):
				lines.append("- " + String(note).left(150))
			if worth.size() > 14:
				lines.append("... and %d more notes" % (worth.size() - 14))
		dlg.ok_button_text = "Convert"
		dlg.confirmed.connect(func():
			if convert_script_apply(path, result):
				_show_screen())
	dlg.dialog_text = "\n".join(lines)
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	_dialog_host().add_child(dlg)
	dlg.popup_centered(Vector2i(W.si(720), 0))


## New Schematic: first offer the starter schematics (ready-wired graphs) next to an empty one. When attaching
## to a node only the starters made for that kind of node are offered, and none means straight to the file dialog.
func new_schematic_dialog(attach: Node = null) -> void:
	var fits := Starters.fitting(attach.get_class() if attach else "")
	if attach != null and fits.is_empty():
		_new_schematic_file(attach.get_class(), attach)
		return
	var items := [{"label": "Empty Schematic" + ((" (%s)" % attach.get_class()) if attach else " (pick a parent class)"), "value": "",
		"icon": W.icon("GraphEdit"), "tip": "A schematic with only the Ready and Process events."}]
	for s in fits:
		items.append({"label": String(s.name), "value": String(s.id), "icon": W.class_icon(String(s.parent)),
			"tip": "%s
Parent class: %s" % [s.desc, s.parent]})
	W.popup_search(_dialog_host(), items, func(id: String):
		if id != "":
			_new_schematic_file(attach.get_class() if attach else String(Starters.find(id).parent), attach, id)
		elif attach:
			_new_schematic_file(attach.get_class(), attach)
		else:
			_pick_parent_class(), "New Schematic: start from", true)


func _pick_parent_class() -> void:
	if EditorInterface.has_method("popup_create_dialog"):
		EditorInterface.popup_create_dialog(func(cls: String):
			if cls != "":
				_new_schematic_file.call_deferred(cls, null), "Object", "Node", "Pick Parent Class")
	else:
		var items := []
		for t in W.all_types():
			if T.is_object(t):
				items.append({"label": t, "value": t, "icon": W.class_icon(t)})
		W.popup_search(_doc_tabs, items, func(cls): _new_schematic_file(cls, null), "Pick Parent Class")


func _new_schematic_file(parent: String, attach: Node, starter := "") -> void:
	if parent.begins_with("res://"):
		var scr := load(parent) as Script
		parent = String(scr.get_global_name()) if scr and scr.get_global_name() != &"" else (String(scr.get_instance_base_type()) if scr else "Node")
	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.add_filter("*.gd", "Schematic (GDScript)")
	fd.title = "Save Schematic Class (parent: %s)" % parent
	var base := "SC_" + (String(attach.name) if attach else (String(Starters.find(starter).file) if starter != "" else parent))
	var dir := "res://"
	if starter != "" and bool(Starters.find(starter).get("plain_name", false)):
		# a flow node is known to FlowNodes by its file name, and lives in a folder FlowNodes is told about
		base = String(Starters.find(starter).file)
		DirAccess.make_dir_recursive_absolute(Kits.FLOW_DIR)
		dir = Kits.FLOW_DIR
	if attach and attach.owner and attach.owner.scene_file_path != "":
		dir = attach.owner.scene_file_path.get_base_dir()
	elif attach and attach.scene_file_path != "":
		dir = attach.scene_file_path.get_base_dir()
	fd.current_path = dir.path_join(T.ident(base) + ".gd")
	fd.file_selected.connect(func(path: String):
		var cn := T.ident(path.get_file().get_basename())
		if T.class_known(cn) or not cn.is_valid_identifier():
			cn = ""
		var bp := Model.new_schematic(parent, cn) if starter == "" else Starters.build(starter, cn)
		bp.parent = parent   # an attached node may be a subclass of the starter's parent
		var d := {"path": path, "bp": bp, "graph_id": int(bp.graphs[0].id), "dirty": true, "errors": [], "code": "", "line_map": {}, "node_lines": {}}
		docs.append(d)
		doc = d
		compile_doc(d, true)
		if starter in ["parley_action", "parley_fact"]:
			var stored := Kits.parley_register(path, starter.trim_prefix("parley_"))
			if stored != "":
				toast("%s: %s." % [path.get_file(), stored])
		if starter == "flow_node":
			var did := Kits.flow_setup(path.get_base_dir())
			if not did.is_empty():
				toast("FlowNodes bridge set up: %s. Restart the project's editor if the node is not in the flow graph menu yet." % ", ".join(did))
		if attach and is_instance_valid(attach):
			attach.set_script(load(path))
			EditorInterface.mark_scene_as_unsaved()
		_sel = {"kind": "class"}
		_refresh_all()
		_show_screen())
	fd.visibility_changed.connect(func():
		if not fd.visible:
			fd.queue_free())
	_dialog_host().add_child(fd)
	fd.popup_file_dialog()


# ---------------------------------------------------------------- editing / undo

## Runs `fn` (which edits doc.bp) as one undoable transaction.
func mutate(action: String, fn: Callable, rebuild := true) -> void:
	if doc.is_empty():
		return
	var before: Dictionary = doc.bp.duplicate(true)
	fn.call()
	var after: Dictionary = doc.bp.duplicate(true)
	doc.dirty = true
	var ur := plugin.get_undo_redo() if plugin else null
	if ur:
		ur.create_action("Schematic: " + action, UndoRedo.MERGE_DISABLE, self)
		ur.add_do_method(self, "_restore", doc.path, after)
		ur.add_undo_method(self, "_restore", doc.path, before)
		ur.commit_action(false)
	_check(doc)
	if rebuild:
		_refresh_graph()
		_refresh_members()
		_refresh_graph_tabs()
	_refresh_status()
	_update_code()


func _restore(path: String, snapshot: Dictionary) -> void:
	var d := _find_doc(path)
	if d.is_empty():
		return
	d.bp = snapshot.duplicate(true)
	d.dirty = true
	_check(d)
	if d == doc:
		_refresh_all()


func set_pin_default(_nid: int, _pin: String, _lit: String) -> void:
	pass


# ---------------------------------------------------------------- compile

## Compiles without saving: fills doc.errors / line maps and the code preview.
func _check(d: Dictionary) -> bool:
	R.invalidate_scripts()
	var c := Compiler.new()
	var code := c.compile(d.bp)
	d.errors = c.errors.duplicate(true)
	d.line_map = c.line_map
	d.node_lines = c.node_lines
	d["pins"] = c.pin_exprs
	d["blocks"] = c.block_lines
	d["preview"] = code
	d["link_src"] = [c, code]   # the line <-> node lookup is built from these the first time it is needed
	d["link"] = null
	for e in d.errors:
		if not e.w:
			return false
	return true


## Compiles and test-loads a document. A local an imported script declared with ":=" is written that way
## again; where GDScript can no longer infer its type (the graph was rewired since), that local goes back to
## the type the graph knows and the document is compiled once more.
func _check_valid(d: Dictionary) -> bool:
	for attempt in 8:
		if not _check(d):
			return false
		if _validate(d, String(d.preview)):
			return true
		if Compiler.drop_inferred(d.bp, String(d.preview), d.get("bad_lines", [])) == 0:
			return false
	return false


func _validate(d: Dictionary, code: String) -> bool:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			lines[i] = "#"
	var gs := GDScript.new()
	gs.source_code = "\n".join(lines)
	var logger: Object = null
	if ClassDB.class_exists("Logger"):
		logger = load("res://addons/schematic/editor/sc_logger.gd").new()
		OS.add_logger(logger)
	var err := gs.reload()
	if logger:
		OS.remove_logger(logger)
	d["bad_lines"] = []
	if err == OK:
		return true
	var found := false
	if logger:
		for it in logger.items:
			var ln := int(it.line)
			d.bad_lines.append(ln)
			var where: Array = [0, 0]
			for back in 12:
				if d.line_map.has(ln - back):
					where = d.line_map[ln - back]
					break
			d.errors.append({"g": where[0], "n": where[1], "m": "%s (generated line %d)" % [String(it.msg).trim_prefix("Parse Error: "), ln], "w": false})
			found = true
	if not found:
		d.errors.append({"g": 0, "n": 0, "m": "GDScript rejected the generated code (see the Output panel).", "w": false})
	return false


## Compiles a document, and with `save` writes its file. The file is not written when it was changed outside
## Schematic and the person has not chosen to keep the graph (see _may_write()); then false is returned and a toast
## says why. `side_effect` is for writes the person did not ask for as such (closing, running, a breakpoint).
func compile_doc(d: Dictionary, save: bool, side_effect := false) -> bool:
	if d.is_empty():
		return false
	var refused := save and not _may_write(d)
	var ok := _check_valid(d)
	if ok and not refused:
		d.code = d.preview
		d["saved_lines"] = d.node_lines.duplicate()
		d["saved_map"] = d.line_map.duplicate()
		d["saved_pins"] = d.get("pins", {})
		d["saved_blocks"] = d.get("blocks", [])
	if refused:
		_tell_not_written([String(d.path)], side_effect)
	elif save:
		var code: String = d.code
		if code == "":
			code = "%s\nextends %s\n" % [Model.MARKER + " v%d (not compiled yet - fix the errors in the Schematic editor)" % Model.VERSION, R.self_class(d.bp)]
		var src := Model.build_source(code, d.bp)
		if not _write_schematic(String(d.path), src):
			return false
		d.dirty = false
		_disk_remember(d, src)
		R.invalidate_libraries()
		if String(d.bp.get("library", "")) == "macro" and not _recompiling:
			_recompiling = true
			recompile_skipped = []
			var users := _recompile_users(String(d.path))
			_recompiling = false
			if users > 0 or not recompile_skipped.is_empty():
				var msg := "Recompiled %d schematic%s using this macro library." % [users, "" if users == 1 else "s"]
				if not recompile_skipped.is_empty():
					msg += " Not rewritten, because %s changed outside Schematic: %s." % ["it was" if recompile_skipped.size() == 1 else "they were",
						", ".join(recompile_skipped.map(func(p): return String(p).get_file()))]
					print("Schematic: ", msg, " (", ", ".join(recompile_skipped), ")")
				toast(msg)
	if d == doc:
		_refresh_graph()
		_refresh_status()
		_refresh_doc_tabs()
		_update_code()
	return ok and not refused


## Writes a Schematic's whole text and tells Godot the script changed. False (with a toast) when it can't be written.
func _write_schematic(path: String, src: String) -> bool:
	var problem := Model.write_text(path, src)
	if problem != "":
		toast("Not saved: %s." % problem)
		push_error("Schematic: " + problem)
		return false
	var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as GDScript
	if scr:
		scr.source_code = src
		scr.reload(true)
	EditorInterface.get_resource_filesystem().update_file(path)
	return true


func save_all() -> void:
	var skipped := []
	for d in docs:
		if d.dirty:
			if not _may_write(d):
				skipped.append(String(d.path))
				continue
			compile_doc(d, true, true)
	if not skipped.is_empty():
		_tell_not_written(skipped, true)


func has_unsaved() -> bool:
	for d in docs:
		if d.dirty:
			return true
	return false


## Open documents with unsaved graph changes whose file was also changed outside Schematic (they are not saved by
## Save All, so their graph changes are lost when Godot closes).
func unsaved_and_changed_outside() -> Array:
	var out := []
	for d in docs:
		if d.dirty and String(d.get("drift", "")) in ["code", "replaced"] and not _keep_chosen(d):
			out.append(String(d.path))
	return out


# ---------------------------------------------------------------- changes made outside Schematic
# A Schematic's file can change while it is open here: its GDScript edited by hand (in Godot's script editor or any
# other), a git pull or checkout, another tool. Each document remembers what this editor last read from or wrote to
# its file: the fingerprint of the code part, of the graph part, and the file's time (a cheap first look only).
# Comparing the file with that gives its state, doc.drift:
#   ""          in sync: nobody else wrote the file since; saving is safe
#   "code"      the code part changed, the graph part did not: an edit to the code the graph does not know about
#   "replaced"  the graph part changed: the whole file was replaced (its graph on disk may be newer)
#   "missing"   the file was deleted or moved; saving writes it again
# The file is looked at when Godot's file system reports changes, when a script is saved in Godot, when the
# Schematic screen is shown or the editor gets the focus back, on switching documents, and always just before
# writing. A file that is not in sync is never overwritten until the person chooses so in the bar above the graph.

const DRIFT_RECENT := 2   # seconds: a file changed this recently is read even when its time looks unchanged


## Remembers `text` as what this editor last read from or wrote to the document's file: in sync from here on.
func _disk_remember(d: Dictionary, text: String) -> void:
	d["disk_code"] = Model.code_hash(Model.code_part(text))
	d["disk_graph"] = Model.graph_part(text).md5_text()
	d["disk_now"] = [d.disk_code, d.disk_graph]
	d["disk_time"] = FileAccess.get_modified_time(d.path) if FileAccess.file_exists(d.path) else 0
	d["drift"] = ""
	d["drift_keep"] = ""
	d["drift_at_open"] = false
	if d == doc:
		_refresh_drift()


## Looks at a document's file and returns its state (see above). Unless `read`, a file whose time has not changed
## since the last look (and is not very recent) is not read again.
func _drift_check(d: Dictionary, read := false) -> String:
	if d.is_empty() or not d.has("disk_graph"):
		return ""   # a new schematic, never written yet: nothing to compare with
	var path := String(d.path)
	var state := ""
	if not FileAccess.file_exists(path):
		state = "missing"
	else:
		var time := FileAccess.get_modified_time(path)
		if not read and d.drift != "missing" and time == int(d.disk_time) and int(Time.get_unix_time_from_system()) - time > DRIFT_RECENT:
			return String(d.drift)
		d.disk_time = time
		var text := FileAccess.get_file_as_string(path)
		var now := [Model.code_hash(Model.code_part(text)), Model.graph_part(text).md5_text()]
		d.disk_now = now
		if now[1] != d.disk_graph:
			state = "replaced"
		elif now[0] != d.disk_code:
			state = "code"
	if state != String(d.drift):
		d.drift = state
		if d == doc:
			_refresh_drift()
		_refresh_doc_tabs()
	return state


## Looks at every open document's file (cheap: the file is read only when its time changed).
func check_drift_all() -> void:
	for d in docs:
		_drift_check(d)


## A script was saved in Godot (its script editor): look at that file now.
func check_drift_path(path: String) -> void:
	var d := _find_doc(path)
	if not d.is_empty():
		_drift_check(d, true)


## The person chose, for the file as it is on disk now, that the graph wins (Keep Graph / Keep Mine).
func _keep_chosen(d: Dictionary) -> bool:
	return String(d.get("drift_keep", "")) != "" and String(d.get("drift_keep", "")) == str(d.get("disk_now", []))


## Whether this editor may write the document's file now: it is in sync, gone, or the person chose to overwrite
## exactly what is there. Always reads the file.
func _may_write(d: Dictionary) -> bool:
	var state := _drift_check(d, true)
	return state == "" or state == "missing" or _keep_chosen(d)


## Keep Graph / Keep Mine: the next save overwrites the file as it is on disk now with what the graph says. (If the
## file changes again before that save, the person is asked again.)
func drift_keep(d: Dictionary) -> void:
	if _drift_check(d, true) in ["", "missing"]:
		return
	d.drift_keep = str(d.disk_now)
	d.dirty = true
	if d == doc:
		_refresh_drift()
		_refresh_status()
	_refresh_doc_tabs()


## Reload From Disk: the graph in memory (and any unsaved change to it) is replaced by the file's.
func drift_reload(d: Dictionary) -> bool:
	var text := FileAccess.get_file_as_string(String(d.path))
	var bp := Model.parse_source(text)
	if bp.is_empty():
		toast("%s on disk %s. There is no graph to load." % [String(d.path).get_file(), Model.unreadable_reason(text)])
		return false
	_load_into(d, bp, text)
	if d == doc:
		_sel = {"kind": "class"}
		_refresh_all()
	toast("%s reloaded from disk." % String(d.path).get_file())
	return true


## The lines that differ between the code on disk and the code the graph compiles to now:
## [{"op": "-" (only on disk) or "+" (only in the graph's code), "line": line number on its side, "text"}].
func drift_diff(d: Dictionary) -> Array:
	var disk := Model.code_part(FileAccess.get_file_as_string(String(d.path))).split("\n")
	var mine := Model.normalize_code(String(d.get("preview", ""))).split("\n")
	var a0 := 0
	while a0 < disk.size() and a0 < mine.size() and disk[a0] == mine[a0]:
		a0 += 1
	var a1 := disk.size()
	var b1 := mine.size()
	while a1 > a0 and b1 > a0 and disk[a1 - 1] == mine[b1 - 1]:
		a1 -= 1
		b1 -= 1
	var out := []
	var n := a1 - a0
	var m := b1 - a0
	if n * m > 250000:
		# too long a stretch to match line by line here: show all of it
		for i in range(a0, a1):
			out.append({"op": "-", "line": i + 1, "text": disk[i]})
		for j in range(a0, b1):
			out.append({"op": "+", "line": j + 1, "text": mine[j]})
		return out
	# longest common subsequence of the differing stretch
	var lcs := PackedInt32Array()
	lcs.resize((n + 1) * (m + 1))
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if disk[a0 + i] == mine[a0 + j]:
				lcs[i * (m + 1) + j] = lcs[(i + 1) * (m + 1) + j + 1] + 1
			else:
				lcs[i * (m + 1) + j] = maxi(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
	var i := 0
	var j := 0
	while i < n or j < m:
		if i < n and j < m and disk[a0 + i] == mine[a0 + j]:
			i += 1
			j += 1
		elif i < n and (j == m or lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1]):
			out.append({"op": "-", "line": a0 + i + 1, "text": disk[a0 + i]})
			i += 1
		else:
			out.append({"op": "+", "line": a0 + j + 1, "text": mine[a0 + j]})
			j += 1
	return out


## Show Changes: a read-only list of the differing lines. With `focus` (a line of the file on disk) the entry of that
## line, or the nearest one, is selected and scrolled to.
func show_drift_changes(d: Dictionary, focus := 0) -> void:
	if _diff_dialog and is_instance_valid(_diff_dialog):
		_diff_dialog.queue_free()
	var dlg := AcceptDialog.new()
	_diff_dialog = dlg
	dlg.title = "Changes outside Schematic: %s" % String(d.path).get_file()
	var box := VBoxContainer.new()
	dlg.add_child(box)
	var head := Label.new()
	head.text = "-  a line in the file on disk that the graph does not make\n+  a line the graph makes that is not in the file on disk"
	box.add_child(head)
	var view := CodeEdit.new()
	view.name = "Diff"
	view.editable = false
	view.custom_minimum_size = W.sv(Vector2(760, 420))
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(view)
	var diff := drift_diff(d)
	var lines := PackedStringArray()
	for e in diff:
		lines.append("%s %5d | %s" % [e.op, int(e.line), String(e.text)])
	if diff.is_empty():
		lines.append("(the code on disk is the code the graph makes)")
	view.text = "\n".join(lines)
	for k in diff.size():
		view.set_line_background_color(k, Color(0.8, 0.25, 0.2, 0.22) if diff[k].op == "-" else Color(0.25, 0.75, 0.3, 0.2))
	var at := -1
	if focus > 0:
		var best := 1 << 30
		for k in diff.size():
			var dist := absi(int(diff[k].line) - focus) * 2 + (0 if diff[k].op == "-" else 1)
			if dist < best:
				best = dist
				at = k
		head.text += "\nLine %d of the file is selected%s." % [focus, "" if at >= 0 and int(diff[at].line) == focus and diff[at].op == "-" else " (it is not itself a changed line: the nearest change is)"]
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	_dialog_host().add_child(dlg)
	dlg.popup_centered()
	if at >= 0:
		view.set_caret_line(at)
		view.select(at, 0, at, view.get_line(at).length())
		view.center_viewport_to_caret.call_deferred()


# ---------------------------------------------------------------- re-import code edited by hand
# Re-import Code (the bar's button; File > Re-import Code From File... for when the bar was dismissed with Keep Graph)
# brings code changed outside Schematic into the graph. SCSync.reimport rebuilds only the functions and events whose
# code differs from the graph's and accepts the result only if it compiles to the file's code.
#   preview  a dry run on the file as it is on disk at that moment, shown in a window: what happens to each function,
#            what the next save will write differently (dropped comments, lines in Schematic's style), or why it
#            can't be done (then nothing changes and the bar stays).
#   apply    the file is read again; if it changed since the preview, the preview is shown again for the new text
#            (a preview is never applied to a file it did not read). Otherwise one undo step "Re-import Code" puts
#            the new graph in. The document then counts as in sync with the text the re-import read (so the bar goes,
#            and a later outside change to the file is caught as a new one) and has unsaved changes: the graph data
#            on disk is the old one until a save, which writes the graph's code (the file's, apart from what the
#            preview said the save rewrites).
#   undo     the old graph comes back with the old record of what is on disk, so the bar comes back (the file still
#            holds the edit); redo applies it again. If the file was written in between (a save), only the graph
#            changes back: it is then an ordinary unsaved change.
#   debug    breakpoints and pin watches on nodes the re-import replaced are removed (they could name other nodes now)
#            and are not brought back by undo.
# Unsaved graph changes: before the re-import the file's code is merged with the graph's code block by block
# (functions, events, members; see _reimport_input): a block the file did not change since the graph was last saved
# is taken from the graph as it is now, a block the file changed is the file's. Nothing is merged inside a block.

## True when the document's file has code changes the graph does not have, which Re-import Code can bring in
## (the file's graph part is the one this editor knows). Reads the file.
func can_reimport(d: Dictionary) -> bool:
	if d.is_empty() or not d.has("disk_graph"):
		return false
	return _drift_check(d, true) == "code"


## Re-import Code: shows what it would do (or why it can't), with Re-import and Cancel.
func reimport_dialog(d: Dictionary) -> void:
	if d.is_empty():
		return
	if not can_reimport(d):
		toast("Nothing to re-import: %s's code on disk is not changed from what the graph knows." % String(d.path).get_file())
		return
	_show_reimport(d, reimport_preview(d))


## The dry run on the file as it is on disk now: {path, text, code (what is handed to the re-import), both, graph_only,
## result: {ok, bp, report}}.
func reimport_preview(d: Dictionary) -> Dictionary:
	var text := FileAccess.get_file_as_string(String(d.path))
	var inp := _reimport_input(d, text)
	var r: Dictionary = Sync.new().reimport(d.bp, String(inp.code), {"dry": true, "path": String(d.path)})
	reimport_last = {"path": String(d.path), "text": text, "code": inp.code, "both": inp.both, "graph_only": inp.graph_only, "result": r}
	return reimport_last


## The code to re-import from the file's `text`: its code part, merged with the graph's code when the graph has unsaved
## changes. {code, both: [names changed in the graph and in the file: the file's taken], graph_only: [names changed only
## in the graph: kept as the graph has them]}.
func _reimport_input(d: Dictionary, text: String) -> Dictionary:
	var out := {"code": Model.code_part(text), "both": [], "graph_only": []}
	var saved := Model.parse_source(text)
	if saved.is_empty():
		return out
	var base := Model.normalize_code(Compiler.new().compile(saved.duplicate(true)))   # the code the saved graph makes
	var mine := Model.normalize_code(Compiler.new().compile(d.bp.duplicate(true)))     # the code the graph makes now
	if base == mine:
		return out   # no unsaved graph changes: the file as it is
	var sync := Sync.new()
	var fb := sync.split(String(out.code))
	var bk := _block_texts(sync.split(base))
	var gb := sync.split(mine)
	var gk := _block_texts(gb)
	var fk := _block_texts(fb)
	if bk.is_empty() or gk.is_empty() or fk.is_empty():
		return out   # a name twice: not merged
	var parts := []   # [key, text]
	for b in fb:
		var k := _block_key(b)
		if k != "" and bk.has(k) and bk[k] == String(b.text):
			# not changed in the file: the graph's (gone if the graph no longer has it)
			if gk.get(k, "") != bk[k] and _block_shown(k):
				out.graph_only.append(k.get_slice(":", 1))
			if gk.has(k):
				parts.append([k, gk[k]])
			continue
		parts.append([k, String(b.text)])
		if k != "" and bk.has(k) and gk.get(k, "") != bk[k] and _block_shown(k):
			out.both.append(k.get_slice(":", 1))
	# added in the graph since its last save: after the block it follows in the graph's code
	var prev := ""
	for b in gb:
		var k := _block_key(b)
		if k == "":
			continue
		if not bk.has(k) and not fk.has(k):
			var at := parts.size()
			for i in parts.size():
				if parts[i][0] == prev and prev != "":
					at = i + 1
			parts.insert(at, [k, "\n" + String(b.text)])
			if _block_shown(k):
				out.graph_only.append(k.get_slice(":", 1))
		prev = k
	out.code = "\n".join(parts.map(func(p): return String(p[1])))
	return out


## kind:name of a block the merge goes by, or "" (blank lines, comments, regions, stray lines).
func _block_key(b: Dictionary) -> String:
	if String(b.kind) in ["blank", "comment", "region", "other", "graph"]:
		return ""
	return "%s:%s" % [b.kind, b.name]


## Whether a merged block is worth naming in the preview (a function or event, a variable or signal of the person's).
func _block_shown(key: String) -> bool:
	var kind := key.get_slice(":", 0)
	var nm := key.get_slice(":", 1)
	return kind in ["func", "var", "signal", "enum"] and not nm.begins_with("__")


## {kind:name: text} of a split's blocks; {} when a key is there twice.
func _block_texts(blocks: Array) -> Dictionary:
	var out := {}
	for b in blocks:
		var k := _block_key(b)
		if k == "":
			continue
		if out.has(k):
			return {}
		out[k] = String(b.text)
	return out


const REIMPORT_KIND := {"function": "Function", "event": "Event", "custom": "Custom event", "lambda": "Inline function"}
const REIMPORT_DECL := {"var": "Variable", "signal": "Signal", "enum": "Enum", "class": "Class line", "extends": "Parent class",
	"class_name": "Class name", "tool": "Run in editor (@tool)", "carried": "Code carried over as written", "extra_code": "Code carried over as written"}


## The words of the preview window, as BBCode: [text, line to show (0 if none)].
func reimport_words(d: Dictionary, pv: Dictionary) -> Array:
	var r: Dictionary = pv.result
	var rep: Dictionary = r.report
	var file := String(d.path).get_file()
	var src := String(pv.code).split("\n")
	var line_text := func(n: int) -> String:
		return String(src[n - 1]).strip_edges().left(90) if n >= 1 and n <= src.size() else ""
	var esc := func(s: String) -> String:
		return s.replace("[", "[lb]")
	var warn := "[color=#ffc552]"
	var dim := "[color=#ffffff99]"
	var t := PackedStringArray()
	var show_line := 0
	if not bool(r.ok):
		t.append("[b]The code changed in %s can't be brought into the graph as it is.[/b] Nothing was changed." % file)
		t.append("")
		for x in rep.refused:
			var n := int(x.get("line", 0))
			if n > 0 and show_line == 0:
				show_line = n
			t.append("%s[b]%s[/b]  %s[/color]" % [warn, ("Line %d:" % n) if n > 0 else "Problem:", esc.call(String(x.reason))])
		if not rep.first_difference.is_empty():
			var f0: Dictionary = rep.first_difference[0]
			if show_line == 0:
				show_line = int(f0.get("line", 0))
			t.append("")
			t.append("First difference, at line %d%s:" % [int(f0.get("line", 0)), (" (in %s)" % f0.name) if String(f0.get("name", "")) != "" else ""])
			t.append("    in the file:          [code]%s[/code]" % esc.call(String(f0.get("file", "")).strip_edges()))
			t.append("    the graph would write: [code]%s[/code]" % esc.call(String(f0.get("graph", "")).strip_edges()))
		t.append("")
		t.append("%sFix the code (or undo the edit) and press Re-import Code again, or choose Keep Graph to keep the graph as it is.[/color]" % dim)
		return ["\n".join(t), show_line]
	t.append("Bring the code changed in [b]%s[/b] into the graph. Only what changed is rebuilt, as one step you can undo." % file)
	t.append("")
	t.append("[b]Functions and events[/b]")
	var kept := 0
	var listed := 0
	for x in rep.functions:
		var act := String(x.action)
		if act == "kept":
			kept += 1
			continue
		var what: String = REIMPORT_KIND.get(String(x.get("kind", "function")), "Function")
		var nm := String(x.name)
		var row := ""
		match act:
			"rebuilt": row = "rebuilt from the code"
			"added": row = "added (new in the file)"
			"removed": row = "removed (no longer in the file)"
			"renamed": row = "renamed from %s" % String(x.get("old_name", ""))
			"renamed+rebuilt": row = "renamed from %s, and rebuilt from the code" % String(x.get("old_name", ""))
			_: row = act
		listed += 1
		if listed <= 14:
			t.append("    %s [b]%s[/b]: %s" % [what, esc.call(nm), row])
	if listed > 14:
		t.append("    ... and %d more" % (listed - 14))
	if listed == 0:
		t.append("    No function or event changes.")
	if kept > 0:
		t.append("    %s%s[/color]" % [dim, "1 other function or event is unchanged." if kept == 1 else "%d other functions and events are unchanged." % kept])
	if not rep.declarations.is_empty():
		t.append("")
		t.append("[b]Declarations[/b]")
		for x in rep.declarations.slice(0, 12):
			var k := "carried" if bool(x.get("carried", false)) else String(x.get("kind", ""))
			var a := String(x.get("action", "rebuilt"))
			var said := {"rebuilt": "changed", "added": "added", "removed": "removed"}.get(a, a) if a != "renamed" else "renamed from %s" % String(x.get("old_name", ""))
			t.append("    %s [b]%s[/b]: %s" % [REIMPORT_DECL.get(k, k.capitalize()), esc.call(String(x.get("name", ""))), said])
		if rep.declarations.size() > 12:
			t.append("    ... and %d more" % (rep.declarations.size() - 12))
	if not pv.graph_only.is_empty() or not pv.both.is_empty():
		t.append("")
		t.append("[b]Unsaved changes in the graph[/b]")
		if not pv.graph_only.is_empty():
			t.append("    Kept as they are in the graph (not changed in the file): %s." % esc.call(", ".join(pv.graph_only)))
		if not pv.both.is_empty():
			t.append("    %sChanged in both the graph and the file, so taken from the file (the graph's changes to these are lost): %s.[/color]" % [warn, esc.call(", ".join(pv.both))])
	var notes := PackedStringArray()
	if int(rep.comments_dropped) > 0:
		var n := int(rep.comments_dropped)
		notes.append("%s[b]%d hand-written comment%s %s not kept yet:[/b] %s from the file at the next save.[/color]" % [warn, n, "" if n == 1 else "s", "is" if n == 1 else "are", "it disappears" if n == 1 else "they disappear"])
		for ln in rep.comment_lines.slice(0, 8):
			notes.append("        line %d:  [code]%s[/code]" % [int(ln), esc.call(line_text.call(int(ln)))])
			if show_line == 0:
				show_line = int(ln)
		if rep.comment_lines.size() > 8:
			notes.append("        ... and %d more" % (rep.comment_lines.size() - 8))
	if not rep.reformatted.is_empty():
		var n: int = rep.reformatted.size()
		notes.append("%s[b]%d line%s will be written in Schematic's style at the next save[/b] (same meaning):[/color]" % [warn, n, "" if n == 1 else "s"])
		for x in rep.reformatted.slice(0, 3):
			notes.append("        line %d:  [code]%s[/code]   becomes   [code]%s[/code]" % [int(x.line), esc.call(String(x.file).strip_edges()), esc.call(String(x.graph).strip_edges())])
		if n > 3:
			notes.append("        ... and %d more" % (n - 3))
	for x in rep.renamed_locals:
		notes.append("In %s, the local [b]%s[/b] is written [b]%s[/b] (another event has a local of that name)." % [esc.call(String(x.function)), esc.call(String(x.written)), esc.call(String(x.now))])
	if int(rep.macros_expanded) > 0:
		notes.append("%d function%s used a shared macro: rebuilt from the code, %s the macro's nodes in place of the macro." % [int(rep.macros_expanded), "" if int(rep.macros_expanded) == 1 else "s", "it has" if int(rep.macros_expanded) == 1 else "they have"])
	if int(rep.code_node_lines) > 0:
		notes.append("%d line%s stay%s as code nodes (Schematic has no nodes for %s yet)." % [int(rep.code_node_lines), "" if int(rep.code_node_lines) == 1 else "s", "s" if int(rep.code_node_lines) == 1 else "", "it" if int(rep.code_node_lines) == 1 else "them"])
	for nt in rep.notes:
		notes.append(esc.call(String(nt)))
	if not notes.is_empty():
		t.append("")
		t.append("[b]Good to know[/b]")
		for nt in notes:
			t.append("    " + nt)
	t.append("")
	var rewrites: bool = int(rep.comments_dropped) > 0 or not rep.reformatted.is_empty() or not rep.renamed_locals.is_empty()
	t.append("%sAfter Re-import the graph has unsaved changes; saving writes the file%s.[/color]" % [dim, " (with the changes listed above)" if rewrites else " (its code stays as it is)"])
	return ["\n".join(t), show_line]


func _show_reimport(d: Dictionary, pv: Dictionary) -> void:
	if _reimport_dialog and is_instance_valid(_reimport_dialog):
		_reimport_dialog.queue_free()
	var ok := bool(pv.result.ok)
	var dlg: AcceptDialog = ConfirmationDialog.new() if ok else AcceptDialog.new()
	_reimport_dialog = dlg
	dlg.name = "ReimportDialog"
	dlg.title = "Re-import Code: %s" % String(d.path).get_file()
	var words := reimport_words(d, pv)
	var rt := RichTextLabel.new()
	rt.name = "Words"
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.selection_enabled = true
	rt.custom_minimum_size = W.sv(Vector2(760, 0))
	rt.text = String(words[0])
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# tall enough for the words (a wrapped line counts as more than one), up to a point; beyond that it scrolls
	var rows := 0
	var tags := RegEx.create_from_string("\\[[^\\]]*\\]")
	for ln in String(words[0]).split("\n"):
		rows += maxi(1, ceili(tags.sub(ln, "", true).length() / 82.0))
	scroll.custom_minimum_size = W.sv(Vector2(780, mini(540, 16 + 24 * rows)))
	scroll.add_child(rt)
	dlg.add_child(scroll)
	var line := int(words[1])
	if ok:
		dlg.ok_button_text = "Re-import"
		(dlg as ConfirmationDialog).cancel_button_text = "Cancel"
		dlg.confirmed.connect(func(): reimport_confirmed(d, pv))
	else:
		dlg.ok_button_text = "Close"
		if line > 0:
			var show_btn := dlg.add_button("Show Line %d" % line, false, "show_line")
			show_btn.name = "ShowLine"
			show_btn.tooltip_text = "Open the list of changes at this line"
		dlg.custom_action.connect(func(action: StringName):
			if action == &"show_line":
				dlg.hide()
				show_drift_changes(d, line))
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	_dialog_host().add_child(dlg)
	dlg.popup_centered()
	dlg.get_ok_button().grab_focus.call_deferred()   # Re-import is one step that can be undone
	# once laid out: as tall as the words really are (the estimate above only avoids a first frame that is too small)
	get_tree().process_frame.connect(func():
		if is_instance_valid(dlg) and is_instance_valid(rt) and rt.get_content_height() > 0:
			scroll.custom_minimum_size.y = mini(W.si(540), rt.get_content_height() + W.si(28))   # (+ the panel's margins)
			dlg.reset_size()
			dlg.move_to_center(), CONNECT_ONE_SHOT)


## Re-import pressed in the preview. The file is read again: if it changed since the preview was made, the preview
## is made again for what is there now (and nothing is applied); otherwise the re-import is applied.
func reimport_confirmed(d: Dictionary, pv: Dictionary) -> bool:
	if docs.find(d) < 0:
		return false
	var now := FileAccess.get_file_as_string(String(d.path))
	if now != String(pv.text):
		toast("%s changed again on disk since the preview: here is what Re-import Code would do now." % String(d.path).get_file())
		if can_reimport(d):
			_show_reimport.call_deferred(d, reimport_preview(d))
		return false
	return reimport_apply(d, now)


## Brings `text` (the file's text, as read) into the document's graph as one undo step. False (with a toast) when the
## re-import refuses it.
func reimport_apply(d: Dictionary, text: String) -> bool:
	var inp := _reimport_input(d, text)
	var r: Dictionary = Sync.new().reimport(d.bp, String(inp.code), {"path": String(d.path)})
	if not bool(r.ok):
		var why: Array = r.report.refused
		toast("Not re-imported: %s" % (String(why[0].reason) if not why.is_empty() else "the code could not be brought in"))
		return false
	var rep: Dictionary = r.report
	var before_bp: Dictionary = d.bp.duplicate(true)
	var after_bp: Dictionary = r.bp
	var before_state := _disk_state(d)
	var after_state := before_state.duplicate(true)
	var code_hash := Model.code_hash(Model.code_part(text))
	var graph_hash := Model.graph_part(text).md5_text()
	# what is on disk is, from here on, the text the re-import read (time -1: the next look reads the file)
	after_state.merge({"disk_code": code_hash, "disk_graph": graph_hash, "disk_now": [code_hash, graph_hash], "disk_time": -1,
		"drift": "", "drift_keep": "", "drift_at_open": false}, true)
	# the line maps of what the game runs: the file's code, which is the new graph's (comments aside)
	var c := Compiler.new()
	var new_code := c.compile(after_bp.duplicate(true))
	after_state.merge({"code": new_code, "saved_lines": c.node_lines.duplicate(), "saved_map": c.line_map.duplicate(), "saved_pins": c.pin_exprs, "saved_blocks": c.block_lines}, true)
	var dropped := _drop_debug_marks(d, rep.replaced, after_bp)
	var gid := int(d.graph_id)
	var ur := plugin.get_undo_redo() if plugin else null
	if ur:
		ur.create_action("Schematic: Re-import Code", UndoRedo.MERGE_DISABLE, self)
		ur.add_do_method(self, "_reimport_restore", d.path, after_bp, after_state, before_state, gid)
		ur.add_undo_method(self, "_reimport_restore", d.path, before_bp, before_state, after_state, gid)
		ur.commit_action()
	else:
		_reimport_restore(d.path, after_bp, after_state, before_state, gid)
	var did := PackedStringArray()
	for x in rep.functions:
		if String(x.action) != "kept":
			did.append("%s %s" % [x.name, String(x.action).replace("+", " and ")])
	var msg := "Code re-imported%s. Save to write the file." % ((": " + ", ".join(did.slice(0, 4)) + (" ..." if did.size() > 4 else "")) if not did.is_empty() else "")
	if dropped[0] > 0:
		msg += " %d breakpoint%s on rebuilt nodes %s removed." % [dropped[0], "" if dropped[0] == 1 else "s", "was" if dropped[0] == 1 else "were"]
	if dropped[1] > 0:
		msg += " %d watch%s on rebuilt nodes %s removed." % [dropped[1], "" if dropped[1] == 1 else "es", "was" if dropped[1] == 1 else "were"]
	toast(msg)
	return true


const DISK_KEYS := ["disk_code", "disk_graph", "disk_now", "disk_time", "drift", "drift_keep", "drift_at_open", "code", "saved_lines", "saved_map", "saved_pins", "saved_blocks"]


## What a document knows about its file on disk (and the line maps of the code there), for the undo step.
func _disk_state(d: Dictionary) -> Dictionary:
	var out := {}
	for k in DISK_KEYS:
		if d.has(k):
			out[k] = d[k].duplicate(true) if (typeof(d[k]) == TYPE_DICTIONARY or typeof(d[k]) == TYPE_ARRAY) else d[k]
	return out


## The do and undo of Re-import Code: puts `bp` in and, unless the file was written since (the record of the disk is not
## `other`, the one the step started from), the record of what is on disk that goes with it.
func _reimport_restore(path: String, bp: Dictionary, state: Dictionary, other: Dictionary, gid: int) -> void:
	var d := _find_doc(path)
	if d.is_empty():
		return
	d.bp = bp.duplicate(true)
	d.dirty = true
	if String(d.get("disk_code", "")) == String(other.get("disk_code", "")) and String(d.get("disk_graph", "")) == String(other.get("disk_graph", "")):
		for k in state:
			d[k] = state[k].duplicate(true) if (typeof(state[k]) == TYPE_DICTIONARY or typeof(state[k]) == TYPE_ARRAY) else state[k]
	if Model.find_graph(d.bp, gid).is_empty():
		gid = 0
		for g in d.bp.graphs:
			if String(g.kind) == "event":
				gid = int(g.id)
				break
		if gid == 0 and not d.bp.graphs.is_empty():
			gid = int(d.bp.graphs[0].id)
	d.graph_id = gid
	_check(d)
	_drift_check(d, true)
	if d == doc:
		if _view:
			for c in _view.get_children():
				if c is GraphElement:
					c.selected = false
		_sel = {"kind": "class"}
		_refresh_all()
	else:
		_refresh_doc_tabs()


## Removes the breakpoints and pin watches on nodes a re-import replaced (listed in `replaced`, or in a graph that is
## gone). Returns [breakpoints removed, watches removed].
func _drop_debug_marks(d: Dictionary, replaced: Dictionary, new_bp: Dictionary) -> Array:
	var path := String(d.path)
	var gone := func(key: String) -> bool:
		var parts := key.split(":")
		if parts.size() != 2:
			return false
		var g := int(parts[0])
		if Model.find_graph(new_bp, g).is_empty():
			return true
		for k in replaced:
			if int(k) == g:
				return replaced[k].any(func(id): return int(id) == int(parts[1]))
		return false
	var all := _all_breaks()
	var list: Array = all.get(path, []).duplicate()
	var keep := []
	var n_breaks := 0
	for key in list:
		if gone.call(String(key)):
			n_breaks += 1
			var line := _node_line(d, String(key))
			if debugger and line != -1:
				for s in debugger.get_sessions():
					if s.is_active():
						s.set_breakpoint(path, line, false)
		else:
			keep.append(key)
	if n_breaks > 0:
		if keep.is_empty():
			all.erase(path)
		else:
			all[path] = keep
		EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", all)
	var n_watches := 0
	var watches: Array = debug_panel.watches if debug_panel else []
	var left := watches.filter(func(w): return not (String(w.get("path", "")) == path and gone.call(String(w.get("key", "")))))
	n_watches = watches.size() - left.size()
	if n_watches > 0 and debug_panel:
		debug_panel.watches = left
		debug_panel._save_watches()
	# the last values the running game showed on those nodes mean nothing now
	if _watch.has(path):
		for k in _watch[path].keys():
			if gone.call("%d:%d" % [int(k) / 100000, int(k) % 100000]):
				_watch[path].erase(k)
	return [n_breaks, n_watches]


## What the plugin does after the kits were loaded again: compile-check every open document (nodes of a kit that
## went away turn into placeholders, nodes of one that came back turn normal) and redraw.
func recheck_all() -> void:
	for d in docs:
		_check(d)
	_refresh_all()


var _kits_dialog: AcceptDialog
var _kits_tree: Tree


## Kits...: the addons that ship nodes (docs/KITS.md), whether each is active or why not, and the problems found
## while loading them. Built when opened. Reload Kits asks the plugin to load them all again.
func show_kits_dialog() -> void:
	if _kits_dialog and is_instance_valid(_kits_dialog):
		_kits_dialog.queue_free()
	var dlg := AcceptDialog.new()
	_kits_dialog = dlg
	dlg.title = "Kits"
	dlg.ok_button_text = "Close"
	var box := VBoxContainer.new()
	dlg.add_child(box)
	var head := Label.new()
	head.text = "Addons can ship nodes for Schematic (res://addons/<addon>/schematic_kit.gd)."
	head.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	box.add_child(head)
	_kits_tree = Tree.new()
	_kits_tree.name = "KitList"
	_kits_tree.hide_root = true
	_kits_tree.custom_minimum_size = W.sv(Vector2(760, 320))
	_kits_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_kits_tree)
	var reload := Button.new()
	reload.name = "ReloadKits"
	reload.text = "Reload Kits"
	reload.icon = W.icon("Reload")
	reload.tooltip_text = "Load every kit again, as happens when an addon is switched on or off or a kit file changes"
	reload.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reload.pressed.connect(func():
		if plugin:
			plugin.reload_kits()
		else:
			R.reload_kits()
		_fill_kits_tree())
	box.add_child(reload)
	_fill_kits_tree()
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	_dialog_host().add_child(dlg)
	dlg.popup_centered()


func _fill_kits_tree() -> void:
	var tree := _kits_tree
	if tree == null or not is_instance_valid(tree):
		return
	tree.clear()
	var root := tree.create_item()
	var ov := Kits.overview()
	var good := Color(0.55, 0.85, 0.6)
	var dim := Color(1, 1, 1, 0.55)
	var bad := Color(0.95, 0.6, 0.45)
	var shown := {}
	for k in ov.kits:
		var it := tree.create_item(root)
		var line := "%s" % k.addon
		match String(k.state):
			"active":
				line += "   -   %s%s   -   %d node%s   -   active" % [k.name, (" " + k.version) if String(k.version) != "" else "", k.nodes, "" if int(k.nodes) == 1 else "s"]
				it.set_custom_color(0, good)
			"disabled":
				line += "   -   not active: " + String(k.reason)
				it.set_custom_color(0, dim)
			_:
				line += "   -   not active: " + String(k.reason)
				it.set_custom_color(0, bad)
		it.set_text(0, line)
		it.set_autowrap_mode(0, TextServer.AUTOWRAP_WORD_SMART)
		shown[k.addon] = true
		for p in R.kit_problems:
			if String(p.addon) != String(k.addon):
				continue
			if String(p.template) == "" and String(k.state) == "failed":
				continue   # already the state line
			var pi := tree.create_item(it)
			pi.set_text(0, ("Node '%s': " % p.template if String(p.template) != "" else "") + String(p.problem))
			pi.set_autowrap_mode(0, TextServer.AUTOWRAP_WORD_SMART)
			pi.set_custom_color(0, bad)
			pi.set_tooltip_text(0, String(p.path))
		var fi := tree.create_item(it)
		fi.set_text(0, String(k.path))
		fi.set_custom_color(0, dim)
	for p in R.kit_problems:
		if not shown.has(String(p.addon)):
			var it := tree.create_item(root)
			it.set_text(0, "%s: %s   (%s)" % [p.addon, p.problem, p.path])
			it.set_custom_color(0, bad)
	if not ov.builtin.is_empty():
		var bi := tree.create_item(root)
		bi.set_text(0, "Built in   -   %s   -   %d nodes   -   active" % [", ".join(ov.builtin), ov.builtin_nodes])
		bi.set_custom_color(0, good)
	if ov.kits.is_empty() and ov.builtin.is_empty():
		var none := tree.create_item(root)
		none.set_text(0, "No kits found.")
		none.set_custom_color(0, dim)


func _tell_not_written(paths: Array, side_effect: bool) -> void:
	var names := ", ".join(paths.map(func(p): return String(p).get_file()))
	if side_effect:
		toast("%s %s not rewritten: changed outside Schematic (see the bar above the graph)." % [names, "was" if paths.size() == 1 else "were"])
	else:
		toast("Not saved: %s changed outside Schematic. Choose what to keep in the bar above the graph." % names)


func _build_drift_bar(parent: Control) -> void:
	_drift_bar = PanelContainer.new()
	_drift_bar.name = "DriftBar"
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.29, 0.21, 0.06)
	bg.border_color = Color(1.0, 0.72, 0.1)
	bg.border_width_left = W.si(3)
	bg.content_margin_left = W.si(8)
	bg.content_margin_right = W.si(6)
	bg.content_margin_top = W.si(3)
	bg.content_margin_bottom = W.si(3)
	_drift_bar.add_theme_stylebox_override("panel", bg)
	_drift_bar.visible = false
	parent.add_child(_drift_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", W.si(4))
	_drift_bar.add_child(row)
	var icon := TextureRect.new()
	icon.texture = W.icon("StatusWarning")
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	_drift_label = Label.new()
	_drift_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drift_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_drift_label.add_theme_color_override("font_color", Color(1, 0.9, 0.7))
	row.add_child(_drift_label)
	var add := func(key: String, text: String, tip: String, fn: Callable) -> void:
		var b := _tool(text, "", tip, fn)
		b.name = key
		b.add_theme_stylebox_override("normal", _drift_button_box())
		row.add_child(b)
		_drift_btns[key] = b
	add.call("show", "Show Changes", "List the lines where the code on disk and the graph's code differ", func(): show_drift_changes(doc))
	add.call("keep", "Keep Graph", "The graph is right: the next save replaces the file's code with the graph's", func(): drift_keep(doc))
	add.call("reimport", "Re-import Code", "Bring the changed code into the graph. Only the functions that changed are rebuilt.", func(): reimport_dialog(doc))
	add.call("reload", "Reload From Disk", "Load the graph that is in the file on disk now, in place of the one here", func(): drift_reload(doc))
	add.call("mine", "Keep Mine", "The graph here is right: the next save overwrites the file on disk", func(): drift_keep(doc))


func _drift_button_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.08)
	sb.set_corner_radius_all(W.si(4))
	sb.content_margin_left = W.si(7)
	sb.content_margin_right = W.si(7)
	sb.content_margin_top = W.si(4)
	sb.content_margin_bottom = W.si(4)
	return sb


## Shows, words and buttons the bar above the graph for the document on screen.
func _refresh_drift() -> void:
	if _drift_bar == null:
		return
	var state := "" if doc.is_empty() else String(doc.get("drift", ""))
	_drift_bar.visible = state != ""
	if state == "":
		return
	var file := String(doc.path).get_file()
	var kept := _keep_chosen(doc)
	var unsaved := " The graph also has unsaved changes." if doc.dirty and not kept else ""
	var text := ""
	var wanted := ["show"]
	match state:
		"code":
			if kept:
				text = "You chose to keep the graph: the next save replaces the code that was changed outside Schematic."
			else:
				text = "This file's code was changed outside Schematic%s. The graph does not include those changes.%s" % [" while it was closed" if bool(doc.get("drift_at_open", false)) else "", unsaved]
				wanted.append_array(["keep", "reimport"])
		"replaced":
			if kept:
				text = "You chose to keep your graph: the next save overwrites the file on disk."
			else:
				text = "%s was replaced outside Schematic (for example by git or another editor): the graph on disk is not the one here.%s" % [file, unsaved]
				wanted.append_array(["reload", "mine"])
		"missing":
			text = "%s was deleted or moved outside Schematic. Saving writes it again here." % file
			wanted = []
	_drift_label.text = text
	for key in _drift_btns:
		_drift_btns[key].visible = wanted.has(key)
	_drift_btns.reload.text = "Reload From Disk (discard unsaved changes)" if doc.dirty else "Reload From Disk"


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or (what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree()):
		check_drift_all.call_deferred()


# ---------------------------------------------------------------- debugging

func _all_breaks() -> Dictionary:
	var v: Variant = EditorInterface.get_editor_settings().get_project_metadata("schematics", "breakpoints", {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func _breaks(path: String) -> Array:
	return _all_breaks().get(path, [])


## Line of the *saved* script that a node starts on, or -1 (pure nodes have no line of their own).
func _node_line(d: Dictionary, key: String) -> int:
	var lines: Dictionary = d.get("saved_lines", d.node_lines)
	return int(lines.get(key, -1))


func toggle_breakpoints(ids: Array) -> void:
	if doc.is_empty() or ids.is_empty():
		return
	if doc.dirty:
		# (a file changed outside Schematic is not rewritten: the breakpoint goes on the lines last saved)
		compile_doc(doc, true, true)
	var all := _all_breaks()
	var list: Array = all.get(doc.path, []).duplicate()
	for id in ids:
		var key := "%d:%d" % [int(doc.graph_id), int(id)]
		var line := _node_line(doc, key)
		var enable := not list.has(key)
		if enable and line == -1:
			toast("Breakpoints go on nodes with execution pins (pure nodes run as part of the node that reads them).")
			continue
		if enable:
			list.append(key)
		else:
			list.erase(key)
		# The running game has the code it started with: its line for the node, when that code's records are known
		# (a node added since is not in it: the breakpoint is kept for the next run).
		var run := _run_rec(String(doc.path))
		var run_line := int(run.lines.get(key, -1)) if bool(run.get("exact", false)) else line
		if debugger and run_line != -1:
			for s in debugger.get_sessions():
				if s.is_active():
					s.set_breakpoint(doc.path, run_line, enable)
	if list.is_empty():
		all.erase(doc.path)
	else:
		all[doc.path] = list
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", all)
	_refresh_graph()


## "res://file.gd:line" for every node breakpoint in the project (handed to the debugger when the game starts).
func breakpoint_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var all := _all_breaks()
	for path in all:
		var d := _find_doc(path)
		var lines: Dictionary = {}
		if not d.is_empty():
			lines = d.get("saved_lines", d.node_lines)
		elif Model.is_schematic_file(path):
			lines = debug_info(path).get("lines", {})
		for key in all[path]:
			if lines.has(key):
				out.append("%s:%d" % [path, int(lines[key])])
	return out


## Called by the debugger when it wants to show a script line (breakpoint hit, stack frame or error clicked).
func debug_goto(path: String, line: int) -> void:
	if debug_panel and not debug_panel.goto(path, line):
		return   # a node step is passing through this line
	debug_show(path, line)


## Opens the schematic that `line` of the generated script belongs to and marks its node as the one the
## game is stopped at.
func debug_show(path: String, line: int) -> void:
	if debug_info(path).is_empty() or not open_schematic(path):
		return
	_exec = [path, line]   # (a line of the code the game runs: the Generated Code tab shows that code while it runs)
	var map: Dictionary = debug_info(path).get("map", doc.get("saved_map", doc.line_map))
	var where: Array = []
	for back in 40:
		if map.has(line - back):
			where = map[line - back]
			break
	_show_screen.call_deferred()
	if where.is_empty() or int(where[1]) == 0:
		toast("Stopped in generated line %d (no single node maps to it)" % line)
		_update_code()
		_set_code_label("")
		_exec_scroll.call_deferred()
		return
	_paused = [path, int(where[0]), int(where[1])]
	doc.graph_id = int(where[0])
	_refresh_graph()
	_refresh_graph_tabs()
	_refresh_members()
	_update_code()
	_set_code_label("")
	_view.focus_node.call_deferred(int(where[1]))
	_exec_scroll.call_deferred()   # (after focus_node, whose selection scrolls to the node's own lines)


var _recompiling := false
var flow_hits := 0
var flow_edges := 0
var watch_hits := 0
var _watch: Dictionary = {}


## Live execution flow: the running game reports which nodes ran (only when Show Execution Flow is on).
func debug_flow(path: String, keys: Array, values: Dictionary = {}, edges: Array = []) -> void:
	flow_hits += keys.size()
	flow_edges += edges.size()
	watch_hits += values.size()
	# last value seen on each wired input pin, per schematic file: {graph*100000+node: {pin: text}}
	if not values.is_empty():
		if not _watch.has(path):
			_watch[path] = {}
		for k in values:
			_watch[path][int(k)] = values[k]
	if doc.is_empty() or doc.path != path or not is_visible_in_tree():
		return
	var ids := []
	for k in keys:
		if int(k) / 100000 == int(doc.graph_id):
			ids.append(int(k) % 100000)
	_view.flash(ids)
	# the exec wires that were followed: (graph * 100000 + from node) * 100000 + to node
	for e in edges:
		var to_id := int(e) % 100000
		var from_key := int(e) / 100000
		if from_key / 100000 == int(doc.graph_id):
			_view.flow(from_key % 100000, to_id)
	for k in values:
		if int(k) / 100000 == int(doc.graph_id):
			_view.show_watch(int(k) % 100000, values[k])


## What the debugger needs to know about a schematic's generated script, as the running game has it:
## {map: line -> [graph, node], pins: function -> "graph:node" -> {pin: expression},
## blocks: [[first line, last line, function]], bp}. Empty for a script that is not a Schematic.
func debug_info(path: String) -> Dictionary:
	# While the game runs: the records of the code it started with, when they are known exactly (see _run_rec).
	var run := _run_rec(path)
	if bool(run.get("exact", false)):
		return {"map": run.map, "pins": run.pins, "blocks": run.blocks, "bp": run.bp}
	var d := _find_doc(path)
	if not d.is_empty():
		return {"map": d.get("saved_map", d.line_map), "pins": d.get("saved_pins", {}), "blocks": d.get("saved_blocks", []), "bp": d.bp}
	if not _debug_cache.has(path):
		var out := {}
		if FileAccess.file_exists(path) and Model.is_schematic_file(path):
			var file_bp := Model.load_file(path)
			var text := FileAccess.get_file_as_string(path)
			var cut := Model.graph_block_at(text)
			out = _file_maps(file_bp, text.substr(0, cut) if cut > 0 else "")
			out["bp"] = file_bp
		_debug_cache[path] = out
	return _debug_cache[path]


## Line maps for a schematic's script as it is on disk, which is what the game runs: {map, lines, pins, blocks}.
func _file_maps(bp: Dictionary, _file_code: String) -> Dictionary:
	var c := Compiler.new()
	c.compile(bp)
	return {"map": c.line_map.duplicate(), "lines": c.node_lines.duplicate(), "pins": c.pin_exprs, "blocks": c.block_lines}


## The watch entry for an input pin of a node in the graph on screen.
func pin_watch(nid: int, pin: String, pin_label: String) -> Dictionary:
	var title := debug_node_title(String(doc.path), int(doc.graph_id), nid)
	var n := Model.find_node(cur_graph(), nid)
	if title == "" and not n.is_empty():
		title = String(R.describe(n, doc.bp, cur_graph()).title)
	return {"label": "%s: %s" % [title, pin_label], "path": String(doc.path), "key": "%d:%d" % [int(doc.graph_id), nid], "pin": pin}


func debug_node_title(path: String, gid: int, nid: int) -> String:
	var info := debug_info(path)
	if info.is_empty():
		return ""
	var g := Model.find_graph(info.bp, gid)
	var n := Model.find_node(g, nid) if not g.is_empty() else {}
	if n.is_empty():
		return ""
	var title := String(R.describe(n, info.bp, g).title)
	return title if title != "" else String(n.kind)


## A node step went from one node to the next: run the dots along the wire between them.
func debug_step_flow(path: String, gid: int, from_id: int, to_id: int) -> void:
	if not doc.is_empty() and String(doc.path) == path and int(doc.graph_id) == gid and from_id != to_id:
		_view.flow(from_id, to_id)


## The debug panel's state changed (paused, resumed, new values): show or hide what depends on it.
func debug_panel_changed() -> void:
	if debug_panel == null:
		return
	debug_panel.visible = debug_panel.paused
	for st in _step_tools:
		st.visible = debug_panel.paused
	if not doc.is_empty():
		_view.watch = _graph_watch()
		for nid in _view.watch:
			_view.show_watch(int(nid), _view.watch[nid])


## Resume, the way Godot's own Continue button does it (it also gives the game its window focus and sound back).
func debug_continue() -> void:
	var sc: Shortcut = EditorInterface.get_editor_settings().get_shortcut("debugger/continue") if EditorInterface.get_editor_settings().has_shortcut("debugger/continue") else null
	if sc != null and not sc.events.is_empty() and sc.events[0] is InputEventKey:
		var ev := (sc.events[0] as InputEventKey).duplicate() as InputEventKey
		ev.pressed = true
		EditorInterface.get_base_control().get_viewport().push_input(ev)
		# Godot's button only hears its shortcut while the Debugger panel is open. If the game is still stopped at
		# the same place a moment later, ask it to go on directly.
		var stopped_at: int = debug_panel.pause_id
		get_tree().create_timer(0.25).timeout.connect(func():
			if debug_panel.paused and debug_panel.pause_id == stopped_at:
				debug_panel._send("continue", []))
		return
	debug_panel._send("continue", [])


## A new game session: values from the last run no longer mean anything.
func debug_started(session_id := -1) -> void:
	_watch.clear()
	_debug_cache.clear()
	# What the game runs is each file as it is now (open schematics were saved before it started, unless refused).
	# Schematic writes files directly, so a save made while the game runs is not loaded into it: keep this text.
	_sessions[session_id] = true
	_game_on = true
	_run_texts.clear()
	_run_recs.clear()
	_run_gen += 1
	_exec = []
	for d in docs:
		if FileAccess.file_exists(String(d.path)):
			_run_texts[String(d.path)] = FileAccess.get_file_as_string(String(d.path))
	if not doc.is_empty():
		_refresh_graph()
		_update_code()
		_set_code_label("")


## A game session ended. When it was the last one, the Generated Code tab goes back to the graph's current code.
func debug_ended(session_id := -1) -> void:
	_sessions.erase(session_id)
	if not _sessions.is_empty():
		return
	_game_on = false
	_run_texts.clear()
	_run_recs.clear()
	_run_gen += 1
	_exec = []
	if not doc.is_empty():
		_update_code()
		_set_code_label("")


func _graph_watch() -> Dictionary:
	var out := {}
	if doc.is_empty():
		return out
	var all: Dictionary = _watch.get(doc.path, {})
	for k in all:
		if int(k) / 100000 == int(doc.graph_id):
			out[int(k) % 100000] = all[k]
	# while the game is paused, the values of the function it is stopped in
	if debug_panel and debug_panel.paused:
		var now: Dictionary = debug_panel.pin_values(String(doc.path), int(doc.graph_id))
		for nid in now:
			var row: Dictionary = out.get(int(nid), {}).duplicate()
			row.merge(now[nid], true)
			out[int(nid)] = row
	return out


func debug_resume() -> void:
	if _paused.is_empty() and _exec.is_empty():
		return
	_paused = []
	_exec = []
	if not doc.is_empty():
		_refresh_graph()
		_link_apply()
		_set_code_label("")


# ---------------------------------------------------------------- refresh

func _refresh_all() -> void:
	if _view == null:
		return
	_empty.visible = doc.is_empty()
	_body.visible = not doc.is_empty()
	_refresh_doc_tabs()
	if doc.is_empty():
		_view.show_graph({}, {})
		_refresh_status()
		return
	_refresh_graph_tabs()
	_refresh_graph()
	_refresh_members()
	_refresh_components()
	_refresh_details()
	_refresh_status()
	_update_code()


func _refresh_doc_tabs() -> void:
	_suppress_tabs = true
	_doc_tabs.clear_tabs()
	for d in docs:
		var outside := String(d.get("drift", "")) != ""
		_doc_tabs.add_tab(d.path.get_file().get_basename() + ("*" if d.dirty else ""), W.icon("StatusWarning") if outside else W.class_icon(R.self_class(d.bp)))
		_doc_tabs.set_tab_tooltip(_doc_tabs.tab_count - 1, d.path + ("\nChanged outside Schematic" if outside else ""))
	var i := docs.find(doc)
	if i >= 0:
		_doc_tabs.current_tab = i
	_doc_tabs.visible = not docs.is_empty()
	_suppress_tabs = false


func _refresh_graph_tabs() -> void:
	_suppress_tabs = true
	_graph_tabs.clear_tabs()
	var cur := 0
	for i in doc.bp.graphs.size():
		var g: Dictionary = doc.bp.graphs[i]
		_graph_tabs.add_tab(g.name, W.icon("GraphEdit") if g.kind == "event" else W.icon("MemberMethod"))
		if int(g.id) == int(doc.graph_id):
			cur = i
	if _graph_tabs.tab_count > 0:
		_graph_tabs.current_tab = cur
	_suppress_tabs = false
	var g := cur_graph()
	_crumb.text = "%s   /   %s" % [doc.path.get_file().get_basename(), g.get("name", "")]
	# graph history for the back / forward arrows
	if not doc.has("nav"):
		doc["nav"] = []
		doc["nav_i"] = -1
	var hist: Array = doc.nav
	var gid := int(doc.graph_id)
	if int(doc.nav_i) < 0 or int(hist[int(doc.nav_i)]) != gid:
		hist.resize(int(doc.nav_i) + 1)
		hist.append(gid)
		doc["nav_i"] = hist.size() - 1


func _fill_bookmarks(menu: PopupMenu) -> void:
	menu.clear()
	menu.add_icon_item(W.icon("Add"), "Add Bookmark Here", 1000)
	if doc.is_empty():
		return
	var list: Array = doc.bp.get("bookmarks", [])
	if not list.is_empty():
		menu.add_separator()
	for i in list.size():
		var g := Model.find_graph(doc.bp, int(list[i].graph))
		menu.add_item("%s   (%s)" % [list[i].name, g.get("name", "?")], i)
	if not list.is_empty():
		menu.add_separator()
		menu.add_icon_item(W.icon("Remove"), "Remove All Bookmarks", 1001)


func _on_bookmark(id: int) -> void:
	if doc.is_empty():
		return
	if id == 1000:
		add_bookmark()
	elif id == 1001:
		mutate("Remove Bookmarks", func(): doc.bp.erase("bookmarks"), false)
	else:
		goto_bookmark(id)


func add_bookmark() -> void:
	var g := cur_graph()
	var list: Array = doc.bp.get("bookmarks", [])
	var names := list.map(func(b): return b.name)
	var mark := {"name": Model.unique_name("Bookmark", names), "graph": int(g.id), "zoom": _view.zoom / W.scale(), "sx": _view.scroll_offset.x / W.scale(), "sy": _view.scroll_offset.y / W.scale()}
	mutate("Add Bookmark", func():
		if not doc.bp.has("bookmarks"):
			doc.bp["bookmarks"] = []
		doc.bp.bookmarks.append(mark), false)
	toast("Bookmark added: %s" % mark.name)


func goto_bookmark(index: int) -> void:
	var list: Array = doc.bp.get("bookmarks", [])
	if index < 0 or index >= list.size():
		return
	var mark: Dictionary = list[index]
	if Model.find_graph(doc.bp, int(mark.graph)).is_empty():
		toast("That bookmark's graph no longer exists.")
		return
	doc.graph_id = int(mark.graph)
	_refresh_graph()
	_refresh_members()
	_refresh_graph_tabs()
	_view.zoom = float(mark.zoom) * W.scale()   # (a view is stored as it is at 100%: see sc_graph_view.gd)
	_view.scroll_offset = Vector2(float(mark.sx), float(mark.sy)) * W.scale()


func _nav_step(dir: int) -> void:
	if doc.is_empty() or not doc.has("nav"):
		return
	var i := int(doc.nav_i) + dir
	while i >= 0 and i < doc.nav.size() and Model.find_graph(doc.bp, int(doc.nav[i])).is_empty():
		i += dir
	if i < 0 or i >= doc.nav.size():
		return
	doc["nav_i"] = i
	doc.graph_id = int(doc.nav[i])
	_refresh_graph()
	_refresh_members()
	_refresh_graph_tabs()


func _on_graph_tab(i: int) -> void:
	if _suppress_tabs or doc.is_empty() or i < 0 or i >= doc.bp.graphs.size():
		return
	doc.graph_id = int(doc.bp.graphs[i].id)
	_refresh_graph()
	_refresh_members()
	_refresh_graph_tabs()


func _refresh_graph() -> void:
	if doc.is_empty():
		return
	var g := cur_graph()
	var errs := {}
	for e in doc.errors:
		if int(e.g) == int(g.get("id", -1)) and int(e.n) != 0 and not errs.has(int(e.n)):
			errs[int(e.n)] = e.m
	var marks := {}
	for key in _breaks(doc.path):
		var parts := String(key).split(":")
		if parts.size() == 2 and int(parts[0]) == int(g.get("id", -1)):
			marks[int(parts[1])] = "bp"
	if _paused.size() == 3 and _paused[0] == doc.path and int(_paused[1]) == int(g.get("id", -1)):
		marks[int(_paused[2])] = String(marks.get(int(_paused[2]), "")) + "paused"
	_view.watch = _graph_watch()
	_view.show_graph(doc.bp, g, errs, marks)
	_link_refresh_soon()


func _refresh_status() -> void:
	_refresh_drift()
	_results.clear()
	if doc.is_empty():
		_status.text = ""
		_parent_btn.text = ""
		return
	var n_err := 0
	for e in doc.errors:
		var g := Model.find_graph(doc.bp, int(e.g))
		var idx := _results.add_item("%s%s" % [("[%s] " % g.name) if not g.is_empty() else "", e.m], W.icon("StatusWarning" if e.w else "StatusError"))
		_results.set_item_metadata(idx, e)
		if not e.w:
			n_err += 1
	if n_err > 0:
		_status.text = "%d error%s" % [n_err, "" if n_err == 1 else "s"]
		_status.add_theme_color_override("font_color", Color(1, 0.4, 0.35))
		_compile_btn.icon = W.icon("StatusError")
	elif doc.dirty:
		_status.text = "Dirty - needs compile"
		_status.add_theme_color_override("font_color", Color(1, 0.8, 0.35))
		_compile_btn.icon = W.icon("StatusWarning")
	else:
		_status.text = "Good to go"
		_status.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
		_compile_btn.icon = W.icon("StatusSuccess")
		if _results.item_count == 0:
			_results.add_item("Compile complete - no issues.", W.icon("StatusSuccess"))
	_compile_btn.tooltip_text = "%s\nCompile this schematic to GDScript and save it (F7)" % _status.text
	_parent_btn.text = "Parent class:  %s" % R.self_class(doc.bp)
	var i := docs.find(doc)
	if i >= 0 and i < _doc_tabs.tab_count:
		_doc_tabs.set_tab_title(i, doc.path.get_file().get_basename() + ("*" if doc.dirty else ""))


func _on_result_activated(i: int) -> void:
	var e: Variant = _results.get_item_metadata(i)
	if typeof(e) != TYPE_DICTIONARY or int(e.g) == 0:
		return
	if int(doc.graph_id) != int(e.g):
		doc.graph_id = int(e.g)
		_refresh_graph()
		_refresh_graph_tabs()
		_refresh_members()
	if int(e.n) != 0:
		_view.focus_node(int(e.n))


## Shows the compiled text in the Generated Code tab (only while that tab is showing) and puts the selection's
## highlights on it. `scroll` also scrolls the first highlighted line into view.
func _update_code(scroll := false) -> void:
	if _code == null or doc.is_empty() or _right_tabs.current_tab != 1:
		return
	var shown := _shown()
	var text := String(shown.text)
	_code_notice.text = String(shown.notice)
	_code_notice.visible = String(shown.notice) != ""
	if _code.text != text:
		var v := _code.scroll_vertical
		var at_line := _code.get_caret_line()
		var at_col := _code.get_caret_column()
		_hold_guard()   # (replacing the text moves the caret; that is not the user's doing)
		_code.text = text
		_code.scroll_vertical = v
		_code.set_caret_line(mini(at_line, _code.get_line_count() - 1), false)
		_code.set_caret_column(at_col, false)
		_marked.clear()
		_exec_shown = -1
		_code.clear_executing_lines()
		for i in _code.get_line_count():
			_code.set_line_background_color(i, LINK_NONE)
	_link_apply(scroll)


# ---------------------------------------------------------------- the code the running game runs
# The game runs each file as it was when it started. While it runs, the Generated Code tab shows that code: when it is
# not the graph's current code (unsaved changes, a save made since, a file changed outside Schematic) a notice above
# the code says so, the line <-> node link works from the records of the running code (for the nodes still in the
# graph), and the line the game is stopped at is marked. Nothing here applies while no game runs.

const EXEC_BG := Color(0.25, 0.85, 0.5, 0.3)   # the line the game is stopped at (selection highlights are amber)
var _game_on := false
var _sessions: Dictionary = {}     # debugger session ids that have started and not stopped
var _run_texts: Dictionary = {}    # path -> the file's whole text when the game started
var _run_recs: Dictionary = {}     # path -> _run_rec()
var _run_gen := 0
var _exec: Array = []              # [path, line] the line of the running code the game is stopped at (the frame shown)
var _exec_shown := -1              # the code view line (0-based) marked as executing right now
var _shown_cache: Dictionary = {}
var _painting_gutter := false
var _exec_scroll_serial := 0


## What the game runs for `path`: {code, bp, exact, link, lines, map, pins, blocks}. The file holds its own graph, so
## compiling that graph gives the code and every record of it; `exact` is true when that compile is the file's code
## (then link, lines (node key -> line), map, pins and blocks are those records). It is false for a file whose code was
## changed outside Schematic: then only the code is known. {} while no game runs, or for a file that is not a Schematic.
func _run_rec(path: String) -> Dictionary:
	if not _game_on or path == "":
		return {}
	if _run_recs.has(path):
		return _run_recs[path]
	var text := String(_run_texts.get(path, ""))
	if text == "" and FileAccess.file_exists(path):
		text = FileAccess.get_file_as_string(path)   # (a schematic first looked at during the run: as it is now)
		_run_texts[path] = text
	var rec := {}
	var bp := Model.parse_source(text) if text != "" else {}
	if not bp.is_empty():
		var cut := Model.graph_block_at(text)
		var code := (text.substr(0, cut) if cut > 0 else text).replace("\r\n", "\n").strip_edges(false, true) + "\n"
		rec = {"code": code, "bp": bp, "exact": false, "link": null, "lines": {}, "map": {}, "pins": {}, "blocks": []}
		var c := Compiler.new()
		var made := c.compile(bp.duplicate(true))
		if Model.normalize_code(made) == Model.normalize_code(code):
			rec.merge({"exact": true, "link": CodeLink.new().build(c, made), "lines": c.node_lines.duplicate(),
				"map": c.line_map.duplicate(), "pins": c.pin_exprs, "blocks": c.block_lines}, true)
	_run_recs[path] = rec
	return rec


## What the Generated Code tab shows for the open document: {text, running, differs, notice, rec}. The graph's current
## code, unless the game is running code that is not that: then the running code (`differs`) and the notice.
func _shown() -> Dictionary:
	var preview := String(doc.get("preview", doc.code))
	var key := [_run_gen, String(doc.path), preview.hash(), bool(doc.dirty), String(doc.get("drift", ""))]
	if _shown_cache.get("key") == key:
		return _shown_cache.out
	var rec := _run_rec(String(doc.path))
	var out := {"text": preview, "running": not rec.is_empty(), "differs": false, "notice": "", "rec": rec}
	if not rec.is_empty() and Model.normalize_code(String(rec.code)) != Model.normalize_code(preview):
		out.differs = true
		out.text = String(rec.code)
		var why := "The graph was saved after the game started."
		if not bool(rec.exact) or String(doc.get("drift", "")) in ["code", "replaced"]:
			why = "The file was changed outside Schematic."
		elif bool(doc.dirty):
			why = "The graph has unsaved changes."
		out.notice = "Showing the saved code the game is running. " + why
	_shown_cache = {"key": key, "out": out}
	return out


## The line <-> node lookup of what the code view shows (null when the running code has no records).
func _shown_link() -> Object:
	var s := _shown()
	return s.rec.get("link") if bool(s.differs) else _get_link()


## The code view line (0-based) the game is stopped at, -1 when it is not stopped in the open document. With Show Flow
## and Values on, a node's first line is its `__sc_trace(...)` call, which is where its breakpoint stops: the line
## marked is then the node's own statement after it.
func _exec_line0() -> int:
	if _exec.size() != 2 or doc.is_empty() or String(_exec[0]) != String(doc.path):
		return -1
	var line := int(_exec[1])
	var link := _shown_link()
	if link != null and link.kind_of_line(line) == "trace":
		var at: Array = link.nodes_at(line)
		if not at.is_empty():
			for l in link.own_lines_of(int(at[0][0]), int(at[0][1])):
				if l > line and link.kind_of_line(l) != "trace":
					return l - 1
	return line - 1


## Marks the line the game is stopped at: the code view's executing arrow and a background of its own. On the lines a
## selection paints, the stop line keeps its own colour.
func _exec_paint() -> void:
	var want := _exec_line0()
	var count := _code.get_line_count()
	if _exec_shown != want and _exec_shown >= 0 and _exec_shown < count:
		_code.set_line_as_executing(_exec_shown, false)
		_code.set_line_background_color(_exec_shown, _marked.get(_exec_shown, LINK_NONE))
	var moved := _exec_shown != want
	_exec_shown = want if want < count else -1
	if _exec_shown >= 0:
		_code.set_line_as_executing(_exec_shown, true)
		_code.set_line_background_color(_exec_shown, EXEC_BG)
		if moved:
			_exec_scroll.call_deferred()   # (it follows each step)


## Scrolls the line the game is stopped at into view (a few lines of context above it), when it is not.
func _exec_scroll() -> void:
	# (a stop can hide the Schematic screen for a moment: a scroll made while the view is hidden, or in the frame it is
	# shown again before its layout, is lost, so wait until it is visible and laid out)
	var serial := _exec_scroll_serial + 1
	_exec_scroll_serial = serial
	var waited := 0
	while is_inside_tree() and _code != null and not _code.is_visible_in_tree() and waited < 120:
		await get_tree().process_frame
		waited += 1
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if serial != _exec_scroll_serial:
		return   # (a later call does it)
	var l := _exec_line0()
	if l < 0 or _code == null or doc.is_empty() or _right_tabs.current_tab != 1 or l >= _code.get_line_count():
		return
	var top := _code.get_first_visible_line()
	var bottom := top + maxi(_code.get_visible_line_count() - 1, 0)
	if l < top + 2 or l > bottom - 2:
		_code.set_line_as_first_visible(maxi(l - 3, 0))


## Puts the gutter's breakpoint marks on the lines of the nodes that have a breakpoint, in the code shown.
func _paint_breakpoints() -> void:
	_painting_gutter = true
	_code.clear_breakpointed_lines()
	var s := _shown()
	var lines: Dictionary = s.rec.get("lines", {}) if bool(s.differs) else doc.get("node_lines", {})
	var count := _code.get_line_count()
	for key in _breaks(String(doc.path)):
		var l := int(lines.get(key, 0)) - 1
		if l >= 0 and l < count:
			_code.set_line_as_breakpoint(l, true)
	_painting_gutter = false


## A click in the code view's breakpoint gutter: toggles the breakpoint of the node that wrote that line, as F9 on
## that node does. The marks are then put back to what the breakpoints are.
func _on_code_breakpoint(line0: int) -> void:
	if _painting_gutter or doc.is_empty():
		return
	var link := _shown_link()
	var at: Array = link.nodes_at(line0 + 1) if link != null else []
	if at.is_empty():
		toast("Breakpoints go on nodes: no node wrote line %d." % (line0 + 1) if link != null else "This code was changed outside Schematic: its lines are not linked to nodes.")
	else:
		var gid := int(at[0][0])
		var nid := int(at[0][1])
		if Model.find_node(Model.find_graph(doc.bp, gid), nid).is_empty():
			toast("The node that wrote line %d is no longer in the graph." % (line0 + 1))
		else:
			if gid != int(doc.graph_id):
				doc.graph_id = gid
				_refresh_graph()
				_refresh_members()
				_refresh_graph_tabs()
			toggle_breakpoints([nid])
	(func():
		if _code != null and not doc.is_empty():
			_paint_breakpoints()).call_deferred()   # (the gutter has set its own mark after this signal)


# ---------------------------------------------------------------- code <-> nodes

## Counters the self-test reads: how often the selection handler ran, how many caret moves were seen and acted on,
## how many times the lookup was built and how many times highlights were applied.
var link_stats := {"selection_runs": 0, "caret_events": 0, "caret_acts": 0, "builds": 0, "applies": 0}
var _marked: Dictionary = {}       # code line (0-based) -> LINK_STRONG / LINK_SOFT, what is painted right now
var _guarding := false             # true while the editor itself moves the caret, scrolls or selects for the code view
var _guard_gen := 0
var _caret_serial := 0
var _link_queued := false


## The editor is about to change the caret or the selection because of the other view: what that causes
## (caret_changed arrives deferred, the selection handler runs at once) is not the user acting. Released a frame later.
func _hold_guard() -> void:
	_guarding = true
	_guard_gen += 1
	var gen := _guard_gen
	get_tree().process_frame.connect(func():
		if gen == _guard_gen:
			_guarding = false, CONNECT_ONE_SHOT)


## The link works whenever a document is open, also while the game runs or is stopped at a node (it never touches the
## game: a clicked line selects a node, nothing more).
func _link_active() -> bool:
	return not doc.is_empty()


## The line <-> node lookup of the open document's current compile. Built the first time it is needed after a compile.
func _get_link() -> Object:
	if doc.is_empty():
		return null
	if doc.get("link") != null:
		return doc.link
	var src: Variant = doc.get("link_src")
	if src == null:
		return null
	doc["link"] = CodeLink.new().build(src[0], src[1])
	link_stats["builds"] = int(link_stats.builds) + 1
	return doc.link


func _clear_marks() -> void:
	if _code == null:
		return
	var count := _code.get_line_count()
	for line in _marked:
		if int(line) < count:
			_code.set_line_background_color(int(line), LINK_NONE)
	_marked.clear()


## Paints the lines of the nodes selected in the graph on the code view. Nothing is built or painted while the code
## tab is not showing. `scroll` brings the first painted line into view (a few lines of context above it).
func _link_apply(scroll := false) -> void:
	_clear_marks()
	if _code == null or _view == null or doc.is_empty() or _right_tabs.current_tab != 1 or not _link_active():
		return
	_link_paint(scroll)
	_paint_breakpoints()
	_exec_paint()
	if scroll and _marked.is_empty():
		_exec_scroll()


func _link_paint(scroll: bool) -> void:
	var ids: Array = _view.selected_ids()
	if ids.is_empty():
		return
	var s := _shown()
	var link := _shown_link()
	if link == null:
		if bool(s.differs):
			_set_code_label("The code the game runs was changed outside Schematic: its lines are not linked to nodes.")
		return
	link_stats["applies"] = int(link_stats.applies) + 1
	var gid := int(doc.graph_id)
	var count := _code.get_line_count()
	if bool(s.differs):
		# nodes of the graph on screen that the running code does not have (added since it was saved)
		var run_g := Model.find_graph(s.rec.bp, gid)
		var missing := []
		for id in ids:
			if Model.find_node(run_g, int(id)).is_empty():
				var n := Model.find_node(cur_graph(), int(id))
				missing.append(String(R.describe(n, doc.bp, cur_graph()).title) if not n.is_empty() else "Node")
		if not missing.is_empty():
			_set_code_label("%s: not in the code the game is running (%s)." % [", ".join(missing),
				"added since the game started" if not bool(doc.dirty) else "the graph has unsaved changes"])
	for id in ids:
		for line in link.lines_of(gid, int(id)):
			if line - 1 < count and not _marked.has(line - 1):
				_marked[line - 1] = LINK_SOFT
		for line in link.own_lines_of(gid, int(id)):
			if line - 1 < count:
				_marked[line - 1] = LINK_STRONG
	if _marked.is_empty():
		return
	var first := count
	for line in _marked:
		_code.set_line_background_color(int(line), _marked[line])
		first = mini(first, int(line))
	if scroll:
		var top := _code.get_first_visible_line()
		var bottom := top + maxi(_code.get_visible_line_count() - 1, 0)
		if first < top + 2 or first > bottom - 2:
			_code.set_line_as_first_visible(maxi(first - 3, 0))


## The same, once the current round of editing has finished (the graph was rebuilt, the text may be replaced next).
func _link_refresh_soon() -> void:
	if _link_queued or not is_inside_tree():
		return
	_link_queued = true
	(func():
		_link_queued = false
		_link_apply(false)).call_deferred()


func _set_code_label(text: String) -> void:
	if text == "":
		text = _idle_label()
	if _code_label:
		_code_label.text = text
		_code_label.tooltip_text = text


## What the label under the code says when no line was clicked: nothing, unless a game is running.
func _idle_label() -> String:
	if doc.is_empty() or not _game_on:
		return ""
	if _exec.size() == 2 and String(_exec[0]) == String(doc.path):
		var title := debug_node_title(String(doc.path), int(_paused[1]), int(_paused[2])) if _paused.size() == 3 and String(_paused[0]) == String(doc.path) else ""
		return "Game stopped at line %d%s." % [_exec_line0() + 1, (": " + title) if title != "" else ""]
	if _run_rec(String(doc.path)).is_empty():
		return "The game is running."
	return "The game is running: this is the code it runs (%s)." % String(doc.path).get_file()


## The caret moved in the code view. A click, the arrow keys and Page Down all come here; the line it rests on after
## a short pause is the one that counts (a drag over many lines acts once, on the line where it ends).
func _on_code_caret() -> void:
	link_stats["caret_events"] = int(link_stats.caret_events) + 1
	if _guarding or not _link_active() or _right_tabs.current_tab != 1:
		return
	_caret_serial += 1
	var serial := _caret_serial
	await get_tree().create_timer(CARET_DEBOUNCE).timeout
	while is_inside_tree() and serial == _caret_serial and _code.has_focus() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		await get_tree().process_frame   # (the button is still down: the drag has not ended)
	if not is_inside_tree() or serial != _caret_serial or _guarding or not _link_active():
		return
	_code_line_clicked(_code.get_caret_line())


## Selects, in the graph, what wrote the clicked line (0-based `line0`) and marks the nodes whose values feed it;
## shows the other graph first when the line belongs to one. A line no node wrote selects nothing and is named.
func _code_line_clicked(line0: int) -> void:
	if _view == null:
		return
	var s := _shown()
	var link := _shown_link()
	var line := line0 + 1
	if link == null:
		if bool(s.differs):
			link_stats["caret_acts"] = int(link_stats.caret_acts) + 1
			_hold_guard()
			_view.show_selection([], [], false)
			_set_code_label("Line %d: the code the game runs was changed outside Schematic, so its lines are not linked to nodes." % line)
		return
	link_stats["caret_acts"] = int(link_stats.caret_acts) + 1
	var src_bp: Dictionary = s.rec.bp if bool(s.differs) else doc.bp   # (the graph the shown code was compiled from)
	var nodes: Array = link.nodes_at(line)
	var kind: String = link.kind_of_line(line)
	if nodes.is_empty() and kind == "function":
		var fg := Model.find_graph(src_bp, link.graph_of_line(line))
		for n in fg.get("nodes", []):
			if String(n.kind) == "fn_entry":
				nodes = [[int(fg.id), int(n.id)]]
				break
	_hold_guard()
	if not nodes.is_empty() and Model.find_node(Model.find_graph(doc.bp, int(nodes[0][0])), int(nodes[0][1])).is_empty():
		# running code whose node was deleted from the graph since
		_view.show_selection([], [], false)
		_set_code_label("Line %d: written by a node that is no longer in the graph." % line)
		return
	if nodes.is_empty():
		_view.show_selection([], [], false)
		var what: String = CodeLink.LABELS.get(kind, "")
		_set_code_label("Line %d: %s" % [line, what if what != "" else "Blank line"])
		return
	var gid := int(nodes[0][0])
	if gid != int(doc.graph_id):
		if Model.find_graph(doc.bp, gid).is_empty():
			return
		doc.graph_id = gid
		_refresh_graph()
		_refresh_members()
		_refresh_graph_tabs()
	var soft := []
	for i in range(1, nodes.size()):
		if int(nodes[i][0]) == gid:
			soft.append(int(nodes[i][1]))
	_view.show_selection([int(nodes[0][1])], soft, true)
	var g := Model.find_graph(doc.bp, gid)
	var title := ""
	var n := Model.find_node(g, int(nodes[0][1]))
	if not n.is_empty():
		title = String(R.describe(n, doc.bp, g).title)
	_set_code_label(("Line %d: Comment on %s" if kind == "comment" else "Line %d: %s") % [line, title if title != "" else "Node"])


func _find_in_schematic() -> void:
	if doc.is_empty():
		return
	var items := []
	for g in doc.bp.graphs:
		for n in g.nodes:
			var d := R.describe(n, doc.bp, g)
			var label := String(d.title)
			if label == "" and not d.outs.is_empty():
				label = String(d.outs[0].name)
			if n.kind == "comment":
				label = "Comment: " + label
			items.append({"label": "%s   (%s)%s" % [label, g.name, NodeVisual.comment_digest(n.p)], "value": [int(g.id), int(n.id)]})   # (the comment's words are in the label, so they are searched)
	W.popup_search(_graph_tabs, items, func(v):
		doc.graph_id = v[0]
		_refresh_graph()
		_refresh_graph_tabs()
		_refresh_members()
		_view.focus_node.call_deferred(v[1]), "Find in Schematic")


# ---------------------------------------------------------------- palette

func open_palette(screen_pos: Vector2, ctx: Dictionary, on_pick: Callable) -> void:
	var bp: Dictionary = doc.bp
	var g := cur_graph()
	var title := "Add node"
	if not ctx.is_empty():
		var tn := "Exec" if ctx.type == "exec" else ("Wildcard" if ctx.type == "any" else String(ctx.type))
		title = ("Actions taking a %s" if ctx.out else "Actions providing a %s") % tn
		if ctx.type == "exec":
			title = "Executable Actions"
	R.editing_path = String(doc.path)
	var provider := func(context_sensitive: bool) -> Array:
		var acts: Array = []
		acts.append_array(R.schematic_actions(bp, g))
		acts.append_array(R.static_actions())
		var classes := []
		var cls := R.self_class(bp)
		if not ctx.is_empty() and T.is_object(String(ctx.type)):
			cls = String(ctx.type)
			var guard := 0
			while cls != "" and guard < 64:
				classes.append(cls)
				cls = T.parent_of(cls)
				guard += 1
			cls = R.self_class(bp)
		var guard2 := 0
		while cls != "" and guard2 < 64:
			if not classes.has(cls):
				classes.append(cls)
			cls = T.parent_of(cls)
			guard2 += 1
		if context_sensitive:
			for c in classes:
				acts.append_array(R.class_actions(c))
			acts.append_array(R.function_library_actions())
		else:
			acts.append_array(R.all_class_actions())
		if g.get("kind", "") in ["function", "macro"]:
			acts = acts.filter(func(a): return not a.k in ["event", "custom_event", "input_action", "signal_event", "key_event"])
		if g.get("kind", "") == "function":
			acts.append(R._act("Add Return Node", "Flow Control", "fn_return", {}))
		if not ctx.is_empty() and context_sensitive:
			acts = acts.filter(func(a): return _fits(a, bp, g, ctx))
		if not ctx.is_empty() and String(ctx.type) != "exec":
			acts.push_front(R._act("Promote to Variable", "Variables", "__promote", {}, "Creates a new variable of this pin's type and wires it up.", "new variable"))
		return acts
	_palette.open(screen_pos, title, provider, on_pick)


## Every node of every schematic file in the project: [{label, value: [path, graph_id, node_id]}].
func all_schematic_nodes() -> Array:
	var files := []
	_scan("res://", files)
	var items := []
	for f in files:
		var path := String(f.value)
		var d := _find_doc(path)
		var fbp: Dictionary = d.bp if not d.is_empty() else Model.load_file(path)
		for g in fbp.get("graphs", []):
			for n in g.nodes:
				var nd := R.describe(n, fbp, g)
				var label := String(nd.title)
				if label == "" and not nd.outs.is_empty():
					label = String(nd.outs[0].name)
				if n.kind == "comment":
					label = "Comment: " + label
				items.append({"label": "%s   (%s > %s)%s" % [label, path.get_file().get_basename(), g.name, NodeVisual.comment_digest(n.p)], "value": [path, int(g.id), int(n.id)]})
	return items


func find_in_all_schematics() -> void:
	W.popup_search(_doc_tabs if _doc_tabs.visible else self, all_schematic_nodes(), func(v):
		if not open_schematic(v[0]):
			return
		doc.graph_id = v[1]
		_refresh_graph()
		_refresh_graph_tabs()
		_refresh_members()
		_view.focus_node.call_deferred(v[2]), "Find in Schematics")


func _fits(act: Dictionary, bp: Dictionary, g: Dictionary, ctx: Dictionary) -> bool:
	if act.k == "__assign":
		return ctx.out and (String(ctx.type) == "exec" or T.matches(String(ctx.type), String(act.p.cls)))
	if not act.has("_sig"):
		var d := R.describe({"kind": act.k, "p": act.p, "id": 0, "d": {}}, bp, g)
		var ins := []
		var outs := []
		for p in d.ins: ins.append(p.type)
		for p in d.outs: outs.append(p.type)
		act["_sig"] = [ins, outs]
	var types: Array = act._sig[0] if ctx.out else act._sig[1]
	var ct := String(ctx.type)
	for t in types:
		if ct == "exec" or t == "exec":
			if ct == t:
				return true
			continue
		if ctx.out and T.matches(ct, t):
			return true
		if not ctx.out and T.matches(t, ct):
			return true
		if t == "any" and act.k in ["print", "select", "reroute", "index", "set_index", "make_array", "op", "expr", "var_set", "local_set"]:
			return true
		if ctx.out and t == "String" and act.k == "print":
			return true
		if ctx.out and t == "bool" and ct == "bool":
			return true
	return false


# ---------------------------------------------------------------- My Schematic

const SEC_GRAPHS := 0
const SEC_FUNCS := 1
const SEC_VARS := 2
const SEC_DISP := 3
const SEC_LOCALS := 4
const SEC_MACROS := 5
const SEC_ENUMS := 6

func _refresh_members() -> void:
	_members.clear()
	if doc.is_empty():
		return
	var bp: Dictionary = doc.bp
	var root := _members.create_item()
	var sec := func(title: String, id: int, tip: String, extra := false) -> TreeItem:
		var it := _members.create_item(root)
		it.set_text(0, title)
		it.set_selectable(0, false)
		it.set_custom_color(0, Color(1, 1, 1, 0.55))
		it.set_custom_bg_color(0, Color(1, 1, 1, 0.05))
		it.add_button(0, W.icon("Add"), id, false, tip)
		if extra:
			it.add_button(0, W.icon("Override") if W.icon("Override") else W.icon("MethodOverride"), 100, false, "Override a function of the parent class")
		return it
	var s_graphs: TreeItem = sec.call("GRAPHS", SEC_GRAPHS, "Add a custom event")
	for g in bp.graphs:
		if g.kind != "event":
			continue
		var gi := _members.create_item(s_graphs)
		gi.set_text(0, g.name)
		gi.set_icon(0, W.icon("GraphEdit"))
		gi.set_metadata(0, {"kind": "graph", "id": int(g.id)})
		for n in g.nodes:
			if n.kind in ["event", "custom_event", "input_action", "signal_event", "key_event"]:
				var ei := _members.create_item(gi)
				ei.set_text(0, String(R.describe(n, bp, g).title))
				ei.set_icon(0, W.icon("Signal") if n.kind != "custom_event" else W.icon("MemberSignal"))
				ei.set_metadata(0, {"kind": "node_ref", "graph": int(g.id), "id": int(n.id), "name": n.p.get("name", ""), "custom": n.kind == "custom_event"})
	var s_funcs: TreeItem = sec.call("FUNCTIONS", SEC_FUNCS, "Add a function", true)
	for g in bp.graphs:
		if g.kind != "function":
			continue
		var fi := _members.create_item(s_funcs)
		fi.set_text(0, g.name)
		fi.set_icon(0, W.icon("MemberMethod"))
		fi.set_metadata(0, {"kind": "graph", "id": int(g.id), "fn": true, "name": g.name})
	var s_macros: TreeItem = sec.call("MACROS", SEC_MACROS, "Add a macro")
	for g in bp.graphs:
		if g.kind != "macro":
			continue
		var mi := _members.create_item(s_macros)
		mi.set_text(0, g.name)
		mi.set_icon(0, W.icon("GraphEdit"))
		mi.set_metadata(0, {"kind": "graph", "id": int(g.id), "fn": true, "macro": true, "name": g.name})
	var s_vars: TreeItem = sec.call("VARIABLES", SEC_VARS, "Add a variable")
	for v in bp.variables:
		var vi := _members.create_item(s_vars)
		vi.set_text(0, v.name)
		vi.set_icon(0, W.swatch(T.color(String(v.type))))
		vi.set_tooltip_text(0, "%s : %s\n%s" % [v.name, v.type, v.get("tooltip", "")])
		vi.set_metadata(0, {"kind": "var", "name": v.name})
		# Unreal shows the type beside the name and an eye that toggles Instance Editable.
		vi.set_suffix(0, "  " + String(v.type))
		var shown: bool = v.get("export", false)
		vi.add_button(0, W.icon("GuiVisibilityVisible") if shown else W.icon("GuiVisibilityHidden"), 200, false,
			"Instance Editable: shown in the Inspector. Click to hide." if shown else "Not Instance Editable. Click to show this variable in the Inspector.")
		if not shown:
			vi.set_button_color(0, 0, Color(1, 1, 1, 0.35))
	var s_enums: TreeItem = sec.call("ENUMERATIONS", SEC_ENUMS, "Add an enumeration")
	for be in bp.get("enums", []):
		var ei2 := _members.create_item(s_enums)
		ei2.set_text(0, be.name)
		ei2.set_icon(0, W.icon("Enum"))
		ei2.set_suffix(0, "(%d)" % be.values.size())
		ei2.set_metadata(0, {"kind": "enum", "name": be.name})
	var s_disp: TreeItem = sec.call("EVENT DISPATCHERS", SEC_DISP, "Add an event dispatcher (signal)")
	for dsp in bp.dispatchers:
		var di := _members.create_item(s_disp)
		di.set_text(0, dsp.name)
		di.set_icon(0, W.icon("MemberSignal"))
		di.set_metadata(0, {"kind": "dispatcher", "name": dsp.name})
	var g := cur_graph()
	if g.get("kind", "") in ["function", "macro"]:
		var s_loc: TreeItem = sec.call("LOCAL VARIABLES (%s)" % g.name, SEC_LOCALS, "Add a local variable")
		for l in g.locals:
			var li := _members.create_item(s_loc)
			li.set_text(0, l.name)
			li.set_icon(0, W.swatch(T.color(String(l.type))))
			li.set_metadata(0, {"kind": "local", "name": l.name})
	_filter_members()
	# keep selection highlight
	var it := root.get_next_in_tree()
	while it:
		var m: Variant = it.get_metadata(0)
		if typeof(m) == TYPE_DICTIONARY and m.get("kind", "") == _sel.kind and m.get("name", "?") == _sel.get("name", "!"):
			it.select(0)
		it = it.get_next_in_tree()


## Hides My Schematic rows that do not match the search box (section headers always stay).
func _filter_members() -> void:
	var root := _members.get_root()
	if root == null or _members_search == null:
		return
	var q := _members_search.text.strip_edges().to_lower()
	for sec in root.get_children():
		for it in sec.get_children():
			var hit := q == "" or it.get_text(0).to_lower().contains(q)
			for sub in it.get_children():
				var sub_hit := q == "" or sub.get_text(0).to_lower().contains(q)
				sub.visible = sub_hit
				hit = hit or sub_hit
			it.visible = hit


func _on_member_button(item: TreeItem, _col: int, id: int, _mb: int) -> void:
	var names := Model.member_names(doc.bp)
	match id:
		SEC_GRAPHS:
			var g: Dictionary = {}
			for gg in doc.bp.graphs:
				if gg.kind == "event":
					g = gg
					break
			if g.is_empty():
				return
			doc.graph_id = int(g.id)
			_refresh_graph()
			_view.spawn("custom_event", {"name": "CustomEvent", "params": []}, _view.to_graph_pos(_view.size * 0.5))
		SEC_FUNCS:
			var nm := Model.unique_name("NewFunction", names)
			mutate("Add Function", func():
				var g := Model.new_graph(doc.bp, nm, "function")
				doc.graph_id = int(g.id))
			_select({"kind": "graph", "id": int(doc.graph_id), "name": nm})
		SEC_MACROS:
			var nm := Model.unique_name("NewMacro", names)
			mutate("Add Macro", func():
				var g := Model.new_graph(doc.bp, nm, "macro")
				doc.graph_id = int(g.id))
			_select({"kind": "graph", "id": int(doc.graph_id), "name": nm})
		SEC_VARS:
			var nm := Model.unique_name("NewVar", names)
			mutate("Add Variable", func():
				doc.bp.variables.append({"name": nm, "type": "bool", "default": "", "export": false, "category": "", "tooltip": ""}))
			_select({"kind": "var", "name": nm})
		SEC_ENUMS:
			var nm := Model.unique_name("NewEnum", names)
			mutate("Add Enumeration", func():
				if not doc.bp.has("enums"):
					doc.bp["enums"] = []
				doc.bp.enums.append({"name": nm, "values": ["First", "Second"]}))
			_select({"kind": "enum", "name": nm})
		SEC_DISP:
			var nm := Model.unique_name("NewEventDispatcher", names)
			mutate("Add Event Dispatcher", func(): doc.bp.dispatchers.append({"name": nm, "params": []}))
			_select({"kind": "dispatcher", "name": nm})
		SEC_LOCALS:
			var g := cur_graph()
			var taken := names.duplicate()
			for l in g.locals:
				taken.append(l.name)
			var nm := Model.unique_name("LocalVar", taken)
			mutate("Add Local Variable", func(): g.locals.append({"name": nm, "type": "bool", "default": ""}))
			_select({"kind": "local", "name": nm})
		100:
			_override_dialog()
		200:
			var meta: Variant = item.get_metadata(0)
			if typeof(meta) == TYPE_DICTIONARY and meta.get("kind", "") == "var":
				var vname := String(meta.name)
				mutate("Toggle Instance Editable", func():
					var v := Model.find_var(doc.bp, vname)
					if not v.is_empty():
						v["export"] = not v.get("export", false))
				_select({"kind": "var", "name": vname})


func _override_dialog() -> void:
	var items := []
	var seen := {}
	var cls := R.self_class(doc.bp)
	var guard := 0
	while cls != "" and guard < 64:
		var info := R.cls_info(cls)
		for mn in info.m:
			if R.is_overridable(cls, info.m[mn]) and not seen.has(mn):
				seen[mn] = true
				items.append({"label": "%s   (%s)" % [R.nice(mn), cls], "value": mn, "icon": W.icon("MemberMethod")})
		cls = T.parent_of(cls)
		guard += 1
	if T.is_a(R.self_class(doc.bp), "Node") and Model.graph_named(doc.bp, "ConstructionScript").is_empty():
		items.push_front({"label": "Construction Script   (runs in the editor and when spawned)", "value": "__construct", "icon": W.icon("Tools")})
	W.popup_search(_members, items, func(mn: String):
		if mn == "__construct":
			mutate("Add Construction Script", func():
				var cg := Model.new_graph(doc.bp, "ConstructionScript", "function")
				doc.graph_id = int(cg.id))
			return
		var m := R.find_method(R.self_class(doc.bp), mn)
		if T.from_info(m.get("return", {}), true) == "":
			for g in doc.bp.graphs:
				if g.kind == "event":
					doc.graph_id = int(g.id)
					_refresh_graph()
					_refresh_graph_tabs()
					_view.spawn("event", {"name": mn}, _view.to_graph_pos(_view.size * 0.5))
					return
			return
		if not Model.graph_named(doc.bp, mn).is_empty():
			open_member_graph(mn)
			return
		mutate("Override Function", func():
			var g := Model.new_graph(doc.bp, mn, "function")
			for a in m.args:
				g.inputs.append([String(a.name), T.from_info(a)])
			g.outputs.append(["return_value", T.from_info(m["return"], true)])
			doc.graph_id = int(g.id)), "Override Function")


func _on_member_selected() -> void:
	var it := _members.get_selected()
	if it == null:
		return
	var m: Variant = it.get_metadata(0)
	if typeof(m) != TYPE_DICTIONARY:
		return
	match m.kind:
		"var", "local", "dispatcher", "enum":
			_select(m, false)
		"graph":
			_select({"kind": "graph", "id": m.id, "name": m.get("name", "")}, false)


func _on_member_activated() -> void:
	var it := _members.get_selected()
	if it == null:
		return
	var m: Variant = it.get_metadata(0)
	if typeof(m) != TYPE_DICTIONARY:
		return
	match m.kind:
		"graph":
			doc.graph_id = int(m.id)
			_refresh_graph()
			_refresh_graph_tabs()
			_refresh_members()
		"node_ref":
			doc.graph_id = int(m.graph)
			_refresh_graph()
			_refresh_graph_tabs()
			_view.focus_node.call_deferred(int(m.id))


func _on_member_rmb(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var it := _members.get_selected()
	if it == null or typeof(it.get_metadata(0)) != TYPE_DICTIONARY:
		return
	var m: Dictionary = it.get_metadata(0)
	if m.kind == "node_ref" or (m.kind == "graph" and not m.get("fn", false)):
		return
	var pm := PopupMenu.new()
	pm.add_icon_item(W.icon("Remove"), "Delete", 0)
	pm.id_pressed.connect(func(_id): _delete_member(m))
	pm.popup_hide.connect(pm.queue_free)
	add_child(pm)
	pm.position = Vector2i(_members.get_screen_position() + pos)
	pm.popup()


func _on_members_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode == KEY_DELETE:
		var it := _members.get_selected()
		if it and typeof(it.get_metadata(0)) == TYPE_DICTIONARY:
			_delete_member(it.get_metadata(0))
			_members.accept_event()


func _delete_member(m: Dictionary) -> void:
	match m.kind:
		"var":
			mutate("Delete Variable", func(): doc.bp.variables = doc.bp.variables.filter(func(v): return v.name != m.name))
		"enum":
			mutate("Delete Enumeration", func():
				doc.bp.enums = doc.bp.enums.filter(func(v): return v.name != m.name)
				for v in doc.bp.variables:
					if String(v.get("enum", "")) == String(m.name):
						v.erase("enum"))
		"dispatcher":
			mutate("Delete Event Dispatcher", func(): doc.bp.dispatchers = doc.bp.dispatchers.filter(func(v): return v.name != m.name))
		"local":
			var g := cur_graph()
			mutate("Delete Local Variable", func(): g.locals = g.locals.filter(func(v): return v.name != m.name))
		"graph":
			if not m.get("fn", false):
				return
			mutate("Delete Function", func():
				doc.bp.graphs = doc.bp.graphs.filter(func(g): return int(g.id) != int(m.id))
				if int(doc.graph_id) == int(m.id):
					doc.graph_id = int(doc.bp.graphs[0].id))
	_select({"kind": "class"})


func _member_drag(at: Vector2) -> Variant:
	var it := _members.get_item_at_position(at)
	if it == null or typeof(it.get_metadata(0)) != TYPE_DICTIONARY:
		return null
	var m: Dictionary = it.get_metadata(0)
	var data := {}
	match m.kind:
		"var", "local", "dispatcher":
			data = {"type": "bp_member", "kind": m.kind, "name": m.name}
		"graph":
			if m.get("fn", false):
				data = {"type": "bp_member", "kind": "macro" if m.get("macro", false) else "fn", "name": m.name}
		"node_ref":
			if m.get("custom", false):
				data = {"type": "bp_member", "kind": "event", "name": m.name}
	if data.is_empty():
		return null
	var l := Label.new()
	l.text = it.get_text(0)
	_members.set_drag_preview(l)
	return data


## Double-click on a macro that lives in a macro library: open the library at that macro.
func open_library_macro(path: String, macro: String) -> void:
	if open_schematic(path):
		open_member_graph(macro)


## After a macro library is saved, every schematic that uses one of its macros is compiled again, because
## macros are copied into the schematics that use them at compile time. Returns how many were recompiled.
func _recompile_users(lib_path: String, seen := {}) -> int:
	if seen.has(lib_path):
		return 0
	seen[lib_path] = true
	var files := []
	_scan("res://", files)
	var count := 0
	for it in files:
		var path := String(it.value)
		if seen.has(path):
			continue
		var open_doc := _find_doc(path)
		var ubp: Dictionary = open_doc.bp if not open_doc.is_empty() else Model.load_file(path)
		var uses := false
		for g in ubp.get("graphs", []):
			for n in g.nodes:
				if n.kind == "macro" and String(n.p.get("lib", "")) == lib_path:
					uses = true
		if not uses:
			continue
		if not open_doc.is_empty():
			# unsaved edits stay unsaved; a file changed outside Schematic is not rewritten
			if not open_doc.dirty and not _may_write(open_doc):
				recompile_skipped.append(path)
				_check(open_doc)
				continue
			var save := not bool(open_doc.dirty)
			if compile_doc(open_doc, save):
				count += 1
				if save and String(ubp.get("library", "")) == "macro":
					count += _recompile_users(path, seen)
			continue
		# not open: the fingerprint in the file says whether its code was edited since a Schematic writer wrote it
		var text := FileAccess.get_file_as_string(path)
		if Model.code_edited(text):
			recompile_skipped.append(path)
			continue
		count += 1
		var c := Compiler.new()
		var code := c.compile(ubp)
		if c.errors.any(func(e): return not e.w):
			toast("%s uses %s and no longer compiles: open it to see why." % [path.get_file(), lib_path.get_file()])
			continue
		if not _write_schematic(path, Model.build_source(code, ubp)):
			continue
		if String(ubp.get("library", "")) == "macro":
			R.invalidate_libraries()
			count += _recompile_users(path, seen)
	return count


func open_member_graph(member: String) -> void:
	var g := Model.graph_named(doc.bp, member)
	if not g.is_empty():
		doc.graph_id = int(g.id)
		_refresh_graph()
		_refresh_graph_tabs()
		_refresh_members()
		return
	for gg in doc.bp.graphs:
		for n in gg.nodes:
			if n.kind == "custom_event" and n.p.get("name", "") == member:
				doc.graph_id = int(gg.id)
				_refresh_graph()
				_refresh_graph_tabs()
				_view.focus_node.call_deferred(int(n.id))
				return


# ---------------------------------------------------------------- Components (scene nodes)

func find_host() -> Node:
	if doc.is_empty():
		return null
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var s := n.get_script() as Script
		if s and s.resource_path == doc.path:
			return n
		for c in n.get_children():
			if c == root or c.owner == root:
				stack.append(c)
	return null


func node_ref_params(host: Node, node: Node) -> Dictionary:
	var path := String(host.get_path_to(node))
	if node.unique_name_in_owner and (node.owner == host or node.owner == host.owner):
		path = "%" + String(node.name)
	var cls := node.get_class()
	var s := node.get_script() as Script
	if s and s.get_global_name() != &"":
		cls = String(s.get_global_name())
	return {"path": path, "cls": cls}


func _refresh_components() -> void:
	_components.clear()
	if doc.is_empty():
		return
	var host := find_host()
	var root := _components.create_item()
	if host == null:
		root.set_text(0, "(open a scene that uses this schematic)")
		root.set_custom_color(0, Color(1, 1, 1, 0.4))
		root.set_selectable(0, false)
		return
	root.set_text(0, "%s (self)" % host.name)
	root.set_icon(0, W.class_icon(host.get_class()))
	root.set_metadata(0, {"node": host, "path": ".", "cls": host.get_class()})
	_add_component_children(host, host, root)


func _add_component_children(host: Node, node: Node, item: TreeItem) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	for c in node.get_children():
		if c.owner != scene_root and c != scene_root:
			continue
		var it := _components.create_item(item)
		it.set_text(0, c.name)
		it.set_icon(0, W.class_icon(c.get_class()))
		var prm := node_ref_params(host, c)
		it.set_metadata(0, {"node": c, "path": prm.path, "cls": prm.cls})
		it.set_tooltip_text(0, "%s : %s" % [prm.path, prm.cls])
		_add_component_children(host, c, it)


func _component_drag(at: Vector2) -> Variant:
	var it := _components.get_item_at_position(at)
	if it == null or typeof(it.get_metadata(0)) != TYPE_DICTIONARY:
		return null
	var m: Dictionary = it.get_metadata(0)
	var l := Label.new()
	l.text = it.get_text(0)
	_components.set_drag_preview(l)
	return {"type": "bp_component", "path": m.path, "cls": m.cls}


func _on_component_clicked(pos: Vector2, button: int) -> void:
	var it := _components.get_selected()
	if it == null or typeof(it.get_metadata(0)) != TYPE_DICTIONARY:
		return
	var m: Dictionary = it.get_metadata(0)
	if button != MOUSE_BUTTON_RIGHT or not is_instance_valid(m.node):
		return
	var items := []
	for s in (m.node as Node).get_signal_list():
		items.append({"label": "On " + R.nice(String(s.name)), "value": s, "icon": W.icon("Signal")})
	items.sort_custom(func(a, b): return a.label < b.label)
	W.popup_search(_components, items, func(s: Dictionary):
		for g in doc.bp.graphs:
			if g.kind == "event":
				if int(doc.graph_id) != int(g.id):
					doc.graph_id = int(g.id)
					_refresh_graph()
					_refresh_graph_tabs()
				break
		_view.spawn("signal_event", {"path": m.path, "signal": String(s.name), "cls": m.cls, "args": R.signal_args(s)},
			_view.to_graph_pos(_view.size * 0.5)), "Add Event for %s" % it.get_text(0))


# ---------------------------------------------------------------- Details

func graph_selection_changed(ids: Array) -> void:
	link_stats["selection_runs"] = int(link_stats.selection_runs) + 1
	if ids.size() == 1:
		_select({"kind": "node", "id": ids[0]}, false)
	elif _sel.kind == "node":
		_select({"kind": "class"}, false)
	# The selection's lines get painted; the code view only scrolls to them when the user chose the nodes in the
	# graph (a selection that follows a click in the code view must not move that view).
	if not _guarding:
		_set_code_label("")
	_link_apply(not _guarding)


func focus_details() -> void:
	_right_tabs.current_tab = 0


func _select(sel: Dictionary, refresh_members := true) -> void:
	_sel = sel
	if refresh_members:
		_refresh_members()
	_refresh_details()
	_update_code()


## Starts a collapsible Details category (Unreal's dark header band with an arrow). Rows added afterwards go in it.
func _section(text: String) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.set_meta("category", text)
	var head := Button.new()
	head.text = text
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.focus_mode = Control.FOCUS_NONE
	head.set_meta("category_header", true)
	var bold := EditorInterface.get_editor_theme().get_font("bold", "EditorFonts") if EditorInterface.get_editor_theme() else null
	if bold:
		head.add_theme_font_override("font", bold)
	head.add_theme_font_size_override("font_size", W.si(13))
	head.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	for state in ["normal", "hover", "pressed", "focus"]:
		var band := StyleBoxFlat.new()
		band.bg_color = W.CHROME if state != "hover" else W.EDGE
		band.border_width_bottom = W.si(1)
		band.border_width_top = W.si(1)
		band.border_color = Color(0, 0, 0, 0.55)
		band.content_margin_left = W.si(6)
		band.content_margin_right = W.si(6)
		band.content_margin_top = W.si(5)
		band.content_margin_bottom = W.si(5)
		head.add_theme_stylebox_override(state, band)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	var apply := func():
		var shut: bool = _cat_collapsed.get(text, false)
		body.visible = not shut
		head.icon = W.icon("GuiTreeArrowRight") if shut else W.icon("GuiTreeArrowDown")
	head.pressed.connect(func():
		_cat_collapsed[text] = not _cat_collapsed.get(text, false)
		apply.call())
	apply.call()
	box.add_child(head)
	box.add_child(body)
	_details.add_child(box)
	_cat_body = body


func _cat_add(control: Control) -> void:
	if _cat_body == null:
		_section(_details_title.text if _details_title.text != "" else "Details")
	if control is PanelContainer or control is MarginContainer:
		_cat_body.add_child(control)
		return
	# Free-form content (parameter lists, add buttons, previews) gets the same inset as the rows.
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", W.si(18))
	m.add_theme_constant_override("margin_right", W.si(6))
	m.add_theme_constant_override("margin_top", W.si(3))
	m.add_theme_constant_override("margin_bottom", W.si(3))
	m.add_child(control)
	_cat_body.add_child(m)


## Right-click > Add Comment / Edit Comment: selects the node and puts the cursor in its Comment box.
func edit_node_note(nid: int) -> void:
	_select({"kind": "node", "id": nid}, false)
	focus_details()
	for te in _details.find_children("*", "TextEdit", true, false):
		if te.has_meta("node_note"):
			te.grab_focus()
			te.select_all()


## A multi-line text box for a Details row; `on_commit(text)` runs when it loses focus with changed text.
func _text_box(text: String, on_commit: Callable) -> TextEdit:
	var te := TextEdit.new()
	te.text = text
	te.custom_minimum_size = W.sv(Vector2(0, 66))
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.scroll_fit_content_height = true
	te.add_theme_font_size_override("font_size", W.si(13))
	var shown := [text]   # (what the box held when last committed: the panel is not rebuilt after an edit)
	te.focus_exited.connect(func():
		if te.text != shown[0]:
			shown[0] = te.text
			on_commit.call(te.text))
	return te


## A one-line box for a Details row that, like _text_box, commits when it loses focus.
func _live_line(text: String, on_commit: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	var shown := [text]
	le.text_submitted.connect(func(_t): le.release_focus())
	le.focus_exited.connect(func():
		if le.text != shown[0]:
			shown[0] = le.text
			on_commit.call(le.text))
	return le


## What the Comment box of a node, variable or signal writes: `holder.note` made from the text by
## NodeVisual.note_from_text (so lines left alone stay as they were), or no note for an empty box. One undo step.
func set_note(holder: Dictionary, text: String) -> void:
	var made := NodeVisual.note_from_text(holder.get("note", []), text)
	if made == holder.get("note", []) or (made.is_empty() and not holder.has("note")):
		return
	mutate("Edit Comment", func():
		if made.is_empty():
			holder.erase("note")
		else:
			holder["note"] = made)


## The same for the comment at the end of the statement's line (`tail`).
func set_tail(holder: Dictionary, text: String) -> void:
	var made := NodeVisual.tail_from_text(String(holder.get("tail", "")), text)
	if made == String(holder.get("tail", "")):
		return
	mutate("Edit Comment After the Line", func():
		if made == "":
			holder.erase("tail")
		else:
			holder["tail"] = made)


## The Details rows of a node's comments: the `#` lines above its statement and the comment at the end of its line.
## (An entry node's are its function's.) What a node of a hand-made graph gets here is written the same way.
func _comment_rows(n: Dictionary) -> void:
	var p: Dictionary = n.p
	_section("Comment")
	var box := _text_box("\n".join(NodeVisual.note_plain(p.get("note", []))), func(t: String): set_note(p, t))
	box.set_meta("node_note", true)
	box.placeholder_text = "Written as # lines above this node's line of code"
	_row("Comment (# above the line)", box, "One comment per line, without the #. Written into the code above this node's line, at the same indentation; empty removes it. A line you begin with # is written as typed (## stays ##).")
	var tl := _live_line(NodeVisual.tail_plain(String(p.get("tail", ""))), func(t: String): set_tail(p, t))
	tl.set_meta("node_tail", true)
	tl.placeholder_text = "Written at the end of the node's line"
	_row("Comment after the line", tl, "Written at the end of this node's line of code, after two spaces and a #.")


## The Comment box of a variable or a signal: its `note`, the # lines written above its declaration.
func _member_note_row(holder: Dictionary) -> void:
	var box := _text_box("\n".join(NodeVisual.note_plain(holder.get("note", []))), func(t: String): set_note(holder, t))
	box.set_meta("node_note", true)
	box.placeholder_text = "Written as # lines above the declaration"
	_row("Comment (# above the line)", box, "One comment per line, without the #. Written into the code above the declaration; empty removes it. (The Description is the ## line Godot shows as a tooltip.)")


## One Details row: name on the left, value on the right, a hairline under it.
func edit_node_comment(nid: int) -> void:
	_select({"kind": "node", "id": nid}, false)
	focus_details()
	for le in _details.find_children("*", "LineEdit", true, false):
		if le.has_meta("node_comment"):
			le.grab_focus()
			le.select_all()


func _row(label: String, control: Control, tip := "", reset := Callable()) -> void:
	var pc := PanelContainer.new()
	pc.set_meta("row_label", label.to_lower())
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.105, 0.105, 0.11)
	sb.border_width_bottom = W.si(1)
	sb.border_color = Color(0, 0, 0, 0.5)
	sb.content_margin_left = W.si(18)
	sb.content_margin_right = W.si(6)
	sb.content_margin_top = W.si(3)
	sb.content_margin_bottom = W.si(3)
	pc.add_theme_stylebox_override("panel", sb)
	pc.mouse_entered.connect(func(): sb.bg_color = Color(0.135, 0.135, 0.14))
	pc.mouse_exited.connect(func(): sb.bg_color = Color(0.105, 0.105, 0.11))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", W.si(8))
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = W.s(132)
	l.clip_text = true
	if label.length() > 20:   # (a long name wraps instead of being cut: the Comment rows)
		l.clip_text = false
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	l.add_theme_font_size_override("font_size", W.si(13))
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	l.tooltip_text = tip if tip != "" else label
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	hb.add_child(l)
	var div := ColorRect.new()
	div.color = Color(0, 0, 0, 0.45)
	div.custom_minimum_size.x = W.s(1)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(div)
	if control is LineEdit or control is BaseButton:
		control.add_theme_font_size_override("font_size", W.si(13))
	if control is CheckBox:
		control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var filler := Control.new()
		filler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(control)
		hb.add_child(filler)
	else:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(control)
	if reset.is_valid():
		# Unreal's yellow arrow: shown only while the value differs from its default.
		var rb := Button.new()
		rb.icon = W.icon("Reload")
		rb.flat = true
		rb.focus_mode = Control.FOCUS_NONE
		rb.tooltip_text = "Reset to default"
		rb.set_meta("reset_arrow", true)
		rb.add_theme_color_override("icon_normal_color", Color(1.0, 0.8, 0.25))
		rb.pressed.connect(reset)
		hb.add_child(rb)
	pc.add_child(hb)
	_cat_add(pc)


## Hides the rows that do not match the search text, and the categories left with nothing to show.
func _filter_details() -> void:
	var q := _details_search.text.strip_edges().to_lower() if _details_search else ""
	for box in _details.get_children():
		if not box.has_meta("category"):
			continue
		var body: Control = box.get_child(1)
		var any := false
		for r in body.get_children():
			var hit: bool = q == "" or (r.has_meta("row_label") and String(r.get_meta("row_label")).contains(q)) or String(box.get_meta("category")).to_lower().contains(q)
			r.visible = hit
			any = any or hit
		box.visible = any or q == ""
		if q != "":
			body.visible = true
		else:
			body.visible = not _cat_collapsed.get(String(box.get_meta("category")), false)


func _line(text: String, on_commit: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.text_submitted.connect(func(_t): le.release_focus())
	le.focus_exited.connect(func():
		if le.text != text:
			on_commit.call(le.text))
	return le


func _check_box(on: bool, on_toggle: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = on
	cb.toggled.connect(on_toggle)
	return cb


func _note(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	l.add_theme_font_size_override("font_size", W.si(12))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", W.si(18))
	m.add_theme_constant_override("margin_right", W.si(8))
	m.add_theme_constant_override("margin_top", W.si(6))
	m.add_theme_constant_override("margin_bottom", W.si(6))
	m.add_child(l)
	_cat_add(m)


func _refresh_details() -> void:
	if _details == null:
		return
	for c in _details.get_children():
		_details.remove_child(c)
		c.queue_free()
	_cat_body = null
	_details.add_theme_constant_override("separation", 0)
	if _class_btn:
		_class_btn.set_pressed_no_signal(not doc.is_empty() and _sel.kind == "class")
		_defaults_btn.set_pressed_no_signal(not doc.is_empty() and _sel.kind == "defaults")
	if doc.is_empty():
		return
	_fill_details()
	_filter_details()


func _fill_details() -> void:
	var bp: Dictionary = doc.bp
	match _sel.kind:
		"class":
			_details_title.text = "Class Settings"
			var pb := Button.new()
			pb.text = R.self_class(bp)
			pb.icon = W.class_icon(R.self_class(bp))
			pb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			pb.pressed.connect(func():
				var items := []
				for t in W.all_types():
					if T.is_object(t) and t != String(bp.get("class_name", "")):
						items.append({"label": t, "value": t, "icon": W.class_icon(t)})
				W.popup_search(pb, items, func(cls):
					mutate("Reparent Schematic", func(): bp.parent = cls)
					_refresh_details()
					_refresh_doc_tabs(), "Reparent Schematic"))
			_row("Parent Class", pb, "The class this schematic extends.")
			_row("Class Name", _line(String(bp.get("class_name", "")), func(t: String):
				var cn := T.ident(t.strip_edges()) if t.strip_edges() != "" else ""
				mutate("Set Class Name", func(): bp["class_name"] = cn)
				_refresh_details()), "Registers the schematic as a global class so other schematics can cast to it and call it.")
			var kinds := ["", "function", "macro", "data", "interface"]
			var kob := OptionButton.new()
			for label in ["Schematic Class", "Function Library", "Macro Library", "Data Asset", "Schematic Interface"]:
				kob.add_item(label)
			kob.select(maxi(kinds.find(String(bp.get("library", ""))), 0))
			kob.item_selected.connect(func(i):
				mutate("Set Schematic Type", func():
					if kinds[i] == "":
						bp.erase("library")
					else:
						bp["library"] = kinds[i])
				_refresh_details())
			_row("Schematic Type", kob, "Function Library: every function is static, so any schematic can call it without an instance (needs a Class Name; variables are shared by the whole game). Macro Library: its macros appear in every schematic's action menu.")
			if String(bp.get("library", "")) == "function":
				_note("Function library: its functions are listed under Function Libraries > %s in every schematic. They can't use events, self or anything that needs a node in the scene." % (String(bp.get("class_name", "")) if String(bp.get("class_name", "")) != "" else "(set a Class Name)"))
			elif String(bp.get("library", "")) == "data":
				_note("Data asset: every variable is a field. Use it as the row structure of a Data Table (FileSystem > Create New > Data Table), or make single assets of it in the Inspector. Graphs get Make %s and Break %s nodes." % [String(bp.get("class_name", "it")), String(bp.get("class_name", "it"))])
			elif String(bp.get("library", "")) == "macro":
				_note("Macro library: its macros are listed under Macros > %s in every schematic. Saving it recompiles the schematics that use them." % doc.path.get_file().get_basename())
			elif String(bp.get("library", "")) == "interface":
				_note("Schematic Interface: each function here is a name with inputs and outputs, and no code. A schematic implements it under Class Settings > Interfaces. Call the functions on any object with the nodes under Interface Messages > %s." % (String(bp.get("class_name", "")) if String(bp.get("class_name", "")) != "" else "(set a Class Name)"))
			if String(bp.get("library", "")) == "":
				_interface_rows(bp)
			_row("Run in Editor", _check_box(bool(bp.get("tool", false)), func(on):
				mutate("Toggle Tool", func(): bp["tool"] = on)), "Adds @tool: events also run inside the editor (construction-script style).")
			_row("Show Flow and Values", _check_box(bool(bp.get("trace", false)), func(on):
				mutate("Toggle Execution Flow", func(): bp["trace"] = on)), "Debug aid: while the game runs from the editor, nodes light up as they execute and each wired input pin shows the last value it received. Adds tracing calls to the generated code, so turn it off before shipping (exporting a release warns about files that still have it on). A value is shown only where reading it a second time changes nothing: not a random number, and not a call that runs in place. Static functions are not traced.")
			_row("Description", _line(String(bp.get("description", "")), func(t: String):
				mutate("Set Description", func(): bp["description"] = t)))
			_note("File: %s\n\nThis schematic compiles to plain GDScript in the same file, so it attaches to nodes, exports variables to the Inspector and is callable from any script exactly like hand-written GDScript." % doc.path)
		"defaults":
			_details_title.text = "Class Defaults"
			if bp.variables.is_empty():
				_note("This schematic has no variables yet. Add one in Members to edit its default here.")
			var by_cat := {}
			var order := []
			for dv in bp.variables:
				var cat := String(dv.get("category", "")) if String(dv.get("category", "")) != "" else "Default"
				if not by_cat.has(cat):
					by_cat[cat] = []
					order.append(cat)
				by_cat[cat].append(dv)
			for cat in order:
				_section(cat)
				for dv in by_cat[cat]:
					var dvar: Dictionary = dv
					var ded := W.make_value_editor(String(dvar.type), ("@" + String(dvar.enum)) if (String(dvar.type) == "int" and String(dvar.get("enum", "")) != "") else "", String(dvar.get("default", "")), func(lit: String):
						if String(dvar.get("default", "")) != lit:
							mutate("Set Default Value", func(): dvar["default"] = lit, false), false)
					if ded:
						_row(String(dvar.name), ded, String(dvar.get("tooltip", "")), _default_reset(dvar))
					else:
						var none := Label.new()
						none.text = T.default_literal(String(dvar.type))
						none.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
						_row(String(dvar.name), none, "No inline editor for %s." % dvar.type)
			if not bp.variables.is_empty():
				_section("About")
				_note("Per-instance values are set in Godot's Inspector on each node that uses this schematic (Instance Editable variables).")
		"var", "local":
			var is_local: bool = _sel.kind == "local"
			var g := cur_graph()
			var v := {}
			for cand in (g.locals if is_local else bp.variables):
				if cand.name == _sel.name:
					v = cand
			if v.is_empty():
				_details_title.text = ""
				return
			_details_title.text = "Local Variable" if is_local else "Variable"
			_row("Variable Name", _line(String(v.name), func(t: String): _rename_member(_sel.kind, String(v.name), t)))
			_row("Variable Type", W.make_type_button(String(v.type), func(t: String):
				mutate("Change Variable Type", func():
					v.type = t
					v.default = ""
					v.erase("enum")
					# a type chosen here is the type from now on, however an imported script declared it
					for flag in ["written", "untyped", "infer", "hint"]:
						v.erase(flag))
				_refresh_details()))
			if not is_local and String(v.type) == "int" and not bp.get("enums", []).is_empty():
				var eob := OptionButton.new()
				eob.add_item("(plain integer)")
				var enames := []
				for be in bp.enums:
					enames.append(String(be.name))
					eob.add_item(String(be.name))
					if String(v.get("enum", "")) == String(be.name):
						eob.select(eob.item_count - 1)
				eob.item_selected.connect(func(i):
					mutate("Set Variable Enum", func():
						if i == 0:
							v.erase("enum")
						else:
							v["enum"] = enames[i - 1]
						v.default = "")
					_refresh_details())
				_row("Enumeration", eob, "Use one of this schematic's enumerations: pins and the Inspector then show a dropdown.")
			if not is_local:
				_row("Instance Editable", _check_box(bool(v.get("export", false)), func(on):
					mutate("Toggle Instance Editable", func(): v["export"] = on)), "Shows the variable in the Inspector (@export).")
				_row("Expose on Spawn", _check_box(bool(v.get("spawn", false)), func(on):
					mutate("Toggle Expose on Spawn", func(): v["spawn"] = on)), "Adds this variable as a pin on Spawn Scene nodes that spawn a scene using this schematic. The value is set before Ready runs.")
				_row("Notify On Change", _check_box(bool(v.get("notify", false)), func(on):
					var fn_name := "on_%s_changed" % T.ident(String(v.name))
					mutate("Toggle Notify On Change", func():
						v["notify"] = on
						if on and Model.graph_named(bp, fn_name).is_empty():
							Model.new_graph(bp, fn_name, "function"))
					_refresh_details()), "Calls the function on_<name>_changed every time the variable is set (like RepNotify / OnRep).")
				_row("Category", _line(String(v.get("category", "")), func(t: String):
					mutate("Set Category", func(): v["category"] = t)))
				_row("Description (## doc, shown as tooltip)", _line(String(v.get("tooltip", "")), func(t: String):
					mutate("Set Tooltip", func(): v["tooltip"] = t)), "The ## line above the variable; Godot shows it as the variable's tooltip.")
				_member_note_row(v)
			_section("Default Value")
			var ed := W.make_value_editor(String(v.type), ("@" + String(v.enum)) if (String(v.type) == "int" and String(v.get("enum", "")) != "") else "", String(v.get("default", "")), func(lit: String):
				if String(v.get("default", "")) != lit:
					mutate("Set Default Value", func(): v["default"] = lit, false), false)
			if ed:
				_row(String(v.name), ed, "", _default_reset(v))
			else:
				_note("No inline editor for %s. It starts as %s." % [v.type, T.default_literal(String(v.type))])
		"enum":
			var be := {}
			for cand in bp.get("enums", []):
				if cand.name == _sel.name:
					be = cand
			if be.is_empty():
				return
			_details_title.text = "Enumeration"
			_row("Name", _line(String(be.name), func(t: String):
				var nn := T.ident(t.strip_edges())
				if nn == "_" or Model.member_names(bp).has(nn):
					toast("'%s' is already used in this schematic" % nn)
				else:
					var old := String(be.name)
					mutate("Rename Enumeration", func():
						be["name"] = nn
						for v in bp.variables:
							if String(v.get("enum", "")) == old:
								v["enum"] = nn)
					_sel["name"] = nn
				_refresh_members()
				_refresh_details()))
			_section("Values")
			for i in be.values.size():
				var idx: int = i
				var row := HBoxContainer.new()
				var le := _line(String(be.values[i]), func(t: String):
					mutate("Rename Enum Value", func(): be.values[idx] = T.ident(t.strip_edges()))
					_refresh_details())
				le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(le)
				var del := Button.new()
				del.icon = W.icon("Remove")
				del.flat = true
				del.pressed.connect(func():
					mutate("Remove Enum Value", func(): be.values.remove_at(idx))
					_refresh_details())
				row.add_child(del)
				_cat_add(row)
			var addv := Button.new()
			addv.text = "Add Value"
			addv.icon = W.icon("Add")
			addv.pressed.connect(func():
				mutate("Add Enum Value", func(): be.values.append(Model.unique_name("NewValue", be.values)))
				_refresh_details())
			_cat_add(addv)
			_note("Compiles to a GDScript enum inside this class, so other scripts can use %s.%s.<Value>. Set an integer variable's Enumeration to this to get dropdowns on pins and in the Inspector." % [bp.get("class_name", "ThisClass") if String(bp.get("class_name", "")) != "" else "ThisClass", be.name])
		"dispatcher":
			var dsp := Model.find_dispatcher(bp, _sel.name)
			if dsp.is_empty():
				return
			_details_title.text = "Event Dispatcher"
			_row("Name", _line(String(dsp.name), func(t: String): _rename_member("dispatcher", String(dsp.name), t)))
			_member_note_row(dsp)
			_section("Inputs")
			_cat_add(W.make_param_list(dsp.get("params", []), func(list: Array):
				mutate("Edit Dispatcher Inputs", func(): dsp["params"] = list)
				_refresh_details()))
			_note("Compiles to a GDScript signal. Use 'Call %s' to broadcast it; other scripts connect to it like any signal." % dsp.name)
		"graph":
			var g := Model.find_graph(bp, int(_sel.id))
			if g.is_empty():
				return
			_graph_details(g)
		"node":
			var g := cur_graph()
			var n := Model.find_node(g, int(_sel.id))
			if n.is_empty():
				_details_title.text = ""
				return
			_node_details(g, n)


## Reset arrow for a variable's default value; empty Callable (no arrow) while the default is untouched.
## Class Settings > Interfaces: the interfaces this schematic implements, and a button to add one.
func _interface_rows(bp: Dictionary) -> void:
	# (the list of interfaces is made anew when a Schematic is saved or the project's files change: see _init and
	# R.invalidate_libraries. Doing it here as well read every Schematic of the project each time this panel was shown.)
	var mine: Array = bp.get("interfaces", [])
	for iname in mine:
		var rm := Button.new()
		rm.text = "Remove %s" % iname
		rm.icon = W.icon("Remove")
		rm.pressed.connect(func():
			mutate("Remove Interface", func():
				var list: Array = bp.get("interfaces", []).duplicate()
				list.erase(iname)
				if list.is_empty():
					bp.erase("interfaces")
				else:
					bp["interfaces"] = list)
			_refresh_details())
		_row("Implements", rm, "This schematic has every function of %s. Removing the interface keeps the functions." % iname)
	var choices := []
	for iname in R.interfaces():
		if not mine.has(iname):
			choices.append(String(iname))
	var add := _tool_menu("Add Interface", choices, func(i: int): implement_interface(String(choices[i])),
		"Make this schematic implement a Schematic Interface: its functions are added to Members for you to fill in.", "Add")
	add.disabled = choices.is_empty()
	_row("Interfaces", add, "Schematic Interfaces are made with New Schematic Class > Schematic Interface." if not choices.is_empty() or not mine.is_empty() else "There is no Schematic Interface in this project yet. Make one with New Schematic Class > Schematic Interface.")


## Lists `iface` among the interfaces of the open schematic and adds a function graph for each of its
## functions the schematic does not have yet.
func implement_interface(iface: String) -> void:
	if doc.is_empty():
		return
	var bp: Dictionary = doc.bp
	mutate("Implement Interface", func():
		var list: Array = bp.get("interfaces", []).duplicate()
		if not list.has(iface):
			list.append(iface)
		bp["interfaces"] = list
		for ig in R.interface_functions(iface):
			if not Model.graph_named(bp, String(ig.name)).is_empty() or not Model.find_custom_event(bp, String(ig.name)).is_empty():
				continue
			var f := Model.new_graph(bp, String(ig.name), "function")
			f.inputs = ig.inputs.duplicate(true)
			f.outputs = ig.outputs.duplicate(true)
			f.wires.append([int(f.nodes[0].id), "then", int(f.nodes[1].id), "exec"]))
	_refresh_details()
	_refresh_members()
	_refresh_graph_tabs()


func _default_reset(v: Dictionary) -> Callable:
	if String(v.get("default", "")) == "":
		return Callable()
	return func():
		mutate("Reset Default Value", func(): v["default"] = "")
		_refresh_details()


func _graph_details(g: Dictionary) -> void:
	if g.kind == "macro":
		_details_title.text = "Macro"
		_row("Macro Name", _line(String(g.name), func(t: String): _rename_member("macro", String(g.name), t)))
		_section("Inputs")
		_cat_add(W.make_param_list(g.inputs, func(list: Array):
			mutate("Edit Macro Inputs", func(): g.inputs = list)
			_refresh_details(), "Add Input", true))
		_section("Outputs")
		_cat_add(W.make_param_list(g.outputs, func(list: Array):
			mutate("Edit Macro Outputs", func(): g.outputs = list)
			_refresh_details(), "Add Output", true))
		_note("A macro is expanded into every graph that uses it, so it can have several exec inputs and outputs and may contain latent nodes. Each use keeps its own state (Do Once, Flip Flop, Delay...).")
		return
	if g.kind != "function":
		_details_title.text = "Event Graph"
		_note("The event graph holds events (Ready, Process, input actions, signals, custom events). Latent nodes such as Delay are allowed here.")
		return
	_details_title.text = "Function"
	if String(g.name) == "ConstructionScript":
		_details_title.text = "Construction Script"
		_note("Runs when the node becomes ready, in the game and in the editor, and again whenever an Instance Editable variable changes in the Inspector. Use it to build or lay out the node from its settings. Gameplay events (Ready, Process, input) do not run in the editor unless Class Settings > Run in Editor is on.")
		return
	_row("Function Name", _line(String(g.name), func(t: String): _rename_member("fn", String(g.name), t)))
	_row("Pure", _check_box(bool(g.pure), func(on): mutate("Toggle Pure", func(): g.pure = on)), "Pure functions have no exec pins and are evaluated whenever their outputs are read.")
	_section("Inputs")
	_cat_add(W.make_param_list(g.inputs, func(list: Array):
		mutate("Edit Function Inputs", func(): g.inputs = list)
		_refresh_details()))
	_section("Outputs")
	_cat_add(W.make_param_list(g.outputs, func(list: Array):
		mutate("Edit Function Outputs", func(): g.outputs = list)
		_refresh_details(), "Add Output"))


func _node_details(g: Dictionary, n: Dictionary) -> void:
	var d := R.describe(n, doc.bp, g)
	_details_title.text = String(d.title) if d.title != "" else R.nice(n.kind)
	var p: Dictionary = n.p
	match n.kind:
		"custom_event":
			_row("Event Name", _line(String(p.name), func(t: String): _rename_member("event", String(p.name), t)))
			var modes := ["", "server", "multicast", "owner"]
			var rob := OptionButton.new()
			for label in ["Not Replicated", "Run on Server", "Multicast", "Run on Owning Client"]:
				rob.add_item(label)
			rob.select(maxi(modes.find(String(p.get("rpc", ""))), 0))
			rob.item_selected.connect(func(i):
				mutate("Set Event Replication", func(): p["rpc"] = modes[i])
				_refresh_details())
			_row("Replicates", rob, "Compiles to a Godot @rpc function. Calling the event sends it over the network and also runs it locally.")
			if String(p.get("rpc", "")) != "":
				_row("Reliable", _check_box(bool(p.get("reliable", true)), func(on): mutate("Toggle Reliable", func(): p["reliable"] = on, false)))
			_section("Inputs")
			_cat_add(W.make_param_list(p.get("params", []), func(list: Array):
				mutate("Edit Event Inputs", func(): p["params"] = list)
				_refresh_details()))
		"fn_entry", "fn_return", "macro_in", "macro_out":
			_graph_details(g)
			if n.kind in ["fn_entry", "fn_return"]:
				_comment_rows(n)
			return
		"timeline":
			_timeline_details(n)
		"comment":
			_row("Comment", _line(String(p.get("text", "")), func(t: String): mutate("Edit Comment", func(): p["text"] = t)))
		"get_node":
			_row("Node Path", _line(String(p.get("path", ".")), func(t: String): mutate("Edit Node Path", func(): p["path"] = t)), "Path relative to this schematic's node. Use %Name for scene-unique nodes.")
			_row("Node Class", W.make_type_button(String(p.get("cls", "Node")), func(t: String):
				mutate("Edit Node Class", func(): p["cls"] = t), false))
		"format":
			_row("Format", _line(String(p.get("text", "")), func(t: String): mutate("Edit Format", func(): p["text"] = t)), "Every {name} becomes an input pin.")
		"expr":
			_row("Expression", _line(String(p.get("code", "")), func(t: String): mutate("Edit Expression", func(): p["code"] = t)), "Any GDScript expression using the input names.")
			_row("Inputs", _line(", ".join(PackedStringArray(p.get("ins", []))), func(t: String):
				var names := []
				for part in t.split(",", false):
					names.append(T.ident(part.strip_edges()))
				mutate("Edit Expression Inputs", func(): p["ins"] = names)), "Comma-separated input names.")
		"code":
			var te := TextEdit.new()
			te.text = String(p.get("code", ""))
			te.custom_minimum_size = W.sv(Vector2(0, 140))
			te.focus_exited.connect(func():
				if te.text != String(p.get("code", "")):
					mutate("Edit Code", func(): p["code"] = te.text))
			_row("Code", te, "GDScript lines, run as written.")
			_row("Inputs", _line(", ".join(PackedStringArray(p.get("ins", []))), func(t: String):
				var names := []
				for part in t.split(",", false):
					names.append(T.ident(part.strip_edges()))
				mutate("Edit Code Inputs", func(): p["ins"] = names)), "Comma-separated input names. Each becomes a pin; its value replaces the name in the code.")
		"input_action":
			var items := []
			for prop in ProjectSettings.get_property_list():
				if String(prop.name).begins_with("input/"):
					items.append(String(prop.name).substr(6))
			var ob := OptionButton.new()
			if not items.has(String(p.action)):
				items.append(String(p.action))
			for i in items.size():
				ob.add_item(items[i])
				if items[i] == String(p.action):
					ob.select(i)
			ob.item_selected.connect(func(i): mutate("Change Input Action", func(): p["action"] = items[i]))
			_row("Input Action", ob, "Actions come from Project Settings > Input Map.")
		"table_row":
			var tinfo := R.table_info(String(p.get("table", "")))
			_row("Data Table", _line(String(p.get("table", "")), func(t: String):
				var path := t.strip_edges()
				var ninfo := R.table_info(path)
				mutate("Set Data Table", func():
					p["table"] = path
					p["cls"] = String(ninfo.cls))
				_refresh_details()), "Path of the Data Table (.tres). Dragging the file from the FileSystem dock into the graph sets it for you.")
			if not tinfo.rows.is_empty():
				var names: Array = tinfo.rows
				var current := String(n.d.get("row", "")).trim_prefix("&").trim_prefix("\"").trim_suffix("\"")
				var nob := OptionButton.new()
				nob.add_item("(type or wire a name)")
				for rn in names:
					nob.add_item(String(rn))
					if String(rn) == current:
						nob.select(nob.item_count - 1)
				nob.item_selected.connect(func(i):
					mutate("Pick Row", func():
						if i == 0:
							n.d.erase("row")
						else:
							n.d["row"] = "&\"%s\"" % String(names[i - 1]).c_escape())
					_refresh_details())
				_row("Row", nob, "The rows of this table.")
			_note("Row structure: %s" % tinfo.cls)
		"make_data":
			_row("Class", W.make_type_button(String(p.cls), func(t: String): mutate("Change Class", func(): p["cls"] = t), false))
		"cast", "new":
			_row("Class", W.make_type_button(String(p.cls), func(t: String): mutate("Change Class", func(): p["cls"] = t), false))
		"switch":
			_section("Cases")
			var cases: Array = p.get("cases", [])
			var is_str := String(p.get("t", "int")) == "String"
			for i in cases.size():
				var idx := i
				_row("Case %d" % i, _line(String(cases[i][0]), func(t: String):
					mutate("Edit Case", func():
						cases[idx] = [t, var_to_str(t) if is_str else str(int(t.to_float()))] if String(p.get("enum", "")) == "" else [t, cases[idx][1]])
					_refresh_details()))
		"select", "reroute", "for_each":
			_row("Value Type", W.make_type_button(String(p.get("t", "any")), func(t: String): mutate("Change Type", func(): p["t"] = t)))
		"event_ref":
			_row("Function / Event", _line(String(p.get("fn", "")), func(t: String): mutate("Change Event", func(): p["fn"] = t)))
		"signal_event":
			_row("Node Path", _line(String(p.get("path", ".")), func(t: String): mutate("Edit Node Path", func(): p["path"] = t)))
	if n.kind != "comment":
		if d.pure and not (n.kind == "reroute" and String(p.get("t", "")) == "exec"):
			# (a value node is written inside the line of the node that reads it: no line of its own to carry a comment)
			_section("Comment")
			_note("A value node (no exec pins) is written inside the line of the node that reads it, so it has no line of its own for a comment. Comment that node instead.")
		else:
			_comment_rows(n)
	if not n.kind in ["fn_entry", "fn_return", "macro_in", "macro_out", "comment"]:
		var cle := _line(String(n.get("c", "")), func(t: String):
			mutate("Edit Node Comment", func():
				if t.strip_edges() == "":
					n.erase("c")
				else:
					n["c"] = t.strip_edges()))
		cle.placeholder_text = "Shown in a bubble above the node"
		cle.set_meta("node_comment", true)
		_row("Graph Note", cle, "A note drawn in a bubble above this node. It stays in the graph: it is not written to the code (use Comment for that).")
		_section("About")
	if d.sub != "":
		_note(d.sub)
	if d.tip != "":
		_note(d.tip)
	if d.err != "":
		_note("ERROR: " + d.err)
	if d.pure and n.kind != "reroute":
		_note("Pure node: it has no exec pins and is evaluated each time one of its outputs is read.")
	if d.latent:
		_note("Latent node: execution continues from its output later. Only usable in the Event Graph.")


func _timeline_details(n: Dictionary) -> void:
	var p: Dictionary = n.p
	var length := maxf(float(p.get("length", 1.0)), 0.01)
	_row("Timeline Name", _line(String(p.get("name", "")), func(t: String):
		var nn := T.ident(t.strip_edges())
		if nn == "_" or Model.member_names(doc.bp).has(nn):
			toast("'%s' is already used in this schematic" % nn)
		else:
			mutate("Rename Timeline", func(): p["name"] = nn)
		_refresh_details()))
	_row("Length", _line(str(length), func(t: String):
		mutate("Set Timeline Length", func(): p["length"] = maxf(t.to_float(), 0.01))
		_refresh_details()), "Seconds.")
	_row("Loop", _check_box(bool(p.get("loop", false)), func(on): mutate("Toggle Loop", func(): p["loop"] = on, false)))
	_row("Auto Play", _check_box(bool(p.get("autoplay", false)), func(on): mutate("Toggle Auto Play", func(): p["autoplay"] = on, false)),
		"Starts playing when the node is ready.")
	var tracks: Array = p.get("tracks", [])
	for ti in tracks.size():
		var tr: Dictionary = tracks[ti]
		var tt := String(tr.get("type", "float"))
		_section("Track: %s" % tr.name)
		_row("Track Name", _line(String(tr.name), func(t: String):
			mutate("Rename Track", func(): tr["name"] = T.ident(t.strip_edges()))
			_refresh_details()))
		var types := ["float", "Vector2", "Vector3", "Color", "event"]
		var ob := OptionButton.new()
		for i in types.size():
			ob.add_item(types[i])
			if types[i] == tt:
				ob.select(i)
		ob.item_selected.connect(func(i):
			mutate("Change Track Type", func():
				tr["type"] = types[i]
				for k in tr.keys:
					k[1] = "")
			_refresh_details())
		_row("Track Type", ob)
		if tt == "event":
			_note("Event track: each key fires this track's exec output when playback crosses its time.")
		else:
			_row("Smooth", _check_box(bool(tr.get("smooth", false)), func(on): mutate("Toggle Smooth", func(): tr["smooth"] = on, false)),
				"Ease in and out between keys instead of straight lines.")
		if tt == "float":
			var curve := CurveEdit.new()
			curve.set_meta("curve_edit", true)
			curve.setup(tr.keys, length, bool(tr.get("smooth", false)), func(new_keys: Array):
				mutate("Edit Curve", func(): tr["keys"] = new_keys, false)
				_refresh_details.call_deferred())
			_cat_add(curve)
		var keys: Array = tr.get("keys", [])
		for ki in keys.size():
			var key: Array = keys[ki]
			var row := HBoxContainer.new()
			var tl := Label.new()
			tl.text = "t"
			row.add_child(tl)
			var te := _line(str(float(key[0])), func(t: String):
				mutate("Move Key", func(): key[0] = clampf(t.to_float(), 0.0, length), false)
				_refresh_details())
			te.custom_minimum_size.x = W.s(56)
			row.add_child(te)
			var ed := W.make_value_editor(tt, "", String(key[1]), func(lit: String):
				if String(key[1]) != lit:
					mutate("Change Key Value", func(): key[1] = lit, false)
					_refresh_details.call_deferred(), false)
			if ed:
				ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(ed)
			var del := Button.new()
			del.icon = W.icon("Remove")
			del.flat = true
			del.tooltip_text = "Remove key"
			var kidx := ki
			del.pressed.connect(func():
				mutate("Remove Key", func(): keys.remove_at(kidx), false)
				_refresh_details())
			row.add_child(del)
			_cat_add(row)
		var hb := HBoxContainer.new()
		var add_key := Button.new()
		add_key.text = "Add Key"
		add_key.icon = W.icon("Add")
		add_key.pressed.connect(func():
			mutate("Add Key", func(): keys.append([length, String(keys[-1][1]) if not keys.is_empty() else ""]), false)
			_refresh_details())
		hb.add_child(add_key)
		var del_track := Button.new()
		del_track.text = "Remove Track"
		del_track.icon = W.icon("Remove")
		var tidx := ti
		del_track.pressed.connect(func():
			mutate("Remove Track", func(): tracks.remove_at(tidx))
			_refresh_details())
		hb.add_child(del_track)
		_cat_add(hb)
	var add_track := Button.new()
	add_track.text = "Add Track"
	add_track.icon = W.icon("Add")
	add_track.pressed.connect(func():
		var taken := []
		for tr in tracks:
			taken.append(tr.name)
		mutate("Add Track", func():
			tracks.append({"name": Model.unique_name("NewTrack", taken), "type": "float", "smooth": false, "keys": [[0.0, "0.0"], [length, "1.0"]]})
			p["tracks"] = tracks)
		_refresh_details())
	_cat_add(add_track)


## Renames a variable / function / dispatcher / custom event and every node that refers to it.
func _rename_member(kind: String, old: String, new_text: String) -> void:
	var nn := T.ident(new_text.strip_edges())
	if nn == old or nn == "" or nn == "_":
		_refresh_details()
		return
	if Model.member_names(doc.bp).has(nn):
		toast("'%s' is already used in this schematic" % nn)
		_refresh_details()
		return
	var apply := func():
		var bp: Dictionary = doc.bp
		match kind:
			"var":
				Model.find_var(bp, old)["name"] = nn
			"dispatcher":
				Model.find_dispatcher(bp, old)["name"] = nn
			"fn", "macro":
				Model.graph_named(bp, old)["name"] = nn
			"event":
				Model.find_custom_event(bp, old).p["name"] = nn
			"local":
				for l in cur_graph().locals:
					if l.name == old:
						l.name = nn
		for g in bp.graphs:
			if kind == "local" and int(g.id) != int(doc.graph_id):
				continue
			for n in g.nodes:
				match kind:
					"var":
						if n.kind in ["var_get", "var_set"] and n.p.name == old: n.p.name = nn
					"local":
						if n.kind in ["local_get", "local_set"] and n.p.name == old: n.p.name = nn
					"dispatcher":
						if n.kind == "emit" and n.p.name == old: n.p.name = nn
					"fn", "event":
						if n.kind in ["call_self", "event_ref"] and n.p.fn == old: n.p.fn = nn
					"macro":
						if n.kind == "macro" and n.p.name == old: n.p.name = nn
	mutate("Rename " + old, apply)
	if _sel.has("name"):
		_sel["name"] = nn
	_refresh_members()
	_refresh_details()
