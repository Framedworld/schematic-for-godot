extends RefCounted
## Editor self-test: a category in the Add Node menu fills with its nodes however it is opened: a mouse click on
## its arrow, Enter, a double click on its row, or from code. (Godot's Tree refuses to create items
## while it is handling a mouse click, which is exactly when the arrow opens a category.)
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_palette_expand.gd

var passed := 0
var failed := 0


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_palette_expand.log"
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


## Categories that have not been filled yet, top of the menu first, each with every parent opened.
func unfilled(tree: Tree) -> Array:
	var out := []
	var it := tree.get_root().get_next_in_tree() if tree.get_root() else null
	while it:
		if it.has_meta("lazy") and it.collapsed:
			out.append(it)
		it = it.get_next_in_tree()
	return out


func open_parents(item: TreeItem) -> void:
	var up := item.get_parent()
	while up and up.get_parent():
		up.collapsed = false
		up = up.get_parent()


## "" when the category is open and holds exactly its nodes; otherwise what is wrong with it.
func problem(item: TreeItem, expected: int) -> String:
	if not is_instance_valid(item):
		return "the category is gone"
	if item.collapsed:
		return "still closed"
	if item.has_meta("lazy"):
		return "open but not filled"
	var leaves := 0
	for ch in item.get_children():
		if ch.get_text(0) == "..." and ch.get_metadata(0) == null:
			return "the placeholder row is still there"
		if ch.get_metadata(0) != null:
			leaves += 1
	return "" if leaves == expected else "%d nodes, expected %d" % [leaves, expected]


## The rows above may have grown since the menu opened: scroll the row into the part of the menu that shows.
func into_view(tree: SceneTree, menu: Tree, item: TreeItem) -> void:
	await tree.process_frame
	menu.scroll_to_item(item, true)
	await tree.process_frame
	await tree.process_frame


func mouse(pal: Window, at: Vector2, pressed: bool, double := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.double_click = double and pressed
	ev.position = at
	ev.global_position = at
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	pal.push_input(ev, true)


## Clicks along the category's row, left to right, until a click on its arrow opens it. Returns the x that did
## it, or -1 when no click opened it.
func click_arrow(pal: Window, tree: Tree, item: TreeItem) -> float:
	var row := tree.get_item_area_rect(item, 0)
	var base := tree.get_global_position()
	var x := 2.0
	while x < row.position.x + row.size.x * 0.5:
		var at := base + Vector2(x, row.position.y + row.size.y * 0.5)
		mouse(pal, at, true)
		mouse(pal, at, false)
		if not item.collapsed:
			return x
		x += 3.0
	return -1.0


func run(p: EditorPlugin) -> void:
	var tree := p.get_tree()
	note("--- start  (Godot %s)" % Engine.get_version_info().string)
	var ed = p.editor
	tree.create_timer(60.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	ed.open_schematic("res://demo/SC_Demo.gd")
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	ed._view._open_palette(Vector2(400, 200), {})
	await tree.create_timer(0.6).timeout
	var pal: Window = ed._palette
	var menu: Tree = pal._tree
	var waiting := unfilled(menu)
	check("the menu opens with categories that are not filled yet", waiting.size() >= 5, "%d" % waiting.size())
	if waiting.size() < 5:
		note("passed %d, failed %d" % [passed, failed])
		tree.quit()
		return

	# 1. a mouse click on the arrow
	var by_mouse: TreeItem = waiting[0]
	var by_mouse_name := by_mouse.get_text(0)
	var want := (by_mouse.get_meta("lazy") as Array).size()
	open_parents(by_mouse)
	await into_view(tree, menu, by_mouse)
	var hit := click_arrow(pal, menu, by_mouse)
	check("a click on the arrow of '%s' opens it" % by_mouse_name, hit >= 0.0, "no click along the row opened it")
	for i in 4:
		await tree.process_frame
	check("opened with the mouse, '%s' holds its %d nodes" % [by_mouse_name, want], problem(by_mouse, want) == "", problem(by_mouse, want))

	# 2. the keyboard: the row is chosen with the arrow keys from the search box, and Enter opens it
	var by_key: TreeItem = waiting[1]
	var by_key_name := by_key.get_text(0)
	want = (by_key.get_meta("lazy") as Array).size()
	open_parents(by_key)
	by_key.select(0)
	await tree.process_frame
	pal._search.text_submitted.emit("")
	for i in 4:
		await tree.process_frame
	check("opened with Enter, '%s' holds its %d nodes" % [by_key_name, want], problem(by_key, want) == "", problem(by_key, want))

	# 3. a double click on the row (the menu's own "activate")
	var by_double: TreeItem = waiting[2]
	var by_double_name := by_double.get_text(0)
	want = (by_double.get_meta("lazy") as Array).size()
	open_parents(by_double)
	await into_view(tree, menu, by_double)
	var row := menu.get_item_area_rect(by_double, 0)
	var on_text := menu.get_global_position() + Vector2(row.position.x + row.size.x * 0.6, row.position.y + row.size.y * 0.5)
	mouse(pal, on_text, true)
	mouse(pal, on_text, false)
	mouse(pal, on_text, true, true)
	mouse(pal, on_text, false)
	for i in 4:
		await tree.process_frame
	check("opened with a double click, '%s' holds its %d nodes" % [by_double_name, want], problem(by_double, want) == "", problem(by_double, want))

	# 4. from code, as the search and the tests do
	var by_code: TreeItem = waiting[3]
	var by_code_name := by_code.get_text(0)
	want = (by_code.get_meta("lazy") as Array).size()
	open_parents(by_code)
	by_code.collapsed = false
	for i in 4:
		await tree.process_frame
	check("opened from code, '%s' holds its %d nodes" % [by_code_name, want], problem(by_code, want) == "", problem(by_code, want))

	# 5. closing and opening a filled category again does not fill it twice
	want = by_code.get_child_count()
	by_code.collapsed = true
	by_code.collapsed = false
	for i in 4:
		await tree.process_frame
	check("opened a second time, '%s' still has the same rows" % by_code_name, by_code.get_child_count() == want, "%d, was %d" % [by_code.get_child_count(), want])

	# 6. the menu is rebuilt (a search) in the same frame as the click: nothing is left pointing at a row that is gone
	var racing: TreeItem = waiting[4]
	open_parents(racing)
	await into_view(tree, menu, racing)
	click_arrow(pal, menu, racing)
	pal._search.text = "print"
	pal._fill()
	for i in 4:
		await tree.process_frame
	check("a search straight after the click leaves a working menu", pal.first_leaf() != null and pal.leaf_count() > 0, "%d" % pal.leaf_count())
	pal._search.text = ""
	pal._fill()
	await tree.process_frame
	check("clearing the search brings the categories back", unfilled(menu).size() >= 5, "%d" % unfilled(menu).size())

	pal.hide()
	note("passed %d, failed %d" % [passed, failed])
	ed.doc.dirty = false
	tree.quit()
