extends Node
## Multi-line lambdas with more of the statement after them: a lambda's body ends where the brackets around
## it go on (a line starting with `,`, `)`, `]` or `}`), and what follows belongs to the statement again.

var out: Array = []
var table := {"inc": func(n):
	return n + 1
, "neg": func(n): return -n}


func _ready() -> void:
	var base := 10
	out.append(["member", table.inc.call(1), table.neg.call(2)])
	# a dictionary of lambdas, the first over several lines
	var d := {"inc": func(n):
		return n + 1
	, "neg": func(n): return -n}
	out.append(["dict", d.inc.call(1), d.neg.call(2), d.size()])
	# both over several lines, the closing brace on a line of its own
	var d2 := {"inc": func(n):
		return n + 1
	, "neg": func(n):
		return -n
	}
	out.append(["dict2", d2.inc.call(1), d2.neg.call(2), d2.size()])
	# an array of lambdas
	var arr := [func(n):
		return n * 2
	, func(n):
		var m: int = n * 3
		return m
	, func(n): return n + base]
	out.append(["array", arr.size(), arr.map(func(f): return f.call(5))])
	# two multi-line lambdas as the arguments of one call
	out.append(["two", both(func(a):
		var t: int = a + 1
		return t
	, func(b):
		return b * base
	)])
	# a multi-line lambda followed by more arguments
	out.append(["more", three(func(x):
		return x - 1
	, 7, "s")])
	# one followed by `).method()`
	var joined := pick(func(x):
		return str(x) + "!"
	).to_upper()
	out.append(["method", joined])
	# the closing bracket on the line after the body, then more of the expression
	var total: int = sum_of([func():
		return 1
	, func():
		return 2
	]) + 100
	out.append(["after", total])


func both(f: Callable, g: Callable) -> Array:
	return [f.call(1), g.call(2)]


func three(f: Callable, n: int, s: String) -> Array:
	return [f.call(n), s]


func pick(f: Callable) -> String:
	return f.call("ab")


func sum_of(fs: Array) -> int:
	var t := 0
	for f in fs:
		t += f.call()
	return t
