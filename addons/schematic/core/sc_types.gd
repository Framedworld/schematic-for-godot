@tool
extends RefCounted
## Pin type helpers. A pin type is a String:
##   "exec"            execution wire
##   "any"             wildcard / Variant
##   "int", "Vector3"  built-in Variant types (GDScript spelling)
##   "Node3D", "MyBP"  Object classes (engine or script class_name)
##   "Array[Node]"     typed arrays

const BUILTIN := {
	"bool": TYPE_BOOL, "int": TYPE_INT, "float": TYPE_FLOAT, "String": TYPE_STRING,
	"Vector2": TYPE_VECTOR2, "Vector2i": TYPE_VECTOR2I, "Rect2": TYPE_RECT2, "Rect2i": TYPE_RECT2I,
	"Vector3": TYPE_VECTOR3, "Vector3i": TYPE_VECTOR3I, "Transform2D": TYPE_TRANSFORM2D,
	"Vector4": TYPE_VECTOR4, "Vector4i": TYPE_VECTOR4I, "Plane": TYPE_PLANE, "Quaternion": TYPE_QUATERNION,
	"AABB": TYPE_AABB, "Basis": TYPE_BASIS, "Transform3D": TYPE_TRANSFORM3D, "Projection": TYPE_PROJECTION,
	"Color": TYPE_COLOR, "StringName": TYPE_STRING_NAME, "NodePath": TYPE_NODE_PATH, "RID": TYPE_RID,
	"Callable": TYPE_CALLABLE, "Signal": TYPE_SIGNAL, "Dictionary": TYPE_DICTIONARY, "Array": TYPE_ARRAY,
	"PackedByteArray": TYPE_PACKED_BYTE_ARRAY, "PackedInt32Array": TYPE_PACKED_INT32_ARRAY,
	"PackedInt64Array": TYPE_PACKED_INT64_ARRAY, "PackedFloat32Array": TYPE_PACKED_FLOAT32_ARRAY,
	"PackedFloat64Array": TYPE_PACKED_FLOAT64_ARRAY, "PackedStringArray": TYPE_PACKED_STRING_ARRAY,
	"PackedVector2Array": TYPE_PACKED_VECTOR2_ARRAY, "PackedVector3Array": TYPE_PACKED_VECTOR3_ARRAY,
	"PackedColorArray": TYPE_PACKED_COLOR_ARRAY, "PackedVector4Array": TYPE_PACKED_VECTOR4_ARRAY,
}

## Types offered in the variable type dropdown, most used first (Unreal order-ish).
const COMMON := ["bool", "int", "float", "String", "StringName", "Vector2", "Vector3", "Color",
	"Transform3D", "Transform2D", "Basis", "Quaternion", "Vector2i", "Vector3i", "Vector4", "Rect2", "AABB", "Plane",
	"NodePath", "Array", "Dictionary", "Callable", "PackedScene", "Node", "Node2D", "Node3D", "Control", "Resource", "Object", "any"]

# Unreal's pin palette.
const C_EXEC := Color(1, 1, 1)
const COLORS := {
	"exec": Color(1, 1, 1), "any": Color(0.55, 0.55, 0.55),
	"bool": Color(0.58, 0.0, 0.0), "int": Color(0.12, 0.89, 0.67), "float": Color(0.62, 1.0, 0.27),
	"String": Color(0.98, 0.0, 0.83), "StringName": Color(0.79, 0.53, 0.95), "NodePath": Color(0.79, 0.53, 0.95),
	"Vector2": Color(1.0, 0.78, 0.14), "Vector2i": Color(1.0, 0.78, 0.14), "Vector3": Color(1.0, 0.78, 0.14),
	"Vector3i": Color(1.0, 0.78, 0.14), "Vector4": Color(1.0, 0.78, 0.14), "Vector4i": Color(1.0, 0.78, 0.14),
	"Quaternion": Color(0.62, 0.7, 1.0), "Basis": Color(0.62, 0.7, 1.0),
	"Transform3D": Color(1.0, 0.45, 0.0), "Transform2D": Color(1.0, 0.45, 0.0), "Projection": Color(1.0, 0.45, 0.0),
	"Color": Color(0.0, 0.35, 0.8), "Rect2": Color(0.0, 0.35, 0.8), "Rect2i": Color(0.0, 0.35, 0.8),
	"AABB": Color(0.0, 0.35, 0.8), "Plane": Color(0.0, 0.35, 0.8), "RID": Color(0.0, 0.35, 0.8),
	"Callable": Color(1.0, 0.22, 0.22), "Signal": Color(1.0, 0.22, 0.22),
	"Dictionary": Color(0.35, 0.75, 0.75), "Array": Color(0.75, 0.75, 0.9),
}
const C_OBJECT := Color(0.0, 0.66, 0.96)
const C_ENUM := Color(0.0, 0.43, 0.39)

