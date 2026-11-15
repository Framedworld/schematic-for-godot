extends RefCounted
## What the converter's tests ask of a converted script, whatever the script is: it loads where the original
## loads, nothing written in the source has gone missing, and it offers other scripts exactly what the
## original offered. Used by tests/test_convert.gd (samples that are also run) and tests/stress_convert.gd
## (any folder of scripts).
const Model := preload("res://addons/schematic/core/sc_model.gd")
const Compiler := preload("res://addons/schematic/core/sc_compiler.gd")
const T := preload("res://addons/schematic/core/sc_types.gd")
const Parser := preload("res://addons/schematic/core/sc_gd_parser.gd")
const LoggerScript := preload("res://addons/schematic/editor/sc_logger.gd")

var digits := RegEx.create_from_string("\\d+")
var own_id := RegEx.create_from_string("gdscript://-?\\d+\\.gd")
var declared := RegEx.create_from_string("\\b(?:var|for|const)[ \\t]+([A-Za-z_][A-Za-z_0-9]*)")
var headers := RegEx.create_from_string("\\bfunc\\s*[A-Za-z_0-9]*\\s*\\(([^)]*)\\)")
var range_from_zero := RegEx.create_from_string("\\brange\\(\\s*0\\s*,")
var extends_path := RegEx.create_from_string("(?m)^(?:class_name\\s+\\w+\\s+)?extends\\s+\"([^\"]+)\"")
var named_lambdas :=RegEx.create_from_string("[=(,:\\[]\\s*func\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(")
var loose := RegEx.create_from_string(":0:(?=[,)])|type 0 (?=,)|returns 0 (?=,)")
var typed := RegEx.create_from_string(":\\d+:[A-Za-z0-9_]*(?=[,)])|type \\d+ [A-Za-z0-9_]*(?=,)|returns \\d+ [A-Za-z0-9_]*(?=,)")


## The script without its class name, so a copy of it can be loaded beside the real one.
func without_class_name(code: String) -> String:
	var lines := code.split("\n")
	var own := ""
	for i in lines.size():
		var at := lines[i].find("class_name ")
		if at != -1 and lines[i].substr(0, at).strip_edges().trim_prefix("@abstract") == "":
			own = lines[i].substr(at + 11).get_slice(" ", 0).strip_edges()
			var rest := lines[i].find(" extends ")
			lines[i] = lines[i].substr(0, at) + (lines[i].substr(rest + 1) if rest > 0 else "")
	var text := "\n".join(lines)
	if own != "":
		text = RegEx.create_from_string("\\b%s\\.(?!new\\b)" % own).sub(text, "", true)
	return text


## Loads a script from text. Returns [script or null, what GDScript said (digits blanked), the lines it named].
func load_text(code: String) -> Array:
	var logger := LoggerScript.new()
	OS.add_logger(logger)
	var gs := GDScript.new()
	gs.source_code = without_class_name(code)
	var ok := gs.reload() == OK
	OS.remove_logger(logger)
	var said := {}
	var lines := []
	for it in logger.items:
		said[digits.sub(String(it.msg), "N", true)] = true
		lines.append(int(it.line))
	return [gs if ok else null, said, lines]


## Compiles a converted schematic the way the editor does: a local written with ":=" that GDScript can no
## longer infer goes back to its stated type. Returns [code, script or null, what GDScript said, what it said
## about the first attempt].
func compile_loaded(bp: Dictionary) -> Array:
	var code := Compiler.new().compile(bp)
	var res := load_text(code)
	var first_said: Dictionary = res[1]
	for attempt in 8:
		if res[0] != null or Compiler.drop_inferred(bp, code, res[2]) == 0:
			break
		code = Compiler.new().compile(bp)
		res = load_text(code)
	return [code, res[0], res[1], first_said]


## What a script is written with, counted: "str <text>", "num <value>", "node <path>", "id <name>".
func tokens_of(code: String) -> Dictionary:
	var reader := Parser.new()
	reader._tokenize(code)
	var out := {}
	for ln in reader._lines:
		for tok in ln.toks:
			var key := ""
			match String(tok.t):
				"str":
					# the same text whichever quotes or prefix it is written with
					var body := String(tok.v).trim_prefix("&").trim_prefix("^")
					if not body.begins_with("r"):
						var q := 3 if (body.begins_with("\"\"\"") or body.begins_with("'''")) else 1
						body = body.substr(q, body.length() - 2 * q).replace("\\\"", "\"").replace("\\'", "'")
					key = "str " + body
				"num":
					# by value, and without its sign: "- 2" and "-2" are the same number written two ways
					var text := String(tok.v).trim_prefix("-")
					key = "num " + str(text.hex_to_int() if text.begins_with("0x") else (text.bin_to_int() if text.begins_with("0b") else float(text)))
				"node":
					key = "node " + String(tok.v)
				"id":
					key = "id " + String(tok.v)
			if key != "":
				out[key] = int(out.get(key, 0)) + 1
	return out


