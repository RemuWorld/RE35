-- Settings keeps draft transactions separate from sections and from the
-- environment which owns its scheduled replacement UI.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor, Profile = require('command_tree'), require('command_tree.settings_editor'), require('command_tree.profile')
local W = require('command_tree.workspaces')
local folder = H.tempdir('settings-lifecycle')
local executions, callbacks, source_reads = 0, 0, 0
local initial = Profile.empty()
initial.workspaces.templates = { { id = 'fixture-board', name = 'Fixture Board', commands = { 'fixture.run' }, sources = { 'quickfix' } } }
initial.tools = { fixture = { command = 'nvim', args = { '--version' }, cwd = { base = 'project', path = '.' } } }
local function options(path)
  return { profile = { path = path or false, data = vim.deepcopy(initial) },
    usage = { path = false }, preferences = { path = false }, auto = false, operator_help = false, triggers = {},
    integrations = { theme = false },
    providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    commands = { { id = 'fixture.run', name = 'Fixture action', run = function() executions = executions + 1 end },
      { id = 'fixture.other', name = 'Other fixture action', run = function() executions = executions + 1 end } } }
end
local function setup(path) CE.close(); CE.setup(options(path)) end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function frame()
  H.eq('workspace', session.active and session.active.mode)
  local current = session.active.stack[#session.active.stack]
  H.eq('settings', current.id)
  return current
end
local function open(route)
  CE.close()
  H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = route or {} }))
  local current = frame()
  -- These independent section scenarios deliberately replace remembered route
  -- fields, including absent entity/detail fields from the preceding section.
  for _, name in ipairs({ 'section', 'entity', 'detail', 'argument', 'selected_id' }) do current.data[name] = (route or {})[name] end
  current.data.selected = 1
  return current
end
local function select_row(id)
  local current = frame()
  local found
  for _, row in ipairs(Editor.items(current, session.active)) do if row.id == id then found = row end end
  H.ok(found, 'Settings row remains stable: ' .. id)
  current.data.selected_id = id
  session:draw()
  return found
end
local function edit(id) select_row(id); keys('<CR>') end

-- Preview computes metadata/key policy without lifecycle/provider callbacks or
-- reading Results. Its returned metadata and base declarations are detached.
local manager = W.new()
manager:register({ id = 'fixture', name = 'Provider fixture',
  enter = function() callbacks = callbacks + 1 end, draw = function() callbacks = callbacks + 1 end,
  actions = { ping = { label = 'Ping', available = function() callbacks = callbacks + 1; return true end,
    run = function() callbacks = callbacks + 1 end } }, bindings = { p = 'ping' } })
manager:configure({ fixture = { keys = { ['\\'] = 'ping' } } }, { close = '<F12>' })
local live = manager:get('fixture')
local memory, order, bases, reserved = vim.deepcopy(manager.memory), vim.deepcopy(manager.order), manager.bases.fixture, vim.deepcopy(manager.reserved)
local Results, read = require('command_tree.results'), require('command_tree.results').read
Results.read = function() source_reads = source_reads + 1; error('Preview must not read Results') end
local preview = manager:preview_configuration({ templates = initial.workspaces.templates,
  overrides = { fixture = { name = 'Draft fixture', keys = { p = false, z = 'ping', ['\\'] = 'ping' } } } })
H.eq('Draft fixture', preview:get('fixture').name)
H.eq('ping', preview:get('fixture').bindings['\\'], 'Preview retains the exact active common-key policy')
H.eq(false, preview:get('fixture').bindings.p)
H.eq('ping', preview:get('fixture').bindings.z)
H.eq('Provider fixture', preview:base('fixture').name)
H.ok(preview:get('fixture-board'), 'A new portable Board is previewed before activation')
H.eq(nil, preview.push, 'Preview exposes no UI lifecycle')
H.eq(nil, preview:get('fixture').enter)
H.eq(nil, preview:get('fixture').draw)
H.eq(nil, preview:get('fixture').actions.ping.run)
H.eq(nil, preview:get('fixture').actions.ping.available)
local detached = preview:get('fixture')
detached.bindings.z, detached.actions.ping.label = false, 'changed'
H.eq('ping', preview:get('fixture').bindings.z)
H.eq('Ping', preview:get('fixture').actions.ping.label)
H.raises(function() manager:preview_configuration({ overrides = { fixture = { keys = { z = 'unknown' } } } }) end)
H.eq(live, manager:get('fixture'), 'Invalid preview preserves the live definition')
H.ok(manager:get('fixture') == live and manager.bases.fixture == bases, 'Preview never replaces active definitions or bases')
H.eq(order, manager.order)
H.eq(memory, manager.memory)
H.eq(reserved, manager.reserved)
H.eq(nil, manager:get('fixture-board'), 'New preview declarations never register in the live manager')
H.eq(0, callbacks)
H.eq(0, source_reads)
Results.read = read

