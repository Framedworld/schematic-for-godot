# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_ArcadeCoin
extends Area2D
## Collected when a node in the 'player' group touches it: adds its value to the Game State's score, then removes itself.

signal collected(by: Node)

## Score given when collected.
@export var value: int = 1


func _ready() -> void:
	body_entered.connect(_on_self_body_entered)


func _on_self_body_entered(body: Node2D) -> void:
	if body.is_in_group(&"player"):
		collected.emit(body)
		__sc_message(get_tree().get_first_node_in_group(&"game_state"), &"add_score", value)
		self.queue_free()


func __sc_message(target: Variant, fn: StringName, arg: Variant) -> Variant:
	if not is_instance_valid(target):
		return null
	var to: Object = target
	if not to.has_method(fn):
		return null
	return to.call(fn) if to.get_method_argument_count(fn) == 0 else to.call(fn, arg)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code af35f1f9b8037f528808755e2d557452
#~hash-v2
#~ {"class_name":"SC_ArcadeCoin","description":"Collected when a node in the 'player' group touches it: adds its value to the Game State's score, then removes itself.","dispatchers":[{"name":"collected","params":[["by","Node"]]}],"enums":[],"parent":"Area2D","tool":false,"variables":[{"category":"","default":"1","export":true,"name":"value","tooltip":"Score given when collected.","type":"int"}],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":10,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"signal_event","p":{"args":[["body","Node2D"]],"cls":"Area2D","path":".","signal":"body_entered"},"x":80.0,"y":120.0},
#~ {"d":{"group":"&\"player\""},"id":2,"kind":"tpl","p":{"id":"is_in_group"},"x":80.0,"y":330.0},
#~ {"d":{},"id":3,"kind":"branch","p":{},"x":420.0,"y":120.0},
#~ {"d":{},"id":4,"kind":"emit","p":{"name":"collected"},"x":660.0,"y":120.0},
#~ {"d":{"group":"&\"game_state\""},"id":5,"kind":"tpl","p":{"id":"get_first_node_in_group"},"x":660.0,"y":330.0},
#~ {"d":{},"id":6,"kind":"var_get","p":{"name":"value"},"x":760.0,"y":470.0},
#~ {"d":{"fn":"&\"add_score\""},"id":7,"kind":"tpl","p":{"id":"call_message"},"x":980.0,"y":120.0},
#~ {"d":{},"id":8,"kind":"tpl","p":{"id":"destroy_node"},"x":1340.0,"y":120.0},
#~ {"d":{},"id":9,"kind":"comment","p":{"h":540.0,"text":"Collected by anything in the 'player' group. Give this node a CollisionShape child.","w":1560.0},"x":40.0,"y":40.0}
#~ ],"wires":[
#~ [1,"then",3,"exec"],[1,"p_body",2,"target"],[2,"ret",3,"cond"],[3,"true",4,"exec"],[1,"p_body",4,"a_by"],[4,"then",7,"exec"],[5,"ret",7,"target"],[6,"value",7,"arg"],
#~ [7,"then",8,"exec"]
#~ ]}
#~ ]}
#endregion
