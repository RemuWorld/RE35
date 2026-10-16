-- Inspection retains identity without retaining execution authority.
local H, K = require('helpers'), require('command_tree.keys')
local Follow = require('command_tree.project.follow_up')
local original_ce = package.loaded.command_tree
local task, records, commands, token, ctx, calls, validations
local function reset()
  task = { id = 7, command_id = 'fixture.build', status = 'failed', args = { configuration = 'Debug' },
    process_revision = 'one', process_target = { project = 'fixture', configuration = 'Debug', target = 'A' } }
  records, token, ctx, calls, validations = { task }, {}, K.context(), {}, 0
  commands = { ['fixture.build'] = { process_revision = 'one', process_validate_target = function()
    validations = validations + 1; return true
  end } }
end
local function dispatched(action, id)
  calls[#calls + 1] = { action = action, id = id }; return true
end
local fake = {
  operations = function() return records end,
  state = function() return { context = ctx } end,
  registry = function() return { get = function(_, id) return commands[id] end } end,
  environment_token = function() return token end,
  is_current_environment = function(value) return value ~= nil and value == token end,
  open_task_results = function(id) return dispatched('results', id) end,
  rerun = function(id) return dispatched('retry', id) end,
  recover_recipe = function(id) return dispatched('recover', id) end,
  review_task_recipe = function(id) return dispatched('review', id) end,
}
local inspection = { workspace_open = function(_, data) return dispatched('details', data.detail_id) end }
package.loaded.command_tree = fake
for _, action in ipairs({ 'details', 'results' }) do
  reset()
  local proposal = H.ok(Follow.offer(7, action))
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { 'unrelated note', 'another line' })
  vim.api.nvim_win_set_cursor(ctx.win, { 2, 1 })
  vim.bo[ctx.buf].filetype = 'lua'
  commands['fixture.build'] = { process_revision = 'replacement', process_validate_target = function()
    error('Read-only inspection must not run target validation')
  end }
  token = {} -- Appearance Apply rebuilds the host while retaining its Executor.
  task.args.configuration, task.process_target.target = 'Release', 'B'
  H.ok(Follow.dispatch(proposal, inspection), action .. ' remains available after unrelated drift')
  H.eq({ { action = action, id = 7 } }, calls, 'Inspection opens only its retained task')
  H.eq(0, validations, 'Inspection never runs execution admission')
  H.eq(false, Follow.dispatch(proposal, inspection), 'Read-only receipts are still consumed once')
end

reset(); task.status = 'pending'
local proposal = H.ok(Follow.offer(7, 'details'))
task.status = 'succeeded'
H.ok(Follow.dispatch(proposal, inspection), 'Progress does not expire Details')
proposal = H.ok(Follow.offer(7, 'results'))
H.ok(Follow.dispatch(proposal), 'Completed task Results remain inspectable')
reset(); proposal = H.ok(Follow.offer(7, 'results')); task.status = 'pending'
H.eq(false, Follow.dispatch(proposal), 'Results requires a currently completed destination')
H.eq({}, calls, 'Pending Results does not invoke a destination')

for _, mutate in ipairs({
  function() records = {} end,
  function() records = { vim.deepcopy(task) } end,
  function() task.command_id = 'fixture.different' end,
  function() ctx = { buf = -1, win = -1 } end,
  function() token = nil end,
}) do
  reset(); proposal = H.ok(Follow.offer(7, 'details')); mutate()
  H.eq(false, Follow.dispatch(proposal, inspection), 'Eviction, reuse and invalid destinations refuse inspection')
  H.eq({}, calls, 'Rejected inspection performs no operation')
end
reset(); proposal = H.ok(Follow.offer(7, 'details')); proposal.id = 'retry'
H.eq(false, Follow.dispatch(proposal, inspection), 'Inspection cannot be upgraded to execution')
H.eq({}, calls, 'Tampering never launches a command')
reset(); proposal = H.ok(Follow.offer(7, 'retry')); commands['fixture.build'] = { process_revision = 'replacement' }
H.eq(false, Follow.dispatch(proposal), 'Retry continues to require its original declaration')
H.eq({}, calls, 'Declaration replacement does not launch a retry')
reset(); proposal = H.ok(Follow.offer(7, 'retry')); token = {}
H.eq(false, Follow.dispatch(proposal), 'Execution consent cannot cross an environment change')
H.eq({}, calls, 'Environment replacement does not recover old execution consent')
package.loaded.command_tree = original_ce

