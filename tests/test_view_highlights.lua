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
local function has_style(part, phrase, bold, fg, bg, label)
  local found = false
  for _, attrs in ipairs(marks_for(part, phrase)) do
    if (attrs.bold == true) == bold and (fg == nil or attrs.fg == fg) and (bg == nil or attrs.bg == bg) then found = true end
  end
  H.ok(found, label .. ': ' .. phrase)
end
local function selected_row(part, phrase)
  local lines = vim.api.nvim_buf_get_lines(part.buf, 0, -1, false)
  for row, text in ipairs(lines) do
    if text:find(phrase, 1, true) then
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(part.buf, -1, 0, -1, { details = true })) do
        if mark[2] == row - 1 and mark[3] == 0 and mark[4].end_col == #text and mark[4].hl_eol and mark[4].priority == 90 then
          return true
        end
      end
    end
  end
  return false
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
  vim.api.nvim_set_hl(0, 'PmenuSel', { fg = 0xFFFFFF, bg = 0x505050 })
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
      has_style(view, 'Action', false, 0xFFFFFF, 0x505050, 'Selected actions keep selected palette and plain text')
      has_style(view, '▸ Group', true, normal, nil, 'Branches use a consistent marker and readable bold text')
      H.ok(selected_row(view, 'Action'), 'Selection extends across the whole row including trailing cells')
      data.selected = 2
      V.draw(view, data, opts)
      has_style(view, '▸ Group', true, 0xFFFFFF, 0x505050, 'Selected branches retain branch emphasis')
      H.ok(selected_row(view, '▸ Group'), 'Selected branch row includes horizontal padding and trailing cells')
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

-- Branch markers survive clipped labels without sacrificing an impossible
-- one-cell command identity. Preset colors also cover every selected segment.
for _, preset in ipairs({ false, true }) do
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    for _, width in ipairs({ 10, 48 }) do
      local configured = { window = { layout = 'dynamic', density = density, width = width,
        max_width = width, max_height = 12, icons = false } }
      if preset then configured.presentation = { version = 1, selected = 'scan', presets = {
        scan = { extends = density, layout = { width = width, max_width = width }, roles = {
          normal = { fg = '#ABCDEF', bg = '#102030' }, selected = { fg = '#FEDCBA', bg = '#405060' } } } } } end
      local opts = P.options(configured, { density = density }, 'tree')
      local view, data = {}, { path = '\\', selected = 1, items = {
        { key = 'branch', name = 'Group ' .. string.rep('very long ', 30), group = true } } }
      V.draw(view, data, opts)
      local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), '\n')
      H.ok(text:find('▸', 1, true), 'Long branch marker survives clipping: ' .. density .. '/' .. width)
      H.ok(selected_row(view, '▸'), 'Narrow selection covers the complete row: ' .. density .. '/' .. width)
      if preset then
        has_style(view, '▸', true, 0xFEDCBA, 0x405060, 'Preset selected branch uses selected semantic colors')
        for _, attrs in ipairs(marks_for(view, '▸')) do
          H.eq(0x405060, attrs.bg, 'Selected marker has no opaque normal-color patch')
        end
        data.selected = nil
        V.draw(view, data, opts)
        if density ~= 'minimal' then
          has_style(view, '▸', true, 0xABCDEF, 0x102030, 'Preset branch inherits normal semantic colors')
        end
      end
      data.selected, data.items[1].disabled = 1, true
      V.draw(view, data, opts)
      H.ok(selected_row(view, '▸'), 'Disabled selected branches retain visible selection and structure')
      V.close(view)
    end
  end
end
H.eq('x', V.item_name({ name = 'x', group = true }, 1), 'One-cell identity yields the decorative marker')

