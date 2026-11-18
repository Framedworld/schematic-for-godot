# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
extends Camera2D


func _ready() -> void:
	if not get_viewport().size_changed.is_connected(_fit_arena):
		get_viewport().size_changed.connect(_fit_arena)
	_fit_arena()


func _fit_arena() -> void:
	var area := get_viewport_rect().size
	zoom = (Vector2.ONE * minf(area.x, area.y)) / 850.0


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code 5c205179b7bb4c1fbede0ea9dc53130b
#~hash-v2
#~ {"class_name":"","crlf":true,"description":"","dispatchers":[],"enums":[],"parent":"Camera2D","tool":false,"variables":[],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":6,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{},"id":2,"kind":"call","p":{"cls":"Camera2D","method":"get_viewport"},"x":400.0,"y":230.0},
#~ {"d":{},"id":3,"kind":"bind_signal","p":{"cls":"Viewport","signal":"size_changed"},"x":980.0,"y":80.0},
#~ {"d":{},"id":4,"kind":"event_ref","p":{"fn":"_fit_arena"},"x":690.0,"y":230.0},
#~ {"d":{},"id":5,"kind":"call_self","p":{"fn":"_fit_arena"},"x":1310.0,"y":80.0}
#~ ],"wires":[
#~ [4,"fn",3,"fn"],[2,"ret",3,"target"],[1,"then",3,"exec"],[3,"then",5,"exec"]
#~ ]},
#~ {"id":2,"inputs":[],"kind":"function","locals":[{"default":"","infer":true,"name":"area","type":"Vector2"}],"name":"_fit_arena","next_id":12,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"fn_entry","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":3,"kind":"call","p":{"cls":"Camera2D","method":"get_viewport_rect"},"x":400.0,"y":270.0},
#~ {"d":{},"id":4,"kind":"break","p":{"type":"Rect2"},"x":690.0,"y":270.0},
#~ {"d":{},"id":5,"kind":"local_set","p":{"name":"area"},"x":980.0,"y":120.0},
#~ {"d":{},"id":6,"kind":"util","p":{"name":"minf"},"x":1890.0,"y":270.0},
#~ {"d":{},"id":7,"kind":"local_get","p":{"name":"area"},"split":{"value":true},"x":1310.0,"y":270.0},
#~ {"d":{},"id":8,"kind":"local_get","p":{"name":"area"},"split":{"value":true},"x":1310.0,"y":405.0},
#~ {"d":{"a0":"Vector2.ONE"},"id":9,"kind":"math","p":{"n":2.0,"op":"*"},"x":2180.0,"y":270.0},
#~ {"d":{"a1":"850.0"},"id":10,"kind":"math","p":{"n":2.0,"op":"/","unbracketed":true},"x":2470.0,"y":270.0},
#~ {"d":{},"id":11,"kind":"set_prop","p":{"cls":"Camera2D","prop":"zoom"},"x":2760.0,"y":120.0}
#~ ],"wires":[
#~ [3,"ret",4,"v"],[1,"then",5,"exec"],[4,"m_size",5,"value"],[7,"value~x",6,"a0"],[8,"value~y",6,"a1"],[6,"ret",9,"a1"],[9,"ret",10,"a0"],[5,"then",11,"exec"],
#~ [10,"ret",11,"value"]
#~ ]}
#~ ]}
#endregion
