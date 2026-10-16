# Configure RE35

Configure the Neovim host with one setup call in your plugin manager's
configuration callback or active Neovim configuration:

```lua
require('re35').setup()
```

Choose the [minimal example](../examples/setup-minimal.lua) or the
[advanced example](../examples/setup-advanced.lua), then keep only the options
you want. The advanced example adds a named appearance, a typed command and
its `\xg` binding. It starts no command during setup.

`require('re35')` and the compatible `require('command_tree')` return the same
API object and use one environment. Loading both names does not create
separate instances.

## Navigation, panels and themes

The Neovim defaults can be adjusted independently:

```lua
require('re35').setup({
  navigation = { wrap = true },
  theme = { persist = true },
  window = {
    layout = 'fixed',
    details = { enabled = true, max_height = 6 },
  },
  guidance = { first_run = true },
})
```

Single Up/Down steps wrap at the ends of selectable lists. Set `wrap = false`
to clamp instead. Page jumps, text cursors, input history and scrollable output
do not wrap. These are local host options, separate from portable profiles.
`PageDown` / `PageUp` move by the current visible page capacity in selection
lists, including theme choices and filtered pickers, across all three densities.
Set `keys.page_down` / `keys.page_up` to remap them. Text-editing `Ctrl-d/u`
keeps its existing meaning. Moving a command-search cursor with Left/Right or
Home/End keeps the selected command; a changed ordered result list resets it.

The main panel keeps its width, height and anchor while selection, description
or error content changes. Changing view/scene or resizing the viewport can
change its geometry. Full, Compact and Minimal retain different footprints;
plain Minimal stays one line with horizontal margins. Descriptions and errors
appear below it, with independent Shift-PageUp/Shift-PageDown scrolling. Text
fields keep their editing keys. Set `layout = 'dynamic'` for the previous
content-sized layout, or `details.enabled = false` to keep inline feedback.
Small viewports fall back to inline feedback. Required input/review/source
facts remain visible or the associated effect is refused.

Full places recognized keyboard controls in a separate, fixed-width panel on the
right when the source viewport can fit every key and label. Descriptions wrap;
key combinations stay intact. Narrower viewports keep controls below; custom
help prose remains below. Selection and message changes do not move the main
panel. History and Timeline use the same guide inside the source viewport.
Routine view-save and Settings confirmations use a neutral one-row indicator
immediately above the main panel and disappear after three seconds. They do not
change its title, size or position. With no room above, confirmations use neutral
contextual text, or one native informational notification if a details panel is
unavailable. Storage failures and diagnostics stay inspectable below. Minimal
hides routine status unless its presentation enables it.

| View | Default information density |
| --- | --- |
| Full | Command context, icons, descriptions and a separate shortcut guide when space permits. |
| Compact | Short key/name rows with less chrome and no unused navigation rows. |
| Minimal | A borderless path strip, or a small selected-item neighborhood, with horizontal margins and no routine help/title. |

Partial last pages retain their allocated row slots so navigation does not
resize the main panel. Search adds its query row. Different scenes can use
different footprints: dense text inputs reserve their prompt and editing row;
choice inputs reserve a page of options. Filtering and selection keep the same
choice geometry. Reviews and requested Results content retain the space needed
for their facts.

History reserves a border inside its source window and shows that buffer in an
inset native view. Number/sign columns, folds and text stay inside the frame in
all densities. Leaving History or covering it with another workspace removes
that view and returns to the unchanged original editor window; it does not add
whitespace to the file.
Sources smaller than three rows or columns cannot fit this frame; History
reports the limitation instead of placing a border over the source text.

### Text and color roles

Branches use a leading `▸` and emphasized panel text; leaf commands use ordinary
panel text. The selected item has a complete row highlight in every view.
Keys and navigation icons share an accent. Descriptions, targets and shortcut
labels use normal text; provider/type metadata stays secondary. Unavailable
items are muted, warnings use `DiagnosticWarn`, and errors use `DiagnosticError`.
Colors do not replace the written availability or error message.

RE35 follows the active colorscheme and preserves explicit highlight overrides:

```lua
vim.api.nvim_set_hl(0, 'CommandTreeKey', { link = 'Special' })
vim.api.nvim_set_hl(0, 'CommandTreeMuted', { link = 'NormalFloat' })
```

Apply overrides after loading a theme, or reapply them from a `ColorScheme`
autocommand. Named presentation presets can override their normal, accent,
muted, selected, warning and error roles independently.

Shortcut hints wrap between complete key/description pairs. Details scrolling
is shown separately from command navigation; the key bindings themselves are
unchanged.

The default builtin theme adapter saves confirmed selections to
`vim.fn.stdpath('state') .. '/re35/theme.json'` and restores them at startup.
Preview and cancellation never save. Set `theme.persist = false` to keep theme
changes in the current session, or use `theme.path` for another absolute local
storage filename. If a saved theme cannot load, RE35 keeps the current editor
theme and reports the failure. If saving fails, the confirmed theme remains
applied for the session and the warning stays inspectable. Theme state is
host-local and is not included in portable profile or UI exports.

