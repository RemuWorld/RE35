-- Opt-in actual checkout self-use, not a temporary pretend project or human test.
-- Never selected by tests/run.py's default test_*.lua discovery.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile, Results = require('re35'), require('command_tree.profile'), require('command_tree.results')
local root = H.repo_root()
local profile_path, source = root .. '/examples/re35-development.json', root .. '/CMakeLists.txt'
local function bytes(path)
  local file = assert(io.open(path, 'rb'))
  local value = assert(file:read('*a')); file:close(); return value
end
local protected = {}
for _, path in ipairs({ profile_path, source, root .. '/tests/run.py', root .. '/examples/command.json' }) do
  protected[path] = bytes(path)
end
local profile = H.ok(Profile.read(profile_path), 'shared JSON profile passes the real profile validator')
local before_import = bytes(profile_path)
H.ok(Profile.preview(Profile.empty(), profile, { mode = 'merge' }), 'portable profile can be reviewed without execution')
H.eq(before_import, bytes(profile_path), 'reading/import preview does not rewrite the shared profile')
H.eq(7, vim.tbl_count(profile.recipes), 'shared development profile retains four legacy recipes and adds three target recipes')
H.eq({ 'all' }, profile.projects.re35.targets, 'legacy project keeps its all-target contract')
H.eq({ 'ce_cpp', 'ce_stdio' }, profile.projects.re35_native_targets.targets, 'new project uses actual CMake target names')
local python, nvim = assert(vim.env.RE35_SELF_PYTHON), assert(vim.env.RE35_SELF_NVIM)
H.eq(1, vim.fn.executable(python)); H.eq(1, vim.fn.executable(nvim))
vim.api.nvim_cmd({ cmd = 'edit', args = { source } }, {})
local buf = vim.api.nvim_get_current_buf()
local lines, tick = vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.api.nvim_buf_get_changedtick(buf)
vim.o.columns, vim.o.lines = 130, 44
vim.fn.setqflist({ { filename = source, lnum = 1, col = 1, text = 'Native list is independent' } }, 'r')
local quickfix = vim.fn.getqflist()
-- Parser compatibility only: this does not execute or attest an MSVC compiler.
local diagnostics = require('command_tree.task_results').parse({ stdout = table.concat({
  source .. '(2,3): error C2143: parser compatibility sample',
  source .. '(3): error C2065: parser compatibility sample',
  source .. ':4:2: error: GNU parser compatibility sample',
}, '\n'), stderr = '' }, { errorformat = profile.tools.re35_build.errorformat, cwd = root })
H.eq('ready', diagnostics.locations_status, 'shared build errorformat parses GNU and MSVC location syntax')
H.eq(3, #diagnostics.locations, 'both MSVC variants and GNU produce navigable locations')
H.eq({ 2, 3 }, { diagnostics.locations[1].line, diagnostics.locations[1].col })
H.eq({ 3, 1 }, { diagnostics.locations[2].line, diagnostics.locations[2].col })
H.eq({ 4, 2 }, { diagnostics.locations[3].line, diagnostics.locations[3].col })
H.eq(quickfix, vim.fn.getqflist(), 'parser-only compatibility check does not replace native quickfix')
local nvim_args = vim.deepcopy(profile.tools.re35_neovim.args)
vim.list_extend(nvim_args, { '--nvim', nvim })
local smoke = vim.env.RE35_SELF_SMOKE == '1'
if smoke then vim.list_extend(nvim_args, { '--select', 'test_core_manifest' }) end
local overrides = {
  re35_neovim = { command = python, args = nvim_args, timeout_ms = 110000 },
  re35_validate = { command = python, timeout_ms = 65000 },
  re35_configure = { timeout_ms = 60000 }, re35_build = { timeout_ms = 60000 },
}
if vim.env.RE35_SELF_NATIVE == '1' then
  local cmake = assert(vim.env.RE35_SELF_CMAKE)
  H.eq(1, vim.fn.executable(cmake))
  overrides.re35_configure.command, overrides.re35_build.command = cmake, cmake
  overrides.re35_configure.args = vim.list_extend(vim.deepcopy(profile.tools.re35_configure.args),
    vim.json.decode(assert(vim.env.RE35_SELF_CONFIGURE_ARGS)))
  overrides.re35_validate.args = vim.list_extend(vim.deepcopy(profile.tools.re35_validate.args),
    { '--lua-runtime', assert(vim.env.RE35_LUA_RUNTIME) })
end
if vim.env.RE35_SELF_TARGETS == '1' then
  local extra = vim.json.decode(assert(vim.env.RE35_SELF_TARGET_OPTIONS))
  for _, name in ipairs({ 're35_target_configure', 're35_target_build', 're35_target_validate' }) do
    local args = vim.list_extend(vim.deepcopy(profile.tools[name].args), extra)
    if name == 're35_target_validate' then vim.list_extend(args, { '--lua-runtime', assert(vim.env.RE35_LUA_RUNTIME) }) end
    overrides[name] = { command = python, args = args, timeout_ms = 65000 }
  end
end
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = profile }, window = { icons = false }, integrations = { theme = false },
  providers = { builtin = false, lsp = false, plugins = false, runner = false, ex = false, native = false, keymaps = false },
  project_overrides = { re35 = { root = root }, re35_native_targets = { root = root } }, tool_overrides = overrides })
