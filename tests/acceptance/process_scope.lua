-- Opt-in actual process tree evidence; use run_process_scope.py with an already
-- built helper and an existing Python. This is not default fixture coverage.
local H = require('helpers')
local CE, Profile = require('re35'), require('command_tree.profile')
local helper, python = assert(vim.env.RE35_PROCESS_HELPER), assert(vim.env.RE35_PROCESS_PYTHON)
local folder = H.tempdir('process-scope')
local script = H.repo_root() .. '/tests/acceptance/process_tree.py'
local source = folder .. '/source.txt'
vim.fn.writefile({ 'saved source' }, source)
vim.api.nvim_cmd({ cmd = 'edit', args = { source } }, {})
local options = { auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false }, process_helper = helper,
  providers = { builtin = true, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false },
  integrations = { theme = false } }
local observations = {}
do
  local profile = Profile.empty()
  profile.tools.argv = { command = 'python', args = {} }
  local arguments = { '', 'a b', 'quote"slash\\', 'tail\\', '한글 😀', 'literal$()&;|<>' }
  local argv = { script, 'args', folder }
  vim.list_extend(argv, arguments)
  options.profile.data = profile
  options.tool_overrides = { argv = { command = python, args = argv, cancel_grace_ms = 150 } }
  CE.setup(options)
  local done, completed = 0, nil
  H.ok(CE.execute('tool.argv', {}, { interactive = false, done = function(ok, detail)
    done = done + 1; completed = { ok = ok, detail = detail }
  end }))
  H.ok(vim.wait(5000, function() return done == 1 end, 10))
  H.eq(true, completed.ok); H.eq(true, completed.detail.termination_confirmed)
  H.eq(arguments, vim.json.decode(table.concat(vim.fn.readfile(folder .. '/argv.json'), '\n')), 'argv is exact data, including Unicode and shell metacharacters')
  observations[#observations + 1] = { mode = 'argv', status = 'succeeded', scope = completed.detail.process_scope,
    termination_confirmed = completed.detail.termination_confirmed }
end
local function alive(pid)
  return vim.system({ python, script, 'alive', tostring(pid) }):wait(3000).code == 0
