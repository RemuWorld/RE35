# Command API

This reference is for shortcut authors and trusted extension integrations.
Start with [customization](../customization.md) for interactive authoring.

## Semantic invocation

VS Code command `re35.execute` accepts a data envelope:

```json
{
  "command": "search.document",
  "args": { "query": "TODO" }
}
```

`command` is a supported stable semantic ID or saved `user.*` ID. `args` is an
optional object. Missing required values can open a form; unknown fields and
arguments are refused. The envelope selects intent, not permission to reuse an
old review. A shortcut and discovery use the same argument, source and Apply
checks. Tree paths and editor key notation do not belong in this envelope.

## Useful semantic IDs

| Area | IDs |
| --- | --- |
| Document | `search.document`, `edit.replace_literal` |
| Project selection | `workspace.project`, `project.inspect` |
| Recipes | `project.run_selected_recipe`, `run.tasks`, `run.cancel`, `run.results`, `run.task_recovery` |
| Saved-file search | `search.project_text`, `search.project_results`, `search.cancel` |
| Saved commands | `user.commands_manage`, `user.commands_run`, `user.commands_results`, `user.commands_cancel` |
| Input authoring | `input.rules_manage`, `input.contexts_manage` |
| Session | `session.reset` |

`search.document` requires `query`. `edit.replace_literal` requires `find` and
accepts optional `replace`; empty replacement deletes matches. The other
interactive entries obtain their choices through the existing workflow.
Supplying text arguments bypasses only those prompts, never diff/Apply review.

## Editor actions

These actions require one local file and one cursor or selection.

| ID | Arguments | Effect |
| --- | --- | --- |
| `editor.move_words` | Optional `count` | Use VS Code's forward-word command. |
| `editor.select_word` | None | Select the language word at the cursor; refuse if absent. |
| `editor.uppercase_selection` | None | Uppercase a nonempty selection and retain its direction. |
| `editor.delete_lines` | Optional `count` | Delete from the active line, capped at document end. |
| `editor.document_start` | None | Collapse selection at document start. |
| `editor.select_line` | None | Select the active line, including its existing line break. |
| `editor.extend_to_end` | None | Extend the current anchor to document end. |

`count` is 1–1000, as an integer or canonical decimal text; omission means 1.
Word rules and Undo are VS Code semantics, not Vim registers or Visual modes.
Selection-only actions create no text Undo entry. Text mutations use an editor
transaction; a composition does not combine every step into one Undo.

## Trusted registrations

The activated `RemuWorld.re35-desktop` extension exports:

```js
registerAction(descriptor, adapter, { owner, replace })
applyEditorEdits(edits, actionContext)
```

The descriptor is bounded command metadata: a stable non-`user.*` ID, display
name and optional description, arguments and capabilities. Callbacks remain in
the trusted adapter. An owner cannot replace built-ins or another owner's
registration. Invalid replacement retains the existing action; disposal retires
the registration generation before later execution can use it.

The adapter supplies `execute(args, context)` and declares:

| Field | Meaning |
| --- | --- |
| `completion` | `observed` or final `handoff` |
| `source` | `none`, `preserve` or `refresh` |
| `composable` | Whether the action can appear in saved sequences |
| `observe(args, context, result)` | Required observation adapter for observed actions |
| `modes` | Use `['editor']` for ordinary editor input |
| `observationEngine` | Defaults to `editor`; `native` is retained legacy behavior |

A resolved Promise alone does not prove an effect. Source-bound observation
returns the same source URI, version, text, mode `editor` and UTF-16
`[line, character]` anchor/active positions. The host verifies that observation
before refreshing the next action's source. Input connections accept only
eligible observed actions.

The context provides source data, a stop signal, ownership checks and declared
effect admission; it does not expose internal Host objects. `applyEditorEdits`
accepts explicit UTF-16 ranges and replacement text, checks its live context and
applies once through VS Code. It does not mirror the edit through another engine.
Ranges must not split a Unicode character. Imported JSON cannot register these
adapters or contain execution receipts.

## Saved command data

Version-1 libraries contain `commands`, each with a stable `user.*` ID, name,
named inputs and ordered `steps`. A step names a semantic command and binds its
arguments to `{ "value": ... }` or `{ "input": "name" }`. Text and finite-choice
inputs are supported. Limits are 64 KiB, 64 commands and 16 steps/inputs per
command, with additional field bounds.

Unsupported IDs remain saved and explain missing support. Imported libraries
contain no shell, key replay, executable adapters or recursive user-command
calls. A final confirmed VS Code handoff takes no arguments and reports
`handed_off`, rather than claiming observed completion.

## Input-rule boundary

Contextual definitions are validated data separate from saved compositions and
function-key profiles. A context declares its owned roots and optional nonempty
selection requirement. Rules declare a token sequence, invocation and optional
next context: omission keeps the context; `null` returns to ordinary typing.
Completion must be observed before a transition. Incomplete prefixes do not
execute on a timer, and complete-rule/prefix collisions are refused.

Acquisition capabilities are narrower than the data model. Only supported,
explicitly bound tokens can activate; storing a declaration does not prove that
VS Code can acquire an arbitrary key. See [customization](../customization.md#contextual-command-input).
