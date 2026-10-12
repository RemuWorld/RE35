-- Actual float geometry and highlight checks; this is not a human visual review.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local V = require('command_tree.view')
V.highlights()
for _, ambiguity in ipairs({ 'single', 'double' }) do
  vim.o.ambiwidth = ambiguity
  for width = 1, 16 do
    H.ok(V.width(V.clip('한글 / long label', width)) <= width, ambiguity .. ': clipped labels respect cell width ' .. width)
    for cursor = 0, vim.fn.strchars('가나다xyz') do
      local value = V.viewport('가나다xyz', cursor, width)
      H.ok(V.width(value) <= width, ambiguity .. ': editing viewport respects cell width ' .. width)
      H.ok(value:find('▏', 1, true) or value:find('|', 1, true), ambiguity .. ': narrow viewport keeps a visible caret')
    end
  end
end
vim.o.ambiwidth = 'single'
local view = {}
local function body()
  return vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
end
local function title(config)
  local parts = {}
  for _, chunk in ipairs(config.title or {}) do parts[#parts + 1] = chunk[1] end
  return table.concat(parts)
end
local function contains(text)
  return table.concat(body(), '\n'):find(text, 1, true) ~= nil
end
local function selected_rows()
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group == 'CommandTreeSelected' then rows[mark[2]] = true end
  end
  return rows
end
local function geometry(label)
  local config = vim.api.nvim_win_get_config(view.win)
  local border = type(config.border) == 'table' and #config.border > 0 and 2 or 0
  H.ok(config.row >= 0 and config.col >= 0, label .. ': float starts within screen')
  H.ok(config.row + config.height + border <= vim.o.lines - vim.o.cmdheight,
    label .. ': float stays above command line')
  H.ok(config.col + config.width + border <= vim.o.columns, label .. ': float stays inside columns')
  H.eq(config.height, #body(), label .. ': float has no spare vertical rows')
  for index, value in ipairs(body()) do
    H.ok(V.width(value) <= config.width, label .. ': row ' .. index .. ' fits cell width')
  end
  H.ok(V.width(title(config)) <= config.width, label .. ': border title fits cell width')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true })) do
    local row, column, detail = mark[2], mark[3], mark[4]
    H.ok(row < #body() and column <= #body()[row + 1], label .. ': highlight starts on a visible byte')
    H.ok(detail.end_row == row and detail.end_col <= #body()[row + 1], label .. ': highlight ends on a visible byte')
  end
  return config
end

-- A long title must leave Compact's page position readable.
local long_items = {}
for index = 1, 12 do long_items[index] = { key = tostring(index), name = 'Choice ' .. index } end
V.draw(view, { title = string.rep('Project', 100), path = '\\', items = long_items, selected = 7 },
  { density = 'compact', width = 24, max_width = 24, compact_rows = 6, icons = false })
local config = geometry('long Compact title')
H.ok(title(config):find('2/2', 1, true), 'long Compact title retains current page')
H.eq(7, view.visible_first, 'Compact second page begins at row seven')
H.eq(12, view.visible_last, 'Compact second page ends at row twelve')
H.ok(contains('Choice 7'), 'Compact selected choice is readable')
V.close(view)

-- Keys yield to the command's name when the panel is too narrow for columns.
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  V.draw(view, { path = '\\', items = { { key = 'first-long-key', name = 'Visible label' } }, selected = 1 },
    { density = density, width = 10, max_width = 10, icons = false })
  geometry('narrow label ' .. density)
  H.ok(contains('Vis'), 'narrow ' .. density .. ' preserves command-name cells')
  H.ok(contains('›'), 'narrow ' .. density .. ' preserves selection marker')
  V.close(view)
end

-- The same unavailable reason should occupy one row, including after Run.
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  V.draw(view, { path = '\\', items = { { key = 'x', name = 'Unavailable', disabled = true } }, selected = 1,
    details = { reason = 'Tool missing' }, message = 'Tool missing' }, { density = density, width = 48, icons = false })
  geometry('single warning ' .. density)
  local count = 0
  for _, value in ipairs(body()) do if value:find('Tool missing', 1, true) then count = count + 1 end end
  H.eq(1, count, density .. ' renders an identical availability/error reason once')
  V.close(view)
end

-- A one-row owned source can show the error, but cannot report hidden choices.
vim.cmd('new')
local source = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_height(source, 1)
V.draw(view, { path = '\\', items = { { key = 'one', name = 'Only item' } }, selected = 1, message = 'Missing tool' },
  { density = 'minimal', width = 24, target_win = source })
geometry('tiny target')
H.ok(contains('Missing tool'), 'tiny target retains failure feedback')
H.eq(nil, view.visible_first, 'trimmed item is not reported as the first visible choice')
H.eq(nil, view.visible_last, 'trimmed item is not reported as the last visible choice')
local position = vim.api.nvim_win_get_position(source)
config = vim.api.nvim_win_get_config(view.win)
H.eq(V.width(body()[1]), config.width, 'Minimal width follows retained content after short-screen trimming')
H.ok(config.row >= position[1] and config.row + config.height <= position[1] + vim.api.nvim_win_get_height(source),
  'tiny target popup remains inside its source window')
V.close(view)
vim.api.nvim_win_close(source, true)

-- Freeze a small representative matrix rather than multiplying every axis.
local scenes = {
  project = { title = 'Project', label = 'Debug / target A', items = {
    { key = 'project', name = 'RE35' }, { key = 'config', name = 'Debug' },
    { key = 'target', name = 'target A' }, { key = 'run', name = 'Build / Test' },
  }, selected = 4 },
  tasks = { title = 'Tasks', label = '2 tasks', items = {
    { key = '#31', name = 'failed · Build', detail = 'exit 1' },
    { key = '#32', name = 'pending · Test', detail = 'running' },
  }, selected = 1, message = 'Build failed; results available' },
  results = { title = 'Results', label = 'Build locations', items = {
    { key = '1', name = 'src/main.cpp:14:7 error' }, { key = '2', name = 'include/api.hpp:8:2 warning' },
  }, selected = 1 },
  search = { title = 'Search', label = 'All commands', query_text = '빌드', query_cursor = 2, query = '빌드▏',
    items = { { key = '', name = '빌드 C++ target' }, { key = '', name = 'Build current target' } }, selected = 1 },
  input = { title = 'Run recipe', label = 'Target', input = true, items = {
    { key = '>', name = 'target A', editing_text = '타깃 A', editing_cursor = 4 },
  }, selected = 1 },
  empty = { title = 'Results', label = 'Diagnostics', items = {}, content = { 'No diagnostics in this source' } },
}
for _, size in ipairs({ { 120, 42, 64 }, { 30, 14, 24 } }) do
  vim.o.columns, vim.o.lines = size[1], size[2]
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    for name, scene in pairs(scenes) do
      local data = vim.deepcopy(scene)
      data.path, data.help = '\\ › ' .. name, 'Enter Open · Esc Back · ? View'
      V.draw(view, data, { density = density, width = size[3], max_width = size[3], icons = false })
      config = geometry(name .. '/' .. density .. '/' .. size[1])
      if scene.selected and not scene.input then
        H.ok(next(selected_rows()) ~= nil, name .. ': selected row has a visible highlight in ' .. density)
      end
      if density == 'minimal' then
        H.eq(nil, config.title, name .. ': Minimal has no title')
        H.ok(config.border == nil or config.border == 'none' or #config.border == 0, name .. ': Minimal popup has no border')
        H.ok(not contains('Esc Back'), name .. ': Minimal omits help chrome')
        for _, value in ipairs(body()) do
          H.ok(value:sub(1, 2) == '  ' and value:sub(-2) == '  ', name .. ': Minimal retains horizontal breathing room')
        end
      end
      V.close(view)
    end
  end
end

-- Density changes only the history HUD; the four symbolic source edges remain.
vim.o.columns, vim.o.lines = 100, 35
local History = require('command_tree.history_mode')
local ctx = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(),
  tab = vim.api.nvim_get_current_tabpage() }
local state = { ctx = ctx }
History.draw(state, { density = 'minimal' })
H.eq(4, #state.frames, 'Minimal retains all four history workspace frame edges')
V.close(state.hud)
for _, edge in ipairs(state.frames) do H.ok(vim.api.nvim_win_is_valid(edge.win), 'history symbolic edge remains visible') end
for _, edge in ipairs(state.frames) do V.close(edge) end

-- Follow real Session Down/Up handlers across Compact pages without executing.
local Session = require('command_tree.session')
local create, session = Session.new
Session.new = function(services) session = create(services); return session end
local CE, commands, executions = require('command_tree'), {}, 0
for index = 1, 12 do commands[index] = { id = ('layout.row.%02d'):format(index), name = ('UI row %02d'):format(index),
  run = function() executions = executions + 1 end } end
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false }, profile = { path = false },
  providers = { builtin = false, plugins = false, runner = false, lsp = false, ex = false, native = false, keymaps = false },
  commands = commands, window = { width = 40, max_width = 40, density = 'compact', icons = false } })
