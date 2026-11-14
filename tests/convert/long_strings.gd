extends Node
## Strings that run over several lines, wherever they stand: their lines are part of their value.

var out: Array = []

const TEMPLATE := """extends Node
	func x():
		pass   # not a comment: part of the text
"""

func _ready():
	var plain := """one
	two (tabbed)
		three # hash
  four, spaces

six after blank"""
	out.append(plain)
	if out.size() > 0:
		for i in 2:
			var deep := """a %d
				far in
b""" % i
			out.append(deep)
			out.append({
				"k": """x
	y""",
				"n": [1,
					2],
			})
	match out:
		[var first, ..]:
			var bound := """m
	n: %s""" % str(first).length()
			out.append(bound)
	var cb := func(v):
		var inner := """lam
	bda %s
""" % v
		return inner
	out.append(cb.call(3))
	out.append(TEMPLATE)
	out.append('single \
continued')
	out.append("tail")
