-- Typed confirmations are short-lived, neutral host UI. They never consume the
-- navigation title or change the geometry of the command/details panels.
local M = {}
local lifetime = 3000
local function now() return vim.uv.hrtime() / 1000000 end

function M.cancel(view)
  local timer = view.status_timer
  view.status_notice, view.status_fallback_owner = nil, nil
  if not timer then return true end
  local ok, why = pcall(function()
    if not timer:is_closing() then timer:stop(); timer:close() end
  end)
  if ok then view.status_timer = nil end
  return ok, not ok and tostring(why) or nil
end

local function remove(V, view)
  if not view.status then return end
  local ok, why = V.close(view.status)
  if not ok then error('Status panel cleanup failed: ' .. tostring(why), 0) end
  view.status = nil
end

function M.prepare(V, data, opts, view)
  local notice = data.notice
  if type(notice) ~= 'table' or type(notice.message) ~= 'string' or type(notice.summary) ~= 'string'
    or notice.message ~= data.message then return data end
  local copy = vim.tbl_extend('force', {}, data)
  copy.message = nil
  local retained = view and view.status_notice
  if retained and retained.owner == notice and (retained.expired or now() >= retained.deadline) then return copy end
  local model = opts.presentation
  local density = model and model.layout.density or opts.density or 'full'
  -- Local Compact has always shown neutral save confirmations, independently
  -- of its reduced inline metadata. Only authored presets explicitly control
  -- this through information.status; normalization must retain that difference.
  local info = model and not (opts._display and opts._display.source == 'legacy') and model.information or nil
  if density == 'minimal' and not (info and info.status) or info and not info.status then return copy end
  if data.diagnostic or data.error then
    copy.message, copy.message_role = notice.message, 'normal'
    return copy
  end
  local viewport_width = opts.target_win and vim.api.nvim_win_is_valid(opts.target_win)
    and vim.api.nvim_win_get_width(opts.target_win) or vim.o.columns
  local available = math.min(model and model.layout.width or opts.width or 48, viewport_width - 2)
  if available < 24 then copy.message, copy.message_role = notice.message, 'normal'
  else copy.top_status, copy._status_notice = V.clip(notice.summary, 80), notice end
  return copy
end

local function fallback(view, data)
  local notice = data._status_notice
  if not notice then return end
  if data._panel_entries then
    data._panel_entries[#data._panel_entries + 1] = { text = notice.message, role = 'normal' }
  elseif view.status_fallback_owner ~= notice then
    -- The main buffer is already drawn. With details disabled or no spare
    -- rows, use the host's informational channel once instead of losing the
    -- confirmation or resizing/repositioning navigation after rendering.
    view.status_fallback_owner = notice
    vim.notify(notice.message, vim.log.levels.INFO, { title = 'RE35' })
  end
end

function M.draw(V, view, data, opts, groups)
  if not data.top_status then remove(V, view); return end
  local config = vim.api.nvim_win_get_config(view.win)
  local origin = opts._fixed_panel and opts._fixed_panel.viewport.top or 0
  if not opts._fixed_panel and opts.target_win and vim.api.nvim_win_is_valid(opts.target_win) then
    origin = vim.api.nvim_win_get_position(opts.target_win)[1]
  end
  if config.row <= origin then remove(V, view); fallback(view, data); return end
  local retained = view.status_notice
  if not retained or retained.owner ~= data._status_notice then
    local ok, why = M.cancel(view)
    if not ok then error('Status timer cleanup failed: ' .. tostring(why), 0) end
    retained = { owner = data._status_notice, deadline = now() + lifetime }
    view.status_notice = retained
  end
  if retained.expired or now() >= retained.deadline then remove(V, view); return end
  local panel = view.status or {}
  view.status = panel
  local ok, why = pcall(function()
    V.window(panel, { V.clip(' ' .. data.top_status, config.width) }, {
      relative = 'editor', row = config.row - 1, col = config.col, width = config.width,
      height = 1, border = 'none', zindex = (opts.zindex or 80) + 1 })
    local normal = groups and groups.normal or 'CommandTreeDesc'
    vim.wo[panel.win].winhighlight = 'Normal:' .. normal .. ',EndOfBuffer:' .. normal
  end)
  if not ok then remove(V, view); fallback(view, data); view.status_error = tostring(why); return end
  view.status_error, view.status_fallback_owner = nil, nil
  if not view.status_timer then
    view.status_timer = vim.defer_fn(function()
      -- A callback from a previous notice/closed session owns no current UI.
      if view.status_notice ~= retained then return end
      view.status_timer, retained.expired = nil, true
      local closed, reason = V.close(view.status)
      if closed then view.status = nil
      elseif not closed then view.status_error = 'Status panel cleanup failed: ' .. tostring(reason) end
    end, math.max(1, math.ceil(retained.deadline - now())))
  end
end
return M
