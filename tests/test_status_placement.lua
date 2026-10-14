local H = require('helpers')
local V, P = require('command_tree.view'), require('command_tree.presentation')
vim.o.columns, vim.o.lines = 100, 42
V.highlights()
local function body(part)
  return part and part.buf and table.concat(vim.api.nvim_buf_get_lines(part.buf, 0, -1, false), '\n') or ''
end
local function title(view)
  local result = ''
  for _, chunk in ipairs(vim.api.nvim_win_get_config(view.win).title or {}) do result = result .. chunk[1] end
  return result
end
local function footprint(view)
  local c = vim.api.nvim_win_get_config(view.win)
  return { c.row, c.col, c.width, c.height }
end
local message = 'View saved · restored at startup'
for _, preset in ipairs({ false, true }) do
  local configured = { window = { layout = 'fixed', density = 'full', width = 52, max_height = 16, icons = false } }
  if preset then configured.presentation = { version = 1, selected = 'full', presets = {} } end
  local opts, view = P.options(configured, {}, 'tree'), {}
  local data = { path = '\\', items = { { key = 'a', name = 'Run' } }, selected = 1 }
  V.draw(view, data, opts)
  local original = footprint(view)
  data.message, data.notice = message, { message = message, summary = 'Saved · startup' }
  V.draw(view, data, opts)
  H.ok(title(view):find('Saved · startup', 1, true), 'Explicit save confirmation is near the title')
  H.ok(not (body(view) .. body(view.details)):find(message, 1, true), 'Confirmation no longer occupies warning/context rows')
  H.eq(original, footprint(view), 'Moving routine status never resizes or moves main')
  local chunks = vim.api.nvim_win_get_config(view.win).title
  H.ok(chunks[#chunks][2] ~= 'CommandTreeWarning', 'Confirmation uses neutral text semantics')
  data.message = 'View changed for this session; saving failed: disk denied'
  V.draw(view, data, opts)
  H.ok(not title(view):find('Saved · startup', 1, true), 'Stale success cannot label a storage failure')
  H.ok(table.concat(view.details.lines, ''):find('disk denied', 1, true), 'Storage failure remains inspectable across wrapped rows below')
  data.message, data.error = message, 'A real error'
  V.draw(view, data, opts)
  H.ok(not title(view):find('Saved · startup', 1, true), 'An error is not hidden by a success notice')
  H.ok(body(view.details):find('A real error', 1, true), 'Error stays in contextual diagnostics')
  V.close(view)
end

local view = {}
V.draw(view, { path = '\\', items = {}, message = message, notice = { message = message, summary = 'Saved · startup' } },
  { layout = 'fixed', density = 'minimal', width = 48, max_height = 16 })
H.eq(1, vim.api.nvim_win_get_config(view.win).height, 'Minimal keeps one passive reading row')
H.eq(nil, vim.api.nvim_win_get_config(view.win).title, 'Minimal remains title-free')
H.eq(nil, view.details, 'Minimal does not add routine confirmation chrome')
V.close(view)
V.draw(view, { path = '\\', items = {}, message = message, notice = { message = message, summary = 'Saved · startup' } },
  { layout = 'fixed', density = 'full', width = 20, max_width = 20, max_height = 12 })
H.ok((body(view) .. body(view.details)):find('View saved', 1, true), 'Narrow status falls back to readable neutral content')
V.close(view)

-- Verify actual density-save production, without guessing message strings.
local Session, live = require('command_tree.session')
local original_new = Session.new
Session.new = function(services) live = original_new(services); return live end
local CE, Feedback = require('re35'), require('command_tree.session.feedback')
CE.setup({ profile = { path = H.tempdir('profile') .. '/profile.json' }, usage = { path = false },
  guidance = { first_run = false }, theme = { persist = false }, window = { icons = false } })
CE.open({ interactive = false })
live:cycle_density()
H.eq('Saved · startup', Feedback.notice(live.active).summary, 'A real successful view write creates a typed notice')
H.ok(live.active.message:find('View saved', 1, true), 'Existing Session message API remains compatible')
live:draw()
H.ok(title(live.active.view):find('Saved · startup', 1, true), 'Actual Compact confirmation moves to its title')
live:record_feedback('Preview', 'Fixture preview failure')
H.eq(nil, Feedback.notice(live.active), 'A new diagnostic revokes success ownership')
live:draw()
H.ok(body(live.active.view.details):find('Fixture preview failure', 1, true), 'Actual diagnostic remains visible')
CE.close(); CE.disable(); Session.new = original_new
print('Status ownership and placement passed: ' .. H.checks .. ' checks')
