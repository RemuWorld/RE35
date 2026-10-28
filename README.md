# RE35

**Your commands. Your workflow.**

RE35 is a command environment for discovering, composing and personalizing work.
It connects commands, inputs, execution, results and recovery while using your
editor's existing editing and Undo facilities.

## Get started

**0.5.0** targets VS Code on Windows x64. Neovim is not required.

1. Download [RE35 for Windows x64](https://github.com/RemuWorld/RE35/releases/download/v0.5.0/re35-0.5.0-win32-x64.vsix).
2. Run **Extensions: Install from VSIX...** in VS Code and select the download.
3. Open a trusted local folder, then run **RE35: Browse Commands**.

[Installation](docs/install.md) · [First steps](docs/usage.md) ·
[Personalization](docs/customization.md) · [Troubleshooting](docs/troubleshooting.md)

## Make it yours

- **Find your next action.** Browse commands and see why an action is unavailable.
- **Compose a workflow.** Name a sequence, reuse its inputs and inspect each result.
- **Define command input.** Assign case-sensitive tokens and prefixes to explicit
  contexts. Each completed rule acts immediately using the actual editor state.
- **Keep the execution context.** Follow recipe failures to results and retry
  with the original configuration and target.

The editable command-context example selects a line with `l`, transforms it with
`C` and returns to ordinary typing. Saving definitions does not activate them.
Existing VS Code writing and shortcuts remain the default.

## Documentation

| Resource | Purpose |
| --- | --- |
| [User guide](docs/README.md) | Install, learn and customize RE35 |
| [Compatibility](docs/compatibility.md) | Supported environments and current limits |
| [Development](docs/development.md) | Architecture, builds and testing |
| [Roadmap](docs/roadmap.md) | What comes next |
| [Changelog](CHANGELOG.md) | Release changes |
| [Contributing](CONTRIBUTING.md) | Report a problem or propose a change |

Authoring currently uses native VS Code controls; the dedicated RE35 interface
is on hold. Installation
uses GitHub releases rather than the Marketplace. Read the compatibility guide
before enabling experimental input rules.

The editor-independent Lua core and C ABI remain available for embedding.
Neovim development has ended; its last release and documentation remain at
[`v0.4.0`](https://github.com/RemuWorld/RE35/tree/v0.4.0).

RE35 is licensed under [Apache License 2.0](LICENSE).
