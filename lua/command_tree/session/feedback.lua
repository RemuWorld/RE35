-- Full diagnostics are bounded host-local state, never profile/draft data.
local M = {}
local owners = setmetatable({}, { __mode = 'k' })
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
function M.current(state)
  local owner = owners[state]
  if not owner then return nil end
  if owner.input ~= state.input or owner.input and (owner.index ~= owner.input.index or owner.command ~= owner.input.command) then
    owners[state] = nil
    return nil
  end
  return owner.record
end
function M.attach(self)
  function self:record_feedback(phase, error_value, command)
    local state = self.active
    if not state then return end
    local input = state.input
    command = command or input and input.command or self:selected_command()
    local full, lines, truncated = bounded(error_value)
    local summary = phase .. ': ' .. vim.fn.strcharpart(lines[1] ~= '' and lines[1] or 'Operation failed', 0, 240)
    local record = { message = summary, full_message = full, lines = lines, phase = phase,
      command_id = command and command.id, provider = command and command.provider,
      field = input and input.command.arguments[input.index] and input.command.arguments[input.index].name,
      truncated = truncated }
    owners[state] = { record = record, input = input, index = input and input.index, command = input and input.command }
    state.message = summary
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
end
return M
