-- Portable command definitions are data, not executable callbacks or receipts.
-- A host manifest describes supported arguments; it does not grant availability
-- or permission. Every resolved invocation still goes through the host dispatcher.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local Invocation = require('command_environment.core.invocation')
local Descriptor = require('command_environment.core.command_descriptor')
local Arguments = require('command_environment.core.arguments')
local M = { version = 1, max_bytes = 65536, max_commands = 64,
  max_steps = 16, max_inputs = 16, max_choices = 64, max_depth = 16, max_items = 32768 }

local function object(value, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'),
    label .. ' must be an object')
  for key in next, value do assert(type(key) == 'string', label .. ' keys must be strings') end
end
local function fields(value, allowed, label)
  object(value, label)
  for key in next, value do assert(allowed[key], 'Unknown ' .. label .. ' field: ' .. key) end
end
local function text(value, label, limit)
  assert(type(value) == 'string' and #value > 0 and #value <= limit
    and not value:find('[%z\1-\31\127]') and J.valid_utf8(value), label .. ' must be nonempty UTF-8 text')
  return value
end
local function input_name(value)
  assert(type(value) == 'string' and #value <= 64 and value:match('^[A-Za-z_][A-Za-z0-9_]*$'),
    'Input names must be identifiers of at most 64 bytes')
  return value
end
local function command_id(value, user)
  local intent, why = Invocation.validate({ command = value })
  assert(intent, why)
  if user then assert(value:match('^user%.[A-Za-z0-9_][A-Za-z0-9_.-]*$'), 'Composition IDs must begin with user.')
  else assert(not value:match('^user%.'), 'Nested compositions are not supported in version 1') end
  return value
end

