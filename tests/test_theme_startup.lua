-- Fresh editor processes prove startup behavior rather than simulating a restart
-- with cached Lua modules. All children inherit the runner's isolated state roots.
local H = require('helpers')
local root, folder = H.repo_root(), H.tempdir('theme-startup')
local sequence = 0
local function child(name, before_enter, after_enter)
  sequence = sequence + 1
  local marker = 'RE35_THEME_CHILD_PASS_' .. sequence
  local script = string.format([[
local root = %q
vim.opt.runtimepath = { root, assert(vim.env.VIMRUNTIME) }
vim.opt.packpath = {}
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
vim.o.shadafile = 'NONE'
vim.o.swapfile, vim.o.backup, vim.o.writebackup = false, false, false
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local Themes = require('command_tree.integrations.themes')
local theme_creations, theme_restores = {}, {}
local create = Themes.new
Themes.new = function(options)
  local adapter = create(options)
  local restore = adapter.restore
  local id = #theme_creations + 1
  theme_creations[id] = adapter
  adapter.restore = function(...)
    theme_restores[id] = (theme_restores[id] or 0) + 1
    return restore(...)
  end
  return adapter
end
local RE35 = require('re35')
local function setup_options(extra)
  return vim.tbl_extend('force', { profile = { path = false }, usage = { path = false }, preferences = { path = false } }, extra or {})
end
local folder = %q
%s
vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
  vim.schedule(function()
    local ok, reason = xpcall(function()
      check(vim.v.vim_did_enter == 1, 'Assertions execute after actual VimEnter')
      %s
    end, debug.traceback)
    if not ok then
      io.stderr:write(tostring(reason) .. '\n'); io.stderr:flush(); vim.cmd('cquit 1'); return
    end
    io.stdout:write(%q .. ':' .. checks .. '\n'); io.stdout:flush(); vim.cmd('qa!')
  end)
end })
]], root, folder, before_enter or '', after_enter or '', marker)
  local init_path = folder .. '/child-' .. sequence .. '.lua'
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), init_path)
  local result = vim.system({ vim.v.progpath, '--headless', '-u', init_path, '-i', 'NONE', '--noplugin', '-n' },
    { text = true }):wait(10000)
  local output = (result.stdout or '') .. (result.stderr or '')
  H.eq(0, result.code, 'Fresh editor scenario completed: ' .. name .. '\n' .. output)
  H.eq(0, result.signal, 'Fresh editor scenario was not terminated: ' .. name)
  H.ok(output:find(marker .. ':', 1, true), 'Fresh editor ran every scheduled assertion: ' .. name .. '\n' .. output)
end

child('plain setup saves the confirmed command', [[
RE35.setup()
]], [[
check(theme_restores[1] == 1, 'First startup makes exactly one restore attempt')
local ok, result = RE35.execute('ui.theme', { theme = 'desert' }, { interactive = false })
check(ok, 'Actual RE35 theme command succeeds: ' .. tostring(result))
check(vim.g.colors_name == 'desert', 'Actual command selected desert')
local data, reason = require('command_tree.integrations.theme_state').read(vim.fn.stdpath('state') .. '/re35/theme.json')
check(data and data.theme == 'desert', 'Plain setup saved the confirmed theme: ' .. tostring(reason))
check(RE35.persistence_status().theme.state == 'saved', 'Public persistence report says Saved')
]])

child('plain setup restores after exiting the previous process', [[
vim.cmd.colorscheme('default')
RE35.setup()
check(vim.g.colors_name == 'default', 'Candidate setup has no immediate colorscheme side effect')
]], [[
check(vim.g.colors_name == 'desert', 'Plain setup restores the prior process confirmed theme')
check(theme_restores[1] == 1, 'Fresh startup restores once')
check(RE35.persistence_status().theme.state == 'restored', 'Public persistence report says Restored')
]])

child('session-only opt-out matches the prior adapter behavior', [[
vim.cmd.colorscheme('default')
RE35.setup({ theme = { persist = false } })
]], [[
check(vim.g.colors_name == 'default', 'Opt-out does not load the saved startup theme')
check(theme_restores[1] == nil, 'Opt-out does not invoke restore')
local ok = RE35.execute('ui.theme', { theme = 'elflord' }, { interactive = false })
check(ok and vim.g.colors_name == 'elflord', 'Opt-out still applies confirmed session themes')
local data = require('command_tree.integrations.theme_state').read(vim.fn.stdpath('state') .. '/re35/theme.json')
check(data.theme == 'desert', 'Opt-out preserves the original saved startup choice')
check(RE35.persistence_status().theme.state == 'session_only', 'Opt-out reports Session only')
]])

