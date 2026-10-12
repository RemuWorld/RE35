-- Preset authoring is data-only; the Settings transaction owns review and Apply.
local M = {}
local C = require('command_tree.settings.common')
local T = require('command_tree.settings.transaction')
local I = require('command_tree.settings.input')
local Core = require('command_environment.core.presentation')
local Data = require('command_tree.presentation_data')
local groups = { 'information', 'layout', 'spacing', 'decoration', 'roles' }
local scenes = { 'tree', 'search', 'input', 'review', 'tasks', 'results' }
local roles = { 'normal', 'selected', 'muted', 'accent', 'warning', 'error' }
local labels = { information = 'Information', layout = 'Layout', spacing = 'Spacing', decoration = 'Decoration', roles = 'Colors' }
local builtin = { full = true, compact = true, minimal = true }
local positions = { center = true, bottom = true, ['bottom-right'] = true, top = true, ['top-right'] = true }
local specifications = {
  information = {
    { id = 'title', label = 'Title', kind = 'boolean' }, { id = 'help', label = 'Help', kind = 'boolean' },
    { id = 'details', label = 'Details', kind = 'boolean' }, { id = 'status', label = 'Status', kind = 'boolean' },
    { id = 'icons', label = 'Icons', kind = 'boolean' },
  },
  layout = {
    { id = 'density', label = 'Density', kind = 'select', items = { 'full', 'compact', 'minimal' } },
    { id = 'position', label = 'Position', kind = 'select', items = { 'center', 'bottom', 'bottom-right', 'top', 'top-right' } },
    { id = 'width', label = 'Width', kind = 'number', min = 1, max = 240 },
    { id = 'max_width', label = 'Maximum width', kind = 'number', min = 1, max = 240 },
    { id = 'max_height', label = 'Maximum height', kind = 'number', min = 1, max = 80 },
    { id = 'rows', label = 'Visible rows', kind = 'number', min = 1, max = 80 },
  },
  spacing = {
    { id = 'horizontal', label = 'Horizontal padding', kind = 'number', min = 0, max = 6 },
    { id = 'vertical', label = 'Vertical padding', kind = 'number', min = 0, max = 2 },
  },
  decoration = {
    { id = 'border', label = 'Popup border', kind = 'select', items = { 'none', 'rounded', 'single', 'double' } },
    { id = 'separator', label = 'Separator', kind = 'boolean' },
  },
}
local function config(data)
  return data.presentation or C.CE().presentation_defaults() or { version = 1, presets = {} }
end
local function editable(data)
  if not data.presentation then data.presentation = C.copy(config(data)) end
  data.presentation.presets = data.presentation.presets or vim.empty_dict()
  return data.presentation
end
local function preset(data, id)
  local value = editable(data)
  value.presets[id] = value.presets[id] or vim.empty_dict()
  return value.presets[id]
end
local function route(state)
  local scene, group = (state.detail or ''):match('^presentation:scene:([^:]+):([^:]+)$')
  if scene then return scene, group end
  scene = (state.detail or ''):match('^presentation:scene:([^:]+)$')
  if scene then return scene end
  return nil, (state.detail or ''):match('^presentation:([^:]+)$')
end
local function contains(values, value)
  for _, item in ipairs(values) do if item == value then return true end end
  return false
end
function M.handles(state)
  return type(state.detail) == 'string' and (state.detail == 'presentation' or state.detail:match('^presentation:')) ~= nil
end
function M.normalize(state, data)
  if not M.handles(state) then return false end
  if state.entity and not builtin[state.entity] and not config(data).presets[state.entity] then
    state.entity, state.detail = nil, 'presentation'
  end
  if not state.entity then state.detail = 'presentation'; return true end
  local scene, group = route(state)
  if scene and not contains(scenes, scene) or group and group ~= 'scenes' and not contains(groups, group) then state.detail = 'presentation' end
  return true
end
local function navigate(state, detail, entity, selected)
  state.detail, state.entity, state.selected, state.selected_id = detail, entity, 1, selected
  return true
end
local function legacy(frame)
  local value = vim.tbl_extend('force', C.CE().ui_defaults(), C.profile(frame).ui or {})
  local placement = value.position
  if placement and not positions[placement] then
    value.position = 'center'
    return value, 'Local placement ' .. placement .. ' uses center in the common presentation contract unless overridden by a preset'
  end
  return value
