-- Small JSON transactions. Recovery requires proof that the local owner exited;
-- old timestamps alone never authorize deleting a lock held by another editor.
local M = {}
local uv = vim.uv
local MAX_BYTES = 4 * 1024 * 1024
local function fingerprint(value)
  -- A NUL-containing Lua string becomes a Blob at Vim's function boundary on
  -- Neovim 0.11. Escape both the marker and NUL so even damaged binary locks
  -- have an unambiguous, inspectable ownership token.
  local encoded = value:gsub("\\", "\\\\"):gsub("%z", "\\0")
  return vim.fn.sha256(encoded)
end

local function raw_read(path)
  local fd, err = uv.fs_open(path, "r", 384)
  if not fd then return nil, err end
  local stat, stat_error = uv.fs_fstat(fd)
  local value, failure
  if stat and stat.type == "file" and stat.size <= MAX_BYTES then value, failure = uv.fs_read(fd, stat.size, 0) end
  uv.fs_close(fd)
  return value, failure or stat_error or (not value and "Not a file or exceeds 4 MiB" or nil)
end

local function write_all(fd, value)
  local offset = 0
  while offset < #value do
    local written, failure = uv.fs_write(fd, value:sub(offset + 1), offset)
    assert(written and written > 0, failure or "Incomplete state write")
    offset = offset + written
  end
end

function M.read(path)
  local text, err = raw_read(path)
  if not text then
    if tostring(err):find("ENOENT", 1, true) then return {} end
    return nil, "Cannot read " .. path .. ": " .. tostring(err)
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then return nil, "Invalid JSON state in " .. path .. "; original file was preserved" end
  return value
end

function M.check_version(data, version)
  if data.version ~= nil and data.version ~= version then
    return false, "Unsupported state version " .. tostring(data.version) .. "; original file was preserved"
  end
  return true
end

local function inspect_owner(path, kind, label)
  local text, err = raw_read(path)
  if not text then
    if tostring(err):find("ENOENT", 1, true) then return { status = "missing" } end
    return { status = "unknown", reason = tostring(err) }
  end
  local result = { status = "unknown", token = fingerprint(text), reason = label .. " ownership is unknown" }
  local ok, owner = pcall(vim.json.decode, text)
  if not ok or type(owner) ~= "table" or owner.version ~= 1 or owner.kind ~= kind
    or type(owner.token) ~= "string" or type(owner.pid) ~= "number" or owner.pid < 1 or owner.pid % 1 ~= 0 then return result end
  result.owner = owner
  if owner.host ~= uv.os_gethostname() then result.reason = label .. " belongs to another host"; return result end
  local checked, alive, failure = pcall(uv.kill, owner.pid, 0)
  if checked and alive then result.status, result.reason = "active", label .. " owner is still running"
  elseif checked and tostring(failure):find("ESRCH", 1, true) then
    result.status, result.reason = "orphan", "Local " .. label:lower() .. " owner has exited"
  else result.reason = "Cannot verify " .. label:lower() .. " owner: " .. tostring(failure or alive) end
  return result
end

function M.inspect_lock(path) return inspect_owner(path .. ".lock", "command-tree-lock", "Lock") end
function M.inspect_recovery(path) return inspect_owner(path .. ".lock.recovery", "command-tree-recovery", "Recovery guard") end

local function ownership(kind)
  return vim.json.encode({ kind = kind, version = 1, pid = uv.os_getpid(), host = uv.os_gethostname(),
    token = tostring(uv.os_getpid()) .. ":" .. tostring(uv.hrtime()), created = os.time() })
end

local function claim_recovery(path, opts)
  local guard_path = path .. ".lock.recovery"
  if opts.recovery_token then
    local observed = M.inspect_recovery(path)
    assert(observed.status ~= "active", observed.reason)
    assert(observed.token == opts.recovery_token,
      "Recovery guard changed since inspection; call inspect_recovery() again")
    assert(observed.status == "orphan" or (opts.force == true and observed.status == "unknown"),
      "Ambiguous recovery guard; inspect_recovery() and use force with its exact recovery_token after checking other editors")
    local latest = M.inspect_recovery(path)
    assert(latest.token == observed.token and latest.status ~= "active", "Recovery guard changed during inspection")
    local removed, failure = uv.fs_unlink(guard_path)
    assert(removed, failure)
  end
  local guard, failure = uv.fs_open(guard_path, "wx", 384)
  assert(guard, "Lock recovery is already guarded; call inspect_recovery() and explicitly recover_lock() with its recovery_token: " .. tostring(failure))
  return guard
