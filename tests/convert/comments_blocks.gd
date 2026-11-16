extends Node
## Commented-out code: blocks of comments indented to different depths at the end of a function, and a whole
## commented-out function between two functions. Every line must come back, in the order written.

var out: Array = []
var mode := 1


func _ready() -> void:
	tidy([1, 2])
	check()
	out.append("ready")


func tidy(items: Array) -> void:
	for it in items:
		out.append(it)

	if mode == 1:
		out.append("one")

	#for node in items:
		#print("Node: %s" % [node])
		#print("  deps: %s" % [node])
	#if not out.is_empty():
		#if mode:
			#out.clear()
		#elif out.size() > 3:
			#out.pop_back()


func check() -> void:
	if mode > 0:
		out.append("checked")
	# a block indented by more than one step, with comments at its depth
	for index in out.size():
			# iterate only over the first ones
			var item = out[index]
			if not item:
				continue
			# count it
			mode += 0
	# commented-out code deeper than the match and its arms, above the first arm
	match mode:
						# the first case
				1:
					out.append("match one")
				_:
					out.append("match other")
	# after the match
	out.append("after match")


## TODO - later
#func find_highest() -> void:
	#var highest: Node
	#for item in out:
		#if not item: continue # skips empty ones
		#if item > 2:
			#highest = item
#
		#mode = 0
#
	#if is_instance_valid(highest):
		#out.append(highest)
	#else:
		#mode = 2


func _process(_delta: float) -> void:
	if mode == 5: return
	out.append("tick")
