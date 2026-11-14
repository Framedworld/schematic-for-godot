extends Node
## Every way of declaring and calling a function.

var out: Array = []
var total := 0
var log_lines: Array = []


func _ready() -> void:
	out.append([plain(2, 3), defaults(), defaults(5), defaults(5, "x"), defaults(5, "x", [9]), loose(1), loose("s"), loose(), inferred(), inferred(2.5)])
	out.append([nothing(), returns_sometimes(1), returns_sometimes(-1), early(3), early(30), factorial(6), fib(12), is_even(10), is_odd(7)])
	out.append([Self.double(4), Self.label_of(2.5), sum_all(), sum_all(1), sum_all(1, 2, 3), first_and_rest("a"), first_and_rest("a", "b", "c")])
	# functions as values
	var by_name := plain
	var by_call := Callable(self, "plain")
	var bound := plain.bind(10)
	var unbound := plain.unbind(1)
	out.append([by_name.call(1, 2), by_call.call(3, 4), bound.call(5), unbound.call(6, 7, 99), by_name.callv([8, 9]), by_name.is_valid(),
		by_name.get_method(), bound.get_bound_arguments(), has_method("plain"), call("plain", 2, 2), callv("defaults", [1, "z"])])
	# a function named like one of GDScript's own is only reached through self
	out.append([self.log("x"), log(1.0), self.range(3), range(3), self.len("abc"), len("abc"), self.print_stack()])
	# lambdas
	var square := func(n): return n * n
	var typed := func(n: int, scale: float = 2.0) -> float: return n * scale
	var seen := []
	var multi := func(items: Array) -> int:
		var count := 0
		for it in items:
			if it is String:
				continue
			count += 1
			seen.append(it)
		return count
	var named := func add_one(n): return n + 1
	var captures := func(): return total + seen.size()
	total = 5
	out.append([square.call(7), typed.call(3), typed.call(3, 0.5), multi.call([1, "a", 2.5, null]), seen, named.call(1), captures.call()])
	out.append([[3, 1, 2].map(func(n): return n * 10), [1, 2, 3, 4].filter(func(n): return n % 2 == 0), [1, 2, 3].reduce(func(acc, n): return acc + n, 100),
		[1, 2, 3].any(func(n): return n > 2), [1, 2, 3].all(func(n): return n > 2), (func(a, b): return a - b).call(9, 4)])
	var words := ["pear", "fig", "banana", "kiwi"]
	words.sort_custom(func(a, b):
		if a.length() != b.length():
			return a.length() < b.length()
		return a < b)
	out.append(words)
	var table := {
		"inc": func(n): return n + 1,
		"neg": func(n):
			return -n,
	}
	out.append([table.inc.call(1), table["neg"].call(1)])
	var makers := []
	for i in 3:
		makers.append(func(): return i * 100)
	out.append(makers.map(func(m): return m.call()))
	var counter := [0]
	var bump := func(): counter[0] += 1
	bump.call()
	bump.call()
	out.append(counter)
	recurse_with_lambda(3)
	out.append(log_lines)


func plain(a: int, b: int) -> int:
	return a * 10 + b


func defaults(a: int = 1, b: String = "d", c: Array = []) -> String:
	return "%d%s%d" % [a, b, c.size()]


func loose(value = null):
	if value == null:
		return "none"
	return value


func inferred(scale := 1.5):
	return scale * 2


func nothing():
	@warning_ignore("return_value_discarded")
	plain(1, 2)
	@warning_ignore("integer_division")
	total += 3 / 2


func returns_sometimes(n):
	if n > 0:
		return "positive"


func early(n: int) -> String:
	for i in 10:
		if i == n:
			return "found %d" % i
		if i > 5:
			break
	while n > 20:
		n -= 7
		if n < 18:
			return "under"
	return "end"


func factorial(n: int) -> int:
	return 1 if n <= 1 else n * factorial(n - 1)


func fib(n: int) -> int:
	if n < 2:
		return n
	return fib(n - 1) + fib(n - 2)


func is_even(n: int) -> bool:
	return true if n == 0 else is_odd(n - 1)


func is_odd(n: int) -> bool:
	return false if n == 0 else is_even(n - 1)


func sum_all(...numbers: Array) -> int:
	var sum := 0
	for n in numbers:
		sum += n
	return sum


func first_and_rest(first: String, ...rest: Array) -> String:
	return first + ":" + "/".join(rest)


func log(text) -> String:
	return "log:" + str(text)


func range(n: int) -> String:
	return "range:%d" % n


func len(_thing) -> int:
	return -1


func print_stack() -> String:
	return "mine"


func recurse_with_lambda(depth: int) -> void:
	var note := func(tag): log_lines.append("%s%d" % [tag, depth])
	note.call("in")
	if depth > 0:
		recurse_with_lambda(depth - 1)
	note.call("out")


class Self:
	static func double(n: int) -> int:
		return n * 2

	static func label_of(value: float) -> String:
		return "v=%.1f" % value
