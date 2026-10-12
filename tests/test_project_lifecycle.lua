-- Reviewed save/replay effects use real files, native write hooks and owned
-- processes. The fixture never relies on a compiler or optional plugin.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile, Project = require('command_tree'), require('command_tree.profile'), require('command_tree.project')
-- Every marker has equal priority, including a project nested in a Git tree.
-- The test directory may itself sit inside this repository during validation.
local roots = H.tempdir('nearest-project-root')
local enclosing, cmake, package_root, file_root = roots .. '/outer git', roots .. '/outer git/cmake',
  roots .. '/outer git/cmake/package', roots .. '/outer git/cmake/package/file marker'
vim.fn.mkdir(enclosing .. '/.git', 'p')
vim.fn.mkdir(file_root .. '/src', 'p')
vim.fn.mkdir(cmake .. '/src', 'p'); vim.fn.mkdir(package_root .. '/src', 'p')
vim.fn.writefile({ 'cmake_minimum_required(VERSION 3.20)' }, cmake .. '/CMakeLists.txt')
vim.fn.writefile({ '{}' }, package_root .. '/package.json')
vim.fn.writefile({ '[]' }, file_root .. '/compile_commands.json')
for _, directory in ipairs({ cmake, package_root, file_root }) do
  vim.fn.writefile({ 'int value;' }, directory .. '/src/main.cpp')
  H.eq(directory, Project.root_file(directory .. '/src/main.cpp'),
    'The nearest CMake/package/file marker wins over outer Git and earlier markers')
end
H.eq(cmake, Project.root_file(cmake .. '/src/not-yet-saved.cpp'),
  'An unsaved named source discovers the existing containing project')
local named, unnamed = vim.api.nvim_create_buf(true, false), vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(named, package_root .. '/src/main.cpp')
H.eq(package_root, Project.root({ buf = named, project_root = enclosing }),
  'A named source discovers its closest marker rather than overriding context fallback')
H.eq(package_root, Project.root({ buf = unnamed, project_root = package_root .. '/src' }),
  'An unnamed source starts discovery from its explicit existing project context')
local root_test_cwd = vim.fn.getcwd()
vim.cmd('cd ' .. vim.fn.fnameescape(enclosing))
H.eq(cmake, Project.root_file('cmake/src/main.cpp'), 'Relative named source paths discover an absolute nearest project')
vim.cmd('cd ' .. vim.fn.fnameescape(cmake .. '/src'))
H.eq(cmake, Project.root({ buf = unnamed }), 'An unnamed source without a project context starts at cwd')
vim.cmd('cd ' .. vim.fn.fnameescape(root_test_cwd))
vim.api.nvim_buf_delete(named, { force = true }); vim.api.nvim_buf_delete(unnamed, { force = true })
local worktree = roots .. '/worktree'
vim.fn.mkdir(worktree .. '/child/src', 'p')
vim.fn.writefile({ 'gitdir: ../owned-unused-git-directory' }, worktree .. '/.git')
vim.fn.writefile({ '{}' }, worktree .. '/child/package.json')
H.eq(worktree, Project.root_file(worktree .. '/source.cpp'), 'A regular Git marker file remains a root marker')
H.eq(worktree .. '/child', Project.root_file(worktree .. '/child/src/source.cpp'),
  'A closer project also wins over a regular outer Git marker file')
-- A host reporting no marker must preserve the established fallback text.
-- Do not require a filesystem location outside the isolated test directory.
local find = vim.fs.find
vim.fs.find = function() return {} end
local fallback_ok, fallbacks = pcall(function()
  return { Project.root_file('unmarked/source.cpp', 'ignored-fallback'),
    Project.root_file('', 'relative-root'), Project.root_file('') }
end)
vim.fs.find = find
H.ok(fallback_ok, fallbacks)
H.eq({ 'unmarked', 'relative-root', vim.fn.getcwd() }, fallbacks,
  'No marker retains the named-source directory, explicit context or cwd fallback')
