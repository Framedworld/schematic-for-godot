extends RefCounted
## Editor self-test for reuse: a Schematic whose repeated groups were made macros opens, compiles to the script
## it compiled to before, and Expand Node on one of the macro nodes gives the nodes back.
## Run: godot --path . --editor -- --sc-selftest=res://tests/shot_reuse.gd
## With `--bp-reuse-open=res://path.gd,FunctionName` it only opens that Schematic's function and takes a picture.

const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Importer := preload("res://addons/schematic/core/sc_importer.gd")
const Reuse := preload("res://addons/schematic/core/sc_reuse.gd")

var plugin: EditorPlugin


func shot(name: String) -> void:
	EditorInterface.get_base_control().queue_redraw()
	await plugin.get_tree().create_timer(0.4).timeout
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	img.save_png("res://tests/out/%s.png" % name)
	note("saved " + name)


func note(msg: String) -> void:
	var path := "res://tests/out/selftest_reuse.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(msg)
	f.close()


func run(p: EditorPlugin) -> void:
	plugin = p
	var tree := p.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	note("--- start")
	tree.create_timer(60.0).timeout.connect(func():
		note("watchdog quit")
		tree.quit())
	await tree.create_timer(2.5).timeout
	var ed = p.editor
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bp-reuse-open="):
			var parts := arg.trim_prefix("--bp-reuse-open=").split(",")
			note("open %s: %s" % [parts[0], ed.open_schematic(parts[0])])
			EditorInterface.set_main_screen_editor("Schematic")
			await tree.create_timer(0.8).timeout
			for i in range(1, parts.size()):
				ed.open_member_graph(parts[i])
				await tree.create_timer(0.5).timeout
				var uses: Array = ed.cur_graph().nodes.filter(func(n): return n.kind == "macro")
				note("%s: %d nodes, %d macro nodes; compile: %s %s" % [parts[i], ed.cur_graph().nodes.size(), uses.size(), ed.compile_doc(ed.doc, false), ed.doc.errors])
				if not uses.is_empty():
					ed._view.focus_node(int(uses[0].id))
					await tree.create_timer(0.4).timeout
				await shot("reuse_open_%d" % i)
			ed.doc.dirty = false
			note("done")
			tree.quit()
			return

	# a script with the same steps in four functions, converted and then reused
	var source: String = load("res://tests/test_reuse.gd").ONE
	var bp: Dictionary = Importer.new().convert(source, {}).bp
	var before: String = Compiler.new().compile(bp)
	var r := Reuse.new()
	var rep := r.run([{"path": "res://tests/tmp/reuse/SC_ReuseOne.gd", "bp": bp}], "")
	note("reuse: %d macros, %d uses" % [int(rep.macros), int(rep.uses)])
	DirAccess.make_dir_recursive_absolute("res://tests/tmp/reuse")
	var f := FileAccess.open("res://tests/tmp/reuse/SC_ReuseOne.gd", FileAccess.WRITE)
	f.store_string(Model.build_source(Compiler.new().compile(bp), bp))
	f.close()

	note("open: %s" % ed.open_schematic("res://tests/tmp/reuse/SC_ReuseOne.gd"))
	EditorInterface.set_main_screen_editor("Schematic")
	await tree.create_timer(0.8).timeout
	note("compiles in the editor: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("editor's script is the script from before reuse: %s" % Reuse.same_code(before, String(ed.doc.preview)))
	ed.open_member_graph("burn")
	await tree.create_timer(0.5).timeout
	var call := {}
	for n in ed.cur_graph().nodes:
		if n.kind == "macro":
			call = n
	note("burn: %d nodes, macro node %s names=%s" % [ed.cur_graph().nodes.size(), call.get("p", {}).get("name", "none"), call.get("p", {}).get("names", {})])
	await shot("reuse_01_function_with_macro")
	var macro_name := String(call.p.name)
	ed.open_member_graph(macro_name)
	await tree.create_timer(0.5).timeout
	note("macro graph %s: %d nodes, inputs %s, locals %s" % [macro_name, ed.cur_graph().nodes.size(), ed.cur_graph().inputs, ed.cur_graph().locals.map(func(l): return l.name)])
	await shot("reuse_02_macro_graph")

	# Expand Node: the macro node becomes its nodes again, with this function's own local
	ed.open_member_graph("burn")
	await tree.create_timer(0.4).timeout
	var with_macro: int = ed.cur_graph().nodes.size()
	ed._view.expand_macro(int(call.id))
	await tree.create_timer(0.5).timeout
	var g: Dictionary = ed.cur_graph()
	note("expanded: %d nodes became %d, macro nodes left %d, locals %s" % [with_macro, g.nodes.size(),
		g.nodes.filter(func(n): return n.kind == "macro").size(), g.locals.map(func(l): return l.name)])
	note("compiles after Expand Node: %s %s" % [ed.compile_doc(ed.doc, false), ed.doc.errors])
	note("script after Expand Node is still the script from before reuse: %s" % Reuse.same_code(before, String(ed.doc.preview)))
	await shot("reuse_03_expanded")
	ed.doc.dirty = false
	note("done")
	tree.quit()
