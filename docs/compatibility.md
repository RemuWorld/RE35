# Compatibility and limitations

## RE35 0.4.0

The primary Neovim host requires **Neovim 0.11 or newer** on Windows or Linux.
It uses Lua source directly and does not require another plugin, a compiler or
a language server to open the command environment. Optional commands require
their configured tools or adapters; unavailable capabilities show a reason.

Confirmed builtin theme choices persist by default; preview does not save.
`theme.persist = false` opts out. Custom theme adapters own their storage and
startup behavior. Existing profile and shared contract versions are unchanged.
Builtin Light/Dark lists use asynchronous cached observations from separate
Neovim processes. These workers execute installed theme code without user init
or Lua setup-module state. Setup-dependent, transparent or unspecified themes
can be omitted; Ctrl-h exposes classification problems. This host-local picker
feature does not change the portable core or add GUI theme support.

See [configuration](configuration.md) for saved-profile precedence and adapter
setup, and [command coverage](command-coverage.md) for the implemented operations.

Optional `editor_keys` are Neovim-global host configuration and are not exported
in portable profiles. Only explicitly declared Normal/Visual/Insert shortcuts
are claimed. Later buffer-local mappings can shadow them. The shared invocation
envelope carries command IDs/arguments, not editor key syntax or execution
permission. Existing custom commands lacking a required final boolean Apply
field cannot use direct `invoke()` when they declare `explicit_apply`.

## Other hosts

The optional [VS Code desktop host](../hosts/vscode/README.md) is a source
development extension. It requires a separately built native helper and an
explicit Lua runtime. It supports document search/replacement, profiles, project
recipes, Tasks/Results, original-task recovery and presentation preferences.
It is not a complete port of Neovim workspaces, LSP, Git or editor behavior.
Web and remote extension hosts are outside the documented scope.

The [C ABI and console examples](portable-core.md) demonstrate embedding the
shared core. They are not complete editor hosts or prebuilt applications.

## Known limitations

- Default theme classification inspects at most 256 themes and allows two seconds
  per appearance. Initial lists can be incomplete while checking. Cached results
  are advisory; live application can reject and correct an outdated observation.
  Custom adapters can own selection for themes the default classifier omits.
- Text wrapping preserves common combining, Hangul and emoji sequences, but does
  not implement every Unicode grapheme or language-specific line-break rule.
- Document search and replacement are single-line, case-sensitive literal
  operations within the [Document v1/v2 limits](document-v2.md). Replacement
  requires explicit review and leaves the source unchanged on a stale plan or
  quota refusal. It does not implicitly save a document.
- Builtin project search is bounded and does not implement every ripgrep option.
  Optional providers have different capabilities; partial results remain partial.
  See [file search](file-search.md) and [search providers](search-providers.md).
- Direct process cancellation does not promise termination of every descendant.
  Optional process-group ownership has a defined scope; detached daemons and
  services remain outside it. See [process ownership](development/process-ownership.md).
- Host-native controls may fall back when they cannot represent a presentation
  preference. Unsupported declarations are retained rather than silently removed.
- VS Code document-search latency remains under investigation. Performance and
  physical UI behavior vary by host and runtime; the development host is not
  advertised as a stable replacement for its editor's builtin tools.
- A complete Ex successor, debugger workflow, JetBrains host and native editing
  grammar are not implemented.

Report a problem with the RE35 version, host/runtime, a minimal reproduction and
any relevant optional integration. Remove personal paths or other sensitive data
from shared logs. See [contributing](../CONTRIBUTING.md).
