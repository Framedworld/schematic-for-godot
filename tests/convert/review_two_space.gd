extends Node
## A script indented with two spaces: its inner class and property setters are kept as written.

var log_: Array = []
var hp = 10:
  set(value):
    if value > 5:
      hp = 5
    else:
      hp = value
  get:
    return hp

var level := 1:
  set(v):
    level = clampi(v, 0, 3)
    log_.append("level %d" % level)


class Inner:
  var n = 1

  func f(k):
    if k > 1:
      return n + k
    return n

  class Deeper:
    var m = 2

    func g():
      for i in 2:
        m += i
      return m


func _ready() -> void:
  hp = 3
  log_.append(hp)
  hp = 20
  log_.append(hp)
  level = 9
  level = 2
  var inner := Inner.new()
  log_.append([inner.f(1), inner.f(4)])
  var deeper := Inner.Deeper.new()
  log_.append(deeper.g())
  for i in 3:
    if i == 1:
      continue
    log_.append(i)
