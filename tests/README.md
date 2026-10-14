# Portable regression tests

Use Python 3.10 or later and Neovim 0.11 or later. This suite needs no optional
plugins, compiler, Lua installation, network access or personal Neovim config.

```sh
python tests/run.py
python tests/run.py --nvim /path/to/nvim --report .artifacts/tests.json
python tests/run.py --list
python tests/run.py --select test_ex_completion --select 'regression/test_input.lua'
```

On Windows, `--nvim "C:/Program Files/Neovim/bin/nvim.exe"` selects an executable
outside PATH. The runner selects only files named `test_*.lua` below `tests/`.
Each `--select` pattern must match a fixture. Run individual tests by stem,
filename or repository-relative path; repeated selections are combined.

Every fixture gets a new `nvim --headless -u NONE -i NONE --noplugin -n`, a
temporary working directory, isolated configuration/data/state/cache locations,
and a runtimepath containing only this repository and Neovim's own runtime.
The fixture is run once. Assertions, nonzero exits, timeouts, excessive output
and early exits without a completion marker fail the run. There are no retries
or automatic prerequisite downloads.

The default timeout is 30 seconds per fixture and the combined output limit is
128 KiB. `--timeout` and `--output-limit` can change these finite bounds. Reports
record the runtime-source and fixture SHA-256 hashes, the fixed presentation
catalog's identity, actual process results and bounded output. A source or
catalog change during the run also fails it. `.artifacts/`
is ignored; generated reports are not repository sources.

## Coverage

The opt-in [self-development driver](acceptance/run_self_development.py) runs
this actual checkout's regression through its portable recipe, then retries its
original Debug/all invocation after selecting Release/all. `--with-native`
adds actual configure/build/FIFO/C++ validation using installed host tools.
See the [development guide](../docs/development/self-development.md). Controlled runs do not replace ordinary editor use or physical UI inspection.

The `regression/` fixtures preserve established host behavior with portable
paths and no personal configuration modules:

| Fixture | Checks |
| --- | --- |
| `test_registry.lua` | Alias/path ownership, failed mutation recovery, availability, persistent and transient usage |
| `test_provider_commands.lua` | Global/buffer-local Ex identity, nargs/bang/range/count, shadowing, refresh and pipe rejection |
| `test_protocol.lua` | Pure Lua JSON/schema bounds, target revisions, one-time execution, cancellation and detached results |
| `test_input.lua` | Typed input, completion, review, Unicode paste, secrets, async prompts and cleanup |
| `test_session.lua` | Review/edit flow, navigation, density/layout, cursor viewport and hidden command rejection |
| `test_workspaces.lua` | Remapped board keys, Results refresh/reselection, workspace filters and window cleanup |
| `test_backend_recovery.lua` | Real saved-file search, Settings review/apply/return, stale-context rejection and no implicit execution |

Top-level fixtures cover changes for the current release. The protocol fixture
sets the global `vim` API to `nil` while exercising the portable engine, so an
accidental editor dependency fails. This does not replace the native C ABI/C++/
C# build checks, external plugin compatibility checks, live LSP tests, terminal
interaction checks or performance measurements used for a release.

