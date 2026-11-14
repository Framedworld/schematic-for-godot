extends Node
## Variables, parameters and results written without a type: they keep taking anything.

var speed = 5
var label = "x"
var ratio := 0.5
var typed: int = 3
var nothing
@export var hp = 2
@export var name_tag := "tag"
var out: Array = []

func _ready():
	var best
	for x in [3, 9, 4]:
		if best == null or x > best:
			best = x
	var loose = 1
	loose = "now a string"
	var kept := 2.5
	var counted: int = 7
	out.append([best, loose, kept, counted, scale_it(3), scale_it(0.5), pick(), pick("b"), nothing_back(), half(5), half(5.0)])
	speed = 2.5
	nothing = [speed]
	out.append([speed, nothing, twice()])

func scale_it(amount):
	return amount * speed

func pick(key = -1, other := 4):
	if key is String:
		return key + str(other)
	return key + other

func nothing_back():
	speed = speed

func half(n):
	return n / 2

func twice() -> float:
	return ratio * 2
