@tool
extends RefCounted
## The object a kit's `register(kit)` receives (see docs/KITS.md). It is the whole surface a kit can touch, so it
## stays small and stable: `template(id, t)` adds a node, `full_id(id)` says how that node is stored in graphs,
## and `addon` / `kit_name` say which kit this is. Everything a kit hands over is checked here; a template with a
## problem is skipped with a message that names the addon, the node and the problem, and the rest of the kit
## still loads.

const T := preload("res://addons/schematic/core/sc_types.gd")

## Between the addon's folder name and the kit's own id in a stored template id: "health:heal".
const SEP := ":"

## Every key a template may have. Anything else is reported (usually a typo).
const KEYS := ["title", "cat", "tip", "search", "ins", "outs", "lines", "exprs", "helper", "pure", "latent", "node", "always", "for"]
const BOOL_KEYS := ["pure", "latent", "node", "always"]
const TEXT_KEYS := ["cat", "tip", "search"]
## Pin ids a template cannot use: Schematic gives every non-pure node "exec" and "then", and {id} is the node's number.
const RESERVED_PINS := ["exec", "then", "id"]

## The addon's folder name (the namespace of its ids).
var addon := ""
## KIT_NAME, or the folder name.
var kit_name := ""
## The kit script's path.
var path := ""

var _templates: Dictionary = {}   # own id -> checked template, in the order they came
var _problems: Array = []         # [{template, problem}]
var _placeholder := RegEx.create_from_string("\\{([A-Za-z_][A-Za-z0-9_]*)\\}")
var _own_id := RegEx.create_from_string("^[A-Za-z0-9_]+$")


func _init(p_addon := "", p_name := "", p_path := "") -> void:
	addon = p_addon
	kit_name = p_name if p_name != "" else p_addon
	path = p_path


## Adds a node. `id` is the kit's own name for it (letters, digits and _); graphs store it as "<addon>:<id>".
func template(id: String, t: Dictionary) -> void:
	if not _own_id.search(id):
		_problem(id, "the id must be letters, digits and _ only (the addon's folder name is added in front of it by Schematic)")
		return
	if _templates.has(id):
		_problem(id, "a node with this id was already added by this kit")
		return
	var checked := check(t, id)
	if checked.is_empty():
		return
	_templates[id] = checked


## How a node of this kit is stored in graphs (and what Schematic's own code calls it): "<addon>:<id>".
func full_id(id: String) -> String:
	return addon + SEP + id


# ---------------------------------------------------------------- checking

## A checked copy of `t` ({} after reporting its problems). `label` names it in messages. Also used for the
## project-specific nodes a kit's actions() offers.
func check(t: Dictionary, label: String) -> Dictionary:
	var before := _problems.size()
	for key in t:
		if not String(key) in KEYS:
			_problem(label, "unknown key '%s' (a template may have: %s)" % [key, ", ".join(KEYS)])
	if not (t.get("title") is String) or String(t.get("title", "")).strip_edges() == "":
		_problem(label, "it has no title (\"title\": the text on the node)")
	for key in TEXT_KEYS:
		if t.has(key) and not (t[key] is String):
			_problem(label, "'%s' must be text" % key)
	for key in BOOL_KEYS:
		if t.has(key) and not (t[key] is bool):
			_problem(label, "'%s' must be true or false" % key)
	if _problems.size() > before:
		return {}
	var pure := bool(t.get("pure", false))
	var latent := bool(t.get("latent", false))
	var ins := _pins(t.get("ins", []), true, label)
	var outs := _pins(t.get("outs", []), false, label)
	if _problems.size() > before:
		return {}
	var in_ids := ins.map(func(x): return String(x[0]))
	var out_ids := outs.map(func(x): return String(x[0]))
	for oid in out_ids:
		if in_ids.has(oid):
			_problem(label, "'%s' is both an input and an output pin; give them different ids" % oid)
	var lines: Array = []
	if t.has("lines"):
		if not (t.lines is Array) or not t.lines.all(func(x): return x is String):
			_problem(label, "'lines' must be a list of text lines")
		else:
			lines = t.lines.duplicate()
	var exprs: Dictionary = {}
	if t.has("exprs"):
		if not (t.exprs is Dictionary) or not t.exprs.values().all(func(x): return x is String):
			_problem(label, "'exprs' must map output pin ids to text")
		else:
			exprs = t.exprs.duplicate()
	if _problems.size() > before:
		return {}
	if pure and latent:
		_problem(label, "a node cannot be both pure and latent")
	if pure and not lines.is_empty():
		_problem(label, "a pure node has no 'lines' (it is only an expression); put its value in 'exprs'")
	if pure and outs.is_empty():
		_problem(label, "a pure node needs at least one output pin")
	if not pure and lines.is_empty() and exprs.is_empty():
		_problem(label, "it compiles to nothing: give it 'lines' (statements) or 'exprs' (values)")
	if latent and not lines.any(func(l): return String(l).contains("await")):
		_problem(label, "a latent node must wait: one of its lines needs an await")
	for i in lines.size():
		_check_text(String(lines[i]), "line %d" % (i + 1), in_ids, label)
	for key in exprs:
		if not out_ids.has(String(key)):
			_problem(label, "'exprs' has '%s', but the node has no output pin with that id (outputs: %s)" % [key, _list(out_ids)])
		else:
			_check_text(String(exprs[key]), "the expression of '%s'" % key, in_ids, label)
	for oid in out_ids:
		if not exprs.has(oid):
			_problem(label, "output pin '%s' has no expression in 'exprs' (it would always be null)" % oid)
	var for_classes: Array = []
	if t.has("for"):
		if not (t["for"] is Array) or t["for"].is_empty() or not t["for"].all(func(x): return x is String and x != ""):
			_problem(label, "'for' must be a list of class names, such as [\"Node3D\"]")
		else:
			for_classes = t["for"].duplicate()
	var helper: Array = []
	if t.has("helper"):
		helper = _helper(t.helper, label)
	if _problems.size() > before:
		return {}
	var out := {"title": String(t.title), "cat": String(t.get("cat", kit_name)), "ins": ins, "outs": outs}
	for key in ["tip", "search"]:
		if t.has(key):
			out[key] = String(t[key])
	for key in BOOL_KEYS:
		if bool(t.get(key, false)):
			out[key] = true
	if not lines.is_empty():
		out["lines"] = lines
	if not exprs.is_empty():
		out["exprs"] = exprs
	if not helper.is_empty():
		out["helper"] = helper
	if not for_classes.is_empty():
		out["for"] = for_classes
	return out