-- Optional provider metadata is not a callback channel. The live declaration
-- remains compatible, but malformed metadata and its metatables cannot escape
-- through any preview access path or execute while extracting missing fields.
local metadata_calls = 0
local function metadata_callback() metadata_calls = metadata_calls + 1; error('Metadata is not executable') end
local metadata_metatable = { __index = metadata_callback, __pairs = metadata_callback, __tostring = metadata_callback }
manager:register({ id = 'metadata-fixture', name = 'Metadata fixture',
  path = setmetatable({ 'm', metadata_callback }, metadata_metatable),
  state_fields = { 'selected' },
  actions = { opaque = { label = 'Opaque metadata', hidden = metadata_callback, control = metadata_callback,
    run = metadata_callback }, normal = { label = 'Normal metadata', hidden = true, control = 'back', run = metadata_callback } },
  bindings = { m = 'opaque' } })
-- Manager normalizes actions into new tables. Simulate a provider attaching a
-- metatable to an optional action record after registering its valid handler.
setmetatable(manager.bases['metadata-fixture'].actions.opaque, metadata_metatable)
setmetatable(manager.bases['metadata-fixture'].state_fields, metadata_metatable)
local safe_preview = manager:preview_configuration()
local function plain_metadata(value)
  if type(value) == 'table' then
    H.eq(nil, getmetatable(value), 'Preview metadata has no provider metatable')
    for key, item in next, value do
      H.ok(type(key) == 'string' or type(key) == 'number', 'Preview keys are ordinary data')
      plain_metadata(item)
    end
  else H.ok(type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' or value == nil,
    'Preview values contain no function, userdata or live handle') end
end
local safe = safe_preview:get('metadata-fixture')
H.eq(nil, safe.path, 'Malformed path lists are omitted rather than copied')
H.eq({ 'selected' }, safe.state_fields, 'Valid string lists keep their values without their metatable')
H.eq(nil, safe.actions.opaque.hidden, 'Function-valued hidden metadata is omitted')
H.eq(nil, safe.actions.opaque.control, 'Function-valued control metadata is omitted')
H.eq(true, safe.actions.normal.hidden, 'Valid boolean action metadata is preserved')
H.eq('back', safe.actions.normal.control, 'Valid control metadata is preserved')
plain_metadata(safe)
plain_metadata(safe_preview:base('metadata-fixture'))
plain_metadata(safe_preview:list({ include_hidden = true }))
H.eq(0, metadata_calls, 'Preview extraction never invokes provider metadata callbacks')

