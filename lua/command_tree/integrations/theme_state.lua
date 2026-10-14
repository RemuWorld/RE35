-- Host-local editor appearance. This file is never part of a portable profile.
local M = {}
local uv, Store = vim.uv, require('command_tree.state_store')
local MAX_BYTES = 2048

function M.name(value)
  return type(value) == 'string' and #value > 0 and #value <= 128 and value ~= '.' and value ~= '..'
    and not value:find('[%z\1-\32\127/\\:|<>*?\"]')
end

function M.path(value)
  assert(type(value) == 'string' and value ~= '' and not value:find('%z'), 'Theme storage path must be a file path')
  assert(value:match('^[/\\]') or value:match('^%a:[/\\]'), 'Theme storage path must be absolute')
  return vim.fs.normalize(value)
end

local function validate(data)
  if type(data) ~= 'table' or vim.islist(data) then return nil, 'Theme state must be an object' end
  for field in pairs(data) do
    if field ~= 'version' and field ~= 'theme' and field ~= 'background' then
      return nil, 'Unknown theme state field: ' .. tostring(field)
    end
  end
  if data.version ~= 1 then return nil, 'Unsupported theme state version' end
  if not M.name(data.theme) then return nil, 'Invalid saved colorscheme name' end
  if data.background ~= 'dark' and data.background ~= 'light' then return nil, 'Invalid saved background' end
  return { version = 1, theme = data.theme, background = data.background }
end

local function guard(path)
  -- Never follow a saved-file or parent link into unrelated user files.
  local current = path
  while current do
    local stat, reason = uv.fs_lstat(current)
    if stat then
      if stat.type == 'link' then return nil, 'Theme storage uses a symbolic link: ' .. current end
      if current == path then
        if stat.type ~= 'file' then return nil, 'Theme storage is not a regular file' end
        if stat.size > MAX_BYTES then return nil, 'Theme state exceeds 2 KiB; original file was preserved' end
      elseif stat.type ~= 'directory' then return nil, 'Theme storage parent is not a directory' end
    elseif not tostring(reason):find('ENOENT', 1, true) then return nil, tostring(reason) end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current or parent == '' then break end
    current = parent
  end
  return true
end

function M.read(path)
  local safe, reason = guard(path)
  if not safe then return nil, reason end
  local fd, open_error = uv.fs_open(path, 'r', 384)
  if not fd then
    if tostring(open_error):find('ENOENT', 1, true) then return false end
    return nil, tostring(open_error)
  end
  local stat, stat_error = uv.fs_fstat(fd)
  local text, read_error
  if stat and stat.type == 'file' and stat.size <= MAX_BYTES then text, read_error = uv.fs_read(fd, stat.size, 0) end
  uv.fs_close(fd)
  if not text then return nil, tostring(read_error or stat_error or 'Theme state exceeds 2 KiB or is not a regular file') end
  local decoded, data = pcall(vim.json.decode, text)
  if not decoded then return nil, 'Invalid JSON theme state; original file was preserved' end
  return validate(data)
end

function M.write(path, name, background)
  local data, validation_error = validate({ version = 1, theme = name, background = background })
  if not data then return false, validation_error end
  local safe, reason = guard(path)
  if not safe then return false, reason end
  return Store.update(path, function(previous)
    -- Corrupt or future state is not silently replaced by a theme confirmation.
    if uv.fs_lstat(path) then
      local valid, failure = validate(previous)
      assert(valid, failure)
    end
    local still_safe, failure = guard(path)
    assert(still_safe, failure)
    return data
  end)
end

return M
