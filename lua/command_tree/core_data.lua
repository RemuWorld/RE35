-- JSON data translation at the Neovim boundary; never copy live host objects.
local U = require('command_environment.core.util')
local M = {}
local function convert(value, host, seen, depth, budget)
  budget.count = budget.count + 1
  assert(depth <= 24 and budget.count <= 20000, 'Data exceeds nesting/item limits')
  local kind = type(value)
  if kind ~= 'table' then
    assert(kind == 'string' or kind == 'boolean' or kind == 'number', 'Value is not JSON data')
    if kind == 'number' then assert(value == value and math.abs(value) < math.huge, 'Value must be finite') end
    return value
  end
  local marker, mt = U.kind(value), getmetatable(value)
  assert(marker ~= 'null', 'Null is not supported in portable declarations')
  assert(mt == nil or mt == vim._empty_dict_mt or marker == 'object' or marker == 'array',
    'Data cannot have an arbitrary metatable')
  assert(not seen[value], 'Data contains a cycle')
  seen[value] = true
  local array = marker == 'array' or mt ~= vim._empty_dict_mt and marker ~= 'object' and U.islist(value)
  local result = {}
  for key, child in pairs(value) do
    assert(array and type(key) == 'number' or not array and type(key) == 'string', 'Data has mixed/non-JSON keys')
    result[key] = convert(child, host, seen, depth + 1, budget)
  end
  if array then U.assert_array(result) end
  seen[value] = nil
  if host then
    if not array and not next(result) then return vim.empty_dict() end
    return result
  end
  -- Unmarked empty Lua tables retain their historical ambiguity. Schema
  -- validators decide their kind; JSON object/array markers remain explicit.
  if marker == 'array' or array and next(result) then return U.array(result) end
  if marker == 'object' or mt == vim._empty_dict_mt or not array then return U.object(result) end
  return result
end
function M.core(value) return convert(value, false, {}, 0, { count = 0 }) end
function M.host(value) return convert(value, true, {}, 0, { count = 0 }) end
return M
