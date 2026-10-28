# Make commands your own

RE35 separates three definitions: reusable commands, contextual input chains
and function-key rules. Saving a definition never runs it or activates typing.

## Reusable commands

Run **RE35: Manage User Commands**, choose **Create user command**, and enter a
readable name and unique `user.name` ID. Add inputs and ordered steps. Arguments
can use literal values or named inputs reused across steps. Reorder or edit the
steps, then choose **Review and save**.

For a small example, add `editor.select_word`, then
`editor.uppercase_selection`. Run it with **RE35: Run User Command** or find its
name in command discovery. The second action uses the selection actually
produced by the first. The available [editing actions](reference/command-api.md#editor-actions)
also include line selection, movement and deletion.

Closing the manager retains its unsaved draft for this window. **Discard
changes** clears the draft. Saved commands survive extension restart. Import
and export use data-only JSON libraries; importing reviews replacement of the
entire library rather than merging, so export a backup first.

Only observed successful steps advance a sequence. Failure, cancellation or
discarded replacement stops later steps. Earlier completed edits remain, with
their normal Undo behavior. A sequence is neither an atomic transaction nor a
single Undo. **RE35: User Command Outcomes** retains recent session outcomes;
**RE35: Cancel User Command** requests cancellation.

A final VS Code command handoff asks for confirmation and reports **handed off**.
RE35 cannot infer that another extension's returned Promise proves completion,
cancellation or Undo support.

## Bind a command to a shortcut

Use VS Code's Keyboard Shortcuts editor or `keybindings.json`. For example:

```json
{
  "key": "f6",
  "command": "re35.execute",
  "args": { "command": "editor.select_line" },
  "when": "editorTextFocus && !editorReadonly"
}
```

F6 is an example, not an installed default. Check existing conflicts first.
Replace the semantic ID with a saved `user.my_command` ID to run a composition.
Arguments go in a nested `args` object. Missing inputs use the same RE35 forms;
direct shortcuts do not bypass replacement review or source validation.

## Contextual command input

Run **RE35: Manage Command Contexts**. Inspect the example or add contexts and
rules. A rule chooses its current context, case-sensitive input sequence,
registered action, literal arguments and the context to enter after completion.
Context names and nonempty-selection requirements are editable.

1. Choose **Save definitions**. The example must be saved before activation.
2. Return to the source editor and run **RE35: Enter Command Input**. Activation
   is explicit and belongs to that source only.
3. In the example, type `l` to select the current line. It runs immediately and
   enters the selected-line context.
4. Type `C` to uppercase the actual selection. Completion returns to ordinary
   typing. No final Enter is required.

These letters are editable data, not built-in Vim bindings. A selection alone
never activates command input. A completed rule executes immediately; only an
incomplete prefix waits. A rule cannot be both complete and a prefix of another
rule in the same context. Ambiguous definitions are refused before activation.

Escape is the example's cancel control. **RE35: Return to Ordinary Typing** also
ends the scope. Backspace removes pending input without undoing completed
actions. An unowned text input ends the scope, discards any consumed prefix and
passes only the current input once to the editor. Consumed letters are not
replayed. Focus/source changes, unrelated edits or selection changes and opening
a RE35 form also close the scope; return does not silently reactivate it.

Pasted or multi-character text is passed as a whole. IME composition is intended
to remain ordinary editor input; see the release's
[verification limits](compatibility.md#input-and-interface).

The supported profile has up to 32 contexts, 256 rules and 16 tokens per rule,
within 64 KiB. Text tokens are Unicode scalars. Named-key acquisition supports
unmodified F1–F24 and cancel/Backspace controls, with explicit ownership. General
count/operator grammar, arbitrary modified keys, recursion and multiple cursors
are not implemented.

## Function-key rules

**RE35: Manage Input Rules** provides the earlier atomic function-key profile.
Choose **VS Code**, then **Use default rules for this profile** or **Add rule**.
The editable defaults are F9 select word, F6 uppercase selection, F10 move by
words and F11 delete a line. They change the draft only.

Save, then explicitly **Activate saved rules**, or choose **Try draft in editor**
for this session. The runtime supports F1–F24; this authoring picker offers
F1–F12. **Pause Editor Input Rules** and **Resume Editor Input Rules** control
this connection. Contextual input and function-key activation are mutually
exclusive.

## State and history

| State | Lifetime |
| --- | --- |
| Unsaved authoring drafts | This extension window; cleared by explicit discard/reset or restart |
| Saved commands, function-key and contextual definitions | Local extension storage; retained after restart |
| Active portable project profile and current choices | Owning RE35 host session; load again after restart/context replacement |
| Active key ownership and incomplete prefixes | Current explicit input scope; never restored at startup |
| Tasks, command outcomes and input history | Bounded session history; not a permanent execution log |

**RE35: Inspect Input History** distinguishes acquired input from confirmed
action outcomes. **Clear Input History** clears display records only. It does
not undo edits, cancel work or change saved definitions. Ordinary writing is
not collected as a key log.

Trusted extensions can register new semantic actions; executable adapters are
separate from imported JSON. See the [command API](reference/command-api.md).
