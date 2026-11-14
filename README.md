# Blueprints for Godot

**Unreal-style Blueprints for Godot 4. You wire nodes; it writes the GDScript you would have written.**

![A Blueprint graph while the game runs: the wires being followed light up and the pins show live values](docs/images/live_flow.gif)

![The Blueprint editor with an event graph open](docs/images/editor.png)

Blueprints for Godot is an editor plugin. There is no custom engine build, no runtime library and no new file
type: a Blueprint is an ordinary `.gd` script, so it attaches to nodes, exports variables to the Inspector,
registers a `class_name`, and is called from hand-written code like any other script.

Tested on stock Godot 4.7.1 and on a 4.8 development build. It needs Godot 4.5 or later (not tried on 4.5 or 4.6).

## A Blueprint is a GDScript file

![A graph beside the GDScript it compiles to](docs/images/graph_to_code.png)

The graph compiles to plain, readable GDScript, and the graph itself is kept in the same file as a comment
block. What runs in your game is the code on the right: no interpreter and no per-node cost. Turn the plugin
off and your Blueprints still run.

## Find any node by typing

![The action menu filtered by the word rotate](docs/images/action_menu.png)

Right-click, or drag off a pin, and type. The menu lists every function of every Godot class, your own
functions, variables, macros and libraries, filtered to what fits the pin you dragged from. Unreal names work
too: typing `BeginPlay` finds Event Ready.

## Start from something that works

![The New Blueprint dialog listing the starters](docs/images/starters.png)

New Blueprint offers ready-wired starters beside Empty: 2D and 3D characters, pickups, trigger volumes,
projectiles, spawners, a health component, a game state and a score HUD, plus function libraries, macro
libraries, data assets and interfaces. A small complete game built only from Blueprints is in `demo/game`.

![The player Blueprint of the demo game](docs/images/game_blueprint.png)

## Debug on the graph

![The game stopped at a node, with values on the pins and a watch list](docs/images/debug_values.png)

Put a breakpoint on a node with F9. When the game stops there, every wired pin of that function shows its
value, and Step Into, Step Over and Step Out move one node at a time. Watch any variable or expression, or
right-click a node and watch one of its pins.

![Stepped into a function, with the call stack showing both functions](docs/images/debug_call_stack.png)

The Call Stack lists the functions that are running and the node each is at. Click one to see its graph and its
values.

## Watch it run

![Exec wires lit up with moving dots while the game runs](docs/images/live_flow.png)

Turn on Show Flow and Values and play: the wires the game follows light up with moving dots, and each pin
shows the last value it received. This is opt-in per Blueprint, because it adds trace calls to the generated
code; with it off, nothing is added.

## Interfaces

![Message nodes calling an interface, beside the code they compile to](docs/images/interface_message.png)

A Blueprint Interface is a list of functions that different Blueprints agree to have. A Message node calls one
on any object and does nothing if the object does not have it, so a player can Interact with whatever it is
looking at without knowing its class. It compiles to the `has_method` check you would write yourself.

## Bring the scripts you already have

![A hand-written script converted to a graph](docs/images/converted_script.png)

Right-click a `.gd` file and pick Convert to Blueprint, or convert a whole project from the command line. The
original is kept beside it. Kenney's 3D platformer starter kit converts with all 110 lines as nodes and plays
identically; a 42,000-line game converted with three lines left as code, and its own test suites gave the same
results as before.

## Timelines and data tables

![A timeline node with its curve editor](docs/images/timeline.png)

Timelines animate values over time with a curve editor in the Details panel. Data Assets are structures of
fields, and Data Tables are rows of them, with CSV import and export.

![The Data Table editor](docs/images/data_table.png)

## Blueprints stand out in your project

![Blueprint files with their own icon in the FileSystem dock](docs/images/file_icon.png)

Blueprint files have their own icon in the FileSystem dock, and double-clicking one opens the graph instead of
the script editor.

## What it does not do

`PARITY.md` lists every Unreal Blueprint feature and where this plugin stands on it. The main gaps are
in-graph animation pose editing (Godot's AnimationTree covers that) and interface-typed pins (GDScript has no
interfaces). The limits of the debugger are listed under Debugging below.

The pictures on this page are taken from the running editor by `tests/shot_readme.gd`, and the animation by
`tests/shot_readme_gif.gd` and `tools/make_gif.py`.

