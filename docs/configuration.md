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
unchanged. Descriptions and required facts prefer word boundaries, including
spaced Korean units. Only tokens wider than a whole row use emergency wrapping;
long paths can break at path separators. Common combining and emoji sequences
stay together. This is not full language-specific Unicode line breaking.
Required-fact measurement and drawing use the same rule after resizing.

The default builtin theme adapter saves confirmed selections to
`vim.fn.stdpath('state') .. '/re35/theme.json'` and restores them at startup.
Preview and cancellation never save. Set `theme.persist = false` to keep theme
changes in the current session, or use `theme.path` for another absolute local
storage filename. If a saved theme cannot load, RE35 keeps the current editor
theme and reports the failure. If saving fails, the confirmed theme remains
applied for the session and the warning stays inspectable. Theme state is
host-local and is not included in portable profile or UI exports.

The builtin Select theme picker separates Light and Dark choices. A theme that
supports both appears in both lists; a Light-only theme such as `peachpuff` does
not normally appear under Dark. `Ctrl-b` switches the list and requested
appearance; `Ctrl-t` toggles automatic preview without leaving the list.
These controls are available while not filtering; `Esc` first leaves the filter.
The picker shows appearance, preview state and Save on confirm / Session only
scope, including in Minimal. Moving the filter caret or editing a filter without
changing the selected theme/appearance does not reload that preview.
Preview starts enabled each time the picker opens. Turning it off restores the
original theme and appearance; selecting another name then has no editor effect
until `Enter` confirms it. Confirmation applies and saves that exact theme and
appearance. Classification is advisory: if the live theme differs from its cached
observation, RE35 corrects the list, restores the previous theme/appearance and
leaves startup storage unchanged. Expected conditions use a short explanation;
`Ctrl-h` opens full details without losing the input. Actual loading or restoration
errors remain errors.
`Esc` cancels both drafts and leaves the previously saved choice unchanged.
Changing `:set background=light` or `:set background=dark` outside this picker
affects the editor immediately but does not rewrite saved startup state. Open
Select theme and confirm when you want to save the current appearance.

Classification starts when the picker opens and runs asynchronously in separate,
clean Neovim processes. It checks the actual `Normal` background and resulting
`background` option for each requested appearance. The list fills while Checking
is shown. Results are
cached at `vim.fn.stdpath('cache') .. '/re35/theme-catalog-v1.json'`; unchanged
observations are reused, new/changed themes are inspected and removed themes are
pruned. Transient process failures are retried on reopening. This cache is separate
from the saved startup choice and portable profiles.

Workers execute installed theme code using the runtime paths and bounded relevant
global options, without running your init, copying Lua setup-module state or
inheriting your `ColorScheme` handlers. Consequently, setup-dependent themes may
differ from the live editor. Inspection covers at most 256 themes with a two-second
limit per appearance; it installs nothing. An appearance is listed only after
successful classification; pending, failed, transparent or unspecified observations
do not become choices. Status reports unfinished
or unclassified entries; `Ctrl-h` explains classification problems. A custom theme
adapter or direct Neovim theme selection remains available for themes this default
classifier cannot represent.

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
`guidance.first_run = false` disables that hint. The entry key (`\`), root Back
and Workspaces > Editor return to editing and preserve safe navigation for the
next plain entry. `Ctrl-c` or `require('re35').close()` explicitly reset it.
Neither operation cancels submitted Tasks.

Resume captures the current buffer and cursor. Forms and reviews are rebuilt
by selecting their command again; nonsecret drafts remain available, while
secrets and Apply confirmations require new input. Workspace frames and their
resources are closed, and navigation returns to the workspace selector with
that workspace selected. Extension workspace drafts are not retained unless
represented by their declared scalar memory. Apply or discard changed Settings
drafts before leaving. Native Normal/Insert/Visual behavior remains Neovim's.
An explicit search, command or workspace request starts a fresh session;
`invoke()` instead reuses parked navigation with a fresh source context.

Ordinary resumption is silent. Restoring nonsecret command inputs shows a
neutral notice in that command's new form. `leave()` and `resume()` expose these
ordinary transitions. The older `suspend()` API remains strict and refuses live
workspace stacks. `state()` distinguishes active, suspended and surface_attached.
If final cleanup fails, `close()` returns false with a reason and retains
`cleanup_pending` / `cleanup_error` for a retry, without live input authority.

## Commands from editor keys

No editing keys are installed by default. Assign keys explicitly in Neovim:

```lua
require('re35').setup({
  editor_keys = {
    { key = '<F6>', command = 'search.document', args = { query = 'TODO' } },
    { key = '<F7>', command = 'project.run_selected_recipe', mode = 'n' },
  },
})
```

`mode` defaults to `n`; `x`, `i` or a list of those modes are also supported.
Bindings are global host configuration, separate from portable profiles and
command tree locations. Missing commands remain declared and report why they
cannot run. Loaded buffer-local conflicts, duplicate/prefix bindings and entry
boundary conflicts reject setup while preserving the previous environment.
An existing exact global map requires `replace = true`; prefix conflicts cannot
be replaced. Disable restores displaced maps only if RE35 still owns the slot.
Later plugin replacements are respected. A later buffer-local map takes
precedence; inspect current ownership with `editor_keys()` or `:checkhealth re35`.

The equivalent programmatic intent is data only:

```lua
require('re35').invoke({ command = 'search.document', args = { query = 'TODO' } })
```

Use an exact stable ID, not an alias, tree path or transient imported map/Ex ID.
Arguments are copied and validated; unknown fields are rejected. Missing inputs
open the existing form. Availability, source checks and required reviews remain
in force; putting `apply = true` in a keybinding is not a reviewed submission.
Finish or leave an active RE35 surface before invoking an editing shortcut.
The VS Code host accepts the same intent through `re35.execute`; its actual key
notation and supported commands belong to that host, as described in its
[setup guide](../hosts/vscode/README.md).

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

## Updating to 0.4.0

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
- Let the initial theme classification finish, then reopen the picker. Confirm
  that cached choices return, Light-only schemes stay out of Dark, and both-mode
  schemes appear in both. Type and erase a filter rapidly; unchanged selections
  should not repeatedly apply a theme. Inspect any classification problem with
  Ctrl-h and return to the same picker.
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

`require('re35').disable()` closes the UI, removes entry/autocommand hooks and explicitly assigned editing keys, and
disposes registered extensions. Retained tasks and the API object remain
available.
Use task cancellation explicitly when you intend to stop work. Call setup
again to install the environment entry.