end
local function run(mode, timeout)
  local dir = folder .. '/' .. mode
  vim.fn.mkdir(dir, 'p')
  local profile = Profile.empty()
  profile.projects, profile.recipes = {}, {}
  profile.tools.tree = { command = 'python', args = {} }
  options.tool_overrides = { tree = { command = python, args = { script, mode, dir }, cancel_grace_ms = 150, timeout_ms = timeout } }
  options.profile.data = profile
  CE.setup(options)
  local done, completed, task = 0, nil, nil
  local accepted, reason, admitted = CE.execute('tool.tree', {}, { interactive = false, done = function(ok, detail, operation)
    done = done + 1; completed = { ok = ok, detail = detail }; task = operation
  end })
  H.ok(accepted, tostring(reason))
  H.ok(vim.wait(8000, function() return vim.fn.filereadable(dir .. '/child-ready') == 1 end, 10),
    'actual child has started; early completion: ' .. vim.inspect(completed))
  local pids = vim.json.decode(table.concat(vim.fn.readfile(dir .. '/launched.json'), '\n'))
  if mode == 'cancel' or mode == 'helper-crash' then
    H.ok(vim.wait(3000, function() return vim.fn.filereadable(dir .. '/parent-ready') == 1 end, 10), 'parent produced output before cancellation')
    task = admitted
    if mode == 'cancel' then H.ok(task:cancel(), 'cancel accepts the owned task')
    else H.ok(vim.uv.kill(task.process_pid, 9) == 0, 'only the fixture-owned helper is deliberately stopped') end
  end
  H.ok(vim.wait(8000, function() return done == 1 end, 10), 'callback follows bounded scope termination')
  H.eq(1, done, 'exactly one completion')
  H.eq(mode ~= 'helper-crash', completed.detail.termination_confirmed, vim.inspect(completed.detail))
  H.eq(mode == 'helper-crash' and 'unconfirmed' or 'confirmed', completed.detail.descendant_termination)
  H.eq(vim.uv.os_uname().sysname == 'Windows_NT' and 'windows_job' or 'linux_group', completed.detail.process_scope)
  H.ok(not alive(pids.parent), 'actual original parent has exited')
  if mode ~= 'detached' then
    H.ok(not alive(pids.child), 'actual child is no longer running')
    local heartbeat = vim.fn.readfile(dir .. '/heartbeat')
    vim.wait(150, function() return false end, 10)
    H.eq(heartbeat, vim.fn.readfile(dir .. '/heartbeat'), 'no post-completion child activity')
  else
    H.ok(alive(pids.child), 'deliberate setsid daemon is excluded, not claimed terminated')
    H.ok(completed.detail.detached_observed >= 1, 'adopted detached child is reported')
    vim.fn.writefile({ 'stop' }, dir .. '/stop-child')
    H.ok(vim.wait(3000, function() return not alive(pids.child) end, 50), 'fixture daemon cooperatively cleaned by its own stop file')
  end
  if mode ~= 'helper-crash' then
    H.ok(completed.detail.stdout:find('parent stdout', 1, true), 'stdout is preserved')
    H.ok(completed.detail.stderr:find('parent stderr', 1, true), 'stderr is preserved')
  end
  H.eq({ 'saved source' }, vim.fn.readfile(source), 'no source save')
  if mode == 'helper-crash' then H.eq(false, completed.ok); H.eq('failed', task.status); H.eq(125, completed.detail.exit_code)
  elseif mode == 'normal' or mode == 'detached' then H.eq(true, completed.ok); H.eq(0, completed.detail.exit_code)
  elseif mode == 'failure' then H.eq(false, completed.ok); H.eq(7, completed.detail.exit_code)
  elseif mode == 'timeout' then H.eq(false, completed.ok); H.eq(true, task.timed_out); H.eq('failed', task.status)
  else H.eq(false, completed.ok); H.eq(true, completed.detail.cancelled); H.eq('cancelled', task.status) end
  if vim.uv.os_uname().sysname == 'Linux' and (mode == 'cancel' or mode == 'timeout') then
    H.eq(true, completed.detail.forced, 'TERM-ignoring children required actual group KILL after grace')
  end
  observations[#observations + 1] = { mode = mode, status = task.status, scope = completed.detail.process_scope,
    termination_confirmed = completed.detail.termination_confirmed, detached_observed = completed.detail.detached_observed }
