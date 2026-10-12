-- Neovim host execution. The portable command core never starts processes.
local M = {}
local direct_message = 'Direct process only; descendant termination is not confirmed by this backend'
local function scoped(helper) return helper ~= nil and helper ~= false end
function M.scope(helper)
  if not scoped(helper) then return 'direct', direct_message end
  local platform = vim.uv.os_uname().sysname
  if platform ~= 'Windows_NT' and platform ~= 'Linux' then return 'unsupported', 'Owned process helper is unsupported on this platform' end
  local scope = platform == 'Windows_NT' and 'windows_job' or 'linux_group'
  return scope, 'Owned ' .. scope .. '; deliberate detached daemons or services outside this scope are excluded'
end
function M.validate(helper)
  assert(not scoped(helper) or type(helper) == 'string' and helper ~= '' and not helper:find('\0', 1, true)
    and (helper:match('^[/\\]') or helper:match('^%a:[/\\]')),
    'process_helper must be an absolute local executable path or false')
end
function M.available(tool, helper)
  if vim.fn.executable(tool.command) ~= 1 then return false, 'Executable is not available: ' .. tool.command end
  if not scoped(helper) then return true end
  local platform = vim.uv.os_uname().sysname
  if platform ~= 'Windows_NT' and platform ~= 'Linux' then return false, 'Owned process helper is unsupported on this platform' end
  if vim.fn.executable(helper) ~= 1 then return false, 'Configured owned process helper is unavailable: ' .. helper end
  return true
end
local function read_status(path, scope)
  local stat = vim.uv.fs_stat(path)
  local ok, value = false, nil
  if stat and stat.type == 'file' and stat.size <= 4096 then
    ok, value = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path, 'b'), '\n')) end)
  end
  pcall(vim.fn.delete, path)
  local fields = { version = true, scope = true, exit_code = true, signal = true, cancelled = true, forced = true,
    termination_confirmed = true, detached_observed = true, error = true }
  local function integer(number, minimum, maximum)
    return type(number) == 'number' and number % 1 == 0 and number >= minimum and number <= maximum
  end
  local known_fields = ok and type(value) == 'table'
  if known_fields then for field in pairs(value) do if not fields[field] then known_fields = false; break end end end
  local coordinates = known_fields and (
    scope == 'windows_job' and integer(value.exit_code, -2147483648, 2147483647) and value.signal == 0 and value.detached_observed == -1
    or scope == 'linux_group' and integer(value.exit_code, 0, 255) and integer(value.signal, 0, 64)
      and (value.signal == 0 or value.exit_code == 128 + value.signal) and integer(value.detached_observed, 0, 1000000))
  if coordinates and value.version == 1 and value.scope == scope
    and type(value.cancelled) == 'boolean' and type(value.forced) == 'boolean'
    and type(value.termination_confirmed) == 'boolean' and type(value.detached_observed) == 'number'
    and value.detached_observed % 1 == 0 and value.detached_observed >= -1 and value.detached_observed <= 1000000
    and type(value.error) == 'string' and #value.error <= 500 and not value.error:find('[%z\1-\31\127]') then return value end
  return { exit_code = 125, signal = 0, cancelled = false, forced = false, termination_confirmed = false,
    detached_observed = -1, error = 'Owned process helper exited without a valid termination report' }
