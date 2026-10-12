-- Actual Session scenes and retained Executor results, not synthetic scene labels.
-- Native geometry/state is checked; terminal font/comfort remains owner judgment.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('presentation-scenes')
local filename = folder .. '/source-한글.cpp'
vim.fn.writefile({ 'source alpha', 'source beta', 'source gamma' }, filename)
vim.cmd('edit ' .. vim.fn.fnameescape(filename))
vim.o.columns, vim.o.lines = 110, 36
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local baseline = { lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
  tick = vim.api.nvim_buf_get_changedtick(source), cursor = vim.api.nvim_win_get_cursor(source_win) }
local profile = Profile.empty()
profile.presentation = { version = 1, selected = 'full', presets = {} }
local runs = 0
CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
  commands = {
    { id = 'fixture.alpha', name = 'Fixture alpha', path = 'xa', run = function() runs = runs + 1 end },
    { id = 'fixture.beta', name = 'Fixture beta 한글', path = 'xb', run = function() runs = runs + 1 end },
    { id = 'fixture.form', name = 'Fixture input', arguments = { { name = 'value', prompt = 'Target configuration', required = true } },
      run = function() runs = runs + 1 end },
    { id = 'fixture.review', name = 'Fixture review', persistent = false,
      arguments = { { name = 'configuration', required = true }, { name = 'target', required = true } },
      run = function() runs = runs + 1 end },
    { id = 'fixture.failed', name = 'Build 실패', path = 'tf', async = true, run = function(_, _, done)
      runs = runs + 1
      done(false, { exit_code = 7, locations_status = 'partial', locations_truncated = true,
        locations_message = 'partial results: captured output limit', locations = {
          { filename = filename, line = 1, col = 2, text = 'First compiler error', valid = true },
          { filename = filename, line = 2, col = 3, text = 'Second compiler error 한글', valid = true },
        } })
    end },
    { id = 'fixture.success', name = 'Other successful task', path = 'ts', run = function() runs = runs + 1; return true end },
  } })
CE.execute('fixture.failed', {}, { interactive = false })
H.ok(CE.execute('fixture.success', {}, { interactive = false }))
local failed
for _, operation in ipairs(CE.operations()) do if operation.command_id == 'fixture.failed' then failed = operation end end
H.ok(failed); H.eq('failed', failed.status)
local admitted_runs, operation_count = runs, #CE.operations()
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(options)
  CE.close(); vim.api.nvim_set_current_win(source_win)
  H.ok(CE.open(vim.tbl_extend('force', { interactive = false }, options or {})))
  return session.active
