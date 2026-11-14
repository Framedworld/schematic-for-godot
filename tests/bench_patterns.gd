extends SceneTree
## Times the code shapes the Schematic compiler emits against the hand-written shape they stand for.
## Run: godot --headless --path . --script res://tests/bench_patterns.gd
const N := 400000

var member_local := 0.0
var holder: Node3D

func t(label: String, a: Callable, b: Callable) -> void:
	var best_a := 1e18
	var best_b := 1e18
	for round in 3:
		var s := Time.get_ticks_usec()
		a.call()
		best_a = minf(best_a, Time.get_ticks_usec() - s)
		s = Time.get_ticks_usec()
		b.call()
		best_b = minf(best_b, Time.get_ticks_usec() - s)
	print("BENCH %-46s hand %7.1f ms   generated %7.1f ms   x%.2f" % [label, best_a / 1000.0, best_b / 1000.0, best_b / best_a])

# 1. loop header
func loop_hand() -> void:
	var acc := 0
	var w := 7
	for y in range(N):
		acc += y * w
func loop_gen() -> void:
	var acc: int = 0
	var w: int = 0
	w = 7
	for i_9 in range(0, (N - 1) + 1):
		acc = (acc + (i_9 * w))

# 2. inferred local type lost
func typed_hand() -> void:
	var acc := Vector3.ZERO
	for i in range(N):
		var pull := (Vector3.ONE * 0.5) if i % 2 == 0 else Vector3.ZERO
		acc += pull
func typed_gen() -> void:
	var acc: Vector3 = Vector3()
	var pull = null
	acc = Vector3.ZERO
	for i_3 in range(0, (N - 1) + 1):
		pull = ((Vector3.ONE * 0.5) if ((i_3 % 2) == 0) else Vector3.ZERO)
		acc = (acc + pull)

# 3. negation
func neg_hand() -> void:
	var v := Vector3(1, 2, 3)
	var acc := Vector3.ZERO
	for i in range(N):
		acc += -v
func neg_gen() -> void:
	var v: Vector3 = Vector3(1, 2, 3)
	var acc: Vector3 = Vector3.ZERO
	for i in range(N):
		acc = (acc + (v * -1))

# 4. locals declared at the top of a function that is called often
func decl_hand_one(x: int) -> int:
	if x < 0:
		return 0
	var a := Vector2i(x, x)
	var d: Dictionary = {}
	var s := "k"
	return a.x
func decl_gen_one(x: int) -> int:
	var a: Vector2i = Vector2i()
	var d: Dictionary = {}
	var s: String = ""
	var v3: Vector3 = Vector3()
	var arr: Array = []
	var b: bool = false
	if (x < 0):
		return 0
	a = Vector2i(x, x)
	d = {}
	s = "k"
	return a.x
func decl_hand() -> void:
	var acc := 0
	for i in range(N):
		acc += decl_hand_one(i)
func decl_gen() -> void:
	var acc := 0
	for i in range(N):
		acc += decl_gen_one(i)

# 5. object truthiness
func truth_hand() -> void:
	var acc := 0
	for i in range(N):
		if holder:
			acc += 1
func truth_gen() -> void:
	var acc := 0
	for i in range(N):
		if is_instance_valid(holder):
			acc += 1

# 6. loop over a packed array
func packed_hand() -> void:
	var p := PackedInt32Array()
	p.resize(64)
	var acc := 0
	for i in range(N / 64):
		for v in p:
			acc += v
func packed_gen() -> void:
	var p := PackedInt32Array()
	p.resize(64)
	var acc := 0
	for i in range(N / 64):
		for item_3: int in Array(p):
			acc += item_3

# 7. set one member of a struct property
func member_hand() -> void:
	for i in range(N):
		holder.position.y += 0.001
func member_gen() -> void:
	for i in range(N):
		holder.position = Vector3(holder.position.x, (holder.position.y + 0.001), holder.position.z)

# 8. an event's local kept on the object
func evlocal_hand() -> void:
	for i in range(N):
		var d := float(i) * 0.5
		member_local = d
var d_process := 0.0
func evlocal_gen() -> void:
	for i in range(N):
		d_process = (float(i) * 0.5)
		member_local = d_process

# 9. the result of a call kept in a temporary first
func temp_hand() -> void:
	var acc := 0
	for i in range(N):
		acc += absi(i)
func temp_gen() -> void:
	var acc: int = 0
	for i in range(N):
		var absi_4: int = absi(i)
		acc = (acc + absi_4)

# 10. elif chain
func elif_hand() -> void:
	var acc := 0
	for i in range(N):
		var m := i % 4
		if m == 0:
			acc += 1
		elif m == 1:
			acc += 2
		elif m == 2:
			acc += 3
		else:
			acc += 4
func elif_gen() -> void:
	var acc: int = 0
	var m: int = 0
	for i in range(N):
		m = (i % 4)
		if (m == 0):
			acc = (acc + 1)
		else:
			if (m == 1):
				acc = (acc + 2)
			else:
				if (m == 2):
					acc = (acc + 3)
				else:
					acc = (acc + 4)

func _init() -> void:
	holder = Node3D.new()
	t("loop header range(0, (n-1)+1)", loop_hand, loop_gen)
	t("local typed by := now untyped", typed_hand, typed_gen)
	t("-v written as v * -1", neg_hand, neg_gen)
	t("locals declared at the top (6 per call)", decl_hand, decl_gen)
	t("if obj: as is_instance_valid(obj)", truth_hand, truth_gen)
	t("for over packed array through Array()", packed_hand, packed_gen)
	t("position.y += as whole-vector rebuild", member_hand, member_gen)
	t("event local stored on the object", evlocal_hand, evlocal_gen)
	t("call result held in a temporary", temp_hand, temp_gen)
	t("elif chain as nested else", elif_hand, elif_gen)
	holder.free()
	quit()
