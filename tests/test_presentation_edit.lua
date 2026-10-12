-- Prepared for the consolidated suite: shared authoring and file-contract parity.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local E = require('command_environment.core.presentation_edit')
local P = require('command_environment.core.presentation')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label)
  check(U.deep_equal(J.decode(J.encode(expected)), J.decode(J.encode(actual))), label)
end
local function apply(config, action)
  local before = J.encode(config)
  local value, reason = E.edit(config, action)
  check(value ~= nil, reason or 'Edit succeeds')
  check(P.validate(value) ~= nil, 'Each returned edit satisfies the unchanged presentation contract')
  check(J.encode(config) == before, 'Each edit leaves its captured input unchanged')
  return value
end
local function refused(config, action, label)
  local before = J.encode(config)
  local value, reason = E.edit(config, action)
  check(value == nil and type(reason) == 'string' and #reason > 0, label)
  check(J.encode(config) == before, 'Rejected edit preserves its original declaration collection')
end
local schema = E.schema()
check(schema.version == 1 and schema.authority == 'data_only' and #schema.groups == 5 and #schema.scenes == 6,
  'Typed discovery covers five cosmetic groups and all six host scenes')
check(schema.groups[5].fields[1].kind == 'color_role' and schema.groups[5].fields[1].component_kind == 'color'
  and #schema.groups[5].fields[1].components == 2, 'Role widgets discover two optional color components')
schema.groups[1].fields[1].id, schema.scenes[1], schema.limits.presets = 'changed', 'changed', 1
check(E.schema().groups[1].fields[1].id ~= 'changed' and E.schema().scenes[1] == 'tree'
  and E.schema().limits.presets == 32, 'Catalog discovery has no aliases to later requests')
local empty = assert(P.validate(nil))
local config = apply(empty, { kind = 'create', id = 'focused', name = 'Focus 한😀' })
check(config.presets.focused.extends == 'full' and config.presets.focused.scenes == nil,
  'Create begins with an editable declaration inheriting Full, matching existing host authoring')
config = apply(config, { kind = 'set', id = 'full', group = 'roles', field = 'normal', component = 'fg', value = '#aabbcc' })
config = apply(config, { kind = 'set', id = 'focused', scene = 'tree', group = 'spacing', field = 'horizontal', value = 4 })
config = apply(config, { kind = 'set', id = 'focused', group = 'information', field = 'help', value = false })
check(not P.resolve(config, 'focused').information.help and P.resolve(config, 'focused').roles.normal.fg == '#AABBCC'
  and P.resolve(config, 'focused', 'tree').spacing.horizontal == 4, 'False visibility and normalized inherited colors are preserved')
config = apply(config, { kind = 'clone', id = 'snapshot', source = 'focused' })
check(config.presets.snapshot.extends == false and config.presets.snapshot.name == 'snapshot',
  'Clone retains a standalone parent and the requested new identity')
local prior = {}
for _, scene in ipairs(E.schema().scenes) do
  prior[scene] = assert(P.resolve(config, 'snapshot', scene))
  check(config.presets.snapshot.scenes[scene] ~= nil, 'Clone includes each resolved scene: ' .. scene)
end
config = apply(config, { kind = 'set', id = 'full', group = 'roles', field = 'selected', component = 'bg', value = '#112233' })
config = apply(config, { kind = 'set', id = 'focused', scene = 'tree', group = 'spacing', field = 'horizontal', value = 1 })
for _, scene in ipairs(E.schema().scenes) do
  equal(prior[scene], P.resolve(config, 'snapshot', scene), 'Standalone clone ignores later parent colors and scenes: ' .. scene)
  check(next(P.resolve(config, 'snapshot', scene).roles.selected) == nil,
    'A previously unset cloned role stays host-theme-owned: ' .. scene)
end
config = apply(config, { kind = 'rename', id = 'snapshot', name = 'Detached 한😀' })
config = apply(config, { kind = 'select', id = 'snapshot' })
check(config.selected == 'snapshot' and config.presets.snapshot.name == 'Detached 한😀', 'Rename and selection retain stable identity')
config = apply(config, { kind = 'clear_selection' })
check(config.selected == nil and config.presets.snapshot ~= nil, 'Clearing selection retains declarations for later use')
config = apply(config, { kind = 'parent', id = 'snapshot', parent = 'compact' })
check(config.presets.snapshot.extends == 'compact', 'Explicit parent edit is a declaration change')
config = apply(config, { kind = 'parent', id = 'snapshot', parent = false })
check(config.presets.snapshot.extends == false, 'False parent remains an explicit standalone policy')
config = apply(config, { kind = 'parent', id = 'snapshot' })
check(config.presets.snapshot.extends == nil, 'Omitted parent resets the explicit inheritance policy')
config = apply(config, { kind = 'reset', id = 'snapshot' })
equal({ name = 'Detached 한😀' }, config.presets.snapshot, 'Reset custom cosmetics retains name and current parent policy')
config = apply(config, { kind = 'set', id = 'snapshot', group = 'roles', field = 'normal', value = { fg = '#abcdef', bg = '#001122' } })
config = apply(config, { kind = 'reset', id = 'snapshot', group = 'roles', field = 'normal', component = 'fg' })
check(config.presets.snapshot.roles.normal.fg == nil and config.presets.snapshot.roles.normal.bg == '#001122',
  'Reset color component inherits that component while preserving its sibling')
config = apply(config, { kind = 'reset', id = 'snapshot', group = 'roles', field = 'normal' })
check(config.presets.snapshot.roles.normal == nil, 'Reset role removes its complete override')
config = apply(config, { kind = 'reset', id = 'snapshot', group = 'roles' })
check(config.presets.snapshot.roles == nil, 'Reset group removes only its authored group')
config = apply(config, { kind = 'set', id = 'snapshot', scene = 'review', group = 'information', field = 'details', value = false })
config = apply(config, { kind = 'reset', id = 'snapshot', scene = 'review', group = 'information', field = 'details' })
check(config.presets.snapshot.scenes.review.information.details == nil, 'Reset scene field restores inheritance')
config = apply(config, { kind = 'reset', id = 'snapshot', scene = 'review', group = 'information' })
check(config.presets.snapshot.scenes.review.information == nil, 'Reset scene group preserves other scenes')
config = apply(config, { kind = 'reset', id = 'snapshot', scene = 'review' })
check(config.presets.snapshot.scenes.review == nil, 'Reset scene removes its override')
config = apply(config, { kind = 'reset_scenes', id = 'focused' })
check(config.presets.focused.scenes == nil, 'Reset scenes removes all authored scene overrides')
config = apply(config, { kind = 'reset_name', id = 'snapshot' })
config = apply(config, { kind = 'reset_parent', id = 'focused' })
check(config.presets.snapshot.name == nil and config.presets.focused.extends == nil, 'Name and parent resets have explicit data operations')
config = apply(config, { kind = 'reset', id = 'full' })
check(config.presets.full == nil and P.resolve(config, 'full').roles.normal.fg == nil, 'Builtin reset removes only its configurable override')
config = apply(config, { kind = 'create', id = 'dependent', source = 'snapshot' })
refused(config, { kind = 'delete', id = 'snapshot' }, 'Delete refuses a parent referenced by another declaration')
config = apply(config, { kind = 'delete', id = 'dependent' })
config = apply(config, { kind = 'select', id = 'snapshot' })
config = apply(config, { kind = 'delete', id = 'snapshot' })
check(config.presets.snapshot == nil and config.selected == nil, 'Deleting the selected custom preset clears its selection')
equal(empty, apply(config, { kind = 'reset' }), 'Reset all returns the existing empty factory configuration')
for _, action in ipairs({
  {}, { kind = 'execute', id = 'focused' }, { kind = 'create', id = 'full' }, { kind = 'create', id = 'Upper' },
  { kind = 'create', id = 'extra', source = false }, { kind = 'create', id = 'extra', name = false },
  { kind = 'clone', id = 'extra' }, { kind = 'clone', id = 'extra', source = 'missing' },
  { kind = 'rename', id = 'focused', name = '' }, { kind = 'rename', id = 'focused', name = 'line\nbreak' },
  { kind = 'parent', id = 'focused', parent = 'focused' }, { kind = 'parent', id = 'focused', parent = 'missing' },
  { kind = 'delete', id = 'full' }, { kind = 'select', id = 'missing' }, { kind = 'clear_selection', id = 'focused' },
  { kind = 'set', id = 'focused', group = 'layout', field = 'width', value = 241 },
  { kind = 'set', id = 'focused', group = 'information', field = 'help', value = 'false' },
  { kind = 'set', id = 'focused', group = 'roles', field = 'normal', component = 'fg', value = 'red' },
  { kind = 'set', id = 'focused', group = 'layout', field = 'width', component = 'fg', value = 40 },
  { kind = 'set', id = 'focused', group = 'layout', field = 'missing', value = 40 },
  { kind = 'set', id = 'focused', scene = 'workspace', group = 'layout', field = 'width', value = 40 },
  { kind = 'set', id = 'focused', group = 'commands', field = 'run', value = 'execute' },
  { kind = 'reset', scene = 'tree' }, { kind = 'reset', id = 'focused', field = 'help' },
  { kind = 'reset', id = 'focused', group = 'information', field = 'help', component = 'fg' },
  { kind = 'rename', id = 'focused', name = 'Name', root = '/untrusted' },
}) do refused(config, action, 'Unsupported action shape/value refuses instead of staging partial data') end
local callback_called = false
local foreign = setmetatable({}, { __index = function() callback_called = true end })
local value, reason = E.edit(config, foreign)
check(value == nil and type(reason) == 'string' and not callback_called, 'Foreign action metatables are refused without invoking callbacks')
local thirty_two = { version = 1, presets = {} }
for index = 1, 32 do thirty_two.presets['p' .. index] = {} end
refused(thirty_two, { kind = 'create', id = 'extra' }, 'Authoring respects the existing 32-declaration limit')
for _, kind in ipairs({ 'reset_scenes', 'reset_name', 'reset_parent' }) do
  equal(thirty_two, apply(thirty_two, { kind = kind, id = 'full' }),
    'Resetting an unset builtin override never creates a 33rd declaration: ' .. kind)
end
local file_config = apply(config, { kind = 'clone', id = 'shared', source = 'focused' })
local envelope = assert(E.file_validate({ format = 're35.presentation', version = 1, presentation = file_config }))
local json = assert(E.file_encode(envelope))
check(json:sub(-1) == '\n' and #json <= 65536, 'Shared export is deterministic UTF-8 JSON with a budgeted trailing newline')
equal(envelope, E.file_decode(json), 'Shared appearance file retains standalone booleans and object markers on round trip')
check(E.file_decode(json).presentation.presets.shared.extends == false,
  'Export/import preserves the explicit false standalone parent without truthiness fallback')
equal(envelope, E.file_decode(json .. string.rep(' ', 65536 - #json)), 'Exact 64 KiB raw file remains readable when normalized data fits')
for _, input in ipairs({
  json .. string.rep(' ', 65537 - #json),
  '{"format":"re35.presentation","version":1,"version":1,"presentation":{"version":1}}',
  '{"format":"re35.presentation","version":1,"presentation":{"version":1,"presets":{"a":{"name":"\\ud800"}}}}',
  '{"format":"re35.presentation","version":1,"commands":{},"presentation":{"version":1}}',
  '{"format":"re35.presentation","version":1,"presentation":[]}',
}) do
  local decoded, why = E.file_decode(input)
  check(decoded == nil and type(why) == 'string' and #why > 0, 'Invalid raw file refuses duplicate keys, payload contamination, encoding and size violations')
end
require('command_environment.core.bridge'); ce_bridge_init('presentation-authoring')
local function call(op, data)
  local response = J.decode(ce_bridge(op, J.encode(data or U.object())))
  check(response.ok == true, 'Successful bridge ' .. op); return response.value
end
local before = J.encode(call('snapshot'))
equal(E.schema(), call('presentation_editor_schema'), 'Bridge schema is the shared typed catalog')
equal(config, call('presentation_edit', { presentation = config, action = { kind = 'clear_selection' } }),
  'Bridge authoring uses unchanged data-only rules')
equal(envelope, call('presentation_file_validate', { file = envelope }), 'Bridge file validation shares the host-independent envelope')
equal(envelope, call('presentation_file_decode', { json = json }), 'Bridge file decode preserves strict shared JSON semantics')
check(call('presentation_file_encode', { file = envelope }) == json, 'Bridge encoding returns exactly the same file bytes')
for _, spec in ipairs({
  { 'presentation_editor_schema', { host = 'vscode' } },
  { 'presentation_edit', { presentation = config, action = { kind = 'select', id = 'missing' } } },
  { 'presentation_edit', { presentation = config, action = { kind = 'clear_selection' }, dispatch = true } },
  { 'presentation_file_validate', { file = envelope, path = '/untrusted' } },
  { 'presentation_file_decode', { json = json, merge = true } },
  { 'presentation_file_encode', { file = envelope, overwrite = true } },
}) do
  local response = J.decode(ce_bridge(spec[1], J.encode(spec[2])))
  check(response.ok == false and type(response.error) == 'string', 'Wire actions refuse extra host authority and invalid edits')
end
check(J.encode(call('snapshot')) == before, 'Authoring, file codecs and refusals change no navigation, selection or execution state')
io.write('presentation_edit: ' .. checks .. ' checks passed\n')