end
local function resolved(frame, id, scene)
  local result, why = Core.resolve(Data.core(config(C.profile(frame))), id, scene, legacy(frame))
  assert(result, why)
  return result
end
local function declaration(frame, scene)
  local spec = config(C.profile(frame)).presets[frame.data.entity] or {}
  if scene then return (spec.scenes or {})[scene] or {} end
  return spec
end
local function style(data, id, scene)
  local spec = preset(data, id)
  if not scene then return spec end
  spec.scenes = spec.scenes or vim.empty_dict()
  spec.scenes[scene] = spec.scenes[scene] or vim.empty_dict()
  return spec.scenes[scene]
end
local function name(data, id)
  return config(data).presets[id] and config(data).presets[id].name or (builtin[id] and id:gsub('^%l', string.upper) or id)
end
local function count(value) local n = 0; for _ in pairs(value or {}) do n = n + 1 end; return n end
local function note(id, scene, group, field, label, before)
  return { id = 'presentation.presets.' .. id .. (scene and '.scenes.' .. scene or '') .. '.' .. group .. '.' .. field,
    label = 'Presentation · ' .. label, before = before }
end
local function group_rows(frame, scene, group)
  local result, effective = {}, resolved(frame, frame.data.entity, scene)
  local local_value = declaration(frame, scene)[group] or {}
  if group == 'roles' then
    for _, role in ipairs(roles) do
      for _, channel in ipairs({ 'fg', 'bg' }) do
        local value = (effective.roles[role] or {})[channel]
        C.add(result, role .. ':' .. channel, role .. ' ' .. (channel == 'fg' and 'foreground' or 'background'), value or 'Theme',
          { role = role, channel = channel, inherited = not (local_value[role] or {})[channel],
            detail = 'RGB color #RRGGBB; Reset inherits the preset or host theme' })
      end
    end
  else
    for _, spec in ipairs(specifications[group]) do
      C.add(result, spec.id, spec.label, effective[group][spec.id], { field = spec, inherited = local_value[spec.id] == nil,
        detail = local_value[spec.id] == nil and 'Inherited · edit to override, Reset to inherit again' or 'Preset override · Reset to inherit' })
    end
  end
  if group == 'layout' then
    local _, placement = legacy(frame)
    if placement then C.add(result, '__placement_fallback__', 'Local placement fallback', nil, { disabled = true, reason = placement }) end
  end
  C.add(result, '__reset_group__', 'Reset ' .. labels[group]:lower() .. ' overrides')
  return result
end
function M.items(frame, session)
  local state, data, result = frame.data, C.profile(frame), {}
  M.normalize(state, data)
  if not state.entity then
    local settings = config(data)
    for _, id in ipairs(Core.ids(Data.core(settings))) do
      C.add(result, 'preset:' .. id, name(data, id), settings.selected == id and 'Selected' or nil, { preset_id = id,
        detail = builtin[id] and 'Built-in preset · editable overrides' or 'User preset · ' .. id })
    end
    C.add(result, '__create__', 'Create preset')
    C.add(result, '__legacy__', 'Use existing UI settings', settings.selected == nil and 'Selected' or nil,
      { detail = 'Keep preset declarations and inherit the existing density and eight UI settings' })
    C.add(result, '__reset_all__', 'Reset all presentation overrides', nil, { detail = 'Return to local presentation defaults; review before Apply' })
    local pending = state.draft and #T.changes(frame) > 0
    for _, action in ipairs({ 'export', 'import' }) do
      if C.registry(session):get('settings.presentation_' .. action) then
        C.add(result, '__' .. action .. '__', action == 'export' and 'Export presentation presets' or 'Import presentation presets', nil,
          { disabled = pending, reason = pending and 'Apply or discard the Settings draft before ' .. action .. 'ing presentation presets' or nil })
      end
    end
    return result
  end
  local scene, group = route(state)
  if group == 'scenes' then
    for _, value in ipairs(scenes) do C.add(result, 'scene:' .. value, value:gsub('^%l', string.upper), nil, { scene = value }) end
    C.add(result, '__reset_scenes__', 'Reset all scene overrides')
  elseif group then return group_rows(frame, scene, group)
  else
    if not scene then
      C.add(result, '__select__', 'Use this preset', config(data).selected == state.entity and 'Selected' or nil)
      C.add(result, 'name', 'Name', name(data, state.entity))
      local parent = (config(data).presets[state.entity] or {}).extends
      C.add(result, 'extends', 'Parent preset', parent == false and 'Standalone defaults' or parent or 'Default')
    end
    for _, value in ipairs(groups) do C.add(result, value, labels[value], nil, { group = value }) end
    if scene then
      C.add(result, '__reset_scene__', 'Reset this scene', nil, { detail = 'Use the preset base style for this scene' })
    else
      C.add(result, '__scenes__', 'Scene overrides', count((config(data).presets[state.entity] or {}).scenes))
      C.add(result, '__clone__', 'Clone preset')
      C.add(result, '__reset_preset__', 'Reset preset overrides')
      if not builtin[state.entity] then C.add(result, '__delete__', 'Delete preset', nil, { detail = 'Refused while another preset inherits this one' }) end
    end
  end
  return result
