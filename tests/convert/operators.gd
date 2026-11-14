extends Node
## Every operator, and the order they run in.

var out: Array = []
var calls: Array = []
var counter := 0


func note(tag: String, value: Variant) -> Variant:
	calls.append(tag)
	return value


func _ready() -> void:
	# arithmetic keeps ints as ints and floats as floats
	out.append([7 / 2, 7.0 / 2, 7 / 2.0, -7 / 2, 7 % 3, -7 % 3, fmod(-7.0, 3.0), 2 ** 10, 2 ** -1, 2.0 ** 0.5, 5 - -3, -(-5), - 2 ** 2])
	out.append([1 + 2 * 3, (1 + 2) * 3, 10 - 4 - 3, 2 * 3 % 4, 100 / 10 / 5, 1 + 2 << 3, 1 << 2 + 3, 6 & 3 | 8, 6 ^ 3, ~5, 1 << 4 >> 2])
	out.append([2 ** 3 ** 2, (2 ** 3) ** 2, 2 ** (3 ** 2), -2 ** 2, (-2) ** 2, 2 ** 2 * 3, 2 * 3 ** 2, 10 - 2 - 3 - 1, 64 / 4 / 2 / 2, 7 - 2 * 3 + 1,
		1 - (2 - 3), 8 / (4 / 2), 2 - -2, 2 - - -2, not true == false, not (true == false), 1 < 2 == true, 5 & 3 == 1, 1 + 1 if true else 5 + 5])
	# the order GDScript itself reads these in: a sign next to a digit belongs to the number, `**` and the
	# rest take what is on their left first, `as` comes last of all
	var x := 3
	var v := Vector2(2, 3)
	var any_five: Variant = 5
	out.append([-2 ** 2, - 2 ** 2, -x ** 2, - x ** 2, 1 -2 ** 2, 1 - 2 ** 2, -2.0 ** 2, -v.x ** 2, -(2) ** 2, +2 ** 2, 7 -3, 7 - -3, 7 - +3])
	out.append([2 ** -1 ** 2, -2 ** -2, ~2 ** 2, -x * 3, -x ** 2 * 3, 2 --2, 2 - --2, 2 - - -2, - - 2, -2 % 3, - 2 % 3, -7 / 2, - 7 / 2])
	out.append([!true == false, not true == false, not 1 in [1], not x > 2 and false, 1 | 2 ^ 3 & 4, 1 << 1 + 1, 3 - 1 << 1, true or false and false,
		not false and false, 1 if false else 2 if false else 3, 5 - 3 if true else 9])
	out.append([2 * 3 as float, -3 as float, x / 2 as float, x / (2 as float), any_five is int == true, not any_five is String, 1 + x if any_five is int else 0,
		[1, 2][1] ** 2, (x as float) / 2, -(x as float), "a" + "b" as String])
	out.append([1 < 2, 2 <= 2, 3 > 4, 4 >= 4, 1 == 1.0, 1 != 2, "a" < "b", [1, 2] == [1, 2], {"a": 1} == {"a": 1}, null == null])
	# and / or stop as soon as the answer is known, and so do && / ||
	out.append(note("a", false) and note("b", true))
	out.append(note("c", true) or note("d", false))
	out.append(note("e", true) and note("f", false) or note("g", true))
	out.append(note("h", false) && note("i", true) || note("j", false))
	out.append(not note("k", true))
	out.append(!note("l", false))
	out.append(note("m", 1) if note("n", false) else note("o", 2))
	out.append(note("p", 1) if note("q", true) else note("r", 2))
	out.append("x" if counter > 0 else "y" if counter == 0 else "z")
	# membership and type tests
	var list := [1, "two", 3.0, null]
	var book := {"key": 1, 2: "two"}
	out.append([1 in list, "two" in list, 4 in list, 4 not in list, "key" in book, 2 in book, "ke" in "key", "z" not in "key"])
	var me: Variant = self
	var five: Variant = 5
	out.append([me is Node, me is Node3D, me is not Node3D, five is int, five is float, five is not String, list is Array, me is Object])
	var as_node := me as Node
	var as_3d := me as Node3D
	out.append([as_node == self, as_3d == null, 3.9 as int, 3 as float, five as float])
	# compound assignment
	var n := 10
	n += 5
	n -= 3
	n *= 4
	n /= 5
	n %= 7
	n **= 3
	n <<= 2
	n >>= 1
	n |= 5
	n &= 14
	n ^= 3
	var f := 1.5
	f += 1
	f *= 2
	f /= 4
	f -= 0.25
	var s := "a"
	s += "b"
	s += str(1)
	var arr := [1]
	arr += [2, 3]
	out.append([n, f, s, arr])
	counter += 1
	counter -= -2
	out.append(counter)
	# strings, arrays and vectors under the same signs
	out.append(["ab" + "cd", "ab".repeat(3), [1] + [2], Vector2(1, 2) + Vector2(3, 4), Vector2(1, 2) * 2, 2 * Vector2(1, 2), Vector3.ONE * Vector3(1, 2, 3),
		-Vector2(1, -2), Vector2(4, 6) / 2, Color(1, 1, 1) * 0.5, "%s-%s" % [1, 2], "%d" % 7])
	# an expression that reads and changes the same thing
	var i := 0
	var seq := [i, i + 1, i * 2]
	i = i + 1 if i == 0 else i - 1
	seq.append(i)
	out.append(seq)
	out.append(calls)
