-- Page movement follows the rendered row capacity; cursor movement owns no Run.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE = require('re35')
local options = { usage = { path = false }, preferences = { path = false }, profile = { path = false },
  guidance = { first_run = false }, theme = { persist = false }, window = { icons = false, max_height = 7 },
  providers = { plugins = false, runner = false, lsp = false, ex = false, keymaps = false, native = false } }
vim.o.columns, vim.o.lines = 120, 45
CE.setup(options)
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local runs, received, choices = 0, nil, {}
for index = 1, 47 do choices[index] = ('Choice %02d'):format(index) end
CE.register({ id = 'fixture.pages', name = 'Long picker', arguments = {
  { name = 'choice', kind = 'select', required = true, items = choices } },
  run = function(_, args) runs, received = runs + 1, args.choice end })
CE.register({ id = 'fixture.multi_pages', name = 'Long multiselect', arguments = {
  { name = 'choices', kind = 'multiselect', items = choices } }, run = function() runs = runs + 1 end })
local function open(id, density)
  CE.close(); session.drafts:forget(id, K.context().buf)
  CE.open({ command = id, interactive = false })
  if density then session.active.density = density; session:draw() end
  return session.active, session.active.input
end
local function capacity(state)
  local size = state.view.page_size
  H.ok(type(size) == 'number' and size >= 1, 'The view publishes its actual selection page size')
  return size
