extends RefCounted
## Editor self-test for the Schematic editor in its own window (Make Floating): floating and docking back, the
## look and theme inside the window, the keys that must still work there (F9, F7, the step keys, Ctrl+S, undo),
## the Add Node menu, dropping a file from the FileSystem dock, switching main screen tabs, the debugger stopping
## on a node, and the remembered place.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_floating.gd
## Then, for what needs the editor to be closed and opened again:
##   ... --sc-selftest=res://tests/shot_floating.gd --float-leave      quits with the editor floating
##   ... --sc-selftest=res://tests/shot_floating.gd --float-restore    expects it to come back floating, docks it
## In a scratch copy only (it switches the plugin off and on, which rewrites project.godot):
##   ... --sc-selftest=res://tests/shot_floating.gd --float-cycle
## With the editor in single-window mode (--single-window, or the Editor Setting) it checks that the button is
## off and nothing floats.

const W := preload("res://addons/schematic/editor/sc_widgets.gd")
const FloatWindow := preload("res://addons/schematic/editor/sc_float.gd")
const DEMO := "res://demo/SC_Demo.gd"

var plugin: EditorPlugin
var tree: SceneTree
var ed
var passed := 0
var failed := 0
var demo_text := ""
var remembered_before: Variant = null   # what the project remembered about the window before the run


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_floating.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	note("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])


func frames(n := 3) -> void:
	for i in n:
		await tree.process_frame


func wait(seconds: float) -> void:
	await tree.create_timer(seconds).timeout


func saved() -> Dictionary:
	var v: Variant = EditorInterface.get_editor_settings().get_project_metadata("schematics", "floating_window", {})
	return v if v is Dictionary else {}


## A key press and release given to a window, the way the window itself hands on what the system sends it.
func tap(vp: Viewport, code: int, ctrl := false, shift := false, alt := false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.ctrl_pressed = ctrl
		ev.shift_pressed = shift
		ev.alt_pressed = alt
		ev.pressed = pressed
		vp.push_input(ev)
	await frames(3)


## The first key of one of the editor's own shortcuts, given to a window.
func tap_shortcut(vp: Viewport, shortcut: String) -> bool:
	var es := EditorInterface.get_editor_settings()
	var sc: Shortcut = es.get_shortcut(shortcut) if es.has_shortcut(shortcut) else null
	if sc == null or sc.events.is_empty() or not (sc.events[0] is InputEventKey):
		return false
	var k := sc.events[0] as InputEventKey
	var code := k.keycode if k.keycode != KEY_NONE else DisplayServer.keyboard_get_keycode_from_physical(k.physical_keycode)
	await tap(vp, code, k.ctrl_pressed, k.shift_pressed, k.alt_pressed)
	return true


## The picture of a control, from the window it is in.
func grab(c: Control) -> Image:
	await wait(0.45)
	var img := c.get_viewport().get_texture().get_image()
	var r := Rect2(c.get_global_rect()).intersection(Rect2(Vector2.ZERO, img.get_size()))
	return img.get_region(Rect2i(r))


## The share of pixels that differ visibly between two pictures of the same size (1.0 when the sizes differ).
func differing(a: Image, b: Image, skip := Rect2i()) -> float:
	if a.get_size() != b.get_size():
		return 1.0
	var off := 0
	var total := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			if skip.has_point(Vector2i(x, y)):
				continue
			total += 1
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) > 0.06:
				off += 1
	return float(off) / maxf(total, 1)


func node_count() -> int:
	return ed.cur_graph().nodes.size()


func cleanup() -> void:
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if is_instance_valid(ed) and not ed.doc.is_empty():
		ed.doc.dirty = false
	if demo_text != "" and FileAccess.get_file_as_string(DEMO) != demo_text:
		var f := FileAccess.open(DEMO, FileAccess.WRITE)
		f.store_string(demo_text)
		f.close()


func finish(leave_floating := false) -> void:
	cleanup()
	if is_instance_valid(plugin) and plugin.is_floating() != leave_floating:
		plugin.set_floating(leave_floating)
		await frames(4)
	# The project gets back what it remembered before the run (--float-leave keeps it for --float-restore).
	var es := EditorInterface.get_editor_settings()
	if leave_floating:
		es.set_project_metadata("schematics", "floating_window_before_test", remembered_before)
	else:
		if OS.get_cmdline_user_args().has("--float-restore"):
			remembered_before = es.get_project_metadata("schematics", "floating_window_before_test", null)
			es.set_project_metadata("schematics", "floating_window_before_test", null)
		es.set_project_metadata("schematics", "floating_window", remembered_before)
	note("done: %d passed, %d failed" % [passed, failed])
	tree.quit()


func run(p: EditorPlugin) -> void:
	if Engine.has_meta("sc_floating_selftest"):
		return   # (the plugin switched on again by --float-cycle starts the self-test a second time)
	Engine.set_meta("sc_floating_selftest", true)
	plugin = p
	tree = p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	var args := OS.get_cmdline_user_args()
	note("--- start %s" % [args])
	tree.create_timer(150.0).timeout.connect(func():
		note("watchdog quit (%d passed, %d failed so far)" % [passed, failed])
		cleanup()
		tree.quit())
	await wait(2.5)
	ed = p.editor
	demo_text = FileAccess.get_file_as_string(DEMO)
	remembered_before = EditorInterface.get_editor_settings().get_project_metadata("schematics", "floating_window", null)
	note("environment: Godot %s, multi-window=%s, display scale=%s, screens=%d, main window focused=%s" % [
		Engine.get_version_info().string, plugin.can_float(), EditorInterface.get_editor_scale(), DisplayServer.get_screen_count(), DisplayServer.window_is_focused()])
	fit_checks()
	if args.has("--float-restore"):
		await restore_checks()
		return
	if not plugin.can_float():
		await single_window_checks()
		return
	if args.has("--float-cycle"):
		await cycle_checks()
		return
	await main_checks(args.has("--float-leave"))


# ---------------------------------------------------------------- the place to open at

func fit_checks() -> void:
	var one := [Rect2i(0, 0, 1920, 1040)]
	var two := [Rect2i(0, 0, 1920, 1040), Rect2i(1920, 0, 2560, 1400)]
	var on_second := {"rect": Rect2i(2100, 120, 1600, 900), "screen": 1, "screen_rect": Rect2i(1920, 0, 2560, 1400)}
	check("a remembered place comes back as it was while its screen is as it was",
		FloatWindow.fit_rect(on_second, two, 0, 32) == Rect2i(2100, 120, 1600, 900))
	var gone: Rect2i = FloatWindow.fit_rect(on_second, one, 0, 32)
	check("with that monitor gone the window opens inside the one that is left",
		gone.size.x > 0 and one[0].encloses(gone) and gone.position.y >= 32, str(gone))
	var smaller: Rect2i = FloatWindow.fit_rect(on_second, [two[0], Rect2i(1920, 0, 1280, 700)], 0, 32)
	check("on a smaller monitor in its place the window is scaled to fit it",
		Rect2i(1920, 0, 1280, 700).encloses(smaller) and smaller.size == Vector2i(800, 450), str(smaller))
	var lost: Rect2i = FloatWindow.fit_rect({"rect": Rect2i(9000, 5000, 1200, 800), "screen": 0, "screen_rect": one[0]}, one, 0, 32)
	check("a place that is off every screen is brought back onto one", one[0].encloses(lost) and lost.size == Vector2i(1200, 800), str(lost))
	var half_off := {"rect": Rect2i(1500, 300, 1200, 800), "screen": 0, "screen_rect": one[0]}
	check("a window left partly off the edge on purpose stays there", FloatWindow.fit_rect(half_off, one, 0, 32) == Rect2i(1500, 300, 1200, 800))
	check("nothing remembered gives no place (the editor's own area is used)", FloatWindow.fit_rect({}, one, 0, 32) == Rect2i())


# ---------------------------------------------------------------- single-window mode

func single_window_checks() -> void:
	note("single-window mode: %s" % plugin.cannot_float_reason())
	check("the Make Floating button is off in single-window mode", ed._float_btn.disabled and not ed._float_btn.button_pressed)
	check("its tooltip says why", ed._float_btn.tooltip_text.contains("Not available"), ed._float_btn.tooltip_text.replace("\n", " | "))
	plugin.set_floating(true)
	await frames(4)
	check("asking to float does nothing", not plugin.is_floating() and plugin.float_window() == null and ed.get_parent() == plugin._screen)
	EditorInterface.set_main_screen_editor("Schematic")
	await frames(4)
	check("the docked editor is on its tab as usual", ed.is_visible_in_tree())
	await finish()


# ---------------------------------------------------------------- floating, keys, docking back

func main_checks(leave_floating: bool) -> void:
	var base := EditorInterface.get_base_control()
	var main_window := base.get_window()
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	ed.open_schematic(DEMO)
	EditorInterface.open_scene_from_path("res://demo/demo.tscn")
	await wait(1.0)
	EditorInterface.set_main_screen_editor("2D")
	await frames(3)
	EditorInterface.set_main_screen_editor("Schematic")
	await wait(0.6)
	var view: GraphEdit = ed._view

	# --- before it is ever used
	var was_floating: bool = plugin.is_floating()
	if was_floating:
		note("the project was left floating by an earlier run: docking first")
		plugin.set_floating(false)
		await wait(0.5)
	else:
		check("nothing is made until the editor is first floated", plugin.float_window() == null and plugin._screen.get_child_count() == 2
			and base.get_node_or_null("SchematicFocusRest") == null)
	check("the docked editor has a Make Floating button, on and not pressed", not ed._float_btn.disabled and not ed._float_btn.button_pressed
		and ed._float_btn.is_visible_in_tree())
	var zoom0 := view.zoom
	var scroll0 := view.scroll_offset
	var size0: Vector2 = ed.size
	var bar_h: float = ed._toolbar.size.y
	var node_menu: PopupMenu = ed._view._node_menu
	var menu_font := node_menu.get_theme_font_size("font_size")
	var docked := await grab(ed)
	docked.save_png("res://tests/out/floating_1_docked.png")

	# --- float it with its button
	ed._float_btn.pressed.emit()
	await wait(0.8)
	var win: Window = plugin.float_window()
	check("the button floats the editor", plugin.is_floating() and win != null and win.visible)
	if win == null:
		await finish()
		return
	check("it is a window of its own, not drawn inside the main one", ed.get_window() == win and win != main_window and not win.is_embedded()
		and win.get_window_id() != DisplayServer.MAIN_WINDOW_ID, "window id %d" % win.get_window_id())
	check("the main window went back to the screen it showed before (2D)", not plugin._screen.is_visible_in_tree() and plugin._main_screen == "2D", plugin._main_screen)
	check("the button now shows as pressed and offers to dock", ed._float_btn.button_pressed and ed._float_btn.tooltip_text.begins_with("Dock"))
	var first_rect := Rect2i(win.position, win.size)
	note("first opened at %s (the editor's area was %s)" % [first_rect, Rect2i(Vector2i(plugin._screen.get_screen_position()), Vector2i(size0))])
	# theme and scale inside the window
	var tree_box: StyleBox = ed._members.get_theme_stylebox("panel")
	check("controls in the window take the editor theme", tree_box == base.get_theme_stylebox("panel", "Tree")
		and ed._members.get_theme_font("font") == base.get_theme_font("font", "Tree")
		and ed._members.get_theme_font_size("font_size") == base.get_theme_font_size("font_size", "Tree")
		and ed._doc_tabs.get_theme_stylebox("tab_selected") == base.get_theme_stylebox("tab_selected", "TabBar"))
	check("menus that open from the canvas keep the editor's text size", node_menu.get_theme_font_size("font_size") == menu_font,
		"%d, docked %d" % [node_menu.get_theme_font_size("font_size"), menu_font])
	check("the window is not scaled a second time", is_equal_approx(win.content_scale_factor, 1.0) and is_equal_approx(ed._toolbar.size.y, bar_h),
		"toolbar %s high, docked %s" % [ed._toolbar.size.y, bar_h])
	check("the graph keeps its zoom", is_equal_approx(view.zoom, zoom0), "%s, docked %s" % [view.zoom, zoom0])
	# the same size as docked, to compare the two pictures
	win.size = Vector2i(size0) + Vector2i(W.si(8), W.si(8))
	await wait(0.5)
	view.scroll_offset = scroll0
	await frames(3)
	var floating := await grab(ed)
	floating.save_png("res://tests/out/floating_2_window.png")
	win.get_texture().get_image().save_png("res://tests/out/floating_2_whole_window.png")
	var btn_at := Rect2i(Vector2i(ed._float_btn.global_position - ed.global_position) - Vector2i(4, 4), Vector2i(ed._float_btn.size) + Vector2i(8, 8))
	var diff := differing(docked, floating, btn_at)
	check("the editor looks the same in its window as docked", diff < 0.004, "%.3f%% of pixels differ (sizes %s and %s)" % [diff * 100.0, docked.get_size(), floating.get_size()])
	# and docked again it is as it was
	win.close_requested.emit()
	await wait(0.8)
	check("closing the window docks the editor back", not plugin.is_floating() and not win.visible and ed.get_parent() == plugin._screen
		and ed.get_index() == 0 and plugin.table_editor.get_index() == 1)
	check("the Schematic tab shows it again", plugin._screen_visible and ed.is_visible_in_tree() and not plugin._placeholder.visible,
		"tab %s, holder shown %s, editor shown %s, note shown %s" % [plugin._main_screen, plugin._screen_visible, ed.is_visible_in_tree(), plugin._placeholder.visible])
	check("the button is back to Make Floating", not ed._float_btn.button_pressed and ed._float_btn.tooltip_text.begins_with("Make Floating"))
	check("the graph is where it was", is_equal_approx(view.zoom, zoom0) and view.scroll_offset.is_equal_approx(scroll0), "%s %s, were %s %s" % [view.zoom, view.scroll_offset, zoom0, scroll0])
	var again := await grab(ed)
	again.save_png("res://tests/out/floating_3_docked_again.png")
	var back := differing(docked, again)
	check("docked again, the editor looks exactly as it did before", back < 0.0005, "%.3f%% of pixels differ (sizes %s and %s)" % [back * 100.0, docked.get_size(), again.get_size()])
	EditorInterface.set_main_screen_editor("2D")
	await frames(3)
	plugin.set_floating(true)
	await wait(0.8)

	# a label that wraps, shown in the window the way the bar about a file changed outside is
	var size_before := win.size
	var wrapped := Label.new()
	wrapped.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wrapped.text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty " .repeat(4)
	ed.add_child(wrapped)
	ed.move_child(wrapped, 2)
	await wait(0.5)
	check("a wrapped label appearing does not make the window grow", win.size == size_before, "%s, was %s" % [win.size, size_before])
	wrapped.queue_free()
	await frames(4)

	# --- keys in the window
	var n3: GraphNode = view.get_node_or_null("n3")
	for c in view.get_children():
		if c is GraphNode:
			c.selected = c == n3
	view.grab_focus()
	await frames(2)
	await tap(win, KEY_F9)
	check("F9 in the window sets a breakpoint on the selected node", ed._breaks(DEMO).size() == 1, str(ed._breaks(DEMO)))
	await tap(win, KEY_F9)
	check("F9 again clears it", ed._breaks(DEMO).is_empty())
	# undo and redo are the main window's shortcuts: they are passed on
	var count0 := node_count()
	view.spawn("branch", {}, Vector2(2400, 2400))
	await frames(4)
	check("a node was added for the undo check", node_count() == count0 + 1)
	var sent: int = win.keys_forwarded
	await tap(win, KEY_Z, true)
	check("Ctrl+Z in the window undoes the last graph change", node_count() == count0, "%d nodes, %d before" % [node_count(), count0])
	check("(the key was passed to the main window)", win.keys_forwarded > sent)
	await tap(win, KEY_Z, true, true)
	check("Ctrl+Shift+Z redoes it", node_count() == count0 + 1)
	await tap(win, KEY_Z, true)
	check("and Ctrl+Z again leaves the graph as it was", node_count() == count0)
	# what has the keyboard focus in the main window must not get the keys
	var typed := LineEdit.new()
	typed.text = "keep"
	base.add_child(typed)
	typed.position = Vector2(20, 60)
	typed.grab_focus()
	typed.caret_column = 4
	await frames(2)
	win.gui_release_focus()
	# (keys a text field would act on, and that mean nothing else to the main window: not Delete or Ctrl+V,
	# which the Scene dock takes for its selected node)
	sent = win.keys_forwarded
	await tap(win, KEY_BACKSPACE)
	await tap(win, KEY_HOME)
	await tap(win, KEY_BACKSPACE)
	await tap(win, KEY_LEFT)
	await tap(win, KEY_LEFT, false, true)
	await tap(win, KEY_BACKSPACE)
	check("keys from the window never reach a text field in the main window", typed.text == "keep" and typed.caret_column == 4 and win.keys_forwarded > sent,
		"text is now '%s', caret at %d, %d keys passed on" % [typed.text, typed.caret_column, win.keys_forwarded - sent])
	var parked := main_window.gui_get_focus_owner()
	check("while they are passed on, the main window's focus rests on a control that does nothing", parked != null and parked.name == "SchematicFocusRest", str(parked))
	main_window.focus_entered.emit()   # what the system says when the main window is used again
	await frames(2)
	check("using the main window again gives the focus back where it was", main_window.gui_get_focus_owner() == typed, str(main_window.gui_get_focus_owner()))
	typed.queue_free()
	await frames(2)
	# F7 compiles, Ctrl+S saves
	ed.doc.dirty = true
	await tap(win, KEY_F7)
	check("F7 in the window compiles and saves the schematic", not ed.doc.dirty)
	ed.doc.dirty = true
	await tap(main_window, KEY_F7)
	check("F7 pressed in the main window is left to the main window", ed.doc.dirty)
	# (Ctrl+S saves the open scene too, and Godot writes a scene back in its own newest form: so it is given a
	# scene of the test's own to save, not the demo's)
	var probe := "res://tests/out/floating_probe.tscn"
	var holder := Node.new()
	holder.name = "FloatingProbe"
	var packed := PackedScene.new()
	packed.pack(holder)
	holder.free()
	ResourceSaver.save(packed, probe)
	EditorInterface.open_scene_from_path(probe)
	await wait(0.6)
	var probe_open := EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == probe
	if probe_open:
		await frames(2)   # (a save started from inside a timer's callback makes Godot complain about its timer list)
		await tap(win, KEY_S, true)
		await wait(0.4)
		check("Ctrl+S in the window saves the schematic", not ed.doc.dirty)
		if EditorInterface.has_method("close_scene"):
			EditorInterface.call("close_scene")
			await wait(0.3)
	else:
		note("  (the test's own scene did not open: Ctrl+S not tried)")
		ed.doc.dirty = false

	# --- the Add Node menu
	view.grab_focus()
	await tap(win, KEY_TAB)
	await wait(0.3)
	var by_key: bool = ed._palette.visible
	ed._palette.hide()
	await frames(3)
	view._open_palette(view.size * 0.5, {})
	await wait(0.4)
	var pal: Window = ed._palette
	check("the Add Node menu opens from the floating window", pal.visible and pal.get_parent().get_window() == win, "Tab opened it: %s" % by_key)
	# (the menu is kept on the screen the window is on: near that screen's edge it opens a little up or left)
	var on_screen := DisplayServer.screen_get_usable_rect(win.current_screen)
	var asked := Vector2i(view.get_screen_position() + view.size * 0.5)
	asked = Vector2i(mini(asked.x, on_screen.end.x - W.si(470)), mini(asked.y, on_screen.end.y - W.si(500)))
	check("it opens at the place asked for, over the floating window", Rect2i(win.position, win.size).has_point(pal.position)
		and (pal.position - asked).length() < 4.0, "menu at %s, asked at %s, window %s" % [pal.position, asked, Rect2i(win.position, win.size)])
	if not by_key:
		note("  (Tab did not open the menu: the test editor is not the window in front, so popups close at once)")
	pal.hide()
	await frames(3)

	# --- dialogs come up over the window in use
	check("with the main window in use, dialogs open over the main window", plugin.dialog_host() == base or win.has_focus())
	if win.has_focus():
		check("with the floating window in use, dialogs open over it", plugin.dialog_host().get_window() == win)

	# --- a file dropped from the FileSystem dock
	await drop_checks(win, view)

	# --- main screen tabs
	EditorInterface.set_main_screen_editor("3D")
	await wait(0.3)
	check("choosing another tab leaves the window up", plugin.is_floating() and win.visible and ed.is_visible_in_tree())
	EditorInterface.set_main_screen_editor("Schematic")
	await wait(0.4)
	check("choosing the Schematic tab leaves the main window on the tab it showed (3D)", not plugin._screen.is_visible_in_tree() and plugin._main_screen == "3D"
		and win.visible and win.mode != Window.MODE_MINIMIZED, "tab %s, holder shown %s, last %s, window in front: %s" % [plugin._main_screen, plugin._screen.is_visible_in_tree(), plugin._last_screen, win.has_focus()])
	plugin.open_path(DEMO)
	await wait(0.3)
	check("opening a schematic while floating does not take over the main screen", not plugin._screen.is_visible_in_tree() and plugin._main_screen == "3D")
	check("the tab holds a note and a way back, in case the main window can't leave it", plugin._placeholder != null and plugin._placeholder.visible
		and plugin._placeholder.find_children("*", "Button", true, false).size() == 2)

	# --- the debugger
	await debug_checks(win, view, main_window)

	# --- the place is remembered
	win.mode = Window.MODE_WINDOWED
	var scr := DisplayServer.screen_get_usable_rect(win.current_screen)
	var want := Rect2i(scr.position + Vector2i(scr.size.x / 8, scr.size.y / 8 + W.si(32)), Vector2i(scr.size.x * 5 / 8, scr.size.y * 5 / 8))
	check("the window has not outgrown its screen (a wrapped label asks for a great height for a moment)", win.size.x <= scr.size.x and win.size.y <= scr.size.y
		and win.min_size.x > 0 and win.min_size.y <= scr.size.y, "window %s, least %s, screen %s" % [win.size, win.min_size, scr.size])
	want.size = Vector2i(maxi(want.size.x, win.min_size.x), maxi(want.size.y, win.min_size.y))
	win.position = want.position
	win.size = want.size
	await wait(0.5)
	var placed := Rect2i(win.position, win.size)
	plugin._save_float_place()
	check("where the window is goes into the project's own metadata", bool(saved().get("on", false)) and saved().get("rect") == placed
		and int(saved().get("screen", -1)) == win.current_screen, str(saved()))
	check("(not into project.godot)", not FileAccess.get_file_as_string("res://project.godot").contains("floating"))

	# --- dock back by closing the window
	win.close_requested.emit()
	await wait(0.8)
	check("docked is remembered, with the place for next time", not plugin.is_floating() and not bool(saved().get("on", true)) and saved().get("rect") == placed, str(saved()))

	# --- float again: same place; dock with the button; then with the tab's own button
	plugin.set_floating(true)
	await wait(0.8)
	check("floated again it opens where it was left", Rect2i(win.position, win.size) == placed, "%s, left at %s" % [Rect2i(win.position, win.size), placed])
	ed._float_btn.pressed.emit()
	await wait(0.6)
	check("the button docks it back too", not plugin.is_floating() and ed.get_parent() == plugin._screen and plugin._screen_visible)
	plugin.set_floating(true)
	await wait(0.6)
	for b in plugin._placeholder.find_children("*", "Button", true, false):
		if b.text.begins_with("Dock"):
			b.pressed.emit()
	await wait(0.6)
	check("and so does the button on the Schematic tab", not plugin.is_floating() and ed.is_visible_in_tree())
	await finish(leave_floating)


func drop_checks(win: Window, view: GraphEdit) -> void:
	var count0 := node_count()
	var data := {"type": "files", "files": ["res://demo/demo.tscn"]}
	var at := view.size * 0.5
	check("the canvas in the window accepts files", view._can_drop_data(at, data))
	# the real thing: press on the file in the FileSystem dock, move over the floating window, let go
	var fs_tree: Tree = plugin._fs_tree
	EditorInterface.get_file_system_dock().navigate_to_path("res://demo/demo.tscn")
	await wait(0.8)
	var item: TreeItem = fs_tree.get_selected() if fs_tree else null
	if item == null or String(item.get_metadata(0)) != "res://demo/demo.tscn" or not fs_tree.is_visible_in_tree():
		note("  (the FileSystem dock's tree is not showing the file: dropping it directly instead)")
		view._drop_data(at, data)
		await frames(4)
		check("a dropped file becomes a node", node_count() == count0 + 1)
	else:
		var main_window := fs_tree.get_window()
		var row := fs_tree.get_item_area_rect(item, 0)
		var from := fs_tree.global_position + row.position + Vector2(minf(row.size.x * 0.5, 60.0), row.size.y * 0.5)
		# Which window the pointer is over, and where in it, Godot asks of the system: so the real pointer is put
		# over the floating canvas for a moment (and back where it was afterwards). If another program's window
		# covers that place, nothing is dragged: the drop would land on whatever the main window has there.
		var pointer_was := DisplayServer.mouse_get_position()
		var target := Vector2i(view.get_screen_position() + at)
		win.grab_focus()
		await frames(3)
		# (warp_mouse counts from the corner of whichever of the editor's windows is in use)
		var origin := win.position if win.has_focus() else main_window.position
		DisplayServer.warp_mouse(target - origin)
		await frames(4)
		var landed := false
		if (DisplayServer.mouse_get_position() - target).length() < 4 and DisplayServer.get_window_at_screen_position(target) == win.get_window_id():
			# while a button is held the system keeps sending the mouse to the window the press was in, with
			# positions measured from that window: so the place over the floating window is given in those terms
			var to := Vector2(target - main_window.position)
			if main_window.gui_get_hovered_control() == null:
				main_window.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
			await mouse_move(from - Vector2(6, 6), from, 0)
			await mouse_button(from, true)
			await mouse_move(from, from + Vector2(40, 30), MOUSE_BUTTON_MASK_LEFT)
			await mouse_move(from + Vector2(40, 30), to, MOUSE_BUTTON_MASK_LEFT)
			await mouse_button(to, false)
			await wait(0.4)
			landed = node_count() == count0 + 1
			check("a file dragged from the FileSystem dock onto the floating window becomes a node", landed, "%d nodes, %d before" % [node_count(), count0])
		else:
			note("  (the floating window is not the one under the pointer at %s: another program is in front, so the drag was not tried)" % [target])
		DisplayServer.warp_mouse(pointer_was - origin)
		if not landed:
			view._drop_data(at, data)
			await frames(4)
			check("a dropped file becomes a node", node_count() >= count0 + 1)
	while node_count() > count0:
		await tap(win, KEY_Z, true)
	check("(and the drop is undone from the window)", node_count() == count0)
	ed.doc.dirty = false


func mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)
	await frames(2)


