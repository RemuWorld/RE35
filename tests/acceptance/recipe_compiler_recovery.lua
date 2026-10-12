-- Opt-in integration acceptance with an installed CMake/Ninja/GNU C++ toolchain.
-- This is controlled compiler evidence, not human usability or timing evidence.
-- No tool is installed; missing prerequisites fail explicitly because run.py has
-- no skipped-fixture state. Override discovery with RE35_TEST_CMAKE/CXX/NINJA.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local function observation_destination(value)
  if not value or value == '' then return nil end
  assert(type(value) == 'string' and #value <= 4096 and not value:find('\0', 1, true)
    and value:lower():match('%.json$'), 'Observation destination must be a bounded JSON path')
  local windows = vim.fn.has('win32') == 1
  assert(windows and (value:match('^%a:[/\\]') or value:match('^[/\\][/\\]'))
    or not windows and value:sub(1, 1) == '/', 'Observation destination must be absolute')
  local function canonical(path)
    local real = assert(vim.uv.fs_realpath(path), 'Observation destination parent must already exist')
    local normalized = vim.fs.normalize(real)
    return windows and normalized:lower() or normalized
  end
  local repo = canonical(H.repo_root())
  local artifacts = canonical(H.repo_root() .. '/.artifacts')
  assert(artifacts == repo .. '/.artifacts', 'Artifact directory must resolve inside the repository')
  local normalized = vim.fs.normalize(value)
  local parent = canonical(vim.fs.dirname(normalized))
  assert(parent == artifacts or parent:sub(1, #artifacts + 1) == artifacts .. '/',
    'Observation destination must resolve inside this repository\'s .artifacts directory')
  assert(not vim.uv.fs_lstat(normalized), 'Observation destination already exists; refusing to overwrite it')
  return normalized
end
local observation_path = observation_destination(vim.env.RE35_COMPILER_OBSERVATION)
local function executable(variable, fallback)
  local value = vim.env[variable]
  if not value or value == '' then value = vim.fn.exepath(fallback) end
  assert(value and value ~= '' and vim.fn.executable(value) == 1,
    'RE35_TEST_PREREQUISITE_MISSING: install ' .. fallback .. ' or set ' .. variable
      .. '; compiler acceptance was not run')
  return vim.fs.normalize(value)
end
local cmake = executable('RE35_TEST_CMAKE', 'cmake')
local cxx = executable('RE35_TEST_CXX', 'g++')
local ninja = executable('RE35_TEST_NINJA', 'ninja')
local compiler_version = vim.system({ cxx, '--version' }, { text = true }):wait(10000)
H.eq(0, compiler_version.code, 'installed C++ compiler identifies itself')
H.ok((compiler_version.stdout or ''):lower():find('g++', 1, true),
  'this acceptance fixture explicitly requires GNU C++ diagnostics')
local cmake_version = vim.system({ cmake, '--version' }, { text = true }):wait(10000)
local ninja_version = vim.system({ ninja, '--version' }, { text = true }):wait(10000)
H.eq(0, cmake_version.code); H.eq(0, ninja_version.code)

local folder = H.tempdir('recipe-compiler-recovery')
local root, unrelated_root = folder .. '/cpp project', folder .. '/other project'
vim.fn.mkdir(root, 'p'); vim.fn.mkdir(unrelated_root, 'p')
local source, unrelated = root .. '/a.cpp', unrelated_root .. '/other.cpp'
local broken = { '#include <cstdio>', '#include "build_config.hpp"', '',
  '#error RE35_INTENTIONAL_BUILD_FAILURE',
  'int main() { std::printf("%s/A\\n", RE35_BUILD_NAME); return 0; }' }
vim.fn.writefile(broken, source)
vim.fn.writefile({ '#include <cstdio>', '#include "build_config.hpp"',
  'int main() { std::printf("%s/B\\n", RE35_BUILD_NAME); return 0; }' }, root .. '/b.cpp')
vim.fn.writefile({ '#define RE35_BUILD_NAME "@CMAKE_BUILD_TYPE@"' }, root .. '/build_config.hpp.in')
vim.fn.writefile({
  'cmake_minimum_required(VERSION 3.20)', 'project(RE35CompilerAcceptance LANGUAGES CXX)',
  'configure_file(build_config.hpp.in build_config.hpp @ONLY)',
  'add_executable(targetA a.cpp)', 'add_executable(targetB b.cpp)',
  'target_include_directories(targetA PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")',
  'target_include_directories(targetB PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")',
}, root .. '/CMakeLists.txt')
vim.fn.writefile({
  'file(READ "${BUILD_ROOT}/CMakeCache.txt" CACHE_TEXT)',
  'if(NOT CACHE_TEXT MATCHES "CMAKE_BUILD_TYPE:STRING=${EXPECTED_CONFIGURATION}([\\r\\n]|$)")',
  '  message(FATAL_ERROR "Unexpected configured build type")', 'endif()',
  'set(PROGRAM "${BUILD_ROOT}/${EXPECTED_TARGET}")',
  'if(WIN32)', '  string(APPEND PROGRAM ".exe")', 'endif()',
  'execute_process(COMMAND "${PROGRAM}" RESULT_VARIABLE CODE OUTPUT_VARIABLE OUTPUT)',
  'if(NOT CODE EQUAL 0)', '  message(FATAL_ERROR "Compiled program failed: ${CODE}")', 'endif()',
  'if(NOT OUTPUT STREQUAL "${EXPECTED_CONFIGURATION}/A\\n")',
  '  message(FATAL_ERROR "Compiled program has wrong configuration/target: ${OUTPUT}")', 'endif()',
  'file(WRITE "${PROJECT_ROOT}/verified.txt" "${OUTPUT}")',
}, root .. '/verify.cmake')
vim.fn.writefile({ '{}' }, unrelated_root .. '/package.json')
vim.fn.writefile({ 'int unrelated() { return 0; }' }, unrelated)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf, original_cwd = vim.api.nvim_get_current_buf(), vim.fn.getcwd()
vim.o.columns, vim.o.lines = 130, 44

local errorformat = '%f:%l:%c: %m,%-G%.%#'
local configure_args = { '-S', '{root}', '-B', '{root}/build-{configuration}', '-G', 'Ninja',
  '-DCMAKE_BUILD_TYPE={configuration}' }
local data = Profile.empty()
data.projects, data.recipes = {}, {}
data.tools.configure = { command = 'cmake', args = configure_args }
data.tools.build = { command = 'cmake', args = { '--build', '{root}/build-{configuration}',
  '--target', '{target}', '--config', '{configuration}', '--parallel', '1' }, errorformat = errorformat }
data.tools.verify = { command = 'cmake', args = { '-DPROJECT_ROOT={root}',
  '-DBUILD_ROOT={root}/build-{configuration}', '-DEXPECTED_CONFIGURATION={configuration}',
  '-DEXPECTED_TARGET={target}', '-P', '{root}/verify.cmake' } }
data.projects.cpp = { name = 'Compiler acceptance', root = { base = 'project', path = '.' }, source = 'a.cpp',
  configurations = { 'Debug', 'Release' }, targets = { 'targetA', 'targetB' },
  default_configuration = 'Debug', default_target = 'targetA' }
data.recipes.build_verify = { name = 'Build then verify compiled program', project = 'cpp', steps = {
  { id = 'configure', tool = 'configure' }, { id = 'build', tool = 'build' }, { id = 'verify', tool = 'verify' },
} }
local actual_configure_args = vim.list_extend(vim.deepcopy(configure_args),
  { '-DCMAKE_CXX_COMPILER=' .. cxx, '-DCMAKE_MAKE_PROGRAM=' .. ninja })
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = data }, window = { icons = false },
  providers = { builtin = false, lsp = false, plugins = false, runner = false, ex = false, native = false, keymaps = false },
  project_overrides = { cpp = { root = root } }, tool_overrides = {
    configure = { command = cmake, args = actual_configure_args, timeout_ms = 30000 },
    build = { command = cmake, timeout_ms = 30000 }, verify = { command = cmake, timeout_ms = 10000 },
  } })
