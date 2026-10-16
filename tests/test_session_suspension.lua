-- A logical Session may outlive its input surface. Native editing never owns
-- an old form, runtime prompt, paste callback or execution approval.
local H = require('helpers')
local Session = require('command_tree.session')
local create, session = Session.new
Session.new = function(services) session = create(services); return session end
local CE, K = require('re35'), require('command_tree.keys')
vim.o.columns, vim.o.lines = 120, 42
local options = { usage = { path = false }, preferences = { path = false }, profile = { path = false },
  auto = false, operator_help = false, triggers = {},
  providers = { plugins = false, runner = false, lsp = false, ex = false }, window = { icons = false } }
CE.setup(options)
local original_paste = vim.paste
local source, original_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'before editing', 'second line' })
local function keys(value)
  for _, key in ipairs(K.tokens(value)) do session:handle(key) end
end
local function open(opts)
  CE.close()
  return CE.open(vim.tbl_extend('force', { interactive = false }, opts or {}))
end
local function no_floats(label)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    H.eq('', vim.api.nvim_win_get_config(win).relative, label)
  end
end
local executions, seen = 0, nil
CE.register({ id = 'fixture.roundtrip', path = 'xz', name = 'Round trip', run = function(ctx)
  executions, seen = executions + 1, vim.deepcopy(ctx)
end })

open(); keys('x')
local state, old_context = session.active, vim.deepcopy(session.active.ctx)
local identifier, old_attachment = CE.state().session_id, state.input_attachment
local stale_execute, stale_input, stale_open = state.workspace_execute, state.workspace_input, state.workspace_open
H.ok(identifier, 'A logical Session has a public identity')
H.ok(CE.state().surface_attached, 'A visible Session owns an input surface')
H.ok(session:enter_workspace('editor'), 'Editor is a reversible native destination')
H.eq(nil, session.active)
H.ok(session.suspended == state, 'Editor retains the logical Session')
H.eq({ active = false, suspended = true, session_id = identifier, surface_attached = false }, CE.state(),
  'Suspended public state exposes identity without a live target or form')
H.eq(false, state.running)
H.eq(nil, state.input_attachment)
H.eq(original_paste, vim.paste, 'Native editor paste is restored during suspension')
H.eq(original_win, vim.api.nvim_get_current_win())
no_floats('Suspension releases all command windows')
vim.api.nvim_buf_set_lines(source, 0, 1, false, { 'edited in native editor' })
vim.api.nvim_win_set_cursor(original_win, { 2, 3 })
CE.open({ interactive = false })
H.ok(session.active == state, 'The ordinary entry resumes the same logical Session')
H.eq(identifier, CE.state().session_id)
H.eq({ 'x' }, state.path, 'Tree navigation survives native editing')
H.eq({ 2, 3 }, state.ctx.cursor, 'Resume captures the current native cursor')
H.ok(state.ctx.changedtick ~= old_context.changedtick, 'Resume captures the current text revision')
H.ok(state.input_attachment ~= old_attachment, 'Resume owns a fresh input attachment')
local stale_answers = 0
H.eq(false, stale_execute('fixture.roundtrip'), 'A retired surface cannot launch a command')
stale_input({ prompt = 'Retired prompt' }, function(value)
  stale_answers = stale_answers + 1; H.eq(nil, value)
end)
H.eq(1, stale_answers, 'A retired input requester is rejected without a dangling callback')
H.eq(nil, state.input)
H.eq(false, stale_open('editor'), 'Retired Workspace navigation cannot detach the new surface')
H.ok(session.active == state); H.eq(0, executions)
keys('z')
H.eq(1, executions, 'Reopening does not execute; a fresh explicit selection executes once')
H.eq(vim.api.nvim_buf_get_changedtick(source), seen.changedtick)
H.eq({ 2, 3 }, seen.cursor)

