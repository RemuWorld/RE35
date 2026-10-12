-- Bounded appearance authoring and sharing. No host API or execution authority.
local P = require('command_environment.core.presentation')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 1, file_format = 're35.presentation', file_version = 1 }
local limit = P.limits().bytes
local schema = P.editor_schema()
local builtin, scenes, groups = {}, {}, {}
for _, id in ipairs(schema.builtins) do builtin[id] = true end
for _, scene in ipairs(schema.scenes) do scenes[scene] = true end
for _, group in ipairs(schema.groups) do
  groups[group.id] = {}
  for _, field in ipairs(group.fields) do groups[group.id][field.id] = field end
end
local actions = {
  create = { id = true, name = true, source = true }, clone = { id = true, name = true, source = true },
  rename = { id = true, name = true }, set = { id = true, scene = true, group = true, field = true, component = true, value = true },
  reset = { id = true, scene = true, group = true, field = true, component = true },
  reset_scenes = { id = true }, reset_name = { id = true }, reset_parent = { id = true },
  select = { id = true }, clear_selection = {}, parent = { id = true, parent = true }, delete = { id = true },
}
local function object(value, allowed, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'), label .. ' must be plain object data')
  for key in next, value do assert(type(key) == 'string' and allowed[key], 'Unknown ' .. label .. ' field') end
  return value
end
local function safely(callback, ...)
  local ok, value = pcall(callback, ...)
  if ok then return value end
  return nil, tostring(value)
end
local function identifier(value)
  assert(type(value) == 'string' and #value <= schema.limits.id_bytes and value:match('^[a-z][a-z0-9_-]*$'),
    'Preset ID must use lowercase ASCII letters, digits, underscores or hyphens')
  return value
end
local function known(config, id)
  identifier(id); assert(builtin[id] or config.presets[id] ~= nil, 'Unknown preset reference: ' .. id)
  return id
end
local function declaration(config, id)
  known(config, id)
  config.presets[id] = config.presets[id] or U.object()
  return config.presets[id]
end
local function normalized(config)
  local value, reason = P.validate(config); assert(value, reason); return value
end
local function address(action)
  if action.scene ~= nil then assert(type(action.scene) == 'string' and scenes[action.scene], 'Unknown presentation scene') end
  if action.group ~= nil then assert(type(action.group) == 'string' and groups[action.group], 'Unknown presentation group') end
  if action.field ~= nil then
    assert(action.group ~= nil and type(action.field) == 'string' and groups[action.group][action.field], 'Unknown presentation field')
  end
  if action.component ~= nil then
    assert(action.group == 'roles' and action.field ~= nil and (action.component == 'fg' or action.component == 'bg'),
      'Color component requires a theme role and fg or bg')
  end
end
local function snapshot(config, id, name)
  local base, reason = P.resolve(config, id); assert(base, reason)
  base.id, base.name, base.extends, base.scenes = nil, name, false, U.object()
  for _, scene in ipairs(schema.scenes) do
    local value, why = P.resolve(config, id, scene); assert(value, why)
    value.id, value.name = nil, nil; base.scenes[scene] = value
  end
  -- Empty roles are deliberately retained. The explicit standalone parent
  -- keeps them theme-owned even if Full or the source receives colors later.
  return base
end
local function container(spec, action, create)
  if action.scene == nil then return spec end
  if create then
    spec.scenes = spec.scenes or U.object()
    spec.scenes[action.scene] = spec.scenes[action.scene] or U.object()
  end
  return spec.scenes and spec.scenes[action.scene]
end
local function reset(config, action)
  address(action)
  if action.id == nil then
    assert(action.scene == nil and action.group == nil and action.field == nil and action.component == nil,
      'Reset all cannot include a preset address')
    return U.object({ version = 1, presets = U.object() })
  end
  known(config, action.id)
  local spec = config.presets[action.id]
  if action.scene == nil and action.group == nil then
    if builtin[action.id] then config.presets[action.id] = nil
    elseif spec then config.presets[action.id] = U.object({ name = spec.name, extends = spec.extends }) end
    return config
  end
  if spec == nil then return config end
  if action.scene ~= nil and action.group == nil then
    if spec.scenes then spec.scenes[action.scene] = nil end
    return config
  end
  local target = container(spec, action, false)
  if target == nil then return config end
  if action.field == nil then target[action.group] = nil
  elseif target[action.group] ~= nil then
    if action.component == nil then target[action.group][action.field] = nil
    elseif target[action.group][action.field] ~= nil then
      target[action.group][action.field][action.component] = nil
    end
  end
  return config
end
function M.schema() return P.editor_schema() end
function M.edit(presentation, action)
  return safely(function()
    local config = normalized(presentation)
    assert(type(action) == 'table' and (getmetatable(action) == nil or U.kind(action) == 'object'), 'Presentation action must be plain object data')
    assert(type(action.kind) == 'string' and actions[action.kind], 'Unknown presentation action')
    local allowed = { kind = true }; for key in next, actions[action.kind] do allowed[key] = true end
    object(action, allowed, 'presentation action')
    local kind = action.kind
    if kind == 'create' or kind == 'clone' then
      local id = identifier(action.id)
      assert(not builtin[id] and config.presets[id] == nil, 'Preset ID already exists')
      assert(kind ~= 'clone' or action.source ~= nil, 'Clone requires its source preset')
      local source, name = action.source, action.name
      if source == nil then source = 'full' end
      if name == nil then name = id end
      known(config, source)
      if kind == 'clone' then config.presets[id] = snapshot(config, source, name)
      else config.presets[id] = U.object({ name = name, extends = source }) end
    elseif kind == 'reset' then config = reset(config, action)
    elseif kind == 'clear_selection' then config.selected = nil
    else
      local id = known(config, action.id)
      if kind == 'select' then config.selected = id
      elseif kind == 'delete' then
        assert(not builtin[id], 'Built-in presets cannot be deleted')
        for _, other in ipairs(U.sorted_keys(config.presets)) do
          assert(other == id or config.presets[other].extends ~= id, 'Another preset inherits this preset: ' .. other)
        end
        config.presets[id] = nil; if config.selected == id then config.selected = nil end
      elseif kind == 'set' then
        address(action)
        assert(action.group ~= nil and action.field ~= nil and action.value ~= nil, 'Set requires a group, field and value')
        local target = container(declaration(config, id), action, true)
        target[action.group] = target[action.group] or U.object()
        if action.component ~= nil then
          target[action.group][action.field] = target[action.group][action.field] or U.object()
          target[action.group][action.field][action.component] = U.clone(action.value)
        else target[action.group][action.field] = U.clone(action.value) end
      elseif kind == 'reset_scenes' or kind == 'reset_name' or kind == 'reset_parent' then
        -- Resetting an absent builtin override is a no-op, including when the
        -- custom declaration collection is already at its 32-entry ceiling.
        local spec = config.presets[id]
        if spec then
          if kind == 'reset_scenes' then spec.scenes = nil
          elseif kind == 'reset_name' then spec.name = nil
          else spec.extends = nil end
        end
      else
        local spec = declaration(config, id)
        if kind == 'rename' then assert(action.name ~= nil, 'Rename requires a preset name'); spec.name = U.clone(action.name)
        elseif kind == 'parent' then
          if action.parent ~= nil and action.parent ~= false then identifier(action.parent) end
          spec.extends = action.parent
        end
      end
    end
    return normalized(config)
  end)
end
function M.file_validate(file)
  return safely(function()
    object(file, { format = true, version = true, presentation = true }, 'presentation file')
    assert(file.format == M.file_format and file.version == M.file_version, 'Unsupported presentation file format or version')
    assert(file.presentation ~= nil, 'Presentation file requires its declarations object')
    local result = U.object({ format = M.file_format, version = M.file_version, presentation = normalized(file.presentation) })
    assert(#J.encode(result) + 1 <= limit, 'Presentation file exceeds 64 KiB')
    return result
  end)
end
function M.file_decode(json)
  return safely(function()
    assert(type(json) == 'string' and #json <= limit, 'Presentation file exceeds 64 KiB')
    local result, reason = M.file_validate(J.decode(json)); assert(result, reason); return result
  end)
end
function M.file_encode(file)
  return safely(function()
    local result, reason = M.file_validate(file); assert(result, reason)
    return J.encode(result) .. '\n'
  end)
end
return M