end
local function identifier(value)
  return type(value) == 'string' and #value <= 48 and value:match('^[a-z][a-z0-9_-]*$') ~= nil,
    'Use a lowercase letter, then lowercase letters, digits, underscore or hyphen; at most 48 bytes'
end
local function new_preset(frame, ctx, session, clone)
  if not session.workspace_input then return false, 'Settings input is unavailable' end
  local data, baseline = C.profile(frame), I.baseline(frame)
  local source = clone and frame.data.entity
  local captured
  if source then
    captured = resolved(frame, source)
    captured.id, captured.name = nil, nil
    captured.extends = false
    captured.scenes = vim.empty_dict()
    for _, scene in ipairs(scenes) do
      local effective, overrides = resolved(frame, source, scene), vim.empty_dict()
      -- Complete scenes and an immutable factory root preserve the source
      -- without inheriting later parent declarations, scene styles or colors.
      for _, group in ipairs(groups) do overrides[group] = C.copy(effective[group]) end
      captured.scenes[scene] = overrides
    end
  end
  return session.workspace_input({ prompt = clone and 'New cloned preset ID' or 'New preset ID', kind = 'text', required = true,
    validate = function(value)
      local ok, why = identifier(value)
      if not ok then return false, why end
      return not builtin[value] and not config(data).presets[value], 'Preset ID already exists'
    end }, function(id)
    if id == nil then return end
    local ok = I.stage(frame, session, function(candidate)
      local value = editable(candidate)
      assert(not builtin[id] and not value.presets[id], 'Preset ID already exists')
      value.presets[id] = captured and Data.host(captured) or { extends = 'full' }
      value.presets[id].name = id
    end, nil, baseline)
    if ok then navigate(frame.data, 'presentation', id) end
  end, ctx)
