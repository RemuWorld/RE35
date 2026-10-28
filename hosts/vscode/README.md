# RE35 for VS Code

Discover commands, compose workflows and define your own command input while
keeping ordinary VS Code editing as the default.

**0.5.0 · Windows x64** Install the VSIX from the
[GitHub release](https://github.com/RemuWorld/RE35/releases/tag/v0.5.0), then run
**RE35: Browse Commands** from the Command Palette. The platform package includes
the RE35 helper and Lua runtime; Neovim is not required.

## Guides

- [Installation](../../docs/install.md)
- [First steps](../../docs/usage.md)
- [Commands and input personalization](../../docs/customization.md)
- [Troubleshooting](../../docs/troubleshooting.md)
- [Compatibility and limitations](../../docs/compatibility.md)
- [Development](../../docs/development.md)

Use **RE35: Manage User Commands** to build a saved sequence with reusable inputs.
Use **RE35: Manage Command Contexts** to assign tokens, actions and explicit
context transitions. Save the editable example, enter command input from your
source editor, then use `l` to select a line and `C` to uppercase it. Each completed
rule runs immediately; leaving the context restores ordinary typing.

Saving never activates rules. Focus or source changes end contextual ownership;
previously completed edits remain available through VS Code Undo. Recipes retain
their original inputs and targets for recovery. Compositions do not promise one
Undo or automatic rollback across all steps.

The dedicated interface is on hold. Current authoring uses native VS Code
controls. This release is distributed through GitHub, not the Marketplace.

Licensed under [Apache License 2.0](https://github.com/RemuWorld/RE35/blob/v0.5.0/LICENSE).
