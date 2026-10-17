local H = require('helpers')
local Session = require('command_tree.session')
local build, session = Session.new
Session.new = function(services) session = build(services); return session end
local CE, K = require('re35'), require('command_tree.keys')
vim.o.columns, vim.o.lines = 120, 42
local calls, seen, reviewed_calls = 0, nil, 0
CE.setup({ profile = { path = false }, preferences = { path = false }, usage = { path = false },
  auto = false, triggers = {}, guidance = { first_run = false },
  providers = { builtin = false, plugins = false, lsp = false, native = false, keymaps = false, ex = false },
  commands = {
    { id = 'fixture.invoke', name = 'Invoke', path = { 'x', 'a' }, aliases = { 'invoke-alias' },
      arguments = { { name = 'text', required = true } },
      run = function(ctx, args) calls = calls + 1; seen = { ctx = ctx, args = args }; return true end },
    { id = 'fixture.unavailable', name = 'Unavailable', available = function() return false, 'Install fixture tool' end,
      run = function() error('Unavailable command executed') end },
    { id = 'fixture.review', name = 'Review', review_policy = 'explicit_apply',
      arguments = { { name = 'apply', kind = 'boolean', required = true, default = false,
        items = { { label = 'Cancel', value = false }, { label = 'Apply', value = true } } } },
      run = function() reviewed_calls = reviewed_calls + 1; return true end },
  }, groups = { x = 'Fixture' },
})
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'old text', 'fresh text' })
CE.open({ keys = 'x', interactive = false })
local state, identifier = session.active, CE.state().session_id
H.ok(CE.leave())
vim.api.nvim_win_set_cursor(0, { 2, 3 })
local input = { command = 'fixture.invoke', args = { text = '한글 😀' } }
H.ok(CE.invoke(input, { interactive = false }))
H.eq(1, calls); H.eq('한글 😀', seen.args.text)
H.eq({ 2, 3 }, seen.ctx.cursor, 'Shortcut captures the current editor position')
H.eq(identifier, CE.state().session_id, 'Direct invocation reuses retained navigation')
H.ok(session.suspended == state); H.eq({ 'x' }, state.path)
H.eq(false, CE.invoke({ command = 'invoke-alias', args = { text = 'bad' } }, { interactive = false }), 'Aliases are not stable command IDs')
H.eq(false, CE.invoke({ command = 'fixture.invoke', args = { invented = true } }, { interactive = false }))
H.eq(1, calls)
H.ok(CE.invoke({ command = 'fixture.invoke' }, { interactive = false }), 'Missing input opens the same form')
H.eq('input', session.active.mode); H.eq('fixture.invoke', session.active.input.command.id)
H.eq(false, CE.invoke(input, { interactive = false }), 'Another invocation cannot overwrite an active form')
CE.close()
local accepted, reason = CE.invoke({ command = 'fixture.unavailable' }, { interactive = false })
H.eq(false, accepted); H.eq('Install fixture tool', reason)
H.ok(session.active.message:find('Install fixture tool', 1, true), 'Unavailable reason is visible')
CE.close()
H.ok(CE.invoke({ command = 'fixture.review', args = { apply = true } }, { interactive = false }),
  'A supplied Apply opens a fresh field')
H.eq(0, reviewed_calls, 'A shortcut cannot enter the handler before a fresh explicit gesture')
H.eq('input', session.active.mode)
H.eq('apply', session.active.input.command.arguments[session.active.input.index].name)
H.eq(nil, session.active.input.args.apply, 'Previously supplied Apply is not restored as authority')
session:handle('<Down>'); session:handle('<CR>')
H.eq(1, reviewed_calls, 'A fresh explicit field submission executes exactly once')
H.eq(1, calls)
CE.close()
for _, bad in ipairs({ { done = true }, { interactive = 'yes' }, { mode = 'o' }, { context = true } }) do
  H.eq(false, CE.invoke(input, bad), 'Malformed host options do not attach a surface')
  H.eq(false, CE.state().active)
end
local stale = K.context()
vim.api.nvim_win_set_cursor(0, { 1, 2 })
H.ok(CE.invoke(input, { context = stale, interactive = false }))
H.eq({ 1, 2 }, seen.ctx.cursor, 'A host context chooses a source, not a stale cursor/revision')
CE.close()
local armed, replaced_calls = false, 0
CE.register({ id = 'fixture.replace_during_entry', name = 'Changing command', path = 'xy',
  arguments = { { name = 'text', required = true } },
  available = function()
    if armed then
      armed = false
      CE.register({ id = 'fixture.replace_during_entry', replace = true, name = 'New definition',
        run = function() replaced_calls = replaced_calls + 1; return true end })
    end
    return true
  end,
  run = function() replaced_calls = replaced_calls + 1; return true end,
})
CE.open({ keys = 'x', interactive = false }); CE.leave(); armed = true
local invoked, changed = CE.invoke({ command = 'fixture.replace_during_entry', args = { text = 'old schema' } }, { interactive = false })
H.eq(false, invoked); H.ok(changed:find('changed', 1, true))
H.eq(0, replaced_calls, 'A redraw cannot replace the command receiving a previously validated intent')
CE.close(); CE.disable()
