extends Node
## What tests/convert/classes.gd extends, by path: a script with no class name of its own.

signal base_signal(value)

const BASE_LIMIT := 7

var base_value := 3
var base_log: Array = []


func _ready() -> void:
	base_log.append("base ready")


func describe() -> String:
	return "base:%d" % base_value


func helper(n: int) -> int:
	return n * base_value


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		base_log.append("base ready notification")


func hook(tag: String) -> String:
	base_log.append("base hook " + tag)
	return "base-" + tag


static func make_label(text: String) -> String:
	return "[%s]" % text
