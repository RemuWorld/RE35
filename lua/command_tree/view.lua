local M = {}
local ns = vim.api.nvim_create_namespace("CommandTreeUI")
-- Reuse a bounded pool of host-owned groups instead of creating new global
-- highlight names for each exported preset or each popup reopening.
local presentation_slots = {}
local derived_defaults = {}

-- Refresh only groups still owned by RE35. Materialized attributes must follow
-- ColorScheme changes, while explicit user links, colors and styles survive.
local function derived_default(name, attributes, legacy_link)
  local current = vim.api.nvim_get_hl(0, { name = name, link = true })
  if next(current) == nil or vim.deep_equal(current, derived_defaults[name])
    or legacy_link and vim.deep_equal(current, { link = legacy_link }) then
    vim.api.nvim_set_hl(0, name, attributes)
    derived_defaults[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
  end
end

local function branch_attributes(normal, branch)
  local attributes = vim.api.nvim_get_hl(0, { name = normal, link = false })
  local style = vim.api.nvim_get_hl(0, { name = branch, link = false })
  for _, key in ipairs({ 'bold', 'italic', 'underline', 'undercurl', 'underdouble',
    'underdotted', 'underdashed', 'strikethrough' }) do attributes[key] = style[key] or false end
  return attributes
end

function M.highlights()
  for name, target in pairs({ Normal = "NormalFloat", Title = "Title",
    Key = "Function", Desc = "NormalFloat", Muted = "Comment",
    Disabled = "Comment", Warning = "DiagnosticWarn", Error = "DiagnosticError",
    Icon = "CommandTreeKey", Selected = "PmenuSel" }) do
    vim.api.nvim_set_hl(0, "CommandTree" .. name, { link = target, default = true })
  end
  local group = vim.api.nvim_get_hl(0, { name = "CommandTreeDesc", link = false })
  group.bold = true
  derived_default("CommandTreeGroup", group, "CommandTreeDesc")
  derived_default("CommandTreeSelectedGroup", branch_attributes("CommandTreeSelected", "CommandTreeGroup"))
  -- Some colorschemes link FloatBorder to a reversed separator. Keep the
  -- theme's foreground, but give the border the same background as the panel.
  local border = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "CommandTreeBorder", { fg = border.fg or comment.fg or normal.fg,
    bg = float.bg or normal.bg, default = true })
end

function M.width(text) return vim.fn.strdisplaywidth(text) end

function M.item_role(item, selected, groups)
  groups = groups or { normal = "CommandTreeDesc", muted = "CommandTreeDisabled",
    branch = "CommandTreeGroup", selected = "CommandTreeSelected", selected_branch = "CommandTreeSelectedGroup" }
  if selected then return item.group and not item.disabled and groups.selected_branch or groups.selected end
  return item.disabled and groups.muted or item.group and groups.branch or groups.normal
end

-- A leading branch marker survives long labels and disabled/selected states.
-- At impossible widths, command identity has priority over the marker.
function M.item_name(item, width)
  local marker = item.group and "▸ " or ""
  if M.width(marker) + 1 > width then marker = "" end
  return marker .. M.clip(item.name or "", math.max(0, width - M.width(marker)))
end

function M.clip(text, width)
  text = tostring(text):gsub("[\r\n\t]", " ")
  if width <= 0 then return "" end
  -- Bound scanning even for a plugin label containing megabytes or long runs
  -- of combining marks. A panel only needs the visible prefix.
  local prefix = vim.fn.strcharpart(text, 0, math.max(256, width * 4))
  if #prefix == #text and M.width(prefix) <= width then return prefix end
  local ellipsis = M.width("…") <= width and "…" or "."
  local out = ""
  for char in prefix:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if M.width(out .. char .. ellipsis) > width then break end
    out = out .. char
  end
  return out .. ellipsis
end

