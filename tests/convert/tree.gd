extends Node2D
## Nodes: making them, finding them, and the engine calling back.

const SPEED := 60.0

var out: Array = []
var log_lines: Array = []
var elapsed := 0.0
var physics_steps := 0
var seen_inputs := 0
var timer: Timer
var body: Node2D
@onready var late := get_node_or_null("Made") as Node2D


func _enter_tree() -> void:
	log_lines.append("enter tree")
	var made := Node2D.new()
	made.name = "Made"
	add_child(made)
	var inner := Sprite2D.new()
	inner.name = "Inner"
	made.add_child(inner)
	inner.unique_name_in_owner = true
	inner.owner = self


func _ready() -> void:
	log_lines.append("ready")
	body = $Made
	body.position = Vector2(10, 20)
	$Made/Inner.modulate = Color(1, 0, 0)
	$"Made/Inner".position.x = 3
	get_node("Made").rotation = 0.5
	get_node(^"Made/Inner").scale = Vector2(2, 2)
	%Inner.visible = false
	out.append([late == body, body.name, has_node("Made/Inner"), has_node("Nope"), get_node_or_null("Nope") == null, $Made.get_child_count(),
		%Inner.position, $Made/Inner.modulate, body.rotation, get_child(0) == body, body.get_index(), is_inside_tree(), is_node_ready()])
	# groups
	add_to_group("things")
	body.add_to_group(&"things")
	body.add_to_group("movers")
	out.append([is_in_group("things"), body.is_in_group("movers"), get_tree().get_nodes_in_group("movers").has(body), body.get_groups().size()])
	# more nodes, some of them gone again
	for i in 3:
		var marker := Marker2D.new()
		marker.name = "Marker%d" % i
		marker.position = Vector2(i * 10, 0)
		add_child(marker)
		if i == 1:
			marker.queue_free()
	var moved := get_node("Marker2")
	remove_child(moved)
	body.add_child(moved)
	move_child(get_node("Marker0"), 0)
	timer = Timer.new()
	timer.name = "Clock"
	timer.wait_time = 0.01
	timer.one_shot = true
	timer.timeout.connect(_on_timeout)
	timer.timeout.connect(func(): log_lines.append("timer lambda"))
	add_child(timer)
	timer.start()
	child_entered_tree.connect(_on_child_entered)
	var late_child := Node.new()
	late_child.name = "Late"
	add_child(late_child)
	tree_exiting.connect(func(): log_lines.append("exiting"))
	set_process_input(true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_input(click)
	_unhandled_input(click)
	out.append([get_children().map(func(c): return c.name), body.get_children().map(func(c): return c.name), moved.get_parent() == body,
		get_path_to(moved), body.get_path_to(self), find_child("Inner", true, false) != null, get_parent() != null])


func _process(delta: float) -> void:
	elapsed += delta
	body.position.x += SPEED * delta
	body.position = body.position.move_toward(Vector2.ZERO, delta)
	rotation += delta * 0.5
	if Engine.get_process_frames() % 2 == 0:
		body.scale = body.scale.lerp(Vector2(2, 2), 0.5)


func _physics_process(delta: float) -> void:
	physics_steps += 1
	if physics_steps == 2:
		log_lines.append("second physics step %s" % (delta > 0.0))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		seen_inputs += 1
		log_lines.append("click %d" % event.button_index)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		seen_inputs += button.button_index * 10


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_READY:
			log_lines.append("notified ready")
		NOTIFICATION_PARENTED:
			log_lines.append("notified parented")
		NOTIFICATION_PROCESS, NOTIFICATION_PHYSICS_PROCESS, NOTIFICATION_INTERNAL_PROCESS:
			pass


func _exit_tree() -> void:
	log_lines.append("exit tree")


func _on_timeout() -> void:
	log_lines.append("timeout")
	timer.queue_free()


func _on_child_entered(child: Node) -> void:
	log_lines.append("child entered %s" % child.name)
