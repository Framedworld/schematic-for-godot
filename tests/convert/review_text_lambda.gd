extends Node
## One-line lambdas that have to be kept as written, with node paths inside them.

var log_: Array = []
var Child = "member, not the node"
var g = func(): var q = $Label; _record(q.name)
var h = func(): var c = $Child; _record(c.name)
var k = func(): var c = $"Child"; _record(c.name); _record(%Label.name)


func _ready() -> void:
	var label := Label.new()
	label.name = "Label"
	label.unique_name_in_owner = true
	add_child(label)
	label.owner = self
	var child := Node.new()
	child.name = "Child"
	add_child(child)
	g.call()
	h.call()
	k.call()


func _record(v) -> void:
	log_.append(v)
