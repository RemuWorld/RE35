local K = require("command_tree.keys")
local M = { records = {}, owned = {}, suspended = false }
local modes, callbacks = { "n", "x" }, setmetatable({}, { __mode = "k" })
local generation, leases = 0, 0

local function canonical(lhs) return table.concat(K.tokens(lhs)) end
local function scope_id(mode, buf) return tostring(buf or 0) .. ":" .. mode end
local function valid(buf) return not buf or vim.api.nvim_buf_is_valid(buf) end
local function maps(mode, buf)
  if not valid(buf) then return {} end
  return buf and vim.api.nvim_buf_get_keymap(buf, mode) or vim.api.nvim_get_keymap(mode)
end
local function lookup(mode, buf, lhs)
  local id = canonical(lhs)
  for _, map in ipairs(maps(mode, buf)) do if canonical(map.lhs) == id then return map end end
end
local function remove(mode, buf, lhs)
  pcall(vim.keymap.del, mode, lhs, buf and { buffer = buf } or {})
end
local function restore(record)
  if not valid(record.buf) or lookup(record.mode, record.buf, record.map.lhs) then return end
  -- mapset retains expression callbacks, script-local RHS, remapping and all
  -- other original mapping flags instead of reconstructing a reduced map.
  local function apply() vim.fn.mapset(record.mode, false, record.map) end
  if record.buf then vim.api.nvim_buf_call(record.buf, apply) else apply() end
end
function M.is_owned(map) return map and type(map.callback) == "function" and callbacks[map.callback] == true or false end
local function release_maps()
  for _, owner in pairs(M.owned) do
    local current = lookup(owner.mode, owner.buf, owner.lhs)
    if current and current.callback == owner.callback then remove(owner.mode, owner.buf, owner.lhs) end
  end
  M.owned = {}
  for _, record in pairs(M.records) do restore(record) end
end
local function eligible(buf)
  return valid(buf) and (not buf or vim.bo[buf].filetype ~= "command-tree")
end
local function claim(mode, buf)
  if not eligible(buf) then return end
  local prefix, scope = canonical(M.opts.open_key), scope_id(mode, buf)
  for _, map in ipairs(maps(mode, buf)) do
    local id = canonical(map.lhs)
    if id:sub(1, #prefix) == prefix and not M.is_owned(map) then
      M.records[scope .. ":" .. id] = { mode = mode, buf = buf, map = map }
      remove(mode, buf, map.lhs)
    end
  end
  local owner = M.owned[scope]
  local current = lookup(mode, buf, M.opts.open_key)
  if owner and current and current.callback == owner.callback then return end
  local token = generation
  local callback = function()
    if token ~= generation or M.suspended or not M.open then return end
    return M.open({ context = K.context(mode), mode = mode })
  end
  callbacks[callback] = true
  vim.keymap.set(mode, M.opts.open_key, callback,
    { buffer = buf, nowait = true, silent = true, desc = "Open Command Environment" })
  M.owned[scope] = { mode = mode, buf = buf, lhs = M.opts.open_key, callback = callback }
end

function M.refresh(buf)
  if not M.opts or M.suspended then return end
  for _, mode in ipairs(modes) do claim(mode); if buf then claim(mode, buf) end end
  for id, record in pairs(M.records) do if not valid(record.buf) then M.records[id] = nil end end
  for id, owner in pairs(M.owned) do if not valid(owner.buf) then M.owned[id] = nil end end
end

-- Overlay originals displaced by the entry boundary onto the native guide.
-- A buffer-local original wins over a global original, just as in Neovim.
function M.list(mode, buf)
  local result = {}
  for _, scope in ipairs({ 0, buf or vim.api.nvim_get_current_buf() }) do
    for _, record in pairs(M.records) do
      if record.mode == mode and (record.buf or 0) == scope then result[canonical(record.map.lhs)] = record.map end
    end
  end
  return result
end

function M.clear()
  generation, leases = generation + 1, 0
  M.opts, M.open, M.suspended = nil, nil, false
  release_maps()
  M.records = {}
end

function M.setup(opts, open)
  assert(type(opts) == "table" and type(opts.open_key) == "string" and opts.open_key ~= "", "Entry requires open_key")
  assert(type(open) == "function", "Entry requires an open callback")
  M.clear()
  M.opts, M.open = opts, open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(buf) then M.refresh(buf) end end
  M.refresh(vim.api.nvim_get_current_buf())
end

-- Native replay must use the actual mapping engine (expr, <Plug>, counts,
-- registers, and visual selections). Temporarily put the originals back.
-- The returned lease is idempotent and cannot revive a later setup instance.
function M.suspend()
  if not M.opts then return function() end end
  local token, released = generation, false
  leases = leases + 1
  if leases == 1 then M.suspended = true; release_maps() end
  return function()
    if released or token ~= generation then return end
    released, leases = true, math.max(0, leases - 1)
    if leases ~= 0 then return end
    -- A mapping may deliberately delete itself while it runs. Do not revive
    -- such a one-shot mapping from the snapshot when the boundary returns.
    for id, record in pairs(M.records) do
      if not lookup(record.mode, record.buf, record.map.lhs) then M.records[id] = nil end
    end
    M.suspended = false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(buf) then M.refresh(buf) end end
  end
end

function M.resume(release) if type(release) == "function" then release() end end
return M
