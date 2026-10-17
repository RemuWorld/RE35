-- Window redraws compare actual host state. Avoiding unchanged writes must
-- never hide edits/options changed by another plugin or leave buffers writable.
local H, View = require('helpers'), require('command_tree.view')
View.highlights()
local view, lines = {}, {'first line', 'second line'}
local function config()
  return {relative='editor', row=2, col=2, width=30, height=2, border='rounded'}
end
View.window(view, lines, config())
local set_option, set_lines = vim.api.nvim_set_option_value, vim.api.nvim_buf_set_lines
local option_writes, content_writes, redundant_window_writes = 0, 0, 0
vim.api.nvim_set_option_value = function(name, value, opts)
  if opts and (opts.win == view.win or opts.buf == view.buf) then option_writes=option_writes+1 end
  if opts and opts.win == view.win and vim.api.nvim_get_option_value(name, opts) == value then
    redundant_window_writes=redundant_window_writes+1
  end
  return set_option(name, value, opts)
end
vim.api.nvim_buf_set_lines = function(buf, ...)
  if buf == view.buf then content_writes=content_writes+1 end
  return set_lines(buf, ...)
end
View.window(view, lines, config())
H.eq(0, content_writes, 'Identical text does not rewrite a companion buffer')
-- Neovim 0.11 reapplies some style=minimal defaults during set_config. Those
-- genuinely changed values must still be repaired, never cached as correct.
H.eq(0, redundant_window_writes, 'Window setters run only when the actual option differs')

local desired={winblend=0, wrap=false, scrolloff=0, sidescrolloff=0,
  cursorline=false, signcolumn='no', statuscolumn=''}
for name, value in pairs({winblend=15, wrap=true, scrolloff=3, sidescrolloff=3,
  cursorline=true, signcolumn='yes', statuscolumn='%l'}) do
  set_option(name, value, {win=view.win})
end
set_option('winhighlight', 'Normal:ErrorMsg', {win=view.win})
set_option('modifiable', true, {buf=view.buf})
set_lines(view.buf, 0, -1, false, {'foreign contents'})
option_writes, content_writes=0, 0
View.window(view, lines, config())
H.eq(lines, vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), 'Fresh reads detect and repair foreign text edits')
H.eq(1, content_writes, 'Changed contents are replaced once')
for name, value in pairs(desired) do H.eq(value, vim.api.nvim_get_option_value(name, {win=view.win}), name) end
H.eq(false, vim.api.nvim_get_option_value('modifiable', {buf=view.buf}))
H.ok(vim.api.nvim_get_option_value('winhighlight', {win=view.win}):find('Normal:CommandTreeNormal', 1, true))

-- A foreign change to writability also needs repair when text still matches.
set_option('modifiable', true, {buf=view.buf})
content_writes=0
View.window(view, lines, config())
H.eq(0, content_writes)
H.eq(false, vim.api.nvim_get_option_value('modifiable', {buf=view.buf}))
View.window(view, lines, config(), 'HistoryModeFrame')
H.eq('Normal:HistoryModeFrame,EndOfBuffer:HistoryModeFrame',
  vim.api.nvim_get_option_value('winhighlight', {win=view.win}), 'Explicit frame styling is still applied')
vim.api.nvim_set_option_value, vim.api.nvim_buf_set_lines=set_option, set_lines
H.ok(View.close(view))
print('Window update checks: ' .. H.checks)
