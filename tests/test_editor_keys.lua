-- Native editing shortcuts preserve the semantic invocation boundary and own
-- exactly the host mappings they install, including rollback and restoration.
local H = require('helpers')
local Keys, Bindings = require('command_tree.keys'), require('command_tree.editor_keys')
local CE = require('command_tree')
local calls = {}
local function options(bindings)
  return { profile = { path = false }, usage = { path = false }, preferences = { path = false },
    integrations = { theme = false }, editor_keys = bindings or {}, guidance = { first_run = false },
    providers = { builtin = false, native = false, keymaps = false, plugins = false, lsp = false, runner = false, ex = false },
    commands = { { id = 'fixture.action', name = 'Fixture action',
      arguments = { { name = 'text', type = 'string' } },
      run = function(ctx, args) calls[#calls + 1] = { mode = ctx.mode, args = vim.deepcopy(args), selection = vim.deepcopy(ctx.selection) }; return true end } } }
end
local function mapping(mode, key, buf)
  for _, map in ipairs(buf and vim.api.nvim_buf_get_keymap(buf, mode) or vim.api.nvim_get_keymap(mode)) do
    if vim.deep_equal(Keys.tokens(Keys.raw(map.lhs), true), Keys.tokens(Keys.raw(key), true)) then return map end
  end
end
local function declaration(key, extra)
  return vim.tbl_extend('force', { key = key, command = 'fixture.action', args = { text = 'saved text' } }, extra or {})
end

CE.setup(options())
H.eq({}, CE.editor_keys(), 'Editing shortcuts are opt-in')
local previous = function() return 'original' end
vim.keymap.set('n', '<F6>', previous, { expr = true, remap = true, silent = false, desc = 'Original expression mapping' })
local original = mapping('n', '<F6>')
local registry, token = CE.registry(), CE.environment_token()
local conflict = H.raises(function() CE.setup(options({ declaration('<F6>') })) end)
H.ok(tostring(conflict):find('replace = true', 1, true), 'An occupied key explains explicit replacement')
H.eq(original.callback, mapping('n', '<F6>').callback, 'Failed setup preserves the original mapping')
H.eq(registry, CE.registry(), 'Native mapping conflict preserves the live registry')
H.ok(CE.is_current_environment(token), 'Native mapping conflict preserves the live environment token')
CE.setup(options({ declaration('<F6>', { replace = true }) }))
H.eq('fixture.action', CE.editor_keys()[1].command, 'Status identifies the stable command')
H.eq('active', CE.editor_keys()[1].status, 'Installed binding reports active')
H.eq(nil, require('command_tree.mappings').list('n', vim.api.nvim_get_current_buf())['<F6>'],
  'Native guide does not import RE35 shortcuts as replay commands')
local owned = mapping('n', '<F6>').callback
owned()
H.eq({ mode = 'n', args = { text = 'saved text' } }, calls[1], 'Shortcut executes the same semantic command with captured arguments')
CE.close()
owned()
CE.close()
H.eq(2, #calls, 'Invocation arguments can be reused')
H.raises(function() CE.setup(options({ declaration('<F6>') })) end,
  'A replacement must still explicitly opt in when rebuilding an environment')
H.eq(owned, mapping('n', '<F6>').callback, 'Rejected replacement retains the existing shortcut callback')
H.ok(CE.disable(), 'Disable succeeds')
local restored = mapping('n', '<F6>')
for _, field in ipairs({ 'callback', 'expr', 'noremap', 'silent', 'nowait', 'desc' }) do
  H.eq(original[field], restored[field], 'Disable restores original mapping field ' .. field)
end
owned()
H.eq(2, #calls, 'A retained callback cannot execute after its generation was disabled')
vim.keymap.del('n', '<F6>')

for _, declarations in ipairs({
  { declaration('gx'), declaration('g') },
  { declaration('<Tab>'), declaration('<C-i>') },
  { declaration('\\x') },
  { declaration('<F6>', { mode = { 'n', 'n' } }) },
  { declaration('<F6>', { mode = false }) },
  { declaration('<F6>', { mode = 'c' }) },
  { declaration('<F6>', { args = false }) },
  { declaration('<F6>', { args = { text = function() end } }) },
  { declaration('<F6>', { command = 'keymap.transient' }) },
}) do H.raises(function() CE.setup(options(declarations)) end, 'Invalid or overlapping declaration is refused') end

vim.keymap.set('n', 'gx', '<Nop>')
H.raises(function() CE.setup(options({ declaration('g', { replace = true }) })) end,
  'Explicit replacement cannot steal another native prefix')
vim.keymap.del('n', 'gx')
local buffer = vim.api.nvim_get_current_buf()
vim.keymap.set('n', '<F7>', '<Nop>', { buffer = buffer })
H.raises(function() CE.setup(options({ declaration('<F7>', { replace = true }) })) end,
  'A global binding cannot silently replace a loaded buffer-local key')
vim.keymap.del('n', '<F7>', { buffer = buffer })

CE.setup(options({ declaration('<F6>'), declaration('<F7>', { args = { text = 'second' }, mode = 'i' }),
  declaration('<F8>', { args = { text = 'visual' }, mode = 'x' }) }))
local normal = mapping('n', '<F6>').callback
local notices, notify = {}, vim.notify
vim.notify = function(message) notices[#notices + 1] = message end
CE.open({ interactive = false })
normal()
H.eq(2, #calls, 'Shortcut cannot replace an active command surface')
H.ok(notices[1]:find('Leave the current command surface', 1, true), 'Rejected shortcut has visible feedback')
CE.close()
vim.notify = notify
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abc' })
vim.api.nvim_feedkeys(Keys.raw('i<F7><Esc>'), 'xt', false)
H.eq('i', calls[3] and calls[3].mode, 'Insert-mode mapping captures the actual editor mode')
H.eq('second', calls[3] and calls[3].args.text, 'Insert shortcut invokes its own command arguments')
CE.close()
vim.api.nvim_feedkeys(Keys.raw('gg0v<F8><Esc>'), 'xt', false)
H.eq('x', calls[4] and calls[4].mode, 'Visual-mode mapping captures visual context')
H.ok(calls[4] and calls[4].selection, 'Visual selection remains part of the invocation context')
CE.close()

vim.keymap.set('n', '<F6>', '<Nop>', { buffer = buffer })
H.eq('shadowed', CE.editor_keys()[1].status, 'A later buffer-local key is visible as shadowed')
vim.keymap.del('n', '<F6>', { buffer = buffer })
local foreign = function() end
vim.keymap.set('n', '<F6>', foreign)
H.eq('replaced', CE.editor_keys()[1].status, 'A later global mapping is reported as replaced')
H.ok(CE.disable(), 'Disable succeeds after another plugin replaces a map')
H.eq(foreign, mapping('n', '<F6>').callback, 'Disable preserves the later plugin mapping')
vim.keymap.del('n', '<F6>')

CE.setup(options({ declaration('<F6>') }))
local before = CE.environment_token()
local set, failed = vim.keymap.set, false
vim.keymap.set = function(mode, key, ...)
  set(mode, key, ...)
  if key == '<F9>' and not failed then failed = true; error('Fixture installation failure after setting a map') end
end
local accepted, reason = pcall(CE.setup, options({ declaration('<F9>'), declaration('<F10>') }))
vim.keymap.set = set
H.ok(not accepted and tostring(reason):find('Host activation failed', 1, true), 'Partial host installation failure is reported')
H.ok(CE.is_current_environment(before), 'Failed shortcut installation restores the old environment')
H.eq(nil, mapping('n', '<F9>'), 'Failed installation removes a map installed before throwing')
H.eq(nil, mapping('n', '<F10>'), 'Failed installation does not leave later candidate mappings')
H.ok(Bindings.is_owned(mapping('n', '<F6>')), 'Rollback reinstalls the old semantic shortcut')
mapping('n', '<F6>').callback()
H.eq(5, #calls, 'Restored shortcut is executable')
CE.close(); CE.disable()
H.eq(nil, mapping('n', '<F6>'), 'Final Disable removes the last owned map')

vim.keymap.set('n', '<F6>', previous, { expr = true })
CE.setup(options({ declaration('<F6>', { replace = true }) }))
local pending_callback, remove = mapping('n', '<F6>').callback, vim.keymap.del
vim.keymap.del = function(mode, key, ...)
  if key == '<F6>' then error('Fixture map removal failure') end
  return remove(mode, key, ...)
end
local disabled, disable_error = CE.disable()
vim.keymap.del = remove
H.ok(not disabled and tostring(disable_error):find('map removal failure', 1, true), 'Mapping cleanup failure is reported')
H.eq('cleanup_pending', CE.editor_keys()[1].status, 'Failed cleanup retains a retryable mapping owner')
H.eq(nil, require('command_tree.entry').opts, 'Cleanup failure still releases the separate entry boundary')
pending_callback()
H.eq(5, #calls, 'Retired shortcut cannot execute while cleanup is pending')
H.ok(CE.disable(), 'Mapping cleanup can be retried')
H.eq(previous, mapping('n', '<F6>').callback, 'Retry restores the displaced original mapping')
vim.keymap.del('n', '<F6>')

vim.keymap.set('n', '<F6>', previous, { expr = true })
CE.setup(options({ declaration('<F6>', { replace = true }) }))
local restore = vim.fn.mapset
vim.fn.mapset = function() error('Fixture map restoration failure') end
disabled, disable_error = CE.disable()
vim.fn.mapset = restore
H.ok(not disabled and tostring(disable_error):find('restoration failure', 1, true), 'Restoration failure is reported')
H.eq(nil, mapping('n', '<F6>'), 'A failed restoration does not revive the retired semantic shortcut')
H.ok(CE.disable(), 'Original mapping restoration can be retried')
H.eq(previous, mapping('n', '<F6>').callback, 'Retry retains the exact original callback after restoration failure')
vim.keymap.del('n', '<F6>')

local leader, localleader = vim.g.mapleader, vim.g.maplocalleader
vim.g.mapleader, vim.g.maplocalleader = ',', ';'
vim.keymap.set('n', ',k', previous, { expr = true })
vim.keymap.set('n', ';k', previous, { expr = true })
CE.setup(options({ declaration('<Leader>k', { replace = true }), declaration('<LocalLeader>k', { replace = true }),
  declaration('<Leader>j') }))
vim.g.mapleader, vim.g.maplocalleader = ' ', '!'
H.eq('active', CE.editor_keys()[1].status, 'Changing mapleader does not move an installed shortcut')
H.eq('active', CE.editor_keys()[2].status, 'Changing maplocalleader does not move an installed shortcut')
H.ok(CE.disable(), 'Disable succeeds after both leader settings change')
H.eq(previous, mapping('n', ',k').callback, 'Old leader slot restores the displaced original')
H.eq(previous, mapping('n', ';k').callback, 'Old localleader slot restores the displaced original')
H.eq(nil, mapping('n', ',j'), 'Old leader slot with no displaced map is removed')
H.eq(nil, mapping('n', ' k'), 'Cleanup does not write to the new leader slot')
H.eq(nil, mapping('n', '!k'), 'Cleanup does not write to the new localleader slot')
vim.keymap.del('n', ',k'); vim.keymap.del('n', ';k')
vim.g.mapleader, vim.g.maplocalleader = leader, localleader
local original_leader = vim.g.mapleader
vim.g.mapleader = '`'
vim.keymap.set('n', '`', previous)
local boundary_options = options()
boundary_options.open_key = '<Leader>'
CE.setup(boundary_options)
local boundary = mapping('n', '`').callback
vim.g.mapleader = '!'
require('command_tree.entry').refresh(vim.api.nvim_get_current_buf())
H.eq(boundary, mapping('n', '`').callback, 'Entry refresh keeps its installed leader boundary')
H.eq(nil, mapping('n', '!'), 'Entry refresh does not claim the changed leader')
H.ok(CE.disable())
H.eq(previous, mapping('n', '`').callback, 'Disabling restores the original resolved entry slot')
vim.keymap.del('n', '`')
vim.g.mapleader = original_leader
print('Editor key checks passed: ' .. H.checks)
