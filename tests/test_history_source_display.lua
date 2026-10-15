-- Native source display geometry and lifecycle assertions. These checks do
-- not stand in for a person's visual approval of a terminal/font combination.
local H, K = require('helpers'), require('command_tree.keys')
local History, V = require('command_tree.history_mode'), require('command_tree.view')
vim.o.swapfile, vim.o.cmdheight = false, 1
vim.o.columns, vim.o.lines = 120, 40
V.highlights()
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local lines = { 'HISTORY_FIRST\t漢字🙂 source text' }
for row = 2, 100 do lines[row] = ('line %03d\tλ text'):format(row) end
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn = false, false, 'no'
vim.wo.statuscolumn, vim.wo.wrap, vim.wo.foldmethod = '', false, 'manual'
vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
local function options()
  local values = {}
  for name, info in pairs(vim.api.nvim_get_all_options_info()) do
    if info.scope == 'win' then values[name] = vim.api.nvim_get_option_value(name, { win = source_win }) end
  end
  return values
end
local function snapshot()
  local tree = vim.api.nvim_win_call(source_win, vim.fn.undotree)
  -- Native window changes may synchronize the current block. Entries, saved
  -- states and sequence identity must remain exact (as with preview :wundo).
  tree.synced, tree.time_cur = nil, nil
  return { lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
    tick = vim.api.nvim_buf_get_changedtick(source), tree = tree,
    view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview), cursor = vim.api.nvim_win_get_cursor(source_win),
    options = options(), layout = vim.fn.winlayout(),
    position = vim.api.nvim_win_get_position(source_win), width = vim.api.nvim_win_get_width(source_win),
    height = vim.api.nvim_win_get_height(source_win), modified = vim.bo[source].modified }
end
local function unchanged(before, label)
  H.eq(before, snapshot(), label .. ': source text, native undo, options, split layout, cursor and view stay exact')
  H.eq(source_win, vim.api.nvim_get_current_win(), label .. ': the original source retains focus')
  H.eq(source, vim.api.nvim_win_get_buf(source_win), label .. ': the original window retains its buffer')
end
local function floats()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then count = count + 1 end
  end
  return count
