local K = require("command_tree.keys")
local A = require("command_tree.arguments")
local Lifetime = require('command_tree.executor.lifetime')
local M = {}

local function prune_history(owner)
  -- Keep pending operations reachable; bound only finished history.
  local finished = 0
  for _, item in ipairs(owner.operations) do if item.status ~= "pending" then finished = finished + 1 end end
  while finished > 100 do
    for i, item in ipairs(owner.operations) do
      if item.status ~= "pending" then table.remove(owner.operations, i); finished = finished - 1; break end
    end
  end
end

function M.new(registry, usage)
  local self = { registry = registry, usage = usage, operations = {}, pending = {}, next_id = 0 }

  function self:execute(id, args, ctx, done, handlers)
    local function reject(reason)
      if done then pcall(done, false, reason)
      else vim.notify(reason, vim.log.levels.WARN, { title = "Command Environment" }) end
      return false, reason
    end
    local command = self.registry:get(id)
    if not command then return reject("Unknown command: " .. tostring(id)) end
    if args ~= nil and type(args) ~= "table" then return reject("Command arguments must be a table") end
    ctx, args = vim.deepcopy(ctx or K.context()), vim.deepcopy(args or {})
    if not K.valid(ctx) then return reject("The original buffer or window is no longer available") end
    if command.stable_target then
      local stable, why = K.unchanged(ctx)
      if not stable then return reject(why) end
    end
    local available, reason = self.registry:available(command.id, ctx)
    if not available then return reject(reason) end
    if type(command.run) ~= "function" then return reject("This command requires a Command Session") end
    for _, field in ipairs(command.arguments or {}) do
      local ok, valid, why = pcall(A.validate, field, args[field.name], ctx, args)
      if not ok then return reject(tostring(valid)) end
      if not valid then return reject(why) end
    end
    local process_target
    if handlers and handlers.process_target and type(command.process_validate_target) ~= "function" then
      return reject("Only a registered project process can use a saved task target")
    end
    if type(command.process_resolve_target) == "function" then
      local safe, valid, target
      if handlers and handlers.process_target then
        safe, valid, target = pcall(command.process_validate_target, vim.deepcopy(handlers.process_target))
        if not safe or not valid then return reject(tostring(safe and target or valid)) end
      else
        safe, target = pcall(command.process_resolve_target, ctx, args)
        if not safe then return reject(tostring(target)) end
      end
      process_target = vim.deepcopy(target)
      if type(process_target) ~= "table" or process_target.version ~= 1
        or type(process_target.file) ~= "string" or type(process_target.root) ~= "string"
        or type(process_target.cwd) ~= "string" or not vim.islist(process_target.argv) then
        return reject("Project process target must contain a file, project root, cwd and argv")
      end
      local text_fields = { process_target.file, process_target.root, process_target.cwd }
      vim.list_extend(text_fields, process_target.argv)
      for _, value in ipairs(text_fields) do
        if type(value) ~= "string" or value:find("\0", 1, true) then return reject("Project target fields must be text without NUL") end
      end
    end
    local key = command.id .. ":" .. (process_target and "target:" .. require("command_tree.project").target_key(process_target) or ctx.buf)
    if self.pending[key] then return reject("This command is already running for this buffer") end
    self.next_id = self.next_id + 1
    local operation = { id = self.next_id, command_id = command.id, name = command.name or command.id,
      provider = type(command.provider) == 'string' and command.provider or nil,
      backend = type(command.backend) == 'string' and command.backend or nil,
      ctx = ctx, args = vim.deepcopy(args), status = "pending", started = vim.uv.hrtime(), buffer = vim.api.nvim_buf_get_name(ctx.buf),
      process_revision = command.process_revision, process_target = process_target }
    for _, field in ipairs(command.arguments or {}) do if field.secret then operation.args[field.name] = "[hidden]" end end
    self.operations[#self.operations + 1], self.pending[key] = operation, operation
    local lifetime = Lifetime.new({ operation = operation, command = command, context = ctx,
      handlers = handlers, usage = self.usage, done = done,
      release_pending = function()
        if self.pending[key] == operation then self.pending[key] = nil end
      end,
      prune_history = function() prune_history(self) end })
    local finish = lifetime.finish
    local result, detail
    local ok, err = pcall(K.call, ctx, function()
      local function call() return command.run(ctx, args, finish, operation) end
      -- Form consent is scoped to this admitted invocation, after availability
      -- and argument callbacks. Those callbacks cannot borrow Apply authority.
      if handlers and type(handlers.with_submission) == 'function' then
        result, detail = handlers.with_submission(command, ctx, args, operation, call)
      else result, detail = call() end
    end)
    if not ok then finish(false, tostring(err), true)
    elseif result == false then finish(false, detail or "Command failed", true)
    else
      if type(result) == "function" then
        local registered, failure = pcall(operation.on_cancel, operation, result)
        if not registered then finish(false, tostring(failure), true) end
      end
      -- Runtime prompts make the command asynchronous even when a third-party
      -- command omitted async=true; choosing a value must not be auto-success.
      if not command.async and not operation.request then finish(true, detail) end
    end
    lifetime:start_timeout()
    if operation.status == "failed" then return false, operation.detail, operation end
    return true, operation.status, operation
  end

  function self:list()
    local result = {}
    for i = #self.operations, 1, -1 do result[#result + 1] = self.operations[i] end
    return result
  end
  function self:cancel(id)
    for _, operation in ipairs(self.operations) do if operation.id == id then return operation:cancel() end end
    return false, "Unknown operation"
  end
  function self:force_cancel(id)
    for _, operation in ipairs(self.operations) do if operation.id == id then return operation:force_cancel() end end
    return false, "Unknown operation"
  end
  return self
end
return M
