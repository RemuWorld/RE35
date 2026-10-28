# Install RE35

The 0.5.0 package targets **Windows x64 desktop VS Code**. Download it
from [the v0.5.0 GitHub release](https://github.com/RemuWorld/RE35/releases/tag/v0.5.0). It is not a
Marketplace release.

## Install the VSIX

1. Download the Windows x64 `.vsix` asset for the intended version.
2. In VS Code, run **Extensions: Install from VSIX...** and select the file.
3. Reload VS Code when prompted.
4. Open a trusted local project folder and a text file.
5. Run **RE35: Browse Commands** from the Command Palette.

The platform package includes the RE35 command helper, shared core and Lua
runtime. No compiler, Neovim, language server or other extension is required for
ordinary document workflows. Build tools and ripgrep are optional and must
already exist when their integrations are selected. RE35 does not install them.

The extension manifest requires VS Code 1.85 or newer. Consult the release notes and [compatibility](compatibility.md) for the actual
validation scope. Web, Remote, virtual workspaces and other packaged platforms
are not included in this release.

## Update

Install the newer VSIX through the same command, then reload. Check the installed
RE35 version in Extensions before reporting a result. Saved commands and input
definitions use local extension storage. They are not silently converted between
legacy Neovim IDs and ordinary VS Code actions.

Activation is never restored at startup: enter contextual input or activate
function-key rules explicitly. Portable workflow profiles are session-owned;
load their JSON file again after restart. Export user-command libraries before
replacing them through import. See [customization](customization.md#state-and-history).

If an older development setup used `re35.helperPath`, `re35.luaRuntime` or
`re35.corePath`, clear those overrides to use bundled components. A source-only
VSIX does not include the native prerequisites; source development is covered
in [development](development.md).

## Uninstall

Use VS Code's normal extension uninstall command, then reload. RE35 does not
delete project files or exported JSON libraries. Do not remove VS Code extension
storage if you want to retain local saved definitions for reinstalling.

For Neovim's historical package, pin `v0.4.0` and use
[that version's instructions](https://github.com/RemuWorld/RE35/blob/v0.4.0/docs/install.md).
Neovim is no longer a future support target.