end
local function framed(state)
  local display = H.ok(state.source_display)
  H.ok(vim.api.nvim_win_is_valid(display.win))
  H.eq(source, vim.api.nvim_win_get_buf(display.win), 'The native display borrows the original source buffer')
  H.ok(display.win ~= source_win, 'History preserves the original source window identity')
  local source_pos = vim.api.nvim_win_get_position(source_win)
  local proxy = vim.api.nvim_win_get_config(display.win)
  H.eq(source_pos[1] + 1, proxy.row, 'A complete source row is reserved above its native display')
  H.eq(source_pos[2] + 1, proxy.col, 'A complete source column is reserved before all native columns')
  H.eq(vim.api.nvim_win_get_width(source_win) - 2, proxy.width)
  H.eq(vim.api.nvim_win_get_height(source_win) - 2, proxy.height)
  H.eq(false, proxy.focusable)
  H.eq(4, #state.frames, 'Every density keeps four symbolic workspace edges')
  local top = vim.api.nvim_win_get_config(state.frames[1].win)
  local bottom = vim.api.nvim_win_get_config(state.frames[2].win)
  local left = vim.api.nvim_win_get_config(state.frames[3].win)
  local right = vim.api.nvim_win_get_config(state.frames[4].win)
  H.ok(top.row < proxy.row and bottom.row >= proxy.row + proxy.height)
  H.ok(left.col < proxy.col and right.col >= proxy.col + proxy.width,
    'The complete native number/sign/text area is strictly inside symbolic edges')
  return display.win, proxy
end
local state = { ctx = K.context() }
local before = snapshot()
History.draw(state, { density = 'full' })
local proxy, geometry = framed(state)
vim.cmd.redraw()
local first = vim.fn.screenpos(proxy, 1, 1)
H.eq(geometry.row + 1, first.row, 'The first actual source character renders below the top frame')
H.eq(geometry.col + 1, first.col, 'Plain full-screen source retains its first character inside the left frame')
local wide_col = assert(lines[1]:find('漢', 1, true))
local wide = vim.fn.screenpos(proxy, 1, wide_col)
H.eq(2, wide.endcol - wide.col + 1, 'Wide Unicode remains native display text')
unchanged(before, 'Full-screen frame')
local edges, display_win = {}, proxy
for index, edge in ipairs(state.frames) do edges[index] = edge.win end
for _, density in ipairs({ 'compact', 'minimal', 'full' }) do
  History.draw(state, { density = density })
  proxy = framed(state)
  H.eq(display_win, proxy, 'Changing density retains the same source display')
  for index, edge in ipairs(state.frames) do H.eq(edges[index], edge.win) end
  unchanged(before, 'Density ' .. density)
end
History.clear(state)
H.eq(nil, state.source_display); H.eq(0, floats())
unchanged(before, 'Close')

-- The source's native manual fold structure, including a closed nested fold
-- inside an open outer fold, must survive the cloned window's smaller size.
vim.wo.number, vim.wo.relativenumber, vim.wo.numberwidth = true, true, 5
vim.wo.signcolumn, vim.wo.statuscolumn = 'yes:2', ''
vim.wo.scrollbind, vim.wo.cursorbind = true, true
vim.wo.wrap = true
vim.fn.sign_define('HistoryDisplayFixture', { text = '!!', texthl = 'ErrorMsg' })
vim.fn.sign_place(1, 'HistoryDisplayFixture', 'HistoryDisplayFixture', source, { lnum = 1 })
vim.cmd('2,12fold'); vim.cmd('normal! zR'); vim.cmd('4,8fold')
vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
before = snapshot()
state = { ctx = K.context() }
History.draw(state, { density = 'full' })
proxy, geometry = framed(state)
for _, name in ipairs({ 'number', 'relativenumber', 'numberwidth', 'signcolumn', 'statuscolumn',
  'wrap', 'foldmethod', 'foldenable', 'foldlevel', 'foldcolumn' }) do
  H.eq(vim.api.nvim_get_option_value(name, { win = source_win }),
    vim.api.nvim_get_option_value(name, { win = proxy }), 'Native source display inherits ' .. name)
end
H.eq(false, vim.wo[proxy].scrollbind); H.eq(false, vim.wo[proxy].cursorbind)
for _, row in ipairs({ 1, 2, 3, 4, 8, 9, 12, 13 }) do
  local function fold(win)
    return vim.api.nvim_win_call(win, function() return { vim.fn.foldlevel(row), vim.fn.foldclosed(row), vim.fn.foldclosedend(row) } end)
  end
  H.eq(fold(source_win), fold(proxy), 'Native clone retains manual fold nesting/closures at row ' .. row)
end
vim.cmd.redraw()
first = vim.fn.screenpos(proxy, 1, 1)
H.ok(first.col > geometry.col + 1, 'Number and sign columns precede source text inside the frame')
H.eq(vim.fn.getwininfo(source_win)[1].textoff, vim.fn.getwininfo(proxy)[1].textoff,
  'All configured sign and number cells remain in the native text area')
H.ok(vim.fn.getwininfo(proxy)[1].textoff >= 9)
unchanged(before, 'Native columns/folds/bindings')
History.clear(state)
unchanged(before, 'Native display cleanup')
vim.wo.scrollbind, vim.wo.cursorbind = false, false

-- A split and later resize update only the proxy/frame geometry. Neighboring
-- windows and the source's scrolled view are untouched on every draw/clear.
vim.cmd('vsplit')
local neighbor = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_call(source_win, function() vim.fn.winrestview({ lnum = 42, col = 4, topline = 32, leftcol = 0 }) end)
before = snapshot(); state = { ctx = K.context() }
History.draw(state, { density = 'minimal' }); framed(state)
unchanged(before, 'Split source')
vim.api.nvim_win_set_width(source_win, 44)
before = snapshot()
History.draw(state, { density = 'compact' }); framed(state)
unchanged(before, 'Resized split source')
History.clear(state); unchanged(before, 'Resized split cleanup')
vim.api.nvim_win_close(neighbor, true)

-- Allocate a source display and one frame edge, then fail the next edge.
-- All partial resources must be released without deleting the borrowed buf.
before = snapshot(); state = { ctx = K.context() }
local window, edge_calls = V.window, 0
V.window = function(view, text, config, frame)
  if frame then edge_calls = edge_calls + 1; if edge_calls == 2 then error('injected History frame allocation failure') end end
  return window(view, text, config, frame)
end
local ok, reason = pcall(History.draw, state, { density = 'full' })
V.window = window
H.eq(false, ok); H.ok(tostring(reason):find('injected History frame allocation failure', 1, true))
H.eq(nil, state.source_display); H.eq(0, floats())
H.ok(vim.api.nvim_buf_is_valid(source)); unchanged(before, 'Allocation failure')

-- A close failure remains owned and observable so the next cleanup can retry.
History.draw(state, { density = 'minimal' })
proxy = state.source_display.win
local close = vim.api.nvim_win_close
vim.api.nvim_win_close = function(win, force)
  if win == proxy then error('injected source display close failure') end
  return close(win, force)
end
ok, reason = pcall(History.clear, state)
vim.api.nvim_win_close = close
H.eq(false, ok); H.ok(tostring(reason):find('injected source display close failure', 1, true))
H.eq(proxy, state.source_display.win, 'Failed cleanup retains the owned proxy handle')
H.ok(vim.api.nvim_win_is_valid(proxy)); H.ok(vim.api.nvim_buf_is_valid(source))
History.clear(state); H.eq(0, floats()); unchanged(before, 'Retried cleanup')

-- Exercise actual workspace suspension/resume, whose History hooks own clear.
local manager = require('command_tree.workspaces').new()
local session = { ctx = K.context(), mode = 'workspace', running = true, stack = {}, path = {}, view = {}, density = 'full' }
local opts = { window = { width = 38 }, keys = { detail = '?' }, open_key = '\\' }
local frame = H.ok(manager:push(session, 'history'))
manager:draw(session, opts)
H.ok(frame.data.source_display and vim.api.nvim_win_is_valid(frame.data.source_display.win))
H.ok(manager:push(session, 'results'))
H.eq(nil, frame.data.source_display, 'Suspending History releases its native source display')
H.eq(0, floats(), 'Suspension releases the source display, frame and HUD')
manager:pop(session); manager:draw(session, opts)
H.ok(frame.data.source_display and vim.api.nvim_win_is_valid(frame.data.source_display.win))
manager:clear(session); H.eq(0, floats())
-- Preview serialization may synchronize an already open native undo block;
-- its entries and current state remain exact, as covered by History fixtures.
H.eq(before.lines, vim.api.nvim_buf_get_lines(source, 0, -1, false))
H.eq(before.view, vim.api.nvim_win_call(source_win, vim.fn.winsaveview))
H.eq(before.options, options())
print('History native source display: ' .. H.checks .. ' checks passed')
