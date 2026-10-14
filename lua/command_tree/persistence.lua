-- Describe host-owned storage without treating a draft or local default as saved.
local M = {}
local labels = {
  draft = 'Draft · not applied or saved', saved = 'Saved · restored at startup',
  restored = 'Saved · restored at startup', session_only = 'Applied in memory · this session only',
  local_defaults = 'Local defaults · no saved change', load_failed = 'Load failed · local settings are active',
  save_failed = 'Save failed · applied settings kept', saved_not_active = 'Saved · activation failed; reload required',
  no_saved_theme = 'No saved theme · current editor theme', disabled = 'Theme persistence disabled',
  restore_failed = 'Restore failed · current editor theme kept',
}
local function text(value)
  if type(value) ~= 'string' then return nil end
  return vim.fn.strcharpart(value:gsub('[%z\1-\8\11\12\14-\31\127]', ''), 0, 512)
end
function M.label(status)
  if status and status.state == 'save_failed' and (status.owner == 'Theme adapter' or status.owner == 'Custom theme adapter') then
    return 'Save failed · theme applied for this session'
  end
  return labels[status and status.state] or 'Storage state unavailable'
end
function M.snapshot(env)
  local profile = { path = env.profile_path, owner = 'RE35 profile', scope = env.profile_path and 'startup' or 'session',
    load_error = env.profile_error, save_error = env.profile_save_error,
    active_state = env.profile_state,
    state = env.requires_profile_reload and 'saved_not_active' or env.profile_save_error and 'save_failed'
      or env.profile_state or (env.profile_path and 'local_defaults' or 'session_only') }
  profile.label = M.label(profile)
  local result = {
    profile = profile,
    usage = { path = env.usage.path, owner = 'Recent command history', load_error = env.usage.load_error,
      save_error = env.usage.save_error, scope = env.usage.path and 'startup' or 'session' },
    preferences = { path = env.preferences.path, persistence_path = env.profile_path, owner = 'RE35 profile',
      load_error = env.preferences.load_error, save_error = env.preferences.save_error,
      scope = env.profile_path and 'startup' or 'session', state = profile.state, label = profile.label },
  }
  local theme = env.options.integrations.theme
  if type(theme) == 'table' and type(theme.persistence_status) == 'function' then
    local ok, status = pcall(theme.persistence_status)
    local owned = require('command_tree.integrations.theme_startup').is_owned(theme)
    local value = { owner = owned and 'Theme adapter' or 'Custom theme adapter' }
    if ok and type(status) == 'table' then
      for _, name in ipairs({ 'state', 'scope', 'path', 'theme', 'error' }) do value[name] = text(rawget(status, name)) end
      value.enabled = rawget(status, 'enabled') == true
    else value.state, value.error = 'restore_failed', text(ok and 'Invalid theme storage report' or tostring(status)) end
    if not owned and theme.builtin == true and theme.id == 'runtime-colorschemes'
      and theme.persistence_status == theme._builtin_persistence_status then
      -- A supplied wrapper may save elsewhere after calling builtin commit.
      -- Its inherited builtin report cannot prove the wrapper's storage scope.
      value.reported_state, value.state, value.scope = value.state, 'adapter_owned', 'adapter'
      value.label = 'Storage is owned by the custom theme adapter'
    else
      value.label = (not owned and 'Reported by custom adapter · ' or '') .. M.label(value)
    end
    result.theme = value
  else
    result.theme = { state = 'session_only', scope = 'session', owner = theme and 'Custom theme adapter' or 'Editor',
      label = theme and 'Storage is owned by the custom theme adapter' or 'Theme integration disabled' }
  end
  return result
end
function M.settings(frame)
  local status = require('re35').persistence_status().profile
  if frame and frame.data and frame.data.draft and #require('command_tree.settings.transaction').changes(frame) > 0 then
    return labels.draft .. ' · ' .. status.owner
  end
  return status.label .. ' · ' .. status.owner
end
function M.applied()
  local status = require('re35').persistence_status().profile
  return status.state == 'saved' and 'Settings saved · restored at startup'
    or status.state == 'saved_not_active' and 'Settings saved · reload required'
    or 'Settings applied in memory · this session only'
end
return M
