-- Drafts live only in this Neovim session. Nothing here is written or exported.
local M = {}
local function simple(value, depth)
  if depth > 4 then return nil end
  if type(value) == "string" then return #value <= 65536 and value or nil end
  if type(value) == "boolean" or type(value) == "number" then return value end
  if type(value) == "table" and vim.islist(value) and #value <= 100 then
    local out = {}
    for _, item in ipairs(value) do
      local copied = simple(item, depth + 1)
      if copied == nil or type(copied) == "table" then return nil end
      out[#out + 1] = copied
    end
    return out
  end
end
function M.new()
  local self = { records = {}, order = {}, max_entries = 16 }
  local function key(id, buf) return tostring(buf) .. ":" .. id end
  function self:forget(id, buf)
    local name = key(id, buf)
    self.records[name] = nil
    for index = #self.order, 1, -1 do if self.order[index] == name then table.remove(self.order, index) end end
  end
  function self:save(command, input, ctx)
    if not command.id or input.callback or command.persistent == false then return end
    local value = { args = {}, drafts = {}, index = input.index, fields = {} }
    for _, field in ipairs(command.arguments or {}) do
      if not field.secret then
        value.fields[field.name] = field.kind or "text"
        value.args[field.name] = simple(input.args[field.name], 0)
        value.drafts[field.name] = simple(input.drafts[field.name], 0)
      end
    end
    local encoded = vim.json.encode(value)
    self:forget(command.id, ctx.buf)
    if #encoded > 65536 then return end
    local name = key(command.id, ctx.buf)
    self.records[name], self.order[#self.order + 1] = value, name
    while #self.order > self.max_entries do self.records[table.remove(self.order, 1)] = nil end
  end
  function self:get(command, ctx, supplied)
    local saved = self.records[key(command.id, ctx.buf)]
    if not saved then return nil end
    local result = { args = {}, drafts = {}, index = math.max(1, math.min(saved.index or 1, #command.arguments)) }
    for _, field in ipairs(command.arguments or {}) do
      if not field.secret and (supplied or {})[field.name] == nil and saved.fields[field.name] == (field.kind or "text") then
        result.args[field.name], result.drafts[field.name] = vim.deepcopy(saved.args[field.name]), vim.deepcopy(saved.drafts[field.name])
      end
    end
    return result
  end
  return self
end
return M