-- Actual Settings -> Inspect -> explicit Run uses the current source facts.
local Session, Navigation = require('command_tree.session'), require('command_tree.session.navigation')
local create, session = Session.new
Session.new = function(services) session = create(services); return session end
local CE = require('command_tree')
local source = vim.api.nvim_get_current_buf()
local source_name = H.tempdir('effect-navigation') .. '/source.txt'
vim.api.nvim_buf_set_name(source, source_name)
local runs, writes, processes, seen = 0, 0, 0
local system = vim.system
vim.system = function() processes = processes + 1; error('Read-only navigation must not spawn') end
vim.api.nvim_create_autocmd('BufWritePre', { buffer = source, callback = function() writes = writes + 1 end })
CE.setup({ usage = { path = false }, profile = { path = false }, preferences = { path = false },
  auto = false, operator_help = false, triggers = {},
  providers = { builtin = false, plugins = false, ex = false, lsp = false, runner = false, native = false, keymaps = false },
  commands = { { id = 'fixture.inspect', name = 'Inspect fixture', run = function() error('Old command must not run') end } } })
H.ok(CE.open({ interactive = false }))
local state = session.active
state.mode, state.inspected_id, state.frames = 'inspect', 'fixture.inspect', { { mode = 'tree', path = {} } }
local receipt = H.ok(Navigation.capture_settings(state))
H.ok(session:enter_workspace('settings'))
state.settings_navigation = receipt
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'fresh source', 'second line' })
vim.bo[source].filetype = 'cpp'
vim.api.nvim_win_set_cursor(state.ctx.win, { 2, 3 })
local tick = vim.api.nvim_buf_get_changedtick(source)
CE.register({ id = 'fixture.inspect', name = 'New inspect fixture', replace = true,
  available = function(context)
    return context.changedtick == tick and context.filetype == 'cpp' and vim.deep_equal(context.cursor, { 2, 3 }),
      'Availability received an obsolete source context'
  end,
  run = function(context) runs, seen = runs + 1, vim.deepcopy(context) end })
H.ok(session:back() ~= false)
H.eq('inspect', state.mode, 'Read-only return retains Inspect after edits')
H.eq(tick, state.ctx.changedtick, 'Return refreshes text revision')
H.eq('cpp', state.ctx.filetype, 'Return refreshes filetype')
H.eq({ 2, 3 }, state.ctx.cursor, 'Return refreshes cursor')
H.eq(0, runs, 'Returning never executes the inspected command')
H.eq(0, #CE.operations(), 'Returning never creates a task')
H.eq(0, writes, 'Returning never writes a buffer')
H.eq(0, processes, 'Returning never starts a subprocess')
H.ok(session:run('fixture.inspect'), 'Explicit Run rechecks availability with the fresh context')
H.eq(1, runs, 'Only the explicit Run executes the current command')
H.eq(tick, seen.changedtick, 'Execution receives the refreshed revision')
H.eq({ 2, 3 }, seen.cursor, 'Execution receives the refreshed cursor')

H.ok(CE.open({ interactive = false }))
state = session.active
state.mode, state.inspected_id = 'inspect', 'fixture.inspect'
receipt = H.ok(Navigation.capture_settings(state))
vim.api.nvim_buf_set_name(source, source_name .. '.renamed')
H.eq(nil, Navigation.validate_settings(receipt, state.ctx), 'Rename changes source identity')
vim.api.nvim_buf_set_name(source, source_name)
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(state.ctx.win, other)
H.eq(nil, Navigation.validate_settings(receipt, state.ctx), 'Changed window buffer refuses the old return route')
vim.api.nvim_win_set_buf(state.ctx.win, source)
H.eq(nil, Navigation.validate_settings({}, state.ctx), 'Fabricated navigation tokens are refused')
H.eq(nil, Navigation.capture_settings({ ctx = state.ctx, mode = 'input', frames = {} }), 'A live form cannot become a Settings navigation receipt')
H.eq(1, runs, 'Rejected navigation performs no further action')
H.eq(0, writes, 'Identity failures never write a buffer')
H.eq(0, processes, 'Identity failures never start a subprocess')
CE.close(); CE.disable(); Session.new, vim.system = create, system
print('Effect-scoped navigation: ' .. H.checks .. ' checks PASS')
