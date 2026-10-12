-- Default tests need only Neovim. Actual native parent/child evidence is an
-- explicit separate runner, never silently skipped as an integration pass.
local H = require('helpers')
local Process = require('command_tree.host.process')
local CE, Profile = require('re35'), require('command_tree.profile')
local folder = H.tempdir('process-scope-contract')
local source, marker = folder .. '/source.txt', folder .. '/ran.txt'
vim.fn.writefile({ 'original' }, source)
vim.api.nvim_cmd({ cmd = 'edit', args = { source } }, {})
local profile = Profile.empty()
profile.tools.probe = { command = 'nvim', args = {} }
local options = { auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false, data = profile }, integrations = { theme = false },
  providers = { builtin = true, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false },
  tool_overrides = { probe = { command = vim.v.progpath, cwd = folder, args = { '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin', '-n',
    '-c', 'lua vim.fn.writefile({"ran"}, "ran.txt"); vim.cmd("qa!")' } } } }
H.eq('direct', Process.scope(false))
H.raises(function() Process.validate('relative/helper') end)
H.raises(function() Process.validate(true) end)
H.raises(function() Process.validate(folder .. '/nul\0helper') end)
Process.validate(false); Process.validate(vim.v.progpath)
H.ok(not Process.available({ command = vim.v.progpath }, folder .. '/missing-helper'), 'configured missing helper refuses rather than downgrades')
H.ok(not Process.available({ command = 're35-nonexistent-tool-46782' }, false))
local function execute()
  local result = { count = 0 }
  result.accepted, result.reason, result.task = CE.execute('tool.probe', {}, { interactive = false, done = function(ok, detail)
    result.count = result.count + 1; result.ok, result.detail = ok, detail
  end })
  return result
end
CE.setup(options)
local direct_revision = CE.registry():get('tool.probe').process_revision
local direct = execute()
H.ok(direct.accepted)
H.ok(vim.wait(5000, function() return direct.count == 1 end, 10))
H.eq(1, direct.count); H.eq(true, direct.ok)
H.eq('direct', direct.detail.process_scope)
H.eq(true, direct.detail.termination_confirmed, 'default evidence means direct process exit only')
H.eq('unknown', direct.detail.descendant_termination)
H.eq(-1, direct.detail.detached_observed)
H.eq({ 'ran' }, vim.fn.readfile(marker))
vim.fn.delete(marker)
options.process_helper = folder .. '/missing-helper'
CE.setup(options)
local unavailable = execute()
H.eq(false, unavailable.accepted)
H.eq(1, unavailable.count, 'unavailable execution reports one rejection callback')
H.eq(false, unavailable.ok)
H.ok(tostring(unavailable.reason):find('helper', 1, true))
H.eq(0, vim.fn.filereadable(marker), 'missing helper never falls back to running the tool')
-- An executable that does not implement the ownership protocol is also a hard
-- failure. Neovim rejects --status; the actual requested tool cannot run.
options.process_helper = vim.v.progpath
CE.setup(options)
H.ok(direct_revision ~= CE.registry():get('tool.probe').process_revision, 'changing host ownership backend invalidates process revision')
local broken = execute()
H.ok(broken.accepted)
H.ok(vim.wait(5000, function() return broken.count == 1 end, 10))
H.eq(1, broken.count); H.eq(false, broken.ok)
H.eq(false, broken.detail.termination_confirmed)
H.eq('unconfirmed', broken.detail.descendant_termination)
H.eq(125, broken.detail.exit_code)
H.ok(broken.detail.message:find('valid termination report', 1, true))
H.eq(0, vim.fn.filereadable(marker), 'broken helper does not silently execute through the default backend')
H.eq({ 'original' }, vim.fn.readfile(source), 'execution never saves the source buffer')
-- Contract-only fake transport exercises typed but contradictory receipts. It
-- does not claim to launch an actual native owner (the opt-in probe does that).
do
  local scope = Process.scope(vim.v.progpath)
  local base = { version = 1, scope = scope, exit_code = 0, signal = 0, cancelled = false, forced = false,
    termination_confirmed = true, detached_observed = scope == 'windows_job' and -1 or 0, error = '' }
  local function receipt(change, transport)
    local value = vim.tbl_extend('force', base, change or {})
    local system = vim.system
    local result, count = nil, 0
    vim.system = function(argv, _, callback)
      vim.fn.writefile({ vim.json.encode(value) }, argv[3])
      callback(transport or { code = 0, signal = 0 })
      return { pid = 1 }
    end
    local invocation = { status = 'pending', on_cancel = function() end, on_force_cancel = function() end }
    local ok, reason = pcall(Process.run, { command = vim.v.progpath }, 'receipt', vim.v.progpath,
      { file = source, root = folder, cwd = folder, argv = { vim.v.progpath } },
      function(accepted, detail) count = count + 1; result = { ok = accepted, detail = detail } end, invocation)
    vim.system = system
    H.ok(ok, tostring(reason)); H.ok(vim.wait(3000, function() return count == 1 end, 10)); H.eq(1, count)
    return result
  end
  local valid = receipt()
  H.eq(true, valid.ok); H.eq(true, valid.detail.termination_confirmed)
  local errors = {
    { signal = 9 }, { exit_code = 4294967296 }, { exit_code = 0.5 }, { signal = 65 }, { signal = -1 },
    { scope = 'unrecognized' }, { detached_observed = -2 }, { detached_observed = 1000001 },
    { detached_observed = 0.5 }, { cancelled = 'false' }, { forced = 1 }, { termination_confirmed = 'true' },
    { version = 2 }, { unrecognized = true }, { error = 'control\nfailed' },
  }
  for _, change in ipairs(errors) do
    local rejected = receipt(change)
    H.eq(false, rejected.ok, vim.inspect(change)); H.eq(false, rejected.detail.termination_confirmed)
    H.eq('unconfirmed', rejected.detail.descendant_termination)
  end
  local reported_error = receipt({ error = 'Owner control failed' })
  H.eq(false, reported_error.ok, 'error text cannot accompany successful command outcome')
  H.eq(true, reported_error.detail.termination_confirmed, 'observed cleanup remains distinct from failed command outcome')
  H.eq('Owner control failed', reported_error.detail.message)
  local transport_signal = receipt(nil, { code = 0, signal = 9 })
  H.eq(false, transport_signal.ok, 'signalled helper transport cannot report success')
  H.eq('Owned process helper transport failed', transport_signal.detail.message)
  local transport_exit = receipt(nil, { code = 7, signal = 0 })
  H.eq(false, transport_exit.ok, 'failed helper transport cannot report success')
  if scope == 'linux_group' then
    local signalled = receipt({ exit_code = 137, signal = 9 })
    H.eq(false, signalled.ok); H.eq(137, signalled.detail.exit_code); H.eq(true, signalled.detail.termination_confirmed)
  else
    local crashed = receipt({ exit_code = -1073741819 })
    H.eq(false, crashed.ok); H.eq(-1073741819, crashed.detail.exit_code); H.eq(true, crashed.detail.termination_confirmed)
  end
end
print('process_scope_contract: ' .. H.checks .. ' checks')
