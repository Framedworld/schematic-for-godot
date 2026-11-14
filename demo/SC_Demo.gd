# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_Demo
extends Node3D
## Demo schematic: spins and bounces its node. Press Space (jump) to change speed.

signal speed_changed(new_speed: float)

@export_group("Motion")
## Degrees per second.
@export var spin_speed: float = 90.0
## How high the node bounces.
@export var bounce_height: float = 0.5
var time: float = 0.0

var __tl_pulse_1_27_time: float = 0.0
var __tl_pulse_1_27_dir: float = 1.0
var __tl_pulse_1_27_playing: bool = false
var __tl_pulse_1_27_Scale: float = 1.0
var __delay_1_5: bool = false
var __flip_flop_1_19: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"jump"):
		__ia_jump_pressed()


func __tl_pulse_1_27_sample() -> void:
	__tl_pulse_1_27_Scale = __sc_sample([[0.0, 1.0], [1.0, 1.35], [2.0, 1.0]], __tl_pulse_1_27_time, true)


func __tl_pulse_1_27_update() -> void:
	scale = (Vector3.ONE * __tl_pulse_1_27_Scale)


func __tl_pulse_1_27_finished() -> void:
	pass


func __tl_pulse_1_27_run() -> void:
	if __tl_pulse_1_27_playing:
		return
	__tl_pulse_1_27_playing = true
	while __tl_pulse_1_27_playing:
		await get_tree().process_frame
		if not __tl_pulse_1_27_playing:
			break
		var prev: float = __tl_pulse_1_27_time
		__tl_pulse_1_27_time += get_process_delta_time() * __tl_pulse_1_27_dir
		var raw: float = __tl_pulse_1_27_time
		var tl_done := false
		if __tl_pulse_1_27_dir > 0.0 and __tl_pulse_1_27_time >= 2.0:
			__tl_pulse_1_27_time = fmod(__tl_pulse_1_27_time, 2.0)
		elif __tl_pulse_1_27_dir < 0.0 and __tl_pulse_1_27_time <= 0.0:
			__tl_pulse_1_27_time = 2.0 + fmod(__tl_pulse_1_27_time, 2.0)
		__tl_pulse_1_27_sample()
		__tl_pulse_1_27_update()
		if tl_done:
			__tl_pulse_1_27_playing = false
			__tl_pulse_1_27_finished()


func _ready() -> void:
	__tl_pulse_1_27_run()
	print("Hello from a Schematic!")
	(func() -> void:
		if __delay_1_5:
			return
		__delay_1_5 = true
		await get_tree().create_timer(1.0).timeout
		__delay_1_5 = false
		print("...one second later")
	).call()
	print("Sequence does not wait for the Delay")


func _process(delta: float) -> void:
	rotate_y((deg_to_rad(spin_speed) * delta))
	time = (time + delta)
	position = Vector3(0.0, wave(time), 0.0)


func __ia_jump_pressed() -> void:
	__flip_flop_1_19 = not __flip_flop_1_19
	if __flip_flop_1_19:
		spin_speed = (spin_speed * 4.0)
		speed_changed.emit(spin_speed)
		print("speed toggled")
		print("speed toggled")
	else:
		spin_speed = (spin_speed / 4.0)
		speed_changed.emit(spin_speed)
		print("speed toggled")
		print("speed toggled")


func wave(t: float) -> float:
	return (absf(sin((t * 3.0))) * bounce_height)