end
function M.run(tool, name, helper, target, done, invocation)
  local cwd, root, argv = target.cwd, target.root, target.argv
  local output, streams, size, truncated, cancelled, process = {}, { stdout = {}, stderr = {} }, 0, false, false, nil
  local exited, grace, forced = false, nil, false
  local owned = scoped(helper)
  local scope, scope_message = M.scope(helper)
  invocation.process_scope, invocation.process_scope_message = scope, scope_message
  local function close_grace()
    if grace then grace:stop(); grace:close(); grace = nil end
  end
  local function collect(channel)
    return function(err, chunk)
      chunk = err and tostring(err) or chunk
      if not chunk then return end
      local remaining = 1048576 - size
      if #chunk > remaining then truncated = true end
      if remaining > 0 then
        local captured = chunk:sub(1, remaining)
        output[#output + 1], streams[channel][#streams[channel] + 1] = captured, captured
        size = size + #captured
      end
    end
  end
  local launch, status = argv, nil
  if owned then
    status = vim.fn.tempname()
    vim.fn.writefile({}, status, 'b')
    if vim.uv.os_uname().sysname ~= 'Windows_NT' then vim.uv.fs_chmod(status, 384) end
    launch = { helper, '--status', status, '--grace-ms', tostring(tool.cancel_grace_ms or 2000), '--' }
    vim.list_extend(launch, argv)
  end
  local started, failure = pcall(function()
    process = vim.system(launch, { cwd = cwd, text = true, stdin = owned or nil,
      stdout = collect('stdout'), stderr = collect('stderr') }, function(result)
      exited = true
      vim.schedule(function()
        close_grace()
        local ownership = owned and read_status(status, scope) or nil
        local stdout, stderr = table.concat(streams.stdout), table.concat(streams.stderr)
        local parsed, detail = pcall(function()
          return require('command_tree.task_results').parse({ stdout = stdout, stderr = stderr }, { errorformat = tool.errorformat, cwd = cwd })
        end)
        if not parsed then detail = { locations = {}, locations_status = 'error',
          locations_message = 'Task location parsing failed: ' .. tostring(detail), invalid_locations = 0, locations_truncated = false } end
        detail.kind, detail.tool_name, detail.command_id = 'process', name, 'tool.' .. name
        detail.root, detail.cwd, detail.argv = root, cwd, vim.deepcopy(argv)
        detail.file, detail.cancelled, detail.forced = target.file, cancelled or ownership and ownership.cancelled or false, forced or ownership and ownership.forced or false
        detail.termination_confirmed, detail.process_scope = not owned or ownership.termination_confirmed, scope
        detail.descendant_termination = owned and (ownership.termination_confirmed and 'confirmed' or 'unconfirmed') or 'unknown'
        detail.detached_observed = owned and ownership.detached_observed or -1
        detail.detached_exclusion = 'Deliberately detached daemons and services outside the owned scope are excluded; their termination is not promised'
        detail.process_scope_message = invocation.process_scope_message
        detail.exit_code, detail.signal = owned and ownership.exit_code or result.code, owned and ownership.signal or result.signal
        detail.output, detail.stdout, detail.stderr, detail.truncated = table.concat(output), stdout, stderr, truncated
        if truncated then detail.locations_message = detail.locations_message .. '; captured process output was limited to 1 MiB' end
        if owned and ownership.error ~= '' then detail.message = ownership.error
        elseif owned and (result.code ~= 0 or result.signal ~= 0) then detail.message = 'Owned process helper transport failed'
        elseif detail.cancelled then detail.message = 'Cancelled' end
        done(not detail.cancelled and detail.exit_code == 0 and (not owned or result.code == 0 and result.signal == 0
          and ownership.termination_confirmed and ownership.error == ''), detail)
      end)
    end)
  end)
  if not started then if status then pcall(vim.fn.delete, status) end; error(failure, 0) end
  invocation.process_pid = process.pid
  local function control(force)
    if owned then process:write(force and 'f\n' or 'c\n') else process:kill(force and 9 or 15) end
  end
  invocation:on_cancel(function()
    if cancelled then return 'pending', 'Cancellation already requested; waiting for owned process completion' end
    if exited then return 'pending', 'Process exit received; waiting for completion' end
    local ok, err = pcall(control, false)
    if not ok then return false, tostring(err) end
    cancelled = true
    invocation.cancel_state = 'requested'
    invocation.cancel_deadline = vim.uv.hrtime() + (tool.cancel_grace_ms or 2000) * 1000000
    local timed, reason = pcall(function()
      grace = assert(vim.uv.new_timer(), 'Could not create cancellation timer')
      grace:start(tool.cancel_grace_ms or 2000, 0, vim.schedule_wrap(function()
        close_grace()
        if invocation.status == 'pending' and not exited then invocation.cancel_state = 'unconfirmed' end
      end))
    end)
    if not timed then close_grace(); invocation.cancel_error = 'Cancellation timer unavailable: ' .. tostring(reason) end
    return 'pending', owned and 'Owned scope cancellation requested; waiting for termination evidence' or 'Cancellation requested for the direct process; descendants remain unconfirmed'
  end)
  invocation:on_force_cancel(function()
    if not cancelled then return false, 'Request cancellation before forcing termination' end
    if exited then return 'pending', 'Process exit received; waiting for completion' end
    if forced then return 'pending', 'Force already requested; waiting for completion' end
    if invocation.cancel_state ~= 'unconfirmed' and vim.uv.hrtime() < (invocation.cancel_deadline or math.huge) then
      return false, 'Wait for the cancellation grace period before forcing termination'
    end
    local ok, err = pcall(control, true)
    if not ok then return false, tostring(err) end
    forced, invocation.cancel_state = true, 'force_requested'
    return 'pending', owned and 'Owned scope force requested; waiting for termination evidence' or 'Force requested for the owned direct process; descendants remain unconfirmed'
  end)
end
return M
