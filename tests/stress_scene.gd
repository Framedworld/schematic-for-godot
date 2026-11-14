extends Node
## tests/stress_convert.gd as a scene: see there.

func _ready() -> void:
	load("res://tests/stress_runner.gd").new().run()
	get_tree().quit()
