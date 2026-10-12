-- Run through tests/run.py or Lua 5.1 with the repository root as arg[1].
-- Remove the editor global before loading or exercising the portable contract.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local S = require('command_environment.core.search_provider')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label)
  check(U.deep_equal(J.decode(J.encode(expected)), J.decode(J.encode(actual))), label)
end
local function raises(callback, label) check(not pcall(callback), label) end
local defaults = { results = 1000, max_file_bytes = 1048576, read_bytes = 8388608,
  output_bytes = 8388608, milliseconds = 5000 }
local builtin = S.manifest()
check(S.contract_version == 1 and vim == nil, 'Search provider data runs without an editor API')
check(builtin.provider == 'builtin' and builtin.available and not builtin.optional,
  'Builtin is the available default provider')
equal({ 'literal' }, builtin.query_modes, 'Builtin declares literal matching only')
equal({ 'sensitive' }, builtin.case_modes, 'Builtin declares its case behavior explicitly')
equal(defaults, builtin.limits, 'Builtin ceilings preserve existing bounded scan limits')
equal(defaults, builtin.default_limits, 'Builtin defaults remain modest')
equal({ encoding = 'utf-8', unit = 'byte', line_base = 1, column_base = 1, end_exclusive = true },
  builtin.coordinates, 'Structured coordinates use one-based UTF-8 bytes and end-exclusive ranges')
check(not builtin.ignore_rules.project_ignore and builtin.ignore_rules.hidden == 'excluded'
  and builtin.ignore_rules.symlinks == 'excluded' and not builtin.ignore_rules.user_configuration,
  'Builtin provenance describes its explicit ignore rules')
equal({ 'node_modules', 'build', 'dist', 'target', '__pycache__', 'vendor' },
  builtin.ignore_rules.generated_directories, 'Generated-directory exclusions are shared data')

local rg = S.manifest('ripgrep', true)
check(rg.optional and rg.available and rg.fallback == 'none', 'Ripgrep is explicit optional capability without fallback')
equal({ 'literal', 'regex' }, rg.query_modes, 'Ripgrep declares both query modes')
equal({ 'sensitive', 'insensitive' }, rg.case_modes, 'Ripgrep declares both case modes')
equal(defaults, rg.default_limits, 'Ripgrep uses bounded modest defaults before explicit increases')
equal({ results = 5000, max_file_bytes = 4194304, read_bytes = 67108864,
  output_bytes = 16777216, milliseconds = 15000 }, rg.limits, 'Ripgrep allows finite project-scale ceilings')
check(rg.ignore_rules.project_ignore and not rg.ignore_rules.user_configuration,
  'Ripgrep respects project ignores while disabling user process configuration')
check(not S.manifest('ripgrep', false).available, 'Missing optional executable is explicit capability data')

local source_options = { limits = { results = 17 } }
local request = S.request(nil, '한😀.*', source_options)
check(request.provider == 'builtin' and request.query == '한😀.*'
  and request.mode == 'literal' and request.case == 'sensitive', 'Default request preserves UTF-8 literal query semantics')
check(request.limits.results == 17 and request.limits.milliseconds == 5000,
  'Partial bounds fill only declared defaults')
request.limits.results = 18
check(source_options.limits.results == 17, 'Validated request detaches caller-owned bounds')
for _, mode in ipairs({ 'literal', 'regex' }) do
  for _, case in ipairs({ 'sensitive', 'insensitive' }) do
    local selected = S.request('ripgrep', '한😀[a-z]', { mode = mode, case = case, limits = rg.limits })
    local transported = J.decode(J.encode(selected))
    local ready = S.report(transported, true)
    check(ready.provider == 'ripgrep' and ready.available and ready.status == 'ready'
      and ready.mode == mode and ready.case == case and ready.message == '',
      'Selected ripgrep mode and case survive transport and provenance')
    equal(rg.limits, ready.limits, 'Explicit finite project-scale bounds survive transport')
    local missing = S.report(transported, false)
    check(missing.provider == 'ripgrep' and not missing.available and missing.status == 'unavailable'
      and missing.fallback == 'none' and missing.message:find('unavailable', 1, true),
      'Unavailable ripgrep retains selection and never silently switches to builtin')
    equal(ready.coordinates, missing.coordinates, 'Unavailable reports retain coordinate capability')
    equal(ready.ignore_rules, missing.ignore_rules, 'Unavailable reports retain ignore capability')
    ready.limits.results = 1
    check(transported.limits.results == 5000, 'Reports cannot mutate validated requests')
  end
end
local report = S.report(S.request('builtin', 'C:/private/project/secret-query'), true)
local encoded = J.encode(report)
check(not encoded:find('private', 1, true) and not encoded:find('secret-query', 1, true)
  and not encoded:find('query', 1, true), 'Portable provenance omits query and host paths')
