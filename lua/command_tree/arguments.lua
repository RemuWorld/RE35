local Core = require('command_environment.core.arguments')
local M = {}

function M.default(field, ctx, args)
  if type(field.default) == "function" then
    return vim.api.nvim_win_call(ctx.win, function() return field.default(ctx, args) end)
  end
  return field.default
end

function M.items(field, ctx, args)
  local items = field.items
  if type(items) == "function" then items = vim.api.nvim_win_call(ctx.win, function() return field.items(ctx, args) end) end
  items = items or (field.kind == "boolean" and { true, false } or {})
  assert(type(items) == "table" and vim.islist(items), "Argument choices must be an array")
  return items
end

function M.value(item)
  return Core.value(item)
end

function M.label(item)
  return Core.label(item)
end

function M.coerce(field, value)
  return Core.coerce(field, value)
end

function M.contains(items, value)
  for index, item in ipairs(items) do if vim.deep_equal(item, value) then return index end end
end

function M.validate(field, value, ctx, args)
  local valid, reason = Core.validate(field, value)
  if not valid then return false, reason end
  if value ~= nil then
    if (field.kind == "select" or field.kind == "multiselect") and field.items then
      local ok, choices = pcall(M.items, field, ctx, args)
      if not ok then return false, tostring(choices) end
      local allowed = {}
      for _, item in ipairs(choices) do allowed[#allowed + 1] = M.value(item) end
      for _, selected in ipairs(field.kind == "multiselect" and value or { value }) do
        if not M.contains(allowed, selected) then return false, "Choice is no longer available; reopen this field" end
      end
    end
  end
  if field.validate then
    local ok, valid, reason = pcall(function()
      local accepted, detail
      vim.api.nvim_win_call(ctx.win, function() accepted, detail = field.validate(value, ctx, args) end)
      return accepted, detail
    end)
    if not ok then return false, tostring(valid) end
    if not valid then return false, reason or "Invalid value" end
  end
  return true
end

return M
