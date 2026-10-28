-- Structured native authoring uses the existing operation-owned input surface.
-- It edits data only; running is a separate, explicit terminal action.
local U = require('command_environment.core.util')
local Arguments = require('command_environment.core.arguments')
local M, UI = {}, {}; UI.__index = UI
local function row(label, action, value) return { label = label, action = action, value = value } end
local back = row('Back', 'back')
local function need(value, why) assert(value, why); return value end

function M.new(options)
  assert(options and options.library and type(options.catalog) == 'function', 'Composition UI requires a library and catalog')
  return setmetatable(options, UI)
end
-- A coroutine is local to one form. Existing operation lifetime owns every
-- pending callback, cancellation and cleanup; no independent UI session exists.
function UI:_start(ctx, operation, done, body)
  local finished, thread
  local function finish(ok, detail)
    if finished then return end
    finished = true; if done then done(ok, detail) end
  end
  local function resume(...)
    if finished then return end
    local ok, reason = coroutine.resume(thread, ...)
    if not ok then finish(false, tostring(reason)) end
  end
  local state = { ui = self, ctx = ctx, operation = operation, finish = finish }
  function state:check()
    if self.ui.live then local ok, why = self.ui.live(); assert(ok ~= false, why or 'Command authoring owner ended') end
    if self.token then need(self.ui.library:guard(self.token)) end
  end
  function state:ask(kind, values, options)
    self:check()
    local answered, response, waiting = false, nil, false
    local function accept(value)
      if finished then return end
      if waiting then resume(value) else answered, response = true, value end
    end
    local accepted, why
    if kind == 'select' then
      options.format_item = function(item) return item.label end
      accepted, why = operation:select(values, options, accept)
    else accepted, why = operation:input(options, accept) end
    assert(accepted ~= false, why or 'Input request was refused')
    if not answered then waiting = true; response = coroutine.yield() end
    self:check()
    if response == nil then error('Cancelled', 0) end
    return response
  end
  function state:pick(items, prompt)
    return self:ask('select', items, { prompt = prompt, title = 'RE35 User Commands' })
  end
  function state:input(prompt, value)
    return self:ask('input', nil, { prompt = prompt, default = value or '' })
  end
  function state:refresh() self.token = need(self.ui.library:current()) end
  function state:save(candidate)
    self.token = need(self.ui.library:save(candidate, self.token.revision))
  end
  function state:error(reason)
    self:pick({ row(tostring(reason), 'error'), back }, 'No changes saved')
  end
  thread = coroutine.create(function()
    state.token = need(self.library:load()); state.catalog = self.catalog(); state:check()
    body(state)
  end)
  resume()
  return true
