# Command workflow coverage

RE35's goal is to keep discovery, input, review, execution, results and recovery
inside a usable command environment. This inventory describes behavior rather
than counting registered command names. A discovered name does not establish
support for every argument, range, completion rule or recovery path.

This inventory describes RE35 0.2.3.
0.2.0 adds Getting started (`help.open`), integration diagnostics
(`help.integrations`) and the native Editor return destination (`workspace.editor`).
See [compatibility](compatibility.md) for host scope and limitations, and
[installation](install.md) for setup. Source and fixture links identify the
implementation and repeatable checks.

The status terms apply to the stated scope:

- **Supported:** the stated workflow has an implementation inside RE35.
- **Partial:** a bounded subset is implemented, or completion and recovery depend on host
  behavior that RE35 does not model completely.
- **External handoff:** RE35 dispatches to another UI or runtime; dispatch success
  does not establish that the user's later interaction completed.
- **Unsupported:** no implemented RE35 workflow covers the stated behavior.

Runtime prerequisites still apply to supported commands. Missing tools, language
servers or optional plugins remain visible as unavailable commands with reasons.

## Neovim workflows

Paths below are defaults after entering `\`; profiles can move or unbind them.

| Workflow | Implementation scope | Current behavior and boundary | Source and fixture references |
| --- | --- | --- | --- |
| Discover, enter arguments, review and execute | Supported | Tree, command search, aliases, words and fixed slots share registered IDs. Typed arguments and captured targets are rechecked. Editable fields retain their text-editing keys. | [Input](../tests/regression/test_input.lua), [Session](../tests/regression/test_session.lua), [Registry](../tests/regression/test_registry.lua) |
| Open/save files and select buffers/windows | Supported | `fo`, `fs`, `fa`, `bb`, `ww` and split/close commands call Neovim services. File operations retain Neovim's filename, modified-buffer and error semantics. This is not every Ex file-command variant. | [Command registration](../lua/command_tree/defaults.lua), [additional builtins](../lua/command_tree/builtin_commands.lua) |
| Find project files and search saved text | Supported within the selected backend's scope | `ff` / `fg` use the selected backend. Builtin scanning is bounded, literal and case-sensitive. Optional ripgrep text search adds declared single-line regex/case choices and project ignore rules through structured Results. Partial results and provider provenance stay visible; saved-file navigation is revalidated. Telescope remains an explicit external handoff. Unsaved buffer text is a separate workflow. | [File search limits](file-search.md), [structured providers](search-providers.md), [scan lifecycle](../tests/test_file_scan_lifecycle.lua), [backend recovery](../tests/regression/test_backend_recovery.lua) |
| Search and replace literal text in the current document | Supported within Document v1/v2 bounds | `ef` / `er` use the shared document core and a captured document revision, including unsaved/unnamed normal buffers. V2 extends larger documents to 10,000 lines / 1 MiB of line content, with 64 KiB individual lines and aggregate edit/output quotas. Search produces navigable Results; replacement requires review and explicit Apply. Single-line, case-sensitive literal matching is distinct from Vim regex substitution. No implicit save or partial Apply occurs. | [Host contracts](host-contracts.md), [v1 workflow](../tests/test_document_workflow.lua), [v2 contract](document-v2.md), [v2 core fixture](../tests/test_document_v2_contract.lua), [v2 workflow](../tests/test_document_v2_workflow.lua) |
| Vim regex substitution | Partial | `es` accepts a within-line Vim pattern and literal replacement, with bounded line/selection/buffer scope, preview and explicit Apply. Capture expansion, replacement expressions and multiline regex are unsupported here. | [Substitution implementation](../lua/command_tree/substitute.lua), [input/review fixtures](../tests/regression/test_input.lua) |
| Undo/redo and History timeline | Supported within the current buffer's undo history | History reads Neovim undo state, preserves the workspace by default after timeline actions and retains native undo ownership. It is not cross-document transactional rollback. | [History implementation](../lua/command_tree/history_mode.lua), [workspace fixture](../tests/regression/test_workspaces.lua) |
| Diagnostic lists and existing quickfix/location lists | Supported | `dl` / `db` open RE35 Results; result navigation revalidates source identity. Native quickfix and location lists are preserved rather than repurposed. | [Results implementation](../lua/command_tree/results.lua), [recipe result fixture](../tests/test_recipe_results.lua), [workspace fixture](../tests/regression/test_workspaces.lua) |
| LSP navigation, rename, code action and formatting | Partial, capability dependent | `c` commands query attached clients for the requested method, retain source context and reject stale targets. Language coverage follows installed servers and their runtime capabilities. RE35 does not install servers or promise successful operations for every major language. | [Capability checks](../tests/test_availability.lua), [status/return flow](../tests/test_availability_flow.lua), [LSP adapter](../lua/command_tree/adapters/lsp.lua) |
| Project build/test/run, failure and retry | Supported for declared sequential process recipes | Project selections feed checked argv steps. `rr` and semantic slots run the current window's selected recipe; retained retry preserves the old invocation. Clean files avoid a redundant save chooser; modified files retain an explicit decision. Save failure, changed declarations or stale sources stop launch. Failure/cancellation stops later steps; Tasks/Results retain partial results and step origin. Default direct execution leaves descendant termination unknown. An explicitly configured optional helper owns a Windows Job or Linux group and reports observed scoped termination; detached daemons/services remain outside that promise. | [Recipes](project-recipes.md), [launch routes](../tests/test_recipe_launch.lua), [Project lifecycle](../tests/test_project_lifecycle.lua), [recipe lifecycle/results](../tests/test_recipe_results.lua), [process ownership](development/process-ownership.md) |
| Tasks inspection and reviewed diagnostic export | Supported | Filters, historical provider identity, bounded report preview and explicit destination review are included. Sensitive arguments, paths, environment, history and output are excluded by default. Export is not upload or automatic retry. | [Task report fixture](../tests/test_task_report.lua), [report implementation](../lua/command_tree/task_report.lua) |
| Recipe remedies and fresh original-choice review | Supported in Neovim | Tasks `c` opens owned source Results or relevant step/tool Settings; Project exposes missing-tool routes. `v` fixes original logical choices while reviewing current tools and preserves current selection/memory. Execution requires a separate decision. Unknown exit causes remain unknown; changed physical identity or declarations refuse review/launch. | [Recipes](project-recipes.md), [recovery fixture](../tests/test_recipe_recovery.lua), [self-development](development/self-development.md) |
| Settings, portable profiles and custom workspaces | Supported within schema 1 | Draft/review/Apply/Undo, portable command links, remapped workspace actions and layout import/export retain public contracts. Local paths/tools are resolved by the host; missing providers remain inert. | [Settings lifecycle](../tests/test_settings_lifecycle.lua), [environment recovery](../tests/test_environment_lifecycle.lua), [profile flows](../tests/test_v52_flow.lua), [navigation](../tests/test_navigation_lifecycle.lua) |
| Named presentation and appearance-only sharing | Supported within presentation v1 | Full/Compact/Minimal and custom presets support inheritance, scene overrides, reviewed editing, independent cloning, import/export and restoration. Required input/review facts retain their admission gates. The separate eight-field UI format remains Neovim-specific. | [Preset guide](presentation-presets.md), [presentation contract](development/presentation-contract.md), [inspection catalog](../tests/fixtures/presentation-inspection.json) |
| Global/buffer-local user Ex commands | Partial | Event-driven discovery preserves command identity, `nargs`, supported bang/range/count fields and native completion callbacks. Argument text still follows that command's Ex syntax; arbitrary plugin commands do not gain semantic forms automatically. A chained second command is rejected. | [User-command provider](../lua/command_tree/providers.lua), [provider fixture](../tests/regression/test_provider_commands.lua), [completion fixture](../tests/test_ex_completion.lua) |
| Native builtin Ex discovery | Partial, opt-in | `providers.ex_builtin=true` discovers builtin names with raw argument input. The discovery API supplies limited builtin metadata, so RE35 does not claim universal typed arguments, range/bang fields or builtin completion parity. | [Provider implementation](../lua/command_tree/providers.lua), [Neovim help](../doc/command-environment.txt) |
| Telescope pickers and plugin-owned screens | External handoff | Explicit adapters preserve the plugin's own UI and selection lifecycle. `handed_off` means dispatch, not completed selection. Plugins are not loaded or installed by discovery. | [Integration help](../doc/command-environment-integrations.txt), [adapter resolution](../lua/command_tree/integrations/init.lua) |
| Optional Git workspace | Supported for its declared file actions | Explicit enablement supplies status, diff and reviewed whole-file stage/unstage. Conflicts, submodules, rename records and clean filters have action restrictions. Git index changes cannot be rolled back generically. | [Extension contract](extensions-v1.md), [Git implementation](../lua/command_tree/extensions/git.lua) |
| Debugger workflow and complete Ex syntax/semantics | Unsupported as a complete RE35 workflow | Custom commands can dispatch existing tools, but no complete debugger or Ex successor is implemented. These entries are excluded from supported coverage. | [Roadmap](roadmap.md) |

Using Neovim's Ex APIs internally fits this goal: RE35 can present a semantic
command and retain input, review and errors while Neovim performs the editor
operation. A visible jump to an external command line or plugin UI remains an
explicit handoff. The two cases must not be counted as the same workflow.

## Host boundaries

The command model and Document v1/v2 are shared pure Lua. Neovim retains its UI,
LSP, undo, filesystem and process services. A native C ABI embeds those same Lua
sources; console examples establish that model/transport integration, not a
complete editor environment. The optional VS Code desktop implementation covers
Document v1/v2, shared profile validation/import, local project selection,
sequential recipes, owned Tasks/Results, bounded compiler diagnostics, original-task
recovery/retry and saved project search. Six native presentation scenes use shared
presets with optional-information support and explicit style/geometry fallbacks.
A read-only `settings.presentation_inspect` command exposes requested/effective
support. The host also connects reviewed preset authoring, appearance-only
import/export and restoration through a saved host-local override. View changes
preserve the existing native form and workflow owner. These implementations do
not establish visual parity or physical acceptance.
See the [VS Code guide](../hosts/vscode/README.md) and
[Results/search contract](development/results-search-contract.md). Neovim
workspaces, LSP, Git workspace and eight-field UI settings are not ported
wholesale. Full-profile validation does not imply that every section is acted
on by the optional host. The shared appearance declarations preserve unsupported
preferences for another host instead of claiming that VS Code renders them.

RE35 is the project name and `require('re35')` is the canonical Neovim entry.
`require('command_tree')` remains the same API object for compatibility.
`command_environment.core.*`, native `ce_*` targets and existing `command-tree`
state paths retain their established module, ABI and storage identities; these
are compatibility boundaries, not separately maintained products.

## Remaining coverage

See [compatibility](compatibility.md) for host limits and [roadmap](roadmap.md)
for planned work. New coverage must specify syntax, arguments, ranges, completion
and recovery alongside an end-to-end workflow. Portability does not imply feature
parity, and dispatch into another UI does not establish completed work.
