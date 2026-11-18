# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
extends Node2D

const CORE := preload("res://demo/arcade/art/salvage_core.svg")

var phase := 0.0


func _ready() -> void:
	phase = fmod(((global_position.x * 0.013) + (global_position.y * 0.027)), TAU)


func _process(delta: float) -> void:
	phase += delta * 2.15
	queue_redraw()


func _draw() -> void:
	var lift := -3.0 + (sin(phase) * 2.2)
	var spread := 0.86 + (0.14 * cos(phase))
	draw_set_transform(Vector2(1, 4), 0.0, Vector2(1, 0.42))
	draw_circle(Vector2.ZERO, 14.0, Color(0.015, 0.025, 0.035, 0.56), true, -1, true)
	draw_set_transform(Vector2(0, lift), 0.0, Vector2((0.156 * spread), 0.156))
	draw_texture(CORE, ((-CORE.get_size()) * 0.5))
	draw_set_transform(Vector2.ZERO)
	var glint := pow(maxf(0.0, sin((phase * 1.4))), 8.0)
	if glint > 0.02:
		var at := Vector2(4.0, (lift - 10.0))
		draw_line((at - Vector2((4.5 * glint), 0)), (at + Vector2((4.5 * glint), 0)), Color(1, 0.99, 0.84, glint), 1.2, true)
		draw_line((at - Vector2(0, (6.0 * glint))), (at + Vector2(0, (6.0 * glint))), Color(1, 0.99, 0.84, glint), 1.2, true)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code eeb9f4c8a03f515b957c2c53a6a505d1
