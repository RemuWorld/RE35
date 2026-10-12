-- Neovim persistence, import preview and activation stay host-owned.
-- The declaration schema is shared with other hosts through the pure core.
local Store = require('command_tree.state_store')
local Core = require('command_environment.core.profile')
local Data = require('command_tree.core_data')
local M = {}
local function text(value, label)
  if type(value) ~= 'string' or value == '' or value:find('\0', 1, true) then
    error(label .. ' must be a nonempty string without NUL', 0)
  end
end
function M.empty() return Data.host(Core.empty()) end
function M.validate(data)
  local ok, portable = pcall(Data.core, data)
  if not ok then return nil, tostring(portable) end
  local prepared, err = Core.validate(portable)
  if not prepared then return nil, err end
  local converted, result = pcall(Data.host, prepared)
  if not converted then return nil, tostring(result) end
  return result
end
function M.read(path)
  local data, err = Store.read(path)
  if not data then return nil, err end
  if not next(data) then return M.empty() end
  return M.validate(data)
end
function M.write(path, data)
  local prepared, err = M.validate(data)
  if not prepared then return false, err end
  return Store.update(path, function(current)
    if next(current) then local previous, failure = M.validate(current); assert(previous, failure) end
    return prepared
  end)
end
local function union(first, second)
  local out, seen = {}, {}
  for _, source in ipairs({ first, second }) do for _, item in ipairs(source or {}) do if not seen[item] then out[#out + 1], seen[item] = item, true end end end
  return out
end
local function keyed(first, second, key)
  local out, indices = vim.deepcopy(first), {}
  for index, item in ipairs(out) do indices[key(item)] = index end
  for _, item in ipairs(second) do
    local name = key(item)
    if indices[name] then out[indices[name]] = vim.deepcopy(item)
    else out[#out + 1], indices[name] = vim.deepcopy(item), #out + 1 end
  end
  return out
end
function M.merge(base, incoming, mode)
  local first, err = M.validate(base)
  if not first then return nil, err end
  local second; second, err = M.validate(incoming)
  if not second then return nil, err end
  mode = mode or "merge"
  if mode == "replace" then return second end
  if mode ~= "merge" then return nil, "Import mode must be merge or replace" end
  local out = vim.tbl_deep_extend("force", first, second)
  -- Each annotation is a complete declaration. Replacing one must not retain
  -- old argument labels which the imported declaration deliberately removed.
  out.command_links = vim.deepcopy(first.command_links)
  for command, link in pairs(second.command_links) do out.command_links[command] = vim.deepcopy(link) end
  for _, field in ipairs({ 'projects', 'recipes' }) do
    if first[field] ~= nil or second[field] ~= nil then
      out[field] = vim.deepcopy(first[field] or vim.empty_dict())
      for id, declaration in pairs(second[field] or {}) do out[field][id] = vim.deepcopy(declaration) end
    end
  end
  -- Each UI preset is a complete declaration, like a command connection.
  if second.presentation then
    out.presentation = vim.deepcopy(first.presentation or { version = 1, presets = vim.empty_dict() })
    for key, value in pairs(second.presentation) do
      if key ~= 'presets' then out.presentation[key] = vim.deepcopy(value) end
    end
    for name, declaration in pairs(second.presentation.presets) do
      out.presentation.presets[name] = vim.deepcopy(declaration)
    end
  end
  for _, name in ipairs({ "bindings", "groups" }) do out.layout[name] = keyed(first.layout[name], second.layout[name], function(item) return vim.json.encode(item.path) end) end
  out.workspaces.templates = keyed(first.workspaces.templates, second.workspaces.templates, function(item) return item.id end)
  for command, values in pairs(second.presets) do out.presets[command] = keyed(first.presets[command] or {}, values, function(item) return item.name end) end
  out.favorites = union(first.favorites, second.favorites)
  for _, name in ipairs({ "commands", "modules", "adapters", "tools" }) do out.requirements[name] = union(first.requirements[name], second.requirements[name]) end
  return M.validate(out)
end
local function references(data)
  local result, seen = {}, {}
  local function add(value) if value and not seen[value] then seen[value], result[#result + 1] = true, value end end
  for _, value in ipairs(data.layout.bindings) do add(value.id) end
  for _, values in ipairs({ data.layout.aliases, data.layout.word_paths, data.slots }) do for _, value in pairs(values) do add(value) end end
  for _, value in ipairs(data.favorites) do add(value) end
  for value in pairs(data.presets) do add(value) end
  for value in pairs(data.command_links or {}) do add(value) end
  for value in pairs(data.layout.hidden) do add(value) end
  for _, workspace_spec in ipairs(data.workspaces.templates) do for _, value in ipairs(workspace_spec.commands or {}) do add(value) end end
  for _, value in ipairs(data.requirements.commands) do add(value) end
  table.sort(result)
  return result
end
function M.export(data, path)
  local out, err = M.validate(data)
  if not out then return nil, err end
  out.requirements.commands = references(out)
  local adapters, tools = {}, {}
  for _, adapter in pairs(out.adapters) do adapters[#adapters + 1] = adapter end
  for name in pairs(out.tools) do tools[#tools + 1] = name end
  for _, recipe in pairs(out.recipes or {}) do for _, step in ipairs(recipe.steps) do tools[#tools + 1] = step.tool end end
  out.requirements.adapters = union(out.requirements.adapters, adapters)
  local modules = {}
  for _, adapter in ipairs(out.requirements.adapters) do
    local module = ({ conform = "conform", telescope = "telescope.builtin" })[adapter]
    if module then modules[#modules + 1] = module end
  end
  out.requirements.modules = union(out.requirements.modules, modules)
  out.requirements.tools = union(out.requirements.tools, tools)
  if path then return M.write(path, out) end
  return out
end
function M.preview(base, incoming, opts)
  opts = opts or {}
  local profile, err = M.merge(base, incoming, opts.mode)
  if not profile then return nil, err end
  local result = { profile = profile, changes = {}, unresolved = {}, warnings = {} }
  for _, field in ipairs({ "layout", "workspaces", "presets", "adapters", "tools", "projects", "recipes", "slots", "favorites", "ui", "presentation", "command_links", "requirements" }) do
    if not vim.deep_equal(base[field], profile[field]) then result.changes[#result.changes + 1] = field end
  end
  local function missing(kind, name, reason) result.unresolved[#result.unresolved + 1] = { kind = kind, id = name, reason = reason } end
  for _, command in ipairs(references(profile)) do
    if not opts.registry then missing("command", command, "Registry not supplied; verify at activation")
    elseif not opts.registry:get(command) or opts.registry:get(command)._command_link_missing then
      missing("command", command, "Command is not registered; reference is preserved")
    end
  end
  for _, module in ipairs(profile.requirements.modules) do
    local filename = module:gsub("%.", "/")
    if not package.loaded[module] and #vim.api.nvim_get_runtime_file("lua/" .. filename .. ".lua", false) == 0
      and #vim.api.nvim_get_runtime_file("lua/" .. filename .. "/init.lua", false) == 0 then
      missing("module", module, "Required module is not on runtimepath; nothing was loaded")
    end
  end
  local adapter_ids = union(profile.requirements.adapters, vim.tbl_values(profile.adapters))
  for _, adapter in ipairs(adapter_ids) do
    if not opts.adapters or not opts.adapters[adapter] then missing("adapter", adapter, "Adapter availability must be supplied by the integration owner") end
  end
  local tool_ids = union(profile.requirements.tools, vim.tbl_keys(profile.tools))
  for recipe_id, recipe in pairs(profile.recipes or {}) do
    if not (profile.projects or {})[recipe.project] then
      missing("project", recipe.project, "Recipe " .. recipe_id .. " has no project declaration; reference is preserved")
    end
    for _, step in ipairs(recipe.steps) do
      if not profile.tools[step.tool] then
        missing("tool", step.tool, "Recipe step " .. recipe_id .. "/" .. step.id .. " has no tool declaration; reference is preserved")
      end
    end
  end
  for _, name in ipairs(tool_ids) do
    local command = (profile.tools[name] or {}).command or name
    local available = opts.tools and opts.tools[name]
    if available == nil then available = vim.fn.executable(command) == 1 end
    if not available then missing("tool", name, "Executable is not available on PATH: " .. command) end
  end
  for name in pairs(profile.workspaces.overrides) do
    local custom = false
    for _, template in ipairs(profile.workspaces.templates) do if template.id == name then custom = true end end
    if not custom and (not opts.workspaces or not opts.workspaces:get(name)) then missing("workspace", name, "Workspace is not registered; override is preserved") end
  end
  if #result.unresolved > 0 then result.warnings[#result.warnings + 1] = "Unavailable references will remain stored; importing does not install or execute anything" end
  return result
end
function M.import_preview(path, base, opts)
  local data, err = M.read(path)
  if not data then return nil, err end
  return M.preview(base, data, opts)
end
return M