equal(report, J.decode(encoded), 'Portable reports contain only JSON data')
local changed = S.manifest('ripgrep', true)
changed.query_modes[1], changed.coordinates.unit, changed.default_limits.results = 'changed', 'changed', 1
changed.ignore_rules.generated_directories[1], changed.limits.results = 'changed', 1
local fresh = S.manifest('ripgrep', true)
check(fresh.query_modes[1] == 'literal' and fresh.coordinates.unit == 'byte'
  and fresh.default_limits.results == 1000 and fresh.ignore_rules.generated_directories[1] == 'node_modules'
  and fresh.limits.results == 5000, 'Manifest mutation cannot change future defaults or capabilities')

raises(function() S.request('builtin', 'x', { mode = 'regex' }) end, 'Builtin rejects regex instead of changing provider')
raises(function() S.request('builtin', 'x', { case = 'insensitive' }) end, 'Builtin rejects unsupported case semantics')
for _, bad in ipairs({ '', 'x\ny', 'x\ry', 'x\0y', string.rep('x', 4097), string.char(192, 128),
  string.char(237, 160, 128), string.char(244, 144, 128, 128), string.char(240, 159), false, 1, {} }) do
  raises(function() S.request('ripgrep', bad) end, 'Malformed or oversized query cannot reach a host process')
end
check(#S.request('ripgrep', string.rep('x', 4096)).query == 4096, 'Exactly 4096 query bytes are supported')
for _, bad in ipairs({ '', 'rg', 'external', false, 1, {} }) do
  raises(function() S.request(bad, 'x') end, 'Provider selection is a strict enum')
  raises(function() S.manifest(bad, true) end, 'Capability selection is a strict enum')
end
for _, bad in ipairs({ 'smart', '', false, 1, {} }) do
  raises(function() S.request('ripgrep', 'x', { mode = bad }) end, 'Query modes are a strict enum')
  raises(function() S.request('ripgrep', 'x', { case = bad }) end, 'Case modes are a strict enum')
end
for _, bad in ipairs({ false, 1, 'literal', U.array() }) do
  raises(function() S.request('ripgrep', 'x', bad) end, 'Options must be plain object data')
  raises(function() S.request('ripgrep', 'x', { limits = bad }) end, 'Limits must be plain object data')
end
for _, key in ipairs({ 'command', 'cwd', 'callback', 'fallback', 'count', 'extra' }) do
  raises(function() S.request('ripgrep', 'x', { [key] = function() end }) end,
    'Host execution and unknown option fields cannot enter the portable contract')
  raises(function() S.request('ripgrep', 'x', { limits = { [key] = 1 } }) end,
    'Unknown bound fields cannot hide in normalized data')
end
for _, provider in ipairs({ 'builtin', 'ripgrep' }) do
  local ceiling = S.manifest(provider, true).limits
  for key, maximum in pairs(ceiling) do
    check(S.request(provider, 'x', { limits = { [key] = maximum } }).limits[key] == maximum,
      'Exactly the declared provider ceiling is supported')
    for _, bad in ipairs({ 0, -1, 1.5, maximum + 1, math.huge, -math.huge, 0 / 0, false, '1', {} }) do
      raises(function() S.request(provider, 'x', { limits = { [key] = bad } }) end,
        'Each bound rejects wrong types, nonfinite values, fractions, and out-of-range integers')
    end
  end
end
raises(function() S.manifest('ripgrep') end, 'Optional provider availability cannot be assumed')
raises(function() S.manifest('builtin', false) end, 'Builtin availability cannot be contradicted')
for _, bad in ipairs({ 'yes', 1, {}, function() end }) do
  raises(function() S.manifest('ripgrep', bad) end, 'Availability must be explicit boolean data')
  raises(function() S.report(S.request('ripgrep', 'x'), bad) end, 'Report availability rejects foreign data')
end
for _, tamper in ipairs({
  function(value) value.extra = true end,
  function(value) value.query = '' end,
  function(value) value.provider = nil end,
  function(value) value.mode = nil end,
  function(value) value.case = nil end,
  function(value) value.limits = nil end,
  function(value) value.limits.results = nil end,
  function(value) value.limits.results = 5001 end,
  function(value) value.limits.extra = 1 end,
}) do
  local bad = S.request('ripgrep', 'x'); tamper(bad)
  raises(function() S.report(bad, true) end, 'Malformed or tampered requests cannot produce provenance')
end
local called = false
local foreign = setmetatable({}, { __index = function() called = true; return 'regex' end,
  __pairs = function() called = true; error('must not execute') end })
raises(function() S.request('ripgrep', 'x', foreign) end, 'Foreign options cannot run callbacks')
raises(function() S.request('ripgrep', 'x', { limits = foreign }) end, 'Foreign bounds cannot run callbacks')
raises(function() S.report(foreign, true) end, 'Foreign report input cannot run callbacks')
check(not called, 'All validation avoids invoking foreign metatables')
print('Portable search-provider contract: ' .. checks .. ' checks PASS; no editor API; ' .. _VERSION)
