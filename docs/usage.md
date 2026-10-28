# Use RE35

Open a trusted local folder in VS Code, then run **RE35: Browse Commands** from
the Command Palette (`Ctrl+Shift+P`). Search by a command's name or explanation
and press Enter.
Unavailable commands explain what they need instead of guessing a replacement.

RE35 uses ordinary VS Code editing. Installing it does not activate letter
commands, replace your editing shortcuts or require Vim modes.

## First workflow

1. Open a small text file containing a repeated word.
2. Run **RE35: Search Current Document** and enter the word.
3. Open a result to select its location in the original document.
4. Run **RE35: Preview Literal Replacement** and enter find/replacement text.
5. Inspect the diff. Choose **Apply** to change the document, or **Discard** to
   leave it unchanged. Apply does not save the file.
6. Use VS Code Undo/Redo to reverse or restore the edit.

Document search and replacement are single-line, case-sensitive and literal.
Search results and reviews belong to the captured document version. If it
changes, run the command again. See [limits](compatibility.md#documents).

## Choose a task

| Task | Command Palette entry |
| --- | --- |
| Discover actions and saved commands | RE35: Browse Commands |
| Search or replace this document | RE35: Search Current Document / Preview Literal Replacement |
| Create a reusable sequence | RE35: Manage User Commands |
| Define immediate input chains | RE35: Manage Command Contexts |
| Load projects, tools and recipes | RE35: Load Portable Profile |
| Run a chosen project recipe | RE35: Select Project Context, then Run Selected Recipe |
| Inspect a run or recover its original choices | RE35: Inspect Recipe Tasks / Recover Original Task |

The current interface uses VS Code's native lists, input controls and diff
editor. The dedicated RE35 interface is being reconsidered; this release does
not include the proposed floating or separate-tab design.

## Run a project recipe

Load a local version-1 profile with **RE35: Load Portable Profile**. Review its
sections, then Apply or Discard. Apply changes the active declarations for this
RE35 host; it does not install tools or run a recipe. Reload the profile after
restarting the extension or changing core/context configuration.

Choose **RE35: Select Project Context**, then select the declared project,
recipe, configuration and target. A single workspace folder supplies the local
project base by default. Multi-folder workspaces need an explicit local mapping;
see [workflow data](reference/workflow-data.md).

Run **RE35: Run Selected Recipe**. Clean saved inputs run directly. Modified
project documents offer a choice to run saved files, save selected files first,
or cancel. RE35 never implicitly selects files to save. A save failure starts
no task and reports files already written.

Tasks show actual step outcomes, output, original configuration/target and
process scope. A failed or cancelled step prevents later steps from starting.
Closing the output panel does not cancel a task. Use **RE35: Cancel Running
Recipe** to request termination, then inspect its observed outcome.

## Recover a failed run

Open the original task's Results or recovery entry. Supported compiler
diagnostics can lead to source locations; unconfigured or unsupported output
formats remain available as captured text.

After a repair, retry from that original task. RE35 revalidates its original
recipe, inputs, configuration and target. Selecting Release/B elsewhere does
not redirect a retry that originally used Debug/A. Changed declarations or an
expired task require a new project selection. A retry is a new execution;
completed effects from the first run are not rolled back.

## Search saved project files

After selecting a project, run **RE35: Search Project Text**. The builtin provider
needs no external executable and supports literal, case-sensitive text. Optional
ripgrep supports regex and case options when selected in the profile and
installed separately. Missing selected providers report unavailable; they do
not switch automatically.

Project search reads saved files. Unsaved editor text, excluded files and
quota-limited results are not silently treated as complete coverage. Results
retain their provider and scope. Changed files are refused during navigation.
See [provider configuration](reference/workflow-data.md#project-search).

## Close, resume and reset

**RE35: Open Command Environment** toggles an open form and restores safe
navigation when reopened. Closing authoring does not save its draft. Direct
document query/replacement drafts are restored only for the same unchanged
document; Apply permission and old review receipts are never restored.

**RE35: Start New Command Session** asks before clearing navigation and unsaved
drafts. Saved definitions, settings and retained task outcomes remain. Restarting
VS Code ends session-only state. See [customization](customization.md) for what
is saved and what needs explicit activation.
