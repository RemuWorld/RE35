-- Actual picker controls keep appearance/preview drafts separate from commit.
local H, K = require('helpers'), require('command_tree.keys')
local State = require('command_tree.integrations.theme_state')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('theme-appearance')
local runtime = folder .. '/runtime'
vim.fn.mkdir(runtime .. '/colors', 'p')
local adaptive_palette = "vim.api.nvim_set_hl(0, 'Normal', { bg = vim.o.background == 'light' and '#eeeeee' or '#222222' })"
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_adaptive'", adaptive_palette }, runtime .. '/colors/re35_fixture_adaptive.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_dark_only'", "vim.o.background = 'dark'",
  "vim.api.nvim_set_hl(0, 'Normal', { bg = '#222222' })" },
  runtime .. '/colors/re35_fixture_dark_only.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_light_only'", "vim.o.background = 'light'",
  "vim.api.nvim_set_hl(0, 'Normal', { bg = '#eeeeee' })" },
  runtime .. '/colors/re35_fixture_light_only.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_adaptive'", adaptive_palette }, runtime .. '/colors/re35_fixture_alias.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_broken'", adaptive_palette }, runtime .. '/colors/re35_fixture_broken.lua')
vim.opt.runtimepath:prepend(runtime)
-- Keep this UI fixture's discovery domain finite. Actual built-in sources and
-- worker processes are still used; catalog coverage tests full cache behavior.
local completion = vim.fn.getcompletion
vim.fn.getcompletion = function(lead, kind, ...)
  local values = completion(lead, kind, ...)
  if kind ~= 'color' then return values end
  return vim.tbl_filter(function(name)
    return name == 'default' or name == 'desert' or name == 'peachpuff' or name:match('^re35_fixture_') ~= nil
  end, values)
end
vim.o.columns, vim.o.lines = 200, 60
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function saved(path) return table.concat(vim.fn.readfile(path), '\n') end
local function text(part)
  return part and part.buf and vim.api.nvim_buf_is_valid(part.buf)
    and table.concat(vim.api.nvim_buf_get_lines(part.buf, 0, -1, false), '\n'):gsub('%s+', ' ') or ''
end
local function hint(part, key, label)
  H.ok(text(part):find(key .. ' ' .. label, 1, true), 'Theme guide exposes ' .. key .. ' ' .. label)
end
local function setup(density, path, integration, persist)
  local profile = Profile.empty()
  profile.presentation = { version = 1, selected = density, presets = {} }
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
    theme = { persist = persist ~= false, path = path }, integrations = integration and { theme = integration } or {},
    guidance = { first_run = false }, auto = false, operator_help = false, triggers = {},
    providers = { builtin = false, plugins = true, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    window = { layout = 'fixed', width = 70, max_height = 16, icons = false } })
end
local function open_theme()
  H.ok(CE.open({ command = 'ui.theme', interactive = false }))
  local adapter = session.options.integrations.theme
  if adapter.builtin then
    H.ok(vim.wait(20000, function()
      local light, dark = adapter.classification_status('light'), adapter.classification_status('dark')
      return light.initialized and light.pending == 0 and dark.pending == 0
    end, 10), 'The actual theme picker receives classified choices')
    session:refresh_input_choices(); session:draw()
  end
end