static var _globals: Dictionary = {}  # class_name -> {base, path}
static var _globals_stamp: int = -1


static func refresh_globals() -> void:
	_globals.clear()
	for c in ProjectSettings.get_global_class_list():
		_globals[String(c["class"])] = {"base": String(c["base"]), "path": String(c["path"])}
	_globals_stamp = Engine.get_process_frames()


static func globals() -> Dictionary:
	if _globals_stamp == -1:
		refresh_globals()
	return _globals


static func is_builtin(t: String) -> bool:
	return BUILTIN.has(t) or t.begins_with("Array[")


static func is_object(t: String) -> bool:
	return t != "" and t != "exec" and t != "any" and not is_builtin(t)


static func class_known(t: String) -> bool:
	return ClassDB.class_exists(t) or globals().has(t)


static func parent_of(cls: String) -> String:
	if ClassDB.class_exists(cls):
		return String(ClassDB.get_parent_class(cls))
	if globals().has(cls):
		return globals()[cls]["base"]
	return ""


## The nearest engine (ClassDB) class in the ancestry of `cls`.
static func native_of(cls: String) -> String:
	var guard := 0
	while cls != "" and not ClassDB.class_exists(cls) and guard < 64:
		cls = parent_of(cls)
		guard += 1
	return cls


static func is_a(cls: String, base: String) -> bool:
	if cls == base or base == "Object" and is_object(cls):
		return true
	var guard := 0
	while cls != "" and guard < 64:
		if cls == base:
			return true
		if ClassDB.class_exists(cls):
			return ClassDB.class_exists(base) and ClassDB.is_parent_class(cls, base)
		cls = parent_of(cls)
		guard += 1
	return false


static func color(t: String, is_enum := false) -> Color:
	if is_enum:
		return C_ENUM
	if COLORS.has(t):
		return COLORS[t]
	if t.begins_with("Array") or t.begins_with("Packed"):
		return COLORS["Array"]
	return C_OBJECT


## Converts a PropertyInfo dictionary (from ClassDB / get_method_list) to a pin type. "" means void.
static func from_info(info: Dictionary, is_return := false) -> String:
	var t: int = info.get("type", TYPE_NIL)
	match t:
		TYPE_NIL:
			if is_return and not (int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT):
				return ""
			return "any"
		TYPE_OBJECT:
			var cn := String(info.get("class_name", ""))
			if cn == "":
				cn = String(info.get("hint_string", "")) if int(info.get("hint", 0)) == PROPERTY_HINT_RESOURCE_TYPE else ""
			if cn == "" or cn.contains(","):
				return "Object"
			return cn
		TYPE_ARRAY:
			if int(info.get("hint", 0)) == PROPERTY_HINT_ARRAY_TYPE:
				var hs := String(info.get("hint_string", ""))
				if hs != "" and not hs.contains("/") and not hs.contains(":") and (BUILTIN.has(hs) or class_known(hs)):
					return "Array[%s]" % hs
			return "Array"
	return type_string(t)


## Returns "Class.EnumName" when the info describes an enum-typed int, else "".
static func enum_from_info(info: Dictionary) -> String:
	if int(info.get("type", 0)) != TYPE_INT:
		return ""
	var u := int(info.get("usage", 0))
	if u & (PROPERTY_USAGE_CLASS_IS_ENUM | PROPERTY_USAGE_CLASS_IS_BITFIELD):
		return String(info.get("class_name", ""))
	return ""


## Type of a runtime value, as a pin type.
static func of_value(v: Variant) -> String:
	if typeof(v) == TYPE_OBJECT:
		return (v as Object).get_class() if v != null else "Object"
	if typeof(v) == TYPE_NIL:
		return "any"
	return type_string(typeof(v))


static func element_type(t: String) -> String:
	if t.begins_with("Array[") and t.ends_with("]"):
		return t.substr(6, t.length() - 7)
	match t:
		"PackedByteArray", "PackedInt32Array", "PackedInt64Array": return "int"
		"PackedFloat32Array", "PackedFloat64Array": return "float"
		"PackedStringArray": return "String"
		"PackedVector2Array": return "Vector2"
		"PackedVector3Array": return "Vector3"
		"PackedColorArray": return "Color"
		"PackedVector4Array": return "Vector4"
	return "any"