| Current fixture | Checks |
| --- | --- |
| `test_theme_persistence.lua` / `test_theme_startup.lua` | Actual save/rollback failures, strict host-local state, confirmed theme restoration across fresh editor processes, custom ownership and disabled/stale startup hooks |
| `test_navigation_feedback.lua` | Shared list wrapping, option-off clamping, full error inspection/return, restoration failure refusal, independent detail scrolling and native Editor return |
| `test_fixed_panels.lua` | Stable main geometry, independent bounded details, legacy/preset and three-density behavior, tiny critical-scene refusal and complete window cleanup |
| `test_guidance_persistence.lua` | Read-only integration status, native first-use routes, truthful Draft/Saved/Session only and actual profile/theme save failures |
| `test_presentation_contract.lua` | Editor-independent preset schema, inheritance/standalone roots, six scenes, capability/fallback, strict data and size bounds |
| `test_presentation_edit.lua` | Shared authoring schema, independent clones, bounded mutations and appearance-file codec parity; no command execution authority |
| `test_presentation_inspection.lua` | Fixed 24-case renderer projections, bounded geometry/state, tiny input/review refusal and separate History edges; physical judgment remains unjudged |
| `test_presentation_settings.lua` | Actual named preset creation/clone/edit/select/reset/delete, parent selection, Review/Apply/Discard/Undo and unrelated profile preservation |
| `test_presentation_session.lua` | Live tree/form/review/search/Board/History/timeline state preservation, fresh resize checks, Settings edit/Apply refusal and symbolic workspace edges |
| `test_presentation_scenes.lua` | Actual Session six-scene/three-mode coverage, retained Executor Tasks/Results, mandatory source/owner facts, narrow/tiny resize, filter-cancel selection and validated native cursor navigation |
| `test_presentation_sharing.lua` | Actual appearance-only export/import/review/Apply/Undo, captured snapshots, invalid files, pending-draft/input view changes and stale navigation refusal |
| `test_presentation_view.lua` | Actual float geometry, independent style axes, Unicode, bounded role slots, theme isolation and unsupported-geometry/required-fact fallbacks |
| `test_document_contract.lua` | Shared URI/revision/UTF-8/16/32 coordinates, strict Unicode, literal search and replacement plans, stale/coherence/bounds checks with editor globals removed |
| `test_document_v2_contract.lua` | Stateless complete-line pages, absolute UTF-8/16/32 coordinates, compact edit plans, strict nested data, exact encoded-frame and quota refusal, additive bridge operations and unchanged v1 with editor globals removed |
| `test_document_workflow.lua` | Actual canonical RE35 input/preview/single Apply, unsaved Results, invocation-bound consent, hook/API replay refusal, enabled Undo and explicit retry |
| `test_session_dispatch.lua` | Actual final Apply, cross-Session/public authority masking, nested exception restoration, one-use consent, post-capture argument/context/form changes and fresh retry |
| `test_executor_lifetime.lua` | Public Executor synchronous prompt cleanup, cleanup reentry/pending ownership, actual fast-event duplicate suppression, rejected/deferred/forced cancellation and timeout precedence |
| `test_document_v2_workflow.lua` | Actual tree/search/preview/Apply/Undo on 10,000 unsaved lines and 1 MiB, late Unicode coordinates, complete-line/aggregate quotas, cancelled/stale/partial refusal and controlled machine samples |
| `test_ex_completion.lua` | Native callbacks, cursor/suffix preservation, stale definitions and cached candidates |
| `test_availability.lua` / `test_availability_flow.lua` | Capability checks, bounded status, recheck and explicit return |
| `test_command_links.lua` | Strict portable declarations, provider replacement, missing placeholders and argument annotations |
| `test_v52_flow.lua` | Actual Settings input/review/Apply/Undo, export/import and Inspect return without execution |
| `test_task_report.lua` | Real failed/cancelled processes, filtered Tasks, rendered preview, stale sources, exact reviewed export and destination races |
| `test_recipe_results.lua` | Real sequential child processes, partial results and origin, failure/cancel/timeout, profile replacement before the next step |
| `test_recipe_launch.lua` | Clean launch, explicit/dirty save decisions, selected-recipe `rr`/slots, old-target retry, binding overrides and empty-profile lazy ownership |
| `test_recipe_recovery.lua` | Actual failed child Results/step Settings, fixed original-choice fresh review, unchanged Project selection/memory, active form/command refusal and physical root replacement at admission/dispatch |
| `test_project_progress.lua` | Actual live recipe stages, original-choice follow-ups, source focus, bounded Tasks/Results returns, timer teardown and refused timer-mediated task retargeting |
| `test_process_scope.lua` | Actual direct-child output/exit, unknown descendant scope and explicit missing/broken helper refusal without fallback |
| `test_view_layout.lua` | Actual float geometry, cell/extmark bounds, density/page identity, short-window truncation and Unicode single/double-width cursor rendering |
| `test_project_lifecycle.lua` | Reviewed partial save failure, original-target replay, changed declarations/filenames, actual cancellation grace and Linux force |
| `test_environment_lifecycle.lua` | Hook activation failure recovery, retained tasks, reentry, runtime CAS, atomic rename failure and committed-profile recovery |
| `test_settings_lifecycle.lua` | Section edit/reset/reorder, callback-free preview, optimistic conflicts and scheduled reopen ownership |
| `test_ui_reset.lua` | Actual whole-UI reset review, Discard/Apply/Undo, other staged section edits, stale review values and inherited local/saved defaults |
| `test_ui_export.lua` | Actual Settings export, detached applied state, draft/privacy protection, failed density persistence, guarded publication and write/collision cleanup |
| `test_ui_import.lua` | Actual UI-only import/review/Discard/Apply/Undo, strict bounded file reads, detached snapshots, unchanged unrelated settings and stale input/transaction refusal |
| `test_navigation_lifecycle.lua` | Back during workspace lifecycle reentry, cleanup failure and source receipt drift |
| `test_file_scan_lifecycle.lua` | Saved-file bounds, hidden/generated entries, changed targets, real asynchronous read races/cancellation and symlink exclusion |
| `test_follow_up.lua` | Editor-independent proposal bounds and one-use host receipts, callback mutation/reentry refusal and original parent/child recovery ownership |
| `test_search_provider.lua` | Editor-independent provider request/options, availability, provenance, strict data and limit validation |
| `test_search_provider_host.lua` | Actual builtin retained search, changed project-root replay refusal, explicit restored-scope retry and missing ripgrep refusal without fallback |
| `test_ripgrep_boundary.lua` | Controlled streamed transport, JSON ordering/summary and Unicode-byte checks, physical containment, output/read limits and partial-result reporting |
| `test_core_manifest.lua` | Shared native/installation source list, unique module identities and complete portable core coverage |
| `test_profile_contract.lua` | Editor-independent full profile normalization, strict object/list identity, declaration preservation, sensitive/runtime refusal and data-only bridge operations |
| `test_workflow_contract.lua` | Shared tool/project/recipe bounds, logical choices and exact argv substitution without editor or execution authority |
| `test_bridge_optional_rules.lua` | Document-only bridge initialization leaves optional profile/workflow/search rules unloaded; first use validates through the same pure rules without execution |

