extends Node
## Branches, loops and match.

enum Kind { NONE, SMALL, BIG }

var out: Array = []
var trace: Array = []


func _ready() -> void:
	for n in [-5, 0, 3, 50, 500]:
		out.append(classify(n))
	# every form of for
	var total := 0
	for i in 4:
		total += i
	for i in range(4):
		total += i * 10
	for i in range(2, 6):
		total += i * 100
	for i in range(10, 0, -3):
		trace.append(i)
	for i in range(0, 10, 4):
		trace.append(i)
	for i: int in range(3):
		trace.append(-i)
	for f in 2.5:
		trace.append(f)
	for ch in "héy":
		trace.append(ch)
	for item in ["a", 1, null, [2]]:
		trace.append(item)
	var mixed: Array = [Vector2(1, 2), Vector2(3, 4)]
	for point: Vector2 in mixed:
		var doubled := point * 2
		trace.append(doubled.x)
	for kind: Kind in [Kind.SMALL, Kind.BIG]:
		var next := kind + 1
		trace.append(next)
	var book := {"x": 1, "y": 2, 3: "z"}
	for key in book:
		trace.append([key, book[key]])
	for key in book.keys():
		trace.append(key)
	for value in book.values():
		trace.append(value)
	for v in PackedInt32Array([7, 8]):
		trace.append(v)
	for v in Vector2i(2, 2):
		trace.append(v)
	for row in 3:
		for col in 3:
			if col == row:
				continue
			if col > row + 1:
				break
			trace.append(row * 10 + col)
	out.append(total)
	# while, with break and continue
	var n := 0
	var steps := 0
	while n < 100:
		steps += 1
		if n % 2 == 0:
			n += 3
			continue
		n *= 2
		if steps > 20 or n == 46:
			break
	out.append([n, steps])
	var countdown := 3
	while countdown:
		countdown -= 1
	var stack := [1, [2, [3, [4]]]]
	var depth := 0
	while stack is Array and stack.size() > 1:
		stack = stack[1]
		depth += 1
	out.append([countdown, depth, stack])
	# a loop that changes what it loops over, and a loop variable read after the loop
	var grow := [1, 2, 3]
	var last := -1
	for g in grow.duplicate():
		if g < 3:
			grow.append(g * 10)
		last = g
	out.append([grow, last])
	# match
	for thing in [0, 1, 2, 3, "one", "other", 2.5, [1, 2], [1, 2, 3], [9, "x"], [], {"k": 1}, {"k": 1, "more": 2}, {"name": "n", "hp": 5},
			Kind.SMALL, Vector2(1, 2), null, true]:
		out.append(describe(thing))
	out.append(trace)
	out.append([odd_else(-1), odd_else(0), odd_else(7), odd_else(4), odd_else(50)])
	out.append([grade(95), grade(85), grade(40), sign_word(-3), sign_word(0), sign_word(8), nested(1, 1), nested(1, 2), nested(2, 9)])
	assert(out.size() > 5, "the list was filled")
	assert(total > 0)


func classify(n: int) -> String:
	if n < 0:
		return "negative"
	elif n == 0:
		return "zero"
	elif n < 10:
		if n % 2 == 0:
			return "small even"
		else:
			return "small odd"
	elif n < 100: return "medium"
	else:
		pass
	return "large"


func describe(thing) -> String:
	match thing:
		0:
			return "zero"
		1, 2:
			return "one or two"
		3: if str(thing) == "3": return "three, on one line"
		"one":
			return "the word one"
		"other": if str(thing).length() > 99: return "never"
		Kind.SMALL:
			return "small kind"
		2.5:
			return "two and a half"
		[]:
			return "empty list"
		[1, 2]:
			return "exactly one two"
		[1, ..]:
			return "starts with one"
		[var first, var second]:
			return "pair %s %s" % [first, second]
		{"name": var who, "hp": var hp}:
			return "%s has %d" % [who, hp]
		{"k": 1}:
			return "k is one"
		{"k": 1, ..}:
			return "k is one and more"
		var s when s is String and s.length() > 3:
			return "long text " + s
		var v when v is Vector2:
			return "vector %s" % v.x
		null:
			return "nothing"
		_:
			return "something else"
	return "past the match"


func grade(score: int) -> String:
	var result := "F"
	match score / 10:
		10, 9:
			result = "A"
		8:
			result = "B"
		7:
			result = "C"
		_:
			if score > 50:
				result = "D"
	return result


func odd_else(n: int) -> String:
	var said := ""
	if n < 0:
		said = "below"
	else: if n == 0:
		said = "zero"
	else: if n < 10:
		said = "small"
		if n == 7: said += " seven"
	else:
		said = "big"
	return said


func sign_word(n: int) -> String:
	return "minus" if n < 0 else "zero" if n == 0 else "plus"


func nested(a: int, b: int) -> String:
	match a:
		1:
			match b:
				1:
					return "one one"
				_:
					for i in 3:
						if i == b:
							return "one loop %d" % i
					return "one other"
		_:
			pass
	return "fell through"
