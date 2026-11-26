@tool
extends Window
## The Schematic editor's own window (the toolbar's Make Floating button), so the graph can sit on a second
## monitor while the 2D / 3D view stays in the main editor window. The plugin moves its editors into `box` and
## back; this window only frames them, passes the keys nothing in it used on to the main window (Ctrl+S, undo,
## F5...), and remembers where it was.
##
## Godot floats its own Script editor with a class (WindowWrapper) that scripts cannot use, so this follows it
## by hand: an ordinary child window of the editor, which takes the editor's theme and display scale from the
## tree like any dialog does.

const W := preload("res://addons/schematic/editor/sc_widgets.gd")

var plugin: EditorPlugin
## The editors sit here while the window is up.
var box: VBoxContainer
## True while a key from this window is being offered to the main window.
var forwarding := false
var keys_forwarded := 0   # (for the tests)

var _bg: Panel
var _margins: MarginContainer
var _min_queued := false
var _park: Control      # holds the main window's keyboard focus while keys are passed to it
var _parked: Control    # the control that had it
var _main: Window


## Passes on the keys nothing in the window used. First child of the window, so of everything in the window that
## listens for shortcuts it is asked last.
class Keys extends Node:
	var window: Window

	func _shortcut_input(event: InputEvent) -> void:
		if window.visible and (event is InputEventKey or event is InputEventShortcut):
			window.forward_key(event)


func _init() -> void:
	title = "Schematic - Godot Engine"
	visible = false
	var keys := Keys.new()
	keys.name = "Keys"
	keys.window = self
	add_child(keys)
	_bg = Panel.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_margins = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		_margins.add_theme_constant_override("margin_" + side, W.si(4))
	_margins.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_margins)
	box = VBoxContainer.new()
	_margins.add_child(box)
	_margins.minimum_size_changed.connect(_queue_min_size)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_ENTER_TREE:
		if _bg and has_theme_stylebox("PanelForeground", "EditorStyles"):
			_bg.add_theme_stylebox_override("panel", get_theme_stylebox("PanelForeground", "EditorStyles"))
	elif what == NOTIFICATION_PREDELETE:
		if is_instance_valid(_park):
			_park.queue_free()


# The window can't be made smaller than the editor needs. Godot's own switch for that (wrap_controls) grows a
# window at once to whatever its contents ask for, and a label that wraps asks for a great height for a moment
# when it is first laid out; the window would stay that tall. So the least size is taken a moment later, once
# the layout has settled, and never more than the screen the window is on can show.

func _queue_min_size() -> void:
	if _min_queued or not is_inside_tree():
		return
	_min_queued = true
	await get_tree().process_frame
	if is_inside_tree():
		await get_tree().process_frame
	_min_queued = false
	_apply_min_size()


func _apply_min_size() -> void:
	if not is_inside_tree() or not visible:
		return
	var room := DisplayServer.screen_get_usable_rect(current_screen).size - Vector2i(0, W.si(32))
	var need := Vector2i(_margins.get_combined_minimum_size())
	need = Vector2i(mini(need.x, room.x), mini(need.y, room.y))
	if need != min_size:
		min_size = need


## Shows the window at `rect` (screen pixels), maximized when asked.
func open(rect: Rect2i, maximized: bool) -> void:
	mode = Window.MODE_WINDOWED
	position = rect.position
	size = rect.size
	if maximized:
		mode = Window.MODE_MAXIMIZED
	show()
	_queue_min_size()
	if _main == null:
		_main = EditorInterface.get_base_control().get_window()
		_main.focus_entered.connect(unpark)


func bring_forward() -> void:
	if mode == Window.MODE_MINIMIZED:
		mode = Window.MODE_WINDOWED
	grab_focus()


## Dialogs opened from the floating editor go here, so they come up over this window and not the main one.
func dialog_host() -> Control:
	return _bg


func close_dialogs() -> void:
	for c in _bg.get_children():
		if c is Window:
			c.hide()
			if not c.is_queued_for_deletion():
				c.queue_free()


# ---------------------------------------------------------------- keys for the main window
# The editor's own shortcuts (save, undo, run, the debugger's keys) are heard by the main window only. A key
# nothing here used is given to it, as Godot does for its floating Script editor. Whatever has the keyboard
# focus over there (a script being typed in, the Scene dock's tree) must not get it, since Ctrl+Z or Delete
# would then change something the user is not looking at. So, for as long as keys come from this window, the
# main window's focus rests on a control that does nothing; it goes back where it was when the main window is
# used again.

