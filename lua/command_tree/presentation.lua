-- Host-owned negotiation and view options; appearance never changes authority.
local Core = require('command_environment.core.presentation')
local Data = require('command_tree.presentation_data')
local M = {}
local positions = { center = true, bottom = true, ['bottom-right'] = true, top = true, ['top-right'] = true }

function M.capabilities()
  return Core.capabilities('neovim')
end

function M.negotiate(model, scene)
  local effective, fallbacks = Core.negotiate(model, M.capabilities())
  if not effective then return nil, fallbacks end
  return effective, { contract_version = 1, host = 'neovim', preset_id = model.id,
    preset_name = model.name, scene = scene, fallbacks = fallbacks or {} }
end

local function explicit(config, state)
  return state and state.presentation_id ~= nil or type(config) == 'table'
    and (config.selected ~= nil or type(config.presets) == 'table' and next(config.presets) ~= nil)
end

function M.options(options, state, scene, overrides)
  options, state = options or {}, state or {}
  local legacy = vim.tbl_extend('force', {}, options.window or {}, overrides or {})
  legacy.density = state.density or legacy.density or 'full'
  -- Existing configurations keep the original renderer, geometry and density
  -- preference behavior until a named preset is explicitly selected/customized.
  if not explicit(options.presentation, state) then return legacy end
  local id = state.presentation_id or options.presentation and options.presentation.selected or legacy.density
  local inherited, legacy_position = legacy, nil
  if legacy.position ~= nil and not positions[legacy.position] then
    legacy_position = legacy.position
    inherited = vim.tbl_extend('force', {}, legacy, { position = 'center' })
  end
  local model, reason = Core.resolve(options.presentation and Data.core(options.presentation), id, scene, inherited)
  if not model then
    legacy.presentation_report = { contract_version = 1, host = 'neovim', scene = scene,
      error = tostring(reason), fallbacks = {} }
    return legacy
  end
  local effective, report = M.negotiate(model, scene)
  if not effective then
    legacy.presentation_report = { contract_version = 1, host = 'neovim', scene = scene,
      error = tostring(report), fallbacks = {} }
    return legacy
  end
  if legacy_position ~= nil then
    report.fallbacks[#report.fallbacks + 1] = { path = 'layout.position', requested = legacy_position,
      effective = effective.layout.position,
      reason = 'Legacy placement is unsupported by the shared contract; center is inherited before preset overrides' }
  end
  legacy.presentation, legacy.presentation_report, legacy.presentation_scene = effective, report, scene
  return legacy
end

return M