end
local function visible(view) return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), '\n') end
local function has(view, text) return visible(view):find(text, 1, true) ~= nil end
local function wrapped_has(view, text)
  local pieces = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)) do
    pieces[#pieces + 1] = line:gsub('^%s+', ''):gsub('%s+$', '')
  end
  return table.concat(pieces):find(text, 1, true) ~= nil
end
local coverage = {}
local function modes(scene, view, verify)
  local state = session.active
  for _, mode in ipairs({ 'full', 'compact', 'minimal' }) do
    for _ = 1, 3 do if state.presentation_id == mode then break end; keys('<F1>') end
    H.eq(mode, state.presentation_id)
    H.ok(session.active == state, scene .. ': renderer changes retain the exact Session owner')
    verify(mode)
    local current = view()
    H.eq(scene, current.presentation_report.scene, scene .. ': real navigation selects the shared scene')
    local geometry = vim.api.nvim_win_get_config(current.win)
    H.eq(#vim.api.nvim_buf_get_lines(current.buf, 0, -1, false), geometry.height)
    H.eq(source_win, vim.api.nvim_get_current_win(), 'Style changes preserve native source focus')
    if mode == 'minimal' then H.eq(nil, geometry.title, 'Minimal omits the routine floating title') end
    coverage[scene .. '/' .. mode] = true
    H.eq(admitted_runs, runs, 'Appearance/navigation never dispatches a command')
    H.eq(operation_count, #CE.operations(), 'Appearance/navigation never creates an execution')
  end
end

local state = open({ keys = 'x' }); keys('<Down><Down>')
local entry, path = vim.deepcopy(state.tree_selected_entry), vim.deepcopy(state.path)
modes('tree', function() return state.view end, function()
  H.eq(entry, state.tree_selected_entry); H.eq(path, state.path)
  H.ok(has(state.view, 'Fixture beta'), 'The actual selected tree command remains readable')
end)

state = open({ search = 'fixture' }); keys('<Down>')
local query, query_cursor, selected_id = state.query, state.query_cursor, state.selected_id
modes('search', function() return state.view end, function()
  H.eq(query, state.query); H.eq(query_cursor, state.query_cursor); H.eq(selected_id, state.selected_id)
  H.ok(state.selected >= state.view.visible_first and state.selected <= state.view.visible_last,
    'The stable selected search result stays in the actual float')
end)

state = open({ command = 'fixture.form' }); keys('Debug한글<Left>')
local input, text, cursor = state.input, state.input.text, state.input.cursor
modes('input', function() return state.view end, function()
  H.ok(state.input == input); H.eq(text, input.text); H.eq(cursor, input.cursor)
  H.ok(has(state.view, 'Target configuration'), 'The required input question survives optional details policy')
  H.eq(true, state.view.presentation_input_complete)
end)
keys('<BS>?')
H.eq('Debug?글', input.text, 'Ordinary Unicode editing still owns Backspace and question mark after switching views')

state = open({ command = 'fixture.review' }); keys('Debug<CR>target-A<CR>')
H.eq('review', state.mode)
input = state.input
local args, selection = vim.deepcopy(input.args), input.review_selected
modes('review', function() return state.view end, function()
  H.ok(state.input == input); H.eq(args, input.args); H.eq(selection, input.review_selected)
  H.eq(true, state.view.presentation_review_complete)
  H.ok(has(state.view, 'configuration = Debug') and has(state.view, 'target = target-A')
    and has(state.view, 'Target:'), 'Submitted arguments and original target remain reviewable')
end)

state = open({ workspace = 'tasks' })
local frame = state.stack[#state.stack]
for _ = 1, 3 do if frame.data.selected_id == failed.id then break end; keys('<Down>') end
H.eq(failed.id, frame.data.selected_id)
keys('<CR><Down><Down>')
local row, task_frame = frame.data.detail_row, frame
modes('tasks', function() return frame.view end, function()
  H.ok(state.stack[#state.stack] == task_frame); H.eq(failed.id, frame.data.detail_id); H.eq(row, frame.data.detail_row)
  H.ok(has(frame.view, '#' .. failed.id .. ' Build 실패'), 'Owned task identity remains visible while browsing detail rows')
  H.eq(true, frame.view.presentation_facts_complete)
end)
vim.o.columns, vim.o.lines = 38, 18
session:draw()
H.eq(row, frame.data.detail_row); H.eq(failed.id, frame.data.detail_id)
H.ok(has(frame.view, 'Build 실패'), 'A resized Minimal Tasks view keeps its owned task header')
vim.o.columns, vim.o.lines = 110, 36

CE.close(); vim.api.nvim_set_current_win(source_win)
H.ok(CE.open_task_results(failed.id, { interactive = false }))
state, frame = session.active, session.active.stack[#session.active.stack]
keys('<Down>')
local result_id, result_revision = frame.data.selected_id, frame.data.result.revision
local canonical_target = frame.data.items[frame.data.selected].detail
modes('results', function() return frame.view end, function()
  H.eq(failed.id, frame.data.task_id); H.eq(result_id, frame.data.selected_id); H.eq(result_revision, frame.data.result.revision)
  H.eq(canonical_target, frame.data.items[frame.data.selected].detail, 'Rendering does not rewrite the canonical source target')
  H.ok(has(frame.view, '#' .. failed.id .. ' Build 실패'), 'Results retains the originating task identity')
  H.ok(wrapped_has(frame.view, 'source-한글.cpp:2:3'), 'The actual selected source coordinate remains fully readable across wrapped rows')
  H.ok(has(frame.view, 'partial results:'), 'Partial output remains explicit regardless optional status')
  H.eq(true, frame.view.presentation_facts_complete)
end)
local target_before = frame.data.items[frame.data.selected]
vim.o.columns, vim.o.lines = 38, 18
session:draw()
H.eq(result_id, frame.data.selected_id); H.eq(result_revision, frame.data.result.revision)
H.ok(frame.data.items[frame.data.selected] == target_before, 'Resize keeps the exact selected Results record')
H.eq(true, frame.view.presentation_facts_complete, 'Required target wraps in a narrow ordinary viewport')
H.ok(wrapped_has(frame.view, ':2:3'), 'The complete target coordinate survives wrapping')

-- Display incompleteness is truthful but does not grant or withdraw location
-- authority. Existing owned-source validation remains the navigation gate.
vim.o.columns, vim.o.lines = 12, 4
session:draw()
H.eq(false, frame.view.presentation_facts_complete)
H.ok(frame.view.presentation_facts_reason:find('source or owner facts', 1, true))
H.eq(result_id, frame.data.selected_id); H.eq(canonical_target, frame.data.items[frame.data.selected].detail)
local reported = false
for _, fallback in ipairs(frame.view.presentation_report.fallbacks) do
  if fallback.path == 'required_facts' then reported = fallback.effective == 'incomplete' end
end
H.ok(reported, 'The actual tiny view reports required facts that it cannot display')
vim.o.columns, vim.o.lines = 110, 36
session:draw()
H.eq(true, frame.view.presentation_facts_complete)
keys('fSecond<Left><BS>?')
local filter, filter_cursor = frame.data.filter, frame.data.filter_cursor
keys('<F1>')
H.eq(filter, frame.data.filter); H.eq(filter_cursor, frame.data.filter_cursor); H.eq(true, frame.data.input_active)
keys('<Esc>')
H.eq(false, frame.data.input_active); H.eq(result_id, frame.data.selected_id, 'Cancelling the actual Results filter restores its stable selection')

H.eq(baseline.lines, vim.api.nvim_buf_get_lines(source, 0, -1, false))
H.eq(baseline.tick, vim.api.nvim_buf_get_changedtick(source))
H.eq(baseline.cursor, vim.api.nvim_win_get_cursor(source_win))
H.eq(admitted_runs, runs); H.eq(operation_count, #CE.operations())
local covered = 0
for _ in pairs(coverage) do covered = covered + 1 end
H.eq(18, covered, 'Exactly six established Session scenes use the three default modes')
-- A small visual surface does not revoke an otherwise validated source jump.
-- This is a native cursor effect, separately from the appearance-only cases.
keys('<CR>')
H.eq({ 2, 2 }, vim.api.nvim_win_get_cursor(source_win), 'The same semantic Results action opens the retained source coordinate')
H.eq(admitted_runs, runs)
H.ok(CE.open_task_results(failed.id, { interactive = false }))
state, frame = session.active, session.active.stack[#session.active.stack]
for _ = 1, 3 do if frame.data.items[frame.data.selected].line == 2 then break end; keys('<Down>') end
vim.o.columns, vim.o.lines = 12, 4
session:draw()
H.eq(false, frame.view.presentation_facts_complete)
keys('<CR>')
H.eq({ 2, 2 }, vim.api.nvim_win_get_cursor(source_win), 'Incomplete cosmetic facts do not block a source-authorized ordinary navigation')
H.eq(false, CE.state().active)
vim.o.columns, vim.o.lines = 110, 36
local V, legacy = require('command_tree.view'), {}
V.draw(legacy, { path = '\\', required_label = 'Owned source', target = filename, items = {} },
  require('command_tree.presentation').options({ presentation = { version = 1, selected = 'minimal', presets = {} } }, {}, 'results'))
H.ok(legacy.presentation_facts_complete ~= nil)
V.draw(legacy, { path = '\\', items = {} }, { density = 'minimal' })
H.eq(nil, legacy.presentation_facts_complete, 'Returning to the legacy renderer removes stale fact-completeness flags')
H.eq(nil, legacy.presentation_facts_reason)
V.close(legacy)
CE.close(); CE.disable(); Session.new = construct
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative, 'Closing releases all scene windows') end
print('PRESENTATION SCENES: ' .. H.checks .. ' checks passed')
