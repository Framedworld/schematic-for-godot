extends Node
## Engine callbacks that use the engine's own parameter names, with no member of that name: nothing to rename.

var log_: Array = []
var ticks := 0
var total := 0.0


func _ready() -> void:
	_push_events.call_deferred()


func _push_events() -> void:
	await get_tree().process_frame
	var key := InputEventKey.new()
	key.keycode = KEY_B
	key.pressed = true
	get_viewport().push_input(key)


# the callback's own parameter is used as written
func _input(event):
	log_.append(["input", event is InputEventKey])


# the callback's own parameter is used as written
func _process(delta):
	ticks += 1
	total += delta * 0.0 + 1.0
