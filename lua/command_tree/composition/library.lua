-- Portable declarations only. Every public method returns value or nil, reason;
-- failed validation, stale reviews and failed writes preserve the active library.
local Core = require('command_environment.core.composition')
local Json = require('command_environment.core.json')
local U = require('command_environment.core.util')
local Store = require('command_tree.state_store')
local Files = require('command_tree.ui_export')
local Identity = require('command_tree.file_identity')
local M = { max_bytes = 65536 }
local Library = {}; Library.__index = Library

local function attempt(fn)
  local ok, value, why = pcall(fn)
  if not ok then return nil, tostring(value) end
  return value, why
end
local function convert(value, host, seen, depth, budget)
  budget.count = budget.count + 1
  assert(depth <= 16 and budget.count <= 8192, 'Command library exceeds nesting or item limits')
  if value == vim.NIL or value == U.null then return host and vim.NIL or U.null end
  if type(value) ~= 'table' then return value end
  local kind, mt = U.kind(value), getmetatable(value)
  assert(kind ~= 'null', 'Command library contains an invalid null marker')
  assert(mt == nil or kind or mt == vim._empty_dict_mt, 'Command library requires plain JSON data')
  assert(not seen[value], 'Command library cannot contain cycles')
  seen[value] = true
  local ambiguous = kind == nil and mt == nil and next(value) == nil
  local array = kind == 'array' or not kind and mt == nil and not ambiguous and U.islist(value)
  local result = ambiguous and {} or array and (host and {} or U.array()) or (host and vim.empty_dict() or U.object())
  for key, child in next, value do result[key] = convert(child, host, seen, depth + 1, budget) end
  seen[value] = nil
  return result
