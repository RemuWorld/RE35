-- History uses the shared fixed shortcut guide and its below-panel fallback.
-- Native geometry/state assertions do not constitute human visual approval.
local H, K = require('helpers'), require('command_tree.keys')
local History, V, P = require('command_tree.history_mode'), require('command_tree.view'), require('command_tree.presentation')
vim.o.swapfile, vim.o.cmdheight = false, 1
vim.o.columns, vim.o.lines = 120, 40
V.highlights()
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'history guide source', 'second line' })
local original = { lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
  tick = vim.api.nvim_buf_get_changedtick(source), cursor = vim.api.nvim_win_get_cursor(source_win) }
local action_keys = { undo = 'z', redo = 'y', timeline = 'T', refresh = '<F6>', restore = '<F7>',
  next = 'n', previous = 'p', page_up = '<M-u>', page_down = '<M-d>', back = '<Esc>' }
local function options(density, preset, position)
  local config = { window = { density = density } }
  if preset then
    config.presentation = { version = 1, selected = 'fixture', presets = { fixture = {
      name = 'History authored mode', extends = density,
      layout = { position = 'center', width = 92, max_width = 100, max_height = 24 },
      spacing = { horizontal = 2 }, roles = { accent = { fg = '#AABBCC' } }, information = { icons = true },
    } } }
  end
  local base = P.options(config, { density = density }, 'tree')
  return { width = 38, max_width = 64, density = density, position = position,
    presentation = base.presentation, action_keys = action_keys, close_key = '<F8>', detail_key = '<F9>' }
end
local function geometry(part)
  local config = vim.api.nvim_win_get_config(part.win)
  return { row = config.row, col = config.col, width = config.width, height = config.height }
end
local function border(config) return type(config.border) == 'table' and #config.border > 0 and 2 or 0 end
local function text(part)
  return table.concat(vim.api.nvim_buf_get_lines(part.buf, 0, -1, false), '\n'):gsub(' +', ' ')
end
local function hint(part, key, label)
  H.ok(text(part):find(key .. ' ' .. label, 1, true), 'The History guide shows actual ' .. key .. ' ' .. label)
end
local function full(view, state)
  H.eq('right', view.panel_report.guide)
  H.ok(view.guide and vim.api.nvim_win_is_valid(view.guide.win), 'Full History has a dedicated guide beside the HUD')
  local main, guide = vim.api.nvim_win_get_config(view.win), vim.api.nvim_win_get_config(view.guide.win)
  local display = vim.api.nvim_win_get_config(state.source_display.win)
  H.eq(30, guide.width, 'History uses the same 30-cell dedicated guide as Commands')
  H.eq(main.col + main.width + border(main) + 1, guide.col)
  H.eq(display.col + display.width, guide.col + guide.width + border(guide),
    'Default History anchors the complete HUD and guide group at the source bottom-right')
  H.ok(guide.row >= display.row and guide.row + guide.height + border(guide) <= display.row + display.height)
  hint(view.guide, 'z', 'Undo'); hint(view.guide, 'y', 'Redo'); hint(view.guide, 'F6', 'Refresh')
  hint(view.guide, 'F9', 'View'); hint(view.guide, 'F8', 'Close')
  H.ok(not text(view.guide):find('u Undo', 1, true), 'Disabled original undo key never appears as an active shortcut')
end

