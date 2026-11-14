extends Node
## Plays the platformer starter kit with a fixed script of inputs and prints what happens, so the original
## and the Blueprint port can be compared line for line. It is added to each copy as an autoload:
##   godot --headless --fixed-fps 60 --path <project>

const PLAN := [
	[30, "press", "move_forward"], [70, "tap", "jump"], [95, "tap", "jump"], [150, "release", "move_forward"],
	[160, "press", "move_right"], [160, "press", "camera_right"], [200, "tap", "jump"], [240, "release", "move_right"],
	[240, "release", "camera_right"], [250, "press", "move_back"], [250, "press", "zoom_in"], [290, "tap", "jump"],
	[330, "release", "move_back"], [330, "release", "zoom_in"], [340, "press", "move_left"], [340, "press", "camera_up"],
	[380, "tap", "jump"], [400, "tap", "jump"], [460, "release", "move_left"], [460, "release", "camera_up"],
	[470, "press", "move_forward"], [470, "press", "move_right"], [520, "tap", "jump"], [640, "release", "move_forward"],
	[640, "release", "move_right"],
]

var frame := 0
var releases := {}


func r(v: Variant) -> String:
	if v is Vector3:
		return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]
	if v is float:
		return "%.3f" % v
	return str(v)


func _physics_process(_delta: float) -> void:
	for step in PLAN:
		if int(step[0]) == frame:
			if step[1] == "release":
				Input.action_release(step[2])
			else:
				Input.action_press(step[2])
				if step[1] == "tap":
					releases[frame + 2] = step[2]
	if releases.has(frame):
		Input.action_release(releases[frame])
	var s := get_tree().current_scene
	if frame % 10 == 0 and s != null:
		var player := s.get_node_or_null("Player")
		var view := s.get_node_or_null("View")
		var hud := s.get_node_or_null("HUD/Coins")
		var coins_left := 0
		var platforms := 0
		var clouds := ""
		for n in s.find_children("*", "", true, false):
			if n.get("grabbed") == false:
				coins_left += 1
			if n.get("falling") != null:
				platforms += 1
			if n.get("random_velocity") != null and clouds == "":
				clouds = r(float(n.get("time")))
		print("TRACE %d pos %s vel %s rot %s coins %s hud '%s' view %s cam %s zoom %s coins_left %d platforms %d cloud_time %s anim %s" % [frame,
			r(player.position) if player else "-", r(player.velocity) if player else "-", r(player.rotation.y) if player else "-",
			str(player.get("coins")) if player else "-", hud.text if hud else "-",
			r(view.rotation_degrees) if view else "-", r(view.get_node("Camera").position) if view else "-", r(float(view.get("zoom"))) if view else "-",
			coins_left, platforms, clouds, str(player.get_node("Character/AnimationPlayer").current_animation) if player else "-"])
	frame += 1
	if frame >= 720:
		get_tree().quit()
