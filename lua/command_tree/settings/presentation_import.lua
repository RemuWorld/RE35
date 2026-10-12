-- Appearance import stages one detached Settings draft; it cannot execute.
local M = {}
local C, T = require('command_tree.settings.common'), require('command_tree.settings.transaction')
local Files, Import = require('command_tree.presentation_export'), require('command_tree.settings.data_import')
local Presentation = require('command_tree.presentation')
local spec = { label = 'Presentation presets', row = '__import__', detail = 'presentation',
  capture = function() return C.CE().export_presentation() end,
  read = function(path) return Files.read(path) end,
  same = function(before, current)
    -- Ignore only the temporary display choice; applied declarations are
    -- guarded by the complete profile/runtime baseline in data_import.
    current = vim.deepcopy(current)
    current.presentation.selected = before.presentation.selected
    return vim.deep_equal(before, current)
  end,
  stage = function(frame, imported, before, baseline)
    local config = imported.presentation
    local conflicts = {}
    for id in pairs(config.presets) do
      if before.presentation.presets[id] then conflicts[#conflicts + 1] = id end
    end
    table.sort(conflicts)
    local defaults = C.CE().ui_defaults()
    local options = Presentation.options({ presentation = config, window = defaults },
      { presentation_id = config.selected or defaults.density }, 'tree')
    if not options.presentation then return false, options.presentation_report.error end
    local fallbacks = options.presentation_report.fallbacks
    local ok, reason = T.stage(frame, function(profile) profile.presentation = vim.deepcopy(config) end, nil, baseline)
    if not ok then return false, reason end
    frame.data.message = 'Import replaces presentation declarations; ' .. #conflicts .. ' conflicting preset IDs · ' .. #fallbacks .. ' host fallbacks'
    return true
  end,
}
function M.import(frame, ctx, session) return Import.import(spec, frame, ctx, session) end
function M.open(owner, ctx) return Import.open(spec, owner, ctx) end
return M
