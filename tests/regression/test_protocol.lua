-- Exercise the portable model with the editor API removed entirely.
local root = assert(vim.env.CE_TEST_ROOT)
arg = { root .. '/lua' }
-- Use only ordinary Lua file loading; the editor's runtime searcher also uses vim.
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then
    return '\nOnly portable core modules are allowed: ' .. name
  end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
assert(vim == nil, 'Independent host must not have vim')
package.path = assert(arg[1]) .. '/?.lua;' .. arg[1] .. '/?/init.lua;' .. package.path
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local E = require('command_environment.core.engine')
local N = require('command_environment.core.navigation')
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
for _, input in ipairs({ 'null', '[]', '{}', 'true', 'false', '0', '-12.5e2', '"가나다 😀"', '"\\ud83d\\ude00"', '{"array":[],"object":{},"null":null}' }) do
  local parsed = J.decode(input); check(U.deep_equal(J.decode(J.encode(parsed)), parsed), 'JSON roundtrip: ' .. input)
end
for _, input in ipairs({ '01', '1.', '1e', 'NaN', '9007199254740992', '{"a":1,"a":2}', '[1,]', '"\\ud800"', '"\\udc00"', 'true false', '"' .. string.char(192, 128) .. '"' }) do check(not pcall(J.decode, input), 'Reject malformed JSON') end
check(not pcall(J.decode, string.rep('[', 66) .. '0' .. string.rep(']', 66)), 'Reject deep JSON')
local engine = E.new()
engine.index:register({ id = 'demo.increment', name = '증가 😀', aliases = { 'inc' }, path = { 'd', 'i' }, cancellable = true,
  arguments = { { name = 'amount', kind = 'number', required = true, integer = true, min = 1, max = 9 } }, capabilities = { 'counter' } })
local target, cap = { token = 'counter:1', revision = '1' }, { counter = true }
local ticket = assert(engine:select('inc', target, cap))
check(not engine:invoke(ticket, { amount = 2 }, { token = target.token, revision = '2' }, cap), 'Reject stale target')
check(not engine:invoke(ticket, { amount = 0 }, target, cap), 'Validate argument bounds')
check(not engine:invoke(ticket, { amount = 1, extra = 4 }, target, cap), 'Reject undeclared arguments')
local args = { amount = 3 }; local request = assert(engine:invoke(J.decode(J.encode(ticket)), args, target, cap)); args.amount = 8
check(request.args.amount == 3, 'Snapshot arguments')
local claimed = assert(engine:claim(request.request_id, target, cap)); local counter = 0
counter = counter + claimed.args.amount
check(counter == 3 and not engine:claim(request.request_id, target, cap), 'Claim host execution once')
engine:close_ui(); engine:open_ui()
check(engine:complete(request.request_id, { status = 'succeeded', result = { counter = counter } }), 'Retain result after UI replacement')
check(not engine:complete(request.request_id, { status = 'succeeded' }), 'Reject double completion')
check(engine:snapshot().operations[1].result.counter == 3, 'Retain actual host result')
ticket = assert(engine:select('inc', target, cap)); engine.index:configure({ aliases = { add = 'demo.increment' } })
check(not engine:invoke(ticket, { amount = 1 }, target, cap), 'Reject stale registry selection')
ticket = assert(engine:select('inc', target, cap)); request = assert(engine:invoke(ticket, { amount = 1 }, target, cap))
check(engine:cancel(request.request_id) and not engine:claim(request.request_id, target, cap), 'Cancel before host execution')
check(engine:snapshot().operations[2].status == 'cancelled', 'Cancellation confirmation')
ticket = assert(engine:select('inc', target, cap)); request = assert(engine:invoke(ticket, { amount = 1 }, target, cap)); assert(engine:claim(request.request_id, target, cap))
check(engine:cancel(request.request_id) ~= nil, 'Request cooperative cancellation')
check(engine:snapshot().operations[3].status == 'pending', 'Request is not confirmed termination')
check(engine:complete(request.request_id, { status = 'cancelled', result = { partial = 'stdout' } }), 'Host confirms termination')
ticket = assert(engine:select('inc', target, cap)); request = assert(engine:invoke(ticket, { amount = 1 }, target, cap))
check(not engine:claim(request.request_id, { token = target.token, revision = 'changed' }, cap), 'Revalidate immediately before host execution')
check(engine:snapshot().operations[4].status == 'failed', 'Retain rejected execution result')
local nav = N.new(); nav.query = 'previous'; nav.selected_id = 'demo.increment'
N.push(nav, 'workspace-list'); N.push(nav, 'history'); check(N.back(nav) == 'workspace' and nav.workspace == 'workspace-list', 'Back returns to Workspace')
N.back(nav); check(nav.query == 'previous' and nav.selected_id == 'demo.increment', 'Restore UI state')
ticket = assert(engine:select('inc', target, cap)); request = assert(engine:invoke(ticket, { amount = 1 }, target, cap)); assert(engine:claim(request.request_id, target, cap))
local detached = engine:dispose(); check(#detached == 1 and detached[1].request_id == request.request_id, 'Explicit pending resource handoff')
check(not pcall(engine.complete, engine, request.request_id, { status = 'succeeded' }), 'Reject result after engine disposal')
check(#engine:dispose() == 0, 'Dispose is idempotent')
require('command_environment.core.bridge')
ce_bridge_init('schema-test')
for _, bad in ipairs({
  { id='bad', arguments={ {name='x',kind='unknown'} } },
  { id='bad', arguments={ {name='x',min='one'} } },
  { id='bad', arguments={ {name='x',min=3,max=1} } },
  { id='bad', arguments={ {name='x',required='yes'} } },
  { id='bad', arguments={ {name='x'}, {name='x'} } },
  { id='bad', arguments={ {name='x',items={ {value={handle='fake'}} }} } },
  { id='bad', arguments={ {name='x',callback='execute code'} } },
}) do
  check(J.decode(ce_bridge('register', J.encode(bad))).ok == false, 'Reject malformed command argument schema')
end
check(J.decode(ce_bridge('get', '{"id":"bad"}')).ok == false, 'Rejected metadata never becomes a command')
check(J.decode(ce_bridge('register', '{"id":"empty"}')).ok == true, 'Command without fields registers')
local empty_ticket = J.decode(ce_bridge('select', '{"id":"empty","target":{"token":"object","revision":"1"}}')).value
local empty_request = J.decode(ce_bridge('invoke', J.encode({selection=empty_ticket,target={token='object',revision='1'}}))).value
check(U.kind(empty_request.args) == 'object', 'Omitted arguments remain an empty object across the bridge')
local atomic = E.new()
atomic.index:register({ id = 'atomic' })
local atomic_ticket = assert(atomic:select('atomic', target))
local atomic_request = assert(atomic:invoke(atomic_ticket, {}, target))
assert(atomic:claim(atomic_request.request_id, target))
check(not pcall(atomic.finish, atomic, atomic.operations[atomic_request.request_id], true, false, { foreign = function() end })
  and atomic:snapshot().operations[1].status == 'pending', 'Rejected result data cannot commit a terminal operation')
check(atomic:complete(atomic_request.request_id, { status = 'succeeded', result = { recovered = true } })
  and atomic:invoke(assert(atomic:select('atomic', target)), {}, target) ~= nil,
  'Retry records completion once and releases the pending target')
print('portable protocol: ' .. checks .. ' checks PASS; ' .. _VERSION .. ' / ' .. (jit and jit.version or 'reference Lua'))
