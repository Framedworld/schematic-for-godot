# Unreal Blueprint parity tracker

Status: **done** (works and is tested), **partial**, **todo**, **engine** (see ENGINE_CASE.md), **n/a** (Godot does it another way).
"Godot tie-in" says how the feature maps onto something Godot already has.

## Class model

| Unreal | Status | Here / Godot tie-in |
|---|---|---|
| Blueprint class extends native class | done | Schematic = `.gd` extending any engine class |
| Blueprint extends Blueprint, override + call parent | done | Parent can be any `class_name` script; Override lists its functions; `Parent:` nodes emit `super` |
| Class defaults | n/a | Exported variables in the Inspector; scene instances override per instance |
| Data-only blueprint | n/a | Inherited scene or Resource with exported variables |
| Components panel | done | Scene tree under the schematic's node (drag in, add signal events) |
| Construction Script | done | Functions > Override > Construction Script. Runs at ready (editor and game) and reruns when an Instance Editable variable changes; gameplay events stay out of the editor |
| Interfaces | done | Schematic Interface asset (New Schematic Class > Schematic Interface): functions with inputs and outputs, no code. Class Settings > Interfaces makes a schematic implement one and adds its functions; one left out is written empty, one with other inputs or outputs is a compile error. Message nodes call a function on any object if it has it; Does Implement Interface tests for all of them. GDScript has no interfaces, so "implements" means "has those functions" (a hand-written script with them counts too), and there is no interface-typed pin |
| Enums | done | My Schematic > Enumerations; compiles to a GDScript `enum`, gives dropdowns on pins and in the Inspector, usable from other scripts |
| Structs | n/a | A schematic that extends Resource with exported variables is the Godot equivalent of a struct / data asset; true value-type structs are an engine language feature |
| Function / macro libraries | done | Class Settings > Schematic Type (or the two library starters). A Function Library compiles every function as `static`, listed in every schematic under Function Libraries; functions marked Pure have no exec pins; its variables are shared by the whole game. A Macro Library's macros are listed in every schematic under Macros > library name; saving the library recompiles the schematics that use them. Double-click a library macro to open it; Expand Node works on it. A function with several outputs returns them as one Array to callers in other schematics. `tests/test_libraries.gd` (23 checks), `tests/shot_libs.gd` (15) |

## Graph language

| Unreal | Status | Notes |
|---|---|---|
| Events, custom events, input action events | done | |
| Functions (inputs, outputs, pure, locals) | done | |
| Macros (multi exec in/out, per-use state, local variables) | done | Locals are separate per use |
| Event dispatchers (call, bind, unbind, assign, event refs) | done | Real Godot signals; Assign creates the bind and a matching custom event together |
| Variables get/set, instance editable, category, tooltip | done | |
| Expose on Spawn | done | Flagged variables become pins on Spawn Scene and are set before the spawned node's Ready; the return pin is typed to the scene's class |
| RepNotify-style variable callbacks | done | Notify On Change calls on_<name>_changed on every set |
| Promote to variable | done | Drag off a data pin > Promote to Variable |
| Branch, Sequence, loops, Switch, Select, Gate, DoOnce, DoN, FlipFlop, MultiGate | done | Also Reverse For Each and For Each (Dictionary) |
| Wildcard operators (Add, Multiply, compare...) with Add pin | done | Result type follows what is connected (Vector3 * float gives Vector3) |
| Format Text | done | Format String: every {name} becomes a pin |
| Increment / Decrement (++ / --) | done | Per numeric variable |
| Keyboard key events | done | Keyboard <Key> nodes; Input Action events remain the recommended route |
| Enum literals | done | Engine class enums and global enums as constants |
| Delay, Retriggerable Delay, timers | done | Set Timer by Event returns a Godot `Timer` |
| Timelines | done | Float/Vector/Color tracks and event tracks. Float tracks have a curve editor in Details: drag keys, double-click to add, right-click or Delete to remove. Vector and colour keys are edited as values |
| Cast (impure and pure), IsValid | done | Right-click a cast > Convert to Pure Cast |
| Make/Break struct, split struct pins | done | Right-click a node > Split Struct Pin for vectors, colours and quaternions (inputs and outputs) |
| Arrays / maps nodes | done | Make Array, Make Dictionary, For Each over both, every `Array`/`Dictionary` method via reflection. Godot has no Set type |
| Math expression | done | Any GDScript expression |
| Reroute, comments | done | |
| Collapse nodes | done | Right-click > Collapse to Macro; boundary wires become macro pins and the generated code is unchanged. Right-click a macro node > Expand Node puts the nodes back (tested: collapse then expand gives identical code). Right-click > Collapse to Function does the same into a function (pure when the selection has no exec pins); it needs one exec wire in and one out, and refuses latent nodes |
| Exec wires that loop back | done | Compiled to a loop, including the Delay-then-wire-back ticking pattern. Not across a Sequence/loop branch that contains a latent node |
| Read another event's output pins, or a node on another branch | done | Those values are kept per instance; you read the last value written |
| Replicated events (Run on Server, Multicast, Run on Owning Client, reliable/unreliable) | done | Custom event > Replicates; compiles to Godot `@rpc` and calls go over the network and run locally |
| Replicated variables | n/a | Godot does this with a MultiplayerSynchronizer node in the scene, not per variable in script |

