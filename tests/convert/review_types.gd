extends Node
## Typed arrays and dictionaries whose element type is a class or an enum, in parameters, return types and signals,
## used by callers that are typed too.

signal listed(a: Array[Inner], b: Array[Mode])
signal mapped(c: Dictionary[String, Inner])

enum Mode { A, B }

class Inner:
	var n = 1

	func _init(v := 1) -> void:
		n = v


var log_: Array = []
var kept: Array[Inner] = []
var from_signal: Array = []
var shapes: Array = []


func _ready() -> void:
	listed.connect(_on_listed)
	mapped.connect(_on_mapped)
	# each case runs on its own, so one failing does not hide the next
	_params.call_deferred()
	_returns_inner.call_deferred()
	_returns_enum.call_deferred()
	_signal_arrays.call_deferred()
	_signal_dictionary.call_deferred()
	_describe.call_deferred()


# parameters keep the element type, so the local that takes one can be typed the same
func f(a: Array[Inner], b: Array[Mode], c: Dictionary[String, Inner]) -> Array[Inner]:
	var loc: Array[Inner] = a
	log_.append(["f", loc.size(), b.size(), c.size(), loc.is_typed(), b.is_typed()])
	return loc


# the return type keeps the element type
func g() -> Array[Mode]:
	var m: Array[Mode] = [Mode.A, Mode.B]
	return m


# a parameter that is only passed on
func pass_on(a: Array[Inner]) -> Array[Inner]:
	return f(a, [], {})


func _params() -> void:
	var items: Array[Inner] = [Inner.new(2), Inner.new(3)]
	var modes: Array[Mode] = [Mode.B]
	var table: Dictionary[String, Inner] = {"k": Inner.new(4)}
	var back: Array[Inner] = f(items, modes, table)
	kept = pass_on(back)
	log_.append(["params", back.size(), back[0].n, kept.size()])


func _returns_inner() -> void:
	var items: Array[Inner] = [Inner.new(5)]
	var back: Array[Inner] = f(items, [], {})
	log_.append(["returns inner", back.get_typed_builtin(), back.is_typed()])


func _returns_enum() -> void:
	var got: Array[Mode] = g()
	log_.append(["returns enum", got, got.is_typed(), got.get_typed_builtin()])


func _signal_arrays() -> void:
	var items: Array[Inner] = [Inner.new(6)]
	var modes: Array[Mode] = [Mode.A, Mode.B]
	listed.emit(items, modes)


func _signal_dictionary() -> void:
	var table: Dictionary[String, Inner] = {"z": Inner.new(7)}
	mapped.emit(table)


func _on_listed(a: Array[Inner], b: Array[Mode]) -> void:
	from_signal.append(["listed", a.size(), b.size(), a.is_typed(), b.is_typed()])


func _on_mapped(c: Dictionary[String, Inner]) -> void:
	from_signal.append(["mapped", c.size(), c.is_typed()])


# what other scripts can see of the signatures: the element type of each array, by name
func _describe() -> void:
	for m in get_method_list():
		if m.name in ["f", "g", "pass_on"]:
			shapes.append([m.name, m.args.map(func(a): return [a.name, a.type, a.hint, a.hint_string.split(".")[-1]]), [m["return"].type, m["return"].hint, m["return"].hint_string.split(".")[-1]]])
	for s in get_signal_list():
		if s.name in ["listed", "mapped"]:
			shapes.append([s.name, s.args.map(func(a): return [a.name, a.type, a.hint, a.hint_string.split(".")[-1]])])
