-- Full diagnostics are bounded host-local state, never profile/draft data.
local M = {}
local owners = setmetatable({}, { __mode = 'k' })
local notices = setmetatable({}, { __mode = 'k' })
local MAX_BYTES, MAX_LINES = 16384, 256
local function bounded(value)
  local ok, text = pcall(tostring, value)
  local message = (ok and text or 'Unable to display diagnostic'):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('%z', '')
  local truncated = #message > MAX_BYTES
  if truncated then
    message = message:sub(1, MAX_BYTES)
    -- Keep a partial UTF-8 codepoint out of the display boundary.
    local start = #message
    while start > 0 and message:byte(start) >= 128 and message:byte(start) < 192 do start = start - 1 end
    if start > 0 and message:byte(start) >= 192 then message = message:sub(1, start - 1) end
  end
  local lines = {}
  for line in (message .. '\n'):gmatch('(.-)\n') do
    if #lines == MAX_LINES then truncated = true; break end
    lines[#lines + 1] = line
  end
  if truncated then lines[#lines + 1] = '[Additional diagnostic text omitted: display limit reached]' end
  return table.concat(lines, '\n'), lines, truncated
end
local function error_summary(lines)
  for _, line in ipairs(lines) do
    local message = line:match('^%s*(.-)%s*$')
    for _ = 1, 16 do
      local inner = message:match('^Error executing lua:%s*(.*)$')
      if inner then message = inner
      else
        local source, rest = message:match('^(.-%.lua):%d+:%s*(.*)$')
        -- Only recognize a Lua source location. A colon elsewhere in prose
        -- (or in an arbitrary command/error prefix) is not a wrapper to strip.
        local file = source and (not source:find(':', 1, true)
          or source:match('^%a:[/\\]') and not source:sub(3):find(':', 1, true))
        if not file then break end
        message = rest
      end
    end
    if message ~= '' and message ~= 'stack traceback:' then return vim.fn.strcharpart(message, 0, 240) end
  end
  return 'Operation failed'
end
function M.current(state)
  local owner = owners[state]
  if not owner then return nil end
  if owner.input ~= state.input or owner.input and (owner.index ~= owner.input.index or owner.command ~= owner.input.command) then
    if state.message == owner.record.message then state.message = nil end
    owners[state] = nil
    return nil
  end
  return owner.record
end
-- Expected provider conditions retain their explanation for Inspect without
-- presenting technical details as a traceback while the user browses a form.
function M.display(state)
  local record = M.current(state)
  if not record or record.kind ~= 'condition' then return record end
  local compact = vim.tbl_extend('force', {}, record)
  compact.full_message, compact.lines = record.message, { record.message }
  return compact
end
function M.notice(state)
  local notice = notices[state]
  if notice and notice.message == state.message then return notice end
  if state then notices[state] = nil end
end
function M.attach(self)
  function self:set_notice(message, summary)
    local state = self.active
    if not state then return end
    local _, lines = bounded(message)
    state.message = vim.fn.strcharpart(lines[1] or '', 0, 240)
    notices[state] = { message = state.message, summary = vim.fn.strcharpart(summary or state.message, 0, 80) }
  end
  function self:record_feedback(phase, error_value, command)
    local state = self.active
    if not state then return end
    notices[state] = nil
    local input = state.input
    command = command or input and input.command or self:selected_command()
    local full, lines, truncated = bounded(error_value)
    local summary = phase .. ': ' .. error_summary(lines)
    local record = { kind = 'error', severity = 'error', message = summary, full_message = full, lines = lines, phase = phase,
      command_id = command and command.id, provider = command and command.provider,
      field = input and input.command.arguments[input.index] and input.command.arguments[input.index].name,
      truncated = truncated }
    owners[state] = { record = record, input = input, index = input and input.index, command = input and input.command }
    state.message = summary
    return record
  end
  function self:record_condition(phase, condition, command)
    if type(condition) ~= 'table' or condition.kind ~= 'condition'
      or type(condition.message) ~= 'string' or condition.message == '' then
      return self:record_feedback(phase, 'Invalid condition; expected a condition with a message', command)
    end
    local state = self.active
    if not state then return end
    notices[state] = nil
    local input = state.input
    command = command or input and input.command or self:selected_command()
    local _, message_lines = bounded(condition.message)
    local message = vim.fn.strcharpart(message_lines[1] ~= '' and message_lines[1] or 'Action needs attention', 0, 240)
    local detail = type(condition.details) == 'string' and condition.details or ''
    local full, lines, truncated = bounded(condition.message .. (detail ~= '' and detail ~= condition.message and '\n\n' .. detail or ''))
    local record = { kind = 'condition', severity = condition.severity == 'info' and 'info' or 'warning',
      code = type(condition.code) == 'string' and vim.fn.strcharpart(condition.code:gsub('[\r\n\t%z]', ' '), 0, 80) or nil,
      message = phase .. ': ' .. message, full_message = full, lines = lines, phase = phase,
      command_id = command and command.id, provider = command and command.provider,
      field = input and input.command.arguments[input.index] and input.command.arguments[input.index].name,
      truncated = truncated }
    owners[state] = { record = record, input = input, index = input and input.index, command = input and input.command }
    state.message = record.message
    return record
  end
  function self:clear_feedback(phase)
    local state = self.active
    local record = state and M.current(state)
    if record and (phase == nil or record.phase == phase) then
      if state.message == record.message then state.message = nil end
      owners[state] = nil
    end
  end
  function self:inspect_feedback()
    local state = self.active
    local record = state and M.current(state)
    if not record then return false end
    local navigation = state.navigation
    self:push_mode('feedback', { feedback_inspection = record, feedback_offset = 1 })
    -- Inspecting does not authorize execution or navigate away from an async form.
    state.navigation = navigation
    return true
  end
  function self:inspect_input_status()
    local state, input = self.active, self.active and self.active.input
    if not input or input.callback or input.retired or state.mode ~= 'input' then return false end
    local command = input.command
    local inspect = command.input_ui and command.input_ui.inspect
    if type(inspect) ~= 'function' then return false end
    local K, Input = require('command_tree.keys'), require('command_tree.session.input')
    local ctx, attachment, index = Input.context(state), state.input_attachment, input.index
    local field = command.arguments[index]
    local function current()
      return self:is_attached(state, attachment) and state.mode == 'input' and state.input == input
        and not input.retired and not input.callback and input.index == index and command.arguments[index] == field
        and self.registry:get(command.id) == command and Input.context(state) == ctx and K.valid(ctx)
    end
    if not field or not current() then return true end
    local args = vim.deepcopy(input.args)
    args[field.name] = vim.deepcopy(Input.value(input))
    local ok, result = pcall(vim.api.nvim_win_call, ctx.win, function()
      return inspect(vim.deepcopy(ctx), args)
    end)
    -- A provider can synchronously replace the Session, command or field. Its
    -- reply owns no new UI and cannot create feedback for that replacement.
    if not current() then return true end
    if not ok then self:record_feedback('Input details', result, command)
    elseif result == nil then return false
    else self:record_condition('Input details', result, command) end
    self:inspect_feedback()
    return true
  end
end
return M