child('custom wrapped adapter retains startup ownership', [[
vim.cmd.colorscheme('default')
local custom = Themes.new()
custom.restore = function() error('Custom restore must only run when its owner asks') end
RE35.setup(setup_options({ integrations = { theme = custom } }))
]], [[
check(vim.g.colors_name == 'default', 'A custom wrapper does not load builtin persisted state')
check(theme_restores[1] == nil, 'A supplied builtin wrapper is not automatically restored')
check(RE35.persistence_status().theme.state == 'adapter_owned', 'Inherited builtin status cannot falsely claim a custom wrapper is session-only')
local ok = RE35.execute('ui.theme', { theme = 'elflord' }, { interactive = false })
check(ok and vim.g.colors_name == 'elflord', 'A custom wrapper still owns theme commits')
local data = require('command_tree.integrations.theme_state').read(vim.fn.stdpath('state') .. '/re35/theme.json')
check(data.theme == 'desert', 'A standalone session adapter does not adopt builtin persistence')
custom.persistence_status = function() return { state = 'saved', scope = 'startup', theme = 'elflord', path = folder .. '/owned-theme.txt' } end
RE35.setup(setup_options({ integrations = { theme = custom } }))
check(RE35.persistence_status().theme.state == 'saved', 'A custom wrapper can explicitly report its own storage')
check(RE35.persistence_status().theme.owner == 'Custom theme adapter', 'Custom status keeps its actual owner visible')
]])

child('Apply and Reload preserve one restore before and after VimEnter', [[
vim.cmd.colorscheme('default')
RE35.setup(setup_options({ profile = { path = folder .. '/before-enter-profile.json' } }))
check(RE35.update_profile(function(profile) profile.ui.density = 'compact' end), 'Apply before VimEnter succeeds')
check(RE35.reload_profile(), 'Reload before VimEnter succeeds')
check(vim.g.colors_name == 'default', 'Profile rebuilding does not restore a candidate theme')
]], [[
check(vim.g.colors_name == 'desert', 'The final activated environment retains startup restoration')
check(theme_restores[1] == 1 and #theme_creations == 1, 'Apply/Reload before VimEnter retain one adapter and one restore')
vim.cmd.colorscheme('default')
check(RE35.update_profile(function(profile) profile.ui.density = 'full' end), 'Apply after VimEnter succeeds')
check(RE35.reload_profile(), 'Reload after VimEnter succeeds')
vim.wait(100, function() return false end, 10)
check(vim.g.colors_name == 'default', 'Apply/Reload do not reset a later native editor theme')
check(theme_restores[1] == 1 and #theme_creations == 1, 'Apply/Reload after VimEnter do not restore again')
]])

child('post-startup Apply and Reload transfer a pending scheduled restore', [[
vim.cmd.colorscheme('default')
]], [[
RE35.setup(setup_options({ profile = { path = folder .. '/after-enter-profile.json' } }))
check(vim.g.colors_name == 'default', 'Post-startup restoration is scheduled, not run under lifecycle activation')
check(RE35.update_profile(function(profile) profile.ui.density = 'compact' end), 'Apply while restore is scheduled succeeds')
check(RE35.reload_profile(), 'Reload while restore is scheduled succeeds')
check(vim.wait(1000, function() return vim.g.colors_name == 'desert' end, 10), 'Current replacement receives the pending startup restore')
check(theme_restores[1] == 1 and #theme_creations == 1, 'Stale scheduled environments cannot duplicate restoration')
]])

child('failed candidate activation cannot restore its theme', [[
vim.cmd.colorscheme('default')
RE35.setup(setup_options())
]], [[
check(vim.g.colors_name == 'desert' and theme_restores[1] == 1, 'Existing activated host restored correctly')
local candidate_path = folder .. '/candidate-theme.json'
check(require('command_tree.integrations.theme_state').write(candidate_path, 'elflord', vim.o.background), 'Candidate fixture theme is saved')
local token = RE35.environment_token()
local Events = require('command_tree.environment.events')
local install, fail_once = Events.install, true
Events.install = function(...)
  install(...)
  if fail_once then fail_once = false; error('Fixture failure after candidate hook installation') end
end
local ok, reason = pcall(RE35.setup, setup_options({ theme = { persist = true, path = candidate_path } }))
Events.install = install
check(not ok and tostring(reason):find('Host activation failed', 1, true), 'Candidate hook failure is reported')
check(RE35.is_current_environment(token), 'Failed candidate restores the previous host identity')
vim.wait(100, function() return false end, 10)
check(vim.g.colors_name == 'desert', 'Rejected candidate cannot apply its elflord theme')
check(theme_restores[1] == 1 and theme_restores[2] == nil, 'Candidate scheduled callback is stale and prior restore is not repeated')
]])

child('disable revokes an already scheduled startup restore', [[
vim.cmd.colorscheme('default')
]], [[
RE35.setup(setup_options())
check(RE35.disable(), 'Host can be disabled before scheduled restoration runs')
vim.wait(100, function() return false end, 10)
check(vim.g.colors_name == 'default', 'Disabled host cannot apply its scheduled theme')
check(theme_restores[1] == nil, 'Disabled host does not attempt restoration')
]])

print('Theme startup: ' .. H.checks .. ' parent checks and eight fresh editor scenarios passed')
