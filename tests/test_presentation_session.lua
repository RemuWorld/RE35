-- Switching appearance must preserve live interaction and source ownership.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
vim.o.columns, vim.o.lines = 100, 36
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'source alpha', 'source beta' })
vim.api.nvim_win_set_cursor(0, { 2, 3 })
local source_win = vim.api.nvim_get_current_win()
local profile = Profile.empty()
profile.presentation = { version = 1, selected = 'minimal', presets = {
  focus = { name = 'Focus', extends = 'compact', spacing = { horizontal = 4 }, decoration = { border = 'double' } },
} }
profile.workspaces.templates = { { id = 'fixture-board', name = 'Fixture Board', commands = { 'fixture.alpha', 'fixture.beta' } } }
local executions = 0
local function action() executions = executions + 1 end
CE.setup({ profile = { path = false, data = profile }, preferences = { path = false }, usage = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
  commands = {
    { id = 'fixture.alpha', name = 'Fixture alpha', path = 'xa', run = action },
    { id = 'fixture.beta', name = 'Fixture beta', path = 'xb', run = action },
    { id = 'fixture.form', name = 'Fixture input', arguments = { { name = 'value', required = true } }, run = action },
    { id = 'fixture.review', name = 'Fixture review', persistent = false,
      arguments = { { name = 'first', required = true }, { name = 'second', required = true } }, run = action },
  } })
local source_snapshot = { lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
  tick = vim.api.nvim_buf_get_changedtick(source), cursor = vim.api.nvim_win_get_cursor(source_win) }
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(options)
  CE.close(); vim.api.nvim_set_current_win(source_win)
  H.ok(CE.open(vim.tbl_extend('force', { interactive = false }, options or {})))
  return session.active
end
local function unchanged_source()
  H.eq(source_snapshot.lines, vim.api.nvim_buf_get_lines(source, 0, -1, false), 'View switching never edits source text')
  H.eq(source_snapshot.tick, vim.api.nvim_buf_get_changedtick(source), 'View switching never advances document revision')
  H.eq(source_snapshot.cursor, vim.api.nvim_win_get_cursor(source_win), 'View switching preserves source cursor')
  H.eq(0, executions, 'No command executes during view switching')
end
local next_id = { full = 'compact', compact = 'minimal', minimal = 'focus', focus = 'full' }
local expected_density = { full = 'full', compact = 'compact', minimal = 'minimal', focus = 'compact' }
local function cycle(key, verify)
  local state, id = session.active, assert(session.active.presentation_id)
  local target = next_id[id]
  keys(key)
  H.ok(session.active == state, 'Cycling preserves the exact active Session state')
  H.eq(target, state.presentation_id, 'Cycle order is Full, Compact, Minimal, then user presets')
  H.eq(expected_density[target], state.density)
  H.eq(target, CE.profile().presentation.selected, 'The selected named mode is saved in the portable profile')
  verify(state)
  unchanged_source()
end

local state = open({ keys = 'x' })
H.eq('minimal', state.presentation_id, 'Initial selection resolves the configured named preset')
keys('<Down>')
local path, selected, context = vim.deepcopy(state.path), vim.deepcopy(state.tree_selected_entry), vim.deepcopy(state.ctx)
for _ = 1, 4 do cycle('?', function(current)
  H.eq('tree', current.mode); H.eq(path, current.path)
  H.eq(selected, current.tree_selected_entry, 'Tree selection survives every renderer mode')
  H.eq(context, current.ctx)
end) end
CE.close(); state = open()
H.eq('minimal', state.presentation_id, 'Reopening restores the saved preset rather than a factory mode')

state = open({ command = 'fixture.form' })
keys('abc한글<Left><Left>')
local input, text, cursor = state.input, state.input.text, state.input.cursor
context = vim.deepcopy(input.context)
for _ = 1, 4 do cycle('<F1>', function(current)
  H.eq('input', current.mode); H.ok(current.input == input, 'The exact live form object survives style changes')
  H.eq(text, input.text); H.eq(cursor, input.cursor); H.eq(context, input.context)
end) end
keys('?')
H.eq('abc?한글', input.text, 'Question mark remains literal when actual text editing owns it')
H.eq('minimal', state.presentation_id)

