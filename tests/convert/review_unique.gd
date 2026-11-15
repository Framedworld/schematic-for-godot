extends Node
## Waiting on a signal of a child found by its unique name.

var order: Array = []
var got = "unset"


func _enter_tree() -> void:
	var clock := Timer.new()
	clock.name = "Clock"
	clock.one_shot = true
	add_child(clock)
	clock.unique_name_in_owner = true
	clock.owner = self


func _ready() -> void:
	# the function waits until the child's signal is emitted
	_fire.call_deferred("first")
	order.append("before the wait")
	await %Clock.timeout
	order.append("after the wait")
	# the same wait with other spellings of the path
	_fire.call_deferred("second")
	await $Clock.timeout
	order.append("after the node path")
	_fire.call_deferred("third")
	await get_node("%Clock").timeout
	order.append("after get_node")
	# the same wait with the result used in an expression
	_fire.call_deferred("fourth")
	got = await %Clock.timeout
	order.append("after the expression")


func _fire(tag: String) -> void:
	await get_tree().process_frame
	order.append("fired " + tag)
	%Clock.timeout.emit()
