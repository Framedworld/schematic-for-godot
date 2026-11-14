extends SceneTree
## Checks every starter Blueprint: all nodes valid, every wire lands on a real pin, it compiles and loads,
## and then plays them together headless to see that they do what they say.
## Run: godot --headless --path . --script res://tests/test_starters.gd
const Model := preload("res://addons/blueprints/core/bp_model.gd")
const Compiler := preload("res://addons/blueprints/core/bp_compiler.gd")
const R := preload("res://addons/blueprints/core/bp_registry.gd")
const T := preload("res://addons/blueprints/core/bp_types.gd")
const Starters := preload("res://addons/blueprints/core/bp_starters.gd")

var fails := 0
var scripts := {}


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func physics(n: int) -> void:
	for i in n:
		await physics_frame


func structure(id: String, bp: Dictionary) -> Array:
	var problems := []
	for g in bp.graphs:
		var descs := {}
		for n in g.nodes:
			var d := R.describe(n, bp, g)
			descs[int(n.id)] = d
			if String(d.err) != "":
				problems.append("%s node %d (%s): %s" % [g.name, n.id, n.kind, d.err])
			for pin in n.d:
				if not d.ins.any(func(pi): return pi.id == pin):
					problems.append("%s node %d (%s): default for missing pin '%s'" % [g.name, n.id, n.kind, pin])
		var fed := {}
		for w in g.wires:
			if not descs.has(int(w[0])) or not descs.has(int(w[2])):
				problems.append("%s: wire to a missing node %s" % [g.name, str(w)])
				continue
			var src := {}
			var dst := {}
			for po in descs[int(w[0])].outs:
				if po.id == w[1]:
					src = po
			for pi in descs[int(w[2])].ins:
				if pi.id == w[3]:
					dst = pi
			if src.is_empty() or dst.is_empty():
				problems.append("%s: wire %s has no such pin (%s)" % [g.name, str(w), "source" if src.is_empty() else "target"])
				continue
			if (src.type == "exec") != (dst.type == "exec"):
				problems.append("%s: wire %s mixes exec and data" % [g.name, str(w)])
			if dst.type != "exec":
				var key := "%d:%s" % [w[2], w[3]]
				if fed.has(key):
					problems.append("%s: input %s is wired twice" % [g.name, key])
				fed[key] = true
	return problems


func make(id: String) -> Node:
	var parent: String = Starters.find(id).parent
	var n: Node = ClassDB.instantiate(parent)
	n.set_script(scripts[id])
	return n


func shape2d(owner: Node, size := 24.0) -> void:
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(size, size)
	cs.shape = sh
	owner.add_child(cs)


