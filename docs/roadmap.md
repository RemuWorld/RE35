# Roadmap

RE35 aims to let users carry command and workflow definitions between
environments, following discovery, input, execution, results and recovery through
one consistent model. Neovim is the primary working host; the shared core and
explicit host contracts keep that model reusable.

## Current scope

RE35 0.4.0 includes the command, recipe, Results/recovery and presentation
workflows from 0.1.0, with remembered themes, list wrapping, inspectable
errors, storage-state labels, first-use guidance, an Editor return destination
and independent command/details panels. It also separates editor handoff from
session disposal, narrows execution checks to relevant changes, and uses one
display model for existing window options and named presets. Theme appearance,
preview controls and page navigation extend the existing selection workflow.
Cached Light/Dark classification, unchanged-preview reuse, concise conditions
and word-based wrapping improve the Neovim selection experience. Explicit editing shortcuts now invoke the same stable command intent in
Neovim and VS Code. Ordinary editor return preserves safe navigation; Ctrl-c
resets it. Existing profile contracts remain compatible.

The optional VS Code desktop host supports the documented document, profile,
project, recipe, Results, recovery and appearance workflows. The optional C ABI
and console examples expose the shared core. See [command coverage](command-coverage.md)
and [compatibility](compatibility.md).

## Next priorities

The following public stages are planned scope boundaries, not implemented
features or release dates:

| Stage | Intended complete workflow |
| --- | --- |
| Command composition | Let users define bounded semantic command compositions, including arguments, step results and failure behavior; run a common definition in Neovim and the VS Code host. |
| Editing grammar | Provide a first bounded user-defined editing grammar with supported actions, targets, counts, cancellation and guidance while input is incomplete. |

Tree discovery and direct input should use the same command definitions. A later
GUI modal-input layer could work with an existing Vim extension or independently;
it is not a complete Vim replacement today. Host services retain ownership of
actual editing, undo and rendering, while supported user definitions remain
portable. Each stage needs a usable end-to-end workflow before publication.

Alongside these stages:

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

Extend discovery and command access into ordinary editing, so RE35 can cover
native key guidance as well as its explicit command environment. The editor
continues to own actual Normal/Insert behavior and undo; entry and guidance
policies need explicit ownership and user configuration.

Explicitly assigned editor shortcuts invoke stable command IDs independently
of tree locations. No editing shortcuts are installed by default. Guidance for
longer user-defined editing sequences remains future work.

Command composition builds toward semantic operations rather than portable raw
keystroke playback. Host-specific key playback may remain a separate escape hatch.
The first editing grammar must define its finite actions, targets and counts;
registers, repeat behavior and a full modal editing layer need further design.
Normal/Insert editing remains owned by the editor. Explicitly configured editor
keys may invoke RE35 without opening the tree first.

An optional machine client could discover command schemas, inspect capabilities
and reuse user recipes through the same host checks. AI/MCP integration remains
proposed work; the current native bridge is not an MCP server. Compare equivalent
workflows against direct tools before claiming better success or efficiency.

Broader command syntax, debugger workflows and additional hosts remain future
work. Version numbers follow implemented public scope. A registered name,
portable schema or external handoff alone does not establish a complete workflow.
