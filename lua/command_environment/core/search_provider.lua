-- Portable bounded project-search data. Hosts detect and run providers.
-- Lua 5.1; no editor, filesystem, process, or callback dependencies.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 1 }
local defaults = { results = 1000, max_file_bytes = 1048576, read_bytes = 8388608,
  output_bytes = 8388608, milliseconds = 5000 }
local maxima = { builtin = defaults, ripgrep = { results = 5000, max_file_bytes = 4194304,
  read_bytes = 67108864, output_bytes = 16777216, milliseconds = 15000 } }
local limit_fields = { results = true, max_file_bytes = true, read_bytes = true,
  output_bytes = true, milliseconds = true }
local option_fields = { mode = true, case = true, limits = true }
local request_fields = { provider = true, query = true, mode = true, case = true, limits = true }

local function object(value, fields, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'),
    label .. ' must be plain object data')
  for key in next, value do assert(fields[key] == true, 'Unknown ' .. label .. ' field') end
  return value
end
local function provider_name(provider)
  if provider == nil then return 'builtin' end
  assert(type(provider) == 'string' and maxima[provider], 'Search provider must be builtin or ripgrep')
  return provider
end
local function available_state(provider, available)
  if provider == 'builtin' then
    assert(available == nil or available == true, 'The builtin provider is always available')
    return true
  end
  assert(type(available) == 'boolean', 'Ripgrep availability must be an explicit boolean')
  return available
end
local function coordinates()
  return { encoding = 'utf-8', unit = 'byte', line_base = 1, column_base = 1, end_exclusive = true }
end
local function ignore_rules(provider)
  return { hidden = 'excluded', symlinks = 'excluded',
    generated_directories = U.array({ 'node_modules', 'build', 'dist', 'target', '__pycache__', 'vendor' }),
    project_ignore = provider == 'ripgrep', user_configuration = false }
end

-- Options never contain executable paths or host process configuration. An
-- explicit provider stays selected even when the host later finds it missing.
function M.request(provider, query, options)
  provider = provider_name(provider)
  assert(type(query) == 'string' and #query > 0 and #query <= 4096
    and not query:find('[\r\n%z]') and J.valid_utf8(query),
    'Search query must be one nonempty UTF-8 line of at most 4096 bytes')
  if options == nil then options = {} end
  object(options, option_fields, 'search options')
  local mode = options.mode == nil and 'literal' or options.mode
  local case = options.case == nil and 'sensitive' or options.case
  assert(mode == 'literal' or mode == 'regex', 'Search mode must be literal or regex')
  assert(case == 'sensitive' or case == 'insensitive', 'Search case must be sensitive or insensitive')
  assert(provider == 'ripgrep' or mode == 'literal' and case == 'sensitive',
    'The builtin provider supports only literal, case-sensitive search')
  local requested = options.limits
  if requested == nil then requested = {} end
  object(requested, limit_fields, 'search limits')
  local limits = {}
  for key in next, limit_fields do
    local value = requested[key]
    if value == nil then value = defaults[key] end
    assert(type(value) == 'number' and value == value and value % 1 == 0
      and value >= 1 and value <= maxima[provider][key],
      'Search ' .. key .. ' must be a positive integer no greater than ' .. maxima[provider][key])
    limits[key] = value
  end
  return { provider = provider, query = query, mode = mode, case = case, limits = limits }
end

-- Availability is supplied by the host; this module never probes a machine.
-- Limits are ceilings, while default_limits are modest values for new runs.
function M.manifest(provider, available)
  provider = provider_name(provider)
  return { contract_version = 1, provider = provider, available = available_state(provider, available),
    optional = provider == 'ripgrep',
    query_modes = U.array(provider == 'ripgrep' and { 'literal', 'regex' } or { 'literal' }),
    case_modes = U.array(provider == 'ripgrep' and { 'sensitive', 'insensitive' } or { 'sensitive' }),
    coordinates = coordinates(), ignore_rules = ignore_rules(provider),
    limits = U.clone(maxima[provider]), default_limits = U.clone(defaults), fallback = 'none' }
end

-- Provenance contains bounded portable data, without queries, project paths,
-- executable paths, handles, or callbacks. Missing ripgrep is not a fallback.
function M.report(request, available)
  object(request, request_fields, 'search request')
  assert(request.provider ~= nil and request.mode ~= nil and request.case ~= nil and request.limits ~= nil,
    'Search report requires a normalized request')
  local checked = M.request(request.provider, request.query,
    { mode = request.mode, case = request.case, limits = request.limits })
  for key in next, limit_fields do
    assert(rawget(request.limits, key) ~= nil, 'Search report requires all normalized limits')
  end
  local manifest = M.manifest(checked.provider, available)
  return { contract_version = 1, provider = checked.provider, available = manifest.available,
    status = manifest.available and 'ready' or 'unavailable', mode = checked.mode, case = checked.case,
    limits = checked.limits, coordinates = manifest.coordinates, ignore_rules = manifest.ignore_rules,
    fallback = 'none', message = manifest.available and ''
      or 'Selected ripgrep provider is unavailable; configure an existing ripgrep executable or choose builtin' }
end
return M