setup()
local f = open({ section = 'ui' })
edit('width'); keys('<C-u>72<CR>')
H.eq(72, frame().data.draft.ui.width, 'UI section stages a typed input')
H.eq(nil, CE.profile().ui.width, 'Editing never commits the profile')
H.eq(true, frame().data.review)
keys('x'); H.eq(nil, frame().data.draft, 'Discard releases transaction state')
f = open({ section = 'tools', entity = 'fixture', detail = 'argv' })
edit('__add_arg__'); keys('extra<CR>')
H.eq({ '--version', 'extra' }, frame().data.draft.tools.fixture.args)
keys('e'); select_row('arg:2'); keys('d')
H.eq({ '--version' }, frame().data.draft.tools.fixture.args, 'Tool section reset removes the selected argument')
keys('x')
f = open({ section = 'workspaces', entity = 'fixture-board', detail = 'board_commands' })
edit('__add_command__'); keys('<CR>')
H.eq(2, #frame().data.draft.workspaces.templates[1].commands, 'Workspace section stages selected command content')
keys('e'); select_row('command:2'); keys('K')
H.eq('command:1', frame().data.selected_id, 'Board reorder retains the moved row selection')
keys('e<Left>')
H.eq('contents', frame().data.detail, 'Board content Back returns to its parent')
H.eq('commands', frame().data.selected_id)
keys('x')
f = open({ section = 'commands', detail = 'slots' })
edit('slot:1'); keys('/fixture.run<CR>')
H.eq('fixture.run', frame().data.draft.slots['1'], 'Commands section stages a command by stable ID')
keys('x')
H.eq(0, executions, 'Section editing, preview, reset and discard execute no connected commands')

-- A runtime mutation after baseline capture cannot be overwritten by Apply.
f = open({ section = 'ui' })
H.ok(Editor.stage(f, function(data) data.ui.width = 74 end))
CE.bind('Q', 'fixture.run')
local ok, reason = Editor.apply(f, f.ctx, session.active)
H.eq(false, ok)
H.ok(reason:find('Runtime bindings changed', 1, true))
H.eq(74, f.data.draft.ui.width, 'Rejected Apply retains the draft')
H.eq(nil, CE.profile().ui.width)

-- The headless fixture queues only the UI boundary so the source of the race
-- is explicit. The actual profile commit, environment replacement and reopen
-- all use production code.
local function defer(action)
  local queued, schedule, uis = {}, vim.schedule, vim.api.nvim_list_uis
  vim.schedule = function(callback) queued[#queued + 1] = callback end
  vim.api.nvim_list_uis = function() return { {} } end
  local success, result = xpcall(action, debug.traceback)
  vim.schedule, vim.api.nvim_list_uis = schedule, uis
  assert(success, result)
  H.eq(1, #queued, 'A successful Settings transaction schedules one replacement')
  H.eq(false, CE.state().active, 'The committed environment waits for its replacement UI')
  return queued[1]
end
setup()
f = open({ section = 'ui', selected_id = 'width' })
H.ok(Editor.stage(f, function(data) data.ui.width = 75 end))
local pending = defer(function() H.ok(Editor.apply(f, f.ctx, session.active)) end)
pending()
H.eq('ui', frame().data.section, 'The intended current environment reopens Settings')
H.eq('Settings applied in memory · this session only', frame().data.message)
H.eq(75, CE.profile().ui.width)
local old_owner = CE.environment_token()
pending = defer(function() H.ok(Editor.undo(session.active.ctx, session.active)) end)
H.ok(not CE.is_current_environment(old_owner), 'Undo creates a new owner')
setup()
pending()
H.eq(false, CE.state().active, 'A delayed Undo cannot reopen a subsequent setup')

f = open({ section = 'ui' })
H.ok(Editor.stage(f, function(data) data.ui.width = 76 end))
pending = defer(function() H.ok(Editor.apply(f, f.ctx, session.active)) end)
setup()
local owner = CE.environment_token()
pending()
H.eq(false, CE.state().active, 'A delayed Apply cannot open Settings in a subsequent environment')
H.ok(CE.is_current_environment(owner))
H.eq(nil, CE.profile().ui.width, 'Stale reopen cannot restore a previous profile')

f = open({ section = 'ui' })
H.ok(Editor.stage(f, function(data) data.ui.width = 77 end))
pending = defer(function() H.ok(Editor.apply(f, f.ctx, session.active)) end)
CE.open({ interactive = false })
local active = session.active
pending()
H.ok(session.active == active, 'A replacement callback preserves an independently opened current UI')
CE.close()

local saved = folder .. '/profile.json'
H.ok(Profile.write(saved, initial))
setup(saved)
f = open({ section = 'tools', entity = 'fixture' })
pending = defer(function() H.ok(Editor.reload(f, f.ctx, session.active)) end)
CE.disable()
pending()
H.eq(false, CE.state().active, 'A delayed Reload cannot reopen a disabled environment')
H.eq(0, executions)
print('Settings lifecycle: ' .. H.checks .. ' checks passed')