H.eq(0, #CE.operations(), 'profile activation registers recipes and starts no external process')
local active_profile = vim.deepcopy(CE.profile())
local function operation(id)
  for _, task in ipairs(CE.operations()) do if task.id == id then return task end end
  error('Retained checkout task is missing: ' .. tostring(id))
end
local function run(callback, selection, expected)
  selection, expected = selection or { configuration = 'Debug', target = 'all' }, expected or 'succeeded'
  local calls, success, detail, parent = 0, nil, nil, nil
  local accepted, why = callback(function(ok, output, task)
    calls, success, detail, parent = calls + 1, ok, output, task
  end)
  H.ok(accepted, 'explicit checkout recipe is accepted: ' .. tostring(why))
  H.ok(vim.wait(115000, function() return calls > 0 end, 10), 'actual checkout recipe completes within bounds')
  H.eq(1, calls, 'completion occurs once')
  H.eq(expected == 'succeeded', success, 'actual checkout recipe reaches its expected state: ' .. vim.inspect(detail))
  H.eq(expected, parent.status)
  H.eq(parent, operation(parent.id), 'actual Tasks parent remains retained')
  H.eq(parent.detail, detail)
  H.eq(root, parent.process_target.root, 'recipe operates on this actual checkout')
  H.eq(selection.configuration, parent.args.configuration); H.eq(selection.target, parent.args.target)
  local results = H.ok(Results.read('task', K.context(), nil, parent.id))
  H.eq(parent.id, results.list_id, 'Results reads the actual retained checkout parent')
  H.ok(type(results.status_message) == 'string', 'Results reports its real navigable-location status')
  H.eq(#detail.steps, #detail.child_ids, 'each completed recipe stage owns one retained child')
  for _, step in ipairs(detail.steps) do
    local child = operation(step.task_id)
    H.eq(parent.id, child.parent_id); H.eq(step.id, child.step_id)
    H.eq(expected, step.status); H.eq(expected, child.status)
    if expected == 'succeeded' then H.eq(0, child.detail.exit_code, 'actual child program exits successfully')
    else H.ok(child.detail.exit_code ~= 0, 'actual unmet native prerequisite fails its child process') end
    H.eq(root, child.detail.cwd, 'actual child cwd is this checkout')
    H.eq(false, child.detail.truncated, 'actual result output is retained without truncation')
  end
  return parent
end
local first = run(function(done)
  return CE.run_recipe('re35_neovim_tests', { configuration = 'Debug', target = 'all' },
    { save = 'saved', interactive = false, done = done })
end)
H.eq({ 'neovim' }, { first.detail.steps[1].id })
local child = operation(first.detail.steps[1].task_id)
H.eq(vim.list_extend({ python }, nvim_args), child.detail.argv, 'child retains exact declared/host-resolved Python argv')
local passed, count = child.detail.stdout:match('(%d+)/(%d+) fixtures passed; runtime source unchanged: True')
H.ok(passed and count and tonumber(count) > 0 and passed == count, 'the real test runner completed nonzero fixtures')
if smoke then H.eq('1', count, 'smoke evidence is explicitly only one fixture')
else H.ok(tonumber(count) >= 23, 'full self-use runs the repository regression suite') end

-- Change the actual Project picker and then retry the retained original plan.
H.ok(CE.open({ interactive = false, workspace = 'project' }))
local function frame() return session.active.stack[#session.active.stack] end
frame().data.selected_id = 'configuration'; session:draw(); session:handle('<CR>')
H.eq('input', session.active.mode)
session:handle('<Down>'); session:handle('<CR>')
H.eq('Release', CE.project_context(session.active.ctx).configuration)
CE.close()
local retry = run(function(done)
  return CE.rerun(first.id, { save = 'saved', interactive = false, done = done })
end)
H.eq(first.process_target, retry.process_target, 'retained retry keeps original root/Debug/all/step argv')
H.eq('Release', CE.project_context().configuration, 'retry leaves the current Release choice intact')
H.eq('succeeded', first.status, 'retry does not replace the earlier task')
local retry_child = operation(retry.detail.steps[1].task_id)
H.eq(child.detail.argv, retry_child.detail.argv)
H.ok(retry_child.detail.stdout:find(passed .. '/' .. count .. ' fixtures passed', 1, true), 'retry really reruns the same suite')
local native
local native_checks
if vim.env.RE35_SELF_NATIVE == '1' then
  native = run(function(done)
    return CE.run_recipe('re35_native_build_validate', { configuration = 'Debug', target = 'all' },
      { save = 'saved', interactive = false, done = done })
  end)
  H.eq({ 'configure', 'build', 'validate' },
    { native.detail.steps[1].id, native.detail.steps[2].id, native.detail.steps[3].id },
    'native recipe executes actual configure, build and nonempty fixture validation')
  local validation_output = operation(native.detail.steps[3].task_id).detail.stdout
  H.ok(validation_output:find('RE35_NATIVE_VALIDATION_PASS:', 1, true),
    'native recipe finishes real FIFO/C++ fixtures, not an empty CTest run')
  native_checks = { fifo = tonumber(validation_output:match('"checks":%s*(%d+)')),
    cpp = tonumber(validation_output:match('C%+%+ host: (%d+) checks PASS')) }
  H.ok(native_checks.fifo and native_checks.fifo > 0 and native_checks.cpp and native_checks.cpp > 0,
    'actual native fixture check counts remain explicit in local evidence')
end
local target_failure, target_build, target_retry, target_opposite, native_target_records
if vim.env.RE35_SELF_TARGETS == '1' then
  local normalized = function(value) return (value:gsub('\\', '/')) end
  local debug = { configuration = 'Debug', target = 'ce_cpp' }
  target_failure = run(function(done)
    return CE.run_recipe('re35_native_target_validate', debug, { save = 'saved', interactive = false, done = done })
  end, debug, 'failed')
  H.eq(1, #target_failure.detail.steps, 'missing fresh cache fails actual validation without running another target')
  H.ok(operation(target_failure.detail.steps[1].task_id).detail.stderr:find('Native build is missing;', 1, true),
    'actual missing-build failure explains the configure/build prerequisite')
  target_build = run(function(done)
    return CE.run_recipe('re35_native_target_build', debug, { save = 'saved', interactive = false, done = done })
  end, debug)
  H.eq(2, #target_build.detail.steps, 'actual selected-target configure and build finish before retained validation retry')
  -- Change actual Project fields, not the manager's in-memory selection table.
  H.ok(CE.open({ interactive = false, workspace = 'project' }))
  local function choose(field)
    frame().data.selected_id = field; session:draw(); session:handle('<CR>')
    H.eq('input', session.active.mode, 'Project opens its actual ' .. field .. ' picker')
    session:handle('<Down>'); session:handle('<CR>')
  end
  choose('project'); choose('configuration'); choose('target'); choose('recipe')
  local current = vim.deepcopy(CE.project_context(session.active.ctx))
  H.eq('re35_native_targets', current.project)
  H.eq('Release', current.configuration); H.eq('ce_stdio', current.target)
  H.eq('re35_native_target_build_validate', current.recipe)
  CE.close()
  target_retry = run(function(done)
    return CE.rerun(target_failure.id, { save = 'saved', interactive = false, done = done })
  end, debug)
  H.eq(target_failure.process_target, target_retry.process_target, 'retry retains original Debug/ce_cpp root, source and validation argv')
  H.eq(current, CE.project_context(), 'retry keeps the independent Release/ce_stdio selection unchanged')
  local failed_child = operation(target_failure.detail.steps[1].task_id)
  local retry_child = operation(target_retry.detail.steps[1].task_id)
  H.eq(failed_child.detail.argv, retry_child.detail.argv, 'prerequisite repair changes no retained validation argv or pinned runtime')
  H.eq(failed_child.detail.cwd, retry_child.detail.cwd, 'retry keeps actual original validation cwd')
  H.eq('failed', target_failure.status, 'original missing-cache failure remains in history')
  target_opposite = run(function(done)
    return CE.execute('project.run_selected_recipe', nil, { interactive = false, done = done })
  end, { configuration = 'Release', target = 'ce_stdio' })
  H.eq('re35_native_target_build_validate', target_opposite.recipe_id,
    'normal selected-recipe command runs the actual remembered Release/ce_stdio recipe')
  H.eq(current, CE.project_context(), 'opposite-target run does not rewrite remembered selection')
  local function records(task)
    local values = {}
    for _, step in ipairs(task.detail.steps) do
      local child = operation(step.task_id)
      for line in child.detail.stdout:gmatch('[^\r\n]+') do
        local value = line:match('^RE35_NATIVE_EXECUTION:(.+)$')
        if value then values[#values + 1] = vim.json.decode(value) end
      end
    end
    return values
  end
  local built, retried, opposite = records(target_build), records(target_retry), records(target_opposite)
  H.eq(2, #built); H.eq(1, #retried); H.eq(3, #opposite)
  native_target_records = { debug_build = built, debug_retry = retried, release_stdio = opposite }
  H.eq('configure', built[1].phase); H.eq('build', built[2].phase)
  H.eq({ '--target', 'ce_cpp' }, { built[2].argv[#built[2].argv - 3], built[2].argv[#built[2].argv - 2] },
    'Debug actual CMake build selects ce_cpp rather than default all')
  H.eq({ '--target', 'ce_stdio' }, { opposite[2].argv[#opposite[2].argv - 3], opposite[2].argv[#opposite[2].argv - 2] },
    'Release actual CMake build selects ce_stdio rather than default all')
  H.eq('ce_cpp', retried[1].target); H.eq('ce_stdio', opposite[3].target)
  H.eq('Debug', retried[1].configuration); H.eq('Release', opposite[3].configuration)
  H.ok(retried[1].checks > 0 and opposite[3].checks > 0, 'both selected targets complete their relevant nonempty actual fixtures')
  H.eq(normalized(root), normalized(retried[1].cwd)); H.eq(normalized(root), normalized(opposite[3].cwd))
  H.ok(retried[1].build ~= opposite[3].build, 'Debug and Release use distinct native CMake caches')
  H.eq(built[1].host, opposite[1].host, 'both caches identify this actual operating system, distribution and architecture')
  H.ok(retried[1].build:find(built[1].host, 1, true), 'build namespace includes actual host identity')
  local suffix = vim.fn.has('win32') == 1 and '.exe' or ''
  H.ok(vim.tbl_contains({ normalized(retried[1].build .. '/ce_cpp' .. suffix), normalized(retried[1].build .. '/Debug/ce_cpp' .. suffix) },
    normalized(retried[1].executable)), 'retained validation runs original Debug/ce_cpp binary')
  H.ok(vim.tbl_contains({ normalized(opposite[3].build .. '/ce_stdio' .. suffix), normalized(opposite[3].build .. '/Release/ce_stdio' .. suffix) },
    normalized(opposite[3].executable)), 'opposite route runs actual Release/ce_stdio binary')
  H.eq(0, vim.fn.filereadable(retried[1].build .. '/ce_stdio' .. suffix), 'Debug target build does not build the unrelated FIFO executable')
  H.eq(0, vim.fn.filereadable(opposite[3].build .. '/ce_cpp' .. suffix), 'Release target build does not build the unrelated C++ executable')
  H.eq(0, vim.fn.filereadable(retried[1].build .. '/Debug/ce_stdio' .. suffix), 'Debug multiconfiguration cache contains no unrelated FIFO executable')
  H.eq(0, vim.fn.filereadable(opposite[3].build .. '/Release/ce_cpp' .. suffix), 'Release multiconfiguration cache contains no unrelated C++ executable')
  H.ok(not operation(target_retry.detail.steps[1].task_id).detail.stdout:find('"passed":', 1, true), 'C++ target validation does not invoke FIFO fixture')
  H.ok(not operation(target_opposite.detail.steps[3].task_id).detail.stdout:find('C++ host:', 1, true), 'FIFO target validation does not invoke C++ fixture')
  local configure_child = operation(target_build.detail.steps[1].task_id)
  local cache_path, cache_before = retried[1].build .. '/CMakeCache.txt'
  cache_before = bytes(cache_path)
  local generator_guard = vim.list_extend(vim.deepcopy(configure_child.detail.argv), { '--generator', 'RE35-invalid-generator' })
  local rejected = vim.system(generator_guard, { cwd = root, text = true }):wait(10000)
  H.ok(rejected.code ~= 0 and rejected.stderr:find('Generator changed;', 1, true),
    'changed explicit generator is rejected before any CMake configure mutation')
  H.eq(cache_before, bytes(cache_path), 'rejected generator leaves original native cache unchanged')
  H.ok(not rejected.stdout:find('RE35_NATIVE_EXECUTION:', 1, true), 'rejected generator starts no native configure program')
  local namespace_guard = vim.list_extend(vim.deepcopy(configure_child.detail.argv), { '--native-namespace', '../escape' })
  local escaped = vim.system(namespace_guard, { cwd = root, text = true }):wait(10000)
  H.ok(escaped.code ~= 0 and escaped.stderr:find('Native namespace must contain', 1, true),
    'path-like namespace is rejected rather than creating a build outside .artifacts')
  H.eq(cache_before, bytes(cache_path), 'rejected namespace leaves original native cache unchanged')
  H.eq(current, CE.project_context(), 'driver guard probes never redirect the active Project selection')
  native_target_records.guard_probes = { generator = { argv = generator_guard, exit_code = rejected.code },
    namespace = { argv = namespace_guard, exit_code = escaped.code }, original_cache_unchanged = true }
end
CE.close()
H.eq(active_profile, CE.profile(), 'running/retrying never changes portable profile data')
H.eq(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'self-development leaves source buffer unchanged')
H.eq(tick, vim.api.nvim_buf_get_changedtick(buf)); H.eq(false, vim.bo[buf].modified)
H.eq(quickfix, vim.fn.getqflist(), 'self-development keeps the user-owned native quickfix list')
for path, value in pairs(protected) do H.eq(value, bytes(path), 'self-development never rewrites checkout source/profile: ' .. path) end
local function record(task)
  if not task then return nil end
  local steps = {}
  for _, step in ipairs(task.detail.steps) do
    local child = operation(step.task_id)
    steps[#steps + 1] = { id = step.id, task_id = child.id, status = child.status,
      argv = child.detail.argv, cwd = child.detail.cwd, exit_code = child.detail.exit_code }
  end
  return { task_id = task.id, recipe_id = task.recipe_id, status = task.status,
    root = task.process_target.root, args = task.args, steps = steps }
end
io.stdout:write('\nRE35_SELF_OBSERVATION:' .. vim.json.encode({ evidence = 'actual-checkout-recipes',
  scope = smoke and 'one-fixture driver smoke' or 'full Neovim regression twice',
  msvc_evidence = 'location parser only; no MSVC compiler execution',
  suite_fixtures = tonumber(count), source_and_profile_unchanged = true,
  current_selection_after_retry = 'Release/all', first = record(first), retry = record(retry),
  native = record(native), native_checks = native_checks,
  native_target_prerequisite_failure = record(target_failure), native_target_build = record(target_build),
  native_target_retry = record(target_retry), native_target_opposite = record(target_opposite),
  current_selection_after_native_retry = target_retry and CE.project_context() or nil,
  native_target_execution_records = native_target_records }) .. '\n')
io.stdout:write('Self-development checks: ' .. H.checks .. '\n'); io.stdout:flush()
