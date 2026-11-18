extends SceneTree
## Rebuilds the arcade demo from its five starter graphs and authored scene layouts.
## The layouts (demo/arcade/art) hold the pictures, the spawn places and which script goes on which node; what they
## draw with is five more Schematics in that folder, converted from scripts once and edited as graphs since.
## Run: godot --headless --path . --script res://tests/make_arcade.gd
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

const DIR := "res://demo/arcade/"
const SCRIPTS := [["topdown_2d", "SC_ArcadePlayer"], ["pickup_2d", "SC_ArcadeCoin"], ["spawner_2d", "SC_ArcadeSpawner"],
	["game_state", "SC_ArcadeState"], ["hud", "SC_ArcadeHUD"]]


func write_scene(file_name: String, root_name: String, layout_name: String) -> void:
	var file := FileAccess.open(DIR + file_name + ".tscn", FileAccess.WRITE)
	file.store_string("""[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://demo/arcade/art/%s.tscn" id="layout"]

[node name="%s" instance=ExtResource("layout")]
""" % [layout_name, root_name])
	file.close()


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	T.refresh_globals()
	R.ensure_api()
	var fails := 0
	for pair in SCRIPTS:
		var bp := Starters.build(pair[0], pair[1])
		var c := Compiler.new()
		var code := c.compile(bp)
		if not c.errors.filter(func(e): return not e.w).is_empty():
			fails += 1
			print("FAIL ", pair[1], " ", c.errors)
		var f := FileAccess.open(DIR + pair[1] + ".gd", FileAccess.WRITE)
		f.store_string(Model.build_source(code, bp))
		f.close()

	write_scene("coin", "Coin", "pickup")
	write_scene("arcade", "Arcade", "arena")
	print("ARCADE FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