local function same(first, second)
  local a, b = vim.fs.normalize(first), vim.fs.normalize(second)
  if vim.fn.has('win32') == 1 then a, b = a:lower(), b:lower() end
  return a == b
end
local function operation(id)
  for _, task in ipairs(CE.operations()) do if task.id == id then return task end end
  error('Retained task is missing: ' .. tostring(id))
end
local function run(callback, expected)
  local complete, success, detail, task, calls = false, nil, nil, nil, 0
  local began = vim.uv.hrtime()
  local accepted, why = callback(function(ok, output, parent)
    complete, success, detail, task, calls = true, ok, output, parent, calls + 1
  end)
  H.ok(accepted, 'reviewed compiler recipe is accepted: ' .. tostring(why))
  H.ok(vim.wait(65000, function() return complete end, 10), 'real compiler recipe completes within bounds')
  H.eq(expected, task and task.status, 'parent retains the actual compiler outcome')
  H.eq(expected == 'succeeded', success); H.eq(1, calls)
  H.eq(task.detail, detail)
  return task, (vim.uv.hrtime() - began) / 1000000000
end
local first_ctx = K.context()
local failed, failed_seconds = run(function(done)
  return CE.run_recipe('build_verify', { configuration = 'Debug', target = 'targetA' },
    { save = 'saved', interactive = false, context = first_ctx, done = done })
end, 'failed')
H.eq({ 'configure', 'build' }, { failed.detail.steps[1].id, failed.detail.steps[2].id })
H.eq(2, #failed.detail.steps, 'failed build starts no verification step')
H.eq(0, vim.fn.filereadable(root .. '/verified.txt'), 'failed build produces no later-step marker')
local failed_build = operation(failed.detail.steps[2].task_id)
H.ok(failed_build.detail.exit_code ~= 0, 'real compiler build exit is nonzero')
H.ok(same(root, failed_build.detail.cwd), 'actual failed child keeps the project cwd')
H.eq({ cmake, '--build', root .. '/build-Debug', '--target', 'targetA', '--config', 'Debug', '--parallel', '1' },
  failed_build.detail.argv, 'actual failed build invokes Debug targetA')
local failed_items = H.ok(require('command_tree.results').read('task', first_ctx, nil, failed.id)).items
local diagnostic
for _, item in ipairs(failed_items) do
  if same(item.filename, source) and item.line == 4 and item.text:find('RE35_INTENTIONAL_BUILD_FAILURE', 1, true) then
    diagnostic = item; break
  end
end
H.ok(diagnostic, 'real GNU compiler failure becomes a retained Results source location')
H.eq('build', diagnostic.recipe_step); H.eq(failed_build.id, diagnostic.child_task_id)

-- Cross-check the same already-configured failed build through native :make.
-- This is execution/location evidence, not a fair end-to-end timing baseline:
-- the RE35 recipe additionally configures the project and owns a parent Task.
CE.close(); vim.api.nvim_set_current_buf(source_buf)
vim.cmd('cd ' .. vim.fn.fnameescape(root))
local old_makeprg, old_errorformat = vim.bo.makeprg, vim.bo.errorformat
local shell_options = {}
for _, name in ipairs({ 'shell', 'shellcmdflag', 'shellquote', 'shellxquote', 'shellpipe', 'shellredir', 'shellslash' }) do
  shell_options[name] = vim.o[name]
end
if vim.fn.has('win32') == 1 then
  -- A inherited PowerShell executable with cmd.exe's default /s /c flags is
  -- not a usable native baseline. Pin this isolated probe to installed cmd.
  H.ok(vim.env.COMSPEC and vim.fn.executable(vim.env.COMSPEC) == 1, 'native Windows probe has an installed command shell')
  vim.o.shell, vim.o.shellcmdflag = vim.env.COMSPEC, '/d /v:off /s /c'
  vim.o.shellquote, vim.o.shellxquote = '', '"'
  vim.o.shellpipe, vim.o.shellredir = '>%s 2>&1', '>%s 2>&1'
  vim.o.shellslash = false
end
local native_shell = vim.o.shell
local native_argv = vim.deepcopy(failed_build.detail.argv)
local native_command = {}
for _, arg in ipairs(native_argv) do
  assert(vim.fn.has('win32') == 0 or not arg:find('%', 1, true),
    'Native cmd.exe comparison does not support percent-containing argv; shellescape cannot prevent environment expansion')
  native_command[#native_command + 1] = vim.fn.shellescape(arg)
end
vim.bo.makeprg, vim.bo.errorformat = table.concat(native_command, ' '), errorformat
local native_begin = vim.uv.hrtime()
vim.cmd('silent make!')
local native_seconds, native_exit = (vim.uv.hrtime() - native_begin) / 1000000000, vim.v.shell_error
local quickfix, native_diagnostic = vim.fn.getqflist(), nil
vim.bo.makeprg, vim.bo.errorformat = old_makeprg, old_errorformat
for name, value in pairs(shell_options) do vim.o[name] = value end
H.ok(native_exit ~= 0, 'native :make sees the same compiler failure')
for _, item in ipairs(quickfix) do
  local filename = item.bufnr and vim.api.nvim_buf_get_name(item.bufnr) or ''
  if filename ~= '' and same(filename, source) and item.lnum == 4
    and item.text:find('RE35_INTENTIONAL_BUILD_FAILURE', 1, true) then native_diagnostic = item; break end
end
H.ok(native_diagnostic, 'native quickfix receives the same expected failure location')
H.eq(native_diagnostic.lnum, diagnostic.line); H.eq(native_diagnostic.col, diagnostic.col)
vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))

