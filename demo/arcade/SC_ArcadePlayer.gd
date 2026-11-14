# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_ArcadePlayer
extends CharacterBody2D
## Moves in four directions with the arrow keys. Joins the 'player' group.

@export_group("Movement")
## Pixels per second.
@export var speed: float = 220.0


func _ready() -> void:
	self.add_to_group(&"player")


func _physics_process(delta: float) -> void:
	velocity = (Input.get_vector(&"ui_left", &"ui_right", &"ui_up", &"ui_down") * speed)
	move_and_slide()


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_ArcadePlayer","description":"Moves in four directions with the arrow keys. Joins the 'player' group.","dispatchers":[],"parent":"CharacterBody2D","tool":false,"variables":[{"category":"Movement","default":"220.0","export":true,"name":"speed","tooltip":"Pixels per second.","type":"float"}],"version":1,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":11,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"group":"&\"player\""},"id":2,"kind":"tpl","p":{"id":"add_to_group"},"x":360.0,"y":80.0},
#~ {"d":{},"id":3,"kind":"comment","p":{"h":190.0,"text":"Pickups, triggers and HUDs look for the 'player' group","w":680.0},"x":40.0,"y":10.0},
#~ {"d":{},"id":4,"kind":"event","p":{"name":"_physics_process"},"x":80.0,"y":340.0},
#~ {"d":{},"id":5,"kind":"tpl","p":{"id":"input_vector"},"x":80.0,"y":520.0},
#~ {"d":{},"id":6,"kind":"var_get","p":{"name":"speed"},"x":360.0,"y":660.0},
#~ {"d":{},"id":7,"kind":"math","p":{"n":2,"op":"*"},"x":560.0,"y":540.0},
#~ {"d":{},"id":8,"kind":"set_prop","p":{"cls":"CharacterBody2D","prop":"velocity"},"x":760.0,"y":340.0},
#~ {"d":{},"id":9,"kind":"call","p":{"cls":"CharacterBody2D","method":"move_and_slide"},"x":1060.0,"y":340.0},
#~ {"d":{},"id":10,"kind":"comment","p":{"h":470.0,"text":"Move: arrow keys (change the actions on Get Input Vector to use your own)","w":1300.0},"x":40.0,"y":270.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[5,"ret",7,"a0"],[6,"value",7,"a1"],[7,"ret",8,"value"],[4,"then",8,"exec"],[8,"then",9,"exec"]
#~ ]}
#~ ]}
#endregion
