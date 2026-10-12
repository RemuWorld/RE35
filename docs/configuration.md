# Configure RE35

Put one setup call in your plugin manager's configuration callback or your
active Neovim configuration:

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

## Portable tools and local overrides

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

`require('re35').disable()` closes the UI, removes entry/autocommand hooks and
disposes registered extensions. Retained tasks and the API object remain
available.
Use task cancellation explicitly when you intend to stop work. Call setup
again to install the environment entry.

