-- Document operations initialize without loading optional declaration rules.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local profile, workflow, search, follow_up = 'command_environment.core.profile', 'command_environment.core.workflow', 'command_environment.core.search_provider', 'command_environment.core.follow_up'
local presentation = 'command_environment.core.presentation'
check(package.loaded[profile] == nil and package.loaded[workflow] == nil and package.loaded[search] == nil
  and package.loaded[follow_up] == nil and package.loaded[presentation] == nil, 'Optional rules start unloaded')
require('command_environment.core.bridge')
ce_bridge_init('optional-rules')
local function call(operation, data)
  local envelope = J.decode(ce_bridge(operation, J.encode(data or U.object())))
  check(envelope.ok, 'Successful ' .. operation)
  return envelope.value
end
check(call('snapshot').protocol_version == 1, 'Protocol remains version one')
check(call('profile_capabilities').authority == 'data_only', 'Capabilities need no declarations')
local result = call('document_search', { snapshot = { uri = 'file:///sample.txt', revision = '1', encoding = 'utf-16',
  lines = U.array({ '한😀 needle' }) }, query = 'needle' })
check(#result.locations == 1, 'Document search works through the actual bridge')
check(package.loaded[profile] == nil and package.loaded[workflow] == nil and package.loaded[search] == nil
  and package.loaded[follow_up] == nil and package.loaded[presentation] == nil,
  'Document/capabilities operations leave optional rules unloaded')
local proposal_request = { task_id = 7, action = 'retry', readiness = 'ready',
  original = U.object({ project = 'sample', recipe = 'build', configuration = 'Debug', target = 'A' }) }
local proposal = call('follow_up_proposal', proposal_request)
check(proposal.schema == 1 and proposal.id == 'retry' and proposal.destination == 'execution'
  and proposal.task_id == 7 and proposal.readiness == 'ready', 'Shared proposal retains action identity')
check(proposal.original.project == 'sample' and proposal.original.recipe == 'build'
  and proposal.original.configuration == 'Debug' and proposal.original.target == 'A', 'JSON choice objects normalize without losing original values')
check(package.loaded[follow_up] ~= nil and package.loaded[profile] == nil and package.loaded[workflow] == nil
  and package.loaded[search] == nil, 'Follow-up loads only its own rules')
local copied = call('follow_up_proposal', J.decode(J.encode(proposal_request)))
check(copied ~= proposal and U.deep_equal(copied, proposal), 'Copied request data yields another proposal, not authority')
check(call('follow_up_proposal', { task_id = 7, action = 'review', readiness = 'unknown',
  reason = 'Original profile changed', original = U.object() }).reason == 'Original profile changed', 'Unavailable/unknown proposals carry a concrete reason')
check(call('follow_up_proposal', { task_id = 7, action = 'details', readiness = 'ready' }).original == nil, 'Optional original choices remain omitted')
check(#call('snapshot').operations == 0, 'Ready/copied follow-up proposals grant no execution')
local request = call('search_request', { provider = 'builtin', query = '한😀 needle' })
check(request.provider == 'builtin' and request.mode == 'literal' and request.case == 'sensitive', 'Shared search defaults resolve')
check(package.loaded[search] ~= nil and package.loaded[profile] == nil and package.loaded[workflow] == nil, 'Search loads only its own rules')
check(call('search_report', { request = request, available = true }).coordinates.encoding == 'utf-8', 'Search provenance has explicit coordinates')
check(call('search_manifest', { provider = 'ripgrep', available = false }).available == false, 'Unavailable selected provider has no fallback')
local function rejected(operation, data)
  local envelope = J.decode(ce_bridge(operation, J.encode(data)))
  check(envelope.ok == false, 'Refuse invalid ' .. operation)
end
rejected('search_request', { provider = 'builtin', query = 'x', options = { mode = 'regex' } })
rejected('search_request', { provider = 'ripgrep', query = 'x', command = '/foreign/tool' })
rejected('search_report', { request = request, available = true, root = '/foreign' })
rejected('search_manifest', { provider = 'ripgrep', available = 'yes' })
check(package.loaded[presentation] == nil, 'Follow-up and search do not load presentation declarations')
local before_presentation = J.encode(call('snapshot'))
local capability = call('presentation_capabilities', { host = 'vscode' })
check(package.loaded[presentation] ~= nil and package.loaded[profile] == nil and package.loaded[workflow] == nil,
  'First presentation use loads only its own optional rules')
local P = package.loaded[presentation]
check(capability.contract_version == 1 and capability.host == 'vscode'
  and U.deep_equal(capability, P.capabilities('vscode')), 'Wire capability is the authoritative detached native manifest')
for section, values in pairs(capability.support) do
  for key, supported in pairs(values) do
    check(type(supported) == 'boolean', 'Every native presentation field explicitly declares support')
    if section ~= 'information' or key == 'icons' then
      check(not supported, 'Native widgets decline unsupported geometry, styles and icons: ' .. section .. '.' .. key)
    end
  end
end
local appearance = { version = 1, selected = 'focused', presets = {
  full = { roles = { normal = { fg = '#aabbcc' } },
    scenes = { tree = { information = { help = false } } } },
  focused = { name = '집중 😀', extends = 'full', information = { title = false, help = false, details = false, status = false },
    layout = { density = 'compact', width = 60 }, roles = { normal = { bg = '#102030' } },
    scenes = { tree = { spacing = { horizontal = 4 } }, search = { layout = { rows = 7 } },
      input = { decoration = { separator = false } }, review = { information = { details = true } },
      tasks = { information = { status = true } }, results = { layout = { position = 'bottom-right' } } } },
  detached = { extends = false },
} }
local normalized_before = J.encode(appearance)
for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
  local resolved = call('presentation_resolve', { presentation = appearance, scene = scene, host = 'vscode' })
  local requested = assert(P.resolve(appearance, nil, scene))
  local effective, fallbacks = P.negotiate(requested, P.capabilities('vscode'))
  check(U.deep_equal(resolved.requested, requested) and U.deep_equal(resolved.effective, effective)
    and U.deep_equal(resolved.fallbacks, fallbacks) and U.deep_equal(resolved.capabilities, capability),
    'Wire consumes inherited scene policy and the exact shared negotiation: ' .. scene)
  check(resolved.requested.id == 'focused' and resolved.requested.name == '집중 😀'
    and resolved.requested.roles.normal.fg == '#AABBCC' and resolved.requested.roles.normal.bg == '#102030',
    'Inherited Unicode name and partial role components survive the wire')
  local declined = {}; for _, fallback in ipairs(resolved.fallbacks) do declined[fallback.path] = true end
  for key, supported in pairs(capability.support.information) do
    check((not supported and declined['information.' .. key] == true)
      or (supported and declined['information.' .. key] == nil),
      'Fallback reporting matches actual native information support: ' .. key)
  end
  check(resolved.effective.layout.density == 'full' and resolved.effective.spacing.horizontal == 0
    and resolved.effective.decoration.border == 'none' and next(resolved.effective.roles.normal) == nil,
    'Declined cosmetic options retain deterministic native fallback intent')
end
check(J.encode(appearance) == normalized_before, 'Resolution cannot rewrite imported profile appearance')
local standalone = call('presentation_resolve', { presentation = appearance, id = 'detached', scene = 'tree', host = 'neovim' })
check(next(standalone.requested.roles.normal) == nil and #standalone.fallbacks == 0,
  'Standalone factory roots and Neovim support retain existing cross-host semantics')
local defaults = call('presentation_resolve', { scene = 'input', host = 'vscode' })
check(defaults.requested.id == 'full', 'Missing presentation resolves the existing Full factory default')
defaults.requested.information.title, defaults.effective.id, defaults.capabilities.support.layout.width = false, 'changed', true
local fresh = call('presentation_resolve', { scene = 'input', host = 'vscode' })
check(fresh.requested.information.title and fresh.effective.id == 'full'
  and not fresh.capabilities.support.layout.width, 'Results, effective values and capability discovery are detached')
for _, data in ipairs({ U.array(), U.null, { host = 'vscode', scene = 'tree', execute = true },
  { host = 'vscode' }, { scene = 'tree' }, { host = 'foreign', scene = 'tree' },
  { host = 'vscode', scene = 'workspace' }, { host = 'vscode', scene = U.null },
  { host = U.array(), scene = 'tree' }, { host = 'vscode', scene = 'tree', id = U.null },
  { host = 'vscode', scene = 'tree', presentation = U.array() },
  { host = 'vscode', scene = 'tree', presentation = U.null },
  { host = 'vscode', scene = 'tree', presentation = { version = 2 } },
  { host = 'vscode', scene = 'tree', presentation = { version = 1, selected = 'missing' } },
  { host = 'vscode', scene = 'tree', presentation = { version = 1, presets = { a = { extends = 'a' } } } },
  { host = 'vscode', scene = 'tree', presentation = { version = 1, presets = { a = { command = 'run' } } } } }) do
  rejected('presentation_resolve', data)
end
for _, data in ipairs({ U.array(), U.null, U.object(), { host = 'foreign' },
  { host = U.null }, { host = 'vscode', support = U.object() } }) do
  rejected('presentation_capabilities', data)
end
local invalid_utf8 = J.decode(ce_bridge('presentation_resolve', '{"host":"vscode","scene":"tree","presentation":{"version":1,"presets":{"a":{"name":"'
  .. string.char(192, 128) .. '"}}}}'))
check(invalid_utf8.ok == false, 'Invalid UTF-8 appearance is refused through the actual decoder')
check(J.encode(call('snapshot')) == before_presentation,
  'Presentation discovery, resolution and refusals change no engine navigation, selection or operation state')
local function follow_rejected(fields)
  local data = { task_id = 7, action = 'retry', readiness = 'ready' }
  for key, value in pairs(fields) do data[key] = value end
  rejected('follow_up_proposal', data)
end
follow_rejected({ permission = 'dispatch' })
rejected('follow_up_proposal', proposal)
rejected('follow_up_proposal', U.array())
rejected('follow_up_proposal', U.array({ proposal_request }))
rejected('follow_up_proposal', U.null)
for _, id in ipairs({ 0, -1, 1.5, '7', U.null }) do follow_rejected({ task_id = id }) end
follow_rejected({ action = 'install' })
follow_rejected({ action = U.array() })
follow_rejected({ readiness = 'running' })
follow_rejected({ readiness = 'unavailable' })
follow_rejected({ readiness = 'unknown' })
for _, reason in ipairs({ '', 'line\nbreak', 'nul\0byte', string.rep('x', 1025), U.array(), U.null }) do
  follow_rejected({ reason = reason })
end
for _, original in ipairs({ U.array(), U.array({ 'Debug' }), U.null, 'Debug',
  { root = '/private' }, { configuration = U.array() }, { target = U.null }, { project = '' },
  { recipe = 'line\nbreak' }, { target = string.rep('x', 257) } }) do follow_rejected({ original = original }) end
local oversized_id = J.decode(ce_bridge('follow_up_proposal', '{"task_id":9007199254740992,"action":"retry","readiness":"ready"}'))
check(oversized_id.ok == false, 'JSON task IDs outside the exact integer range are refused')
local argv = call('workflow_argv', { tool = { command = 'tool', args = U.array({ '{target}', '' }) },
  values = { root = '/project', file = '', configuration = 'Debug', target = 'A' } })
check(argv[2] == 'A' and argv[3] == '', 'First workflow use resolves exact argv')
check(package.loaded[workflow] ~= nil and package.loaded[profile] == nil, 'Workflow use loads only its own rules')
local prepared = call('profile_validate', { profile = { version = 1 } })
check(prepared.version == 1 and package.loaded[profile] ~= nil, 'First profile use loads and validates')
check(#call('snapshot').operations == 0, 'Lazy declaration access grants no execution')
print('Optional bridge rules: ' .. checks .. ' checks passed')