## Installing it in your own project

1. Copy the `addons/blueprints` folder into your project's `addons` folder (make `addons` if there is none).
2. Open the project, go to Project > Project Settings > Plugins and tick Enable beside Blueprints.
3. A **Blueprint** tab appears next to 2D / 3D / Script. Nothing else is needed: there is no autoload, no export
   setting and no engine build.

To update, replace the `addons/blueprints` folder with the new one, then open each Blueprint you want to debug
and save it once (breakpoints follow the line numbers of the saved script).

To remove it, disable the plugin and delete the folder. Your Blueprints stay ordinary `.gd` scripts that run
without it; only `addons/blueprints/runtime/data_table.gd` is needed at run time, and only if you use Data Tables.

This repository is also a Godot project you can open as it is to try the demos and run the tests. Some tests
named in this file (`tests/kits`, `tests/rewrite`, `tests/ports`, `tests/engine`) and the `ports` folder need
other projects and are not in the repository.

## Using it

1. Open this folder as a project (the plugin is already enabled), or copy `addons/blueprints` into your project
   and enable it in Project Settings > Plugins.
2. A **Blueprint** tab appears next to 2D / 3D / Script.
3. Create one: **New Blueprint** in the toolbar, FileSystem right-click > Create New > **Blueprint Class...**,
   or Scene tree right-click > **Attach New Blueprint...**. Pick a starter (or Empty and a parent class), pick a file name.
   Starters are ready-wired graphs: Top-Down / Platformer / 3D Character, Pickup, Trigger Volume, Projectile, Spawner,
   Health Component, Game State and Score HUD. They work alone and together (characters join the `player` group,
   the Game State joins `game_state`); pickups and triggers need a CollisionShape child, the Spawner a scene.
4. Double-clicking a Blueprint `.gd` in the FileSystem opens it in the graph editor.
5. `demo/demo.tscn` + `demo/BP_Demo.gd` is a working example (press Space while it runs).
6. `demo/game/main.tscn` is a small complete game built only from blueprints (player, coins, HUD, spawner): arrow keys to move.

### Editor

| Unreal | Here |
|---|---|
| Right-click graph / Tab | Action menu (search, categories, Context Sensitive toggle) |
| Drag off a pin | Context-filtered action menu; new node is auto-wired |
| My Blueprint | Graphs, Functions (+ Override), Variables, Event Dispatchers, Local Variables |
| Components | Scene nodes under the blueprint's node: drag in for a reference, right-click for signal events |
| Details | Variable / function / node / class settings |
| Compile | Compile button, F7, or Ctrl+S (also runs before Play). Errors appear on nodes and in Compiler Results |
| B / S / D / F / G / O / N / P + click | Branch / Sequence / Delay / ForEach / Gate / DoOnce / IsValid / Print |
| C | Comment box around selection |
| F9 | Toggle a breakpoint on the selected node; the game pauses on that node and the graph jumps to it |
| F10 / F11 / Alt+F11 while paused | Step Over / Step Into / Step Out, one node at a time |
| Ctrl-drag / Alt-drag variable | Get / Set |
| Eye beside a variable | Toggles Instance Editable |
| Typing an Unreal name (BeginPlay, GetActorLocation...) | Finds the Godot node; the row shows the Unreal name it matched |
| Watch values | Class Settings > Show Flow and Values: wired input pins show their last value while the game runs |
| Animated wires | With Show Flow and Values on, dots run along each exec wire the game follows; a node step at a breakpoint animates the wire it took |
| Drag from Scene dock or FileSystem | Node reference / preloaded resource |

The **Generated Code** tab shows the GDScript live; selecting a node jumps to its lines.

### Semantics that match Blueprints

- Pure nodes (no exec pins) are re-evaluated by each consumer; impure outputs are cached in locals.
- `Sequence` does not wait for latent work started by an earlier pin.
- `Delay` ignores re-triggers while pending; `Retriggerable Delay` restarts.
- `Do Once`, `Do N`, `Flip Flop`, `Gate` keep state per instance and per node.
- Latent nodes are rejected inside function graphs.
- **Data**: a Blueprint of type **Data Asset** (New Blueprint > Data Asset, or Class Settings > Blueprint Type) is a
  structure of fields, like an Unreal struct; graphs get Make and Break nodes for it. A **Data Table** (FileSystem >
  Create New > Data Table, or Project > Tools > New Data Table) is a file of named rows of one structure. Double-click it
  to edit it as a grid, with the selected row's full editor beside it; CSV import and export are in its toolbar. In a
  graph, drag the table file in to get a **Get Data Table Row** node, or use the Data Table nodes (Get Rows, Find Rows...).
  `demo/data` has a sample. Tables need `addons/blueprints/runtime/data_table.gd` in the exported game.
