-- Real float geometry and teardown; the optional guide never owns editor focus.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 180, 48
local V, P = require('command_tree.view'), require('command_tree.presentation')
V.highlights()
local source = vim.api.nvim_get_current_win()
local help = 'Esc Back · Enter Run · ↑/↓ Select · / Search · ? View · <C-h> Details · Shift+PgUp/PgDn Scroll details'
local function options(density, preset)
  local config = { window = { layout = 'fixed', density = density, width = 48, max_width = 72,
    max_height = 16, icons = false, details = { enabled = true, max_height = 4 } } }
  if preset then config.presentation = { version = 1, selected = density, presets = {} } end
  return P.options(config, { density = density }, 'tree')
end
local function body(part) return vim.api.nvim_buf_get_lines(part.buf, 0, -1, false) end
local function text(part) return table.concat(body(part), '\n') end
local function geometry(part)
  local config = vim.api.nvim_win_get_config(part.win)
  return { width = config.width, height = config.height, row = config.row, col = config.col }
end
local function border(part)
  local value = vim.api.nvim_win_get_config(part.win).border
  return type(value) == 'table' and #value > 0 and 2 or 0
end
local function audit(part)
  local config = geometry(part)
  H.ok(config.col >= 0 and config.row >= 0, 'Guide stays inside viewport origin')
  H.ok(config.col + config.width + border(part) <= vim.o.columns, 'Guide stays within terminal columns')
  H.ok(config.row + config.height + border(part) <= vim.o.lines - vim.o.cmdheight, 'Guide stays above the command line')
  H.eq(config.height, #body(part), 'Guide allocates only its rendered rows')
  for _, line in ipairs(body(part)) do H.ok(V.width(line) <= config.width, 'Guide row fits complete display cells') end
end
local function scene()
  return { path = '\\', selected = 1, items = {
    { key = 'a', name = 'Build' }, { key = 'g', name = 'Project', group = true } } }
end

for _, preset in ipairs({ false, true }) do
  local view, opts, data = {}, options('full', preset), scene()
  V.draw(view, data, opts)
  local initial = geometry(view)
  data.help = help
  V.draw(view, data, opts)
  H.ok(view.guide, 'Wide Full has a dedicated right guide')
  H.eq('right', view.panel_report.guide, 'Effective right placement is reported')
  H.eq(initial, geometry(view), 'Adding hints does not move or resize main')
  local guide_position = geometry(view.guide)
  H.eq(initial.row, guide_position.row, 'Guide aligns with the main top')
  H.eq(initial.col + initial.width + border(view) + 1, guide_position.col, 'Guide occupies spare cells after a one-cell gap')
  H.ok(text(view.guide):find('Navigation', 1, true) and text(view.guide):find('Information', 1, true)
    and text(view.guide):find('Actions', 1, true), 'Related controls are grouped')
  H.ok(text(view.guide):find('Shift+PgUp/Down', 1, true), 'Long key chord stays intact')
  H.eq(nil, view.details, 'Hints do not allocate redundant bottom details')
  audit(view.guide)

  local messages = {}
  for index = 1, 30 do messages[index] = 'Diagnostic line ' .. index end
  data.diagnostic = { message = 'Failure', full_message = table.concat(messages, '\n') }
  data.details = { description = 'Description stays below', target = 'src/main.cpp' }
  data.selected = 2
  V.draw(view, data, opts)
  H.eq(initial, geometry(view), 'Selection and diagnostic text leave main stable')
  H.eq(33, view.details.total, 'Right guide retains every diagnostic and description row')
  H.ok(not text(view.details):find('Esc', 1, true), 'Bottom panel does not duplicate right-side hints')
  H.eq(nil, view.details.pinned, 'Right guide removes duplicate pinned shortcut row')
  H.ok(V.scroll_details(view, 10), 'Long diagnostic remains independently scrollable')
  H.ok(text(view.details):find('Diagnostic line 11', 1, true), 'Later diagnostic rows remain inspectable')
  H.eq(initial, geometry(view), 'Details scrolling leaves main stable')
  H.eq(source, vim.api.nvim_get_current_win(), 'Main and guide keep the native editor focused')
  local stale_win, stale_buf = view.guide.win, view.guide.buf
  data.help = nil
  V.draw(view, data, opts)
  H.eq(nil, view.guide, 'Removing hints detaches the guide')
  H.ok(not vim.api.nvim_win_is_valid(stale_win) and not vim.api.nvim_buf_is_valid(stale_buf), 'Removed guide leaves no handles')

  data.help, data.diagnostic, data.details = help, nil, nil
  V.draw(view, data, opts)
  stale_win, stale_buf = view.guide.win, view.guide.buf
  V.draw(view, data, options('compact', preset))
  H.eq(nil, view.guide, 'Compact closes the Full guide')
  H.ok(not vim.api.nvim_win_is_valid(stale_win) and not vim.api.nvim_buf_is_valid(stale_buf), 'Density change cleans guide handles')
  V.draw(view, data, options('minimal', preset))
  H.eq(nil, view.guide, 'Minimal never introduces routine guide chrome')
  H.eq(nil, view.details, 'Minimal keeps routine shortcut hints hidden')
  V.close(view)
end

-- The complete guide falls back below when either horizontal or vertical room
-- is insufficient. No hint group is silently discarded to keep a side panel.
local view, opts, data = {}, options('full', false), scene()
data.help = help
V.draw(view, data, opts)
local guide_win, guide_buf = view.guide.win, view.guide.buf
vim.o.columns = 80
V.draw(view, data, opts)
H.eq(nil, view.guide, 'Terminal narrowing closes the stale right guide')
H.ok(not vim.api.nvim_win_is_valid(guide_win) and not vim.api.nvim_buf_is_valid(guide_buf), 'Resize cleans stale guide handles')
H.eq('below', view.panel_report.guide, 'Narrow viewport explicitly reports below fallback')
H.ok(view.details and text(view.details):find('Back', 1, true), 'Navigation hints remain below after fallback')
local retained = table.concat(view.details.lines, '\n')
H.ok(retained:find('Shift+PgUp/Down', 1, true), 'Fallback retains the entire long key chord')
V.close(view)
vim.o.columns, vim.o.lines = 180, 48
data.help = 'Custom explanation without shortcut grammar'
V.draw(view, data, opts)
H.eq(nil, view.guide, 'Plain custom adapter help remains below')
H.ok(text(view.details):find(data.help, 1, true), 'Plain custom help remains readable unchanged')
V.close(view)

data.help = help
V.draw(view, data, opts)
opts.layout = 'dynamic'
V.draw(view, data, opts)
H.eq(nil, view.guide, 'Dynamic opt-out removes the fixed-layout guide')
H.ok(text(view):find('Back', 1, true), 'Dynamic layout retains inline help')
V.close(view)
opts.layout = 'fixed'
opts.position = 'bottom-right'
V.draw(view, data, opts)
H.eq(nil, view.guide, 'A right-anchored main does not shift left to make guide space')
H.eq('below', view.panel_report.guide, 'Right-anchored view uses below fallback')
V.close(view)
opts.position = nil

local many = {}
for index = 1, 32 do
  local label = ({ 'Back', 'Details', 'Run' })[(index - 1) % 3 + 1] .. index
  many[index] = 'a ' .. label
end
data.help = table.concat(many, ' · ')
V.draw(view, data, opts)
H.eq(nil, view.guide, 'All guide groups fall back when their complete height cannot fit')
retained = table.concat(view.details.lines, '\n')
for index = 1, 32 do
  H.ok(retained:find(many[index]:sub(3), 1, true), 'Height fallback retains hint ' .. index)
end
V.close(view)

-- A workspace guide belongs wholly inside the source window's viewport.
vim.cmd('vsplit')
local owned_source = vim.api.nvim_get_current_win()
opts.target_win, opts.width = owned_source, 24
data.help = 'Esc Back · Enter Run · ? View'
V.draw(view, data, opts)
H.ok(view.guide, 'A source window with spare right cells can show its guide')
local owned_position, owned_width = vim.api.nvim_win_get_position(owned_source), vim.api.nvim_win_get_width(owned_source)
local guide_config = geometry(view.guide)
H.ok(guide_config.col >= owned_position[2]
  and guide_config.col + guide_config.width + border(view.guide) <= owned_position[2] + owned_width,
  'Workspace guide does not cover the neighboring source window')
H.eq(owned_source, vim.api.nvim_get_current_win(), 'Workspace guide leaves its source focused')
V.close(view)
vim.api.nvim_win_close(owned_source, true)
opts.target_win, opts.width = nil, 48

-- Help extraction never removes source identities or review facts.
data = { path = '\\ Review', input = true, review = true, required_label = 'Review edits', target = 'src/main.cpp',
  selected = 1, items = { { key = 'a', name = 'Apply' } }, content = { 'Before: old', 'After: new' }, help = help }
V.draw(view, data, opts)
H.ok(view.guide, 'A readable Full review can place only its shortcuts beside it')
H.ok(text(view):find('Before: old', 1, true) and text(view):find('After: new', 1, true)
  and text(view):find('src/main.cpp', 1, true), 'Required review and owner facts remain in main')
H.eq(true, view.presentation_review_complete, 'Complete review still passes its existing admission rules')
H.eq(true, V.presentation_review_status(data, opts), 'Fresh review admission agrees after optional guide extraction')
V.close(view)
data = scene()
data.help = help

-- Slot colors also govern the side guide; it has no separate portable roles.
opts = options('full', true)
opts.presentation.roles.normal = { fg = '#ABCDEF', bg = '#102030' }
opts.presentation.roles.accent = { fg = '#FFAA22' }
V.draw(view, data, opts)
local colors = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.guide.buf, -1, 0, -1, { details = true })) do
  local group = mark[4].hl_group
  if type(group) == 'number' then group = vim.api.nvim_get_hl_name_by_id(group) end
  colors[vim.api.nvim_get_hl(0, { name = group, link = false }).fg] = true
