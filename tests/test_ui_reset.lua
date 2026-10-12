-- Reset all UI overrides is one reviewed Settings transaction, not a theme,
-- workspace or preference reset. Exercise the actual workspace key paths.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor, Profile = require('command_tree'), require('command_tree.settings_editor'), require('command_tree.profile')
local folder = H.tempdir('ui-reset')
local preferences = folder .. '/preferences.json'
vim.fn.writefile({ vim.json.encode({ version = 1, values = { density = 'compact' } }) }, preferences)
local local_window = { density = 'full', width = 66, max_width = 92, max_height = 12, icons = true,
  position = 'top-right', compact_rows = 5, minimal_rows = 2 }
local original = Profile.empty()
original.ui = { density = 'minimal', width = 55, max_width = 80, max_height = 9, icons = false,
  position = 'bottom', compact_rows = 4, minimal_rows = 1 }
original.workspaces.overrides.history = { name = 'Timeline fixture' }
local theme = 'fixture-theme-marker'
vim.g.colors_name = theme
local executions = 0
local function setup(ui)
  CE.close()
  local profile = vim.deepcopy(original)
  if ui ~= nil then profile.ui = vim.deepcopy(ui) end
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = preferences },
    window = vim.deepcopy(local_window), auto = false, operator_help = false, triggers = {},
    integrations = { theme = false },
    providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    commands = { { id = 'fixture.run', name = 'Fixture action', run = function() executions = executions + 1 end } } })
  H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = { section = 'ui' } }))
end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function frame()
  H.eq('workspace', session.active and session.active.mode)
  local current = session.active.stack[#session.active.stack]
  H.eq('settings', current.id)
  return current
end
local function select(id)
  local current, found = frame()
  for _, row in ipairs(Editor.items(current, session.active)) do if row.id == id then found = row end end
  H.ok(found, 'The actual Settings row exists: ' .. id)
  current.data.selected_id = id
  session:draw()
  return found
end
local function edit(id) select(id); keys('<CR>') end
local function other_state(profile)
  H.eq(original.workspaces, profile.workspaces, 'UI reset preserves portable workspace overrides')
  H.eq(theme, vim.g.colors_name, 'UI reset does not enter or change the editor theme')
  H.eq('compact', assert(require('command_tree.state_store').read(preferences)).values.density,
    'Saved preferences remain an inherited source, not reset data')
end

setup()
H.eq('minimal', session.active.density, 'Profile density initially overrides local and saved density')
local row = select('__reset_all__')
H.eq('Reset all UI overrides', row.label)
keys('<CR>')
H.eq({}, frame().data.draft.ui, 'Enter stages removal of all UI overrides')
H.eq(true, frame().data.review, 'Reset opens the ordinary transaction review')
H.eq(original.ui, CE.profile().ui, 'Reset never applies immediately')
other_state(CE.profile())
keys('x')
H.eq(nil, frame().data.draft, 'Discard removes the reset draft')
H.eq(original.ui, CE.profile().ui, 'Discard preserves exact live UI overrides')

-- A previous typed UI edit must not survive in review metadata after reset.
-- Another section's staged edit stays in the same transaction throughout.
edit('width'); keys('<C-u>76<CR>')
H.eq(76, frame().data.draft.ui.width)
keys('e<Left>')
edit('commands'); edit('__slots__'); edit('slot:1'); keys('/fixture.run<CR>')
H.eq('fixture.run', frame().data.draft.slots['1'])
keys('e<Left><Left>')
edit('ui'); select('__reset_all__'); keys('d')
local pending = frame()
H.eq({}, pending.data.draft.ui, 'The reset key also stages all UI removals')
H.eq('fixture.run', pending.data.draft.slots['1'], 'UI reset retains another section\'s staged edit')
H.eq(original.ui, CE.profile().ui, 'The combined draft remains unapplied')
H.eq(nil, CE.profile().slots['1'])
local width_change
for _, item in ipairs(Editor.items(pending, session.active)) do
  if item.id == 'ui.width' then width_change = item.change end
end
H.ok(width_change, 'Review includes the reset width')
H.eq('Default (66)', width_change.after, 'Reset review describes the inherited local width')
H.ok(not width_change.after:find('76', 1, true), 'Reset review never shows the superseded draft width')
keys('a')
H.eq({}, CE.profile().ui, 'Apply commits exactly the removal of profile UI overrides')
H.eq('fixture.run', CE.profile().slots['1'], 'Apply also commits the retained staged slot')
H.eq('compact', session.active.density, 'A reset profile inherits saved density instead of factory full')
H.eq(66, frame().data.window.width, 'The reopened UI inherits local width')
H.eq('top-right', frame().data.window.position, 'The reopened UI inherits local placement')
H.eq('Settings applied', frame().data.message)
other_state(CE.profile())
keys('u')
H.eq(original.ui, CE.profile().ui, 'Undo restores exact prior UI overrides')
H.eq(nil, CE.profile().slots['1'], 'Undo restores the whole reviewed transaction')
H.eq('minimal', session.active.density, 'Undo reactivates the prior profile density')
H.eq(55, frame().data.window.width)
other_state(CE.profile())

-- An already inherited UI has no transaction to review or commit. Both paths
-- report the no-op without inventing a settings history entry.
setup(vim.empty_dict())
select('__reset_all__'); keys('<CR>')
H.eq(false, frame().data.review)
H.eq('No settings changed', frame().data.message)
H.eq(0, #frame().data.changes, 'Empty overrides produce no staged changes')
H.eq({}, CE.profile().ui)
keys('x')
select('__reset_all__'); keys('d')
H.eq(false, frame().data.review)
H.eq('No settings changed', frame().data.message)
H.eq(0, #frame().data.changes)
H.eq('compact', session.active.density)
other_state(CE.profile())
H.eq(0, executions, 'Editing, reset, Apply and Undo do not execute a connected command')
CE.close()
print('UI reset workflow: ' .. H.checks .. ' checks passed')