## Pins in Schematic's form: inputs [id, label, type, default], outputs [id, label, type].
func _pins(list: Variant, is_in: bool, label: String) -> Array:
	var side := "ins" if is_in else "outs"
	if not (list is Array):
		_problem(label, "'%s' must be a list of pins" % side)
		return []
	var out := []
	var seen := {}
	for i in list.size():
		var pin: Variant = list[i]
		var where := "%s pin %d" % ["input" if is_in else "output", i + 1]
		if not (pin is Array) or pin.size() < 3 or pin.size() > (4 if is_in else 3) or not pin.all(func(x): return x is String):
			_problem(label, "%s must be [id, label, type%s] (all text)" % [where, ", default" if is_in else ""])
			continue
		var pid := String(pin[0])
		if pid == "":
			_problem(label, "%s has no id" % where)
			continue
		if not pid.is_valid_identifier():
			_problem(label, "%s: the id '%s' must be a name (letters, digits and _, not starting with a digit)" % [where, pid])
			continue
		if pid in RESERVED_PINS:
			_problem(label, "%s: the id '%s' is used by Schematic itself; pick another" % [where, pid])
			continue
		if seen.has(pid):
			_problem(label, "%s: there are two %s pins with the id '%s'" % [where, "input" if is_in else "output", pid])
			continue
		seen[pid] = true
		var type := String(pin[2])
		var why := type_problem(type)
		if why != "":
			_problem(label, "pin '%s': %s" % [pid, why])
			continue
		var row := [pid, String(pin[1]) if String(pin[1]) != "" else pid.capitalize(), type]
		if is_in:
			row.append(String(pin[3]) if pin.size() > 3 else "")
		out.append(row)
	return out


## "" when a pin can have this type, else why not.
static func type_problem(type: String) -> String:
	if type == "":
		return "it has no type (use \"any\" for a pin that takes anything)"
	if type == "exec":
		return "\"exec\" pins are added by Schematic (every node that is not pure has one in and one out)"
	if type in ["Variant", "var"]:
		return "unknown type '%s' (use \"any\" for a pin that takes anything)" % type
	if type == "any" or T.BUILTIN.has(type):
		return ""
	if type.begins_with("Array[") and type.ends_with("]"):
		var inner := type.substr(6, type.length() - 7)
		var why := type_problem(inner)
		return "" if why == "" and inner != "any" else "unknown element type in '%s'" % type
	if T.class_known(type):
		return ""
	return "unknown type '%s' (a pin type is \"any\", a built-in type such as int or Vector3, Array[...] of one, or a class: an engine class or a script's class_name)" % type


func _check_text(text: String, where: String, in_ids: Array, label: String) -> void:
	for m in _placeholder.search_all(text):
		var name := m.get_string(1)
		if name != "id" and not in_ids.has(name):
			_problem(label, "%s uses {%s}, but the node has no input pin '%s' (inputs: %s; {id} is the node's own number)" % [where, name, name, _list(in_ids)])


func _helper(h: Variant, label: String) -> Array:
	var shape := "'helper' must be [name, \"func name(...) -> Type:\", [[indent, \"line\"], ...]]"
	if not (h is Array) or h.size() != 3 or not (h[0] is String) or not (h[1] is String) or not (h[2] is Array):
		_problem(label, shape)
		return []
	var name := String(h[0])
	if not name.is_valid_identifier():
		_problem(label, "the helper's name '%s' must be a name" % name)
		return []
	if name.begins_with("__sc_"):
		_problem(label, "helper names starting with __sc_ are Schematic's own; start yours with your addon's name")
		return []
	if not String(h[1]).begins_with("func %s(" % name):
		_problem(label, "the helper's header must start with \"func %s(\"" % name)
		return []
	var body := []
	for row in h[2]:
		if not (row is Array) or row.size() != 2 or not (typeof(row[0]) in [TYPE_INT, TYPE_FLOAT]) or not (row[1] is String) or int(row[0]) < 1:
			_problem(label, shape + "; each line is [indent (1 or more), \"text\"]")
			return []
		body.append([int(row[0]), String(row[1])])
	if body.is_empty():
		_problem(label, "the helper has no lines")
		return []
	return [name, String(h[1]), body]


func _list(ids: Array) -> String:
	return ", ".join(ids) if not ids.is_empty() else "none"


func _problem(template_id: String, text: String) -> void:
	_problems.append({"template": template_id, "problem": text})