end
run('normal')
run('failure')
run('cancel')
-- Allow actual descendant startup under concurrent platform/full-suite load.
-- The controlled parent holds for 12s, so 5s still exercises a real timeout.
run('timeout', 5000)
run('helper-crash')
if vim.uv.os_uname().sysname == 'Linux' then run('detached') end
-- The real helper must also own hidden sequential recipe steps, aggregate their
-- actual evidence, and stop before the next step after explicit parent cancel.
do
  local dir = folder .. '/recipe'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(vim.fn.readfile(script), folder .. '/process_tree.py')
  local profile = Profile.empty()
  profile.projects, profile.recipes = {}, {}
  profile.tools.tree = { command = 'python', args = {} }
  profile.projects.owned = { name = 'Owned fixture', root = { base = 'project', path = '.' }, source = 'source.txt',
    configurations = { 'Debug', 'Release' }, targets = { 'A', 'B' } }
  profile.recipes.owned = { name = 'Owned sequential recipe', project = 'owned', steps = {
    { id = 'compile', tool = 'tree', args = { 'process_tree.py', 'recipe-cancel', 'recipe' } },
    { id = 'never', tool = 'tree', args = { 'process_tree.py', 'next', 'recipe' } },
  } }
  options.profile.data, options.project_overrides = profile, { owned = { root = folder } }
  options.tool_overrides = { tree = { command = python, cancel_grace_ms = 150 } }
  CE.setup(options)
  local count, completed, parent = 0, nil, nil
  H.ok(CE.run_recipe('owned', { configuration = 'Debug', target = 'A' }, { interactive = false, save = 'saved',
    done = function(ok, detail, task) count = count + 1; completed = { ok = ok, detail = detail }; parent = task end }))
  for _, task in ipairs(CE.operations()) do if task.command_id == 'recipe.owned' and task.status == 'pending' then parent = task end end
  H.ok(parent, 'actual recipe creates the retained parent')
  local scope = vim.uv.os_uname().sysname == 'Windows_NT' and 'windows_job' or 'linux_group'
  H.eq('sequential-' .. scope, parent.process_scope, 'parent announces configured hidden-step scope')
  H.ok(vim.wait(5000, function() return vim.fn.filereadable(dir .. '/parent-ready') == 1 end, 10), 'actual recipe parent and child running')
  local pids = vim.json.decode(table.concat(vim.fn.readfile(dir .. '/launched.json'), '\n'))
  H.ok(CE.cancel(parent.id), 'public parent cancellation accepted')
  H.eq('pending', parent.status, 'parent remains pending until actual scope receipt')
  H.ok(vim.wait(8000, function() return count == 1 end, 10), 'recipe waits for actual child scope cleanup')
  H.eq(1, count); H.eq(false, completed.ok); H.eq('cancelled', parent.status)
  H.eq('sequential-' .. scope, completed.detail.process_scope)
  H.eq(true, completed.detail.termination_confirmed)
  H.eq('confirmed', completed.detail.descendant_termination)
  H.eq(1, #completed.detail.steps, 'later recipe step never starts')
  H.eq('compile', completed.detail.steps[1].id)
  H.eq('cancelled', completed.detail.steps[1].status)
  H.eq(scope, completed.detail.steps[1].process_scope)
  H.eq(true, completed.detail.steps[1].termination_confirmed)
  H.eq('confirmed', completed.detail.steps[1].descendant_termination)
  H.eq(0, vim.fn.filereadable(dir .. '/next-started'))
  H.ok(not alive(pids.parent) and not alive(pids.child), 'both actual recipe processes have stopped')
  if scope == 'linux_group' then H.eq(true, completed.detail.forced, 'parent preserves child automatic forced cleanup') end
  H.eq({ 'saved source' }, vim.fn.readfile(source), 'recipe cancellation never writes source')
  observations[#observations + 1] = { mode = 'recipe-cancel', status = parent.status, scope = completed.detail.process_scope,
    termination_confirmed = completed.detail.termination_confirmed, descendant_termination = completed.detail.descendant_termination,
    steps = #completed.detail.steps, forced = completed.detail.forced }
end
if vim.env.RE35_NONBLOCK_FAILURE_HELPER then
  local dir = folder .. '/nonblocking-fault'
  vim.fn.mkdir(dir, 'p')
  local profile = Profile.empty()
  profile.tools.fault = { command = 'python', args = {} }
  options.profile.data, options.project_overrides = profile, {}
  options.process_helper = vim.env.RE35_NONBLOCK_FAILURE_HELPER
  options.tool_overrides = { fault = { command = python, args = { script, 'nonblocking-fault', dir }, cancel_grace_ms = 150 } }
  CE.setup(options)
  local count, completed, task = 0, nil, nil
  H.ok(CE.execute('tool.fault', {}, { interactive = false, done = function(ok, detail, operation)
    count = count + 1; completed = { ok = ok, detail = detail }; task = operation
  end }))
  H.ok(vim.wait(5000, function() return count == 1 end, 10), 'nonblocking setup failure does not hang owner control')
  H.eq(1, count); H.eq(false, completed.ok); H.eq('failed', task.status)
  H.eq('linux_group', completed.detail.process_scope)
  H.eq(true, completed.detail.termination_confirmed, 'actual pinned-group exceptional cleanup observed')
  H.eq('confirmed', completed.detail.descendant_termination)
  H.eq('Nonblocking owner control setup failed', completed.detail.message)
  H.eq(125, completed.detail.exit_code)
  H.eq(1, vim.fn.filereadable(dir .. '/child-ready'), 'real descendant spawned before injected control failure')
  local pids = vim.json.decode(table.concat(vim.fn.readfile(dir .. '/launched.json'), '\n'))
  H.ok(not alive(pids.parent) and not alive(pids.child), 'exceptional cleanup ends actual owned parent and child')
  observations[#observations + 1] = { mode = 'nonblocking-setup-fault', status = task.status, scope = completed.detail.process_scope,
    termination_confirmed = completed.detail.termination_confirmed, evidence = 'explicit compile-time fault helper' }
end
for _, fault in ipairs({
  { name = 'ready-write', helper = vim.env.RE35_READY_WRITE_FAILURE_HELPER, mode = 'nonblocking-fault',
    confirmed = false, message = 'Session readiness handoff failed' },
  { name = 'result-write', helper = vim.env.RE35_RESULT_WRITE_FAILURE_HELPER, mode = 'normal',
    confirmed = true, message = 'Session anchor exited before command result' },
}) do
  if fault.helper then
    local dir = folder .. '/' .. fault.name .. '-fault'
    vim.fn.mkdir(dir, 'p')
    local profile = Profile.empty()
    profile.tools.fault = { command = 'python', args = {} }
    options.profile.data, options.project_overrides = profile, {}
    options.process_helper = fault.helper
    options.tool_overrides = { fault = { command = python, args = { script, fault.mode, dir }, cancel_grace_ms = 150 } }
    CE.setup(options)
    local count, completed, task = 0, nil, nil
    H.ok(CE.execute('tool.fault', {}, { interactive = false, done = function(ok, detail, operation)
      count = count + 1; completed = { ok = ok, detail = detail }; task = operation
    end }))
    H.ok(vim.wait(8000, function() return count == 1 end, 10), 'broken handoff completes without an owner-control hang')
    H.eq(1, count); H.eq(false, completed.ok); H.eq('failed', task.status)
    H.eq('linux_group', completed.detail.process_scope)
    H.eq(fault.confirmed, completed.detail.termination_confirmed, 'receipt claims only actually observed scope cleanup')
    H.eq(fault.confirmed and 'confirmed' or 'unconfirmed', completed.detail.descendant_termination)
    H.eq(fault.message, completed.detail.message)
    H.eq(125, completed.detail.exit_code, 'missing handoff never invents the normal tool exit code')
    H.eq(0, completed.detail.signal, 'missing handoff has no observed original tool signal')
    H.eq(1, vim.fn.filereadable(dir .. '/parent-ready'), 'real parent reached the existing fixture marker')
    H.eq(1, vim.fn.filereadable(dir .. '/child-ready'), 'real descendant started before the injected handoff failure')
    local pids = vim.json.decode(table.concat(vim.fn.readfile(dir .. '/launched.json'), '\n'))
    H.ok(vim.wait(3000, function() return not alive(pids.parent) and not alive(pids.child) end, 10),
      'broken handoff ends both actual owned processes, including the readiness-failure descendant')
    H.eq(0, vim.fn.filereadable(dir .. '/child-exited'), 'the descendant was stopped before cooperative completion')
    H.eq({ 'saved source' }, vim.fn.readfile(source), 'handoff failure never writes source')
    observations[#observations + 1] = { mode = fault.name .. '-fault', status = task.status,
      scope = completed.detail.process_scope, termination_confirmed = completed.detail.termination_confirmed,
      descendant_termination = completed.detail.descendant_termination, actual_processes_stopped = true,
      evidence = 'explicit compile-time broken-reader pipe; actual EPIPE/SIGPIPE' }
  end
end
if vim.env.RE35_PROCESS_OBSERVATION then
  vim.fn.writefile({ vim.json.encode({ evidence = 'controlled-owned-process-tree', checks = H.checks, cases = observations }) }, vim.env.RE35_PROCESS_OBSERVATION)
end
print('process_scope: ' .. H.checks .. ' checks')
