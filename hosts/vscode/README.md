# RE35 VS Code desktop host

This optional desktop host runs the same Lua document and profile rules as Neovim.
It supports current-document literal search, owned Results, reviewed literal
replacement, stale-target refusal, discard and editor Undo. It also loads portable
profiles with support review/Apply, selects a local project context and executes
sequential recipes with retained Task output/outcome, declared compiler diagnostics,
original-task recovery/retry and structured saved-file builtin/ripgrep project search.
Native forms stay open across appearance changes, with shared information
preferences and read-only capability/fallback and complete-facts inspection.
It supports reviewed named-preset editing, appearance-file sharing and
restoration. See [compatibility](../../docs/compatibility.md) for host scope
and known limitations. The complete
Neovim command environment has not been ported. This is a source development
extension, not a Marketplace release or a prebuilt VSIX.

## Build and open

Build the repository's optional native targets using the instructions in
[portable-core.md](../../docs/portable-core.md). The new `ce_stdio` executable
uses the adjacent bridge library and an explicitly supplied Lua 5.1 ABI runtime.
Neither the extension nor setup downloads a runtime or compiles anything.
Rebuild the helper when the portable core module manifest changes; replacing
Lua files alone cannot teach an older native loader about newly shared modules.

Open an isolated Extension Development Host from the checkout:

```sh
code --extensionDevelopmentPath=/absolute/RE35/hosts/vscode
```

Set these machine-local VS Code settings to existing absolute paths:

```json
{
  "re35.helperPath": "/absolute/build/ce_stdio",
  "re35.luaRuntime": "/absolute/lib/libluajit-5.1.so.2",
  "re35.corePath": "/absolute/RE35/lua"
}
```

On Windows use the built `ce_stdio.exe` and a compatible `lua51.dll`; both
runtime and core paths support Unicode. The bridge shared library belongs
alongside the helper or on its normal native-library search path. `corePath`
defaults to this source checkout's Lua directory. Local `toolOverrides` and
`processHelper` repairs preserve the profile, project selection and retained
Tasks, while invalidating old execution reviews and stopping active work.
Appearance-only `re35.presentation` changes also preserve the helper and workflow
owners and the same active native form. Other RE35 execution/context settings
changes dispose the previous helper and profile/context; load the profile again
afterward. A trusted workspace is required.

**RE35: Presentation Presets** stages named creation/cloning, field/scene/parent
edits and resets. Apply saves only a host-local appearance override; Reset to
profile/local defaults clears it. **RE35: Export Presentation Presets** and
**RE35: Import Presentation Presets** share the bounded appearance-only file,
with conflict/fallback review and explicit Apply/Discard. Unsupported declarations
remain portable. See [presentation presets](../../docs/presentation-presets.md)
for precedence and restoration. The helper must use the current 17-module core
manifest before using these commands.

Run **RE35: Open Command Environment** from the Command Palette. Search and
replacement are the same `search.document` and `edit.replace_literal` IDs used
in Neovim. No editor keybinding is installed by default. Replacement presents a
diff followed by Apply or Discard. Apply uses one editor transaction and requests
no save; a user's AutoSave or other extensions retain their own behavior.
Results refuse navigation after their source document changes. Narrow documents
to the [shared contract limits](../../docs/host-contracts.md). The host uses
stateless Document v2 pages above the v1 scope, up to 10,000 lines/1 MiB of UTF-8
line content. Individual lines are at most 64 KiB; retained search locations,
edits, compact plans, rendered output and processing time remain bounded.
The helper must advertise the exact supported v2 capabilities. A missing
capability or failed page refuses the operation; it does not silently use v1
or apply a partial replacement. Both paths keep single-line literal semantics.

## Portable profiles and local projects

