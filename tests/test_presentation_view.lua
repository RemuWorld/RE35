-- Real Neovim float/model checks. These are not a physical UI approval.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local V = require('command_tree.view')
local P = require('command_tree.presentation')
V.highlights()
local view = {}
local function options(config, state, scene)
  return P.options({ window = { density = 'full', width = 52, max_width = 72, max_height = 16, icons = false },
    presentation = config }, state or {}, scene or 'tree')
end
local function body(current)
  return vim.api.nvim_buf_get_lines((current or view).buf, 0, -1, false)
end
local function contains(text)
  return table.concat(body(), '\n'):find(text, 1, true) ~= nil
end
local function geometry(label)
  local config = vim.api.nvim_win_get_config(view.win)
  local border = type(config.border) == 'table' and #config.border > 0 and 2 or 0
  H.ok(config.row >= 0 and config.col >= 0, label .. ': starts inside screen')
  H.ok(config.row + config.height + border <= vim.o.lines - vim.o.cmdheight, label .. ': respects screen height')
  H.ok(config.col + config.width + border <= vim.o.columns, label .. ': respects screen width')
  H.eq(#body(), config.height, label .. ': buffer and float height agree')
  for _, text in ipairs(body()) do H.ok(V.width(text) <= config.width, label .. ': text fits cells') end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true })) do
    H.ok(mark[2] < #body() and mark[3] <= #body()[mark[2] + 1] and mark[4].end_col <= #body()[mark[2] + 1],
      label .. ': highlight byte range stays in rendered text')
  end
  return config
end
local function title(config)
  local result = ''
  for _, chunk in ipairs(config.title or {}) do result = result .. chunk[1] end
  return result
end
local function config(id, declaration)
  return { version = 1, selected = id, presets = declaration and { [id] = declaration } or {} }
end

H.eq(nil, options(nil).presentation, 'No presentation configuration retains the exact legacy renderer')
H.eq(nil, options({ version = 1, presets = vim.empty_dict() }).presentation,
  'An empty appearance object retains legacy geometry and preferences')
local legacy_left = { window = { density = 'full', width = 52, max_width = 72, max_height = 16,
  icons = false, position = 'left' } }
H.eq('left', P.options(legacy_left, {}, 'tree').position,
  'An existing unrestricted legacy position remains untouched without explicit presets')
legacy_left.presentation = { version = 1, selected = 'full', presets = {} }
local placed = P.options(legacy_left, {}, 'tree')
H.ok(placed.presentation, 'An unsupported inherited legacy position cannot prevent a valid preset from resolving')
H.eq('center', placed.presentation.layout.position, 'Unsupported legacy placement inherits deterministic center')
H.eq('left', placed.presentation_report.fallbacks[1].requested)
H.eq('center', placed.presentation_report.fallbacks[1].effective)
V.draw(view, { path = '\\', items = { { key = 'x', name = 'Valid preset' } }, selected = 1 }, placed)
geometry('unsupported legacy placement fallback')
H.ok(contains('Valid preset'), 'The valid preset remains usable with legacy placement fallback')
V.close(view)
H.eq('left', legacy_left.window.position, 'Placement fallback never rewrites local setup')
legacy_left.presentation = config('placed', { extends = 'full', layout = { position = 'top-right' } })
placed = P.options(legacy_left, {}, 'tree')
H.eq('top-right', placed.presentation.layout.position, 'An explicit preset position overrides inherited fallback')
H.eq('top-right', placed.presentation_report.fallbacks[1].effective, 'Fallback report names the resulting placement')
local custom = config('reading', { name = '읽기', extends = 'compact', information = {
  title = false, help = true, details = true, status = true, icons = true },
  spacing = { horizontal = 3, vertical = 1 }, decoration = { border = 'double', separator = true },
  layout = { rows = 4 }, roles = { normal = { fg = '#ABCDEF', bg = '#102030' },
    selected = { bg = '#304050' }, accent = { fg = '#80A0C0' } } })
local state = { density = 'minimal', path = { 'p', 'b' }, selected = 2,
  query = '빌드', query_cursor = 1, presentation_id = 'reading', pending_review = { retained = true } }
