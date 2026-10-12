-- Applied appearance exports retain their own snapshot and lifecycle owner.
-- Loaded only by the public export entry points; no live environment is cached.
local M = {}

function M.export(lifecycle, get, path, presentation)
  local function failure(reason)
    if path ~= nil then return false, reason end
    return nil, reason
  end
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return failure(admission_error) end
  local env = get()
  local Export = require(presentation and 'command_tree.presentation_export' or 'command_tree.ui_export')
  local owner = lifecycle:token()
  local function snapshot()
    local active = env.session.active
    for _, frame in ipairs(active and active.stack or {}) do
      if frame.id == 'settings' and frame.data.draft and #require('command_tree.settings.transaction').changes(frame) > 0 then
        return nil, 'Apply or discard the Settings draft before exporting UI settings'
      end
    end
    local density = active and active.density or env.preferences:get('density', env.options.window.density)
    if presentation then
      return Export.capture(env.options.presentation, active and active.presentation_id
        or env.options.presentation and env.options.presentation.selected or density)
    end
    return Export.capture(env.options.window, density)
  end
  local function protected_paths()
    local paths = {}
    for _, value in ipairs({ env.profile_path or false, env.preferences.path or false, env.usage.path or false }) do
      if type(value) == 'string' then paths[#paths + 1] = value end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then paths[#paths + 1] = name end
    end
    return paths
  end
  local data, err = snapshot()
  if not data then return failure(err) end
  if path == nil then return data end
  return Export.export(data, path, protected_paths(), function()
    if not lifecycle:is_current(owner) then return false, 'UI export environment changed; run it again' end
    local current, why = snapshot()
    if not current or not vim.deep_equal(current, data) then return false, why or 'UI settings changed; export them again' end
    if Export.protected(path, protected_paths()) then return false, 'UI export destination became protected; choose another file' end
    return true
  end)
end

return M
