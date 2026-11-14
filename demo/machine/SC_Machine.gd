# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_Machine
extends Node3D
## Runs the whole chain reaction: each frame in the graph is one part of the machine.

## How many of the tower's blocks have reached the ground.
var blocks_down: int = 0

var __do_once_1_16: bool = false


func _ready() -> void:
	get_node(^"TrapSensor").body_entered.connect(_on_TrapSensor_body_entered)
	get_node(^"Launcher").body_entered.connect(_on_Launcher_body_entered)
	get_node(^"Button").body_entered.connect(_on_Button_body_entered)
	get_node(^"Floor").body_entered.connect(_on_Floor_body_entered)
	get_node(^"Restart").timeout.connect(_on_Restart_timeout)
	await get_tree().create_timer(1.2).timeout
	await create_tween().tween_property((get_node(^"Gate") as AnimatableBody3D), "position:y", 6.25, 0.25).finished


func _on_TrapSensor_body_entered(body: Node3D) -> void:
	await get_tree().create_timer(0.45).timeout
	await create_tween().tween_property((get_node(^"Trapdoor") as AnimatableBody3D), "rotation:z", -1.4, 0.2).finished


func _on_Launcher_body_entered(body: Node3D) -> void:
	var as_rigid_body_3d_12: RigidBody3D = body as RigidBody3D
	if as_rigid_body_3d_12 != null:
		as_rigid_body_3d_12.linear_velocity = Vector3(2.4, 5.6, 0.0)


func _on_Button_body_entered(body: Node3D) -> void:
	if not __do_once_1_16:
		__do_once_1_16 = true
		var spawned_18: RigidBody3D = (preload("res://demo/machine/cannonball.tscn") as PackedScene).instantiate() as RigidBody3D
		(get_node(^"Cannon/Muzzle") as Marker3D).add_child(spawned_18)
		spawned_18.linear_velocity = Vector3(20.0, 1.0, 0.0)


func _on_Floor_body_entered(body: Node3D) -> void:
	blocks_down += 1
	(get_node(^"UI/Counter") as Label).text = "Blocks down: {count}".format({"count": blocks_down})


