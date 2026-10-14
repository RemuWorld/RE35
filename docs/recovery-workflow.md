# Recover and retry a recipe

A recipe keeps the project, configuration, target and invocation it ran with.
Changing your current Project selection does not rewrite a retained task.
For example, retrying a failed Debug/A Task still runs Debug/A after you select
Release/B. Running the current selection instead starts a separate Release/B
invocation.

After a failure, open its Task or the latest run in Project. Source results
contain locations actually produced by that run. Select a location and press
Enter to return to its source; this does not edit or save the file.

In Tasks, `r` retries the original invocation, `c` opens the recipe remedy and
`v` opens an original-choice review. In owned task Results, the same actions are
`R`, `C` and `V`; `t` returns to the owning Task. Lowercase `r` still refreshes
Results and lowercase `c` clears its filter. While editing a filter, these keys
enter text. Non-task result lists cannot use the task follow-ups.

Repair the source, then retry. Modified project files require a save decision:

- **Select files to save then run** opens a selection. Mark intended files and
  confirm; only those reviewed files are saved before execution.
- **Run saved files** deliberately uses disk contents and leaves edits unsaved.
- **Back** cancels this attempt without saving or launching.

A retry creates a new Task and retains the old failure. Changed declarations,
renamed sources, replaced roots or stale reviews may prevent execution. Use
original-choice review to inspect a fresh invocation with current tools, or
ordinary Project to choose a new configuration and target. Opening either review
does not run anything; Run remains explicit.

A remedy opens owned source locations when available, or the relevant Settings
for inspection. An unclassified process failure is not automatically diagnosed
as a missing dependency. The message states when its cause is unknown.

The optional VS Code host exposes this workflow through native Task/Results
menus and **RE35: Recover Original Task**. See its
[recovery instructions](../hosts/vscode/README.md#recover-the-original-task).
Host controls differ while using the same declared recipe choices. A portable
profile shares the workflow; the live Task, output and recovery receipt remain
in the host that ran it.