static func _num(t: String) -> bool:
	return t == "int" or t == "float"


static func _strish(t: String) -> bool:
	return t == "String" or t == "StringName" or t == "NodePath"


## Can a wire run from an output of type `from` to an input of type `to`?
static func can_connect(from: String, to: String) -> bool:
	if from == "exec" or to == "exec":
		return from == to
	if from == to or to == "any" or from == "any":
		return true
	if to == "String":
		return true  # everything prints
	if _num(from) and _num(to):
		return true
	if to == "bool" and (_num(from) or is_object(from)):
		return true
	if _strish(from) and _strish(to):
		return true
	if is_object(from) and is_object(to):
		return is_a(from, to)
	if to.begins_with("Array") and from.begins_with("Array"):
		return to == "Array" or from == "Array"
	if to == "Array" and from.begins_with("Packed"):
		return true
	if (to == "Vector2" and from == "Vector2i") or (to == "Vector2i" and from == "Vector2"):
		return true
	if (to == "Vector3" and from == "Vector3i") or (to == "Vector3i" and from == "Vector3"):
		return true
	if (to == "Quaternion" and from == "Basis") or (to == "Basis" and from == "Quaternion"):
		return true
	return false


## Stricter test used for context-sensitive palette filtering.
static func matches(from: String, to: String) -> bool:
	if from == to:
		return true
	if from == "exec" or to == "exec" or from == "any" or to == "any":
		return false
	if _num(from) and _num(to):
		return true
	if _strish(from) and _strish(to):
		return true
	if is_object(from) and is_object(to):
		return is_a(from, to)
	if from.begins_with("Array") and to.begins_with("Array"):
		return true
	return false


## Wraps `expr` so a value of type `from` can feed an input of type `to`.
static func coerce(expr: String, from: String, to: String) -> String:
	if from == to or to == "any" or from == "any" or to == "exec":
		return expr
	if to == "String":
		return "str(%s)" % expr
	if to == "int" and from == "float":
		return "int(%s)" % expr
	if to == "bool" and _num(from):
		return "(%s != 0)" % expr
	if to == "bool" and is_object(from):
		return "is_instance_valid(%s)" % expr
	if to == "StringName" and from == "String":
		return "StringName(%s)" % expr
	if to == "NodePath" and _strish(from):
		return "NodePath(%s)" % expr
	if BUILTIN.has(to) and BUILTIN.has(from) and not _num(from):
		if to in ["Vector2", "Vector2i", "Vector3", "Vector3i", "Quaternion", "Basis", "Array"]:
			return "%s(%s)" % [to, expr]
	return expr


## GDScript literal for the zero value of a type.
static func default_literal(t: String) -> String:
	match t:
		"bool": return "false"
		"int": return "0"
		"float": return "0.0"
		"String": return "\"\""
		"StringName": return "&\"\""
		"NodePath": return "^\"\""
		"any", "exec", "": return "null"
		"Array": return "[]"
		"Dictionary": return "{}"
	if t.begins_with("Array["):
		return "[]"
	if BUILTIN.has(t):
		return "%s()" % t
	return "null"


## Type annotation text (without the colon), or "" when the pin is untyped.
static func hint(t: String) -> String:
	if t == "any" or t == "exec" or t == "":
		return ""
	if is_builtin(t):
		if t.begins_with("Array["):
			var e := element_type(t)
			return t if (BUILTIN.has(e) or class_known(e)) else "Array"
		return t
	return t if class_known(t) else ""


static func ident(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s[i]
		var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (c >= "0" and c <= "9")
		out += c if ok else "_"
	if out == "" or (out[0] >= "0" and out[0] <= "9"):
		out = "_" + out
	return out


## Literal -> value (literals are stored as var_to_str text so they are valid GDScript).
static func parse_literal(lit: String, fallback: Variant = null) -> Variant:
	if lit == "":
		return fallback
	var v: Variant = str_to_var(lit)
	return fallback if v == null and lit != "null" else v


static func to_literal(v: Variant) -> String:
	match typeof(v):
		TYPE_FLOAT:
			var s := var_to_str(v)
			return s if (s.contains(".") or s.contains("e") or s.contains("inf") or s.contains("nan")) else s + ".0"
		TYPE_NIL:
			return "null"
		TYPE_OBJECT:
			if v is Resource and (v as Resource).resource_path != "":
				return "preload(\"%s\")" % (v as Resource).resource_path
			return "null"
	return var_to_str(v)
