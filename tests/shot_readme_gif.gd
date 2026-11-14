extends RefCounted
## Records the frames of the README's animation: the demo running with Show Flow and Values on.
## Run: godot --path . --editor -- --bp-selftest=res://tests/shot_readme_gif.gd
## then: python tools/make_gif.py   (joins tests/out/gif_frames/*.png into docs/images/live_flow.gif)

const DEMO := "res://demo/BP_Demo.gd"
const FRAMES_DIR := "res://tests/out/gif_frames/"
const COUNT := 30   # six passes of a dot from one place to the next, five frames each, so it loops cleanly
const FRAME_SEC := 46.0 / 150.0 / 5.0   # dot spacing / dot speed (see bp_flow_overlay.gd) / frames per pass
const WIDTH := 1200

var plugin: EditorPlugin
var tree: SceneTree
var ed
var view


func wait(sec: float) -> void:
	await tree.create_timer(sec).timeout


func cleanup() -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if not ed.doc.is_empty() and bool(ed.doc.bp.get("trace", false)):
		ed.doc.bp["trace"] = false
		ed.compile_doc(ed.doc, true)
	for d in ed.docs:
		d.dirty = false
	EditorInterface.set_distraction_free_mode(false)


func run(p: EditorPlugin) -> void:
	plugin = p
	tree = p.get_tree()
	ed = p.editor
	view = ed._view
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FRAMES_DIR))
	for f in DirAccess.get_files_at(FRAMES_DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FRAMES_DIR + f))
	tree.create_timer(70.0).timeout.connect(func():
		cleanup()
		tree.quit())
	await wait(2.5)
	EditorInterface.set_main_screen_editor("Blueprint")
	ed.open_blueprint(DEMO)
	ed.doc.graph_id = int(ed.doc.bp.graphs[0].id)
	ed._refresh_graph_tabs()
	ed._refresh_graph()
	ed.mutate("Toggle Execution Flow", func(): ed.doc.bp["trace"] = true)
	ed.compile_doc(ed.doc, true)
	ed.flow_hits = 0
	EditorInterface.play_custom_scene("res://demo/demo.tscn")
	var waited := 0.0
	while ed.flow_hits == 0 and waited < 15.0:
		await wait(0.25)
		waited += 0.25
	EditorInterface.set_distraction_free_mode(true)
	plugin.hide_bottom_panel()
	await wait(0.8)
	# the Event Process row, close up
	var box := Rect2()
	var first := true
	for c in view.get_children():
		if c is GraphNode and c.position_offset.y < 620.0:
			var r := Rect2(c.position_offset, c.size)
			box = r if first else box.merge(r)
			first = false
	box = box.grow(60.0)
	var z := minf(1.0, minf(view.size.x / box.size.x, view.size.y / box.size.y))
	view.zoom = z
	await wait(0.1)
	view.scroll_offset = box.get_center() * z - view.size * 0.5
	plugin.hide_bottom_panel()
	await wait(0.6)
	# what is recorded: the band of the graph those nodes are in
	var vr: Rect2 = view.get_global_rect()
	var band := Rect2(vr.position.x, vr.get_center().y - box.size.y * z * 0.5, vr.size.x, box.size.y * z).intersection(vr)
	var shots: Array[Image] = []
	var times := PackedInt32Array()
	var start := Time.get_ticks_msec()
	while shots.size() < COUNT:
		view.flow_overlay.time_override = shots.size() * FRAME_SEC
		view.flow_overlay.queue_redraw()
		await tree.process_frame
		await tree.process_frame
		var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
		shots.append(img.get_region(Rect2i(band)))
		times.append(int(round(shots.size() * FRAME_SEC * 1000.0)))
	view.flow_overlay.time_override = -1.0
	EditorInterface.stop_playing_scene()
	var list := FileAccess.open(FRAMES_DIR + "times.txt", FileAccess.WRITE)
	for i in shots.size():
		var im := shots[i]
		im.resize(WIDTH, int(round(im.get_height() * float(WIDTH) / im.get_width())), Image.INTERPOLATE_LANCZOS)
		im.save_png(FRAMES_DIR + "f%03d.png" % i)
		list.store_line(str(times[i]))
	list.close()
	await wait(0.8)
	cleanup()
	await wait(0.5)
	tree.quit()
