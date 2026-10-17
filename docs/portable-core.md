# Portable command model and native bridge

RE35 keeps command data and shared validation in `lua/command_environment/core`.
Those modules have no editor, filesystem or process dependency. Hosts own input,
rendering, persistence, source identity and execution. Neovim uses them in process;
the optional VS Code host uses the native transport. The portable Engine is a
bounded request model rather than the complete Neovim Session.

`core.command_descriptor` shares argument structure checks between native
registration and Protocol 1. Neovim's Index also receives a discovery schema;
callbacks and omitted values are identified by `host_fields`, without secret
defaults or choices. Large optional values can be omitted to keep the Index
bounded without restricting native commands. These snapshots do not grant
execution authority or replace host validation. Protocol 1 retains its own
field allowlists and quotas; they are not limits on Neovim declarations.

Shared profile declarations can describe logical projects, recipes, choices and
presentation preferences. Executable paths, project mappings, live editor
objects, authorization receipts and Task history belong to the host. Retaining
a valid declaration does not make an unsupported operation available. The
[architecture map](development/execution-structure.md) locates those boundaries;
[command coverage](command-coverage.md) identifies the supported host features.

The Lua 5.1 syntax is executable by LuaJIT. The native bridge requires the **Lua 5.1 C ABI** and an explicit compatible runtime library path. It dynamically loads the runtime and preloads the core sources declared in `native/core_modules.def`. CMake uses the same manifest for installation and rejects missing, duplicate or unlisted core sources. It does not ship a Lua runtime, load Neovim or duplicate command logic in C++. Neovim needs no native compiler or bridge binary.

The source includes [Document v1/v2](host-contracts.md), portable profile and
workflow validation, search-provider semantics, follow-up proposals and shared
presentation resolution/editing. `ce_stdio` supplies the optional desktop
transport. See the [workflow](development/workflow-contract.md) and
[presentation](development/presentation-contract.md) contracts for host boundaries;
see [compatibility](compatibility.md) for host requirements and limitations.
Neovim's project-name `require("re35")`
facade and legacy `require("command_tree")` expose the same host API; portable
Lua modules retain the `command_environment.core` namespace.

## Direct command intent

`core.invocation.validate({command="search.document", args={query="TODO"}})`
validates and copies data; it does not select, authorize or execute a command.
The optional wire operation is `invocation_validate` with `{invocation: ...}`.
Both hosts use this envelope before their existing command flow. Exact stable
IDs are independent of tree paths; host key notation stays outside the envelope.
The bound is 64 KiB encoded JSON, depth 16 and 2048 data items; arguments must be
an object containing finite JSON-compatible data. Unknown invocation fields,
callbacks, host objects and runtime map/Ex IDs are refused. A host then validates
supported command arguments, captures its current source, and owns capability,
review and execution checks. Missing inputs may open the existing form.
Unsupported IDs remain unavailable rather than becoming raw key playback.

## Build and run

With a C11/C++17 toolchain, run `cmake -S . -B build`, then `cmake --build build`. On Linux the loader uses `dlopen`; Windows uses UTF-8 to wide path conversion. Supply a runtime library such as a compatible `lua51.dll` or `libluajit-5.1.so.2`; do not supply a Lua 5.4 library.

Run `ce_cpp <runtime-library> <absolute-lua-directory> <command.json>` from the built executable directory. `ce_lua_console <runtime-library> <script.lua> [args]` runs standalone Lua fixtures without an editor.

The C# wrapper in `examples/csharp` uses P/Invoke and a SafeHandle. `dotnet build examples/csharp/CommandEnvironment.Console.csproj` uses an optional .NET 8 SDK. Keep the platform's bridge library alongside the executable (or on its native library search path) and run the same fixture with the same three arguments. Build and runtime requirements belong to these examples, not to the Neovim plugin.

## Protocol 1 / C ABI 1

`native/ce.h` defines `ce_create`, `ce_call`, `ce_destroy`, `ce_free` and `ce_abi_version`. One opaque engine handle belongs to its creating thread. Calls must use that thread; idle destruction can happen on another thread for managed finalizers. Callers must prevent destruction racing with any call, never use a destroyed handle, and release only returned buffers with `ce_free`. UI close, operation cancellation and engine disposal are separate protocol actions.

All JSON and paths use strict UTF-8. JSON inputs and outputs are bounded to 1 MiB. The VM allocator has a 32 MiB budget. JSON rejects duplicate keys, invalid UTF-8, invalid surrogate pairs, nonfinite numbers, depth over 64 and integers beyond the exact 53-bit range. `[]`, `{}` and `null` have distinct markers in Lua. The response is `{ "ok": true, "value": ... }` or `{ "ok": false, "error": ... }`; C transport failures are separate status codes with an error buffer.

The base command lifecycle includes `register`, `unregister`, `configure`, `bind`,
`resolve`, `get`, `search`, `words`, `select`, `invoke`, `claim`, `complete`,
`cancel`, UI/workspace navigation and `snapshot`/`dispose`. It is not the complete
operation list: typed document, profile/workflow, search-provider,
follow-up and presentation operations are described by their contracts and
dispatched in `lua/command_environment/core/bridge.lua`. Register only metadata;
functions and native objects never cross JSON. The host supplies current
capabilities and a target `{token,revision}` at selection, invocation and claim.
Claim immediately before the actual handler runs. Changed generation/target,
duplicate claim and duplicate completion are rejected.

The host owns actual handlers, dynamic choices, permission checks and external resources. Cancellation requests do not pretend that a process stopped. Complete once with actual success/failure/cancellation and any partial result. A closed UI keeps operation records; a disposed engine returns pending request IDs for the host to detach and rejects later completion. Detaching does not kill a host process.

The C++ and C# samples resolve the same tree and alias and execute their own
counter handler. They include cases for bad input, stale selection/target,
exceptions, repeated completion, cancellation, thread rejection and disposal.
These are embedding examples, not additional editor hosts. They require their
respective installed toolchains; see [compatibility](compatibility.md).
Game-engine UI, mobile/console platforms and per-frame budgets require checks
in their actual hosts.
