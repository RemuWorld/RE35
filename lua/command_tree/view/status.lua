-- Only explicitly classified confirmations move into the title. Unknown
-- messages and diagnostics retain their warning/error path below the tree.
local M = {}
function M.prepare(V, data, opts)
  local notice = data.notice
  if type(notice) ~= 'table' or type(notice.message) ~= 'string' or type(notice.summary) ~= 'string'
    or notice.message ~= data.message then return data end
  local copy = vim.tbl_extend('force', {}, data)
  local model = opts.presentation
  local density = model and model.layout.density or opts.density or 'full'
  local info = model and model.information
  copy.message = nil
  if density == 'minimal' and not (info and info.title and info.status) or info and not info.status then return copy end
  if data.diagnostic or data.error then
    copy.message, copy.message_role = notice.message, 'normal'
    return copy
  end
  local viewport_width = opts.target_win and vim.api.nvim_win_is_valid(opts.target_win)
    and vim.api.nvim_win_get_width(opts.target_win) or vim.o.columns
  local available = math.min(model and model.layout.width or opts.width or 48, viewport_width - 2)
  if available < 24 or info and not info.title or model and model.decoration.border == 'none' then
    copy.message, copy.message_role = notice.message, 'normal'
  else copy.top_status = V.clip(notice.summary, 80) end
  return copy
end
function M.decorate(V, data, config, groups)
  if not data.top_status or type(config.title) ~= 'string' then return end
  local summary = V.clip(data.top_status, math.max(0, config.width - 12))
  if summary == '' then return end
  local title = V.clip(config.title, math.max(1, config.width - V.width(summary) - 3))
  config.title = { { title, groups and groups.accent or 'CommandTreeTitle' },
    { ' · ' .. summary, groups and groups.normal or 'CommandTreeDesc' } }
end
return M