## Everything written in `src` that `code` no longer has: every string, number and node path, and every name
## the script did not make up itself (a local, parameter or loop variable may be renamed; a type may be left
## for GDScript to infer). Returns [[kind, text, times in the source, times after], ...]; kind "type" is a name
## only ever used as a type, which is left out when the project it is converted in does not have it.
func missing(src: String, code: String) -> Array:
	var had := tokens_of(src)
	var has := tokens_of(code)
	var own := {}
	for m in declared.search_all(src):
		own[m.get_string(1)] = true
	for m in headers.search_all(src):
		for part in m.get_string(1).split(","):
			own[part.strip_edges().trim_prefix("...").get_slice(":", 0).get_slice("=", 0).strip_edges()] = true
	for m in named_lambdas.search_all(src):
		own[m.get_string(1)] = true   # a lambda's name is only for error messages
	var out := []
	for tk in had:
		var want := int(had[tk])
		var got := int(has.get(tk, 0))
		if got >= want:
			continue
		var kind := String(tk).get_slice(" ", 0)
		var text := String(tk).substr(kind.length() + 1)
		if kind == "id":
			# (a plugin's get_editor_interface() is written as the EditorInterface singleton it returns)
			if got > 0 or own.has(text) or T.hint(text) != "" or text in ["Variant", "void", "get_editor_interface"]:
				continue
			got += int(has.get("str " + text, 0))   # {name = value} is written {"name": value}
			if got < want and text in ["x", "y", "z", "w"] and code.count("Vector") > src.count("Vector"):
				continue   # `t.origin.y = h` on a local is written as a whole new origin
			if got < want and text[0] == text[0].to_upper() and text[0] != "_" and not src.contains(text + ".") and not src.contains(text + "("):
				out.append(["type", text, want, got])
				continue
		elif kind == "num" and text == "0.0":
			got += range_from_zero.search_all(src).size()   # range(0, n) is written range(n)
		elif kind == "str" and extends_path.search(src) != null and extends_path.search(src).get_string(1) == text:
			continue   # `extends "res://base.gd"` names the class by its class name when it has one
		elif kind == "node":
			got += int(has.get("str " + text, 0))   # $Path may be written get_node("Path") now, or the other way round
		elif kind == "str":
			got += int(has.get("node " + text, 0))
			if text.ends_with(".gd") and not text.begins_with("res://"):
				for other in has:
					if String(other).ends_with("/" + text):
						got += 1   # `extends "base.gd"` names the same file by its full path now
		if got < want:
			out.append([kind, text, want, got])
	return out


func plain(v: Variant) -> String:
	if v is Object:
		return "<%s>" % (v as Object).get_class()
	return var_to_str(v)


## What a script offers the rest of the project: its functions, properties (with their default values),
## signals, constants, whether it is a tool and what it extends.
func interface(gs: GDScript) -> Dictionary:
	var out := {}
	var virtuals := {}
	for m in ClassDB.class_get_method_list(gs.get_instance_base_type()):
		if int(m.flags) & METHOD_FLAG_VIRTUAL:
			virtuals[String(m.name)] = true
	for m in gs.get_script_method_list():
		var args := PackedStringArray()
		for a in m.args:
			if virtuals.has(String(m.name)):
				args.append("-")   # an engine callback's parameters take the names and types of the event's pins
				continue
			args.append("%s:%d:%s" % [a.name, a.type, own_id.sub(String(a.class_name), "gdscript://self")])
		out["func %s" % m.name] = "(%s) defaults %d, returns %d %s, static %s" % [", ".join(args), m.default_args.size(), m["return"].type,
			own_id.sub(String(m["return"].class_name), "gdscript://self"), (int(m.flags) & METHOD_FLAG_STATIC) != 0]
	for p in gs.get_script_property_list():
		if int(p.usage) & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			out["group %s" % p.name] = str(p.usage)
			continue
		out["var %s" % p.name] = "type %d %s, hint %d %s, exported %s, default %s" % [p.type, own_id.sub(String(p.class_name), "gdscript://self"), p.hint,
			own_id.sub(String(p.hint_string), "gdscript://self"), (int(p.usage) & PROPERTY_USAGE_EDITOR) != 0, plain(gs.get_property_default_value(p.name))]
	for s in gs.get_script_signal_list():
		var args := PackedStringArray()
		for a in s.args:
			args.append("%s:%d" % [a.name, a.type])
		out["signal %s" % s.name] = ", ".join(args)
	var consts := gs.get_script_constant_map()
	for c in consts:
		out["const %s" % c] = plain(consts[c])
	out["tool"] = str(gs.is_tool())
	out["base"] = String(gs.get_instance_base_type())
	var rpcs: Variant = gs.get_rpc_config()
	out["rpc"] = var_to_str(rpcs) if rpcs is Dictionary else "{}"
	return out


## How the converted script's interface differs from the original's:
## [[what, key, was, now], ...] with what = "missing", "added", "different" or "typed" (a variable or
## parameter the source left untyped that now has the type it is always used with).
func interface_changes(a: Dictionary, b: Dictionary) -> Array:
	var out := []
	for k in a:
		if not b.has(k):
			out.append(["missing", k, a[k], ""])
		elif a[k] != b[k]:
			var what := "different"
			if loose.search(String(a[k])) != null and typed.sub(String(a[k]), "T", true) == typed.sub(String(b[k]), "T", true):
				what = "typed"
			out.append([what, k, a[k], b[k]])
	for k in b:
		# live debugging adds helpers of its own (a lambda is written back as a lambda, and adds nothing)
		if not a.has(k) and not String(k).contains("__sc_"):
			out.append(["added", k, "", b[k]])
	return out
