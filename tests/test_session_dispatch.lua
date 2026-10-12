-- Actual form submission and shared authority boundaries across two Sessions.
local H = require('helpers')
local Session = require('command_tree.session')
local create, session, services = Session.new
Session.new = function(value) services = value; session = create(value); return session end
local CE, K = require('re35'), require('command_tree.keys')
CE.setup({ usage = { path = false }, preferences = { path = false }, profile = { path = false },
  providers = { plugins = false, runner = false, lsp = false, ex = false }, window = { icons = false } })
local inner = create(vim.tbl_extend('force', {}, services))
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(id)
  CE.close(); inner:close()
  session.drafts:forget(id, K.context().buf)
  CE.open({ command = id, interactive = false })
end
local outer, observed, completed = nil, {}, 0
local function fields()
  return { { name = 'value', required = true },
    { name = 'confirm', kind = 'boolean', required = true, default = false,
      items = { { label = 'Cancel', value = false }, { label = 'Apply', value = true } } } }
end
local function consume()
  return Session.consume_submission(outer.command, outer.ctx, outer.args, outer.operation)
end
CE.register({ id = 'test.scope_probe', name = 'Public scope probe', run = function()
  observed.cross_session = consume()
end })
CE.register({ id = 'test.scope_outer', name = 'Owned form', review_policy = 'explicit_apply', arguments = fields(),
  run = function(ctx, args, _, operation)
    outer = { command = session.registry:get('test.scope_outer'), ctx = ctx, args = args, operation = operation }
    inner:open({ interactive = false })
    observed.inner_accepted = inner:run('test.scope_probe')
    observed.same_session_accepted = session:run('test.scope_probe', nil, nil, function()
      observed.rejected_public = consume()
    end)
    -- The actual Registry hook throws before Executor admission. The public
    -- entry must restore the outer scope even when dispatch exits by error.
    inner:open({ interactive = false })
    local get = inner.registry.get
    inner.registry.get = function(registry, id)
      if id == 'test.scope_throw' then observed.throw_boundary = consume(); error('Intentional admission exception') end
      return get(registry, id)
    end
    observed.throw_ok, observed.throw_reason = pcall(inner.run, inner, 'test.scope_throw')
    inner.registry.get = get
    inner:close()
    observed.restored = consume()
    observed.replay = consume()
    if not observed.restored then return false, 'Submitted approval was lost' end
    completed = completed + 1
  end })
open('test.scope_outer'); keys('approved<CR><Down><CR>')
H.eq(1, completed, 'The original actual form completes after nested entries: '
  .. vim.inspect(observed) .. '; ' .. vim.inspect(CE.operations()[1] and CE.operations()[1].detail))
H.eq(true, observed.inner_accepted)
H.eq(false, observed.cross_session, 'A different Session cannot borrow exact outer invocation objects')
H.eq(false, observed.same_session_accepted)
H.eq(false, observed.rejected_public, 'A rejected public entry masks authority before its callback')
H.eq(false, observed.throw_ok)
H.ok(observed.throw_reason:find('Intentional admission exception', 1, true))
H.eq(false, observed.throw_boundary, 'An admission hook sees no surrounding authority')
H.eq(true, observed.restored, 'The private outer scope is restored after a thrown nested entry')
H.eq(false, observed.replay, 'One invocation consumes approval once')
H.eq(false, CE.state().active)
H.eq(false, consume(), 'No scope survives a completed form')
H.ok(CE.execute('test.scope_probe', {}, { interactive = false }))
H.eq(false, observed.cross_session, 'A later independent public run receives no old authority')

local armed, mutation, permissions, mutation_calls = false, nil, {}, 0
CE.register({ id = 'test.scope_changed', name = 'Changing form', review_policy = 'explicit_apply', arguments = fields(),
  available = function()
    if armed then armed = false; mutation_calls = mutation_calls + 1; mutation(session.active) end
    return true
  end,
  run = function(ctx, args, _, operation)
    local accepted = Session.consume_submission(session.registry:get('test.scope_changed'), ctx, args, operation)
    permissions[#permissions + 1] = accepted
    return accepted, accepted and nil or 'The form changed before admission'
  end })
local function changed_form(change, label)
  mutation = change
  open('test.scope_changed'); keys('original<CR><Down>')
  H.eq(2, session.active.input.index, 'The fresh form is at its final Apply field')
  H.eq(true, require('command_tree.session.input').value(session.active.input))
  local calls, runs = mutation_calls, #permissions
  armed = true; keys('<CR>')
  H.eq(calls + 1, mutation_calls, 'The availability mutation runs once after submission')
  H.eq(runs + 1, #permissions, 'This invocation reports its own authority result')
  H.eq(false, permissions[#permissions], label .. ': no approval follows changed form data')
  H.eq('failed', CE.operations()[1].status, label .. ': no successful execution is recorded')
  H.eq(false, Session.consume_submission(outer.command, outer.ctx, outer.args, outer.operation))
end
changed_form(function(state) state.input.args.value = 'modified' end, 'Argument mutation')
changed_form(function(state)
  local cursor = state.input.context.cursor
  state.input.context.cursor = { cursor[1], cursor[2] + 1 }
end, 'Captured context mutation')
changed_form(function(state) state.input = vim.tbl_extend('force', {}, state.input) end, 'Live form replacement')
open('test.scope_changed'); keys('fresh<CR><Down><CR>')
H.eq(true, permissions[#permissions], 'A later fresh form obtains its own approval')
H.eq('succeeded', CE.operations()[1].status)
CE.close(); inner:close(); CE.disable(); Session.new = create
for _, win in ipairs(vim.api.nvim_list_wins()) do
  H.eq('', vim.api.nvim_win_get_config(win).relative, 'Both Sessions release their floating windows')
end
print('Session dispatch ownership checks: ' .. H.checks)
