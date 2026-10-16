-- Actual reviewed recipes own real child processes. Their retained snapshots
-- must preserve provenance without changing native lists or exporting paths.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('command_tree'), require('command_tree.profile')
local Results, Report = require('command_tree.results'), require('command_tree.task_report')
local folder = H.tempdir('recipe-results')
local source = folder .. '/source.cpp'
vim.fn.writefile({ 'int main() { return 0; }' }, source)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()
vim.o.columns, vim.o.lines = 130, 44
local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
local source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
vim.fn.setqflist({ { filename = source, lnum = 1, col = 1, text = 'Native quickfix stays owned by the user' } }, 'r')
vim.fn.setloclist(0, { { filename = source, lnum = 1, col = 1, text = 'Native location list stays owned by the window' } }, 'r')
local quickfix, loclist = vim.fn.getqflist(), vim.fn.getloclist(0)

local function child_script(name, waits, fails, diagnostics, extra_output)
  local script = {
    "vim.fn.writefile({ 'started' }, '" .. name .. ".started')",
    "io.stdout:write(string.rep('source.cpp:1:1: shared diagnostic\\n', " .. (diagnostics or 1) .. ")); io.stdout:flush()",
  }
  if extra_output then script[#script + 1] = 'io.stdout:write(string.rep("x", ' .. extra_output .. ')); io.stdout:flush()' end
  if waits then script[#script + 1] = 'vim.wait(' .. waits .. ')' end
  if fails then script[#script + 1] = 'vim.cmd("cquit 7")' end
  vim.fn.writefile(script, folder .. '/' .. name .. '.lua')
end
child_script('first')
child_script('second')
child_script('failed', nil, true)
child_script('waiting', 10000)
child_script('guarded', 700)
child_script('never')
child_script('child_limited', nil, nil, 5001)
child_script('aggregate_first', nil, nil, 3000)
child_script('aggregate_second', nil, nil, 3000)
child_script('output_limited', nil, nil, 1, 1048577)

local function child_args(name)
  return { '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-c',
    'lua dofile("' .. name .. '.lua")', '-c', 'qa!' }
end
local function configuration(steps, timeout)
  local data = Profile.empty()
  data.tools.fixture = { command = 'nvim', args = child_args('never'), errorformat = '%f:%l:%c: %m' }
  if timeout then data.tools.timed_fixture=vim.deepcopy(data.tools.fixture)end
  data.projects = { fixture = { name = 'Fixture project', root = { base = 'project', path = '.' }, source = 'source.cpp' } }
  data.recipes = { fixture = { name = 'Fixture recipe', project = 'fixture', steps = {} } }
  for _, name in ipairs(steps) do
    data.recipes.fixture.steps[#data.recipes.fixture.steps + 1] = { id = name,
      tool = timeout and name=='waiting' and 'timed_fixture' or 'fixture', args = child_args(name) }
  end
  return { auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
    profile = { path = false, data = data }, window = { icons = false },
    providers = { builtin = false, lsp = false, plugins = false, runner = false, ex = false, native = false, keymaps = false },
    project_overrides = { fixture = { root = folder } },
    tool_overrides = { fixture = { command = vim.v.progpath, cancel_grace_ms = 50 },
      timed_fixture = timeout and { command = vim.v.progpath, timeout_ms = timeout, cancel_grace_ms = 50 } or nil } }
end
local function start(steps, timeout)
  CE.close()
  vim.api.nvim_set_current_buf(source_buf)
  for _, name in ipairs({ 'first', 'second', 'failed', 'waiting', 'guarded', 'never',
    'child_limited', 'aggregate_first', 'aggregate_second', 'output_limited' }) do
    vim.fn.delete(folder .. '/' .. name .. '.started')
  end
  CE.setup(configuration(steps, timeout))
  local ctx = K.context()
  local completed, completion_ok, completion_detail, completion_task, callbacks = false, nil, nil, nil, 0
  local accepted, reason = CE.run_recipe('fixture', {}, { save = 'saved', interactive = false, context = ctx,
    done = function(ok, detail, task)
      completed, completion_ok, completion_detail, completion_task = true, ok, detail, task
      callbacks = callbacks + 1
    end })
  H.ok(accepted, 'explicit saved-file dispatch accepts a real recipe: ' .. tostring(reason))
  local parent
  for _, task in ipairs(CE.operations()) do if task.command_id == 'recipe.fixture' and task.status == 'pending' then parent = task; break end end
  H.ok(parent, 'reviewed recipe creates a retained pending parent')
  return { parent = parent, ctx = ctx, finish = function(expected_status)
    H.ok(vim.wait(8000, function() return completed end, 10), 'real recipe completes within its bounded fixture timeout')
    H.eq(expected_status, parent.status, 'retained parent has the backend-confirmed outcome')
    H.eq(expected_status == 'succeeded', completion_ok, 'completion reports the same outcome')
    H.eq(parent, completion_task, 'completion retains the actual parent identity')
    H.eq(parent.detail, completion_detail, 'completion retains the aggregate snapshot')
    H.eq(1, callbacks, 'parent completion is reported once')
    return parent.detail
  end }
end
local function child(parent, id)
  for _, task in ipairs(CE.operations()) do if task.id == id then
    H.eq(parent.id, task.parent_id, 'actual child belongs to the reviewed parent')
    H.eq('fixture', task.recipe_id, 'actual child retains the recipe ID')
    return task
  end end
  error('Recipe child disappeared from retained history')
end
local function no_later_step()
  H.eq(0, vim.fn.filereadable(folder .. '/never.started'), 'stopped recipe never starts a later real process')
end

local running = start({ 'first', 'second' })
local detail = running.finish('succeeded')
H.eq(2, #detail.steps, 'both successful steps finish in declaration order')
H.eq({ 'first', 'second' }, { detail.steps[1].id, detail.steps[2].id })
H.eq(2, #detail.child_ids, 'each real process has a retained child task')
H.eq(2, #detail.locations, 'same-position diagnostics remain separate step results')
for index, step in ipairs(detail.steps) do
  local task = child(running.parent, step.task_id)
  H.eq('succeeded', task.status)
  H.eq(step.id, task.step_id)
  H.eq(step.id, detail.locations[index].recipe_step)
  H.eq(task.id, detail.locations[index].child_task_id)
end
local result = H.ok(Results.read('task', running.ctx, nil, running.parent.id))
H.eq(2, #result.items, 'Results receives both actual aggregate locations')
for index, item in ipairs(result.items) do
  H.eq(detail.steps[index].id, item.recipe_step, 'Results preserves the originating step')
  H.eq(detail.steps[index].task_id, item.child_task_id, 'Results preserves the originating child')
  H.eq(running.parent.id, item.task_id, 'Results retains the aggregate parent independently')
  H.ok(item.detail:find('step ' .. item.recipe_step, 1, true), 'step provenance is visible and filterable')
  H.ok(item.detail:find('#' .. item.child_task_id, 1, true), 'child task provenance is visible')
end
H.ok(result.items[1].id ~= result.items[2].id, 'identical diagnostics from different steps have distinct stable identities')
detail.locations[1], detail.locations[2] = detail.locations[2], detail.locations[1]
local reordered = H.ok(Results.read('task', running.ctx, nil, running.parent.id))
H.eq(result.items[1].id, reordered.items[2].id, 'result identity follows its provenance through reordering')
H.eq(result.items[2].id, reordered.items[1].id)
local previous_revision = reordered.revision
detail.locations[1].recipe_step = 'different-origin'
H.ok(H.ok(Results.read('task', running.ctx, nil, running.parent.id)).revision ~= previous_revision,
  'changed provenance invalidates the Results selection snapshot')
detail.locations[1].recipe_step = 'second'
local poison = setmetatable({}, { __tostring = function() error('Opaque metadata must not convert to text') end })
detail.locations[1].recipe_step, detail.locations[1].child_task_id = poison, 0 / 0
local sanitized = H.ok(Results.read('task', running.ctx, nil, running.parent.id))
H.eq(nil, sanitized.items[1].recipe_step, 'arbitrary result metadata is omitted')
H.eq(nil, sanitized.items[1].child_task_id, 'nonfinite child IDs are omitted')
detail.locations[1].recipe_step, detail.locations[1].child_task_id = string.rep('x', 4097), 9007199254740992
sanitized = H.ok(Results.read('task', running.ctx, nil, running.parent.id))
H.eq(nil, sanitized.items[1].recipe_step, 'oversized provenance is bounded before rendering')
H.eq(nil, sanitized.items[1].child_task_id, 'child IDs outside the exact integer range are omitted')
detail.locations[1].recipe_step, detail.locations[1].child_task_id = 'second', detail.steps[2].task_id
local preview = H.ok(Report.prepare(running.parent, { version = CE.version }))
local decoded = vim.json.decode(preview.encoded)
H.eq('sequential-direct', decoded.task.process_scope, 'parent report preserves the sequential direct-process boundary')
H.eq(true, decoded.task.termination_confirmed, 'completed recipe confirms its owned child exit')
H.eq('excluded', decoded.scope.paths, 'adding scope never broadens report disclosure')
for _, private in ipairs({ folder, 'Fixture project', 'shared diagnostic', 'source.cpp', 'argv', 'locations' }) do
  H.ok(not preview.encoded:find(private, 1, true), 'summary still excludes path/output/result data: ' .. private)
end
running.parent.process_scope = nil
H.eq('sequential-direct', vim.json.decode(H.ok(Report.prepare(running.parent, { version = CE.version })).encoded).task.process_scope,
  'report preserves a known scope from the retained detail fallback')
running.parent.process_scope = 'private-unrecognized-scope'
preview = H.ok(Report.prepare(running.parent, { version = CE.version }))
H.eq(nil, vim.json.decode(preview.encoded).task.process_scope, 'unknown scopes remain excluded')
H.ok(not preview.encoded:find('private-unrecognized-scope', 1, true), 'unknown scope cannot leak arbitrary text')
running.parent.process_scope = 'sequential-direct'

running = start({ 'child_limited' })
detail = running.finish('succeeded')
local limited_child = child(running.parent, detail.child_ids[1])
H.eq(5000, #detail.locations, 'child parser limit retains the bounded aggregate')
H.eq(true, limited_child.detail.locations_truncated, 'real child parser reports the lost 5001st location')
H.eq(true, detail.locations_truncated, 'recipe preserves its child parser limit')
H.ok(detail.locations_message:find('Step child_limited:', 1, true), 'partial aggregate names its limited child')
H.ok(detail.locations_message:find('parsed results were limited', 1, true), 'partial aggregate retains the child limit reason')
H.ok(CE.open_task_results(running.parent.id, { interactive = false }), 'actual parent Results opens after successful limited execution')
local result_frame = session.active.stack[#session.active.stack]
H.eq('results', result_frame.id)
H.eq(true, result_frame.data.result.truncated, 'parent Results exposes partial locations')
H.ok(result_frame.data.result.status_message:find('partial results:', 1, true), 'parent Results explains that successful execution has partial results')

running = start({ 'aggregate_first', 'aggregate_second' })
detail = running.finish('succeeded')
for _, id in ipairs(detail.child_ids) do
  local actual = child(running.parent, id)
  H.eq(3000, #actual.detail.locations, 'individual child remains below its parser limit')
  H.eq(false, actual.detail.locations_truncated)
end
H.eq(5000, #detail.locations, 'multiple complete children respect the aggregate cap')
H.eq(true, detail.locations_truncated, 'parent reports locations omitted by its own cap')
result = H.ok(Results.read('task', running.ctx, nil, running.parent.id))
H.eq(true, result.truncated, 'parent Results exposes aggregate truncation independently of child limits')
H.ok(result.status_message:find('limited to 5000 locations', 1, true), 'parent Results gives the aggregate limit reason')

running = start({ 'output_limited' })
detail = running.finish('succeeded')
limited_child = child(running.parent, detail.child_ids[1])
H.eq(true, limited_child.detail.truncated, 'real child crosses the process output capture limit')
H.eq(false, limited_child.detail.locations_truncated, 'capture loss is distinct from the parser result cap')
H.eq(true, detail.locations_truncated, 'parent warns that captured output may have lost further locations')
H.eq(limited_child.detail.invalid_locations, detail.invalid_locations, 'parent preserves rejected source entries')
H.ok(detail.locations_message:find('captured process output was limited to 1 MiB', 1, true), 'parent retains the actual process capture limit reason')

running = start({ 'first', 'failed', 'never' })
detail = running.finish('failed')
H.eq({ 'succeeded', 'failed' }, { detail.steps[1].status, detail.steps[2].status }, 'success followed by failure stops the recipe')
H.eq(2, #detail.steps)
H.eq(7, child(running.parent, detail.steps[2].task_id).detail.exit_code, 'actual child failure retains its exit code')
H.eq(2, #H.ok(Results.read('task', running.ctx, nil, running.parent.id)).items, 'partial results remain available after failure')
no_later_step()

running = start({ 'first', 'waiting', 'never' })
H.ok(vim.wait(8000, function() return vim.fn.filereadable(folder .. '/waiting.started') == 1 end, 10), 'second real child reaches its running stage')
H.eq('pending', running.parent.status)
local current_child
for _, task in ipairs(CE.operations()) do if task.parent_id == running.parent.id and task.status == 'pending' then current_child = task end end
H.ok(current_child, 'parent owns exactly the running second child')
H.ok(CE.cancel(running.parent.id), 'explicit parent cancellation is accepted')
H.eq('pending', running.parent.status, 'cancel request does not pretend the parent has exited')
H.eq('pending', current_child.status, 'cancel request waits for the actual child exit callback')
detail = running.finish('cancelled')
H.eq('cancelled', current_child.status)
H.eq(true, detail.cancelled)
H.eq(true, detail.termination_confirmed)
H.eq({ 'succeeded', 'cancelled' }, { detail.steps[1].status, detail.steps[2].status })
no_later_step()

running = start({ 'first', 'waiting', 'never' }, 600)
detail = running.finish('failed')
H.eq(true, detail.timed_out, 'a real child timeout remains a failure rather than synthetic cancellation')
H.eq('failed', child(running.parent, detail.steps[2].task_id).status)
no_later_step()

running = start({ 'guarded', 'never' })
H.ok(vim.wait(8000, function() return vim.fn.filereadable(folder .. '/guarded.started') == 1 end, 10), 'profile replacement happens while the first real child runs')
local registry_before = CE.registry()
local profile_after = CE.profile()
profile_after.ui.width = 53
H.ok(CE.apply_profile(profile_after, 'replace'), 'actual profile Apply creates a new environment during the recipe')
H.ok(CE.registry() ~= registry_before, 'Apply replaces the registry while retaining live operations')
detail = running.finish('succeeded')
H.eq(2, #detail.steps, 'unchanged execution declarations continue through the newly active environment')
H.eq('succeeded', detail.steps[1].status)
H.eq('succeeded', detail.steps[2].status)
H.eq(2, #detail.child_ids)
H.eq(1, vim.fn.filereadable(folder .. '/never.started'), 'unrelated appearance Apply permits the reviewed next process')

CE.close(); CE.disable()
vim.api.nvim_set_current_buf(source_buf)
H.eq(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), 'recipe and Results reading never alter source text')
H.eq(source_tick, vim.api.nvim_buf_get_changedtick(source_buf), 'source revision remains unchanged')
H.eq(quickfix, vim.fn.getqflist(), 'task parsing/Results never replace native quickfix')
H.eq(loclist, vim.fn.getloclist(0), 'task parsing/Results never replace the source window location list')
io.stdout:write('Recipe result checks: ' .. H.checks .. '\n')