end
local function support(state, definition)
  local ids, missing = {}, {}
  for _, command in ipairs(state.catalog) do ids[command.id] = true end
  for _, step in ipairs(definition.steps) do if not ids[step.command] then missing[#missing + 1] = step.command end end
  return #missing == 0 and '' or ' · Unavailable here: ' .. table.concat(missing, ', ')
end
local function review(state, candidate, apply)
  local rows = { row('Save declarations only; no commands run', 'save'), back }
  for _, command in ipairs(candidate.commands) do rows[#rows + 1] = row(command.id .. ' · ' .. command.name, 'inspect') end
  while true do
    local choice = state:pick(rows, 'Replace library with ' .. #candidate.commands .. ' command(s)?')
    if choice.action == 'back' then return false end
    if choice.action == 'save' then apply(); return true end
  end
end
local function choices(state, old)
  local values = U.clone(old or U.array())
  while true do
    local rows = { row('Add choice', 'add'), row('Use these choices', 'done'), back }
    for index, value in ipairs(values) do rows[#rows + 1] = row('Remove: ' .. value, 'remove', index) end
    local selected = state:pick(rows, 'Input choices · ' .. #values .. '/64')
    if selected.action == 'back' then return nil end
    if selected.action == 'done' then assert(#values > 0, 'At least one choice is required'); return values end
    if selected.action == 'remove' then table.remove(values, selected.value)
    else
      assert(#values < 64, 'An input supports at most 64 choices')
      local value = state:input('Choice value')
      assert(#value <= 4096 and not Arguments.contains(values, value), 'Use a distinct choice of at most 4096 bytes')
      values[#values + 1] = value
    end
  end
end
local function edit_input(state, draft, index)
  local original = index and draft.inputs[index]
  local name = state:input('Input name · letters, digits, underscore', original and original.name)
  assert(#name <= 64 and name:match('^[A-Za-z_][A-Za-z0-9_]*$'), 'Choose an identifier of at most 64 bytes')
  for at, input in ipairs(draft.inputs) do assert(at == index or input.name ~= name, 'Input name already exists') end
  local kind = state:pick({ row('Text', 'text'), row('Choice', 'select'), back }, 'Input type')
  if kind.action == 'back' then return end
  local required = state:pick({ row('Required', 'required'), row('Optional', 'optional'), back }, 'Input requirement')
  if required.action == 'back' then return end
  local result = { name = name, type = kind.action, required = required.action == 'required' }
  if result.type == 'select' then result.choices = choices(state, original and original.choices); if not result.choices then return end end
  if index then
    draft.inputs[index] = result
    for _, step in ipairs(draft.steps) do for _, binding in pairs(step.args) do
      if binding.input == original.name then binding.input = name end
    end end
  else assert(#draft.inputs < 16, 'A command supports at most 16 inputs'); draft.inputs[#draft.inputs + 1] = result end
end
local function inputs(state, draft)
  while true do
    local rows = { row('Add input', 'add'), back }
    for index, input in ipairs(draft.inputs) do rows[#rows + 1] = row(input.name .. ' · ' .. input.type, 'input', index) end
    local chosen = state:pick(rows, 'Reusable inputs · ' .. #draft.inputs .. '/16')
    if chosen.action == 'back' then return end
    if chosen.action == 'add' then edit_input(state, draft)
    else
      local action = state:pick({ row('Edit input', 'edit'), row('Delete input', 'delete'), back }, draft.inputs[chosen.value].name)
      if action.action == 'edit' then edit_input(state, draft, chosen.value)
      elseif action.action == 'delete' then
        local name = draft.inputs[chosen.value].name
        for _, step in ipairs(draft.steps) do for _, binding in pairs(step.args) do
          assert(binding.input ~= name, 'Input is still bound to a step; change its binding before deleting it')
        end end
        table.remove(draft.inputs, chosen.value)
      end
    end
  end
end
local function literal(state, field, previous)
  if field.kind == 'select' or field.kind == 'boolean' then
    local rows = { back }
    local values = field.kind == 'boolean' and { true, false } or field.items or {}
    for _, value in ipairs(values) do rows[#rows + 1] = row(Arguments.label(value), 'value', Arguments.value(value)) end
    local choice = state:pick(rows, 'Literal: ' .. field.name)
    return choice.action ~= 'back' and { value = choice.value } or nil
  end
  local value = state:input('Literal: ' .. field.name, previous and previous.value ~= nil and tostring(previous.value) or '')
  if field.kind == 'number' then local reason; value, reason = Arguments.coerce(field, value); assert(value, reason) end
  local valid, why = Arguments.validate(field, value, field.items); assert(valid, why)
  return { value = value }
end
local function configure_step(state, draft, previous)
  local rows = { back }
  for _, command in ipairs(state.catalog) do rows[#rows + 1] = row(command.name .. ' · ' .. command.id, 'command', command) end
  local choice = state:pick(rows, 'Choose a supported command')
  if choice.action == 'back' then return end
  local command, result = choice.value, { command = choice.value.id, args = U.object() }
  for _, field in ipairs(command.arguments or {}) do
    local bindings = { row('Literal value', 'literal'), back }
    for _, input in ipairs(draft.inputs) do bindings[#bindings + 1] = row('Input: ' .. input.name, 'input', input.name) end
    if not field.required then bindings[#bindings + 1] = row('Do not supply', 'omit') end
    local selected = state:pick(bindings, 'Bind: ' .. field.name .. (field.required and ' · required' or ' · optional'))
    if selected.action == 'back' then return end
    if selected.action == 'input' then result.args[field.name] = { input = selected.value }
    elseif selected.action == 'literal' then
      local old = previous and previous.command == command.id and previous.args[field.name]
      local value = literal(state, field, old); if not value then return end
      result.args[field.name] = value
    end
  end
  return result
end
local function steps(state, draft)
  while true do
    local rows = { row('Add step', 'add'), back }
    for index, step in ipairs(draft.steps) do rows[#rows + 1] = row(index .. '. ' .. step.command, 'step', index) end
    local selected = state:pick(rows, 'Ordered steps · ' .. #draft.steps .. '/16')
    if selected.action == 'back' then return end
    if selected.action == 'add' then
      assert(#draft.steps < 16, 'A command supports at most 16 steps')
      local step = configure_step(state, draft); if step then draft.steps[#draft.steps + 1] = step end
    else
      local index = selected.value
      local actions = { row('Edit step', 'edit'), row('Delete step', 'delete'), back }
      if index > 1 then actions[#actions + 1] = row('Move earlier', 'up') end
      if index < #draft.steps then actions[#actions + 1] = row('Move later', 'down') end
      local action = state:pick(actions, 'Step ' .. index)
      if action.action == 'edit' then local value = configure_step(state, draft, draft.steps[index]); if value then draft.steps[index] = value end
      elseif action.action == 'delete' then table.remove(draft.steps, index)
      elseif action.action == 'up' or action.action == 'down' then
        local to = index + (action.action == 'up' and -1 or 1)
        draft.steps[index], draft.steps[to] = draft.steps[to], draft.steps[index]
      end
    end
  end
end
local function edit(state, original)
  local draft = original and U.clone(original)
  if not draft then
    assert(#state.token.library.commands < 64, 'The library supports at most 64 commands')
    local name = state:input('Command name')
    local id = state:input('Stable command ID · user.name', 'user.')
    draft = { id = id, name = name, inputs = U.array(), steps = U.array() }
  end
  while true do
    local choice = state:pick({ row('Steps', 'steps'), row('Inputs', 'inputs'), row('Rename', 'rename'),
      row('Review and save', 'save'), row('Discard changes', 'back') }, draft.id .. ' · unsaved draft')
    if choice.action == 'back' then return end
    local ok, why = pcall(function()
      if choice.action == 'steps' then steps(state, draft)
      elseif choice.action == 'inputs' then inputs(state, draft)
      elseif choice.action == 'rename' then draft.name = state:input('Command name', draft.name)
      elseif choice.action == 'save' then
        local candidate, replaced = U.clone(state.token.library), false
        for index, command in ipairs(candidate.commands) do
          if command.id == (original and original.id or draft.id) then
            assert(original, 'Command ID already exists'); candidate.commands[index], replaced = U.clone(draft), true
          end
        end
        if not replaced then candidate.commands[#candidate.commands + 1] = U.clone(draft) end
        local valid, reason = require('command_tree.composition.library').validate(candidate); assert(valid, reason)
        if review(state, candidate, function() state:save(candidate) end) then return true end
      end
    end)
    if not ok then if tostring(why) == 'Cancelled' then error(why, 0) end; state:error(why)
    elseif choice.action == 'save' and state.token.library.commands then
      for _, saved in ipairs(state.token.library.commands) do if U.deep_equal(saved, draft) then return end end
    end
  end
end
local function run(state, definition)
  assert(type(state.ui.run) == 'function', 'Command execution is unavailable')
  local values, omitted = U.object(), {}
  for _, input in ipairs(definition.inputs) do
    if input.type == 'select' then
      local rows = {}; if not input.required then rows[#rows + 1] = row('Leave absent', 'omit') end
      for _, value in ipairs(input.choices) do rows[#rows + 1] = row(value, 'value', value) end
      local selected = state:pick(rows, input.name)
      if selected.action ~= 'omit' then values[input.name] = selected.value else omitted[input.name] = true end
    else
      local supply = input.required or state:pick({row('Supply '..input.name,'supply'),row('Leave absent','omit')},input.name).action=='supply'
      if supply then
        local value = state:input(input.name .. (input.required and ' · required' or ' · optional; empty is explicit'))
        assert(not input.required or value ~= '', input.name .. ' is required')
        values[input.name] = value
      else omitted[input.name] = true end
    end
  end
  state:check()
  -- Host-local absence metadata prevents execution from asking a second time.
  -- It is not part of the exported definition or scalar input object.
  state.ui.run(U.clone(definition), values, state.ctx, state.finish, omitted)
end
function UI:run_picker(ctx, operation, done)
  return self:_start(ctx, operation, done, function(state)
    local rows = {}
    for _, definition in ipairs(state.token.library.commands) do
      rows[#rows + 1] = row(definition.name .. ' · ' .. definition.id .. support(state, definition), 'run', definition)
    end
    assert(#rows > 0, 'No user commands yet; open Manage user commands to create one')
    run(state, state:pick(rows, 'Run saved user command').value)
  end)
end
function UI:manage(ctx, operation, done)
  return self:_start(ctx, operation, done, function(state)
    while true do
      local rows = { row('Create user command', 'create'), row('Import user commands', 'import'), row('Export user commands', 'export'), row('Close', 'back') }
      for _, definition in ipairs(state.token.library.commands) do
        rows[#rows + 1] = row(definition.name .. ' · ' .. definition.id .. support(state, definition), 'command', definition)
      end
      local choice = state:pick(rows, state.token.notice or 'Create, edit and share declarations; saving never runs them')
      if choice.action == 'back' then state.finish(true, 'User commands closed'); return end
      local launch = false
      local ok, why = pcall(function()
        if choice.action == 'create' then edit(state)
        elseif choice.action == 'import' then
          local receipt = need(state.ui.library:read(state:input('Import local .json path')))
          review(state, receipt.library, function() need(state.ui.library:apply_import(receipt)); state:refresh() end)
        elseif choice.action == 'export' then
          local path = state:input('Export to a new local .json path')
          need(state.ui.library:export(path, state.token.revision))
        else
          local action = state:pick({ row('Run command', 'run'), row('Edit command', 'edit'), row('Delete command', 'delete'), back }, choice.value.id)
          if action.action == 'run' then launch = true; run(state, choice.value)
          elseif action.action == 'edit' then edit(state, choice.value)
          elseif action.action == 'delete' then
            local candidate = U.clone(state.token.library)
            for index, definition in ipairs(candidate.commands) do if definition.id == choice.value.id then table.remove(candidate.commands, index); break end end
            review(state, candidate, function() state:save(candidate) end)
          end
        end
      end)
      if not ok then if tostring(why) == 'Cancelled' then error(why, 0) end; state:error(why) end
      if launch then return end
    end
  end)
end
return M