func mouse_move(from: Vector2, to: Vector2, mask: int) -> void:
	for i in range(1, 9):
		var ev := InputEventMouseMotion.new()
		var p := from.lerp(to, i / 8.0)
		ev.position = p
		ev.global_position = p
		ev.relative = (to - from) / 8.0
		ev.button_mask = mask
		Input.parse_input_event(ev)
		await frames(1)


func debug_checks(win: Window, view: GraphEdit, main_window: Window) -> void:
	var screens := []
	var heard := func(screen_name: String): screens.append("%s@%d" % [screen_name, Engine.get_process_frames()])
	plugin.main_screen_changed.connect(heard)
	ed.toggle_breakpoints([3])   # the first Print String after Event Ready
	check("a breakpoint is set for the run", plugin._get_breakpoints().size() == 1)
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var waited := 0.0
	while ed._paused.is_empty() and waited < 25.0:
		await wait(0.25)
		waited += 0.25
	await wait(0.6)
	check("the game stops on the node while the editor floats", ed._paused.size() == 3 and int(ed._paused[2]) == 3, "%s after %.1fs" % [ed._paused, waited])
	if ed._paused.size() != 3:
		EditorInterface.stop_playing_scene()
		await wait(0.8)
		return
	var gn = view.get_node_or_null("n3")
	check("the stopped node is marked in the window, and the step buttons show", gn != null and ed.is_visible_in_tree() and ed.debug_panel.paused
		and ed._step_tools[1].is_visible_in_tree())
	check("the Schematic tab's holder is not shown beside the screen Godot chose", not plugin._screen.is_visible_in_tree()
		and plugin._main_screen != "Schematic", "main screen went: %s" % [screens])
	win.get_texture().get_image().save_png("res://tests/out/floating_4_paused.png")
	# a step key pressed in the main window is Godot's own line step; in the floating window it is a node step
	ed.debug_panel.steps_sent = 0
	var was: Array = ed._paused.duplicate()
	var ok := await tap_shortcut(win, "debugger/step_over")
	waited = 0.0
	while ed._paused == was and waited < 6.0:
		await wait(0.25)
		waited += 0.25
	check("the step-over key in the window steps to the next node", ok and ed.debug_panel.steps_sent > 0 and ed._paused.size() == 3 and ed._paused != was,
		"%s -> %s, %d steps sent" % [was, ed._paused, ed.debug_panel.steps_sent])
	for s in plugin._debugger.get_sessions():
		if s.is_active():
			s.send_message("continue", [])
	await wait(1.0)
	check("after continuing, the mark is gone", ed._paused.is_empty())
	EditorInterface.stop_playing_scene()
	await wait(0.8)
	# live execution flow, as tests/shot_debug.gd checks it docked
	EditorInterface.get_editor_settings().set_project_metadata("schematics", "breakpoints", {})
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = true)
	ed.compile_doc(ed.doc, true)
	ed.flow_hits = 0
	ed.flow_edges = 0
	await frames(3)
	# Not about floating, and the same with the editor docked: on Godot 4.6, once the debugger has stopped in a
	# schematic, Godot's own Script editor holds a copy of its script, and Godot writes that older copy back over
	# the file when the next game starts (it counts the script as edited). The mark is taken off here so this
	# run shows what it is meant to; the note says when that was needed.
	var demo_script := load(DEMO) as Script
	if EditorInterface.has_method("is_object_edited") and bool(EditorInterface.call("is_object_edited", demo_script)):
		EditorInterface.call("set_object_edited", demo_script, false)
		note("  (Godot had the demo's script marked as edited before the second run: mark taken off, see the comment in the test)")
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	waited = 0.0
	var told := false
	while ed.flow_hits == 0 and waited < 20.0:
		await wait(0.25)
		waited += 0.25
		if not told and ed._drift_check(ed.doc, true) != "":
			told = true
			var on_disk := FileAccess.get_file_as_string(DEMO)
			note("  the file changed under the editor %.2fs into the run: state '%s', trace calls in it: %s" % [waited, ed.doc.drift, on_disk.contains("__sc_trace(")])
	await wait(0.6)
	check("while the game runs, the floating graph shows the wires being followed", ed.flow_hits > 0 and ed.flow_edges > 0 and view.flow_overlay.count() > 0,
		"%d node hits, %d wires, %d animated now, after %.1fs; file state '%s', playing %s" % [ed.flow_hits, ed.flow_edges, view.flow_overlay.count(), waited,
			ed.doc.get("drift", ""), EditorInterface.is_playing_scene()])
	win.get_texture().get_image().save_png("res://tests/out/floating_5_running.png")
	EditorInterface.stop_playing_scene()
	await wait(0.8)
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = false)
	ed.compile_doc(ed.doc, true)
	plugin.main_screen_changed.disconnect(heard)
	note("main screen during the runs: %s" % [screens])
	# (compared without line endings, which a checkout may have made CRLF, and without the graph's scroll and zoom)
	var view_state := RegEx.create_from_string("\"sx\":[-0-9.e]+,\"sy\":[-0-9.e]+,\"zoom\":[-0-9.e]+")
	var now_text := view_state.sub(FileAccess.get_file_as_string(DEMO).replace("\r", ""), "", true)
	var was_text := view_state.sub(demo_text.replace("\r", ""), "", true)
	var first_diff := ""
	if now_text != was_text:
		var a := now_text.split("\n")
		var b := was_text.split("\n")
		for i in mini(a.size(), b.size()):
			if a[i] != b[i]:
				first_diff = "line %d now: %s | was: %s" % [i + 1, a[i].left(120), b[i].left(120)]
				break
	check("the demo's file is as it was after the runs (apart from where its graph is scrolled to)", now_text == was_text, first_diff)


