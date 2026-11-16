extends Node2D
## Comments a person writes, everywhere they write them: each must come back where it was written.

# A free comment between declarations

signal moved(amount: float)   # trailing comment on a signal
## Doc comment on a member
var speed := 4.0   # trailing comment on a declaration
var blocked := false
# above a variable that keeps its declaration as written
@export_range(0, 10) var level := 3  # trailing on one kept as written
var log_: Array = []
const LIMIT := 5  # trailing on a constant
## A doc comment on an enum
enum Mode { A, B }  # trailing on an enum

#region Movement
# Comment above a function
func move(delta: float) -> void:  # trailing on the function's line
	# a comment line above a statement
	position.x += speed * delta   # a trailing comment
	if blocked:
		# a comment as the only thing in a branch, before its statement
		return
	# a comment at the end of a block, after the last statement

	# a comment after a blank line
#endregion


func _ready() -> void:
	move(0.5)
	log_.append(position.x)

	log_.append("after a blank line")
	breakpoint   # stops in the debugger; nothing happens without one
	var n := 0
	for i in range(3):
		# inside a loop
		n += i  # adding
		# end of the loop body
	log_.append(n)
	if n > 2:
		log_.append("big")
	# above an elif
	elif n > 1:
		log_.append("middle")
	# above the else
	else:
		# first thing in the else
		log_.append("small")
	match n:
		# above the first arm
		3:
			# inside an arm
			log_.append("three")  # in the arm
		# above the second arm
		_:
			log_.append("other")
			# end of the last arm
	var total := sum_of([
		1,  # the first
		2,  # the second
	])
	log_.append(total)
	var twice := func(x):
		# inside a lambda
		return x * 2  # doubled
	log_.append(twice.call(4))
	if n > 100:
		pass  # nothing to do yet
	log_.append(kept_whole())
	moved.emit(1.0)  # told
	# the last line of the function


func sum_of(items: Array) -> int:
	var s := 0
	for it in items:
		s += it
	return s   # the sum


func kept_whole() -> int:
	# a function the converter keeps whole: its comments stay in its text
	var k := 0
	for k2 in range(2):   # (a loop variable named like a local elsewhere)
		k += k2
	if true:
		var k2 := 5   # the clash
		k += k2
	return k

# at the very end of the file
