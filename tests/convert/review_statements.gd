extends Node
## Statements whose meaning is easy to lose: a declaration with no value that comes after another of the same
## name, expression statements that contain calls, and a loop variable with a type.

var count = 3
var log_: Array = []
var calls: Array = []
var typed_loop: Array = []
var untyped_loop: Array = []


func _ready() -> void:
	# a variable with no value starts empty again, though an earlier block had one of the same name
	reset_untyped(true, true)
	reset_typed(true, true)
	reset_after_loop(true)
	# expression statements with calls in them still make the calls
	for c in [true, false]:
		calls.append("c=%s" % c)
		effects(c)
	# a loop variable keeps its type
	for j: float in range(2):
		typed_loop.append(j)
	for k: int in [1, 2]:
		typed_loop.append(k)
	# a loop over an untyped value, which is an int and then not
	for i in count:
		untyped_loop.append(i)
	set("count", 2.5)
	for i in count:
		untyped_loop.append(i)


func hit(n: int) -> bool:
	calls.append(n)
	return n % 2 == 1


func reset_untyped(p, q) -> void:
	if p:
		var x = 5
		log_.append(x)
	if q:
		var x
		log_.append(x)


func reset_typed(p, q) -> void:
	if p:
		var y = 5
		log_.append(y)
	if q:
		var y: int
		log_.append(y)
	if q:
		var s := "kept"
		log_.append(s)
	if q:
		var s: String
		log_.append(s)


func reset_after_loop(p) -> void:
	for n in 2:
		var z = n + 10
		log_.append(z)
	if p:
		var z
		log_.append(z)


func effects(c) -> void:
	# the right side of "and" runs only when the left is true
	hit(1) and hit(2)
	hit(4) and hit(5)
	# the right side of "or" runs only when the left is false
	c or hit(7)
	hit(8) or hit(9)
	# only one branch of a conditional runs
	hit(3) if c else hit(6)
	# a call inside a list is still made
	[hit(10)]
	# negation still calls
	not hit(11)
	# a comparison with a call in it
	hit(13) == true
	# these have no effect and may be dropped
	c
	count
	c and c
