-- Clean recipe requests do not need a second launch decision. Unsaved files
-- still require a choice, and the original target/declaration guards remain.
local H, K = require('helpers'), require('command_tree.keys')
local A = require('command_tree.arguments')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('recipe-launch')
local source = folder .. '/source.txt'
vim.fn.writefile({ 'saved input' }, source)
vim.api.nvim_cmd({ cmd = 'edit', args = { source } }, {})
local buf = vim.api.nvim_get_current_buf()
vim.o.columns, vim.o.lines = 130, 44
vim.fn.writefile({
  "local args = vim.fn.argv()",
  "vim.fn.writefile({ args[1] .. '/' .. args[2], vim.fn.readfile('source.txt')[1] }, 'observed.txt')",
  "vim.cmd('qa!')",
}, folder .. '/step.lua')
local profile = Profile.empty()
profile.slots['1'] = 'project.run_selected_recipe'
profile.projects, profile.recipes = {}, {}
profile.tools.fixture = { command = 'nvim', args = {} }
profile.projects.fixture = { name = 'Fixture', root = { base = 'project', path = '.' }, source = 'source.txt',
  configurations = { 'Debug', 'Release' }, targets = { 'A', 'B' }, default_configuration = 'Debug', default_target = 'A' }
profile.recipes.fixture = { name = 'Read saved input', project = 'fixture', steps = {
  { id = 'read', tool = 'fixture', args = { '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n',
    '-c', 'lua dofile("step.lua")', '--', '{configuration}', '{target}' } },
} }
local options = { auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = profile }, window = { icons = false }, integrations = { theme = false },
  providers = { builtin = true, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false },
  project_overrides = { fixture = { root = folder } }, tool_overrides = { fixture = { command = vim.v.progpath } } }