## Godot tie-ins (things Unreal users expect, mapped to Godot)

| Unreal habit | Status | Godot feature used |
|---|---|---|
| Get All Actors With Tag / Of Class | done | Groups: Get All Nodes In Group, Get First Node In Group |
| Game Instance / singletons | done | Autoload nodes appear as `Autoloads` references |
| Open Level, Quit Game, Set Game Paused | done | SceneTree |
| Spawn Actor | done | Spawn Scene (PackedScene) |
| Destroy Actor | done | Destroy Node (`queue_free`) |
| Move Component To / simple interpolation | done | Tween Property (latent) |
| Custom nodes from plugins (UK2Node) | done | `BPRegistry.register_template()` |
| Every reflected function is a node | done | ClassDB + script classes + built-in types |
| Animation Blueprint | partial | Godot's AnimationTree is the state machine / blend editor; schematics drive it with Travel To Animation State and Get/Set Animation Parameter nodes. No in-graph pose editing |
| Widget Blueprint | n/a | Control scenes + a schematic on the root |
| Level Blueprint | n/a | Schematic on the scene root |

## Editor

| Unreal | Status | Notes |
|---|---|---|
| Context-sensitive action menu, drag-off-pin | done | |
| My Blueprint, Details, Compiler Results, Find in blueprint | done | |
| Undo/redo, copy/paste/duplicate | done | |
| Quick-spawn keys (B, S, D, ...), C for comment | done | |
| Generated code view | done | (Unreal has no equivalent) |
| Node breakpoints, pause on node, stack frames and errors jump to node | done | F9 or right-click; uses Godot's debugger, whose panel shows the schematic's variables and locals while paused |
| Live execution flow | done | Class Settings > Show Flow and Values: nodes light up as they run in the game, and dots run along each exec wire that was followed (the generated trace calls report which node execution came from). A node step at a breakpoint animates the wire it followed too, with no trace calls |
| Graph look: pin shapes, title bars, wires, grid | done | Pentagon exec pins, ring/filled data pins with the nub, grid pins for arrays, pins inside the node body, colour-spill title bars with icons, compact pills for variables and maths, exec wires thicker than data wires, Unreal's spline tangents, 16-unit grid with a rule every 8, zoom text and SCHEMATIC corner mark, comment boxes with a title band |
| Toolbar and editor chrome | done | Asset tab row with Parent class on the right; flat toolbar in Unreal's order (Save, Browse, File, Compile with status icon and options, Find, Class Settings, Class Defaults, Play, Stop); graph bar with back / forward arrows and the Schematic > Graph breadcrumb; "Right-Click to Create New Nodes." hint on an unwired graph; My Schematic has Add and Search. No Diff, Hide Unrelated, Simulation or debug-object picker |
| Class Defaults | done | Toolbar > Class Defaults lists every variable's default value by category. Per-instance values stay in Godot's Inspector |
| Details panel layout | done | Search box, collapsible category bands (state remembered), two-column rows with a divider and hover highlight. No per-row reset-to-default arrow yet |
| Action menu and panel look | done | Icons tinted by kind (blue function, green pure, red event, type colour for variables); My Schematic shows each variable's type and an eye that toggles Instance Editable |
| Values shown on pins | done | While the game is stopped at a node, every wired input pin of the function it is stopped in shows its value (read from the paused game, nothing added to the generated code). With Class Settings > Show Flow and Values on, pins also show the last value they received while the game runs |
| Step per node | done | Step Into / Step Over / Step Out in the Schematic toolbar and their keys (F11, F10, Alt+F11) move one node at a time: generated lines that belong to the same node, or to no node, are passed over. The buttons in Godot's Debugger panel still step generated lines |
| Call Stack and Watch windows | done | Shown under the graph while the game is paused. Call Stack lists the running functions with the node each is at; clicking one shows its graph and values. Watches holds expressions typed in and pins added with right-click > Watch This Value, plus the locals and variables of the selected function. No debug-object picker |
| Unreal names in the action menu | done | About 200 Unreal node names (BeginPlay, Tick, Get Actor Location, Set Timer by Event, Get All Actors with Tag...) find the Godot node; the hit shows which Unreal name matched. Table in `core/sc_aliases.gd` |
| Structs, Data Assets, Data Tables | done | Schematic Type > Data Asset: every variable is an exported field of a Resource class; Make / Break nodes with the structure's defaults and typed pins. `SchematicDataTable` (addon runtime class): named rows of one structure in one `.tres`, in order. Table editor in the Schematic main screen: grid with inline text / number / checkbox / enum cells, Row Editor for every other field type, add / duplicate / delete / move / rename, search, undo, CSV import and export, saves on every change. Get Data Table Row node (Row Found / Row Not Found, Out Row typed by the table, row names listed in Details); the table's read functions are pure nodes. Changing the structure updates every row, because rows are instances of it. `tests/test_data.gd` (26 checks), `tests/shot_data.gd` (28) |
| Convert GDScript to Blueprint | done | FileSystem / Scene dock > Convert to Schematic, or `tools/convert_project.tscn` for a whole project. Members, signals, engine callbacks, functions, if / for / while, assignments (including `position.y += ...`), calls, operators become nodes; types come from declarations, the scene that uses the script (node classes for `$Path`, parameter types of connected signals) and the script's own assignments. What can't be nodes stays as a GDScript code node and is listed in the report. Declarations are written back as the script wrote them (untyped stays untyped, `:=` stays `:=`). Tested by difference: `tests/test_import.gd` and `tests/test_convert.gd` run sample scripts as written and converted and compare their state, their interface and every literal in them; `tests/stress_convert.gd` does the checks that need no run over any folder of scripts; Kenney's starter kit (7 scripts) renders the same 560 frames, to the pixel, before and after |
| Starter blueprints | done | New Schematic offers 14 ready-wired starters beside Empty (characters, pickup, trigger, projectile, spawner, health, game state, HUD); attaching to a node offers only the ones made for it. `tests/test_starters.gd` builds each one and plays them headless (40 checks) |
| Find in all blueprints | done | Toolbar > Find in Schematics; opens the file and jumps to the node |
| Wire double-click reroute, Alt+click to break a wire, Align Left / Top | done | |
| Node comment bubbles | done | Right-click > Node Comment, or the Comment row in Details; drawn in a bubble above the node |
| Greyed starter events | done | A built-in event with nothing wired to it is drawn faded with Unreal's "This node is disabled" note |
| Hide Unrelated | done | Toolbar toggle: fades every node not linked to the selection |
| Reset to default arrows | done | Yellow arrow on default-value rows, shown only when the value was changed |
| Unreal-shaped title icons | done | Event diamond, italic f, branch fork, sequence, loop, cast and gate glyphs drawn as vectors |
| Bookmarks | done | Bookmark menu on the graph bar: saves graph, position and zoom in the schematic file |
| Distribute / straighten | todo | |
| Blueprint diff | n/a | The file is text: `git diff` shows code and graph changes |
| Thumbnail / distinct file icon | done | Schematic files have their own icon in the FileSystem dock (tree and list view; not on the large thumbnails). The plugin sets it on the dock's rows; nothing is written into the scripts |

