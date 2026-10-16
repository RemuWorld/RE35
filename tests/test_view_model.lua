-- Compatibility inputs share one renderer without changing saved preferences.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local V, Host = require('command_tree.view'), require('command_tree.presentation')
local Model = require('command_tree.view.model')
V.highlights()

local choices = {}
for index = 1, 12 do choices[index] = { key = tostring(index), name = 'Choice ' .. index } end
local view = {}
local function config() return vim.api.nvim_win_get_config(view.win) end
local function text() return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), '\n') end
local function draw(data, opts)
  local before_data, before_opts = vim.deepcopy(data), vim.deepcopy(opts)
  local wins, bufs = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
  local _, _, size, plan = V.presentation_review_status(data, opts)
  H.eq(wins, #vim.api.nvim_list_wins(), 'Fresh display planning allocates no window')
  H.eq(bufs, #vim.api.nvim_list_bufs(), 'Fresh display planning allocates no buffer')
  H.eq(before_data, data, 'Planning preserves caller scene data')
  H.eq(before_opts, opts, 'Planning preserves legacy and preset options')
  V.draw(view, data, opts)
  H.eq(size, view.page_size, 'Navigation uses the freshly planned page capacity')
  H.eq(plan.width, view.presentation_plan.width, 'Admission and draw agree on cells')
  H.eq(plan.body_height, view.presentation_plan.body_height, 'Admission and draw agree on body rows')
  H.eq(before_opts, opts, 'Drawing does not rewrite caller preferences')
end

-- Legacy local bounds deliberately exceed portable preset bounds. They keep
-- their old host-clamped meaning, including unrestricted placement spelling.
local legacy = { density = 'full', width = 400, max_width = 500, max_height = 3,
  position = 'left', icons = false }
draw({ path = '\\', selected = 4, items = choices }, legacy)
H.eq(116, config().width, 'Legacy wide bounds are clamped by the actual host viewport')
H.eq(3, view.page_size, 'Legacy max_height limits selectable rows rather than complete body')
H.eq(6, config().height, 'Legacy path, separator and paging retain their own rows')
H.eq(4, view.visible_first, 'Legacy paging keeps the selected page')
H.ok(text():find('Choice 4', 1, true), 'Wide local options remain usable')
H.eq(1, math.abs(config().col), 'Legacy left spelling retains its original centered host placement')
H.eq('legacy', view.presentation_options._display.source, 'Internal provenance distinguishes local setup')
V.close(view)

vim.o.lines = 10
draw({ path = '\\', selected = 4, items = choices, error = 'Build failed' },
  { layout = 'dynamic', density = 'full', width = 48, icons = false })
H.eq(1, view.page_size, 'A short inline layout reserves feedback spacing and its page footer')
H.eq(4, view.visible_first, 'The planned page retains its selected item after chrome costs')
H.eq(4, view.visible_last, 'Page capacity matches the actual selectable rows')
H.ok(text():find('Build failed', 1, true), 'Feedback remains visible within the planned capacity')
V.close(view)
vim.o.lines = 42

-- Saved normalized display options remain usable for a later, different scene
-- and a resize. They are display input, not a cached execution admission.
local opts = { layout = 'fixed', density = 'compact', width = 42, max_width = 52,
  max_height = 16, compact_rows = 4, icons = false }
draw({ path = '\\', selected = 1, items = choices }, opts)
local normalized = view.presentation_options
H.eq(true, normalized._display.legacy_geometry, 'Ordinary local list keeps its historical row vocabulary')
local review = { path = '\\ Review', review = true, selected = 1,
  content = { 'Before: old', 'After: new' }, required_facts = { { 'Before: old', 'After: new' } },
  items = { { key = 'a', name = 'Apply' }, { key = 'x', name = 'Discard' } } }
V.close(view)
draw(review, normalized)
H.eq(true, view.presentation_review_complete, 'A later review uses complete-value rendering')
H.eq(false, view.presentation_options._display.legacy_geometry,
  'Normalization recalculates scene compatibility rather than reusing an old list budget')
vim.o.columns, vim.o.lines = 12, 5
H.eq(false, V.presentation_review_status(review, normalized), 'A resize invalidates an old readable review')
vim.o.columns, vim.o.lines = 120, 42
V.close(view)

local authored = Host.options({ window = { density = 'full', icons = false }, presentation = {
  version = 1, selected = 'compact', presets = {} } }, {}, 'tree')
local authored_before = vim.deepcopy(authored)
draw({ path = '\\', selected = 1, items = choices }, authored)
H.eq('preset', view.presentation_options._display.source, 'Authored presentation has explicit provenance')
H.eq(authored_before, authored, 'Internal provenance never becomes stored profile data')
H.eq('compact', Model.normalize({}, authored).presentation.layout.density, 'Selected preset keeps its effective density')
V.close(view)
