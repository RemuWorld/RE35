# Owned Results and saved-file search

The optional VS Code host implements owned Results and saved-file search.
These host services own filesystem/editor authority. Shared search declarations
remain pure Lua; Document v1/v2, Protocol 1 and C ABI 1 keep their existing limits.

## Task observation

`task-plan` retains each declared tool's errorformat with its exact resolved argv.
`task-sequence` preserves that metadata and each child's bounded output.
`task-service` captures original source/loaded-document stamps and editor owners
after the explicit Save decision, revalidates admission, and launches the task.
Terminal `TaskResults.capture` runs after the actual process outcome/core
bookkeeping. An observation error cannot change success/failure/cancellation or
authorize another process. Tasks retains the error alongside raw output.

The supported errorformat subset is `%f:%l:%c: %m`, `%f:%l: %m`,
`%f(%l\,%c): %m`, `%f(%l): %m`, and ignore-all `%-G%.%#`.
Unsupported whole formats remain output, without approximate regex translation.
This is not Neovim's full quickfix parser, multiline state or directory stack.
ANSI-decorated/unrecognized lines remain captured text. Severity is reported
only when the message explicitly identifies it; otherwise it is `unknown`.

GCC/G++ direct argv with explicit `-fdiagnostics-column-unit=byte`, origin one,
UTF-8 input and no response-file ambiguity permits byte-column conversion to
VS Code UTF-16. Last explicit unit/origin options win. Other columns remain
reported data; navigation uses the known line's start and labels that limitation.
MSVC-style messages can therefore supply line navigation without claiming a
universal column unit. This follows the
[GCC diagnostic coordinate options](https://gcc.gnu.org/onlinedocs/gcc/Diagnostic-Message-Formatting-Options.html).

At most 1,000 diagnostics and 10,000 nonempty output lines are inspected; messages
are at most 8 KiB and paths 4,096 characters. Source verification has an 8 MiB
aggregate attempted-read budget and a 1 MiB per-file navigation bound. A temporary
same-revision read cache avoids repeated reads for multiple diagnostics in one
file, then releases all source text before retaining the outcome. Later navigation
always rereads. Limits and partial process output remain explicit.

Only the originally declared source and original relevant loaded documents have
admission revisions. Other diagnostic files remain inspectable with an unavailable
original-revision reason. Dirty run-saved documents, later edits, replacement,
closed/reopened owners and changed versions refuse their old locations, including
Undo restoring equal text. Current configuration/target selection does not retarget
the original result. Four result owners are retained with four Tasks.

## Location ownership

`result-locations` owns private WeakMap receipts. Serialized/copied locations grant
no navigation. Root identity, physical containment, regular-file identity/stamps,
valid UTF-8 and coordinate boundaries are checked before reading/opening and after
editor callbacks. Nonblocking, no-follow flags apply where available. UTF-8 BOM is
encoding metadata; CRLF terminators are not columns. Dirty or mismatching editor
text and ambiguous owners refuse navigation. The final selection is set only
after fresh validation; opening a file does not grant later dispatch authority.

## Project search ownership

`ProjectSearch.prepare` validates shared request/report data and binds the original
profile, project root, core, local settings and optional executable identity.
`start` consumes one owned receipt, revalidates, claims one `search.project_text`
operation, and admits the engine. Completion sends bounded outcome/provenance
metadata to the core; locations, source bytes and process handles remain host-local.
Loss of the core, host, profile or workspace cancels active work. Current logical
configuration/target selection cannot retarget an admitted search.

Provider comes from `adapters.project_search`; local `re35.projectSearch` holds
only executable/limits. Builtin implements literal sensitive saved-file search.
Ripgrep is optional, uses exact argv and streamed JSON, honors project ignore
files, and exposes explicit literal/regex and sensitive/insensitive options.
Missing/unsupported selected providers are unavailable, with no automatic fallback,
installation, shell or invocation of VS Code's search screen.

Both engines verify bounded saved UTF-8 files, physical paths, all same-line
matches and strict byte boundaries. Navigation adapts the retained one-based UTF-8
bytes to zero-based UTF-16. Files stay unmodified; unsaved documents are not search
inputs. Binary/encoding/generated/hidden/symlink filtering, caps, scan errors and
omissions remain explicit. Builtin does not interpret ignore files; provider
provenance states that difference. Native search and RE35 search are separate.

The [shared provider guide](../search-providers.md) defines query/limit semantics.
Builtin additionally bounds traversal to 3,000 files, 20,000 entries, 500 directories
and depth 24. Ripgrep uses one worker, no mmap, parent/global ignore or external
configuration. Records are at most 1 MiB; incomplete/malformed/trailing JSON fails
the run. Read/result/output/time limits retain visibly partial results.

Ripgrep owns only its direct child; descendants remain unknown. Explicit cancellation
and limits request TERM followed by KILL after 200 ms, await actual close and retain
partial matches. Inherited pipes drain for at most two seconds after child exit.
`executionComplete`, filtered-scope coverage, termination and core completion are
separate facts. Four finished searches are retained; evicted owners lose navigation.

New bridge data operations are `search_request {provider,query,options?}`,
`search_manifest {provider,available}` and `search_report {request,available}`.
They validate exact fields through the existing lazily loaded search-provider
module and grant no filesystem/process rights. No high-volume search payload
crosses the 1 MiB IPC frame. Recovery with original arguments uses fresh
admission as described in the
[recovery contract](task-recovery-contract.md).
