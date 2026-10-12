# Roadmap

RE35 aims to let users carry command and workflow definitions between
environments, following discovery, input, execution, results and recovery through
one consistent model. Neovim is the primary working host; the shared core and
explicit host contracts keep that model reusable.

## Current scope

RE35 0.1.0 includes the Neovim command environment, bounded document search
and replacement, sequential project recipes, owned Tasks/Results,
original-context recovery and editable presentation presets.

The optional VS Code desktop host supports the documented document, profile,
project, recipe, Results, recovery and appearance workflows. The optional C ABI
and console examples expose the shared core. See [command coverage](command-coverage.md)
and [compatibility](compatibility.md).

## Next priorities

- Improve recipe failure-to-repair-to-retry workflows through independent use.
- Resolve the VS Code document-search latency investigation and check the same
  workload before and after a correction.
- Refine UI stability, first-use guidance and documentation from user feedback.
- Exercise actual Linux desktop interaction alongside process/filesystem checks.
- Expand document and project workflows only with visible limits, source checks
  and explicit partial-result reporting.

## Portable workflows

Preserve logical projects, tools, choices and steps while each host supplies
machine mappings and runtime capabilities. Unsupported customization should
remain intact with a clear explanation. Live task history and review authority
remain host-local.

Use structured engines behind stable command IDs rather than duplicating mature
search, Git or build tools. Builtin providers offer a bounded baseline; optional
providers can offer richer capabilities. Improve equivalent workflows before
adding more hosts. Host-specific distribution packages are possible future work.

## Research and optional extensions

Explicitly assigned native editor shortcuts could invoke stable command IDs
independently of tree locations. This needs conflict handling and owned keymap
cleanup; no native editing shortcuts are installed by default.

Command composition could build on recipes, typed inputs and structured results.
A native editing grammar with motions, operators, counts, registers and repeat
behavior is a separate research effort. Normal/Insert editing remains owned by
the editor before explicit RE35 entry.

An optional machine client could discover command schemas, inspect capabilities
and reuse user recipes through the same host checks. AI/MCP integration remains
proposed work; the current native bridge is not an MCP server. Compare equivalent
workflows against direct tools before claiming better success or efficiency.

Broader command syntax, debugger workflows and additional hosts remain future
work. Version numbers follow implemented public scope. A registered name,
portable schema or external handoff alone does not establish a complete workflow.
