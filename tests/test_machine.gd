extends SceneTree
## Runs demo/machine without a window and checks that the chain reaction goes all the way through, in order:
## gate, trapdoor, launcher, dominoes, button, cannon, tower.
## The scene shows imported models, so on a fresh checkout import the project first: godot --headless --path . --import
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_machine.gd
const SCENE := "res://demo/machine/machine.tscn"
const SECONDS := 14.0
## One of each kind of part that is shown as a model: without these the machine would run with nothing to see.
const SHOWN := ["DisplayModel", "Cannon/DisplayModel", "Dominoes/Domino1/DisplayModel", "Dominoes/Domino2/DisplayModel", "Tower/Block1/DisplayModel",
	"Tower/Block2/DisplayModel", "Tower/Block3/DisplayModel"]

var machine: Node3D
var marble: RigidBody3D
var frames := 0
var log := []
var times := {}
var verbose := false
var unseen := 0


func note(what: String) -> void:
	if not times.has(what):
		times[what] = frames / 60.0
		log.append("%5.2f  %s" % [frames / 60.0, what])


func _initialize() -> void:
	verbose = OS.get_cmdline_user_args().has("--verbose")
	var scene := load(SCENE) as PackedScene
	if scene == null:
		print("FAIL %s did not load. If its models are not imported yet, run: godot --headless --path . --import" % SCENE)
		print("MACHINE RUN FAILS: 1")
		quit(1)
		return
	machine = scene.instantiate()
	root.add_child(machine)
	for path in SHOWN:
		var model := machine.get_node_or_null(path)
		if model == null or model.find_children("*", "MeshInstance3D", true, false).is_empty():
			unseen += 1
			print("FAIL nothing is shown for ", path)
	if unseen > 0:
		# a scene whose models did not load is not the machine: say so now instead of running it
		print("If the models are not imported yet, run: godot --headless --path . --import")
		print("MACHINE RUN FAILS: %d" % unseen)
		machine.free()
		quit(1)
		return
	marble = machine.get_node("Marble")
	for s in ["TrapSensor", "Launcher", "Button", "Floor"]:
		(machine.get_node(s) as Area3D).body_entered.connect(func(body: Node3D): note("%s entered by %s" % [s, body.name]))


func _physics_process(_delta: float) -> bool:
	frames += 1
	if not is_instance_valid(machine):
		return true
	var t := frames / 60.0
	if (machine.get_node("Gate") as Node3D).position.y > 6.1:
		note("gate open")
	if (machine.get_node("Trapdoor") as Node3D).rotation.z < -1.0:
		note("trapdoor open")
	if (machine.get_node("Dominoes/Domino1") as Node3D).rotation.z < -0.5:
		note("first domino over")
	if (machine.get_node("Dominoes/Domino6") as Node3D).rotation.z < -0.3:
		note("last domino going")
	if machine.get_node("Cannon/Muzzle").get_child_count() > 0:
		note("cannon fired")
	if verbose and frames % 6 == 0:
		print("%5.2f marble %s v %s" % [t, marble.position, marble.linear_velocity])
	if t < SECONDS:
		return false
	var count: int = machine.get("blocks_down")
	for line in log:
		print(line)
	print("blocks down: %d   label: %s" % [count, (machine.get_node("UI/Counter") as Label).text])
	var order := ["gate open", "TrapSensor entered by Marble", "trapdoor open", "Launcher entered by Marble", "first domino over", "last domino going",
		"Button entered by Domino6", "cannon fired"]
	var fails := unseen
	var last := 0.0
	for step in order:
		if not times.has(step):
			fails += 1
			print("FAIL never happened: ", step)
		elif float(times[step]) < last:
			fails += 1
			print("FAIL out of order: ", step)
		else:
			last = float(times[step])
	if count < 20:
		fails += 1
		print("FAIL only %d blocks reached the ground" % count)
	if (machine.get_node("UI/Counter") as Label).text != "Blocks down: %d" % count:
		fails += 1
		print("FAIL the label does not show the count")
	print("MACHINE RUN FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
	return true
