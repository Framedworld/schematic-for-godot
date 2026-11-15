## Schematic nodes for the fake "health" addon (see docs/KITS.md, which walks through this file).
## In a real addon this file is res://addons/health/schematic_kit.gd.

const KIT_API := 1
const KIT_NAME := "Health"
const KIT_VERSION := "1.0.0"


static func register(kit) -> void:
	# a node that runs a statement: calls a method of the health node
	kit.template("heal", {
		"title": "Heal",
		"cat": "Health",
		"tip": "Gives the target back some health points (never more than its maximum).",
		"search": "health hp restore cure",
		"ins": [["target", "Target", "Node", ""], ["amount", "Amount", "int", "10"]],
		"lines": ["{target}.heal({amount})"],
	})
	# a pure node: a value, written out where it is used
	kit.template("is_alive", {
		"title": "Is Alive",
		"cat": "Health",
		"pure": true,
		"search": "health hp dead living",
		"ins": [["target", "Target", "Node", ""]],
		"outs": [["ret", "Alive", "bool"]],
		"exprs": {"ret": "({target}.hp > 0)"},
	})
	# a latent node: waits for a signal, only in schematics that are nodes
	kit.template("wait_until_dead", {
		"title": "Wait Until Dead",
		"cat": "Health",
		"latent": true,
		"for": ["Node"],
		"search": "health died death await signal",
		"ins": [["target", "Target", "Node", ""]],
		"lines": ["if {target}.hp > 0:", "\tawait {target}.died"],
	})


## Ready-made schematics offered in the New Schematic dialog.
static func starters() -> Array:
	return [{"id": "regen", "name": "Regenerating Health (Health kit)", "parent": "Node", "file": "Regen",
		"desc": "Heals its parent a little every second."}]


## The starter's script, as GDScript source; Schematic turns it into nodes.
static func build_starter(id: String, _cls: String) -> Variant:
	if id == "regen":
		return "extends Node\n\n@export var per_second := 5\n\nfunc _process(delta: float) -> void:\n\tget_parent().heal(int(per_second * delta))\n"
	return ""


## Palette entries that depend on the schematic's class: here one value, offered everywhere.
static func actions(_self_cls: String) -> Array:
	return [{"value": "100", "type": "int", "title": "Full Health", "cat": "Health", "tip": "The health a new health node starts with."}]