# ---------------------------------------------------------------- closed and opened again

func restore_checks() -> void:
	var state := saved()
	note("remembered: %s" % [state])
	var waited := 0.0
	while not plugin.is_floating() and waited < 10.0:
		await wait(0.25)
		waited += 0.25
	var es := EditorInterface.get_editor_settings()
	var wanted: bool = plugin.can_float() and (not es.has_setting("interface/multi_window/restore_windows_on_load") or bool(es.get_setting("interface/multi_window/restore_windows_on_load")))
	if not wanted:
		check("the editor stays docked when Godot can't or is set not to bring windows back", not plugin.is_floating())
		await finish()
		return
	check("opened again, the editor floats as it was left", plugin.is_floating() and bool(state.get("on", false)), "after %.1fs" % waited)
	var win: Window = plugin.float_window()
	if win != null and plugin.is_floating():
		await wait(0.5)
		check("in the same place", Rect2i(win.position, win.size) == state.get("rect", Rect2i()), "%s, left at %s" % [Rect2i(win.position, win.size), state.get("rect")])
		check("with the editor in it", ed.get_window() == win and ed.is_visible_in_tree())
		win.get_texture().get_image().save_png("res://tests/out/floating_6_restored.png")
	await finish()


# ---------------------------------------------------------------- the plugin switched off while floating

