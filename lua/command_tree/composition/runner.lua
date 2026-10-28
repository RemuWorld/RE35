-- Sequential host orchestration. Commands retain their own admission, effects,
-- completion and cancellation contracts; this module never invents rollback.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = {}
M.SKIP_INPUT = {} -- Distinguishes omitting an optional value from cancelling.
local Runner = {}
Runner.__index = Runner
local completed = { succeeded=true, failed=true, cancelled=true, handed_off=true }
local publish

local function copy(value)
  -- Clone first so encoding cannot accept a foreign table metatable. The JSON
  -- round trip also preserves the portable empty-array/object/null markers.
  return J.decode(J.encode(U.clone(value)))
end
local function message(value)
  return type(value) == 'string' and value or tostring(value)
end
local function cancellation(handle)
  if type(handle) == 'function' then return handle end
  if type(handle) == 'table' and type(handle.cancel) == 'function' then
    return function() return handle.cancel() end
  end
end
local function cancel_pending(entry, pending)
  if not pending or pending.cancel_called then return end
  local cancel = cancellation(pending.handle)
  if not cancel then return end
  pending.cancel_called = true
  pending.in_cancel = true
  local ok, accepted, why = pcall(cancel)
  pending.in_cancel = false
  if not ok or accepted == false then
    entry.cancelError = message(ok and (why or 'The child refused cancellation') or accepted)
    entry.message = 'Cancellation request failed: ' .. entry.cancelError
    publish(entry)
  end
  if pending.has_deferred then
    pending.has_deferred = false
    pending.complete(pending.deferred_value, pending.deferred_error)
  end
end

function M.new(deps)
  assert(type(deps) == 'table', 'Composition runner dependencies are required')
  for _, name in ipairs({ 'resolve', 'invoke' }) do
    assert(type(deps[name]) == 'function', 'Composition runner requires ' .. name)
  end
  for _, name in ipairs({ 'live', 'capture', 'input' }) do
    assert(deps[name] == nil or type(deps[name]) == 'function', 'Invalid composition dependency: ' .. name)
  end
  return setmetatable({ deps=deps, active=nil, _active=nil, _runs={}, _serial=0, _disposed=false }, Runner)
end

publish = function(entry)
  local public = entry.public
  public.id, public.status, public.cancelled = entry.id, entry.status, entry.cancelled
  public.definition, public.inputs, public.steps = copy(entry.definition), copy(entry.inputs), copy(entry.steps)
  public.message, public.cancelError = entry.message, entry.cancelError
end

function Runner:list()
  local result = U.array()
  for index = #self._runs, 1, -1 do result[#result + 1] = copy(self._runs[index].result) end
  return result
end

function Runner:retained(id)
  for _, entry in ipairs(self._runs) do
    if entry.id == id then return copy({ definition=entry.definition, inputs=entry.inputs }) end
  end
  return nil, 'The original user command is no longer retained'
end

function Runner:cancel()
  local entry = self._active
  if not entry then return false end
  entry.cancelled = true
  entry.message = entry.message or 'User command cancelled'
  publish(entry)
  local pending = entry.pending
  if pending then
    pending.cancel_requested = true
    cancel_pending(entry, pending)
    -- Input owns no command effects. A late answer cannot restart the run.
    if pending.kind == 'input' then entry.finish('cancelled', entry.message) end
  else entry.finish('cancelled', entry.message) end
  -- A pending child remains active until its explicit completion callback.
  return true
end

function Runner:dispose()
  if self._disposed then return end
  self._disposed = true
  if self._active then self._active.message = 'Composition runner disposed'; self:cancel() end
end

