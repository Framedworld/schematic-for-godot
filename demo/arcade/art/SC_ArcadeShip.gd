# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
extends Node2D
## Rendering only. The starter CharacterBody2D owns all motion.

const HULL := preload("res://demo/arcade/art/interceptor.svg")
const PLUME := Color("#63e9de")
const ECHO_LIFE := 0.42
const SHIP_SCALE := Vector2(0.21, 0.21)

var heading := 0.0
var elapsed := 0.0
var thrust := 0.0
var trail := PackedVector2Array()
var bursts: Array[Dictionary] = []
@onready var pilot := get_parent() as CharacterBody2D


func _ready() -> void:
	top_level = true
	var state := get_tree().get_first_node_in_group(&"game_state")
	if state:
		state.connect(&"score_changed", _on_pickup)


func _physics_process(delta: float) -> void:
	elapsed += delta
	thrust = move_toward(thrust, minf((pilot.velocity.length() / 200.0), 1.0), (8.0 * delta))
	if pilot.velocity.length_squared() > 1.0:
		heading = lerp_angle(heading, pilot.velocity.angle(), (1.0 - exp((-15.0 * delta))))
	trail.insert(0, (pilot.global_position + Vector2(-24, 0).rotated(heading)))
	if trail.size() > 13:
		trail.resize(13)
	for i: int in range((bursts.size() - 1), -1, -1):
		bursts[i].age = (bursts[i].age + delta)
		if bursts[i].age >= ECHO_LIFE:
			bursts.remove_at(i)
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(pilot):
		return
	var pos := pilot.global_position
	for i: int in range((trail.size() - 1), 0, -1):
		var strength := (1.0 - (float(i) / trail.size())) * thrust
		if trail[i].distance_squared_to(trail[(i - 1)]) > 0.01:
			draw_line(trail[i], trail[(i - 1)], Color(PLUME, (0.45 * strength)), (1.0 + (5.0 * strength)), true)
	for burst: Dictionary in bursts:
		var age: float = burst.age / ECHO_LIFE
		var r := lerpf(14.0, 42.0, (1.0 - pow((1.0 - age), 2)))
		var at: Vector2 = burst.at
		for j in range(8):
			var axis := Vector2.from_angle((((j * TAU) / 8.0) + 0.25))
			draw_line((at + (axis * r)), (at + (axis * (r + (7 * (1.0 - age))))), Color(1.0, 0.80, 0.44, (1.0 - age)), 2.0, true)
	draw_set_transform((pos + Vector2(4, 6)), heading, SHIP_SCALE)
	draw_texture(HULL, ((-HULL.get_size()) * 0.5), Color(0.01, 0.03, 0.05, 0.52))
	draw_set_transform(pos, heading)
	for side in [-1, 1]:
		var jet := Vector2(-27, (side * 9))
		var span := 4.0 + (thrust * (12.0 + (3.0 * sin(((elapsed * 45.0) + side)))))
		draw_colored_polygon(PackedVector2Array([(jet + Vector2(2, -2.6)), (jet + Vector2((-span), 0)), (jet + Vector2(2, 2.6))]), Color(0.25, 0.91, 0.89, 0.8))
		draw_line(jet, (jet + Vector2(((-span) * 0.66), 0)), Color("#d1fff6"), 2.0, true)
	draw_set_transform(pos, heading, SHIP_SCALE)
	draw_texture(HULL, ((-HULL.get_size()) * 0.5))


