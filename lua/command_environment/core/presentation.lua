-- Bounded presentation preferences. Drawing and required review facts are host-owned.
-- Lua 5.1 data only: no editor API, callbacks, handles, or executable style imports.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 1 }
local limits = { presets = 32, inheritance_edges = 4, bytes = 65536, name_bytes = 80, id_bytes = 48 }
local sections = { 'information', 'layout', 'spacing', 'decoration', 'roles' }
local scenes = { tree = true, search = true, input = true, review = true, tasks = true, results = true }
local roles = { 'normal', 'selected', 'muted', 'accent', 'warning', 'error' }
local fields = {
  information = { title = true, help = true, details = true, status = true, icons = true },
  layout = { density = true, position = true, width = true, max_width = true, max_height = true, rows = true },
  spacing = { horizontal = true, vertical = true },
  decoration = { border = true, separator = true },
  roles = { normal = true, selected = true, muted = true, accent = true, warning = true, error = true },
}
local declaration_fields = { name = true, extends = true, scenes = true }
for _, section in ipairs(sections) do declaration_fields[section] = true end
local builtin_ids = { full = true, compact = true, minimal = true }
local densities = { full = true, compact = true, minimal = true }
local positions = { center = true, bottom = true, ['bottom-right'] = true, top = true, ['top-right'] = true }
local borders = { none = true, rounded = true, single = true, double = true }

local function object(value, allowed, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'),
    label .. ' must be plain object data')
  for key in next, value do
    assert(type(key) == 'string' and (allowed == nil or allowed[key]), 'Unknown ' .. label .. ' field')
  end
  return value
end
local function text(value, maximum, label)
  assert(type(value) == 'string' and #value > 0 and #value <= maximum
    and J.valid_utf8(value) and not value:find('[%z\1-\31\127]'),
    label .. ' must be a nonempty UTF-8 line of at most ' .. maximum .. ' bytes')
  return value
end
local function identifier(value)
  text(value, limits.id_bytes, 'Preset ID')
  assert(value:match('^[a-z][a-z0-9_-]*$'), 'Preset ID must use lowercase ASCII letters, digits, underscores or hyphens')
  return value
end
local function integer(value, minimum, maximum, label)
  assert(type(value) == 'number' and value == value and value % 1 == 0
    and value >= minimum and value <= maximum, label .. ' must be an integer from ' .. minimum .. ' to ' .. maximum)
  return value
end
local function color(value)
  assert(type(value) == 'string' and value:match('^#%x%x%x%x%x%x$'), 'Role colors must use #RRGGBB')
  return value:upper()
end
local function checked_section(section, value)
  object(value, fields[section], section)
  local result = U.object()
  for key, child in next, value do
    if section == 'roles' then
      object(child, { fg = true, bg = true }, 'color role')
      result[key] = U.object()
      for component, shade in next, child do result[key][component] = color(shade) end
    elseif section == 'information' or section == 'decoration' and key == 'separator' then
      assert(type(child) == 'boolean', section .. '.' .. key .. ' must be a boolean'); result[key] = child
    elseif section == 'layout' and (key == 'density' or key == 'position') or section == 'decoration' then
      local enum = key == 'density' and densities or key == 'position' and positions or borders
      assert(type(child) == 'string' and enum[child], 'Unsupported ' .. section .. '.' .. key); result[key] = child
    else
      local minimum, maximum = 1, (key == 'width' or key == 'max_width') and 240 or 80
      if section == 'spacing' then minimum, maximum = 0, key == 'horizontal' and 6 or 2 end
      result[key] = integer(child, minimum, maximum, section .. '.' .. key)
    end
  end
  return result
end
local function checked_declaration(value)
  object(value, declaration_fields, 'preset')
  local result = U.object()
  if value.name ~= nil then result.name = text(value.name, limits.name_bytes, 'Preset name') end
  if value.extends == false then result.extends = false
  elseif value.extends ~= nil then result.extends = identifier(value.extends) end
  for _, section in ipairs(sections) do
    if value[section] ~= nil then result[section] = checked_section(section, value[section]) end
  end
  if value.scenes ~= nil then
    object(value.scenes, scenes, 'scenes'); result.scenes = U.object()
    for scene, override in next, value.scenes do
      object(override, fields, 'scene override'); local normalized = U.object()
      for section, child in next, override do normalized[section] = checked_section(section, child) end
      result.scenes[scene] = normalized
    end
  end
  return result
