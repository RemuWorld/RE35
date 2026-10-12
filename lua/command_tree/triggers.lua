local K, Entry = require("command_tree.keys"), require("command_tree.entry")
local M = { owned = {}, suspended = false }
local ns = vim.api.nvim_create_namespace("CommandTreeReplay")
local generation, pending_restore = 0, nil

-- Kept as an internal compatibility surface. Entry is now explicit: native
-- g/z/operator/leader prefixes never open an automatic command guide.
function M.clear() M.owned = {} end
function M.refresh() end
function M.setup(opts, open)
  if pending_restore then pending_restore() end
  generation = generation + 1
  vim.on_key(nil, ns)
  M.suspended, M.opts, M.open = false, opts, open
  M.clear()
end

function M.replay(raw, ctx, exact)
  if not K.valid(ctx) then return false end
  if pending_restore then pending_restore() end
  generation = generation + 1
  local token, restored = generation, false
  local release = Entry.suspend()
  M.suspended = true
  local prefix = ""
  if ctx.mode == "n" or ctx.mode == "o" then
    if ctx.mode == "o" then prefix = "<Esc>" end
    if ctx.register and ctx.register ~= '"' then prefix = prefix .. '"' .. ctx.register end
    if ctx.count and ctx.count > 0 then prefix = prefix .. ctx.count end
    if ctx.mode == "o" then
      prefix = prefix .. (ctx.operator or vim.v.operator)
      local operator_mode = ctx.operator_mode or vim.api.nvim_get_mode().mode
      if operator_mode:sub(1, 2) == "no" then prefix = prefix .. operator_mode:sub(3) end
    end
  end
  local function restore()
    if generation ~= token or restored then return end
    restored, pending_restore = true, nil
    vim.on_key(nil, ns)
    M.suspended = false
    release()
  end
  pending_restore = restore
  vim.on_key(function()
    vim.on_key(nil, ns)
    vim.schedule(restore)
  end, ns)
  -- <Nop> and interrupted input can produce no on_key event.
  vim.defer_fn(restore, math.max(vim.o.timeoutlen, 100) + 100)
  vim.api.nvim_feedkeys(K.raw(prefix) .. raw .. (exact and K.raw("<Ignore>") or ""), "mi", false)
  return true
end

return M