for _, preset in ipairs({ false, true }) do
  local state = { ctx = K.context() }
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    local opts = options(density, preset)
    local model_before = vim.deepcopy(opts.presentation)
    History.draw(state, opts)
    H.eq(38, vim.api.nvim_win_get_width(state.hud.win), 'History-local width survives the selected mode')
    if density == 'full' then full(state.hud, state); hint(state.hud.guide, 'T', 'Timeline')
    else H.eq(nil, state.hud.guide, density .. ' releases the dedicated Full guide') end
    H.eq(model_before, opts.presentation, 'History does not mutate the shared authored presentation model')
    if preset then
      H.eq(2, state.hud.presentation_options.presentation.spacing.horizontal, 'Authored spacing survives History-local geometry')
      H.eq('#AABBCC', state.hud.presentation_options.presentation.roles.accent.fg, 'Authored colors survive History-local geometry')
      H.eq(density, state.hud.presentation_options.presentation.layout.density)
    end
    local hud_geometry = geometry(state.hud)
    state.message = 'An independently inspectable History message'
    History.draw(state, opts)
    H.eq(hud_geometry, geometry(state.hud), 'Messages do not move or resize the History HUD')
    state.message = nil
    H.ok(History.timeline(state))
    History.draw(state, opts)
    H.eq(52, vim.api.nvim_win_get_width(state.timeline_view.win), 'Timeline-local width survives the selected mode')
    if density == 'full' then
      full(state.timeline_view, state)
      hint(state.timeline_view.guide, 'p/n', 'Select')
      hint(state.timeline_view.guide, 'Alt+u/d', 'Page')
      hint(state.timeline_view.guide, 'F7', 'Restore')
      H.ok(not text(state.timeline_view.guide):find('T Timeline', 1, true), 'Timeline guide lists its active controls')
    else H.eq(nil, state.timeline_view.guide) end
    local timeline_geometry = geometry(state.timeline_view)
    History.handle(state, 'k', opts); History.draw(state, opts)
    H.eq(timeline_geometry, geometry(state.timeline_view), 'Timeline selection never moves or resizes its HUD')
    H.eq(model_before, opts.presentation, 'Timeline also preserves the shared model')
    state.timeline = nil
  end
  -- The explicit History position is applied to the private mode copy too.
  local opts = options('full', preset, 'top-right')
  History.draw(state, opts)
  local display = vim.api.nvim_win_get_config(state.source_display.win)
  H.eq(display.row + 1, vim.api.nvim_win_get_config(state.hud.win).row, 'Explicit History top-right placement is honored')
  History.clear(state)
end

-- A real remapped workspace drives the same guide rather than hardcoded keys.
local manager = require('command_tree.workspaces').new()
manager:configure({ history = { keys = { u = false, z = 'undo', t = false, T = 'timeline',
  j = false, n = 'next', k = false, p = 'previous', ['<CR>'] = false, ['<F7>'] = 'restore',
  R = false, ['<F6>'] = 'refresh' } } }, { close = '\\', detail = '?' })
local session = { ctx = K.context(), mode = 'workspace', running = true, stack = {}, path = {}, view = {}, density = 'full' }
local opts = { window = { width = 38 }, keys = { detail = '?' }, open_key = '\\' }
local frame = H.ok(manager:push(session, 'history'))
manager:draw(session, opts)
hint(frame.data.hud.guide, 'z', 'Undo'); hint(frame.data.hud.guide, 'T', 'Timeline')
H.eq(false, manager:handle(session, 't', opts))
H.ok(manager:handle(session, 'T', opts)); H.ok(frame.data.timeline)
manager:draw(session, opts)
hint(frame.data.timeline_view.guide, 'p/n', 'Select')
hint(frame.data.timeline_view.guide, 'F7', 'Restore')
manager:clear(session)

-- Below-panel fallback is exercised by shrinking the real source viewport.
for _, preset in ipairs({ false, true }) do
  vim.o.columns = 60
  local state = { ctx = K.context() }
  History.draw(state, options('full', preset))
  H.eq(nil, state.hud.guide); H.eq('below', state.hud.panel_report.guide)
  H.ok(state.hud.details and state.hud.details.total > 0, 'Narrow Full retains actionable hints below the HUD')
  H.ok(History.timeline(state)); History.draw(state, options('full', preset))
  H.eq(nil, state.timeline_view.guide); H.eq('below', state.timeline_view.panel_report.guide)
  H.ok(state.timeline_view.details and state.timeline_view.details.total > 0)
  History.clear(state)
end
H.eq(original.lines, vim.api.nvim_buf_get_lines(source, 0, -1, false))
H.eq(original.tick, vim.api.nvim_buf_get_changedtick(source)); H.eq(original.cursor, vim.api.nvim_win_get_cursor(source_win))
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative) end
print('History shared shortcut guide: ' .. H.checks .. ' checks passed')
