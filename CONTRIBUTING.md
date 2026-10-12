# Contributing to RE35

Describe the user-visible problem and resulting behavior in a pull request.
Include a small reproduction and the relevant test result. Keep command IDs and
public profile/API contracts stable unless a versioned change is intended.

## Source boundaries

The Neovim host lives in `lua/command_tree`; portable semantics live in
`lua/command_environment/core`; the optional VS Code host lives in
`hosts/vscode`. Keep editor, filesystem, process and plugin APIs out of the
portable core. Hosts own live resources, UI, document revisions and execution
permissions.

Keep one command identity across discovery, inputs, execution, Results and
recovery. Prefer adapting an existing engine with structured output over
reimplementing it. Preserve unsupported portable declarations and explain the
host's limitation. Optional integrations must not silently install software or
switch to another backend.

Use RE35 as the product name and `require('re35')` as the Neovim entry.
`command_tree`, `command_environment.core`, the `ce_*` ABI, existing command
IDs and storage paths retain their compatibility identities. Before explicit
entry into RE35, Normal-mode input belongs to Neovim and the user's configuration.

## Documentation and tests

The [documentation index](docs/README.md) separates user guides from integration
contracts. Describe observable behavior in guides, ownership and call direction
in [architecture and execution](docs/development/execution-structure.md), and
planned work in the [roadmap](docs/roadmap.md).

Run `python tests/run.py` before submitting a runtime change. Add a regression
fixture for a meaningful behavior change. See [tests/README.md](tests/README.md)
for runner options and optional host checks. Native bridge changes also need the
applicable build checks from [portable core](docs/portable-core.md).

## Source packages

[Source packaging](docs/development/source-packaging.md) uses a reviewed file
inventory. Update that inventory deliberately when adding or removing sources.

Do not commit personal configuration, usage/history/profile records,
credentials, machine-specific dependency paths, downloaded runtimes, build outputs,
raw test reports or backups. Keep examples and synthetic fixture data small.
Test results submitted with a change should identify the source revision, runtime
and actual scope; retain detailed execution records outside the public source.

Contributions use the repository's Apache License 2.0. Retain applicable
third-party notices for included code.
