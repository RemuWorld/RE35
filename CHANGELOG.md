# Changelog

## 0.3.2

- Reject incompatible colorscheme appearances instead of forcing a background
  option that can clear the active colorscheme identity. Restore the previous
  theme/appearance and preserve startup storage on failure. Peachpuff works
  with Light; choosing Dark reports the incompatibility.

## 0.3.1

- Restore Full's contextual Keys panel in choice pickers, including selection,
  paging and theme controls. Show controls that apply to the current filter state
  and preserve custom adapter help when a side guide cannot represent it.
- Resume navigation from Editor silently. Show a neutral input-restoration notice
  only when reopening the command whose draft is restored.
- Expose the existing Workspaces shortcut in tree guidance and explain Editor's
  resumable return alongside Close's fresh navigation on the next entry.
- Use a consistent border role for the main, Keys and Details panels. Refresh
  RE35-owned border colors after palette changes while preserving user overrides.
- Identify both commands and the setup entry responsible for a path conflict.
  Keep strict candidate validation and preserve an existing working environment.

The reported source-buffer background inconsistency during colorscheme preview
remains under investigation; the border fix does not establish its cause.

## 0.3.0

- Return to the native editor and resume command navigation with a fresh source
  context. Restore nonsecret drafts without restoring old reviews or permissions.
- Keep saved-input recipe runs independent of unrelated buffer edits. Recheck
  relevant tools, targets and files before effects, while keeping Results and
  other read-only inspection accessible.
- Use one display model for existing window options and named presets, retaining
  their layout behavior and checking required review information after resizing.
- Add Light/Dark selection and an automatic-preview toggle to the builtin theme
  picker. Confirm the exact theme/appearance pair; cancellation restores both.
- Add configurable PageUp/PageDown navigation to selectable lists and preserve
  the selected search result when only the query caret moves.
- Share command argument rules between the portable core and Neovim, preserving
  host callbacks and existing profile, document, protocol and ABI contracts.

## 0.2.3

- Keep source text, number/sign columns and folds inside History's symbolic
  frame without changing the original document or native undo owner.
- Size Compact/Minimal input scenes independently while keeping selection,
  filtering and pagination stable. Preserve required review and source facts.
- Keep Full shortcut guides at a stable width, wrap descriptions without
  splitting key combinations, and use the same guide for History and Timeline.
- Show neutral, temporary confirmations above the command panel without
  crowding its title or moving the main window. Keep failures inspectable.

## 0.2.2

- Distinguish branches with a persistent marker and emphasis, and highlight the
  complete selected row in all three densities.
- Show grouped shortcuts to the right in Full when spare viewport space fits
  every control; retain below-panel guidance when it does not.
- Move explicitly classified save confirmations into the title with neutral
  styling. Keep storage failures, warnings and diagnostics inspectable below.
- Remove unused Compact/Minimal navigation rows while preserving fixed main
  geometry, required review facts, custom spacing and theme overrides.

## 0.2.1

- Fix availability diagnostics showing a failure reason for ready commands.
- Group shortcut hints and keep complete key combinations together on wrapping.
- Use consistent command-label and navigation-accent colors, readable description
  and target text, and distinct error/warning highlights.
- Preserve existing settings, bindings, theme persistence and custom highlights.

## 0.2.0

Neovim usability improvements based on independent feedback.

- Remember confirmed builtin theme choices across editor restarts by default;
  `theme.persist = false` keeps session-only behavior. Preview never saves.
- Keep custom theme adapters responsible for their own persistence and startup.
- Wrap single-step selectable-list navigation consistently; `navigation.wrap =
  false` preserves clamping. Text editing, history browsing and page scrolling
  keep their separate semantics.
- Keep the main command panel stable while descriptions and errors change;
  show bounded, independently scrollable details below it. Minimal stays small.
- Retain full bounded preview and restoration errors with Ctrl-h inspection,
  preserving the active input. Report storage warnings without silently closing.
- Distinguish Draft, Saved, Session only and failed storage states.
- Add Getting started, integration diagnostics, canonical `:checkhealth re35`
  and an Editor return destination without changing native editing modes.
- Preserve visible source/owner facts, partial-result notices and reviewed
  report destinations; refuse effects when required facts cannot fit.

Profile, presentation, document, protocol and ABI contract versions are unchanged.
Fixed Neovim float geometry is host-owned; this update does not promise the same
layout in native VS Code controls. See [compatibility](docs/compatibility.md).

## 0.1.0

Initial public development release of RE35.

- Add the Neovim command environment: discovery, typed input, review,
  execution, History, Project, Tasks, Results and Settings.
- Include builtin file search, optional search/integration providers, bounded
  document search and reviewed replacement, sequential project recipes and
  original-context recovery.
- Provide portable profiles, custom commands, workspace bindings, named
  presentation presets and reviewed appearance-only sharing.
- Include an editor-independent Lua core, optional C ABI and C++/C# console
  integration examples.
- Include the optional VS Code desktop development host for the supported
  document, profile, project, recipe, Results, recovery and presentation workflows.
- Begin public versioning at 0.1.0. Existing profile/schema, protocol and ABI
  versions keep their compatibility contracts.
