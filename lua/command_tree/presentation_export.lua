-- Host-neutral appearance declarations; no commands, roots or execution data.
local M = {}
local Data = require('command_tree.presentation_data')
local Core = require('command_environment.core.presentation_edit')
local Files = require('command_tree.ui_export')
local LIMIT = 65536
function M.validate(data)
  if type(data) ~= 'table' then return nil, 'Presentation file must be an object' end
  local ok, plain = pcall(Data.core, data)
  if not ok then return nil, tostring(plain) end
  local normalized, err = Core.file_validate(plain)
  if not normalized then return nil, err end
  local result = Data.host(normalized)
  if #vim.json.encode(result) + 1 > LIMIT then return nil, 'Presentation file exceeds 64 KiB' end
  return result
end
function M.capture(config, selected)
  local value, err = Data.validate(config or { version = 1, presets = vim.empty_dict() })
  if not value then return nil, err end
  value.selected = selected or value.selected or 'full'
  return M.validate({ format = 're35.presentation', version = 1, presentation = value })
end
local codec = { limit = LIMIT, validate = M.validate }
function M.read(path) return Files.read(path, codec) end
function M.export(data, path, protected, validate) return Files.export(data, path, protected, validate, codec) end
M.protected = Files.protected
return M
