extends SceneTree
## Plays demo/machine in a window and saves pictures of it at chosen moments, to look at how it reads.
## Run: godot --path . --resolution 1920x600 --position X,Y --script res://tests/shot_machine.gd -- [seconds ...]
const SCENE := "res://demo/machine/machine.tscn"
const OUT := "res://tests/out/machine/"

var machine: Node3D
var at := [0.5, 2.2, 3.3, 5.3, 7.2, 7.9, 8.4, 9.2, 11.0]
var elapsed := 0.0
var next := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var given := []
	for a in OS.get_cmdline_user_args():
		if a.is_valid_float():
			given.append(float(a))
	if not given.is_empty():
		at = given
	machine = (load(SCENE) as PackedScene).instantiate()
	root.add_child(machine)


func _process(delta: float) -> bool:
	elapsed += delta
	if next < at.size() and elapsed >= float(at[next]):
		var img := root.get_texture().get_image()
		img.save_png(OUT + "t%05.2f.png" % float(at[next]))
		next += 1
	if next >= at.size():
		quit()
		return true
	return false
