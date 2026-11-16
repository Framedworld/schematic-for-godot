extends Node
## Comments and blank lines inside a lambda's body: a comment with an apostrophe in it (the director's) must not
## hide the captured values used after it, and a blank line in the body stays where it was.

var out: Array = []


func build(scale: int, rng: RandomNumberGenerator, broken_prob: float) -> void:
	var limit := 3
	# a helper kept in a variable
	var configure := func(v: int, is_bath: bool) -> void:
		# The director's toy box works on this one.
		out.append(v * scale)

		# after a blank line and a comment, more captured values are used for the first time
		var chance := 0.5
		if is_bath and limit > 2:
			chance = 0.75

		if rng.randf() < broken_prob:
			# Establish the dark state immediately.
			out.append("broken")
		elif rng.randf() < chance:
			out.append("flicker")
		elif limit > 0:
			# a string with a function in it
			var src := "extends Node\nfunc _ready():\n\tpass"
			out.append(src.length())
	configure.call(2, true)
	configure.call(3, false)


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	build(5, rng, 0.0)