func _init() -> void:
	T.refresh_globals()
	R.ensure_api()

	# ---------------------------------------------------------------- every starter builds, compiles and loads
	for s in Starters.LIST:
		var bp := Starters.build(s.id, "BP_T_Lib" if s.id in ["function_library", "data_asset", "interface"] else "")
		var problems := structure(s.id, bp)
		var c := Compiler.new()
		var code := c.compile(bp)
		for e in c.errors:
			problems.append("compile: " + String(e.m))
		var scr := GDScript.new()
		scr.source_code = code.replace("class_name BP_T_Lib", "#")
		var err := scr.reload()
		if err != OK:
			problems.append("generated script does not load (error %d)" % err)
		else:
			scripts[s.id] = scr
		# survives a save and load exactly
		var again := Model.parse_source(Model.build_source(code, bp))
		if JSON.stringify(again) != JSON.stringify(Model.normalize(JSON.parse_string(JSON.stringify(bp)))):
			problems.append("changes when saved and loaded")
		var count := 0
		for g in bp.graphs:
			count += g.nodes.size()
		check("%s: valid, compiles, loads" % s.name, problems.is_empty(), "%d nodes  %s" % [count, "; ".join(problems)])
	check("ids are unique and parents exist", Starters.LIST.all(func(s): return ClassDB.class_exists(s.parent) and Starters.LIST.filter(func(o): return o.id == s.id).size() == 1))
	check("fitting() offers character starters for a CharacterBody2D", Starters.fitting("CharacterBody2D").map(func(s): return s.id) == ["topdown_2d", "platformer_2d"], str(Starters.fitting("CharacterBody2D").map(func(s): return s.id)))
	check("Function Library starter: percent(1, 4) is 25", scripts.has("function_library") and scripts["function_library"].percent(1.0, 4.0) == 25.0)
	if scripts.size() != Starters.LIST.size():
		print("STARTER FAILS: ", fails)
		quit(1)
		return

	# ---------------------------------------------------------------- top-down character + pickup + game state + HUD
	var world := Node2D.new()
	root.add_child(world)
	var state := make("game_state")
	world.add_child(state)
	var hud: Label = make("hud")
	world.add_child(hud)
	var player: CharacterBody2D = make("topdown_2d")
	player.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	shape2d(player)
	world.add_child(player)
	var coin: Area2D = make("pickup_2d")
	coin.value = 7
	coin.position = Vector2(120, 0)
	shape2d(coin)
	world.add_child(coin)
	var trigger: Area2D = make("trigger_2d")
	trigger.position = Vector2(260, 0)
	shape2d(trigger)
	world.add_child(trigger)
	var heard := {"collected": 0, "entered": 0, "exited": 0}
	coin.collected.connect(func(_by): heard.collected += 1)
	trigger.entered.connect(func(_b): heard.entered += 1)
	trigger.exited.connect(func(_b): heard.exited += 1)
	await physics(4)
	check("character joined 'player', game state joined 'game_state'", player.is_in_group("player") and state.is_in_group("game_state"))
	check("HUD shows the starting score", hud.text == "Score: 0", hud.text)
	Input.action_press("ui_right")
	var waited := 0
	while (heard.exited == 0) and waited < 400:
		await physics(1)
		waited += 1
	Input.action_release("ui_right")
	await physics(3)
	check("top-down character moves with the arrow keys", player.position.x > 250.0, "x %.0f" % player.position.x)
	check("pickup: dispatcher called, score added, removed itself", heard.collected == 1 and state.score == 7 and not is_instance_valid(coin), "collected %d, score %d" % [heard.collected, state.score])
	check("HUD followed the score", hud.text == "Score: 7", hud.text)
	check("trigger called Entered then Exited", heard.entered == 1 and heard.exited == 1, str(heard))
	world.queue_free()
	await physics(2)

	# ---------------------------------------------------------------- pickup with no game state does not error
	world = Node2D.new()
	root.add_child(world)
	player = make("topdown_2d")
	shape2d(player)
	world.add_child(player)
	coin = make("pickup_2d")
	shape2d(coin)
	world.add_child(coin)
	var lone_hud: Label = make("hud")
	world.add_child(lone_hud)
	await physics(6)
	check("pickup and HUD work without a Game State", not is_instance_valid(coin) and lone_hud.text == "Score: 0", lone_hud.text)
	world.queue_free()
	await physics(2)

	# ---------------------------------------------------------------- platformer: falls, lands, jumps, runs
	world = Node2D.new()
	root.add_child(world)
	var ground := StaticBody2D.new()
	ground.position = Vector2(0, 200)
	var gs := CollisionShape2D.new()
	var gr := RectangleShape2D.new()
	gr.size = Vector2(4000, 40)
	gs.shape = gr
	ground.add_child(gs)
	world.add_child(ground)
	var hero: CharacterBody2D = make("platformer_2d")
	shape2d(hero)
	world.add_child(hero)
	await physics(8)
	check("platformer falls under gravity", hero.position.y > 5.0 and hero.velocity.y > 0.0, "y %.1f vy %.1f" % [hero.position.y, hero.velocity.y])
	waited = 0
	while not hero.is_on_floor() and waited < 300:
		await physics(1)
		waited += 1
	check("platformer lands on the floor", hero.is_on_floor(), "after %d frames at y %.1f" % [waited, hero.position.y])
	var floor_y := hero.position.y
	Input.action_press("ui_accept")
	await physics(1)
	Input.action_release("ui_accept")
	await physics(6)
	check("platformer jumps", hero.position.y < floor_y - 20.0, "y %.1f -> %.1f" % [floor_y, hero.position.y])
	waited = 0
	while not hero.is_on_floor() and waited < 300:
		await physics(1)
		waited += 1
	var x0 := hero.position.x
	Input.action_press("ui_left")
	await physics(20)
	Input.action_release("ui_left")
	check("platformer runs left and comes back down", hero.position.x < x0 - 50.0 and hero.is_on_floor(), "x %.0f -> %.0f" % [x0, hero.position.x])
	world.queue_free()
	await physics(2)

	# ---------------------------------------------------------------- 3D character
	var world3 := Node3D.new()
	root.add_child(world3)
	var ground3 := StaticBody3D.new()
	ground3.position = Vector3(0, -2, 0)
	var gs3 := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(200, 1, 200)
	gs3.shape = gb
	ground3.add_child(gs3)
	world3.add_child(ground3)
	var hero3: CharacterBody3D = make("character_3d")
	var hs := CollisionShape3D.new()
	hs.shape = BoxShape3D.new()
	hero3.add_child(hs)
	world3.add_child(hero3)
	await physics(6)
	check("3D character falls under gravity", hero3.position.y < -0.01, "y %.3f" % hero3.position.y)
	waited = 0
	while not hero3.is_on_floor() and waited < 300:
		await physics(1)
		waited += 1
	var y_floor := hero3.position.y
	Input.action_press("ui_accept")
	await physics(1)
	Input.action_release("ui_accept")
	await physics(8)
	check("3D character lands and jumps", waited < 300 and hero3.position.y > y_floor + 0.2, "y %.2f -> %.2f" % [y_floor, hero3.position.y])
	waited = 0
	while not hero3.is_on_floor() and waited < 300:
		await physics(1)
		waited += 1
	Input.action_press("ui_right")
	Input.action_press("ui_up")
	await physics(20)
	Input.action_release("ui_right")
	Input.action_release("ui_up")
	check("3D character walks on the ground plane", hero3.position.x > 0.5 and hero3.position.z < -0.5, str(hero3.position))
	# 3D pickup and projectile
	var gem: Area3D = make("pickup_3d")
	var gsh := CollisionShape3D.new()
	gsh.shape = BoxShape3D.new()
	gem.add_child(gsh)
	gem.position = hero3.position
	world3.add_child(gem)
	var shot: Area3D = make("projectile_3d")
	shot.position = Vector3(50, 5, 0)
	world3.add_child(shot)
	await physics(10)
	check("3D pickup is collected", not is_instance_valid(gem))
	check("3D projectile flies forward (-Z)", shot.position.z < -1.0 and absf(shot.position.x - 50.0) < 0.001, str(shot.position))
	world3.queue_free()
	await physics(2)

	# ---------------------------------------------------------------- projectile + health component
	world = Node2D.new()
	root.add_child(world)
	var target := StaticBody2D.new()
	target.position = Vector2(200, 0)
	shape2d(target, 40.0)
	# the body forwards take_damage to its Health child, as a user's blueprint would
	var fwd := GDScript.new()
	fwd.source_code = "extends StaticBody2D\nfunc take_damage(amount):\n\tget_node(\"Health\").take_damage(amount)\n"
	fwd.reload()
	target.set_script(fwd)
	var health := make("health")
	health.name = "Health"
	health.max_health = 30.0
	target.add_child(health)
	world.add_child(target)
	var log := []
	health.health_changed.connect(func(h, m): log.append("%d/%d" % [h, m]))
	health.died.connect(func(): log.append("died"))
	await physics(2)
	check("health starts full", health.health == 30.0, str(health.health))
	var bullet: Area2D = make("projectile_2d")
	bullet.damage = 20.0
	shape2d(bullet, 8.0)
	world.add_child(bullet)
	await physics(4)
	check("projectile flies along its X axis", bullet.position.x > 10.0 and bullet.position.y == 0.0, str(bullet.position))
	waited = 0
	while is_instance_valid(bullet) and waited < 200:
		await physics(1)
		waited += 1
	check("projectile hit: damage delivered, projectile removed", not is_instance_valid(bullet) and health.health == 10.0, "health %s after %d frames" % [health.health, waited])
	health.heal(100.0)
	health.take_damage(50.0)
	check("heal is capped, damage floors at zero, Died fires once", str(log) == "[\"10/30\", \"30/30\", \"0/30\", \"died\"]", str(log))
	var stray: Area2D = make("projectile_2d")
	stray.lifetime = 0.2
	stray.rotation = PI / 2.0
	world.add_child(stray)
	await physics(4)
	check("a rotated projectile follows its own heading", stray.position.y > 10.0 and absf(stray.position.x) < 0.01, str(stray.position))
	await create_timer(0.4).timeout
	await physics(2)
	check("projectile removes itself after its lifetime", not is_instance_valid(stray))

	# ---------------------------------------------------------------- spawner
	var packed := PackedScene.new()
	var proto := Node2D.new()
	proto.name = "Spawned"
	packed.pack(proto)
	proto.free()
	var idle: Node2D = make("spawner_2d")
	idle.interval = 0.05
	world.add_child(idle)
	var spawner: Node2D = make("spawner_2d")
	spawner.interval = 0.1
	spawner.scene = packed
	world.add_child(spawner)
	await create_timer(0.55).timeout
	var made := spawner.get_children().filter(func(c): return c is Node2D).size()
	check("spawner makes one scene per interval", made >= 3 and made <= 6, "%d spawned in 0.55s" % made)
	check("spawner with no scene set does nothing (and no error)", idle.get_children().filter(func(c): return c is Node2D).is_empty())
	world.queue_free()
	await physics(2)

	print("STARTER FAILS: ", fails)
	quit(1 if fails else 0)
