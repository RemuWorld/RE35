# Structured project search

`search.project_text` uses the same command ID and query contract in Neovim and
the optional VS Code host. Builtin search is the default and needs no external
executable. Select an engine with `adapters.project_search` in a version 1
portable profile:

```json
{ "adapters": { "project_search": "ripgrep" } }
```

This is a profile fragment, not a complete import file. In Neovim, Settings →
Backends → Search project text edits that choice. In VS Code, import the profile,
select a local Project context and use **RE35: Search Project Text**. Install
ripgrep separately. A missing selected engine reports unavailable and never
switches to another provider automatically. Neovim's optional Telescope route
is a picker handoff rather than this structured engine; VS Code does not
implement that provider.

Ripgrep accepts a single-line query with explicit `mode` (`literal` or `regex`)
and `case` (`sensitive` or `insensitive`). Defaults are literal and sensitive.
Queries must be nonempty UTF-8, single-line text of at most 4096 bytes. Regex
syntax belongs to ripgrep's default engine; PCRE2 and multiline queries are not
requested. Builtin supports only literal, sensitive searches. Neovim's backend
recovery can retain a literal, sensitive query; it does not reinterpret regex
or case-insensitive input as builtin syntax. Reopen the command and choose
supported options explicitly when changing those semantics.

Ripgrep returns JSON rather than opening another picker. RE35 verifies saved
UTF-8 contents and byte boundaries, retains all same-line matches within the
result limit, and opens owned Results. Neovim builtin search retains only the
first match on each matching line; VS Code builtin retains each nonoverlapping
match. These location-count differences do not change the selected query mode.

Result coordinates are one-based UTF-8 byte columns with an exclusive range end
when available. A UTF-8 BOM is encoding metadata, not a source column. Neovim
navigates byte columns; VS Code validates and converts them to UTF-16 positions.
Navigation refuses changed files, unsaved editor contents and outside-root
targets. Searching leaves source text, undo, editor cwd and Neovim's quickfix
and location lists unchanged.

Hidden files, symlinks and common generated directories are excluded. Ripgrep
respects project `.gitignore`, `.ignore` and `.rgignore` rules, including projects
without a Git repository. Parent/global ignore rules and external rg configuration
are disabled for this invocation. Non-UTF-8 output or files, binary files and
unverifiable targets are excluded explicitly when encountered. A completed
search describes this filtered scope, not every file on the machine.

## Local limits

Neovim setup `ripgrep` and VS Code machine setting `re35.projectSearch` accept
only `command` and `limits`. Keep executable paths outside portable profiles.
Neovim override:

```lua
ripgrep = {
  command = 'rg',
  limits = { results = 3000, read_bytes = 32 * 1024 * 1024 },
}
```

| Limit | Default | Ripgrep maximum |
| --- | ---: | ---: |
| results | 1000 | 5000 |
| max_file_bytes | 1 MiB | 4 MiB |
| read_bytes | 8 MiB | 64 MiB |
| output_bytes | 8 MiB | 16 MiB |
| milliseconds | 5000 | 15000 |

In VS Code, use the same fields under `"re35.projectSearch"`; a shared local
limit must also fit builtin's smaller ceilings if the profile selects builtin.
Neovim builtin uses the separate `file_search` traversal settings described in
[file search](file-search.md#limits-and-partial-results). Its maxima cannot be
raised. Both hosts' builtin traversal is bounded to 3000 files, 500 directories,
20000 entries and depth 24.

`read_bytes` bounds host verification reads, including attempts later rejected
as stale. It is not a bound on every byte the external engine internally scans.
Per-record JSON parsing is limited to 1 MiB. Preview text is limited to 512 bytes
at a complete UTF-8 boundary. Time, output, read and result limits retain visible
partial results; process completion and exhaustive coverage are separate facts.
Malformed JSON, invalid byte ranges or missing/misordered summary fail the run.

Cancellation waits for the directly spawned process to exit, with bounded signal
escalation. Descendant termination remains unknown; this engine route does not
promise owned-group termination. A limit-triggered stop is partial completion,
not a successful exhaustive scan.

## Reuse and provenance

Retained outcomes expose the engine, mode, case, effective limits, coordinate
convention, ignore policy and no-fallback behavior. Neovim's default exported
task reports exclude queries, executable paths, file paths and output. A retained
Neovim retry refuses changed engine configuration/limits or a changed discovered
project root instead of silently changing scope. Reopen the command to search a
new scope. VS Code retains four finished searches; **RE35: Project Search
Results** reopens them without starting a search. Use **RE35: Search Project
Text** for a fresh invocation.

Saved-file search does not use Document snapshots, so the document find/replace
line and byte limits do not define its scope. See the
[VS Code guide](../hosts/vscode/README.md#search-saved-project-files) for native
controls and local setup. Maintainer ownership rules are in the
[Results/search contract](development/results-search-contract.md), and test
host limitations are described in [compatibility](compatibility.md).

The engine's output contract is based on the upstream
[ripgrep JSON printer](https://docs.rs/grep-printer/latest/grep_printer/struct.JSON.html).
