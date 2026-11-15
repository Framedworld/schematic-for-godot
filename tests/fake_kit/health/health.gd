extends Node
## The fake "health" addon's one script: a node that has health points, can be healed and damaged, and says
## when it dies. Used by tests/test_public_kit.gd and tests/shot_public_kit.gd, and by the example in
## docs/KITS.md.

signal died

@export var max_hp := 100
var hp := 100


func heal(amount: int) -> void:
	hp = mini(hp + amount, max_hp)


func damage(amount: int) -> void:
	if hp <= 0:
		return
	hp = maxi(hp - amount, 0)
	if hp == 0:
		died.emit()