The builtin Select theme picker shows the pending Light/Dark appearance,
automatic-preview state and confirmation scope above the theme list. `Ctrl-b`
switches Light/Dark; `Ctrl-t` toggles automatic preview without leaving the list.
These controls are available while not filtering; `Esc` first leaves the filter.
Preview starts enabled each time the picker opens. Turning it off restores the
original theme and appearance; selecting another name then has no editor effect
until `Enter` confirms it. Confirmation applies and saves that exact theme and
appearance (or reports why the scheme cannot retain the requested appearance).
`Esc` cancels both drafts and leaves the previously saved choice unchanged.
Changing `:set background=light` or `:set background=dark` outside this picker
affects the editor immediately but does not rewrite saved startup state. Open
Select theme and confirm when you want to save the current appearance.

A supplied `integrations.theme` adapter continues to own its commit, storage
and startup. RE35 does not automatically call a custom adapter's `restore()`.
Remove a custom persistence wrapper only when you intend to adopt the builtin
behavior; loading both storage implementations is unnecessary.
A wrapper's inherited builtin status cannot describe its additional writes,
so it is labeled Adapter owned. Custom adapters can supply their own
`persistence_status()` to explain their actual storage and failure state.

Settings > Getting started (`\sg`) explains controls and storage scope;
`\sv` inspects integrations for the originating buffer. `:checkhealth re35`
is also available. Inspection installs no plugins, executables or servers.
The first manual entry in each editor session offers a brief guide hint;
`guidance.first_run = false` disables that hint. Editor in the workspace
selector suspends command navigation and returns to the native editing window.
From the command tree, the configured Workspaces key (`Ctrl-w` by default) opens
that selector. Its Editor entry explains that the next plain entry resumes
navigation. The Close key (`\` by default) resets navigation for the next entry;
neither action cancels submitted Tasks.

Leave an active workspace before choosing Editor; RE35 keeps its Settings drafts
and resources intact if suspension is refused. The next plain `\` entry resumes
the retained navigation with the current buffer and cursor. Forms and reviews
are rebuilt by selecting their command again; nonsecret drafts remain available,
secrets and Apply confirmations require new input. Native Normal/Insert/Visual
modes remain managed by Neovim. An explicit search, command or workspace request
starts a fresh session instead of resuming the old destination.

If Editor was selected from the workspace selector, resuming returns to that
selector; press Esc to return to the preceding command tree.
Ordinary resumption is silent. If you select a command with remembered inputs,
its new form shows a neutral restoration notice; it still requires a fresh run
decision, and any secrets or Apply confirmations must be entered again.

`require('re35').suspend()` and `require('re35').resume()` also expose the
transitions. `close()` disposes visible or suspended sessions without cancelling
submitted background tasks. If final resource cleanup fails, it returns `false`
with a reason; `state().cleanup_pending` and `cleanup_error` retain the diagnostic
until cleanup can be retried. No live form or input hook is retained for that retry.

## Setup and saved settings

Each `setup(options)` builds from the built-in defaults and the supplied
options. It replaces the previous setup rather than merging another call's
options. Keep declarations together; use `commands` and `bindings` as shown
in the advanced example.

Saved profile settings are then applied:

| Setting | Precedence |
| --- | --- |
| Existing UI fields | Saved `profile.ui` fields override corresponding `window` options. |
| Named presentation | Saved `profile.presentation`, when present, replaces the local `presentation` collection. |
| Command layout | Saved layout bindings and command labels are applied after setup command declarations and bindings. |
| Tool execution | Local `tool_overrides` override the corresponding portable `profile.tools` declaration. |

Changing a local width, selected preset or command path can therefore appear
ineffective when a saved override exists. Inspect Settings and reset the
relevant overrides or edit them there. Appearance resets restore the local
setup defaults; they do not replace your editor colorscheme.
See [presentation presets](presentation-presets.md) for inheritance, scene
overrides and appearance sharing.

By default the profile is read from
`vim.fn.stdpath('state') .. '/command-tree/profile.json'`. That directory name
is retained for existing installations. `profile.path` selects another local
profile file; `profile.path = false` keeps profile changes in memory. Also set
`usage.path = false` and `preferences.path = false` to disable recent-history
and legacy-preference storage.

An explicit `profile.data` must be a version 1 profile. It supplies the profile
at every setup, even if a saved file exists; it does not merge with that file
and setup does not automatically write it. For normal remembered settings,
omit `profile.data`. To share declarations, import through Settings' profile
preview and Apply rather than replacing your saved profile on every startup.

Settings shows Draft until Apply. Successful disk-backed changes show Saved;
`profile.path = false` shows Applied in memory / Session only. A failed write
retains the draft and previously applied settings. If writing succeeds but
host activation fails, Saved / Reload required distinguishes the disk state
from the still-active previous environment. The status screen reports the
storage owner; a theme preview is independent of a Settings draft.

## Updating to 0.3.1

Keep a backup of your existing profile and configuration. Update RE35 without
deleting its state directory or replacing the saved profile. Version 1 profiles
and existing storage paths are retained. Check the loaded version and source as
described in [installation](install.md#check-the-loaded-source).

After updating, check these flows in your normal configuration:

- Confirm your existing command paths, aliases, labels, favorites, quick slots,
  workspace bindings and presentation presets still work. Setup alone should
  not rewrite the saved profile; deliberate Settings Apply is a separate write.
- Find an unavailable command through the tree or command search. Open Details
  (`Ctrl-h`) and inspect its reason. Correct the stated requirement through its
  offered Settings route or your host configuration, return and supply its
  required input, then explicitly execute it. Returning from Settings must not
  run the old command. For a concrete route, follow
  [unavailable backend recovery](file-search.md#recover-an-unavailable-backend).
- In a test project with two configurations and targets, run a recipe as
  Debug/A and let a source error fail it. Change the current Project selection
  to Release/B, open the failed Task's source results and repair the source.
  Return to that Task and open its original-choice review (`v`): it should show
  Debug/A. Explicitly run it, making any required file-save choice. The new Task
  should use Debug/A while Project remains Release/B. See
  [recipe recovery](recovery-workflow.md) for the controls and save choices.
- Start a sufficiently long task, leave its active workspace and select Editor
  in the workspace selector. Edit an unrelated note, then press plain `\` to
  resume RE35. It should return to the selector; Esc returns to the preceding
  tree. Inspect the original Task: the handoff should neither cancel it nor
  launch another copy, and the note should not have been implicitly saved.
- Navigate within one scene and density, show/hide descriptions and errors, and
  scroll details. The main panel should keep its footprint. Resize the terminal:
  panels should fit and reanchor to the new viewport, preserving input and
  selection. Changing scene or density can intentionally change the layout.
- Stage a Settings change, inspect it and Discard. Verify the applied settings
  remain unchanged. Inspect a preview failure with Ctrl-h and return to the same
  input. Storage failures should explain whether the draft remains pending or a
  theme has applied for the session; they should not claim a successful save.
- To test builtin theme persistence, first back up and remove only your custom
  theme adapter and its restore callback from the test configuration. Keep one
  setup call with the builtin defaults. Confirm a theme, exit and restart Neovim;
  it should return without the custom workaround. Previewing and cancelling a
  different theme should not replace the confirmed choice.
- In Select theme, choose Light/Dark with `Ctrl-b` and turn automatic preview
  off with `Ctrl-t`. Browse without changing the editor, cancel to restore the
  original pair, then reopen and confirm the exact theme/appearance. Restart to
  check the saved pair.
- Test `PageUp` / `PageDown` in long selection lists, including Select theme
  before and during filtering. Jumps should follow the visible page capacity
  and stop at the ends; single Up/Down steps should retain your wrap setting.
- In command search, select a later result and move the query caret with
  Left/Right and Home/End. The result should stay selected until the ordered
  result list changes. Repeat in Full, Compact and Minimal.

Use your normal editing workflow as well as these focused cases. Report the
loaded version, relevant setup options, steps and expected/observed behavior.
See [compatibility](compatibility.md) for host support and known limitations.

## Portable tools and local overrides

Portable profiles carry command preferences, project/tool declarations and
recipes. Host setup owns executable paths, local roots, editor adapters and
panel behavior. Importing the same profile into another host preserves its
declarations; it does not transfer live Tasks, windows or editor state. The
[VS Code guide](../hosts/vscode/README.md#portable-profiles-and-local-projects)
describes that host's supported profile sections and local mappings.

The [CMake profile](../examples/cpp-cmake-recipe.json) declares tools, project
choices and a configure/build/test recipe without machine paths. Import it
through Settings, adapt its target to your project, then explicitly run the
recipe. Reading or importing it does not install or start CMake.

The advanced setup optionally reads `RE35_CMAKE` from the local environment
and uses it as the executable override for that profile's `cmake` tool.
Without a portable `tools.cmake` declaration, the override adds no command.
Without the variable, the imported declaration uses `cmake` on PATH.
Local tool/root overrides are excluded from portable profile exports.
See [project recipes](project-recipes.md) for argv, root selection and retry.

## Reconfiguration

RE35 validates a candidate before installing its hooks. Invalid setup raises
an error and keeps the previous environment. Successful replacement closes
the open command UI, replaces its registry and editor hooks, and keeps the
retained Task executor and running jobs. Setup is not a task-cancellation
operation.

A conflicting command path is rejected rather than silently reassigned. The
error identifies the path, existing and requested command IDs, and the setup
entry (`commands[n]` or `bindings[n]`). Choose another path to keep the current
binding, unbind it first, or deliberately use `replace = true`. On the first
setup there is no previous environment to preserve: correct the reported entry
and retry setup. A rejected candidate does not partially activate its commands.

`require('re35').disable()` closes the UI, removes entry/autocommand hooks and
disposes registered extensions. Retained tasks and the API object remain
available.
Use task cancellation explicitly when you intend to stop work. Call setup
again to install the environment entry.