Run **RE35: Load Portable Profile**, select a local JSON file and review its
changed sections and support feedback. Apply activates the reviewed snapshot for
this extension host. This uses the shared `settings.profile_import` ID and currently
supports explicit replacement; merge mode remains unavailable in this host.
Discard preserves the current profile and selection.
Unsupported settings remain stored; importing them does not claim UI, workspace,
adapter or task support. Loading/Apply writes no profile file and runs no declared
tool. The configured core helper must still be available in a trusted workspace.

Run **RE35: Select Project Context** to choose the declared project, recipe,
configuration and target through the shared `workspace.project` entry. One local workspace folder supplies the project base
by default. For multiple folders, configure exact folder URIs locally:

```json
{
  "re35.projectRoots": {
    "cpp": "file:///absolute/workspace/folder"
  }
}
```

Use the actual folder's URI, including percent encoding and Windows drive syntax
when relevant. Missing/ambiguous folders and physical root/source escapes are
refused. `config`/`home` roots require explicit absolute `re35.configBase`/
`re35.homeBase` settings; empty values leave those bases unavailable. Local paths
and mappings do not become part of the imported profile. Workspace changes
invalidate selection. **RE35: Inspect Project Context** shows current choices
after revalidation. Selection and inspection save no documents and start no task.

Owned Recipe Results support compiler navigation, explicit saved-file search
providers, original-context recovery and fresh retry.
Imported profiles live only for the owning RE35 host service; load them
again after a core/context configuration change or extension reload. Local
execution Settings repairs preserve the existing profile and retained Tasks.
Large valid profiles can exceed the existing 1 MiB escaped transport frame and
are refused without changing current data. See the
[shared workflow contract](../../docs/development/workflow-contract.md).

## Native presentation preferences

Set `re35.presentation` to the shared version 1 appearance collection:

```json
{
  "re35.presentation": {
    "version": 1,
    "selected": "focused",
    "presets": {
      "focused": {
        "extends": "minimal",
        "scenes": {
          "review": { "information": { "details": true } },
          "tasks": { "information": { "status": true } }
        }
      }
    }
  }
}
```

A saved authored appearance override takes precedence over an applied portable
profile's `presentation` collection, which takes precedence over the local
collection. Clearing the authored override reveals the profile or local
collection; omitting the profile field reveals the local collection. Preferences
resolve for tree, search, input, review, tasks and results. Native controls apply
routine titles and explicitly optional help/details/status; required input,
Task identity/status, original choices/argv/cwd, save/review facts and unknown,
partial or stale notices remain visible. Geometry, spacing, icons, decoration
and color roles use native fallbacks; terminal width/row values do not size a
Quick Pick.

Use **RE35: Inspect Presentation Support** (`re35.presentationSupport`), also
available in RE35 discovery with recorded command path `s u p`, to inspect a scene's
requested preference and fallbacks. It changes no settings and admits no work.
Use **RE35: Presentation Presets**, **RE35: Export Presentation Presets**
and **RE35: Import Presentation Presets** for reviewed native authoring and
appearance-only files. Appearance can also accompany the existing portable
profile import. See the [preset guide](../../docs/presentation-presets.md).

An appearance-only update validates a detached declaration and preserves the
same backend, profile, project selection, Tasks/Results and private pending
execution admission, including an active review. The same native widget retains
its query/input, active choice and multiselection. The eye button cycles views
for this host session; it does not persist or rewrite the profile. Enter during
refresh does not queue execution: make a fresh choice after the refresh completes.
Informational rows stay open when selected; explicit action rows retain their
original ownership. Invalid data leaves the prior appearance and form intact.
Backend/profile replacement, trust loss or disposal refuses the old form.

Task, Results and review lists also provide an **Open complete facts** button.
It opens the exact original text, including long paths and argv, in an immutable
read-only virtual document while preserving the native form and query. The
snapshot includes no action links and cannot run, approve or save an operation;
use the original explicit action in the form. One snapshot of at most 1 MiB is
retained per presentation service. Native rows may still elide text visually;
the complete document provides scrollable access rather than claiming unclipped
list pixels. Required review text above that bound is refused before Run/Apply
choices are offered. The implemented native adapter is separate from
actual visual approval, physical gestures and human-time acceptance.