func __sc_sample(keys: Array, t: float, smooth: bool) -> Variant:
	if keys.is_empty():
		return 0.0
	if t <= keys[0][0]:
		return keys[0][1]
	for i in range(1, keys.size()):
		if t <= keys[i][0]:
			var w: float = (t - keys[i - 1][0]) / maxf(keys[i][0] - keys[i - 1][0], 0.00001)
			return lerp(keys[i - 1][1], keys[i][1], smoothstep(0.0, 1.0, w) if smooth else w)
	return keys[-1][1]


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {"class_name":"SC_Demo","description":"Demo schematic: spins and bounces its node. Press Space (jump) to change speed.","dispatchers":[{"name":"speed_changed","params":[["new_speed","float"]]}],"enums":[],"parent":"Node3D","tool":false,"trace":false,"variables":[{"category":"Motion","default":"90.0","export":true,"name":"spin_speed","tooltip":"Degrees per second.","type":"float"},{"category":"Motion","default":"0.5","export":true,"name":"bounce_height","tooltip":"How high the node bounces.","type":"float"},{"category":"","default":"","export":false,"name":"time","tooltip":"","type":"float"}],"version":1.0,"graphs":[
#~ {"id":1,"inputs":[],"kind":"event","locals":[],"name":"EventGraph","next_id":32,"outputs":[],"pure":false,"sx":0.0,"sy":-146.024047851562,"zoom":0.963931024074554,"nodes":[
#~ {"d":{},"id":1,"kind":"event","p":{"name":"_ready"},"x":60.0,"y":60.0},
#~ {"d":{},"id":2,"kind":"event","p":{"name":"_process"},"x":60.0,"y":330.0},
#~ {"d":{"text":"\"Hello from a Schematic!\""},"id":3,"kind":"print","p":{},"x":300.0,"y":60.0},
#~ {"d":{},"id":4,"kind":"sequence","p":{"n":2.0},"x":600.0,"y":60.0},
#~ {"d":{"duration":"1.0"},"id":5,"kind":"delay","p":{},"x":820.0,"y":30.0},
#~ {"d":{"text":"\"...one second later\""},"id":6,"kind":"print","p":{},"x":1080.0,"y":30.0},
#~ {"d":{"text":"\"Sequence does not wait for the Delay\""},"id":7,"kind":"print","p":{},"x":820.0,"y":170.0},
#~ {"d":{},"id":8,"kind":"var_get","p":{"name":"spin_speed"},"x":60.0,"y":500.0},
#~ {"d":{},"id":9,"kind":"util","p":{"name":"deg_to_rad"},"x":230.0,"y":480.0},
#~ {"d":{},"id":10,"kind":"op","p":{"l":"float","op":"*","r":"float","ret":"float"},"x":470.0,"y":470.0},
#~ {"d":{},"id":11,"kind":"call","p":{"cls":"Node3D","method":"rotate_y"},"x":620.0,"y":330.0},
#~ {"d":{},"id":12,"kind":"var_get","p":{"name":"time"},"x":640.0,"y":520.0},
#~ {"d":{},"id":13,"kind":"op","p":{"l":"float","op":"+","r":"float","ret":"float"},"x":790.0,"y":500.0},
#~ {"d":{},"id":14,"kind":"var_set","p":{"name":"time"},"x":940.0,"y":330.0},
#~ {"d":{},"id":15,"kind":"call_self","p":{"fn":"wave"},"x":1120.0,"y":500.0},
#~ {"d":{},"id":16,"kind":"ctor","p":{"i":3.0,"type":"Vector3"},"x":1340.0,"y":470.0},
#~ {"d":{},"id":17,"kind":"set_prop","p":{"cls":"Node3D","prop":"position"},"x":1580.0,"y":330.0},
#~ {"d":{},"id":18,"kind":"input_action","p":{"action":"jump"},"x":60.0,"y":720.0},
#~ {"d":{},"id":19,"kind":"flip_flop","p":{},"x":330.0,"y":720.0},
#~ {"d":{},"id":20,"kind":"var_get","p":{"name":"spin_speed"},"x":330.0,"y":900.0},
#~ {"d":{"b":"4.0"},"id":21,"kind":"op","p":{"l":"float","op":"*","r":"float","ret":"float"},"x":520.0,"y":860.0},
#~ {"d":{"b":"4.0"},"id":22,"kind":"op","p":{"l":"float","op":"/","r":"float","ret":"float"},"x":520.0,"y":960.0},
#~ {"d":{},"id":23,"kind":"var_set","p":{"name":"spin_speed"},"x":700.0,"y":700.0},
#~ {"d":{},"id":24,"kind":"var_set","p":{"name":"spin_speed"},"x":700.0,"y":830.0},
#~ {"d":{},"id":25,"kind":"emit","p":{"name":"speed_changed"},"x":1000.0,"y":740.0},
#~ {"d":{},"id":26,"kind":"comment","p":{"h":400.0,"text":"Press Space: toggle fast / slow spin","w":1250.0},"x":30.0,"y":660.0},
#~ {"d":{},"id":27,"kind":"timeline","p":{"autoplay":true,"length":2.0,"loop":true,"name":"Pulse","tracks":[{"keys":[[0.0,"1.0"],[1.0,"1.35"],[2.0,"1.0"]],"name":"Scale","smooth":true,"type":"float"}]},"x":60.0,"y":1130.0},
#~ {"d":{},"id":28,"kind":"const","p":{"expr":"Vector3.ONE","label":"Vector3.ONE","t":"Vector3"},"x":330.0,"y":1330.0},
#~ {"d":{},"id":29,"kind":"op","p":{"l":"Vector3","op":"*","r":"float","ret":"Vector3"},"x":520.0,"y":1300.0},
#~ {"d":{},"id":30,"kind":"set_prop","p":{"cls":"Node3D","prop":"scale"},"x":700.0,"y":1130.0},
#~ {"d":{"i_text":"\"speed toggled\""},"id":31,"kind":"macro","p":{"name":"LogTwice"},"x":1010.0,"y":900.0}
#~ ],"wires":[
#~ [1,"then",3,"exec"],[3,"then",4,"exec"],[4,"then_0",5,"exec"],[5,"then",6,"exec"],[4,"then_1",7,"exec"],[8,"value",9,"a0"],[9,"ret",10,"a"],[2,"p_delta",10,"b"],
#~ [2,"then",11,"exec"],[10,"ret",11,"a0"],[12,"value",13,"a"],[2,"p_delta",13,"b"],[13,"ret",14,"value"],[11,"then",14,"exec"],[14,"out",15,"a_t"],[15,"r_height",16,"a1"],
#~ [16,"ret",17,"value"],[14,"then",17,"exec"],[18,"pressed",19,"exec"],[19,"a",23,"exec"],[19,"b",24,"exec"],[20,"value",21,"a"],[20,"value",22,"a"],[21,"ret",23,"value"],
#~ [22,"ret",24,"value"],[23,"then",25,"exec"],[24,"then",25,"exec"],[23,"out",25,"a_new_speed"],[27,"update",30,"exec"],[28,"value",29,"a"],[27,"t_Scale",29,"b"],[29,"ret",30,"value"],
#~ [25,"then",31,"i_In"]
#~ ]},
#~ {"id":2,"inputs":[["In","exec"],["text","String"]],"kind":"macro","locals":[],"name":"LogTwice","next_id":5,"outputs":[["Out","exec"]],"pure":false,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"macro_in","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":2,"kind":"macro_out","p":{},"x":900.0,"y":120.0},
#~ {"d":{},"id":3,"kind":"print","p":{},"x":320.0,"y":120.0},
#~ {"d":{},"id":4,"kind":"print","p":{},"x":600.0,"y":120.0}
#~ ],"wires":[
#~ [1,"i_In",3,"exec"],[3,"then",4,"exec"],[4,"then",2,"o_Out"],[1,"i_text",3,"text"],[1,"i_text",4,"text"]
#~ ]},
#~ {"id":3,"inputs":[["t","float"]],"kind":"function","locals":[],"name":"wave","next_id":8,"outputs":[["height","float"]],"pure":true,"sx":0.0,"sy":0.0,"zoom":1.0,"nodes":[
#~ {"d":{},"id":1,"kind":"fn_entry","p":{},"x":80.0,"y":120.0},
#~ {"d":{},"id":2,"kind":"fn_return","p":{},"x":1000.0,"y":120.0},
#~ {"d":{"b":"3.0"},"id":3,"kind":"op","p":{"l":"float","op":"*","r":"float","ret":"float"},"x":300.0,"y":260.0},
#~ {"d":{},"id":4,"kind":"util","p":{"name":"sin"},"x":440.0,"y":250.0},
#~ {"d":{},"id":5,"kind":"util","p":{"name":"absf"},"x":640.0,"y":250.0},
#~ {"d":{},"id":6,"kind":"var_get","p":{"name":"bounce_height"},"x":640.0,"y":360.0},
#~ {"d":{},"id":7,"kind":"op","p":{"l":"float","op":"*","r":"float","ret":"float"},"x":850.0,"y":270.0}
#~ ],"wires":[
#~ [1,"p_t",3,"a"],[3,"ret",4,"a0"],[4,"ret",5,"a0"],[5,"ret",7,"a"],[6,"value",7,"b"],[7,"ret",2,"r_height"],[1,"then",2,"exec"]
#~ ]}
#~ ]}
#endregion
