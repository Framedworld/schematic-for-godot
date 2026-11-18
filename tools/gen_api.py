import json, re, sys
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding='utf8'))
def brief(s):
    if not s: return ""
    s = s.split("\n")[0]
    s = re.sub(r"\[(?:param|member|method|constant|signal|enum|code|b|i) ?([^\]]*)\]", r"\1", s)
    s = re.sub(r"\[/?[a-z_]+\]", "", s)
    s = re.sub(r"\[([A-Za-z0-9_@.]+)\]", r"\1", s)
    m = re.match(r"(.{20,220}?\.)(\s|$)", s)
    return (m.group(1) if m else s[:220]).strip()
def args(a): return [[x["name"], x["type"]] + ([x["default_value"]] if "default_value" in x else []) for x in a.get("arguments", [])]
# Made from the oldest Godot the plugin supports (`godot --headless --dump-extension-api-with-docs`), so every
# utility function and built-in type method offered as a node exists on every supported version. The version is
# kept in the file: the plugin says so when it runs on an older engine than the data was made from.
h = d["header"]
o = {"engine": [h["version_major"], h["version_minor"]], "engine_name": h["version_full_name"], "utils": [], "types": {}, "enums": {}, "docs": {}}
for u in d["utility_functions"]:
    o["utils"].append({"n": u["name"], "r": u.get("return_type", ""), "a": args(u), "v": u["is_vararg"], "c": u["category"], "d": brief(u.get("description"))})
for b in d["builtin_classes"]:
    n = b["name"]
    if n in ("Nil",): continue
    t = {"m": [], "mem": [[m["name"], m["type"]] for m in b.get("members", [])], "ctor": [args(c) for c in b.get("constructors", [])],
         "op": [[x["name"], x.get("right_type", ""), x["return_type"]] for x in b.get("operators", [])],
         "const": [[c["name"], c["type"], c["value"]] for c in b.get("constants", [])], "d": brief(b.get("brief_description"))}
    for m in b.get("methods", []):
        t["m"].append({"n": m["name"], "r": m.get("return_type", ""), "a": args(m), "c": m["is_const"], "s": m["is_static"], "v": m["is_vararg"], "d": brief(m.get("description"))})
    o["types"][n] = t
for e in d["global_enums"]:
    o["enums"][e["name"]] = [[v["name"], v["value"]] for v in e["values"]]
for c in d["classes"]:
    cd = {}
    for m in c.get("methods", []):
        b_ = brief(m.get("description"))
        if b_: cd[m["name"]] = b_
    for p in c.get("properties", []):
        b_ = brief(p.get("description"))
        if b_: cd["." + p["name"]] = b_
    for s in c.get("signals", []):
        b_ = brief(s.get("description"))
        if b_: cd["!" + s["name"]] = b_
    b_ = brief(c.get("brief_description"))
    if b_: cd[""] = b_
    if cd: o["docs"][c["name"]] = cd
json.dump(o, open(out, "w", encoding="utf8"), separators=(",", ":"), ensure_ascii=False)
print(len(o["utils"]), len(o["types"]), len(o["docs"]))