function Runner:run(definition, supplied, previous_id, captured_source, done)
  if self._disposed then return nil, 'Composition runner is disposed' end
  if self._active then return nil, 'A user command is already running; finish or cancel it first' end
  if done ~= nil and type(done) ~= 'function' then return nil, 'Completion must be a function' end
  local original
  if previous_id ~= nil then
    for _, retained in ipairs(self._runs) do if retained.id == previous_id then original = retained; break end end
    if not original then return nil, 'The original user command is no longer retained' end
  end
  local ok, owned_definition, owned_inputs, source = pcall(function()
    local declaration = copy(definition)
    local values = copy(supplied == nil and U.object() or supplied)
    assert(type(declaration) == 'table' and U.kind(declaration) ~= 'null', 'A validated command definition is required')
    assert(type(values) == 'table' and U.kind(values) ~= 'array' and U.kind(values) ~= 'null', 'Inputs must be an object')
    for key in pairs(values) do assert(type(key) == 'string', 'Input names must be strings') end
    U.assert_array(declaration.inputs or {}, 'Command inputs')
    local captured = captured_source
    if captured == nil and self.deps.capture then captured = self.deps.capture(copy(declaration)) end
    return declaration, values, captured
  end)
  if not ok then return nil, message(owned_definition) end
  self._serial = self._serial + 1
  local entry = { id=self._serial, definition=owned_definition, inputs=owned_inputs,
    steps=U.array(), omitted=original and copy(original.omitted) or U.object(),
    status='input', cancelled=false, public={}, source=source }
  self._active, self.active = entry, entry.public
  publish(entry)
  local function check()
    assert(not self._disposed, 'Composition runner disposed')
    assert(self._active == entry and not entry.finished and not entry.cancelled, 'User command cancelled')
    if self.deps.live then
      local live, why = self.deps.live(entry.public)
      assert(live ~= false, why or 'User command context changed')
    end
    assert(not self._disposed and self._active == entry and not entry.cancelled, 'User command cancelled')
    return true
  end
  local function finish(status, why)
    if entry.finished then return end
    entry.finished, entry.status, entry.message = true, status, why or entry.message
    local pending = entry.pending
    if pending then pending.settled = true end
    entry.pending = nil
    if self._active == entry then self._active, self.active = nil, nil end
    publish(entry)
    entry.result = copy({ id=entry.id, command=entry.definition.id, name=entry.definition.name,
      status=entry.status, message=entry.message or '', inputs=entry.inputs, steps=entry.steps, cancelError=entry.cancelError })
    entry.public.result = copy(entry.result)
    self._runs[#self._runs + 1] = entry
    if #self._runs > 20 then table.remove(self._runs, 1) end
    if done then done(copy(entry.result)) end
  end
  entry.finish = finish
  local function fail(why)
    local status = entry.cancelled and 'cancelled' or 'failed'
    local last = entry.steps[#entry.steps]
    if last and last.status == 'running' then last.status, last.message = status, message(why) end
    finish(status, entry.cancelError and ('Cancellation request failed: ' .. entry.cancelError .. '; ' .. message(why)) or message(why))
  end
  local function checked()
    local valid, why = pcall(check)
    if not valid then fail(why); return false end
    return true
  end
  local advance
  advance = function(invocations, index)
    if not checked() then return end
    if index > #invocations then finish('succeeded'); return end
    entry.status = 'running'
    local invocation = invocations[index]
    local item = { command=invocation.command, status='running' }
    entry.steps[#entry.steps + 1] = item
    local pending = { kind='child', settled=false }
    entry.pending = pending
    publish(entry)
    local prior = original and original.steps[index]
    local frame = { source=source, check=check, recipeTaskId=prior and prior.taskId }
    local function observed(outcome)
      if pending.settled or entry.finished or self._active ~= entry then return end
      if pending.in_cancel then
        if not pending.has_deferred then pending.has_deferred, pending.deferred_value=true, outcome end
        return
      end
      pending.settled, entry.pending = true, nil
      local valid, normalized = pcall(function()
        if type(outcome) ~= 'table' or not completed[outcome.status] then
          return { status='handed_off', message='Completion is owned by the external command' }
        end
        local value = { status=outcome.status, message=outcome.message, taskId=outcome.taskId }
        if value.status == 'succeeded' and outcome.completionRecorded == false then
          value.status, value.message = 'failed', outcome.completionError or value.message or 'Task completion was not recorded'
        end
        return copy(value)
      end)
      if not valid then fail(normalized); return end
      item.status, item.message = normalized.status, normalized.message
      item.taskId = normalized.taskId or item.taskId
      publish(entry)
      -- Record the actual child outcome first, including effects completed just
      -- before cancellation. Cancellation/staleness still forbids the next step.
      if not checked() then return end
      if item.status ~= 'succeeded' then finish(item.status, item.message); return end
      advance(invocations, index + 1)
    end
    pending.complete = observed
    local invoked, handle = pcall(self.deps.invoke, copy(invocation), frame, observed)
    if not invoked then
      if not pending.settled and not entry.finished then entry.pending=nil; pending.settled=true; fail(handle) end
      return
    end
    pending.handle = handle
    if not pending.settled and type(handle) == 'table' then
      local task_id = handle.taskId or handle.id
      if type(task_id) == 'number' or type(task_id) == 'string' then item.taskId = task_id end
    end
    if not pending.settled then
      publish(entry)
      if pending.cancel_requested then cancel_pending(entry, pending) end
    end
  end
  local function resolve()
    if not checked() then return end
    local resolved, calls, why = pcall(self.deps.resolve, copy(entry.definition), copy(entry.inputs))
    if not resolved then fail(calls); return end
    if not calls then fail(why or 'User command could not be resolved'); return end
    local valid, invocations = pcall(function() local value=copy(calls); U.assert_array(value, 'Resolved steps'); return value end)
    if not valid then fail(invocations); return end
    if checked() then advance(invocations, 1) end
  end
  local prompt
  prompt = function(index)
    if not checked() then return end
    local field = (entry.definition.inputs or {})[index]
    if not field then resolve(); return end
    if rawget(entry.inputs, field.name) ~= nil then entry.omitted[field.name]=nil; prompt(index + 1); return end
    if entry.omitted[field.name] and not field.required then prompt(index + 1); return end
    local pending = { kind='input', settled=false }
    entry.pending = pending
    local function answered(value, why)
      if pending.settled or entry.finished or self._active ~= entry then return end
      if pending.in_cancel then
        if not pending.has_deferred then
          pending.has_deferred, pending.deferred_value, pending.deferred_error=true, value, why
        end
        return
      end
      pending.settled, entry.pending = true, nil
      if why ~= nil then fail(why); return end
      if not checked() then return end
      if value == nil then entry.cancelled=true; finish('cancelled', 'User command cancelled'); return end
      if value == M.SKIP_INPUT then
        if field.required then fail('Required input cannot be omitted: ' .. field.name); return end
        entry.omitted[field.name] = true
      else
        local copied, input_value = pcall(copy, value)
        if not copied then fail(input_value); return end
        entry.inputs[field.name] = input_value
      end
      publish(entry)
      prompt(index + 1)
    end
    pending.complete = answered
    if not self.deps.input then answered(nil); return end
    local prompted, handle = pcall(self.deps.input, copy(field), check, answered)
    if not prompted then
      if not pending.settled and not entry.finished then entry.pending=nil; pending.settled=true; fail(handle) end
      return
    end
    pending.handle = handle
    if pending.cancel_requested then cancel_pending(entry, pending) end
  end
  prompt(1)
  return entry.public
end

function Runner:retry(id, done)
  for _, original in ipairs(self._runs) do
    if original.id == id then return self:run(original.definition, original.inputs, id, nil, done) end
  end
  return nil, 'The original user command is no longer retained'
end

return M
