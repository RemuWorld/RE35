# RE35 documentation

These documents describe RE35 0.3.0. Start with installation and configuration.
See [command coverage](command-coverage.md) and
[compatibility](compatibility.md) for host scope and known limitations.

## User guides

| Guide | Purpose |
| --- | --- |
| [Installation](install.md) / [Configuration](configuration.md) | Install and configure RE35 |
| [Neovim help](../doc/command-environment.txt) / [Integrations](../doc/command-environment-integrations.txt) | Keys, workspaces and optional adapters |
| [File search](file-search.md) / [Search providers](search-providers.md) | Providers, Results and search limits |
| [Project recipes](project-recipes.md) / [Recovery](recovery-workflow.md) | Project selection, execution and retry |
| [UI settings](ui-settings.md) / [Presentation presets](presentation-presets.md) | Customize and share appearance |
| [VS Code host](../hosts/vscode/README.md) | Optional desktop development host |

## Architecture and integration

| Reference | Purpose |
| --- | --- |
| [Architecture and execution](development/execution-structure.md) | Core/host boundaries, module owners and call paths |
| [Extension API](extensions-v1.md) / [Portable core](portable-core.md) | Trusted integrations, shared Lua rules and optional C ABI |
| [Host contracts](host-contracts.md) / [Document v2](document-v2.md) | Document coordinates, pages and host responsibilities |
| [Workflow](development/workflow-contract.md) / [Process ownership](development/process-ownership.md) | Context, execution and cancellation |
| [Recovery](development/task-recovery-contract.md) / [Results and search](development/results-search-contract.md) | Original invocation and source/provider identity |
| [Presentation](development/presentation-contract.md) / [Follow-up](follow-up-contract.md) | Appearance data, host fallback and proposed next actions |

## Development

| Reference | Purpose |
| --- | --- |
| [Contributing](../CONTRIBUTING.md) / [Tests](../tests/README.md) | Changes and repeatable checks |
| [Source packaging](development/source-packaging.md) / [Self-development](development/self-development.md) | Reviewed inventory and this checkout's recipes |
| [Changelog](../CHANGELOG.md) / [Roadmap](roadmap.md) | Public versions and planned work |

`require('re35')` is the canonical Neovim entry; `command_tree` remains its
compatible alias. Product versions are separate from profile, document,
presentation, protocol and ABI contract versions. Portable declarations do not
imply complete feature parity between hosts.
