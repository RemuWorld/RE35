local U = require('command_environment.core.util')
local Index = require('command_environment.core.index')
local A = require('command_environment.core.arguments')
local Navigation = require('command_environment.core.navigation')
local Operation = require('command_environment.core.operation')
local M, Engine, serial = { protocol_version = 1 }, {}, 0
Engine.__index = Engine
local function text(value, label)
  assert(type(value) == 'string' and value ~= '' and #value <= 1024 and not value:find('\0', 1, true), label .. ' must be nonempty text without NUL')
  return value
end
local function stamp(target)
  assert(type(target) == 'table', 'Host target is required')
  return { token = text(target.token, 'Target token'), revision = text(target.revision, 'Target revision') }
end
local function capability(command, capabilities)
  capabilities = capabilities or {}
  assert(type(capabilities) == 'table', 'Host capabilities must be a map')
  for _, name in ipairs(command.capabilities or {}) do if capabilities[name] ~= true then return false, 'Host capability unavailable: ' .. name end end
  return true
end
function M.new(index, opts)
  serial = serial + 1; opts = opts or {}
  return setmetatable({ index = index or Index.new(), scope = text(opts.scope or 'lua:' .. serial, 'Engine scope'), navigation = Navigation.new(),
    ui_epoch = 1, ui_open = true, selection_serial = 0, next_request = 0, operations = {}, order = {}, pending = {}, disposed = false }, Engine)
end
function Engine:live() assert(not self.disposed, 'Engine is disposed') end
function Engine:select(id, target, capabilities)
  self:live(); assert(self.ui_open, 'Command UI is closed')
  local command = self.index:get(id); if not command then return nil, 'Unknown command: ' .. tostring(id) end
  local available, reason = capability(command, capabilities); if not available then return nil, reason end
  local original = stamp(target)
  self.selection_serial = self.selection_serial + 1
  self.selection = { selection_id = self.scope .. ':s' .. self.selection_serial, command_id = command.id,
    generation = self.index.generation, ui_epoch = self.ui_epoch, target = original }
  self.navigation.selected_id = command.id
  return U.clone(self.selection)
end
function Engine:invoke(ticket, args, target, capabilities)
  self:live()
  local selected = self.selection
  if not self.ui_open or not selected or type(ticket) ~= 'table' or ticket.selection_id ~= selected.selection_id
    or ticket.command_id ~= selected.command_id or ticket.generation ~= selected.generation or ticket.ui_epoch ~= selected.ui_epoch
    or type(ticket.target) ~= 'table' or ticket.target.token ~= selected.target.token or ticket.target.revision ~= selected.target.revision then return nil, 'Selection is no longer active' end
  if ticket.ui_epoch ~= self.ui_epoch or ticket.generation ~= self.index.generation then return nil, 'Commands changed; select the command again' end
  local actual = stamp(target)
  if actual.token ~= selected.target.token or actual.revision ~= selected.target.revision then return nil, 'Host target changed; review the command again' end
  local command = self.index:get(ticket.command_id)
  if not command then return nil, 'Command is no longer registered' end
  local available, reason = capability(command, capabilities); if not available then return nil, reason end
  args = U.clone(args or {})
  assert(type(args) == 'table' and U.kind(args) ~= 'array' and U.kind(args) ~= 'null', 'Arguments must be an object')
  args = U.object(args)
  local names = {}
  for _, field in ipairs(command.arguments or {}) do
    names[field.name] = true
    local valid, why = A.validate(field, args[field.name], field.items)
    if not valid then return nil, why end
  end
  for key in pairs(args) do if not names[key] then return nil, 'Unknown argument: ' .. tostring(key) end end
  local key = command.id .. '\0' .. actual.token
  if self.pending[key] then return nil, 'This command is already running for the host target' end
  local active = 0; for _ in pairs(self.pending) do active = active + 1 end
  if active >= 128 then return nil, 'Too many pending host operations' end
  self.next_request = self.next_request + 1
  local id = self.scope .. ':r' .. self.next_request
  local operation = { request_id = id, command_id = command.id, generation = self.index.generation, target = actual,
    args = args, ui_epoch = self.ui_epoch, state = Operation.new(), claimed = false, key = key }
  self.operations[id], self.pending[key] = operation, id; self.order[#self.order + 1] = id
  self.selection = nil
  return { kind = 'execute', request_id = id, command_id = command.id, args = U.clone(args), target = U.clone(actual), generation = operation.generation }
end
function Engine:finish(operation, success, cancelled, result)
  -- Prepare owned result data before committing the terminal transition. A
  -- rejected graph or exhausted allocator must leave the request retryable.
  local owned_result = U.clone(result)
  local accepted, status = Operation.finish(operation.state, success, cancelled)
  if not accepted then return false, 'This request has already completed' end
  operation.result = owned_result
  if self.pending[operation.key] == operation.request_id then self.pending[operation.key] = nil end
  local finished = 0
  for _, id in ipairs(self.order) do if self.operations[id].state.status ~= 'pending' then finished = finished + 1 end end
  while finished > 100 do
    for i, id in ipairs(self.order) do
      if self.operations[id].state.status ~= 'pending' then self.operations[id] = nil; table.remove(self.order, i); finished = finished - 1; break end
    end
  end
  return true, status
end
function Engine:claim(id, target, capabilities)
  self:live(); local operation = self.operations[id]
  if not operation or operation.state.status ~= 'pending' or operation.claimed then return nil, 'Request is unavailable or already claimed' end
  local command = self.index:get(operation.command_id)
  local actual = stamp(target)
  local enabled, why
  if command then enabled, why = capability(command, capabilities) end
  if operation.state.cancel_requested then why = 'Cancelled before host execution'
  elseif not command then why = 'Command was removed before host execution'
  elseif operation.generation ~= self.index.generation then why = 'Commands changed before host execution'
  elseif not U.deep_equal(actual, operation.target) then why = 'Host target changed before execution'
  elseif enabled then why = nil end
  if why or not enabled then
    self:finish(operation, false, operation.state.cancel_requested, { message = why or 'Host capability unavailable' })
    return nil, why or 'Host capability unavailable'
  end
  operation.claimed = true
  return { request_id = id, command_id = operation.command_id, args = U.clone(operation.args), target = U.clone(operation.target) }
end
function Engine:complete(id, completion)
  self:live(); local operation = self.operations[id]
  if not operation or operation.state.status ~= 'pending' then return false, 'Request is unavailable or already completed' end
  assert(type(completion) == 'table', 'Completion must be an object')
  local status = completion.status
  if status ~= 'succeeded' and status ~= 'failed' and status ~= 'cancelled' then return false, 'Invalid completion status' end
  if not operation.claimed and not operation.state.cancel_requested then return false, 'Request has not been claimed by the host' end
  local result = U.clone(completion.result)
  return self:finish(operation, status == 'succeeded', status == 'cancelled', result)
end
function Engine:cancel(id)
  self:live(); local operation = self.operations[id]
  if not operation or operation.state.status ~= 'pending' then return nil, 'Request is unavailable or already completed' end
  local command = self.index:get(operation.command_id)
  if operation.claimed and (not command or command.cancellable ~= true) then return nil, 'Host command does not support cancellation' end
  if operation.state.cancel_requested then return nil, 'Cancellation was already requested' end
  Operation.cancel(operation.state)
  return { kind = 'cancel', request_id = id, target = U.clone(operation.target), claimed = operation.claimed }
end
function Engine:close_ui()
  self:live(); self.ui_open = false; self.ui_epoch = self.ui_epoch + 1; self.selection = nil
  return true
end
function Engine:open_ui()
  self:live(); self.ui_open = true; self.ui_epoch = self.ui_epoch + 1; self.selection = nil
  return true
end
function Engine:snapshot()
  local operations = U.array()
  for _, id in ipairs(self.order) do
    local op = self.operations[id]
    operations[#operations + 1] = { request_id = id, command_id = op.command_id, target = U.clone(op.target), args = U.clone(op.args),
      status = op.state.status, cancel_requested = op.state.cancel_requested, cancel_state = op.state.cancel_state,
      claimed = op.claimed, result = U.clone(op.result), ui_epoch = op.ui_epoch }
  end
  return { protocol_version = 1, generation = self.index.generation, ui_epoch = self.ui_epoch, ui_open = self.ui_open,
    disposed = self.disposed, navigation = Navigation.snapshot(self.navigation), selection = U.clone(self.selection), operations = operations }
end
function Engine:dispose()
  if self.disposed then return U.array() end
  self:close_ui(); self.disposed = true
  local detached = U.array()
  for _, id in ipairs(self.order) do local op = self.operations[id]; if op.state.status == 'pending' then detached[#detached + 1] = { kind = 'detach', request_id = id, claimed = op.claimed } end end
  return detached
end
return M
