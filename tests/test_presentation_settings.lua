-- Drive actual Settings rows, typed input, review, Apply and Undo.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor, Profile = require('command_tree'), require('command_tree.settings_editor'), require('command_tree.profile')
local Core, Data = require('command_environment.core.presentation'), require('command_tree.presentation_data')
local original = Profile.empty()
original.ui.width, original.ui.max_width = 62, 88
original.workspaces.overrides.history = { name = 'Unrelated History' }
original.layout.aliases.keep = 'fixture.action'
original.presets['fixture.action'] = { { name = 'Unrelated arguments', args = { value = 'unchanged' } } }
local executions = 0
local function setup(data)
CE.setup({ profile = { path = false, data = data or original }, preferences = { path = false }, usage = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = true, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
  commands = { { id = 'fixture.action', name = 'Unrelated command', run = function() executions = executions + 1 end } } })
end
setup()
H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = { section = 'ui' } }))
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function frame()
  H.eq('workspace', session.active and session.active.mode)
  local current = session.active.stack[#session.active.stack]
  H.eq('settings', current.id)
  return current
end
local function row(id)
  local current, found = frame()
  for _, item in ipairs(Editor.items(current, session.active)) do if item.id == id then found = item end end
  H.ok(found, 'The actual Settings row exists: ' .. id)
  current.data.selected_id = id; session:draw()
  return found
end
local function edit(id) row(id); keys('<CR>') end
local function text(value) keys('<C-u>'); H.ok(vim.paste({ value }, -1)); keys('<CR>') end
local function others(data)
  local detached = vim.deepcopy(data); detached.presentation = nil
  H.eq(original, detached, 'Preset authoring preserves every unrelated profile field')
  H.eq(0, executions, 'UI authoring never executes a connected command')
end
local function resolve(id, scene)
  local applied = vim.tbl_extend('force', CE.ui_defaults(), CE.profile().ui)
  return H.ok(Core.resolve(Data.core(CE.profile().presentation), id, scene, applied))
end

edit('__presentation__')
H.eq('presentation', frame().data.detail)
H.ok(row('preset:full')); H.ok(row('preset:compact')); H.ok(row('preset:minimal'))
edit('__create__'); H.eq('input', session.active.mode); text('my-mode')
H.eq(true, frame().data.review, 'Creation opens the standard Settings review')
H.eq(nil, CE.profile().presentation, 'Creation is inert until Apply')
H.eq('full', frame().data.draft.presentation.presets['my-mode'].extends)
H.eq('my-mode', frame().data.entity, 'Continue editing has a stable preset destination')
keys('e'); edit('name'); text('My readable mode')
H.eq('My readable mode', frame().data.draft.presentation.presets['my-mode'].name)
keys('e'); edit('spacing'); edit('horizontal'); text('4')
H.eq(4, frame().data.draft.presentation.presets['my-mode'].spacing.horizontal)
keys('e<Left>'); H.eq('presentation', frame().data.detail)
edit('__scenes__'); edit('scene:tree'); edit('information'); edit('title'); keys('<Down><CR>')
H.eq(false, frame().data.draft.presentation.presets['my-mode'].scenes.tree.information.title,
  'A scene has its own typed information override')
keys('e<Left><Left><Left>'); edit('__select__')
H.eq('my-mode', frame().data.draft.presentation.selected)
others(CE.profile())
keys('a')
H.eq('my-mode', CE.profile().presentation.selected, 'Apply selects the reviewed named preset')
H.eq('My readable mode', resolve('my-mode').name)
H.eq(4, resolve('my-mode').spacing.horizontal)
H.eq(false, resolve('my-mode', 'tree').information.title)
H.eq(true, resolve('my-mode', 'search').information.title, 'A tree override does not leak into another scene')
H.eq('my-mode', frame().data.entity, 'Apply returns to the owning preset')
others(CE.profile())
keys('u')
H.eq(nil, CE.profile().presentation, 'Undo restores the exact optional absent presentation field')
others(CE.profile())

-- Built-ins can be edited, but deletion is not offered. Discard is inert.
edit('preset:minimal'); H.eq('minimal', frame().data.entity)
local has_delete = false
for _, item in ipairs(Editor.items(frame(), session.active)) do has_delete = has_delete or item.id == '__delete__' end
H.eq(false, has_delete, 'Built-in modes remain available')
edit('spacing'); edit('horizontal'); text('5')
H.eq(5, frame().data.draft.presentation.presets.minimal.spacing.horizontal)
keys('x'); H.eq(nil, CE.profile().presentation, 'Discard leaves live built-in defaults untouched')
keys('<Left>'); edit('__clone__'); text('minimal-copy')
H.eq(true, frame().data.review)
H.eq(2, frame().data.draft.presentation.presets['minimal-copy'].spacing.horizontal,
  'Clone captures the applied source, not a discarded preview')
H.eq(false, frame().data.draft.presentation.presets['minimal-copy'].extends, 'Clone is a detached resolved snapshot with an immutable factory root')
keys('a')
local cloned = vim.deepcopy(CE.profile())
others(cloned)
edit('roles'); edit('accent:fg'); text('#aabbcc')
H.eq('#AABBCC', frame().data.draft.presentation.presets['minimal-copy'].roles.accent.fg)
keys('a'); H.eq('#AABBCC', resolve('minimal-copy').roles.accent.fg)
keys('u'); H.eq(cloned, CE.profile(), 'Color Undo restores the preceding complete profile')

-- Validation failure retains the previous draft and live profile. Field reset
-- removes only the named override and drops stale typed review annotations.
keys('<Left>'); edit('spacing'); edit('horizontal'); text('9')
H.eq('input', session.active.mode, 'Out-of-range typed spacing remains in input')
keys('<Esc>')
H.eq(cloned, CE.profile())
row('horizontal'); keys('d')
H.eq(true, frame().data.review)
H.eq(nil, frame().data.draft.presentation.presets['minimal-copy'].spacing.horizontal)
keys('a'); H.eq(0, resolve('minimal-copy').spacing.horizontal, 'A detached clone inherits Full when its copied override is removed')
keys('u'); H.eq(cloned, CE.profile())

keys('<Left>'); edit('__delete__')
H.eq(true, frame().data.review, 'Delete is reviewed before removing a user mode')
H.ok(CE.profile().presentation.presets['minimal-copy'], 'Review does not delete live data')
keys('a'); H.eq(nil, CE.profile().presentation.presets['minimal-copy'])
keys('u'); H.eq(cloned, CE.profile(), 'Undo restores the deleted declaration')
others(CE.profile())

-- The offered Default parent is a real selectable value, not an empty value
-- accidentally refused by the generic required-input check.
edit('preset:minimal-copy'); edit('extends'); keys('<Down><Down><Down><CR>')
H.eq('minimal', frame().data.draft.presentation.presets['minimal-copy'].extends)
keys('a'); H.eq('minimal', CE.profile().presentation.presets['minimal-copy'].extends)
edit('extends'); keys('<Up><Up><Up><Up><CR>')
H.eq(true, frame().data.review, 'Default parent opens review instead of a required-input error')
H.eq(nil, frame().data.draft.presentation.presets['minimal-copy'].extends)
keys('a'); H.eq(nil, CE.profile().presentation.presets['minimal-copy'].extends)
keys('u'); H.eq('minimal', CE.profile().presentation.presets['minimal-copy'].extends, 'Undo restores the explicit parent')
keys('u'); H.eq(cloned, CE.profile(), 'Parent edits preserve the original detached clone through Undo')
others(CE.profile())
CE.close()

-- A compact source never inherits editable Full declarations. Its clone must
-- preserve that behavior when Full has unrelated scene and color overrides.
local configured = vim.deepcopy(original)
configured.presentation = { version = 1, selected = 'compact', presets = {
  full = { roles = { normal = { fg = '#FF0000' } }, scenes = { tree = { spacing = { horizontal = 6 } } } },
} }
setup(configured)
H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = { section = 'ui', detail = 'presentation' } }))
local source_model, source_tree = resolve('compact'), resolve('compact', 'tree')
edit('preset:compact'); edit('__clone__'); text('compact-snapshot')
H.eq(false, frame().data.draft.presentation.presets['compact-snapshot'].extends)
keys('a')
local function same_style(first, second)
  for _, group in ipairs({ 'information', 'layout', 'spacing', 'decoration', 'roles' }) do H.eq(first[group], second[group], 'Clone preserves resolved ' .. group) end
end
same_style(source_model, resolve('compact-snapshot'))
same_style(source_tree, resolve('compact-snapshot', 'tree'))
H.eq(nil, resolve('compact-snapshot').roles.normal.fg, 'Configured Full color cannot leak into a compact clone')
keys('<Left>'); edit('preset:full'); edit('roles'); edit('normal:fg'); text('#00FF00'); keys('a')
keys('<Left>'); edit('__scenes__'); edit('scene:tree'); edit('spacing'); edit('horizontal'); text('3'); keys('a')
same_style(source_model, resolve('compact-snapshot'))
same_style(source_tree, resolve('compact-snapshot', 'tree'))
H.eq(nil, resolve('compact-snapshot').roles.normal.fg, 'Later Full color edits do not change the clone')
others(CE.profile())
CE.close()
print('Presentation Settings workflow: ' .. H.checks .. ' checks passed')
