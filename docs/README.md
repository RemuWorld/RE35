# RE35 documentation

RE35 **0.5.0** runs in VS Code on Windows x64 and is distributed through GitHub.
It uses ordinary VS Code editing; Neovim is not required. The custom UI remains
on hold. Start with the native controls and supported workflows below.

## Start here

1. [Install](install.md) the VSIX and open a local workspace.
2. [Try a workflow](usage.md): discover, search, review an edit and inspect results.
3. [Customize](customization.md): create commands, bind shortcuts and define
   immediate contextual input chains.
4. [Troubleshoot](troubleshooting.md) an unavailable command or unexpected state.

[Compatibility](compatibility.md) describes supported scope, limits and remaining
verification. [Roadmap](roadmap.md) separates this release from future work.

## For contributors and integrations

- [Development](development.md): source layout, local builds and validation.
- [Command API](reference/command-api.md): semantic invocation, editor actions
  and trusted adapters.
- [Workflow data](reference/workflow-data.md): portable profiles, project roots,
  recipes and search providers.
- [Core contracts](reference/core-contracts.md): coordinates, protocol, document
  plans, ownership and cancellation.

For the retired Neovim implementation, use the documentation at
[`v0.4.0`](https://github.com/RemuWorld/RE35/tree/v0.4.0). Its keys, settings and
theme behavior are historical and are not the setup path for this release.
