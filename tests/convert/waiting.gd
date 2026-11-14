extends Node
## await: the order things happen in around it.

signal step_done
signal answered(value, extra)

var out: Array = []
var order: Array = []
var frames := 0
var ticks := 0


func _ready() -> void:
	order.append("ready starts")
	begin()
	order.append("ready goes on while begin waits")
	var quick := await no_wait(3)
	order.append("no_wait gave %d" % quick)
	var slow: int = await counted(2)
	order.append("counted gave %d" % slow)
	await get_tree().process_frame
	order.append("a frame later")
	for i in 2:
		await get_tree().process_frame
		order.append("loop frame %d" % i)
	var n := 0
	while n < 2:
		n += await counted(1)
	order.append("while gave %d" % n)
	# a signal that hands back values
	answer_later.call_deferred()
	var reply = await answered
	order.append("answered %s" % str(reply))
	step_later.call_deferred()
	await step_done
	order.append("step done")
	# awaiting inside a condition and an argument
	if await counted(1) == 1:
		order.append("condition waited")
	order.append("argument %d" % (await counted(1) + await no_wait(5)))
	await chain(3)
	var results := []
	for delay in [2, 1]:
		results.append(await counted(delay))
	order.append(results)
	out.append(order)
	out.append([frames > 5, ticks])


func _process(_delta: float) -> void:
	frames += 1


func begin() -> void:
	order.append("begin starts")
	await get_tree().process_frame
	order.append("begin after a frame")
	ticks += 1


func no_wait(n: int) -> int:
	return n * 2


func counted(wait_frames: int) -> int:
	for i in wait_frames:
		await get_tree().process_frame
	ticks += 1
	return wait_frames


func chain(depth: int) -> void:
	if depth == 0:
		order.append("chain bottom")
		return
	await get_tree().process_frame
	await chain(depth - 1)
	order.append("chain %d" % depth)


func answer_later() -> void:
	answered.emit(42, "x")


func step_later() -> void:
	step_done.emit()
