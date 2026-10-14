-- Real Sessions exercise shared navigation and read-only diagnostic ownership.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE = require('re35')
local Lists, Feedback = require('command_tree.list_navigation'), require('command_tree.session.feedback')
local options = { usage = { path = false }, preferences = { path = false }, profile = { path = false },
  guidance = { first_run = false }, theme = { persist = false }, window = { icons = false },
  providers = { plugins = false, runner = false, lsp = false, ex = false, keymaps = false, native = false } }
vim.o.columns, vim.o.lines = 120, 45
CE.setup(options)
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(id)
  CE.close(); session.drafts:forget(id, K.context().buf)
  CE.open({ command = id, interactive = false })
end
local function workspace(id)
  CE.close(); CE.open({ workspace = id, interactive = false })
  return session.active.stack[#session.active.stack]
end
H.eq(1, Lists.move(1, 0, -1), 'Empty list never creates index zero')
H.eq(1, Lists.move(1, 1, -1), 'A single item remains selected')
H.eq(3, Lists.move(1, 3, -1)); H.eq(1, Lists.move(3, 3, 1))
H.eq(1, Lists.move(1, 3, -1, { wrap = false }))
H.eq(3, Lists.move(3, 3, 1, { wrap = false }))
H.eq(3, Lists.move(1, 3, 10), 'Page movement keeps viewport clamping')

local runs = 0
CE.register({ id = 'fixture.nav', name = 'Navigation fixture', run = function() runs = runs + 1 end,
  arguments = { { name = 'choice', kind = 'select', items = { 'Alpha', 'Beta', 'Gamma' } } } })
open('fixture.nav'); keys('<Up>')
H.eq(3, session.active.input.selected, 'Input Up wraps to last item')
keys('<Down>'); H.eq(1, session.active.input.selected, 'Input Down wraps to first item')
keys('<Up>/ma'); H.eq('Gamma', session.active.input.choices[session.active.input.selected])
keys('<C-u>'); H.eq(3, session.active.input.selected, 'Clearing a filter retains selected value, rather than numeric index')
keys('zz<Down><Up>'); H.eq(1, session.active.input.selected, 'Empty filtered list stays recoverable')
keys('<C-u><Esc>'); H.eq(0, runs)
session.options.navigation.wrap = false
session.active.input.selected = 1; keys('<Up>'); H.eq(1, session.active.input.selected)
session.active.input.selected = 3; keys('<Down>'); H.eq(3, session.active.input.selected)
session.options.navigation.wrap = true

CE.register({ id = 'fixture.review', name = 'Review fixture', run = function() runs = runs + 1 end,
  arguments = { { name = 'a' }, { name = 'b' } } })
open('fixture.review'); keys('a<CR>b<CR>'); H.eq('review', session.active.mode)
keys('<Down>'); H.eq(1, session.active.input.review_selected, 'Review action list wraps')
keys('<Up>'); H.eq(3, session.active.input.review_selected)
CE.close(); CE.open({ interactive = false }); keys('<Down>')
local tree_count = #session.active.tree_items
keys('<Up>'); H.eq(tree_count, session.active.tree_selection, 'Tree rows use the same list policy')
keys('<Down>'); H.eq(1, session.active.tree_selection)
keys('<C-w>'); local workspace_count = #session:workspace_choices()
keys('<Up>'); H.eq(workspace_count, session.active.selected, 'Workspace selector wraps')
keys('<Down>'); H.eq(1, session.active.selected)
CE.close(); CE.open({ interactive = false }); keys('/fixture')
local found = session:results(); H.ok(#found > 1)
keys('<Up>'); H.eq(#found, session.active.selected, 'Search results wrap')
keys('<Down>'); H.eq(1, session.active.selected)

local frame = workspace('settings')
local settings = require('command_tree.settings_editor').items(frame, session.active)
frame.data.selected, frame.data.selected_id = 1, settings[1].id
keys('<Up>'); H.eq(#settings, frame.data.selected, 'Settings navigation wraps')
keys('<Down>'); H.eq(1, frame.data.selected)
local History = require('command_tree.history_mode')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'timeline first state' })
frame = workspace('history'); keys('t')
local timeline = frame.data.timeline
H.ok(#timeline.entries >= 2, 'Native history has an original and an edited state')
timeline.selected = 1; keys('<Up>'); H.eq(#timeline.entries, timeline.selected, 'Timeline selection wraps without changing undo state')
local undo_sequence = History.sequence(frame.ctx).seq_cur
keys('<Down>'); H.eq(1, timeline.selected); H.eq(undo_sequence, History.sequence(frame.ctx).seq_cur)
session.options.navigation.wrap = false
keys('<Up>'); H.eq(1, timeline.selected, 'History honors the global opt-out')
session.options.navigation.wrap = true
CE.close()
local legacy = require('command_tree')
local actual_operations = legacy.operations
local stamp = vim.uv.hrtime()
legacy.operations = function() return { { id = 3, status = 'succeeded', name = 'Third', started = stamp, finished = stamp },
  { id = 2, status = 'failed', name = 'Second', started = stamp, finished = stamp },
  { id = 1, status = 'succeeded', name = 'First', started = stamp, finished = stamp } } end
frame = workspace('tasks'); keys('<Up>'); H.eq(3, frame.data.selected, 'Tasks list selection wraps')
keys('<Down>'); H.eq(1, frame.data.selected)
keys('<CR><Up>'); H.eq(1, frame.data.detail_row, 'Task detail scrolling retains clamping rather than wrap')
CE.close(); legacy.operations = actual_operations
local manager = { selections = {}, recipes = {}, env = { registry = CE.registry(), profile = { tools = {} } },
  context = function() return nil, 'No selected project' end }
CE.register_workspace(require('command_tree.project.recipe_workspace').definition(manager))
frame = workspace('project'); keys('<Up>'); H.eq(#frame.data.items, frame.data.selected, 'Project rows share the same wrap policy')
keys('<Down>'); H.eq(1, frame.data.selected)
CE.register_workspace(require('command_tree.board').definition({ id = 'fixture-board', name = 'Fixture board', commands = { 'fixture.nav', 'fixture.review' } }))
frame = workspace('fixture-board'); keys('<Up>'); H.eq(2, frame.data.selected, 'Board navigation wraps')
keys('<Down>'); H.eq(1, frame.data.selected)
local source = session.active.ctx.buf
vim.fn.setqflist({}, ' ', { items = { { bufnr = source, lnum = 1, col = 1, text = 'One' },
  { bufnr = source, lnum = 1, col = 1, text = 'Two' } } })
frame = workspace('results'); keys('q<Up>'); H.eq(2, frame.data.selected, 'Results navigation wraps')
keys('<Down>'); H.eq(1, frame.data.selected)

local preview_calls, cleanup_calls = 0, 0
local error_text = 'Cannot load selected theme\nProvider details: missing dependency\nSuggested action: install the declared theme dependency'
CE.register({ id = 'fixture.preview', name = 'Theme preview fixture', provider = 'fixture-provider',
  arguments = { { name = 'theme', kind = 'select', items = { 'Bad', 'Good', 'Other' } } },
  preview = function(_, args)
    preview_calls = preview_calls + 1
    if args.theme == 'Bad' then error(error_text, 0) end
    return function() cleanup_calls = cleanup_calls + 1 end
  end, run = function() runs = runs + 1 end })
open('fixture.preview')
local state, input = session.active, session.active.input
local record = Feedback.current(state)
H.ok(record.full_message:find(error_text, 1, true), 'Multiline preview diagnostic is retained with host context')
local retained_error = record.full_message
H.eq('fixture-provider', record.provider); H.eq('fixture.preview', record.command_id); H.eq('theme', record.field)
local calls, cleanup, navigation = preview_calls, cleanup_calls, state.navigation
keys('<C-h>'); H.eq('feedback', state.mode); H.ok(state.input == input)
keys('<CR><Down><C-d><Up><C-u>'); H.eq(calls, preview_calls); H.eq(cleanup, cleanup_calls)
H.eq(0, runs, 'Inspecting/scrolling a diagnostic cannot execute the selected choice')
keys('<Esc>'); H.eq('input', state.mode); H.ok(state.input == input); H.eq(1, input.selected)
H.eq(navigation, state.navigation, 'Diagnostic Inspect/Back preserves form ownership')
H.eq(retained_error, Feedback.current(state).full_message)
keys('<Up>'); H.eq(3, input.selected); H.eq(nil, Feedback.current(state), 'Successful preview supersedes its earlier error')
keys('<Down><C-h><Esc>'); H.eq('input', state.mode)
input.filtering, input.filter, input.filter_cursor, input.checked = true, 'draft', 5, { 'saved' }
keys('<C-h><Esc>')
H.eq('draft', input.filter); H.eq(5, input.filter_cursor); H.eq({ 'saved' }, input.checked)
H.eq(true, input.filtering, 'Inspection does not leave filtering or discard form state')
session:record_feedback('Preview', string.rep('한', 10000), input.command)
record = Feedback.current(state)
H.eq(true, record.truncated); H.ok(#record.full_message < 17000, 'Diagnostic bytes are bounded')
H.ok(pcall(vim.str_utfindex, record.full_message), 'Bounded diagnostic retains complete Unicode codepoints')
session:record_feedback('Preview', string.rep('line\n', 1000), input.command)
H.ok(#Feedback.current(state).lines <= 257, 'Diagnostic lines are bounded with an explicit truncation marker')

-- With panel opt-out, full Inspect remains readable through the main paged list.
state.input.filtering = false
session.options.window.layout = 'dynamic'
session:record_feedback('Preview', 'first line\nlast detail line', input.command)
keys('<C-h><Down>')
H.eq(2, state.feedback_offset)
local shown = table.concat(vim.api.nvim_buf_get_lines(state.view.buf, 0, -1, false), '\n')
H.ok(shown:find('last detail line', 1, true), 'Dynamic layout exposes the last diagnostic line')
keys('<Esc>'); session.options.window.layout = 'fixed'

CE.register({ id = 'fixture.rollback', name = 'Rollback fixture', provider = 'broken-theme-adapter',
  arguments = { { name = 'theme', kind = 'select', items = { 'One', 'Two' } } },
  preview = function() return function() error('Restore failed\nOriginal theme is not available', 0) end end,
  run = function() runs = runs + 1 end })
open('fixture.rollback'); keys('<Down>')
state, input = session.active, session.active.input
H.eq(true, state.preview_restore_failed)
H.ok(Feedback.current(state).full_message:find('Original theme is not available', 1, true))
keys('<C-h><Esc>'); H.ok(state.input == input); H.eq('input', state.mode)
keys('<CR>'); H.eq(0, runs, 'Failed preview rollback cannot be forgotten to authorize Apply')
local entered, why = session:enter_workspace('editor')
H.eq(false, entered); H.ok(why:find('close and reopen', 1, true))
CE.close()

CE.register({ id = 'fixture.plain', name = 'Plain text', arguments = { { name = 'value' } }, run = function() end })
open('fixture.plain'); keys('draft<C-h>')
H.eq('input', session.active.mode); H.eq('draft', session.active.input.text, 'Inspect without a diagnostic never replaces a live form')
CE.close(); CE.open({ interactive = false })
local original = session.active.ctx.win
local secondary = vim.api.nvim_open_win(session.active.ctx.buf, false, { split = 'right', win = original })
H.ok(original ~= secondary)
H.ok(session:enter_workspace('editor')); H.eq(false, CE.state().active)
H.eq(original, vim.api.nvim_get_current_win(), 'Editor destination returns to the original native window')
vim.api.nvim_win_close(secondary, true)
CE.open({ interactive = false })
local stale = session.active.ctx.win
local closed = vim.api.nvim_open_win(session.active.ctx.buf, false, { split = 'right', win = stale })
vim.api.nvim_win_close(closed, true)
session.active.ctx.win = closed
entered, why = session:enter_workspace('editor')
H.eq(false, entered); H.ok(why:find('no longer available', 1, true)); H.eq(true, CE.state().active)
CE.close(); CE.disable(); Session.new = construct
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative, 'No diagnostic or preview windows leak') end
print('Navigation and diagnostic ownership checks: ' .. H.checks)