local before_config, before_state = vim.deepcopy(custom), vim.deepcopy(state)
local opts = options(custom, state, 'search')
H.eq('compact', opts.presentation.layout.density, 'Named list layout is independent of legacy state density')
H.eq(3, opts.presentation.spacing.horizontal)
H.eq({}, opts.presentation_report.fallbacks, 'Neovim supports the declared model without capability substitutions')
local normal_before = vim.api.nvim_get_hl(0, { name = 'NormalFloat', link = false })
V.draw(view, { title = 'Commands', path = '\\ p b', query = '빌드▏', query_text = '빌드', query_cursor = 1,
  items = { { key = 'a', name = 'Choice A', icon = '@', detail = 'detail A' },
    { key = 'b', name = 'Choice B', icon = '@', detail = 'detail B' } }, selected = 2,
  help = 'Distinct help', status = 'Distinct status' }, opts)
local floating = geometry('independent axes')
H.eq(nil, floating.title, 'Title is hidden independently of the Compact list')
H.ok(contains('Distinct help') and contains('Distinct status'), 'Compact can show help and status when requested')
H.ok(contains('detail B') and contains('@'), 'Compact can show details and icons independently')
H.eq('', body()[1], 'Explicit vertical spacing adds one leading row')
H.eq('', body()[#body()], 'Explicit vertical spacing adds one trailing row')
for index = 2, #body() - 1 do
  H.ok(body()[index]:sub(1, 3) == '   ' and body()[index]:sub(-3) == '   ', 'Horizontal spacing is independent')
end
local highlight = vim.wo[view.win].winhighlight:match('Normal:([^,]+)')
H.eq(tonumber('ABCDEF', 16), vim.api.nvim_get_hl(0, { name = highlight, link = false }).fg,
  'Explicit semantic role foreground is applied to the popup')
H.eq(tonumber('102030', 16), vim.api.nvim_get_hl(0, { name = highlight, link = false }).bg)
H.eq(normal_before, vim.api.nvim_get_hl(0, { name = 'NormalFloat', link = false }),
  'Popup role overrides do not change the editor theme')
H.eq(before_config, custom, 'Resolution and rendering leave source configuration unchanged')
H.eq(before_state, state, 'Resolution and rendering leave navigation, input and pending review untouched')
local slot = view.presentation_slot
V.close(view)
V.draw(view, { path = '\\', items = {} }, options(custom))
H.eq(slot, view.presentation_slot, 'Closed popup highlight slots are reused')
V.close(view)

-- A finite representative matrix covers scenes and independent geometry axes.
local scenes = {
  tree = { title = 'Tree', path = '\\', items = { { key = 'build-long-key', name = '한글 Build target A' } }, selected = 1 },
  search = { title = 'Search', path = '\\ /', query = '한글', query_text = '한글', query_cursor = 1,
    items = { { key = '', name = 'Search result 한글' } }, selected = 1 },
  input = { title = 'Input', path = '\\ › target', input = true,
    items = { { key = '>', name = '타깃', editing_text = '타깃 / long input', editing_cursor = 3 } }, selected = 1 },
  review = { title = 'Review', path = '\\ › Review', input = true,
    items = { { key = '1', name = 'Target = A' }, { key = 'Run', name = 'Apply' } }, selected = 2 },
  tasks = { title = 'Tasks', path = '\\ › Tasks', items = { { key = '#1', name = 'Build failed', detail = 'exit 1' } },
    selected = 1, message = 'Build failed' },
  results = { title = 'Results', path = '\\ › Results', items = {}, content = { 'No results' } },
}
for index, size in ipairs({ { 120, 42 }, { 30, 14 } }) do
  vim.o.columns, vim.o.lines, vim.o.background = size[1], size[2], index == 1 and 'dark' or 'light'
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    for scene, source in pairs(scenes) do
      local data = vim.deepcopy(source)
      data.help, data.status = 'Esc Back · ? View', 'Status summary'
      V.draw(view, data, options(config(density), {}, scene))
      floating = geometry(scene .. '/' .. density .. '/' .. index)
      if source.selected then
        H.ok(source.selected >= (view.visible_first or math.huge) and source.selected <= (view.visible_last or 0),
          'Selected item remains in the reported visible range')
      end
      if scene == 'tasks' then H.ok(contains('Build failed'), 'Failure feedback survives all density policies') end
      if density == 'minimal' then
        H.eq(nil, floating.title, 'Minimal default has no title')
        H.ok(not contains('Esc Back') and not contains('Status summary'), 'Minimal omits optional help/status')
      end
      V.close(view)
    end
  end
end
vim.o.columns, vim.o.lines = 100, 35

local quiet = config('quiet', { extends = 'minimal', information = {
  title = false, help = false, details = false, status = false, icons = false }, layout = { rows = 1 } })
local data = { title = 'Review', path = '\\ › Review', input = true, selected = 2,
  items = { { key = '1', name = 'Original = Debug / A' }, { key = '2', name = 'Apply' } },
  details = { target = 'original.cpp', description = 'Review facts' }, content = { 'Before: old', 'After: new' } }
V.draw(view, data, options(quiet, {}, 'review'))
H.ok(contains('Before: old') and contains('After: new') and contains('Target: original.cpp'),
  'Review facts remain visible when all cosmetic information controls are disabled')
H.ok(contains('2/2'), 'Required review pagination remains visible even with status disabled')
H.eq(true, view.presentation_review_complete, 'A representable review reports complete required content')
V.close(view)
local limited = config('limited', { extends = 'compact', layout = {
  width = 32, max_width = 32, max_height = 10, rows = 1 },
  information = { title = false, help = false, details = false, status = false, icons = false } })
local review_data = { path = '\\ Review', input = true, review = true, label = 'Review arguments', selected = 1,
  items = { { key = '1', name = 'value = ' .. string.rep('X', 600) },
    { key = 'Run', name = 'Execute with these arguments' } } }
local review_opts = options(limited, {}, 'review')
V.draw(view, review_data, review_opts)
H.eq(false, view.presentation_review_complete, 'An oversized required value makes the review incomplete')
review_data.selected = 2
V.draw(view, review_data, review_opts)
H.eq(2, view.visible_first, 'The Run item can still be browsed on its own page')
H.eq(false, view.presentation_review_complete, 'Moving to Run cannot clear another page\'s unrepresentable fact')
H.eq(false, V.presentation_review_status(review_data, review_opts), 'Fresh whole-review check also refuses the Run page')
V.close(view)
review_data.items[1].name = 'value = small'
for selected = 1, 2 do
  review_data.selected = selected
  local _, pages = V.draw(view, review_data, review_opts)
  H.eq(2, pages, 'Ordinary readable review values retain normal pagination')
  H.eq(true, view.presentation_review_complete, 'Readable facts remain complete on every page')
end
local complete, reason = V.presentation_review_status(review_data, review_opts)
H.eq(true, complete)
H.eq(nil, reason, 'A successful fresh check has no refusal reason')
V.close(view)
limited.presets.limited.layout.rows = 6
review_data.items = { { key = '1', name = 'first = ' .. string.rep('A', 40) },
  { key = '2', name = 'second = ' .. string.rep('B', 40) },
  { key = '3', name = 'third = ' .. string.rep('C', 40) }, { key = 'Run', name = 'Apply' } }
review_opts = options(limited, {}, 'review')
for selected = 1, 4 do
  review_data.selected = selected
  local _, pages = V.draw(view, review_data, review_opts)
  H.eq(2, pages, 'Wrapped but representable values reduce the rows ceiling instead of making impossible pages')
  H.eq(true, view.presentation_review_complete, 'Reduced pages preserve complete wrapped facts')
end
V.close(view)
local atomic = { required_facts = { { 'Change', 'Before: small', 'After: small' },
  { 'Other change', 'Before: ' .. string.rep('x', 600), 'After: small' } },
  required_footer = 'a Apply · x Discard · e Continue editing' }
H.eq(false, V.presentation_review_status(atomic, review_opts), 'Every atomic Before/After group is checked independently of selection')
local many = { required_facts = {}, required_footer = 'Apply / Discard' }
for index = 1, 1500 do many.required_facts[index] = { 'Change', 'Before: small', 'After: small' } end
H.eq(true, V.presentation_review_status(many, review_opts), 'Readable bounded appearance data has no artificial 1024-change admission ceiling')
V.draw(view, { path = '\\ › raw_field_name', label = 'Select the target configuration', input = true,
  items = { { key = '>', name = 'Debug', editing_text = 'Debug', editing_cursor = 5 } } },
  options(quiet, {}, 'input'))
H.ok(contains('Select the target configuration'), 'Required input prompt survives disabled optional details')
H.eq(true, view.presentation_input_complete, 'A readable input prompt reports complete required content')
V.close(view)
local one_cell = config('onecell', { extends = 'minimal', layout = { width = 1, max_width = 1 },
  spacing = { horizontal = 0 } })
V.draw(view, { path = '\\', label = '한글', input = true,
  items = { { key = '>', name = 'x', editing_text = 'x', editing_cursor = 1 } } },
  options(one_cell, {}, 'input'))
H.eq(false, view.presentation_input_complete, 'A wide required prompt glyph cannot be claimed readable in one cell')
H.ok(view.presentation_input_reason:find('Required input facts', 1, true), 'Input refusal reports its concrete cause')
V.close(view)
one_cell.presets.onecell.layout.max_height = 1
local clip, calls = V.clip, 0
V.clip = function(...) calls = calls + 1; return clip(...) end
local drawn, drawing_error = pcall(V.draw, view,
  { path = '\\', items = {}, content = { string.rep('x', 4096) }, message = '!' },
  options(one_cell, {}, 'review'))
V.clip = clip
H.ok(drawn, 'A long one-cell required fact remains a bounded refusal: ' .. tostring(drawing_error))
H.eq(false, view.presentation_review_complete, 'A long required fact exceeding the viewport is incomplete')
H.ok(calls <= 10, 'Wrapped row generation stops after the viewport budget instead of producing thousands of rows')
H.eq({ '!' }, body(), 'Bounded required-row generation still preserves highest-priority failure feedback')
V.close(view)
V.draw(view, { path = '\\', items = {}, selected = 1, details = { reason = 'Missing tool' }, message = 'Missing tool' },
  options(quiet, {}, 'tree'))
local repeats = 0
for _, text in ipairs(body()) do if text:find('Missing tool', 1, true) then repeats = repeats + 1 end end
H.eq(1, repeats, 'A failure and identical availability reason are rendered once')
V.close(view)

-- Tiny source windows preserve errors and report inability to represent review.
vim.cmd('new')
local source = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_height(source, 1)
local tiny_opts = options(quiet, {}, 'review')
tiny_opts.target_win = source
V.draw(view, { path = '\\ › Review', items = { { key = 'Apply', name = 'Apply' } }, selected = 1,
  content = { 'Before: original text', 'After: proposed text' }, message = 'Review failure' }, tiny_opts)
geometry('tiny review')
H.ok(contains('Review failure'), 'Tiny source retains failure feedback before metadata')
H.eq(false, view.presentation_review_complete, 'Clipped required review content is explicitly refused')
H.ok(view.presentation_review_reason:find('Review facts', 1, true), 'Unrepresentable review reports a concrete reason')
V.close(view)
local tiny_input = options(quiet, {}, 'input')
tiny_input.target_win = source
V.draw(view, { path = '\\ › value', label = 'Value', input = true,
  items = { { key = '>', name = 'typed', editing_text = 'typed', editing_cursor = 5 } } }, tiny_input)
H.ok(contains('Value'), 'A tiny source can retain the short required prompt')
H.eq(false, view.presentation_input_complete, 'Retaining only the prompt cannot claim a hidden typed value/caret readable')
V.close(view)
vim.api.nvim_win_close(source, true)

-- Bound role allocation by concurrent views, independent of renamed presets.
local active = {}
for index = 1, 33 do
  active[index] = {}
  V.draw(active[index], { path = '\\', items = {} }, options(custom))
end
H.eq(nil, active[33].presentation_slot, 'At most 32 presentation highlight slots are active')
H.ok(active[33].presentation_report.fallbacks[1].reason:find('slots exhausted', 1, true),
  'Exhausted style slots report deterministic host-theme fallback')
V.close(active[1])
V.draw(active[33], { path = '\\', items = {} }, options(custom))
H.ok(active[33].presentation_slot, 'A released slot becomes available to another view')
H.eq(0, #active[33].presentation_report.fallbacks, 'Redraw removes a resolved resource fallback')
for _, current in ipairs(active) do V.close(current) end
local caps = P.capabilities()
caps.support.roles.normal = false
H.eq(true, P.capabilities().support.roles.normal, 'Capability inspection returns detached data')
print('PRESENTATION VIEW: ' .. H.checks .. ' checks passed')