- **Convert an existing script**: right-click a `.gd` in the FileSystem dock (or a node with a script in the Scene dock)
  > **Convert to Blueprint...**. Statements become nodes and the result behaves like the source. The original is kept
  as `<name>.gd.orig`. A whole project converts with
  `godot --headless --path <project> res://addons/blueprints/tools/convert_project.tscn -- --only=scripts,scenes`
  (run it, import, run it again; `--only` keeps it to the folders named, so a project's own tests and tools stay scripts).
  What GDScript can say and a plain Blueprint could not is covered by node forms rather than code blocks:
  - a call that must run where its value is read (`a and f()`, `g(x, f())`, `f() if c else h()`) is a call node marked
    **runs in place**: it has no exec pins and is written into the line that reads it;
  - `await f()` is the call node marked **waits for it**; `await signal` is **Wait For**; the usual timer wait is **Wait**.
    A function that waits is marked as one, and its Sequence and loop nodes are the kind that wait for each step;
  - a value whose type is not known (an untyped variable, a helper script loaded by path) is read, set and called
    **by name** (*Get / Set / Call (by name)*), which is what the script does;
  - `match` is a **Switch**; `if x.has_method(m): x.call(m, ...)` is **Call If Present**; `is` / `as` on built-in types are
    **Is / As** nodes; `v.x = ...` on a vector held in a variable or property is a Set node for that member;
  - a lambda becomes a function of the blueprint, with what it captured bound to the reference; handed to `connect`
    (or with optional parameters and captured values) it is a **Lambda** node, which makes a separate Callable each time.
  What still stays as a GDScript node: a `match` arm that binds a name or has a guard, and odd lines the parser does
  not understand. `ports/platformer` is Kenney's 3D platformer starter kit converted this way (110 of 110 lines as
  nodes, plays the same as the original sample for sample).
- **Reuse**: groups of nodes that repeat, inside one Blueprint or across a project's Blueprints, become macros that
  every place then uses. `convert_project.tscn` does this after converting (`--no-reuse` skips it), and
  `godot --headless --path <project> res://addons/blueprints/tools/reuse_project.tscn -- --only=scripts,scenes`
  does it for Blueprints that exist already (`--dry` only reports). Macros used by more than one file go to a macro
  library, `res://shared_macros.gd` (`--library=` names another place); the rest stay in the file that uses them.
  What differs between the places (a number, a text, a variable, a value from outside) is an input pin; a local
  variable the group sets is a local of the macro, and each use says which of its own locals that is. A macro is
  expanded where it is used, so the generated scripts are unchanged and nothing is added at run time. The tool
  checks exactly that: a Blueprint is only changed when the script generated from it afterwards is the script
  generated before (loop variables, which are numbered by node, may get another number); otherwise it is put back.
  Never grouped: Return, Break, Continue, GDScript nodes and nodes that keep state (Do Once, Delay...). A group has
  to save at least 8 nodes over all its uses, with at most 6 input pins and 2 value outputs. A file at the
  library's path that reuse did not make is never written over. Running the tool again is safe; it may find a few
  more groups, since a macro node can itself be part of a group.
- Libraries: set Class Settings > Blueprint Type to **Function Library** (every function becomes static and shows up in
  every blueprint under Function Libraries; needs a Class Name) or **Macro Library** (its macros show up in every
  blueprint under Macros). Both are also offered as starters by New Blueprint.
- Macros (My Blueprint > MACROS) are expanded into each graph that uses them: several exec inputs/outputs,
  latent nodes allowed, and every use keeps its own Do Once / Flip Flop / Delay state.
- Timelines (action menu > Add Timeline...) have float / Vector2 / Vector3 / Color tracks edited in Details,
  with Play, Play from Start, Stop, Reverse, Reverse from End and Set New Time inputs, Update and Finished outputs,
  looping and auto play.
