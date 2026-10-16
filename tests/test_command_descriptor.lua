-- Shared structural rules and real wire registration, without editor globals.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local D = require('command_environment.core.command_descriptor')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function equal(expected, actual, message) check(U.deep_equal(expected, actual), message) end
local function rejects(callback, message) check(not pcall(callback), message) end
local function has(fields, name)
  for _, value in ipairs(fields or {}) do if value == name then return true end end
  return false
end

for _, fields in ipairs({
  { { name = 'text' } },
  { { name = 'amount', kind = 'number', required = true, integer = true, min = 0, max = 3 } },
  { { name = 'choice', kind = 'select', items = { false, 0, 'value', { label = 'Labeled', value = 'labeled' } } } },
}) do
  check(pcall(D.validate_arguments, fields, 'host'), 'Native policy accepts ordinary static fields')
  check(pcall(D.validate_arguments, fields, 'protocol1'), 'Wire policy accepts ordinary static fields')
end
for _, fields in ipairs({
  { { name = '' } }, { { kind = 'text' } }, { { name = 'same' }, { name = 'same' } },
  { { name = 'value', kind = 'unknown' } }, { { name = 'value', required = 'yes' } },
  { { name = 'value', integer = 1 } }, { { name = 'value', min = 'one' } },
  { { name = 'value', min = 4, max = 2 } }, { [1] = { name = 'first' }, [3] = { name = 'third' } },
}) do
  rejects(function() D.validate_arguments(fields, 'host') end, 'Native policy rejects malformed structural fields')
  rejects(function() D.validate_arguments(fields, 'protocol1') end, 'Wire policy rejects malformed structural fields')
end
for _, bound in ipairs({ math.huge, -math.huge, 0 / 0 }) do
  rejects(function() D.validate_arguments({ { name = 'value', min = bound } }, 'host') end,
    'Native bounds must remain finite')
end

local callbacks = 0
local function host_callback() callbacks = callbacks + 1; error('Projection cannot invoke host behavior') end
local structured = { path = { 'project', 'target' }, enabled = false }
local fields = {
  { name = 'static', kind = 'select', prompt = 'Choose: ', description = 'Static selection',
    items = { { label = 'Structured', value = structured } }, default = structured },
  { name = 'dynamic', kind = 'select', items = host_callback, default = host_callback,
    completion = host_callback, validate = host_callback },
  { name = 'secret', secret = true, history = false, default = 'private-default',
    items = { 'private-choice' } },
  { name = 'native_completion', completion = 'file' },
}
check(pcall(D.validate_arguments, fields, 'host'), 'Native declarations retain structured values and host callbacks')
local projection = D.project_arguments(fields)
equal(structured, projection[1].default, 'Static structured default is represented')
equal(fields[1].items, projection[1].items, 'Static structured choices are represented')
check(projection[1].default ~= structured and projection[1].items ~= fields[1].items,
  'Projection owns static nested data')
equal('Static selection', projection[1].description, 'Native argument description is discoverable')
for _, key in ipairs({ 'items', 'default', 'completion', 'validate' }) do
  equal(nil, projection[2][key], 'Dynamic behavior is absent from projected argument: ' .. key)
  check(has(projection[2].host_fields, key), 'Dynamic argument identifies host-owned field: ' .. key)
end
equal(true, projection[3].secret, 'Privacy fact remains discoverable')
equal(false, projection[3].history, 'History policy remains discoverable')
for _, key in ipairs({ 'default', 'items' }) do
  equal(nil, projection[3][key], 'Secret values cannot enter projected argument: ' .. key)
  check(has(projection[3].host_fields, key), 'Secret field identifies omitted host-owned values: ' .. key)
end
equal(nil, projection[4].completion, 'Native completion mode does not become portable behavior')
check(has(projection[4].host_fields, 'completion'), 'Native completion mode remains explicitly host-owned')
equal(0, callbacks, 'Validation and projection execute no callbacks')
projection[1].default.path[1] = 'changed'
projection[1].items[1].value.path[1] = 'changed'
equal('project', structured.path[1], 'Projection cannot mutate native structured inputs')

local cyclic = {}; cyclic.self = cyclic
local foreign = setmetatable({ value = 'opaque' }, { __index = host_callback })
for _, value in ipairs({ host_callback, foreign, cyclic, math.huge, coroutine.create(host_callback) }) do
  local native_fields = { { name = 'value', default = value } }
  check(pcall(D.validate_arguments, native_fields, 'host'), 'Native default compatibility is unchanged')
  local projected = D.project_arguments(native_fields)[1]
  equal(nil, projected.default, 'Unsafe optional default is omitted from portable metadata')
  check(has(projected.host_fields, 'default'), 'Omitted optional default remains marked host-owned')
end
local unsafe_choices = { { name = 'choice', kind = 'select', items = { { value = host_callback } } } }
check(pcall(D.validate_arguments, unsafe_choices, 'host'), 'Host registration still defers choice interpretation')
local omitted_choices = D.project_arguments(unsafe_choices)[1]
equal(nil, omitted_choices.items, 'Unsafe optional choices are omitted as a unit')
check(has(omitted_choices.host_fields, 'items'), 'Unsafe choices remain explicitly host-owned')
equal(0, callbacks, 'Foreign metatables and callbacks are not evaluated')
local inherited_reads = 0
local inherited_field = setmetatable({ name = 'inherited' }, { __index = function(_, key)
  inherited_reads = inherited_reads + 1
  if key == 'prompt' or key == 'description' or key == 'default' then error('Discovery must not inspect inherited ' .. key) end
end })
check(pcall(D.validate_arguments, { inherited_field }, 'host'), 'Existing native validation accepts inherited presentation fields')
inherited_reads = 0
local inherited_projection = D.project_arguments({ inherited_field })[1]
equal(0, inherited_reads, 'Projection does not perform extra field metatable lookups')
equal('inherited', inherited_projection.name, 'Projection retains raw facts on a field with a metatable')
check(has(inherited_projection.host_fields, 'default') and has(inherited_projection.host_fields, 'prompt'),
  'Absent inherited fields remain explicitly host-owned')
