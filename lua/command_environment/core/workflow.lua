-- Portable project, tool and recipe declarations and scalar resolution only.
-- Hosts retain roots, filesystem identity, tool overrides and execution authority.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 1 }
local limits = { projects = 64, recipes = 128, steps = 16, choices = 64,
  step_arguments = 256, items = 20000, depth = 24, bytes = 1048576 }
local function check(value, why) if not value then error(why, 0) end end
local function safely(callback, ...)
  local ok, first, second = pcall(callback, ...)
  if ok then return first, second end
  return nil, tostring(first)
end
local function bounded(value)
  local seen, count, bytes = {}, 0, 0
  local function visit(child, depth)
    count = count + 1
    check(count <= limits.items and depth <= limits.depth, 'Workflow exceeds nesting/item limits')
    local kind = type(child)
    if kind == 'string' then
      bytes = bytes + #child
      check(bytes <= limits.bytes, 'Workflow exceeds 1 MiB')
      check(J.valid_utf8(child), 'Workflow text must be valid UTF-8')
    elseif kind == 'table' then
      local marker, mt = U.kind(child), getmetatable(child)
      check(mt == nil or marker == 'object' or marker == 'array', 'Workflow must contain plain object or array data')
      check(not seen[child], 'Workflow contains a cycle'); seen[child] = true
      local array = U.islist(child)
      check(marker ~= 'array' or array, 'Workflow arrays must be dense')
      for key, item in next, child do
        check(array and type(key) == 'number' or not array and type(key) == 'string', 'Workflow contains mixed/non-JSON keys')
        if type(key) == 'string' then
          bytes = bytes + #key
          check(bytes <= limits.bytes, 'Workflow exceeds 1 MiB')
          check(J.valid_utf8(key), 'Workflow text must be valid UTF-8')
        end
        visit(item, depth + 1)
      end
      seen[child] = nil
    elseif kind == 'number' then check(child == child and math.abs(child) < math.huge, 'Workflow numbers must be finite')
    else check(kind == 'boolean' or kind == 'nil', 'Workflow contains non-JSON data') end
  end
  visit(value, 0)
  check(#J.encode(value) <= limits.bytes, 'Workflow exceeds 1 MiB')
end
local function object(value, label)
  check(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'), label .. ' must be an object')
  for key in next, value do check(type(key) == 'string', label .. ' must have string keys') end
end
local function fields(value, allowed, label)
  object(value, label)
  local known = {}; for name in allowed:gmatch('%S+') do known[name] = true end
  for name in next, value do check(known[name], 'Unknown ' .. label .. ' field: ' .. name) end
end
local function text(value, label, empty, profile)
  check(type(value) == 'string' and (empty or value ~= '') and not value:find('\0', 1, true),
    label .. (profile and ' must be a nonempty string without NUL' or ' must be text without NUL'))
  return value
end
local function absolute(value)
  return type(value) == 'string' and (value:match('^[/\\]') or value:match('^%a:') or value:match('^~[/\\]'))
end
local function relative(value, label)
  text(value, label); check(not absolute(value), label .. ' must be a logical relative path')
  value = value:gsub('\\', '/')
  for part in value:gmatch('[^/]+') do check(part ~= '..', label .. ' cannot escape its project') end
  return value
end
local function contains(values, value)
  for _, item in ipairs(values) do if item == value then return true end end
  return false
end
local function choices(value, label)
  check(U.islist(value) and #value > 0 and #value <= limits.choices, label .. ' must contain 1–64 choices')
  local result, seen = U.array(), {}
  for _, item in ipairs(value) do
    text(item, label); check(not seen[item], label .. ' contains a duplicate'); seen[item] = true
    result[#result + 1] = item
  end
  return result
end
local function logical_cwd(value, label)
  fields(value, 'base path', label)
  check(contains({ 'project', 'config', 'home' }, value.base), label .. '.base must be project, config or home')
  return U.object({ base = value.base, path = relative(value.path, label .. '.path') })
end
local function project(spec, id)
  fields(spec, 'name root source configurations targets default_configuration default_target', 'project ' .. id)
  local value = U.object({ name = text(spec.name or id, 'Project name'),
    root = logical_cwd(spec.root or { base = 'project', path = '.' }, 'Project root'),
    source = spec.source and spec.source ~= '' and relative(spec.source, 'Project source') or '',
    configurations = choices(spec.configurations or { 'default' }, 'Project configurations'),
    targets = choices(spec.targets or { 'default' }, 'Project targets') })
  value.default_configuration = spec.default_configuration or value.configurations[1]
  value.default_target = spec.default_target or value.targets[1]
  check(contains(value.configurations, value.default_configuration), 'Default configuration is not declared')
  check(contains(value.targets, value.default_target), 'Default target is not declared')
  return value
end
local function normalize(projects, recipes)
  projects, recipes = projects or {}, recipes or {}
  bounded({ projects = projects, recipes = recipes })
  check(type(projects) == 'table' and type(recipes) == 'table', 'Projects and recipes must be objects')
  object(projects, 'Projects'); object(recipes, 'Recipes')
  local p, r, count = U.object(), U.object(), 0
  for id, spec in next, projects do
    count = count + 1; check(count <= limits.projects, 'Project/recipe declaration limit exceeded')
    text(id, 'Project ID'); check(id:match('^[%w_.-]+$'), 'Project ID must use letters, numbers, dot, underscore or hyphen')
    p[id] = project(spec, id)
  end
  count = 0
  for id, spec in next, recipes do
    count = count + 1; check(count <= limits.recipes, 'Project/recipe declaration limit exceeded')
    text(id, 'Recipe ID'); check(id:match('^[%w_.-]+$'), 'Recipe ID must use letters, numbers, dot, underscore or hyphen')
    fields(spec, 'name project steps', 'recipe ' .. id); text(spec.project, 'Recipe project')
    check(U.islist(spec.steps) and #spec.steps > 0 and #spec.steps <= limits.steps, 'Recipe must have 1–16 ordered steps')
    local value, seen = U.object({ name = text(spec.name or id, 'Recipe name'), project = spec.project, steps = U.array() }), {}
    for _, step in ipairs(spec.steps) do
      fields(step, 'id name tool args cwd', 'recipe step'); text(step.id, 'Step ID'); text(step.tool, 'Step tool')
      check(step.id:match('^[%w_.-]+$') and not seen[step.id], 'Duplicate or invalid recipe step ID'); seen[step.id] = true
      local item = U.object({ id = step.id, name = step.name and text(step.name, 'Step name') or step.id, tool = step.tool })
      if step.args ~= nil then
        check(U.islist(step.args) and #step.args <= limits.step_arguments, 'Step args must be an argv array of at most 256 entries')
        item.args = U.array()
        for _, arg in ipairs(step.args) do
          text(arg, 'Step argument', true)
          local attached = arg:match('^%-[^=]*=(.*)$') or arg:match('^%-[IL](.*)$')
          check(not absolute(arg) and not (attached and absolute(attached)), 'Portable step argv cannot contain absolute machine paths')
          item.args[#item.args + 1] = arg
        end
      end
      if step.cwd then item.cwd = logical_cwd(step.cwd, 'Step cwd') end
      value.steps[#value.steps + 1] = item
    end
    -- Missing references remain declarations so hosts can explain readiness.
    r[id] = value
  end
  local commands = {}
  for id in next, r do commands['recipe.' .. id] = true end
  for id, spec in next, r do for _, step in ipairs(spec.steps) do
    local command = 'recipe.' .. id .. '.step.' .. step.id
    check(not commands[command], 'Recipe and step command IDs collide: ' .. command); commands[command] = true
  end end
  check(#J.encode(U.object({ projects = p, recipes = r })) <= limits.bytes, 'Workflow exceeds 1 MiB')
  return p, r
end
function M.validate(projects, recipes) return safely(normalize, projects, recipes) end
function M.validate_tools(tools)
  return safely(function()
    if tools == nil then tools = {} end
    bounded(tools); object(tools, 'tools')
    local result = U.object()
    for name, tool in next, tools do
      text(name, 'tool name', false, true); fields(tool, 'command args cwd description errorformat', 'tool ' .. name)
      text(tool.command, 'tool.command', false, true)
      check(not absolute(tool.command) and not tool.command:find('[/\\]'),
        'Portable tool.command must be a PATH name; machine overrides belong in local configuration')
      check(U.islist(tool.args or {}), 'tool.args must be an array')
      local value = U.object({ command = tool.command })
      if tool.args == false then value.args = false
      elseif tool.args ~= nil then value.args = U.array() end
      for _, argument in ipairs(tool.args or {}) do
        text(argument, 'tool argument', false, true)
        local attached = argument:match('^%-[IL](.+)$') or argument:match('^%-%-[^=]+=(.+)$')
        check(not absolute(argument) and not absolute(attached), 'Portable tool arguments cannot contain absolute machine paths')
        value.args[#value.args + 1] = argument
      end
      if tool.cwd then
        fields(tool.cwd, 'base path', 'tool.cwd')
        check(contains({ 'project', 'config', 'home' }, tool.cwd.base), 'tool.cwd.base must be project, config, or home')
        text(tool.cwd.path, 'tool.cwd.path', false, true)
        check(not absolute(tool.cwd.path), 'tool.cwd.path must be relative; keep machine paths in local configuration')
        -- Existing profile tool directories may traverse a logical base; project
        -- roots, sources and step overrides retain their stricter no-escape rule.
        value.cwd = U.object({ base = tool.cwd.base, path = tool.cwd.path:gsub('\\', '/') })
      end
      for _, field in ipairs({ 'description', 'errorformat' }) do
        if tool[field] then value[field] = text(tool[field], 'tool.' .. field, false, true) end
      end
      if tool.cwd == false then value.cwd = false end
      if tool.description == false then value.description = false end
      if tool.errorformat == false then value.errorformat = false end
      result[name] = value
    end
    check(#J.encode(result) <= limits.bytes, 'Workflow exceeds 1 MiB')
    return result
  end)
end
function M.choices(declaration, selection)
  return safely(function()
    bounded({ project = declaration, selection = selection or {} })
    local value = project(declaration, 'selection'); selection = selection or {}
    fields(selection, 'configuration target', 'Project selection')
    local configuration, target = selection.configuration or value.default_configuration, selection.target or value.default_target
    check(contains(value.configurations, configuration), 'Configuration is not declared')
    check(contains(value.targets, target), 'Target is not declared')
    return U.object({ configuration = configuration, target = target })
  end)
end
function M.argv(tool, values)
  return safely(function()
    bounded({ tool = tool, values = values }); fields(tool, 'command args', 'Resolved tool')
    fields(values, 'file root configuration target', 'Recipe substitution')
    text(tool.command, 'Tool executable'); check(U.islist(tool.args or {}), 'Tool arguments must be an array')
    for _, name in ipairs({ 'file', 'root', 'configuration', 'target' }) do text(values[name], 'Recipe ' .. name, name == 'file') end
    local result, bytes = U.array({ tool.command }), #tool.command
    for _, argument in ipairs(tool.args or {}) do
      text(argument, 'Tool argument', true)
      check(not argument:find('{file}', 1, true) or values.file ~= '', 'Declare a project source before using {file}')
      local chunks, start = {}, 1
      local function append(value)
        bytes = bytes + #value; check(bytes <= limits.bytes, 'Workflow exceeds 1 MiB')
        chunks[#chunks + 1] = value
      end
      while true do
        local first, last, name = argument:find('{([%w_]+)}', start)
        if not first then append(argument:sub(start)); break end
        append(argument:sub(start, first - 1))
        check(values[name] ~= nil, 'Unknown recipe argv placeholder: {' .. name .. '}')
        append(values[name]); start = last + 1
      end
      result[#result + 1] = table.concat(chunks)
    end
    check(#J.encode(result) <= limits.bytes, 'Workflow exceeds 1 MiB')
    return result
  end)
end
function M.limits() return U.clone(limits) end
return M
