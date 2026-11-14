# Does this need to be more than a plugin?

Short answer so far: **no for the language and workflow, yes for a handful of polish items.** Nothing below
blocks making a game. Each entry says what the plugin cannot do, what the engine patch would be, and how big it is.

| # | Gap | Why a plugin can't | Engine change | Size | Worth it? |
|---|---|---|---|---|---|
| 1 | Blueprint files look like any `.gd` in the FileSystem dock | Done in the plugin: it sets its own icon on the dock's rows each time the dock rebuilds them. An `@icon` line in the script does not do it: `EditorFileSystem::_update_file_icon_path` replaces a script's own icon path with its type's icon, so the dock never sees it (tested on this build) | Keep the script's own icon path in `_update_file_icon_path`, or a per-file icon hook | ~5 lines | No - only so the plugin need not touch the dock's rows |
| 2 | Show values on pins while paused | Done in the plugin: the paused game is asked for its stack and values over the debugger connection. To learn which object a function is running on, the plugin has to use the debugger's Evaluate request, and each use leaves a line in the Debugger panel's Evaluator tab (cleared at the next run) | Let an Evaluate request ask for its result not to be listed, or expose stack frames on `EditorDebuggerSession` | ~20 lines | Only to keep the Evaluator tab clean |
| 3 | Wire styling: animated flow along a wire (the moving bubbles while debugging) | Done in the plugin: a control inside `GraphEdit`'s wire layer draws the glow and the moving dots along the same curve `get_connection_line` gives the wire. Thicker exec wires, Unreal's spline shape and the pin shapes were already done there | None needed | - | No |
| 4 | True struct value types | GDScript has no structs | Language feature (upstream proposal exists) | Large | No - use Resource blueprints |
| 5 | Interface-typed pins and variables | Blueprint Interfaces are done in the plugin as "has these functions" (see PARITY.md). GDScript has no interface type, so a pin cannot be typed as an interface and nothing checks a call at compile time | Language feature (traits are planned upstream) | Large | No |
| 6 | Blueprint opens in the Script editor from some paths | Tested: FileSystem double-click and breakpoint hits stay in the Blueprint editor. Not yet tested: double-clicking an entry in Debugger > Errors | Route through `EditorNode::edit_resource` or add a plugin veto | ~20 lines | Probably not needed |

Items 2 and 6 were tested against a live debug session; the Errors-panel path in item 6 is the one thing still unchecked.
