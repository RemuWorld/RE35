-- One data-only intent in-process and over the native protocol.
local root = assert(vim.env.CE_TEST_ROOT)
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable modules allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local I = require('command_environment.core.invocation')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local args = { query = '한글 😀', options = { enabled = false, counts = { 1, 2 } } }
local request = assert(I.validate({ command = 'search.document', args = args }))
args.options.counts[1] = 7
check(request.args.options.counts[1] == 1, 'Validated intent owns nested data')
check(request.args.query == '한글 😀', 'Unicode is retained')
check(J.encode(assert(I.validate({ command = 'editor.action' }))) == '{"args":{},"command":"editor.action"}', 'Omitted args is an object')
local cycle = {}; cycle.self = cycle
for _, bad in ipairs({
  {}, { command = 'tree path' }, { command = 'ex.SomeCommand' }, { command = 'keymap.runtime' },
  { command = 'buffer.runtime' }, { command = 'editor.action', path = {} },
  { command = 'editor.action', args = false }, { command = 'editor.action', args = U.array() },
  { command = 'editor.action', args = { callback = function() end } },
  { command = 'editor.action', args = { value = 0/0 } }, { command = 'editor.action', args = { value = math.huge } },
  { command = 'editor.action', args = { value = string.char(255) } },
  { command = 'editor.action', args = { value = string.rep('x', I.max_bytes) } },
  { command = 'editor.action', args = cycle },
  setmetatable({ command = 'editor.action' }, { __index = function() error('Must not evaluate') end }),
}) do
  local value, why = I.validate(bad)
  check(value == nil and type(why) == 'string', 'Invalid invocation is rejected without execution')
end
local too_deep = {}; local tail = too_deep
for _ = 1, I.max_depth + 1 do tail.child = {}; tail = tail.child end
check(not I.validate({ command = 'editor.action', args = too_deep }), 'Depth is bounded')
local too_many = {}; for n = 1, I.max_items do too_many['k' .. n] = n end
check(not I.validate({ command = 'editor.action', args = too_many }), 'Work is bounded')
require('command_environment.core.bridge')
ce_bridge_init('invocation-contract')
local wire = J.decode(ce_bridge('invocation_validate', '{"invocation":{"command":"search.document","args":{"query":"한글 😀"}}}'))
check(wire.ok and wire.value.command == request.command and wire.value.args.query == request.args.query,
  'Wire and in-process contract agree')
local before = ce_bridge('snapshot', '{}')
local invalid = J.decode(ce_bridge('invocation_validate', '{"invocation":{"command":"search.document","execute":true}}'))
check(not invalid.ok, 'Wire validation rejects invented authority')
check(before == ce_bridge('snapshot', '{}'), 'Validating does not select or execute')
print('Invocation contract: ' .. checks .. ' checks')
