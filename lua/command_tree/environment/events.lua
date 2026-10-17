-- Own editor hooks and the entry boundary for one live environment.
local V = require('command_tree.view')
local T, Entry = require('command_tree.triggers'), require('command_tree.entry')
local EditorKeys = require('command_tree.editor_keys')
local M = {}
function M.clear()
  local cleared, reason = pcall(EditorKeys.clear)
  Entry.clear(); T.clear()
  pcall(vim.api.nvim_del_augroup_by_name, 'CommandTree')
  if not cleared then error(reason, 0) end
end
function M.install(env, api, current)
  local options, registry = env.options, env.registry
  V.highlights()
  T.setup(options, api.show)
  Entry.setup(options, api.open)
  EditorKeys.setup(options.editor_keys, options.open_key, api.invoke)
  local group = vim.api.nvim_create_augroup("CommandTree", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function()
    if current() ~= env then return end
    if (env.session.preview_depth or 0) > 0 then env.session.preview_palette_dirty = true; return end
    if env.session.active then env.session.active.preview_identity = nil end
    V.highlights(); env.session:refresh()
  end })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { group = group, callback = function()
    vim.schedule(function() if current() == env then env.session:refresh() end end)
  end })
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "LspAttach", "LspDetach" }, { group = group, callback = function(ev)
    Entry.refresh(ev.buf)
    vim.schedule(function()
      if current() ~= env then return end
      if env.providers then env.providers:refresh(vim.api.nvim_get_current_buf(), false) end
      env.session:refresh()
      Entry.refresh(vim.api.nvim_get_current_buf())
    end)
  end })
  local refresh_pending = false
  local discovery_events = { "SourcePost" }
  if vim.fn.exists("##PackChanged") == 1 then discovery_events[#discovery_events + 1] = "PackChanged" end
  vim.api.nvim_create_autocmd(discovery_events, { group = group, callback = function()
    if refresh_pending then return end
    refresh_pending = true
    vim.schedule(function() refresh_pending = false; if current() == env then api.refresh() end end)
  end })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = { "CommandEnvironmentRefresh", "LazyLoad", "VeryLazy" }, callback = function()
    vim.schedule(function() if current() == env then api.refresh() end end)
  end })
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout", "WinEnter" }, { group = group, callback = function(ev)
    if current() ~= env then return end
    env.session:editor_event(ev)
  end })
  vim.api.nvim_create_user_command("CommandEnvironment", function(cmd)
    if cmd.args == "" then api.open() else api.execute(cmd.args) end
  end, { nargs = "?", desc = "Open environment or execute a command ID / alias", force = true,
    complete = function(lead)
      local result = {}
      for _, command in ipairs(registry:list()) do if command.id:sub(1, #lead) == lead then result[#result + 1] = command.id end end
      return result
    end })
  vim.api.nvim_create_user_command("CommandEnvironmentRefresh", api.refresh, { desc = "Refresh command providers", force = true })
  vim.api.nvim_create_user_command("CommandTree", function() api.open() end, { desc = "Open Command Environment", force = true })
  vim.api.nvim_create_user_command("CommandTreeKeys", function(cmd) api.show({ keys = cmd.args }) end,
    { nargs = "?", desc = "Show keymaps", force = true })
  env.providers:refresh(vim.api.nvim_get_current_buf(), true)
  local token = api.environment_token()
  require('command_tree.integrations.theme_startup').activate(env, current, group,
    function() return api.is_current_environment(token) end)
end
return M
