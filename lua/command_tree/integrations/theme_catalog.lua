-- Neovim-only discovery and advisory palette classification. Installed themes
-- execute in bounded clean workers, never in the editor which owns the picker.
local M, uv = {}, vim.uv
local Cache = require('command_tree.integrations.theme_cache')
local Name = require('command_tree.integrations.theme_state').name
local MAX_THEMES, MAX_OUTPUT, MAX_GLOBALS = 256, 65536, 32768
local marker = 'RE35_THEME_PROBE:'
local worker = debug.getinfo(1, 'S').source:sub(2):gsub('theme_catalog.lua$', 'theme_probe.lua')

local function globals(name)
  local family = name:gsub('-', '_'):match('^[^_]+') or name
  local result, total = {}, 0
  for _, variable in ipairs(vim.fn.getcompletion('g:', 'var')) do
    local key = variable:gsub('^g:', '')
    local value = vim.g[key]
    -- Theme setup options commonly use this namespace. Never send unrelated
    -- globals (which may contain credentials), callbacks, or entire user init.
    if key:sub(1, #family + 1) == family .. '_' or key:match('^theme_') or key:match('^colorscheme_') then
      local ok, encoded = pcall(vim.json.encode, value)
      if ok and #encoded <= 8192 and total + #encoded <= MAX_GLOBALS then
        result[key], total = vim.json.decode(encoded), total + #encoded
      end
    end
  end
  return result
end
local function configuration(name, paths)
  local runtime = vim.api.nvim_list_runtime_paths()
  while #runtime > 128 do table.remove(runtime) end
  local options = globals(name)
  local versions = vim.version()
  local stamps = {}
  for _, path in ipairs(paths) do stamps[#stamps + 1] = Cache.stamp(path) end
  -- MYVIMRC is fingerprinted, not executed by workers. Lua setup functions and
  -- ColorScheme handlers are deliberately not copied across this boundary.
  local config = vim.env.MYVIMRC and Cache.stamp(vim.env.MYVIMRC) or false
  return { name = name, runtimepath = runtime, globals = options, termguicolors = vim.o.termguicolors },
    Cache.hash({ stamps, runtime, options, config, vim.o.termguicolors, versions.major, versions.minor, versions.patch })
end
local function signature(base, dependencies)
  local stamps = {}
  for _, path in ipairs(dependencies or {}) do stamps[#stamps + 1] = Cache.stamp(path) end
  return Cache.hash({ base, stamps })
end
local function observation(value)
  if type(value) ~= 'table' or type(value.supported) ~= 'boolean' then return nil end
  return { supported = value.supported, failed = value.failed == true,
    transient = value.transient == true,
    reason = type(value.reason) == 'string' and value.reason:sub(1, 2048) or nil,
    background = value.background, palette = value.palette }
end

function M.new(options)
  options = options or {}
  local path = options.path or (vim.fn.stdpath('cache') .. '/re35/theme-catalog-v1.json')
  local timeout = options.timeout_ms or 2000
  local entries, retained = Cache.read(path), {}
  local names, by_name, queue, listeners = {}, {}, {}, {}
  local active, generation, scheduled, stopped, exit_hook = nil, 0, false, false, nil
  local initialized, discovering, cache_error, discovery_error = false, false, nil, nil
  local catalog = {}

  local function notify()
    for callback in pairs(listeners) do pcall(callback) end
  end
  local function save()
    local ok, why = Cache.write(path, retained)
    if ok then cache_error = nil else cache_error = tostring(why) end
  end
  local pump
  local function discover()
    discovering = true
    names, by_name, queue, retained = {}, {}, {}, {}
    discovery_error = nil
    local seen = {}
    for _, name in ipairs(vim.fn.getcompletion('', 'color')) do
      if Name(name) and not seen[name] then names[#names + 1], seen[name] = name, true end
    end
    table.sort(names)
    if #names > MAX_THEMES then
      discovery_error = 'Theme inspection is limited to 256 installed themes'
      while #names > MAX_THEMES do table.remove(names) end
    end
    for _, name in ipairs(names) do by_name[name] = { name = name } end
    local current, preferred = vim.g.colors_name, vim.o.background
    local inspection = vim.deepcopy(names)
    table.sort(inspection, function(a, b) if a == current then return true elseif b == current then return false end; return a < b end)
    local index, revision = 1, generation
    local function inspect(name)
      local paths = {}
      for _, file in ipairs(vim.api.nvim_get_runtime_file('colors/' .. name .. '.*', true)) do
        if (file:match('%.vim$') or file:match('%.lua$')) and Cache.stamp(file) then paths[#paths + 1] = file end
      end
      local request, base = configuration(name, paths)
      local cached = entries[name]
      local entry = { name = name, request = request, base = base }
      by_name[name] = entry
      if cached and not cached.light.transient and not cached.dark.transient and cached.key == signature(base, cached.dependencies) then
        entry.light, entry.dark = cached.light, cached.dark
        retained[name] = cached
      elseif #paths == 0 then
        entry.light = { supported = false, failed = true, reason = 'No regular runtime colorscheme source was found' }
        entry.dark = vim.deepcopy(entry.light)
      else
        entry.dependencies = {}
        queue[#queue + 1] = { entry = entry, background = 'dark' }
        queue[#queue + 1] = { entry = entry, background = 'light' }
      end
    end
    local function step()
      if stopped or revision ~= generation then return end
      local name = inspection[index]
      if not name then
        initialized, discovering = true, false
        table.sort(queue, function(a, b)
          if a.entry.name ~= b.entry.name then
            if a.entry.name == current then return true elseif b.entry.name == current then return false end
            return a.entry.name < b.entry.name
          end
          return a.background == preferred and b.background ~= preferred
        end)
        save() -- Also prunes observations for removed or changed runtime themes.
        notify()
        pump()
        return
      end
      local ok, why = pcall(inspect, name)
      if not ok then
        local failure = { supported = false, failed = true, transient = true,
          reason = 'Theme discovery failed: ' .. tostring(why):sub(1, 512) }
        by_name[name] = { name = name, light = failure, dark = failure }
      end
      index = index + 1
      notify()
      -- Resolve/fingerprint one theme per event-loop turn. A large installed
      -- collection must not turn initial classification into an input freeze.
      vim.schedule(step)
    end
    vim.schedule(step)
  end
  local function finish(job, value)
    if job.generation ~= generation then return end
    active = nil
    local entry = job.entry
    if not entry.live or not entry.live[job.background] then
      entry[job.background] = observation(value) or { supported = false, failed = true, transient = true,
        reason = 'Invalid theme inspection result' }
    end
    local seen = {}
    for _, dependency in ipairs(entry.dependencies or {}) do seen[dependency] = true end
    local dependencies = type(value) == 'table' and type(value.dependencies) == 'table' and value.dependencies or {}
    for _, dependency in ipairs(dependencies) do
      if type(dependency) == 'string' and #dependency <= 4096 and not seen[dependency] and #entry.dependencies < 512 then
        entry.dependencies[#entry.dependencies + 1], seen[dependency] = dependency, true
      end
    end
    if entry.light and entry.dark then
      table.sort(entry.dependencies)
      local record = { key = signature(entry.base, entry.dependencies), dependencies = entry.dependencies,
        light = entry.light, dark = entry.dark }
      if entry.light.transient or entry.dark.transient then
        entries[entry.name], retained[entry.name] = nil, nil
      else entries[entry.name], retained[entry.name] = record, record end
      save()
    end
    notify()
    vim.schedule(pump)
  end
  pump = function()
    if stopped or active or not next(listeners) or #queue == 0 then return end
    local job = table.remove(queue, 1)
    job.generation = generation
    active = job
    local output, bytes, overflow = {}, 0, false
    local function stream(_, chunk)
      if not chunk then return end
      bytes = bytes + #chunk
      if bytes <= MAX_OUTPUT then output[#output + 1] = chunk
      elseif not overflow then
        overflow = true
        vim.schedule(function() if active == job and job.process then pcall(job.process.kill, job.process, 9) end end)
      end
    end
    local request = vim.tbl_extend('force', {}, job.entry.request, { background = job.background })
    local ok, process = pcall(vim.system, { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n', '-l', worker },
      { stdin = vim.json.encode(request), stdout = stream, stderr = stream, timeout = timeout,
        env = { NVIM = '', NVIM_LISTEN_ADDRESS = '' } }, function(result)
        vim.schedule(function()
          if job.generation ~= generation then return end
          local value
          if not overflow and result.code == 0 then
            local encoded = table.concat(output):match(marker .. '([^\r\n]+)')
            if encoded then local decoded, data = pcall(vim.json.decode, encoded); if decoded then value = data end end
          end
          finish(job, value or { supported = false, failed = true, transient = true,
            reason = overflow and 'Theme inspection exceeded its output limit'
              or result.code == 124 and 'Theme inspection timed out'
              or ('Theme inspection process failed: ' .. table.concat(output):sub(1, 1536)) })
        end)
      end)
    if ok then job.process = process
    else finish(job, { supported = false, failed = true, transient = true,
      reason = 'Theme inspection could not start: ' .. tostring(process) }) end
  end
  local function start()
    stopped = false
    if scheduled or discovering then return end
    scheduled = true
    vim.schedule(function()
      scheduled = false
      if stopped or not next(listeners) then return end
      if not initialized then
        local ok, why = pcall(discover)
        if not ok then
          initialized, discovering, names, by_name, queue = true, false, {}, {}, {}
          discovery_error = 'Theme discovery failed: ' .. tostring(why):sub(1, 512)
          notify()
        end
      end
      pump()
    end)
  end
  function catalog.subscribe(callback)
    assert(type(callback) == 'function')
    listeners[callback] = true
    if not exit_hook then
      exit_hook = vim.api.nvim_create_autocmd('VimLeavePre', { once = true, callback = function()
        stopped, generation = true, generation + 1
        if active and active.process then pcall(active.process.kill, active.process, 9) end
      end })
    end
    start()
    local disposed = false
    return function()
      if disposed then return end
      disposed, listeners[callback] = true, nil
      if not next(listeners) then
        stopped, generation = true, generation + 1
        if active then
          table.insert(queue, 1, { entry = active.entry, background = active.background })
          if active.process then pcall(active.process.kill, active.process, 9) end
          active = nil
        end
        -- Reopening re-discovers additions/deletions and configuration changes;
        -- successful partial observations have already been saved.
        initialized, discovering = false, false
        -- Retired lists must not flash a deleted theme on the next opening
        -- while fresh runtime discovery is still waiting for its scheduled turn.
        names, by_name, queue = {}, {}, {}
        if exit_hook then pcall(vim.api.nvim_del_autocmd, exit_hook); exit_hook = nil end
      end
    end
  end
  function catalog.choices(background)
    local result = {}
    for _, name in ipairs(names) do
      local entry = by_name[name]
      if entry[background] and entry[background].supported == true then result[#result + 1] = { value = name, label = name } end
    end
    return result
  end
  function catalog.reject(name, background, actual, reason)
    local entry = by_name[name]
    if not entry or background ~= 'dark' and background ~= 'light' then return end
    entry[background] = { supported = false, background = actual.background, palette = actual.palette,
      reason = reason }
    entry.live = entry.live or {}
    entry.live[background] = true
    -- A live configuration can differ from an isolated theme's defaults (for
    -- example, a Lua setup() option). Prefer that authoritative observation.
    if retained[name] then
      retained[name][background] = entry[background]
      entries[name] = retained[name]
      save()
    end
    notify()
  end
  function catalog.status(background)
    local report = { pending = 0, failed = 0, unclassified = 0, available = 0, reasons = {}, cache_error = cache_error,
      discovery_error = discovery_error, initialized = initialized }
    for _, name in ipairs(names) do
      local checked = by_name[name][background]
      if not checked then report.pending = report.pending + 1
      elseif checked.supported then report.available = report.available + 1
      elseif checked.failed or checked.palette == nil then
        local key = checked.failed and 'failed' or 'unclassified'
        report[key] = report[key] + 1
        if #report.reasons < 8 then report.reasons[#report.reasons + 1] = name .. ': ' .. tostring(checked.reason) end
      end
    end
    return report
  end
  return catalog
end
return M
