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
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_adaptive'" }, runtime .. '/colors/re35_fixture_adaptive.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_dark_only'", "vim.o.background = 'dark'" },
  runtime .. '/colors/re35_fixture_dark_only.lua')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_broken'", "vim.o.background = 'light'",
  "error('appearance fixture preview failure')" }, runtime .. '/colors/re35_fixture_broken.lua')
vim.opt.runtimepath:prepend(runtime)
vim.o.columns, vim.o.lines = 120, 42
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function saved(path) return table.concat(vim.fn.readfile(path), '\n') end
local function setup(density, path, integration, persist)
  local profile = Profile.empty()
  profile.presentation = { version = 1, selected = density, presets = {} }
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
    theme = { persist = persist ~= false, path = path }, integrations = integration and { theme = integration } or {},
    guidance = { first_run = false }, auto = false, operator_help = false, triggers = {},
    providers = { builtin = false, plugins = true, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    window = { layout = 'fixed', width = 70, max_height = 16, icons = false } })
end

for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  local path = folder .. '/' .. density .. '.json'
  vim.cmd.colorscheme('default'); vim.o.background = 'dark'
  setup(density, path)
  local operations = #CE.operations()
  H.ok(CE.open({ command = 'ui.theme', interactive = false }))
  local input, state = session.active.input, session.active
  H.eq(1, #input.command.arguments, density .. ': one Theme choice preserves the direct picker flow')
  H.eq('dark', input.args.background, density .. ': draft starts with actual appearance')
  H.eq(true, input.args.preview, density .. ': navigating previews by default')
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
  H.ok(CE.open({ command = 'ui.theme', interactive = false }))
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
local ok, why = CE.execute('ui.theme', { theme = 're35_fixture_dark_only', background = 'light' }, { interactive = false })
H.ok(ok, tostring(why)); H.eq('light', vim.o.background)
H.eq('light', H.ok(State.read(path)).background, 'Explicit appearance is reapplied after a scheme changes it while loading')
vim.cmd.colorscheme('default'); vim.o.background = 'dark'
for _, args in ipairs({ { theme = 'default', background = 'sepia' }, { theme = 'default', preview = 'off' } }) do
  H.eq(false, CE.execute('ui.theme', args, { interactive = false }), 'Malformed native options fail before applying')
  H.eq('default', vim.g.colors_name); H.eq('dark', vim.o.background)
end
H.ok(CE.execute('ui.theme', { theme = 'default' }, { interactive = false }), 'Existing theme-only callers still work')
H.eq('dark', H.ok(State.read(path)).background, 'Theme-only callers confirm actual native appearance')

local confirmed = saved(path)
H.ok(CE.open({ command = 'ui.theme', interactive = false }))
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

-- Storage failure keeps the applied pair and accurately reports session scope.
session.drafts:forget('ui.theme', K.context().buf)
H.ok(CE.open({ command = 'ui.theme', interactive = false }))
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
H.ok(CE.open({ command = 'ui.theme', interactive = false }))
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
H.ok(CE.open({ command = 'ui.theme', interactive = false }))
H.eq(nil, session.active.input.args.background)
keys('<Down><CR>')
H.eq('Custom B', applied.theme); H.eq(nil, applied.background); H.eq(nil, applied.preview)
H.ok(previews > 0 and restored > 0, 'Custom preview/cleanup ownership is preserved')
H.eq(nil, vim.uv.fs_stat(folder .. '/custom.json'), 'Custom adapters do not acquire builtin persistence')
CE.close()
vim.opt.runtimepath:remove(runtime)
print('Theme appearance: ' .. H.checks .. ' checks passed')
