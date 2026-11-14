extends SceneTree
## Builds demo/arcade, the coin-collecting game shown in the README's video. Its five scripts are the plugin's
## own starters, unchanged; the two scenes add only shapes, particles and where things are.
## Run: godot --headless --path . --script res://tests/make_arcade.gd
const Starters := preload("res://addons/schematic/core/sc_starters.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const Model := preload("res://addons/schematic/core/sc_model.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const R := preload("res://addons/schematic/core/sc_registry.gd")

const DIR := "res://demo/arcade/"
const SCRIPTS := [["topdown_2d", "SC_ArcadePlayer"], ["pickup_2d", "SC_ArcadeCoin"], ["spawner_2d", "SC_ArcadeSpawner"],
	["game_state", "SC_ArcadeState"], ["hud", "SC_ArcadeHUD"]]
## Where coins appear, and how many seconds apart at each place.
const SPOTS := [[-250, -210, 2.3], [250, -210, 3.1], [-250, 210, 2.7], [250, 210, 3.7], [0, -300, 4.3], [0, 290, 2.9], [-310, 0, 3.4], [310, 0, 4.9]]


func ring(radius: float, sides := 24, turn := 0.0) -> String:
	var pts := PackedStringArray()
	for i in sides:
		var a := turn + i * TAU / sides
		pts.append("%.2f, %.2f" % [cos(a) * radius, sin(a) * radius])
	return "PackedVector2Array(%s)" % ", ".join(pts)


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

	var coin := """[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://demo/arcade/SC_ArcadeCoin.gd" id="1"]

[sub_resource type="CircleShape2D" id="shape"]
radius = 18.0

[sub_resource type="Gradient" id="fade"]
colors = PackedColorArray(1, 0.86, 0.35, 0.9, 1, 0.75, 0.2, 0)

[node name="Coin" type="Area2D"]
script = ExtResource("1")
value = 10

[node name="Shape" type="CollisionShape2D" parent="."]
shape = SubResource("shape")

[node name="Glow" type="CPUParticles2D" parent="."]
amount = 14
lifetime = 0.9
emission_shape = 1
emission_sphere_radius = 12.0
spread = 180.0
gravity = Vector2(0, 0)
initial_velocity_min = 14.0
initial_velocity_max = 30.0
scale_amount_min = 2.0
scale_amount_max = 4.0
color_ramp = SubResource("fade")

[node name="Rim" type="Polygon2D" parent="."]
color = Color(0.85, 0.55, 0.1, 1)
polygon = %s

[node name="Face" type="Polygon2D" parent="."]
color = Color(1, 0.8, 0.25, 1)
polygon = %s

[node name="Shine" type="Polygon2D" parent="."]
position = Vector2(-4, -4)
color = Color(1, 0.95, 0.7, 1)
polygon = %s
""" % [ring(16), ring(13), ring(4, 12)]
	var cf := FileAccess.open(DIR + "coin.tscn", FileAccess.WRITE)
	cf.store_string(coin)
	cf.close()

	var grid := ""
	var n := 0
	for k in range(-360, 361, 80):
		for across in [true, false]:
			grid += """
[node name="Line%d" type="Line2D" parent="Floor"]
points = PackedVector2Array(%s)
width = 1.0
default_color = Color(0.11, 0.14, 0.2, 1)
""" % [n, ("-380, %d, 380, %d" % [k, k]) if across else ("%d, -380, %d, 380" % [k, k])]
			n += 1
	var spawners := ""
	for i in SPOTS.size():
		spawners += """
[node name="Spawner%d" type="Node2D" parent="."]
position = Vector2(%d, %d)
script = ExtResource("4")
scene = ExtResource("6")
interval = %.1f

[node name="Pad" type="Polygon2D" parent="Spawner%d"]
z_index = -5
color = Color(0.13, 0.17, 0.24, 1)
polygon = %s
""" % [i, SPOTS[i][0], SPOTS[i][1], SPOTS[i][2], i, ring(26, 6, PI / 6)]

	var main := """[gd_scene load_steps=9 format=3]

[ext_resource type="Script" path="res://demo/arcade/SC_ArcadePlayer.gd" id="1"]
[ext_resource type="Script" path="res://demo/arcade/SC_ArcadeState.gd" id="2"]
[ext_resource type="Script" path="res://demo/arcade/SC_ArcadeHUD.gd" id="3"]
[ext_resource type="Script" path="res://demo/arcade/SC_ArcadeSpawner.gd" id="4"]
[ext_resource type="PackedScene" path="res://demo/arcade/coin.tscn" id="6"]

[sub_resource type="CircleShape2D" id="shape"]
radius = 18.0

[sub_resource type="Gradient" id="trail"]
colors = PackedColorArray(0.3, 0.9, 1, 0.8, 0.2, 0.5, 1, 0)

[sub_resource type="LabelSettings" id="score"]
font_size = 44
outline_size = 8
outline_color = Color(0.03, 0.05, 0.08, 1)

[node name="Arcade" type="Node2D"]

[node name="Backdrop" type="Polygon2D" parent="."]
z_index = -20
color = Color(0.055, 0.07, 0.1, 1)
polygon = PackedVector2Array(-4000, -4000, 4000, -4000, 4000, 4000, -4000, 4000)

[node name="Floor" type="Node2D" parent="."]
z_index = -10

[node name="Edge" type="Line2D" parent="Floor"]
points = PackedVector2Array(-380, -380, 380, -380, 380, 380, -380, 380)
closed = true
width = 3.0
default_color = Color(0.2, 0.26, 0.36, 1)
%s
[node name="GameState" type="Node" parent="."]
script = ExtResource("2")
%s
[node name="Player" type="CharacterBody2D" parent="."]
motion_mode = 1
script = ExtResource("1")
speed = 300.0

[node name="Shape" type="CollisionShape2D" parent="Player"]
shape = SubResource("shape")

[node name="Trail" type="CPUParticles2D" parent="Player"]
z_index = -1
amount = 60
lifetime = 0.55
local_coords = false
emission_shape = 1
emission_sphere_radius = 7.0
spread = 180.0
gravity = Vector2(0, 0)
initial_velocity_max = 12.0
scale_amount_min = 5.0
scale_amount_max = 9.0
color_ramp = SubResource("trail")

[node name="Body" type="Polygon2D" parent="Player"]
color = Color(0.25, 0.85, 1, 1)
polygon = %s

[node name="Core" type="Polygon2D" parent="Player"]
color = Color(0.85, 0.98, 1, 1)
polygon = %s

[node name="Camera2D" type="Camera2D" parent="."]
zoom = Vector2(0.8, 0.8)

[node name="UI" type="CanvasLayer" parent="."]

[node name="HUD" type="Label" parent="UI"]
offset_left = 28.0
offset_top = 18.0
offset_right = 400.0
offset_bottom = 80.0
text = "Score: 0"
label_settings = SubResource("score")
script = ExtResource("3")
""" % [grid, spawners, ring(18, 6), ring(8)]
	var mf := FileAccess.open(DIR + "arcade.tscn", FileAccess.WRITE)
	mf.store_string(main)
	mf.close()
	print("ARCADE FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