local privacy_reads = 0
local inherited_private = setmetatable({ name = 'private', kind = 'select',
  default = 'inherited-private-default', items = { 'inherited-private-choice' } }, { __index = function(_, key)
    privacy_reads = privacy_reads + 1
    if key == 'secret' then return true end
  end })
check(pcall(D.validate_arguments, { inherited_private }, 'host'), 'Native validation preserves inherited privacy policy')
privacy_reads = 0
local private_projection = D.project_arguments({ inherited_private })[1]
equal(0, privacy_reads, 'Privacy-safe projection does not evaluate inherited flags')
equal(nil, private_projection.default, 'Inherited privacy cannot expose a raw default')
equal(nil, private_projection.items, 'Inherited privacy cannot expose raw choices')
check(has(private_projection.host_fields, 'secret') and has(private_projection.host_fields, 'default')
  and has(private_projection.host_fields, 'items'), 'Inherited privacy and values remain host-owned')

local command = { id = 'native.command', name = 'Native', arguments = fields,
  run = host_callback, preview = host_callback, available = host_callback }
local projected_command = D.project(command)
equal(command.id, projected_command.id, 'Command projection preserves semantic identity')
equal('static', projected_command.arguments[1].name, 'Command metadata includes argument schema')
for _, key in ipairs({ 'run', 'preview', 'available' }) do
  equal(nil, projected_command[key], 'Command projection carries no execution callback: ' .. key)
end
check(pcall(J.encode, projected_command), 'Projected discovery descriptor can be encoded as plain data')

-- These limits belong to Protocol 1, not to in-process Neovim declarations.
local many_fields, many_items = {}, {}
for index = 1, 65 do many_fields[index] = { name = 'field' .. index } end
for index = 1, 4097 do many_items[index] = index end
for _, wide in ipairs({ many_fields, { { name = string.rep('n', 65) } },
  { { name = 'nul\0name' } }, { { name = 'many', items = many_items } } }) do
  check(pcall(D.validate_arguments, wide, 'host'), 'Wire quota does not restrict native host declarations')
  rejects(function() D.validate_arguments(wide, 'protocol1') end, 'Existing wire quota remains enforced')
end

require('command_environment.core.bridge')
ce_bridge_init('descriptor-regression')
local function call(operation, data) return J.decode(ce_bridge(operation, J.encode(data or U.object()))) end
local initial = call('snapshot').value
equal(1, initial.protocol_version, 'Shared rules do not change the protocol version')
local wire = { id = 'wire.valid', aliases = { 'wire' }, path = { 'w' },
  arguments = { { name = 'amount', kind = 'number', required = true, integer = true, min = 1, max = 9 } } }
check(call('register', wire).ok, 'Actual bridge registers a shared static descriptor')
local returned = call('get', { id = 'wire.valid' })
check(returned.ok and returned.value.arguments[1].name == 'amount', 'Actual bridge retains typed arguments')
for _, bad_field in ipairs({
  { name = 'value', secret = true }, { name = 'value', history = false },
  { name = 'value', default = 'new-wire-field' }, { name = 'value', completion = 'file' },
  { name = 'value', description = 'new-wire-field' }, { name = 'value', host_fields = { 'default' } },
  { name = 'value', items = { { value = { path = 'native-only' } } } },
}) do
  local before = J.encode(call('snapshot').value)
  check(not call('register', { id = 'wire.rejected', aliases = { 'rejected' }, path = { 'r' },
    arguments = { bad_field } }).ok, 'Protocol 1 rejects native-only field or value')
  equal(before, J.encode(call('snapshot').value), 'Rejected wire schema makes no state mutation')
  check(not call('get', { id = 'wire.rejected' }).ok, 'Rejected wire metadata has no descriptor')
end
check(not call('register', { id = 'wire.root', run = 'native-only' }).ok,
  'Protocol 1 command field allowlist remains unchanged')
check(not call('register', { id = 'wire.fields', arguments = many_fields }).ok, 'Actual bridge retains field quota')
check(not call('register', { id = 'wire.items', arguments = { { name = 'many', items = many_items } } }).ok,
  'Actual bridge retains static choice quota')
local target = { token = 'fixture', revision = '1' }
local selected = call('select', { id = 'wire', target = target })
check(selected.ok, 'Alias still selects the registered command')
check(not call('invoke', { selection = selected.value, target = target, args = { amount = 0 } }).ok,
  'Actual bridge still enforces declared numeric bounds')
local invocation = call('invoke', { selection = selected.value, target = target, args = { amount = 3 } })
check(invocation.ok and invocation.value.args.amount == 3, 'Actual bridge still prepares valid typed invocation')
equal(0, callbacks, 'Pure metadata and wire operations cannot invoke native behavior')
print('Command descriptor checks: ' .. checks)