-- Change real Project workspace choices through its pickers, not its manager.
local function frame() return session.active.stack[#session.active.stack] end
H.ok(CE.open({ interactive = false, workspace = 'project' }))
for _, field in ipairs({ 'configuration', 'target' }) do
  frame().data.selected_id = field
  session:draw(); session:handle('<CR>')
  H.eq('input', session.active.mode, 'Project choice opens the actual ' .. field .. ' picker')
  session:handle('<Down>'); session:handle('<CR>')
  H.eq('workspace', session.active.mode)
end
H.eq('Release', CE.project_context(session.active.ctx).configuration)
H.eq('targetB', CE.project_context(session.active.ctx).target)

-- Open the retained Results workspace and activate its actual selected row.
H.ok(CE.open_task_results(failed.id, { interactive = false }))
local result_frame = frame()
result_frame.data.selected_id = diagnostic.id
session:draw(); session:handle('<CR>')
H.eq(nil, session.active, 'Results activation returns to the source instead of retaining a stale UI')
H.ok(same(source, vim.api.nvim_buf_get_name(0)), 'Results loads the exact compiler source')
H.eq({ diagnostic.line, diagnostic.col - 1 }, vim.api.nvim_win_get_cursor(0), 'Results sets the actual diagnostic byte position')
H.eq(broken, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), 'jump changes no source text')
local corrected = vim.deepcopy(broken)
corrected[4] = '// Corrected after inspecting the retained compiler diagnostic.'
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, corrected)
H.eq(broken, vim.fn.readfile(source), 'editing alone leaves the saved compiler input untouched')
H.eq(true, vim.bo[source_buf].modified)
-- Leave the correction unsaved until the real Tasks retry save review.