-- Keep the caret visible while editing long Unicode text; only a bounded
-- neighborhood is measured, even when a pasted field is near the size limit.
function M.viewport(text, cursor, width)
  if width <= 0 then return "" end
  local caret = M.width("▏") <= width and "▏" or "|"
  if width == 1 then return caret end
  cursor = math.max(0, math.min(cursor or vim.fn.strchars(text), vim.fn.strchars(text)))
  local start = math.max(0, cursor - width * 2)
  local before = vim.fn.strcharpart(text, start, cursor - start)
  local ellipsis = M.width("…") + M.width(caret) <= width and "…" or ""
  local budget = math.max(0, math.min(math.floor(width * 0.65) - 2, width - M.width(caret) - M.width(ellipsis)))
  while M.width(before) > budget do before = vim.fn.strcharpart(before, 1); start = start + 1 end
  local prefix = (start > 0 and ellipsis or "") .. before .. caret
  local after = vim.fn.strcharpart(text, cursor, width * 2)
  return prefix .. M.clip(after, math.max(0, width - M.width(prefix)))
end

function M.close(view)
  if not view then return true end
  local panel_failures = {}
  local timer_ok, timer_error = require('command_tree.view.status').cancel(view)
  if not timer_ok then panel_failures[#panel_failures + 1] = timer_error end
  for _, name in ipairs({ 'details', 'guide', 'status' }) do
    local panel = view[name]
    if panel then
      view[name] = nil
      local ok, reason = M.close(panel)
      if not ok then view[name], panel_failures[#panel_failures + 1] = panel, reason end
    end
  end
  local win, buf = view.win, view.buf
  -- WinClosed/BufWipeout observers must see the UI as detached while Neovim
  -- destroys it, otherwise a routine redraw can recursively close its session.
  view.win, view.buf = nil, nil
  local failures = {}
  local function close(handle, valid, action)
    if handle and valid(handle) then
      local ok, err = pcall(action, handle)
      if not ok then failures[#failures + 1] = tostring(err):match("[^\n]+") end
    end
  end
  close(win, vim.api.nvim_win_is_valid, function(value) vim.api.nvim_win_close(value, true) end)
  close(buf, vim.api.nvim_buf_is_valid, function(value) vim.api.nvim_buf_delete(value, { force = true }) end)
  view.win = win and vim.api.nvim_win_is_valid(win) and win or nil
  view.buf = buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
  for _, reason in ipairs(panel_failures) do failures[#failures + 1] = reason end
  if view.win or view.buf or view.details or view.guide or view.status or view.status_timer then return false, table.concat(failures, "; ") end
  if view.presentation_slot then presentation_slots[view.presentation_slot], view.presentation_slot = nil, nil end
  return true
end

function M.scroll_details(view, delta)
  return require('command_tree.view.panels').scroll(M, view, delta)
end

function M.window(view, lines, config, frame)
  if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) then
    view.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[view.buf].bufhidden, vim.bo[view.buf].filetype = "wipe", "command-tree"
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  config.style, config.focusable, config.noautocmd = "minimal", false, true
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    config.noautocmd = nil
    vim.api.nvim_win_set_config(view.win, config)
  else view.win = vim.api.nvim_open_win(view.buf, false, config) end
  local wo = vim.wo[view.win]
  wo.winblend, wo.wrap, wo.scrolloff, wo.sidescrolloff = 0, false, 0, 0
  wo.cursorline, wo.signcolumn, wo.statuscolumn = false, "no", ""
  wo.winhighlight = frame and ("Normal:" .. (type(frame) == "string" and frame or "HistoryModeFrame")
    .. ",EndOfBuffer:" .. (type(frame) == "string" and frame or "HistoryModeFrame"))
    or "Normal:CommandTreeNormal,FloatBorder:CommandTreeBorder,FloatTitle:CommandTreeTitle,EndOfBuffer:CommandTreeNormal"
  return view
end

local function presentation_roles(view, model, accent)
  if not view.presentation_slot then
    for slot = 1, 32 do
      if not presentation_slots[slot] then presentation_slots[slot], view.presentation_slot = true, slot; break end
    end
  end
  if not view.presentation_slot then return nil end
  local defaults = { normal = 'CommandTreeNormal', selected = 'CommandTreeSelected', muted = 'CommandTreeMuted',
    accent = 'CommandTreeKey', warning = 'CommandTreeWarning', error = 'CommandTreeError' }
  local groups = {}
  for role, target in pairs(defaults) do
    local name = 'RE35Presentation' .. view.presentation_slot .. role
    local colors = model.roles[role] or {}
    if colors.fg or colors.bg or role == 'accent' and accent then
      local inherited = vim.api.nvim_get_hl(0, { name = target, link = false })
      inherited.fg, inherited.bg = colors.fg or (role == 'accent' and accent or nil) or inherited.fg,
        colors.bg or (role == 'accent' and model.roles.normal.bg or nil) or inherited.bg
      vim.api.nvim_set_hl(0, name, inherited)
    else vim.api.nvim_set_hl(0, name, { link = target }) end
    groups[role] = name
  end
  for role, base in pairs({ branch = 'normal', selected_branch = 'selected' }) do
    local name = 'RE35Presentation' .. view.presentation_slot .. role
    local target = role == 'branch' and 'CommandTreeGroup' or 'CommandTreeSelectedGroup'
    local colors = model.roles[base] or {}
    if colors.fg or colors.bg then
      vim.api.nvim_set_hl(0, name, branch_attributes(groups[base], 'CommandTreeGroup'))
    else vim.api.nvim_set_hl(0, name, { link = target }) end
    groups[role] = name
  end
  return groups
end


function M.presentation_review_status(data, opts)
  opts = require('command_tree.view.panels').critical_options(data or {}, opts or {})
  if not opts.presentation then return true end
  return require('command_tree.view.presentation').required_status(M, data, opts)
end

local function draw(view, data, opts)
  opts = opts or {}
  local Panels = require('command_tree.view.panels')
  data = require('command_tree.view.status').prepare(M, data, opts, view)
  local source_data = data
  data, opts = Panels.prepare(M, view, data, opts)
  if opts.presentation then
    local groups = presentation_roles(view, opts.presentation, opts.accent)
    if not groups then
      groups = { normal = 'CommandTreeNormal', selected = 'CommandTreeSelected', muted = 'CommandTreeMuted',
        accent = 'CommandTreeKey', warning = 'CommandTreeWarning', error = 'CommandTreeError',
        branch = 'CommandTreeGroup', selected_branch = 'CommandTreeSelectedGroup' }
      opts = vim.tbl_extend('force', {}, opts)
      opts.presentation_report = vim.deepcopy(opts.presentation_report or { fallbacks = {} })
      opts.presentation_report.fallbacks[#opts.presentation_report.fallbacks + 1] = {
        path = 'roles', requested = opts.presentation.roles, effective = {},
        reason = 'Concurrent presentation highlight slots exhausted; host theme roles are used' }
    end
    data = require('command_tree.view.guide').prepare(M, view, data, opts, source_data, groups)
    return require('command_tree.view.presentation').draw(M, view, data, opts, groups)
  end
  data = require('command_tree.view.guide').prepare(M, view, data, opts, source_data)
  view.presentation_report, view.presentation_review_complete, view.presentation_review_reason = nil, nil, nil
  view.presentation_input_complete, view.presentation_input_reason = nil, nil
  view.presentation_facts_complete, view.presentation_facts_reason = nil, nil
  view.presentation_options = nil
  view.visible_first, view.visible_last = nil, nil
  data.items = data.items or {}
  local K = require("command_tree.keys")
  local density = opts.density or "full"
  local target
  if opts.target_win and vim.api.nvim_win_is_valid(opts.target_win) then
    local pos = vim.api.nvim_win_get_position(opts.target_win)
    local bottom = math.min(vim.o.lines - vim.o.cmdheight, pos[1] + vim.api.nvim_win_get_height(opts.target_win))
    local right = math.min(vim.o.columns, pos[2] + vim.api.nvim_win_get_width(opts.target_win))
    target = { top = math.max(0, pos[1]), left = math.max(0, pos[2]) }
    target.width, target.height = math.max(1, right - target.left), math.max(1, bottom - target.top)
  end
  local border = density == "minimal" and 0 or 2
  -- A target panel belongs inside its source window, including its border.
  -- Very small sources keep a borderless body instead of covering neighbors.
  if target and (target.width <= border or target.height <= border) then border = 0 end
  if opts._fixed_panel then border = opts._fixed_panel.border end
  local max_width = math.max(1, target and target.width - border or vim.o.columns - border - 2)
  local window_limit = math.min(max_width, opts.max_width or 72)
  local padding = density == "minimal" and math.min(2, math.max(0, math.floor((window_limit - 4) / 2))) or 0
  if opts._fixed_panel then padding = math.min(padding, math.max(0, math.floor((opts._fixed_panel.width - 1) / 2))) end
  local limit = math.max(1, window_limit - padding * 2)
  local width = math.max(1, math.min(limit, (opts.width or 48) - padding * 2))
  local interactive = data.selected ~= nil or data.query ~= nil or data.input == true or data.content ~= nil
  width = math.min(limit, math.max(width, M.width(tostring(data.path or "\\")) + 4))
  for _, item in ipairs(data.items) do
    if width >= limit then break end
    if density == "full" then
      width = math.min(limit, math.max(width, M.width(K.label(item.key or "")) + M.width(item.name or "")
        + M.width(item.detail or "") + 12))
    end
  end
  if density == "compact" then
    -- A compact list needs room for one key and label, never for descriptions.
    local key_width, name_width = 1, 1
    for _, item in ipairs(data.items) do
      key_width = math.max(key_width, M.width(M.clip(item.current and "↵" or K.label(item.key or ""), 8)))
      name_width = math.max(name_width, M.width(M.clip((item.name or "") .. (item.group and " ›" or ""), limit)))
    end
    key_width = math.min(key_width, math.max(1, limit - 14))
    width = math.min(limit, math.max(width, key_width + name_width + 8))
  end
  if opts._fixed_panel then width = math.max(1, opts._fixed_panel.width - padding * 2) end
  local repeated_reason = data.details and data.details.reason and data.details.reason == data.message
  local detail_rows = data.details and (density == "full" and (repeated_reason and 2 or 3)
    or data.details.reason and not repeated_reason and 1 or 0) or 0
  local content_rows = data.content and #data.content or 0
  local max_height = math.max(1, target and target.height - border or vim.o.lines - vim.o.cmdheight - border - 1)
  if opts._fixed_panel then max_height = opts._fixed_panel.height end
  local header_rows = 1 + (data.query ~= nil and 1 or 0) + (density == "full" and 1 or 0)
  local help_rows = density == "full" and data.help and not data.message and not data.error
    and Panels.help_rows(M, data, math.max(1, width - 2)) or nil
  local feedback_rows = (data.message or data.error or density == "full" and data.help) and
    ((density == "full" and 1 or 0) + (help_rows and #help_rows or 1)) or 0
  feedback_rows = feedback_rows + (density == "full" and data.status and 1 or 0)
  local available = math.max(1, max_height - header_rows - detail_rows - content_rows - feedback_rows)
  local page_size = math.max(1, math.min(opts.max_height or 16, available))
  if density == "full" and #data.items > page_size then
    -- Full alone shows a paging footer in the body. Compact places it in the
    -- border title and Minimal keeps it out of the reading strip.
    page_size = math.max(1, math.min(page_size, available - 1))
  end
  local pages, range_first, range_last = 1
  local lines, marks, priorities, item_indices = {}, {}, {}, {}
  local function line(chunks, priority, item_index)
    local text = ""
    priority = priority or 1
    for _, chunk in ipairs(chunks) do
      if chunk[2] == "CommandTreeWarning" then priority = math.max(priority, 3)
      elseif chunk[2] == "CommandTreeSelected" then priority = math.max(priority, 2) end
      local value = M.clip(chunk[1], math.max(0, width - M.width(text)))
      marks[#marks + 1] = { #lines, #text, #text + #value, chunk[2] }
      text = text .. value
    end
    lines[#lines + 1] = text
    priorities[#lines] = priority
    item_indices[#lines] = item_index or false
  end
  -- A narrow panel must still identify the selected command. A long shortcut
  -- yields space to its name instead of consuming the whole row by itself.
  local function narrow_item(item, selected, index)
    local prefix = width < 3 and (selected and "›" or "") or (selected and "› " or "  ")
    local remaining = math.max(0, width - M.width(prefix))
    local key_limit = math.min(8, math.max(0, remaining - math.min(8, remaining) - 1))
    local key = key_limit > 0 and M.clip(item.current and "↵" or K.label(item.key or ""), key_limit) or ""
    local key_text = key ~= "" and key .. " " or ""
    local name = M.item_name(item, math.max(0, remaining - M.width(key_text)))
    local highlight = selected and "CommandTreeSelected" or nil
    line({ { prefix .. key_text, highlight or "CommandTreeKey" },
      { name, M.item_role(item, selected) } },
      selected and 2 or 1, index)
  end
  local path = tostring(data.path or "\\")
  if density == "minimal" and not interactive then
    line({ { path, "CommandTreeKey" } }, 4)
    if data.message then line({ { data.message, "CommandTreeWarning" } }) end
    data.page = 1
  else
    line({ { (density == "minimal" and "" or "  ") .. path, "CommandTreeKey" },
      { density ~= "minimal" and data.label and "   " .. data.label or "", "CommandTreeMuted" } }, 4)
    -- The session supplies the cursor at its actual editing position.
    if data.query ~= nil then
      local label = (density == "minimal" or width < 10) and "" or "  " .. (data.query_label or "Search") .. "  "
      local shown = data.query_text ~= nil and M.viewport(data.query_text, data.query_cursor, math.max(1, width - M.width(label))) or data.query
      line({ { label, "CommandTreeMuted" }, { shown, "CommandTreeKey" } }, 2)
    end
    if density == "compact" then
      -- Every Down/Up step moves to the next/previous visible row in every
      -- mode. A short page keeps the list dense without a second column.
      local inside = math.max(1, width - 4)
      local key_width = 1
      for _, item in ipairs(data.items) do key_width = math.max(key_width, M.width(K.label(item.key or ""))) end
      key_width = math.min(8, key_width, math.max(1, inside - 10))
      local compact_rows = math.max(1, math.min(page_size, opts.compact_rows or 6))
      pages = math.max(1, math.ceil(#data.items / compact_rows))
      if data.selected then data.page = math.ceil(math.max(1, data.selected) / compact_rows) end
      data.page = math.max(1, math.min(data.page or 1, pages))
      for index = (data.page - 1) * compact_rows + 1, math.min(#data.items, data.page * compact_rows) do
        local item = data.items[index]
        local selected = data.selected == index
        local label = M.clip(item.current and "↵" or K.label(item.key or ""), key_width)
        local name_width = math.max(1, inside - key_width - 4)
        local name = item.editing_text ~= nil and M.viewport(item.editing_text, item.editing_cursor, name_width)
          or M.item_name(item, name_width)
        local highlight = selected and "CommandTreeSelected" or nil
        if item.editing_text ~= nil and width < 10 then
          line({ { M.viewport(item.editing_text, item.editing_cursor, width), highlight or "CommandTreeKey" } }, 2, index)
        elseif item.editing_text == nil and width < 28 then
          narrow_item(item, selected, index)
        else
          line({ { "  " .. (selected and "› " or "  ") .. label .. string.rep(" ", key_width - M.width(label)) .. "  ", highlight or "CommandTreeKey" },
            { name, M.item_role(item, selected) } },
            (selected or item.editing_text ~= nil) and 2 or 1, index)
        end
      end
    else
      if density == "full" then line({ { "  " .. string.rep("─", math.max(0, width - 4)), "CommandTreeMuted" } }, 0) end
      if interactive and density ~= "full" then
        page_size = math.max(1, math.min(page_size, density == "minimal" and (opts.minimal_rows or 3) or (opts.compact_rows or 6)))
      end
      pages = math.max(1, math.ceil(#data.items / page_size))
      data.page = data.selected and math.ceil(math.max(1, data.selected) / page_size) or data.page or 1
      data.page = math.max(1, math.min(data.page, pages))
      local first, last = (data.page - 1) * page_size + 1, math.min(#data.items, data.page * page_size)
      if density == "minimal" and data.selected then
        first = math.max(1, math.min(math.max(1, data.selected) - math.floor(page_size / 2), #data.items - page_size + 1))
        last = math.min(#data.items, first + page_size - 1)
        range_first, range_last = first, last
      end
      local key_width = 1
      for i = first, last do key_width = math.min(12, math.max(key_width, M.width(K.label(data.items[i].key or "")))) end
      for i = first, last do
        local item = data.items[i]
        local selected = data.selected == i
        if item.editing_text ~= nil and (density == "minimal" or width < 10) then
          line({ { M.viewport(item.editing_text, item.editing_cursor, width), selected and "CommandTreeSelected" or "CommandTreeKey" } }, 2, i)
        elseif item.editing_text == nil and width < 28 then
          narrow_item(item, selected, i)
        else
          local label = M.clip(item.current and "↵" or K.label(item.key or ""), key_width)
          local icon = (opts.icons == false or density ~= "full" or data.input) and ""
            or ((item.icon or (item.group and "󰉋" or "󰌋")) .. "  ")
          local detail_text = item.disabled and item.reason or item.detail
          local detail = density == "full" and detail_text and "  " .. detail_text or ""
          local budget = math.max(1, width - key_width - M.width(icon) - 9)
          local detail_width = math.min(M.width(detail), math.floor(budget / 2))
          local desc = item.editing_text ~= nil and M.viewport(item.editing_text, item.editing_cursor, math.max(1, budget - detail_width))
            or M.item_name(item, math.max(1, budget - detail_width))
          line({ { (selected and "› " or "  ") .. label .. string.rep(" ", key_width - M.width(label)) .. "   ", selected and "CommandTreeSelected" or "CommandTreeKey" },
            { icon, selected and "CommandTreeSelected" or item.disabled and "CommandTreeDisabled" or "CommandTreeIcon" },
            { desc, M.item_role(item, selected) },
            { M.clip(detail, detail_width), selected and "CommandTreeSelected" or "CommandTreeMuted" },
            { item.disabled and "  ·" or "", selected and "CommandTreeSelected" or "CommandTreeMuted" } }, (selected or item.editing_text ~= nil) and 2 or 1, i)
        end
      end
    end
    if #data.items == 0 and content_rows == 0 then line({ { (density == "minimal" and "" or "  ") .. (data.empty or "No commands"), "CommandTreeMuted" } }) end
    -- Explicit content is requested output (for example a Results preview),
    -- rather than optional status chrome. Keep each source line in every
    -- density, clipping to cells and retaining it ahead of metadata/help.
    for _, text in ipairs(data.content or {}) do
      line({ { (density == "minimal" and "" or "  ") .. tostring(text), "CommandTreeDesc" } }, 2)
    end
    if data.details and (density == "full" or data.details.reason) then
      local detail = data.details
      if density == "full" then
        line({ { "  " .. (detail.kind or "action") .. " · " .. (detail.source or "registered"), "CommandTreeMuted" } }, 0)
        line({ { "  Target: " .. (detail.target or "current buffer"), "CommandTreeDesc" } }, 0)
      end
      local text = detail.reason and ((density == "full" and "Unavailable: " or "") .. detail.reason) or detail.description
        or ((detail.kind or "action") .. " · " .. (detail.target or detail.id or ""))
      if not repeated_reason then
        line({ { ((density == "minimal" or width < 5) and "" or "  ") .. text, detail.reason and "CommandTreeWarning" or "CommandTreeDesc" } }, 0)
      end
    end
    if data.status and density == "full" then line({ { "  " .. data.status, "CommandTreeMuted" } }, 0) end
    if data.message or data.error or data.help and density == "full" then
      if density == "full" then line({ { "", "CommandTreeMuted" } }, 0) end
      local hint_rows = not data.message and not data.error and Panels.help_rows(M, data, math.max(1, width - 2))
      if hint_rows then
        for _, chunks in ipairs(hint_rows) do
          table.insert(chunks, 1, { width < 5 and "" or "  ", "CommandTreeDesc" })
          line(chunks, 0)
        end
      else
        line({ { ((density == "minimal" or width < 5) and "" or "  ") .. (data.error or data.message or data.help),
          data.error and "CommandTreeError" or data.message and data.message_role ~= 'normal' and "CommandTreeWarning" or "CommandTreeDesc" } },
          (data.error or data.message and data.message_role ~= 'normal') and 5 or 0)
      end
    end
    if pages > 1 and density == "full" then
      local paging = range_first and ("  ↑/↓  ·  %d–%d of %d"):format(range_first, range_last, #data.items)
        or ("  %s  ·  %d/%d"):format(data.selected and "↑/↓ Select" or "Ctrl-d/u", data.page, pages)
      line({ { paging, "CommandTreeMuted" } }, 0)
    end
  end
  local tiny_target = (target or opts._fixed_panel) and max_height <= 2
  if tiny_target then priorities[1] = 0 end
  -- On short screens, trim guidance and metadata before the input, selected
  -- item or error. Keep extmark rows in step with any removed middle row.
  while #lines > max_height do
    local remove, priority = #lines, math.huge
    for index = #lines, tiny_target and 1 or 2, -1 do
      if priorities[index] < priority then remove, priority = index, priorities[index] end
    end
    table.remove(lines, remove)
    table.remove(priorities, remove)
    table.remove(item_indices, remove)
    for index = #marks, 1, -1 do
      local mark = marks[index]
      if mark[1] == remove - 1 then table.remove(marks, index)
      elseif mark[1] > remove - 1 then mark[1] = mark[1] - 1 end
    end
  end
  for _, index in ipairs(item_indices) do
    if index then
      view.visible_first = view.visible_first or index
      view.visible_last = index
    end
  end
  if density == "minimal" then
    local used = 1
    for _, text in ipairs(lines) do used = math.max(used, M.width(text)) end
    if not opts._fixed_panel then width = math.min(width, used) end
    -- Horizontal breathing room keeps this a short reading strip. Do not
    -- add empty vertical rows; narrow panels yield padding before content.
    for index, text in ipairs(lines) do lines[index] = string.rep(" ", padding) .. text .. string.rep(" ", padding) end
    for _, mark in ipairs(marks) do mark[2], mark[3] = mark[2] + padding, mark[3] + padding end
    width = width + padding * 2
  end
  local row = opts.position and opts.position:find("bottom", 1, true) and math.max(0, vim.o.lines - vim.o.cmdheight - #lines - border - 1)
    or math.max(0, math.floor((vim.o.lines - #lines - border) / 2))
  local col = opts.position and opts.position:find("right", 1, true) and math.max(0, vim.o.columns - width - border - 1)
    or math.max(0, math.floor((vim.o.columns - width - border) / 2))
  if target then
    local last_row, last_col = target.top + target.height - #lines - border, target.left + target.width - width - border
    row = opts.position and opts.position:find("bottom", 1, true) and last_row or target.top + 1
    col = opts.position and opts.position:find("right", 1, true) and last_col or target.left + 2
    row, col = math.max(target.top, math.min(row, last_row)), math.max(target.left, math.min(col, last_col))
  end
  local density_label = density:sub(1, 1):upper() .. density:sub(2)
  local config = { relative = "editor", row = row, col = col, width = width,
    height = #lines, border = border == 0 and "none" or "rounded", zindex = opts.zindex or 80 }
  if density ~= "minimal" and border > 0 then
    local page_label = density == "compact" and pages > 1 and (" · %d/%d"):format(data.page, pages) or ""
    local suffix = " · " .. density_label .. page_label .. " "
    if M.width(suffix) + 2 > width then suffix = page_label ~= "" and page_label .. " " or " " end
    config.title = " " .. M.clip(data.title or "Commands", math.max(0, width - M.width(suffix) - 1)) .. suffix
    if M.width(config.title) > width then
      config.title = M.clip(page_label ~= "" and ("%d/%d"):format(data.page, pages) or data.title or "Commands", width)
    end
    config.title_pos, config.footer, config.footer_pos = "left", "", "right"
  end
  Panels.main(view, lines, config, opts)
  M.window(view, lines, config)
  if view.presentation_slot then presentation_slots[view.presentation_slot], view.presentation_slot = nil, nil end
  if opts.accent then
    local group = "CommandTreeAccent" .. tostring(opts.accent):gsub("[^%w]", "")
    local background = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false }).bg
    vim.api.nvim_set_hl(0, group, { fg = opts.accent, bg = background })
    vim.wo[view.win].winhighlight = "Normal:CommandTreeNormal,FloatBorder:" .. group .. ",FloatTitle:" .. group .. ",EndOfBuffer:CommandTreeNormal"
  end
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for index, item_index in ipairs(item_indices) do
    if item_index == data.selected then
      vim.api.nvim_buf_set_extmark(view.buf, ns, index - 1, 0, { end_col = #lines[index],
        hl_group = "CommandTreeSelected", hl_eol = true, priority = 90 })
    end
  end
  for _, mark in ipairs(marks) do
    if mark[1] < #lines and mark[3] > mark[2] then
      vim.api.nvim_buf_set_extmark(view.buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4], priority = 100 })
    end
  end
  require('command_tree.view.status').draw(M, view, data, opts)
  Panels.draw(M, view, data, opts)
  vim.cmd.redraw()
  return data.page, pages
end

function M.draw(view, data, opts)
  local ok, page, pages = pcall(draw, view, data, opts)
  if not ok then
    local closed, reason = M.close(view)
    if not closed then page = tostring(page) .. '; panel cleanup: ' .. tostring(reason) end
    error(page, 0)
  end
  return page, pages
end

return M