-- A suspended review is navigation plus non-secret draft data, never a live
-- form or a previously chosen Apply. Selecting it again creates a new form.
CE.register({ id = 'fixture.form', name = 'Owned form', review_policy = 'explicit_apply', arguments = {
  { name = 'value', required = true }, { name = 'password', secret = true, required = true },
  { name = 'confirm', kind = 'boolean', default = false, required = true,
    items = { { label = 'Cancel', value = false }, { label = 'Apply', value = true } } },
}, run = function(ctx, args, _, operation)
  H.ok(Session.consume_submission(session.registry:get('fixture.form'), ctx, args, operation),
    'Only the newly submitted form can obtain one-use Apply authority')
  executions = executions + 1
end })
open({ command = 'fixture.form' }); keys('kept<CR>private<CR><Down>')
state = session.active
local old_form, before = state.input, executions
H.eq(true, require('command_tree.session.input').value(old_form))
H.ok(session:suspend())
H.eq(nil, state.input, 'The original form is discarded at suspension')
H.eq(nil, old_form.args.password, 'A retired form reference cannot retain submitted secrets')
H.eq('', old_form.text)
H.eq('inspect', state.mode, 'The command remains discoverable without its review authority')
local draft = H.ok(session.drafts:get(session.registry:get('fixture.form'), state.ctx))
H.eq('kept', draft.args.value)
H.eq(nil, draft.args.password); H.eq(nil, draft.drafts.password)
H.eq(nil, draft.args.confirm); H.eq(nil, draft.drafts.confirm)
session:resume({ interactive = false })
H.eq(before, executions, 'Resume cannot submit the old review')
keys('<CR>')
H.ok(state.input ~= old_form, 'A new explicit selection constructs a fresh form')
H.eq('kept', state.input.args.value)
H.eq(nil, state.input.args.password, 'The secret must be entered again')
H.eq(nil, state.input.args.confirm, 'Previously selected Apply is not reused')
-- Depending on the draft index, the new form can start at a missing secret or
-- at its safe first field. Advance explicitly using the actual visible field.
while session.active and state.mode == 'input' and state.input.index < 3 do
  local field = state.input.command.arguments[state.input.index]
  keys('<C-u>' .. (field.secret and 'fresh-secret' or 'kept') .. '<CR>')
end
H.eq(3, state.input.index)
H.eq(false, require('command_tree.session.input').value(state.input), 'Fresh Apply defaults to Cancel')
keys('<Down><CR>')
H.eq(before + 1, executions, 'Only fresh confirmation executes the reviewed command')

-- Choice filtering and input history can contain typed secrets even when
-- args/drafts never received a submitted value. Retire those caches as well.
for _, kind in ipairs({ 'select', 'multiselect' }) do
  local id = 'fixture.secret_' .. kind
  CE.register({ id = id, name = 'Private choices', arguments = {
    { name = 'private', kind = kind, secret = true, items = { 'Alpha', 'Beta' } },
  }, run = function() error('A retired secret form must not execute') end })
  open({ command = id }); keys('/private-filter')
  local retired = session.active.input
  H.eq('private-filter', retired.filter, 'The test exercises actual secret choice filtering')
  retired.history_draft, retired.completion = 'private-history-draft', { 'private-completion' }
  if kind == 'multiselect' then retired.checked = { 'private-checked-value' } end
  H.ok(session:suspend())
  H.ok(retired.filter == nil or retired.filter == '', 'Retired secret choice filters are erased')
  H.eq(nil, retired.history_draft, 'Retired history drafts cannot retain typed secrets')
  H.eq(nil, retired.completion); H.eq(nil, retired.checked)
  H.eq(nil, retired.args.private); H.eq(nil, retired.drafts.private)
  CE.close()
end

-- Native :edit/:enew can replace the buffer in the same window while a
-- logical Session is suspended. Its navigation may follow, its draft may not.
CE.register({ id = 'fixture.buffer_owned_form', name = 'Buffer-owned form',
  arguments = { { name = 'value', required = true } }, run = function() executions = executions + 1 end })
