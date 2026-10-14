# Changelog

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
