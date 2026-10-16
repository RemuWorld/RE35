-- Host-only compatibility input. Stored profiles and the portable presentation
-- contract are unchanged; all scenes leave here with one complete view model.
local M = {}

function M.normalize(data, opts)
  opts = opts or {}
  if opts._display and opts._display.source == 'preset' then return opts end
  local effective = vim.tbl_extend('force', {}, opts)
  if opts.presentation and not (opts._display and opts._display.source == 'legacy') then
    effective._display = { source = 'preset' }
    return effective
  end
  local density = opts.density or 'full'
  local model = assert(require('command_environment.core.presentation').resolve(nil, density))
  for _, field in ipairs({ 'width', 'max_width', 'max_height', 'position' }) do
    if opts[field] ~= nil then model.layout[field] = opts[field] end
  end
  model.layout.max_width = opts.max_width or 72
  model.layout.rows = density == 'minimal' and (opts.minimal_rows or 3)
    or density == 'compact' and (opts.compact_rows or 6) or (opts.max_height or 16)
  if opts.icons ~= nil then model.information.icons = opts.icons end
  -- Fixed question/review scenes have always used complete-value wrapping.
  -- Preserve that row vocabulary without promoting to a different renderer.
  local required = data.input or data.review or data.required_review or data.required_label
    or data.target or data.required_notice or type(data.required_facts) == 'table' and next(data.required_facts) ~= nil
  local ordinary = not (opts.layout == 'fixed' and required)
  effective.presentation = model
  effective._display = { source = 'legacy', legacy_geometry = ordinary, legacy_rows = ordinary }
  return effective
end

return M
