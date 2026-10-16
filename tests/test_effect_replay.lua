-- Replay admission follows the effect: saved inputs permit unrelated editor
-- activity, while explicitly selected writes retain exact native ownership.
local H, K, A = require('helpers'), require('command_tree.keys'), require('command_tree.arguments')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('effect-replay')
local root, other = folder .. '/project', folder .. '/other-project'
vim.fn.mkdir(root .. '/src', 'p'); vim.fn.mkdir(root .. '/build', 'p'); vim.fn.mkdir(other, 'p')
vim.fn.writefile({ '{}' }, root .. '/package.json'); vim.fn.writefile({ '{}' }, other .. '/package.json')
local names = { root .. '/src/a.cpp', root .. '/src/b.hpp', root .. '/src/c-notes.txt', other .. '/view.txt' }
local buffers = {}
for index, name in ipairs(names) do
  vim.fn.writefile({ 'saved ' .. index }, name)
  buffers[index] = vim.fn.bufadd(name); vim.fn.bufload(buffers[index])
end
local source, second, notes, view = unpack(buffers)
vim.api.nvim_set_current_buf(source)
vim.o.columns, vim.o.lines = 130, 44
local profile = Profile.empty()
profile.tools.fixture = { command = 'nvim', args = { '{file}', '--fixture' }, cwd = { base = 'project', path = 'build' } }
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = profile }, window = { icons = false },
  providers = { builtin = false, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false },
  tool_overrides = { fixture = { command = vim.v.progpath } } })
