-- Shared declarations and argv run in plain Lua; no editor or process authority.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local W = require('command_environment.core.workflow')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label) check(J.encode(expected) == J.encode(actual), label) end
local function refused(callback, label, fragment)
  local value, reason = callback()
  check(value == nil and type(reason) == 'string' and reason ~= '' and (not fragment or reason:find(fragment, 1, true)), label)
end
check(vim == nil and W.contract_version == 1, 'The same declaration model has no editor dependency')
local projects = { app = { name = '응용 😀', root = { base = 'project', path = 'app\\src' }, source = 'source\\main.cpp',
  configurations = { 'Debug', 'Release' }, targets = { 'A', 'B' }, default_configuration = 'Debug', default_target = 'A' } }
local recipes = { build = { project = 'app', steps = {
  { id = 'configure', tool = 'cmake', args = { '-S', '.', '-B', 'build/{configuration}' } },
  { id = 'build', tool = 'cmake', args = { '--build', 'build/{configuration}', '--target', '{target}', '' }, cwd = { base = 'project', path = '.' } },
} }, missing = { project = 'later', steps = { { id = 'run', tool = 'later' } } } }
local p, r = W.validate(projects, recipes)
check(p and r and U.kind(p) == 'object' and U.kind(r) == 'object', 'Declarations produce explicit portable maps')
check(p.app.root.path == 'app/src' and p.app.source == 'source/main.cpp' and projects.app.root.path == 'app\\src',
  'Logical separators normalize without mutating shared profile input')
check(r.missing.project == 'later' and r.missing.steps[1].tool == 'later', 'Unresolved references remain discoverable')
check(U.kind(p.app.configurations) == 'array' and U.kind(r.build.steps) == 'array' and U.kind(r.build.steps[2].args) == 'array',
  'Ordered choices, steps and argv preserve array identity')
local round = J.decode(J.encode({ projects = p, recipes = r }))
local p2, r2 = W.validate(round.projects, round.recipes)
equal(p, p2, 'Project declarations roundtrip without host-dependent normalization')
equal(r, r2, 'Recipe declarations roundtrip without host-dependent normalization')
local empty_p, empty_r = W.validate(nil, nil)
check(J.encode(empty_p) == '{}' and J.encode(empty_r) == '{}', 'Empty declarations remain objects')
local default_p = assert(W.validate({ simple = {} }, {}))
equal({ configuration = 'default', target = 'default' }, W.choices(default_p.simple), 'Default declarations retain existing choices')
equal({ configuration = 'Debug', target = 'A' }, W.choices(p.app), 'First execution resolves declared defaults')
equal({ configuration = 'Release', target = 'B' }, W.choices(p.app, { configuration = 'Release', target = 'B' }),
  'Current selection resolves independently of remembered receipts')
local retained = assert(W.choices(p.app, { configuration = 'Debug', target = 'A' }))
local current = assert(W.choices(p.app, { configuration = 'Release', target = 'B' }))
equal({ configuration = 'Debug', target = 'A' }, retained, 'Changing choices cannot mutate a retained original selection')
check(current.configuration == 'Release', 'Retained original choices do not overwrite the current selection')
local values = { file = '/local root/한글.cpp', root = '/local root', configuration = retained.configuration, target = retained.target }
equal({ 'cmake', '--build', 'build/Debug', '--target', 'A', '' },
  W.argv({ command = 'cmake', args = r.build.steps[2].args }, values), 'Direct argv preserves ordering and empty explicit step arguments')
equal({ 'C:/local/tool.exe', '/local root/한글.cpp', '-DROOT=/local root', '%Debug A', '{literal-hyphen}' },
  W.argv({ command = 'C:/local/tool.exe', args = { '{file}', '-DROOT={root}', '%{configuration} {target}', '{literal-hyphen}' } }, values),
  'Runtime substitution is scalar data and preserves spaces, percent, Unicode and local override executable')
check(values.configuration == 'Debug' and r.build.steps[2].args[2] == 'build/{configuration}', 'Resolving argv does not mutate retained context or declaration')
refused(function() return W.argv({ command = 'cmake', args = { '{file}' } }, { file = '', root = '.', configuration = 'Debug', target = 'A' }) end,
  'Missing declared source has an actionable refusal', 'Declare a project source')
