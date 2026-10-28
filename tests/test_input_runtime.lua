-- Real native map installation/limits; the VS Code callback is controlled.
local root = assert(vim.env.RE35_TEST_ROOT or vim.env.CE_TEST_ROOT)
local messages, effects = {}, 0
local response = function()
  effects = effects + 1
  return { status = 'succeeded' }
end
package.loaded.vscode = nil
package.preload.vscode = function()
  return {
    call = function(command, options)
      assert(command == 're35.input.marker')
      assert(options.args[2].valid_source)
      return response(options.args[1], options.args[2])
    end,
    action = function(command, options) messages[#messages + 1] = { command = command, value = options.args[1], args = options.args } end,
  }
end
local input = dofile(root .. '/hosts/vscode/runtime/input.lua')
local function uuid(number) return ('%08x-0000-4000-8000-%012x'):format(number, number) end
local owner = uuid(1000)
local function dispatch(operation, fields)
  fields = fields or {}
  fields.id, fields.owner, fields.operation = uuid(#messages + 1001), owner, operation
  input.dispatch(vim.json.encode(fields))
  assert(messages[#messages].command == 're35.input.connectionReply')
  return messages[#messages].value
end
local tickets = {}
for index = 1, 64 do tickets[index] = uuid(index) end
local function owned_maps()
  local count = 0
  for _, value in ipairs(vim.api.nvim_get_keymap('n')) do
    if value.desc and value.desc:match('^RE35 input barrier ') then count = count + 1 end
  end
  return count
end
local prepared = dispatch('prepare', { tickets = tickets, keys = {} })
assert(prepared.ok, prepared.error)
assert(owned_maps() == 64)
local mapping = '<Plug>(RE35i-' .. tickets[1] .. ')'
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(mapping, true, false, true), 'mx', false)
assert(effects == 1)
assert(owned_maps() == 63)
assert(messages[#messages].command == 're35.input.markerReturned')
assert(dispatch('refill', { tickets = { uuid(99) } }).ok)
assert(owned_maps() == 64)
vim.keymap.set('n', '<F24>', '<Nop>', { desc = 'Fixture foreign physical key' })
local denied = dispatch('prepare', { tickets = { uuid(100) }, keys = { 'F24' } })
assert(not denied.ok and denied.code == 'mapping-conflict')
assert(owned_maps() == 64, 'Conflict validation must preserve prior maps')
vim.keymap.del('n', '<F24>')
local foreign = '<Plug>(RE35i-' .. tickets[2] .. ')'
vim.keymap.set('n', foreign, '<Nop>', { desc = 'Fixture foreign replacement' })
assert(dispatch('dispose').ok)
assert(owned_maps() == 0)
assert(vim.fn.maparg(foreign, 'n', false, true).desc == 'Fixture foreign replacement')
vim.keymap.del('n', foreign)
-- A reserved key without a rule in the observed mode returns to its existing
-- native mapping before subsequent markers. This is not observed completion.
local order, native_calls = {}, 0
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'first', 'second', 'third' })
vim.keymap.set('n', '<F6>', function()
  native_calls = native_calls + 1; order[#order + 1] = 'native'
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end, { desc = 'Fixture preserved native function key' })
local passthrough_ticket, following_ticket = uuid(201), uuid(202)
assert(dispatch('prepare', { tickets = { passthrough_ticket, following_ticket }, keys = { 'F6' }, override = true }).ok)
response = function(ticket)
  if ticket == passthrough_ticket then return { status = 'passthrough', token = 'F6', observed = false, admitted = true } end
  assert(ticket == following_ticket and vim.api.nvim_win_get_cursor(0)[1] == 2)
  order[#order + 1] = 'following'
  return { status = 'succeeded' }
end
local stream = '<Plug>(RE35i-' .. passthrough_ticket .. ')<Plug>(RE35i-' .. following_ticket .. ')'
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(stream, true, false, true), 'mx', false)
assert(vim.deep_equal(order, { 'native', 'following' }), 'Native fallback must remain at its original FIFO position')
assert(native_calls == 1)
assert(vim.fn.maparg('<F6>', 'n', false, true).desc == 'Fixture preserved native function key')

local refused = { 'cancelled', 'failed', 'rejected' }
for index, status in ipairs(refused) do
  local ticket = uuid(210 + index)
  assert(dispatch('prepare', { tickets = { ticket }, keys = { 'F6' }, override = true }).ok)
  response = function() return { status = status, token = 'F6' } end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Plug>(RE35i-' .. ticket .. ')', true, false, true), 'mx', false)
  assert(native_calls == 1, 'Failed or cancelled receipts must not replay the original key')
end
local invalid_ticket = uuid(220)
assert(dispatch('prepare', { tickets = { invalid_ticket }, keys = { 'F6' }, override = true }).ok)
response = function() return { status = 'passthrough', token = 'F7' } end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Plug>(RE35i-' .. invalid_ticket .. ')', true, false, true), 'mx', false)
assert(messages[#messages].command == 're35.input.markerReturned' and messages[#messages].args[2].ok == false)
assert(native_calls == 1, 'Passthrough requires an activation-owned function key')

local original_buf, other_buf = vim.api.nvim_get_current_buf(), vim.api.nvim_create_buf(false, true)
local stale_ticket = uuid(221)
assert(dispatch('prepare', { tickets = { stale_ticket }, keys = { 'F6' }, override = true }).ok)
response = function()
  vim.api.nvim_set_current_buf(other_buf)
  return { status = 'passthrough', token = 'F6' }
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Plug>(RE35i-' .. stale_ticket .. ')', true, false, true), 'mx', false)
assert(messages[#messages].command == 're35.input.markerReturned' and messages[#messages].args[2].ok == false)
assert(native_calls == 1, 'A stale source cannot receive a native passthrough key')
vim.api.nvim_set_current_buf(original_buf)
local original_win, moved_win = vim.api.nvim_get_current_win(), nil
local window_ticket = uuid(222)
assert(dispatch('prepare', { tickets = { window_ticket }, keys = { 'F6' }, override = true }).ok)
response = function()
  vim.cmd('vsplit'); moved_win = vim.api.nvim_get_current_win()
  return { status = 'passthrough', token = 'F6' }
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Plug>(RE35i-' .. window_ticket .. ')', true, false, true), 'mx', false)
assert(messages[#messages].command == 're35.input.markerReturned' and messages[#messages].args[2].ok == false)
assert(native_calls == 1, 'A changed source window cannot receive a native passthrough key')
assert(moved_win and moved_win ~= original_win)
vim.api.nvim_win_close(moved_win, true)
vim.api.nvim_set_current_win(original_win)
assert(dispatch('dispose').ok)
vim.keymap.del('n', '<F6>')
vim.api.nvim_buf_delete(other_buf, { force = true })
-- Actual native on_key callbacks. The feedkeys `t` flag supplies Neovim's
-- typed-input channel; this is not evidence of physical OS/IME acquisition.
local trace_owner, trace_serial = uuid(3000), 3000
local function trace_dispatch(operation, requested_owner)
  trace_serial = trace_serial + 1
  input.trace_dispatch(vim.json.encode({ id = uuid(trace_serial), owner = requested_owner or trace_owner, operation = operation }))
  assert(messages[#messages].command == 're35.trace.reply')
  return messages[#messages].value
end
local trace_start = assert(trace_dispatch('start'))
assert(trace_start.ok, trace_start.error)
local function observed()
  local result = {}
  for _, message in ipairs(messages) do
    local value = message.value
    if message.command == 're35.trace.observe' and value.owner == trace_owner
      and value.epoch == trace_start.result.epoch and value.kind == 'key' then
      result[#result + 1] = value.token
    end
  end
  return result
end
local function typed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'mtx', false)
  vim.wait(30, function() return false end, 5)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three' })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
typed('gg')
assert(vim.api.nvim_win_get_cursor(0)[1] == 1, 'Observation must preserve native movement')
assert(vim.deep_equal(observed(), { 'g', 'g' }), vim.inspect(observed()))
typed('V'); typed('G')
assert(vim.fn.mode(1) == 'V', 'Observation must preserve native line Visual mode')
assert(vim.deep_equal(observed(), { 'g', 'g', 'V', 'G' }), vim.inspect(observed()))
assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
typed('<Esc>')
assert(vim.fn.mode(1) == 'n')
-- Internal function-key ordering barriers never reveal UUIDs in this trace.
local private_ticket = uuid(3100)
assert(dispatch('prepare', { tickets = { private_ticket }, keys = {} }).ok)
response = function() return { status = 'succeeded' } end
typed('<Plug>(RE35i-' .. private_ticket .. ')')
for _, value in ipairs(observed()) do assert(not value:find('RE35i', 1, true) and not value:find('3100', 1, true)) end
assert(dispatch('dispose').ok)

-- The native listener reports the typed mapping lhs once, not its generated
-- expansion. Native mappings and their behavior remain unchanged.
vim.keymap.set('n', 'Q', 'gg', { desc = 'Fixture trace remap' })
local before = #observed()
typed('Q')
local mapped = observed()
assert(#mapped == before + 1 and mapped[#mapped] == 'Q', vim.inspect(mapped))
assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
vim.keymap.del('n', 'Q')

before = #observed()
typed('iPRIVATE_INSERT_TEXT<Esc>')
assert(vim.fn.mode(1) == 'n')
local inserted = observed()
assert(#inserted == before, 'Queued Normal entry key is retired when Insert begins')
typed(':let g:re35_trace_private = "PRIVATE_COMMAND_TEXT"<CR>')
for _, value in ipairs(observed()) do
  assert(not value:find('PRIVATE', 1, true), 'Insert and command-line text must not be observed')
end
assert(vim.g.re35_trace_private == 'PRIVATE_COMMAND_TEXT', 'Observation cannot alter command-line input')
local clears = 0
for _, message in ipairs(messages) do
  if message.command == 're35.trace.observe' and message.value.kind == 'clear'
    and message.value.reason == 'unsupported_mode' then clears = clears + 1 end
end
assert(clears >= 2, 'Entering Insert and command-line clears the trace')

local second_start = trace_dispatch('start')
assert(second_start.ok and second_start.result.epoch > trace_start.result.epoch)
trace_start = second_start
typed('g') -- Pending prefix is observed input, not command completion.
assert(vim.deep_equal(observed(), { 'g' }))
assert(trace_dispatch('stop', uuid(3999)).ok, 'Foreign late stop is harmless')
typed('g')
assert(vim.deep_equal(observed(), { 'g', 'g' }))
trace_start = trace_dispatch('start')
assert(trace_start.ok)
typed(string.rep('l', 100))
assert(#observed() <= 32, 'Native pending notifications have a fixed bound')
local overflow_cleared = false
for _, message in ipairs(messages) do
  if message.command == 're35.trace.observe' and message.value.epoch == trace_start.result.epoch
    and message.value.kind == 'clear' and message.value.reason == 'input_limit' then overflow_cleared = true end
end
assert(overflow_cleared, 'Dropped typeahead is explicit rather than presented as continuous input')
-- Moving away clears and stops acquisition for the original native source.
local trace_other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(trace_other)
vim.wait(30, function() return false end, 5)
local away_count = #observed()
typed('G')
assert(#observed() == away_count)
vim.api.nvim_set_current_buf(original_buf)
assert(trace_dispatch('stop').ok)
typed('G')
assert(#observed() == away_count)
vim.api.nvim_buf_delete(trace_other, { force = true })
vim.g.re35_trace_private = nil
print('RE35 input runtime native mapping and bounded input observation checks passed')