end
H.ok(colors[0xABCDEF] and colors[0xFFAA22], 'Named preset normal and accent colors govern guide labels and keys')
guide_win, guide_buf = view.guide.win, view.guide.buf
V.close(view)
H.ok(not vim.api.nvim_win_is_valid(guide_win) and not vim.api.nvim_buf_is_valid(guide_buf), 'Session close tears down guide window and buffer')

-- Failure after allocation must clean up and retain original below hints.
opts = options('full', false)
local original_window, allocated = V.window, {}
V.window = function(part, ...)
  local result = original_window(part, ...)
  if part == view.guide then allocated = { win = part.win, buf = part.buf }; error('Fixture guide rendering failure') end
  return result
end
local ok, reason = pcall(V.draw, view, data, opts)
V.window = original_window
H.ok(ok, 'Guide rendering failure uses below fallback instead of failing main: ' .. tostring(reason))
H.eq(nil, view.guide, 'Failed guide detaches')
H.ok(not vim.api.nvim_win_is_valid(allocated.win) and not vim.api.nvim_buf_is_valid(allocated.buf), 'Failed guide leaves no orphan handles')
H.ok(view.details and text(view.details):find('Back', 1, true), 'Guide failure retains the original hints below')
H.eq('below', view.panel_report.guide, 'Guide host failure reports below fallback')
V.close(view)

