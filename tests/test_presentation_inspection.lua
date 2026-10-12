-- Fixed inspection catalog: prepared for the consolidated validation run.
-- Real Neovim projection/geometry and two guarded Session actions are checked.
-- This fixture does not approve terminal fonts, appearance or human usability.
local H, K = require('helpers'), require('command_tree.keys')
local V, P = require('command_tree.view'), require('command_tree.presentation')
local catalog = vim.json.decode(table.concat(vim.fn.readfile(H.repo_root()
  .. '/tests/fixtures/presentation-inspection.json'), '\n'))
H.eq(1, catalog.version); H.eq('inspection-only', catalog.scope)
H.eq(24, #catalog.cases, 'The agreed matrix has exactly 24 cases, not a Cartesian expansion')
V.highlights()
vim.o.swapfile, vim.o.cmdheight = false, 1
vim.o.columns, vim.o.lines = 120, 40
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'source alpha', 'source beta', 'source gamma' })
vim.api.nvim_win_set_cursor(source_win, { 2, 3 })
local original = { lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
  tick = vim.api.nvim_buf_get_changedtick(source), cursor = vim.api.nvim_win_get_cursor(source_win) }
local function nil_if_null(value) if value == vim.NIL then return nil end; return value end
local function undecorated(border)
  if border == nil or border == 'none' then return true end
  if type(border) ~= 'table' then return false end
  for _, part in ipairs(border) do
    local glyph = type(part) == 'table' and part[1] or part
    if glyph ~= '' then return false end
  end
  return true
end
local function source_unchanged(label)
  H.eq(source, vim.api.nvim_win_get_buf(source_win), label .. ': exact source buffer owner is retained')
  H.eq(original.lines, vim.api.nvim_buf_get_lines(source, 0, -1, false), label .. ': source text is unchanged')
  H.eq(original.tick, vim.api.nvim_buf_get_changedtick(source), label .. ': source revision is unchanged')
  H.eq(original.cursor, vim.api.nvim_win_get_cursor(source_win), label .. ': source cursor is unchanged')
  H.eq(source_win, vim.api.nvim_get_current_win(), label .. ': source focus is unchanged')
end
local function options(case)
  return P.options({ presentation = catalog.presentation,
    window = { width = 48, max_width = 72, max_height = 16, icons = false } },
    { presentation_id = case.mode }, case.scene)
end
local function projection(case)
  local content = catalog.contents[case.content]
  local data = { title = content.label, path = '\\ ' .. case.scene, label = content.label,
    help = 'Esc Back · ? View', status = content.status, error = content.error, empty = content.empty,
    items = {}, query = content.query, query_text = content.query, query_cursor = content.queryCursor }
  for index, item in ipairs(content.items) do
    data.items[index] = vim.deepcopy(item)
    if item.id == nil_if_null(case.selected) then data.selected = index end
  end
  if case.scene == 'input' then
    data.input, data.label = true, content.input.question
    data.items[1].editing_text, data.items[1].editing_cursor = content.input.value, content.input.cursor
  elseif case.scene == 'review' then
    data.input, data.review = true, true
    data.details = { target = content.target, description = content.description, source = 'inspection fixture' }
  end
  if content.owner then
    data.required_label = content.label .. ' · Failed · exit ' .. content.owner.exitCode
    if case.scene == 'results' then data.target = content.target end
  end
  return data
end
local function geometry(view, case)
  local config = vim.api.nvim_win_get_config(view.win)
  local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  local border = undecorated(config.border) and 0 or 2
  H.ok(config.row >= 0 and config.col >= 0, case.id .. ': float begins in the actual viewport')
  H.ok(config.row + config.height + border <= vim.o.lines - vim.o.cmdheight,
    case.id .. ': float fits the actual viewport height')
  H.ok(config.col + config.width + border <= vim.o.columns, case.id .. ': float fits viewport width')
  H.eq(#lines, config.height, case.id .. ': native window and rendered buffer heights agree')
  for _, line in ipairs(lines) do H.ok(V.width(line) <= config.width, case.id .. ': Unicode fits native cells') end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, -1, 0, -1, { details = true })) do
    H.ok(mark[2] < #lines and mark[3] <= #lines[mark[2] + 1] and mark[4].end_col <= #lines[mark[2] + 1],
      case.id .. ': every highlight byte range belongs to a rendered line')
  end
  return config, lines