for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  local path = folder .. '/' .. density .. '.json'
  vim.cmd.colorscheme('default'); vim.o.background = 'dark'
  setup(density, path)
  local operations = #CE.operations()
  open_theme()
  local input, state = session.active.input, session.active
  H.eq(1, #input.command.arguments, density .. ': one Theme choice preserves the direct picker flow')
  H.eq('dark', input.args.background, density .. ': draft starts with actual appearance')
  H.eq(true, input.args.preview, density .. ': navigating previews by default')
  if density == 'full' then
    H.ok(state.view.guide and vim.api.nvim_win_is_valid(state.view.guide.win), 'Actual Full theme picker has a side Keys panel')
    H.eq('right', state.view.panel_report.guide)
    hint(state.view.guide, '↑/↓', 'Select'); hint(state.view.guide, 'PgUp/Down', 'Page')
    hint(state.view.guide, 'Ctrl+b', 'Light/Dark'); hint(state.view.guide, 'Ctrl+t', 'Auto preview')
    hint(state.view.guide, 'Enter', 'Confirm'); hint(state.view.guide, 'Esc', 'Cancel')
    keys('/')
    hint(state.view.guide, 'Esc', 'Finish filter')
    H.ok(not text(state.view.guide):find('Ctrl+b', 1, true) and not text(state.view.guide):find('Ctrl+t', 1, true),
      'Filter mode never advertises disabled appearance controls as active shortcuts')
    keys('<C-b><C-t>')
    H.eq('dark', input.args.background, 'Filter editing cannot toggle Light/Dark')
    H.eq(true, input.args.preview, 'Filter editing cannot toggle automatic preview')
    keys('<Esc>')
    hint(state.view.guide, 'Ctrl+b', 'Light/Dark'); hint(state.view.guide, 'Ctrl+t', 'Auto preview')
    vim.o.columns = 90; session:draw()
    H.eq(nil, state.view.guide, 'Narrowing the actual theme picker releases the side guide')
    H.eq('below', state.view.panel_report.guide, 'Narrow theme picker reports its complete below fallback')
    local below = table.concat(state.view.details.lines, '\n'):gsub('%s+', ' ')
    H.ok(below:find('Ctrl+b', 1, true), 'Narrow fallback retains theme controls in scrollable details')
    H.ok(below:find('Ctrl+t', 1, true), 'Narrow fallback retains auto-preview in scrollable details')
    vim.o.columns = 200; session:draw()
    hint(state.view.guide, 'Ctrl+b', 'Light/Dark')
  else
    H.eq(nil, state.view.guide, density .. ': does not add a Full-only side guide')
  end
  keys('<C-b>')
  H.eq('light', input.args.background, density .. ': explicit Light/Dark control updates the draft')
  H.eq('light', vim.o.background, density .. ': enabled preview shows the chosen appearance')
  local rendered = table.concat(vim.api.nvim_buf_get_lines(state.view.buf, 0, -1, false), '\n')
  H.ok(rendered:find('Light', 1, true), density .. ': appearance is visible in the actual picker')
  H.eq(nil, vim.uv.fs_stat(path), density .. ': appearance preview never saves')
  keys('<C-t>')
  H.eq(false, input.args.preview, density .. ': auto preview can be disabled without leaving the list')
  H.eq('default', vim.g.colors_name); H.eq('dark', vim.o.background, density .. ': disabling preview restores the original pair')
  keys('/re35_fixture_adaptive<Esc>')
  H.ok(input.choices[input.selected], 'Adaptive fixture must be classified: '
    .. vim.inspect(session.options.integrations.theme.classification_status('light')))
  H.eq('re35_fixture_adaptive', input.choices[input.selected].value, density .. ': filtered choice is selected')
  H.eq('default', vim.g.colors_name, density .. ': navigation with preview off has no theme side effect')
  H.eq('dark', vim.o.background)
  H.eq(nil, vim.uv.fs_stat(path)); H.eq(operations, #CE.operations(), density .. ': controls and browsing execute no command')
  keys('<CR>')
  H.eq('re35_fixture_adaptive', vim.g.colors_name, density .. ': confirmation applies the selected theme with preview off')
  H.eq('light', vim.o.background, density .. ': confirmation applies the chosen pending appearance')
  local record = H.ok(State.read(path))
  H.eq('re35_fixture_adaptive', record.theme); H.eq('light', record.background)
  local persisted = saved(path)
  H.eq('light', CE.persistence_status().theme.background, density .. ': status names the exact saved appearance')
  CE.close()
  vim.o.background = 'dark'
  H.eq(persisted, saved(path), density .. ': native background changes do not silently rewrite confirmed state')
  open_theme()
  H.eq('dark', session.active.input.args.background, density .. ': new picker reflects the actual native appearance')
  keys('<C-b><Esc>')
  H.eq('re35_fixture_adaptive', vim.g.colors_name); H.eq('dark', vim.o.background, density .. ': Back restores both original values')
  H.eq(persisted, saved(path), density .. ': cancellation preserves saved startup state')
  CE.close()
end

-- Explicit appearance must not silently save a scheme's different preference.
vim.cmd.colorscheme('default'); vim.o.background = 'dark'
local path = folder .. '/conflict.json'
setup('full', path)
for _, conflict in ipairs({ { 're35_fixture_dark_only', 'light', 'dark' }, { 're35_fixture_light_only', 'dark', 'light' } }) do
  vim.cmd.colorscheme('default'); vim.o.background = conflict[3]
  local ok, why = CE.execute('ui.theme', { theme = conflict[1], background = conflict[2] }, { interactive = false })
  H.eq(false, ok, 'Fixed-appearance schemes reject the opposite requested appearance')
  H.ok(tostring(why):find('selected ' .. conflict[3] .. ' appearance; requested ' .. conflict[2], 1, true),
    'Appearance mismatch explains the actual and requested values')
  H.ok(tostring(why):find('Ctrl-b', 1, true), 'Appearance mismatch explains how to select the compatible appearance')
  H.eq('default', vim.g.colors_name, 'Rejected appearance preserves the original theme identity')
  H.eq(conflict[3], vim.o.background, 'Rejected appearance restores the original background')
  H.eq(nil, vim.uv.fs_stat(path), 'Rejected appearance never creates startup state')
end
H.ok(CE.execute('ui.theme', { theme = 're35_fixture_alias', background = 'light' }, { interactive = false }),
  'A valid theme alias need not assign colors_name equal to its filename')
H.eq('re35_fixture_adaptive', vim.g.colors_name)
H.eq('re35_fixture_alias', H.ok(State.read(path)).theme, 'Persistence retains the user-selected runtime alias')
vim.cmd.colorscheme('default'); vim.o.background = 'dark'
for _, args in ipairs({ { theme = 'default', background = 'sepia' }, { theme = 'default', preview = 'off' } }) do
  H.eq(false, CE.execute('ui.theme', args, { interactive = false }), 'Malformed native options fail before applying')
  H.eq('default', vim.g.colors_name); H.eq('dark', vim.o.background)
end
H.ok(CE.execute('ui.theme', { theme = 'default' }, { interactive = false }), 'Existing theme-only callers still work')
H.eq('dark', H.ok(State.read(path)).background, 'Theme-only callers confirm actual native appearance')

local confirmed = saved(path)
open_theme()
-- A previously classified installed source can fail later. Exercise actual
-- preview rollback without deliberately listing a known-broken theme.
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_broken'", "vim.o.background = 'light'",
  "error('appearance fixture preview failure')" }, runtime .. '/colors/re35_fixture_broken.lua')