open({ command = 'fixture.buffer_owned_form' }); keys('buffer-owned-draft')
state = session.active
local original_buffer, old_runs = state.ctx.buf, executions
H.ok(session:suspend())
local alternate_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(original_win, alternate_buffer)
CE.open({ interactive = false })
H.ok(session.active == state, 'Replacing the native buffer does not strand suspended navigation')
H.eq(alternate_buffer, state.ctx.buf, 'Resume acquires the new current buffer in the same window')
H.eq(K.document_uri(alternate_buffer), state.ctx.document_uri)
H.eq(old_runs, executions, 'Changing buffers and resuming never executes a command')
keys('<CR>')
H.eq('input', state.mode)
H.eq('', state.input.text, 'A draft belonging to the old buffer cannot leak to a new document')
H.eq(nil, state.input.args.value)
local retained_draft = H.ok(session.drafts:get(session.registry:get('fixture.buffer_owned_form'), { buf = original_buffer }))
H.eq('buffer-owned-draft', retained_draft.drafts.value, 'The original buffer keeps its own nonsecret draft')
CE.close()
vim.api.nvim_win_set_buf(original_win, original_buffer)
vim.api.nvim_buf_delete(alternate_buffer, { force = true })

-- UI cancellation settles an outstanding host prompt once. It does not leave
-- a callback that can later operate on the resumed source context.
local answers, completions, prompt_cleanup = {}, 0, nil
CE.register({ id = 'fixture.runtime', async = true, run = function(_, _, done, operation)
  operation:input({ prompt = 'Runtime input' }, function(value)
    answers[#answers + 1] = { value = value }
    done(value ~= nil, value == nil and 'Cancelled' or nil)
  end)
end })
open({ command = 'fixture.runtime', done = function() completions = completions + 1 end })
state = session.active
H.ok(state.input and state.input.callback, 'Runtime input is attached to its originating task')
prompt_cleanup = state.input.cleanup
H.ok(session:suspend())
H.eq(1, #answers); H.eq(nil, answers[1].value)
H.eq(1, completions, 'The cancelled runtime request completes its operation once')
H.eq(nil, state.input)
if type(prompt_cleanup) == 'function' then prompt_cleanup(); prompt_cleanup() end
session:resume({ interactive = false }); CE.close(); CE.close()
H.eq(1, #answers, 'Late runtime cleanup cannot call the answer twice')
H.eq(1, completions)

open()
local reentered, prompt_answers = nil, 0
session:request_input({ prompt = 'Reentrant prompt cleanup' }, function(value)
  prompt_answers = prompt_answers + 1; H.eq(nil, value)
  reentered = { session:open({ interactive = false }) }
end)
state = session.active
H.ok(session:suspend())
H.eq(1, prompt_answers)
H.eq(nil, reentered[1], 'Prompt cleanup cannot reenter an unfinished lifecycle transition')
H.ok(type(reentered[2]) == 'string')
H.ok(session.suspended == state); H.eq(nil, session.active)
CE.close()

local finish, cancellations, done_count = nil, 0, 0
CE.register({ id = 'fixture.background', async = true, run = function(_, _, done, operation)
  finish = done
  operation:on_cancel(function() cancellations = cancellations + 1; return 'pending' end)
end })
open({ command = 'fixture.background', done = function() done_count = done_count + 1 end })
state = session.active
local task, executor = CE.operations()[1], session.executor
H.eq('pending', task.status)
H.ok(session:suspend())
H.eq(0, cancellations, 'Suspending the UI never cancels independent work')
finish(true)
H.eq('succeeded', task.status); H.eq(1, done_count)
H.ok(session.suspended == state, 'Background completion cannot dispose the retained Session')
session:resume({ interactive = false })
H.ok(session.active == state); H.eq(false, state.busy)
H.eq(executor, session.executor, 'Resumption reuses the original task owner')
CE.close(); H.eq(0, cancellations)

-- Preview restoration must finish before the surface or its ownership moves.
open()
state, old_attachment = session.active, session.active.input_attachment
state.preview_cleanup = function() error('fixture preview restore failure', 0) end
local accepted, reason = session:suspend()
H.eq(false, accepted); H.ok(reason:find('preview', 1, true))
H.ok(session.active == state); H.eq(nil, session.suspended)
H.ok(state.input_attachment == old_attachment, 'Failed restoration keeps its original input owner')
H.ok(state.preview_restore_failed, 'Failed restoration remains visible and cannot be forgotten')
H.eq(false, session:suspend(), 'Repeated suspension cannot bypass a failed restoration')
CE.close(); no_floats('Final close releases failed-preview windows')

-- Arbitrary Workspace data cannot silently cross an editor handoff. Refusing
-- preserves the live frame, draft and resources; final close leaves once.
local leave_count = 0
CE.register_workspace({ id = 'fixture.owned', name = 'Owned Workspace', enter = function(frame)
  frame.data.unsaved = { text = 'Workspace-owned draft' }
end, leave = function() leave_count = leave_count + 1 end })
open({ workspace = 'fixture.owned' })
state = session.active
local frame = state.stack[#state.stack]
accepted, reason = session:suspend()
H.eq(false, accepted); H.ok(type(reason) == 'string' and reason ~= '')
H.ok(session.active == state); H.ok(state.stack[#state.stack] == frame)
H.eq('Workspace-owned draft', frame.data.unsaved.text)
H.eq(0, leave_count, 'Rejected suspension never runs Workspace leave')
CE.close(); CE.close(); H.eq(1, leave_count, 'Final disposal invokes leave exactly once')

-- Failed disposal keeps an owner for the leftover surface, while every input
-- and execution capability is already retired. A retry must only clean up.
open({ workspace = 'fixture.owned' })
H.ok(session:run('fixture.form'))
keys('cleanup-value<CR>private-cleanup')
state = session.active
local disposal_input, disposal_window = state.input, state.view.win
local owner, old_registry, left_before = session, CE.registry(), leave_count
local View, blocked = require('command_tree.view'), true
local close_view = View.close
H.ok(disposal_window and vim.api.nvim_win_is_valid(disposal_window))
View.close = function(view)
  if blocked and view == state.view then return false, 'fixture window disposal failure' end
  return close_view(view)
end
accepted, reason = CE.close()
H.eq(false, accepted); H.ok(reason:find('disposal failure', 1, true))
H.eq(nil, owner.active); H.eq(nil, owner.suspended)
H.ok(owner.cleanup_pending == state, 'Failed disposal retains the owner of known remaining views')
H.eq(true, CE.state().cleanup_pending)
H.ok(CE.state().cleanup_error:find('disposal failure', 1, true))
H.eq(false, CE.state().surface_attached)
H.eq(nil, state.input); H.eq(nil, state.input_attachment)
H.eq('', disposal_input.text, 'A failed close still erases the in-flight secret')
H.eq(nil, disposal_input.args.password)
H.eq(original_paste, vim.paste, 'Failed cleanup does not keep the editor input lease')
H.ok(vim.api.nvim_win_is_valid(disposal_window), 'The fixture leaves an actual resource for the retry')
H.eq(left_before + 1, leave_count, 'Workspace leave runs once even if a separate surface cannot close')
local opened, open_reason = owner:open({ interactive = false })
H.eq(nil, opened); H.ok(open_reason:find('cleanup', 1, true))
H.eq(nil, owner.active, 'Incomplete disposal cannot be replaced by a fresh form')
local replaced, replace_reason = pcall(CE.setup, options)
session = owner -- A failed candidate may have been constructed by the capture hook.
H.eq(false, replaced); H.ok(tostring(replace_reason):lower():find('cleanup', 1, true))
H.eq(old_registry, CE.registry(), 'Cleanup failure refuses environment replacement before ownership changes')
H.ok(owner.cleanup_pending == state)
blocked = false
View.close = close_view
H.ok(CE.close(), 'A later close retries the remaining views')
H.eq(nil, owner.cleanup_pending)
H.eq(nil, CE.state().cleanup_pending)
H.eq(false, vim.api.nvim_win_is_valid(disposal_window))
H.eq(left_before + 1, leave_count, 'Disposal retry does not repeat an already completed leave hook')
no_floats('Successful disposal retry releases all known Session views')

-- A stale getchar callback can suspend and resume the *same* state before it
-- returns. Its returned key and loop cleanup still belong to the old lease.
local getchar, called = vim.fn.getcharstr, 0
vim.fn.getcharstr = function()
  called = called + 1
  H.ok(session:suspend())
  H.ok(session:resume({ interactive = false }))
  return 'x'
end
local driven = CE.open()
vim.fn.getcharstr = getchar
H.eq(1, called, 'The retired input loop returns without polling the new surface')
H.ok(session.active == driven, 'Old-loop finalization cannot close a resumed logical Session')
H.eq({}, driven.path, 'A key returned by the retired attachment is never delivered')
CE.close()

-- Paste streams and captured callbacks are surface-owned, including a
-- third-party handler installed while RE35 is visible.
open({ search = 'before' })
state = session.active
local stale_paste = vim.paste
H.eq(true, stale_paste({ 'unfinished' }, 1))
H.ok(session:suspend()); H.eq(nil, state.paste_text)
session:resume({ interactive = false })
local resumed_paste = vim.paste
H.eq(false, stale_paste({ ' old stream' }, 3))
H.eq('before', state.query, 'Retired paste cannot append to resumed input')
H.eq(true, resumed_paste({ ' fresh' }, -1))
H.eq('before fresh', state.query, 'The current surface still accepts paste')
local foreign_calls = 0
local foreign = function() foreign_calls = foreign_calls + 1; return true end
vim.paste = foreign
H.ok(session:suspend())
H.eq(foreign, vim.paste, 'Detach does not overwrite a handler owned by another plugin')
session:resume({ interactive = false })
H.eq(false, resumed_paste({ 'stale' }, -1))
CE.close()
H.eq(foreign, vim.paste, 'Final close restores only the handler this attachment replaced')
H.eq(0, foreign_calls, 'Stale callbacks never forward text to a foreign paste handler')
vim.paste = original_paste

-- A plugin may install a forwarding wrapper after RE35. Keeping that wrapper
-- must preserve complete native paste after detach without replaying old
-- streaming fragments or sending an old callback into a newer attachment.
for _, action in ipairs({ 'suspend', 'close' }) do
  open({ search = 'wrapped' })
  state = session.active
  local previous = vim.paste
  local wrapper = function(...) return previous(...) end
  vim.paste = wrapper
  H.eq(true, wrapper({ 'unfinished stream' }, 1))
  H.ok(session[action](session))
  H.eq(wrapper, vim.paste, 'The late plugin wrapper remains installed after ' .. action)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  H.eq(false, wrapper({ 'retired middle' }, 2))
  H.eq(false, wrapper({ 'retired end' }, 3))
  H.eq(tick, vim.api.nvim_buf_get_changedtick(source), 'Expired stream fragments cannot enter the native document')
  H.eq(true, wrapper({ 'NATIVE-PASTE' }, -1), 'A complete paste still reaches the native editor after ' .. action)
  H.ok(table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n'):find('NATIVE%-PASTE'),
    'Native paste changes the actual source document')
  CE.open({ interactive = false })
  local attached, query = session.active, session.active.query
  tick = vim.api.nvim_buf_get_changedtick(source)
  H.eq(false, previous({ 'retired callback' }, -1), 'A new surface rejects complete paste from its retired predecessor')
  H.eq(false, wrapper({ 'retired forwarding callback' }, -1))
  H.eq(tick, vim.api.nvim_buf_get_changedtick(source))
  H.eq(query, attached.query, 'Retired paste cannot edit the new command input')
  H.ok(session.active == attached)
  CE.close()
  vim.paste = original_paste
end

-- Native destruction terminates the owner; it cannot strand a hidden Session
-- that later resumes against a different buffer bearing a reused window ID.
CE.close()
local temporary = vim.api.nvim_create_buf(true, false)
local secondary = vim.api.nvim_open_win(temporary, true, { split = 'right', win = original_win })
CE.open({ interactive = false })
H.eq(secondary, session.active.ctx.win)
vim.api.nvim_win_close(secondary, true)
H.eq(nil, session.active, 'Closing an attached source window disposes its Session')
H.eq(nil, session.suspended)
secondary = vim.api.nvim_open_win(temporary, true, { split = 'right', win = original_win })
CE.open({ interactive = false }); H.ok(session:suspend())
vim.api.nvim_set_current_win(original_win)
H.ok(session.suspended, 'Moving through native editor windows does not execute or dispose suspension')
vim.api.nvim_buf_delete(temporary, { force = true })
H.eq(nil, session.suspended, 'Wiping a suspended source buffer disposes its logical owner')
H.eq(nil, session.active)
if vim.api.nvim_win_is_valid(secondary) then vim.api.nvim_win_close(secondary, true) end
vim.api.nvim_set_current_win(original_win)

-- Provider refresh is allowed while the surface is detached. Resume must
-- reconcile deleted paths and Inspect targets before attempting to draw.
local function visible_resume(expected_path, expected_mode)
  H.ok(session:resume({ interactive = false }))
  local current = session.active
  H.eq(expected_mode, current.mode); H.eq(expected_path, current.path)
  H.ok(current.view.win and vim.api.nvim_win_is_valid(current.view.win),
    'Reconciled navigation has a real visible command window')
  H.ok(type(current.message) == 'string' and (current.message:find('changed', 1, true)
    or current.message:find('removed', 1, true) or current.message:find('no longer', 1, true)
    or current.message:find('available', 1, true)), 'Navigation fallback explains the unavailable destination')
end
session.registry:group('Y', { name = 'Retained parent' })
CE.register({ id = 'fixture.vanishing_leaf', provider = 'fixture-volatile', path = 'Yab',
  run = function() error('Removed commands must not execute') end })
open(); keys('Ya'); H.eq({ 'Y', 'a' }, session.active.path)
H.ok(session:suspend())
H.ok(session.registry:unregister('fixture.vanishing_leaf'))
-- Removing a provider preserves user-owned placements. Explicitly unbind the
-- disappearing layout here to exercise a genuinely absent branch.
H.ok(session.registry:unbind('Yab'))
H.eq(nil, session.registry:node({ 'Y', 'a' }))
visible_resume({ 'Y' }, 'tree')
CE.register({ id = 'fixture.vanishing_form', provider = 'fixture-volatile', path = 'Yab',
  arguments = { { name = 'value' } }, run = function() error('Removed forms must not execute') end })
open({ command = 'fixture.vanishing_form' })
H.ok(session:suspend()); H.eq('inspect', session.suspended.mode)
H.eq(1, session.registry:remove_provider('fixture-volatile'))
visible_resume({}, 'tree')
H.eq(nil, session.active.inspected_id, 'A removed Inspect target cannot survive in active navigation')
CE.close()

-- Explicit destinations supersede suspended navigation. Environment changes
-- dispose its logical owner while retaining independent Executor operations.
open(); keys('x'); state = session.active; H.ok(session:suspend())
CE.open({ search = 'fixture.roundtrip', interactive = false })
H.ok(session.active ~= state); H.eq('search', session.active.mode)
H.eq(nil, session.suspended)
CE.close(); open(); local old_session = session
H.ok(old_session:suspend())
CE.setup(options)
H.eq(nil, old_session.suspended, 'Environment replacement disposes a suspended Session')
local resumed, why = old_session:resume({ interactive = false })
H.eq(nil, resumed); H.ok(type(why) == 'string')
H.eq(executor, session.executor, 'Environment replacement retains task ownership')
H.eq(original_paste, vim.paste)
CE.close(); CE.disable(); Session.new = create
no_floats('All Session and Workspace surfaces are released')
print('Session suspension checks: ' .. H.checks)
