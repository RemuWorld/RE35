-- Private owner of one admitted Neovim operation. Executor retains admission,
-- backend invocation, pending-key ownership and finished-history retention.
-- Completion, prompts, cancellation and timeout share this single lifetime;
-- no callback may release or complete a different invocation.
local K = require('command_tree.keys')
local Operation = require('command_environment.core.operation')
local M = {}

function M.new(options)
  local operation, command, ctx = options.operation, options.command, options.context
  -- Setup may replace the registry and usage while this backend is running.
  -- Retain the admitted invocation's history destination and consent handlers.
  local handlers, operation_usage, done = options.handlers, options.usage, options.done
  local release_pending, prune_history = options.release_pending, options.prune_history
  local completion_state = Operation.new()
  local persistent = command.persistent ~= false
  local timer, cancel_requested, cancel_called, completion_queued

  local function release_request(request)
    if not request or request.closed then return end
    request.closed = true
    if operation.request == request then operation.request = nil end
    local cleanup = request.cleanup
    request.cleanup = nil
    if cleanup then
      local ok, err = pcall(cleanup)
      if not ok then
        operation.cleanup_error = tostring(err)
        vim.notify("Input cleanup: " .. tostring(err), vim.log.levels.ERROR, { title = "Command Environment" })
      end
    end
  end

  local function stop_backend()
    cancel_requested = true
    Operation.cancel(completion_state)
    if cancel_called then return operation.cancel_requested and "pending" or nil end
    if not operation.cancel_hook then return end
    cancel_called = true
    local ok, accepted, err = pcall(operation.cancel_hook)
    if not ok or accepted == false then operation.cancel_error = tostring(ok and (err or "Cancellation was not accepted") or accepted) end
    if ok and accepted == "pending" then operation.cancel_requested = true end
    return ok and accepted or false
  end

  local function finish(ok, detail, stop)
    if operation.status ~= "pending" or completion_queued then return false end
    if vim.in_fast_event() then
      completion_queued = true
      vim.schedule(function() completion_queued = false; finish(ok, detail, stop) end)
      return true
    end
    if type(ok) ~= "boolean" then ok, detail = false, "Command completion must report true or false" end
    if stop then
      -- Establish the failure before invoking a cooperative hook: a hook may
      -- complete synchronously, but timeout/error must keep its own reason.
      operation.termination_reason = detail ~= nil and detail ~= "Cancelled" and detail or nil
      operation.timed_out = detail == "Command timed out"
      local stopped = stop_backend()
      if operation.status ~= "pending" then return true end
      if stopped == "pending" or command.backend == "process" and operation.cancel_hook then
        release_request(operation.request)
        return true
      end
    end
    if operation.termination_reason then
      ok = false
      if type(detail) == "table" then
        detail.message, detail.timed_out = operation.termination_reason, operation.timed_out or false
      else detail = operation.termination_reason end
    end
    local cancelled = detail == nil or detail == "Cancelled" or type(detail) == "table" and detail.cancelled == true
    local completed, status = Operation.finish(completion_state, ok, cancelled and not operation.termination_reason or false)
    if not completed then return false end
    operation.status = status
    if operation.cancel_requested then
      operation.cancel_state = type(detail) == 'table' and detail.termination_confirmed == false
        and 'unconfirmed' or 'confirmed'
    end
    operation.detail, operation.finished = detail, vim.uv.hrtime()
    operation.cancel_hook, operation.force_cancel_hook = nil, nil
    release_pending()
    if timer then timer:stop(); timer:close(); timer = nil end
    release_request(operation.request)
    if ok then
      local safe, saved, failure = pcall(operation_usage.record, operation_usage, command.id, persistent)
      if not safe or saved == false then vim.notify("Command succeeded; recent history could not be saved: " .. tostring(safe and failure or saved), vim.log.levels.WARN) end
    end
    prune_history()
    if done then
      local safe, err = pcall(done, ok, detail, operation)
      if not safe then vim.notify("Completion callback: " .. tostring(err), vim.log.levels.ERROR) end
    elseif not ok and detail and detail ~= "Cancelled" then vim.notify(tostring(detail), vim.log.levels.ERROR, { title = "Command Environment" }) end
    return true
  end

  local function request(kind, values, options, callback)
    if operation.status ~= "pending" then return false, "This operation has already finished" end
    if type(callback) ~= "function" then finish(false, "Input callback must be a function", true); return false end
    if operation.request then finish(false, "A command can request only one input at a time", true); return false end
    if not handlers or type(handlers[kind]) ~= "function" then
      finish(false, "No Command Environment " .. kind .. " handler is available", true)
      return false
    end
    local pending = { kind = kind }
    operation.request = pending
    local function accept(value, index)
      if pending.closed or operation.status ~= "pending" then return end
      if vim.in_fast_event() then vim.schedule(function() accept(value, index) end); return end
      local valid, why = K.valid(ctx), "The original buffer or window is no longer available"
      if valid and command.stable_target then valid, why = K.unchanged(ctx) end
      if not valid then finish(false, why, true); return end
      release_request(pending)
      local ok, err = pcall(K.call, ctx, function() callback(value, index) end)
      if not ok then finish(false, tostring(err), true)
      elseif value == nil then finish(false, "Cancelled", true) end
    end
    local ok, cleanup
    if kind == "select" then ok, cleanup = pcall(handlers.select, values, options or {}, accept)
    else ok, cleanup = pcall(handlers.input, options or {}, accept) end
    if not ok then finish(false, tostring(cleanup), true); return false, tostring(cleanup) end
    if type(cleanup) == "function" then
      -- A handler may accept synchronously before returning its cleanup.
      if pending.closed then
        pending.closed = false
        pending.cleanup = cleanup
        release_request(pending)
      else pending.cleanup = cleanup end
    end
    return operation.status ~= "failed", operation.detail
  end

  function operation:select(items, options, callback) return request("select", items, options, callback) end
  function operation:input(options, callback) return request("input", nil, options, callback) end
  function operation:on_cancel(callback)
    assert(type(callback) == "function", "Cancellation hook must be a function")
    assert(not self.cancel_hook or self.cancel_hook == callback, "Cancellation hook is already registered")
    self.cancel_hook = callback
    if cancel_requested then stop_backend() end
    return self
  end
  function operation:on_force_cancel(callback)
    assert(type(callback) == "function", "Force cancellation hook must be a function")
    assert(not self.force_cancel_hook or self.force_cancel_hook == callback, "Force cancellation hook is already registered")
    self.force_cancel_hook = callback
    return self
  end
  function operation:force_cancel()
    if self.status ~= "pending" or completion_queued then return false, "This operation has already finished" end
    if not self.cancel_requested then return false, "Request cancellation before forcing termination" end
    if not self.force_cancel_hook then return false, "This backend does not support safe force termination" end
    local ok, accepted, err = pcall(self.force_cancel_hook)
    if not ok or accepted == false then
      self.cancel_error = tostring(ok and (err or "Force termination was not accepted") or accepted)
      return false, self.cancel_error
    end
    self.force_requested, self.cancel_error = true, nil
    return true, err or "Force requested; waiting for backend completion"
  end
  function operation:cancel()
    if self.status ~= "pending" or completion_queued then return false, "This operation has already finished" end
    if not self.cancel_hook then return false, "This operation cannot be interrupted safely" end
    if self.cancel_requested then return true, "Cancellation already requested; waiting for backend completion" end
    self.cancel_error = nil
    local ok, accepted, err = pcall(self.cancel_hook)
    if not ok or accepted == false then
      self.cancel_error = tostring(ok and (err or "Cancellation was not accepted") or accepted)
      -- A failed stop attempt does not prove the backend has stopped.
      return false, self.cancel_error
    end
    cancel_called = true
    if accepted == "pending" then
      self.cancel_requested = true
      return true, err or "Cancellation requested; waiting for backend completion"
    end
    finish(false, "Cancelled")
    return true
  end

  local lifetime = { finish = finish }
  function lifetime:start_timeout()
    if command.timeout_ms and operation.status == "pending" then
      local started, failure = pcall(function()
        timer = assert(vim.uv.new_timer(), "Could not create timeout timer")
        timer:start(command.timeout_ms, 0, vim.schedule_wrap(function() finish(false, "Command timed out", true) end))
      end)
      if not started then finish(false, "Could not start command timeout: " .. tostring(failure), true) end
    end
  end
  return lifetime
end
return M
