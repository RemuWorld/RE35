-- Neovim owns float geometry. Shared presentation widths/heights remain bounds;
-- these local panels do not add a new portable presentation contract.
local M = {}
local ns = vim.api.nvim_create_namespace('CommandTreeDetails')

function M.critical_options(data, opts)
  if opts.layout ~= 'fixed' or opts.presentation then return opts end
  if not (data.input or data.review or data.required_review or data.required_label or data.target or data.required_notice
    or type(data.required_facts) == 'table' and next(data.required_facts) ~= nil) then return opts end
  -- Factory rendering supplies the same admission/wrapping rules to ordinary
  -- local setup. This is a private display model, never a selected/saved preset.
  local density = opts.density or 'full'
  local model = assert(require('command_environment.core.presentation').resolve(nil, density))
  for _, field in ipairs({ 'width', 'max_width', 'max_height', 'position' }) do
    if opts[field] ~= nil then model.layout[field] = opts[field] end
  end
  if opts.icons ~= nil then model.information.icons = opts.icons end
  if density == 'compact' and opts.compact_rows then model.layout.rows = opts.compact_rows
  elseif density == 'minimal' and opts.minimal_rows then model.layout.rows = opts.minimal_rows end
  return vim.tbl_extend('force', {}, opts, { presentation = model, _legacy_critical = true })
end

local function bounds(opts)
  if opts.target_win and vim.api.nvim_win_is_valid(opts.target_win) then
    local pos = vim.api.nvim_win_get_position(opts.target_win)
    local bottom = math.min(vim.o.lines - vim.o.cmdheight, pos[1] + vim.api.nvim_win_get_height(opts.target_win))
    local right = math.min(vim.o.columns, pos[2] + vim.api.nvim_win_get_width(opts.target_win))
    return { top = math.max(0, pos[1]), left = math.max(0, pos[2]),
      height = math.max(1, bottom - pos[1]), width = math.max(1, right - pos[2]) }
  end
  return { top = 0, left = 0, height = math.max(1, vim.o.lines - vim.o.cmdheight - 1), width = vim.o.columns }
end

