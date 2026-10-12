-- The same profile schema runs with no Neovim, filesystem or execution service.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  return loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
end }
vim = nil
local P = require('command_environment.core.profile')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local checks = 0
local function check(value, why) checks = checks + 1; assert(value, why) end
local function rejected(data, why)
  local value, reason = P.validate(data)
  check(value == nil and type(reason) == 'string' and reason ~= '', why)
end
local empty = assert(P.validate({ version = 1 }))
check(vim == nil and empty.version == 1, 'Shared validation needs no editor')
check(J.encode(empty.tools) == '{}' and J.encode(empty.favorites) == '[]', 'Default map and array identities')
check(J.encode(empty.workspaces.templates) == '[]' and J.encode(empty.layout.aliases) == '{}', 'Nested JSON identities')
check(P.validate({ version = 1, layout = {}, workspaces = {}, requirements = {} }) ~= nil, 'Legacy empty default overlays')
local declaration = J.decode([[{
  "version":1,
  "projects":{"source":{"root":{"base":"project","path":"."},"source":"src\\main.cpp",
    "configurations":["Debug","Release"],"targets":["ce_cpp","ce_stdio"]}},
  "recipes":{"build":{"project":"source","steps":[{"id":"compile","tool":"cmake","args":["--build","build/{configuration}","--target","{target}",""]}]},
    "missing":{"project":"absent","steps":[{"id":"wait","tool":"absent"}]}},
  "tools":{"cmake":{"command":"cmake","args":["--version","--version"],"cwd":{"base":"config","path":"../build\\Debug"}}},
  "presets":{"project.build":[{"name":"custom","args":{}}]},
  "command_links":{"project.build":{"name":"Build 😀","arguments":{"password":{"prompt":"Secret label only"}}}},
  "presentation":{"version":1,"selected":"focused","presets":{"focused":{"extends":false,"information":{"help":false}}}},
  "ui":{"density":"minimal"},"favorites":["project.build"],"slots":{"1":"project.build"}
}]])
local before = J.encode(declaration)
local prepared = assert(P.validate(declaration))
check(J.encode(declaration) == before, 'Validation leaves caller declarations unchanged')
check(prepared.projects.source.source == 'src/main.cpp', 'Logical source separators normalize')
check(prepared.tools.cmake.cwd.path == '../build/Debug', 'Historical tool relative traversal remains accepted')
check(prepared.recipes.build.steps[1].args[5] == '', 'Step argv retains explicit empty values')
check(prepared.tools.cmake.args[1] == prepared.tools.cmake.args[2], 'Repeated tool argv is meaningful')
check(prepared.recipes.missing.project == 'absent', 'Unresolved references remain declarations')
check(J.encode(prepared.presets['project.build'][1].args) == '{}', 'Empty preset arguments remain an object')
check(prepared.presentation.presets.focused.extends == false, 'Standalone appearance declarations remain portable')
prepared.projects.source.targets[1] = 'changed'
check(declaration.projects.source.targets[1] == 'ce_cpp', 'Validated results are detached')
local function mutate(callback)
  local data = J.decode(before); callback(data); return data
end
rejected(mutate(function(d) d.version = 2 end), 'Unsupported version refused')
rejected(mutate(function(d) d.extra = true end), 'Unknown profile fields refused')
rejected(mutate(function(d) d.tools.cmake.command = 'C:/tools/cmake.exe' end), 'Machine executable stays outside portable profile')
rejected(mutate(function(d) d.tools.cmake.args = U.array({ '' }) end), 'Historical empty tool argv rule preserved')
rejected(mutate(function(d) d.projects.source.root.path = '../other' end), 'Project root cannot escape logical base')
rejected(mutate(function(d) d.tools = false end), 'Tools cannot be false')
rejected(mutate(function(d) d.tools = U.array() end), 'Object positions reject explicit empty arrays')
rejected(mutate(function(d) d.favorites = U.object() end), 'List positions reject explicit empty objects')
rejected(mutate(function(d) d.presets['project.build'][1].args.password = 'value' end), 'Sensitive submitted values refused')
rejected(mutate(function(d) d.command_links['project.build'].arguments.password.value = 'value' end), 'Annotations do not carry values')
rejected(mutate(function(d) d.ui = U.null end), 'Null declarations refused')
rejected(mutate(function(d) d.layout = { aliases = { ['project.build'] = 'another.command' } } end), 'Stable command link cannot be redirected by alias')
rejected({ version = 1, tools = setmetatable({}, { __index = function() error('must not run') end }) }, 'Arbitrary metatables refused')
local cyclic = { version = 1 }; cyclic.layout = cyclic
rejected(cyclic, 'Cycles refused')
rejected({ version = 1, favorites = { [2] = 'project.build' } }, 'Sparse lists refused')
rejected({ version = 1, ui = { width = math.huge } }, 'Non-finite numbers refused')
rejected({ version = 1, presets = { command = { { name = 'large', args = { text = string.rep('x', 1048576) } } } } }, 'Whole profile byte budget enforced')
require('command_environment.core.bridge')
ce_bridge_init('profile-contract')
local cap = J.decode(ce_bridge('profile_capabilities', '{}'))
check(cap.ok and cap.value.profile_version == 1 and cap.value.authority == 'data_only', 'Additive capabilities carry no dispatch authority')
local validated = J.decode(ce_bridge('profile_validate', J.encode({ profile = declaration })))
check(validated.ok and validated.value.recipes.build.steps[1].args[5] == '', 'Actual bridge shares exact normalization')
check(not J.decode(ce_bridge('profile_validate', '{"profile":{"version":1},"execute":true}')).ok, 'Bridge refuses extra action fields')
check(not J.decode(ce_bridge('profile_validate', '{"profile":null}')).ok, 'Bridge refuses null profile')
local oversized_error = J.decode(ce_bridge('profile_validate', J.encode({ profile = {
  version = 1, [string.rep('한', 10000)] = true
} })))
check(not oversized_error.ok and #oversized_error.error <= 8192 and J.valid_utf8(oversized_error.error),
  'Large Unicode declaration errors remain bounded valid response data')
check(J.decode(ce_bridge('snapshot', '{}')).value.protocol_version == 1, 'Existing protocol remains usable after rejected data')
print('Profile contract: ' .. checks .. ' checks passed')
