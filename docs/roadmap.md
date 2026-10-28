# Roadmap

RE35 helps users own their commands and workflows: discover what is available,
provide inputs, execute, inspect results and recover without losing the original
intent. New users should be able to find a task; experienced users should be able
to define a faster personal path through the same semantic actions.

## Current scope

0.5.0 focuses on ordinary Windows x64 VS Code editing, reusable
commands, explicit contextual input chains, project recipes and connected
Results/recovery. It uses the editor's own selection and Undo/Redo. Read
[usage](usage.md), [customization](customization.md) and
[compatibility](compatibility.md) for the implemented scope.

Neovim and vscode-neovim are no longer future support targets. Existing source
and historical definitions may remain, but they do not require future feature
parity. The core remains separate from editor APIs without making additional
hosts a condition for completing the current experience.

## Next priorities

1. Validate installed editing workflows, input ownership, IME, persistence and
   recovery with actual use; fix observed defects before widening scope.
2. Make command and rule authoring easier to understand, test and change. Preserve
   ordinary writing and keep activation explicit.
3. Develop the next input capabilities in bounded increments. Counts, operators,
   recursion and multiple cursors need defined semantics and real acquisition
   support before they become available.
4. Revisit the custom interface after a suitable code-visible surface is chosen.
   The design is currently on hold. Native forms are the present tools, not the
   adopted final visual design.

RE35 should connect capable tools through stable command identities rather than
rebuild search, build, Git or language engines. An unavailable provider must
explain its limitation instead of pretending to support another host's features.

Marketplace publication, new editor hosts, AI/MCP, debugger integration, an
independent Vim engine and a core-language rewrite are not current release
requirements. Version numbers follow delivered scope; this roadmap is not a
release calendar or a claim that planned features are implemented.
