# Contributing

Start with a concrete problem, a short reproduction and the expected behavior.
For input issues, include the RE35 and VS Code versions, operating system,
enabled input profile and relevant extensions. Remove personal data from logs.

Keep changes focused. Explain the resulting behavior and relevant validation in
a few sentences. See [development](docs/development.md) for architecture, builds,
testing and source packaging.

## Design principles

- Reuse semantic command IDs across discovery, compositions and editor input.
- Keep core definitions separate from editor APIs and live execution authority.
- Preserve ordinary writing unless the user explicitly activates command input.
- Stop continuation on failure; report completed effects without silent replay.
- Adapt existing tools instead of rebuilding their engines.

New development targets VS Code. Existing Neovim code is retained as legacy
source without a future compatibility commitment.

Keep personal settings, machine paths, credentials, downloaded runtimes, build
outputs, raw validation reports and backups out of commits. Update the reviewed
source inventory deliberately when files are added or removed.

Contributions use [Apache License 2.0](LICENSE). Retain third-party notices.
