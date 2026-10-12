-- Actual Neovim appearance codec, data conversion and floating renderer.
-- Display projections are not physical input or Settings-import navigation.
local root, folder = assert(vim.env.RE35_ROUNDTRIP_ROOT), assert(vim.env.RE35_ROUNDTRIP_FOLDER)
vim.opt.runtimepath = { root, assert(vim.env.VIMRUNTIME) }
vim.opt.packpath = {}
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.shadafile = false, false, false, 'NONE'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local Files, Data = require('command_tree.presentation_export'), require('command_tree.presentation_data')
local Renderer, View = require('command_tree.presentation'), require('command_tree.view')
local Profile, UI = require('command_tree.profile'), require('command_tree.ui_export')
local Core = require('command_environment.core.presentation')
local phase, checks = assert(vim.env.RE35_ROUNDTRIP_PHASE), 0
local function eq(expected, actual, message)
  assert(vim.deep_equal(expected, actual), message or 'Appearance round-trip mismatch'); checks = checks + 1
end
local function ok(value, message) assert(value, message); checks = checks + 1; return value end
local function read(path) local value, why = Files.read(path); return ok(value, why) end
local function write(value, path)
  local published, why = Files.export(value, path, {}, function() return true end)
  ok(published, why)
end
local ui = { density = 'compact', icons = false, width = 72, max_width = 104, max_height = 17,
  position = 'bottom-right', compact_rows = 7, minimal_rows = 2 }
local ui_before = vim.deepcopy(ui)
local profile = Profile.empty()
profile.ui = vim.deepcopy(ui)
profile.tools.keep = { command = 'never-started', args = { 'unchanged' } }
profile.layout.aliases.keep = 'fixture.never-run'
local profile_before = vim.deepcopy(profile)
local config = { version = 1, selected = 'portable', presets = {
  foundation = { name = 'Foundation 한글 😀', extends = false,
    information = { title = false, help = true, details = false, status = true, icons = false },
    layout = { density = 'compact', position = 'bottom-right', width = 73, max_width = 102, max_height = 20, rows = 9 },
    spacing = { horizontal = 4, vertical = 1 }, decoration = { border = 'double', separator = false },
    roles = { normal = { bg = '#112233' }, accent = { fg = '#AABBCC' }, selected = { fg = '#FFFFFF', bg = '#445566' } },
    scenes = { tree = { information = { help = false } }, search = { spacing = { horizontal = 3 } },
      input = { information = { title = true } }, review = { information = { details = false } },
      tasks = { layout = { rows = 5 } }, results = { roles = { warning = { fg = '#FFA500' } } } } },
  portable = { name = 'Portable workflow 한글 😀', extends = 'foundation' }
} }
local envelope = ok(Files.capture(config), 'Neovim captures the shared envelope')
local windows = {}
local function draw(presentation)
  vim.o.columns, vim.o.lines = 120, 40
  View.highlights()
  for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
    local options = Renderer.options({ window = ui, presentation = presentation },
      { presentation_id = presentation.selected, density = 'compact' }, scene)
    ok(options.presentation, 'Actual Neovim negotiation resolves ' .. scene)
    eq(scene, options.presentation_report.scene)
    local view = {}; windows[#windows + 1] = view
    View.draw(view, { title = 'Round trip 한글 😀', path = '\\', selected = 1,
      items = { { key = 'x', name = 'Portable appearance', detail = 'Read-only renderer projection' } } }, options)
    ok(vim.api.nvim_win_is_valid(view.win), 'Actual native float exists')
    local geometry = vim.api.nvim_win_get_config(view.win)
    eq(geometry.height, #vim.api.nvim_buf_get_lines(view.buf, 0, -1, false))
    View.close(view)
  end
end
local function run()
  if phase == 'export' then
    write(envelope, folder .. '/nvim-original.json')
    local local_ui = ok(UI.capture(ui, ui.density))
    local exported, reason = UI.export(local_ui, folder .. '/nvim-local-ui.json', {}, function() return true end)
    ok(exported, reason)
    draw(envelope.presentation)
  elseif phase == 'return' then
    local unchanged, edited = read(folder .. '/node-unchanged.json'), read(folder .. '/node-edited.json')
    eq(envelope, unchanged, 'Neovim -> Node appearance-only export is exact')
    local expected = vim.deepcopy(envelope.presentation)
    expected.presets.foundation.spacing.horizontal = 5
    expected.presets.detached = edited.presentation.presets.detached
    eq(expected, edited.presentation, 'Node changes only the declared field and independent clone')
    eq(false, edited.presentation.presets.foundation.extends, 'Explicit standalone false survives')
    eq(false, edited.presentation.presets.detached.extends, 'Independent clone is standalone')
    local clone = edited.presentation.presets.detached
    for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
      local source, why = Core.resolve(Data.core(envelope.presentation), 'portable', scene)
      ok(source, why)
      local independent, reason = Core.resolve(Data.core(edited.presentation), 'detached', scene)
      ok(independent, reason)
      source.id, source.name = independent.id, independent.name
      eq(Data.host(source), Data.host(independent), 'Clone retains original ' .. scene .. ' meaning after parent edit')
      ok(clone.scenes[scene], 'Independent clone contains ' .. scene)
    end
    draw(edited.presentation)
    write(ok(Files.capture(edited.presentation)), folder .. '/nvim-returned.json')
    eq(edited, read(folder .. '/nvim-returned.json'), 'Node -> Neovim export is exact')
    local local_ui, reason = UI.read(folder .. '/nvim-local-ui.json')
    ok(local_ui, reason); eq(ui, local_ui.ui, 'Eight Neovim UI values remain separate')
    eq(nil, edited.ui, 'Appearance envelope contains no host-local UI snapshot')
    eq(nil, edited.tools, 'Appearance envelope contains no tool or process data')
  else error('Unknown appearance round-trip phase') end
  eq(ui_before, ui, 'Renderer and sharing do not mutate local UI values')
  eq(profile_before, profile, 'Sharing does not mutate unrelated profile data')
  print(vim.json.encode({ passed = true, phase = phase, checks = checks,
    actual_neovim = true, actual_float_renderer = true, projection_scenes = 6,
    physical_gestures = false, actual_settings_import_navigation = false,
    host_local_ui_separate = true, unrelated_profile_unchanged = true }))
end
local passed, reason = xpcall(run, debug.traceback)
for _, view in ipairs(windows) do pcall(View.close, view) end
if not passed then io.stderr:write(tostring(reason) .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