local function entries(data, opts)
  local model, output, seen = opts.presentation, {}, {}
  local full = (opts.density or 'full') == 'full'
  local info = model and model.information or {
    details = full, status = full, help = full }
  local function add(value, role)
    if type(value) ~= 'string' or value == '' or seen[value] then return end
    -- External adapter messages and descriptions are bounded independently of
    -- their author. Errors remain inspectable without unbounded render work.
    local value_prefix = vim.fn.strcharpart(value, 0, 16384)
    seen[value] = true
    for text in (value_prefix .. '\n'):gmatch('(.-)\n') do
      if #output >= 256 then break end
      output[#output + 1] = { text = text:gsub('[\r\t%z]', ' '), role = role or 'muted' }
    end
    if #value_prefix ~= #value and #output < 256 then
      output[#output + 1] = { text = '[Message truncated]', role = 'warning' }
    end
  end
  local details = data.details
  local diagnostic = data.diagnostic
  if type(diagnostic) == 'table' then
    local full = diagnostic.full_message
    if type(full) ~= 'string' and type(diagnostic.lines) == 'table' then full = table.concat(diagnostic.lines, '\n') end
    add(full or diagnostic.message, 'error')
  end
  if not diagnostic or data.message ~= diagnostic.message then add(data.message, 'warning') end
  add(data.error, 'error')
  if details then
    if details.reason and details.reason ~= data.message then add('Unavailable: ' .. details.reason, 'warning') end
    if info.details then
      add((details.kind or 'action') .. ' · ' .. (details.source or 'registered'))
      add('Target: ' .. (details.target or 'current buffer'))
      add(details.description)
    end
  end
  if info.status then add(data.status) end
  if info.help then add(data.help) end
  return output
end

function M.prepare(V, view, data, opts)
  if opts.layout ~= 'fixed' then
    view.panel_report = nil
    return data, opts
  end
  opts = M.critical_options(data, opts)
  local model = opts.presentation
  local layout = model and model.layout or opts
  local density = layout.density or 'full'
  local viewport = bounds(opts)
  local border_name = model and model.decoration.border or density == 'minimal' and 'none' or 'rounded'
  local border = border_name == 'none' and 0 or 2
  if viewport.width <= border or viewport.height <= border then border = 0 end
  local maximum = math.max(1, math.min(layout.max_width or 72, viewport.width - border))
  if not opts.target_win then maximum = math.max(1, math.min(maximum, viewport.width - border - 2)) end
  local width = math.max(1, math.min(layout.width or 48, maximum))
  local vertical = model and model.spacing.vertical or 0
  local maximum_height = math.max(1, layout.max_height or 16)
  local review = opts.presentation_scene == 'review' or data.review == true or data.required_review == true
    or type(data.required_facts) == 'table' and next(data.required_facts) ~= nil
  local interactive = data.selected ~= nil or data.query ~= nil or data.input == true or data.content ~= nil
  local desired = maximum_height
  if not review and not data.input and not data.required_label and not data.target and not data.required_notice then
    if density == 'compact' then desired = math.min(maximum_height, (layout.rows or opts.compact_rows or 6) + 3 + vertical * 2)
    elseif density == 'minimal' then
      desired = not interactive and 1 + vertical * 2
        or math.min(maximum_height, (layout.rows or opts.minimal_rows or 3) + 3 + vertical * 2)
    end
  end
  local main_height = math.max(1, math.min(desired, viewport.height - border))
  local config = opts.details or {}
  local requested = config.enabled ~= false
  local detail_border = density == 'minimal' and 0 or border
  local detail_height = math.max(1, math.min(config.max_height or 6, 32))
  -- Reserve the same footprint before there is a message. When a viewport is
  -- short, optional metadata yields to the main list and mandatory review.
  local remaining = viewport.height - main_height - border - detail_border
  local separate = requested and remaining >= 1
  detail_height = separate and math.min(detail_height, remaining) or 0
  local footprint = main_height + border + (separate and detail_height + detail_border or 0)
  local position = layout.position or 'center'
  local bottom, right = position:find('bottom', 1, true), position:find('right', 1, true)
  local top, left = position:find('top', 1, true), position:find('left', 1, true)
  local row = bottom and viewport.top + viewport.height - footprint
    or top and viewport.top + 1 or viewport.top + math.floor((viewport.height - footprint) / 2)
  local col = right and viewport.left + viewport.width - width - border - (opts.target_win and 0 or 1)
    or left and viewport.left + 1 or viewport.left + math.floor((viewport.width - width - border) / 2)
  row = math.max(viewport.top, math.min(row, viewport.top + viewport.height - footprint))
  col = math.max(viewport.left, math.min(col, viewport.left + viewport.width - width - border))
  local fixed = { width = width, height = main_height, row = row, col = col,
    border = border, detail_border = detail_border, detail_height = detail_height,
    detail_row = row + main_height + border, separate = separate,
    density = density, viewport = viewport }
  local effective = vim.tbl_extend('force', {}, opts, { _fixed_panel = fixed })
  view.panel_report = { layout = 'fixed', details = separate and 'separate' or requested and 'inline' or 'disabled',
    fallbacks = {} }
  if requested and not separate then
    view.panel_report.fallbacks[1] = { path = 'window.details', requested = 'separate', effective = 'inline',
      reason = 'Viewport has no room below the command panel; feedback stays in the main panel' }
  end
  if not separate then
    if data.diagnostic and not data.message and not data.error then
      local inline = vim.tbl_extend('force', {}, data, { error = data.diagnostic.message })
      return inline, effective
    end
    return data, effective
  end
  local split = vim.tbl_extend('force', {}, data)
  split._panel_entries = entries(data, opts)
  split.message, split.error, split.status, split.help, split.diagnostic = nil, nil, nil, nil, nil
  if review and data.details and data.details.target then
    -- Target identity is part of the reviewed operation, not optional chrome.
    split.details = { target = data.details.target, kind = data.details.kind, source = data.details.source }
  else split.details = nil end
  return split, effective
end

function M.main(view, lines, config, opts)
  local fixed = opts._fixed_panel
  if not fixed then return end
  config.width, config.height, config.row, config.col = fixed.width, fixed.height, fixed.row, fixed.col
  while #lines < fixed.height do lines[#lines + 1] = '' end
end

local function wrap(V, records, width, groups)
  local lines, roles, truncated = {}, {}, false
  for record_index, record in ipairs(records) do
    local current, chars = '', record.text
    local group = groups and groups[record.role] or 'CommandTree' .. (record.role == 'error' and 'Warning'
      or record.role == 'warning' and 'Warning' or 'Muted')
    local function emit()
      lines[#lines + 1], roles[#roles + 1] = current, group
      current = ''
    end
    for char in chars:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      if #lines >= 512 then truncated = true; break end
      if V.width(current .. char) > width then
        if current ~= '' then emit() end
        if V.width(char) > width then char = V.clip(char, width) end
      end
      current = current .. char
    end
    if #lines < 512 then emit() elseif current ~= '' then truncated = true end
    if #lines >= 512 then
      truncated = truncated or record_index < #records
      break
    end
  end
  return lines, roles, truncated
end

local function render(V, detail)
  local lines, marks = {}, {}
  local bottom = math.min(detail.total, detail.top + detail.visible - 1)
  for index = detail.top, bottom do
    local value = detail.lines[index]
    lines[#lines + 1] = string.rep(' ', detail.padding) .. value .. string.rep(' ', detail.padding)
    if #value > 0 then marks[#marks + 1] = { #lines - 1, detail.padding, detail.padding + #value, detail.roles[index] } end
  end
  while #lines < detail.visible do lines[#lines + 1] = '' end
  local config = vim.deepcopy(detail.config)
  if detail.density ~= 'minimal' and detail.total > detail.visible and config.border ~= 'none' then
    config.title = V.clip((' Details %d–%d/%d '):format(detail.top, bottom, detail.total), config.width)
    config.title_pos = 'left'
  end
  V.window(detail, lines, config)
  if detail.winhighlight then vim.wo[detail.win].winhighlight = detail.winhighlight end
  vim.api.nvim_buf_clear_namespace(detail.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(detail.buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
end

function M.draw(V, view, data, opts, groups)
  local fixed = opts._fixed_panel
  local records = data._panel_entries
  if not fixed or not fixed.separate or not records or #records == 0 then
    if view.details then
      local ok, reason = V.close(view.details)
      if not ok then return false, reason end
      view.details = nil
    end
    return true
  end
  local detail = view.details or {}
  view.details = detail
  local requested_padding = opts.presentation and opts.presentation.spacing.horizontal or fixed.density == 'minimal' and 2 or 1
  detail.padding = math.min(requested_padding, math.max(0, math.floor((fixed.width - 1) / 2)))
  local lines, roles, truncated = wrap(V, records, math.max(1, fixed.width - detail.padding * 2), groups)
  detail.truncated = truncated
  if truncated then
    view.panel_report.fallbacks[#view.panel_report.fallbacks + 1] = { path = 'window.details.content',
      requested = 'Complete bounded detail text', effective = '512 display rows',
      reason = 'Details exceed the display-row limit; enlarge this viewport to inspect more of the message' }
  end
  local identity = table.concat(lines, '\n')
  if identity ~= detail.identity then detail.top = 1 end
  detail.identity, detail.lines, detail.roles, detail.total = identity, lines, roles, #lines
  detail.visible = math.min(fixed.detail_height, math.max(1, #lines))
  detail.top = math.max(1, math.min(detail.top or 1, math.max(1, detail.total - detail.visible + 1)))
  detail.density = fixed.density
  detail.config = { relative = 'editor', row = fixed.detail_row, col = fixed.col,
    width = fixed.width, height = detail.visible,
    border = fixed.detail_border == 0 and 'none' or opts.presentation and opts.presentation.decoration.border or 'rounded',
    zindex = opts.zindex or 80 }
  if groups then detail.winhighlight = 'Normal:' .. groups.normal .. ',FloatBorder:' .. groups.accent
    .. ',FloatTitle:' .. groups.accent .. ',EndOfBuffer:' .. groups.normal end
  local ok, reason = pcall(render, V, detail)
  if not ok then
    -- A host API failure after scratch-buffer allocation cannot leave an
    -- unowned detail float behind. Keep failed handles reachable for close.
    local closed, closing_reason = V.close(detail)
    if closed then view.details = nil end
    view.panel_report.error = tostring(reason)
    if not closed then view.panel_report.error = view.panel_report.error .. '; cleanup: ' .. tostring(closing_reason) end
    error('Details panel: ' .. view.panel_report.error, 0)
  end
  return true
end

function M.scroll(V, view, delta)
  local detail = view and view.details
  if not detail or not detail.win or not vim.api.nvim_win_is_valid(detail.win) then return false end
  if type(delta) ~= 'number' or delta ~= delta then return false end
  detail.top = math.max(1, math.min(detail.top + math.floor(delta), math.max(1, detail.total - detail.visible + 1)))
  render(V, detail)
  vim.cmd.redraw()
  return true
end

return M