-- ColorScheme clears host groups, and later palette changes must refresh only
-- still-owned derived defaults rather than freezing materialized colors.
vim.cmd('highlight clear')
vim.api.nvim_set_hl(0, 'NormalFloat', { fg = 0x112233, bg = 0x223344 })
vim.api.nvim_set_hl(0, 'PmenuSel', { fg = 0x334455, bg = 0x445566 })
V.highlights()
for _, palette in ipairs({ { 0x556677, 0x667788, 0x778899, 0x8899AA }, { 0x99AABB, 0xAABBCC, 0xBBCCDD, 0xCCDDEE } }) do
  vim.api.nvim_set_hl(0, 'NormalFloat', { fg = palette[1], bg = palette[2] })
  vim.api.nvim_set_hl(0, 'PmenuSel', { fg = palette[3], bg = palette[4] })
  vim.api.nvim_set_hl(0, 'FloatBorder', { fg = palette[3], bg = 0x010101, reverse = true })
  V.highlights()
  local branch = vim.api.nvim_get_hl(0, { name = 'CommandTreeGroup', link = false })
  local selected = vim.api.nvim_get_hl(0, { name = 'CommandTreeSelectedGroup', link = false })
  local border = vim.api.nvim_get_hl(0, { name = 'CommandTreeBorder', link = false })
  H.eq(palette[1], branch.fg, 'Derived branch foreground follows ColorScheme palette')
  H.eq(palette[2], branch.bg, 'Derived branch background follows ColorScheme palette')
  H.eq(palette[3], selected.fg, 'Derived selected branch foreground follows ColorScheme palette')
  H.eq(palette[4], selected.bg, 'Derived selected branch background follows ColorScheme palette')
  H.eq(true, branch.bold, 'Theme refresh keeps default branch emphasis')
  H.eq(palette[3], border.fg, 'Owned border follows a palette-only foreground change')
  H.eq(palette[2], border.bg, 'Owned border follows the panel background without highlight clear')
  H.ok(not border.reverse, 'A reversed theme separator cannot reverse the panel border')
end
local preset_view, inherited_colors = {}, { window = { density = 'full', width = 48, icons = false },
  presentation = { version = 1, selected = 'palette', presets = { palette = { extends = 'full', roles = {
    normal = { bg = '#010203' }, selected = { bg = '#040506' } } } } } }
local preset_opts = P.options(inherited_colors, {}, 'tree')
for _, palette in ipairs({ { 0x223344, 0x556677 }, { 0x8899AA, 0xBBCCDD } }) do
  vim.api.nvim_set_hl(0, 'NormalFloat', { fg = palette[1], bg = 0x001122 })
  vim.api.nvim_set_hl(0, 'PmenuSel', { fg = palette[2], bg = 0x334455 })
  V.highlights()
  V.draw(preset_view, { path = '\\', selected = 2, items = {
    { key = 'a', name = 'Ordinary group', group = true }, { key = 'b', name = 'Selected group', group = true } } }, preset_opts)
  has_style(preset_view, 'Ordinary group', true, palette[1], 0x010203, 'Preset branch refreshes inherited foreground')
  has_style(preset_view, 'Selected group', true, palette[2], 0x040506, 'Preset selected branch refreshes inherited foreground')
end
V.close(preset_view)

-- Simultaneous legacy feedback fields must display the actual error with its
-- severity, rather than painting a less important message as that error.
vim.api.nvim_set_hl(0, 'DiagnosticError', { fg = 0xD02020 })
local feedback = {}
V.draw(feedback, { path = '\\', items = {}, message = 'Secondary message', error = 'Primary failure' },
  { layout = 'dynamic', density = 'full', width = 48, max_width = 60, max_height = 16 })
has_fg(feedback, 'Primary failure', 0xD02020, 'Inline feedback prioritizes actual error text and severity')
V.close(feedback)

-- Main, Keys and Details share decoration colors on real floating windows.
-- The legacy host accent and authored preset accents retain their precedence.
vim.o.columns, vim.o.lines = 180, 48
local function window_role(part, role)
  for from, group in vim.wo[part.win].winhighlight:gmatch('([^:,]+):([^,]+)') do
    if from == role then return group end
  end
end
local function consistent_borders(view, fg, bg, label)
  H.ok(view.guide and view.details, label .. ': actual Keys and Details panels exist')
  local group = window_role(view, 'FloatBorder')
  for _, part in ipairs({ view, view.guide, view.details }) do
    H.eq(group, window_role(part, 'FloatBorder'), label .. ': each panel uses the same border role')
    local attrs = vim.api.nvim_get_hl(0, { name = window_role(part, 'FloatBorder'), link = false })
    H.eq(fg, attrs.fg, label .. ': border foreground is consistent')
    H.eq(bg, attrs.bg, label .. ': border background is consistent')
  end
