extends Node
## Where a name lives, and for how long.

var out: Array = []
var speed := 10
var shared: Array = []
var calls := 0


func _ready() -> void:
	# a variable declared without a value starts empty every time round a loop
	for i in 4:
		var hit: String
		var loose
		var count: int
		var list: Array
		var where: Vector2
		if i % 2 == 0:
			hit = "even"
			loose = i
			count += i + 1
			where.x = i
		list.append(i)
		out.append([hit, loose, count, list, where])
	# the same name in two blocks is two variables
	if speed > 5:
		var note := "fast"
		out.append(note)
	else:
		var note := 0
		out.append(note)
	for i in 2:
		var note := i * 1.5
		out.append(note)
	# a best-so-far that starts as nothing
	var best
	var best_name
	for pair in [["a", 3], ["b", 9], ["c", 4]]:
		if best == null or pair[1] > best:
			best = pair[1]
			best_name = pair[0]
	out.append([best, best_name])
	# a variable that changes type as it goes
	var anything = 1
	anything = "text"
	anything = [anything, anything.length()]
	out.append(anything)
	# a local with the name of a member hides the member
	out.append(shadow())
	out.append(speed)
	# a parameter can be given a new value
	out.append([clamp_to(15), clamp_to(-3), clamp_to(4), speed])
	# values are copied, arrays and dictionaries are shared
	var a := Vector2(1, 2)
	var b := a
	b.x = 9
	var first := [1, 2]
	var second := first
	second.append(3)
	var third := first.duplicate()
	third.append(4)
	var book := {"k": [1]}
	var same_book := book
	same_book.k.append(2)
	same_book["new"] = true
	out.append([a, b, first, second, third, book])
	shared.append(first)
	first.append("late")
	out.append(shared)
	# a loop variable is the loop's own; changing it changes nothing outside
	var numbers := [1, 2, 3]
	for n in numbers:
		n *= 10
		shared.append(n + 1)
		if n > 15:
			n = -n
		shared.append(n)
	var i := 100
	for j in 3:
		i += j
	out.append([numbers, i])
	# what a lambda sees: its own copy of each local, the real members
	var local := 1
	var read_local := func(): return local
	var read_member := func(): return speed
	var change_member := func(): speed += 1
	local = 2
	speed = 50
	change_member.call()
	out.append([read_local.call(), read_member.call(), speed])
	# functions are called once each, in the order they are written
	out.append([tick() + tick() * tick(), [tick(), tick()], {tick(): tick()}, tick() if tick() > 0 else tick(), calls])
	var once := tick()
	out.append([once, once, once + once, calls])


func shadow() -> int:
	var speed := 3
	speed += 1
	return speed * 2


func clamp_to(value: int) -> int:
	if value > speed:
		value = speed
	elif value < 0:
		value = 0
	value += 1
	return value


func tick() -> int:
	calls += 1
	return calls