func cycle_checks() -> void:
	var base := EditorInterface.get_base_control()
	var main_window := base.get_window()
	ed.open_schematic(DEMO)
	plugin.set_floating(true)
	await wait(0.8)
	var win: Window = plugin.float_window()
	check("floating before the plugin is switched off", plugin.is_floating() and win != null and win.visible)
	# a key passed on, so the control the main window's focus rests on exists too
	win.gui_release_focus()
	await tap(win, KEY_Q)
	check("(the focus rest exists)", base.get_node_or_null("SchematicFocusRest") != null)
	var holder: Control = plugin._screen
	EditorInterface.set_plugin_enabled("schematic", false)
	await wait(1.0)
	var left := []
	for w in tree.root.find_children("*", "Window", true, false):
		if String(w.title).begins_with("Schematic"):
			left.append(w)
	check("switching the plugin off while floating leaves no window", left.is_empty() and not is_instance_valid(win), str(left))
	var ours := []
	for n in tree.root.find_children("*", "", true, false):
		var scr := n.get_script() as Script
		if scr != null and scr.resource_path.begins_with("res://addons/schematic/"):
			ours.append(n)
	check("nor the focus rest, nor anything else of the plugin's", base.get_node_or_null("SchematicFocusRest") == null
		and not is_instance_valid(holder) and ours.is_empty(), str(ours))
	check("the main window's focus is not left on something that is gone", main_window.gui_get_focus_owner() == null or is_instance_valid(main_window.gui_get_focus_owner()))
	check("floating is still remembered", bool(saved().get("on", false)))
	EditorInterface.set_plugin_enabled("schematic", true)
	await wait(2.5)
	var back: Window = null
	for w in tree.root.find_children("*", "Window", true, false):
		if String(w.title).begins_with("Schematic") and w.visible:
			back = w
	check("switched on again, the editor comes back floating", back != null)
	if back != null:
		plugin = back.plugin
		ed = plugin.editor
	else:
		plugin = null
	await finish()