-- Persistent host teardown failure must retain ownership and an observable
-- error in every removal path, including failed guide allocation/rendering.
local close_window, delete_buffer = vim.api.nvim_win_close, vim.api.nvim_buf_delete
for _, phase in ipairs({ 'hidden', 'plain', 'narrow', 'allocation' }) do
  vim.o.columns = 180
  data.help = help
  V.draw(view, data, opts)
  local retained_guide, attempts = view.guide, 0
  local retained_win, retained_buf = retained_guide.win, retained_guide.buf
  vim.api.nvim_win_close = function(win, ...)
    if win == retained_win then attempts = attempts + 1; error('Fixture guide close failure') end
    return close_window(win, ...)
  end
  vim.api.nvim_buf_delete = function(buf, ...)
    if buf == retained_buf then error('Fixture guide buffer deletion failure') end
    return delete_buffer(buf, ...)
  end
  local changed = opts
  if phase == 'hidden' then changed = options('compact', false)
  elseif phase == 'plain' then data.help = 'Custom help stays below'
  elseif phase == 'narrow' then vim.o.columns = 80
  else
    V.window = function(part, ...)
      local result = original_window(part, ...)
      if part == retained_guide then error('Fixture guide render followed by cleanup failure') end
      return result
    end
  end
  local failed, failure = pcall(V.draw, view, data, changed)
  V.window, vim.api.nvim_win_close, vim.api.nvim_buf_delete = original_window, close_window, delete_buffer
  H.eq(false, failed, phase .. ': persistent guide cleanup failure is observable')
  H.ok(tostring(failure):find('Fixture guide close failure', 1, true), phase .. ': error preserves the concrete host failure')
  H.ok(attempts >= 2, phase .. ': main containment retries guide teardown')
  H.eq(retained_guide, view.guide, phase .. ': failed teardown retains the owned guide')
  H.eq(retained_win, view.guide.win, phase .. ': window handle remains reachable')
  H.eq(retained_buf, view.guide.buf, phase .. ': buffer handle remains reachable')
  H.ok(vim.api.nvim_win_is_valid(retained_win) and vim.api.nvim_buf_is_valid(retained_buf),
    phase .. ': persistent host failure leaves known handles alive')
  H.eq('cleanup-failed', view.panel_report.guide, phase .. ': diagnostics never claim hidden/below while guide survives')
  H.ok(view.panel_report.guide_error:find('Fixture guide close failure', 1, true), phase .. ': diagnostics retain cleanup failure')
  H.ok(V.close(view), phase .. ': restoring host API allows complete cleanup')
  H.eq(nil, view.guide, phase .. ': successful retry detaches guide ownership')
  H.ok(not vim.api.nvim_win_is_valid(retained_win) and not vim.api.nvim_buf_is_valid(retained_buf),
    phase .. ': successful retry removes both handles')
end
vim.o.columns = 180
data.help = help

-- A subsequent main failure also closes the previously allocated side guide.
allocated = {}
V.window = function(part, ...)
  local result = original_window(part, ...)
  if part == view.guide then allocated = { win = part.win, buf = part.buf }
  elseif part == view then error('Fixture main failure') end
  return result
end
ok = pcall(V.draw, view, data, opts)
V.window = original_window
H.eq(false, ok, 'Main host failure remains observable')
H.eq(nil, view.guide, 'Main failure detaches the side guide')
H.ok(not vim.api.nvim_win_is_valid(allocated.win) and not vim.api.nvim_buf_is_valid(allocated.buf), 'Main failure leaves no guide orphan')
H.eq(source, vim.api.nvim_get_current_win(), 'All guide operations retain editor focus')
for _, win in ipairs(vim.api.nvim_list_wins()) do
  H.eq('', vim.api.nvim_win_get_config(win).relative, 'No guide or command popup survives teardown')
end
print('Shortcut guide geometry, fallback and lifecycle passed')