local folder = H.tempdir('project-lifecycle')
local root, other = folder .. '/project 한글 space', folder .. '/unrelated project'
local build = root .. '/build output'
vim.fn.mkdir(build, 'p'); vim.fn.mkdir(other, 'p')
vim.fn.writefile({ '{}' }, root .. '/package.json')
vim.fn.writefile({ '{}' }, other .. '/package.json')
local first, second, unrelated = root .. '/a source.cpp', root .. '/b header.hpp', other .. '/other.hpp'
vim.fn.writefile({ 'first saved' }, first)
vim.fn.writefile({ 'second saved' }, second)
vim.fn.writefile({ 'unrelated saved' }, unrelated)
local first_buf = vim.fn.bufadd(first); vim.fn.bufload(first_buf)
local second_buf = vim.fn.bufadd(second); vim.fn.bufload(second_buf)
local unrelated_buf = vim.fn.bufadd(unrelated); vim.fn.bufload(unrelated_buf)
vim.api.nvim_set_current_buf(first_buf)
vim.o.columns, vim.o.lines = 130, 44
local original_cwd, dirchanges = vim.fn.getcwd(), 0
local cwd_event = vim.api.nvim_create_autocmd('DirChanged', { callback = function() dirchanges = dirchanges + 1 end })
vim.fn.writefile({
  "vim.fn.writefile({ vim.json.encode({ source = arg[2], cwd = vim.fn.getcwd() }) }, 'launches.jsonl', 'a')",
  "if arg[1] == 'wait' then",
  "  vim.fn.writefile({ 'ready' }, 'waiting.started')",
  "  vim.wait(10000)",
  "else",
  "  io.stdout:write(arg[2] .. ':1:1:E:deliberate fixture diagnostic\\n'); io.stdout:flush()",
  "  vim.cmd('cquit 7')",
  "end",
}, root .. '/process.lua')
-- Neovim has its own SIGTERM handling. A POSIX shell's explicit trap gives this
-- fixture one owned direct process which really ignores graceful termination.
-- Every command below is a shell builtin; no descendant process is created.
vim.fn.writefile({ "trap '' TERM", "printf '%s\\n' '{}' >> launches.jsonl",
  "printf '%s\\n' ready > waiting.started", 'while :; do :; done' }, root .. '/ignore-term.sh')
local data = Profile.empty()
for _, name in ipairs({ 'compile', 'wait' }) do
  data.tools[name] = { command = 'nvim', cwd = { base = 'project', path = 'build output' }, errorformat = '%f:%l:%c:%t:%m',
    args = { '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-l', '{root}/process.lua',
      name == 'wait' and 'wait' or 'fail', '{file}' } }
end
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = data }, window = { icons = false },
  providers = { builtin = false, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false },
  tool_overrides = { compile = { command = vim.v.progpath }, wait = { cancel_grace_ms = 100,
    command = vim.fn.has('win32') == 1 and vim.v.progpath or '/bin/sh',
    args = vim.fn.has('win32') == 0 and { '{root}/ignore-term.sh' } or nil } } })

local function same(a, b) return vim.uv.fs_realpath(a) == vim.uv.fs_realpath(b) end
local function launches() return vim.fn.readfile(build .. '/launches.jsonl') end
local function keys(value) for _, token in ipairs(K.tokens(value)) do session:handle(token) end end
local function wait(task, expected)
  H.ok(vim.wait(8000, function() return task.status ~= 'pending' end, 10), 'owned Project process exits within the bounded fixture timeout')
  H.eq(expected, task.status)
