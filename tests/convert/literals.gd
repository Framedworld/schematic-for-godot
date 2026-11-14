extends Node
## Every way of writing a value.

const BIG := 1_000_000
const HEX := 0xFF_A0
const BIN := 0b1010_0101
const TINY := 1.5e-3
const HALF := .5
const WHOLE := 3.
const NAMES := ["a", 'b', "c\"d", 'e\'f']
const TABLE := {"one": 1, 2: "two", Vector2(1, 2): [1, 2, 3], &"name": ^"Some/Path"}
const LUA := {speed = 4.5, label = "fast", nested = {depth = 2, tags = ["x", "y"]}}

var out: Array = []
var text_plain := "tab\there \\ backslash \"quoted\" 'single' newline\\n end"
var text_single := 'it\'s "fine" \\ here'
var text_unicode := "café 中文 \U01F600"
var text_raw := r"raw\d+\n [^\"]"
var text_raw_single := r'raw \s "x"'
var text_long := """first line
	second line, tabbed # not a comment
  third line with "quotes" and \\ a backslash

last line"""
var string_name := &"with spaces and \\ slash"
var node_path := ^"Parent/Child:property"
var empty_things := ["", '', [], {}, null, &"", ^""]


func _ready() -> void:
	out.append([BIG, HEX, BIN, TINY, HALF, WHOLE, NAMES, TABLE, LUA])
	out.append([1, -1, +1, 0, 0.0, -0.0, 1e3, 1E3, 2.5E-2, 0x10, 0b11, 9_223_372_036_854_775_807])
	out.append([true, false, null, PI, TAU, INF, -INF, is_nan(NAN)])
	out.append([text_plain, text_single, text_unicode, text_raw, text_raw_single, text_long, string_name, node_path, empty_things])
	out.append([
		1,
		[2, 3,],   # a trailing comma
		{
			"k": "v",   # a comment inside a literal
			"list": [
				4,
				5,
			],
		},
	])
	var typed_ints: Array[int] = [1, 2, 3]
	var typed_strings: Array[String] = ["a", "b"]
	var typed_dict: Dictionary[String, int] = {"a": 1, "b": 2}
	var packed := PackedInt32Array([1, 2, 3])
	var packed_text := PackedStringArray(["x", "y"])
	out.append([typed_ints, typed_strings, typed_dict, packed, packed_text, typed_ints.is_typed(), typed_dict.is_typed()])
	out.append([Vector2(1, 2), Vector3.UP, Vector2i(3, 4), Color(1, 0.5, 0, 0.25), Color.RED, Color("#ff8800"), Rect2(0, 0, 4, 5),
		Transform3D.IDENTITY, Basis.IDENTITY, Quaternion.IDENTITY, AABB(Vector3.ZERO, Vector3.ONE), Plane(Vector3.UP, 2.0)])
	out.append("%d items, %s, %.2f, %5.1f%%, %-4s|, %04d, %x, %c" % [3, "text", 1.23456, 45.678, "ab", 42, 255, 65])
	out.append("{0} and {name} and {1}".format(["zero", "one"]).format({"name": "named"}))
	out.append("a" + "b" + str(1) + str(2.5) + str(true) + str(null) + str([1, "x"]) + str({"k": Vector2.ONE}))