state = open({ command = 'fixture.review' })
keys('original-A<CR>original-B<CR>')
H.eq('review', state.mode)
input = state.input
local args, review_selected = vim.deepcopy(input.args), input.review_selected
context = vim.deepcopy(input.context)
for _ = 1, 4 do cycle('<F1>', function(current)
  H.eq('review', current.mode); H.ok(current.input == input, 'Review keeps the original form object')
  H.eq(args, input.args, 'Review keeps submitted arguments without recreating or executing the form')
  H.eq(context, input.context); H.eq(review_selected, input.review_selected)
end) end

state = open({ search = 'fixture' }); keys('<Down>')
local query, query_cursor, search_id, search_selected = state.query, state.query_cursor, state.selected_id, state.selected
context = vim.deepcopy(state.ctx)
for _ = 1, 4 do cycle('<F1>', function(current)
  H.eq('search', current.mode); H.eq(query, current.query); H.eq(query_cursor, current.query_cursor)
  H.eq(search_id, current.selected_id); H.eq(search_selected, current.selected)
  H.eq(context, current.ctx)
end) end

state = open({ workspace = 'fixture-board' }); keys('<Down>')
local stack, board = state.stack, state.stack[#state.stack]
local board_selection = board.data.selected
context = vim.deepcopy(state.ctx)
for _ = 1, 4 do cycle('?', function(current)
  H.eq('workspace', current.mode); H.ok(current.stack == stack)
  H.ok(current.stack[#current.stack] == board, 'Workspace switches retain the exact frame stack')
  H.eq(board_selection, board.data.selected); H.eq(context, current.ctx)
end) end

state = open({ workspace = 'history' })
local history = state.stack[#state.stack]
H.eq(4, #history.data.frames, 'History marks the source with four symbolic edge windows')
local edge_windows = {}
for index, part in ipairs(history.data.frames) do edge_windows[index] = part.win; H.ok(vim.api.nvim_win_is_valid(part.win)) end
for _ = 1, 4 do cycle('?', function(current)
  H.ok(current.stack[#current.stack] == history)
  H.eq(4, #history.data.frames, 'Minimal popup borders do not erase the History source frame')
  for index, part in ipairs(history.data.frames) do
    H.eq(edge_windows[index], part.win, 'Style changes reuse the exact symbolic source edge window')
    H.ok(vim.api.nvim_win_is_valid(part.win))
  end
end) end
keys('t')
local timeline = H.ok(history.data.timeline)
local timeline_selected = timeline.selected
for _ = 1, 4 do cycle('<F1>', function(current)
  H.ok(current.stack[#current.stack] == history); H.ok(history.data.timeline == timeline)
  H.eq(timeline_selected, timeline.selected, 'Timeline selection is independent of the presentation preset')
end) end

-- Drive real input refusal through an actual four-line screen. No test writes
-- the renderer's completeness flags or bypasses the normal Enter path.
state = open({ command = 'fixture.form' }); keys('ready')
input = state.input
vim.o.columns, vim.o.lines = 12, 4
-- Accept refreshes geometry after resize, without a manual redraw by the test.
keys('<CR>')
H.eq(false, state.view.presentation_input_complete, 'A tiny real viewport cannot show the required prompt and current value: '
  .. vim.inspect({ columns = vim.o.columns, lines = vim.o.lines,
    geometry = vim.api.nvim_win_get_config(state.view.win),
    text = vim.api.nvim_buf_get_lines(state.view.buf, 0, -1, false) }))
keys('<CR>')
H.eq('input', state.mode); H.ok(state.input == input)
H.eq(0, executions, 'Enter refuses an unrepresentable input instead of executing it')
H.ok(state.message:find('Required input facts', 1, true))
vim.o.columns, vim.o.lines = 100, 36
session:draw()
H.eq(true, state.view.presentation_input_complete, 'Enlarging the real viewport makes input readable again')

state = open({ command = 'fixture.review' })
H.eq('input', state.mode); H.eq(1, state.input.index, 'Viewport case starts with a fresh first argument')
keys('saved-A<CR>saved-B<CR>')
H.ok(session.active == state); H.eq('review', state.mode)
input = state.input; args = vim.deepcopy(input.args)
H.eq({ first = 'saved-A', second = 'saved-B' }, args, 'This review owns only the current case inputs')
vim.o.columns, vim.o.lines = 12, 4
keys('<CR>')
H.eq(false, state.view.presentation_review_complete, 'A tiny real viewport reports incomplete command review: '
  .. vim.inspect({ mode = state.mode, columns = vim.o.columns, lines = vim.o.lines,
    message = state.message, executions = executions, input = state.input and state.input.review_selected,
    geometry = state.view.win and vim.api.nvim_win_is_valid(state.view.win) and vim.api.nvim_win_get_config(state.view.win),
    text = state.view.buf and vim.api.nvim_buf_is_valid(state.view.buf) and vim.api.nvim_buf_get_lines(state.view.buf, 0, -1, false) }))
keys('<CR>')
H.eq('review', state.mode); H.ok(state.input == input); H.eq(args, input.args)
H.eq(0, executions, 'Enter refuses incomplete review without running the command')
vim.o.columns, vim.o.lines = 100, 36
session:draw()
H.eq(true, state.view.presentation_review_complete, 'Enlarging restores required command review facts')

-- F1 while the first Settings prompt is open must not save over the baseline
-- captured before the draft exists. The accepted input remains reviewable.
state = open({ workspace = 'settings', workspace_data = { section = 'ui' } })
local settings = state.stack[#state.stack]
local Editor = require('command_tree.settings_editor')
local before_settings = CE.profile()
local found = false
for _, item in ipairs(Editor.items(settings, state)) do if item.id == 'width' then found = true end end
H.ok(found); settings.data.selected_id = 'width'; session:draw(); keys('<CR><C-u>77')
H.eq('input', state.mode); H.eq(nil, settings.data.draft)
input = state.input
keys('<F1>')
H.ok(state.input == input); H.eq('77', input.text)
H.eq(before_settings, CE.profile(), 'Cycling inside the first Settings prompt is session-only')
keys('<CR>')
H.eq(true, settings.data.review); H.eq(77, settings.data.draft.ui.width)
vim.o.columns, vim.o.lines = 12, 4
-- Deliberately omit draw after resize: Apply must use fresh geometry instead
-- of the previously readable wide-screen flag.
keys('a')
H.eq(before_settings, CE.profile(), 'A resize cannot make Apply rely on an old complete-review flag')
session:draw()
H.eq(false, settings.view.presentation_review_complete, 'Actual Settings review refuses a tiny viewport')
keys('a')
H.eq(before_settings, CE.profile(), 'Apply refuses an unrepresentable Settings review')
H.eq(true, settings.data.review); H.eq(77, settings.data.draft.ui.width)
H.ok(settings.data.message:find('Review facts', 1, true))
keys('e')
H.eq(nil, settings.data.review)
H.eq(false, settings.view.presentation_review_complete, 'Continue editing retains whole-draft viewport preflight')
keys('a')
H.eq(before_settings, CE.profile(), 'Continue editing cannot bypass incomplete required review facts')
H.eq(77, settings.data.draft.ui.width)
vim.o.columns, vim.o.lines = 100, 36
session:draw()
H.eq(true, settings.view.presentation_review_complete, 'Enlarging restores readable Before and After facts')
keys('a')
H.eq(77, CE.profile().ui.width, 'Readable Settings Apply accepts the original first-prompt baseline')
keys('u'); H.eq(before_settings, CE.profile(), 'Settings Undo restores the exact profile after viewport refusal')
H.eq(0, executions)
CE.close(); CE.disable(); Session.new = create
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative, 'Closing releases all preset view windows') end
print('Presentation Session state: ' .. H.checks .. ' checks passed')