end
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  local state, input = open('fixture.pages', density)
  local page = capacity(state)
  keys('<PageDown>'); H.eq(math.min(#choices, 1 + page), input.selected, density .. ' picker advances by one visible page')
  keys('<PageUp>'); H.eq(1, input.selected)
  keys('<PageUp>'); H.eq(1, input.selected, 'Pages clamp at the first item even with wrap enabled')
  keys('<Up>'); H.eq(#choices, input.selected, 'Single-item navigation retains wrapping')
  keys('<PageDown>'); H.eq(#choices, input.selected, 'PageDown clamps at the final item')
  keys('<PageUp>'); H.eq(math.max(1, #choices - page), input.selected, 'A partial final page retains the full page distance')
  H.eq(0, runs, 'Paging never accepts a picker')
  keys('/Choice'); local filter = input.filter
  local selected = input.selected
  keys('<PageUp>'); H.eq(filter, input.filter, 'Page navigation does not edit the filter')
  H.eq(math.max(1, selected - capacity(state)), input.selected)
  keys('<C-u>'); H.eq('', input.filter, 'Ctrl-u remains filter text editing')
  selected = input.selected; keys('<C-d>'); H.eq(selected, input.selected, 'Ctrl-d is not reassigned from text input')
  keys('missing'); H.eq(0, #input.choices)
  keys('<PageDown><PageUp><CR>'); H.eq(1, input.selected); H.eq(0, runs, 'Empty filtered lists cannot accept a value')
  keys('<C-u><Esc>'); session.options.navigation.wrap = false
  input.selected = 1; keys('<Up><PageUp>'); H.eq(1, input.selected)
  input.selected = #choices; keys('<Down><PageDown>'); H.eq(#choices, input.selected)
  session.options.navigation.wrap = true
end
local state, input = open('fixture.multi_pages', 'compact')
keys('<PageDown><Space>'); H.eq({ choices[input.selected] }, input.checked, 'Paging preserves explicit multiselect toggling')
keys('<PageDown>'); H.eq(1, #input.checked); H.eq(0, runs)

-- The same Session request path backs runtime/provider select prompts.
CE.register({ id = 'fixture.runtime_pages', name = 'Runtime picker', async = true,
  run = function(_, _, done, invocation)
    invocation:select(choices, { prompt = 'Runtime choices' }, function(value, index)
      received = { value = value, index = index }; done(value ~= nil)
    end)
  end })
state, input = open('fixture.runtime_pages', 'minimal')
keys('<PageDown>'); H.eq(1 + capacity(state), input.selected)
H.eq(nil, received, 'Runtime selection waits for Enter')
local selected = input.selected
keys('<CR>'); H.eq({ value = choices[selected], index = selected }, received)

-- Search changes selection only if the ordered result identities change.
for index = 1, 24 do
  CE.register({ id = ('fixture.search_%02d'):format(index), name = ('한글 navresult %02d'):format(index),
    run = function() runs = runs + 1 end })
end
CE.close(); CE.open({ search = '한글', interactive = false })
state = session.active
local results = session:results(); H.eq(24, #results)
keys('<Down><Down><Down>'); local original_index, original_id = state.selected, state.selected_id
keys('<Home><Right>'); H.eq(1, state.query_cursor, 'Unicode query cursors count characters')
H.eq(original_index, state.selected); H.eq(original_id, state.selected_id)
for _, key in ipairs({ '<Left>', '<Right>', '<End>', '<Home>', '<C-a>', '<C-e>' }) do
  keys(key); H.eq(original_index, state.selected, 'Moving only the query cursor preserves result selection: ' .. key)
  H.eq(original_id, state.selected_id)
end
keys('<End><Space>'); H.eq(original_id, state.selected_id, 'An equivalent query with unchanged results preserves selection')
keys('<PageDown>'); H.eq(math.min(#results, original_index + capacity(state)), state.selected)
keys('<PageUp>'); H.eq(original_index, state.selected)
keys('23'); H.eq(1, state.selected); H.eq('fixture.search_23', state.selected_id, 'Changed results reset selection to a valid result')
keys('<C-u>no-such-command-zzzz'); H.eq(0, #session:results())
keys('<PageDown><PageUp><Right><CR>'); H.eq(1, state.selected); H.eq(nil, state.selected_id)
H.eq(0, runs, 'Searching, paging and moving cursors never execute a result')
keys('<C-u>한글'); H.eq(24, #session:results()); keys('<Down><Down>')
local selected_id = state.selected_id
CE.unregister(selected_id); session:refresh()
H.ok(state.selected_id ~= selected_id, 'Removed registry results cannot retain a stale selected identity')
H.eq(1, state.selected)

-- Custom page controls go through the same route and remain reserved controls.
CE.close(); options.keys = { page_down = '<F8>', page_up = '<F7>' }; CE.setup(options)
CE.register({ id = 'fixture.custom_pages', arguments = { { name = 'choice', kind = 'select', items = choices } }, run = function() runs = runs + 1 end })
state, input = open('fixture.custom_pages', 'full')
keys('<F8>'); H.eq(1 + capacity(state), input.selected)
keys('<F7>'); H.eq(1, input.selected)
local registered = pcall(CE.bind, { '<F8>' }, 'fixture.custom_pages')
H.eq(false, registered, 'Configured page controls cannot be rebound as executable tree commands')

-- Actual Session-built guidance retains configured keys without parsing the
-- displayed page pair. Custom adapter prose still owns its original fallback.
vim.o.columns, vim.o.lines = 200, 60
session.active.density = 'full'; session:draw()
H.ok(state.view.guide and vim.api.nvim_win_is_valid(state.view.guide.win), 'An actual Full picker renders a side Keys panel')
local function panel_text(part)
  if not part then return '' end
  return table.concat(part.lines or vim.api.nvim_buf_get_lines(part.buf, 0, -1, false), '\n'):gsub('%s+', ' ')
end
H.ok(panel_text(state.view.guide):find('F7/F8 Page', 1, true), 'Picker guide shows the configured page controls')
H.ok(panel_text(state.view.guide):find('↑/↓ Select', 1, true), 'Picker guide shows ordinary selection controls')
CE.register({ id = 'fixture.raw_help', name = 'Custom picker help', arguments = {
  { name = 'choice', kind = 'select', required = true, items = choices } },
  input_ui = { status = function() return { help = 'Custom adapter explanation without shortcut grammar' } end },
  run = function() runs = runs + 1 end })
state, input = open('fixture.raw_help', 'full')
H.eq(nil, state.view.guide, 'Unrecognized adapter help keeps the below-panel fallback')
H.ok(panel_text(state.view.details):gsub('%s', ''):find(('Custom adapter explanation without shortcut grammar'):gsub('%s', ''), 1, true),
  'Structured built-in controls never discard custom adapter prose')

-- Ordinary return and the Editor destination share navigation preservation;
-- explicit reset remains discoverable without overloading the entry key.
CE.close(); CE.open({ interactive = false }); state = session.active
local guide = panel_text(state.view.guide)
H.ok(guide:find('Ctrl+w Workspaces', 1, true), 'Ordinary tree guidance advertises the configured workspace route')
H.ok(guide:find('Editor', 1, true), 'Ordinary tree guidance names the return to editing')
H.ok(guide:find('Ctrl+c Reset', 1, true), 'Ordinary tree guidance names explicit disposal')
keys('<C-w>')
local destinations = session:workspace_choices()
for index, destination in ipairs(destinations) do if destination.destination == 'editor' then state.selected = index; break end end
session:draw()
local editor_details = panel_text(state.view.details):gsub('%s', '')
H.ok(editor_details:find('entryresumesnavigation', 1, true), 'Editor destination explains resuming')
H.ok(editor_details:find('Ctrl-cresetsnavigation', 1, true), 'Editor destination explains explicit reset')
H.ok(editor_details:find('Submittedbackgroundtaskscontinue', 1, true), 'Editor destination describes submitted task lifetime')

-- The native replacement's last boolean submits immediately. Its guide must
-- never promise another Review screen before the selected Apply/Cancel effect.
CE.close()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, true, { 'before replacement' })
local operation_count = #CE.operations()
H.ok(CE.execute('edit.replace_literal', { find = 'before', replace = 'after' }, { interactive = false }))
state, input = session.active, session.active.input
H.eq('confirm', input.command.arguments[input.index].name)
H.ok(panel_text(state.view.guide):find('Enter Apply / Cancel', 1, true), 'Explicit-Apply picker advertises the immediate action')
H.eq(false, input.choices[input.selected].value)
keys('<CR>')
H.eq({ 'before replacement' }, vim.api.nvim_buf_get_lines(source, 0, -1, true), 'One Enter on Cancel preserves the source')
H.eq(operation_count, #CE.operations(), 'Explicit Cancel opens no replacement operation')
H.ok(CE.execute('edit.replace_literal', { find = 'before', replace = 'after' }, { interactive = false }))
state, input = session.active, session.active.input
if input.choices[input.selected].value ~= true then keys('<Down>') end
H.ok(panel_text(state.view.guide):find('Enter Apply / Cancel', 1, true), 'Selected Apply still advertises immediate execution')
H.eq({ 'before replacement' }, vim.api.nvim_buf_get_lines(source, 0, -1, true), 'Selecting Apply alone cannot mutate the source')
keys('<CR>')
H.eq({ 'after replacement' }, vim.api.nvim_buf_get_lines(source, 0, -1, true), 'One Enter on Apply performs the reviewed buffer edit')
H.eq(nil, session.active, 'Explicit Apply does not insert another Review screen')

-- Native hooks receive detached drafts, but can still reenter the host. Their
-- retired return values must never repaint an old surface or restore its args.
local retired, retired_input, previews, cleanups = nil, nil, 0, 0
local function hook_command(id, ui)
  CE.register({ id = id, name = 'Old hook form', arguments = { { name = 'choice', kind = 'select', items = { 'One', 'Two' } } },
    input_ui = ui, preview = function()
      previews = previews + 1
      return function() cleanups = cleanups + 1 end
    end, run = function() runs = runs + 1 end })
end
local function retire()
  retired, retired_input = session.active, session.active.input
  CE.close()
end
hook_command('fixture.init_close', { init = function(_, args)
  args.poison = 'detached'; retire(); return { poison = 'returned' }
end })
CE.close(); CE.open({ command = 'fixture.init_close', interactive = false })
H.eq(nil, session.active); H.eq(nil, retired.view.win)
H.eq({}, retired_input.args, 'An init return cannot restore retired draft args')
H.eq(0, previews, 'Init closure prevents any later preview')

hook_command('fixture.handle_close', { handle = function(_, args, key)
  if key ~= '<F9>' then return end
  args.poison = 'detached'; retire(); return { poison = 'returned' }
end })
open('fixture.handle_close'); H.eq(1, previews)
keys('<F9>'); H.eq(nil, session.active); H.eq(nil, retired.view.win)
H.eq({}, retired_input.args); H.eq(1, previews); H.eq(1, cleanups, 'Handle closure cleans up its preview exactly once')

hook_command('fixture.status_close', { status = function()
  retire(); return { label = 'Retired label', description = 'Retired details' }
end })
CE.open({ command = 'fixture.status_close', interactive = false })
H.eq(nil, session.active); H.eq(nil, retired.view.win, 'A status callback cannot reopen a closed Session view')
H.eq({}, retired_input.args); H.eq(2, previews); H.eq(2, cleanups)

hook_command('fixture.status_replace', { status = function()
  retire(); CE.open({ command = 'fixture.custom_pages', interactive = false })
  return { label = 'Retired label', description = 'Retired details' }
end })
CE.open({ command = 'fixture.status_replace', interactive = false })
H.ok(session.active ~= retired); H.eq('fixture.custom_pages', session.active.input.command.id)
H.eq(nil, retired.view.win, 'Replacing a Session during status preserves only the new surface')
H.eq({}, retired_input.args); H.eq(3, previews); H.eq(3, cleanups)
local shown = table.concat(vim.api.nvim_buf_get_lines(session.active.view.buf, 0, -1, false), '\n')
H.ok(not shown:find('Retired label', 1, true), 'A returned old status cannot overwrite the replacement form')

local first_status = true
hook_command('fixture.status_nested', { status = function()
  if first_status then
    first_status = false
    session:request_input({ prompt = 'Replacement form' }, function() end)
  end
  return { label = 'Retired label' }
end })
CE.close(); CE.open({ command = 'fixture.status_nested', interactive = false })
H.eq(true, session.active.input.callback ~= nil, 'A nested input owns the current form after status reentry')
shown = table.concat(vim.api.nvim_buf_get_lines(session.active.view.buf, 0, -1, false), '\n')
H.ok(shown:find('Replacement form', 1, true)); H.ok(not shown:find('Retired label', 1, true))

hook_command('fixture.handle_reattach', { handle = function(_, _, key)
  if key ~= '<F9>' then return end
  require('command_tree.session.input_driver').attach(session, session.active)
  return { poison = 'expired attachment' }
end })
state, input = open('fixture.handle_reattach')
local attachment = state.input_attachment
keys('<F9>'); H.eq(true, attachment.detached); H.ok(state.input_attachment ~= attachment)
H.eq(nil, input.args.poison, 'A callback cannot carry its draft across a surface lease change')
H.eq(0, runs, 'Lifecycle callbacks cannot imply acceptance or execution')
CE.close(); CE.disable(); Session.new = construct
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative, 'Picker navigation leaves no floating windows') end
print('Picker paging and search stability checks: ' .. H.checks)
