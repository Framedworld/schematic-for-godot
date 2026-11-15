# Kits: nodes for Schematic from your addon

A **kit** is one GDScript file that an addon ships so that Schematic users get nodes for that addon. A
user who has your addon and Schematic installed finds your nodes in Schematic's action menu. They wire them
like any other node. Each node turns into a few lines of plain GDScript that call your addon. Schematic is
not needed when the game runs.

This page is for addon authors. You do not need to know how Schematic works inside.

## Where the file goes

Put a file named exactly `schematic_kit.gd` at the root of your addon folder:

    res://addons/<your_addon>/schematic_kit.gd

That is all. Nothing calls a registration function. Load order does not matter. Your addon does not depend
on Schematic: if Schematic is not installed, nothing ever loads this file.

Schematic loads a kit when:

- the addon folder is there, **and**
- the addon has no `plugin.cfg` (a plain library of scripts), **or** its plugin is enabled in
  *Project > Project Settings > Plugins*.

When a user enables or disables a plugin, adds or removes an addon folder, or edits a kit file, Schematic
loads all kits again. Open graphs are updated straight away.

## The kit script

A kit script has no base class. It has constants and static functions only.

```gdscript
const KIT_API := 1                 # required: the kit API this file is written for
const KIT_NAME := "Health"         # optional: shown in messages; default palette category
const KIT_VERSION := "1.0.0"       # optional

static func register(kit) -> void:                                  # required
	kit.template("heal", { ... })

static func starters() -> Array:                                    # optional
static func build_starter(id: String, cls: String) -> Variant:      # optional
static func actions(self_cls: String) -> Array:                     # optional
```

`register` receives a small object, `kit`. It has these members and nothing else:

| Member | What it does |
|---|---|
| `kit.template(id, t)` | Adds a node. `id` is your own name for it: letters, digits and `_`. `t` is the template, described below. |
| `kit.full_id(id)` | The id the node is stored under in graphs: `"<addon folder>:<id>"`. |
| `kit.addon` | Your addon's folder name. |
| `kit.kit_name` | `KIT_NAME`, or the folder name. |

## Node ids are namespaced

Inside your kit you write `kit.template("heal", ...)`. Schematic stores the node as `health:heal`, with
your addon's folder name, a colon, then your id. Two addons can both have a `heal` node and the two never
mix. A kit cannot replace one of Schematic's own nodes, or a node from another addon.

Graphs save the full id. **Do not rename a node id once people use it.** A graph that refers to an id that
no longer exists shows that node as a placeholder (see below).

## The template

A template is a dictionary. These are all the keys. Any other key is reported as a mistake.

| Key | Type | Meaning |
|---|---|---|
| `title` | text, **required** | The text on the node and in the action menu. |
| `cat` | text | The action-menu category. Use `|` to nest: `"Health|Advanced"`. Default: `KIT_NAME`. |
| `tip` | text | The tooltip. |
| `search` | text | Extra words the action menu search matches. |
| `ins` | list of input pins | See *Pins*. |
| `outs` | list of output pins | See *Pins*. |
| `lines` | list of text | The GDScript statements the node turns into. Not allowed on a pure node. |
| `exprs` | dictionary | For each output pin id, the GDScript expression that gives its value. Every output needs one. |
| `pure` | true/false | A value with no execution pins. Its expression is written wherever the value is used, each time it is used. |
| `latent` | true/false | The node waits (a line has `await`). Its execution output is labelled *Completed*. |
| `node` | true/false | The code uses something only a Node has (`get_tree()`, `$Child`, ...). Compiling it in a schematic that is not a Node is an error. |
| `always` | true/false | Write the node's expressions even when nothing reads its outputs. Use this when the expression does something, such as a call that changes state. |
| `for` | list of class names | Offer the node only in schematics of these classes or their subclasses, for example `["Node"]` or `["CharacterBody3D"]`. |
| `helper` | list | A helper function added once to every script that uses the node. See *Helpers*. |

A node that is not `pure` gets an execution input (`exec`) and an execution output (`then`) by itself.

### Pins

An input pin is `[id, label, type, default]`. An output pin is `[id, label, type]`. All four parts are text.

- **id**: a name (letters, digits, `_`, not starting with a digit), unique on the node. `exec`, `then` and
  `id` are taken.
