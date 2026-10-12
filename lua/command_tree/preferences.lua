local Store = require("command_tree.state_store")
local M, Preferences = {}, {}
Preferences.__index = Preferences

function M.new(opts)
  opts = opts or {}
  local path = opts.path
  if path == nil then path = vim.fn.stdpath("state") .. "/command-tree/preferences.json" end
  assert(path == false or (type(path) == "string" and path ~= ""), "Preferences path must be false or a file path")
  local data, err = {}, nil
  if path then data, err = Store.read(path) end
  if data then
    local supported, failure = Store.check_version(data, 1)
    if not supported then data, err = nil, failure end
  end
  return setmetatable({ path = path, data = data or {}, overrides = {}, _pending = {}, load_error = err }, Preferences)
end

function Preferences:get(key, fallback)
  if self.profile_values and self.profile_values[key] ~= nil then return self.profile_values[key] end
  return self:inherited(key, fallback)
end

function Preferences:inherited(key, fallback)
  if self._pending[key] then
    local value = self._pending[key].value
    if value == nil then return fallback end
    return value
  end
  if self.overrides[key] ~= nil then return self.overrides[key] end
  local values = type(self.data.values) == "table" and self.data.values or {}
  if key == "density" and values[key] ~= nil and not vim.tbl_contains({ "full", "compact", "minimal" }, values[key]) then return fallback end
  if values[key] == nil then return fallback end
  return values[key]
end

function Preferences:flush()
  if not next(self._pending) then return true end
  local function mutate(data)
    local supported, err = Store.check_version(data, 1)
    assert(supported, err)
    data.version = 1
    if type(data.values) ~= "table" then data.values = {} end
    for key, entry in pairs(self._pending) do data.values[key] = entry.value end
    return data
  end
  if not self.path then self.data = mutate(self.data); self._pending, self.overrides = {}, {}; return true end
  local ok, err, data = Store.update(self.path, mutate)
  self.save_error = err
  if ok then self.data, self.load_error, self.overrides, self._pending = data, nil, {}, {} end
  return ok, err
end

function Preferences:set(key, value)
  assert(type(key) == "string" and key ~= "", "Preference key must be a nonempty string")
  if key == "density" and value ~= nil and not vim.tbl_contains({ "full", "compact", "minimal" }, value) then
    return false, "Unknown UI density: " .. tostring(value)
  end
  if self.profile_save then
    local values = vim.deepcopy(self.profile_values)
    values[key] = value
    local ok, err, saved = self.profile_save(values, { key = key, value = value })
    if ok then self.profile_values = saved or values end
    self.save_error = err
    return ok, err
  end
  if not self._pending[key] and vim.tbl_count(self._pending) >= 256 then
    self.save_error = "Unsaved preferences reached the queue limit; restore storage and retry"
    return false, self.save_error
  end
  self._pending[key], self.overrides[key] = { value = value }, value
  return self:flush()
end

function Preferences:pending_count() return vim.tbl_count(self._pending) end
function Preferences:attach_profile(values, save)
  self.profile_values, self.profile_save = vim.deepcopy(values), save
end

return M
