-- Applied UI snapshots only. No profile, theme, executable or history data.
local M, uv = {}, vim.uv
local Export = require('command_tree.host.export_file')
local Identity = require('command_tree.file_identity')
local Json, Data = require('command_environment.core.json'), require('command_environment.core.util')
local LIMIT = 4096
local keys = { 'density', 'icons', 'width', 'max_width', 'max_height', 'position', 'compact_rows', 'minimal_rows' }
local allowed = {}
for _, key in ipairs(keys) do allowed[key] = true end
local densities = { full = true, compact = true, minimal = true }
local positions = { center = true, bottom = true, ['bottom-right'] = true, top = true, ['top-right'] = true }
local windows = uv.os_uname().sysname == 'Windows_NT'

local function plain(value)
  return type(value) == 'table' and (getmetatable(value) == nil or getmetatable(value) == vim._empty_dict_mt
    or Data.kind(value) == 'object')
end
function M.validate(data)
  if not plain(data) then return nil, 'UI settings must be plain JSON data' end
  for key in next, data do
    if key ~= 'format' and key ~= 'version' and key ~= 'host' and key ~= 'ui' then return nil, 'Unknown UI settings field' end
  end
  if rawget(data, 'format') ~= 're35.ui-settings' or rawget(data, 'version') ~= 1 or rawget(data, 'host') ~= 'neovim' then
    return nil, 'Unsupported UI settings format, version or host'
  end
  local source = rawget(data, 'ui')
  if not plain(source) then return nil, 'UI values must be plain JSON data' end
  for key in next, source do if not allowed[key] then return nil, 'Unknown UI setting' end end
  local ui = {}
  for _, key in ipairs(keys) do
    local value = rawget(source, key)
    if key == 'density' then
      if type(value) ~= 'string' or not densities[value] then return nil, 'Choose a supported UI density' end
    elseif key == 'position' then
      if type(value) ~= 'string' or not positions[value] then return nil, 'Choose a supported UI position' end
    elseif key == 'icons' then
      if type(value) ~= 'boolean' then return nil, 'UI icons must be boolean' end
    elseif type(value) ~= 'number' or value ~= value or value < 1 or value > 65535 or value % 1 ~= 0 then
      return nil, 'UI ' .. key .. ' must be an integer from 1 to 65535'
    end
    ui[key] = value
  end
  return { format = 're35.ui-settings', version = 1, host = 'neovim', ui = ui }
end
function M.capture(window, density)
  if type(window) ~= 'table' then return nil, 'Applied UI settings are unavailable' end
  local ui = {}
  for _, key in ipairs(keys) do ui[key] = rawget(window, key) end
  ui.density = density
  ui.compact_rows, ui.minimal_rows = ui.compact_rows or 6, ui.minimal_rows or 3
  return M.validate({ format = 're35.ui-settings', version = 1, host = 'neovim', ui = ui })
end
local function identity(path)
  if type(path) ~= 'string' or path == '' then return nil end
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local parent = uv.fs_realpath(vim.fs.dirname(absolute))
  local real = parent and vim.fs.normalize(parent):gsub('/+$', '') .. '/' .. vim.fs.basename(absolute) or absolute
  return windows and real:lower() or real
end
function M.protected(path, paths)
  local target = identity(path)
  for _, value in ipairs(paths or {}) do
    if identity(value) == target then return true end
  end
  return false
end
local function filename(path)
  if type(path) ~= 'string' or path == '' or #path > 4096 or path:find('[%z\1-\31\127]') or not Json.valid_utf8(path) then
    return false, 'Choose a valid UI settings .json file'
  end
  local leaf = path:gsub('\\', '/'):match('([^/]+)$')
  if not leaf or not leaf:lower():match('%.json$') then return false, 'UI settings require a .json filename' end
  if windows then
    local stem = leaf:match('^([^.]*)'):upper():gsub(' +$', '')
    if leaf:find('[:*?"<>|]') or leaf:match('[ .]$') or stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL'
      or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$') then return false, 'Choose a valid Windows JSON filename' end
  end
  return true
end
function M.read(path, codec)
  local limit = codec and codec.limit or LIMIT
  local validator = codec and codec.validate or M.validate
  assert(type(limit) == 'number' and limit >= 1 and limit <= 65536, 'Invalid data file limit')
  local valid, reason = filename(path)
  if not valid then return nil, reason end
  local fd
  local ok, value, why = pcall(function()
    local absolute = vim.fn.fnamemodify(path, ':p')
    local before = uv.fs_lstat(absolute)
    if not before or before.type ~= 'file' then return nil, 'UI settings must be an existing regular file, without a symbolic link' end
    if before.size > limit then return nil, codec and 'Presentation file exceeds 64 KiB' or 'UI settings exceed 4 KiB' end
    -- Nonblocking open prevents a substituted Unix FIFO from hanging. Optional
    -- no-follow adds a symlink guard; fstat/lstat identity checks remain required.
    local constants = uv.constants or {}
    if not windows and type(constants.O_NONBLOCK) ~= 'number' then return nil, 'Safe UI settings reads are unavailable in this runtime' end
    local flags = (constants.O_RDONLY or 0) + (constants.O_NONBLOCK or 0) + (constants.O_NOFOLLOW or 0)
    fd = uv.fs_open(absolute, flags, 0)
    if not fd then return nil, 'Could not open the UI settings file' end
    local opened = uv.fs_fstat(fd)
    if not Identity.same(before, opened) then return nil, 'UI settings file changed before reading; choose it again' end
    local text = uv.fs_read(fd, limit + 1, 0)
    local after, current = uv.fs_fstat(fd), uv.fs_lstat(absolute)
    if not text or #text ~= before.size or not Identity.same(opened, after) or not Identity.same(after, current) then
      return nil, 'UI settings file changed or could not be fully read; choose it again'
    end
    local closed = uv.fs_close(fd)
    if not closed then return nil, 'Could not close the UI settings file' end
    fd = nil
    local decoded, data = pcall(Json.decode, text)
    if not decoded then return nil, 'UI settings must contain valid UTF-8 JSON without duplicate fields or trailing data' end
    return validator(data)
  end)
  if fd then pcall(uv.fs_close, fd) end
  if not ok then return nil, 'Could not read the UI settings file' end
  return value, why
end
function M.export(data, path, protected, validate, codec)
  local limit = codec and codec.limit or LIMIT
  local validator = codec and codec.validate or M.validate
  assert(type(limit) == 'number' and limit >= 1 and limit <= 65536, 'Invalid data file limit')
  local value, err = validator(data)
  if not value then return false, err end
  local valid, why = filename(path)
  if not valid then return false, why end
  local target, reason = Export.destination(path)
  if not target then return false, reason end
  if M.protected(target.path, protected) then return false, 'Choose a new file outside RE35 storage and named source buffers' end
  local encoded = vim.json.encode(value) .. '\n'
  if #encoded > limit then return false, codec and 'Presentation export exceeds 64 KiB' or 'UI export exceeds 4 KiB' end
  return Export.publish(path, target, encoded, validate)
end
return M
