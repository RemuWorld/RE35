# Core and host contracts

This reference states the integration boundaries used by the VS Code host.
It is not a claim of complete host parity or additional supported applications.
See [development](../development.md) for source locations and build setup.

## Responsibilities

The editor-independent Lua core validates command/document/profile/workflow
data and produces structured results or plans. The VS Code host owns live
documents, source versions, persistence, key acquisition, UI, external tools,
review and actual effects. The contextual parser is a separate pure data module;
its editor connection owns acquisition and execution. Display history is not an
execution queue or authorization receipt.

Stable command IDs connect discovery, direct invocation, compositions and input
rules. Portable definitions do not contain editor objects, process handles,
callbacks, machine mappings or permission to apply an old review. A retained
unsupported declaration stays unavailable instead of gaining an implementation
through import.

## Protocol and native ABI

Protocol 1 uses strict UTF-8 JSON. Input/output frames are bounded to 1 MiB;
exact JSON escaping and envelope bytes count. Duplicate keys, invalid UTF-8 or
surrogates, nonfinite numbers, depth over 64 and integers beyond the exact 53-bit
range are refused. Arrays, objects and null remain distinct. The VM allocator
has a 32 MiB budget.

Responses are `{ "ok": true, "value": ... }` or
`{ "ok": false, "error": ... }`. Native transport failures are separate from
semantic refusals. `ce_stdio` carries one operation and JSON payload per line;
the bridge loads only core modules in its explicit manifest using a Lua 5.1 C ABI
runtime. It does not load Neovim or execute host callbacks from JSON.

C ABI 1 exposes `ce_create`, `ce_call`, `ce_destroy`, `ce_free` and
`ce_abi_version`. Calls use the creating thread. Idle destruction may use another
thread for managed finalizers, but must not race with a call. Destroyed handles
must not be reused; only returned buffers are released with `ce_free`.

The request lifecycle separates selection, invocation, claim and completion.
Claim immediately before the host effect using the current generation,
capabilities and target identity/revision. Stale selection, duplicate claim and
duplicate completion are refused. UI close, cancellation and engine disposal
are different operations. Disposing core data alone does not kill host processes.

## Coordinates

Shared Document positions use zero-based `line` and `character`. Ranges have an
exclusive end. `encoding` declares character units, not the encoding of JSON:

| Encoding | Character unit |
| --- | --- |
| `utf-8` | UTF-8 bytes |
| `utf-16` | UTF-16 code units; supplementary characters occupy two |
| `utf-32` | Unicode code points |

Strings are valid UTF-8. Coordinates must end at a complete Unicode character;
they do not promise grapheme-cluster, display-cell or visual-column semantics.
VS Code adapts UTF-16 positions explicitly. Project-search/compiler providers
may have different source coordinates and must declare and convert them.

A Document snapshot carries `uri`, opaque `revision`, `encoding` and `lines`.
The core checks bounded shape and Unicode; the host resolves resource ownership
and permissions. The host must distinguish a closed-and-reopened document from
the earlier object even if URI and text match. It owns line endings, file
encoding and final-newline behavior.

## Documents

Document v1 accepts at most 2,000 lines / 256 KiB of line-content bytes. The host
selects additive stateless Document v2 above those limits, up to 10,000 lines /
1 MiB. Search and replacement remain single-line, literal, case-sensitive and
non-overlapping. They perform no host I/O or implicit save.

V2 pages contain complete lines plus absolute `start_line`, whole-document
`total_lines`/`total_bytes`, URI, revision and coordinate encoding. Pages are
limited to 256 lines / 64 KiB; a line is at most 64 KiB. The core retains no
uploaded document, upload owner or cross-call document handle.

The bridge adds `document_page_capabilities`, `document_page_search`,
`document_page_prepare_replace` and `document_page_apply`. The host requires
compatible advertised capabilities. It owns ordered complete coverage, detects
gaps/overlap/revision changes, and enforces aggregate counts, exact transport
bytes and a 5-second stage budget. A partial search must stay partial; incomplete
processing cannot authorize a partial replacement.

V2 find/replacement text is bounded to 4 KiB / 64 KiB. Retained search locations
are limited to 200 with 1,024-byte excerpts. Replacement is bounded to 4,096
edits, a 512 KiB compact plan, 1 MiB whole output and 256 KiB page output.
Line separators are excluded from content counts. Encoded frames can still
refuse otherwise in-scope documents.

Plans contain identity, coordinates, expected old text and proposed text.
Core Apply revalidates source and exact plan consistency and returns proposed
lines; it cannot prove user consent or mutate an editor. The host privately
retains the reviewed plan, binds explicit Apply to its owner, recaptures the
same live source and checks write permission immediately before one editor
transaction. Cancellation/staleness leaves it unchanged. An error after a real
edit must report possible/applied effects rather than invite automatic replay.

## Sequential execution and input

Only observed successful completion advances a composition or contextual
transition. Handoff is a distinct outcome. A cancelled, failed or unknown
effect stops later work; earlier completed effects remain. There is no generic
transaction across edits, file saves and processes and no composition-wide Undo.

Input ownership is explicit and source-bound. Ordinary typing passes to the
editor outside that scope. Complete minimal rules execute immediately; only
unfinished prefixes wait. No idle timer executes a rule. Pending prefixes and
old queued input are retired on cancellation/source loss, not replayed into a
new editor. Live state and completion tickets are not persisted or serialized
as portable authority.

## Process ownership

Direct-child scope confirms only the launched process's exit. It does not prove
that descendants stopped. An available configured process helper can own a
Windows Job or Linux session group. A missing selected helper is refused rather
than silently downgraded.

On Windows, the helper creates a suspended tool atomically inside a private Job
with kill-on-close before resuming. Cancellation stops that Job; it does not
promise POSIX-style graceful signals. Confirmation needs original-parent exit
and an observed empty Job.

On Linux, an anchor pins group identity while cancellation sends TERM, waits
the configured grace period and escalates to KILL if needed. Observation requires
adequate `/proc` visibility; unreadable or bounded-out observation is
unconfirmed. These native capabilities do not constitute a Linux desktop VSIX
support claim for this release.

Intentional detached daemons, services and group escapes are excluded. RE35 is
not a process sandbox. Results distinguish a termination request, actual exit,
scope, confirmation, forced escalation and unknown/unconfirmed descendants.
A lost completion receipt remains unconfirmed even when the operating system
may have cleaned up the scope.