end
function M.activate(frame, ctx, session, item)
  local state, id = frame.data, frame.data.entity
  if item.preset_id then return navigate(state, 'presentation', item.preset_id) end
  if item.id == '__create__' or item.id == '__clone__' then return new_preset(frame, ctx, session, item.id == '__clone__') end
  if item.id == '__import__' then return require('command_tree.settings.presentation_import').import(frame, ctx, session) end
  if item.id == '__export__' then
    if state.draft and #T.changes(frame) > 0 then return false, 'Apply or discard the Settings draft before exporting presentation presets' end
    return session.workspace_execute('settings.presentation_export', nil, ctx)
  end
  if item.id == '__select__' or item.id == '__legacy__' then
    return T.stage(frame, function(data) editable(data).selected = item.id == '__select__' and id or nil end)
  end
  if item.group then
    local scene = route(state)
    return navigate(state, scene and 'presentation:scene:' .. scene .. ':' .. item.group or 'presentation:' .. item.group, id)
  end
  if item.id == '__scenes__' then return navigate(state, 'presentation:scenes', id) end
  if item.scene then return navigate(state, 'presentation:scene:' .. item.scene, id) end
  if item.id:match('^__reset') or item.id == '__delete__' then return M.reset(frame, ctx, session, item) end
  if item.id == 'name' then
    return I.edit(frame, ctx, session, { prompt = 'Preset name', kind = 'text', default = item.value }, function(data, value) preset(data, id).name = value end)
  end
  if item.id == 'extends' then
    local items = { { value = '', label = 'Default parent' }, { value = false, label = 'Standalone defaults' } }
    for _, parent in ipairs(Core.ids(Data.core(config(C.profile(frame))))) do
      if parent ~= id then items[#items + 1] = { value = parent, label = name(C.profile(frame), parent) .. ' · ' .. parent } end
    end
    local current = (config(C.profile(frame)).presets[id] or {}).extends
    return I.edit(frame, ctx, session, { prompt = 'Parent preset', kind = 'select', items = items, required = false,
      default = current == nil and '' or current }, function(data, value)
        if value == '' then preset(data, id).extends = nil else preset(data, id).extends = value end
      end)
  end
  local scene, group = route(state)
  if item.role then
    return I.edit(frame, ctx, session, { prompt = item.label .. ' (#RRGGBB)', kind = 'text', default = item.value ~= 'Theme' and item.value or '',
      validate = function(value) return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil, 'Use an RGB color #RRGGBB' end },
      function(data, value)
        local current = style(data, id, scene)
        current.roles = current.roles or vim.empty_dict(); current.roles[item.role] = current.roles[item.role] or vim.empty_dict()
        current.roles[item.role][item.channel] = value
      end, note(id, scene, 'roles', item.role .. '.' .. item.channel, item.label, item.value))
  end
  local spec = item.field
  if not spec then return false, 'Select a presentation setting' end
  return I.edit(frame, ctx, session, { prompt = spec.label, kind = spec.kind, items = spec.items, default = item.value, min = spec.min, max = spec.max },
    function(data, value) local current = style(data, id, scene); current[group] = current[group] or vim.empty_dict(); current[group][spec.id] = value end,
    note(id, scene, group, spec.id, item.label, item.value))
end
function M.reset(frame, _, _, item)
  local state, id = frame.data, frame.data.entity
  local scene, group = route(state)
  local function reset(mutator)
    local ok, result = T.stage(frame, mutator)
    if ok then
      -- A reset must not reuse an earlier typed edit's proposed display value.
      for key in pairs(frame.data.notes or {}) do if key:match('^presentation%.') then frame.data.notes[key] = nil end end
      result = T.changes(frame)
    end
    return ok, result
  end
  if item.id == '__reset_all__' then return reset(function(data) data.presentation = nil end) end
  if item.id == '__delete__' then
    if builtin[id] then return false, 'Built-in presets cannot be deleted' end
    return reset(function(data)
      local current = editable(data)
      for other, spec in pairs(current.presets) do assert(other == id or spec.extends ~= id, 'Another preset inherits this preset: ' .. other) end
      current.presets[id] = nil
      if current.selected == id then current.selected = nil end
    end)
  end
  if item.id == '__reset_preset__' then
    return reset(function(data)
      local current = editable(data)
      if builtin[id] then current.presets[id] = nil
      else local spec = current.presets[id]; current.presets[id] = { name = spec.name, extends = spec.extends } end
    end)
  end
  if item.id == 'name' or item.id == 'extends' then
    return reset(function(data)
      local spec = config(data).presets[id]
      if spec and spec[item.id] ~= nil then preset(data, id)[item.id] = nil end
    end)
  end
  if item.id == '__reset_scenes__' or item.id == '__reset_scene__' or item.id == '__reset_group__' or item.field or item.role then
    return reset(function(data)
      if not config(data).presets[id] then return end
      local spec = preset(data, id)
      if item.id == '__reset_scenes__' then spec.scenes = nil
      elseif item.id == '__reset_scene__' then if spec.scenes then spec.scenes[scene] = nil end
      else
        local current = spec
        if scene then current = (spec.scenes or {})[scene] end
        if not current then return end
        if item.id == '__reset_group__' then current[group] = nil
        elseif item.field and current[group] then current[group][item.field.id] = nil
        elseif item.role and current.roles and current.roles[item.role] then current.roles[item.role][item.channel] = nil end
      end
    end)
  end
  return false, 'Select a preset override to reset'
end
function M.back(state)
  if not M.handles(state) then return false end
  local scene, group = route(state)
  if scene and group then return navigate(state, 'presentation:scene:' .. scene, state.entity, group) end
  if scene then return navigate(state, 'presentation:scenes', state.entity, 'scene:' .. scene) end
  if group then return navigate(state, 'presentation', state.entity, group == 'scenes' and '__scenes__' or group) end
  if state.entity then return navigate(state, 'presentation', nil, 'preset:' .. state.entity) end
  return navigate(state, nil, nil, '__presentation__')
end
return M