## Next passes (in order)

1. (done) Node breakpoints, pause-on-node, live execution flow, values on pins while paused, call stack, watches, stepping by node.
2. (done) Construction Script, Notify On Change, Expose on Spawn.
3. (done) Collapse to Macro, MultiGate, split struct pins, schematic enums.
4. (done) Exec wires that loop back, reading other events' outputs, macro-local variables.
5. (mostly done) Find in all schematics, alignment, wire gestures, comment bubbles. Bookmarks done.
6. (done) `@rpc` custom events; AnimationTree nodes.

## Checked against the Unreal 5.8 install (not from memory)

Read from the engine's own graph editor settings and Schematic node classes on this machine:

- Pin colours: bool, int, float, string, name, vector, rotator, transform, object, struct, delegate, wildcard and enum all match Unreal's defaults.
- Wire thickness: Unreal draws exec wires 2.5 and data wires 1.5. Matched in proportion (3.0 and 1.9) by narrowing data wires after Godot lays them out.
- Wire shape: Unreal's spline tangent rule (forward range 1000, backward range 200 with factors 2 and 1.5) is used as is.
- Grid: line, rule and centre colours and the rule period of 8 come from Unreal's style values.
- Node classes still without an equivalent here: Set Fields In Struct, Get Class Defaults, Clear Delegate, touch events, Class casts, Bitmask literal, enum iteration, (Since added: Expand Node, collapsed graphs, macro locals, Make Dictionary, async load, Assign, input axis nodes, pure casts.)
- Standard macros still missing: For Loop With Break, For Each With Break (Break Loop node covers the use), Swap, Do Once MultiInput.

