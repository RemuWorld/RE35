# Compatibility and limits

RE35 0.5.0 targets Windows x64 desktop VS Code and trusted local
workspaces. The platform VSIX includes its helper and Lua runtime. Other desktop
packages, Remote, web and virtual workspaces are outside this release's scope.
An installation requirement is not evidence that every supported VS Code version
or optional extension combination has been tested.

## Input and interface

- Ordinary VS Code writing, selection and Undo/Redo are the baseline. RE35 does
  not require Vim modes or implement its own text editor.
- Contextual input and function-key rules require explicit activation, one local
  file and one cursor/selection. Active vscode-neovim or VSCodeVim blocks this
  ordinary input owner; RE35 does not disable another extension automatically.
- Contextual text/prefix rules and unmodified contributed keys are bounded.
  General count/operator grammar, arbitrary modified-key capture, recursion and
  multiple cursors are not implemented.
- This release uses native forms and diff controls. The custom code-visible UI
  is on hold; the separate-tab prototype is not the selected interface.
- Physical IME, shortcut priority, focus/resize and accessibility require actual
  installed testing. API or controlled-event tests do not establish those results.
  The release notes identify completed checks and remaining cases.

Neovim code and definitions remain historical material without future support
or compatibility commitments. Existing `edit.*` IDs are not reinterpreted as
ordinary `editor.*` actions. Use the documentation at
[`v0.4.0`](https://github.com/RemuWorld/RE35/tree/v0.4.0) for that implementation.

## Documents

Current-document search/replacement is single-line, case-sensitive and literal.
It does not support regex, multiline matches or replacement expressions.

| Boundary | Supported limit |
| --- | --- |
| Small document path | 2,000 lines / 256 KiB of UTF-8 line content |
| Paged document path | 10,000 lines / 1 MiB of UTF-8 line content |
| Paged line/page | 64 KiB per line; 256 complete lines / 64 KiB per page |
| Paged retained search locations | 200, with an explicit truncation notice |
| Paged replacement | 4,096 edits / 512 KiB compact plan / 1 MiB output |
| Processing | 5 seconds per paged processing stage |

Line separators do not count toward content bytes. Exact encoded transport
limits still apply, so a smaller document may be refused if its escaped plan or
request exceeds another quota. A failed, stale or incomplete page never permits
a partial replacement. Apply does not implicitly save. See
[core contracts](reference/core-contracts.md#documents).

## Projects, execution and storage

Builtin project search is bounded, literal and case-sensitive; it does not read
ignore files. Optional ripgrep differs in syntax, ignore policy and limits.
Saved-file search does not include unsaved editor text. Partial results remain
partial. See [workflow data](reference/workflow-data.md#project-search).

Compositions are not atomic transactions or one Undo. Cancellation does not roll
back completed effects. An admitted but unconfirmed edit needs inspection before
retry. Process cancellation guarantees depend on the reported direct-child or
owned-scope backend; detached services are excluded.

Portable profiles, saved commands, input definitions and live execution history
are different data. An imported definition does not supply missing host support
or grant execution approval. See [customization](customization.md#state-and-history).
