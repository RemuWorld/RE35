local H = require('helpers')
local Session = require('command_tree.session')
local create, session = Session.new
Session.new = function(services) session = create(services); return session end
local CE = require('command_tree')
CE.setup({ usage = { path = false }, preferences = { path = false }, profile = { path = false },
  auto = false, operator_help = false, triggers = {},
  providers = { plugins = false, runner = false, lsp = false, ex = false }, window = { icons = false } })
local nested, left = {}, 0
CE.register_workspace({ id = 'parent', name = 'Parent' })
CE.register_workspace({ id = 'child', name = 'Child', leave = function()
  left = left + 1
  nested = { session:back() }
end })
CE.open({ workspace = 'parent', interactive = false })
H.ok(session:enter_workspace('child'), 'Child workspace opens inside the parent')
local state = session.active
local navigation, returns = state.navigation, vim.deepcopy(state.workspace_returns)
state.workspace_mutating = true
local accepted, reason = session:back()
H.eq(false, accepted, 'Back rejects an active lifecycle transition')
H.ok(reason:find('already changing', 1, true), 'Rejected Back explains the lifecycle owner')
H.eq('workspace', state.mode, 'Rejected Back keeps workspace mode')
H.eq({ 'parent', 'child' }, CE.state().workspaces, 'Rejected Back keeps both workspace frames')
H.eq(returns, state.workspace_returns, 'Rejected Back keeps the return route')
H.eq(navigation, state.navigation, 'Rejected Back does not claim a navigation change')
state.workspace_mutating = nil
session:back()
H.eq(false, nested[1], 'Back from a leave hook rejects lifecycle reentry')
H.eq(1, left, 'Child leave executes exactly once')
H.eq({ 'parent' }, CE.state().workspaces, 'Outer Back completes the parent return')
H.eq('workspace', CE.state().kind, 'Parent remains in workspace mode')
session:back()
H.eq('tree', CE.state().kind, 'Next Back leaves the parent to its original home')

CE.register_workspace({ id = 'broken_leave', name = 'Broken leave', leave = function() error('fixture cleanup failed') end })
H.ok(session:enter_workspace('broken_leave'), 'Workspace with failing cleanup opens')
session:back()
H.eq({}, CE.state().workspaces, 'Failed cleanup still releases the popped workspace')
H.eq('tree', CE.state().kind, 'Completed pop restores the actual parent mode')
H.ok(CE.state().message:find('fixture cleanup failed', 1, true), 'Cleanup failure remains visible after the return')

-- The receipt must reject source drift independently of presentation density.
local Navigation = require('command_tree.session.navigation')
state = session.active
state.mode, state.inspected_id = 'inspect', 'file.save'
local receipt = H.ok(Navigation.capture_settings(state), 'Read-only Inspect route can be captured')
H.ok(Navigation.validate_settings(receipt, state.ctx), 'Unchanged source receipt validates')
local original_type = vim.bo[state.ctx.buf].filetype
vim.bo[state.ctx.buf].filetype = 'lua'
H.eq(nil, Navigation.validate_settings(receipt, state.ctx), 'Receipt refuses changed filetype')
vim.bo[state.ctx.buf].filetype = original_type
vim.api.nvim_buf_set_lines(state.ctx.buf, 0, -1, false, { 'one', 'two' })
receipt = H.ok(Navigation.capture_settings(state), 'Capture the new source revision')
vim.api.nvim_win_set_cursor(state.ctx.win, { 2, 0 })
H.eq(nil, Navigation.validate_settings(receipt, state.ctx), 'Receipt refuses changed source cursor')
CE.close(); CE.disable(); Session.new = create
print('Navigation lifecycle checks: ' .. H.checks)
