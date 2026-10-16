-- One side-effect-free main-panel plan drives drawing and fresh admission.
local H = require('helpers')
vim.opt.rtp:prepend(H.repo_root())
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local V, Host = require('command_tree.view'), require('command_tree.presentation')
local Renderer = require('command_tree.view.presentation')
V.highlights()

local function options(density, layout)
  return Host.options({ window = { layout = layout, density = density, width = 42,
    max_width = 52, max_height = 18, details = { enabled = true, max_height = 4 } },
    presentation = { version = 1, selected = density, presets = {} } }, {}, 'review')
end
local function review()
  local data = { path = '\\ run', title = 'Build', label = 'Review arguments', input = true,
    review = true, selected = 1, content = { 'Review saved arguments' },
    details = { target = 'src/main.cpp' }, required_facts = { { 'Before: Debug', 'After: Release' } }, items = {} }
  for index = 1, 11 do
    data.items[index] = { key = tostring(index), name = 'Option ' .. index .. ' ' .. string.rep('한글 ', 5) }
  end
  return data
end
local function fresh(data, opts)
  local wins, bufs = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
  local complete, reason, size, plan = Renderer.required_status(V, data, opts)
  H.eq(wins, #vim.api.nvim_list_wins(), 'Fresh planning does not create windows')
  H.eq(bufs, #vim.api.nvim_list_bufs(), 'Fresh planning does not create buffers')
  H.eq(size, plan.page_size, 'Admission returns the common page size')
  return complete, reason, plan
end

for _, layout in ipairs({ 'fixed', 'dynamic' }) do
  for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
    local opts, data, view = options(density, layout), review(), {}
    for _, selected in ipairs({ 1, #data.items }) do
      data.selected = selected
      local complete, _, plan = fresh(data, opts)
      V.draw(view, vim.deepcopy(data), opts)
      H.eq(true, complete, layout .. '/' .. density .. ' representable review is admitted')
      H.eq(complete, view.presentation_review_complete, 'Whole-review admission agrees with rendering')
      H.eq(plan.width, view.presentation_plan.width, 'Both paths measure the same content cells')
      H.eq(plan.body_height, view.presentation_plan.body_height, 'Both paths reserve the same body rows')
      H.eq(plan.page_size, view.presentation_plan.page_size, 'Both paths use the same wrapped-item page size')
      local first = (math.ceil(selected / plan.page_size) - 1) * plan.page_size + 1
      if density == 'minimal' then
        first = math.max(1, math.min(selected - math.floor(plan.page_size / 2), #data.items - plan.page_size + 1))
      end
      H.eq(first, view.visible_first, 'Rendered first item follows the common page plan')
      H.eq(math.min(#data.items, first + plan.page_size - 1), view.visible_last,
        'Rendered last item follows the common page plan')
    end

    -- A mandatory fact on an unselected page is still part of admission.
    data.required_facts[2] = { 'Before: ' .. string.rep('wide 한글 ', 500), 'After: short' }
    H.eq(false, fresh(data, opts), 'An undisplayed oversized fact cannot hide behind the selected Run page')
    V.draw(view, vim.deepcopy(data), opts)
    H.eq(false, view.presentation_review_complete, 'Rendering keeps the same all-page refusal')

    data = review()
    vim.o.columns, vim.o.lines = 22, 9
    local complete, _, small = fresh(data, opts)
    V.draw(view, vim.deepcopy(data), opts)
    H.eq(false, complete, 'A narrow short viewport refuses missing review facts')
    H.eq(complete, view.presentation_review_complete, 'Resize refusal agrees with drawing')
    H.eq(small.width, view.presentation_plan.width, 'Resize uses current cell width')
    vim.o.columns, vim.o.lines = 120, 42
    H.eq(true, fresh(data, opts), 'Enlarging recalculates admission without retaining a refusal')
    V.draw(view, vim.deepcopy(data), opts)
    H.eq(true, view.presentation_review_complete, 'Drawing recovers with the same fresh plan')
    V.close(view)
  end
end