keys('/re35_fixture_broken<Esc>')
local failure = require('command_tree.session.feedback').current(session.active)
H.ok(failure.full_message:find('appearance fixture preview failure', 1, true), 'Failed preview remains inspectable')
H.eq('default', vim.g.colors_name); H.eq('dark', vim.o.background, 'Partially applied preview restores both original values')
keys('<C-t>')
H.eq(false, session.active.input.args.preview, 'Preview can be disabled after a script failure')
H.eq(nil, require('command_tree.session.feedback').current(session.active), 'Disabled preview clears its superseded diagnostic')
keys('<CR>')
H.eq('default', vim.g.colors_name); H.eq('dark', vim.o.background, 'A failed explicit commit restores both original values')
H.eq(confirmed, saved(path), 'Failed preview and commit preserve previously confirmed startup state')
CE.close()

-- Peachpuff is a real light-only runtime scheme. Forcing background back to
-- dark used to clear colors_name while retaining its light palette, yet report
-- a successful dark preview/commit. The classified picker now prevents that
-- ordinary mismatch instead of presenting it as a routine preview failure.
local peach_path = folder .. '/peachpuff.json'
vim.cmd.colorscheme('desert'); vim.o.background = 'dark'
setup('full', peach_path)
open_theme()
keys('/peachpuff<Esc>')
local peach_input, peach_state = session.active.input, session.active
H.eq(0, #peach_input.choices, 'Light-only Peachpuff never appears in the classified Dark list')
H.eq('dark', peach_input.args.background)
H.eq('desert', vim.g.colors_name, 'Excluded themes have no preview effects')
H.eq('dark', vim.o.background)
H.eq(nil, vim.uv.fs_stat(peach_path))
failure = require('command_tree.session.feedback').current(peach_state)
H.eq(nil, failure, 'Ordinary Light/Dark filtering produces no mismatch warning')
hint(peach_state.view.guide, 'Ctrl+b', 'Light/Dark')
keys('<C-b>')
H.eq(peach_input, session.active.input, 'Changing appearance refreshes the attached picker')
H.eq('light', peach_input.args.background)
H.eq('peachpuff', vim.g.colors_name, 'Compatible Light preview retains the real theme identity')
H.eq('light', vim.o.background)
H.eq(nil, require('command_tree.session.feedback').current(peach_state), 'Successful Light preview clears the old incompatibility error')
H.eq(nil, vim.uv.fs_stat(peach_path), 'Compatible preview is still temporary')
keys('<CR>')
H.eq('peachpuff', vim.g.colors_name); H.eq('light', vim.o.background)
local peach_saved = H.ok(State.read(peach_path))
H.eq('peachpuff', peach_saved.theme); H.eq('light', peach_saved.background, 'Confirm saves the compatible pair only')
local peach_confirmed = saved(peach_path)
CE.close()
vim.cmd.colorscheme('desert'); vim.o.background = 'dark'
open_theme()
keys('/peachpuff<Esc><C-b>')
H.eq('peachpuff', vim.g.colors_name); H.eq('light', vim.o.background)
keys('<Esc>')
H.eq('desert', vim.g.colors_name); H.eq('dark', vim.o.background, 'Cancelling Peachpuff returns to the original pair')
H.eq(peach_confirmed, saved(peach_path), 'Cancelling a later preview never rewrites the confirmed pair')
CE.close()
H.ok(CE.execute('ui.theme', { theme = 'peachpuff' }, { interactive = false }),
  'Theme-only callers retain native behavior for fixed-appearance themes')
H.eq('peachpuff', vim.g.colors_name); H.eq('light', vim.o.background)
local incompatible_path = folder .. '/incompatible-startup.json'
H.ok(State.write(incompatible_path, 'peachpuff', 'dark'))
local incompatible_saved = saved(incompatible_path)
vim.cmd.colorscheme('desert'); vim.o.background = 'dark'
local incompatible = require('command_tree.integrations.themes').new({ persist = true, path = incompatible_path })
local restored, incompatible_status = incompatible.restore()
H.eq(false, restored, 'Previously saved incompatible Peachpuff/Dark startup state is rejected')
H.eq('restore_failed', incompatible_status.state)
H.ok(incompatible_status.error:find('selected light appearance; requested dark', 1, true))
H.eq('desert', vim.g.colors_name); H.eq('dark', vim.o.background, 'Rejected startup appearance restores the current pair')
H.eq(incompatible_saved, saved(incompatible_path), 'Rejected startup state remains untouched for explicit user recovery')

-- Storage failure keeps the applied pair and accurately reports session scope.
setup('full', path)
vim.cmd.colorscheme('default'); vim.o.background = 'dark'
session.drafts:forget('ui.theme', K.context().buf)
open_theme()
keys('<C-b><C-t>')
local write = State.write
State.write = function() return false, 'fixture startup state denied' end
keys('<CR>')
State.write = write
H.eq('default', vim.g.colors_name); H.eq('light', vim.o.background, 'Failed save keeps the explicitly confirmed session appearance')
local storage = CE.persistence_status().theme
H.eq('save_failed', storage.state); H.eq('session', storage.scope); H.eq('light', storage.background)
H.eq(confirmed, saved(path), 'Failed save preserves the last startup choice')
CE.close()

vim.cmd.colorscheme('default'); vim.o.background = 'dark'
local session_path = folder .. '/session-only.json'
setup('minimal', session_path, nil, false)
open_theme()
local body = table.concat(vim.api.nvim_buf_get_lines(session.active.view.buf, 0, -1, false), '\n')
H.ok(body:find('Session only', 1, true), 'Opt-out confirmation scope is visible even in Minimal')
keys('<C-b><CR>')
H.eq('light', vim.o.background)
H.eq('session_only', CE.persistence_status().theme.state)
H.eq(nil, vim.uv.fs_stat(session_path), 'Builtin theme.persist=false never writes its confirmation')
CE.close()

-- Custom adapters remain single-field pickers without implicitly acquiring
-- builtin storage or Light/Dark behavior they have not declared.
local applied, previews, restored = nil, 0, 0
local custom = { items = function() return { 'Custom A', 'Custom B' } end, current = function() return 'Custom A' end,
  preview = function() previews = previews + 1; return function() restored = restored + 1 end end,
  commit = function(_, args) applied = vim.deepcopy(args); return true end }
setup('full', folder .. '/custom.json', custom)
open_theme()
H.eq(nil, session.active.input.args.background)
keys('<Down><CR>')
H.eq('Custom B', applied.theme); H.eq(nil, applied.background); H.eq(nil, applied.preview)
H.ok(previews > 0 and restored > 0, 'Custom preview/cleanup ownership is preserved')
H.eq(nil, vim.uv.fs_stat(folder .. '/custom.json'), 'Custom adapters do not acquire builtin persistence')
CE.close()
vim.opt.runtimepath:remove(runtime)
vim.fn.getcompletion = completion
print('Theme appearance: ' .. H.checks .. ' checks passed')
