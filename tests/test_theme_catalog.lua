-- Actual clean Neovim workers classify palettes without touching the live
-- editor. Fixture themes, caches, and logs stay in the test-owned directory.
local H = require('helpers')
local Themes = require('command_tree.integrations.themes')
local lazy = Themes.new()
lazy.current()
H.ok(lazy.restore(), 'Session-only startup restoration remains available without classification')
H.ok(lazy.commit(nil, { theme = 'default' }), 'Direct application does not need a classification scan')
lazy.input_ui.init(nil, {})
lazy.input_ui.preview_key(nil, {})
H.eq(nil, package.loaded['command_tree.integrations.theme_catalog'], 'Normal adapter setup, current, restore, and direct commit load no classifier')
H.eq(nil, package.loaded['command_tree.integrations.theme_cache'], 'Normal startup reads no classification cache')
lazy.input_ui.choices(nil, { background = 'dark' })
H.ok(package.loaded['command_tree.integrations.theme_catalog'], 'Explicit picker presentation initializes classification lazily')
local Catalog = require('command_tree.integrations.theme_catalog')
local native_version, native_system = vim.version(), vim.system
if native_version.minor < 12 then require('vim._system') end
local folder = H.tempdir('theme-catalog')
local runtime, path, log = folder .. '/runtime', folder .. '/cache.json', folder .. '/workers.log'
vim.fn.mkdir(runtime .. '/colors', 'p')
vim.fn.mkdir(runtime .. '/lua', 'p')
local function write(name, body)
  local lines = { "vim.fn.writefile({ '" .. name .. " ' .. vim.o.background }, " .. string.format('%q', log) .. ", 'a')" }
  vim.list_extend(lines, body)
  lines[#lines + 1] = "vim.g.colors_name = '" .. name .. "'"
  vim.fn.writefile(lines, runtime .. '/colors/' .. name .. '.lua')
end
local adaptive = { "vim.api.nvim_set_hl(0, 'Normal', { bg = vim.o.background == 'light' and '#eeeeee' or '#222222' })" }
write('re35_adaptive', adaptive)
write('re35_light', { "vim.o.background = 'light'", "vim.api.nvim_set_hl(0, 'Normal', { bg = '#ffffff' })" })
write('re35_dark', { "vim.o.background = 'dark'", "vim.api.nvim_set_hl(0, 'Normal', { bg = '#222222' })" })
write('shine', { "vim.o.background = 'dark'", "vim.api.nvim_set_hl(0, 'Normal', { bg = '#222222' })" })
write('re35_transparent', { "vim.api.nvim_set_hl(0, 'Normal', {})" })
write('re35_broken', { "error('classification fixture failed')" })
vim.opt.runtimepath = { runtime }
vim.g.colors_name = 're35_adaptive'
vim.g.re35_test_option = 'private-theme-option-do-not-persist'
vim.g.unrelated_secret = 'never-forward-this-secret'
local initial_name, initial_background = vim.g.colors_name, vim.o.background
local initial_normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
local function lines()
  return vim.uv.fs_stat(log) and #vim.fn.readfile(log) or 0
end
local function names(catalog, appearance)
  local values = {}
  for _, item in ipairs(catalog.choices(appearance)) do values[#values + 1] = item.value end
  return values
end
local function complete(catalog)
  H.ok(vim.wait(15000, function()
    local light, dark = catalog.status('light'), catalog.status('dark')
    return light.initialized and light.pending == 0 and dark.pending == 0
  end, 10), 'Bounded theme workers finish')
end
local catalog = Catalog.new({ path = path })
H.eq({}, catalog.choices('dark'), 'Unverified themes are absent from both appearance lists')
H.eq(0, lines(), 'Constructing a catalog never applies a theme')
local cancel = catalog.subscribe(function() end)
cancel(); vim.wait(30)
H.eq(0, lines(), 'Unsubscribing before deferred discovery starts no worker')
local updates, joined_cancel, joined = 0, nil, false
cancel = catalog.subscribe(function()
  updates = updates + 1
  if not joined and not catalog.status('dark').initialized then
    joined = true
    joined_cancel = catalog.subscribe(function() end)
  end
end)
complete(catalog)
H.ok(joined, 'A second consumer joined during incremental discovery')
H.ok(catalog.status('dark').available > 0, vim.inspect(catalog.status('dark')))
H.eq({ 're35_adaptive', 're35_dark', 'shine' }, names(catalog, 'dark'), 'Dark lists use actual resolved palettes, including overridden built-in names')
H.eq({ 're35_adaptive', 're35_light' }, names(catalog, 'light'), 'Adaptive themes appear in both appearances; fixed Dark themes do not appear in Light')
H.eq(12, lines(), 'Each installed theme is inspected in two isolated appearances')
H.ok(updates > 1, 'Incremental completion notifies the attached picker')
H.eq(1, catalog.status('dark').failed, 'Broken themes have an inspectable failure count')
H.eq(1, catalog.status('dark').unclassified, 'Transparent themes remain unclassified rather than being guessed')
H.eq(initial_name, vim.g.colors_name, 'Classification preserves live colorscheme identity')
H.eq(initial_background, vim.o.background, 'Classification preserves live appearance')
H.eq(initial_normal, vim.api.nvim_get_hl(0, { name = 'Normal', link = false }), 'Classification preserves live highlight palette')
local cache_text = table.concat(vim.fn.readfile(path), '\n')
H.ok(not cache_text:find(vim.g.re35_test_option, 1, true) and not cache_text:find(vim.g.unrelated_secret, 1, true),
  'Only fingerprints, never private theme globals, enter persisted observations')
cancel()
joined_cancel()
H.eq({}, names(catalog, 'dark'), 'Retired choices are hidden until fresh discovery can exclude deleted themes')

local warm = Catalog.new({ path = path })
cancel = warm.subscribe(function() end)
complete(warm)
H.eq(12, lines(), 'Unchanged installed themes reuse the saved classification cache')
cancel()
write('re35_new', adaptive)
local added = Catalog.new({ path = path })
cancel = added.subscribe(function() end); complete(added)
H.eq(14, lines(), 'Adding a theme inspects only that new theme')
cancel()
vim.uv.fs_unlink(runtime .. '/colors/re35_new.lua')
local removed = Catalog.new({ path = path })
cancel = removed.subscribe(function() end); complete(removed)
H.eq(14, lines(), 'Removing a theme never rescans unrelated themes')
H.ok(not vim.tbl_contains(names(removed, 'dark'), 're35_new'), 'Removed themes disappear from picker choices')
H.ok(not table.concat(vim.fn.readfile(path), '\n'):find('re35_new', 1, true), 'Removed observations are pruned from persisted cache')
cancel()

-- Both source edits and imported Lua dependencies invalidate only the affected
-- theme. Cached support is never keyed by name alone.
vim.fn.writefile({ "return vim.o.background == 'light' and '#eeeeee' or '#222222'" }, runtime .. '/lua/re35_dependency.lua')
write('re35_adaptive', { "vim.api.nvim_set_hl(0, 'Normal', { bg = require('re35_dependency') })" })
local changed = Catalog.new({ path = path })
cancel = changed.subscribe(function() end); complete(changed)
H.eq(16, lines(), 'Editing one colorscheme invalidates only that observation')
cancel()
vim.fn.writefile({ "return vim.o.background == 'light' and '#fefefe' or '#333333'" }, runtime .. '/lua/re35_dependency.lua')
local dependency = Catalog.new({ path = path })
cancel = dependency.subscribe(function() end); complete(dependency)
H.eq(18, lines(), 'Editing an imported Lua dependency invalidates its theme observation')
cancel()
vim.g.re35_test_option = 'a-different-private-option'
local configuration = Catalog.new({ path = path })
cancel = configuration.subscribe(function() end); complete(configuration)
H.eq(28, lines(), 'Changed theme-family configuration invalidates its observations without rescanning an unrelated theme')
cancel()

-- A worker which hangs is bounded and its termination cannot change the editor.
write('re35_aaa_slow', { 'vim.wait(5000)', unpack(adaptive) })
local interrupted = Catalog.new({ path = path })
cancel = interrupted.subscribe(function() end)
H.ok(vim.wait(5000, function() return lines() > 28 end, 10), 'The first isolated worker actually starts before cancellation')
cancel()
local cancelled_lines = lines()
vim.wait(250)
H.eq(cancelled_lines, lines(), 'Detaching the final picker cancels its active worker and starts no remaining work')
local bounded = Catalog.new({ path = path, timeout_ms = 100 })
cancel = bounded.subscribe(function() end); complete(bounded)
H.ok(bounded.status('dark').failed >= 2, 'Timed-out themes are reported unavailable with a reason')
cancel()
H.ok(not table.concat(vim.fn.readfile(path), '\n'):find('re35_aaa_slow', 1, true), 'Transient timeouts are not persisted as permanent missing themes')
local original_system, retries = vim.system, 0
vim.system = function(...) retries = retries + 1; return original_system(...) end
cancel = bounded.subscribe(function() end); complete(bounded)
vim.system = original_system
H.eq(2, retries, 'Reopening retries only the previously timed-out theme')
cancel()
vim.uv.fs_unlink(runtime .. '/colors/re35_aaa_slow.lua')
write('re35_overflow', { "io.stdout:write(string.rep('x', 100000))", unpack(adaptive) })
local overflow = Catalog.new({ path = path })
cancel = overflow.subscribe(function() end); complete(overflow)
H.ok(overflow.status('dark').failed >= 2, 'An excessive-output worker is terminated and excluded')
H.ok(not vim.tbl_contains(names(overflow, 'dark'), 're35_overflow'), 'Output-limit failures are never presented as valid themes')
cancel()
vim.uv.fs_unlink(runtime .. '/colors/re35_overflow.lua')
write('re35_palette', { "vim.api.nvim_set_hl(0, 'Normal', { bg = '#ffffff' })" })
local palette = Catalog.new({ path = path })
cancel = palette.subscribe(function() end); complete(palette)
H.ok(not vim.tbl_contains(names(palette, 'dark'), 're35_palette'), 'A light Normal palette cannot claim Dark support by retaining the Dark option')
H.ok(vim.tbl_contains(names(palette, 'light'), 're35_palette'), 'A consistent light Normal palette remains available in Light')
cancel()

-- Presentation classification never narrows execution membership. Direct calls
-- still validate the installed name and the adapter performs its live guard.
local adapter = Themes.new()
local installed = {}
for _, item in ipairs(adapter.items()) do installed[#installed + 1] = item.value end
H.ok(vim.tbl_contains(installed, 're35_light'), 'Installed-name validation remains independent of classification readiness')
local result = adapter.preview(nil, { theme = 're35_light', background = 'dark' })
H.eq('condition', result.kind, 'Expected stale-classification mismatch returns a structured condition')
H.eq('appearance_mismatch', result.code)
H.ok(not result.message:find('stack traceback', 1, true), 'Routine mismatch has a concise summary without a traceback')
H.eq(initial_name or 'default', vim.g.colors_name, 'Mismatch restores the original live theme')
result = adapter.preview(nil, { theme = 're35_palette', background = 'dark' })
H.eq('appearance_mismatch', result.code, 'Live application uses the same palette check as the isolated worker')
H.ok(result.details:find('light Normal background', 1, true), 'Live palette mismatch explains the actual observation')
H.eq(initial_name, vim.g.colors_name, 'Live palette mismatch also restores the previous theme')
print('Theme catalog checks: ' .. H.checks)
