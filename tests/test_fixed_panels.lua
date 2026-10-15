-- Actual Neovim geometry, scroll and lifecycle checks; not human visual approval.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local V, P = require('command_tree.view'), require('command_tree.presentation')
V.highlights()
local view, source = {}, vim.api.nvim_get_current_win()
local function lines(part)
  return vim.api.nvim_buf_get_lines(part.buf, 0, -1, false)
end
local function text(part) return table.concat(lines(part), '\n') end
local function footprint(part)
  local config = vim.api.nvim_win_get_config(part.win)
  return { width = config.width, height = config.height, row = config.row, col = config.col }
end
local function border(config) return type(config.border) == 'table' and #config.border > 0 and 2 or 0 end
local function audit(part, label)
  local config, body = vim.api.nvim_win_get_config(part.win), lines(part)
  H.ok(config.row >= 0 and config.col >= 0, label .. ' starts inside screen')
  H.ok(config.row + config.height + border(config) <= vim.o.lines - vim.o.cmdheight, label .. ' height fits viewport')
  H.ok(config.col + config.width + border(config) <= vim.o.columns, label .. ' width fits viewport')
  H.eq(config.height, #body, label .. ' fills its allocated body')
  for _, row in ipairs(body) do H.ok(V.width(row) <= config.width, label .. ' fits Unicode display cells') end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(part.buf, -1, 0, -1, { details = true })) do
    H.ok(mark[2] < #body and mark[3] <= #body[mark[2] + 1]
      and mark[4].end_col <= #body[mark[2] + 1], label .. ' highlights match rendered bytes')
  end
end
local function options(density, preset)
  local configured = { window = { layout = 'fixed', density = density, width = 52, max_width = 72,
    max_height = 16, compact_rows = 6, minimal_rows = 3, icons = false,
    details = { enabled = true, max_height = 4 } } }
  if preset then configured.presentation = { version = 1, selected = density, presets = {} } end
  return P.options(configured, { density = density }, 'tree')
end
local base = { path = '\\', selected = 1, items = {
  { key = 'a', name = 'Build 한글' }, { key = 'b', name = 'Test' } } }

for _, preset in ipairs({ false, true }) do
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    local opts, data = options(density, preset), vim.deepcopy(base)
    V.draw(view, data, opts)
    local initial, main_win = footprint(view), view.win
    H.eq(nil, view.details, 'No empty details float is allocated')
    data.path, data.selected = '\\ a long nested path 한글', 2
    data.items[2].name = string.rep('Long name 한글 ', 40)
    data.details = { description = 'Selected description 한글', reason = 'Missing compiler', target = 'src/main.cpp' }
    data.message = 'Missing compiler'
    V.draw(view, data, opts)
    H.eq(initial, footprint(view), density .. ' main geometry survives selection/description/error changes')
    H.eq(main_win, view.win, 'Main float is reused rather than reopened')
    H.ok(view.details and text(view.details):find('Missing compiler', 1, true), 'Unavailable fact lives in details')
    audit(view, density .. ' main')
    audit(view.details, density .. ' details')
    local main_config, detail_config = vim.api.nvim_win_get_config(view.win), vim.api.nvim_win_get_config(view.details.win)
    H.eq(main_config.row + main_config.height + border(main_config), detail_config.row, 'Details is directly below main')
    H.eq(main_config.col, detail_config.col, 'Details shares the main horizontal anchor')
    H.eq(main_config.width, detail_config.width, 'Details shares main width')
    H.ok(detail_config.height <= 4, 'Details obeys its separate height ceiling')
    H.eq(source, vim.api.nvim_get_current_win(), 'Rendering never takes native editor focus')
    local detail_win, detail_buf = view.details.win, view.details.buf
    data.details, data.message, data.error = nil, nil, nil
    V.draw(view, data, opts)
    H.eq(initial, footprint(view), 'Hiding details does not move or resize main')
    H.eq(nil, view.details, 'Hidden detail state is detached')
    H.ok(not vim.api.nvim_win_is_valid(detail_win) and not vim.api.nvim_buf_is_valid(detail_buf), 'Hidden details has no orphan handles')
    V.close(view)
  end
end

-- Each dense page reserves selectable rows and actual chrome, not unexplained
-- bottom padding. A short last page keeps the same capacity and anchor.
local choices = {}
for index = 1, 13 do choices[index] = { key = tostring(index), name = 'Choice ' .. index } end
for _, preset in ipairs({ false, true }) do
  for _, density in ipairs({ 'compact', 'minimal' }) do
    local opts, slots = options(density, preset), density == 'compact' and 6 or 3
    local data = { path = '\\', selected = 1, items = choices }
    V.draw(view, data, opts)
    local initial = footprint(view)
    H.eq(slots + 1, initial.height, density .. ' reserves only its path and configured list slots')
    H.eq(1, view.visible_first, density .. ' first page starts at its first choice')
    H.eq(slots, view.visible_last, density .. ' all configured slots remain selectable')
    for _, row in ipairs(lines(view)) do H.ok(row:find('%S'), density .. ' full page has no unused bottom rows') end
    data.selected, data.path = 13, '\\ f nested branch'
    data.message, data.help = 'An error', 'Esc Back · Enter Open'
    V.draw(view, data, opts)
    H.eq(initial, footprint(view), density .. ' last page, path and feedback preserve the footprint')
    H.eq(13, view.visible_last, density .. ' final choice remains visible')
    V.close(view)

    data = { path = '\\ /', query = 'Choice', selected = 1, items = choices }
    V.draw(view, data, opts)
    H.eq(slots + 2, footprint(view).height, density .. ' search reserves its actual query row')
    H.eq(slots, view.visible_last, density .. ' search keeps its configured choice capacity')
    for _, row in ipairs(lines(view)) do H.ok(row:find('%S'), density .. ' search full page has no unused bottom rows') end
    V.close(view)

    -- Choice/source scenes reserve a page and their actual required facts.
    data.input, data.label = true, 'Choose the required target'
    data._input_choice_labels = {}
    for _, item in ipairs(choices) do data._input_choice_labels[#data._input_choice_labels + 1] = item.name end
    V.draw(view, data, opts)
    H.eq(slots + 3, footprint(view).height, density .. ' choice input reserves prompt, query and configured slots')
    H.eq(true, view.presentation_input_complete, density .. ' choice input retains complete required question/value')
    local input_geometry = footprint(view)
    data.selected, data.query, data.query_text, data.query_cursor = 13, 'Choice 13', 'Choice 13', 9
    V.draw(view, data, opts)
    H.eq(input_geometry, footprint(view), density .. ' choice selection and filter text preserve its footprint')
    data.items, data.selected = { choices[13] }, 1
    V.draw(view, data, opts)
    H.eq(input_geometry, footprint(view), density .. ' a filtered short page keeps the same domain budget')
    V.close(view)
    data.input, data.label, data.target, data.items = nil, nil, 'src/main.cpp', choices
    V.draw(view, data, opts)
    H.eq(slots + 3, footprint(view).height, density .. ' source identity adds its required row to the page')
    H.eq(true, view.presentation_facts_complete, density .. ' source identity remains complete')
    V.close(view)

    data = { path = '\\ Input', input = true, label = 'Target configuration (1/1)',
      items = { { key = '>', name = 'Debug', editing_text = 'Debug', editing_cursor = 5 } } }
    V.draw(view, data, opts)
    H.eq(3, footprint(view).height, density .. ' text input reserves path, prompt and one edit row')
    H.eq(true, view.presentation_input_complete, density .. ' compact text input retains its required facts')
    local editor_geometry = footprint(view)
    data.items[1].editing_text, data.items[1].editing_cursor = string.rep('long 한글 ', 20), 80
    data.message = 'Validation failed'
    V.draw(view, data, opts)
    H.eq(editor_geometry, footprint(view), density .. ' typing, caret movement and validation cannot resize the editor')
    H.ok(text(view.details):find('Validation failed', 1, true), density .. ' editor errors remain inspectable')
    V.close(view)

    data.review, data.content = true, { 'Before: old', 'After: new' }
    V.draw(view, data, opts)
    H.eq(16, footprint(view).height, density .. ' explicit review keeps its larger reading budget')
    H.eq(true, view.presentation_review_complete, density .. ' review facts retain existing admission')
    V.close(view)
  end
end

-- Required labels are wrapped and included in the structural budget. A choice
-- with a long name reserves its extra lines on every filtered page.
for _, density in ipairs({ 'compact', 'minimal' }) do
  local opts = options(density, true)
  local slots = density == 'compact' and 6 or 3
  local long = string.rep('Long target ', 10)
  local data = { path = '\\ Input', input = true, label = string.rep('Required prompt ', 5), selected = 1,
    items = { { name = long }, { name = 'Short' } }, _input_choice_labels = { long, 'Short' } }
  V.draw(view, data, opts)
  local initial = footprint(view)
  H.ok(initial.height > slots + 2 and initial.height < 16, density .. ' wraps static required text without always taking max height')
  H.eq(true, view.presentation_input_complete, density .. ' wrapped question and selected value remain complete')
  data.items, data.selected = { { name = 'Short' } }, 1
  V.draw(view, data, opts)
  H.eq(initial, footprint(view), density .. ' filtering away the longest choice preserves geometry')
  H.eq(true, view.presentation_input_complete, density .. ' the filtered choice stays admitted')
  V.close(view)
end

-- Explicit rows, custom chrome and spacing each account for actual body rows.
for _, density in ipairs({ 'compact', 'minimal' }) do
  local opts = options(density, false)
  if density == 'compact' then opts.compact_rows = 4 else opts.minimal_rows = 2 end
  local slots = density == 'compact' and 4 or 2
  V.draw(view, { path = '\\', selected = 1, items = choices }, opts)
  H.eq(slots + 1, footprint(view).height, density .. ' honors local custom rows')
  H.eq(slots, view.visible_last, density .. ' renders every local custom slot')
  V.close(view)

  opts = options(density, true)
  opts.presentation.layout.rows = slots
  opts.presentation.spacing.vertical = 1
  opts.presentation.decoration.border = 'none'
  opts.presentation.decoration.separator = true
  opts.presentation.information.title = true
  opts.presentation.information.status = true
  V.draw(view, { path = '\\', selected = 1, items = choices }, opts)
  -- Title, path, separator, page footer and explicit top/bottom padding.
  H.eq(slots + 6, footprint(view).height, density .. ' custom presentation reserves exactly its chrome and padding')
  H.eq(slots, view.visible_last, density .. ' custom presentation keeps its requested slots')
  audit(view, density .. ' custom dense page')
  V.close(view)

  opts.presentation.layout.max_height = 6
  V.draw(view, { path = '\\', selected = 13, items = choices }, opts)
  H.eq(6, footprint(view).height, density .. ' custom ceiling bounds chrome plus rows')
  H.ok(view.visible_first and view.visible_last == 13, density .. ' custom ceiling preserves the selected choice')
  audit(view, density .. ' ceiling-limited page')
  V.close(view)
end

-- Preserve the intentionally short Minimal entry strip and horizontal margins.
local minimal = options('minimal', false)
V.draw(view, { path = '\\', items = {} }, minimal)
H.eq(1, footprint(view).height, 'Plain Minimal entry keeps exactly one reading row')
H.ok(lines(view)[1]:sub(1, 2) == '  ', 'Minimal retains left breathing room')
local minimal_geometry = footprint(view)
V.draw(view, { path = '\\', items = {}, message = 'A failure while opening' }, minimal)
H.eq(minimal_geometry, footprint(view), 'Minimal errors do not enlarge the entry strip')
H.eq(0, border(vim.api.nvim_win_get_config(view.details.win)), 'Minimal detail panel is borderless')
H.eq(nil, vim.api.nvim_win_get_config(view.win).title, 'Minimal main has no title')
V.close(view)

-- Bounded full diagnostic messages are inspectable and scroll without moving selection.
local opts, data = options('compact', true), vim.deepcopy(base)
local diagnostic_lines = {}
for index = 1, 40 do diagnostic_lines[index] = ('Message %02d 한글'):format(index) end
data.diagnostic = { message = 'Preview failed', full_message = table.concat(diagnostic_lines, '\n'), phase = 'preview' }
data.message = 'Preview failed'
V.draw(view, data, opts)
local main_before, original_selection, original_win = footprint(view), data.selected, view.win
H.eq(40, view.details.total, 'All diagnostic lines remain retained behind the visible slice')
H.ok(text(view.details):find('Message 01', 1, true), 'Full diagnostic starts at its first line')
H.ok(V.scroll_details(view, 4), 'The renderer provides independent details paging')
H.eq(5, view.details.top, 'Details offset moves by requested rows')
H.ok(text(view.details):find('Message 05', 1, true), 'A later full diagnostic page is readable')
H.eq(main_before, footprint(view), 'Scrolling details cannot reflow main')
H.eq(original_selection, data.selected, 'Scrolling details cannot change command selection')
H.eq(original_win, view.win, 'Scrolling details keeps the command float')
V.draw(view, data, opts)
H.eq(5, view.details.top, 'Unchanged diagnostic redraw preserves its inspection position')
V.scroll_details(view, 10000)
H.eq(37, view.details.top, 'Scrolling clamps at the last complete page')
V.scroll_details(view, -10000)
H.eq(1, view.details.top, 'Scrolling clamps at the first page')
H.eq(false, V.scroll_details(view, 0 / 0), 'Invalid scroll deltas cannot corrupt geometry')
audit(view.details, 'diagnostic details')
local owned = { view.win, view.details.win }
local buffers = { view.buf, view.details.buf }
V.close(view)
for _, win in ipairs(owned) do H.ok(not vim.api.nvim_win_is_valid(win), 'Closing session closes each owned float') end
for _, buf in ipairs(buffers) do H.ok(not vim.api.nvim_buf_is_valid(buf), 'Closing session wipes each owned scratch buffer') end

-- Host failures after detail allocation tear down both panels before propagating.
local original_window, allocated_windows, allocated_buffers = V.window, {}, {}
V.window = function(part, ...)
  local value = original_window(part, ...)
  allocated_windows[#allocated_windows + 1], allocated_buffers[#allocated_buffers + 1] = part.win, part.buf
  if part ~= view then error('Fixture detail rendering failure') end
  return value
end
local drew, failure = pcall(V.draw, view, data, opts)
V.window = original_window
H.eq(false, drew, 'Host rendering failure remains observable')
H.ok(tostring(failure):find('Fixture detail rendering failure', 1, true), 'Failure propagates its concrete detail')
H.eq(nil, view.win, 'Rendering failure detaches the main panel')
H.eq(nil, view.details, 'Rendering failure detaches the detail panel')
for _, win in ipairs(allocated_windows) do H.ok(not vim.api.nvim_win_is_valid(win), 'Failed render leaves no owned float') end
for _, buf in ipairs(allocated_buffers) do H.ok(not vim.api.nvim_buf_is_valid(buf), 'Failed render leaves no owned scratch buffer') end

-- Explicit local dynamic opt-out preserves historical renderer behavior.
opts = options('full', false)
opts.layout = 'dynamic'
V.draw(view, { path = '\\', items = {} }, opts)
local short = footprint(view)
V.draw(view, { path = '\\', items = {}, message = 'Inline warning', details = { description = 'Description' } }, opts)
H.ok(footprint(view).height > short.height, 'Dynamic opt-out still follows content height')
H.eq(nil, view.details, 'Dynamic opt-out closes the separate panel')
H.ok(text(view):find('Inline warning', 1, true), 'Dynamic feedback remains inline')
V.close(view)

-- Narrow/tiny targets stay bounded; separate details yield before mandatory facts.
vim.o.columns, vim.o.lines = 30, 14
for _, preset in ipairs({ false, true }) do
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    opts = options(density, preset)
    data = vim.deepcopy(base)
    data.message = 'Failure details 한글'
    V.draw(view, data, opts)
    audit(view, 'narrow main')
    if view.details then audit(view.details, 'narrow details') else
      H.eq('inline', view.panel_report.details, 'Insufficient room produces explicit inline fallback')
      H.ok(text(view):find('Failure', 1, true), 'Short viewport retains feedback')
    end
    V.close(view)
  end
end
vim.o.columns, vim.o.lines = 100, 35
vim.cmd('new')
local tiny = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_height(tiny, 1)
opts = options('minimal', true)
opts.presentation_scene, opts.target_win = 'review', tiny
data = { path = '\\ Review', review = true, input = true, selected = 1,
  items = { { key = 'a', name = 'Apply' } }, content = { 'Before: old', 'After: new' }, message = 'Review failure' }
V.draw(view, data, opts)
H.eq(nil, view.details, 'A one-row source cannot create an out-of-bounds detail pane')
H.eq('inline', view.panel_report.details, 'Tiny fallback is reported independently of shared presentation')
H.eq(false, view.presentation_review_complete, 'Clipped mandatory review facts refuse execution')
H.eq(false, V.presentation_review_status(data, opts), 'Fresh whole-review admission uses the same actual capacity')
H.ok(text(view):find('Review failure', 1, true), 'Tiny review preserves its error')
audit(view, 'tiny review')
V.close(view)
vim.api.nvim_win_close(tiny, true)

-- Resizing or changing an explicit mode is allowed; panels still stay anchored.
opts = options('compact', false)
opts.position = 'bottom-right'
V.draw(view, { path = '\\', selected = 1, items = base.items, message = 'Status' }, opts)
local config, detail = vim.api.nvim_win_get_config(view.win), vim.api.nvim_win_get_config(view.details.win)
H.eq(detail.row, config.row + config.height + border(config), 'Bottom-right main reserves the details footprint')
vim.o.columns, vim.o.lines = 44, 22
V.draw(view, { path = '\\', selected = 1, items = base.items, message = 'Status changed' }, opts)
audit(view, 'resized main')
if view.details then audit(view.details, 'resized details') end
V.close(view)
for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative, 'No popup survives complete teardown') end

-- The actual runtime theme picker receives the stable unfiltered domain from
-- the Session presenter. Filtering and previewing cannot change its footprint.
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile, Keys = require('re35'), require('command_tree.profile'), require('command_tree.keys')
local function keys(value) for _, key in ipairs(Keys.tokens(value)) do session:handle(key) end end
vim.o.columns, vim.o.lines = 120, 42
vim.cmd.colorscheme('default')
for _, density in ipairs({ 'compact', 'minimal' }) do
  local profile = Profile.empty()
  profile.presentation = { version = 1, selected = density, presets = {} }
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
    theme = { persist = false }, auto = false, operator_help = false, triggers = {},
    providers = { builtin = false, plugins = true, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    window = { layout = 'fixed', width = 52, max_width = 72, max_height = 16, compact_rows = 6, minimal_rows = 3 } })
  H.ok(CE.open({ command = 'ui.theme', interactive = false }))
  local state, slots = session.active, density == 'compact' and 6 or 3
  H.eq('input', state.mode, 'The real theme command opens its ordinary input scene')
  H.ok(#state.input.all_choices > 1, 'Actual installed runtime colorschemes populate the picker')
  H.eq(slots + 2, footprint(state.view).height, density .. ' actual theme input uses only its prompt and page slots')
  local initial, input = footprint(state.view), state.input
  keys('<Down>')
  H.eq(initial, footprint(state.view), density .. ' actual theme preview selection preserves geometry')
  keys('/')
  local filtering = footprint(state.view)
  H.eq(initial.height + 1, filtering.height, 'Entering the filter scene reserves exactly its query row')
  keys('d')
  H.eq(filtering, footprint(state.view), density .. ' actual filtered results keep the same page budget')
  keys('e')
  H.eq(filtering, footprint(state.view), density .. ' editing the real filter cannot resize or move the input')
  H.ok(state.input == input, 'Filtering preserves the exact live input owner')
  H.eq(true, state.view.presentation_input_complete, 'Real theme filtering preserves required input admission')
  H.eq(0, #CE.operations(), 'Browsing and previewing never confirms a theme operation')
  CE.close()
  H.eq('default', vim.g.colors_name, 'Closing the picker rolls back its real theme preview')
end
-- Actual Results filtering retains the unfiltered target domain, including
-- when no result is selected. Required identity text still names only the
-- actual selected result; the private domain is a sizing reference.
local result_folder = H.tempdir('fixed-result-domain')
vim.fn.setqflist({
  { filename = result_folder .. '/short.cpp', lnum = 1, col = 1, text = 'Short result' },
  { filename = result_folder .. '/' .. string.rep('long-target-segment/', 5) .. 'target.cpp',
    lnum = 2, col = 3, text = 'Long result' },
}, 'r')
for _, density in ipairs({ 'compact', 'minimal' }) do
  local profile = Profile.empty()
  profile.presentation = { version = 1, selected = density, presets = {} }
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
    auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
    providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    window = { layout = 'fixed', width = 52, max_width = 72, max_height = 16 } })
  H.ok(CE.open({ workspace = 'results', workspace_data = { source = 'quickfix' }, interactive = false }))
  local state = session.active
  local frame = state.stack[#state.stack]
  H.eq(2, #frame.data.items, 'Native quickfix populates both source identities')
  local short_target, initial = frame.data.items[1].detail, footprint(frame.view)
  keys('<Down>')
  H.eq(initial, footprint(frame.view), density .. ' selecting the longer source preserves geometry')
  keys('<Up>f')
  local filtering = footprint(frame.view)
  H.eq(initial.height + 1, filtering.height, 'Results filter entry adds exactly its query row')
  keys('short')
  H.eq(1, #frame.data.items)
  H.eq(short_target, frame.data.items[1].detail, 'The actual selected source identity is unchanged')
  H.eq(filtering, footprint(frame.view), density .. ' filtering away the longest target preserves geometry')
  H.eq(true, frame.view.presentation_facts_complete, 'The actual short source remains completely readable')
  keys('missing')
  H.eq(0, #frame.data.items)
  H.eq(filtering, footprint(frame.view), density .. ' a no-match filter retains the same source budget')
  H.eq(nil, frame.view.presentation_facts_complete, 'No-match results do not invent a selected source identity')
  CE.close()
end
Session.new = construct
print('FIXED PANELS: ' .. H.checks .. ' checks passed')
