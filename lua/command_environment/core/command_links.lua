-- Portable presentation declarations. They do not define execution behavior.
local U = require('command_environment.core.util')
local M = {}

local function object(value, label)
  assert(type(value) == 'table' and U.kind(value) ~= 'array' and U.kind(value) ~= 'null', label .. ' must be an object')
  local mt = getmetatable(value)
  assert(mt == nil or U.kind(value) == 'object', label .. ' cannot have a metatable')
  for key in pairs(value) do assert(type(key) == 'string', label .. ' must have string keys') end
end

local function fields(value, allowed, label)
  object(value, label)
  for key in pairs(value) do assert(allowed[key], 'Unknown ' .. label .. ' field: ' .. key) end
end

-- Lua 5.1 has no utf8 library. Check code points without loading an editor,
-- interpreter extension, or callback from the declaration being inspected.
local function utf8(value)
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    local count, low, high = 0, 128, 191
    if first < 128 then count = 0
    elseif first >= 194 and first <= 223 then count = 1
    elseif first >= 224 and first <= 239 then
      count = 2
      if first == 224 then low = 160 elseif first == 237 then high = 159 end
    elseif first >= 240 and first <= 244 then
      count = 3
      if first == 240 then low = 144 elseif first == 244 then high = 143 end
    else return false end
    if index + count > #value then return false end
    for offset = 1, count do
      local byte = value:byte(index + offset)
      if byte < (offset == 1 and low or 128) or byte > (offset == 1 and high or 191) then return false end
    end
    index = index + count + 1
  end
  return true
end

local function text(value, label, maximum, budget)
  assert(type(value) == 'string' and value ~= '', label .. ' must be a nonempty string')
  assert(#value <= maximum, label .. ' exceeds ' .. maximum .. ' bytes')
  assert(not value:find('[%z\1-\31\127]') and utf8(value), label .. ' must be one line of valid UTF-8 text')
  budget.bytes = budget.bytes + #value
  assert(budget.bytes <= 262144, 'Command links exceed 256 KiB of text')
  return value
end

local function stable_id(value, label, budget)
  text(value, label, 192, budget)
  assert(not value:match('^ex%.buffer%.') and not value:match('^keymap%.'),
    label .. ' is a runtime ID; use a stable adapter or global Ex command ID')
end

local function validate(links)
  object(links, 'command_links')
  local out, count, budget = U.object(), 0, { bytes = 0 }
  for id, link in pairs(links) do
    count = count + 1
    assert(count <= 512, 'Command links exceed 512 commands')
    stable_id(id, 'Command link ID', budget)
    fields(link, { name = true, description = true, arguments = true }, 'command link ' .. id)
    local prepared = U.object()
    if link.name ~= nil then prepared.name = text(link.name, id .. '.name', 256, budget) end
    if link.description ~= nil then prepared.description = text(link.description, id .. '.description', 4096, budget) end
    if link.arguments ~= nil then
      object(link.arguments, id .. '.arguments')
      prepared.arguments = U.object()
      local arguments = 0
      for name, annotation in pairs(link.arguments) do
        arguments = arguments + 1
        assert(arguments <= 64, id .. ' exceeds 64 argument annotations')
        text(name, 'Argument name', 128, budget)
        fields(annotation, { prompt = true, description = true }, id .. '.arguments.' .. name)
        local field = U.object()
        if annotation.prompt ~= nil then field.prompt = text(annotation.prompt, name .. '.prompt', 512, budget) end
        if annotation.description ~= nil then field.description = text(annotation.description, name .. '.description', 2048, budget) end
        prepared.arguments[name] = field
      end
    end
    out[id] = prepared
  end
  return out
end

function M.validate(links)
  local ok, result = pcall(validate, links == nil and {} or links)
  if not ok then return nil, tostring(result) end
  return result
end

return M
