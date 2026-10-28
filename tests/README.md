# Tests

The current test target is ordinary VS Code editing. Start with the commands in
[Development](../docs/development.md). Test reports belong in the ignored
`.artifacts/` directory; they are not source or release assets.

## Test layers

- `hosts/vscode/test/*.js`: bounded rule parsing, storage, ownership and execution
  tests. Modules with a command-line entry point can run directly with Node.js.
- `tests/acceptance/run_vscode_host.py`: an isolated real VS Code Extension Host
  with the actual helper and documents. It records source hashes and refuses
  changed snapshots. Public API invocation is distinct from physical input.
- `tests/vscode_package.py`: source inventory and VSIX contents, platform runtime
  files, notices and documentation links.

Use meaningful regressions for behavior changes. Cover cancellation, stale
sources and storage failures when they affect the change. Keep synthetic data
small and identify controlled seams honestly.

Physical keyboard, focus and IME behavior need an installed-package check.
Automated assertions do not establish independent usability or accessibility.

## Legacy suites

The existing `test_*.lua` and `regression/` fixtures preserve historical Neovim
behavior. Their runner remains available with `python tests/run.py`; it is not a
future Neovim support gate. Core/C ABI changes should additionally run the
applicable native checks described in the development guide.