end
local function data(value, host) return convert(value, host, {}, 0, { count = 0 }) end
function M.validate(value)
  return attempt(function()
    local normalized, why = Core.validate(data(value, false))
    assert(normalized, why)
    assert(#Json.encode(normalized) <= M.max_bytes, 'Command library exceeds 64 KiB')
    return normalized
  end)
end
local function live(self)
  local ok, why = self.live()
  assert(ok ~= false, why or 'This command library owner has ended')
end
local function empty() return { version = 1, commands = U.array() } end
local function file_error(reason)
  return tostring(reason):gsub('UI settings', 'Command library'):gsub('Presentation', 'Command library')
end
local function checked(self, value)
  live(self)
  local prepared, why = M.validate(value); assert(prepared, why)
  if self.validate then
    local valid, reason = self.validate(U.clone(prepared)); assert(valid, reason)
    prepared, why = M.validate(valid); assert(prepared, why)
  end
  live(self)
  return prepared
end
local function snapshot(self)
  return { revision = self.revision, library = U.clone(self.library), notice = self.notice,
    persistent = self.path ~= false }
end
local function guard(self, receipt)
  live(self)
  local revision = type(receipt) == 'table' and receipt.revision or receipt
  assert(self.ready and revision == self.revision, 'Command library changed; reopen the command editor')
end
function M.new(options)
  options = options or {}
  assert(options.path == false or type(options.path) == 'string' and options.path ~= '', 'Command library needs a storage path or false')
  return setmetatable({ path = options.path, live = options.live or function() end,
    changed = options.changed, validate = options.validate, protected_paths = options.protected_paths,
    library = empty(), revision = 0, imports = setmetatable({}, { __mode = 'k' }) }, Library)
end
function Library:load()
  return attempt(function()
    live(self)
    if self.ready then return snapshot(self) end
    if self.path ~= false then
      local present = vim.uv.fs_lstat(self.path) ~= nil
      local stored, read_error
      if present then stored, read_error = Files.read(self.path, { limit = M.max_bytes, validate = M.validate })
      else stored = empty() end
      local ok, prepared = pcall(function()
        assert(stored, file_error(read_error))
        local prepared = checked(self, stored)
        self.disk = present and Json.encode(prepared) or 'absent'
        return prepared
      end)
      if ok then self.library = prepared
      else self.notice = 'Saved user commands were refused; built-in commands remain available. ' .. tostring(prepared) end
    end
    live(self); self.ready = true
    return snapshot(self)
  end)
end
function Library:current()
  return attempt(function() live(self); assert(self.ready, 'Command library has not loaded'); return snapshot(self) end)
end
function Library:guard(receipt) return attempt(function() guard(self, receipt); return true end) end
function Library:save(candidate, expected_revision)
  return attempt(function()
    guard(self, expected_revision)
    assert(not self.saving, 'Command library is already saving')
    local prepared = checked(self, candidate)
    guard(self, expected_revision)
    self.saving = true
    local ok, why = true, nil
    if self.path ~= false then
      ok, why = Store.update(self.path, function()
        guard(self, expected_revision)
        local disk = 'absent'
        if vim.uv.fs_lstat(self.path) then
          local normalized, reason = Files.read(self.path, { limit = M.max_bytes, validate = M.validate }); assert(normalized, reason)
          disk = Json.encode(normalized)
        end
        assert(self.disk and disk == self.disk,
          'Saved command library changed outside this editor; reload before saving')
        return data(prepared, true)
      end)
    end
    self.saving = false
    assert(ok, why)
    self.library, self.disk, self.revision, self.notice = prepared, Json.encode(prepared), self.revision + 1, nil
    if self.changed then
      local refreshed, reason = pcall(self.changed, snapshot(self))
      if not refreshed then self.notice = 'Commands saved; command list refresh failed: ' .. tostring(reason) end
    end
    return snapshot(self)
  end)
end
function Library:read(path)
  return attempt(function()
    live(self); assert(self.ready, 'Command library has not loaded')
    local revision = self.revision
    local library, why = Files.read(path, { limit = M.max_bytes, validate = M.validate })
    assert(library, file_error(why))
    library = checked(self, library); guard(self, revision)
    local absolute = vim.fn.fnamemodify(path, ':p')
    local identity = vim.uv.fs_lstat(absolute)
    assert(identity and identity.type == 'file', 'Command import file changed; inspect it again')
    local receipt = { library = U.clone(library), revision = revision, file = absolute }
    self.imports[receipt] = { encoded = Json.encode(library), revision = revision, file = absolute, identity = identity }
    return receipt
  end)
end
function Library:apply_import(receipt)
  return attempt(function()
    guard(self, receipt)
    local owned = self.imports[receipt]
    assert(owned and receipt.file == owned.file and receipt.revision == owned.revision
      and Json.encode(data(receipt.library, false)) == owned.encoded, 'Command import requires its unchanged owned review')
    assert(Identity.same(owned.identity, vim.uv.fs_lstat(owned.file)), 'Command import file changed; inspect it again')
    local current, why = Files.read(owned.file, { limit = M.max_bytes, validate = M.validate })
    assert(current, file_error(why))
    assert(Json.encode(current) == owned.encoded and Identity.same(owned.identity, vim.uv.fs_lstat(owned.file)),
      'Command import file changed; inspect it again')
    local saved, reason = self:save(current, owned.revision); assert(saved, reason)
    self.imports[receipt] = nil
    return saved
  end)
end
function Library:export(path, revision)
  return attempt(function()
    revision = revision == nil and self.revision or revision
    guard(self, revision)
    local protected = self.protected_paths and self.protected_paths() or {}
    protected = vim.list_extend({}, protected)
    if self.path ~= false then protected[#protected + 1] = self.path end
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= '' then protected[#protected + 1] = name end
    end
    -- Reuse the established filename/protected-path and atomic no-clobber I/O.
    local ok, result = Files.export(data(self.library, true), path, protected, function()
      return self:guard(revision)
    end, { limit = M.max_bytes, validate = function()
      -- The active declarations are already validated and privately owned.
      -- Re-decoding host empty tables would lose literal [] versus {}.
      return data(self.library, true)
    end })
    assert(ok, file_error(result))
    return result
  end)
end
return M