The optional [native FIFO fixture](native_stdio.py) takes an already built
`ce_stdio`, compatible Lua runtime and absolute Lua directory. It validates
actual shared document operations and malformed/oversized/partial framing
without Neovim. On Windows it also uses real Unicode/space runtime and core
paths, a trailing core separator, invalid argument counts/empty paths, and raw
malformed UTF-16 refusal through `CreateProcessW`. The
[VS Code host guide](../hosts/vscode/README.md) describes its separate Node
transport and real Extension Development Host fixtures.
These optional host checks require their own runtimes and are not silently
included in the default Neovim-only runner.

The opt-in [VS Code integration runner](acceptance/run_vscode_host.py) captures
an immutable source/helper snapshot and executes actual editor APIs with isolated
settings/workspace files. [Resource measurement](acceptance/run_vscode_resources.py)
uses the same actual host with fixed conditions and comparison budgets; see
[VS Code resource comparison](#vs-code-resource-comparison). Physical QuickPick
gestures and appearance remain owner observations. The standalone Node
`hosts/vscode/test/project-context.js` fixture checks real local filesystem mapping,
identity, ambiguity and link escape refusal without claiming editor behavior.

Supplying an existing absolute `--ripgrep` executable to the VS Code integration
runner adds `hosts/vscode/test/results-search.js`: actual compiler diagnostics,
owned Recipe Results, source navigation, builtin/ripgrep project search,
Unicode/BOM/CRLF coordinates, partial output, cancellation and stale-source
refusal. `RE35_RECIPE_CXX` selects the compiler inside the captured host; the
runner supplies it from `--cxx`. Missing configured tools are explicit failures;
the runner installs nothing. `hosts/vscode/test/result-boundaries.js` separately
checks real disk identities, encoding and link containment with controlled
editor participants, and is not evidence of native UI gestures.

The resource runner's optional `--ripgrep` workload uses
`hosts/vscode/test/results-resources.js` for fixed saved-file searches and
diagnostic capture. Its separate budgets are declared in
[results-resources.js](../hosts/vscode/test/results-resources.js); passing them
does not establish rendered UI latency or human workflow superiority.

## VS Code resource comparison

Use an already installed VS Code executable, built `ce_stdio` and adjacent bridge
library, and compatible Lua 5.1 ABI runtime. The opt-in runner downloads, installs
and builds nothing. From the repository root, select existing absolute paths:

```sh
python tests/acceptance/run_vscode_resources.py \
  --code /absolute/path/to/code \
  --helper /absolute/build/ce_stdio \
  --lua-runtime /absolute/lib/libluajit-5.1.so.2 \
  --runs 3 --report .artifacts/usage/resource-baseline.json

python tests/acceptance/run_vscode_resources.py \
  --code /absolute/path/to/code \
  --helper /absolute/candidate-build/ce_stdio \
  --lua-runtime /absolute/lib/libluajit-5.1.so.2 \
  --runs 3 --baseline .artifacts/usage/resource-baseline.json \
  --report .artifacts/usage/resource-candidate.json
```

The baseline command is for an explicitly labelled initial collection. To judge
the existing failure, use the original frozen maintainer-local baseline report;
it is not shipped in this repository. Preserve that report and all failed or
incomplete comparisons. A new runtime, workload or baseline cannot clear the
original gate. Every report needs a new path.

Each of three fresh Extension Hosts uses an immutable source/helper capture,
isolated settings and a trusted empty workspace, with AutoSave, telemetry, updates,
external extensions and GPU acceleration disabled. The small-document workload
has 1,000 unsaved lines and ten Unicode matches. Repeated timings have five
warmups and 30 sequential samples per host, giving 90 measured samples. Stop
other owned tests and compilation before measurement.

Compare the same platform, VS Code executable, Node/Lua runtime, workload,
settings and sample counts. Reports retain source, fixture, binary and runtime
SHA-256 identities and raw samples. For baseline p95 `B`, the incumbent limit is
`min(ceiling, max(2 * B, B + allowance))`; the frozen allowances, ceilings and
retention bounds remain in [the runner](acceptance/run_vscode_resources.py).
Collected retention compares find cycles 100 and 300 outside timed work: at most
4 MiB host-heap and 2 MiB helper-private growth, and at most 8 MiB each above the
baseline's total retained values. Missing equivalent memory accounting is
unmeasured. API completion and controlled callbacks do not measure rendered UI,
physical input or ordinary-use value.

Optional `--node` and `--ripgrep` select already installed tools for the separate
[Task](../hosts/vscode/test/task-resources.js) and
[saved-file search](../hosts/vscode/test/results-resources.js) policies.
The [presentation workload](../hosts/vscode/test/presentation-resources.js)
also keeps its own fixed budgets. These workloads do not replace the document comparison.
See [compatibility](../docs/compatibility.md) for host limitations.

The optional [compiler recovery probe](acceptance/recipe_compiler_recovery.lua)
requires an already installed CMake, Ninja and GNU C++ toolchain:

```sh
python tests/acceptance/run_recipe_compiler.py
```

It uses a temporary CMake project to produce a real compiler error, compares its
location with native `:make`/quickfix, follows RE35 Results, edits and explicitly
saves, changes current selections to Release/targetB, and retries the original
Debug/targetA task. It checks actual child argv/cwd and the compiled program's
configuration and target. Tool paths can be supplied by `RE35_TEST_CMAKE`,
`RE35_TEST_CXX` and `RE35_TEST_NINJA`. Missing prerequisites fail explicitly;
nothing is installed. The separate runner accepts `--nvim`, `--timeout` and
`--report`. Report destinations must be JSON files below this repository's
ignored `.artifacts/`; existing files are replaced only when they identify
themselves as records from this probe. Local reports contain paths and execution
details and use `.artifacts/usage/` by default.

This is controlled actual compiler/editor integration, not physical UI,
non-implementer observation or human timing. It does not verify process-tree
cancellation. The default runner never discovers this optional fixture.

The optional [process ownership probe](../docs/development/process-ownership.md)
uses an already built `ce_process_scope` and actual parent/descendant processes.
Its separate runner checks normal exit cleanup, cancellation, timeout and
helper crash with truthful confirmation, plus deliberate Linux detachment.
It installs nothing and is separate from the default builtin-only suite.

The optional route comparison runner uses only the already installed Neovim:

```sh
python tests/acceptance/run_routes.py --report .artifacts/usage/routes.json
```

Use `--select replacement` or `--select recipe` to run one comparison. It executes
actual native commands, Session forms and finite recipe child processes; entry
keys are modelled and no human time is measured. Fairness controls include
single/multiple ASCII occurrences, metacharacters, prepared native command
history, and recipe first/repeated/retained execution as separate endpoints.
Reports include source/fixture hashes and belong in ignored `.artifacts/`.
The default fixture suite does not silently run these acceptance probes.

## Actual checkout compiler recovery

An explicit actual-checkout compiler recovery probe uses installed CMake,
Ninja, GNU C/C++ and a Lua 5.1-compatible runtime library:

```sh
python tests/acceptance/run_checkout_recovery.py --lua-runtime /path/to/libluajit.so --report .artifacts/usage/checkout-recovery.json
```

Use `--cmake`, `--cc`, `--cxx`, `--ninja` and `--nvim` for explicit tool paths.
Missing prerequisites fail; none are downloaded. The probe copies source roots
into an owned temporary directory under `.artifacts`, injects a compiler error
only into that copy, and uses the shared development profile and target driver.
It exercises Project Results navigation, Tasks cancelled save review, Results
retry, selected-file saving and original Debug/ce_cpp native validation under
current Release/ce_stdio selection. Reports retain copied-source hashes and
native execution records; fresh report paths preserve failed runs. It is not a
human timing trial and is not part of the default dependency-free suite.

## Structured search integration

The optional structured-search integration uses an already installed ripgrep:

```sh
python tests/acceptance/run_ripgrep.py --report .artifacts/usage/ripgrep-integration.json
```

Use `--rg` and `--nvim` for explicit executable paths. It installs nothing and is
not selected by the default suite. Default provider-data and transport-boundary
fixtures remain executable without rg; transport doubles are not engine evidence.

## VS Code task and presentation checks

The optional VS Code runner also accepts `--node /absolute/bin/node` for actual
file-document/Save/direct-task checks. Supplying `--recipe-checkout`, `--cmake`,
`--ninja`, `--cc` and `--cxx` runs canonical RE35 configure/build/validation
recipes and a known missing-target failed-step stop against a fresh artifact cache.
`--process-helper /absolute/build/ce_process_scope` adds optional owned-group
cancellation checks. Without it, direct-child scope is explicit. The actual
sequential fixture checks original choices, generated cwd, stale inputs/context,
teardown, timeout, descendant stop and the shared parent output cap.
All tools must already exist; profile imports start no task by themselves.
The same explicit Node/compiler options exercise an original Debug/ce_cpp
failure, owned source navigation, actual editor repair and selected Save, then
fresh retry under current Release/ce_stdio selection. Settings, physical-root,
retention and copied/consumed receipt refusals are included. A separate
controlled native-callback fixture checks repeated view routes, stale source
refusal/Return and review cleanup; it does not measure physical UI gestures.
`run_vscode_resources.py --node ...` separately measures the fixed-budget small
task workload after incumbent document measurements. Do not run resource probes
concurrently with compilation or functional suites.

The actual VS Code fixture also runs `test/presentation.js` against the actual
shared helper with explicitly controlled native callbacks. It checks six-scene
resolution/cache, optional-information projection, protected facts, original-item
identity, configuration ownership and stale-view refusal. The aggregate also runs
`test/presentation-native.js`, `test/presentation-live.js` and
`test/presentation-scenes.js` for native widget lifetime/validation, same-form
appearance refresh and the established UI action routes. Controlled widgets and
admissions are labelled explicitly; actual editor checks remain separate from
those boundary fixtures. The scene cases preserve original active/checked items,
text/filter and review owners and require a fresh semantic action after cosmetic
refresh. Inspection rows cannot dispatch work. Controlled callbacks
do not establish native renderer timing or physical usability. The resource
runner adds a separately budgeted presentation workload with 5 warmups/30 samples
and 60 appearance/cache/dispose cycles; its immediate native callbacks are
labelled separately from actual editor API timings.

Standalone `node hosts/vscode/test/task-process.js` tests real direct processes,
capture stress and observed termination; `node hosts/vscode/test/task-inputs.js`
uses real disk stamps and controlled editor save participants for failure races.
The latter exercises exception boundaries rather than native editor interaction. Their
temporary directories remain inside ignored `.artifacts` and are verified before
cleanup. Actual editor Save and execution need their own host checks.
`node hosts/vscode/test/task-sequence.js` controls completion and between-step
callback schedules. It establishes race handling, not actual OS termination.

## Adding a fixture

Place a self-contained `test_*.lua` file in `tests/` or `tests/regression/`.
Return normally; do not call `qa!` or `cquit`. The harness owns process exit and
the success marker. `CE_TEST_ROOT` contains the repository root;
`RE35_TEST_TMP` contains the fixture's temporary directory.

```lua
local H = require('helpers')
local root = H.repo_root()
local folder = H.tempdir('sample')
H.eq('expected', 'expected', 'Example assertion')
H.ok(folder:find('sample', 1, true), 'Temporary directory is available')
```

Use real editor/service effects when behavior depends on them; doubles should
make contract boundaries explicit. Keep user records, credentials, personal
paths and generated build/test reports out of fixtures.

The presentation probes distinguish actual helper/action calls, controlled
native events and actual Windows Quick Pick/Input Box/virtual-document APIs.
`presentation-native.js` checks controller lifetime and validation;
`presentation-facts.js` checks exact Unicode text, the 1 MiB read-only boundary
and inspector ownership; `presentation-scenes.js` exercises the production
action modules; `presentation-live.js` preserves the exact prepared review and
checks same-widget updates. Linux uses declared widget/editor facades and does
not establish desktop GUI behavior. None of these probes measures physical
gestures, native pixels, font coverage or ordinary-use acceptance.
