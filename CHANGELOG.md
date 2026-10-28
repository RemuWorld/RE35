# Changelog

## 0.5.0

- Make ordinary VS Code editing the development baseline; Neovim is no longer
  a prerequisite or a future support target.
- Add saved user commands with reusable inputs, ordered semantic steps and
  inspectable outcomes.
- Add editable command contexts, case-sensitive tokens and bounded prefixes.
  Complete rules run immediately; declared transitions use observed editor state.
- Keep drafts, saved definitions and active input separate. Preserve prior saved
  data when validation or storage fails.
- Add ordinary editor actions for word movement, selection, uppercase, line
  deletion and document-range selection, using VS Code Undo/Redo.
- Improve source-bound input recovery, command discovery and editor-key return.
- Provide a Windows x64 VSIX with its helper, Lua runtime and runtime notice.
- Reorganize documentation around installation, first use and personalization.

The dedicated interface remains on hold; native controls provide the current
authoring flow. See
[compatibility](docs/compatibility.md) for supported environments and limitations.

## 0.4.0 — Legacy Neovim release

- Add resumable editor return, explicit session reset and direct semantic keys.
- Classify Light/Dark themes with cached isolated checks.
- Reduce repeated previews and redraws; improve concise feedback and word wrapping.

## 0.3.2

- Reject incompatible colorscheme appearances and restore the previous theme.

## 0.3.1

- Restore contextual picker keys, quiet editor return and consistent panel borders.
- Explain command-path conflicts while preserving a working environment.

## 0.3.0

- Add Light/Dark and automatic-preview controls and picker paging.
- Preserve command navigation and safe input drafts when returning from editing.

## 0.2.3

- Refine History framing, Compact/Minimal spacing and contextual guidance.

## 0.2.2

- Distinguish branches and commands, group keys and separate routine status.

## 0.2.1

- Fix availability diagnostics and improve shortcut readability and color roles.

## 0.2.0

- Persist confirmed builtin themes and add consistent list navigation.
- Stabilize the main window, separate details and clarify saved/session state.
- Add setup guidance, integration diagnostics and an Editor destination.

## 0.1.0

- Initial public command environment with discovery, input, execution and recovery.
- Include document search/replacement, projects, recipes, portable profiles,
  appearance presets, the Lua core/C ABI and a limited VS Code host.