refused(function() return W.argv({ command = 'cmake', args = { '{unknown}' } }, values) end,
  'Unknown placeholder is refused rather than executed or silently substituted', 'Unknown recipe argv placeholder')
refused(function() return W.argv({ command = 'cmake', shell = true }, values) end, 'Scalar argv proposal cannot carry shell authority')
refused(function() return W.choices(p.app, { configuration = 'Other' }) end, 'Undeclared configuration cannot be resolved', 'Configuration is not declared')
refused(function() return W.choices(p.app, { target = 'Other' }) end, 'Undeclared target cannot be resolved', 'Target is not declared')
refused(function() return W.choices(p.app, { process_id = 4 }) end, 'Selection cannot carry process ownership')
local tools = assert(W.validate_tools({ cmake = { command = 'cmake', args = { '--build', 'build/{configuration}', '-include', '-include' },
  cwd = { base = 'project', path = 'build\\..' }, description = 'Configure/build', errorformat = '%f:%l:%c: %m' }, plain = { command = 'ninja' } }))
check(tools.cmake.cwd.path == 'build/..' and tools.cmake.args[3] == tools.cmake.args[4], 'Existing tool directory and repeated argv semantics are preserved')
check(tools.plain.args == nil, 'An omitted tool argv does not gain a persisted default field')
equal(tools, W.validate_tools(J.decode(J.encode(tools))), 'Tool declarations have the same wire model on every host')
local flags = assert(W.validate_tools({ disabled = { command = 'ninja', args = false, cwd = false, description = false, errorformat = false } }))
check(flags.disabled.args == false and flags.disabled.cwd == false and flags.disabled.description == false,
  'Historical false optional profile fields survive validation without acquiring meaning')
for _, machine in ipairs({ '/usr/bin/cmake', 'C:\\Tools\\cmake.exe', '\\\\server\\share\\tool.exe', '~/bin/cmake', 'dir/cmake' }) do
  refused(function() return W.validate_tools({ bad = { command = machine } }) end, 'Portable tool executable cannot embed a machine location')
end
for _, machine in ipairs({ '/tmp/out', 'C:\\out', '-I/usr/include', '-LC:\\lib', '--prefix=/tmp/out' }) do
  refused(function() return W.validate_tools({ bad = { command = 'cmake', args = { machine } } }) end, 'Portable tool argv cannot embed supported absolute-path forms')
end
refused(function() return W.validate_tools({ bad = { command = 'cmake', args = { '' } } }) end, 'Existing portable tool empty argument rule remains distinct from recipe steps')
refused(function() return W.validate_tools({ bad = { command = 'cmake', cwd = { base = 'project', path = '/tmp' } } }) end,
  'Standalone tool validation enforces the parent profile relative path rule')
for _, mutate in ipairs({
  function(a) a.app.root.path = '../outside' end,
  function(a) a.app.source = 'dir/../../outside' end,
  function(a) a.app.root.path = 'C:/machine' end,
  function(a) a.app.configurations = { 'Debug', 'Debug' } end,
  function(a) a.app.targets = U.object() end,
  function(a) a.app.default_target = 'missing' end,
  function(a) a.app.execute = function() end end,
}) do
  local malformed = U.clone(projects); mutate(malformed)
  refused(function() return W.validate(malformed, recipes) end, 'Invalid declarations fail without mutating the source')
end
for _, mutate in ipairs({
  function(a) a.build.steps[2].id = 'configure' end,
  function(a) a.build.steps[1].cwd = { base = 'project', path = '../outside' } end,
  function(a) a.build.steps[1].args = { '--root=C:/machine' } end,
  function(a) a.build.steps[1].args = { [1] = 'first', [3] = 'third' } end,
  function(a) a.build.steps = {} end,
}) do
  local malformed = U.clone(recipes); mutate(malformed)
  refused(function() return W.validate(projects, malformed) end, 'Malformed ordered recipe cannot reach host execution')
end
refused(function() return W.validate({}, { x = { project = 'later', steps = { { id = 'run', tool = 'later' } } },
  ['x.step.run'] = { project = 'later', steps = { { id = 'run', tool = 'later' } } } }) end,
  'Stable recipe/step command identity collisions are rejected', 'command IDs collide')