Session.new = create
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
CE.open({ search = 'UI row', interactive = false })
view = session.active.view
for index = 1, 12 do
  if index > 1 then session:handle('<Down>') end
  H.eq(index, CE.state().selected, 'Compact Down advances exactly one command')
  H.ok(contains(('UI row %02d'):format(index)), 'Compact selected command remains readable after Down')
  H.ok(index >= view.visible_first and index <= view.visible_last, 'Compact selected command belongs to visible page')
end
for index = 11, 1, -1 do
  session:handle('<Up>')
  H.eq(index, CE.state().selected, 'Compact Up reverses one command across page boundaries')
  H.ok(contains(('UI row %02d'):format(index)), 'Compact selected command remains readable after Up')
end
session:handle('<F1>')
H.eq('minimal', CE.state().density, 'shared density action changes Compact to Minimal')
H.eq(1, CE.state().selected, 'density change preserves selected command')
H.ok(contains('UI row 01'), 'Minimal keeps the selected command readable after mode change')
H.eq(0, executions, 'navigation and density changes do not execute commands')
H.eq(source_buf, vim.api.nvim_get_current_buf(), 'popup navigation does not replace source buffer')
H.eq(source_win, vim.api.nvim_get_current_win(), 'popup navigation keeps the source window focused')
CE.close()
for _, win in ipairs(vim.api.nvim_list_wins()) do
  H.eq('', vim.api.nvim_win_get_config(win).relative, 'all audited popup windows close cleanly')
end
print('VIEW LAYOUT: ' .. H.checks .. ' checks passed')