end
local accepted, _, original = CE.execute('tool.compile', {}, { interactive = false })
H.ok(accepted, 'actual declared compiler process starts')
H.ok(original, 'actual compiler has an owned retained operation')
wait(original, 'failed')
H.eq(7, original.detail.exit_code)
H.eq(1, #original.detail.locations, 'actual tool output parses into a task-owned location')
H.ok(same(first, original.detail.locations[1].filename), 'Unicode/space source survives argv and errorformat')
H.ok(same(root, original.process_target.root))
H.ok(same(build, original.process_target.cwd))
H.eq(1, #launches())

-- Rerun from another project/window context retains the original saved target.
CE.close(); vim.api.nvim_set_current_buf(unrelated_buf)
vim.cmd('cd ' .. vim.fn.fnameescape(other))
local changed = dirchanges
local complete, replay, replay_count = false, nil, 0
H.ok(CE.rerun(original.id, { save = 'saved', interactive = false, done = function(ok, _, task)
  complete, replay, replay_count = true, task, replay_count + 1
  H.eq(false, ok, 'real replay reports its actual compiler failure')
end }), 'saved-target replay accepts a different current header')
H.ok(vim.wait(8000, function() return complete end, 10))
H.ok(replay and replay ~= original, 'replay produces a distinct retained operation')
H.eq(original.process_target, replay.process_target, 'rerun retains the reviewed source/root/cwd/argv')
H.eq(unrelated_buf, replay.ctx.buf, 'editor context and saved process target remain distinct')
H.eq(1, replay_count)
H.eq(2, #launches(), 'explicit replay launches exactly one real process')
local launched = vim.json.decode(launches()[2])
H.ok(same(first, launched.source), 'actual replay process receives the original source')
H.ok(same(build, launched.cwd), 'actual replay process runs in the original cwd')
H.ok(same(other, vim.fn.getcwd()), 'replay leaves the current editor directory intact')
H.eq(changed, dirchanges, 'backend/parser never emit a directory change')

-- The selected save set is reviewed through real Session input. A native write
-- hook rejects the second file after the first was successfully saved.
CE.close(); vim.api.nvim_set_current_buf(first_buf)
vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { 'first explicitly changed' })
vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { 'second explicitly changed' })
vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { 'unrelated unsaved change' })
local save_calls, operations_before, callbacks, reason = {}, #CE.operations(), 0, nil
local write_hook = vim.api.nvim_create_autocmd('BufWritePre', { callback = function(event)
  save_calls[#save_calls + 1] = event.buf
  if event.buf == second_buf then error('deliberate second selected write failure') end
end })
H.ok(CE.rerun(original.id, { interactive = false, done = function(ok, message)
  callbacks, reason = callbacks + 1, message
  H.eq(false, ok, 'selected-save failure rejects replay')
end }), 'dirty project opens the reviewed save choice')
H.eq('input', session.active.mode)
H.eq('selected', session.active.input.choices[1].value.id, 'save choice is an explicit reviewed action')
H.eq(operations_before, #CE.operations(), 'opening review does not create a task')
keys('<CR>')
H.eq('input', session.active.mode)
H.eq('multiselect', session.active.input.command.arguments[1].kind)
H.eq(2, #session.active.input.choices, 'another project is excluded from selected saves')
H.eq({}, session.active.input.checked, 'no file is implicitly selected')
keys('<Space><Down><Space><CR>')
vim.api.nvim_del_autocmd(write_hook)
H.eq(1, callbacks, 'write failure reports completion once')
H.ok(reason:find('deliberate second selected write failure', 1, true), 'native write failure remains visible')
H.ok(reason:find('already saved: ' .. first, 1, true), 'partial save identifies the file already written')
H.eq({ first_buf, second_buf }, save_calls, 'only the reviewed selected files reach native write hooks')
H.eq({ 'first explicitly changed' }, vim.fn.readfile(first), 'the first successful write remains saved')
H.eq({ 'second saved' }, vim.fn.readfile(second), 'the rejected second file stays untouched on disk')
H.eq(false, vim.bo[first_buf].modified)
H.eq(true, vim.bo[second_buf].modified)
H.eq(true, vim.bo[unrelated_buf].modified)
H.eq({ 'unrelated saved' }, vim.fn.readfile(unrelated), 'an unrelated project is never saved')
H.eq(operations_before, #CE.operations(), 'partial save failure starts no operation')
H.eq(2, #launches(), 'partial save failure launches no process')
H.eq('workspace', session.active.mode, 'write rejection returns to the owned Tasks workspace')

-- Saved replay still rejects stale command revisions and renamed source buffers.
CE.close()
vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { 'second saved' }); vim.bo[second_buf].modified = false
vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { 'unrelated saved' }); vim.bo[unrelated_buf].modified = false
local retained_target = vim.deepcopy(original.process_target)
H.ok(CE.update_profile(function(profile) profile.tools.compile.errorformat = '%f:%l:%m' end))
accepted, reason = CE.rerun(original.id, { save = 'saved', interactive = false })
H.eq(false, accepted)
H.ok(reason:find('Tool configuration changed', 1, true), 'changed process declaration rejects retained target replay')
H.eq(operations_before, #CE.operations()); H.eq(2, #launches())
H.ok(CE.update_profile(function(profile) profile.tools.compile.errorformat = data.tools.compile.errorformat end))
vim.api.nvim_buf_set_name(first_buf, root .. '/renamed.cpp')
accepted, reason = CE.rerun(original.id, { save = 'saved', interactive = false })
H.eq(false, accepted)
H.ok(reason:find('buffer was renamed', 1, true), 'renamed original buffer cannot impersonate the saved target')
vim.api.nvim_buf_set_name(first_buf, first)
H.eq(retained_target, original.process_target, 'guard rejection never mutates the original captured target')
H.eq(operations_before, #CE.operations()); H.eq(2, #launches())

-- Real direct-process cancellation respects its grace period. Unix can keep
-- SIGTERM cooperative and verify force; Windows confirms its actual direct
-- process exit because TerminateProcess cannot be ignored by the child.
CE.close(); vim.api.nvim_set_current_buf(first_buf)
local system, owned_process, child_exited = vim.system, nil, false
local checked, check_error = xpcall(function()
vim.system = function(argv, options, done)
  owned_process = system(argv, options, function(result) child_exited = true; done(result) end)
  return owned_process
end
accepted, _, replay = CE.execute('tool.wait', {}, { interactive = false })
vim.system = system
H.ok(accepted)
H.ok(vim.wait(8000, function() return vim.fn.filereadable(build .. '/waiting.started') == 1 end, 10), 'actual child is running before cancellation')
H.ok(CE.cancel(replay.id))
H.eq('pending', replay.status, 'cancel request never confirms exit before the backend callback')
accepted, reason = CE.force_cancel(replay.id)
H.eq(false, accepted, 'force cannot bypass the direct-process grace period')
H.ok(reason:find('grace period', 1, true))
if vim.fn.has('win32') == 0 then
  H.ok(vim.wait(3000, function() return replay.cancel_state == 'unconfirmed' end, 10), 'cooperative Unix child outlives its grace period')
  H.eq('pending', replay.status, 'unconfirmed graceful exit remains pending')
  H.ok(CE.force_cancel(replay.id), 'explicit force stops only the owned direct child')
  H.eq('pending', replay.status, 'force request also waits for backend exit')
  wait(replay, 'cancelled')
  H.eq(true, replay.detail.forced)
else
  wait(replay, 'cancelled')
  H.eq(false, replay.detail.forced, 'Windows direct-process exit needs no synthetic force')
end
H.eq(true, replay.detail.termination_confirmed)
H.eq('direct', replay.detail.process_scope, 'backend never claims descendant process termination')
H.eq('confirmed', replay.cancel_state)
H.eq(3, #launches())
end, debug.traceback)
vim.system = system
-- An assertion failure must not leave the deliberately noncooperative fixture
-- running. This handle belongs to this exact launch; cleanup never uses a PID.
if not checked and owned_process and not child_exited then
  pcall(owned_process.kill, owned_process, 9)
  if not vim.wait(2000, function() return child_exited end, 10) then
    check_error = tostring(check_error) .. '\nOwned fixture process cleanup did not confirm termination'
  end
end
if not checked then error(check_error, 0) end

CE.close(); CE.disable(); Session.new = create
vim.api.nvim_del_autocmd(cwd_event)
vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
H.eq(1, #vim.api.nvim_list_wins(), 'Project review/task UI resources are cleaned up')
io.stdout:write('Project lifecycle checks: ' .. H.checks .. '\n')
