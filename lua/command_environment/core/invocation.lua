-- A portable command intent. Validation never selects, authorizes or executes it.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { max_bytes = 65536, max_depth = 16, max_items = 2048 }

local function object(value, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'),
    label .. ' must be an object')
  for key in next, value do assert(type(key) == 'string', label .. ' keys must be strings') end
end

function M.validate(request)
  local ok, result = pcall(function()
    object(request, 'Invocation')
    for key in next, request do assert(key == 'command' or key == 'args', 'Unknown invocation field') end
    local id = rawget(request, 'command')
    assert(type(id) == 'string' and #id <= 160 and id:match('^[A-Za-z0-9_][A-Za-z0-9_.-]*$'),
      'Invocation command must be an exact stable command ID')
    assert(not id:match('^ex%.') and not id:match('^keymap%.') and not id:match('^buffer%.'),
      'Invocation cannot use a runtime command ID')
    local args = rawget(request, 'args')
    if args == nil then args = {} end
    object(args, 'Invocation args')
    local seen, count, bytes = {}, 0, 0
    local function copy(value, depth)
      count = count + 1
      assert(count <= M.max_items and depth <= M.max_depth, 'Invocation exceeds depth/item limits')
      local kind = type(value)
      if kind == 'string' then
        bytes = bytes + #value
        assert(bytes <= M.max_bytes and J.valid_utf8(value), 'Invocation text exceeds limits or is not UTF-8')
        return value
      end
      if kind == 'number' then
        assert(value == value and math.abs(value) <= J.max_number, 'Invocation numbers must fit the JSON contract')
        return value
      end
      if kind == 'boolean' then return value end
      assert(kind == 'table', 'Invocation arguments must be data only')
      local marker = U.kind(value)
      assert(getmetatable(value) == nil or marker, 'Invocation cannot contain host objects')
      if marker == 'null' then return U.null end
      assert(not seen[value], 'Invocation cannot contain cycles')
      seen[value] = true
      local array = marker == 'array' or marker ~= 'object' and next(value) ~= nil and U.islist(value)
      if array then U.assert_array(value, 'Invocation array') else object(value, 'Invocation object') end
      local out = marker == 'array' and U.array() or marker == 'object' and U.object() or {}
      for key, child in next, value do
        if not array then copy(key, depth + 1) end
        out[key] = copy(child, depth + 1)
      end
      seen[value] = nil
      return out
    end
    local prepared = { command = id, args = copy(args, 0) }
    assert(#J.encode(prepared) <= M.max_bytes, 'Invocation exceeds the encoded byte limit')
    return prepared
  end)
  if not ok then return nil, tostring(result) end
  return result
end

return M
