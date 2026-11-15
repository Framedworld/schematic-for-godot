extends Node
## Lambdas: what they capture, and when. A lambda takes a copy of every local, parameter and loop variable it
## uses at the moment it is made; members it reads through self are read when it runs.

signal poked(value)

var out: Array = []
var events: Array = []
var speed := 3
var calls := 0
var stored: Callable
var stored_late: Array = []


func _ready() -> void:
	# a captured local changed after the lambda is made: the lambda keeps the old value
	var base := 10
	var read_base := func(): return base
	base = 99
	out.append(["reassigned", read_base.call(), base])
	# a captured array is shared, not copied: a change to its contents is seen
	var bag := [1]
	var bag_size := func(): return bag.size()
	bag.append(2)
	out.append(["shared array", bag_size.call()])
	# a loop variable captured: each lambda has the value of its own round
	var makers := []
	for i in 3:
		makers.append(func(): return i * 10)
	out.append(["loop variable", makers.map(func(m): return m.call())])
	# a local of the loop body, made in each round
	var squares := []
	for n in [2, 3, 4]:
		var sq: int = n * n
		squares.append(func(): return sq + base)
	out.append(["made in a loop", squares.map(func(m): return m.call())])
	# a lambda that captures another lambda
	var inc := func(x): return x + 1
	var twice_inc := func(y): return inc.call(inc.call(y))
	out.append(["captures a lambda", twice_inc.call(5)])
	# a lambda inside a lambda, capturing the outer lambda's parameter and a local of the function
	var k := 7
	var make_adder := func(a):
		var add := func(b):
			return a + b + k
		return add
	k = 1000
	var adder: Callable = make_adder.call(100)
	out.append(["nested", adder.call(1), make_adder.call(0).call(0)])
	# members are read when the lambda runs, through self
	var fast := func(): return speed * 2
	speed = 4
	var count_call := func():
		calls += 1
		return calls
	count_call.call()
	out.append(["members", fast.call(), count_call.call(), calls])
	# default arguments, with and without captured values
	var off := 3
	var add_off := func(a, b = 2): return a + b + off
	var just_defaults := func(a: int, b: int = 5) -> int: return a * b
	out.append(["defaults", add_off.call(1), add_off.call(1, 10), just_defaults.call(2), just_defaults.call(2, 3)])
	# a lambda that does nothing, on one line and on two, with and without a return type
	var nothing := func(_a: int, _b: String) -> void: pass
	var nothing_plain := func():
		pass
	nothing.call(1, "x")
	out.append(["does nothing", nothing_plain.call(), nothing.is_valid()])
	# a declared return type, typed and untyped parameters
	var describe := func(a: int, b, c: String = "c") -> String:
		return "%d-%s-%s" % [a, str(b), c]
	out.append(["typed", describe.call(1, 2.5), describe.call(3, [4], "z")])
	# passed straight as an argument
	var items := [{"x": 3, "n": "c"}, {"x": 1, "n": "a"}, {"x": 2, "n": "b"}]
	items.sort_custom(func(a, b): return a.x < b.x)
	out.append(["sorted", items.map(func(it): return it.n)])
	var limit := 1
	out.append(["filtered", items.filter(func(it): return it.x > limit).map(func(it):
		var label: String = it.n
		return label.to_upper()
	), items.reduce(func(acc, it): return acc + it.x, 0)])
	# a lambda in the middle of an argument list, and in a condition
	out.append(["middle", pair(func(): return base + 1, 5), pair(func():
		var v := base * 2
		return v
	, 6)])
	if items.any(func(it): return it.x == limit):
		out.append(["in a condition", true])
	for it in items.filter(func(it): return it.x >= 2):
		out.append(["loop over", it.n])
	# kept in a dictionary and an array
	var table := {"double": func(v): return v * 2, "minus": func(v): return v - off}
	var list := [func(): return "first", func(): return base]
	out.append(["in literals", table.double.call(4), table["minus"].call(10), list[0].call(), list[1].call()])
	# returned from a function
	var counter := make_counter(5)
	counter.call()
	out.append(["returned", counter.call(), make_counter(0).call(), scaler(3).call(4)])
	# connected to a signal: each lambda is a new Callable, so connecting in a loop connects every one
	var tag := "t"
	poked.connect(func(v): events.append(tag + str(v)))
	for round_no in 2:
		poked.connect(func(v): events.append([round_no, v]), CONNECT_ONE_SHOT)
	tag = "late"
	poked.emit(1)
	poked.emit(2)
	# bound by the script itself
	var minus := (func(a, b): return a - b).bind(1)
	var minus_off := (func(a, b): return a - b - off).bind(100)
	out.append(["bound", minus.call(10), minus_off.call(1000), minus.get_bound_arguments()])
	# a captured value changed inside the lambda changes its own copy only
	var own := 5
	var bump := func():
		own += 1
		return own
	out.append(["own copy", bump.call(), bump.call(), own])
	# a parameter captured
	out.append(["parameter", with_param(21).call()])
	# a name a match case binds
	var picked: Callable
	match [4, 5]:
		[var a, var b]:
			picked = func(): return a * b
	out.append(["match", picked.call()])
	# a lambda kept in a member and called later, and one that waits
	var when := "made"
	stored = func(): return [when, speed]
	when = "changed"
	speed = 8
	var wait_then := func(n):
		await get_tree().process_frame
		return n + base
	var waited = await wait_then.call(1)
	out.append(["awaited", waited, stored.call()])
	var late := func(): stored_late.append(["late", base, speed])
	get_tree().process_frame.connect(late, CONNECT_ONE_SHOT)


func pair(f: Callable, n: int) -> Array:
	return [f.call(), n]


func make_counter(start: int) -> Callable:
	var count := [start]
	return func():
		count[0] += 1
		return count[0]


static func scaler(n: int) -> Callable:
	return func(x): return x * n


func with_param(p):
	return func(): return p * 2
