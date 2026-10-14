# Share UI settings

Neovim's fixed-panel layout, details height, navigation wrapping and theme
storage are local setup options described in [configuration](configuration.md).
They do not add fields to the existing eight-value export below. Native VS Code
controls keep their host-owned geometry and capability reports.

## Export

Open Settings > UI > Export UI settings, enter a new `.json` filename inside an
existing directory, and press Enter. Successful export returns to Settings.
Apply or discard any Settings draft first: export captures the applied UI, not
unreviewed changes.

The file contains density, icons, width, maximum width/height, position and
Compact/Minimal row counts. Values combine local settings and profile overrides;
density follows the active view, or saved preferences when no view is active.
This exports configuration intent rather than a particular screen's measured
size or workspace-specific geometry.

The envelope uses `format: "re35.ui-settings"`, `version: 1`, `host: "neovim"`
and a `ui` object. Geometry uses terminal columns/rows. Values are plain bounded
data; numeric fields range from 1 to 65535 and the file is at most 4 KiB. The
supported positions are center, bottom, bottom-right, top and top-right.

The file contains no editor theme, commands, project/tool declarations, paths,
history or execution records. RE35 refuses existing destinations, active storage
paths and named source-buffer paths. Unsupported atomic-publication filesystems
report failure rather than overwrite or expose a partial file.

```lua
local re35 = require('re35')
local values, reason = re35.export_ui() -- Detached snapshot; no file write.
local ok, path_or_error = re35.export_ui('my-ui.json')
```

## Import, review and restore

Open Settings > UI > Import UI settings, or use `\sui`, and select the exported
`.json` file. Apply or discard any pending Settings draft first. Import reads
the file and opens the normal Settings review with effective Before and After
values; it does not change the active UI or saved profile yet. Inherited Before
values are labeled so making the same value an explicit override is visible.

Press `a` to Apply, `x` to Discard, or `e` to continue editing. After Apply,
Settings `u` restores the exact previous profile overrides, including inherited
values. Undo refuses to overwrite newer settings or runtime-binding changes.
The eight imported values become explicit UI overrides. Editor theme, commands,
project/tool declarations, workspace overrides and saved density preferences
remain separate from the import.

Only the exact version 1 Neovim envelope above is accepted. Missing fields,
unknown fields, wrong types, unsupported host/version, duplicate JSON keys,
invalid UTF-8 and trailing data are refused. Files must be existing regular
files without a symbolic link, at most 4 KiB. An incomplete read or file
replacement during reading is refused. Import runs no code or command.

If the command environment, Settings draft, source context or applied settings
change during file selection/reading, choose the file again. After successful
reading, the review owns a detached snapshot: later changes to that file do not
change what Apply commits. A profile/runtime conflict at Apply preserves the
draft and current settings.

This file is a Neovim UI snapshot, not a complete environment profile or a shared
named preset. Shared named presets use the separate
[presentation preset format](presentation-presets.md). The existing eight-field
format remains supported; VS Code applies supported preset information fields
with native fallbacks for geometry and style. A temporary view switch while entering an import does not change
its captured profile baseline or target.
