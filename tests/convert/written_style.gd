extends Node
## Code that should come back the way it was written: an `elif` as an `elif`, the comment at the end of an
## `elif` / `else:` line at the end of that line, and no brackets added where the meaning is the same without.

var out: Array = []
var speed := 10
var name_tag := "Breach"
var needs_key := true


func _ready() -> void:
	for n in [-3, 0, 4, 12, 200]:
		out.append(band(n))
		out.append(tails(n))
	out.append(brackets(3, 4))
	out.append(words("a", 2))


func band(n: int) -> String:
	if n < 0:
		return "negative"
	elif n == 0:
		return "zero"
	elif n < 10:
		if n % 2 == 0:
			return "small even"
		return "small odd"
	elif n < 100:
		return "medium"
	return "large"


func tails(n: int) -> String:
	var said := ""
	if n < 0:  # below nothing
		said = "under"
	elif n == 0:  # [PIECE] the middle
		said = "nil"
	# above an elif, on a line of its own
	elif n < 10:
		said = "few"
	else:  # everything else
		said = "many"
	return said


func brackets(a: int, b: int) -> Array:
	var got: Array = []
	got.append(a * 2 + b)
	got.append(a - b - 1)
	got.append(a - (b - 1))
	got.append((a + b) * 2)
	got.append(-a * b)
	got.append(a + b * 2 > 10 and needs_key)
	got.append(name_tag == "Breach" and needs_key and a < b and bool(got.size()))
	got.append(not a == b)
	got.append(not (needs_key and a > b))
	got.append(maxi(a + b, a * b))
	got.append([a + 1, b - 1][a - 3])
	got.append("%d of %d" % [a + b, a * b])
	got.append(a > 1 == true)
	got.append(a + b if needs_key else a - b)
	got.append((a + b) as float)
	got.append(str(a + b) + name_tag)
	return got


func words(tag: String, count: int) -> String:
	var text := tag + "-" + str(count * 2)
	if tag == "a" and count > 1 or tag == "b":
		text += "!"
	return text.to_upper() + tag.repeat(2)
