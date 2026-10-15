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
  H.ok(not title(view):find('Saved', 1, true), 'Navigation title contains no save confirmation')
  H.ok(body(view.status):find('Saved · startup', 1, true), 'Explicit confirmation has its own status panel')
  local status_config, main_config = vim.api.nvim_win_get_config(view.status.win), vim.api.nvim_win_get_config(view.win)
  H.eq(main_config.row - 1, status_config.row, 'Status is immediately above the main panel')
  H.eq(main_config.col, status_config.col, 'Status shares the main horizontal anchor')
  H.eq(1, status_config.height, 'Routine status occupies one row')
  H.ok(not (body(view) .. body(view.details)):find(message, 1, true), 'Confirmation no longer occupies warning/context rows')
  H.eq(original, footprint(view), 'Moving routine status never resizes or moves main')
  H.ok(vim.wo[view.status.win].winhighlight:find('Normal:', 1, true)
    and not vim.wo[view.status.win].winhighlight:find('Warning', 1, true), 'Confirmation uses neutral text semantics')
  data.message = 'View changed for this session; saving failed: disk denied'
  V.draw(view, data, opts)
  H.eq(nil, view.status, 'A storage failure removes the success panel')
  H.ok(not title(view):find('Saved · startup', 1, true), 'Stale success cannot label a storage failure')
  H.ok(table.concat(view.details.lines, ''):find('disk denied', 1, true), 'Storage failure remains inspectable across wrapped rows below')
  data.message, data.error = message, 'A real error'
  V.draw(view, data, opts)
  H.eq(nil, view.status, 'An error removes the success panel')
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
H.eq(nil, view.status, 'Minimal does not add a routine status panel')
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
H.ok(body(live.active.view.status):find('Saved · startup', 1, true), 'Actual Compact confirmation has a separate status panel')
live:record_feedback('Preview', 'Fixture preview failure')
H.eq(nil, Feedback.notice(live.active), 'A new diagnostic revokes success ownership')
live:draw()
H.ok(body(live.active.view.details):find('Fixture preview failure', 1, true), 'Actual diagnostic remains visible')
CE.close(); CE.disable(); Session.new = original_new

-- Success expires without input and an ordinary redraw cannot resurrect it.
local data = { path = '\\', items = { { key = 'a', name = 'Run' } }, selected = 1,
  message = message, notice = { message = message, summary = 'Saved · startup' } }
local opts = { layout = 'fixed', density = 'compact', width = 48, max_height = 16 }
V.draw(view, data, opts)
local stable, status_win, status_buf = footprint(view), view.status.win, view.status.buf
H.ok(vim.wait(3500, function() return view.status == nil end, 10), 'Success disappears without another navigation key')
H.ok(not vim.api.nvim_win_is_valid(status_win) and not vim.api.nvim_buf_is_valid(status_buf), 'Expired status releases owned UI')
V.draw(view, data, opts)
H.eq(nil, view.status, 'Redrawing the same notice does not restart its lifetime')
H.eq(stable, footprint(view), 'Status expiration leaves main geometry unchanged')
data.notice = { message = message, summary = 'Saved · startup' }
V.draw(view, data, opts)
H.ok(view.status, 'A new save with identical wording is a new confirmation')
local timer = view.status_timer
status_win, status_buf = view.status.win, view.status.buf
H.ok(V.close(view), 'Closing the main view also cancels the status timer')
H.ok(timer:is_closing(), 'Closed session cannot keep a live status timer')
H.ok(not vim.api.nvim_win_is_valid(status_win) and not vim.api.nvim_buf_is_valid(status_buf), 'Closing main releases the status window and buffer')

-- If there is no row above a scene, preserve the confirmation as neutral
-- contextual content instead of displacing the main panel or hiding a failure.
opts.position = 'top'
V.draw(view, data, opts)
H.ok(view.status or (body(view) .. body(view.details)):find('View saved', 1, true), 'Top-anchored success remains visible')
V.close(view)

-- A secondary panel failure must preserve confirmation and main navigation.
opts.position = 'center'
local window = V.window
V.window = function(part, ...)
  local result = window(part, ...)
  if part == view.status then error('Fixture status allocation failure') end
  return result
end
local ok, why = pcall(V.draw, view, data, opts)
V.window = window
H.ok(ok, 'Status allocation failure leaves the command UI usable: ' .. tostring(why))
H.eq(nil, view.status, 'Failed status allocation releases its partial handles')
H.ok((body(view) .. body(view.details)):find('View saved', 1, true), 'Confirmation falls back to contextual text')
V.close(view)

V.draw(view, data, opts)
local retained = view.status
local retained_win, retained_buf = retained.win, retained.buf
local close_win, delete_buf = vim.api.nvim_win_close, vim.api.nvim_buf_delete
vim.api.nvim_win_close = function(win, ...)
  if win == retained_win then error('Fixture status close failure') end
  return close_win(win, ...)
end
vim.api.nvim_buf_delete = function(buf, ...)
  if buf == retained_buf then error('Fixture status buffer cleanup failure') end
  return delete_buf(buf, ...)
end
ok, why = V.close(view)
vim.api.nvim_win_close, vim.api.nvim_buf_delete = close_win, delete_buf
H.eq(false, ok, 'Secondary panel cleanup failure remains observable')
H.eq(retained, view.status, 'Failed cleanup retains ownership for retry')
H.ok(V.close(view), 'Status teardown succeeds after the host recovers')

-- A failed secondary panel cannot fall back into an already-rendered main
-- buffer. Details-disabled users receive one informational host message.
opts.details = { enabled = false }
local notify, notices = vim.notify, {}
vim.notify = function(value, level) notices[#notices + 1] = { value, level } end
V.window = function(part, ...)
  local result = window(part, ...)
  if part == view.status then error('Fixture secondary panel unavailable') end
  return result
end
V.draw(view, data, opts)
local anchor = footprint(view)
V.draw(view, data, opts)
V.window, vim.notify = window, notify
H.eq(1, #notices, 'Repeated rendering does not repeat the same fallback confirmation')
H.eq({ message, vim.log.levels.INFO }, notices[1], 'No-space fallback uses a neutral host notification')
H.eq(anchor, footprint(view), 'Fallback never changes main geometry')
V.close(view)

-- Dynamic opt-out still belongs to its source split, including status chrome.
vim.cmd('botright 6split')
local source = vim.api.nvim_get_current_win()
local source_top = vim.api.nvim_win_get_position(source)[1]
opts.layout, opts.target_win, opts.density = 'dynamic', source, 'full'
data.items = {}
for index = 1, 20 do data.items[index] = { key = tostring(index), name = 'Action ' .. index } end
notices = {}
vim.notify = function(value, level) notices[#notices + 1] = { value, level } end
V.draw(view, data, opts)
vim.notify = notify
H.eq(source_top, vim.api.nvim_win_get_config(view.win).row, 'Dynamic main reaches the top of its source split')
H.eq(nil, view.status, 'Status never draws above its owning split')
H.eq(1, #notices, 'A dynamic scene with no spare status row uses the host fallback')
V.close(view)
vim.api.nvim_win_close(source, true)
print('Status ownership and placement passed: ' .. H.checks .. ' checks')