- Event Dispatchers are real Godot signals; custom events and functions are real methods.

## Layout

- `addons/blueprints/core` - types, document model, node registry (reflection-driven), compiler
- `addons/blueprints/editor` - main screen, graph canvas, node widgets, palette
- `addons/blueprints/data/api.json` - built-in types / utility functions / doc blurbs, generated by `tools/gen_api.py`
  from `godot --dump-extension-api-with-docs`
- `addons/blueprints/core/bp_starters.gd` - the starter blueprints offered by New Blueprint
- `tests/test_compile.gd` - headless compiler tests; `tests/test_starters.gd` - builds every starter and plays them; `tests/shot.gd` - in-editor self-test with screenshots

```
godot --headless --path . --script res://tests/test_compile.gd
godot --path . --editor -- --bp-selftest=res://tests/shot.gd        # also shot_input, shot_panels, shot_look, shot_alias, shot_macros, shot_tieins, shot_debug, shot_debugger, shot_interfaces, shot_collapse, shot_starters, shot_libs, shot_import, shot_data, shot_reuse
godot --headless --path . --script res://tests/test_data.gd
godot --headless --path . --script res://tests/test_import.gd
godot --headless --path . --script res://tests/test_libraries.gd
godot --headless --path . --script res://tests/test_interfaces.gd
godot --headless --path . --script res://tests/test_reuse.gd
godot --headless --path . --script res://tests/test_starters.gd
godot --headless --path . --script res://tests/test_game.gd
```

## Extending

Add your own nodes from any plugin or tool script - no compiler changes needed:

```gdscript
const BPRegistry := preload("res://addons/blueprints/core/bp_registry.gd")
BPRegistry.register_template("heal", {"title": "Heal", "cat": "My Game",
	"ins": [["target", "Target", "Node", "self"], ["amount", "Amount", "float", "10.0"]],
	"outs": [], "lines": ["{target}.health += {amount}"]})
```

Feature-by-feature status against Unreal is in PARITY.md; what would need engine changes is in ENGINE_CASE.md.

## Interfaces

A Blueprint Interface is a list of functions that different blueprints agree to have, so one blueprint can
talk to another without knowing its class (a player that calls Interact on whatever it is looking at).

1. New Blueprint Class > Blueprint Interface. Add functions in My Blueprint and give each its inputs and outputs
   in the Details panel. An interface has no code.
2. In a blueprint that should answer, Class Settings > Interfaces > Add Interface. The interface's functions
   are added to My Blueprint to fill in. One you delete is written as an empty function that returns default
   values; one whose inputs or outputs differ from the interface is a compile error. A custom event with the
   function's name also counts.
3. To call, use the nodes under Interface Messages in the action menu. A Message node calls the function if the
   target has it and does nothing otherwise (its outputs then keep their default values). Does Implement
   Interface is true when the target has every function of the interface.

A Message node compiles to what a person would write:

    if is_instance_valid(target) and target.has_method(&"interact"):
        target.interact(self)

GDScript has no interfaces, so "implements" means "has those functions". A hand-written script that defines
them counts as implementing the interface, and there is no interface type for pins or variables.

## Debugging

Set a breakpoint on a node with F9. When the game stops there, the Blueprint editor shows:

- the node it stopped at, and on every wired input pin of that function the value it has now;
- Resume, Step Into, Step Over and Step Out in the toolbar. They move one node at a time: generated lines that
  belong to the same node, or to no node, are passed over;
- a Call Stack list (click a function to see its graph and values; double-click a hand-written script to open it);
- a Watches list: type a variable or an expression, or right-click a node and pick Watch This Value for one of
  its pins. The locals and variables of the selected function are listed under it.

How it works: nothing is added to the generated scripts. The first time the game stops, the editor asks it
(through Godot's own Evaluate request) to load `addons/blueprints/runtime/bp_debug_probe.gd`, which then answers
the editor's questions over the debugger connection. Expressions are worked out with calls that cannot change
anything, so a watch such as `queue_free()` shows no value instead of running.

Blueprint files have their own icon in the FileSystem dock. The plugin sets it on the dock's rows; nothing is
written into the scripts for it.

Limits:

- Each stop leaves one line in the Evaluator tab of Godot's Debugger panel (that request is the only way to
  learn which object a function is running on). The tab is cleared at the next run.
