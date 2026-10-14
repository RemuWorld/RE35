-- Optional Neovim shortcut panel. It consumes spare cells to the right without
-- moving the command panel; the existing below-panel help is the fallback.
local M = {}
local ns = vim.api.nvim_create_namespace('CommandTreeGuide')
local Keys = require('command_tree.session.key_guide')

local function close(V, view)
  if not view.guide then return true end
  local ok, reason = V.close(view.guide)
  if ok then view.guide = nil end
  return ok, reason
end

local function remove(V, view, render_error)
  local ok, reason = close(V, view)
  if ok then return end
  local failure = 'Shortcut panel cleanup failed: ' .. tostring(reason)
    .. (render_error and '; render: ' .. tostring(render_error) or '')
  if view.panel_report then
    view.panel_report.guide, view.panel_report.guide_error = 'cleanup-failed', failure
  end
  -- The guide retains its handles. The main draw's containment retries close;
  -- a persistent host failure remains owned and observable, never "hidden".
  error(failure, 0)
end

local function role(name, groups)
  return groups and groups[name] or ({ normal = 'CommandTreeDesc', accent = 'CommandTreeKey',
    muted = 'CommandTreeMuted' })[name]
end

local function hint_rows(V, source, scroll, groups)
  -- Unknown adapter prose remains below. Parse only the already supported
  -- built-in grammar instead of guessing where custom text contains keys.
  local hints = Keys.help_hints(source.help)
  if not hints then return nil end
  if scroll then
    if type(scroll) ~= 'table' or type(scroll.key) ~= 'string' or type(scroll.label) ~= 'string' then return nil end
    local found = false
    for _, hint in ipairs(hints) do
      if hint.key == Keys.hint_key(scroll.key) and hint.label == scroll.label then found = true end
    end
    if not found then hints[#hints + 1] = scroll end
  end
  if #hints > 32 then return nil end
  local ordered, buckets, key_width, label_width = {}, {}, 0, 0
  for _, hint in ipairs(hints) do
    if type(hint.key) ~= 'string' or type(hint.label) ~= 'string'
      or #hint.key > 128 or #hint.label > 256 or hint.key:find('[\r\n\t%z]')
      or hint.label:find('[\r\n\t%z]') then return nil end
    local category = hint.group or 'information'
    if not buckets[category] then buckets[category] = {}; ordered[#ordered + 1] = category end
    local key = Keys.hint_key(hint.key)
    buckets[category][#buckets[category] + 1] = { key = key, label = hint.label }
    key_width, label_width = math.max(key_width, V.width(key)), math.max(label_width, V.width(hint.label))
  end
  local rows, marks = {}, {}
  local function line(text, spans)
    local row = #rows
    rows[#rows + 1] = ' ' .. text .. ' '
    for _, span in ipairs(spans or {}) do
      marks[#marks + 1] = { row, span[1] + 1, span[2] + 1, span[3] }
    end
  end
  for index, category in ipairs(ordered) do
    if index > 1 then line('') end
    local heading = ({ navigation = 'Navigation', information = 'Information', actions = 'Actions' })[category]
      or 'Information'
    line(heading, { { 0, #heading, role('normal', groups) } })
    for _, hint in ipairs(buckets[category]) do
      local key = hint.key .. string.rep(' ', key_width - V.width(hint.key)) .. '  '
      line(key .. hint.label, { { 0, #hint.key, role('accent', groups) },
        { #key, #key + #hint.label, role('normal', groups) } })
    end
  end
  return rows, marks, math.max(20, key_width + label_width + 4)
end

local function report(view, placement, reason)
  if not view.panel_report then return end
  view.panel_report.guide = placement
  if reason then
    view.panel_report.fallbacks[#view.panel_report.fallbacks + 1] = {
      path = 'window.guide', requested = 'right', effective = 'below', reason = reason }
  end
end

function M.prepare(V, view, data, opts, source, groups)
  local fixed, model = opts._fixed_panel, opts.presentation
  local density = model and model.layout.density or opts.density or 'full'
  local help = model and model.information.help or not model and density == 'full'
  if not fixed or density ~= 'full' or not help or type(source.help) ~= 'string' then
    remove(V, view)
    report(view, help and source.help and 'below' or 'hidden')
    return data
  end
  local scroll = data._panel_scroll_hint or opts._details_hint
  local rows, marks, width = hint_rows(V, source, scroll, groups)
  if not rows then
    remove(V, view)
    report(view, 'below')
    return data
  end
  local viewport, border = fixed.viewport, fixed.border
  local col = fixed.col + fixed.width + border + 1
  local right = viewport.left + viewport.width
  local bottom = viewport.top + viewport.height
  -- No truncation: a complete chord and label form one row. If the whole guide
  -- cannot fit, all hint groups keep the existing below-panel representation.
  if width > 44 or col + width + border > right or fixed.row + #rows + border > bottom then
    remove(V, view)
    report(view, 'below', 'Complete shortcut groups do not fit beside the command panel')
    return data
  end
  local guide = view.guide or {}
  view.guide = guide
  local config = { relative = 'editor', row = fixed.row, col = col, width = width, height = #rows,
    border = border == 0 and 'none' or model and model.decoration.border or 'rounded', zindex = opts.zindex or 80 }
  if border > 0 then config.title, config.title_pos = ' Keys ', 'left' end
  local ok, reason = pcall(function()
    V.window(guide, rows, config)
    if groups then
      vim.wo[guide.win].winhighlight = 'Normal:' .. groups.normal .. ',FloatBorder:' .. groups.accent
        .. ',FloatTitle:' .. groups.accent .. ',EndOfBuffer:' .. groups.normal
    end
    vim.api.nvim_buf_clear_namespace(guide.buf, ns, 0, -1)
    for _, mark in ipairs(marks) do
      if mark[3] > mark[2] then
        vim.api.nvim_buf_set_extmark(guide.buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
      end
    end
  end)
  if not ok then
    remove(V, view, reason)
    report(view, 'below', 'Shortcut panel could not be opened; help remains below')
    if view.panel_report then
      view.panel_report.guide_error = tostring(reason)
    end
    return data
  end
  report(view, 'right')
  local prepared = vim.tbl_extend('force', {}, data)
  prepared.help, prepared.hints, prepared._panel_scroll_hint = nil, nil, nil
  if data._panel_entries then
    prepared._panel_entries = {}
    for _, entry in ipairs(data._panel_entries) do
      if not entry.hints then prepared._panel_entries[#prepared._panel_entries + 1] = entry end
    end
  end
  return prepared
end

return M