## Run a recipe

Choose **RE35: Run Selected Recipe** after selecting a project context. Clean
saved inputs run directly. When loaded project documents are modified, choose
**Run saved inputs**, **Save selected files, then Run**, or **Cancel**. The save
picker contains only the original relevant project documents. Untitled inputs,
unrelated files and nested projects are not silently saved. A save failure stops
admission and reports any files already saved. File/editor changes during review
require a fresh Run. Task admission captures identity/version/stamps, not document
text, so the document-search line/byte bounds do not limit ordinary task inputs.

Use **RE35: Inspect Recipe Tasks** to see status, exit code, exact invocation,
original configuration/target and captured output. Open captured output in an
owned read-only document; the output panel streams the current task. Four Task
outcomes are retained. Each parent captures at most 1 MiB of stdout/stderr combined
across up to 16 steps. A failed or cancelled child stops later steps. Closing the
panel leaves its task running. Closing the owning extension/helper requests
termination and records observed exit separately from the request. Batch files
need an explicitly declared interpreter; no shell is inserted.

Use **RE35: Cancel Running Recipe**, or select **Cancel this task** in Tasks.
Tasks also offers force after cancellation grace. One original invocation keeps
its original configuration and target even when another context is selected.
Changing its profile, workspace ownership, tools or relevant inputs stops later
launches. A declared logical cwd may be created by an earlier step; its existing
base is pinned and its physical containment is checked before execution.

An optional absolute `re35.processHelper` setting selects the separately built
`ce_process_scope`. It owns a Windows Job or Linux process group. A configured
unavailable helper is refused, without substituting direct scope. Without this
setting, only the direct child is controlled and descendant termination is
unknown. Intentionally detached services remain outside group guarantees;
observed survivors and unknown observation scope are reported honestly.

Local executable paths/argv/cwd overrides remain machine settings:

```json
{
  "re35.toolOverrides": {
    "re35_target_build": { "command": "/absolute/bin/cmake", "timeout_ms": 120000, "cancel_grace_ms": 2000 }
  }
}
```

Override `args` replaces tool arguments; recipe step `args`/`cwd` still takes
precedence. An explicit local `cwd` is absolute. A logical cwd that escapes its
base is unavailable until an explicit local override is chosen. Timeout is
disabled by default (`0`); local `timeout_ms` accepts 0–86400000 and
`cancel_grace_ms` accepts 0–60000 (default 2000). Scope helper grace has a minimum
of 1 ms internally. Timeout requests cancellation and escalation; a request is
never presented as observed termination. Portable profile import runs no step.

## Inspect recipe Results

Use **RE35: Recipe Results**, or **Open source results** in Tasks. Results retains
the original step, configuration/target, parser status and partial-output notices.
Supported declared `file:line[:column]` and `file(line[,column])` errorformats
produce inspectable diagnostics. Unsupported formats remain captured output.
Original declared source and loaded input documents can supply verified navigation;
other files report an unavailable original revision. Dirty/stale/reopened sources
refuse their old coordinates. Changing only the current configuration/target does
not replace the result owner.

Explicit GCC byte columns are converted to UTF-16. Unknown display/column units
use the start of the reported line, with that limitation shown. Results inspection
does not run or save anything. See the [result contract](../../docs/development/results-search-contract.md)
for the exact parser subset and verification limits.

## Recover the original task

Use **RE35: Recover Original Task**, or **Recovery and original-task retry** in
Tasks/Results. Choose Inspect, Results, a declared remedy, Retry original task,
or Review original choices. Inspection and Settings never start or save work.
Return goes to the same Task ID. A source remedy requires a diagnostic from the
failed step; plain failure output keeps its cause unknown and exposes that
step's declared tool for inspection in local Settings.

