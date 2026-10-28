-- One environment owns editor hooks; the retained Executor owns running jobs.
-- Candidate building and profile writes run under the same reentry boundary.
local Builder, Events = require('command_tree.environment.builder'), require('command_tree.environment.events')
local M, Lifecycle = {}, {}
Lifecycle.__index = Lifecycle

local function dispose(env)
  if env and env.compositions then pcall(env.compositions.dispose,env.compositions) end
  if env and env.extensions then pcall(env.extensions.dispose, env.extensions) end
end

function M.new(api)
  return setmetatable({ api = api }, Lifecycle)
end

function Lifecycle:current() return self.environment end
function Lifecycle:token() return self.identity end
function Lifecycle:is_current(token) return token ~= nil and token == self.identity end
function Lifecycle:prepare(opts)
  local previous=self.environment
  local seed
  if previous and previous.compositions and previous.compositions.library.path==false then
    seed=previous.compositions.library:current()
  end
  return Builder.prepare(opts,seed and seed.library)
end
function Lifecycle:admit()
  if self.changing then return false, 'Environment lifecycle is already changing: ' .. self.changing end
  if self.environment and self.environment.session.transitioning then return false, 'Session lifecycle is already changing' end
  return true
end
function Lifecycle:assert_mutable()
  local ok, err = self:admit()
  assert(ok, err)
end

function Lifecycle:with_lock(label, callback)
  if self.changing then return false, 'Environment lifecycle is already changing: ' .. self.changing end
  if self.environment and self.environment.session.transitioning then return false, 'Session lifecycle is already changing' end
  local state = self.environment and self.environment.session.active
  if state and state.workspace_mutating then return false, 'Workspace lifecycle is already changing; retry after its current hook completes' end
  self.changing = label
  local function packed(...) return { n = select('#', ...), ... } end
  local values = packed(pcall(callback))
  self.changing = nil
  if not values[1] then return false, tostring(values[2]) end
  return unpack(values, 1, values.n)
end

function Lifecycle:activate(candidate)
  local previous, identity = self.environment, self.identity
  if previous and previous.session.active and previous.session.active.workspace_mutating then
    dispose(candidate)
    return false, 'Workspace lifecycle is already changing; previous environment was kept'
  end
  local executor = previous and previous.executor or candidate.executor
  local old_registry, old_usage = executor.registry, executor.usage
  local ok, err = xpcall(function()
    if previous then
      local closed, why = previous.session:close()
      if closed == false then error('Previous session cleanup is incomplete: ' .. tostring(why), 0) end
      -- Transfer reviewed scalar Project state only; UI ownership never crosses
      -- environments. Empty recipe profiles retain their lazy service.
      if rawget(candidate.project_recipes, 'projects') and rawget(previous.project_recipes, 'projects') then
        candidate.project_recipes:inherit_state(previous.project_recipes, previous.workspaces, candidate.workspaces)
      end
    end
    candidate.executor, candidate.session.executor = executor, executor
    executor.registry, executor.usage = candidate.registry, candidate.usage
    self.environment, self.identity = candidate, {}
    Events.install(candidate, self.api, function() return self.environment end)
  end, debug.traceback)
  if ok then
    -- Old extension handlers remain usable until every host installation step
    -- succeeds. Disposing them earlier would make a failed activation permanent.
    dispose(previous)
    return true
  end

  self.environment, self.identity = previous, identity
  executor.registry, executor.usage = old_registry, old_usage
  dispose(candidate)
  local restored, restore_error = pcall(function()
    if previous and identity then
      Events.install(previous, self.api, function() return self.environment end)
    else Events.clear() end
  end)
  local message = 'Host activation failed; previous environment and retained tasks were kept: ' .. tostring(err)
  if not restored then
    -- A host which also rejects restoration must not retain candidate entry
    -- callbacks. Programmatic access to the previous environment still works.
    pcall(Events.clear)
    self.identity = nil
    message = message .. '; entry/hook restoration also failed: ' .. tostring(restore_error)
  end
  return false, message
end

function Lifecycle:disable()
  local safe, result, err = self:with_lock('disable', function()
    if self.environment then
      local closed, why = self.environment.session:close()
      if closed == false then return false, 'Session cleanup is incomplete: ' .. tostring(why) end
      dispose(self.environment)
    end
    self.identity = nil
    Events.clear()
    return true
  end)
  if not safe then return false, result end
  return result, err
end

return M
