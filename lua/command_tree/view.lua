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
  derived_default("CommandTreeBorder", { fg = border.fg or comment.fg or normal.fg,
    bg = float.bg or normal.bg })
end

function M.width(text) return vim.fn.strdisplaywidth(text) end

function M.item_role(item, selected, groups)
  groups = groups or { normal = "CommandTreeDesc", muted = "CommandTreeDisabled",
    branch = "CommandTreeGroup", selected = "CommandTreeSelected", selected_branch = "CommandTreeSelectedGroup" }
  if selected then return item.group and not item.disabled and groups.selected_branch or groups.selected end
  return item.disabled and (groups.disabled or groups.muted) or item.group and groups.branch or groups.normal
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
  view.page_size = nil
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
  return require('command_tree.view.presentation').required_status(M, data or {}, opts or {})
end

local function draw(view, data, opts)
  opts = require('command_tree.view.model').normalize(data, opts)
  local Panels = require('command_tree.view.panels')
  data = require('command_tree.view.status').prepare(M, data, opts, view)
  local source_data = data
  data, opts = Panels.prepare(M, view, data, opts)
  local groups
  if opts._display.source == 'preset' then groups = presentation_roles(view, opts.presentation, opts.accent)
  elseif view.presentation_slot then
    presentation_slots[view.presentation_slot], view.presentation_slot = nil, nil
  end
  if not groups then
    groups = { normal = opts._display.legacy_rows and 'CommandTreeDesc' or 'CommandTreeNormal',
      selected = 'CommandTreeSelected', muted = 'CommandTreeMuted',
      accent = 'CommandTreeKey', warning = 'CommandTreeWarning', error = 'CommandTreeError',
      branch = 'CommandTreeGroup', selected_branch = 'CommandTreeSelectedGroup', icon = 'CommandTreeIcon',
      disabled = opts._display.legacy_rows and 'CommandTreeDisabled' or nil }
    if opts._display.source == 'preset' then
      opts = vim.tbl_extend('force', {}, opts)
      opts.presentation_report = vim.deepcopy(opts.presentation_report or { fallbacks = {} })
      opts.presentation_report.fallbacks[#opts.presentation_report.fallbacks + 1] = {
        path = 'roles', requested = opts.presentation.roles, effective = {},
        reason = 'Concurrent presentation highlight slots exhausted; host theme roles are used' }
    end
  end
  -- Companion panels use the same decoration role as the main surface. Keep
  -- default borders distinct from shortcut text, while retaining authored
  -- preset roles and the host's explicit per-window accent.
  if opts._display.source == 'preset' then groups.border = groups.accent
  elseif opts.accent then
    groups.border = 'CommandTreeAccent' .. tostring(opts.accent):gsub('[^%w]', '')
    local background = vim.api.nvim_get_hl(0, { name = 'NormalFloat', link = false }).bg
    vim.api.nvim_set_hl(0, groups.border, { fg = opts.accent, bg = background })
  else groups.border = 'CommandTreeBorder' end
  data, opts = require('command_tree.view.guide').prepare(M, view, data, opts, source_data, groups)
  return require('command_tree.view.presentation').draw(M, view, data, opts, groups)
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
