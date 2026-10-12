-- Neovim compatibility facade: behaviors stay here; data indexing is portable.
local K = require("command_tree.keys")
local Index = require("command_environment.core.index")
local U = require("command_environment.core.util")
local M, Registry = {}, {}
Registry.__index = function(self, key)
  if Registry[key] ~= nil then return Registry[key] end
  -- Supported compatibility observations, rather than an arbitrary proxy of
  -- every private model table and method. Mutations go through this facade.
  if key == 'generation' or key == 'root' then return self._index[key] end
end

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
  if type(path) == "string" then return K.tokens(path) end
  array(path, "Path")
  local result = {}
  for _, key in ipairs(path) do
    nonempty(key, "Path segment")
    local parts = K.tokens(key)
    assert(#parts == 1, "Each path segment must contain exactly one key: " .. key)
    result[#result + 1] = parts[1]
  end
  return result
end
-- vim.empty_dict() is the one known editor data marker accepted at this boundary.
-- It becomes ordinary dictionary data; foreign metatables never enter the model.
local function data(value, seen, depth, budget)
  depth, budget = depth or 0, budget or { count = 0 }
  budget.count = budget.count + 1
  assert(depth <= 128 and budget.count <= 100000, 'Data exceeds depth/item limits')
  local kind = type(value)
  if kind == 'nil' or kind == 'string' or kind == 'boolean' then return value end
  if kind == 'number' then assert(value == value and math.abs(value) < math.huge, 'Data numbers must be finite'); return value end
  assert(kind == 'table', 'Data cannot contain ' .. kind)
  local marker = U.kind(value)
  local mt = getmetatable(value)
  assert(mt == nil or mt == vim._empty_dict_mt or marker, "Index metadata cannot have an arbitrary metatable")
  if marker == 'null' then assert(value == U.null, 'Invalid null marker'); return value end
  if marker == 'array' then U.assert_array(value) end
  if marker == 'object' then for key in pairs(value) do assert(type(key) == 'string', 'Object keys must be strings') end end
  seen = seen or {}
  assert(not seen[value], "Index metadata cannot contain a cycle")
  seen[value] = true
  local result = {}
  for key, item in next, value do
    local key_kind = type(key)
    assert(key_kind == 'string' or key_kind == 'number' or key_kind == 'boolean', 'Data keys must be primitive values')
    result[data(key, seen, depth + 1, budget)] = data(item, seen, depth + 1, budget)
  end
  seen[value] = nil
  return marker and setmetatable(result, mt) or result
end
-- This root table is constructed here with known string keys. Validate/copy
-- its values once without allocating another root or a traversal set when
-- all projected metadata is scalar; nested data keeps the complete checks.
local function metadata_data(value)
  local budget = { count = 1 }
  for key, item in pairs(value) do
    budget.count = budget.count + 1
    assert(budget.count <= 100000, 'Data exceeds depth/item limits')
    value[key] = data(item, nil, 1, budget)
  end
  return value
end
local function presentation(command)
  local base = { name = command.name, description = command.description, arguments = {},
    provider = command.provider, source = command.source, backend = command.backend }
  for _, field in ipairs(command.arguments or {}) do
    base.arguments[field.name] = { prompt = field.prompt, description = field.description }
  end
  return base
end
local function annotate(command, link)
  if not link then return end
  if link.name ~= nil then command.name = link.name end
  if link.description ~= nil then command.description = link.description end
  for _, field in ipairs(command.arguments or {}) do
    local labels = (link.arguments or {})[field.name]
    if labels then
      if labels.prompt ~= nil then field.prompt = labels.prompt end
      if labels.description ~= nil then field.description = labels.description end
    end
  end
end
local function reindex(self, command)
  self._index:register(metadata_data({ id = command.id, name = command.name, description = command.description,
    aliases = command.aliases, provider = command.provider, source = command.source, type = command.type,
    icon = command.icon, session_action = command.session_action, workspace = command.workspace,
    hidden = command.hidden, replace = true }))
end
function M.new(opts)
  local self = setmetatable({ _index = Index.new(), _commands = {}, _command_links = {}, _command_link_bases = {} }, Registry)
  if opts and opts.reserved then self:set_reserved(opts.reserved) end
  return self
end
function Registry:set_reserved(config)
  assert(type(config) == "table", "Reserved keys must be a table")
  local prepared = { global = {}, root = {} }
  for _, scope in ipairs({ "global", "root" }) do
    assert(config[scope] == nil or type(config[scope]) == "table", "Reserved " .. scope .. " keys must be a map")
    for key, rule in pairs(config[scope] or {}) do
      local parts = K.tokens(key)
      assert(#parts == 1, "Reserved key must be a single key: " .. tostring(key))
      assert(prepared[scope][parts[1]] == nil or vim.deep_equal(prepared[scope][parts[1]], rule), "Conflicting reserved key aliases")
      prepared[scope][parts[1]] = data(rule)
    end
  end
  self._index:set_reserved(prepared)
  return self
end
function Registry:get(id)
  if self._commands[id] then return self._commands[id] end
  local override = self._index:alias_owner(id, true)
  if override == false then return self._commands[id] end
  return self._commands[override or id]
end
function Registry:configure(layout)
  layout = layout or {}
  return self._index:configure({ aliases = data(layout.aliases or {}), hidden = data(layout.hidden or {}),
    word_paths = data(layout.word_paths or {}) })
end
function Registry:hidden(id) return self._index:hidden(id) end
function Registry:resolve_word(query)
  local command = self._index:resolve_word(tostring(query or ""))
  return command and self._commands[command.id] or nil
end
function Registry:words(query, ctx)
  local result = self._index:words(tostring(query or ""))
  for _, item in ipairs(result) do
    item.command = self:get(item.id) or item.command
    item.available, item.reason = self:available(item.id, ctx)
  end
  return result
end
function Registry:node(path) return self._index:node(tokens(path or {})) end
function Registry:bind(path, id, opts)
  return self._index:bind(tokens(path), id, opts and { replace = opts.replace } or nil)
end
function Registry:unbind(path) return self._index:unbind(tokens(path)) end
function Registry:group(path, spec)
  assert(type(spec) == "table", "Group metadata must be a table")
  return self._index:group(tokens(path), data({ name = spec.name, icon = spec.icon, provider = spec.provider, replace = spec.replace }))
end
function Registry:register(spec)
  assert(type(spec) == "table", "Command metadata must be a table")
  local id = nonempty(spec.id, "Command ID")
  local replace = spec.replace or (self._commands[id] and self._commands[id]._command_link_missing)
  assert(not self._commands[id] or replace, "Command ID already exists: " .. id)
  assert(spec.run == nil or type(spec.run) == "function", "Command run must be a function")
  assert(spec.preview == nil or type(spec.preview) == "function", "Command preview must be a function")
  assert(spec.async == nil or type(spec.async) == "boolean", "Command async must be a boolean")
  assert(spec.stable_target == nil or type(spec.stable_target) == "boolean", "Command stable_target must be a boolean")
  assert(spec.timeout_ms == nil or (type(spec.timeout_ms) == "number" and spec.timeout_ms > 0 and spec.timeout_ms < math.huge), "Command timeout_ms must be a positive finite number")
  if spec.type ~= nil then nonempty(spec.type, "Command type") end
  if spec.workspace ~= nil then nonempty(spec.workspace, "Workspace ID") end
  if spec.session_action ~= nil then
    assert(vim.tbl_contains({ "search", "recent", "favorites", "keymaps", "workspaces", "density", "words", "inspect", "selected_recipe", "ui_import", "presentation_import" }, spec.session_action),
      "Unknown session action")
  end
  local targets = (spec.run and 1 or 0) + (spec.workspace and 1 or 0) + (spec.session_action and 1 or 0)
  assert(targets == 1, "Choose exactly one command execution target: run, workspace, or session_action; use group() for namespaces")
  if spec.arguments ~= nil then
    array(spec.arguments, "Command arguments")
    local names = {}
    for _, field in ipairs(spec.arguments) do
      assert(type(field) == "table", "Argument must be a field specification")
      nonempty(field.name, "Argument name")
      assert(not names[field.name], "Duplicate argument name: " .. field.name)
      names[field.name] = true
      assert(field.kind == nil or vim.tbl_contains({ "text", "path", "number", "select", "multiselect", "boolean" }, field.kind), "Unknown argument kind")
      assert(field.validate == nil or type(field.validate) == "function", "Argument validate must be a function")
      assert(field.items == nil or type(field.items) == "table" or type(field.items) == "function", "Argument items must be a table or function")
      assert(field.required == nil or type(field.required) == "boolean", "Argument required must be a boolean")
      assert(field.completion == nil or type(field.completion) == "string" or type(field.completion) == "function", "Argument completion must be a string or function")
      for _, flag in ipairs({ "integer", "secret", "history" }) do assert(field[flag] == nil or type(field[flag]) == "boolean", "Argument " .. flag .. " must be a boolean") end
      for _, bound in ipairs({ "min", "max" }) do
        local value = field[bound]
        assert(value == nil or (type(value) == "number" and value == value and math.abs(value) < math.huge), "Argument " .. bound .. " must be a finite number")
      end
      assert(not field.min or not field.max or field.min <= field.max, "Argument min must not exceed max")
    end
  end
  assert(spec.available == nil or type(spec.available) == "function" or type(spec.available) == "boolean",
    "Command available must be a function or boolean")
  if spec.aliases ~= nil then array(spec.aliases, "Command aliases") end
  local seen = {}
  for _, alias in ipairs(spec.aliases or {}) do
    nonempty(alias, "Alias")
    assert(not seen[alias], "Duplicate alias: " .. alias)
    assert(not self._commands[alias] or alias == id, "Alias conflicts with command ID: " .. alias)
    seen[alias] = true
  end
  local parts = spec.path ~= nil and tokens(spec.path) or nil
  local command = vim.deepcopy(spec)
  command.path, command.replace = nil, nil
  command._command_link_missing = nil
  command.name = command.name or id
  nonempty(command.name, "Command name")
  assert(command.description == nil or type(command.description) == "string", "Command description must be a string")
  local base = self._command_links[id] and presentation(command) or nil
  annotate(command, self._command_links[id])
  local metadata = metadata_data({ id = id, name = command.name, description = command.description, aliases = command.aliases,
    provider = command.provider, source = command.source, type = command.type, icon = command.icon,
    session_action = command.session_action, workspace = command.workspace, hidden = command.hidden, path = parts, replace = replace })
  local detached = {}
  local function remember(alias)
    local owner = self._index:alias_owner(alias)
    if owner and owner ~= id then detached[#detached + 1] = { owner = self._commands[owner], alias = alias } end
  end
  remember(id)
  for alias in pairs(seen) do remember(alias) end
  -- The model validates all mutations before the host descriptor table changes.
  self._index:register(metadata)
  for _, item in ipairs(detached) do
    if item.owner then
      for index = #(item.owner.aliases or {}), 1, -1 do
        if item.owner.aliases[index] == item.alias then table.remove(item.owner.aliases, index) end
      end
    end
  end
  self._commands[id] = command
  self._command_link_bases[id] = base
  return command
end
function Registry:_link_placeholder(id, base)
  local link = self._command_links[id]
  if not link then return nil end
  local provider = base and base.provider or (id:match('^ex%.') and 'ex' or 'command_links')
  local command = {
    id = id, name = link.name or (base and base.name) or id,
    description = link.description or (base and base.description) or 'Linked command is not currently registered',
    provider = provider, source = 'command_link', type = 'action', persistent = true,
    _command_link_missing = true,
    available = function() return false, 'Linked command is not registered: ' .. id end,
    run = function() return false, 'Linked command is not registered: ' .. id end,
  }
  reindex(self, command)
  -- Keep only the original presentation data, never its run/completion or
  -- availability handlers. Re-editing a missing link retains its owner.
  self._commands[id], self._command_link_bases[id] = command, base
  return command
end
function Registry:_apply_command_links(links)
  -- All declarations were validated before entering this method. An ID which
  -- belongs to an alias cannot be promoted silently into a separate command.
  for id in pairs(links) do
    local alias = self._index:alias_owner(id, true)
    -- A disabled profile alias still has a declared provider owner. Linking
    -- must not silently promote that alias into a separate descriptor.
    if alias == false then alias = self._index:alias_owner(id) end
    if not self._commands[id] and alias and alias ~= id then
      return false, 'Command link ID belongs to an alias; use its stable command ID: ' .. id
    end
  end
  local changed = {}
  for id in pairs(self._command_links) do changed[id] = true end
  for id in pairs(links) do changed[id] = true end
  self._command_links = vim.deepcopy(links)
  for _, id in ipairs(U.sorted_keys(changed)) do
    local command, base = self._commands[id], self._command_link_bases[id]
    if command and not command._command_link_missing then
      -- Retain descriptor identity: provider guards refer to the real current
      -- descriptor, while only presentation metadata changes in place.
      base = base or presentation(command)
      self._command_link_bases[id] = links[id] and base or nil
      command.name, command.description = base.name, base.description
      for _, field in ipairs(command.arguments or {}) do
        local original = base.arguments[field.name]
        if original then field.prompt, field.description = original.prompt, original.description end
      end
      annotate(command, links[id])
      reindex(self, command)
    elseif links[id] then self:_link_placeholder(id, base)
    elseif command then
      self._index:unregister(id)
      self._commands[id], self._command_link_bases[id] = nil, nil
    end
  end
  return true
end
function Registry:unregister(id)
  local command = self:get(id)
  if not command then return false end
  if command._command_link_missing then return false end
  local removed = self._index:unregister(command.id)
  if removed then
    local base = self._command_link_bases[command.id]
    self._commands[command.id], self._command_link_bases[command.id] = nil, nil
    self:_link_placeholder(command.id, base)
  end
  return removed
end
function Registry:list()
  local result = {}
  for _, id in ipairs(U.sorted_keys(self._commands)) do result[#result + 1] = self._commands[id] end
  return result
end
function Registry:available(id, ctx)
  local command = self:get(id)
  if not command then return false, "Unknown command: " .. tostring(id) end
  if command.available == nil then return true end
  if type(command.available) ~= "function" then
    if command.available then return true end
    return false, "Unavailable in this context"
  end
  local ok, enabled, reason = pcall(command.available, ctx)
  if not ok then return false, "Condition failed: " .. tostring(enabled) end
  if not enabled then return false, reason or "Unavailable in this context" end
  return true
end
function Registry:paths(id) return self._index:paths(id) end
function Registry:unresolved() return self._index:unresolved() end
function Registry:search(query, ctx, opts)
  opts = opts or {}
  local search_opts = { ids = data(opts.ids), limit = opts.limit }
  local candidates, ranks = self._index:search_rows(tostring(query or ""), search_opts)
  local result = {}
  for _, item in ipairs(candidates) do
    if ctx ~= nil then
      item.available, item.reason = self:available(item.id, ctx)
      if opts.include_unavailable ~= false or item.available ~= false then result[#result + 1] = item end
    else result[#result + 1] = item end
  end
  result = Index.finish_search_rows(result, search_opts, ranks)
  for _, item in ipairs(result) do
    item.command = self._commands[item.id]
  end
  return result
end
function Registry:remove_provider(provider)
  nonempty(provider, "Provider name")
  local ids = {}
  for id, command in pairs(self._commands) do if command.provider == provider then ids[#ids + 1] = id end end
  for _, id in ipairs(ids) do self:unregister(id) end
  self._index:remove_groups(provider)
  return #ids
end
return M