- **label**: the text next to the pin. If it is empty, the id is used.
- **type**: one of
  - `"any"`: takes anything;
  - a built-in type: `bool`, `int`, `float`, `String`, `StringName`, `NodePath`, `Vector2`, `Vector2i`,
    `Vector3`, `Vector3i`, `Vector4`, `Vector4i`, `Color`, `Rect2`, `Rect2i`, `Transform2D`, `Transform3D`,
    `Basis`, `Quaternion`, `Plane`, `AABB`, `Projection`, `RID`, `Callable`, `Signal`, `Dictionary`,
    `Array`, and the `Packed...Array` types;
  - `Array[T]`, where `T` is any of these types except `any`;
  - a class: an engine class (`Node`, `Node3D`, `Resource`, ...) or a script's `class_name`.
- **default** (inputs only): a GDScript literal used when nothing is wired in, such as `"10"`, `"\"hello\""`
  or `"Vector3.UP"`. Write `"self"` for "this object". Leave it empty or out for no default.

### Placeholders in `lines` and `exprs`

`{pin_id}` is replaced by the GDScript of whatever is wired into that input: a variable name, an expression,
or the pin's default. `{id}` is replaced by the node's own number. Use it to give a local variable a name
that no other node uses, such as `var __hits_{id} := ...`.

Only input pins and `{id}` can be named. A placeholder that names anything else is reported. Braces that do
not hold a plain name stay as they are, so dictionary literals such as `{"key": {value}}` work.

Start a line with tab characters (`"\t"`) to indent it under the line before. That is how you write an `if`
or a `for` block.

For a node that is not pure, the lines run first, then each wired output gets its own variable, set to its
expression. An output expression can therefore read a variable that the lines declared.

### Helpers

Some nodes need a function of their own. `helper` is
`[name, "func name(args) -> Type:", [[indent, "line"], ...]]`. The function is added once to each script
that uses the node, however many of those nodes it has. Indent 1 is the function body.

Start the name with your addon's name, for example `health_clamp`. Names that start with `__sc_` belong to
Schematic. If two nodes have helpers with the same name but different bodies, the second node is skipped.

```gdscript
"helper": ["health_percent", "func health_percent(node: Node) -> float:", [
	[1, "return 100.0 * node.hp / maxf(node.max_hp, 1)"]]],
"exprs": {"ret": "health_percent({target})"},
```

## A worked example: a health addon

The addon `res://addons/health/` has one script, `health.gd`:

```gdscript
extends Node

signal died

@export var max_hp := 100
var hp := 100

func heal(amount: int) -> void:
	hp = mini(hp + amount, max_hp)

func damage(amount: int) -> void:
	if hp <= 0:
		return
	hp = maxi(hp - amount, 0)
	if hp == 0:
		died.emit()
```

It ships `res://addons/health/schematic_kit.gd` with three nodes:

```gdscript
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
```

A user builds a schematic with three functions. Each function takes a node `who`:

- **heal_twice**: Heal with Amount set to 5, then Heal with the default amount.
- **alive**: returns the value of Is Alive.
- **wait_dead**: a function marked as one that waits. Wait Until Dead, then *Set saw_death* to true.

Schematic writes this script:

```gdscript
extends Node
var saw_death: bool = false
func heal_twice(who: Node) -> void:
	who.heal(5)
	who.heal(10)
	return
func alive(who: Node) -> bool:
	return (who.hp > 0)
func wait_dead(who: Node) -> void:
	if who.hp > 0:
		await who.died
	saw_death = true
	return
```

(The first line of a generated file is a `# @schematic` comment. The graph itself is saved at the end of the
file as comment lines. Both are left out here.)