On 2026-11-11 the running Unreal 5.8 Blueprint editor was captured (blank Actor blueprint with Print String, Branch and Multiply nodes added) and compared with screenshots of this plugin. Matched from that: toolbar order and flat style, tab row above the toolbar, graph breadcrumb bar, the empty-graph hint, neutral grey maths pills, the red square on event titles, the outline style of inline value boxes, and action-menu search results grouped under their category.

## How the editor is tested

Control of the Godot and Unreal windows through the desktop was declined, so the editor is exercised from inside by
sending real mouse-button, mouse-motion and key events through Godot's input pipeline:

- `tests/shot_input.gd` (18 checks): right-click menu, typing a search, Enter, dragging wires pin-to-pin and
  pin-to-empty, typing into a pin's value box, B + click, select + Delete, dragging a node, double-click and Alt+click
  on wires, right-click node menu.
- `tests/shot_panels.gd` (17 checks): adding a variable, renaming it, the type picker, Instance Editable, default
  value, Ctrl-dragging it into the graph, the Compile button, adding a function, undo, and the New Schematic flow up to
  a file on disk that opens and compiles.

`tests/shot_look.gd` saves full-resolution crops of the canvas, the action menu and the panels to `tests/out/look_*.png`.
Those images were reviewed against Unreal's style values during the restyle; they are still images, not a side-by-side
with Unreal running.

The two input-driven suites need the editor window in front with the real mouse cursor over it: Godot only gives a
control keyboard focus on click while the cursor is over the window, and popups close when the window is not in
front. Each suite logs an `environment:` line first, so a failure caused by someone using the machine is obvious.
They now ask for the foreground and tell the window the mouse has entered before sending events, which covers a
cursor on another monitor. With the Windows lock screen up nothing can take keyboard focus, and the one check that
needs a real key press on the canvas (Delete removes the selected node) fails; the log says so.

Two limits. Godot's Tree only accepts a click on a row button when the real OS cursor is over it, so the + buttons in
My Schematic are checked for position and then fired by signal. And this is real input handling, not a person looking
at the screen: visual polish, the native file dialog and the Scene / FileSystem dock menus are unverified by eye.

## Proof: a complete game made only of schematics

`demo/game` (generated by `tests/make_game.gd`) is four schematics and two scenes: a player moved with the arrow keys,
coins spawned in a loop with Expose-on-Spawn values, a coin that casts what touched it and calls a function on the
player, and a HUD that finds the player by group and binds to its event dispatcher. `tests/test_game.gd` plays it
headless with simulated input and physics: 9 of 9 checks pass (spawning, input movement, overlap, cross-schematic
call, dispatcher to HUD, destroy). Open `demo/game/main.tscn` and press Play to try it.

## Where this stands

Done and tested: the class model, the graph language (events, functions, macros, dispatchers, timelines, flow control,
wildcard math, enums, split pins), Godot tie-ins, debugging with breakpoints and live flow, replication of events, and
the editor workflow. A complete sample game is built from schematics only.

Still open, all minor: distribute / straighten,
a few rarely used node classes (listed above), and two-machine testing of replicated events.

Needs an engine change: true structs and interface-typed pins (language features). See ENGINE_CASE.md.
