-- Translate only the two known JSON object markers at the host boundary.
local Core = require('command_environment.core.presentation')
local U = require('command_environment.core.util')
local M = {}
local function convert(value, host, seen, depth, budget)
  budget.count = budget.count + 1
  assert(depth <= 16 and budget.count <= 12000, 'Presentation exceeds data limits')
  if type(value) ~= 'table' then return value end
  local mt = getmetatable(value)
  assert(mt == nil or mt == vim._empty_dict_mt or U.kind(value) == 'object',
    'Presentation must contain plain objects')
  assert(not seen[value], 'Presentation contains a cycle')
  seen[value] = true
  local result = host and vim.empty_dict() or U.object()
  for key, child in pairs(value) do
    assert(type(key) == 'string', 'Presentation objects require string keys')
    result[key] = convert(child, host, seen, depth + 1, budget)
  end
  seen[value] = nil
  return result
end
function M.core(value) return convert(value, false, {}, 0, { count = 0 }) end
function M.host(value) return convert(value, true, {}, 0, { count = 0 }) end
function M.validate(value)
  local ok, data = pcall(M.core, value)
  if not ok then return nil, tostring(data) end
  local prepared, err = Core.validate(data)
  if not prepared then return nil, err end
  return M.host(prepared)
end
return M
