# Schematic project code review

## Review fixes

| Priority | Finding | Resolution and regression |
| --- | --- | --- |
| P1 | Orchestrator could overwrite a hand-written script or map two graphs to the same destination. | Import skips colliding sources and existing destinations with different bytes. Identical generated output can repair references on a repeat run. The bulk-tool test checks output and references in dry and write modes. |
| P1 | Macro reuse could restore stale generated code over hand edits. | Reuse checks the script on disk, checks again before writing, and retains shared macros still referenced on disk. The reuse suite changes generated code and verifies its exact bytes and shared macro survive. |
| P1 | Bulk commands could edit ignored folders and nested Godot projects. | Conversion, reuse, Orchestrator import, and editor file discovery check directory boundaries. A directly named subfolder also inherits its ancestors’ exclusions. The bulk-tool suite exercises both entry paths. |
| P1 | A line such as `#~ hello` in a GDScript string could prevent its graph from reopening. | The reader locates and validates the trailing graph region before decoding JSON. Drift tests include a quoted graph header, payload, and terminator, plus a genuine legacy Blueprint footer. |
| P1 | The code fingerprint ignored meaningful whitespace inside multiline strings. | New fingerprints preserve literal spaces, tabs, and line endings. For older fingerprints on multiline scripts, the embedded graph supplies the comparison. Drift tests cover deleting a literal space and changing an internal CRLF. |
| P2 | CSV import rounded integer identifiers above 2^53. | Integer-form cells parse directly as integers. The data-table suite exports and imports large positive and negative 64-bit values. |
| P2 | Macro reuse could accept a change inside a string as a loop-variable rename. | The comparison requires a numbered loop declaration and a matching use in scope. Tests cover quoted and multiline strings, comments, member access, dictionary keys, nested loops, and uses after dedent. |
| P2 | An open intermediate macro library could leave downstream scripts stale. | After saving an open intermediate library, recompilation continues to its consumers. The native editor test saves the inner library twice and reads the generated consumer from disk with the intermediate tab closed and open. |
| P2 | Four suites could print failed assertions and return success to CI. | Code-link, conversion, sync, and re-import now return exit code 1 on failure. An injected failing check in isolated copies of each suite exercised all eight engine/suite combinations. |
| P2 | Re-import could pass its assertions and crash during shutdown on Godot 4.6. | The failure was isolated to temporary validation of the `classes.gd` fixture. Replacing the disposable script’s compiled bytecode after validation released its inner-class and static script references. Both engines completed the full re-import suite with 450 passing checks and clean shutdown. |

## Rescan, shutdown and conversion follow-up

| Check | Godot 4.6 | Godot 4.7.1 |
| --- | --- | --- |
| Headless suites | 18/18 passed | 18/18 passed |
| Identical generated text and graph structure after re-import | 71/71 each | 71/71 each |
| Converter stress | 30 scripts, 1,375 statement lines, zero findings | Same |
| Native editor | Drift and live debugger passed twice with 34 stale scripts indexed, data tables 29/29, alias search 28/28 | Drift and live debugger passed, data tables 29/29, alias search 28/28 |

