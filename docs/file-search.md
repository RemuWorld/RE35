# Neovim file finding and project text search

This guide describes Neovim's file finder, backend Settings and builtin text
search. Optional structured ripgrep and the VS Code text-search route are in
[search providers](search-providers.md). VS Code does not currently expose this
file finder or the Telescope integration.

`file.find` and `search.project_text` are stable command IDs. With the default built-in provider enabled, `\ f f` finds a project file and `\ f g` searches project text. User bindings may replace these routes. `file.open` still opens an explicitly entered path.

The default `builtin` backend needs no additional plugin, executable, or index database. It finds the project from the originating source file using the shared project markers; without a marker it uses the source file's directory. Open the commands from a normal source window. Discovery stays asynchronous and never changes source text, undo history, cwd, quickfix, or the location list.

## Choosing a backend

A version 1 profile's `adapters` object selects each capability independently:

```json
{
  "file_find": "builtin",
  "project_search": "telescope"
}
```

An omitted selection defaults to `builtin`. The older `adapters.picker = "telescope"` preference selects Telescope for these capabilities when no individual choice is supplied. A missing or unknown selected backend leaves the stable command visible with an unavailable reason; it never silently executes another backend.

The `picker.telescope.find_files`, `picker.telescope.live_grep`, and `picker.telescope.buffers` IDs remain available when that optional integration is registered. The first two default tree routes now lead through the semantic IDs. Telescope keeps its own UI, query syntax, selection, cancellation, and configured picker options. Opening its picker records a handoff, not a completed selection. An explicit `query` argument becomes Telescope's initial `default_text`; query syntax still belongs to its picker. This document's literal-search and scan-limit rules describe the built-in backend.

Settings → Backends displays each capability's declared or inherited choice.
Enter offers inheritance, `builtin`, or `telescope`; project text search also
offers `ripgrep`. An unknown current declaration remains selectable so that
inspection does not discard it. Selection creates a draft and review: `a`
applies, `d` stages a reset to inheritance, and `u` undoes an applied Settings
change. These actions never run a search or install a dependency.

## Recover an unavailable backend

For an unavailable `file.find` or `search.project_text`, select the command and open Details (`Ctrl-h` by default), then press `c` to configure its backend. The targeted route is **Details → c → Settings / Backends → select → review / a Apply → original Details → Enter**. Successful Apply of exactly that one capability change returns automatically to the original semantic ID and source window, retaining the command-search query and selection. Esc from those Details returns to the original command search. Apply never executes the command.

Generic Settings and multiple-change edits retain the separate Return row when their receipt remains valid. A pending draft must be applied or discarded before Return. To undo a single change after automatic return, explicitly reopen Settings and use its Undo action; Undo and Reload do not automatically run or return to a command.

If an explicit `search.project_text` execution supplied a literal,
case-sensitive `query` while its selected backend was unavailable, this route
retains that one nonsecret query. It is shown in recovered Details and remains
dormant until a separate Enter executes it once. Only nonempty, single-line
UTF-8 text of at most 4096 bytes is retained. Larger or invalid queries and
explicit regex/case-insensitive options refuse recovery with an explanation.
No generic argument or secret cache is created.

Recovery belongs to the original command and source. If either changes while
Settings is open, Return can refuse recovery and ask you to reopen the command.
The retained query is local and temporary; it is not included in portable
profiles. Recovery never selects an automatic fallback or launches the command.

## Built-in behavior

The finder scans regular files, then presents the native RE35 selector. `/`
filters the filename list; Enter selects. Back/Esc cancels and retains the scan
snapshot in Tasks. Changed sources or missing/changed targets are refused with
a reason before opening a file.

Text search accepts one nonempty UTF-8 query line, at most 4096 bytes. Matching is literal and case-sensitive, with one result per matching line. It reads saved UTF-8 files rather than unsaved buffer contents. UTF-8 BOM and CRLF are supported; location columns use Neovim's byte positions. NUL-containing files, UTF-16, malformed UTF-8, and oversized files are skipped and counted.

Completed text search retains a task-owned location snapshot and opens the shared Results workspace when the originating UI is still at the same location. Leaving that UI does not reopen it on completion; the record remains available through Tasks → Results. Results provides filtering and preview. Native search locations include a saved-file revision: changed, deleted, outside-root, symlink, or loaded-and-modified targets are refused before navigation. Save the target and search again. Existing compiler locations without this native revision keep their existing behavior.

Dot-prefixed entries and `node_modules`, `build`, `dist`, `target`, `__pycache__`, and `vendor` directories are skipped. All symlinks are skipped, including links inside the root. Directory pages contain at most 64 entries; directory and file handles are released after completion or cooperative cancellation. This is a bounded saved-file scan, not Git ignore parsing or a persistent project index.

## Limits and partial results

Default maxima are:

| Bound | Maximum |
| --- | ---: |
| Files inspected | 3000 |
| Directories opened | 500 |
| Directory entries | 20000 |
| Directory depth | 24 |
| Bytes read in total | 8 MiB |
| Bytes per text file | 1 MiB |
| Result locations | 1000 |
| Scan duration | 5000 ms |

Local setup option `file_search` may lower these bounds using `files`, `directories`, `entries`, `depth`, `bytes`, `file_bytes`, `results`, and `milliseconds`; it cannot raise them. Reaching a limit retains partial results and marks the limit in `locations_message`. Read errors and changing files are counted; warnings are bounded. A successful empty scan means no results within the stated scope and limits, not an exhaustive search of excluded files.

Tasks retains the root, query, locations, ready/empty/error status, partial-result
notice, scan statistics and bounded warnings. Cooperative cancellation retains
the partial snapshot. Closing a selector or refusing a stale target cannot
invoke a different command or create a second operation.

## Choosing a larger search scope

The builtin backend is a dependency-free bounded scan. For project ignore rules,
regex, case-insensitive search or larger configurable read limits, explicitly
choose [ripgrep](search-providers.md). Telescope is a separate picker handoff;
its selections do not become native task-owned search results. Partial results
remain visible, and reaching a limit never switches the backend automatically.

See [compatibility](compatibility.md) for host scope and known limitations,
[search providers](search-providers.md) for engine options and portable
declarations, and [architecture](development/execution-structure.md) for
recovery ownership.
