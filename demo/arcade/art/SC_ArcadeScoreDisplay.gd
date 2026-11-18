# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
extends CanvasLayer

@onready var backdrop: Panel = $Readout
@onready var hud: Label = $HUD
@onready var caption: Label = $Mode


func _ready() -> void:
	if not get_viewport().size_changed.is_connected(_layout):
		get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	var scale_factor := clampf((minf(size.x, size.y) / 900.0), 0.65, 2.7)
	var origin := Vector2(21, 20) * scale_factor
	for control in [backdrop, hud, caption]:
		control.scale = Vector2.ONE * scale_factor
	backdrop.position = origin
	hud.position = origin + (Vector2(18, 20) * scale_factor)
	caption.position = origin + (Vector2(18, 7) * scale_factor)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code 80c1892b9fb0332b4acfae4749066834
#~hash-v2
#~ {"class_name":"","crlf":true,"description":"","dispatchers":[],"enums":[],"parent":"CanvasLayer","tool":false,"variables":[{"category":"","default":"$Readout","export":false,"name":"backdrop","raw":"@onready var backdrop: Panel = $Readout","tooltip":"","type":"Panel"},{"category":"","default":"$HUD","export":false,"name":"hud","raw":"@onready var hud: Label = $HUD","tooltip":"","type":"Label"},{"category":"","default":"$Mode","export":false,"name":"caption","raw":"@onready var caption: Label = $Mode","tooltip":"","type":"Label"}],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":6,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{},"id":2,"kind":"call","p":{"cls":"CanvasLayer","method":"get_viewport"},"x":400.0,"y":230.0},
#~ {"d":{},"id":3,"kind":"bind_signal","p":{"cls":"Viewport","signal":"size_changed"},"x":980.0,"y":80.0},
#~ {"d":{},"id":4,"kind":"event_ref","p":{"fn":"_layout"},"x":690.0,"y":230.0},
#~ {"d":{},"id":5,"kind":"call_self","p":{"fn":"_layout"},"x":1310.0,"y":80.0}
#~ ],"wires":[
#~ [4,"fn",3,"fn"],[2,"ret",3,"target"],[1,"then",3,"exec"],[3,"then",5,"exec"]
#~ ]},
#~ {"id":2,"inputs":[],"kind":"function","locals":[{"default":"","infer":true,"name":"size","type":"Vector2"},{"default":"","infer":true,"name":"scale_factor","type":"float"},{"default":"","infer":true,"name":"origin","type":"Vector2"}],"name":"_layout","next_id":40,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"fn_entry","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":3,"kind":"call","p":{"cls":"CanvasLayer","method":"get_viewport"},"x":400.0,"y":270.0},
#~ {"d":{},"id":4,"kind":"call","p":{"cls":"Viewport","method":"get_visible_rect"},"x":690.0,"y":270.0},
#~ {"d":{},"id":5,"kind":"break","p":{"type":"Rect2"},"x":980.0,"y":270.0},
#~ {"d":{},"id":6,"kind":"local_set","p":{"name":"size"},"x":1270.0,"y":120.0},
#~ {"d":{"a1":"0.65","a2":"2.7"},"id":7,"kind":"util","p":{"name":"clampf"},"x":2760.0,"y":270.0},
#~ {"d":{},"id":8,"kind":"util","p":{"name":"minf"},"x":2180.0,"y":270.0},
#~ {"d":{},"id":9,"kind":"local_get","p":{"name":"size"},"split":{"value":true},"x":1600.0,"y":270.0},
#~ {"d":{},"id":10,"kind":"local_get","p":{"name":"size"},"split":{"value":true},"x":1600.0,"y":405.0},
#~ {"d":{"a1":"900.0"},"id":11,"kind":"math","p":{"n":2.0,"op":"/"},"x":2470.0,"y":270.0},
#~ {"d":{},"id":12,"kind":"local_set","p":{"name":"scale_factor"},"x":3050.0,"y":120.0},
#~ {"d":{},"id":13,"kind":"local_get","p":{"name":"scale_factor"},"x":3380.0,"y":270.0},
#~ {"d":{"a0":"Vector2(21, 20)"},"id":14,"kind":"math","p":{"n":2.0,"op":"*","unbracketed":true},"x":3670.0,"y":270.0},
#~ {"d":{},"id":15,"kind":"local_set","p":{"name":"origin"},"x":3960.0,"y":120.0},
#~ {"d":{},"id":16,"kind":"make_array","p":{"n":3.0},"x":4580.0,"y":270.0},
#~ {"d":{},"id":17,"kind":"var_get","p":{"name":"backdrop"},"x":4290.0,"y":270.0},
#~ {"d":{},"id":18,"kind":"var_get","p":{"name":"hud"},"x":4290.0,"y":405.0},
#~ {"d":{},"id":19,"kind":"var_get","p":{"name":"caption"},"x":4290.0,"y":540.0},
#~ {"d":{},"id":20,"kind":"for_each","p":{"t":"any","var":"control"},"x":4870.0,"y":120.0},
#~ {"d":{},"id":21,"kind":"local_get","p":{"name":"scale_factor"},"x":5190.0,"y":270.0},
#~ {"d":{"a0":"Vector2.ONE"},"id":22,"kind":"math","p":{"n":2.0,"op":"*","unbracketed":true},"x":5480.0,"y":270.0},
#~ {"d":{},"id":23,"kind":"dyn_set","p":{"name":"scale"},"x":5770.0,"y":120.0},
#~ {"d":{},"id":24,"kind":"local_get","p":{"name":"origin"},"x":5190.0,"y":895.0},
#~ {"d":{},"id":25,"kind":"var_get","p":{"name":"backdrop"},"x":5190.0,"y":1030.0},
#~ {"d":{},"id":26,"kind":"set_prop","p":{"cls":"Panel","prop":"position"},"x":5480.0,"y":745.0},
#~ {"d":{},"id":27,"kind":"local_get","p":{"name":"origin"},"x":6100.0,"y":895.0},
#~ {"d":{},"id":28,"kind":"local_get","p":{"name":"scale_factor"},"x":5810.0,"y":895.0},
#~ {"d":{"a0":"Vector2(18, 20)"},"id":29,"kind":"math","p":{"n":2.0,"op":"*"},"x":6100.0,"y":1030.0},
#~ {"d":{},"id":30,"kind":"math","p":{"n":2.0,"op":"+","unbracketed":true},"x":6390.0,"y":895.0},
#~ {"d":{},"id":31,"kind":"var_get","p":{"name":"hud"},"x":6390.0,"y":1030.0},
#~ {"d":{},"id":32,"kind":"set_prop","p":{"cls":"Label","prop":"position"},"x":6680.0,"y":745.0},
#~ {"d":{},"id":33,"kind":"local_get","p":{"name":"origin"},"x":7300.0,"y":895.0},
#~ {"d":{},"id":34,"kind":"local_get","p":{"name":"scale_factor"},"x":7010.0,"y":895.0},
#~ {"d":{"a0":"Vector2(18, 7)"},"id":35,"kind":"math","p":{"n":2.0,"op":"*"},"x":7300.0,"y":1030.0},
#~ {"d":{},"id":36,"kind":"math","p":{"n":2.0,"op":"+","unbracketed":true},"x":7590.0,"y":895.0},
#~ {"d":{},"id":37,"kind":"var_get","p":{"name":"caption"},"x":7590.0,"y":1030.0},
#~ {"d":{},"id":38,"kind":"set_prop","p":{"cls":"Label","prop":"position"},"x":7880.0,"y":745.0},
#~ {"d":{},"id":39,"kind":"reroute","p":{"t":"exec"},"x":5105.0,"y":816.0}
#~ ],"wires":[
#~ [3,"ret",4,"target"],[4,"ret",5,"v"],[1,"then",6,"exec"],[5,"m_size",6,"value"],[9,"value~x",8,"a0"],[10,"value~y",8,"a1"],[8,"ret",11,"a0"],[11,"ret",7,"a0"],
#~ [6,"then",12,"exec"],[7,"ret",12,"value"],[13,"value",14,"a1"],[12,"then",15,"exec"],[14,"ret",15,"value"],[17,"value",16,"e0"],[18,"value",16,"e1"],[19,"value",16,"e2"],
#~ [15,"then",20,"exec"],[16,"ret",20,"array"],[21,"value",22,"a1"],[20,"body",23,"exec"],[20,"element",23,"target"],[22,"ret",23,"value"],[20,"completed",39,"i"],[25,"value",26,"target"],
#~ [24,"value",26,"value"],[28,"value",29,"a1"],[27,"value",30,"a0"],[29,"ret",30,"a1"],[26,"then",32,"exec"],[31,"value",32,"target"],[30,"ret",32,"value"],[34,"value",35,"a1"],
#~ [33,"value",36,"a0"],[35,"ret",36,"a1"],[32,"then",38,"exec"],[37,"value",38,"target"],[36,"ret",38,"value"],[39,"o",26,"exec"]
#~ ]}
#~ ]}
#endregion
