extends Node
## Engine callbacks and signal handlers whose parameter is named differently from the engine's own name, in a
## script that has a member with the engine's name.

signal pinged(who)

var event = "member event"
var delta = 1.0
var node = "member node"
var who = "member who"
var log_: Array = []
var input_log: Array = []
var tick_log: Array = []
var step_log: Array = []
var ticks := 0
var physics_ticks := 0
var pushed := false


func _ready() -> void:
	pinged.connect(_on_pinged)
	pinged.emit("sent")
	child_entered_tree.connect(_on_child)
	var extra := Node.new()
	extra.name = "Extra"
	add_child(extra)
	_push_events.call_deferred()


func _push_events() -> void:
	await get_tree().process_frame
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.pressed = true
	get_viewport().push_input(key)
	pushed = true


# the member called event is read, not the callback's parameter
func _input(ev):
	input_log.append(["input", event])


# the member called event is read here too
func _unhandled_input(ev):
	input_log.append(["unhandled", event])


# the member called delta is changed by the callback, not its parameter
func _process(dt):
	ticks += 1
	if ticks == 3:
		delta += 1.0 + dt * 0.0
		tick_log.append(["process", delta])


# the same for the physics callback
func _physics_process(step):
	physics_ticks += 1
	if physics_ticks == 2:
		delta += 100.0 + step * 0.0
		step_log.append(["physics", delta])


# a handler for a signal of this script whose parameter is not the declared name
func _on_pinged(w):
	log_.append(["pinged", w, who])


# a handler for an engine signal whose parameter is not the engine's name
func _on_child(c):
	log_.append(["child", c.name, node])
