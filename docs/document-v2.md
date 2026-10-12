# Stateless paged Document v2

Document v1, Protocol 1 and C ABI 1 remain unchanged. This document defines the
implemented data and host boundaries for both editor hosts.

## Supported scope and limits

Matching remains single-line, case-sensitive literal text. No regex, multiline
matching, provider install or implicit save is introduced. Existing small
documents continue through v1; Neovim `ef`/`er` and the optional VS Code host
use v2 when the document exceeds 2000 lines or 256 KiB of line-content bytes.
The public Neovim `Document.snapshot` function remains v1.

| Boundary | Limit |
| --- | --- |
| Whole document | 10,000 lines; 1 MiB UTF-8 line-content bytes |
| Independent page | 256 complete lines; 64 KiB line-content bytes |
| Individual input/output line | 64 KiB |
| Find / replacement | 4 KiB / 64 KiB of single-line UTF-8 |
| Retained search locations | 200; each text excerpt at most 1024 bytes |
| Aggregate replacement | 4096 edits; 512 KiB encoded compact plan |
| Rendered output | 1 MiB whole document; 256 KiB per page |
| Transport | 1 MiB exact encoded request/response envelope |
| Processing | 5 seconds per processing stage, checked at page boundaries |

Line separators are excluded from content byte counts. Hosts retain their own
line-ending/final-newline semantics. A quota, oversized individual line or
unrepresentable escaped frame refuses replacement rather than applying a prefix.
Search distinguishes retained-location truncation from incomplete processing.
Neovim has bounded synchronous page calls; it does not promise mid-call
cooperative interruption. Canceling review never edits the source. VS Code
request timers include queue time and close the helper on timeout or disposal.

## Additive API

`command_environment.core.document_v2` exposes `capabilities`, `validate`,
`search`, `prepare_replace` and `apply`. Every page is exactly:

```json
{
  "contract_version": 2,
  "uri": "file:///project/main.cpp",
  "revision": "42",
  "encoding": "utf-8",
  "start_line": 256,
  "total_lines": 10000,
  "total_bytes": 1048576,
  "lines": ["return value;"]
}
```

`start_line` is zero-based and result ranges use absolute document lines.
`total_lines`/`total_bytes` declare the whole-document scope, not proof of its
completeness. URI, opaque revision, UTF-8/16/32 character units and half-open
ranges retain the v1 definitions. Arrays are dense, objects have exact keys,
and foreign callbacks/metatables, malformed Unicode and unknown fields fail.

The bridge adds `document_page_capabilities` (`{}`), `document_page_search`
(`{page,query,options?}`), `document_page_prepare_replace` (`{page,find,replace}`)
and `document_page_apply` (`{page,plan}`). These names retain Protocol 1's
operation alphabet. Capabilities return version 2, supported operations and the
limits above. V1 operation names and their rejection behavior remain unchanged.

Page plans contain identity/scope, line count, find/replacement, match count,
edits and rendered byte count. Each edit carries `range`, `old_text` and `text`;
there are no original/proposed whole-document copies on the wire. `apply`
regenerates and compares the exact plan against its supplied page, returning
proposed page lines without a host write. It cannot confer user consent.

Hosts compact retained plans further: common identity and find/replacement
appear once, with ordered page summaries and edits. Exact core page plans are
reconstructed only for validation. Neovim releases the original capture after
preview and retains at most 100 clipped changed-line previews. VS Code retains
its frozen source and bounded proposed lines for native diff presentation.
Each host recaptures the same document before Apply.

## Independent pages, host-owned completeness

Matching is single-line, case-sensitive and literal. A match
cannot cross a line boundary, so pages containing complete lines can be processed
independently by pure core calls. The core retains no uploaded document,
upload owner, expiry timer or inter-call document handle.

Each page carries document identity, revision, coordinate encoding, its absolute
starting line and declared scope. Page results and edits use absolute document
ranges. The host owns the immutable capture, page ordering, cumulative counts
and byte budgets, completeness, cancellation and the final reviewed edit set.
Passing cumulative counts to the core does not independently prove that the
host supplied every page. The host must detect gaps, overlap, duplicate pages,
revision changes and incomplete processing before claiming a whole-document
result or authorizing Apply. A partial result remains explicitly partial.

Hosts apply the complete edit set in one transaction. After explicit review, they validate the
complete ordered edit set, exact private review receipt, live document identity,
version, original text at affected ranges and write permission before one
host-owned edit/Undo transaction. Core consistency checks are not review
authorization. Cancellation or a stale page leaves the document unchanged.

## Compact wire data and compatibility

Document v2 adds capability discovery and page operations while preserving v1
schemas, Protocol 1's 1 MiB encoded-frame bound and C ABI 1. Wire plans contain
ranges, expected old text and replacement text. Hosts generate previews from
validated edits and retain authorization privately.

Quotas apply to the exact encoded envelope, including JSON escaping and
metadata, and to cumulative input, results, edits, rendered bytes and processing
time. A document below the content limit can still be refused if its encoded
page or plan exceeds another quota. Both editor hosts use the limits above;
complete-line pages do not support arbitrarily long individual lines.
