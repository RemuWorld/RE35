# Shared documents and host responsibilities

Audience: maintainers and host implementers. User operations are covered by the
[command scope inventory](command-coverage.md), [Neovim configuration guide](configuration.md)
and [VS Code guide](../hosts/vscode/README.md). See the compatibility guide for host scope and known limitations.

Both editor hosts implement literal
search, reviewed literal replacement and stale-source rejection through Document v1 and the
additive stateless paged Document v2. Neovim and the optional VS Code desktop
host use the same
[`command_environment.core.document`](../lua/command_environment/core/document.lua)
and [`document_v2`](../lua/command_environment/core/document_v2.lua)
implementations rather than maintaining a JavaScript copy of matching logic.
The v1 API, coordinates and limits below are unchanged. Hosts select v2 for
documents above 2000 lines or 256 KiB of line-content bytes; its whole-document
scope is 10,000 lines / 1 MiB with separate page, line, edit and exact transport
quotas. See the [Document v2 contract](document-v2.md).

## Document v1 snapshot and coordinates

A host captures the originating document into plain bounded data:

```json
{
  "uri": "file:///project/example.cpp",
  "revision": "host-owned-opaque-version",
  "encoding": "utf-16",
  "lines": ["int main() {", "  return 0;", "}"]
}
```

`uri` is an absolute URI identity, up to 4096 UTF-8 bytes, without spaces,
backslashes or control characters. The core checks the URI shape; it does not normalize
filesystem paths, resolve aliases, open a file or decide whether a resource may
be edited. Untitled documents can use a host's absolute non-file URI.

`revision` is a nonempty opaque UTF-8 string, up to 1024 bytes. The host must
change it when document content or ownership changes. The core does not compare
versions numerically or infer that a reopened document is the same object.

`lines` is a dense array of valid UTF-8 strings without CR, LF or NUL. A snapshot
has at most 2000 lines and 256 KiB of aggregate line bytes. Line separators are
not included in those bytes. The host owns the original line-ending convention,
file encoding and final-newline policy.

`encoding` specifies **coordinate units**, not how the line strings are stored:

| Value | `character` unit |
| --- | --- |
| `utf-8` | UTF-8 bytes |
| `utf-16` | UTF-16 code units; a supplementary character occupies two |
| `utf-32` | Unicode code points |

All lines and characters are zero-based. Ranges have `start` and `end`; the end
is exclusive. Matches end on complete UTF-8 characters. The contract does not
claim grapheme-cluster or screen-cell coordinates. Neovim's byte columns and
VS Code's UTF-16 positions must be adapted explicitly at the host boundary.

Unknown snapshot fields, invalid UTF-8, sparse lines, unexpected metatables and
out-of-bound data are rejected. Failure must leave the host document unchanged.

## Lua API

```lua
local Document = require("command_environment.core.document")
local snapshot = Document.validate(captured_snapshot)
local results = Document.search(snapshot, "return", { limit = 200 })
local plan = Document.prepare_replace(snapshot, { find = "return", replace = "co_return" })
-- After explicit review, capture the same document again:
local next_lines = Document.apply(current_snapshot, plan)
-- Only the host can now apply next_lines to its live document.
```

`validate` returns detached validated snapshot data. Core validation failures
raise Lua errors; Neovim catches them for RE35 errors, and the native bridge
returns its normal `{ "ok": false, "error": ... }` envelope.

Search is single-line, literal, case-sensitive and non-overlapping. Query/find
text is nonempty, valid UTF-8, at most 4096 bytes and contains no CR/LF/NUL.
Regex, case folding, multiline matching and replacement expressions are outside
this contract. Search returns:

```json
{
  "contract_version": 1,
  "uri": "file:///project/example.cpp",
  "revision": "host-owned-opaque-version",
  "encoding": "utf-16",
  "locations": [
    {
      "uri": "file:///project/example.cpp",
      "revision": "host-owned-opaque-version",
      "encoding": "utf-16",
      "range": { "start": { "line": 1, "character": 2 }, "end": { "line": 1, "character": 8 } },
      "text": "  return 0;"
    }
  ],
  "truncated": false
}
```

The search limit defaults to 200 and accepts 1..1000. The 1 MiB serialization
budget can truncate sooner when locations repeat long lines or identities.
`truncated` must remain visible; a host must not imply that a bounded list contains
every match. Navigating a location requires the host to revalidate document
identity and revision, then its coordinate boundary.

Replacement text can be empty, otherwise valid single-line UTF-8 up to 256 KiB.
A plan contains contract version, URI, revision, encoding, find/replace text,
match count, ordered edits, original lines and proposed next lines. Each edit
has a range, literal `text` and expected `old_text`. At most 1000 matches and
1 MiB of proposed line bytes are allowed. The complete serialized Apply request,
including both snapshot and plan, must fit the 1 MiB Protocol 1 input bound. This
can reject a smaller proposal whose review data is larger and ensures that a
returned plan can round-trip through the bridge.

Plans are detached data intended to remain unchanged after review. `apply`
revalidates the current snapshot, checks the URI/revision/encoding, recomputes
the replacement and requires every plan field to match. Changed original text,
incoherent ranges/counts/output or additional fields are rejected. This proves
plan consistency and current content, not review authorization: a caller can
prepare a different coherent plan for the same source. The host must retain its
reviewed arguments or plan privately and bind Apply to that exact review owner.
Plans are not cryptographic tokens. A revision alone is not enough to authorize
an edit. `apply` returns proposed lines and performs no external side effect.

