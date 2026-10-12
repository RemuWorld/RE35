-- Data helpers shared by the portable model. Compatible with Lua 5.1 syntax.
-- No editor, filesystem, process, callback, or foreign-object dependency.
local M = {}
local array_mt, object_mt, null_mt = {}, {}, {}
M.null = setmetatable({}, null_mt)

function M.kind(value)
  if type(value) ~= 'table' then return nil end
  local mt = getmetatable(value)
  if mt == array_mt then return 'array' end
  if mt == object_mt then return 'object' end
  if mt == null_mt then return 'null' end
end
local function supported(value)
  local mt = getmetatable(value)
  assert(mt == nil or mt == array_mt or mt == object_mt or mt == null_mt, 'Data cannot have an arbitrary metatable')
end
local function dense(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  for index = 1, count do if rawget(value, index) == nil then return false end end
  return true
end
function M.islist(value)
  if type(value) ~= 'table' then return false end
  local mt, kind = getmetatable(value), M.kind(value)
  if kind == 'object' or kind == 'null' or mt ~= nil and kind == nil then return false end
  return dense(value)
end
function M.assert_array(value, label)
  assert(M.islist(value), (label or 'Value') .. ' must be a dense array')
  return value
end
function M.array(value)
  value = value or {}
  M.assert_array(value)
  return setmetatable(value, array_mt)
end
function M.object(value)
  value = value or {}
  assert(type(value) == 'table', 'Object must be a table')
  supported(value)
  assert(M.kind(value) == nil or M.kind(value) == 'object', 'Object must not be an array or null')
  for key in pairs(value) do assert(type(key) == 'string', 'Object keys must be strings') end
  return setmetatable(value, object_mt)
end
function M.clone(value)
  local seen, count = {}, 0
  local function copy(child, depth)
    count = count + 1
    assert(depth <= 128 and count <= 100000, 'Data exceeds depth/item limits')
    local kind = type(child)
    if kind == 'nil' or kind == 'string' or kind == 'boolean' then return child end
    if kind == 'number' then
      assert(child == child and math.abs(child) < math.huge, 'Data numbers must be finite')
      return child
    end
    assert(kind == 'table', 'Data cannot contain ' .. kind)
    supported(child)
    local marker = M.kind(child)
    if marker == 'null' then assert(child == M.null, 'Invalid null marker'); return M.null end
    if marker == 'array' then M.assert_array(child) end
    if marker == 'object' then for key in pairs(child) do assert(type(key) == 'string', 'Object keys must be strings') end end
    assert(not seen[child], 'Data cannot contain a cycle')
    seen[child] = true
    local result = {}
    for key, item in pairs(child) do
      local key_kind = type(key)
      assert(key_kind == 'string' or key_kind == 'number' or key_kind == 'boolean', 'Data keys must be primitive values')
      result[copy(key, depth + 1)] = copy(item, depth + 1)
    end
    seen[child] = nil
    return setmetatable(result, getmetatable(child))
  end
  return copy(value, 0)
end
function M.deep_equal(a, b)
  local seen = {}
  local function equal(first, second)
    if type(first) ~= type(second) or M.kind(first) ~= M.kind(second) then return false end
    if type(first) ~= 'table' then return first == second end
    local mt1, mt2 = getmetatable(first), getmetatable(second)
    if mt1 ~= nil and M.kind(first) == nil or mt2 ~= nil and M.kind(second) == nil then return false end
    if rawequal(first, second) then return true end
    if M.kind(first) == 'null' then return false end
    if seen[first] then return seen[first] == second end
    seen[first] = second
    for key, child in pairs(first) do if not equal(child, rawget(second, key)) then return false end end
    for key in pairs(second) do if rawget(first, key) == nil then return false end end
    seen[first] = nil
    return true
  end
  return equal(a, b)
end
function M.sorted_keys(value)
  supported(value)
  local result = {}; for key in pairs(value) do result[#result + 1] = key end
  table.sort(result); return result
end
function M.extend(...)
  local result = {}
  for index = 1, select('#', ...) do
    local source = select(index, ...)
    if source then supported(source); for key, value in pairs(source) do result[key] = value end end
  end
  return result
end
function M.list_copy(value)
  M.assert_array(value)
  local result = {}; for index, child in ipairs(value) do result[index] = child end
  return result
end
function M.split(text, separator)
  assert(type(text) == 'string' and type(separator) == 'string' and separator ~= '', 'Split expects text and a nonempty separator')
  local result, start = {}, 1
  while true do
    local at = text:find(separator, start, true)
    if not at then result[#result + 1] = text:sub(start); break end
    result[#result + 1], start = text:sub(start, at - 1), at + #separator
  end
  return result
end
return M
