extends SceneTree
## Plays the blueprint-only sample game headless and checks it behaves as a game.
## Run: godot --headless --path . --script res://tests/test_game.gd

var fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func physics(n: int) -> void:
	for i in n:
		await physics_frame


func _init() -> void:
	var game: Node = (load("res://demo/game/main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await physics(4)
	var player: Node = game.get_node("Player")
	var hud: Label = game.get_node("HUD")
	var coins := game.get_children().filter(func(c): return c is Area2D)
	check("game blueprint spawned three coins", coins.size() == 3, str(coins.size()))
	var values := coins.map(func(c): return c.value)
	var xs := coins.map(func(c): return c.position.x)
	check("expose-on-spawn values arrived", str(values) == "[10, 20, 30]", str(values))
	check("coins placed by the loop", str(xs) == "[200.0, 280.0, 360.0]", str(xs))
	check("player joined its group in Ready", player.is_in_group("player"))
	# Hold "right": the player blueprint reads the input vector and moves.
	var x0: float = player.position.x
	Input.action_press("ui_right")
	await physics(20)
	check("holding right moves the player", player.position.x > x0 + 40.0, "%.1f -> %.1f" % [x0, player.position.x])
	# Keep going until the first coin is collected.
	var waited := 0
	while player.score == 0 and waited < 240:
		await physics(1)
		waited += 1
	Input.action_release("ui_right")
	await physics(3)
	check("touching a coin calls Add Score on the player", player.score == 10, "score %d after %d frames" % [player.score, waited])
	check("HUD heard the dispatcher and updated", hud.text == "Score: 10", hud.text)
	check("collected coin destroyed itself", game.get_children().filter(func(c): return c is Area2D).size() == 2)
	# Collect the rest.
	Input.action_press("ui_right")
	waited = 0
	while player.score < 60 and waited < 600:
		await physics(1)
		waited += 1
	Input.action_release("ui_right")
	await physics(3)
	check("all coins collected", player.score == 60 and hud.text == "Score: 60", "score %d, hud '%s'" % [player.score, hud.text])
	print("GAME FAILS: ", fails)
	game.queue_free()
	await process_frame
	quit(1 if fails else 0)
