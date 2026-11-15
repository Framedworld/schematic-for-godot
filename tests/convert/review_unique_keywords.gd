extends Node
## A unique-name path right after elif, while and match.

var out: Array = []
var loops := 0


func _enter_tree() -> void:
	var label := Label.new()
	label.name = "Title"
	label.text = "hello"
	add_child(label)
	label.unique_name_in_owner = true
	label.owner = self


func _ready() -> void:
	out.append(branch(0))
	out.append(branch(1))
	%Title.visible = false
	out.append(branch(1))
	%Title.visible = true
	# a loop whose condition reads a unique node
	while %Title.visible:
		loops += 1
		if loops == 3:
			%Title.visible = false
	# a match on a unique node's value
	match %Title.name:
		&"Other":
			out.append("other")
		&"Title":
			out.append("title")
	# a match on a unique node's value with a block as the pattern's body
	match %Title.text:
		"hello":
			out.append("hello")
		_:
			out.append("no")


func branch(n: int) -> String:
	if n == 0:
		return "zero"
	elif %Title.visible:
		return "visible"
	elif %Title.text == "hello":
		return "hidden hello"
	return "none"
