-- Hint units, semantic spans and real panel geometry; no key behavior changes.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 100, 42
local V = require('command_tree.view')
local Panels = require('command_tree.view.panels')
local Guide = require('command_tree.session.key_guide')
V.highlights()

H.eq('Ctrl+h', Guide.hint_key('<C-h>'), 'Neovim control notation has a readable display name')
H.eq('Shift+PgUp/Down', Guide.hint_key('Shift-PgUp/PgDn'), 'Details scroll display is concise')
H.eq('Ctrl+Shift+x', Guide.hint_key('<C-S-x>'), 'Multiple modifiers remain explicit')
H.eq('Ctrl+Shift+x', Guide.hint_key('<S-C-x>'), 'Modifier order uses the same display spelling')
H.eq('Shift+PgUp/Down', Guide.hint_pair('<S-PageUp>', '<S-PageDown>'), 'Configured scroll keys share their modifier')
H.eq('Ctrl+u/d', Guide.hint_pair('<C-u>', '<C-d>'), 'Customized scroll keys display their actual chords')
H.eq(nil, Guide.help_hints('A custom explanation without controls'), 'Custom prose remains raw help')
H.eq(nil, Guide.help_hints(string.rep('x', 4097)), 'Raw help parsing has a finite byte bound')
H.eq(nil, Guide.help_hints('Esc Back\nEnter Run'), 'Multiline adapter help remains raw help')

local help = 'Esc Back · / Search · ? View · \\ Close · ↑/↓ Select · <C-h> Details · Shift-PgUp/PgDn Scroll details'
local hints = assert(Guide.help_hints(help))
local function row_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do parts[#parts + 1] = chunk[1] end
  return table.concat(parts)
end
local function rendered_rows(width)
  local rows = assert(Panels.help_rows(V, { hints = hints }, width))
  local found = {}
  for _, chunks in ipairs(rows) do
    local text = row_text(chunks)
    H.ok(V.width(text) <= width, 'Hint row stays inside ' .. width .. ' display cells')
    H.ok(not text:match('^%s*·') and not text:match('·%s*$'), 'Rows contain no dangling separators')
    for _, chunk in ipairs(chunks) do
      H.ok(not chunk[1]:find('[\r\n\t%z]'), 'Hint text stays on its own display row')
      if chunk[2] == 'CommandTreeKey' then found[chunk[1]] = true end
    end
  end
  return rows, found
end
for _, width in ipairs({ 1, 8, 16, 24, 32, 60 }) do
  local _, found = rendered_rows(width)
  if width >= 16 then
    H.ok(found['Shift+PgUp/Down'], 'Full details chord is intact when its key spelling fits')
    H.ok(found['Ctrl+h'], 'Control chord is intact when its key spelling fits')
  end
end
local rows = rendered_rows(60)
H.eq(3, #rows, 'Related navigation, action and inspection controls form three rows')
H.ok(row_text(rows[1]):find('Esc Back', 1, true) and row_text(rows[1]):find('↑/↓ Select', 1, true),
  'Navigation controls stay together')
H.ok(row_text(rows[3]):find('Ctrl+h Details', 1, true), 'Inspection controls stay together')

local function config(view)
  local cfg = vim.api.nvim_win_get_config(view.win)
  return { row = cfg.row, col = cfg.col, width = cfg.width, height = cfg.height }
end
local function text(view)
  return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), '\n')
