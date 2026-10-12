-- Persist semantic IDs only. Mutations reread under a short lock so separate
-- Neovim processes keep each other's changes.
local Store = require("command_tree.state_store")
local M, Usage = {}, {}
Usage.__index = Usage

local function ids(value, limit)
  local result, seen = {}, {}
  for _, id in ipairs(type(value) == "table" and value or {}) do
    if type(id) == "string" and id ~= "" and not seen[id] and #result < limit then
      result[#result + 1], seen[id] = id, true
    end
  end
  return result
end

local function check_id(id) assert(type(id) == "string" and id ~= "", "A nonempty command ID is required") end
local function slot_index(index)
  index = tonumber(index)
  assert(index and index % 1 == 0 and index >= 1 and index <= 9, "Slot must be an integer from 1 to 9")
  return index
end
local function slots(value)
  local result = {}
  for index = 1, 9 do
    local id = type(value) == "table" and (value[tostring(index)] or value[index]) or nil
    if type(id) == "string" and id ~= "" then result[index] = id end
  end
  return result
end
local function remove(values, id)
  for index = #values, 1, -1 do if values[index] == id then table.remove(values, index) end end
end
local function normalize(data, maximum)
  local supported, err = Store.check_version(data, 1)
  assert(supported, err)
  data.version, data.recent, data.favorites = 1, ids(data.recent, maximum), ids(data.favorites, math.huge)
  local encoded_slots = vim.empty_dict()
  for index, id in pairs(slots(data.slots)) do encoded_slots[tostring(index)] = id end
  data.slots = encoded_slots
  return data
end

function M.new(opts)
  opts = opts or {}
  local maximum = opts.max_recent == nil and 50 or opts.max_recent
  assert(type(maximum) == "number" and maximum >= 0 and maximum < math.huge, "max_recent must be a finite nonnegative number")
  local path = opts.path
  if path == nil then path = vim.fn.stdpath("state") .. "/command-tree/usage.json" end
  assert(path == false or (type(path) == "string" and path ~= ""), "Usage path must be false or a file path")
  local self = setmetatable({ path = path, max_recent = math.floor(maximum), _recent = {}, _favorites = {},
    _slots = {}, _transient = {}, _pending = {}, max_pending = opts.max_pending or math.max(256, math.floor(maximum) + 32),
    notify = opts.notify ~= false }, Usage)
  assert(type(self.max_pending) == "number" and self.max_pending >= 9 and self.max_pending % 1 == 0,
    "max_pending must be an integer of at least 9")
  local data, err = {}, nil
  if path then data, err = Store.read(path) end
  if data then
    local supported, failure = Store.check_version(data, 1)
    if supported then self:_sync(data) else self.load_error = failure; self:_report(failure) end
  else self.load_error = err; self:_report(err) end
  for index, id in pairs(opts.slots or {}) do
    index = slot_index(index)
    if id ~= false then check_id(id); self._slots[index] = id else self._slots[index] = nil end
    if path then self:_enqueue({ kind = "slot", index = index, id = self._slots[index] }) end
  end
  return self
end

function Usage:_report(err)
  if not err or self._reported_error == err then return end
  self._reported_error = err
  if self.notify then
    vim.schedule(function() vim.notify("Command history was not saved: " .. err, vim.log.levels.WARN, { title = "Command Environment" }) end)
  end
end

function Usage:_sync(data)
  local recent, favorites, saved_slots = ids(data.recent, self.max_recent), ids(data.favorites, math.huge), slots(data.slots)
  if self._profile_save then favorites, saved_slots = {}, {}; favorites = vim.list_slice(self._favorites); saved_slots = vim.deepcopy(self._slots) end
  -- Buffer-scoped IDs remain local. They never enter the shared JSON file.
  for index, id in ipairs(self._recent) do
    if self._transient[id] then table.insert(recent, math.min(index, #recent + 1), id) end
  end
  while #recent > self.max_recent do recent[#recent] = nil end
  if not self._profile_save then
    for _, id in ipairs(self._favorites) do if self._transient[id] then favorites[#favorites + 1] = id end end
  end
  for index, id in pairs(self._slots) do if self._transient[id] then saved_slots[index] = id end end
  self._recent, self._favorites, self._slots = recent, favorites, saved_slots
end

function Usage:_save()
  if not self.path or #self._pending == 0 then return true end
  local ok, err, data = Store.update(self.path, function(current)
    current = normalize(current, self.max_recent)
    for _, operation in ipairs(self._pending) do
      if operation.kind == "record" then
        remove(current.recent, operation.id)
        table.insert(current.recent, 1, operation.id)
        while #current.recent > self.max_recent do current.recent[#current.recent] = nil end
      elseif operation.kind == "favorite" then
        remove(current.favorites, operation.id)
        if operation.enabled then current.favorites[#current.favorites + 1] = operation.id end
      elseif operation.kind == "slot" then current.slots[tostring(operation.index)] = operation.id end
    end
    return current
  end)
  self.save_error = err
  if ok then
    self._pending, self.load_error, self._reported_error = {}, nil, nil
    self:_sync(data)
  else self:_report(err) end
  return ok, err
end

-- Keep only the latest intent for each ID/slot. Older record operations beyond
-- the recent-list limit can never affect the eventual durable result.
function Usage:_enqueue(operation)
  local pending = vim.deepcopy(self._pending)
  for index = #pending, 1, -1 do
    local old = pending[index]
    if old.kind == operation.kind and ((old.kind == "slot" and old.index == operation.index)
      or (old.kind ~= "slot" and old.id == operation.id)) then table.remove(pending, index) end
  end
  pending[#pending + 1] = operation
  local records = 0
  for index = #pending, 1, -1 do
    if pending[index].kind == "record" then
      records = records + 1
      if records > math.min(self.max_recent, self.max_pending - 9) then table.remove(pending, index) end
    end
  end
  if #pending > self.max_pending then
    local err = "Unsaved changes reached the queue limit; restore storage and retry before adding more favorites"
    self.save_error = err
    self:_report(err)
    return false, err
  end
  self._pending = pending
  return true
end

function Usage:flush() return self:_save() end
function Usage:pending_count() return #self._pending end

function Usage:record(id, persistent)
  check_id(id)
  if persistent == false then self._transient[id] = true end
  if self.path and not self._transient[id] then
    local ok, err = self:_enqueue({ kind = "record", id = id })
    if not ok then return false, err end
  end
  remove(self._recent, id)
  table.insert(self._recent, 1, id)
  while #self._recent > self.max_recent do self._recent[#self._recent] = nil end
  return self:_save()
end

function Usage:toggle(id, persistent)
  check_id(id)
  if persistent == false then self._transient[id] = true end
  local enabled = not vim.tbl_contains(self._favorites, id)
  if self._profile_save then
    local next_values = vim.list_slice(self._favorites)
    remove(next_values, id)
    if enabled then next_values[#next_values + 1] = id end
    local durable = vim.tbl_filter(function(value) return not self._transient[value] end, next_values)
    if self._transient[id] then self._favorites = next_values; return enabled end
    local ok, err, saved = self._profile_save("favorites", durable, { id = id, enabled = enabled })
    if not ok then return not enabled, err end
    self._favorites = saved or next_values
    if saved then for _, value in ipairs(next_values) do if self._transient[value] then self._favorites[#self._favorites + 1] = value end end end
    return enabled
  end
  if self.path and not self._transient[id] then
    local ok, err = self:_enqueue({ kind = "favorite", id = id, enabled = enabled })
    if not ok then return not enabled, err end
  end
  remove(self._favorites, id)
  if enabled then self._favorites[#self._favorites + 1] = id end
  local _, err = self:_save()
  return enabled, err
end

function Usage:slot(index) return self._slots[slot_index(index)] end
function Usage:set_slot(index, id, persistent)
  index = slot_index(index)
  if id ~= nil then check_id(id) end
  if id and persistent == false then self._transient[id] = true end
  if self._profile_save then
    local next_slots, encoded = vim.deepcopy(self._slots), vim.empty_dict()
    next_slots[index] = id
    for key, value in pairs(next_slots) do if not self._transient[value] then encoded[tostring(key)] = value end end
    local ok, err, saved = self._profile_save("slots", encoded, { slot = index, id = encoded[tostring(index)] })
    if ok then
      self._slots = saved and slots(saved) or next_slots
      for key, value in pairs(next_slots) do if self._transient[value] then self._slots[key] = value end end
    end
    return ok, err
  end
  if self.path then
    -- Replacing a saved slot with a buffer-local ID clears its durable value.
    local stored_id = id
    if id and self._transient[id] then stored_id = nil end
    local ok, err = self:_enqueue({ kind = "slot", index = index, id = stored_id })
    if not ok then return false, err end
  end
  self._slots[index] = id
  return self:_save()
end

function Usage:slots() return vim.deepcopy(self._slots) end
function Usage:attach_profile(profile, save)
  self._favorites, self._slots = ids(profile.favorites, math.huge), slots(profile.slots)
  self._profile_save = save
end
function Usage:recent() return vim.list_slice(self._recent) end
function Usage:favorites() return vim.list_slice(self._favorites) end

return M
