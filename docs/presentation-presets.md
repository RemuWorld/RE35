# Presentation presets

Neovim supports editable presentation presets. Full, Compact and
Minimal remain available; you can customize them or create additional named
modes. A preset changes RE35 panels, not the editor's entire theme or commands.
The optional VS Code desktop host applies supported information preferences
through native controls, with native appearance authoring and standalone sharing.
See [compatibility](compatibility.md) for host support and limitations.

## Create, edit and select

Open `\` > Settings > UI > Presentation presets. Select a preset to edit its
name, parent, information, layout, spacing, decoration, colors or scene overrides.
Choose **Use this preset** to stage its selection. **Create preset** starts from
Full; **Clone preset** copies the source's effective base and all six scenes
into a standalone preset. Later source or Full edits do not change the clone,
including color components that originally inherited the host theme.

A custom preset with no `extends` inherits configured Full; naming a nonexistent
parent is invalid. **Standalone defaults** uses the factory root, without another
preset's declarations or scene overrides.

Edits use the existing Settings draft. Review the Before/After values, then
press `a` to Apply, `x` to Discard or `e` to continue editing. Settings `u` restores
the previous profile after Apply, provided newer profile or runtime-binding
changes have not made that restoration unsafe.

Reset a field or group to inherit its parent again, or the factory root for a
standalone preset. Reset a built-in preset to
remove its overrides. Reset a custom preset's overrides to retain its name and
parent. Delete a custom preset only after other presets stop inheriting it;
the three built-in presets cannot be deleted. **Reset all presentation overrides**
returns to local setup defaults. The separate **Reset all UI overrides** action
still controls the eight existing UI fields.

**Use existing UI settings** clears the selected preset without deleting its
declarations. Existing density settings remain supported. When declarations are
present, they can still override the corresponding built-in preset.

## Independent settings and scenes

| Section | Settings |
| --- | --- |
| Information | Routine title, help, details, status and item icons |
| Layout | Full/Compact/Minimal list behavior, position, width, maximum width/height and visible rows |
| Spacing | Horizontal and vertical panel padding |
| Decoration | Popup border and separator |
| Colors | Foreground/background for normal, selected, muted, accent, warning and error roles |

Custom preset names do not add another rendering engine. Their layout density
chooses one of the three list behaviors while the other sections vary independently.
Minimal removes routine decoration and uses modest horizontal padding. Required
input, failure and review facts remain independent of optional visibility settings.
Workspace boundary colors remain distinct from decorative floating-panel borders.

Scene overrides are available for tree, search, input, review, tasks and results.
For example, use a short Compact tree while retaining explanations in reviews.
Parents supply base values and scene overrides; a child scene can replace the
inherited scene values. Colors inherit the host theme when no color is declared.
This does not select or export an editor colorscheme.

With a presentation configuration, `?` or `F1` cycles Full -> Compact -> Minimal
-> custom IDs in alphabetical order. Text-editing contexts retain their ordinary
`?` behavior; `F1` remains the view control. The applicable selection, input and
navigation stay in place. While a Settings draft is pending, switching affects
only the current session and does not save a selection that would invalidate its
review. This also applies while entering the first Settings value or an import
filename, before a draft exists. Otherwise the selected preset is saved; a failed
save is reported.

Small viewports can reduce padding, decorative borders or icons. The renderer
records these fallbacks. If required input or review facts cannot fit, enlarge
the panel or reduce spacing before continuing; clipped required facts cannot
authorize Apply. If a fact exceeds bounded wrapping even in a larger panel,
return to editing and shorten the input or simplify the draft.

## Local setup

```lua
require('re35').setup({
  presentation = {
    version = 1,
    selected = 'focused',
    presets = {
      focused = {
        name = 'Focused',
        extends = 'compact',
        information = { title = false, icons = false },
        spacing = { horizontal = 2, vertical = 0 },
        decoration = { border = 'rounded', separator = false },
        roles = { selected = { fg = '#FFFFFF', bg = '#304050' } },
        scenes = {
          review = { information = { title = true, details = true } },
        },
      },
    },
  },
})
```

Saved profile presentation settings take precedence over local setup. Presets
inherit the eight existing UI values before applying their explicit declarations;
for example, local width or icons can affect an inherited value. Appearance
profiles use `profile.presentation`; command argument presets remain the separate
`profile.presets` field.

## VS Code native preferences

The optional VS Code desktop host reads the same version 1 declaration from
its local `re35.presentation` setting:

```json
{
  "re35.presentation": {
    "version": 1,
    "selected": "focused",
    "presets": {
      "focused": {
        "extends": "minimal",
        "scenes": {
          "review": { "information": { "details": true } },
          "tasks": { "information": { "status": true } }
        }
      }
    }
  }
}
```

An applied portable profile's `presentation` collection overrides the local
collection. If that profile omits it, the host uses local settings again. The
same six scenes are tree, search, input, review, tasks and results.

Native controls support routine title, optional help, details and status
preferences. Only fields designated as optional may disappear: required input
questions, task identity/status and outcomes, failure/partial/stale notices,
original choices and save/review facts remain visible. Geometry, spacing, icons,
borders, separators and color roles use the editor's native presentation and
report fallbacks. Terminal dimensions do not become Quick Pick dimensions.

Run **RE35: Inspect Presentation Support** (`re35.presentationSupport`), or open
the recorded `s u p` command in RE35 discovery, to inspect a
scene's requested preset and native fallbacks. This inspection changes no
settings and starts no task. **RE35: Presentation Presets** opens native
creation, independent cloning, name/parent/field/scene editing, selection,
reset and deletion. Edits form one draft with Before/After, conflicts and all
six native fallback reports. Choose Apply, Discard or Continue editing explicitly;
the draft survives View-button cycling. Undo stages one restoration for review.

Apply saves a host-local authored collection in RE35's extension preferences.
It takes precedence over imported profile appearance and `re35.presentation`;
it does not rewrite the workflow profile or replace project/Task owners.
**Use profile / local defaults** clears that override after review. The same
saved collection is available after reopening the host. External storage changes
refuse stale editing; reload the VS Code window to load the new saved collection.
Malformed saved data is refused with a notice and uses profile/local appearance
so repair remains available.

**RE35: Export Presentation Presets** and **RE35: Import Presentation Presets**
use the same appearance-only version 1 envelope below. Export requires no pending
draft and a new local filename. Import replaces only the authored collection
after review, retaining unsupported declarations and its detached snapshot even
if the source file changes later. Neither operation starts a task or modifies
other profile sections. The existing portable-profile import is still available.

Changing only `re35.presentation` validates and applies appearance while keeping
the same helper, profile, project selection, retained Tasks/Results and pending
execution admission, including the active review. It updates the same native
widget while retaining input/query, active item and multiselection. Its eye button
cycles views for the VS Code host session without persisting or rewriting a profile.
Enter during refresh is ignored; only a fresh post-refresh choice can submit.
Invalid appearance leaves the previous valid settings and form active. Changing
the backend/profile owner, losing workspace trust or disposing the host still
refuses the old form. Informational rows do not submit an action.

Task, Results and review lists offer complete-facts inspection in a read-only
virtual document. It retains long original paths and arguments independently
of list elision or filtering, with no action links or execution authority. The
native form and query stay owned by the same review; use its explicit action to
proceed. The display snapshot is bounded to 1 MiB, with one retained snapshot per
service. An oversized required review is refused before its actions are offered.
See [compatibility](compatibility.md) for host support and limitations.

## Export, import and restore

Open Presentation presets > **Export presentation presets**, or use `\supe`.
Choose a new `.json` filename in an existing directory. Export requires applying
or discarding any pending Settings draft. It captures applied declarations and
the active or saved selection. Existing files, RE35 storage and named source
buffers are protected from replacement.

Use **Import presentation presets**, or `\supi`, to read a file into Settings
review. Import replaces the presentation collection; conflicting IDs and removed
declarations appear in the changes. It does not merge or replace commands,
recipes, workspace definitions, tools or execution history. Review before Apply;
Discard keeps current settings, and Settings Undo restores the prior collection.
The review owns a detached snapshot, so later changes to the file do not change
what Apply commits.

The shared file contains a `re35.presentation` version 1 envelope:

```json
{
  "format": "re35.presentation",
  "version": 1,
  "presentation": {
    "version": 1,
    "selected": "focused",
    "presets": {
      "focused": {
        "extends": "compact",
        "spacing": { "horizontal": 2 }
      }
    }
  }
}
```

Declarations preserve inheritance intent. The eight inherited UI values stay
local to the receiving host; sharing a preset does not snapshot those values.
Use the separate [UI settings format](ui-settings.md) to share those Neovim values.
No source paths, commands, executable style code or editor theme are included.

```lua
local re35 = require('re35')
local snapshot, reason = re35.export_presentation() -- Detached data; no write.
local ok, path_or_error = re35.export_presentation('focused.json')
local capabilities = re35.presentation_capabilities()
```

## Bounds and compatibility

The collection permits 32 explicit declarations, including built-in overrides,
with at most four inheritance edges to a built-in or standalone factory root.
IDs use a lowercase ASCII letter followed by lowercase letters, digits,
underscores or hyphens, up to 48
bytes. Display names are nonempty UTF-8 without control characters, up to 80 bytes.
Missing parents and cyclic inheritance are refused.

Width and maximum width range from 1 to 240; maximum height and visible rows from
1 to 80. Horizontal padding ranges from 0 to 6, vertical padding from 0 to 2.
Positions are center, bottom, bottom-right, top and top-right; borders are none,
rounded, single and double. Colors use `#RRGGBB`. Configuration and shared-file
size each have a 64 KiB ceiling, including the shared envelope for a file.

In Lua or JSON, `extends = false` / `"extends": false` selects the standalone
factory root. Older local placements such as `left` retain their historical host
placement through the internal compatibility model; explicit presets inherit
center as the unsupported-placement fallback and report it. Both use the same
renderer without rewriting local preferences or saved profiles.
An explicit preset position takes precedence.

Imports require bounded UTF-8 JSON with known fields and types. Duplicate fields,
arrays in object positions, unknown versions, invalid inheritance, symbolic links,
incomplete reads and changed Settings/source ownership are refused. Reading or
sharing appearance never runs code or authorizes a command.

Appearance changes preserve selected result locations and Task identity in
Neovim, and keep VS Code forms open. Sharing preserves the declarations; each
host reports fallbacks for unsupported geometry and style. It does not promise
identical screens across hosts. See [compatibility](compatibility.md).
