-- Opt-in automated Session route trace; not a human key/timing observation.
-- No process monkeypatch: bounded child Neovim tools record their real argv.
local H, K = require('helpers'), require('command_tree.keys')
local A = require('command_tree.arguments')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('recipe-routes')
local source = folder .. '/source.cpp'
vim.fn.writefile({ 'FIXME' }, source)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.o.columns, vim.o.lines = 130, 44
vim.fn.writefile({
  "local args = vim.fn.argv(); local configuration, target, step = args[1], args[2], args[3]",
  "assert(configuration == 'Debug' or configuration == 'Release'); assert(target == 'A' or target == 'B')",
  "vim.fn.writefile({ configuration .. '/' .. target .. '/' .. step }, 'launched.txt', 'a')",
  "if step == 'build' and vim.fn.readfile('source.cpp')[1] == 'FIXME' then",
  "  io.stdout:write('source.cpp:1:1: ROUTE_BUILD_FAILURE\\n'); io.stdout:flush(); vim.cmd('cquit 7')",
  "end",
  "vim.cmd('qa!')",
}, folder .. '/step.lua')
local common = { '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-c',
  'lua dofile("step.lua")', '--', '{configuration}', '{target}' }
local profile = Profile.empty()
profile.projects, profile.recipes = {}, {}
profile.tools.fixture = { command = 'nvim', args = {}, errorformat = '%f:%l:%c: %m,%-G%.%#' }
profile.projects.fixture = { name = 'Route fixture', root = { base = 'project', path = '.' }, source = 'source.cpp',
  configurations = { 'Debug', 'Release' }, targets = { 'A', 'B' }, default_configuration = 'Debug', default_target = 'A' }
profile.recipes.build_test = { name = 'Configure build test', project = 'fixture', steps = {} }
for _, step in ipairs({ 'configure', 'build', 'test' }) do
  profile.recipes.build_test.steps[#profile.recipes.build_test.steps + 1] = {
    id = step, tool = 'fixture', args = vim.list_extend(vim.deepcopy(common), { step }) }
end
-- Additional prepared routes use supported profile data, not a direct execute
-- call or a synthetic command. A slot stores a command ID, never preset args.
profile.presets['recipe.build_test'] = { { name = 'Debug A', args = { configuration = 'Debug', target = 'A' } } }
profile.slots['1'], profile.slots['2'] = 'command.preset', 'recipe.build_test'
profile.slots['3'] = 'project.run_selected_recipe'
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = profile }, window = { icons = false },
  providers = { builtin = true, lsp = false, plugins = false, runner = false, ex = false, native = false, keymaps = false },
  project_overrides = { fixture = { root = folder } },
  tool_overrides = { fixture = { command = vim.v.progpath, timeout_ms = 5000 } } })
