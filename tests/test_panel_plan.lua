-- Optional-panel placement is a pure input to the same main review plan.
local H = require('helpers')
local V, Host = require('command_tree.view'), require('command_tree.presentation')
local Model, Panels = require('command_tree.view.model'), require('command_tree.view.panels')
local Guide, Renderer = require('command_tree.view.guide'), require('command_tree.view.presentation')
vim.o.columns, vim.o.lines = 180, 48
V.highlights()
local function options(preset)
  local configured = { window = { layout = 'fixed', density = 'full', width = 48,
    max_width = 64, max_height = 16, details = { enabled = false } } }
  if preset then configured.presentation = { version = 1, selected = 'full', presets = {} } end
  return Host.options(configured, {}, 'review')
end
local function scene()
  local items = {}
  for index = 1, 11 do items[index] = { key = tostring(index), name = 'Choice ' .. index } end
  return { path = '\\ Review', input = true, review = true, selected = 8, items = items,
    content = { 'Before: Debug', 'After: Release' }, target = 'src/main.cpp',
    required_facts = { { 'Before: Debug', 'After: Release' } },
    help = 'Esc Back · Enter Run · ? View · Ctrl-h Details · Shift+PgUp/Down Scroll details' }
end
local function planned(data, opts)
  local wins, bufs = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
  opts = Model.normalize(data, opts)
  local source = data
  local prepared, effective = Panels.prepare(V, {}, data, opts)
  local body, guide = Guide.plan(V, prepared, effective, source)
  local plan = Renderer.plan(V, body, effective)
  H.eq(wins, #vim.api.nvim_list_wins(), 'Planning cannot create or close windows')
  H.eq(bufs, #vim.api.nvim_list_bufs(), 'Planning cannot create or close buffers')
  return plan, guide
end
for _, preset in ipairs({ false, true }) do
  local opts, data, view = options(preset), scene(), {}
  local before_data, before_opts = vim.deepcopy(data), vim.deepcopy(opts)
  local plan, guide = planned(data, opts)
  H.eq('right', guide.placement, 'Wide review assigns complete optional controls to the right')
  H.eq(before_data, data, 'Planning retains the submitted scene')
  H.eq(before_opts, opts, 'Planning retains authored settings')
  V.draw(view, vim.deepcopy(data), opts)
  H.eq('right', view.panel_report.guide)
  H.eq(plan.page_size, view.page_size, 'Actual list capacity uses the pure panel plan')
  H.eq(plan.complete, view.presentation_review_complete)
  local complete, _, size = V.presentation_review_status(data, opts)
  H.eq(plan.complete, complete, 'Fresh admission includes the same guide extraction')
  H.eq(plan.page_size, size, 'Fresh admission reserves the same body rows')

  vim.o.columns = 70
  plan, guide = planned(data, opts)
  H.eq('below', guide.placement, 'Narrowing puts complete controls back below')
  V.draw(view, vim.deepcopy(data), opts)
  H.eq(nil, view.guide, 'The old side guide is released')
  H.eq(plan.page_size, view.page_size, 'Fallback and drawing agree on current capacity')
  complete, _, size = V.presentation_review_status(data, opts)
  H.eq(plan.complete, complete)
  H.eq(plan.page_size, size)
  V.close(view)

  vim.o.columns = 180
  local window = V.window
  local checked, failure = xpcall(function()
    V.window = function(part, ...)
      local result = window(part, ...)
      if part == view.guide then error('Deliberate guide allocation failure') end
      return result
    end
    V.draw(view, vim.deepcopy(data), opts)
  end, debug.traceback)
  V.window = window
  H.ok(checked, failure)
  H.eq(nil, view.guide, 'Failed optional allocation has no retained orphan')
  H.eq(true, view.presentation_options._guide_fallback, 'Actual fallback is retained for fresh validation')
  plan, guide = planned(data, view.presentation_options)
  H.eq('below', guide.placement, 'Fresh validation cannot assume a failed guide exists')
  H.eq(plan.page_size, view.page_size, 'Failure fallback uses the same row budget')
  complete, _, size = V.presentation_review_status(data, view.presentation_options)
  H.eq(plan.complete, complete)
  H.eq(plan.page_size, size)
  V.draw(view, vim.deepcopy(data), opts)
  H.eq('right', view.panel_report.guide, 'A normal redraw can recover optional rendering')
  H.eq(nil, view.presentation_options._guide_fallback, 'Recovered drawing drops the transient fallback')
  V.close(view)
end
H.eq(1, #vim.api.nvim_list_wins(), 'All display resources are released')
