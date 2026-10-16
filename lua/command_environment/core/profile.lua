-- Portable profile declarations. Validation reads data only; it cannot
-- load adapters, access paths, mutate a host registry, or start a process.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local Workflow = require('command_environment.core.workflow')
local M = {}
local function contains(values, item)
  for _, value in ipairs(values) do if value == item then return true end end
  return false
end
local function merge_defaults(defaults, incoming)
  local out = U.clone(defaults)
  for key, value in pairs(incoming) do
    if type(out[key]) == 'table' and type(value) == 'table'
      and not U.islist(out[key])
      and (not U.islist(value) or not next(value) and U.kind(value) == nil) then
      out[key] = merge_defaults(out[key], value)
    else out[key] = U.clone(value) end
  end
  return out
end
local function mark_json(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = mark_json(child) end
  if U.kind(value) == 'object' or not U.islist(value) then return U.object(out) end
  return U.array(out)
end
local function map() return U.object() end
local function fail(message) error(message, 0) end
local function object(value, label)
  if type(value) ~= "table" or U.kind(value) == "array" or U.kind(value) == "null" then fail(label .. " must be an object") end
  for key in pairs(value) do if type(key) ~= "string" then fail(label .. " must have string keys") end end
  return U.object(value)
end
local function fields(value, names, label)
  object(value, label)
  local allowed = {}
  for name in names:gmatch("%S+") do allowed[name] = true end
  for key in pairs(value) do if not allowed[key] then fail("Unknown " .. label .. " field: " .. key) end end
end
local function text(value, label)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then fail(label .. " must be a nonempty string without NUL") end
end
local function list(value, label)
  if type(value) ~= "table" or not U.islist(value) then fail(label .. " must be an array") end
  return U.array(value)
end
local function id(value, label)
  text(value, label)
  if value:match("^ex%.buffer%.") or value:match("^keymap%.") then fail(label .. " is a runtime ID; use a stable adapter or user command ID") end
end
local function absolute(value)
  return type(value) == "string" and (value:match("^[/\\]") or value:match("^%a:") or value:match("^~[/\\]"))
end
local forbidden = { bufnr = true, winid = true, jobid = true, process_id = true, buffer_id = true,
  window_id = true, pid = true, password = true, secret = true, token = true, access_token = true,
  api_key = true, private_key = true, authorization = true, credentials = true }
local function serial(value, label, seen, depth, budget, submitted)
  budget.count = budget.count + 1
  if budget.count > 20000 or depth > 24 then fail("Profile exceeds nesting/item limits") end
  local kind = type(value)
  if kind == "number" then if value ~= value or math.abs(value) == math.huge then fail(label .. " must be finite") end
  elseif kind == "table" then
    if seen[value] then fail(label .. " contains a cycle") end
    local mt = getmetatable(value)
    if U.kind(value) == "null" or mt and U.kind(value) == nil then fail(label .. " cannot have a metatable or null") end
    seen[value] = true
    local array = U.islist(value)
    for key, child in pairs(value) do
      if (not array and type(key) ~= "string") or (array and type(key) ~= "number") then fail(label .. " has mixed/non-JSON keys") end
      if type(key) == "string" then
        -- A declaration's IDs and labels are not submitted argument values.
        -- Strict field validators below own those structural maps; only the
        -- opaque preset.args payload needs this recursive privacy policy.
        if submitted and forbidden[key:lower()] then fail(label .. "." .. key .. " contains runtime or sensitive data") end
        if (key == "path" or key == "cwd" or key == "file" or key:match("_path$")) and absolute(child) then
          fail(label .. "." .. key .. " must be relative; keep machine paths in local configuration")
        end
      end
      serial(child, label .. "." .. tostring(key), seen, depth + 1, budget, submitted)
    end
    seen[value] = nil
  elseif kind ~= "string" and kind ~= "boolean" then fail(label .. " is not JSON data (" .. kind .. ")") end
end
local function path(value, label)
  if type(value) == "string" then text(value, label); return end
  list(value, label)
  if #value == 0 then fail(label .. " cannot be empty") end
  for _, segment in ipairs(value) do text(segment, label .. " segment") end
end
local function strings(value, label, check)
  list(value, label)
  local seen = {}
  for _, item in ipairs(value) do
    (check or text)(item, label)
    if seen[item] then fail(label .. " contains a duplicate: " .. item) end
    seen[item] = true
  end
end
local function keys(value, label)
  object(value, label)
  for key, action in pairs(value) do
    text(key, label .. " key")
    if action ~= false then text(action, label .. " action") end
  end
end
local function workspace(value, label, template)
  fields(value, template and "id name commands keys color icon path order hidden sources filter" or "name color icon path order hidden keys", label)
  if template then id(value.id, label .. ".id"); strings(value.commands or {}, label .. ".commands", id) end
  for _, key in ipairs({ "name", "icon", "color" }) do if value[key] ~= nil then text(value[key], label .. "." .. key) end end
  if value.color ~= nil and not value.color:match("^#%x%x%x%x%x%x$") then fail(label .. ".color must be #RRGGBB") end
  if value.path ~= nil then path(value.path, label .. ".path") end
  if value.order ~= nil and (type(value.order) ~= "number" or value.order % 1 ~= 0) then fail(label .. ".order must be an integer") end
  if value.hidden ~= nil and type(value.hidden) ~= "boolean" then fail(label .. ".hidden must be boolean") end
  if value.keys then keys(value.keys, label .. ".keys") end
  if value.sources then strings(value.sources, label .. ".sources", id) end
  if value.filter ~= nil and type(value.filter) ~= "string" then fail(label .. ".filter must be a string") end
end
function M.empty()
  return { version = 1, layout = { bindings = U.array(), groups = U.array(), aliases = map(), hidden = map(), word_paths = map() },
    workspaces = { overrides = map(), templates = U.array() }, presets = map(), adapters = map(), tools = map(),
    slots = map(), favorites = U.array(), ui = map(), command_links = map(), requirements = { api = 1, commands = U.array(), modules = U.array(), adapters = U.array(), tools = U.array(), versions = map() } }
end
local function validate(data)
  serial(data, "profile", {}, 0, { count = 0 })
  data = U.clone(data)
  fields(data, "version layout workspaces presets adapters tools projects recipes slots favorites ui presentation command_links requirements", "profile")
  if data.version ~= 1 then fail("Unsupported profile version " .. tostring(data.version) .. "; original data was preserved") end
  local out = merge_defaults(M.empty(), data)
  local links, link_error = require('command_environment.core.command_links').validate(out.command_links)
  if not links then fail(link_error) end
  out.command_links = next(links) and links or map()
  -- Lists are atomic; deep_extend would otherwise retain unwanted defaults.
  fields(out.layout, "bindings groups aliases hidden word_paths", "layout")
  for _, field in ipairs({ "bindings", "groups" }) do
    list(out.layout[field], "layout." .. field)
    local seen = {}
    for _, item in ipairs(out.layout[field]) do
      fields(item, field == "bindings" and "path id" or "path name icon", "layout." .. field)
      path(item.path, "layout path")
      local key = J.encode(item.path)
      if seen[key] then fail("Duplicate layout path: " .. key) end
      seen[key] = true
      if field == "bindings" then if item.id ~= false then id(item.id, "binding.id") end
      else text(item.name, "group.name"); if item.icon then text(item.icon, "group.icon") end end
    end
  end
  for _, field in ipairs({ "aliases", "word_paths" }) do
    object(out.layout[field], "layout." .. field)
    for alias, command in pairs(out.layout[field]) do
      text(alias, field)
      if alias ~= alias:gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "") then
        fail(field .. " must use single spaces between words and no surrounding whitespace")
      end
      if command ~= false then id(command, field .. " command") end
    end
  end
  for command in pairs(out.command_links) do
    local target = out.layout.aliases[command]
    if target ~= nil and target ~= false and target ~= command then
      fail('Command link ID conflicts with profile alias; use its stable command ID: ' .. command)
    end
  end
  object(out.layout.hidden, "layout.hidden")
  for command, hidden in pairs(out.layout.hidden) do id(command, "hidden command"); if type(hidden) ~= "boolean" then fail("hidden must be boolean") end end
  fields(out.workspaces, "overrides templates", "workspaces")
  object(out.workspaces.overrides, "workspaces.overrides")
  for name, value in pairs(out.workspaces.overrides) do id(name, "workspace ID"); workspace(value, "workspace " .. name, false) end
  list(out.workspaces.templates, "workspaces.templates")
  local names = {}
  for _, value in ipairs(out.workspaces.templates) do
    workspace(value, "workspace template", true)
    if names[value.id] then fail("Duplicate workspace template: " .. value.id) end
    names[value.id] = true
  end
  object(out.presets, "presets")
  for command, values in pairs(out.presets) do
    id(command, "preset command"); list(values, "presets." .. command)
    local seen = {}
    for _, preset in ipairs(values) do
      fields(preset, "name args", "preset"); text(preset.name, "preset.name"); object(preset.args, "preset.args")
      serial(preset.args, "presets." .. command .. "." .. preset.name .. ".args", {}, 0, { count = 0 }, true)
      if seen[preset.name] then fail("Duplicate preset: " .. preset.name) end
      seen[preset.name] = true
    end
  end
  object(out.adapters, "adapters")
  for capability, adapter in pairs(out.adapters) do text(capability, "adapter capability"); id(adapter, "adapter ID") end
  object(out.tools, 'tools')
  local tools, tool_error = Workflow.validate_tools(out.tools)
  if not tools then fail(tool_error) end
  out.tools = tools
  object(out.slots, "slots")
  for slot, command in pairs(out.slots) do
    if not slot:match("^[1-9]$") then fail("Slot must be a string from 1 to 9") end
    if command ~= false then id(command, "slot command") end
  end
  strings(out.favorites, "favorites", id)
  fields(out.ui, "density icons width max_width max_height position compact_rows minimal_rows", "ui")
  if out.ui.density and not contains({ "full", "compact", "minimal" }, out.ui.density) then fail("Unknown UI density") end
  if out.ui.icons ~= nil and type(out.ui.icons) ~= "boolean" then fail("ui.icons must be boolean") end
  if out.ui.position then text(out.ui.position, "ui.position") end
  for _, name in ipairs({ "width", "max_width", "max_height", "compact_rows", "minimal_rows" }) do
    local value = out.ui[name]
    if value ~= nil and (type(value) ~= "number" or value < 1 or value % 1 ~= 0) then fail("ui." .. name .. " must be a positive integer") end
  end
  if out.presentation ~= nil then
    local presentation, err = require('command_environment.core.presentation').validate(out.presentation)
    if not presentation then fail(err) end
    out.presentation = presentation
  end
  fields(out.requirements, "api commands modules adapters tools versions", "requirements")
  if out.requirements.api ~= 1 then fail("Unsupported profile API requirement") end
  for _, name in ipairs({ "commands", "modules", "adapters", "tools" }) do strings(out.requirements[name], "requirements." .. name, id) end
  object(out.requirements.versions, "requirements.versions")
  for name, version in pairs(out.requirements.versions) do text(name, "version name"); text(version, "version") end
  if out.projects ~= nil or out.recipes ~= nil then
    local projects, recipes = Workflow.validate(out.projects, out.recipes)
    if not projects then fail(recipes) end
    if out.projects ~= nil then out.projects = projects end
    if out.recipes ~= nil then out.recipes = recipes end
  end
  serial(out, 'Normalized profile', {}, 0, { count = 0 })
  if #J.encode(out) > 1024 * 1024 then fail("Profile exceeds 1 MiB") end
  return mark_json(out)
end
function M.validate(data)
  local ok, result = pcall(validate, data)
  if not ok then return nil, tostring(result) end
  return result
end
function M.decode(json)
  local ok, data = pcall(J.decode, json)
  if not ok then return nil, tostring(data) end
  return M.validate(data)
end
return M
