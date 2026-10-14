# Install RE35

This guide installs RE35's Neovim host, which requires Neovim 0.11 or newer on
Windows or Linux. A compiler, .NET SDK, language server or another plugin is
not required. Optional integrations have their own prerequisites; the
[VS Code development host](../hosts/vscode/README.md) has a separate setup.

## Choose a source revision

The public repository is [RemuWorld/RE35](https://github.com/RemuWorld/RE35).
Pin a version tag such as `v0.2.1` to install that version.
Use `main` only to follow ongoing development.

Install the complete source layout from one revision. Check its runtime version
and read the documentation shipped with it. A newer `main` revision can have
different behavior. See [compatibility](compatibility.md) for host requirements
and known limitations.

## With lazy.nvim

```lua
{
  "RemuWorld/RE35",
  tag = "v0.2.1",
  config = function()
    require("re35").setup()
  end,
}
```

To follow development, replace `tag = "v0.2.1"` with `branch = "main"`.
Use the plugin manager's normal install/update commands. Inspect any lockfile or
configured revision before expecting an update.

See [configuration](configuration.md) for minimal and advanced setup and the
precedence of saved settings.

## Manual install on Linux

Arch Linux and Ubuntu use the same Neovim package layout. This example honors
`XDG_DATA_HOME` and `NVIM_APPNAME`:

```sh
re35_data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
re35_app_name="${NVIM_APPNAME:-nvim}"
re35_parent="$re35_data_root/$re35_app_name/site/pack/re35/start"
mkdir -p "$re35_parent"
git clone --branch v0.2.1 https://github.com/RemuWorld/RE35.git "$re35_parent/RE35"
```

To follow development, use `--branch main` instead of `--branch v0.2.1`.
If the destination already exists, inspect it and update the intended checkout.

## Manual install on Windows or another layout

Inside Neovim, find the active data directory:

```vim
:lua print(vim.fn.stdpath('data'))
```

Clone or place the complete repository from tag `v0.2.1` at
`site/pack/re35/start/RE35` below that directory. Keep `lua/re35.lua`,
`lua/command_tree`, `lua/command_environment` and the accompanying files from
the same revision.

Add one setup call to your Neovim configuration:

```lua
require('re35').setup()
```

Restart Neovim, press `\`, then `/` to search commands. RE35 installs into the
runtime directory and uses your existing Neovim configuration.

## Check the loaded source

```vim
:lua print(require('re35').version)
:lua print(debug.getinfo(require('re35').setup, 'S').source)
```

Tag `v0.2.1` should report `0.2.1`. The reported version should match your chosen tag.
The source path should be inside the intended installation. Remove an older
duplicate runtimepath entry if it shadows
that source. `require('command_tree')` is the same compatible API object, so an
existing configuration using that name can keep it.

Use `:help command-environment` for settings and keys. If help tags are missing,
run `:helptags` for the installation's `doc` directory.

## Install a source snapshot

A snapshot prepared by [the source tool](development/source-packaging.md)
contains `re35-source.zip` and a companion `source-manifest.json`.
The manifest records the source version, per-file hashes and archive SHA-256.
Compare the archive hash before unpacking:

```sh
sha256sum /path/to/re35-source.zip
```

On Windows:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '/path/to/re35-source.zip'
```

The archive contains one top-level `RE35` directory. Extract it below
`site/pack/re35/start/` so that the resulting layout is
`site/pack/re35/start/RE35/lua/re35.lua`. Use a new destination and preserve an
existing installation before replacing it. Avoid an extra `RE35/RE35` level.
Then use the setup and source checks above. Check the
[compatibility](compatibility.md) for host requirements and limits;
an archive hash verifies the source bytes, not runtime behavior.

## Optional hosts and native integration

Neovim loads the Lua source directly. The source layout also contains the
[VS Code development host](../hosts/vscode/README.md) and
[native bridge](portable-core.md), which have separate runtime/build instructions.
Keep the complete layout: the VS Code host's default core path resolves to the
repository's Lua directory.

The initial public release provides source. Read the relevant host guide before
using an optional integration; a source directory is not a Marketplace extension
or a prebuilt native binary.

## Update

Inspect local changes and the selected revision first:

```sh
git -C /path/to/RE35 status --short
git -C /path/to/RE35 branch --show-current
```

Preserve intentional edits. Only a clean checkout following the development
branch `main` uses:

```sh
git -C /path/to/RE35 pull --ff-only
```

Restart Neovim and check the loaded version. A pinned tag stays at that release
until you intentionally select another revision. Extracted source snapshots
have no Git remote; update them by reviewing a new snapshot and preserving the
previous installation.