Retry uses the Task's original project, recipe, configuration and target even
when current selection differs. It rechecks current saved files, editor inputs
and tools. Dirty repairs offer Save selected, Run saved, or Cancel; Run saved
keeps the edited document unsaved. A new source version invalidates its old
diagnostic position but can become a fresh retry input.

If local tool arguments, working directory, parser, timeout or process helper
changed, strict Retry refuses. **Review original choices** shows the fresh
literal argv/cwd and limits for the original logical choices, then offers Run
or Return. This review never changes current selection. A replaced profile or
physical root/source requires selecting and running the new context instead.
Only the four retained Tasks can prepare recovery. See the
[recovery contract](../../docs/development/task-recovery-contract.md).

## Search saved project files

After selecting a local project, use **RE35: Search Project Text**. Provider comes
from the portable profile's `adapters.project_search`: `builtin` by default, or
explicit `ripgrep`. Builtin offers literal case-sensitive search; ripgrep adds
single-line regex and case options with project ignore rules. Missing selected
providers do not fall back. Install any external engine yourself.

Keep executable paths and limits in machine settings:

```json
{
  "re35.projectSearch": {
    "command": "/absolute/bin/rg",
    "limits": { "results": 1000, "milliseconds": 5000 }
  }
}
```

Four finished searches retain provider/options, filtered scope, partial matches
and observed completion. **RE35: Project Search Results** reopens them. Cancellation
is available in the progress notification or **RE35: Cancel Project Search**.
Ripgrep controls its direct child only, with descendants explicitly unknown.
Matches refer to saved UTF-8 files; unsaved editor changes are not search inputs.
Navigation rechecks root/file identity, disk revision, editor owner and explicit
byte-to-UTF-16 coordinates. Generated/hidden/symlink/binary filtering and read,
result, output and time caps remain visible. Builtin does not read ignore files.
See [provider semantics and limits](../../docs/search-providers.md).

## Verify

The independent transport fixture uses Node and the actual C ABI helper:

```sh
node hosts/vscode/test/transport.js /absolute/build/ce_stdio /absolute/runtime /absolute/RE35/lua
```

The [extension fixture](test/extension.js) runs inside VS Code's real Extension
Development Host. Supply absolute `RE35_HOST_TEST_DIR`, `RE35_TEST_HELPER`,
`RE35_TEST_LUA_RUNTIME` and `RE35_TEST_CORE` environment values; then add
`--extensionTestsPath=/absolute/RE35/hosts/vscode/test/extension.js`. Use new
`--user-data-dir`, `--extensions-dir` and workspace directories for each run.
The test workspace must be trusted, AutoSave must be off, and the fixture creates
only its document/project/profile fixture files and JSON report below `RE35_HOST_TEST_DIR`.

The immutable-snapshot runner prepares those isolated settings and paths:

```sh
python tests/acceptance/run_vscode_host.py \
  --code /absolute/path/to/code \
  --helper /absolute/build/ce_stdio \
  --lua-runtime /absolute/runtime \
  --report .artifacts/usage/vscode-integration.json
```

This fixture exercises actual documents, edits, selections and Undo, including
CRLF, emoji, unsaved text, stale reviews, retry and cancellation, concurrent/disposed
helper startup, full profile preservation and actual local project selection. It does not
automate physical QuickPick/diff gestures or establish latency, Linux desktop,
web/remote, LSP or complete Workspace compatibility. With explicit `--node`,
`--process-helper` and recipe-tool options, additional fixtures exercise actual
sequential tasks, owned termination and checkout configure/build/validation.
Adding `--ripgrep /absolute/bin/rg` with the existing Node/compiler options checks
actual compiler diagnostics, owned navigation and both search providers.
The same compiler/Node options exercise failure -> Results -> editor repair ->
fresh original retry, local Settings repair and stale/foreign/consumed owners.
Controlled callback tests and headless Linux service checks are separate from
native desktop interaction and physical UI acceptance.
