-- Advisory, host-local observations. Only hashes and bounded observations are
-- persisted; user globals and configuration contents never enter this file.
local M, uv = {}, vim.uv
local MAX_BYTES = 2 * 1024 * 1024
function M.stamp(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return false end
  return { path, stat.size, stat.mtime.sec, stat.mtime.nsec }
end
local function ordered(value)
  if type(value) ~= 'table' then return value end
  local keys, result = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do result[#result + 1] = { key, ordered(value[key]) } end
  return result
end
function M.hash(value) return vim.fn.sha256(vim.json.encode(ordered(value))) end
local function safe(path)
  local current = path
  while current and current ~= '' do
    local stat = uv.fs_lstat(current)
    if stat and (stat.type == 'link' or current == path and (stat.type ~= 'file' or stat.size > MAX_BYTES)
      or current ~= path and stat.type ~= 'directory') then return false end
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return true
end
function M.read(path)
  if not safe(path) then return {} end
  local data = require('command_tree.state_store').read(path)
  if type(data) ~= 'table' or data.version ~= 1 or type(data.entries) ~= 'table' then return {} end
  local result, count = {}, 0
  local function valid_observation(value, appearance)
    return type(value) == 'table' and type(value.supported) == 'boolean'
      and (value.failed == nil or type(value.failed) == 'boolean')
      and (value.transient == nil or type(value.transient) == 'boolean')
      and (value.reason == nil or type(value.reason) == 'string' and #value.reason <= 2048)
      and (value.background == nil or value.background == 'light' or value.background == 'dark')
      and (value.palette == nil or value.palette == 'light' or value.palette == 'dark')
      and (not value.supported or value.background == appearance and value.palette == appearance and not value.failed)
  end
  for name, entry in pairs(data.entries) do
    count = count + 1
    if count > 256 then return {} end
    if type(name) == 'string' and #name <= 128 and type(entry) == 'table'
      and type(entry.key) == 'string' and #entry.key == 64 and type(entry.dependencies) == 'table'
      and #entry.dependencies <= 512 and valid_observation(entry.light, 'light') and valid_observation(entry.dark, 'dark') then
      local valid = true
      for _, dependency in ipairs(entry.dependencies) do
        if type(dependency) ~= 'string' or #dependency > 4096 then valid = false; break end
      end
      if valid then result[name] = entry end
    end
  end
  return result
end
function M.write(path, entries)
  if not safe(path) then return false, 'Theme classification cache path is not a regular local file' end
  local encoded = vim.json.encode({ version = 1, entries = entries })
  if #encoded > MAX_BYTES then return false, 'Theme classification cache exceeds 2 MiB' end
  return require('command_tree.state_store').update(path, function()
    assert(safe(path), 'Theme classification cache path changed')
    return { version = 1, entries = entries }
  end)
end
return M