local many = {}; for i = 1, 65 do many['p' .. i] = {} end
refused(function() return W.validate(many, {}) end, 'Project declaration bound remains 64')
local too_many_steps = {}; for i = 1, 17 do too_many_steps[i] = { id = 's' .. i, tool = 'later' } end
refused(function() return W.validate({}, { many = { project = 'later', steps = too_many_steps } }) end, 'Recipe step bound remains 16')
local cycle = {}; cycle.loop = cycle
refused(function() return W.validate(cycle, {}) end, 'Cycles are refused before normalization')
refused(function() return W.validate(setmetatable({}, { __index = projects }), {}) end, 'Foreign objects cannot smuggle live host state')
refused(function() return W.validate(U.array(), {}) end, 'An explicit JSON array cannot masquerade as a declaration map')
refused(function() return W.validate_tools({ null = U.null }) end, 'Null cannot masquerade as a tool declaration')
refused(function() return W.validate_tools({ bad = { command = '\255' } }) end, 'Standalone declarations reject invalid UTF-8')
refused(function() return W.argv({ command = 'tool', args = { '{root}{root}{root}' } },
  { file = '', root = string.rep('x', 400000), configuration = 'Debug', target = 'A' }) end,
  'Repeated substitutions stop at the output bound before assembling an oversized argv', 'Workflow exceeds 1 MiB')
local limit = W.limits(); limit.projects = 1
check(W.limits().projects == 64 and W.limits().bytes == 1048576, 'Limit discovery is detached from validation')
local Bridge = require('command_environment.core.bridge')
ce_bridge_init('workflow-contract')
local function wire(data)
  return J.decode(ce_bridge('workflow_argv', J.encode(data)))
end
local baseline = J.decode(ce_bridge('snapshot', '{}')).value
local wire_request = { tool = { command = 'C:/local/tool.exe', args = { '{file}', '{configuration}', '{target}', '' } }, values = values }
local wire_result = wire(wire_request)
check(Bridge.protocol_version == 1 and baseline.protocol_version == 1, 'Additive scalar resolution retains Protocol 1')
check(wire_result.ok and U.kind(wire_result.value) == 'array', 'Bridge preserves ordered direct argv array identity')
equal({ 'C:/local/tool.exe', '/local root/한글.cpp', 'Debug', 'A', '' }, wire_result.value,
  'Transport follows exactly the shared placeholder semantics for host-local supplied scalar values')
equal(W.argv(wire_request.tool, values), wire_result.value, 'Transport and in-process resolution return the same scalar argv')
equal(baseline, J.decode(ce_bridge('snapshot', '{}')).value, 'Resolving an argv does not claim a command, create a task or change navigation')
for _, malformed in ipairs({
  U.array(), U.null,
  { tool = wire_request.tool, values = values, cwd = '/authority' },
  { tool = { command = 'tool', args = { '{file}' }, shell = true }, values = values },
  { tool = { command = 'tool', args = U.object() }, values = values },
  { tool = U.array(), values = values },
  { tool = U.null, values = values },
  { tool = { command = 'tool' }, values = U.null },
  { tool = { command = 'tool' }, values = { file = '', root = '.', configuration = 'Debug', target = 'A', process_id = 3 } },
  { tool = { command = 'tool', args = { '{unknown}' } }, values = values },
  { tool = { command = 'tool', args = { '{file}' } }, values = { file = '', root = '.', configuration = 'Debug', target = 'A' } },
}) do
  local rejected = wire(malformed)
  check(not rejected.ok and type(rejected.error) == 'string' and rejected.error ~= '', 'Malformed wire requests receive finite data-only refusal')
end
local near_limit = wire({ tool = { command = 'x', args = { '{root}{root}' } },
  values = { file = '', root = string.rep('x', 524280), configuration = 'Debug', target = 'A' } })
check(not near_limit.ok and near_limit.error:find('transport response limit', 1, true),
  'A valid scalar output near 1 MiB is refused before response envelope framing can overflow')
local after_refusal = wire(wire_request)
check(after_refusal.ok, 'Semantic and transport-bound refusals leave the shared bridge live')
equal(baseline, J.decode(ce_bridge('snapshot', '{}')).value, 'No malformed proposal grants execution rights or mutates the operation engine')
ce_bridge('dispose', '{}')
local retired = wire(wire_request)
check(not retired.ok, 'Retired core generations cannot resolve new workflow proposals')
io.write('workflow_contract: ' .. checks .. ' checks passed\n')
