-- Neovim rendering of the negotiated presentation model; no execution state.
local P = {}
local ns = vim.api.nvim_create_namespace('CommandTreeUI')

local function geometry(V, data, opts)
  local model, K = opts.presentation, require('command_tree.keys')
  local layout, information = model.layout, model.information
  local density = layout.density
  local review = opts.presentation_scene == 'review' or data.review == true or data.required_review == true
  local target
  if opts.target_win and vim.api.nvim_win_is_valid(opts.target_win) then
    local pos = vim.api.nvim_win_get_position(opts.target_win)
    local bottom = math.min(vim.o.lines - vim.o.cmdheight, pos[1] + vim.api.nvim_win_get_height(opts.target_win))
    local right = math.min(vim.o.columns, pos[2] + vim.api.nvim_win_get_width(opts.target_win))
    target = { top = math.max(0, pos[1]), left = math.max(0, pos[2]),
      width = math.max(1, right - pos[2]), height = math.max(1, bottom - pos[1]) }
  end
  local requested_border = model.decoration.border
  local border = requested_border == 'none' and 0 or 2
  if target and (target.width <= border or target.height <= border) then border = 0 end
  if opts._fixed_panel then border = opts._fixed_panel.border end
  local available_width = math.max(1, target and target.width - border or vim.o.columns - border - 2)
  local window_limit = math.max(1, math.min(available_width, layout.max_width))
  local padding = math.min(model.spacing.horizontal, math.max(0, math.floor((window_limit - 1) / 2)))
  if opts._fixed_panel then padding = math.min(padding, math.max(0, math.floor((opts._fixed_panel.width - 1) / 2))) end
  local limit = math.max(1, window_limit - padding * 2)
  local width = math.max(1, math.min(limit, layout.width - padding * 2))
  local path = tostring(data.path or '\\')
  width = math.min(limit, math.max(width, V.width(path) + 4))
  if density ~= 'minimal' then
    for _, item in ipairs(data.items or {}) do
      local detail = information.details and (item.disabled and item.reason or item.detail) or ''
      width = math.min(limit, math.max(width, V.width(K.label(item.key or ''))
        + V.width(item.name or '') + V.width(detail or '') + 8))
      if width == limit then break end
    end
  end
  if opts._fixed_panel then width = math.max(1, opts._fixed_panel.width - padding * 2) end
  local max_height = math.max(1, math.min(layout.max_height,
    target and target.height - border or vim.o.lines - vim.o.cmdheight - border - 1))
  if opts._fixed_panel then max_height = opts._fixed_panel.height end
  local vertical = math.min(model.spacing.vertical, math.max(0, math.floor((max_height - 2) / 2)))
  local body_height = math.max(1, max_height - vertical * 2)
  return { target = target, border = border, requested_border = requested_border, padding = padding,
    width = width, max_height = max_height, vertical = vertical, body_height = body_height,
    path = path, density = density, review = review }
end

local incomplete = 'Review facts do not fit this viewport; enlarge it or reduce presentation spacing'
local function wrapped_rows(V, text, width, maximum)
  if type(text) ~= 'string' then return nil end
  text = text:gsub('[\r\n\t]', ' ')
  local prefix = vim.fn.strcharpart(text, 0, 4096)
  if #prefix ~= #text then return nil end
  local current, rows = '', 1
  for char in prefix:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if V.width(char) > width then return nil end
    if V.width(current .. char) > width then
      rows, current = rows + 1, ''
      if rows > maximum then return nil end
    end
    current = current .. char
  end
  return rows
end

