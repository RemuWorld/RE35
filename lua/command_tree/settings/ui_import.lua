-- UI-only import uses the shared inert Settings import boundary.
local C = require('command_tree.settings.common')
local T = require('command_tree.settings.transaction')
local Files = require('command_tree.ui_export')
local Import = require('command_tree.settings.data_import')
local M = {}
local fields = {
  density = 'Density', icons = 'Icons', width = 'Width', max_width = 'Maximum width',
  max_height = 'Maximum height', position = 'Position', compact_rows = 'Compact rows', minimal_rows = 'Minimal rows',
}
local spec = { label = 'UI settings', row = '__import__',
  capture = function() return C.CE().export_ui() end,
  read = function(path) return Files.read(path) end,
  same = function(before, current)
    -- A temporary view change cannot retarget an import. Persisted changes
    -- still fail the complete profile/runtime comparison in data_import.
    current = vim.deepcopy(current)
    current.ui.density = before.ui.density
    return vim.deep_equal(before, current)
  end,
  stage = function(frame, imported, before, baseline)
    local ok, err = T.stage(frame, function(data) data.ui = vim.deepcopy(imported.ui) end, nil, baseline)
    if not ok then return false, err end
    for key, label in pairs(fields) do
      local old = C.display(before.ui[key])
      if baseline.profile.ui[key] == nil then old = 'Inherited (' .. old .. ')' end
      frame.data.notes['ui.' .. key] = { label = 'UI · ' .. label,
        before = old, after = C.display(imported.ui[key]) }
    end
    return true
  end,
}
function M.import(frame, ctx, session) return Import.import(spec, frame, ctx, session) end
function M.open(owner, ctx) return Import.open(spec, owner, ctx) end
return M