#~hash-v2
#~ {"class_name":"","crlf":true,"description":"","dispatchers":[],"enums":[],"extra_code":"const CORE := preload(\"res://demo/arcade/art/salvage_core.svg\")","parent":"Node2D","tool":false,"variables":[{"category":"","default":"0.0","export":false,"name":"phase","tooltip":"","type":"float","written":"infer"}],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[{"default":"","infer":true,"name":"lift","type":"float"},{"default":"","infer":true,"name":"spread","type":"float"},{"default":"","infer":true,"name":"glint","type":"float"},{"default":"","infer":true,"name":"at","type":"Vector2"}],"name":"EventGraph","next_id":76,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"a1":"TAU"},"id":2,"kind":"util","p":{"name":"fmod"},"x":1560.0,"y":230.0},
#~ {"d":{},"id":3,"kind":"get_prop","p":{"cls":"Node2D","prop":"global_position"},"split":{"value":true},"x":400.0,"y":230.0},
#~ {"d":{"a1":"0.013"},"id":4,"kind":"math","p":{"n":2.0,"op":"*"},"x":980.0,"y":230.0},
#~ {"d":{},"id":5,"kind":"get_prop","p":{"cls":"Node2D","prop":"global_position"},"split":{"value":true},"x":400.0,"y":365.0},
#~ {"d":{"a1":"0.027"},"id":6,"kind":"math","p":{"n":2.0,"op":"*"},"x":980.0,"y":365.0},
#~ {"d":{},"id":7,"kind":"math","p":{"n":2.0,"op":"+"},"x":1270.0,"y":230.0},
#~ {"d":{},"id":8,"kind":"var_set","p":{"name":"phase"},"x":1850.0,"y":80.0},
#~ {"d":{},"id":9,"kind":"event","p":{"name":"_process"},"x":80.0,"y":640.0},
#~ {"d":{"a1":"2.15"},"id":10,"kind":"math","p":{"n":2.0,"op":"*","unbracketed":true},"x":400.0,"y":790.0},
#~ {"d":{},"id":11,"kind":"var_set","p":{"name":"phase","op":"+"},"x":690.0,"y":640.0},
#~ {"d":{},"id":12,"kind":"call","p":{"cls":"Node2D","method":"queue_redraw"},"x":1020.0,"y":640.0},
#~ {"d":{},"id":13,"kind":"event","p":{"name":"_draw"},"x":80.0,"y":1065.0},
#~ {"d":{},"id":14,"kind":"util","p":{"name":"sin"},"x":690.0,"y":1215.0},
#~ {"d":{},"id":15,"kind":"var_get","p":{"name":"phase"},"x":400.0,"y":1215.0},
#~ {"d":{"a1":"2.2"},"id":16,"kind":"math","p":{"n":2.0,"op":"*"},"x":980.0,"y":1215.0},
#~ {"d":{"a0":"-3.0"},"id":17,"kind":"math","p":{"n":2.0,"op":"+","unbracketed":true},"x":1270.0,"y":1215.0},
#~ {"d":{},"id":18,"kind":"local_set","p":{"name":"lift"},"x":1560.0,"y":1065.0},
#~ {"d":{},"id":19,"kind":"util","p":{"name":"cos"},"x":2180.0,"y":1215.0},
#~ {"d":{},"id":20,"kind":"var_get","p":{"name":"phase"},"x":1890.0,"y":1215.0},
#~ {"d":{"a0":"0.14"},"id":21,"kind":"math","p":{"n":2.0,"op":"*"},"x":2470.0,"y":1215.0},
#~ {"d":{"a0":"0.86"},"id":22,"kind":"math","p":{"n":2.0,"op":"+","unbracketed":true},"x":2760.0,"y":1215.0},
#~ {"d":{},"id":23,"kind":"local_set","p":{"name":"spread"},"x":3050.0,"y":1065.0},
#~ {"d":{"a0":"Vector2(1, 4)","a1":"0.0","a2":"Vector2(1, 0.42)"},"id":24,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":3380.0,"y":1065.0},
#~ {"d":{"a0":"Vector2.ZERO","a1":"14.0","a2":"Color(0.015, 0.025, 0.035, 0.56)","a3":"true","a4":"-1","a5":"true"},"id":25,"kind":"call","p":{"cls":"Node2D","method":"draw_circle"},"x":3710.0,"y":1065.0},
#~ {"d":{"a1":"0.0"},"id":26,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":4910.0,"y":1065.0},
#~ {"d":{"a0":"0"},"id":27,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":4620.0,"y":1215.0},
#~ {"d":{},"id":28,"kind":"local_get","p":{"name":"lift"},"x":4330.0,"y":1215.0},
#~ {"d":{"a1":"0.156"},"id":29,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":4620.0,"y":1350.0},
#~ {"d":{},"id":30,"kind":"local_get","p":{"name":"spread"},"x":4040.0,"y":1215.0},
#~ {"d":{"a0":"0.156"},"id":31,"kind":"math","p":{"n":2.0,"op":"*"},"x":4330.0,"y":1350.0},
#~ {"d":{"a0":"CORE"},"id":32,"kind":"call","p":{"cls":"Node2D","method":"draw_texture"},"x":6110.0,"y":1065.0},
#~ {"d":{"target":"CORE"},"id":33,"kind":"dyn_call","p":{"inline":true,"method":"get_size","n":0.0},"x":5240.0,"y":1215.0},
#~ {"d":{},"id":34,"kind":"op","p":{"l":"any","op":"unary-","r":"","ret":"any"},"x":5530.0,"y":1215.0},
#~ {"d":{"a1":"0.5"},"id":35,"kind":"math","p":{"n":2.0,"op":"*"},"x":5820.0,"y":1215.0},
#~ {"d":{"a0":"Vector2.ZERO"},"id":36,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":6440.0,"y":1065.0},
#~ {"d":{"a1":"8.0"},"id":37,"kind":"util","p":{"name":"pow"},"x":7930.0,"y":1215.0},
#~ {"d":{"a0":"0.0"},"id":38,"kind":"util","p":{"name":"maxf"},"x":7640.0,"y":1215.0},
#~ {"d":{},"id":39,"kind":"util","p":{"name":"sin"},"x":7350.0,"y":1215.0},
#~ {"d":{},"id":40,"kind":"var_get","p":{"name":"phase"},"x":6770.0,"y":1215.0},
#~ {"d":{"a1":"1.4"},"id":41,"kind":"math","p":{"n":2.0,"op":"*"},"x":7060.0,"y":1215.0},
#~ {"d":{},"id":42,"kind":"local_set","p":{"name":"glint"},"x":8220.0,"y":1065.0},
#~ {"d":{},"id":43,"kind":"local_get","p":{"name":"glint"},"x":8550.0,"y":1215.0},
#~ {"d":{"a1":"0.02"},"id":44,"kind":"math","p":{"n":2.0,"op":">","unbracketed":true},"x":8840.0,"y":1215.0},
#~ {"d":{},"id":45,"kind":"branch","p":{},"x":9130.0,"y":1065.0},
#~ {"d":{"a0":"4.0"},"id":46,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":10010.0,"y":1215.0},
#~ {"d":{},"id":47,"kind":"local_get","p":{"name":"lift"},"x":9430.0,"y":1215.0},
#~ {"d":{"a1":"10.0"},"id":48,"kind":"math","p":{"n":2.0,"op":"-"},"x":9720.0,"y":1215.0},
#~ {"d":{},"id":49,"kind":"local_set","p":{"name":"at"},"x":10300.0,"y":1065.0},
#~ {"d":{"a3":"1.2","a4":"true"},"id":50,"kind":"call","p":{"cls":"Node2D","method":"draw_line"},"x":11790.0,"y":1065.0},
#~ {"d":{},"id":51,"kind":"local_get","p":{"name":"at"},"x":11210.0,"y":1215.0},
#~ {"d":{"a1":"0"},"id":52,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":11210.0,"y":1350.0},
#~ {"d":{},"id":53,"kind":"local_get","p":{"name":"glint"},"x":10630.0,"y":1215.0},
#~ {"d":{"a0":"4.5"},"id":54,"kind":"math","p":{"n":2.0,"op":"*"},"x":10920.0,"y":1215.0},
#~ {"d":{},"id":55,"kind":"math","p":{"n":2.0,"op":"-"},"x":11500.0,"y":1215.0},
#~ {"d":{},"id":56,"kind":"local_get","p":{"name":"at"},"x":11210.0,"y":1485.0},
#~ {"d":{"a1":"0"},"id":57,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":11210.0,"y":1620.0},
#~ {"d":{},"id":58,"kind":"local_get","p":{"name":"glint"},"x":10630.0,"y":1350.0},
#~ {"d":{"a0":"4.5"},"id":59,"kind":"math","p":{"n":2.0,"op":"*"},"x":10920.0,"y":1350.0},
#~ {"d":{},"id":60,"kind":"math","p":{"n":2.0,"op":"+"},"x":11500.0,"y":1350.0},
#~ {"d":{"a0":"1","a1":"0.99","a2":"0.84"},"id":61,"kind":"ctor","p":{"i":4.0,"type":"Color"},"x":11500.0,"y":1485.0},
#~ {"d":{},"id":62,"kind":"local_get","p":{"name":"glint"},"x":11210.0,"y":1755.0},
#~ {"d":{"a3":"1.2","a4":"true"},"id":63,"kind":"call","p":{"cls":"Node2D","method":"draw_line"},"x":13280.0,"y":1065.0},
#~ {"d":{},"id":64,"kind":"local_get","p":{"name":"at"},"x":12700.0,"y":1215.0},
#~ {"d":{"a0":"0"},"id":65,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":12700.0,"y":1350.0},
#~ {"d":{},"id":66,"kind":"local_get","p":{"name":"glint"},"x":12120.0,"y":1215.0},
#~ {"d":{"a0":"6.0"},"id":67,"kind":"math","p":{"n":2.0,"op":"*"},"x":12410.0,"y":1215.0},
#~ {"d":{},"id":68,"kind":"math","p":{"n":2.0,"op":"-"},"x":12990.0,"y":1215.0},
#~ {"d":{},"id":69,"kind":"local_get","p":{"name":"at"},"x":12700.0,"y":1485.0},
#~ {"d":{"a0":"0"},"id":70,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":12700.0,"y":1620.0},
#~ {"d":{},"id":71,"kind":"local_get","p":{"name":"glint"},"x":12120.0,"y":1350.0},
#~ {"d":{"a0":"6.0"},"id":72,"kind":"math","p":{"n":2.0,"op":"*"},"x":12410.0,"y":1350.0},
#~ {"d":{},"id":73,"kind":"math","p":{"n":2.0,"op":"+"},"x":12990.0,"y":1350.0},
#~ {"d":{"a0":"1","a1":"0.99","a2":"0.84"},"id":74,"kind":"ctor","p":{"i":4.0,"type":"Color"},"x":12990.0,"y":1485.0},
#~ {"d":{},"id":75,"kind":"local_get","p":{"name":"glint"},"x":12700.0,"y":1755.0}
#~ ],"wires":[
#~ [3,"value~x",4,"a0"],[5,"value~y",6,"a0"],[4,"ret",7,"a0"],[6,"ret",7,"a1"],[7,"ret",2,"a0"],[1,"then",8,"exec"],[2,"ret",8,"value"],[9,"p_delta",10,"a0"],
#~ [9,"then",11,"exec"],[10,"ret",11,"value"],[11,"then",12,"exec"],[15,"value",14,"a0"],[14,"ret",16,"a0"],[16,"ret",17,"a1"],[13,"then",18,"exec"],[17,"ret",18,"value"],
#~ [20,"value",19,"a0"],[19,"ret",21,"a1"],[21,"ret",22,"a1"],[18,"then",23,"exec"],[22,"ret",23,"value"],[23,"then",24,"exec"],[24,"then",25,"exec"],[28,"value",27,"a1"],
#~ [30,"value",31,"a1"],[31,"ret",29,"a0"],[27,"ret",26,"a0"],[29,"ret",26,"a2"],[25,"then",26,"exec"],[33,"ret",34,"a"],[34,"ret",35,"a0"],[35,"ret",32,"a1"],
#~ [26,"then",32,"exec"],[32,"then",36,"exec"],[40,"value",41,"a0"],[41,"ret",39,"a0"],[39,"ret",38,"a1"],[38,"ret",37,"a0"],[36,"then",42,"exec"],[37,"ret",42,"value"],
#~ [43,"value",44,"a0"],[42,"then",45,"exec"],[44,"ret",45,"cond"],[47,"value",48,"a0"],[48,"ret",46,"a1"],[45,"true",49,"exec"],[46,"ret",49,"value"],[53,"value",54,"a1"],
#~ [54,"ret",52,"a0"],[51,"value",55,"a0"],[52,"ret",55,"a1"],[58,"value",59,"a1"],[59,"ret",57,"a0"],[56,"value",60,"a0"],[57,"ret",60,"a1"],[62,"value",61,"a3"],
#~ [55,"ret",50,"a0"],[60,"ret",50,"a1"],[61,"ret",50,"a2"],[49,"then",50,"exec"],[66,"value",67,"a1"],[67,"ret",65,"a1"],[64,"value",68,"a0"],[65,"ret",68,"a1"],
#~ [71,"value",72,"a1"],[72,"ret",70,"a1"],[69,"value",73,"a0"],[70,"ret",73,"a1"],[75,"value",74,"a3"],[68,"ret",63,"a0"],[73,"ret",63,"a1"],[74,"ret",63,"a2"],
#~ [50,"then",63,"exec"]
#~ ]}
#~ ]}
#endregion
