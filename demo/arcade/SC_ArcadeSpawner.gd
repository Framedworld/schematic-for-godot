# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_ArcadeSpawner
extends Node2D
## Spawns a scene at its own position on a repeating timer.

## The scene to spawn.
@export var scene: PackedScene
## Seconds between spawns.
@export var interval: float = 2.0


func _ready() -> void:
	__sc_set_timer(SpawnOne, interval, true)


func SpawnOne() -> void:
	if is_instance_valid(scene):
		var spawned_10: Node = (scene as PackedScene).instantiate()
		add_child(spawned_10)


func __sc_set_timer(event: Callable, time: float, looping: bool) -> Timer:
	var timer := Timer.new()
	timer.wait_time = maxf(time, 0.001)
	timer.one_shot = not looping
	add_child(timer)
	timer.timeout.connect(event)
	if not looping:
		timer.timeout.connect(timer.queue_free)
	timer.start()
	return timer


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_ArcadeSpawner","description":"Spawns a scene at its own position on a repeating timer.","dispatchers":[],"parent":"Node2D","tool":false,"variables":[{"category":"","default":"","export":true,"name":"scene","tooltip":"The scene to spawn.","type":"PackedScene"},{"category":"","default":"2.0","export":true,"name":"interval","tooltip":"Seconds between spawns.","type":"float"}],"version":1,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":12,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"looping":"true"},"id":2,"kind":"tpl","p":{"id":"set_timer"},"x":420.0,"y":80.0},
#~ {"d":{},"id":3,"kind":"event_ref","p":{"fn":"SpawnOne"},"x":120.0,"y":240.0},
#~ {"d":{},"id":4,"kind":"var_get","p":{"name":"interval"},"x":200.0,"y":320.0},
#~ {"d":{},"id":5,"kind":"comment","p":{"h":400.0,"text":"Start a repeating timer","w":760.0},"x":40.0,"y":10.0},
#~ {"d":{},"id":6,"kind":"custom_event","p":{"name":"SpawnOne","params":[]},"x":80.0,"y":520.0},
#~ {"d":{},"id":7,"kind":"var_get","p":{"name":"scene"},"x":140.0,"y":680.0},
#~ {"d":{},"id":8,"kind":"is_valid","p":{},"x":380.0,"y":520.0},
#~ {"d":{},"id":9,"kind":"var_get","p":{"name":"scene"},"x":480.0,"y":720.0},
#~ {"d":{},"id":10,"kind":"spawn","p":{"xt":"Transform2D"},"x":700.0,"y":520.0},
#~ {"d":{},"id":11,"kind":"comment","p":{"h":400.0,"text":"Spawn one as a child of this node (set Scene in the Inspector)","w":1040.0},"x":40.0,"y":450.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[3,"fn",2,"event"],[4,"value",2,"time"],[6,"then",8,"exec"],[7,"value",8,"obj"],[8,"valid",10,"exec"],[9,"value",10,"scene"]
#~ ]}
#~ ]}
#endregion
