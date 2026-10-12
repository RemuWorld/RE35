-- UI settings author profile overrides; theme preview remains provider-owned.
local M = {}
local C = require("command_tree.settings.common")
local CE, display = C.CE, C.display
local profile, registry, add = C.profile, C.registry, C.add
local T = require("command_tree.settings.transaction")
local I = require("command_tree.settings.input")
local edit = I.edit
local changes = T.changes
local ui = {
  { id = "density", label = "Density", kind = "select", items = { "full", "compact", "minimal" }, fallback = "full" },
  { id = "icons", label = "Icons", kind = "boolean", fallback = true },
  { id = "width", label = "Width", kind = "number", fallback = 48 },
  { id = "max_width", label = "Maximum width", kind = "number", fallback = 88 },
  { id = "max_height", label = "Maximum height", kind = "number", fallback = 16 },
  { id = "position", label = "Position", kind = "select", items = { "center", "bottom", "bottom-right", "top", "top-right" }, fallback = "center" },
  { id = "compact_rows", label = "Compact rows", kind = "number", fallback = 6 },
  { id = "minimal_rows", label = "Minimal rows", kind = "number", fallback = 3 },
}
local function ui_value(frame, data, spec)
  if data.ui[spec.id] ~= nil then return data.ui[spec.id] end
  local effective = frame.data.draft and CE().ui_defaults and CE().ui_defaults() or frame.data.window or {}
  if effective[spec.id] ~= nil then return effective[spec.id] end
  return spec.fallback
end
local function reset_all(frame)
  local ok, result = T.stage(frame, function(data) data.ui = vim.empty_dict() end)
  if not ok then return false, result end
  -- Earlier field edits must not describe the newly reset draft with their old
  -- proposed values. Other sections retain their own review annotations.
  local defaults = CE().ui_defaults()
  for _, spec in ipairs(ui) do
    local key, before = "ui." .. spec.id, frame.data.base.ui[spec.id]
    local inherited = defaults[spec.id]
    if inherited == nil then inherited = spec.fallback end
    frame.data.notes[key] = before ~= nil and {
      label = "UI · " .. spec.label, before = display(before),
      after = "Default (" .. display(inherited) .. ")",
    } or nil
  end
  return true, changes(frame)
end
function M.items(frame, session)
  if require('command_tree.settings.presentation').handles(frame.data) then
    return require('command_tree.settings.presentation').items(frame, session)
  end
  local data, result = profile(frame), {}
  local commands = registry(session)
    local theme = commands:get("ui.theme")
    if theme then
      local current = vim.g.colors_name
      local field = theme.arguments and theme.arguments[1]
      if not current and field then
        local ok, value = pcall(require("command_tree.arguments").default, field, frame.ctx or session.ctx, {})
        if ok then current = value end
      end
      local ok, available, why = pcall(commands.available, commands, theme.id, frame.ctx or session.ctx)
      add(result, "theme", "Theme", current or "Default", { disabled = not ok or not available,
        reason = not ok and tostring(available) or not available and why or nil,
        detail = "Uses the theme provider's preview and commit; separate from profile drafts and settings Undo" })
    end
    add(result, '__presentation__', 'Presentation presets', nil, { detail = 'Create, edit and share named UI modes; review before Apply' })
    for _, spec in ipairs(ui) do add(result, spec.id, spec.label, ui_value(frame, data, spec), { field = spec }) end
    add(result, "__reset_all__", "Reset all UI overrides", nil, {
      detail = "Inherit local UI settings and saved density; review before Apply. Settings Undo restores the previous overrides." })
    if commands:get('settings.ui_export') then
      local pending = frame.data.draft and #changes(frame) > 0
      add(result, '__export__', 'Export UI settings', nil, { disabled = pending,
        reason = pending and 'Apply or discard the Settings draft before exporting UI settings' or nil })
    end
    if commands:get('settings.ui_import') then
      local pending = frame.data.draft and #changes(frame) > 0
      add(result, '__import__', 'Import UI settings', nil, { disabled = pending,
        reason = pending and 'Apply or discard the Settings draft before importing UI settings' or nil,
        detail = 'Read a UI settings file, review changes, then Apply. Settings Undo restores the previous overrides.' })
    end

  return result
end
function M.activate(frame, ctx, session, item)
    if require('command_tree.settings.presentation').handles(frame.data) then
      return require('command_tree.settings.presentation').activate(frame, ctx, session, item)
    end
    if item.id == '__presentation__' then frame.data.detail, frame.data.selected, frame.data.selected_id = 'presentation', 1, nil; return true end
    if item.id == '__import__' then return require('command_tree.settings.ui_import').import(frame, ctx, session) end
    if item.id == '__export__' then
      if frame.data.draft and #changes(frame) > 0 then return false, 'Apply or discard the Settings draft before exporting UI settings' end
      return session.workspace_execute('settings.ui_export', nil, ctx)
    end
    if item.id == "__reset_all__" then return reset_all(frame) end
    if item.id == "theme" then
      if frame.data.draft and #changes(frame) > 0 then return false, "Apply or discard the settings draft before previewing a theme" end
      if item.disabled then return false, item.reason or "Theme provider is unavailable" end
      return session.workspace_execute("ui.theme", nil, ctx)
    end
    local spec = item.field
    return edit(frame, ctx, session, { prompt = spec.label, kind = spec.kind, items = spec.items, default = item.value, min = 1 },
      function(candidate, value) candidate.ui[spec.id] = value end,
      { id = "ui." .. spec.id, label = "UI · " .. spec.label, before = item.value })

end
function M.reset(frame, _, session, item)
    if require('command_tree.settings.presentation').handles(frame.data) then
      return require('command_tree.settings.presentation').reset(frame, nil, session, item)
    end
    if item.id == '__presentation__' then return false, 'Open Presentation presets to reset an override' end
    if item.id == '__import__' then return false, 'Enter imports UI settings for review; this row has no override to reset' end
    if item.id == '__export__' then return false, 'Enter exports the applied UI settings; this row has no override to reset' end
    if item.id == "__reset_all__" then return reset_all(frame) end
    if item.id == "theme" then return false, "Themes use the theme provider's preview and commit" end
    local defaults = CE().ui_defaults and CE().ui_defaults() or {}
    local inherited = defaults[item.id]
    if inherited == nil then inherited = item.field.fallback end
    return T.stage(frame, function(data) data.ui[item.id] = nil end,
      { id = "ui." .. item.id, label = "UI · " .. item.label, before = item.value,
        after = "Default (" .. display(inherited) .. ")" })

end
return M