end
local function spans(view)
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true })) do
    local detail, line = mark[4], lines[mark[2] + 1]
    H.ok(line and mark[3] <= #line and detail.end_col <= #line, 'Semantic span references visible bytes')
    result[#result + 1] = { text = line:sub(mark[3] + 1, detail.end_col), role = detail.hl_group }
  end
  return result
end
local function has_span(values, part, suffix)
  for _, value in ipairs(values) do
    if value.text:find(part, 1, true) and value.role:sub(-#suffix) == suffix then return true end
  end
  return false
end
local base = { title = 'Commands', path = '\\', selected = 1,
  items = { { key = '/', name = 'Search commands' } }, help = help, hints = hints }
for _, presentation in ipairs({ false, true }) do
  local opts = { layout = 'fixed', width = 60, max_width = 60, max_height = 14,
    density = 'full', icons = false, details = { enabled = true, max_height = 8 } }
  if presentation then
    opts.presentation = assert(require('command_environment.core.presentation').resolve(nil, 'full'))
    opts.presentation.layout.width, opts.presentation.layout.max_width = 60, 60
    opts.presentation.layout.max_height = 14
  end
  local view, data = {}, vim.deepcopy(base)
  V.draw(view, data, opts)
  local original = config(view)
  data.details = { kind = 'picker', source = 'builtin', target = 'init.lua · lua', description = 'Search for commands' }
  V.draw(view, data, opts)
  H.eq(original, config(view), 'Details and hints keep the main footprint fixed')
  H.ok(view.details, 'Separate detail panel displays structured hints')
  local values = spans(view.details)
  H.ok(has_span(values, 'Ctrl+h', presentation and 'accent' or 'CommandTreeKey'), 'Key chord has accent semantics')
  H.ok(has_span(values, ' Details', presentation and 'normal' or 'CommandTreeDesc'), 'Help label has normal text semantics')
  H.ok(has_span(values, 'Target: init.lua', presentation and 'normal' or 'CommandTreeDesc'), 'Target has readable text semantics')
  H.ok(has_span(values, 'picker · builtin', presentation and 'muted' or 'CommandTreeMuted'), 'Provider metadata stays secondary')
  H.ok(text(view.details):find('Shift+PgUp/Down', 1, true), 'Details contains the complete scroll chord')
  data.error = 'Preview failed'
  V.draw(view, data, opts)
  H.eq(original, config(view), 'Error details keep the main footprint fixed')
  values = spans(view.details)
  H.ok(has_span(values, 'Preview failed', presentation and 'error' or 'CommandTreeError'), 'Error keeps error semantics')
  data.help, data.hints, data.details, data.error = 'Custom adapter instructions 한글', nil, nil, nil
  V.draw(view, data, opts)
  H.eq(original, config(view), 'Raw adapter help keeps the main footprint fixed')
  H.ok(text(view.details):find('Custom adapter instructions 한글', 1, true), 'Plain custom help remains available')
  V.close(view)
end

-- Long feedback cannot hide the only advertised scrolling control. The pinned
-- row yields in a one-row viewport, and every content row stays reachable.
do
  local view, data = {}, vim.deepcopy(base)
  local opts = { layout = 'fixed', width = 60, max_width = 60, max_height = 14,
    density = 'full', icons = false, details = { enabled = true, max_height = 4 } }
  data.error = 'Preview failed\nDiagnostic 2\nDiagnostic 3\nDiagnostic 4\nDiagnostic 5\nDiagnostic 6'
  V.draw(view, data, opts)
  local original = config(view)
  H.ok(text(view.details):find('Preview failed', 1, true), 'Overflow shows the first failure immediately')
  H.ok(text(view.details):find('Shift+PgUp/Down Scroll details', 1, true), 'Overflow advertises scrolling immediately')
  H.eq(3, view.details.content_visible, 'Pinned guidance leaves three content rows in a four-row pane')
  local seen = {}
  for _ = 1, view.details.total do
    for index in text(view.details):gmatch('Diagnostic (%d+)') do seen[tonumber(index)] = true end
    V.scroll_details(view, 1)
  end
  for index = 2, 6 do H.ok(seen[index], 'Diagnostic row ' .. index .. ' remains reachable') end
  H.eq(view.details.total - view.details.content_visible + 1, view.details.top, 'Overflow scroll clamps at its final complete page')
  H.ok(text(view.details):find('Shift+PgUp/Down Scroll details', 1, true), 'Final page keeps its scrolling control visible')
  H.eq(original, config(view), 'Pinned detail scrolling never changes main geometry')
  V.scroll_details(view, -10000)
  H.ok(text(view.details):find('Preview failed', 1, true), 'Scrolling returns to the original failure')
  opts.details.max_height = 1
  V.draw(view, data, opts)
  H.eq(nil, view.details.pinned, 'One-row details yield optional pinned help')
  H.ok(text(view.details):find('Preview failed', 1, true), 'One-row details prioritize failure feedback')
  V.close(view)

  data.help, data.hints = 'Enter Open · Esc Back', nil
  opts.details.max_height = 3
  opts._details_hint = { key = Guide.hint_pair('<C-u>', '<C-d>'), label = 'Scroll details', group = 'information' }
  V.draw(view, data, opts)
  H.ok(text(view.details):find('Ctrl+u/d Scroll details', 1, true), 'Workspace overflow shows actual configured scroll keys')
  V.scroll_details(view, 10000)
  H.ok(text(view.details):find('Ctrl+u/d Scroll details', 1, true), 'Workspace final page retains configured scroll keys')
  opts.details.max_height = 1
  V.scroll_details(view, -10000)
  V.draw(view, data, opts)
  H.eq(nil, view.details.pinned, 'Workspace one-row panel also yields its control')
  H.ok(text(view.details):find('Preview failed', 1, true), 'Workspace one-row panel retains first feedback')
  V.close(view)
end

-- Dynamic opt-out uses the same complete units and role spans in the main pane.
for _, presentation in ipairs({ false, true }) do
  local opts = { layout = 'dynamic', width = 60, max_width = 60, max_height = 20, density = 'full', icons = false }
  if presentation then
    opts.presentation = assert(require('command_environment.core.presentation').resolve(nil, 'full'))
    opts.presentation.layout.width, opts.presentation.layout.max_width = 60, 60
    opts.presentation.layout.max_height = 20
  end
  local view = {}
  V.draw(view, vim.deepcopy(base), opts)
  H.ok(text(view):find('Ctrl+h Details', 1, true), 'Dynamic help keeps key and short label together')
  H.ok(has_span(spans(view), 'Ctrl+h', presentation and 'accent' or 'CommandTreeKey'), 'Dynamic help keys retain semantic spans')
  V.close(view)
end

-- Factory Compact/Minimal keep their existing hidden-help policy. All modes
-- still retain an error, even when the viewport cannot host a separate pane.
vim.o.columns, vim.o.lines = 30, 14
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  local view = {}
  V.draw(view, vim.tbl_extend('force', vim.deepcopy(base), { error = 'Preview failed' }),
    { layout = 'fixed', width = 24, max_width = 24, max_height = 10, density = density,
      icons = false, details = { enabled = true, max_height = 6 } })
  local shown = text(view) .. (view.details and '\n' .. text(view.details) or '')
  H.ok(shown:find('Preview failed', 1, true), density .. ' preserves failure feedback on a narrow screen')
  if density ~= 'full' then H.ok(not shown:find('Ctrl+h', 1, true), density .. ' retains hidden optional guidance') end
  V.close(view)
end
for _, win in ipairs(vim.api.nvim_list_wins()) do
  H.eq('', vim.api.nvim_win_get_config(win).relative, 'Hint rendering leaves no owned popup after closing')
end
print('SHORTCUT HINTS: ' .. H.checks .. ' checks passed')
