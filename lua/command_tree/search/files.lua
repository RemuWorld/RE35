local uv,M=vim.uv,{}
local windows = uv.os_uname().sysname == 'Windows_NT'
local function canonical(path)
  local real = uv.fs_realpath(path)
  if not real then return nil end
  return vim.fs.normalize(real)
end
local function identity(path) return windows and path:lower() or path end
local function inside(path, root)
  path, root = identity(path), identity(root):gsub('/$', '')
  return path == root or path:sub(1, #root + 1) == root .. '/'
end
local same_file = require('command_tree.file_identity').same
local function revision(stat)
  return { size = stat.size, dev = stat.dev, ino = stat.ino, mtime = { sec = stat.mtime.sec, nsec = stat.mtime.nsec }, type = 'file' }
end
function M.validate_location(item)
  if not item.file_revision then return true end
  local stat = type(item.filename) == 'string' and uv.fs_lstat(item.filename)
  local real, root = type(item.filename) == 'string' and canonical(item.filename), item.scan_root
  if not stat or not same_file(item.file_revision, stat) or not real or type(root) ~= 'string'
    or canonical(root) ~= root or not inside(real, root) then
    return false, 'Saved search target changed or disappeared; search the project again'
  end
  local buf = vim.fn.bufnr(item.filename)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return false, 'Saved search target has unsaved changes; save it and search again'
  end
  return true
end
M.canonical,M.inside,M.revision=canonical,inside,revision
M.utf8=require('command_environment.core.json').valid_utf8
-- Source text has already passed UTF-8 validation. Back off at most three
-- continuation bytes instead of rescanning a long line for every match.
function M.excerpt(text,limit)
  assert(type(text)=='string' and type(limit)=='number' and limit>=0
    and limit<math.huge and limit%1==0,'Excerpt requires text and a finite byte limit')
  if #text<=limit then return text end
  local finish=limit
  while finish>0 do
    local next_byte=text:byte(finish+1)
    if next_byte<128 or next_byte>=192 then break end
    finish=finish-1
  end
  return text:sub(1,finish)
end
return M
