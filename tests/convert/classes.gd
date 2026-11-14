@tool
@icon("res://addons/schematic/icons/schematic.svg")
extends "res://tests/convert/_base.gd"
## Everything a script can declare.

signal changed(what: String, to: Variant)
signal emptied
signal typed_one(state: State, holder: Holder)
@warning_ignore("unused_signal")
signal never_emitted

enum State { IDLE, WALK = 5, RUN, JUMP = WALK * 2 }
enum { LOOSE_A, LOOSE_B = 10, LOOSE_C }
enum Flags { NONE = 0, A = 1 << 0, B = 1 << 1, BOTH = A | B }

const LIMIT := 4
const NAMES: Array[String] = ["zero", "one"]
const LOOKUP := {State.IDLE: "idle", State.RUN: "run"}
const DOUBLE_LIMIT := LIMIT * 2 + BASE_LIMIT
const Other := preload("res://tests/convert/_base.gd")

@export var plain_export: int = 3
@export var untyped_export = 2.5
@export var inferred_export := "text"
@export_range(0, 10, 0.5) var ranged: float = 1.5
@export_enum("Low", "Mid", "High") var level: int = 1
@export_flags("Fire", "Water", "Earth") var elements: int = 5
@export_multiline var story: String = "once\nupon"
@export var state_export: State = State.WALK
@export var packed: PackedScene
@export var colour := Color(1, 0.5, 0)
@export_group("Movement")
@export var walk_speed := 2.0
@export var run_speed: float = 6.0
@export_subgroup("Air")
@export var jump_height := 1.5
@export_category("Other")
@export var after_category := true

var out: Array = []
var events: Array = []
var state: State = State.IDLE
var holder: Holder
var holders: Array[Holder] = []
var by_state: Dictionary[State, String] = {}
var watched: int = 0:
	set(value):
		events.append("watched %d -> %d" % [watched, value])
		watched = clampi(value, 0, LIMIT)
	get:
		return watched
var doubled: int:
	get:
		return watched * 2
var routed: String = "start": set = _set_routed, get = _get_routed
var _routed_store := "store"
static var shared_count := 0
static var shared_names: Array = []
@onready var ready_value := base_value * 2
@onready var ready_name: String = String(name).left(1)


class Holder:
	const KIND := "holder"
	var label: String
	var amount := 0
	var inner: Deep

	func _init(p_label: String = "none", p_amount: int = 1) -> void:
		label = p_label
		amount = p_amount
		inner = Deep.new()

	func grow(by: int) -> Holder:
		amount += by
		return self

	func _to_string() -> String:
		return "%s x%d" % [label, amount]

	static func twin(of: Holder) -> Holder:
		return Holder.new(of.label + "'", of.amount)

	class Deep:
		var depth := 2
		func describe() -> String:
			return "deep %d" % depth


class Counter extends RefCounted:
	var count := 0
	signal bumped(to: int)
	func bump() -> void:
		count += 1
		bumped.emit(count)


func _ready() -> void:
	super()
	out.append([State.IDLE, State.WALK, State.RUN, State.JUMP, LOOSE_A, LOOSE_B, LOOSE_C, Flags.BOTH, State.keys(), State.values(), State.find_key(6)])
	out.append([LIMIT, NAMES, LOOKUP[State.RUN], DOUBLE_LIMIT, BASE_LIMIT, Other.BASE_LIMIT, Other.make_label("x"), make_label("y"), Holder.KIND])
	out.append([plain_export, untyped_export, inferred_export, ranged, level, elements, story, state_export, packed, colour, walk_speed, run_speed, jump_height, after_category])
	out.append([ready_value, ready_name, base_value, describe(), helper(4), super.describe()])
	# properties with set and get
	watched = 3
	watched += 9
	watched -= 1
	routed = "new"
	out.append([watched, doubled, routed, _routed_store])
	# inner classes
	holder = Holder.new("box", 2)
	holder.grow(3).grow(1)
	var twin := Holder.twin(holder)
	twin.inner.depth += 5
	holders.append(holder)
	holders.append(twin)
	holders.append(Holder.new())
	out.append([str(holder), str(twin), holder.inner.describe(), twin.inner.describe(), holders.size(), str(holders[2]), holder is Holder, holder is RefCounted])
	var counter := Counter.new()
	counter.bumped.connect(func(to): events.append("bumped %d" % to))
	counter.bump()
	counter.bump()
	out.append(counter.count)
	# static state is the class's, not the object's
	shared_count += 1
	shared_names.append(name)
	out.append([shared_count > 0, shared_names.size() > 0, total_shared() > 0])
	# signals
	changed.connect(_on_changed)
	changed.connect(func(what, to): events.append("lambda %s" % what), CONNECT_ONE_SHOT)
	emptied.connect(_on_emptied.bind("bound"))
	base_signal.connect(func(value): events.append("base %s" % value))
	changed.emit("state", State.RUN)
	changed.emit("again", 2)
	emptied.emit()
	base_signal.emit(7)
	typed_one.emit(state, holder)
	out.append([changed.is_connected(_on_changed), changed.get_connections().size(), emptied.get_name(), has_signal("typed_one"), has_user_signal("x")])
	changed.disconnect(_on_changed)
	changed.emit("unheard", 0)
	# a variable and a result typed with one of the script's enums
	for i in 4:
		var picked: State
		var flagged: Flags
		if i % 2 == 1:
			picked = state_for(i)
			flagged = Flags.BOTH
		out.append([picked, flagged, state_for(i), other_limit(i)])
	state = State.JUMP
	by_state[state] = "jumping"
	out.append([state, by_state, hook("child"), base_log, events])


func describe() -> String:
	return "child:" + super()


func state_for(n: int) -> State:
	match n:
		0:
			return State.IDLE
		1:
			return State.WALK
		_:
			return State.RUN


func other_limit(n: int) -> Node.ProcessMode:
	if n > 2:
		return Node.PROCESS_MODE_ALWAYS
	else:
		return Node.PROCESS_MODE_PAUSABLE


func hook(tag: String) -> String:
	var from_base := super.hook(tag)
	return from_base + "+child"


func _set_routed(value: String) -> void:
	_routed_store = value.to_upper()


func _get_routed() -> String:
	return _routed_store + "!"


func _on_changed(what: String, to: Variant) -> void:
	events.append("changed %s to %s" % [what, to])


func _on_emptied(extra: String) -> void:
	events.append("emptied " + extra)


static func total_shared() -> int:
	return shared_count + shared_names.size()