- **Heal**: `{target}` became `who` (the wire from the function's input) and `{amount}` became `5`. The
  second Heal has nothing wired into Amount, so it used the default, `10`.
- **Is Alive** has no execution pins. Its expression went straight into the `return`.
- **Wait Until Dead** became the `if` and the indented `await`. The node after it runs when the signal
  comes.

In an event graph, with `target` an exported variable, the same nodes give:

```gdscript
func _ready() -> void:
	target.heal(10)
	alive = (target.hp > 0)
	if target.hp > 0:
		await target.died
```

The example is a real test: `tests/fake_kit/health/` in the Schematic repository is this addon, and
`tests/test_public_kit.gd` builds this graph, compiles it, runs the script and checks the results.

## Starters and actions (optional)

**Starters** are ready-made schematics offered in Schematic's *New Schematic* dialog.

```gdscript
static func starters() -> Array:
	return [{"id": "regen", "name": "Regenerating Health (Health kit)", "parent": "Node",
		"file": "Regen", "desc": "Heals its parent a little every second."}]

static func build_starter(id: String, _cls: String) -> Variant:
	if id == "regen":
		return "extends Node\n\n@export var per_second := 5\n\nfunc _process(delta: float) -> void:\n\tget_parent().heal(int(per_second * delta))\n"
	return ""
```

A starter has `id`, `name` and `parent` (required), and `desc` and `file` (the suggested file name,
optional). Its id is namespaced like node ids. `build_starter` returns GDScript source, and Schematic turns
it into nodes. `cls` is the class name the user chose, or `""`.

**Actions** are extra entries in the action menu that depend on the schematic being edited, or on what is in
the project. `self_cls` is the class of the schematic.

```gdscript
static func actions(self_cls: String) -> Array:
	return [{"value": "100", "type": "int", "title": "Full Health", "cat": "Health",
		"tip": "The health a new health node starts with."}]
```

Each entry is one of:

- `{"value": "<GDScript expression>", "type": ..., "title": ..., "cat": ..., "tip": ..., "search": ...}`: a
  value node;
- `{"template": {...}}`: a node made for one thing in the project, such as one particular data file. The
  template is written into the graph itself, so it does not need an id.

To offer a node only in some classes, `for` in its template is usually simpler than `actions`.

## When something is wrong

Schematic checks everything a kit gives it. Each problem is reported **once**, as a warning in Godot's
Output panel, like this:

    Schematic kit 'health' (res://addons/health/schematic_kit.gd), node 'heal': pin 'amount': unknown type 'Intt' (...); that node is skipped, the kit's other nodes are loaded

A message names the addon, the file, the node and the problem, and says what was skipped. Schematic also
keeps the list, so its editor can show it.

| Problem | What happens |
|---|---|
| unknown key, missing `title`, a pin with no id or an unknown type, a placeholder naming no input pin, an output with no expression, a pure node with `lines`, a latent node with no `await` | that node is skipped; the rest of the kit loads |
| no `KIT_API`, or not a whole number | the kit is skipped |
| `KIT_API` newer than this Schematic understands | the kit is skipped; the message says which kit API it needs and which Schematic version is installed |
| the script has a parse error | the kit is skipped; Godot prints the error with its line; fixing and saving the file loads it |
| `register` stops with an error | Godot prints the error; the nodes added before it are kept; other kits are not affected |

## When your addon is missing

A user might open a graph that uses your nodes in a project where your addon is not installed or not
enabled. Each of those nodes shows as a red placeholder titled *(missing)*. It keeps all its wires, and
compiling reports that the addon is missing. When the addon comes back, the nodes are normal nodes again,
with the same wires and the same code.

## Testing your kit

1. Put the addon and Schematic in a project. Open the Schematic editor, right-click the graph and search for
   your node's title or search words.
2. Watch the Output panel for messages that start with `Schematic kit`.
3. Look at the *Generated Code* tab to see what your nodes write.
4. For an automated test, follow `tests/test_public_kit.gd` in the Schematic repository. It points the kit
   scan at a folder (`Kits.set_kit_roots`), loads the kits (`R.reload_kits()`), builds a graph with
   `sc_model.gd`, compiles it with `sc_compiler.gd`, loads the generated script and calls it.

## Stability

`KIT_API` is the version of this contract: the file name, the constants, the four functions, the `kit`
object, the template keys, the pin format and the placeholder syntax. Schematic loads every kit written for
its kit API or an older one. If the contract ever changes in a way old kits could not handle, `KIT_API` goes
up, and older Schematic versions skip the new kits with a clear message. A kit never changes the code of
graphs that do not use its nodes.

Only what this page describes is covered. Other parts of Schematic's source can change in any release.

## Security

A kit script is code from an addon the user installed. It runs in the editor like any other addon code,
with the same access.
