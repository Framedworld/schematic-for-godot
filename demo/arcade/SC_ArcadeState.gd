# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_ArcadeState
extends Node
## Keeps the score. Joins the 'game_state' group so pickups can add to it and HUDs can listen to it.

signal score_changed(new_score: int)

## The current score.
var score: int = 0


func _ready() -> void:
	self.add_to_group(&"game_state")


func add_score(amount: int) -> void:
	score = (score + amount)
	score_changed.emit(score)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_ArcadeState","description":"Keeps the score. Joins the 'game_state' group so pickups can add to it and HUDs can listen to it.","dispatchers":[{"name":"score_changed","params":[["new_score","int"]]}],"parent":"Node","tool":false,"variables":[{"category":"","default":"","export":false,"name":"score","tooltip":"The current score.","type":"int"}],"version":1,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":4,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"group":"&\"game_state\""},"id":2,"kind":"tpl","p":{"id":"add_to_group"},"x":360.0,"y":80.0},
#~ {"d":{},"id":3,"kind":"comment","p":{"h":200.0,"text":"Pickups and HUDs find the Game State through the 'game_state' group","w":720.0},"x":40.0,"y":10.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"]
#~ ]},
#~ {"id":2,"inputs":[["amount","int"]],"kind":"function","locals":[],"name":"add_score","next_id":7,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"fn_entry","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":3,"kind":"var_get","p":{"name":"score"},"x":80.0,"y":320.0},
#~ {"d":{},"id":4,"kind":"math","p":{"n":2,"op":"+"},"x":300.0,"y":300.0},
#~ {"d":{},"id":5,"kind":"var_set","p":{"name":"score"},"x":480.0,"y":120.0},
#~ {"d":{},"id":6,"kind":"emit","p":{"name":"score_changed"},"x":760.0,"y":120.0}
#~ ],"wires":[
#~ [3,"value",4,"a0"],[1,"p_amount",4,"a1"],[1,"then",5,"exec"],[4,"ret",5,"value"],[5,"then",6,"exec"],[5,"out",6,"a_new_score"]
#~ ]}
#~ ]}
#endregion
