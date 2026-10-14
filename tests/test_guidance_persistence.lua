-- Real host Settings and read-only first-use diagnostics, with isolated storage.
local H = require('helpers')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, P = require('re35'), require('command_tree.persistence')
local Editor, Transaction = require('command_tree.settings_editor'), require('command_tree.settings.transaction')
local folder = H.tempdir('guidance-persistence')
vim.o.columns, vim.o.lines = 120, 45
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'cpp'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'source remains unchanged' })
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local function setup(path)
  CE.close()
  CE.setup({ profile = { path = path or false }, usage = { path = false }, preferences = { path = false },
    integrations = { theme = false }, providers = { plugins = false, runner = false, native = false, ex = false, keymaps = false } })
end
local function keys(value)
  for _, key in ipairs(require('command_tree.keys').tokens(value)) do session:handle(key) end
end
local function frame() return session.active.stack[#session.active.stack] end
setup()
H.eq('session_only', CE.persistence_status().profile.state)
H.eq('session', CE.persistence_status().preferences.scope, 'UI preferences use the in-memory profile owner, not a misleading legacy path')
H.eq('Editor', CE.persistence_status().theme.owner)
H.ok(CE.registry():get('help.open') and CE.registry():get('help.integrations'))
H.ok(CE.registry():get('workspace.editor'))
local modules, operations = {}, #CE.operations()
for _, name in ipairs({ 'mason', 'conform', 'telescope.builtin' }) do modules[name] = package.loaded[name] end
local report = H.ok(CE.integration_status())
H.ok(#report >= 8)
local action
for _, item in ipairs(report) do if item.id == 'code.action' then action = item end end
H.ok(action and action.report and action.report.code == 'lsp_not_attached')
H.ok(action.report.guidance[1]:find('server', 1, true))
for _, name in ipairs({ 'mason', 'conform', 'telescope.builtin' }) do
  H.eq(modules[name], package.loaded[name], 'Diagnostic inspection does not load ' .. name)
end
H.eq(operations, #CE.operations(), 'Integration status never starts a Task')
H.eq(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
local exposed = CE.persistence_status(); exposed.profile.owner = 'changed by caller'
H.eq('RE35 profile', CE.persistence_status().profile.owner, 'Status snapshots are detached')
local callback_state
CE.open({ interactive = false, workspace = 'help', on_open = function(state) callback_state = state end })
H.eq(session.active, callback_state, 'Public on_open receives the existing one-state callback contract')
H.eq('help', frame().id)
keys('<Up>'); H.eq(7, frame().data.selected)
keys('<Down>'); H.eq(1, frame().data.selected)
keys('r'); H.eq('integrations', frame().data.section)
H.ok(#frame().data.report >= 8)
keys('<Esc>'); H.eq(nil, frame().data.section)
for _ = 1, 5 do keys('<Down>') end
keys('<CR>'); H.eq('persistence', frame().data.section)
keys('<Down>'); H.eq(2, frame().data.selected)
keys('<Esc>'); H.eq(nil, frame().data.section)
keys('<Esc>'); H.eq('tree', session.active.mode)
CE.close()

CE.open({ interactive = false, workspace = 'settings' })
local current = frame()
H.ok(Transaction.stage(current, function(data) data.ui.width = 62 end))
H.ok(P.settings(current):find('Draft', 1, true))
H.eq(nil, CE.profile().ui.width, 'Staged settings do not change applied values')
H.ok(Transaction.discard(current, current.ctx, session.active))
H.ok(not P.settings(current):find('Draft', 1, true))
H.ok(Transaction.stage(current, function(data) data.ui.width = 64 end))
H.ok(Transaction.apply(current, current.ctx, session.active))
H.eq(64, CE.profile().ui.width)
H.eq('Settings applied in memory · this session only', frame().data.message)
H.eq('session_only', CE.persistence_status().profile.state)
CE.close()

local path = folder .. '/profile.json'
setup(path)
H.eq('local_defaults', CE.persistence_status().profile.state, 'An absent file is not falsely reported as saved')
H.ok(CE.update_profile(function(data) data.ui.width = 66 end))
H.eq('saved', CE.persistence_status().profile.state)
H.eq('Saved · restored at startup', CE.persistence_status().profile.label)
setup(path); H.eq(66, CE.profile().ui.width, 'A fresh environment actually loads the saved profile')
H.eq('saved', CE.persistence_status().profile.state)
CE.open({ interactive = false, workspace = 'settings' })
current = frame()
H.ok(Transaction.stage(current, function(data) data.ui.width = 68 end))
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function(source, target)
  if target == path then return nil, 'EACCES: controlled save denial' end
  return rename(source, target)
end
local ok, why = Transaction.apply(current, current.ctx, session.active)
vim.uv.fs_rename = rename
H.eq(false, ok); H.ok(tostring(why):find('controlled save denial', 1, true))
H.eq(66, CE.profile().ui.width, 'A failed save keeps applied values')
H.ok(current.data.draft and current.data.draft.ui.width == 68, 'A failed save retains the editable draft')
H.eq('save_failed', CE.persistence_status().profile.state)
H.ok(P.settings(current):find('Draft', 1, true), 'An unsaved failed Apply is still a draft')
H.ok(Transaction.apply(current, current.ctx, session.active))
H.eq(68, CE.profile().ui.width)
H.eq('saved', CE.persistence_status().profile.state)
H.eq('Settings saved · restored at startup', frame().data.message)
CE.close()
H.raises(function() CE.setup({ navigation = { wrap = 'yes' } }) end)
H.raises(function() CE.setup({ window = { details = { max_height = 0 } } }) end)
H.eq(68, CE.profile().ui.width, 'Invalid new options retain the previous host')
CE.close()
local theme_path = folder .. '/theme.json'
CE.setup({ profile = { path = false }, usage = { path = false }, preferences = { path = false },
  theme = { persist = true, path = theme_path }, providers = { lsp = false, runner = false, native = false, ex = false, keymaps = false } })
vim.wait(20, function() return false end, 10)
rename = vim.uv.fs_rename
vim.uv.fs_rename = function(source, target)
  if target == theme_path then return nil, 'EACCES: controlled theme save denial' end
  return rename(source, target)
end
ok = CE.execute('ui.theme', { theme = 'desert' }, { interactive = false })
vim.uv.fs_rename = rename
H.eq(true, ok, 'Theme application can succeed while persistence fails')
H.eq('desert', vim.g.colors_name)
H.ok(session.active and session.active.message:find('saving', 1, true), 'The actual command UI keeps save failure visible instead of silently closing')
H.eq('save_failed', CE.persistence_status().theme.state)
keys('<C-h>'); H.eq('feedback', session.active.mode)
H.ok(session.active.feedback_inspection.full_message:find('controlled theme save denial', 1, true), 'Full storage warning remains inspectable')
keys('<Esc>'); H.eq('tree', session.active.mode)
H.ok(not vim.uv.fs_stat(theme_path), 'Failed theme save creates no misleading startup file')
CE.close()
H.ok(CE.execute('ui.theme', { theme = 'desert' }, { interactive = false }))
H.eq('saved', CE.persistence_status().theme.state)
CE.disable(); Session.new = construct
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative) end
print('Guidance and persistence: ' .. H.checks .. ' checks')