local function preflight(V, data, opts, prepared, page_size)
  local review, width, height = prepared.review, prepared.width, prepared.body_height
  local groups, items = data.required_facts or {}, data.items or {}
  if type(groups) ~= 'table' then return false, incomplete, 1 end
  local active = review or next(groups) ~= nil
  local facts = data.required_label or data.target or data.required_notice
  if not active and not facts then return true, nil, page_size end
  if not vim.islist(groups) or review and not vim.islist(items) then return false, incomplete, 1 end
  local complete, common, longest = true, 1, 1
  local costs = {}
  local function cost(text)
    if costs[text] ~= nil then return costs[text] or height + 1 end
    local rows = wrapped_rows(V, text, width, height)
    costs[text] = rows or false
    if not rows then complete = false; return height + 1 end
    return rows
  end
  if not active then
    for _, text in ipairs({ data.required_label or false, data.target and 'Target: ' .. data.target or false,
      data.required_notice or false }) do
      if text then common = common + cost(text) end
    end
    if data.query ~= nil then common = common + 1 end
    if not complete or common + 1 > height then
      return false, 'Required source or owner facts do not fit this viewport; enlarge it or reduce presentation spacing', 1
    end
    return true, nil, math.max(1, math.min(page_size, height - common))
  end
  if review and data.input and data.label then common = common + cost(data.label) end
  if review and data.details then common = common + cost('Target: ' .. (data.details.target or 'current buffer')) end
  if data.query ~= nil then common = common + 1 end
  -- Each additional group is one inspectable page of atomic Before/After facts.
  -- Its line boundaries count, independently of the currently selected change.
  local footer_rows = data.required_footer and cost(data.required_footer) or 1
  local group_capacity = height - common - 1 - footer_rows
  for _, group in ipairs(groups) do
    local rows = 0
    if type(group) == 'string' then rows = cost(group)
    elseif type(group) == 'table' and vim.islist(group) then
      for _, text in ipairs(group) do
        rows = rows + cost(text)
        if rows > group_capacity then return false, incomplete, 1 end
      end
    else complete, rows = false, height + 1 end
    if rows > group_capacity then return false, incomplete, 1 end
  end
  if review then
    for _, text in ipairs(data.content or {}) do
      common = common + cost(tostring(text))
      if common > height then return false, incomplete, 1 end
    end
    local capacity = height - common - (#items > 1 and 1 or 0)
    local K = require('command_tree.keys')
    for _, item in ipairs(items) do
      local key = item.current and '↵' or K.label(item.key or '')
      local text = '› ' .. (key ~= '' and key .. ' ' or '') .. (item.name or '')
      local rows = cost(text)
      longest = math.max(longest, rows)
      if rows > capacity then return false, incomplete, 1 end
    end
    if common > height then complete = false end
    -- rows is a ceiling. Wrapped values get fewer peers on each page, while
    -- every page uses the same bound and selection cannot clear a refusal.
    page_size = math.max(1, math.min(page_size, math.floor(math.max(0, capacity) / longest)))
  end
  if complete then return true, nil, page_size end
  return false, incomplete, page_size
end

function P.required_status(V, data, opts)
  if not opts or not opts.presentation then return true end
  local prepared_data, prepared_opts = require('command_tree.view.panels').prepare(V, {}, data or {}, opts)
  return preflight(V, prepared_data, prepared_opts, geometry(V, prepared_data, prepared_opts), opts.presentation.layout.rows)
end

function P.draw(V, view, data, opts, groups)
  local model, K = opts.presentation, require('command_tree.keys')
  local layout, information = model.layout, model.information
  local prepared = geometry(V, data, opts)
  local target, border, requested_border, padding = prepared.target, prepared.border, prepared.requested_border, prepared.padding
  local width, max_height, vertical, body_height = prepared.width, prepared.max_height, prepared.vertical, prepared.body_height
  local path, density, review = prepared.path, prepared.density, prepared.review
  view.presentation_report = vim.deepcopy(opts.presentation_report or { contract_version = 1,
    host = 'neovim', preset_id = model.id, preset_name = model.name, scene = opts.presentation_scene, fallbacks = {} })
  local function fallback(path, requested, effective, reason)
    view.presentation_report.fallbacks[#view.presentation_report.fallbacks + 1] = {
      path = path, requested = requested, effective = effective, reason = reason }
  end
  if border == 0 and requested_border ~= 'none' then
    fallback('decoration.border', requested_border, 'none', 'Source viewport has no room for decorative borders')
  end
  if padding ~= model.spacing.horizontal then
    fallback('spacing.horizontal', model.spacing.horizontal, padding, 'Horizontal spacing yields to readable content cells')
  end
  if vertical ~= model.spacing.vertical then
    fallback('spacing.vertical', model.spacing.vertical, vertical, 'Vertical spacing yields to content in short viewports')
  end
  if information.icons and (width < 28 or data.input or review) then
    fallback('information.icons', true, false, 'Decorative item icons yield to input, review or narrow content')
  end
  view.visible_first, view.visible_last = nil, nil
  view.presentation_review_complete, view.presentation_review_reason = review and true or nil, nil
  view.presentation_options = vim.deepcopy(opts)
  view.presentation_input_complete, view.presentation_input_reason = data.input and true or nil, nil
  view.presentation_facts_complete, view.presentation_facts_reason = (data.required_label or data.target or data.required_notice) and true or nil, nil
  local lines, marks, priorities, indices, critical = {}, {}, {}, {}, {}
  local function refuse(kind)
    if kind == 'review' then
      view.presentation_review_complete = false
      view.presentation_review_reason = incomplete
    elseif kind == 'input' then
      view.presentation_input_complete = false
      view.presentation_input_reason = 'Required input facts do not fit this viewport; enlarge it or reduce presentation spacing'
    elseif kind == 'facts' then
      view.presentation_facts_complete = false
      view.presentation_facts_reason = 'Required source or owner facts do not fit this viewport; enlarge it or reduce presentation spacing'
    end
  end
  local function line(chunks, priority, item_index, required)
    local value, complete = '', ''
    for _, chunk in ipairs(chunks) do
      complete = complete .. tostring(chunk[1])
      local text = V.clip(chunk[1], math.max(0, width - V.width(value)))
      if #text > 0 then marks[#marks + 1] = { #lines, #value, #value + #text, chunk[2] or groups.normal } end
      value = value .. text
    end
    lines[#lines + 1], priorities[#lines + 1], indices[#lines + 1] = value, priority or 1, item_index or false
    critical[#lines] = required or review and item_index ~= nil and 'review' or false
    if critical[#lines] and V.width(complete) > width then refuse(critical[#lines]) end
  end
  local function required_line(text, role, priority, item_index, kind)
    text = tostring(text):gsub('[\r\n\t]', ' ')
    local prefix = vim.fn.strcharpart(text, 0, 4096)
    if #prefix ~= #text then refuse(kind) end
    local current, generated = '', 0
    -- Once a critical block exceeds the viewport, it is already incomplete.
    -- Keep one extra row for that refusal, rather than allocating thousands of
    -- wrapped rows that the priority trimmer would repeatedly scan/remove.
    local row_limit = body_height + 1
    local function emit()
      if generated >= row_limit then refuse(kind); return false end
      line({ { current, role } }, priority, item_index, kind)
      generated = generated + 1
      return true
    end
    for char in prefix:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      if V.width(current .. char) > width then
        if current ~= '' then
          if not emit() then return end
          current = ''
          if generated >= row_limit then refuse(kind); return end
        end
        if V.width(char) > width then refuse(kind); char = V.clip(char, width) end
      end
      current = current .. char
    end
    emit()
  end
  local repeated_reason = data.details and data.details.reason and data.details.reason == data.message
  local show_details = (information.details or review) and data.details ~= nil
  local reason = data.details and data.details.reason
  local path_rows = 1 + (data.query ~= nil and 1 or 0) + (information.title and border == 0 and 1 or 0)
    + (data.input and data.label and 1 or 0)
  for _, text in ipairs({ data.required_label or false, data.target and 'Target: ' .. data.target or false,
    data.required_notice or false }) do
    if text then path_rows = path_rows + (wrapped_rows(V, text, width, body_height) or body_height + 1) end
  end
  local help_rows = information.help and data.help
    and require('command_tree.view.panels').help_rows(V, data, width, groups) or nil
  local metadata_rows = (show_details and 2 or 0) + (data.details and (reason or show_details) and not repeated_reason and 1 or 0)
    + (information.status and data.status and 1 or 0) + (information.help and data.help and (help_rows and #help_rows or 1) or 0)
    + (data.message and 1 or 0) + (data.error and 1 or 0) + (model.decoration.separator and 1 or 0)
  local page_size = math.max(1, math.min(layout.rows, layout.max_height,
    body_height - path_rows - metadata_rows - (#(data.content or {}))))
  if (information.status or review) and #(data.items or {}) > page_size then
    -- A paging row is real chrome only for modes that actually display one.
    page_size = math.max(1, math.min(page_size,
      body_height - path_rows - metadata_rows - (#(data.content or {})) - 1))
  end
  if review or data.required_facts and next(data.required_facts) ~= nil then
    view.presentation_review_complete, view.presentation_review_reason, page_size = preflight(V, data, opts, prepared, page_size)
  end
  local interactive = data.selected ~= nil or data.query ~= nil or data.input == true or data.content ~= nil or review
  local items = data.items or {}
  local show_items = density ~= 'minimal' or interactive
  local pages = show_items and math.max(1, math.ceil(#items / page_size)) or 1
  data.page = data.selected and math.ceil(math.max(1, data.selected) / page_size) or data.page or 1
  data.page = math.max(1, math.min(data.page, pages))
  if information.title and border == 0 then line({ { data.title or 'Commands', groups.accent } }, 1) end
  line({ { path, groups.accent }, { information.details and not data.input and not data.required_label and data.label and '   ' .. data.label or '', groups.muted } }, 4)
  if data.required_label then required_line(data.required_label, groups.muted, 3, nil, 'facts') end
  if data.required_notice then required_line(data.required_notice, groups.warning, 3, nil, 'facts') end
  if data.input and data.label then
    required_line(data.label, groups.muted, 3, nil, review and 'review' or 'input')
  end
  if data.query ~= nil then
    local label = information.details and width >= 10 and (data.query_label or 'Search') .. '  ' or ''
    local text = data.query_text ~= nil and V.viewport(data.query_text, data.query_cursor, math.max(1, width - V.width(label))) or data.query
    line({ { label, groups.muted }, { text, groups.accent } }, 3)
  end
  if model.decoration.separator then line({ { string.rep('─', width), groups.muted } }, 0) end
  if show_items then
    local first, last = (data.page - 1) * page_size + 1, math.min(#items, data.page * page_size)
    if density == 'minimal' and data.selected then
      first = math.max(1, math.min(math.max(1, data.selected) - math.floor(page_size / 2), #items - page_size + 1))
      last = math.min(#items, first + page_size - 1)
    end
    local key_width = 1
    for index = first, last do key_width = math.min(12, math.max(key_width, V.width(K.label(items[index].key or '')))) end
    for index = first, last do
      local item, selected = items[index], data.selected == index
      local role = V.item_role(item, selected, groups)
      if item.editing_text ~= nil then
        local prefix = width < 4 and '' or '> '
        line({ { prefix, role }, { V.viewport(item.editing_text, item.editing_cursor,
          math.max(1, width - V.width(prefix))), role } }, 3, index,
          data.input and (review and 'review' or 'input') or nil)
      elseif review then
        local key = item.current and '↵' or K.label(item.key or '')
        local prefix = (selected and '› ' or '  ') .. (key ~= '' and key .. ' ' or '')
        required_line(prefix .. (item.name or ''), role, selected and 4 or 3, index, 'review')
      elseif data.input and selected then
        local key = item.current and '↵' or K.label(item.key or '')
        required_line('› ' .. (key ~= '' and key .. ' ' or '') .. (item.name or ''), role, 4, index, 'input')
      else
        local prefix = width < 3 and (selected and '›' or '') or (selected and '› ' or '  ')
        local remaining = math.max(0, width - V.width(prefix))
        local key_limit = math.min(key_width, 8, math.max(0, remaining - math.min(8, remaining) - 1))
        local key = key_limit > 0 and V.clip(item.current and '↵' or K.label(item.key or ''), key_limit) or ''
        local key_text = key ~= '' and key .. string.rep(' ', key_limit - V.width(key)) .. ' ' or ''
        -- The new renderer uses portable ASCII default icons. Provider glyphs
        -- remain host-owned; cell clipping cannot establish terminal font support.
        local icon = information.icons and not data.input and width >= 28 and ((item.icon or (item.group and '+' or '*')) .. ' ') or ''
        local detail = information.details and width >= 28 and not (selected and data.target)
          and (item.disabled and item.reason or item.detail) or nil
        local detail_text = detail and '  ' .. detail or ''
        local budget = math.max(0, remaining - V.width(key_text) - V.width(icon))
        local detail_width = math.min(V.width(detail_text), math.floor(budget / 2))
        local name = V.item_name(item, math.max(0, budget - detail_width))
        line({ { prefix .. key_text, selected and role or groups.accent }, { icon .. name, role },
          { V.clip(detail_text, detail_width), selected and role or groups.muted } }, selected and 4 or review and 3 or 1, index)
      end
    end
    if #items == 0 and #(data.content or {}) == 0 then line({ { data.empty or 'No commands', groups.muted } }, 1) end
  end
  -- Explicit output and review facts are content, independent of visibility
  -- preferences. Cosmetics can remove guidance, never unavailable/error facts.
  for _, text in ipairs(data.content or {}) do
    if review then required_line(text, groups.normal, 3, nil, 'review')
    else line({ { tostring(text), groups.normal } }, 2) end
  end
  if data.target then required_line('Target: ' .. data.target, groups.normal, 3, nil, 'facts') end
  if show_details then
    line({ { (data.details.kind or 'action') .. ' · ' .. (data.details.source or 'registered'), groups.muted } }, 0)
    local text = 'Target: ' .. (data.details.target or 'current buffer')
    if review then required_line(text, groups.normal, 3, nil, 'review')
    else line({ { text, groups.normal } }, 0) end
  end
  if data.details and (reason or show_details) and not repeated_reason then
    local text = reason and 'Unavailable: ' .. reason or data.details.description
      or ((data.details.kind or 'action') .. ' · ' .. (data.details.target or data.details.id or ''))
    line({ { text, reason and groups.warning or groups.normal } }, reason and 5 or 0)
  end
  if information.status and data.status then line({ { data.status, groups.muted } }, 0) end
  if data.message then line({ { data.message, data.message_role == 'normal' and groups.normal or groups.warning } },
    data.message_role == 'normal' and 0 or 5) end
  if data.error then line({ { data.error, groups.error } }, 5) end
  if information.help and data.help then
    local rows = require('command_tree.view.panels').help_rows(V, data, width, groups)
    if rows then for _, chunks in ipairs(rows) do line(chunks, 0) end
    else line({ { data.help, groups.normal } }, 0) end
  end
  if pages > 1 and (information.status or review) then
    line({ { ('↑/↓ · %d/%d'):format(data.page, pages), groups.muted } }, review and 3 or 0)
  end
  if body_height <= 2 then priorities[1] = 0 end
  while #lines > body_height do
    local remove, priority = #lines, math.huge
    for index = #lines, 1, -1 do
      if priorities[index] < priority then remove, priority = index, priorities[index] end
    end
    if critical[remove] then refuse(critical[remove]) end
    table.remove(lines, remove); table.remove(priorities, remove); table.remove(indices, remove)
    table.remove(critical, remove)
    for index = #marks, 1, -1 do
      if marks[index][1] == remove - 1 then table.remove(marks, index)
      elseif marks[index][1] > remove - 1 then marks[index][1] = marks[index][1] - 1 end
    end
  end
  for _, index in ipairs(indices) do
    if index then view.visible_first, view.visible_last = view.visible_first or index, index end
  end
  if view.presentation_facts_complete == false then
    fallback('required_facts', 'readable source and owner facts', 'incomplete', view.presentation_facts_reason)
  end
  if density == 'minimal' then
    local used = 1
    for _, text in ipairs(lines) do used = math.max(used, V.width(text)) end
    if not opts._fixed_panel then width = math.min(width, used) end
  end
  for index, text in ipairs(lines) do lines[index] = string.rep(' ', padding) .. text .. string.rep(' ', padding) end
  for _, mark in ipairs(marks) do mark[1], mark[2], mark[3] = mark[1] + vertical, mark[2] + padding, mark[3] + padding end
  for _ = 1, vertical do table.insert(lines, 1, ''); lines[#lines + 1] = '' end
  width = width + padding * 2
  local position = layout.position
  local bottom, right, top, left = position:find('bottom', 1, true), position:find('right', 1, true),
    position:find('top', 1, true), position:find('left', 1, true)
  local row = bottom and math.max(0, vim.o.lines - vim.o.cmdheight - #lines - border - 1)
    or top and 1 or math.max(0, math.floor((vim.o.lines - #lines - border) / 2))
  local col = right and math.max(0, vim.o.columns - width - border - 1)
    or left and 1 or math.max(0, math.floor((vim.o.columns - width - border) / 2))
  if target then
    local last_row, last_col = target.top + target.height - #lines - border, target.left + target.width - width - border
    row = bottom and last_row or top and target.top + 1 or target.top + math.floor((target.height - #lines - border) / 2)
    col = right and last_col or left and target.left + 1 or target.left + math.floor((target.width - width - border) / 2)
    row, col = math.max(target.top, math.min(row, last_row)), math.max(target.left, math.min(col, last_col))
  end
  local config = { relative = 'editor', row = row, col = col, width = width, height = #lines,
    border = border == 0 and 'none' or requested_border, zindex = opts.zindex or 80 }
  if information.title and border > 0 then
    local suffix = ' · ' .. (model.name or model.id or density)
    if pages > 1 then suffix = suffix .. (' · %d/%d'):format(data.page, pages) end
    if V.width(suffix) + 3 > width then suffix = pages > 1 and (' · %d/%d'):format(data.page, pages) or '' end
    config.title = V.clip(data.title or 'Commands', math.max(0, width - V.width(suffix))) .. suffix
    config.title_pos = 'left'
  end
  local Panels = require('command_tree.view.panels')
  Panels.main(view, lines, config, opts)
  V.window(view, lines, config)
  vim.wo[view.win].winhighlight = 'Normal:' .. groups.normal .. ',FloatBorder:' .. groups.accent
    .. ',FloatTitle:' .. groups.accent .. ',EndOfBuffer:' .. groups.normal
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for index, item_index in ipairs(indices) do
    if item_index == data.selected then
      local row = index - 1 + vertical
      vim.api.nvim_buf_set_extmark(view.buf, ns, row, 0, { end_col = #lines[row + 1],
        hl_group = groups.selected, hl_eol = true, priority = 90 })
    end
  end
  for _, mark in ipairs(marks) do
    if mark[1] < #lines and mark[3] > mark[2] then
      vim.api.nvim_buf_set_extmark(view.buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4], priority = 100 })
    end
  end
  require('command_tree.view.status').draw(V, view, data, opts, groups)
  Panels.draw(V, view, data, opts, groups)
  vim.cmd.redraw()
  return data.page, pages
end


return P
