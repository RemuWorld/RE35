-- Optional Neovim shortcut panel. It consumes spare cells to the right without
-- moving the command panel; the existing below-panel help is the fallback.
local M = {}
local ns = vim.api.nvim_create_namespace('CommandTreeGuide')
local Keys = require('command_tree.session.key_guide')
local Text = require('command_tree.view.text_layout')
local guide_width, padding = 30, 1

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

local function hints_for(source, scroll)
  -- Typed controls retain the actual configured keys. Unknown adapter prose
  -- remains below; only the established built-in help grammar is parsed.
  local supplied = source.hints
  if supplied == nil then supplied = Keys.help_hints(source.help) end
  if type(supplied) ~= 'table' then return nil end
  local count = 0
  for index in pairs(supplied) do
    count = count + 1
    if count > 32 or type(index) ~= 'number' or index < 1 or index % 1 ~= 0 then return nil end
  end
  if count == 0 or count ~= #supplied then return nil end
  local hints = {}
  for _, hint in ipairs(supplied) do hints[#hints + 1] = hint end
  if scroll then
    if type(scroll) ~= 'table' or type(scroll.key) ~= 'string' or type(scroll.label) ~= 'string' then return nil end
    local found = false
    for _, hint in ipairs(hints) do
      if type(hint) == 'table' and type(hint.key) == 'string'
        and Keys.hint_key(hint.key) == Keys.hint_key(scroll.key) and hint.label == scroll.label then found = true end
    end
    if not found then hints[#hints + 1] = scroll end
  end
  if #hints > 32 then return nil end
  return hints
end

-- Wrap descriptions by display cells, retaining every character of long words
-- and Unicode labels. Key chords never pass through this wrapping function.
local function wrap_label(V, label, width)
  return Text.wrap(label, width, V.width)
end

local function hint_rows(V, source, scroll, groups)
  local hints = hints_for(source, scroll)
  if not hints then return nil end
  local ordered, buckets, key_width = {}, {}, 0
  local inner_width = guide_width - padding * 2
  for _, hint in ipairs(hints) do
    if type(hint) ~= 'table' or type(hint.key) ~= 'string' or type(hint.label) ~= 'string'
      or hint.key == '' or not hint.label:find('%S')
      or #hint.key > 128 or #hint.label > 256 or hint.key:find('[\r\n\t%z]')
      or hint.label:find('[\r\n\t%z]') or hint.group ~= nil and type(hint.group) ~= 'string' then return nil end
    local category = hint.group or 'information'
    if not buckets[category] then buckets[category] = {}; ordered[#ordered + 1] = category end
    local key = Keys.hint_key(hint.key)
    if V.width(key) > inner_width then return nil end
    buckets[category][#buckets[category] + 1] = { key = key, label = hint.label }
    key_width = math.max(key_width, V.width(key))
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
      -- A wide remapped chord gets its own row, so it cannot squeeze its
      -- description into a thin column or change this panel's fixed width.
      local inline = inner_width - key_width - 2 >= 8
      local indent = inline and key_width + 2 or 2
      local labels = wrap_label(V, hint.label, inner_width - indent)
      if not inline then line(hint.key, { { 0, #hint.key, role('accent', groups) } }) end
      for label_index, label in ipairs(labels) do
        local first = inline and label_index == 1
        local prefix = first and hint.key .. string.rep(' ', indent - V.width(hint.key))
          or string.rep(' ', indent)
        local spans = { { #prefix, #prefix + #label, role('normal', groups) } }
        if first then spans[#spans + 1] = { 0, #hint.key, role('accent', groups) } end
        line(prefix .. label, spans)
      end
    end
  end
  return rows, marks, guide_width
end

local function report(view, placement, reason)
  if not view.panel_report then return end
  view.panel_report.guide = placement
  if reason then
    view.panel_report.fallbacks[#view.panel_report.fallbacks + 1] = {
      path = 'window.guide', requested = 'right', effective = 'below', reason = reason }
  end
end

local function without_help(data)
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

-- The same pure placement decision is used for drawing and fresh admission.
-- Planning never allocates or closes a view, even if a previous guide exists.
function M.plan(V, data, opts, source, groups)
  local fixed, model = opts._fixed_panel, opts.presentation
  local density = model and model.layout.density or opts.density or 'full'
  local help = model and model.information.help or not model and density == 'full'
  if not fixed or density ~= 'full' or not help
    or type(source.help) ~= 'string' and type(source.hints) ~= 'table' then
    return data, { placement = help and (source.help or source.hints) and 'below' or 'hidden' }
  end
  if opts._guide_fallback then
    return data, { placement = 'below', reason = 'Shortcut panel failed during the current draw; help remains below' }
  end
  local scroll = data._panel_scroll_hint or opts._details_hint
  local rows, marks, width = hint_rows(V, source, scroll, groups)
  if not rows then
    return data, { placement = 'below' }
  end
  local viewport, border = fixed.viewport, fixed.border
  local col = fixed.guide_col or fixed.col + fixed.width + border + 1
  local right = viewport.left + viewport.width
  local bottom = viewport.top + viewport.height
  local row = fixed.row
  if opts.guide_anchor == 'group' then row = math.max(viewport.top, math.min(row, bottom - #rows - border)) end
  -- Keep complete controls: labels may add rows, while an impossible chord or
  -- viewport returns every original group to the existing below-panel path.
  if col < viewport.left or col + width + border > right or row + #rows + border > bottom then
    return data, { placement = 'below', reason = 'Complete shortcut groups do not fit beside the command panel' }
  end
  local config = { relative = 'editor', row = row, col = col, width = width, height = #rows,
    border = border == 0 and 'none' or model and model.decoration.border or 'rounded', zindex = opts.zindex or 80 }
  if border > 0 then config.title, config.title_pos = ' Keys ', 'left' end
  return without_help(data), { placement = 'right', rows = rows, marks = marks, config = config }
end

function M.prepare(V, view, data, opts, source, groups)
  local prepared, plan = M.plan(V, data, opts, source, groups)
  if plan.placement ~= 'right' then
    remove(V, view)
    report(view, plan.placement, plan.reason)
    return prepared, opts
  end
  local guide = view.guide or {}
  view.guide = guide
  local ok, reason = pcall(function()
    V.window(guide, plan.rows, plan.config)
    if groups then
      vim.wo[guide.win].winhighlight = 'Normal:' .. groups.normal .. ',FloatBorder:' .. (groups.border or groups.accent)
        .. ',FloatTitle:' .. groups.accent .. ',EndOfBuffer:' .. groups.normal
    end
    vim.api.nvim_buf_clear_namespace(guide.buf, ns, 0, -1)
    for _, mark in ipairs(plan.marks) do
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
    -- Retain the actual fallback in the cached view options. A later fresh
    -- admission may not assume help was extracted into a failed guide. The
    -- next normal redraw plans again from its newly supplied source options.
    return data, vim.tbl_extend('force', {}, opts, { _guide_fallback = true })
  end
  report(view, 'right')
  return prepared, opts
end

return M
