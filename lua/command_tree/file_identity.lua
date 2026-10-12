-- Older Windows libuv path stats omit the volume ID (dev=0), while fstat
-- supplies it. Never discard file ID, size or timestamp checks for that case.
local M = {}
local old_windows = vim.uv.os_uname().sysname == 'Windows_NT' and vim.fn.has('nvim-0.12') == 0
function M.same(first, second)
  if not first or not second or first.type ~= 'file' or second.type ~= 'file' then return false end
  local device = first.dev == second.dev or old_windows and (first.dev == 0 or second.dev == 0)
  return device and first.ino == second.ino and first.size == second.size
    and first.mtime.sec == second.mtime.sec and first.mtime.nsec == second.mtime.nsec
    and (first.mode == nil or second.mode == nil or first.mode == second.mode)
end
return M