end
local panel_data = { path = '\\', selected = 1,
  items = { { key = 'a', name = 'Action' }, { key = 'g', name = 'Group', group = true } },
  help = 'Esc Back  ·  Enter Run  ·  / Search', details = { description = 'Context stays below' } }
local palette_view = {}
local palette_options = P.options({ window = { layout = 'fixed', density = 'full', width = 48,
  max_width = 72, max_height = 12, details = { enabled = true, max_height = 4 } } }, {}, 'tree')
for _, palette in ipairs({ { 0x123456, 0x223344 }, { 0x654321, 0x334455 } }) do
  vim.api.nvim_set_hl(0, 'NormalFloat', { fg = 0xEEEEEE, bg = palette[2] })
  vim.api.nvim_set_hl(0, 'FloatBorder', { fg = palette[1], bg = 0x010101 })
  V.highlights()
  V.draw(palette_view, panel_data, palette_options)
  consistent_borders(palette_view, palette[1], palette[2], 'Default after palette-only transition')
end
V.close(palette_view)
local local_accent = vim.deepcopy(palette_options)
local_accent.accent = '#C08020'
V.draw(palette_view, panel_data, local_accent)
consistent_borders(palette_view, 0xC08020, 0x334455, 'Explicit host window accent')
V.close(palette_view)
local preset_accent = P.options({ window = { layout = 'fixed', density = 'full', width = 48,
  max_width = 72, max_height = 12, accent = '#C08020', details = { enabled = true, max_height = 4 } },
  presentation = { version = 1, selected = 'decorated', presets = { decorated = {
    extends = 'full', roles = { normal = { bg = '#102030' }, accent = { fg = '#AA55CC', bg = '#223344' } } } } } }, {}, 'tree')
V.draw(palette_view, panel_data, preset_accent)
consistent_borders(palette_view, 0xAA55CC, 0x223344, 'Authored preset accent takes precedence')
V.close(palette_view)

-- Host defaults must never overwrite explicit user choices on redraw/setup.
vim.api.nvim_set_hl(0, 'CommandTreeKey', { fg = 0x123456, bold = true })
vim.api.nvim_set_hl(0, 'CommandTreeGroup', { fg = 0x654321, bold = false, underline = true })
vim.api.nvim_set_hl(0, 'CommandTreeError', { link = 'Special' })
vim.api.nvim_set_hl(0, 'CommandTreeBorder', { fg = 0xABCDEF, bg = 0x010203, bold = true })
local custom = {}
for _, name in ipairs({ 'CommandTreeKey', 'CommandTreeGroup', 'CommandTreeError', 'CommandTreeBorder' }) do
  custom[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
end
V.highlights(); V.highlights()
for name, attrs in pairs(custom) do
  H.eq(attrs, vim.api.nvim_get_hl(0, { name = name, link = true }), 'Explicit user highlight is preserved: ' .. name)
end
H.ok(not vim.api.nvim_get_hl(0, { name = 'CommandTreeSelectedGroup', link = false }).bold,
  'Explicit plain branch style also remains plain while selected')
H.eq(true, vim.api.nvim_get_hl(0, { name = 'CommandTreeSelectedGroup', link = false }).underline,
  'Explicit branch underline also survives selection')
V.draw(palette_view, panel_data, palette_options)
consistent_borders(palette_view, 0xABCDEF, 0x010203, 'Explicit border color and style override')
H.eq(true, vim.api.nvim_get_hl(0, { name = 'CommandTreeBorder', link = false }).bold,
  'Explicit border style is retained')
V.close(palette_view)
vim.api.nvim_set_hl(0, 'CommandTreeBorder', { link = 'Special' })
vim.api.nvim_set_hl(0, 'NormalFloat', { fg = 0xEEEEEE, bg = 0x445566 })
vim.api.nvim_set_hl(0, 'FloatBorder', { fg = 0x112233 })
V.highlights()
H.eq({ link = 'Special' }, vim.api.nvim_get_hl(0, { name = 'CommandTreeBorder', link = true }),
  'Explicit border link survives a subsequent palette refresh')
print('Rendered color roles and user overrides passed: ' .. H.checks .. ' checks')
