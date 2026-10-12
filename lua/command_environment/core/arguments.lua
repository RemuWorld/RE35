local U = require('command_environment.core.util')
local M = {}
function M.value(item) if type(item) == 'table' then return item.value end; return item end
function M.label(item) if type(item) == 'table' then return tostring(item.label or item.value) end; return tostring(item) end
function M.coerce(field, value)
  if field.kind ~= 'number' then return value end
  if value == nil or value == '' then return nil end
  local number = tonumber(value)
  if not number or number ~= number or math.abs(number) == math.huge then return nil, 'Enter a finite number' end
  return number
end
function M.contains(items, value)
  for index, item in ipairs(items) do if U.deep_equal(item, value) then return index end end
end
function M.validate(field, value, choices)
  if field.required and (value == nil or value == '') then return false, (field.prompt or field.name) .. ' is required' end
  if value == nil then return true end
  if field.kind == 'boolean' and type(value) ~= 'boolean' then return false, 'Choose true or false' end
  if field.kind == 'number' then
    if type(value) ~= 'number' or value ~= value or math.abs(value) == math.huge then return false, 'Enter a finite number' end
    if field.integer and value % 1 ~= 0 then return false, 'Enter a whole number' end
    if field.min and value < field.min then return false, 'Minimum: ' .. field.min end
    if field.max and value > field.max then return false, 'Maximum: ' .. field.max end
  end
  if field.kind == 'multiselect' then
    if type(value) ~= 'table' or not U.islist(value) then return false, 'Choose a list of values' end
    if field.required and #value == 0 then return false, (field.prompt or field.name) .. ' is required' end
  end
  if (field.kind == 'text' or field.kind == 'path' or field.kind == nil) and type(value) ~= 'string' then return false, 'Enter text' end
  if (field.kind == 'select' or field.kind == 'multiselect') and choices then
    local allowed = {}; for _, item in ipairs(choices) do allowed[#allowed + 1] = M.value(item) end
    for _, selected in ipairs(field.kind == 'multiselect' and value or { value }) do
      if not M.contains(allowed, selected) then return false, 'Choice is no longer available; reopen this field' end
    end
  end
  return true
end
return M
