extends Node
## Triple-quoted strings that hold escaped quotes and things that look like comments.

var log_: Array = []
var t = """x \""" # y"""
var u = """one \" two # three"""


func _ready() -> void:
	# an escaped triple quote does not end the string, and what follows it is still inside
	log_.append(t)
	log_.append(u)
	var local = """a \""" b # c
	d \""" e"""
	log_.append(local)
	# a string that really ends, followed by a comment
	var closed = """done""" # a comment
	log_.append(closed)