-- Validate/copy before inspecting any fields. No arbitrary metatable, callback,
-- sparse array or unsafe number can enter the contract through native callers.
local function data_copy(value)
  local seen, count, bytes = {}, 0, 0
  local function copy(item, depth)
    count = count + 1
    assert(count <= M.max_items and depth <= M.max_depth, 'Composition exceeds depth/item limits')
    local kind = type(item)
    if kind == 'string' then
      bytes = bytes + #item
      assert(bytes <= M.max_bytes and J.valid_utf8(item), 'Composition text exceeds limits or is not UTF-8')
      return item
    end
    if kind == 'number' then
      assert(item == item and math.abs(item) <= J.max_number, 'Composition numbers must fit the JSON contract')
      return item
    end
    if kind == 'boolean' then return item end
    assert(kind == 'table', 'Composition must contain JSON data only')
    local marker = U.kind(item)
    assert(getmetatable(item) == nil or marker, 'Composition cannot contain host objects')
    if marker == 'null' then assert(item == U.null, 'Invalid null marker'); return U.null end
    assert(not seen[item], 'Composition cannot contain cycles')
    seen[item] = true
    local array = marker == 'array' or marker ~= 'object' and next(item) ~= nil and U.islist(item)
    if array then U.assert_array(item, 'Composition array') else object(item, 'Composition object') end
    local out = marker == 'array' and U.array() or marker == 'object' and U.object() or {}
    for key, child in next, item do
      if not array then copy(key, depth + 1) end
      out[key] = copy(child, depth + 1)
    end
    seen[item] = nil
    return out
  end
  local result = copy(value, 0)
  assert(#J.encode(result) <= M.max_bytes, 'Composition exceeds the encoded byte limit')
  return result
end
local function manifest_map(definitions)
  if definitions == nil then return nil end
  local copied = data_copy(definitions)
  U.assert_array(copied, 'Composition host definitions')
  assert(#copied <= 512, 'Composition host definitions exceed 512 commands')
  local result = {}
  for _, definition in ipairs(copied) do
    Descriptor.protocol(definition)
    command_id(definition.id, false)
    assert(not result[definition.id], 'Duplicate host command: ' .. definition.id)
    result[definition.id] = definition
  end
  return result
end
local function argument_value(field, value)
  local ok, why = Arguments.validate(field, value, field.items)
  assert(ok, 'Argument ' .. field.name .. ': ' .. tostring(why))
end
local function validate_definition(definition, manifest)
  fields(definition, { id=true, name=true, inputs=true, steps=true }, 'composition')
  command_id(definition.id, true)
  text(definition.name, 'Composition name', 128)
  local inputs = definition.inputs == nil and U.array() or definition.inputs
  U.assert_array(inputs, 'Composition inputs')
  assert(#inputs <= M.max_inputs, 'Composition exceeds 16 inputs')
  local names, prepared_inputs = {}, U.array()
  for _, input in ipairs(inputs) do
    fields(input, { name=true, type=true, required=true, choices=true }, 'composition input')
    input_name(input.name)
    assert(not names[input.name], 'Duplicate composition input: ' .. input.name)
    assert(input.type == 'text' or input.type == 'select', 'Composition input type must be text or select')
    assert(input.required == nil or type(input.required) == 'boolean', 'Input required must be a boolean')
    local prepared = { name=input.name, type=input.type, required=input.required == true }
    if input.type == 'select' then
      U.assert_array(input.choices, 'Input choices')
      assert(#input.choices > 0 and #input.choices <= M.max_choices, 'Select inputs need 1 to 64 choices')
      local choices = {}; prepared.choices = U.array()
      for _, choice in ipairs(input.choices) do
        assert(type(choice) == 'string' and #choice <= 4096, 'Input choices must be text of at most 4096 bytes')
        assert(not choices[choice], 'Duplicate input choice')
        choices[choice] = true; prepared.choices[#prepared.choices + 1] = choice
      end
    else assert(input.choices == nil, 'Text inputs cannot declare choices') end
    names[prepared.name] = prepared; prepared_inputs[#prepared_inputs + 1] = prepared
  end
  U.assert_array(definition.steps, 'Composition steps')
  assert(#definition.steps > 0 and #definition.steps <= M.max_steps, 'Composition needs 1 to 16 steps')
  local steps = U.array()
  for _, step in ipairs(definition.steps) do
    fields(step, { command=true, args=true }, 'composition step')
    command_id(step.command, false)
    local target = manifest and manifest[step.command]
    assert(not manifest or target, 'Command is unsupported by this host manifest: ' .. step.command)
    local target_fields = {}
    for _, field in ipairs(target and target.arguments or {}) do target_fields[field.name] = field end
    local args = step.args == nil and {} or step.args
    local prepared_args, literal_args = U.object(), U.object()
    object(args, 'Step args')
    for name, binding in next, args do
      fields(binding, { input=true, value=true }, 'argument binding')
      assert((binding.input ~= nil) ~= (binding.value ~= nil), 'Argument binding needs exactly one input or value')
      local field = target_fields[name]
      assert(not manifest or field, 'Unknown argument ' .. name .. ' for ' .. step.command)
      if binding.input ~= nil then
        local input = names[binding.input]
        assert(input, 'Unknown composition input: ' .. tostring(binding.input))
        if field then
          assert(field.kind == nil or field.kind == 'text' or field.kind == 'path' or field.kind == 'select',
            'Text input cannot bind argument ' .. name .. ' of kind ' .. tostring(field.kind))
          assert(not field.required or input.required, 'Required argument ' .. name .. ' needs a required input')
          if field.kind == 'select' then
            assert(input.type == 'select', 'Select argument ' .. name .. ' needs a select input')
            for _, choice in ipairs(input.choices) do argument_value(field, choice) end
          end
        end
        prepared_args[name] = { input=binding.input }
      else
        if field then argument_value(field, binding.value) end
        -- Existing invocation bounds also apply to every literal step.
        local literal, why = Invocation.validate({ command=step.command, args={ [name]=binding.value } })
        assert(literal, why)
        prepared_args[name] = { value=literal.args[name] }
        literal_args[name] = literal.args[name]
      end
    end
    for name, field in next, target_fields do
      assert(not field.required or prepared_args[name] ~= nil, 'Missing required argument ' .. name .. ' for ' .. step.command)
    end
    local literal_intent, why = Invocation.validate({ command=step.command, args=literal_args })
    assert(literal_intent, why)
    steps[#steps + 1] = { command=step.command, args=prepared_args }
  end
  return { id=definition.id, name=definition.name, inputs=prepared_inputs, steps=steps }
end
local function attempt(callback)
  local ok, result = pcall(callback)
  if not ok then return nil, tostring(result) end
  return result
end
function M.validate(library, definitions)
  return attempt(function()
    library = data_copy(library)
    fields(library, { version=true, commands=true }, 'composition library')
    assert(library.version == 1, 'Unsupported composition library version')
    U.assert_array(library.commands, 'Composition commands')
    assert(#library.commands <= M.max_commands, 'Composition library exceeds 64 commands')
    local manifest, ids, commands = manifest_map(definitions), {}, U.array()
    for _, definition in ipairs(library.commands) do
      local prepared = validate_definition(definition, manifest)
      assert(not ids[prepared.id], 'Duplicate composition ID: ' .. prepared.id)
      ids[prepared.id] = true; commands[#commands + 1] = prepared
    end
    local result = { version=1, commands=commands }
    assert(#J.encode(result) <= M.max_bytes, 'Normalized composition library exceeds its byte limit')
    return result
  end)
end
function M.resolve(definition, inputs, definitions)
  return attempt(function()
    local library, why = M.validate({ version=1, commands={ definition } }, definitions)
    assert(library, why)
    definition = library.commands[1]
    inputs = data_copy(inputs == nil and {} or inputs)
    object(inputs, 'Composition input values')
    local names = {}
    for _, input in ipairs(definition.inputs) do
      names[input.name] = input
      local value = inputs[input.name]
      assert(value == nil or type(value) == 'string', 'Input ' .. input.name .. ' must be text')
      assert(not input.required or value ~= nil and value ~= '', 'Input ' .. input.name .. ' is required')
      if input.type == 'select' and value ~= nil then
        assert(Arguments.contains(input.choices, value), 'Input ' .. input.name .. ' is not an available choice')
      end
    end
    for name in next, inputs do assert(names[name], 'Unknown composition input value: ' .. name) end
    local result = U.array()
    for _, step in ipairs(definition.steps) do
      local args = U.object()
      for name, binding in next, step.args do
        -- Missing optional input deliberately omits its bound argument. No
        -- first select choice, empty text or host default is invented here.
        if binding.input ~= nil then args[name] = inputs[binding.input]
        else args[name] = binding.value end
      end
      local invocation, reason = Invocation.validate({ command=step.command, args=args })
      assert(invocation, reason)
      result[#result + 1] = invocation
    end
    assert(#J.encode(result) <= M.max_bytes, 'Resolved composition exceeds its byte limit')
    return result
  end)
end
return M
