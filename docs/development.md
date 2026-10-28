# Develop RE35

The current product target is ordinary desktop VS Code editing. The source also
retains an older Neovim host and core-embedding examples; they are not additional
current editor support targets.

## Source map

| Location | Responsibility |
| --- | --- |
| `lua/command_environment/core` | Shared command, document, profile and workflow data/validation |
| `hosts/vscode` | Input ownership, native forms, live editor effects, persistence, tasks and recovery |
| `hosts/vscode/contextual-*` | Pure bounded rule parser, editor connection, definition storage and authoring |
| `native` | Lua C ABI bridge, stdio transport and optional process-scope helper |
| `tests` / `hosts/vscode/test` | Repeatable contracts, controlled seams and actual-host fixtures |
| `tools` | Explicit source inventory and VSIX packaging |
| `lua/command_tree` / `lua/re35.lua` | Retained legacy Neovim implementation |

Discovery, direct invocation, compositions and input rules share semantic IDs.
Core modules return data; the host owns documents, permission, review, actual
completion and external resources. UI appearance must not change execution
meaning. See [command API](reference/command-api.md) and
[core contracts](reference/core-contracts.md).

## Build the helper

Use an existing C11/C++17 toolchain and CMake:

```sh
cmake -S . -B build
cmake --build build --target ce_stdio ce_lua_console
```

The loader requires a compatible **Lua 5.1 C ABI** runtime, such as LuaJIT or a
compatible `lua51.dll`; Lua 5.4 is not interchangeable. The bridge library belongs
beside the helper or on the native loader's search path. Core sources and the
helper must come from the same revision; `native/core_modules.def` is their
explicit module inventory. Nothing is downloaded by setup.

Launch an isolated Extension Development Host:

```sh
code --extensionDevelopmentPath=/absolute/RE35/hosts/vscode
```

Configure existing absolute local paths for `re35.helperPath`, `re35.luaRuntime`
and `re35.corePath`. The last points to this checkout's `lua` directory. These
are source-development overrides; platform VSIX users normally leave them empty.
Do not use a personal editing profile as a test fixture.

## Validate a change

Run checks for the affected owner and its meaningful failure boundaries. Pure
tests do not replace actual editor, process or input evidence. Examples:

```sh
node hosts/vscode/test/contextual-grammar.js
node hosts/vscode/test/contextual-input-connection.js
node hosts/vscode/test/contextual-library.js
node hosts/vscode/test/contextual-ui.js
python tests/acceptance/run_vscode_host.py --help
python tools/package_vscode.py --help
```

The actual-host runner snapshots sources and uses separate extension/user
directories. Programmatic `type` calls are API evidence, not physical keyboard
or OS IME evidence. Group installed UI checks after implementation and record
failed or unperformed cases explicitly. Independent use from documentation is
a separate usability check.

## Package and review

`tools/source-files.json` is the public source allowlist. Add required production
files and repeatable tests deliberately. Local plans, raw feedback,
generated reports, machine paths, caches and development binaries do not belong
in it. VSIX packaging uses the reviewed sources and explicit native inputs.
Use a freshly built package when validating a release; a package hash identifies
the tested bytes, not the current working tree.

Keep user instructions here and in the user guides. Keep private planning and
generated validation history outside the public docs. See
[Contributing](../CONTRIBUTING.md) for changes and reports.