- The probe is loaded at the first stop inside a function that has a `self`. If the first stop of a run is in a
  static function (a function library), the lists stay empty until a later stop; stepping still works.
- A pin whose value needs GDScript that Godot's Expression class cannot read (`a if c else b`, `as`, `$Node`,
  a call that could change something) shows no value.
- The step buttons in Godot's own Debugger panel still step generated lines.
- Step Out from a function the engine calls itself (`_process`, `_ready`) lets the game run on; in one test on a
  large converted project it did not stop again. Use Step Over there.

## Not done yet

See PARITY.md for the full list. The main gap: in-graph animation pose editing
(Godot's AnimationTree editor covers that; blueprints drive it).

## Kits: LimboAI and FlowNodes

When one of these addons is in the project, the plugin adds nodes and starters for it (`addons/blueprints/core/bp_kits.gd`).
Nothing is added to projects that do not have them, and the generated code names the other addon's classes directly.

**LimboAI**

- Starters (New Blueprint): *Behavior Tree Action*, *Behavior Tree Condition*, *State*. A task written as a Blueprint
  is an ordinary LimboAI task: it shows up in the tree editor like any task script.
- Blackboard nodes: *Get / Set / Has Blackboard Var* inside a task or state; *Get / Set Blackboard Var (of a BT Player
  or State)* and *Bind Blackboard Var to My Variable* in an actor. Every blackboard variable the project uses
  (declared in a blackboard plan, or named in a script) also gets its own Get and Set node, typed when a plan says so.
- *Status: Success / Failure / Running* for a task's `_tick`, and *Dispatch State Machine Event*.
- Tree to Blueprint: LimboAI's own *Call Method* task calls any Blueprint function, and BTPlayer / LimboHSM signals
  are events in the actor's graph.

**FlowNodes**

- *Run Flow Graph*, plus one *Run Flow Graph: <name>* node per flow graph in the project, with the graph's inputs
  and outputs as pins. *Host* is the Flow Graph Node that spawned things are added to.
- Flow data nodes: *Make Flow Points*, *Copy Flow Data*, *Point Count*, *Positions*, *Point Transform*,
  *Get Attribute*, *Set Attribute*.
- Starter *Flow Node*: a FlowNodes node written as a Blueprint (*Define Flow Node*, *Get Flow Input*,
  *Set Flow Output*).
- Graph to Blueprint: the *Call Blueprint* flow node calls a function on the host, its parent, a group or the
  nodes in the data, hands it the graph's data and passes on what it returns.
- Project > Tools > *Blueprints: Set Up FlowNodes Bridge* writes that node and a small autoload into
  `res://blueprint_kits`, so FlowNodes finds them and any folder listed under Project Settings > Blueprints >
  Kits > Flow Node Folders. Creating a Flow Node from the starter does this for its folder.

**Parley**

- Starters *Dialogue Action* and *Dialogue Fact*: what a dialogue's Action, Condition and Match nodes run, written
  as Blueprints. Creating one adds it to the project's action or fact store.
- *Run Dialogue*, plus one *Run Dialogue: <name>* node per dialogue file, *Wait for Dialogue to End*, and
  *Get / Set Dialogue Data* (the data facts, actions and the Blueprint that started the dialogue all see).
- Every fact and action in the project's stores is a node (*Dialogue Fact: <name>*, *Run Dialogue Action: <name>*),
  and every character is a value node.
- *Get First Node In Group (from anywhere)* for actions and facts, which are not nodes themselves.

Checked in the Jerk Chicken port: `tests/kits/test_parley.gd` (16 checks, run as a scene), `tests/kits/test_kits.gd` (28 checks, headless) and `tests/kits/shot_kits.gd`
(15 checks, in the editor). Both are copied to `ports/jerk_chicken/bp_kit_test` and run there.

## Hand-built comparison

`tests/rewrite` holds one Jerk Chicken script (`wet_floor_circuit.gd`) rebuilt by hand from nodes instead of converted
line by line: `wet_floor_nodes.gd` is the graph, `build_wet_floor.gd` writes it to the port's `bp_rewrite_test/`,
`test_wet_floor.gd` runs the original, the converted and the hand-built versions side by side (18 checks, bit-exact,
plus timings) and `shot_wet_floor.gd` photographs both in the editor into `tests/out/rewrite`.
