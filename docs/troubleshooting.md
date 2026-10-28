# Troubleshooting

Start with the RE35 version, VS Code version, operating system and the exact
command that failed. Use a small disposable file when reproducing editing
issues. Remove personal paths, queries and source text from shared reports.

| Symptom | What to check |
| --- | --- |
| No RE35 commands after installation | Confirm the VSIX is installed and enabled in the current local VS Code window, then reload. Use the Windows x64 asset with desktop VS Code. |
| Core helper/runtime unavailable | Clear stale `re35.helperPath`, `re35.luaRuntime` or `re35.corePath` overrides to use bundled components. Source-only packages require separately built components. |
| Workspace rejected | This release operates in trusted local workspaces. Web, virtual and Remote hosts are outside its release scope. |
| Command unavailable | Read its reason. Optional tools must already exist. A declaration does not install an executable or provide missing host support. |
| Input rules do nothing | Save definitions, return to the source and activate them explicitly. Installing or saving alone never claims keys. |
| Ordinary input activation is refused | Use one local file and one cursor/selection. Active vscode-neovim or VSCodeVim conflicts with this input owner; disable it yourself for the workspace and reload. |
| Rule disappeared after a failure | Inspect saved versus draft state. Invalid saves preserve previous saved definitions; unsupported legacy IDs remain data rather than being translated. |
| Keys stop after switching windows/documents | Contextual ownership closes on focus/source changes. Activate again deliberately. A function-key connection stays paused if its original source no longer validates. |
| Replacement or result is stale | Run the command again from the current document. RE35 does not apply an old review to a later revision. |
| A large search/replacement is refused | Check the document, line, plan and processing limits in [compatibility](compatibility.md#documents). No partial replacement is applied. |
| A recipe cannot resolve its root | Open its workspace folder. Multi-folder workspaces need exact project-ID to folder-URI mappings. See [workflow data](reference/workflow-data.md). |
| Project declarations vanished after reload | Portable workflow profiles are session-owned. Load the JSON profile again. Saved user commands and input definitions are separate persistent data. |
| No compiler locations in Results | Inspect captured output and the declared `errorformat`. Unconfigured or unsupported formats do not produce guessed locations. |
| Search results are partial | Inspect provider scope and limit notices. Saved-file search does not include unsaved editor text or excluded files. |

## An edit may already have happened

If RE35 reports an admitted but unconfirmed effect, inspect the source before
retrying. An error after an editor mutation does not mean that the mutation was
undone. Cancellation prevents unexecuted continuation; it does not roll back
completed edits. Use normal VS Code Undo/Redo where appropriate.

## Cancellation is still pending

A request is not evidence of process exit. Inspect Tasks for the actual exit,
termination confirmation and process scope. Direct-child scope cannot confirm
that descendants stopped. A configured scope helper owns only its declared Job
or process group; intentionally detached services are excluded.

## Appearance looks different from the proposed design

RE35 uses VS Code's native controls. Presentation preferences can
adjust optional information; arbitrary RE35 geometry, colors and floating layout
are not implemented by those controls. The custom interface remains on hold.
RE35 does not change VS Code's global Quick Input position to imitate it.

## Report a reproducible issue

Include a short sequence from a fresh local file, expected versus observed
behavior, the package version and relevant optional extensions. State whether
the problem concerns physical keys, IME, API invocation, persistence or display.
Logs and screenshots are optional; share only the relevant redacted material.