The old drift setup deleted scripts that Godot 4.6 was still reading to build its help index. With 34 stale scripts indexed, this produced missing-file errors and a Windows access violation. Waiting for the filesystem scan alone still reproduced the crash. The test now creates directories unique to each run and waits for rescans before removing only its own fixtures. Both engines preserved all 34 stale scripts. The live debugger ran against a private copy of the demo. Its shipped scene and script remained byte-identical after each run. Godot starts its documentation worker after the filesystem scan completes. [Godot 4.6 documentation loader](https://github.com/godotengine/godot/blob/4.6-stable/editor/doc/editor_help.cpp#L2940-L2988)

Cold editor runs retained 14 script resources even with the plugin disabled. Adding the `classes.gd` fixture and its base to the demo-only control reproduced the warning. The raw converter fixtures now have a `.gdignore` marker so editor startup skips indexing them. The headless converter, re-import and stress suites still read and exercise those fixtures directly. The final native runs logged no ObjectDB, resource or GPU texture leak warnings.

In the headless suites, the waiting fixture now finishes its nested coroutines before teardown. Delay and Retriggerable Delay now capture the timeout signal before suspending, so destroying a projectile on impact releases its temporary timer. Verbose Godot 4.6 still reports an unclaimed `timeout` StringName in the starter suite and `Node` in the editor. Both diagnostics also occur in minimal projects without Schematic.

The six graph differences came from three fixtures in two line-ending formats. The compiler now preserves a bare typed `Callable` and keeps the fallback return for partial branches and matches. Nested struct assignments keep their assignable member path and compound operator. The fixed-point suite returns a failing status for a mismatch, a skipped input or an empty selection. Against the previous converter, the same test caught the nested-struct graph changes and exited 1 on both engines.

## Verification immediately after the first ten fixes

The same checks ran on stock Windows builds of Godot 4.6 and 4.7.1 in separate project copies.

| Check | Godot 4.6 | Godot 4.7.1 |
| --- | --- | --- |
| Headless test scripts | 18 completed, all exit codes 0 | 18 completed, all exit codes 0 |
| Re-import | 450 checks passed, clean shutdown | 450 checks passed, clean shutdown |
| Converter stress | 30 scripts, 1,375 statement lines, zero findings, clean shutdown | Same |
| Native editor | Save conflicts and library propagation passed, data tables 29/29, alias search 28/28 | Same |
| Injected failure in four CI suites | Each returned 1 | Each returned 1 |
| Bulk converter CLI | Respected nested and ignored directories, overlapping scopes, and hand edits on repeat conversion | Same |

The fixed-point diagnostic generated identical GDScript for all 71 inputs. Six graphs changed structure on their second conversion and all 71 stabilized by the third, matching the original review. The 4.6 conversion and starter suites still logged ObjectDB warnings on exit. Native 4.6 drift and data-table runs also logged resource warnings. An initial 4.6 drift run crashed during a filesystem rescan in a reused test directory. A fresh copy with the checkout’s scratch-folder exclusions passed the complete editor run, including the live debugger, and exited successfully.

## Bugs fixed in the editor pass

- Closing a dirty graph after a write failure now leaves the document open with its changes. This also covers the overwrite-and-close dialog. A native regression test directs the save into a missing directory.
- Switching between documents with identical graph and node IDs clears selection and live wire pulses and restores the destination viewport. Selected nodes in one file no longer become Delete targets in another.
- Data-table undo and redo save the resource that owns the action. The native test switches to another table, undoes a cell edit, and reloads the original table from disk.
- Leaving an untouched numeric pin no longer commits a rounded display value. Submitting an integer preserves all 64 bits and commits once. The editor test covers both paths.
- Search results keep the tooltip explaining which Unreal alias matched. Compact string fields have a bounded width and still scroll while editing, so a long default no longer dictates the width of a Print node.

## Original review coverage

The review covered the first-party Godot plugin and its editor, parser, compiler, graph persistence, re-import, reuse, kit integration, runtime data tables, command-line tools, test harnesses, and bundled demos. The review used isolated copies for every destructive reproduction.

- **Godot 4.6 and 4.7.1** each ran all 17 tracked headless test scripts. Sixteen suites reported zero failed checks per engine. The fixed-point diagnostic produced identical GDScript in all 71 cases on each engine. Six cases changed graph structure on a second conversion, covering `classes`, `lambdas_inline`, and `values` in both line-ending formats.
- **Converter stress on Godot 4.7.1** reported zero findings across 30 loadable fixture scripts and 1,375 statement lines. The stress and re-import runs also reported 17 ObjectDB instances and nine resources still live at process exit.
- **Native Godot 4.7.1 editor checks** covered category-colored title bars in normal and selected states, file switching, graph zoom, comments, live-value labels, action search, curve editing, bookmarks, table undo, and save-conflict handling. Data-table and alias suites reported 29 and 28 passes respectively. The drift suite reported zero failures, including retaining the document after a failed write. Its rescan also logged a failed SVG resource load.
- The third-party projects under `ports/`, exported builds, and live multiplayer debugger sessions were outside the executed test matrix. The checked-in demo videos show the earlier interface. The README editor and search stills show the revised UI.
