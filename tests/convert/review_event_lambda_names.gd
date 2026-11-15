extends Node
# An event's locals that share their names with the parameters of lambdas written elsewhere stay locals.

signal entered(b)

var out: Array = []
var pool: Array = [3, 1, 2]


func _ready() -> void:
	entered.connect(func(b) -> void:
		out.append(["entered", b]))
	out.append(pool.any(func(p: int) -> bool: return p > 2))
	pool.sort_custom(func(a, b): return a < b)
	out.append(pool)


func _process(_delta: float) -> void:
	var b: int = pool[0]
	var p := pool.size()
	var a: int = b + p
	out.append([a, b, p])
	set_process(false)
	entered.emit(a)
