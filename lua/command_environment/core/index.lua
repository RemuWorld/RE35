-- Portable Command Index v1. No execution, host callbacks, or key parser.
-- Semantic commands and their locations are independent. Nodes only reference IDs.
local U = require("command_environment.core.util")
local M, Registry = {}, {}
Registry.__index = Registry

local function nonempty(value, label)
  assert(type(value) == "string" and value ~= "", label .. " must be a nonempty string")
  return value
end

local function array(value, label)
  assert(type(value) == "table", label .. " must be an array")
  local count = 0
  for key in pairs(value) do
    assert(type(key) == "number" and key >= 1 and key % 1 == 0, label .. " must be an array")
    count = count + 1
  end
  for index = 1, count do assert(value[index] ~= nil, label .. " cannot contain gaps") end
end

local function tokens(path)
  U.assert_array(path, "Normalized path")
  local result = {}
  for _, token in ipairs(path) do
    nonempty(token, "Path segment")
    assert(not token:find("\0", 1, true), "Normalized tokens cannot contain NUL")
    result[#result + 1] = token
  end
  return result
end

local function path_key(path) return table.concat(path, "\0") end
local function reserved_allows(rule, id, command)
  if rule == nil or rule == false then return true end
  if type(rule) == "string" then return id == rule end
  if type(rule) == "table" then
    return (rule.id ~= nil and id == rule.id)
      or (rule.session_action ~= nil and command and command.session_action == rule.session_action) or false
  end
  return false
end

local function validate_path(self, parts, id, command, reserved)
  reserved = reserved or self._reserved
  for index, key in ipairs(parts) do
    local rules = { reserved.global[key] }
    if index == 1 then rules[#rules + 1] = reserved.root[key] end
    -- Do not use ipairs: a missing global rule may precede a root-only rule.
    for _, rule in pairs(rules) do
      assert(rule == false or (index == #parts and reserved_allows(rule, id, command)),
        "Command path uses reserved session key " .. key .. ": " .. table.concat(parts))
    end
  end
end
local function sorted_keys(t)
  local result = {}
  for key in pairs(t) do result[#result + 1] = key end
  table.sort(result)
  return result
end

local function command_ids(self)
  if self._command_ids_generation ~= self.generation then
    self._command_ids, self._command_ids_generation = sorted_keys(self._commands), self.generation
  end
  return self._command_ids
end

local function locate(self, path, create)
  local node = self.root
  for _, key in ipairs(path) do
    if not node.children[key] then
      if not create then return nil end
      node.children[key] = { children = {} }
    end
    node = node.children[key]
  end
  return node
end

local function prune(self, node, path)
  for key, child in pairs(node.children) do
    path[#path + 1] = key
    prune(self, child, path)
    if not child.command_id and not next(child.children) and not self._groups[path_key(path)] then
      node.children[key] = nil
    end
    path[#path] = nil
  end
end

local function changed(self) self.generation = self.generation + 1 end

local function index_command(self, command)
  local fields = { command.id:lower(), command.name:lower() }
  for _, alias in ipairs(command.aliases or {}) do fields[#fields + 1] = alias:lower() end
  fields[#fields + 1] = (command.description or ""):lower()
  self._search[command.id] = fields
end

local function detach_alias(self, alias)
  local owner = self._commands[self._aliases[alias]]
  self._aliases[alias] = nil
  if not owner then return end
  for index = #(owner.aliases or {}), 1, -1 do
    if owner.aliases[index] == alias then table.remove(owner.aliases, index) end
  end
  index_command(self, owner)
end

function M.new(opts)
  opts = opts and U.clone(opts) or nil
  local self = setmetatable({ root = { name = "Commands", children = {} }, generation = 0,
    _commands = {}, _aliases = {}, _groups = {}, _search = {}, _placements = {}, _reserved = { global = {}, root = {} } }, Registry)
  if opts and opts.reserved then self:set_reserved(opts.reserved) end
  return self
end

function Registry:set_reserved(config)
  assert(type(config) == "table", "Reserved keys must be a table")
  config = U.clone(config)
  local prepared = { global = {}, root = {} }
  for _, scope in ipairs({ "global", "root" }) do
    assert(config[scope] == nil or type(config[scope]) == "table", "Reserved " .. scope .. " keys must be a map")
    for key, rule in pairs(config[scope] or {}) do
      local parts = tokens({ key })
      assert(#parts == 1, "Reserved key must be a single key: " .. tostring(key))
      assert(type(rule) == "boolean" or type(rule) == "string" or type(rule) == "table", "Invalid reserved key rule")
      if type(rule) == "string" then nonempty(rule, "Allowed command ID") end
      if type(rule) == "table" then
        assert(rule.id ~= nil or rule.session_action ~= nil, "Reserved key exception needs id or session_action")
        if rule.id ~= nil then nonempty(rule.id, "Allowed command ID") end
        if rule.session_action ~= nil then nonempty(rule.session_action, "Allowed session action") end
      end
      assert(prepared[scope][parts[1]] == nil or U.deep_equal(prepared[scope][parts[1]], rule), "Conflicting reserved key aliases")
      prepared[scope][parts[1]] = U.clone(rule)
    end
  end
  -- Validate the complete existing layout before replacing the policy.
  for id, placements in pairs(self._placements) do
    for _, path in pairs(placements) do validate_path(self, path, id, self._commands[id], prepared) end
  end
  for key in pairs(self._groups) do
    local path = key == "" and {} or U.split(key, "\0", { plain = true })
    local node = locate(self, path, false)
    validate_path(self, path, node and node.command_id, node and self:_get(node.command_id), prepared)
  end
  if not U.deep_equal(self._reserved, prepared) then self._reserved = prepared; changed(self) end
  return self
end

function Registry:_get(id)
  if self._commands[id] then return self._commands[id] end
  local override = self._profile_aliases and self._profile_aliases[id]
  if override == false then return self._commands[id] end
  return self._commands[override or self._aliases[id] or id]
end

-- Returned command descriptors are data snapshots, never execution callbacks.
function Registry:get(id)
  return U.clone(self:_get(id))
end

-- Host descriptors keep callbacks outside this data model. A scalar alias
-- lookup lets a host retain descriptor identity and update a former alias
-- owner's presentation without depending on private model maps. Profile
-- overrides are optional: false explicitly suppresses a configured alias.
function Registry:alias_owner(alias, configured)
  if configured and self._profile_aliases and self._profile_aliases[alias] ~= nil then
    return self._profile_aliases[alias]
  end
  return self._aliases[alias]
end

-- Profile aliases survive provider refresh and can reference a missing adapter.
function Registry:configure(layout)
  layout = U.clone(layout or {})
  local aliases = U.clone(layout.aliases or {})
  for alias, id in pairs(aliases) do
    assert(not self._commands[alias] or alias == id or id == false, "Alias conflicts with command ID: " .. alias)
    assert(not next(self._placements[alias] or {}) or alias == id or id == false, "Alias conflicts with deferred command ID: " .. alias)
  end
  self._profile_aliases, self._hidden, self._word_paths = aliases, U.clone(layout.hidden or {}), U.clone(layout.word_paths or {})
  changed(self)
end

function Registry:hidden(id)
  if self._hidden and self._hidden[id] ~= nil then return self._hidden[id] == true end
  return self._commands[id] ~= nil and self._commands[id].hidden == true
end

function Registry:resolve_word(query)
  assert(query == nil or type(query) == "string", "Word query must be text")
  query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  local id = (self._word_paths or {})[query]
  if id == false then return nil end
  return U.clone(self:_get(id or query))
end

function Registry:words(query)
  assert(query == nil or type(query) == "string", "Word query must be text")
  local result, seen = {}, {}
  query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local paths = U.extend({}, self._aliases, self._profile_aliases or {}, self._word_paths or {})
  for id in pairs(self._commands) do if paths[id] == nil then paths[id] = id end end
  for _, phrase in ipairs(sorted_keys(paths)) do
    local id = paths[phrase]
    if id and not self:hidden(id) and phrase:lower():find(query, 1, true) then
      local command = self:_get(id)
      result[#result + 1] = { id = id, command = U.clone(command or { id = id, name = id, type = "unavailable" }),
        word_path = phrase, paths = self:paths(id) }
      seen[phrase] = true
    end
  end
  return result
end

function Registry:node(path) return locate(self, tokens(path or {}), false) end

function Registry:bind(path, id, opts)
  opts = opts and U.clone(opts) or nil
  nonempty(id, "Command ID")
  local command, parts = self:_get(id), tokens(path)
  id = command and command.id or id
  assert(#parts > 0, "A command path cannot be empty")
  validate_path(self, parts, id, command)
  local node = locate(self, parts, false)
  assert(not node or not node.command_id or node.command_id == id or (opts and opts.replace),
    "Command path is already bound: " .. table.concat(parts))
  node = node or locate(self, parts, true)
  if node.command_id ~= id then
    local key = path_key(parts)
    if node.command_id then self._placements[node.command_id][key] = nil end
    self._placements[id] = self._placements[id] or {}
    self._placements[id][key] = U.list_copy(parts)
    node.command_id = id
    changed(self)
  end
  return node
end

function Registry:unbind(path)
  local parts = tokens(path)
  local node = locate(self, parts, false)
  if not node or not node.command_id then return false end
  self._placements[node.command_id][path_key(parts)] = nil
  node.command_id = nil
  prune(self, self.root, {})
  changed(self)
  return true
end

function Registry:group(path, spec)
  assert(type(spec) == "table", "Group metadata must be a table")
  spec = U.clone(spec)
  local parts = tokens(path)
  local prior = locate(self, parts, false)
  validate_path(self, parts, prior and prior.command_id, prior and self:_get(prior.command_id))
  local key, existing = path_key(parts), self._groups[path_key(parts)]
  if existing and not spec.replace then
    assert((spec.name == nil or spec.name == existing.name) and (spec.icon == nil or spec.icon == existing.icon)
      and (spec.provider == nil or spec.provider == existing.provider), "Group metadata already exists: " .. table.concat(parts))
  end
  local metadata = { name = spec.name, icon = spec.icon, provider = spec.provider }
  if existing and not spec.replace then metadata = U.extend(existing, metadata) end
  local node = locate(self, parts, true)
  node.name, node.icon = metadata.name, metadata.icon
  self._groups[key] = metadata
  if not existing or not U.deep_equal(existing, metadata) then changed(self) end
  return node
end

-- Private host bridge: the model still validates/copies the caller's input,
-- but a facade which discards metadata need not allocate a return snapshot.
local function register(self, spec, owned)
  assert(type(spec) == "table", "Command metadata must be a table")
  spec = owned and spec or U.clone(spec)
  local id = nonempty(spec.id, "Command ID")
  local replace = spec.replace
  assert(not self._commands[id] or spec.replace, "Command ID already exists: " .. id)
  assert(not self._aliases[id] or self._aliases[id] == id or spec.replace, "Command ID conflicts with alias: " .. id)
  assert(spec.run == nil and spec.preview == nil and spec.available == nil, "Execution behaviors belong to the host, not the Command Index")
  local command = spec
  if command.type ~= nil then nonempty(command.type, "Command type") end
  assert(command.hidden == nil or type(command.hidden) == "boolean", "Command hidden must be a boolean")
  command.name = command.name or id
  nonempty(command.name, "Command name")
  assert(command.description == nil or type(command.description) == "string", "Command description must be a string")
  if spec.aliases ~= nil then array(spec.aliases, "Command aliases") end
  local seen = {}
  for _, alias in ipairs(spec.aliases or {}) do
    nonempty(alias, "Alias")
    assert(not seen[alias], "Duplicate alias: " .. alias)
    assert(not self._commands[alias] or alias == id, "Alias conflicts with command ID: " .. alias)
    assert(alias == id or not next(self._placements[alias] or {}), "Alias conflicts with a deferred command ID: " .. alias)
    assert(not self._aliases[alias] or self._aliases[alias] == id or spec.replace, "Alias already exists: " .. alias)
    seen[alias] = true
  end
  local parts = spec.path ~= nil and tokens(spec.path) or nil
  if parts then
    assert(#parts > 0, "A command path cannot be empty")
    validate_path(self, parts, id, spec)
    local node = locate(self, parts, false)
    assert(not node or not node.command_id or node.command_id == id or spec.replace,
      "Command path is already bound: " .. table.concat(parts))
  end
  for _, path in pairs(self._placements[id] or {}) do validate_path(self, path, id, spec) end
  command.path, command.replace = nil, nil
  if self._aliases[id] and self._aliases[id] ~= id then detach_alias(self, id) end
  for alias in pairs(seen) do
    if self._aliases[alias] and self._aliases[alias] ~= id then detach_alias(self, alias) end
  end
  for alias, owner in pairs(self._aliases) do if owner == id then self._aliases[alias] = nil end end
  self._commands[id] = command
  for alias in pairs(seen) do self._aliases[alias] = id end
  index_command(self, command)
  changed(self)
  if parts then self:bind(parts, id, { replace = replace }) end
  return command
end

function Registry:_register(spec)
  return register(self, spec, false)
end

-- Only the Neovim facade uses this private adoption path after its data
-- projection has already validated and copied the complete metadata graph.
function Registry:_register_owned(spec)
  return register(self, spec, true)
end

function Registry:register(spec)
  return U.clone(self:_register(spec))
end

function Registry:unregister(id)
  local command = self:_get(id)
  if not command then return false end
  id = command.id
  self._commands[id], self._search[id] = nil, nil
  for alias, owner in pairs(self._aliases) do if owner == id then self._aliases[alias] = nil end end
  -- Layout belongs to the user, even while a provider is absent or refreshing.
  -- Explicit unbind() is the operation that removes a placement.
  changed(self)
  return true
end

function Registry:list()
  local result = {}
  for _, id in ipairs(sorted_keys(self._commands)) do result[#result + 1] = U.clone(self._commands[id]) end
  return result
end

-- Availability is a host concern; index discovery never executes a predicate.

function Registry:paths(id)
  local command = self:_get(id)
  local result, placements = {}, self._placements[command and command.id or id]
  if not placements or not next(placements) then return result end
  for _, key in ipairs(sorted_keys(placements)) do result[#result + 1] = U.list_copy(placements[key]) end
  return result
end

function Registry:unresolved()
  local result = {}
  for _, id in ipairs(sorted_keys(self._placements)) do
    if not self._commands[id] and next(self._placements[id]) then
      result[#result + 1] = { id = id, paths = self:paths(id) }
    end
  end
  return result
end

local function match_score(field, query)
  if field == query then return 1000 end
  local start = field:find(query, 1, true)
  if start then return 700 - start * 2 - (#field - #query) end
  local position, first, last = 1, nil, 0
  for index = 1, #query do
    local at = field:find(query:sub(index, index), position, true)
    if not at then return nil end
    first, last, position = first or at, at, at + 1
  end
  return 400 - (last - first + 1 - #query) * 4 - first - (#field - #query)
end

-- Private candidates own their rows/paths; command references remain internal.
-- Public discovery below snapshots these rows before handing them to callers.
function Registry:_search_candidates(query, opts)
  assert(query == nil or type(query) == "string", "Search query must be text")
  opts = U.clone(opts or {})
  query = tostring(query or ""):lower()
  local words, ids, ranks = {}, {}, {}
  for word in query:gmatch("%S+") do words[#words + 1] = word end
  if opts.ids then
    for _, id in ipairs(opts.ids) do
      local command = self:_get(id)
      if command and not ranks[command.id] then
        ids[#ids + 1], ranks[command.id] = command.id, #ids + 1
      end
    end
  else ids = command_ids(self) end
  local result = {}
  for _, id in ipairs(ids) do
    local total, matches = 0, true
    for _, word in ipairs(words) do
      local best
      for index, field in ipairs(self._search[id]) do
        local score = match_score(field, word)
        if score then
          score = score + (index <= 2 and 20 or 0)
          best = best and math.max(best, score) or score
        end
      end
      if not best then matches = false; break end
      total = total + best
    end
    if matches and not self:hidden(id) then
      -- Curated operations lead discovery. Explicit Ex names/IDs still win
      -- over weaker fuzzy matches, and recent/favorite order remains intact.
      if not opts.ids then
        local command = self._commands[id]
        total = total + (command.source == "ex_builtin" and -30 or command.provider == "ex" and -10 or 20)
      end
      local item = { id = id, command = self._commands[id], paths = self:paths(id), score = total }
      result[#result + 1] = item
    end
  end
  return result, ranks
end

local function snapshot_candidates(result)
  local snapshots = {}
  for index, item in ipairs(result) do snapshots[index] = U.clone(item) end
  return snapshots
end

function Registry:search_candidates(query, opts)
  local candidates, ranks = self:_search_candidates(query, opts)
  return snapshot_candidates(candidates), ranks
end

-- Host discovery needs identities, scores and placements before it evaluates
-- capabilities. These rows and path lists are newly owned by the caller;
-- descriptors are omitted so a large catalog is not copied before limiting.
function Registry:search_rows(query, opts)
  local rows, ranks = self:_search_candidates(query, opts)
  for _, row in ipairs(rows) do row.command = nil end
  return rows, ranks
end

-- Host facades can filter candidates before sorting/limiting without changing
-- availability-predicate order or passing execution callbacks into the model.
function M._finish_search(result, opts, ranks)
  opts, ranks = opts or {}, ranks or {}
  table.sort(result, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if opts.ids and ranks[a.id] ~= ranks[b.id] then return ranks[a.id] < ranks[b.id] end
    return a.id < b.id
  end)
  if opts.limit then
    local limit = math.max(0, math.floor(opts.limit))
    while #result > limit do result[#result] = nil end
  end
  return result
end

function M.finish_search(result, opts, ranks)
  result, opts, ranks = U.clone(result), U.clone(opts or {}), U.clone(ranks or {})
  U.assert_array(result, "Search candidates")
  return M._finish_search(result, opts, ranks)
end

-- Unlike finish_search snapshots, this explicitly sorts and limits rows owned
-- by its caller. No model tables are returned, and host availability metadata
-- is preserved without a whole-catalog clone/depth budget.
function M.finish_search_rows(rows, opts, ranks)
  U.assert_array(rows, 'Search rows')
  for _, row in ipairs(rows) do
    assert(type(row) == 'table' and (getmetatable(row) == nil or U.kind(row) == 'object'), 'Search rows must be plain objects')
    assert(type(row.id) == 'string' and type(row.score) == 'number' and row.score == row.score and math.abs(row.score) < math.huge,
      'Search rows need a command ID and finite score')
  end
  return M._finish_search(rows, U.clone(opts or {}), U.clone(ranks or {}))
end

function Registry:search(query, opts)
  local candidates, ranks = self:_search_candidates(query, opts)
  -- _search_candidates validated options before any indexing; the finish step
  -- touches only owned rows, then only visible results need public snapshots.
  return snapshot_candidates(M._finish_search(candidates, opts, ranks))
end

function Registry:remove_provider(provider)
  nonempty(provider, "Provider name")
  local ids = {}
  for id, command in pairs(self._commands) do if command.provider == provider then ids[#ids + 1] = id end end
  for _, id in ipairs(ids) do self:unregister(id) end
  self:remove_groups(provider)
  return #ids
end

function Registry:remove_groups(provider)
  nonempty(provider, "Provider name")
  local removed_group = false
  local function visit(node, path)
    local key = path_key(path)
    if self._groups[key] and self._groups[key].provider == provider then
      self._groups[key], node.name, node.icon = nil, nil, nil
      removed_group = true
    end
    for child_key, child in pairs(node.children) do
      path[#path + 1] = child_key; visit(child, path); path[#path] = nil
    end
  end
  visit(self.root, {})
  if removed_group then prune(self, self.root, {}); changed(self) end
  return removed_group
end

return M
