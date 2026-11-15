extends Node
## A comment that ends in a backslash, inside brackets and outside them.

var log_: Array = []


func _ready() -> void:
	# a comment ending in a backslash inside a list does not join the next line to it
	log_.append([1, # files live in C:\data\
		2])
	# the same inside a call's arguments
	log_.append(max(3, # see C:\temp\
		4))
	# and inside a dictionary
	var d := {
		"a": 5, # kept in D:\
		"b": 6,
	}
	log_.append(d)
	# a comment ending in a backslash outside brackets is only a comment
	var plain := 7 # C:\
	log_.append(plain)
	# a real continuation inside brackets still joins the lines
	log_.append([8, \
		9])
	# a real continuation outside brackets still joins the lines
	var total := 10 + \
		11
	log_.append(total)