CE.close(); vim.cmd('edit ' .. vim.fn.fnameescape(unrelated))
local unrelated_buf = vim.api.nvim_get_current_buf()
vim.cmd('cd ' .. vim.fn.fnameescape(unrelated_root))
local selection_before_retry = H.ok(CE.project_context())
H.eq('Release', selection_before_retry.configuration, 'later Release selection remains current in the same source window')
H.eq('targetB', selection_before_retry.target)
local before_retry = #CE.operations()
H.ok(CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=failed.id}}))
session:handle('r')
H.eq('input',session.active.mode,'Tasks retry opens the real dirty-file decision')
H.eq(before_retry,#CE.operations(),'save review starts no process')
H.eq(broken,vim.fn.readfile(source),'opening save review does not persist the repair')
session:handle('<Down>');session:handle('<Down>');session:handle('<CR>')
H.eq(before_retry,#CE.operations(),'Back cancels retry without starting a process')
H.eq(broken,vim.fn.readfile(source),'Back leaves the original disk input unchanged')
H.eq(true,vim.bo[source_buf].modified,'Back preserves the unsaved repair')
local rerun_begin=vim.uv.hrtime()
session:handle('r');H.eq('input',session.active.mode)
session:handle('<CR>') -- Explicitly choose selected-file saving.
H.eq('multiselect',session.active.input.command.arguments[session.active.input.index].kind)
session:handle('<Space>');session:handle('<CR>')
local succeeded
H.ok(vim.wait(65000,function()
  for _,item in ipairs(CE.operations())do
    if item.id~=failed.id and item.command_id==failed.command_id and item.status~='pending'then
      succeeded=item;return true
    end
  end
  return false
end,10),'Tasks retry finishes real build and nonempty validation')
local rerun_seconds=(vim.uv.hrtime()-rerun_begin)/1000000000
H.eq('succeeded',succeeded.status)
H.eq(corrected,vim.fn.readfile(source),'explicit selected-file save persists only the repair')
H.eq(false,vim.bo[source_buf].modified)
H.eq({'int unrelated() { return 0; }'},vim.fn.readfile(unrelated),'selected save does not modify unrelated input')
H.eq(failed.process_target, succeeded.process_target, 'retry retains the exact original plan despite current Release/B context')
H.eq('Debug', succeeded.detail.configuration); H.eq('targetA', succeeded.detail.target)
H.eq(unrelated_buf, succeeded.ctx.buf, 'current editor context remains separate from the retained compiler plan')
H.eq({ 'configure', 'build', 'verify' }, { succeeded.detail.steps[1].id, succeeded.detail.steps[2].id, succeeded.detail.steps[3].id })
H.eq(3, #succeeded.detail.steps)
local replay_build = operation(succeeded.detail.steps[2].task_id)
H.eq(failed_build.detail.argv, replay_build.detail.argv, 'actual retry argv still addresses original Debug targetA')
H.ok(same(root, replay_build.detail.cwd), 'actual retry child keeps the original cwd')
H.eq(0, replay_build.detail.exit_code)
H.eq({ 'Debug/A' }, vim.fn.readfile(root .. '/verified.txt'), 'compiled executable proves the original configuration and target')
H.eq(0, vim.fn.isdirectory(root .. '/build-Release'), 'changing current selections never configures Release')
H.eq(0, vim.fn.filereadable(root .. '/build-Debug/targetB' .. (vim.fn.has('win32') == 1 and '.exe' or '')),
  'retry never builds the later targetB selection')
H.ok(same(unrelated_root, vim.fn.getcwd()), 'recipe retry never changes the current editor cwd')
H.eq(quickfix, vim.fn.getqflist(), 'RE35 retry retains native quickfix ownership')
H.eq('failed', failed.status, 'old failure remains unchanged in Task history')
H.ok(failed.id ~= succeeded.id, 'retry owns a distinct retained Task')
local selection_after_retry = H.ok(CE.project_context(session.active and session.active.ctx or K.context()))
H.eq('Release', selection_after_retry.configuration, 'retry does not replace the current Release selection')
H.eq('targetB', selection_after_retry.target, 'retry does not replace the current targetB selection')

CE.close(); CE.disable(); Session.new = create
vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
local observation = { evidence = 'controlled-real-compiler-integration',
  compiler = (compiler_version.stdout or ''):match('[^\r\n]+'),
  cmake = (cmake_version.stdout or ''):match('[^\r\n]+'), ninja = (ninja_version.stdout or ''):match('[^\r\n]+'),
  recipe_failure_seconds = failed_seconds, native_failed_build_seconds = native_seconds,
  recipe_retry_seconds = rerun_seconds, native_exit = native_exit,
  timing_comparable = false, physical_keys_measured = false, human_usability_measured = false,
  retry_entry = 'Tasks r', save_policy = 'explicit selected files', cancelled_review_no_write_or_launch = true,
  process_scope = 'sequential-direct', descendant_cancellation_tested = false }
if observation_path then
  local local_record = vim.deepcopy(observation)
  local_record.failure = { configuration = failed.detail.configuration, target = failed.detail.target,
    argv = failed_build.detail.argv, cwd = failed_build.detail.cwd, exit_code = failed_build.detail.exit_code,
    steps = failed.detail.steps, location = { filename = diagnostic.filename, line = diagnostic.line, col = diagnostic.col } }
  local_record.native = { argv = native_argv, cwd = root, exit_code = native_exit, shell = native_shell,
    location = { filename = source, line = native_diagnostic.lnum, col = native_diagnostic.col } }
  local_record.retry = { configuration = succeeded.detail.configuration, target = succeeded.detail.target,
    argv = replay_build.detail.argv, cwd = replay_build.detail.cwd, exit_code = replay_build.detail.exit_code,
    steps = succeeded.detail.steps, compiled_output = vim.fn.readfile(root .. '/verified.txt') }
  local_record.current_selection_at_retry = { configuration = selection_before_retry.configuration,
    target = selection_before_retry.target, current_file = unrelated, current_cwd = unrelated_root }
  local_record.selection_before_retry, local_record.selection_after_retry = selection_before_retry, selection_after_retry
  observation_destination(observation_path)
  local encoded = vim.json.encode(local_record) .. '\n'
  local handle = assert(vim.uv.fs_open(observation_path, 'wx', 384),
    'Observation destination could not be exclusively created; existing files are never overwritten')
  local written, write_error = vim.uv.fs_write(handle, encoded, 0)
  local closed, close_error = vim.uv.fs_close(handle)
  H.eq(#encoded, written, 'exclusive local observation write completes: ' .. tostring(write_error))
  H.ok(closed, 'exclusive local observation closes cleanly: ' .. tostring(close_error))
end
io.stdout:write(vim.json.encode(observation) .. '\n')
io.stdout:write('Recipe compiler recovery checks: ' .. H.checks .. '\n')
