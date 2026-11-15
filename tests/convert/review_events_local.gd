extends Node
## An engine callback whose parameter has another name, while its body has a local with the engine's name.

var out: Array = []
var ticks := 0


# a local called delta next to a parameter called dt
func _process(dt):
	ticks += 1
	if ticks == 2:
		var delta = 5.0
		out.append([delta, dt * 0.0])