local records, active_record = {}, nil
local function frame() return assert(session.active.stack[#session.active.stack], 'Workspace frame required') end
local function state()
  if not session.active then return { mode = 'closed' } end
  local s = session.active
  local result = { mode = s.mode, busy = s.busy or false, message = s.message }
  if s.mode == 'workspace' then
    local f = frame(); result.workspace, result.selected_id = f.id, f.data.selected_id
  elseif s.mode == 'selector' then
    local choices = session:workspace_choices(); result.choice = choices[s.selected] and choices[s.selected].id
  elseif s.mode == 'input' then
    result.prompt = s.input.command.name
    local choices = s.input.choices or {}; result.choice = choices[s.input.selected] and A.label(choices[s.input.selected])
  end
  return result
end
local function begin(name)
  active_record = { name = name, keys = {}, trace = {}, entry_modelled = true }
  records[#records + 1] = active_record
end
local function send(key)
  active_record.keys[#active_record.keys + 1] = key
  local before = state(); session:handle(key, K.raw(key)); session:draw()
  active_record.trace[#active_record.trace + 1] = { key = key, before = before, after = state() }
end
local function open()
  H.eq(nil, session.active, 'route begins in closed source window')
  H.ok(CE.open({ interactive = false }), 'entry is modelled by noninteractive normal open')
  active_record.keys[#active_record.keys + 1] = '\\'
  active_record.trace[#active_record.trace + 1] = { key = '\\', entry_modelled = true, after = state() }
end
local function project()
  send('m'); H.eq('selector', session.active.mode)
  local choices, wanted = session:workspace_choices()
  for i, item in ipairs(choices) do if item.id == 'project' then wanted = i end end
  H.ok(wanted, 'Project exists in actual workspace selector')
  while session.active.selected < wanted do send('<Down>') end
  while session.active.selected > wanted do send('<Up>') end
  send('<CR>'); H.eq('project', frame().id)
end
local function row(id)
  H.eq('workspace', session.active.mode)
  local items, wanted = frame().data.items
  for i, item in ipairs(items) do if item.id == id then wanted = i end end
  H.ok(wanted, 'actual Project row exists: ' .. id)
  -- Use available six-row paging when it saves actions; never mutate selection.
  while wanted - frame().data.selected >= 6 do send('<C-d>') end
  while frame().data.selected - wanted >= 6 do send('<C-u>') end
  while frame().data.selected < wanted do send('<Down>') end
  while frame().data.selected > wanted do send('<Up>') end
  H.eq(id, frame().data.selected_id)
end
local function choice(value)
  H.eq('input', session.active.mode)
  local input, wanted = session.active.input
  for i, item in ipairs(input.choices or {}) do if vim.deep_equal(A.value(item), value) then wanted = i end end
  H.ok(wanted, 'actual input choice exists: ' .. tostring(value))
  while input.selected < wanted do send('<Down>') end
  while input.selected > wanted do send('<Up>') end
  send('<CR>')
end
local function parent_after(id)
  local found
  H.ok(vim.wait(12000, function()
    for _, task in ipairs(CE.operations()) do
      if task.command_id == 'recipe.build_test' and task.id > id and task.status ~= 'pending' then found = task; return true end
    end
  end, 10), 'real recipe reaches finite backend completion')
  return found
end
local function latest_parent()
  local id = 0
  for _, task in ipairs(CE.operations()) do if task.command_id == 'recipe.build_test' then id = math.max(id, task.id) end end
  return id
end
local function launch()
  local last = latest_parent()
  row('run'); send('<CR>')
  -- Trace the former mandatory review when comparing the old implementation;
  -- clean-file execution in the current implementation has no review to click.
  if session.active.mode == 'input' then choice({ id = 'saved', label = 'Run saved files' }) end
  return parent_after(last)
end
begin('re35-first-launch')
open(); project()
local failed = launch()
H.eq('failed', failed.status)
H.eq('Debug', failed.detail.configuration); H.eq('A', failed.detail.target)
H.eq({ 'configure', 'build' }, { failed.detail.steps[1].id, failed.detail.steps[2].id })
H.eq(2, #failed.detail.steps, 'failed build never starts test')
H.eq({ 'Debug/A/configure', 'Debug/A/build' }, vim.fn.readfile(folder .. '/launched.txt'))
CE.close()

local function selected_launch(name, keys, configuration, target, expected_plan)
  begin(name)
  local previous = latest_parent()
  open()
  for _, key in ipairs(keys) do send(key) end
  local task = parent_after(previous)
  H.eq(configuration, task.detail.configuration); H.eq(target, task.detail.target)
  if expected_plan then H.eq(expected_plan, task.process_target, 'selected shortcut preserves the validated current pipeline') end
  if vim.fn.readfile(source)[1] == 'FIXME' then
    H.eq('failed', task.status); H.eq(2, #task.detail.steps, 'selected shortcut also stops before test after build failure')
  else H.eq('succeeded', task.status); H.eq(3, #task.detail.steps) end
  H.eq(configuration, CE.project_context().configuration)
  H.eq(target, CE.project_context().target, 'selected shortcut leaves the current choices intact')
  CE.close()
end
-- These are available only after the first explicit Project Run has prepared
-- and validated a current selection. Slot 3 stores the action ID, not args.
selected_launch('re35-default-selected-repeat', { 'r', 'r' }, 'Debug', 'A', failed.process_target)
selected_launch('re35-prepared-selected-slot-repeat', { '3' }, 'Debug', 'A', failed.process_target)

begin('re35-repeat-same-selection')
open(); project()
local repeated = launch()
H.eq('failed', repeated.status); H.eq(failed.process_target, repeated.process_target)
CE.close()

-- Count Result navigation and save separately; the source correction itself
-- is a common one-line fixture edit, not a compiled C++ code repair.
begin('re35-failure-location-and-save')
open(); send('r'); send('t'); H.eq('tasks', frame().id)
local function taskrow(id)
  local operations = frame().data.operations
  local wanted
  for i, task in ipairs(operations) do if task.id == id then wanted = i end end
  H.ok(wanted, 'retained parent is present in actual Tasks list')
  while frame().data.selected < wanted do send('<Down>') end
  while frame().data.selected > wanted do send('<Up>') end
  H.eq(id, frame().data.selected_id)
end
taskrow(failed.id); send('o')
H.eq('results', frame().id); send('<CR>')
H.eq(nil, session.active); H.eq(source_buf, vim.api.nvim_get_current_buf())
H.eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0), 'actual diagnostic row jumps to source')
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'fixed' })
vim.cmd('write')
active_record.common_edit_excluded = true
active_record.save_keys = { ':', 'w', '<CR>' }
H.eq({ 'fixed' }, vim.fn.readfile(source), 'explicit save updates tool input')

begin('re35-change-current-selection')
open(); project(); row('configuration'); send('<CR>'); choice('Release')
row('target'); send('<CR>'); choice('B')
H.eq('Release', CE.project_context(session.active.ctx).configuration)
H.eq('B', CE.project_context(session.active.ctx).target)
CE.close()

begin('re35-retained-retry-from-source')
local last = latest_parent()
open(); send('r'); send('t'); H.eq('tasks', frame().id)
taskrow(failed.id); send('r')
if session.active.mode == 'input' then choice({ id = 'saved', label = 'Run saved files' }) end
local retry = parent_after(last)
H.eq('succeeded', retry.status); H.eq(failed.process_target, retry.process_target)
H.eq('Debug', retry.detail.configuration); H.eq('A', retry.detail.target)
H.eq(3, #retry.detail.steps)
H.eq('Release', CE.project_context(session.active.ctx).configuration)
H.eq('B', CE.project_context(session.active.ctx).target)
H.eq(source_win, session.active.ctx.win, 'retry preserves source window')
CE.close()
selected_launch('re35-default-selected-after-drift', { 'r', 'r' }, 'Release', 'B')

local function prepared_preset(name)
  begin(name)
  local previous = latest_parent()
  open(); send('1')
  H.eq('input', session.active.mode, 'quick slot opens the actual saved-input picker')
  choice('recipe.build_test'); choice('Debug A')
  H.eq('review', session.active.mode, 'ordinary saved-input picker still has its generic review')
  send('<CR>')
  local task = parent_after(previous)
  H.eq('succeeded', task.status)
  H.eq('Debug', task.detail.configuration); H.eq('A', task.detail.target)
  H.eq(failed.process_target, task.process_target, 'prepared preset resolves the same original pipeline')
  H.eq('Release', CE.project_context().configuration)
  H.eq('B', CE.project_context().target, 'preset execution preserves the selected Release/B project')
  CE.close()
end
prepared_preset('re35-prepared-preset-first-launch')
prepared_preset('re35-prepared-preset-repeat')

begin('re35-prepared-recipe-slot-current-selection')
local previous = latest_parent()
open(); send('2')
H.eq('input', session.active.mode, 'a recipe slot does not provide argument values')
choice('Release'); choice('B')
H.eq('review', session.active.mode, 'two recipe arguments retain ordinary form review')
send('<CR>')
local slotted = parent_after(previous)
H.eq('succeeded', slotted.status)
H.eq('Release', slotted.detail.configuration); H.eq('B', slotted.detail.target)
CE.close(); CE.disable(); Session.new = construct

-- Equivalent native pipeline: one makeprg invocation, same three stage argv,
-- sequential stop on nonzero; no artificial three-command input penalty.
vim.fn.writefile({
  "local args = vim.fn.argv(); local configuration, target = args[1] or 'Debug', args[2] or 'A'",
  "for _, step in ipairs({ 'configure', 'build', 'test' }) do",
  "  local argv = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-c', 'lua dofile(\"step.lua\")', '--', configuration, target, step }",
  "  local result = vim.system(argv, { text = true }):wait(5000)",
  "  io.stdout:write(result.stdout or ''); io.stderr:write(result.stderr or ''); io.stdout:flush(); io.stderr:flush()",
  "  if result.code ~= 0 then vim.cmd('cquit ' .. result.code) end",
  "end",
  "vim.cmd('qa!')",
}, folder .. '/pipeline.lua')
vim.cmd('cd ' .. vim.fn.fnameescape(folder))
if vim.fn.has('win32') == 1 then
  H.ok(vim.env.COMSPEC and vim.fn.executable(vim.env.COMSPEC) == 1)
  vim.o.shell, vim.o.shellcmdflag = vim.env.COMSPEC, '/d /v:off /s /c'
  vim.o.shellquote, vim.o.shellxquote = '', '"'
  vim.o.shellpipe, vim.o.shellredir, vim.o.shellslash = '>%s 2>&1', '>%s 2>&1', false
end
local argv = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-c',
  'lua dofile("pipeline.lua")', '--' }
local escaped = {}; for _, arg in ipairs(argv) do escaped[#escaped + 1] = vim.fn.shellescape(arg) end
vim.bo.makeprg, vim.bo.errorformat = table.concat(escaped, ' '), '%f:%l:%c: %m,%-G%.%#'
vim.fn.histdel('cmd')
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'FIXME' }); vim.cmd('write')
vim.fn.writefile({}, folder .. '/launched.txt')
local function native(command, keys, name, payload)
  vim.cmd('silent ' .. command); vim.fn.histadd('cmd', command)
  records[#records + 1] = { name = name, keys = keys, native_command_modelled = true,
    payload_characters = payload or 0 }
end
local function typed(value) return K.tokens(value) end
native('mak Debug A', typed(':mak Debug A<CR>'), 'native-first-launch', #'DebugA')
H.ok(vim.v.shell_error ~= 0)
H.eq({ 'Debug/A/configure', 'Debug/A/build' }, vim.fn.readfile(folder .. '/launched.txt'))
H.ok(vim.fn.getqflist()[1].valid == 1, 'native pipeline provides matching diagnostic quickfix')
local remembered = vim.fn.histget('cmd', -1)
H.eq('mak Debug A', remembered)
native(remembered, { '@', ':' }, 'native-repeat-last-command')
H.ok(vim.v.shell_error ~= 0)
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'fixed' }); vim.cmd('write')
-- Native active choice changes by executing the same pipeline with Release/B;
-- old Debug/A command remains in ordinary command history, as RE35 old Task.
native('mak Release B', typed(':mak Release B<CR>'), 'native-change-current-selection', #'ReleaseB')
H.eq(0, vim.v.shell_error)
local original = vim.fn.histget('cmd', -2)
H.eq('mak Debug A', original, 'two Up presses retrieve original native invocation')
native(original, { ':', '<Up>', '<Up>', '<CR>' }, 'native-retained-retry-from-source')
H.eq(0, vim.v.shell_error)
local lines = vim.fn.readfile(folder .. '/launched.txt')
H.eq({ 'Debug/A/configure', 'Debug/A/build', 'Debug/A/test' }, { lines[#lines-2], lines[#lines-1], lines[#lines] })
native('mak', typed(':mak<CR>'), 'native-pinned-default-first-launch')
H.eq(0, vim.v.shell_error)
lines = vim.fn.readfile(folder .. '/launched.txt')
H.eq({ 'Debug/A/configure', 'Debug/A/build', 'Debug/A/test' }, { lines[#lines-2], lines[#lines-1], lines[#lines] },
  'prepared native defaults launch original full pipeline with no argument entry')
for _, record in ipairs(records) do
  record.actions, record.control_keys, record.enter_keys = #record.keys, #record.keys - (record.payload_characters or 0), 0
  record.payload_characters = record.payload_characters or 0
  for _, key in ipairs(record.keys) do
    if key == '<CR>' then record.enter_keys = record.enter_keys + 1 end
    -- Command argument characters are payload; method selection/command names
    -- and navigation remain control actions, disclosed by exact transcript.
  end
end
local report = { evidence = 'automated-current-session-route-count', neovim = vim.version(),
  human_timing_measured = false, physical_entry_measured = false, finite_fake_tool = true,
  correctness_passed = true, descendant_cancellation_tested = false,
  prepared_profile = { slots = profile.slots, presets = profile.presets }, records = records }
io.stdout:write(vim.json.encode(report) .. '\n')
io.stdout:write('Recipe route checks: ' .. H.checks .. '\n')