func forward_key(event: InputEvent) -> void:
	var main := EditorInterface.get_base_control().get_viewport()
	if main == null or main == get_viewport():
		return
	_park_focus(main)
	forwarding = true
	keys_forwarded += 1
	main.push_input(event)
	forwarding = false
	if main.is_input_handled():
		set_input_as_handled()


func _park_focus(main: Viewport) -> void:
	if _park == null:
		_park = Control.new()
		_park.name = "SchematicFocusRest"
		_park.focus_mode = Control.FOCUS_ALL
		_park.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_park.size = Vector2.ZERO
		EditorInterface.get_base_control().add_child(_park)
		# the arrow keys and Tab find no neighbour to move the focus to
		for prop in ["focus_neighbor_left", "focus_neighbor_top", "focus_neighbor_right", "focus_neighbor_bottom", "focus_next", "focus_previous"]:
			_park.set(prop, NodePath("."))
	var has := main.gui_get_focus_owner()
	if has != _park:
		_parked = has
		_park.grab_focus()


## Gives the main window's keyboard focus back to the control that had it.
func unpark() -> void:
	if not is_instance_valid(_park) or not _park.is_inside_tree():
		return
	if _park.get_viewport().gui_get_focus_owner() == _park:
		if is_instance_valid(_parked) and _parked.is_inside_tree() and _parked.is_visible_in_tree() and _parked.focus_mode != Control.FOCUS_NONE:
			_parked.grab_focus()
		else:
			_park.release_focus()
	_parked = null


# ---------------------------------------------------------------- where the window was
# Kept per project as {on, rect, screen, screen_rect, max}: the window's place in screen pixels, the screen it
# was on and that screen's usable area then.

## What to remember now. `was` is what was remembered before: a maximized or minimized window keeps the place it
## had as an ordinary window.
func placement(was: Dictionary) -> Dictionary:
	var out := was.duplicate()
	if not visible:
		return out
	out["max"] = mode == Window.MODE_MAXIMIZED
	if mode == Window.MODE_WINDOWED:
		out["rect"] = Rect2i(position, size)
		out["screen"] = current_screen
		out["screen_rect"] = DisplayServer.screen_get_usable_rect(current_screen)
	return out


## The place to open at, from what was remembered, for the screens there are now (`screens`: the usable area of
## each). The same place when the screen it was on is as it was. When that screen is gone or has changed, the
## place is carried over in proportion to the screen that is there instead (`main_screen` when the old number
## no longer exists), and kept inside it. Rect2i() when nothing usable was remembered.
static func fit_rect(saved: Dictionary, screens: Array, main_screen: int, title_height: int) -> Rect2i:
	var rect: Rect2i = saved.get("rect", Rect2i())
	if rect.size.x <= 0 or rect.size.y <= 0 or screens.is_empty():
		return Rect2i()
	var screen := int(saved.get("screen", -1))
	if screen < 0 or screen >= screens.size():
		screen = clampi(main_screen, 0, screens.size() - 1)
	var now: Rect2i = screens[screen]
	var then: Rect2i = saved.get("screen_rect", Rect2i())
	if then.size.x > 0 and then.size.y > 0 and then != now:
		var ratio := Vector2(now.size) / Vector2(then.size)
		rect = Rect2i(Vector2i(Vector2(rect.position - then.position) * ratio) + now.position, Vector2i(Vector2(rect.size) * ratio))
	# (never bigger than all the screens together)
	var all: Rect2i = screens[0]
	for s in screens:
		all = all.merge(s as Rect2i)
	rect.size = Vector2i(mini(rect.size.x, all.size.x), mini(rect.size.y, all.size.y))
	# The title bar has to be within reach on some screen, or the window can't be moved.
	var bar := Rect2i(rect.position.x, rect.position.y - title_height, rect.size.x, title_height)
	var reach := 0
	for s in screens:
		var part := bar.intersection(s as Rect2i)
		if part.size.y >= title_height:
			reach = maxi(reach, part.size.x)
	if reach >= mini(rect.size.x, title_height * 4):
		return rect
	rect.size = Vector2i(mini(rect.size.x, now.size.x), mini(rect.size.y, now.size.y - title_height))
	rect.position.x = clampi(rect.position.x, now.position.x, now.end.x - rect.size.x)
	rect.position.y = clampi(rect.position.y, now.position.y + title_height, now.end.y - rect.size.y)
	return rect
