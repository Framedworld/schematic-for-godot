extends Node
## A one-line lambda that calls a method on a node path, kept as written.

var log_: Array = []
var m = func(): var i = $Label.get_index(); _record(i)


func _ready() -> void:
	var label := Label.new()
	label.name = "Label"
	add_child(label)
	m.call()


func _record(v) -> void:
	log_.append(v)