CE.setup(options)
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
H.eq(0, #CE.operations(), 'setup registers selected-recipe execution without launching anything')
H.eq('project.run_selected_recipe', CE.registry():node({ 'r', 'r' }).command_id, 'free rr gets the semantic selected-recipe command')
H.eq('selected_recipe', CE.registry():get('project.run_selected_recipe').session_action)
CE.open({ interactive = false }); keys('rr')
H.ok(session.active.message:find('Open Project', 1, true), 'no remembered choice explains the required Project action')
H.eq(0, #CE.operations(), 'missing Project selection does not guess or start a process')
CE.close()
local function request(opts)
  CE.close(); vim.api.nvim_set_current_buf(buf)
  local result = { callbacks = 0 }
  local options = vim.tbl_extend('force', { interactive = false, context = K.context(), done = function(ok, detail, task)
    result.callbacks = result.callbacks + 1
    result.ok, result.detail, result.task = ok, detail, task
  end }, opts or {})
  result.accepted, result.reason = CE.run_recipe('fixture', { configuration = 'Debug', target = 'A' }, options)
  return result
end
local function finished(result)
  H.ok(vim.wait(8000, function() return result.callbacks > 0 end, 10), 'actual recipe process completes')
  H.eq(1, result.callbacks, 'completion is emitted once')
  H.eq(true, result.ok, 'actual saved-input recipe succeeds')
  H.eq('succeeded', result.task.status)
end
local first = request()
H.ok(first.accepted, first.reason)
H.ok(not session.active or session.active.mode ~= 'input', 'clean launch has no redundant saved-file picker')
finished(first)
H.eq({ 'Debug/A', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'))
H.eq({ 'saved input' }, vim.fn.readfile(source), 'clean launch performs no file write')

-- Explicit review remains available to callers which require it, even clean.
local count = #CE.operations()
local reviewed = request({ force_review = true })
H.ok(reviewed.accepted)
H.eq('input', session.active.mode, 'force_review retains an explicit save-policy choice')
H.eq(count, #CE.operations(), 'review itself never starts an operation')
keys('<Down><Down><CR>')
H.eq(false, reviewed.ok)
H.eq(1, reviewed.callbacks)
H.eq(count, #CE.operations(), 'cancelling explicit review starts no process')

vim.api.nvim_buf_set_lines(buf, 0, -1, true, { 'unsaved input' })
local dirty = request()
H.ok(dirty.accepted)
H.eq('input', session.active.mode, 'modified project file still requires a saved-file decision')
H.eq(count, #CE.operations(), 'unsaved-file prompt does not start a task')
H.eq(0, dirty.callbacks)
H.eq({ 'saved input' }, vim.fn.readfile(source), 'opening dirty review does not save')
keys('<Down><Down><CR>')
H.eq(false, dirty.ok)
H.eq(count, #CE.operations(), 'dirty-file cancellation starts no process')
H.eq({ 'unsaved input' }, vim.api.nvim_buf_get_lines(buf, 0, -1, true), 'cancellation preserves unsaved text')

dirty = request()
H.eq('input', session.active.mode)
keys('<Down><CR>') -- Run saved files, deliberately leaving the buffer modified.
finished(dirty)
H.eq({ 'Debug/A', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'), 'Run saved files uses existing disk inputs')
H.eq(true, vim.bo[buf].modified)
H.eq({ 'unsaved input' }, vim.api.nvim_buf_get_lines(buf, 0, -1, true))
H.eq({ 'saved input' }, vim.fn.readfile(source), 'Run saved files never implicitly saves')

-- Clean replay still refuses the old source identity rather than following a
-- renamed buffer, even though the original disk pathname remains readable.
CE.close(); vim.api.nvim_buf_set_lines(buf, 0, -1, true, { 'saved input' }); vim.bo[buf].modified = false
vim.api.nvim_buf_set_name(buf, folder .. '/renamed.txt')
count = #CE.operations()
local accepted, why = CE.rerun(first.task.id, { interactive = false })
H.eq(false, accepted)
H.ok(why:find('renamed', 1, true), 'clean replay still checks original source identity')
H.eq(count, #CE.operations())
vim.api.nvim_buf_set_name(buf, source)
local invalid = request({ force_review = 'yes' })
H.eq(false, invalid.accepted)
H.ok(invalid.reason:find('force_review must be a boolean', 1, true))
H.eq(count, #CE.operations())

-- Make the first explicit choice through the real Project workspace. Merely
-- rendering its defaults does not arm a later selected-recipe command.
local function open()
  CE.close(); vim.api.nvim_set_current_buf(buf)
  H.ok(CE.open({ interactive = false }))
end
local function frame() return assert(session.active.stack[#session.active.stack]) end
local function project()
  open(); keys('m')
  H.eq('selector', session.active.mode)
  local wanted
  for index, item in ipairs(session:workspace_choices()) do if item.id == 'project' then wanted = index end end
  H.ok(wanted, 'Project is available in the workspace selector')
  while session.active.selected < wanted do keys('<Down>') end
  while session.active.selected > wanted do keys('<Up>') end
  keys('<CR>'); H.eq('project', frame().id)
end
local function row(id)
  H.eq('workspace', session.active.mode)
  local current, wanted = frame()
  for index, item in ipairs(current.data.items) do if item.id == id then wanted = index end end
  H.ok(wanted, 'Project row exists: ' .. id)
  while current.data.selected < wanted do keys('<Down>') end
  while current.data.selected > wanted do keys('<Up>') end
  H.eq(id, current.data.selected_id)
end
local function choose(value)
  H.eq('input', session.active.mode)
  local input, wanted = session.active.input
  for index, item in ipairs(input.choices) do if vim.deep_equal(A.value(item), value) then wanted = index end end
  H.ok(wanted, 'actual selection includes ' .. tostring(value))
  while input.selected < wanted do keys('<Down>') end
  while input.selected > wanted do keys('<Up>') end
  keys('<CR>')
end
local function latest()
  local value = 0
  for _, task in ipairs(CE.operations()) do if task.command_id == 'recipe.fixture' then value = math.max(value, task.id) end end
  return value
end
local function completed(previous)
  local found
  H.ok(vim.wait(8000, function()
    for _, task in ipairs(CE.operations()) do
      if task.command_id == 'recipe.fixture' and task.id > previous and task.status ~= 'pending' then found = task; return true end
    end
  end, 10), 'actual Session route finishes its owned recipe')
  H.eq('succeeded', found.status)
  return found
end
project()
H.eq(false, CE.registry():available('project.run_selected_recipe', session.active.ctx), 'rendered defaults are not remembered execution intent')
local previous = latest()
row('run'); keys('<CR>')
local chosen = completed(previous)
H.eq({ 'Debug/A', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'))
H.eq('Debug', CE.project_context(session.active.ctx).configuration)
H.eq('A', CE.project_context(session.active.ctx).target)
H.eq('fixture', CE.project_context(session.active.ctx).recipe, 'explicit Run remembers the visible recipe ID')

open(); previous = latest(); keys('rr')
H.ok(not session.active or session.active.mode ~= 'input' and session.active.mode ~= 'review', 'clean rr opens no argument or launch review')
local repeated = completed(previous)
H.eq(chosen.process_target, repeated.process_target, 'rr repeats the remembered configuration and target')
H.eq({ 'saved input' }, vim.fn.readfile(source), 'selected-recipe fast path performs no implicit write')

project(); row('configuration'); keys('<CR>'); choose('Release')
row('target'); keys('<CR>'); choose('B')
H.eq('Release', CE.project_context(session.active.ctx).configuration)
H.eq('B', CE.project_context(session.active.ctx).target)
open(); previous = latest(); keys('1')
local changed = completed(previous)
H.eq('Release', changed.detail.configuration, 'semantic quick slot uses the current remembered configuration')
H.eq('B', changed.detail.target, 'semantic quick slot uses the current remembered target')
H.eq({ 'Release/B', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'))

-- The same semantic quick slot is intentionally window scoped; another source
-- window cannot silently borrow the originating window's project selection.
CE.close(); vim.cmd('split')
local other_win = vim.api.nvim_get_current_win()
H.ok(CE.open({ interactive = false })); count = #CE.operations(); keys('1')
H.ok(session.active.message:find('Open Project', 1, true))
H.eq(count, #CE.operations(), 'another window has no implicit selected recipe')
CE.close(); vim.api.nvim_win_close(other_win, true)

-- Retrying the old task from the actual Tasks workspace keeps Debug/A even
-- after the selected-recipe command has launched the current Release/B.
open(); keys('rt'); H.eq('tasks', frame().id)
local tasks, wanted = frame().data.operations
for index, task in ipairs(tasks) do if task.id == chosen.id then wanted = index end end
H.ok(wanted, 'the original chosen task remains in Tasks')
while frame().data.selected < wanted do keys('<Down>') end
while frame().data.selected > wanted do keys('<Up>') end
previous = latest(); keys('r')
local retained = completed(previous)
H.eq(chosen.process_target, retained.process_target, 'retained task retry never resolves current Project choices')
H.eq({ 'Debug/A', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'))
H.eq('Release', CE.project_context(session.active.ctx).configuration)
H.eq('B', CE.project_context(session.active.ctx).target, 'retained retry preserves current Project choices')

-- Fast access retains the explicit save decision. Run saved uses disk inputs,
-- so unsaved text changes grant neither write consent nor a new blocker.
CE.close(); vim.api.nvim_buf_set_lines(buf, 0, -1, true, { 'selected unsaved input' })
open(); count = #CE.operations(); keys('rr')
H.eq('input', session.active.mode, 'dirty rr retains a saved-file decision')
H.eq(count, #CE.operations(), 'opening selected-recipe review starts no process')
keys('<Down><Down><CR>')
H.eq(count, #CE.operations(), 'cancelling dirty selected-recipe review starts no process')
H.eq({ 'saved input' }, vim.fn.readfile(source), 'cancel never saves modified text')
open(); keys('1'); H.eq('input', session.active.mode)
previous = latest(); keys('<Down><CR>')
local saved_only = completed(previous)
H.eq('Release', saved_only.detail.configuration); H.eq('B', saved_only.detail.target)
H.eq({ 'Release/B', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'))
H.eq(true, vim.bo[buf].modified)
H.eq({ 'selected unsaved input' }, vim.api.nvim_buf_get_lines(buf, 0, -1, true))
H.eq({ 'saved input' }, vim.fn.readfile(source), 'Run saved files retains the modified buffer without writing')
open(); count = #CE.operations(); keys('rr')
H.eq('input', session.active.mode)
vim.api.nvim_buf_set_lines(buf, 0, -1, true, { 'changed during selected review' })
previous = latest()
keys('<Down><CR>')
local edited_saved = completed(previous)
H.eq('Release', edited_saved.detail.configuration); H.eq('B', edited_saved.detail.target)
H.eq({ 'Release/B', 'saved input' }, vim.fn.readfile(folder .. '/observed.txt'),
  'Run saved still consumes the reviewed disk source after an unsaved edit')
H.eq({ 'changed during selected review' }, vim.api.nvim_buf_get_lines(buf, 0, -1, true))
H.eq({ 'saved input' }, vim.fn.readfile(source))
count = #CE.operations()

-- Existing user commands keep rr. The semantic ID can still be bound through
-- a later portable profile layout, without replacing the user's command.
CE.close(); vim.api.nvim_buf_set_lines(buf, 0, -1, true, { 'saved input' }); vim.bo[buf].modified = false
local setup = vim.deepcopy(options)
setup.commands = { { id = 'fixture.keep_rr', name = 'Existing Run', type = 'action', run = function() return true end } }
setup.bindings = { { path = 'rr', id = 'fixture.keep_rr' } }
setup.profile.data.layout.bindings = { { path = 'rx', id = 'project.run_selected_recipe' } }
CE.setup(setup)
H.eq('fixture.keep_rr', CE.registry():node('rr').command_id, 'registration preserves a preexisting rr binding')
H.eq('project.run_selected_recipe', CE.registry():node('rx').command_id, 'later profile layout binds the semantic selected-recipe ID')
H.eq(count, #CE.operations(), 'reconfiguration starts no recipe operation')

local empty = vim.deepcopy(options)
empty.profile.data = Profile.empty()
empty.profile.data.layout.bindings = { { path = 'rr', id = 'file.save' } }
empty.disabled_commands = { ['project.run_selected_recipe'] = true }
CE.setup(empty)
H.eq(nil, CE.registry():get('project.run_selected_recipe'), 'empty profiles omit selected-recipe metadata')
H.eq('file.save', CE.registry():node('rr').command_id)
local current, why = CE.project_context()
H.eq(nil, current); H.ok(why:find('No declarative projects', 1, true))
H.eq(nil, CE.registry():get('project.run_selected_recipe'), 'lazy manager access cannot resurrect the disabled semantic ID')
H.eq('file.save', CE.registry():node('rr').command_id, 'lazy manager access preserves the already applied profile layout')
H.eq(count, #CE.operations(), 'materializing an empty manager starts no process')

CE.close(); CE.disable(); Session.new = construct
io.stdout:write('Recipe launch checks: ' .. H.checks .. '\n')
