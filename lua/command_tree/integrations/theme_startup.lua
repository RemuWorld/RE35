-- Startup restoration follows the activated host, never candidate validation.
local M = {}
local attempted = setmetatable({}, { __mode = 'k' })
local owned = setmetatable({}, { __mode = 'k' })
function M.own(adapter)
  owned[adapter.restore] = true
end
function M.is_owned(adapter)
  return type(adapter) == 'table' and owned[adapter.restore] == true
end
function M.activate(env, current, group, active)
  local theme = env.options.integrations.theme
  if type(theme) ~= 'table' or theme.builtin ~= true or theme.id ~= 'runtime-colorschemes'
    or type(theme.restore) ~= 'function' or not owned[theme.restore]
    or env.options.theme.persist == false or attempted[theme.restore] then return end
  local restore = theme.restore
  local function apply()
    if current() ~= env or active and not active() or attempted[restore] then return end
    attempted[restore] = true
    local ok, restored, status = pcall(restore)
    if not ok or restored == false then
      local reason = not ok and tostring(restored) or type(status) == 'table' and status.error or tostring(status)
      vim.notify('RE35 theme restore failed: ' .. tostring(reason), vim.log.levels.WARN, { title = 'RE35' })
    end
  end
  if vim.v.vim_did_enter == 1 then vim.schedule(apply)
  else vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = apply }) end
end
return M