end
local function chain(config, id)
  local result, visiting = {}, {}
  local function walk(current, edges)
    assert(edges <= limits.inheritance_edges, 'Preset inheritance exceeds four edges to a built-in or standalone factory root')
    assert(not visiting[current], 'Cyclic preset inheritance')
    local declaration = config.presets[current]
    assert(declaration ~= nil or builtin_ids[current], 'Unknown preset reference: ' .. current)
    visiting[current] = true
    if declaration and declaration.extends == false then
      -- Detached snapshots inherit only immutable factory defaults, never the
      -- configured Full declaration or its inherited color/scene overrides.
      result.root = builtin_ids[current] and current or 'full'
    elseif declaration and declaration.extends ~= nil then
      walk(declaration.extends, edges + 1)
    elseif not builtin_ids[current] then
      walk('full', edges + 1)
    else result.root = current end
    result[#result + 1] = current; visiting[current] = nil
  end
  walk(id, 0); return result
end
local function checked_config(config)
  if config == nil then config = { version = 1, presets = {} } end
  object(config, { version = true, selected = true, presets = true }, 'presentation')
  assert(config.version == 1, 'Unsupported presentation version')
  local result = U.object({ version = 1, presets = U.object() })
  if config.selected ~= nil then result.selected = identifier(config.selected) end
  if config.presets ~= nil then
    object(config.presets, nil, 'presets'); local count = 0
    for id, declaration in next, config.presets do
      identifier(id); count = count + 1; assert(count <= limits.presets, 'Presentation permits at most 32 preset declarations')
      result.presets[id] = checked_declaration(declaration)
    end
  end
  assert(#J.encode(result) <= limits.bytes, 'Presentation exceeds the 64 KiB data limit')
  for id in next, result.presets do chain(result, id) end
  if result.selected ~= nil then chain(result, result.selected) end
  return result
end
local function safely(callback, ...)
  local ok, first, second = pcall(callback, ...)
  if ok then return first, second end
  return nil, tostring(first)
end
function M.validate(config) return safely(checked_config, config) end
function M.limits() return U.clone(limits) end

-- Authoring widgets consume this typed catalog, then submit edits to the same
-- declaration validator. Labels describe portable intent, not editor controls.
function M.editor_schema()
  local groups = U.array()
  local labels = { information = 'Information', layout = 'Layout', spacing = 'Spacing',
    decoration = 'Decoration', roles = 'Theme roles' }
  local choices = { density = { 'full', 'compact', 'minimal' },
    position = { 'center', 'bottom', 'bottom-right', 'top', 'top-right' },
    border = { 'none', 'rounded', 'single', 'double' } }
  for _, section in ipairs(sections) do
    local group = U.object({ id = section, label = labels[section], fields = U.array() })
    for _, key in ipairs(U.sorted_keys(fields[section])) do
      local field = U.object({ id = key, label = key:gsub('_', ' '):gsub('^%l', string.upper) })
      if section == 'roles' then
        field.kind, field.components = 'color_role', U.array({ 'fg', 'bg' })
        field.component_kind = 'color'
      elseif section == 'information' or section == 'decoration' and key == 'separator' then
        field.kind = 'boolean'
      elseif choices[key] ~= nil then
        field.kind, field.values = 'enum', U.array(U.clone(choices[key]))
      else
        field.kind, field.min, field.max = 'integer', 1, (key == 'width' or key == 'max_width') and 240 or 80
        if section == 'spacing' then field.min, field.max = 0, key == 'horizontal' and 6 or 2 end
      end
      group.fields[#group.fields + 1] = field
    end
    groups[#groups + 1] = group
  end
  return U.object({ version = 1, groups = groups,
    scenes = U.array({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }),
    builtins = U.array({ 'full', 'compact', 'minimal' }), limits = M.limits(),
    authority = 'data_only' })
end

local function builtin(id)
  local full, minimal = id == 'full', id == 'minimal'
  local result = U.object({ id = id, name = ({ full = 'Full', compact = 'Compact', minimal = 'Minimal' })[id],
    information = U.object({ title = not minimal, help = full, details = full, status = full, icons = full }),
    layout = U.object({ density = id, position = 'center', width = 48, max_width = 88, max_height = 16,
      rows = full and 16 or minimal and 3 or 6 }),
    spacing = U.object({ horizontal = minimal and 2 or 0, vertical = 0 }),
    decoration = U.object({ border = minimal and 'none' or 'rounded', separator = full }), roles = U.object() })
  for _, role in ipairs(roles) do result.roles[role] = U.object() end
  return result
end
function M.builtins()
  local result = U.object()
  for id in next, builtin_ids do result[id] = builtin(id) end
  return result
end
function M.ids(config)
  return safely(function()
    config = checked_config(config); local set = { full = true, compact = true, minimal = true }
    for id in next, config.presets do set[id] = true end
    return U.array(U.sorted_keys(set))
  end)
end
local function merge(result, declaration)
  for _, section in ipairs(sections) do
    local override = declaration[section]
    if override ~= nil then
      for key, value in next, override do
        if section == 'roles' then
          for component, shade in next, value do result.roles[key][component] = shade end
        else result[section][key] = value end
      end
    end
  end
end
local function checked_legacy(legacy)
  if legacy == nil then return {} end
  object(legacy, nil, 'legacy UI')
  local result = {}
  for key, value in next, legacy do
    if key == 'density' then assert(type(value) == 'string' and densities[value], 'Unknown legacy density'); result[key] = value
    elseif key == 'icons' then assert(type(value) == 'boolean', 'Legacy icons must be a boolean'); result[key] = value
    elseif key == 'position' then assert(type(value) == 'string' and positions[value], 'Unknown legacy position'); result[key] = value
    elseif key == 'width' or key == 'max_width' or key == 'max_height' or key == 'compact_rows' or key == 'minimal_rows' then
      -- Historical setup permits larger host geometry; clamp to the shared cosmetic ceiling.
      assert(type(value) == 'number' and value % 1 == 0 and value >= 1 and value < math.huge, 'Invalid legacy geometry')
      result[key] = math.min(value, (key == 'width' or key == 'max_width') and 240 or 80)
    end
  end
  return result
end
function M.resolve(config, id, scene, legacy)
  return safely(function()
    config, legacy = checked_config(config), checked_legacy(legacy)
    if scene ~= nil then assert(type(scene) == 'string' and scenes[scene], 'Unknown presentation scene') end
    id = id or config.selected or legacy.density or 'full'; identifier(id)
    local lineage = chain(config, id); local result = builtin(lineage.root)
    for _, key in ipairs({ 'position', 'width', 'max_width', 'max_height' }) do
      if legacy[key] ~= nil then result.layout[key] = legacy[key] end
    end
    if legacy.icons ~= nil then result.information.icons = legacy.icons end
    local rows
    if result.layout.density == 'compact' then rows = legacy.compact_rows
    elseif result.layout.density == 'minimal' then rows = legacy.minimal_rows end
    if rows ~= nil then result.layout.rows = rows end
    for _, ancestor in ipairs(lineage) do
      local declaration = config.presets[ancestor]
      if declaration ~= nil then merge(result, declaration) end
    end
    if scene ~= nil then
      for _, ancestor in ipairs(lineage) do
        local declaration = config.presets[ancestor]
        if declaration and declaration.scenes and declaration.scenes[scene] then merge(result, declaration.scenes[scene]) end
      end
    end
    result.id, result.name = id, (config.presets[id] and config.presets[id].name) or (builtin_ids[id] and builtin(id).name) or id
    return result
  end)
end

function M.capabilities(host)
  return safely(function()
    assert(host == 'neovim' or host == 'vscode', 'Unknown presentation host')
    local support = U.object()
    for _, section in ipairs(sections) do
      support[section] = U.object()
      for key in next, fields[section] do
        -- Native Quick Pick/Input Box consume optional information across the
        -- six scenes. Geometry and styling remain owned by the editor widgets.
        support[section][key] = host == 'neovim' or section == 'information' and key ~= 'icons'
      end
    end
    return U.object({ contract_version = 1, host = host, support = support })
  end)
end
local function checked_resolved(resolved)
  object(resolved, { id = true, name = true, information = true, layout = true, spacing = true, decoration = true, roles = true }, 'resolved presentation')
  local result = U.object({ id = identifier(resolved.id), name = text(resolved.name, limits.name_bytes, 'Preset name') })
  for _, section in ipairs(sections) do
    result[section] = checked_section(section, resolved[section])
    for key in next, fields[section] do assert(result[section][key] ~= nil, 'Resolved presentation is missing ' .. section .. '.' .. key) end
  end
  return result
end
function M.negotiate(resolved, capabilities)
  return safely(function()
    local effective = checked_resolved(resolved)
    object(capabilities, { contract_version = true, host = true, support = true }, 'presentation capabilities')
    assert(capabilities.contract_version == 1, 'Unsupported presentation capability version')
    text(capabilities.host, 48, 'Presentation host')
    object(capabilities.support, fields, 'capability support')
    local native = builtin('full')
    native.information.icons, native.decoration.border, native.decoration.separator = false, 'none', false
    local fallbacks = U.array()
    for _, section in ipairs(sections) do
      local supported = object(capabilities.support[section], fields[section], 'capability ' .. section)
      for _, key in ipairs(U.sorted_keys(fields[section])) do
        assert(type(supported[key]) == 'boolean', 'Capabilities must explicitly support or decline each option')
        if not supported[key] then
          local requested, fallback = effective[section][key], native[section][key]
          if section ~= 'roles' or next(requested) ~= nil then
            fallbacks[#fallbacks + 1] = U.object({ path = section .. '.' .. key,
              requested = U.clone(requested), effective = U.clone(fallback),
              reason = capabilities.host .. ' uses its native presentation for this option' })
          end
          effective[section][key] = U.clone(fallback)
        end
      end
    end
    return effective, fallbacks
  end)
end
return M
