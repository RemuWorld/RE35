-- Versioned host extensions. Runtime callbacks remain here; Workspace hooks
-- receive copied data and opaque owner tokens, never Frames or Sessions.
local U = require('command_environment.core.util')
local K, V = require('command_tree.keys'), require('command_tree.view')
local M, Manager = {}, {}
Manager.__index = Manager
local serial = 0
local function object(value, name)
  assert(type(value) == 'table', name .. ' must be an object')
  return U.clone(value)
end
local function state(value)
  local copy = object(value or {}, 'Extension state')
  assert(#vim.json.encode(copy) <= 2097152, 'Extension state exceeds 2 MiB')
  if copy.rows then assert(vim.islist(copy.rows) and #copy.rows <= 5000, 'Extension rows exceed 5000') end
  if copy.diff then assert(type(copy.diff) == 'string' and #copy.diff <= 1048576, 'Extension diff exceeds 1 MiB') end
  return copy
end
function Manager:dispose()
  if self.disposed then return true, {} end
  self.disposed = true
  local errors = {}
  for _, entry in ipairs(self.order) do
    if not entry.disposed then
      entry.disposed = true
      for index = #entry.cleanups, 1, -1 do
        local ok, err = pcall(entry.cleanups[index])
        if not ok then
          local message = entry.id .. ': ' .. tostring(err)
          errors[#errors + 1] = message
          entry.cleanup_error = message
        end
      end
    end
  end
  self.cleanup_errors = errors
  if #errors > 0 then
    pcall(vim.notify, 'Extension cleanup: ' .. table.concat(errors, '; '), vim.log.levels.WARN, { title = 'Command Environment' })
  end
  return #errors == 0, errors
end
function Manager:list()
  local result = {}
  for _, entry in ipairs(self.order) do result[#result + 1] = { id = entry.id, api_version = 1, disposed = entry.disposed or self.disposed,
    cleanup_error = entry.cleanup_error } end
  return result
end
function Manager:register(spec)
  assert(not self.disposed, 'Extension manager is disposed')
  assert(type(spec) == 'table' and spec.api_version == 1, 'Extension requires api_version=1')
  assert(type(spec.id) == 'string' and spec.id:match('^[%a_][%w_.-]*$') and #spec.id <= 128, 'Invalid extension ID')
  assert(not self.entries[spec.id], 'Extension ID already exists: ' .. spec.id)
  assert(type(spec.build) == 'function', 'Extension build must be a function')
  local entry = { id = spec.id, cleanups = {}, commands = {}, workspaces = {} }
  self.entries[spec.id], self.order[#self.order + 1] = entry, entry
  local requests = setmetatable({}, { __mode = 'k' })
  local owners = setmetatable({}, { __mode = 'k' })
  local function current(req)
    local token = requests[req]
    if self.disposed or entry.disposed or not token or not token.owner.alive then return nil, 'Extension UI owner is gone' end
    local owner = token.owner
    if self.env.session.active ~= owner.session or self.env.workspaces:active(owner.session) ~= owner.frame
      or owner.session.mode ~= 'workspace' and not owner.session.workspace_mutating then return nil, 'Extension Workspace is no longer active' end
    if token.revision ~= owner.revision then return nil, 'Extension Workspace changed; late update discarded' end
    if not owner.session.workspace_mutating and token.navigation ~= (owner.session.navigation or 0) then
      return nil, 'Extension navigation changed; late request discarded'
    end
    if not K.valid(owner.frame.ctx) then return nil, 'Extension target is no longer available' end
    return owner, token
  end
  local function request(owner)
    local req = { owner_id = owner.id, revision = owner.revision, state = state(owner.frame.data), context = U.clone(owner.frame.ctx) }
    requests[req] = { owner = owner, revision = owner.revision,
      navigation = owner.session.navigation or 0, admitting = owner.admitting }
    return req
  end
  local function patch(owner, value)
    local next_state = state(owner.frame.data)
    for key, item in pairs(state(value)) do next_state[key] = item end
    owner.frame.data = state(next_state)
    owner.revision = owner.revision + 1
  end
  local api = { api_version = 1 }
  function api.register_command(command)
    assert(type(command) == 'table' and not command.replace, 'Extension commands cannot replace existing commands')
    entry.commands[#entry.commands + 1] = vim.deepcopy(command)
  end
  function api.on_dispose(callback)
    assert(type(callback) == 'function', 'Extension cleanup must be a function')
    entry.cleanups[#entry.cleanups + 1] = callback
  end
  function api.project_root(ctx)
    assert(type(ctx) == 'table' and K.valid(ctx), 'Project target is no longer available')
    local selected = self.env.project_recipes and self.env.project_recipes:context(ctx)
    return selected and selected.root or require('command_tree.project').root(ctx)
  end
  function api.publish(req, value)
    local owner, token = current(req)
    if not owner then return false, token end
    local ok, err = pcall(patch, owner, value)
    if not ok then return false, tostring(err) end
    token.revision, req.revision = owner.revision, owner.revision
    req.state = state(owner.frame.data)
    return true
  end
  function api.refresh(req)
    local owner, reason = current(req)
    if not owner then return false, reason end
    self.env.session:draw()
    return true
  end
  function api.execute(id, args, req, done)
    assert(done == nil or type(done) == 'function', 'Extension completion must be a function')
    local owner, reason = current(req)
    if not owner then if done then pcall(done, false, reason) end; return false, reason end
    local command = self.env.registry:get(id)
    if not command or command.extension_owner ~= entry.id then
      reason = 'Extension can execute only its owned command IDs'
      if done then pcall(done, false, reason) end
      return false, reason
    end
    local values = object(args or {}, 'Extension arguments')
    return self.env.session:run(id, values, nil, done, false, owner.frame.ctx)
  end
  local function outcome(owner, result, req)
    if result == nil then return true end
    assert(type(result) == 'table', 'Extension action must return structured data')
    result = U.clone(result)
    for key in pairs(result) do assert(key == 'state' or key == 'message' or key == 'execute', 'Unknown extension action result: ' .. tostring(key)) end
    if result.state then patch(owner, result.state) end
    if result.message then assert(type(result.message) == 'string', 'Extension message must be text'); patch(owner, { message = result.message }) end
    if result.execute then
      local next_req = request(owner)
      return api.execute(result.execute.id, result.execute.args, next_req)
    end
    return true
  end
  function api.register_workspace(workspace)
    assert(type(workspace) == 'table' and type(workspace.render) == 'function', 'Extension Workspace needs render(req)')
    assert(not workspace.replace, 'Extension Workspace cannot replace an existing Workspace')
    for _, hook in ipairs({ 'enter', 'resume', 'suspend', 'leave' }) do assert(workspace[hook] == nil or type(workspace[hook]) == 'function', 'Invalid extension ' .. hook) end
    local initial = state(workspace.initial_state or {})
    local wrapped = {}
    for _, key in ipairs({ 'id', 'name', 'icon', 'order', 'color', 'path', 'bindings', 'state_fields', 'state_scope', 'hidden' }) do wrapped[key] = U.clone(workspace[key]) end
    wrapped.actions = {}
    for id, action in pairs(workspace.actions or {}) do
      assert(type(action) == 'table' and type(action.run) == 'function', 'Extension actions need run(req)')
      local callback = action.run
      wrapped.actions[id] = { label = action.label, hidden = action.hidden, control = action.control,
        run = function(frame)
          local owner = assert(owners[frame], 'Extension Workspace has no owner')
          owner.revision = owner.revision + 1
          local req = request(owner)
          return outcome(owner, callback(req), req)
        end }
    end
    wrapped.enter = function(frame, _, session)
      assert(not self.disposed and not entry.disposed, 'Extension was disposed; configure it again before opening')
      serial = serial + 1
      frame.data = state(vim.tbl_extend('force', {}, initial, frame.data))
      local owner = { id = entry.id .. ':' .. serial, revision = 1, frame = frame, session = session, alive = true, admitting = true }
      owners[frame] = owner
      local req = request(owner)
      if workspace.enter then outcome(owner, workspace.enter(req), req) end
    end
    wrapped.resume = function(frame)
      local owner = assert(owners[frame], 'Extension Workspace has no owner')
      owner.admitting = true
      owner.revision = owner.revision + 1
      if workspace.resume then local req = request(owner); outcome(owner, workspace.resume(req), req) end
    end
    wrapped.suspend = function(frame)
      local owner = owners[frame]
      if owner then owner.revision = owner.revision + 1; if workspace.suspend then workspace.suspend(request(owner)) end end
    end
    wrapped.leave = function(frame)
      local owner = owners[frame]
      if owner then
        owner.alive = false
        owner.revision = owner.revision + 1
        if workspace.leave then workspace.leave(request(owner)) end
      end
    end
    wrapped._extension_ready = function(frame)
      local owner = owners[frame]
      if not owner or not owner.admitting then return end
      owner.admitting = false
      for _, token in pairs(requests) do
        if token.owner == owner and token.admitting then
          token.navigation, token.admitting = owner.session.navigation or 0, false
        end
      end
    end
    wrapped.draw = function(frame, _, _, opts)
      local owner = assert(owners[frame], 'Extension Workspace has no owner')
      local model = object(workspace.render(request(owner)), 'Extension render model')
      assert(not model.items or vim.islist(model.items) and #model.items <= 5000, 'Extension render items exceed 5000')
      assert(not model.content or vim.islist(model.content) and #model.content <= 5000, 'Extension render content exceeds 5000')
      model.title = opts.title
      model.help = opts.help
      V.draw(frame.view, model, vim.tbl_extend('force', opts.window, { accent = opts.accent, density = opts.density }))
    end
    entry.workspaces[#entry.workspaces + 1] = wrapped
  end
  local ok, err = xpcall(function()
    spec.build(api)
    local function availability(original)
      return function(ctx)
        if self.disposed or entry.disposed then return false, 'Extension was disposed; configure it again before running' end
        if type(original) == 'function' then return original(ctx) end
        if original == false then return false, 'Extension command is unavailable' end
        return true
      end
    end
    for _, command in ipairs(entry.commands) do
      command.extension_owner = entry.id
      command.available = availability(command.available)
      self.env.registry:register(command)
    end
    for _, workspace in ipairs(entry.workspaces) do
      self.env.workspaces:register(workspace)
      self.env.registry:register({ id = 'workspace.' .. workspace.id, name = workspace.name or workspace.id,
        type = 'workspace', workspace = workspace.id, extension_owner = entry.id, available = availability() })
    end
  end, debug.traceback)
  if not ok then self:dispose(); error(err, 0) end
  return entry.id
end
function M.new(env) return setmetatable({ env = env, entries = {}, order = {}, disposed = false }, Manager) end
return M
