-- Publish a bounded, reviewed snapshot without replacing an existing file.
-- Snapshot/schema ownership stays with the caller; this module owns only I/O.
local M, uv = {}, vim.uv
local LIMIT = 65536

local function destination(path)
  if type(path) ~= 'string' or path == '' or #path > 4096 or path:find('[%z\1-\31\127]') then
    return nil, 'Choose a valid unused file path'
  end
  local absolute = vim.fn.fnamemodify(path, ':p'):gsub('\\', '/')
  local parent, leaf = absolute:match('^(.*)/([^/]+)$')
  if not parent or leaf == '.' or leaf == '..' then return nil, 'Choose a file inside an existing directory' end
  local real = uv.fs_realpath(parent)
  local stat = real and uv.fs_stat(real)
  if not stat or stat.type ~= 'directory' then return nil, 'The export directory must already exist' end
  local target = real:gsub('\\', '/'):gsub('/+$', '') .. '/' .. leaf
  if uv.fs_lstat(target) then return nil, 'The export destination already exists; choose another path' end
  return { path = target, parent = real, dev = stat.dev, ino = stat.ino }
end

function M.destination(path)
  local ok, result, reason = pcall(destination, path)
  if not ok then return nil, 'Could not inspect the export destination' end
  return result, reason
end

local function same(target, reviewed)
  return type(target) == 'table' and type(reviewed) == 'table'
    and target.path == reviewed.path and target.parent == reviewed.parent
    and target.dev == reviewed.dev and target.ino == reviewed.ino
end

function M.publish(path, reviewed, encoded, validate)
  if type(encoded) ~= 'string' or #encoded == 0 or #encoded > LIMIT then
    return false, 'Export exceeds its bounded size limit'
  end
  if type(validate) ~= 'function' then return false, 'Export snapshot validation is required' end
  local fd, temporary, created
  local function check_snapshot()
    local safe, valid, why = pcall(validate)
    if not safe then error('Export snapshot validation failed', 0) end
    if valid ~= true then error(type(why) == 'string' and why or 'Export snapshot changed; prepare it again', 0) end
  end
  local ok, result = pcall(function()
    check_snapshot()
    local target, reason = M.destination(path)
    if not target then error(reason, 0) end
    if not same(target, reviewed) then error('Export destination changed; review it again', 0) end
    temporary = target.path .. '.re35-' .. vim.fn.sha256(tostring(uv.hrtime()) .. tostring({})):sub(1, 16) .. '.tmp'
    fd = uv.fs_open(temporary, 'wx', 384)
    if not fd then error('Could not create a private export file', 0) end
    created = true
    local wrote = uv.fs_write(fd, encoded, 0)
    if wrote ~= #encoded or not uv.fs_fsync(fd) then error('Export write failed; destination was not created', 0) end
    local closed = uv.fs_close(fd)
    if closed then fd = nil end
    if not closed then error('Export write failed; destination was not created', 0) end
    check_snapshot()
    local current, current_error = M.destination(path)
    if not current then error(current_error, 0) end
    if not same(current, reviewed) then error('Export destination changed; review it again', 0) end
    -- Linking is atomic and cannot clobber a destination another writer claimed.
    -- Unsupported filesystems fail safely; never fall back to rename or to a
    -- visible destination that contains only a partial write.
    if not uv.fs_link(temporary, target.path) then
      error('Could not publish export without overwriting; choose another supported destination', 0)
    end
    return target.path
  end)
  if fd then pcall(uv.fs_close, fd) end
  if created then pcall(uv.fs_unlink, temporary) end
  if not ok then return false, type(result) == 'string' and result or 'Export file operation failed' end
  return true, result
end

return M