end

-- Unknown/legacy locks require explicit approval of the exact observed token.
-- A crashed recovery guard also needs its separately observed recovery_token.
-- Known active locks and guards cannot be removed, even when force is true.
function M.recover_lock(path, opts)
  opts = opts or {}
  local guard_path = path .. ".lock.recovery"
  local claimed, guard = pcall(claim_recovery, path, opts)
  if not claimed then return false, tostring(guard) end
  local encoded = ownership("command-tree-recovery")
  local own_token = fingerprint(encoded)
  local ok, result = pcall(function()
    write_all(guard, encoded)
    local synced, sync_error = uv.fs_fsync(guard)
    assert(synced, sync_error)
    local current = M.inspect_lock(path)
    if current.status == "missing" then return true end
    assert(current.status ~= "active", current.reason)
    assert(current.status == "orphan" or (opts.force == true and opts.token and current.token == opts.token),
      "Ambiguous lock; inspect_lock() and explicitly recover_lock() with its token after checking other editors")
    if opts.token then assert(current.token == opts.token, "Lock changed since inspection; inspect it again") end
    local latest = M.inspect_lock(path)
    assert(latest.token == current.token and latest.status ~= "active", "Lock changed during recovery")
    assert(M.inspect_recovery(path).token == own_token, "Recovery guard changed; original lock was preserved")
    local removed, failure = uv.fs_unlink(path .. ".lock")
    assert(removed, failure)
    return true
  end)
  uv.fs_close(guard)
  -- Never remove a guard replaced by another process or a partial unknown write.
  if M.inspect_recovery(path).token == own_token then uv.fs_unlink(guard_path) end
  if not ok then return false, tostring(result) end
  return true
end

function M.update(path, mutate)
  local lock, temporary, output, lock_path = nil, nil, nil, path .. ".lock"
  local ok, result = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local lock_error
    lock, lock_error = uv.fs_open(lock_path, "wx", 384)
    if not lock and tostring(lock_error):find("EEXIST", 1, true) then
      local inspection = M.inspect_lock(path)
      if inspection.status == "orphan" then
        local recovered, recovery_error = M.recover_lock(path, { token = inspection.token })
        if recovered then lock, lock_error = uv.fs_open(lock_path, "wx", 384) end
        if not recovered then lock_error = recovery_error end
      end
    end
    assert(lock, "Cannot lock state; retry or inspect_lock/recover_lock (" .. lock_path .. "): " .. tostring(lock_error))
    write_all(lock, ownership("command-tree-lock"))
    local data, read_error = M.read(path)
    assert(data, read_error)
    data = mutate(data) or data
    assert(type(data) == "table", "State mutation must produce a table")
    local encoded = vim.json.encode(data)
    assert(#encoded <= MAX_BYTES, "State exceeds 4 MiB")
    temporary = path .. ".tmp." .. tostring(uv.os_getpid()) .. "." .. tostring(uv.hrtime())
    local open_error
    output, open_error = uv.fs_open(temporary, "wx", 384)
    assert(output, open_error)
    write_all(output, encoded)
    local synced, sync_error = uv.fs_fsync(output)
    assert(synced, sync_error)
    local closed, close_error = uv.fs_close(output)
    output = nil
    assert(closed, close_error)
    local renamed, rename_error = uv.fs_rename(temporary, path)
    assert(renamed, rename_error)
    temporary = nil
    return data
  end)
  if output then pcall(uv.fs_close, output) end
  if temporary then pcall(uv.fs_unlink, temporary) end
  if lock then uv.fs_close(lock); uv.fs_unlink(lock_path) end
  if not ok then return false, tostring(result) end
  return true, nil, result
end

return M
