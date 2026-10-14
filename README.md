# RE35

RE35 is a command environment that connects discovery, input, execution,
results and recovery. A recipe can fail, lead you to a source location or tool
setting, and run again with its original configuration and target.

Its editor-independent Lua core defines shared command, document, profile and
workflow semantics. Hosts connect those definitions to their UI, editor services
and tools. Portable profiles carry user declarations; supported operations and
live task history depend on the host.

**Version 0.2.0.** Neovim is the primary host.
The optional VS Code desktop development host supports a defined subset of
document and project workflows. See [command coverage](docs/command-coverage.md)
and [compatibility](docs/compatibility.md) for supported scope and limitations.

## Neovim

Requires **Neovim 0.11+** on Windows or Linux. No other plugin is required.
Press `\` to open RE35; ordinary Normal-mode keys remain available before entry.

- Navigate a command tree or search commands, with aliases, favorites and quick slots.
- Enter typed arguments with validation, completion and relevant command status.
- Find files and search project text through the builtin provider or optional ripgrep and Telescope integrations.
- Search the current document and review literal replacement with native Undo.
- Use History, Project, Tasks, Results and Settings workspaces.
- Configure sequential build/test/run recipes, inspect outcomes and review a retry using the original choices.
- Edit portable profiles, custom commands and workspace bindings.
- Create, edit and share appearance presets, including Full, Compact and Minimal views.

0.2.0 adds remembered themes, consistent list navigation, clearer
storage/error feedback and a stable command panel with separate details.

## Install

With lazy.nvim, pin the version you want to use:

```lua
{
  "RemuWorld/RE35",
  tag = "v0.2.0",
  config = function()
    require("re35").setup()
  end,
}
```

Use `branch = "main"` in place of the tag only to follow ongoing development.
See [installation](docs/install.md) for manual installs, source snapshots and
version checks, and [configuration](docs/configuration.md) for setup options.

## Usage

After opening RE35 with `\`:

| Keys | Action |
| --- | --- |
| `/` | Search commands |
| `f f` / `f g` | Find files / search project text |
| `e f` / `e r` | Search the current document / review literal replacement |
| `r r` | Run the selected Project recipe |
| `h` | Open History |
| `m` | Choose a workspace |
| `s` | Open Settings |
| `s g` / `s v` | Getting started / integration diagnostics |
| `↑` / `↓` | Select a tree item |
| Enter / `→` | Enter the selected item |
| Esc / Backspace / `←` | Go back |
| `?` | Change view density |

Text fields retain their editing keys. Tab offers completion and F1 changes
density. Ctrl-h opens a command's details; `s` there shows status and `r`
rechecks requirements.
Ctrl-h also inspects preview errors without losing an input. Shift-PageUp and
Shift-PageDown scroll the independent details panel. Select Editor in Workspaces
to return to native editing. See [configuration](docs/configuration.md) for theme
persistence, list wrapping and panel options available since 0.2.0.

## Other integrations

The [VS Code development host](hosts/vscode/README.md) supports document
search/replacement, portable profile import, local project selection, sequential
recipes, cancellation, owned Results, original-task recovery, saved-file search
and shared presentation preferences. Native controls report unsupported
appearance options explicitly.

The [portable core](docs/portable-core.md) can also be embedded through an
optional C ABI. C++ and C# console examples demonstrate the integration boundary.

## Documentation

| Guide | Contents |
| --- | --- |
| [Installation](docs/install.md) / [Configuration](docs/configuration.md) | Setup and source selection |
| [Neovim help](doc/command-environment.txt) / [Integrations](doc/command-environment-integrations.txt) | Keys, workspaces and optional adapters |
| [File search](docs/file-search.md) / [Recipes](docs/project-recipes.md) / [Recovery](docs/recovery-workflow.md) | Find, run and retry work |
| [UI settings](docs/ui-settings.md) / [Presentation presets](docs/presentation-presets.md) | Customize and share appearance |
| [Documentation index](docs/README.md) | User guides, architecture and integration contracts |
| [Changelog](CHANGELOG.md) / [Roadmap](docs/roadmap.md) / [Contributing](CONTRIBUTING.md) | Release scope and future work |

Licensed under [Apache License 2.0](LICENSE).