end
local coverage = {}
for index, case in ipairs(catalog.cases) do
  H.eq(('case%02d'):format(index), case.id, 'Semantic case IDs are stable and ordered')
  local size = assert(catalog.hosts.neovim.viewports[case.viewport])
  local content = assert(catalog.contents[case.content])
  vim.o.columns, vim.o.lines, vim.o.background = size.columns, size.lines, case.theme
  H.ok(case.outcomes.sameSource and case.outcomes.appearanceOnly, 'The catalog grants no source action')
  local view, data, opts = {}, projection(case), options(case)
  local before = vim.deepcopy(data)
  local declared = vim.deepcopy(catalog.presentation)
  local selected = data.selected and data.items[data.selected]
  V.draw(view, data, opts)
  local config, lines = geometry(view, case)
  H.eq(case.scene, view.presentation_report.scene)
  H.eq(case.mode, view.presentation_report.preset_id)
  H.eq(case.mode, opts.presentation.id, case.id .. ': host negotiation retains the requested stable preset ID')
  H.eq(declared, catalog.presentation, case.id .. ': drawing cannot modify portable declarations')
  local page = data.page; data.page = nil
  H.eq(before, data, case.id .. ': projection changes only renderer-owned pagination')
  data.page = page
  if selected then
    H.ok(data.items[data.selected] == selected, case.id .. ': the exact selected record is retained')
    H.eq(case.selected, selected.id, case.id .. ': stable selected ID is unchanged')
    if not case.required.refusal then
      H.ok(data.selected >= view.visible_first and data.selected <= view.visible_last,
        case.id .. ': selection is in the actual visible item range')
    end
  else
    H.eq(0, #content.items, case.id .. ': empty content has no fabricated selected row')
  end
  local visible = table.concat(lines, '\n')
  local reported_error = nil_if_null(case.error)
  if reported_error and not case.required.refusal then
    H.ok(visible:find(reported_error, 1, true), case.id .. ': explicit errors survive optional information policy')
  end
  if case.required.input then
    local expected = not case.required.refusal
    H.eq(expected, view.presentation_input_complete, case.id .. ': required input completeness is truthful')
  end
  if case.required.review then
    local expected = not case.required.refusal
    H.eq(expected, view.presentation_review_complete, case.id .. ': whole review completeness is truthful')
    H.eq(expected, V.presentation_review_status(data, opts), case.id .. ': fresh whole-review check agrees')
  end
  if case.required.facts then
    H.eq(true, view.presentation_facts_complete, case.id .. ': original source and owner facts remain readable')
  end
  if case.mode == 'minimal' then
    H.eq(nil, config.title, case.id .. ': Minimal omits the routine title')
    H.ok(undecorated(config.border), case.id .. ': Minimal popup has no decorative border')
    if not case.required.refusal then
      for _, line in ipairs(lines) do
        H.ok(line:sub(1, 2) == '  ' and line:sub(-2) == '  ',
          case.id .. ': Minimal retains two horizontal cells on each side')
      end
      H.ok(lines[1] ~= '' and lines[#lines] ~= '', case.id .. ': Minimal has no extra vertical rows')
    end
  end
  if case.mode == 'focused' then
    H.eq(3, opts.presentation.spacing.horizontal)
    H.eq(0, opts.presentation.spacing.vertical)
    H.eq('#AABBCC', opts.presentation.roles.normal.fg,
      case.id .. ': supported host roles do not rewrite the shared declaration')
    if case.scene == 'review' then
      H.ok(opts.presentation.information.title and opts.presentation.information.details,
        'Focused review overrides expose its required context')
    elseif case.scene == 'tasks' then
      H.eq(true, opts.presentation.information.status, 'Focused Tasks exposes optional task status')
    end
    for _, line in ipairs(lines) do
      H.ok(line:sub(1, 3) == '   ' and line:sub(-3) == '   ', 'Focused keeps its independent horizontal spacing')
    end
  end
  -- A second projection of the exact data is a redraw, never a selection or an execution.
  V.draw(view, data, opts); geometry(view, case)
  H.eq(case.selected, selected and selected.id or vim.NIL)
  source_unchanged(case.id)
  H.ok(V.close(view), case.id .. ': closing releases the native inspection float')
  coverage[case.mode .. '/' .. case.scene] = (coverage[case.mode .. '/' .. case.scene] or 0) + 1
end
for _, mode in ipairs({ 'full', 'compact', 'minimal' }) do
  for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
    local extra = (mode == 'minimal' and scene == 'input' or mode == 'full' and scene == 'review') and 1 or 0
    H.eq(1 + extra, coverage[mode .. '/' .. scene], 'Exactly 18 base pairs plus the two named tiny cases')
  end
end

-- Tiny cases additionally pass through actual Session Enter guards. No fixture
-- callbacks are invoked; the counters reject any accidentally admitted action.
vim.o.columns, vim.o.lines = 120, 40
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local profile = Profile.empty(); profile.presentation = vim.deepcopy(catalog.presentation)
local calls = 0
CE.setup({ profile = { path = false, data = profile }, preferences = { path = false }, usage = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
  commands = {
    { id = 'fixture.input', name = 'Inspection input',
      arguments = { { name = 'value', prompt = catalog.contents['input-tiny-refusal'].input.question, required = true } },
      run = function() calls = calls + 1 end },
    { id = 'fixture.review', name = 'Inspection review', persistent = false,
      arguments = { { name = 'configuration', required = true }, { name = 'target', required = true } },
      run = function() calls = calls + 1 end },
  } })
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(command)
  CE.close(); vim.api.nvim_set_current_win(source_win)
  H.ok(CE.open({ command = command, interactive = false }))
  return session.active
end
local state = open('fixture.input'); keys('ready')
local owned_input = state.input
state.presentation_id = 'minimal'
vim.o.columns, vim.o.lines = 16, 6
keys('<CR><CR>')
H.eq('input', state.mode); H.ok(state.input == owned_input)
H.eq(false, state.view.presentation_input_complete)
H.eq(0, calls, 'case23: actual Enter refuses unreadable input before execution')
H.eq('ready', owned_input.text, 'case23: refusal preserves the exact original typed value')
source_unchanged('case23 Session')
vim.o.columns, vim.o.lines = 120, 40
state = open('fixture.review')
keys(string.rep('原', 72) .. '<CR>original-target-A<CR>')
H.eq('review', state.mode)
owned_input = state.input
local submitted = vim.deepcopy(owned_input.args)
state.presentation_id = 'full'
vim.o.columns, vim.o.lines = 16, 6
keys('<CR><CR>')
H.eq('review', state.mode); H.ok(state.input == owned_input)
H.eq(submitted, owned_input.args, 'case24: refusal preserves submitted original arguments')
H.eq(false, state.view.presentation_review_complete)
H.eq(0, calls, 'case24: actual Enter refuses the whole unrepresentable review before execution')
source_unchanged('case24 Session')

-- History's four source edges are a workspace symbol, separate from popup
-- decoration. This is a retained invariant, not a 25th inspection scene.
vim.o.columns, vim.o.lines = 120, 40
CE.close(); vim.api.nvim_set_current_win(source_win)
H.ok(CE.open({ workspace = 'history', interactive = false }))
state = session.active
local frame = state.stack[#state.stack]
H.eq(4, #frame.data.frames, 'The History workspace starts with four symbolic source edges')
local edges = {}
for index, part in ipairs(frame.data.frames) do edges[index] = part.win end
state.presentation_id, state.density = 'minimal', 'minimal'
session:draw()
H.eq(4, #frame.data.frames, 'Minimal popup styling retains every History source edge')
for index, part in ipairs(frame.data.frames) do
  H.eq(edges[index], part.win, 'The exact History source edge is retained')
  H.ok(vim.api.nvim_win_is_valid(part.win))
end
local popup = vim.api.nvim_win_get_config(frame.data.hud.win)
H.ok(undecorated(popup.border), 'Minimal History popup has no decorative border')
H.eq(0, calls); source_unchanged('History frame invariant')
CE.close(); CE.disable(); Session.new = construct
for _, win in ipairs(vim.api.nvim_list_wins()) do
  H.eq('', vim.api.nvim_win_get_config(win).relative, 'All inspection floats and History edges are released')
end
print('PRESENTATION INSPECTION: 24 prepared cases; ' .. H.checks .. ' checks passed')