## Review and actual edits belong to the host

1. Retain the original document owner and capture a bounded snapshot.
2. Ask for find/replacement values and show the exact proposed change without
   changing document text or undo history.
3. Treat cancellation or closed review as no edit. A changed input needs a new
   plan and review.
4. After explicit Apply, recheck the active owner and capture the current source.
   Call `Document.apply` with the reviewed plan.
5. Immediately before mutation, recheck the host version and write permission.
   Apply in one host-owned edit/undo operation; report actual acceptance or
   failure. Reject a stale owner instead of redirecting to a later active editor.

The core cannot make a host edit atomic, create an undo stop or roll back an
external mutation. Those claims require actual editor tests. Neovim's `ef` /
`er` adapt RE35's captured context and Results. Its replacement preview uses
temporary extmarks and privately retains the exact snapshot and plan. Apply
requires the original environment, source context and one explicit Apply choice
with unchanged arguments. Session authorizes only the admitted executor invocation
and the command consumes that authority once; validation and native hooks cannot
borrow or replay it. The core validates that retained plan against the current
document before one buffer edit in a native undo block. Supplying all arguments
through the public execution API cannot bypass preview and explicit Apply. Preview
failure invalidates the receipt; editing reviewed inputs requires a new preview
and a separate Apply. Neither host saves the document implicitly. The VS Code
extension retains its own reviewed plan and editor owner. They share data
semantics while preserving their editor's ownership and undo behavior.

## Protocol 1 and the optional stdio host

The following additive bridge operations use the existing Protocol 1 envelope
and C ABI 1; no new native ABI is required:

| Operation | Request data | Success value |
| --- | --- | --- |
| `document_search` | `{snapshot, query, options?}` | Search result |
| `document_prepare_replace` | `{snapshot, find, replace}` | Detached review plan |
| `document_apply` | `{snapshot, plan}` | Proposed next lines |

The native target [`ce_stdio`](../native/stdio.c) wraps the same C ABI and Lua
source manifest. Its invocation is `ce_stdio <Lua-5.1-runtime-library>
<absolute-Lua-directory>`. Each stdin frame is `operation<TAB>JSON<LF>`; each
stdout frame is one JSON response and LF. Calls run in FIFO order on the creating
thread. Operation names are bounded, JSON is at most 1 MiB and malformed or
failed transport closes the helper. A core validation error is a normal error
response. Host document text is local transport data, not a diagnostic upload.

The [VS Code desktop host](../hosts/vscode) launches that helper without a shell.
Helper, Lua runtime and core paths are explicit machine-local settings; the
checkout does not ship or download a Lua binary. The backend has bounded pending
requests, responses and timeouts, and rejects queued work when disposed or when
the helper exits. Starting the helper is optional standalone-host functionality;
the Neovim plugin calls the shared Lua module directly.

## Other shared contracts and host boundaries

Document contracts describe bounded text and edit consistency. They do not
confer editor authority or define a universal LSP, workspace, process or undo
system. The following shared rules support host-owned workflows:

| Area | Shared responsibility | Host responsibility and current boundary |
| --- | --- | --- |
| Profiles and project recipes | Full schema validation, stable command links, logical configuration/target choices and scalar argv resolution | Both hosts resolve local roots/tools and own admission, sequential execution, saving, Tasks/Results and original-context recovery. VS Code supports reviewed profile replacement; profile merge and the complete Neovim workspace/LSP/Git surfaces are not implemented there. See the [workflow contract](development/workflow-contract.md). |
| Saved-file search | Provider request/options, capability and provenance data | Builtin bounded literal scans or explicitly selected ripgrep run through host-owned files/processes and source navigation. Ripgrep reads project ignore rules; builtin does not. Missing providers do not trigger automatic fallback. See [search providers](search-providers.md) and [Results/search ownership](development/results-search-contract.md). |
| Cancellation | Outcome data cannot itself prove exit | Default direct execution confirms only the launched process. An explicitly configured optional helper owns a Windows Job or Linux group, with observed scoped termination and explicit detached-process exclusions. See [process ownership](development/process-ownership.md). |
| Presentation | Versioned bounded declarations, typed edits/file codec, resolution and capability negotiation | Neovim owns terminal rendering; VS Code owns native controls and reports unsupported geometry/style. Both have reviewed appearance authoring/sharing; workflow ownership and review permissions remain separate. See the [presentation contract](development/presentation-contract.md). |

The optional native loader and installed source manifest currently list 17 core
modules, including `presentation_edit`. A helper built for an earlier manifest
must be rebuilt for that manifest. Neovim calls pure Lua in-process; the optional
desktop host uses Protocol 1 / C ABI 1. Neither transport changes the common
coordinate, validation or data-only authority semantics.

RE35 is the public project name and `require('re35')` is the canonical Neovim
entry. `command_tree` remains a same-object API alias, while
`command_environment.core.*`, native `ce_*` symbols/targets and saved
`command-tree` paths retain compatibility identities. No profile or ABI rename
is required by that naming distinction.

## Implementation checks

The [Document contract fixture](../tests/test_document_contract.lua) exercises
the shared data behavior with editor globals removed. The [Neovim workflow
fixture](../tests/test_document_workflow.lua) exercises host behavior; host and
transport checks must additionally verify actual review, version rejection,
edits, undo and cleanup in their runtimes. Those tests are distinct from console
counter checks and from an extension activation mock.

See [compatibility](compatibility.md) for host scope and known limitations.
Correctness, performance and physical interaction need separate checks when
implementing or changing a host.