func _on_pickup(_score: int) -> void:
	bursts.append({"at": pilot.global_position, "age": 0.0})


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~code eb2d8d051fdb2ec5cb7271d0f4138ce7
#~hash-v2
#~ {"class_name":"","crlf":true,"description":"Rendering only. The starter CharacterBody2D owns all motion.","dispatchers":[],"enums":[],"extra_code":"const HULL := preload(\"res://demo/arcade/art/interceptor.svg\")\nconst PLUME := Color(\"#63e9de\")\nconst ECHO_LIFE := 0.42\nconst SHIP_SCALE := Vector2(0.21, 0.21)","parent":"Node2D","tool":false,"variables":[{"category":"","default":"0.0","export":false,"name":"heading","tooltip":"","type":"float","written":"infer"},{"category":"","default":"0.0","export":false,"name":"elapsed","tooltip":"","type":"float","written":"infer"},{"category":"","default":"0.0","export":false,"name":"thrust","tooltip":"","type":"float","written":"infer"},{"category":"","default":"PackedVector2Array()","export":false,"name":"trail","tooltip":"","type":"PackedVector2Array","written":"infer"},{"category":"","default":"[]","export":false,"name":"bursts","tooltip":"","type":"Array[Dictionary]"},{"category":"","default":"get_parent() as CharacterBody2D","export":false,"name":"pilot","raw":"@onready var pilot := get_parent() as CharacterBody2D","tooltip":"","type":"CharacterBody2D","written":"infer"}],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[{"default":"","infer":true,"name":"state","type":"Node"},{"default":"","infer":true,"name":"pos","type":"Vector2"},{"default":"","infer":true,"name":"strength","type":"float"},{"default":"","name":"age","type":"float"},{"default":"","infer":true,"name":"r","type":"float"},{"default":"","name":"at","type":"Vector2"},{"default":"","infer":true,"name":"axis","type":"Vector2"},{"default":"","infer":true,"name":"jet","type":"Vector2"},{"default":"","infer":true,"name":"span","type":"float"}],"name":"EventGraph","next_id":211,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":80.0,"y":80.0},
#~ {"d":{"value":"true"},"id":2,"kind":"set_prop","p":{"cls":"Node2D","prop":"top_level"},"x":400.0,"y":80.0},
#~ {"d":{},"id":3,"kind":"call","p":{"cls":"Node2D","method":"get_tree"},"x":730.0,"y":230.0},
#~ {"d":{"a0":"&\"game_state\""},"id":4,"kind":"call","p":{"cls":"SceneTree","method":"get_first_node_in_group"},"x":1310.0,"y":80.0},
#~ {"d":{},"id":5,"kind":"local_set","p":{"name":"state"},"x":1640.0,"y":80.0},
#~ {"d":{},"id":6,"kind":"local_get","p":{"name":"state"},"x":1970.0,"y":230.0},
#~ {"d":{},"id":7,"kind":"branch","p":{},"x":2260.0,"y":80.0},
#~ {"d":{},"id":8,"kind":"local_get","p":{"name":"state"},"x":2560.0,"y":230.0},
#~ {"d":{"a0":"&\"score_changed\""},"id":9,"kind":"call","p":{"cls":"Node","method":"connect"},"x":2850.0,"y":80.0},
#~ {"d":{},"id":10,"kind":"event_ref","p":{"fn":"_on_pickup"},"x":2560.0,"y":365.0},
#~ {"d":{},"id":11,"kind":"event","p":{"name":"_physics_process"},"x":80.0,"y":640.0},
#~ {"d":{},"id":12,"kind":"var_set","p":{"name":"elapsed","op":"+"},"x":400.0,"y":640.0},
#~ {"d":{},"id":13,"kind":"util","p":{"name":"move_toward"},"x":2180.0,"y":790.0},
#~ {"d":{},"id":14,"kind":"var_get","p":{"name":"thrust"},"x":1890.0,"y":790.0},
#~ {"d":{"a1":"1.0"},"id":15,"kind":"util","p":{"name":"minf"},"x":1890.0,"y":925.0},
#~ {"d":{},"id":16,"kind":"var_get","p":{"name":"pilot"},"x":730.0,"y":790.0},
#~ {"d":{},"id":17,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"velocity"},"x":1020.0,"y":790.0},
#~ {"d":{},"id":18,"kind":"bcall","p":{"method":"length","type":"Vector2"},"x":1310.0,"y":790.0},
#~ {"d":{"a1":"200.0"},"id":19,"kind":"math","p":{"n":2.0,"op":"/"},"x":1600.0,"y":790.0},
#~ {"d":{"a0":"8.0"},"id":20,"kind":"math","p":{"n":2.0,"op":"*"},"x":1890.0,"y":1060.0},
#~ {"d":{},"id":21,"kind":"var_set","p":{"name":"thrust"},"x":2470.0,"y":640.0},
#~ {"d":{},"id":22,"kind":"sequence","p":{"n":2.0},"x":2800.0,"y":640.0},
#~ {"d":{},"id":23,"kind":"var_get","p":{"name":"pilot"},"x":3050.0,"y":790.0},
#~ {"d":{},"id":24,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"velocity"},"x":3340.0,"y":790.0},
#~ {"d":{},"id":25,"kind":"bcall","p":{"method":"length_squared","type":"Vector2"},"x":3630.0,"y":790.0},
#~ {"d":{"a1":"1.0"},"id":26,"kind":"math","p":{"n":2.0,"op":">","unbracketed":true},"x":3920.0,"y":790.0},
#~ {"d":{},"id":27,"kind":"branch","p":{},"x":4210.0,"y":640.0},
#~ {"d":{},"id":28,"kind":"util","p":{"name":"lerp_angle"},"x":5670.0,"y":790.0},
#~ {"d":{},"id":29,"kind":"var_get","p":{"name":"heading"},"x":5380.0,"y":790.0},
#~ {"d":{},"id":30,"kind":"var_get","p":{"name":"pilot"},"x":4800.0,"y":790.0},
#~ {"d":{},"id":31,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"velocity"},"x":5090.0,"y":790.0},
#~ {"d":{},"id":32,"kind":"bcall","p":{"method":"angle","type":"Vector2"},"x":5380.0,"y":925.0},
#~ {"d":{},"id":33,"kind":"util","p":{"name":"exp"},"x":5090.0,"y":925.0},
#~ {"d":{},"id":34,"kind":"const","p":{"expr":"delta","in":1.0,"label":"delta","of":11.0,"t":"float"},"x":4510.0,"y":790.0},
#~ {"d":{"a0":"-15.0"},"id":35,"kind":"math","p":{"n":2.0,"op":"*"},"x":4800.0,"y":925.0},
#~ {"d":{"a0":"1.0"},"id":36,"kind":"math","p":{"n":2.0,"op":"-"},"x":5380.0,"y":1060.0},
#~ {"d":{},"id":37,"kind":"var_set","p":{"name":"heading"},"x":5960.0,"y":640.0},
#~ {"d":{},"id":38,"kind":"var_get","p":{"name":"trail"},"x":3630.0,"y":1415.0},
#~ {"d":{"a0":"0"},"id":39,"kind":"bcall","p":{"method":"insert","type":"PackedVector2Array"},"x":3920.0,"y":1265.0},
#~ {"d":{},"id":40,"kind":"var_get","p":{"name":"pilot"},"x":3050.0,"y":1415.0},
#~ {"d":{},"id":41,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"global_position"},"x":3340.0,"y":1415.0},
#~ {"d":{"target":"Vector2(-24, 0)"},"id":42,"kind":"bcall","p":{"method":"rotated","type":"Vector2"},"x":3340.0,"y":1550.0},
#~ {"d":{},"id":43,"kind":"var_get","p":{"name":"heading"},"x":3050.0,"y":1550.0},
#~ {"d":{},"id":44,"kind":"math","p":{"n":2.0,"op":"+"},"x":3630.0,"y":1550.0},
#~ {"d":{},"id":45,"kind":"sequence","p":{"n":2.0},"x":4250.0,"y":1265.0},
#~ {"d":{},"id":46,"kind":"var_get","p":{"name":"trail"},"x":4500.0,"y":1415.0},
#~ {"d":{},"id":47,"kind":"bcall","p":{"method":"size","type":"PackedVector2Array"},"x":4790.0,"y":1415.0},
#~ {"d":{"a1":"13"},"id":48,"kind":"math","p":{"n":2.0,"op":">","unbracketed":true},"x":5080.0,"y":1415.0},
#~ {"d":{},"id":49,"kind":"branch","p":{},"x":5370.0,"y":1265.0},
#~ {"d":{},"id":50,"kind":"var_get","p":{"name":"trail"},"x":5670.0,"y":1415.0},
#~ {"d":{"a0":"13"},"id":51,"kind":"bcall","p":{"method":"resize","type":"PackedVector2Array"},"x":5960.0,"y":1265.0},
#~ {"d":{"step":"-1","to":"-1"},"id":52,"kind":"tpl","p":{"id":"range"},"x":5370.0,"y":1905.0},
#~ {"d":{},"id":53,"kind":"var_get","p":{"name":"bursts"},"x":4500.0,"y":1905.0},
#~ {"d":{},"id":54,"kind":"bcall","p":{"method":"size","type":"Array"},"x":4790.0,"y":1905.0},
#~ {"d":{"a1":"1"},"id":55,"kind":"math","p":{"n":2.0,"op":"-"},"x":5080.0,"y":1905.0},
#~ {"d":{},"id":56,"kind":"for_each","p":{"t":"int","var":"i"},"x":5660.0,"y":1755.0},
#~ {"d":{},"id":57,"kind":"var_get","p":{"name":"bursts"},"x":5980.0,"y":1905.0},
#~ {"d":{},"id":58,"kind":"index","p":{},"x":6270.0,"y":1905.0},
#~ {"d":{},"id":59,"kind":"dyn_get","p":{"name":"age"},"x":6560.0,"y":1905.0},
#~ {"d":{},"id":60,"kind":"const","p":{"expr":"delta","in":1.0,"label":"delta","of":11.0,"t":"float"},"x":6560.0,"y":2040.0},
#~ {"d":{},"id":61,"kind":"math","p":{"n":2.0,"op":"+"},"x":6850.0,"y":1905.0},
#~ {"d":{},"id":62,"kind":"var_get","p":{"name":"bursts"},"x":6560.0,"y":2175.0},
#~ {"d":{},"id":63,"kind":"index","p":{},"x":6850.0,"y":2040.0},
#~ {"d":{},"id":64,"kind":"dyn_set","p":{"name":"age"},"x":7140.0,"y":1755.0},
#~ {"d":{},"id":65,"kind":"var_get","p":{"name":"bursts"},"x":7470.0,"y":1905.0},
#~ {"d":{},"id":66,"kind":"index","p":{},"x":7760.0,"y":1905.0},
#~ {"d":{},"id":67,"kind":"dyn_get","p":{"name":"age"},"x":8050.0,"y":1905.0},
#~ {"d":{"a1":"ECHO_LIFE"},"id":68,"kind":"math","p":{"n":2.0,"op":">=","unbracketed":true},"x":8340.0,"y":1905.0},
#~ {"d":{},"id":69,"kind":"branch","p":{},"x":8630.0,"y":1755.0},
#~ {"d":{},"id":70,"kind":"var_get","p":{"name":"bursts"},"x":8930.0,"y":1905.0},
#~ {"d":{},"id":71,"kind":"bcall","p":{"method":"remove_at","type":"Array"},"x":9220.0,"y":1755.0},
#~ {"d":{},"id":72,"kind":"call","p":{"cls":"Node2D","method":"queue_redraw"},"x":5980.0,"y":2380.0},
#~ {"d":{},"id":73,"kind":"event","p":{"name":"_draw"},"x":80.0,"y":2650.0},
#~ {"d":{},"id":74,"kind":"sequence","p":{"n":2.0},"x":400.0,"y":2650.0},
#~ {"d":{},"id":75,"kind":"util","p":{"name":"is_instance_valid"},"x":940.0,"y":2800.0},
#~ {"d":{},"id":76,"kind":"var_get","p":{"name":"pilot"},"x":650.0,"y":2800.0},
#~ {"d":{},"id":77,"kind":"math","p":{"n":1.0,"op":"not","unbracketed":true},"x":1230.0,"y":2800.0},
#~ {"d":{},"id":78,"kind":"branch","p":{},"x":1520.0,"y":2650.0},
#~ {"d":{},"id":79,"kind":"fn_return","p":{},"x":1820.0,"y":2650.0},
#~ {"d":{},"id":80,"kind":"var_get","p":{"name":"pilot"},"x":650.0,"y":3155.0},
#~ {"d":{},"id":81,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"global_position"},"x":940.0,"y":3155.0},
#~ {"d":{},"id":82,"kind":"local_set","p":{"name":"pos"},"x":1230.0,"y":3005.0},
#~ {"d":{"step":"-1","to":"0"},"id":83,"kind":"tpl","p":{"id":"range"},"x":2430.0,"y":3155.0},
#~ {"d":{},"id":84,"kind":"var_get","p":{"name":"trail"},"x":1560.0,"y":3155.0},
#~ {"d":{},"id":85,"kind":"bcall","p":{"method":"size","type":"PackedVector2Array"},"x":1850.0,"y":3155.0},
#~ {"d":{"a1":"1"},"id":86,"kind":"math","p":{"n":2.0,"op":"-"},"x":2140.0,"y":3155.0},
#~ {"d":{},"id":87,"kind":"for_each","p":{"t":"int","var":"i"},"x":2720.0,"y":3005.0},
#~ {"d":{},"id":88,"kind":"ctor","p":{"i":2.0,"type":"float"},"x":3330.0,"y":3155.0},
#~ {"d":{},"id":89,"kind":"var_get","p":{"name":"trail"},"x":3040.0,"y":3155.0},
#~ {"d":{},"id":90,"kind":"bcall","p":{"method":"size","type":"PackedVector2Array"},"x":3330.0,"y":3290.0},
#~ {"d":{},"id":91,"kind":"math","p":{"n":2.0,"op":"/"},"x":3620.0,"y":3155.0},
#~ {"d":{"a0":"1.0"},"id":92,"kind":"math","p":{"n":2.0,"op":"-"},"x":3910.0,"y":3155.0},
#~ {"d":{},"id":93,"kind":"var_get","p":{"name":"thrust"},"x":3910.0,"y":3290.0},
#~ {"d":{},"id":94,"kind":"math","p":{"n":2.0,"op":"*","unbracketed":true},"x":4200.0,"y":3155.0},
#~ {"d":{},"id":95,"kind":"local_set","p":{"name":"strength"},"x":4490.0,"y":3005.0},
#~ {"d":{},"id":96,"kind":"var_get","p":{"name":"trail"},"x":4820.0,"y":3155.0},
#~ {"d":{},"id":97,"kind":"index","p":{},"x":5110.0,"y":3155.0},
#~ {"d":{},"id":98,"kind":"dyn_call","p":{"inline":true,"method":"distance_squared_to","n":1.0},"x":5400.0,"y":3155.0},
#~ {"d":{},"id":99,"kind":"var_get","p":{"name":"trail"},"x":4820.0,"y":3290.0},
#~ {"d":{"a1":"1"},"id":100,"kind":"math","p":{"n":2.0,"op":"-"},"x":4820.0,"y":3425.0},
#~ {"d":{},"id":101,"kind":"index","p":{},"x":5110.0,"y":3290.0},
#~ {"d":{"a1":"0.01"},"id":102,"kind":"math","p":{"n":2.0,"op":">","unbracketed":true},"x":5690.0,"y":3155.0},
#~ {"d":{},"id":103,"kind":"branch","p":{},"x":5980.0,"y":3005.0},
#~ {"d":{"a4":"true"},"id":104,"kind":"call","p":{"cls":"Node2D","method":"draw_line"},"x":7150.0,"y":3005.0},
#~ {"d":{},"id":105,"kind":"var_get","p":{"name":"trail"},"x":6570.0,"y":3155.0},
#~ {"d":{},"id":106,"kind":"index","p":{},"x":6860.0,"y":3155.0},
#~ {"d":{},"id":107,"kind":"var_get","p":{"name":"trail"},"x":6570.0,"y":3290.0},
#~ {"d":{"a1":"1"},"id":108,"kind":"math","p":{"n":2.0,"op":"-"},"x":6570.0,"y":3425.0},
#~ {"d":{},"id":109,"kind":"index","p":{},"x":6860.0,"y":3290.0},
#~ {"d":{"a0":"PLUME"},"id":110,"kind":"ctor","p":{"i":2.0,"type":"Color"},"x":6860.0,"y":3425.0},
#~ {"d":{},"id":111,"kind":"local_get","p":{"name":"strength"},"x":6280.0,"y":3155.0},
#~ {"d":{"a0":"0.45"},"id":112,"kind":"math","p":{"n":2.0,"op":"*"},"x":6570.0,"y":3560.0},
#~ {"d":{},"id":113,"kind":"local_get","p":{"name":"strength"},"x":6280.0,"y":3290.0},
#~ {"d":{"a0":"5.0"},"id":114,"kind":"math","p":{"n":2.0,"op":"*"},"x":6570.0,"y":3695.0},
#~ {"d":{"a0":"1.0"},"id":115,"kind":"math","p":{"n":2.0,"op":"+"},"x":6860.0,"y":3560.0},
#~ {"d":{},"id":116,"kind":"var_get","p":{"name":"bursts"},"x":3040.0,"y":4050.0},
#~ {"d":{},"id":117,"kind":"for_each","p":{"t":"Dictionary","var":"burst"},"x":3330.0,"y":3900.0},
#~ {"d":{},"id":118,"kind":"dyn_get","p":{"name":"age"},"x":3650.0,"y":4050.0},
#~ {"d":{"a1":"ECHO_LIFE"},"id":119,"kind":"math","p":{"n":2.0,"op":"/","unbracketed":true},"x":3940.0,"y":4050.0},
#~ {"d":{},"id":120,"kind":"local_set","p":{"name":"age"},"x":4230.0,"y":3900.0},
#~ {"d":{"a0":"14.0","a1":"42.0"},"id":121,"kind":"util","p":{"name":"lerpf"},"x":5720.0,"y":4050.0},
#~ {"d":{"a1":"2"},"id":122,"kind":"util","p":{"name":"pow"},"x":5140.0,"y":4050.0},
#~ {"d":{},"id":123,"kind":"local_get","p":{"name":"age"},"x":4560.0,"y":4050.0},
#~ {"d":{"a0":"1.0"},"id":124,"kind":"math","p":{"n":2.0,"op":"-"},"x":4850.0,"y":4050.0},
#~ {"d":{"a0":"1.0"},"id":125,"kind":"math","p":{"n":2.0,"op":"-"},"x":5430.0,"y":4050.0},
#~ {"d":{},"id":126,"kind":"local_set","p":{"name":"r"},"x":6010.0,"y":3900.0},
#~ {"d":{},"id":127,"kind":"dyn_get","p":{"name":"at"},"x":6340.0,"y":4050.0},
#~ {"d":{},"id":128,"kind":"local_set","p":{"name":"at"},"x":6630.0,"y":3900.0},
#~ {"d":{"first":"0","last":"7"},"id":129,"kind":"for","p":{"var":"j"},"x":6960.0,"y":3900.0},
#~ {"d":{},"id":130,"kind":"bcall","p":{"method":"from_angle","type":"Vector2"},"x":8150.0,"y":4050.0},
#~ {"d":{"a1":"TAU"},"id":131,"kind":"math","p":{"n":2.0,"op":"*"},"x":7280.0,"y":4050.0},
#~ {"d":{"a1":"8.0"},"id":132,"kind":"math","p":{"n":2.0,"op":"/"},"x":7570.0,"y":4050.0},
#~ {"d":{"a1":"0.25"},"id":133,"kind":"math","p":{"n":2.0,"op":"+"},"x":7860.0,"y":4050.0},
#~ {"d":{},"id":134,"kind":"local_set","p":{"name":"axis"},"x":8440.0,"y":3900.0},
#~ {"d":{"a3":"2.0","a4":"true"},"id":135,"kind":"call","p":{"cls":"Node2D","method":"draw_line"},"x":10510.0,"y":3900.0},
#~ {"d":{},"id":136,"kind":"local_get","p":{"name":"at"},"x":9930.0,"y":4050.0},
#~ {"d":{},"id":137,"kind":"local_get","p":{"name":"axis"},"x":9640.0,"y":4050.0},
#~ {"d":{},"id":138,"kind":"local_get","p":{"name":"r"},"x":9640.0,"y":4185.0},
#~ {"d":{},"id":139,"kind":"math","p":{"n":2.0,"op":"*"},"x":9930.0,"y":4185.0},
#~ {"d":{},"id":140,"kind":"math","p":{"n":2.0,"op":"+"},"x":10220.0,"y":4050.0},
#~ {"d":{},"id":141,"kind":"local_get","p":{"name":"at"},"x":9930.0,"y":4320.0},
#~ {"d":{},"id":142,"kind":"local_get","p":{"name":"axis"},"x":9640.0,"y":4320.0},
#~ {"d":{},"id":143,"kind":"local_get","p":{"name":"r"},"x":9350.0,"y":4050.0},
#~ {"d":{},"id":144,"kind":"local_get","p":{"name":"age"},"x":8770.0,"y":4050.0},
#~ {"d":{"a0":"1.0"},"id":145,"kind":"math","p":{"n":2.0,"op":"-"},"x":9060.0,"y":4050.0},
#~ {"d":{"a0":"7"},"id":146,"kind":"math","p":{"n":2.0,"op":"*"},"x":9350.0,"y":4185.0},
#~ {"d":{},"id":147,"kind":"math","p":{"n":2.0,"op":"+"},"x":9640.0,"y":4455.0},
#~ {"d":{},"id":148,"kind":"math","p":{"n":2.0,"op":"*"},"x":9930.0,"y":4455.0},
#~ {"d":{},"id":149,"kind":"math","p":{"n":2.0,"op":"+"},"x":10220.0,"y":4185.0},
#~ {"d":{"a0":"1.0","a1":"0.80","a2":"0.44"},"id":150,"kind":"ctor","p":{"i":4.0,"type":"Color"},"x":10220.0,"y":4320.0},
#~ {"d":{},"id":151,"kind":"local_get","p":{"name":"age"},"x":9640.0,"y":4590.0},
#~ {"d":{"a0":"1.0"},"id":152,"kind":"math","p":{"n":2.0,"op":"-"},"x":9930.0,"y":4590.0},
#~ {"d":{"a2":"SHIP_SCALE"},"id":153,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":4230.0,"y":4795.0},
#~ {"d":{},"id":154,"kind":"local_get","p":{"name":"pos"},"x":3650.0,"y":4945.0},
#~ {"d":{"a1":"Vector2(4, 6)"},"id":155,"kind":"math","p":{"n":2.0,"op":"+"},"x":3940.0,"y":4945.0},
#~ {"d":{},"id":156,"kind":"var_get","p":{"name":"heading"},"x":3940.0,"y":5080.0},
#~ {"d":{"a0":"HULL","a2":"Color(0.01, 0.03, 0.05, 0.52)"},"id":157,"kind":"call","p":{"cls":"Node2D","method":"draw_texture"},"x":5430.0,"y":4795.0},
#~ {"d":{"target":"HULL"},"id":158,"kind":"dyn_call","p":{"inline":true,"method":"get_size","n":0.0},"x":4560.0,"y":4945.0},
#~ {"d":{},"id":159,"kind":"op","p":{"l":"any","op":"unary-","r":"","ret":"any"},"x":4850.0,"y":4945.0},
#~ {"d":{"a1":"0.5"},"id":160,"kind":"math","p":{"n":2.0,"op":"*"},"x":5140.0,"y":4945.0},
#~ {"d":{},"id":161,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":6050.0,"y":4795.0},
#~ {"d":{},"id":162,"kind":"local_get","p":{"name":"pos"},"x":5760.0,"y":4945.0},
#~ {"d":{},"id":163,"kind":"var_get","p":{"name":"heading"},"x":5760.0,"y":5080.0},
#~ {"d":{"array":"[-1, 1]"},"id":164,"kind":"for_each","p":{"t":"any","var":"side"},"x":6380.0,"y":4795.0},
#~ {"d":{"a0":"-27"},"id":165,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":6990.0,"y":4945.0},
#~ {"d":{"a1":"9"},"id":166,"kind":"math","p":{"n":2.0,"op":"*"},"x":6700.0,"y":4945.0},
#~ {"d":{},"id":167,"kind":"local_set","p":{"name":"jet"},"x":7280.0,"y":4795.0},
#~ {"d":{},"id":168,"kind":"var_get","p":{"name":"thrust"},"x":9060.0,"y":4945.0},
#~ {"d":{},"id":169,"kind":"util","p":{"name":"sin"},"x":8480.0,"y":4945.0},
#~ {"d":{},"id":170,"kind":"var_get","p":{"name":"elapsed"},"x":7610.0,"y":4945.0},
#~ {"d":{"a1":"45.0"},"id":171,"kind":"math","p":{"n":2.0,"op":"*"},"x":7900.0,"y":4945.0},
#~ {"d":{},"id":172,"kind":"math","p":{"n":2.0,"op":"+"},"x":8190.0,"y":4945.0},
#~ {"d":{"a0":"3.0"},"id":173,"kind":"math","p":{"n":2.0,"op":"*"},"x":8770.0,"y":4945.0},
#~ {"d":{"a0":"12.0"},"id":174,"kind":"math","p":{"n":2.0,"op":"+"},"x":9060.0,"y":5080.0},
#~ {"d":{},"id":175,"kind":"math","p":{"n":2.0,"op":"*"},"x":9350.0,"y":4945.0},
#~ {"d":{"a0":"4.0"},"id":176,"kind":"math","p":{"n":2.0,"op":"+","unbracketed":true},"x":9640.0,"y":4945.0},
#~ {"d":{},"id":177,"kind":"local_set","p":{"name":"span"},"x":9930.0,"y":4795.0},
#~ {"d":{"a1":"Color(0.25, 0.91, 0.89, 0.8)"},"id":178,"kind":"call","p":{"cls":"Node2D","method":"draw_colored_polygon"},"x":12000.0,"y":4795.0},
#~ {"d":{},"id":179,"kind":"ctor","p":{"i":2.0,"type":"PackedVector2Array"},"x":11710.0,"y":4945.0},
#~ {"d":{},"id":180,"kind":"make_array","p":{"n":3.0},"x":11420.0,"y":4945.0},
#~ {"d":{},"id":181,"kind":"local_get","p":{"name":"jet"},"x":10840.0,"y":4945.0},
#~ {"d":{"a1":"Vector2(2, -2.6)"},"id":182,"kind":"math","p":{"n":2.0,"op":"+"},"x":11130.0,"y":4945.0},
#~ {"d":{},"id":183,"kind":"local_get","p":{"name":"jet"},"x":10840.0,"y":5080.0},
#~ {"d":{"a1":"0"},"id":184,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":10840.0,"y":5215.0},
#~ {"d":{},"id":185,"kind":"local_get","p":{"name":"span"},"x":10260.0,"y":4945.0},
#~ {"d":{},"id":186,"kind":"op","p":{"l":"float","op":"unary-","r":"","ret":"float"},"x":10550.0,"y":4945.0},
#~ {"d":{},"id":187,"kind":"math","p":{"n":2.0,"op":"+"},"x":11130.0,"y":5080.0},
#~ {"d":{},"id":188,"kind":"local_get","p":{"name":"jet"},"x":10840.0,"y":5350.0},
#~ {"d":{"a1":"Vector2(2, 2.6)"},"id":189,"kind":"math","p":{"n":2.0,"op":"+"},"x":11130.0,"y":5215.0},
#~ {"d":{"a2":"Color(\"#d1fff6\")","a3":"2.0","a4":"true"},"id":190,"kind":"call","p":{"cls":"Node2D","method":"draw_line"},"x":13780.0,"y":4795.0},
#~ {"d":{},"id":191,"kind":"local_get","p":{"name":"jet"},"x":13490.0,"y":4945.0},
#~ {"d":{},"id":192,"kind":"local_get","p":{"name":"jet"},"x":13200.0,"y":4945.0},
#~ {"d":{"a1":"0"},"id":193,"kind":"ctor","p":{"i":3.0,"type":"Vector2"},"x":13200.0,"y":5080.0},
#~ {"d":{},"id":194,"kind":"local_get","p":{"name":"span"},"x":12330.0,"y":4945.0},
#~ {"d":{},"id":195,"kind":"op","p":{"l":"float","op":"unary-","r":"","ret":"float"},"x":12620.0,"y":4945.0},
#~ {"d":{"a1":"0.66"},"id":196,"kind":"math","p":{"n":2.0,"op":"*"},"x":12910.0,"y":4945.0},
#~ {"d":{},"id":197,"kind":"math","p":{"n":2.0,"op":"+"},"x":13490.0,"y":5080.0},
#~ {"d":{"a2":"SHIP_SCALE"},"id":198,"kind":"call","p":{"cls":"Node2D","method":"draw_set_transform"},"x":6990.0,"y":5555.0},
#~ {"d":{},"id":199,"kind":"local_get","p":{"name":"pos"},"x":6700.0,"y":5705.0},
#~ {"d":{},"id":200,"kind":"var_get","p":{"name":"heading"},"x":6700.0,"y":5840.0},
#~ {"d":{"a0":"HULL"},"id":201,"kind":"call","p":{"cls":"Node2D","method":"draw_texture"},"x":8190.0,"y":5555.0},
#~ {"d":{"target":"HULL"},"id":202,"kind":"dyn_call","p":{"inline":true,"method":"get_size","n":0.0},"x":7320.0,"y":5705.0},
#~ {"d":{},"id":203,"kind":"op","p":{"l":"any","op":"unary-","r":"","ret":"any"},"x":7610.0,"y":5705.0},
#~ {"d":{"a1":"0.5"},"id":204,"kind":"math","p":{"n":2.0,"op":"*"},"x":7900.0,"y":5705.0},
#~ {"d":{},"id":205,"kind":"reroute","p":{"t":"exec"},"x":3035.0,"y":1336.0},
#~ {"d":{},"id":206,"kind":"reroute","p":{"t":"exec"},"x":4485.0,"y":1796.0},
#~ {"d":{},"id":207,"kind":"reroute","p":{"t":"exec"},"x":635.0,"y":3046.0},
#~ {"d":{},"id":208,"kind":"reroute","p":{"t":"exec"},"x":2955.0,"y":3941.0},
#~ {"d":{},"id":209,"kind":"reroute","p":{"t":"exec"},"x":3565.0,"y":4866.0},
#~ {"d":{},"id":210,"kind":"reroute","p":{"t":"exec"},"x":6615.0,"y":5626.0}
#~ ],"wires":[
#~ [1,"then",2,"exec"],[3,"ret",4,"target"],[2,"then",4,"exec"],[4,"then",5,"exec"],[4,"ret",5,"value"],[5,"then",7,"exec"],[6,"value",7,"cond"],[8,"value",9,"target"],
#~ [10,"fn",9,"a1"],[7,"true",9,"exec"],[11,"then",12,"exec"],[11,"p_delta",12,"value"],[16,"value",17,"target"],[17,"value",18,"target"],[18,"ret",19,"a0"],[19,"ret",15,"a0"],
#~ [11,"p_delta",20,"a1"],[14,"value",13,"a0"],[15,"ret",13,"a1"],[20,"ret",13,"a2"],[12,"then",21,"exec"],[13,"ret",21,"value"],[21,"then",22,"exec"],[23,"value",24,"target"],
#~ [24,"value",25,"target"],[25,"ret",26,"a0"],[22,"then_0",27,"exec"],[26,"ret",27,"cond"],[30,"value",31,"target"],[31,"value",32,"target"],[34,"value",35,"a1"],[35,"ret",33,"a0"],
#~ [33,"ret",36,"a1"],[29,"value",28,"a0"],[32,"ret",28,"a1"],[36,"ret",28,"a2"],[27,"true",37,"exec"],[28,"ret",37,"value"],[38,"value",39,"target"],[40,"value",41,"target"],
#~ [43,"value",42,"a0"],[41,"value",44,"a0"],[42,"ret",44,"a1"],[44,"ret",39,"a1"],[22,"then_1",205,"i"],[39,"then",45,"exec"],[46,"value",47,"target"],[47,"ret",48,"a0"],
#~ [45,"then_0",49,"exec"],[48,"ret",49,"cond"],[50,"value",51,"target"],[49,"true",51,"exec"],[53,"value",54,"target"],[54,"ret",55,"a0"],[55,"ret",52,"from"],[45,"then_1",206,"i"],
#~ [52,"ret",56,"array"],[57,"value",58,"c"],[56,"element",58,"k"],[58,"ret",59,"target"],[59,"value",61,"a0"],[60,"value",61,"a1"],[62,"value",63,"c"],[56,"element",63,"k"],
#~ [56,"body",64,"exec"],[63,"ret",64,"target"],[61,"ret",64,"value"],[65,"value",66,"c"],[56,"element",66,"k"],[66,"ret",67,"target"],[67,"value",68,"a0"],[64,"then",69,"exec"],
#~ [68,"ret",69,"cond"],[70,"value",71,"target"],[56,"element",71,"a0"],[69,"true",71,"exec"],[56,"completed",72,"exec"],[73,"then",74,"exec"],[76,"value",75,"a0"],[75,"ret",77,"a0"],
#~ [74,"then_0",78,"exec"],[77,"ret",78,"cond"],[78,"true",79,"exec"],[80,"value",81,"target"],[74,"then_1",207,"i"],[81,"value",82,"value"],[84,"value",85,"target"],[85,"ret",86,"a0"],
#~ [86,"ret",83,"from"],[82,"then",87,"exec"],[83,"ret",87,"array"],[87,"element",88,"a0"],[89,"value",90,"target"],[88,"ret",91,"a0"],[90,"ret",91,"a1"],[91,"ret",92,"a1"],
#~ [92,"ret",94,"a0"],[93,"value",94,"a1"],[87,"body",95,"exec"],[94,"ret",95,"value"],[96,"value",97,"c"],[87,"element",97,"k"],[97,"ret",98,"target"],[87,"element",100,"a0"],
#~ [99,"value",101,"c"],[100,"ret",101,"k"],[101,"ret",98,"v0"],[98,"ret",102,"a0"],[95,"then",103,"exec"],[102,"ret",103,"cond"],[105,"value",106,"c"],[87,"element",106,"k"],
#~ [87,"element",108,"a0"],[107,"value",109,"c"],[108,"ret",109,"k"],[111,"value",112,"a1"],[112,"ret",110,"a1"],[113,"value",114,"a1"],[114,"ret",115,"a1"],[106,"ret",104,"a0"],
#~ [109,"ret",104,"a1"],[110,"ret",104,"a2"],[115,"ret",104,"a3"],[103,"true",104,"exec"],[87,"completed",208,"i"],[116,"value",117,"array"],[117,"element",118,"target"],[118,"value",119,"a0"],
#~ [117,"body",120,"exec"],[119,"ret",120,"value"],[123,"value",124,"a1"],[124,"ret",122,"a0"],[122,"ret",125,"a1"],[125,"ret",121,"a2"],[120,"then",126,"exec"],[121,"ret",126,"value"],
#~ [117,"element",127,"target"],[126,"then",128,"exec"],[127,"value",128,"value"],[128,"then",129,"exec"],[129,"index",131,"a0"],[131,"ret",132,"a0"],[132,"ret",133,"a0"],[133,"ret",130,"a0"],
#~ [129,"body",134,"exec"],[130,"ret",134,"value"],[137,"value",139,"a0"],[138,"value",139,"a1"],[136,"value",140,"a0"],[139,"ret",140,"a1"],[144,"value",145,"a1"],[145,"ret",146,"a1"],
#~ [143,"value",147,"a0"],[146,"ret",147,"a1"],[142,"value",148,"a0"],[147,"ret",148,"a1"],[141,"value",149,"a0"],[148,"ret",149,"a1"],[151,"value",152,"a1"],[152,"ret",150,"a3"],
#~ [140,"ret",135,"a0"],[149,"ret",135,"a1"],[150,"ret",135,"a2"],[134,"then",135,"exec"],[154,"value",155,"a0"],[155,"ret",153,"a0"],[156,"value",153,"a1"],[117,"completed",209,"i"],
#~ [158,"ret",159,"a"],[159,"ret",160,"a0"],[160,"ret",157,"a1"],[153,"then",157,"exec"],[162,"value",161,"a0"],[163,"value",161,"a1"],[157,"then",161,"exec"],[161,"then",164,"exec"],
#~ [164,"element",166,"a0"],[166,"ret",165,"a1"],[164,"body",167,"exec"],[165,"ret",167,"value"],[170,"value",171,"a0"],[171,"ret",172,"a0"],[164,"element",172,"a1"],[172,"ret",169,"a0"],
#~ [169,"ret",173,"a1"],[173,"ret",174,"a1"],[168,"value",175,"a0"],[174,"ret",175,"a1"],[175,"ret",176,"a1"],[167,"then",177,"exec"],[176,"ret",177,"value"],[181,"value",182,"a0"],
#~ [185,"value",186,"a"],[186,"ret",184,"a0"],[183,"value",187,"a0"],[184,"ret",187,"a1"],[188,"value",189,"a0"],[182,"ret",180,"e0"],[187,"ret",180,"e1"],[189,"ret",180,"e2"],
#~ [180,"ret",179,"a0"],[179,"ret",178,"a0"],[177,"then",178,"exec"],[194,"value",195,"a"],[195,"ret",196,"a0"],[196,"ret",193,"a0"],[192,"value",197,"a0"],[193,"ret",197,"a1"],
#~ [191,"value",190,"a0"],[197,"ret",190,"a1"],[178,"then",190,"exec"],[199,"value",198,"a0"],[200,"value",198,"a1"],[164,"completed",210,"i"],[202,"ret",203,"a"],[203,"ret",204,"a0"],
#~ [204,"ret",201,"a1"],[198,"then",201,"exec"],[205,"o",39,"exec"],[206,"o",56,"exec"],[207,"o",82,"exec"],[208,"o",117,"exec"],[209,"o",153,"exec"],[210,"o",198,"exec"]
#~ ]},
#~ {"id":2,"inputs":[["_score","int"]],"kind":"function","locals":[],"name":"_on_pickup","next_id":8,"outputs":[],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"fn_entry","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":3,"kind":"var_get","p":{"name":"bursts"},"x":980.0,"y":270.0},
#~ {"d":{},"id":4,"kind":"bcall","p":{"method":"append","type":"Array"},"x":1270.0,"y":120.0},
#~ {"d":{"k0":"\"at\"","k1":"\"age\"","v1":"0.0"},"id":5,"kind":"make_dict","p":{"n":2.0},"x":980.0,"y":405.0},
#~ {"d":{},"id":6,"kind":"var_get","p":{"name":"pilot"},"x":400.0,"y":270.0},
#~ {"d":{},"id":7,"kind":"get_prop","p":{"cls":"CharacterBody2D","prop":"global_position"},"x":690.0,"y":270.0}
#~ ],"wires":[
#~ [3,"value",4,"target"],[6,"value",7,"target"],[7,"value",5,"v0"],[5,"ret",4,"a0"],[1,"then",4,"exec"]
#~ ]}
#~ ]}
#endregion
