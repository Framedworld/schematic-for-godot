# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
extends Node2D


func _draw() -> void:
	var corners := PackedVector2Array()
	for i in range(8):
		corners.append((Vector2.from_angle((((i + 0.5) * TAU) / 8.0)) * 24.0))
	draw_colored_polygon(corners, Color("#172930"))
	corners.append(corners[0])
	draw_polyline(corners, Color("#61716b"), 1.0, true)
	draw_circle(Vector2.ZERO, 18.5, Color("#293c40"), true, -1, true)
	draw_arc(Vector2.ZERO, 17.5, 0, TAU, 60, Color("#121f29"), 1.8, true)
	for i in range(3):
		var angle := ((i * TAU) / 3.0) - PI * 0.5
		draw_arc(Vector2.ZERO, 20.5, (angle - 0.19), (angle + 0.19), 8, Color("#bba171"), 2.2, true)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code cbb9aaf6bb48fe2990a9de5f68966cbe
#~hash-v2
#~ {"class_name":"","crlf":true,"description":"","dispatchers":[],"enums":[],"parent":"Node2D","tool":false,"variables":[],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[{"default":"","infer":true,"name":"corners","type":"PackedVector2Array"},{"default":"","infer":true,"name":"angle","type":"float"}],"name":"EventGraph","next_id":32,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_draw"},"x":80.0,"y":80.0},
#~ {"d":{"value":"PackedVector2Array()"},"id":2,"kind":"local_set","p":{"name":"corners"},"x":400.0,"y":80.0},
#~ {"d":{"first":"0","last":"7"},"id":3,"kind":"for","p":{"var":"i"},"x":730.0,"y":80.0},
#~ {"d":{},"id":4,"kind":"local_get","p":{"name":"corners"},"x":2210.0,"y":230.0},
#~ {"d":{},"id":5,"kind":"bcall","p":{"method":"append","type":"PackedVector2Array"},"x":2500.0,"y":80.0},
#~ {"d":{},"id":6,"kind":"bcall","p":{"method":"from_angle","type":"Vector2"},"x":1920.0,"y":230.0},
#~ {"d":{"a1":"0.5"},"id":7,"kind":"math","p":{"n":2.0,"op":"+"},"x":1050.0,"y":230.0},
#~ {"d":{"a1":"TAU"},"id":8,"kind":"math","p":{"n":2.0,"op":"*"},"x":1340.0,"y":230.0},
#~ {"d":{"a1":"8.0"},"id":9,"kind":"math","p":{"n":2.0,"op":"/"},"x":1630.0,"y":230.0},
#~ {"d":{"a1":"24.0"},"id":10,"kind":"math","p":{"n":2.0,"op":"*"},"x":2210.0,"y":365.0},
#~ {"d":{"a1":"Color(\"#172930\")"},"id":11,"kind":"call","p":{"cls":"Node2D","method":"draw_colored_polygon"},"x":1340.0,"y":570.0},
#~ {"d":{},"id":12,"kind":"local_get","p":{"name":"corners"},"x":1050.0,"y":720.0},
#~ {"d":{},"id":13,"kind":"local_get","p":{"name":"corners"},"x":1960.0,"y":720.0},
#~ {"d":{},"id":14,"kind":"bcall","p":{"method":"append","type":"PackedVector2Array"},"x":2250.0,"y":570.0},
#~ {"d":{},"id":15,"kind":"local_get","p":{"name":"corners"},"x":1670.0,"y":720.0},
#~ {"d":{"k":"0"},"id":16,"kind":"index","p":{},"x":1960.0,"y":855.0},
#~ {"d":{"a1":"Color(\"#61716b\")","a2":"1.0","a3":"true"},"id":17,"kind":"call","p":{"cls":"Node2D","method":"draw_polyline"},"x":2870.0,"y":570.0},
#~ {"d":{},"id":18,"kind":"local_get","p":{"name":"corners"},"x":2580.0,"y":720.0},
#~ {"d":{"a0":"Vector2.ZERO","a1":"18.5","a2":"Color(\"#293c40\")","a3":"true","a4":"-1","a5":"true"},"id":19,"kind":"call","p":{"cls":"Node2D","method":"draw_circle"},"x":3200.0,"y":570.0},
#~ {"d":{"a0":"Vector2.ZERO","a1":"17.5","a2":"0","a3":"TAU","a4":"60","a5":"Color(\"#121f29\")","a6":"1.8","a7":"true"},"id":20,"kind":"call","p":{"cls":"Node2D","method":"draw_arc"},"x":3530.0,"y":570.0},
#~ {"d":{"first":"0","last":"2"},"id":21,"kind":"for","p":{"var":"i"},"x":3860.0,"y":570.0},
#~ {"d":{"a1":"TAU"},"id":22,"kind":"math","p":{"n":2.0,"op":"*"},"x":4180.0,"y":720.0},
#~ {"d":{"a1":"3.0"},"id":23,"kind":"math","p":{"n":2.0,"op":"/"},"x":4470.0,"y":720.0},
#~ {"d":{"a1":"PI * 0.5"},"id":24,"kind":"math","p":{"n":2.0,"op":"-","unbracketed":true},"x":4760.0,"y":720.0},
#~ {"d":{},"id":25,"kind":"local_set","p":{"name":"angle"},"x":5050.0,"y":570.0},
#~ {"d":{"a0":"Vector2.ZERO","a1":"20.5","a4":"8","a5":"Color(\"#bba171\")","a6":"2.2","a7":"true"},"id":26,"kind":"call","p":{"cls":"Node2D","method":"draw_arc"},"x":5960.0,"y":570.0},
#~ {"d":{},"id":27,"kind":"local_get","p":{"name":"angle"},"x":5380.0,"y":720.0},
#~ {"d":{"a1":"0.19"},"id":28,"kind":"math","p":{"n":2.0,"op":"-"},"x":5670.0,"y":720.0},
#~ {"d":{},"id":29,"kind":"local_get","p":{"name":"angle"},"x":5380.0,"y":855.0},
#~ {"d":{"a1":"0.19"},"id":30,"kind":"math","p":{"n":2.0,"op":"+"},"x":5670.0,"y":855.0},
#~ {"d":{},"id":31,"kind":"reroute","p":{"t":"exec"},"x":965.0,"y":641.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[2,"then",3,"exec"],[4,"value",5,"target"],[3,"index",7,"a0"],[7,"ret",8,"a0"],[8,"ret",9,"a0"],[9,"ret",6,"a0"],[6,"ret",10,"a0"],
#~ [10,"ret",5,"a0"],[3,"body",5,"exec"],[12,"value",11,"a0"],[3,"completed",31,"i"],[13,"value",14,"target"],[15,"value",16,"c"],[16,"ret",14,"a0"],[11,"then",14,"exec"],
#~ [18,"value",17,"a0"],[14,"then",17,"exec"],[17,"then",19,"exec"],[19,"then",20,"exec"],[20,"then",21,"exec"],[21,"index",22,"a0"],[22,"ret",23,"a0"],[23,"ret",24,"a0"],
#~ [21,"body",25,"exec"],[24,"ret",25,"value"],[27,"value",28,"a0"],[29,"value",30,"a0"],[28,"ret",26,"a2"],[30,"ret",26,"a3"],[25,"then",26,"exec"],[31,"o",11,"exec"]
#~ ]}
#~ ]}
#endregion
