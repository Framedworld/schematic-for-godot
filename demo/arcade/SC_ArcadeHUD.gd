# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_ArcadeHUD
extends Label
## A label that shows the Game State's score and updates whenever it changes.


func _ready() -> void:
	OnScoreChanged(0)
	if is_instance_valid(get_tree().get_first_node_in_group(&"game_state")):
		get_tree().get_first_node_in_group(&"game_state").connect(&"score_changed", OnScoreChanged)


func OnScoreChanged(new_score: int) -> void:
	text = "Score: {score}".format({"score": new_score})


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_ArcadeHUD","description":"A label that shows the Game State's score and updates whenever it changes.","dispatchers":[],"parent":"Label","tool":false,"variables":[],"version":1,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":13,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"a_new_score":"0"},"id":2,"kind":"call_self","p":{"fn":"OnScoreChanged"},"x":360.0,"y":80.0},
#~ {"d":{"group":"&\"game_state\""},"id":3,"kind":"tpl","p":{"id":"get_first_node_in_group"},"x":360.0,"y":280.0},
#~ {"d":{},"id":4,"kind":"is_valid","p":{},"x":700.0,"y":80.0},
#~ {"d":{"group":"&\"game_state\""},"id":5,"kind":"tpl","p":{"id":"get_first_node_in_group"},"x":700.0,"y":280.0},
#~ {"d":{},"id":6,"kind":"event_ref","p":{"fn":"OnScoreChanged"},"x":760.0,"y":400.0},
#~ {"d":{"a0":"&\"score_changed\""},"id":7,"kind":"call","p":{"cls":"Object","method":"connect"},"x":1060.0,"y":80.0},
#~ {"d":{},"id":8,"kind":"comment","p":{"h":490.0,"text":"Listen to the Game State's Score Changed dispatcher (if there is a Game State)","w":1420.0},"x":40.0,"y":10.0},
#~ {"d":{},"id":9,"kind":"custom_event","p":{"name":"OnScoreChanged","params":[["new_score","int"]]},"x":80.0,"y":620.0},
#~ {"d":{},"id":10,"kind":"format","p":{"text":"Score: {score}"},"x":300.0,"y":780.0},
#~ {"d":{},"id":11,"kind":"set_prop","p":{"cls":"Label","prop":"text"},"x":660.0,"y":620.0},
#~ {"d":{},"id":12,"kind":"comment","p":{"h":400.0,"text":"Show the score","w":960.0},"x":40.0,"y":550.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[2,"then",4,"exec"],[3,"ret",4,"obj"],[4,"valid",7,"exec"],[5,"ret",7,"target"],[6,"fn",7,"a1"],[9,"then",11,"exec"],[9,"p_new_score",10,"f_score"],
#~ [10,"ret",11,"value"]
#~ ]}
#~ ]}
#endregion