func _on_Restart_timeout() -> void:
	get_tree().reload_current_scene()


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_Machine","description":"Runs the whole chain reaction: each frame in the graph is one part of the machine.","dispatchers":[],"parent":"Node3D","tool":false,"variables":[{"category":"","default":"","export":false,"name":"blocks_down","tooltip":"How many of the tower's blocks have reached the ground.","type":"int"}],"version":1,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":30,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":90.0},
#~ {"d":{"duration":"1.2"},"id":2,"kind":"tpl","p":{"id":"wait"},"x":500.0,"y":90.0},
#~ {"d":{},"id":3,"kind":"get_node","p":{"cls":"AnimatableBody3D","path":"Gate"},"x":640.0,"y":240.0},
#~ {"d":{"duration":"0.25","final":"6.25","property":"\"position:y\""},"id":4,"kind":"tpl","p":{"id":"tween_property"},"x":940.0,"y":90.0},
#~ {"d":{},"id":5,"kind":"comment","p":{"h":290,"text":"1. Gate: lift it, and the marble rolls","w":1540},"x":40.0,"y":20.0},
#~ {"d":{},"id":6,"kind":"signal_event","p":{"args":[["body","Node3D"]],"cls":"Area3D","path":"TrapSensor","signal":"body_entered"},"x":80.0,"y":490.0},
#~ {"d":{"duration":"0.45"},"id":7,"kind":"tpl","p":{"id":"wait"},"x":500.0,"y":490.0},
#~ {"d":{},"id":8,"kind":"get_node","p":{"cls":"AnimatableBody3D","path":"Trapdoor"},"x":640.0,"y":640.0},
#~ {"d":{"duration":"0.2","final":"-1.4","property":"\"rotation:z\""},"id":9,"kind":"tpl","p":{"id":"tween_property"},"x":940.0,"y":490.0},
#~ {"d":{},"id":10,"kind":"comment","p":{"h":290,"text":"2. Trapdoor: hold the marble a moment, then drop it","w":1540},"x":40.0,"y":420.0},
#~ {"d":{},"id":11,"kind":"signal_event","p":{"args":[["body","Node3D"]],"cls":"Area3D","path":"Launcher","signal":"body_entered"},"x":80.0,"y":890.0},
#~ {"d":{},"id":12,"kind":"cast","p":{"cls":"RigidBody3D"},"x":460.0,"y":890.0},
#~ {"d":{"value":"Vector3(2.4, 5.6, 0.0)"},"id":13,"kind":"set_prop","p":{"cls":"RigidBody3D","prop":"linear_velocity"},"x":1010.0,"y":890.0},
#~ {"d":{},"id":14,"kind":"comment","p":{"h":290,"text":"3. Launcher: throw the marble through the hoop","w":1540},"x":40.0,"y":820.0},
#~ {"d":{},"id":15,"kind":"signal_event","p":{"args":[["body","Node3D"]],"cls":"Area3D","path":"Button","signal":"body_entered"},"x":80.0,"y":1290.0},
#~ {"d":{},"id":16,"kind":"do_once","p":{},"x":430.0,"y":1290.0},
#~ {"d":{},"id":17,"kind":"get_node","p":{"cls":"Marker3D","path":"Cannon/Muzzle"},"x":440.0,"y":1460.0},
#~ {"d":{"scene":"preload(\"res://demo/machine/cannonball.tscn\")"},"id":18,"kind":"spawn","p":{"xt":"Transform3D"},"x":690.0,"y":1290.0},
#~ {"d":{"value":"Vector3(20.0, 1.0, 0.0)"},"id":19,"kind":"set_prop","p":{"cls":"RigidBody3D","prop":"linear_velocity"},"x":1130.0,"y":1290.0},
#~ {"d":{},"id":20,"kind":"comment","p":{"h":290,"text":"4. Cannon: the last domino presses the button","w":1540},"x":40.0,"y":1220.0},
#~ {"d":{},"id":21,"kind":"signal_event","p":{"args":[["body","Node3D"]],"cls":"Area3D","path":"Floor","signal":"body_entered"},"x":80.0,"y":1690.0},
#~ {"d":{},"id":22,"kind":"var_inc","p":{"by":1,"name":"blocks_down"},"x":420.0,"y":1690.0},
#~ {"d":{},"id":23,"kind":"format","p":{"text":"Blocks down: {count}"},"x":700.0,"y":1800.0},
#~ {"d":{},"id":24,"kind":"get_node","p":{"cls":"Label","path":"UI/Counter"},"x":910.0,"y":1778.0},
#~ {"d":{},"id":25,"kind":"set_prop","p":{"cls":"Label","prop":"text"},"x":1130.0,"y":1690.0},
#~ {"d":{},"id":26,"kind":"comment","p":{"h":290,"text":"5. Count: every block that reaches the ground","w":1540},"x":40.0,"y":1620.0},
#~ {"d":{},"id":27,"kind":"signal_event","p":{"args":[],"cls":"Timer","path":"Restart","signal":"timeout"},"x":80.0,"y":2090.0},
#~ {"d":{},"id":28,"kind":"tpl","p":{"id":"reload_scene"},"x":420.0,"y":2090.0},
#~ {"d":{},"id":29,"kind":"comment","p":{"h":230,"text":"Then set it all up again","w":760},"x":40.0,"y":2020.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[2,"then",4,"exec"],[3,"node",4,"target"],[6,"then",7,"exec"],[7,"then",9,"exec"],[8,"node",9,"target"],[11,"then",12,"exec"],[11,"p_body",12,"obj"],
#~ [12,"then",13,"exec"],[12,"as",13,"target"],[15,"then",16,"exec"],[16,"then",18,"exec"],[17,"node",18,"parent"],[18,"then",19,"exec"],[18,"ret",19,"target"],[21,"then",22,"exec"],
#~ [22,"then",25,"exec"],[22,"value",23,"f_count"],[24,"node",25,"target"],[23,"ret",25,"value"],[27,"then",28,"exec"]
#~ ]}
#~ ]}
#endregion
