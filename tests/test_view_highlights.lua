-- Real rendered highlight roles under themes with deliberately dim comments.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.columns, vim.o.lines = 100, 42
local V, P = require('command_tree.view'), require('command_tree.presentation')

local function marks_for(part, phrase)
  local lines = vim.api.nvim_buf_get_lines(part.buf, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(part.buf, -1, 0, -1, { details = true })
  local result = {}
  for row, line in ipairs(lines) do
    local first, last = line:find(phrase, 1, true)
    if first then
      for _, mark in ipairs(marks) do
        if mark[2] == row - 1 and mark[3] <= first - 1 and (mark[4].end_col or 0) >= last then
          local group = mark[4].hl_group
          if type(group) == 'number' then group = vim.api.nvim_get_hl_name_by_id(group) end
          result[#result + 1] = vim.api.nvim_get_hl(0, { name = group, link = false })
        end
      end
    end
  end
  return result
end
local function has_fg(part, phrase, fg, label)
  local found = false
  for _, attrs in ipairs(marks_for(part, phrase)) do if attrs.fg == fg then found = true end end
  H.ok(found, label .. ': ' .. phrase)
end

for _, background in ipairs({ 'dark', 'light' }) do
  vim.o.background = background
  vim.cmd('highlight clear')
  local normal = background == 'dark' and 0xE8E8E8 or 0x181818
  local panel = background == 'dark' and 0x181818 or 0xF0F0F0
  local muted = background == 'dark' and 0x303030 or 0xDDDDDD
  vim.api.nvim_set_hl(0, 'Normal', { fg = normal, bg = panel })
  vim.api.nvim_set_hl(0, 'NormalFloat', { fg = normal, bg = panel })
  vim.api.nvim_set_hl(0, 'Comment', { fg = muted })
  vim.api.nvim_set_hl(0, 'Keyword', { fg = 0xA020C0 })
  vim.api.nvim_set_hl(0, 'Function', { fg = 0x208080 })
  vim.api.nvim_set_hl(0, 'DiagnosticWarn', { fg = 0xC08020 })
  vim.api.nvim_set_hl(0, 'DiagnosticError', { fg = 0xD02020 })
  V.highlights()
  H.eq(normal, vim.api.nvim_get_hl(0, { name = 'CommandTreeGroup', link = false }).fg,
    'Group labels use readable panel text rather than syntax Keyword color')
  H.eq(vim.api.nvim_get_hl(0, { name = 'CommandTreeKey', link = false }).fg,
    vim.api.nvim_get_hl(0, { name = 'CommandTreeIcon', link = false }).fg,
    'Navigation icons and keys share one accent')
  H.eq(0xD02020, vim.api.nvim_get_hl(0, { name = 'CommandTreeError', link = false }).fg,
    'Errors have their own diagnostic severity')
  for _, preset in ipairs({ false, true }) do
    for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
      local configured = { window = { layout = 'fixed', density = density, width = 60,
        max_height = 12, icons = false, details = { max_height = 8 } } }
      if preset then configured.presentation = { version = 1, selected = density, presets = {} } end
      local opts = P.options(configured, { density = density }, 'tree')
      local view, data = {}, { path = '\\', selected = 1, items = {
        { key = 'a', name = 'Action' }, { key = 'g', name = 'Group', group = true } },
        diagnostic = { message = 'Preview failed', full_message = 'Preview failed clearly' },
        details = { description = 'Readable description', target = 'src/main.cpp', kind = 'picker', source = 'builtin' },
        help = 'Esc Back  ·  Enter Run' }
      V.draw(view, data, opts)
      H.ok(view.details, 'Errors remain inspectable in every density')
      has_fg(view.details, 'Preview failed clearly', 0xD02020, 'Rendered error retains diagnostic severity')
      if density == 'full' then
        has_fg(view.details, 'Readable description', normal, 'Description does not inherit dim comments')
        has_fg(view.details, 'src/main.cpp', normal, 'Target remains readable')
        has_fg(view.details, 'Back', normal, 'Shortcut label remains readable')
      else
        local text = table.concat(vim.api.nvim_buf_get_lines(view.details.buf, 0, -1, false), '\n')
        H.ok(not text:find('Esc Back', 1, true), 'Reduced densities still omit routine hints')
      end
      V.close(view)
    end
  end
end

-- Simultaneous legacy feedback fields must display the actual error with its
-- severity, rather than painting a less important message as that error.
local feedback = {}
V.draw(feedback, { path = '\\', items = {}, message = 'Secondary message', error = 'Primary failure' },
  { layout = 'dynamic', density = 'full', width = 48, max_width = 60, max_height = 16 })
has_fg(feedback, 'Primary failure', 0xD02020, 'Inline feedback prioritizes actual error text and severity')
V.close(feedback)

-- Host defaults must never overwrite explicit user choices on redraw/setup.
vim.api.nvim_set_hl(0, 'CommandTreeKey', { fg = 0x123456, bold = true })
vim.api.nvim_set_hl(0, 'CommandTreeGroup', { fg = 0x654321 })
vim.api.nvim_set_hl(0, 'CommandTreeError', { link = 'Special' })
local custom = {}
for _, name in ipairs({ 'CommandTreeKey', 'CommandTreeGroup', 'CommandTreeError' }) do
  custom[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
end
V.highlights(); V.highlights()
for name, attrs in pairs(custom) do
  H.eq(attrs, vim.api.nvim_get_hl(0, { name = name, link = true }), 'Explicit user highlight is preserved: ' .. name)
end
print('Rendered color roles and user overrides passed: ' .. H.checks .. ' checks')