local system, launches, writes = vim.system, {}, {}
vim.system = function(argv, options, done)
  launches[#launches + 1] = { argv = vim.deepcopy(argv), cwd = options.cwd, done = done }
  return { pid = 1000 + #launches, kill = function() error('This fixture never cancels a process') end }
end
local write_event = vim.api.nvim_create_autocmd('BufWritePre', { callback = function(event)
  writes[#writes + 1] = event.buf
end })
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function complete(launch, task)
  launch.done({ code = 7, signal = 0 })
  H.ok(vim.wait(2000, function() return task.status ~= 'pending' end, 10), 'Fake transport completes its actual owned task')
  H.eq('failed', task.status)
end
local accepted, why, original = CE.execute('tool.fixture', {}, { interactive = false })
H.ok(accepted, why); H.eq(1, #launches)
complete(launches[1], original)
local original_target = vim.deepcopy(original.process_target)
local function reset()
  CE.close(); vim.api.nvim_set_current_buf(source)
  vim.fn.delete(root .. '/src/package.json')
  for index, buf in ipairs(buffers) do
    vim.fn.writefile({ 'saved ' .. index }, names[index])
    vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
    vim.api.nvim_buf_call(buf, function() vim.cmd('silent edit!') end)
  end
  writes = {}
end
local function edit(buf, text) vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text }) end
local function review(task, current)
  CE.close(); vim.api.nvim_set_current_buf(current or source)
  local result = { callbacks = 0, launch_count = #launches, operations = #CE.operations() }
  result.accepted, result.reason = CE.rerun((task or original).id, { interactive = false, force_review = true,
    done = function(ok, detail, operation)
      result.callbacks, result.ok, result.detail, result.task = result.callbacks + 1, ok, detail, operation
    end })
  H.ok(result.accepted, result.reason)
  H.eq('input', session.active.mode, 'Replay opens the actual saved-file decision')
  H.eq(result.operations, #CE.operations(), 'Review has no execution effect')
  return result
end
local function saved() keys('<Down><CR>') end
local function selected(values)
  keys('<CR>')
  H.eq('multiselect', session.active.input.command.arguments[1].kind)
  local input = session.active.input
  for _, value in ipairs(values) do
    local wanted
    for index, item in ipairs(input.choices) do if A.value(item) == value then wanted = index end end
    H.ok(wanted, 'Only reviewed modified files can be selected')
    while input.selected < wanted do keys('<Down>') end
    while input.selected > wanted do keys('<Up>') end
    keys('<Space>')
  end
end
local function launched(result)
  H.eq(result.launch_count + 1, #launches, 'Explicit submit dispatches exactly one process')
  local next_task = CE.operations()[1]
  for _, task in ipairs(CE.operations()) do if task.id > (next_task.id or 0) then next_task = task end end
  H.eq(original_target, next_task.process_target, 'Saved source/root/cwd/argv remain the original target')
  H.eq(original_target.argv, launches[#launches].argv)
  H.eq(original_target.cwd, launches[#launches].cwd)
  complete(launches[#launches], next_task)
  H.eq(1, result.callbacks, 'Completion is settled once')
end
local function refused(result, text, retained_count)
  H.eq(result.launch_count, #launches, 'Rejected admission starts no process')
  H.eq(retained_count or result.operations, #CE.operations(), 'Rejected admission creates no task')
  H.eq(1, result.callbacks, 'Rejection settles once')
  H.eq(false, result.ok)
  H.ok(type(result.detail) == 'string' and result.detail ~= '', 'Rejection explains the invalidated fact')
  if text then H.ok(result.detail:find(text, 1, true), result.detail) end
end

-- Loaded buffers are not the process's complete dependency graph. Editing,
-- opening or unloading them must not pretend that the saved disk inputs moved.
reset(); edit(source, 'source draft'); edit(second, 'header draft')
local transient_name = root .. '/src/transient.txt'
vim.fn.writefile({ 'transient saved' }, transient_name)
local transient = vim.fn.bufadd(transient_name); vim.fn.bufload(transient)
local result = review()
edit(source, 'source changed again'); edit(second, 'header changed again'); edit(notes, 'new note')
vim.api.nvim_buf_delete(transient, { force = true })
local loaded = vim.fn.bufadd(root .. '/src/loaded-after-review.txt'); vim.fn.bufload(loaded)
edit(loaded, 'new unsaved file')
saved(); launched(result)
H.eq({}, writes, 'Run saved files never writes loaded buffers')
H.eq({ 'saved 1' }, vim.fn.readfile(names[1])); H.eq({ 'saved 2' }, vim.fn.readfile(names[2]))
H.eq(true, vim.bo[source].modified); H.eq(true, vim.bo[second].modified)
vim.api.nvim_buf_delete(loaded, { force = true })

reset(); result = review(nil, view); edit(view, 'unrelated current document changed'); saved(); launched(result)
H.eq({}, writes, 'Current editor notes do not become implicit save targets')

-- Admission still depends on the reviewed disk source, source identity and
-- exact executable contract, rather than trusting a generic "safe" flag.
reset(); result = review(); vim.fn.writefile({ 'externally replaced original source' }, names[1]); saved()
refused(result, 'disk'); H.eq({}, writes)
reset(); result = review(); vim.api.nvim_buf_set_name(source, root .. '/src/renamed.cpp'); saved()
refused(result, 'renamed'); H.eq({}, writes); vim.api.nvim_buf_set_name(source, names[1])
reset(); result = review(); vim.fn.writefile({ '{}' }, root .. '/src/package.json'); saved()
refused(result); H.eq({}, writes)
reset(); result = review(); H.eq(0, vim.fn.delete(root .. '/build', 'd')); saved()
refused(result, 'directory'); H.eq({}, writes); vim.fn.mkdir(root .. '/build', 'p')
reset()
local command = CE.registry():get('tool.fixture')
local revision, validator, cwd = command.process_revision, command.process_validate_target, command.process_cwd
result = review(); command.process_revision = revision .. '-changed'; saved(); refused(result)
command.process_revision = revision
result = review(); command.process_validate_target = function(target)
  local fresh = vim.deepcopy(target); fresh.argv[#fresh.argv + 1] = '--changed'; return true, fresh
end
saved(); refused(result); command.process_validate_target = validator
result = review(); command.process_cwd = function() return other end; saved(); refused(result)
command.process_cwd = cwd

-- A visible chooser cannot acquire a different invocation by mutating a live
-- history record or by evicting and reusing its public numeric task ID.
reset(); result = review()
local prior_args = vim.deepcopy(original.args)
original.args.unreviewed = 'replacement argument'; saved(); refused(result, 'Original task changed')
original.args = prior_args
result = review()
original.process_target.argv[#original.process_target.argv + 1] = '--replacement-target'
saved(); refused(result, 'Original task changed'); original.process_target = vim.deepcopy(original_target)
local function retained_index()
  for index, task in ipairs(session.executor.operations) do if task == original then return index end end
  error('The original task must still be retained before this test')
end
result = review()
local index = retained_index()
table.remove(session.executor.operations, index)
saved(); refused(result, 'retained history', result.operations - 1)
table.insert(session.executor.operations, index, original)
result = review(); index = retained_index()
session.executor.operations[index] = vim.deepcopy(original)
saved(); refused(result, 'retained history')
session.executor.operations[index] = original

-- All selected records must be valid before even the first native write.
reset(); edit(source, 'first selected draft'); edit(second, 'second selected draft')
result = review(); selected({ source, second }); edit(second, 'changed after selecting'); keys('<CR>')
refused(result); H.eq({}, writes, 'Changed second selection prevents the first write too')
H.eq({ 'saved 1' }, vim.fn.readfile(names[1])); H.eq({ 'saved 2' }, vim.fn.readfile(names[2]))

-- A successful first write may run hooks which invalidate a later selection.
-- Report that partial effect exactly and never write or dispatch the remainder.
reset(); edit(source, 'first selected draft'); edit(second, 'second selected draft')
result = review(); selected({ source, second })
local hook = vim.api.nvim_create_autocmd('BufWritePre', { buffer = source, once = true, callback = function()
  edit(second, 'second changed by first native write hook')
end })
keys('<CR>'); pcall(vim.api.nvim_del_autocmd, hook)
refused(result, 'already saved: ' .. names[1]); H.eq({ source }, writes)
H.eq({ 'first selected draft' }, vim.fn.readfile(names[1])); H.eq({ 'saved 2' }, vim.fn.readfile(names[2]))
H.eq(false, vim.bo[source].modified); H.eq(true, vim.bo[second].modified)

reset(); edit(source, 'selected source'); edit(second, 'unselected header')
result = review(); selected({ source }); edit(second, 'unselected header changed during review'); keys('<CR>')
launched(result); H.eq({ source }, writes, 'Only explicit selections reach native writes')
H.eq({ 'selected source' }, vim.fn.readfile(names[1])); H.eq({ 'saved 2' }, vim.fn.readfile(names[2]))
H.eq(true, vim.bo[second].modified)

reset(); edit(source, 'selected readonly source'); result = review(); selected({ source })
vim.bo[source].readonly = true; keys('<CR>'); refused(result); H.eq({}, writes)
vim.bo[source].readonly = false

-- Hooks may format a selected document, but cannot redirect its reviewed
-- write to a new filename. The final guard must leave no autocmd behind.
local function write_hook_count() return #vim.api.nvim_get_autocmds({ event = 'BufWritePre' }) end
reset(); edit(source, 'selected before rename hook'); result = review(); selected({ source })
local hooks_before = write_hook_count()
local redirected = root .. '/src/unreviewed-write.cpp'
hook = vim.api.nvim_create_autocmd('BufWritePre', { buffer = source, once = true, callback = function()
  vim.api.nvim_buf_set_name(source, redirected)
end })
keys('<CR>'); pcall(vim.api.nvim_del_autocmd, hook)
refused(result, 'write hook')
H.eq(0, vim.fn.filereadable(redirected), 'A rename hook cannot create an unreviewed path')
H.eq({ 'saved 1' }, vim.fn.readfile(names[1]), 'A redirected save leaves the reviewed disk file untouched')
H.eq(hooks_before, write_hook_count(), 'Rejected target hook leaves no final write guard')
vim.api.nvim_buf_set_name(source, names[1])

reset(); edit(source, 'selected before formatting'); result = review(); selected({ source })
hooks_before = write_hook_count()
hook = vim.api.nvim_create_autocmd('BufWritePre', { buffer = source, once = true, callback = function()
  edit(source, 'formatted by ordinary native hook')
end })
keys('<CR>'); pcall(vim.api.nvim_del_autocmd, hook)
H.eq(hooks_before, write_hook_count(), 'Successful native formatting leaves no final write guard')
launched(result)
H.eq({ 'formatted by ordinary native hook' }, vim.fn.readfile(names[1]), 'Formatting remains allowed at the selected path')
H.eq(false, vim.bo[source].modified)

reset(); edit(source, 'selected before failed hook'); result = review(); selected({ source })
hooks_before = write_hook_count()
hook = vim.api.nvim_create_autocmd('BufWritePre', { buffer = source, once = true, callback = function()
  error('Deliberate earlier native write hook failure')
end })
keys('<CR>'); pcall(vim.api.nvim_del_autocmd, hook)
refused(result, 'Deliberate earlier native write hook failure')
H.eq({ 'saved 1' }, vim.fn.readfile(names[1]), 'An earlier hook failure leaves the selected disk input untouched')
H.eq(hooks_before, write_hook_count(), 'An earlier hook failure also removes the not-yet-run final guard')

-- Arbitrary process commands do not inherit the narrower native tool policy.
reset()
local custom_runs = 0
CE.register({ id = 'fixture.custom', name = 'Custom process', backend = 'process', async = true,
  process_revision = 'custom-one', process_resolve_target = function() return vim.deepcopy(original_target) end,
  process_validate_target = function(target) return true, vim.deepcopy(target) end,
  process_cwd = function() return original_target.cwd end,
  run = function(_, _, done)
    custom_runs = custom_runs + 1
    vim.schedule(function() done(false, vim.tbl_extend('force', vim.deepcopy(original_target), { kind = 'process' })) end)
  end })
local custom
accepted, why, custom = CE.execute('fixture.custom', {}, { interactive = false })
H.ok(accepted, why)
H.ok(vim.wait(2000, function() return custom.status ~= 'pending' end, 10))
H.eq('failed', custom.status); H.eq(1, custom_runs)
result = review(custom); edit(source, 'custom context changed'); saved(); refused(result)
H.eq(1, custom_runs, 'Generic context drift stays conservative')
reset(); result = review(custom); edit(notes, 'custom dirty set changed'); saved(); refused(result)
H.eq(1, custom_runs, 'Generic dirty-set drift stays conservative')
reset(); result = review(custom)
H.ok(CE.update_profile(function(data) data.ui.icons = false end))
H.eq(1, result.callbacks, 'Profile replacement settles the old generic review')
H.eq(false, result.ok); H.eq(result.operations, #CE.operations()); H.eq(1, custom_runs)

CE.close(); CE.disable(); Session.new = construct; vim.system = system
vim.api.nvim_del_autocmd(write_event)
H.eq(1, #vim.api.nvim_list_wins(), 'Replay review releases its owned UI resources')
io.stdout:write('Effect replay checks: ' .. H.checks .. '\n')
