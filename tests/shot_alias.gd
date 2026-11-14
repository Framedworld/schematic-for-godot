extends RefCounted
## Editor self-test: Unreal names typed into the action menu find the Godot node.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_alias.gd
const R := preload("res://addons/schematic/core/sc_registry.gd")
const Aliases := preload("res://addons/schematic/core/sc_aliases.gd")

var passed := 0
var failed := 0


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_alias.log"
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


func first_hit(ed, query: String) -> String:
	ed._palette._search.text = query
	ed._palette._fill()
	var it: TreeItem = ed._palette.first_leaf()
	return it.get_text(0) if it else "<none>"


func run(p: EditorPlugin) -> void:
	var tree := p.get_tree()
	note("--- start")
	var ed = p.editor
	tree.create_timer(50.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	ed.open_schematic("res://demo/SC_Demo.gd")
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	ed._view._open_palette(Vector2(400, 200), {})
	await tree.create_timer(0.5).timeout
	# typed the way an Unreal user would, with and without spaces
	var want := {
		"beginplay": ["Event Ready"], "event begin play": ["Event Ready"], "tick": ["Event Process"], "event tick": ["Event Process"],
		"endplay": ["Event Exit Tree"],
		"getactorlocation": ["Get Global Position"], "set actor location": ["Set Global Position"],
		"get actor rotation": ["Get Global Rotation", "Get Global Rotation Degrees"], "setactorscale3d": ["Set Scale"],
		"destroy actor": ["Destroy Node", "Queue Free"], "spawnactorfromclass": ["Spawn Scene (3D)", "Spawn Scene (2D)"],
		"get all actors with tag": ["Get All Nodes In Group"], "open level": ["Open Scene (by Path)"],
		"settimerbyevent": ["Set Timer by Event"], "get world delta seconds": ["Get World Delta Seconds"],
		"random float in range": ["Randf Range"], "set visibility": ["Set Visible", "Show", "Hide"],
		"get owner": ["Get Owner", "Get Parent"], "get attach parent": ["Get Parent"], "has authority": ["Is Server (Has Authority)"], "print string": ["Print String"],
		"branch": ["Branch"], "delay": ["Delay"], "get game instance": [],
	}
	for q in want:
		var got := first_hit(ed, q)
		if want[q].is_empty():
			check("'%s' finds something" % q, got != "<none>", got)
		else:
			check("'%s' -> %s" % [q, want[q][0]], want[q].has(got), "got: " + got)
	# the row says which Unreal name matched
	ed._palette._search.text = "getactorlocation"
	ed._palette._fill()
	var hit: TreeItem = ed._palette.first_leaf()
	check("the hit shows its Unreal name", hit != null and hit.get_suffix(0).contains("Get Actor Location"), hit.get_suffix(0) if hit else "")
	# plain Godot names still win over aliases
	check("'queue free' still finds Queue Free", first_hit(ed, "queue free") == "Queue Free", first_hit(ed, "queue free"))
	check("'global position' still finds a Global Position node", first_hit(ed, "global position").contains("Global Position"), first_hit(ed, "global position"))
	ed._palette.hide()
	# every alias must point at a node that exists somewhere
	var keys := {}
	for act in R.static_actions() + R.all_class_actions() + R.schematic_actions(ed.doc.bp, ed.cur_graph()):
		keys[Aliases.key_for(String(act.k), act.p)] = true
	var dead := []
	for k in Aliases.TABLE:
		if k == "k:autoload" and R.autoloads().is_empty():
			continue   # this project has no autoloads, so there is nothing for that alias to list
		if not keys.has(k):
			dead.append(k)
	check("every alias points at a real node (%d aliases)" % Aliases.TABLE.size(), dead.is_empty(), "no node for: %s" % str(dead))
	note("passed %d, failed %d" % [passed, failed])
	ed.doc.dirty = false
	tree.quit()
