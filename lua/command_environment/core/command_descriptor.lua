-- Shared argument structure and discovery data. No host callbacks are invoked.
-- Protocol 1 is a restricted transport profile, not a limit on native hosts.
local U = require('command_environment.core.util')
local M = {}
local kinds = { text=true, path=true, number=true, boolean=true, select=true, multiselect=true }
local wire_fields = { name=true, kind=true, prompt=true, required=true, integer=true, min=true, max=true, items=true }
local wire_commands = { id=true, name=true, description=true, type=true, provider=true, source=true, aliases=true,
  path=true, arguments=true, capabilities=true, cancellable=true, icon=true }

-- Native registration historically accepts dense tables without requiring the
-- portable JSON marker. Preserve that boundary; wire arrays use U.assert_array.
local function host_array(value, label)
  assert(type(value) == 'table', label .. ' must be an array')
  local count = 0
  for key in pairs(value) do
    assert(type(key) == 'number' and key >= 1 and key % 1 == 0, label .. ' must be an array')
    count = count + 1
  end
  for index = 1, count do assert(value[index] ~= nil, label .. ' cannot contain gaps') end
end

local function wire_choices(items)
  U.assert_array(items, 'Static choices')
  assert(#items <= 4096, 'Static choices exceed 4096')
  for _, item in ipairs(items) do
    if type(item) == 'table' then
      assert(U.kind(item) ~= 'array' and U.kind(item) ~= 'null', 'Choice must be a value or labeled object')
      for key in pairs(item) do assert(key == 'label' or key == 'value', 'Unknown choice field') end
      assert(item.label == nil or type(item.label) == 'string', 'Choice label must be text')
      item = item.value
    end
    assert(type(item) == 'string' or type(item) == 'boolean' or type(item) == 'number', 'Choice values must be scalar')
  end
end

function M.validate_arguments(fields, profile)
  profile = profile or 'host'
  assert(profile == 'host' or profile == 'protocol1', 'Unknown command descriptor profile')
  if fields == nil then return nil end
  local wire = profile == 'protocol1'
  if wire then
    U.assert_array(fields, 'Command arguments')
    assert(#fields <= 64, 'Command arguments exceed 64 fields')
  else host_array(fields, 'Command arguments') end
  local names = {}
  for _, field in ipairs(fields) do
    assert(type(field) == 'table', wire and 'Argument must be an object' or 'Argument must be a field specification')
    if wire then
      assert(U.kind(field) ~= 'array' and U.kind(field) ~= 'null', 'Argument must be an object')
      for key in pairs(field) do assert(wire_fields[key], 'Unknown argument field: ' .. tostring(key)) end
    end
    assert(type(field.name) == 'string' and field.name ~= '', wire and 'Invalid argument name' or 'Argument name must be a nonempty string')
    if wire then assert(#field.name <= 64 and not field.name:find('\0', 1, true), 'Invalid argument name') end
    assert(not names[field.name], 'Duplicate argument name: ' .. field.name)
    names[field.name] = true
    assert(field.kind == nil or kinds[field.kind], 'Unknown argument kind')
    for _, flag in ipairs({ 'required', 'integer', 'secret', 'history' }) do
      assert(field[flag] == nil or type(field[flag]) == 'boolean', 'Argument ' .. flag .. ' must be a boolean')
    end
    for _, bound in ipairs({ 'min', 'max' }) do
      local value = field[bound]
      assert(value == nil or (type(value) == 'number' and value == value and math.abs(value) < math.huge),
        'Argument ' .. bound .. ' must be a finite number')
    end
    assert(not field.min or not field.max or field.min <= field.max, 'Argument min must not exceed max')
    if wire then
      assert(field.prompt == nil or type(field.prompt) == 'string', 'Argument prompt must be text')
      if field.items then wire_choices(field.items) end
    else
      assert(field.validate == nil or type(field.validate) == 'function', 'Argument validate must be a function')
      assert(field.items == nil or type(field.items) == 'table' or type(field.items) == 'function', 'Argument items must be a table or function')
      assert(field.completion == nil or type(field.completion) == 'string' or type(field.completion) == 'function',
        'Argument completion must be a string or function')
    end
  end
  return fields
end

-- The wire allowlists and quotas stay here, separate from shared structure.
-- Index still validates identity, aliases, placement and data ownership.
function M.protocol(spec)
  assert(type(spec) == 'table' and U.kind(spec) ~= 'array', 'Command descriptor must be an object')
  for key in pairs(spec) do assert(wire_commands[key], 'Unknown command descriptor field: ' .. tostring(key)) end
  if spec.capabilities then
    U.assert_array(spec.capabilities, 'Capabilities')
    for _, name in ipairs(spec.capabilities) do assert(type(name) == 'string' and name ~= '', 'Capability must be nonempty text') end
  end
  assert(spec.cancellable == nil or type(spec.cancellable) == 'boolean', 'cancellable must be a boolean')
  if spec.arguments then M.validate_arguments(spec.arguments, 'protocol1') end
  return spec
end

local function optional_data(value)
  -- Host values may include functions, cycles or foreign objects. They remain
  -- host-owned; adding discovery metadata must not reject a formerly valid host.
  local kind = type(value)
  if kind == 'string' or kind == 'boolean' then return value, true end
  if kind == 'number' then return value, value == value and math.abs(value) < math.huge end
  if kind ~= 'table' then return nil, false end
  local ok, copied = pcall(U.clone, value)
  if ok then return copied, true end
  return nil, false
end

function M.project_arguments(fields, omit_values)
  if fields == nil then return nil end
  local result = U.array()
  for _, field in ipairs(fields) do
    local projected, host_fields = {}, U.array()
    local inherited = getmetatable(field) ~= nil and U.kind(field) == nil
    for _, key in ipairs({ 'name', 'kind', 'prompt', 'description', 'required', 'integer', 'secret', 'history', 'min', 'max',
      'default', 'items', 'completion', 'validate' }) do
      -- A host descriptor can inherit fields through __index. Discovery must
      -- not run that code, including to discover an inherited privacy flag.
      local value = rawget(field, key)
      if value ~= nil then
        local value_field = key == 'default' or key == 'items'
        local hidden = value_field and (rawget(field, 'secret') == true or inherited or omit_values)
          or key == 'completion' or key == 'validate'
          or (key == 'prompt' or key == 'description') and type(value) ~= 'string'
        local copied, safe
        if not hidden and (key ~= 'items' or U.islist(value)) then copied, safe = optional_data(value) end
        if safe then projected[key] = copied else host_fields[#host_fields + 1] = key end
      elseif inherited then
        host_fields[#host_fields + 1] = key
      end
    end
    if #host_fields > 0 then projected.host_fields = host_fields end
    result[#result + 1] = projected
  end
  return result
end

-- A schema snapshot for discovery, not an executable portable command or an
-- invocation receipt. host_fields identifies facts still resolved by the host.
-- Callers retain their existing validation/copy of identity and layout metadata.
function M.project(command, placement)
  local result = {}
  for _, key in ipairs({ 'id', 'name', 'description', 'aliases', 'provider', 'source', 'type', 'icon',
    'session_action', 'workspace', 'hidden' }) do result[key] = command[key] end
  result.arguments = M.project_arguments(command.arguments)
  if placement then result.path, result.replace = placement.path, placement.replace end
  return result
end

return M
