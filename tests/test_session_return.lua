-- Returning to editing preserves safe navigation independently of how the
-- user leaves. Full disposal is explicit and never restarts a saved review.
local H = require('helpers')
local Session = require('command_tree.session')
local create, session = Session.new
Session.new = function(services) session = create(services); return session end
local CE, K = require('re35'), require('command_tree.keys')
vim.o.columns, vim.o.lines = 120, 42
CE.setup({ usage={path=false}, preferences={path=false}, profile={path=false},
  auto=false, operator_help=false, triggers={},
  providers={ plugins=false, runner=false, lsp=false, ex=false }, window={icons=false} })
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(opts)
  CE.close()
  return CE.open(vim.tbl_extend('force', {interactive=false}, opts or {}))
end
local function no_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do H.eq('', vim.api.nvim_win_get_config(win).relative) end
end
local runs, seen = 0, nil
CE.register({id='fixture.return_action', path='xz', name='Return action', run=function(ctx)
  runs, seen = runs + 1, vim.deepcopy(ctx)
end})

local state = open()
keys('x\\')
H.eq(nil, session.active)
H.eq(state, session.suspended, 'Ordinary close keeps the logical session')
no_floats()
CE.open({interactive=false})
H.eq(state, session.active); H.eq({'x'}, state.path)
H.eq(nil, state.message, 'Ordinary return does not invent recovery information')
keys('z')
H.eq(1, runs)
H.eq(state, session.suspended, 'Successful execution returns to editing without losing navigation')
CE.open({interactive=false}); H.eq({'x'}, state.path)
keys('<Esc><Esc>')
H.eq(state, session.suspended, 'Back from the command home uses the same return policy')
H.eq({}, state.path)
CE.open({interactive=false}); keys('<C-c>')
H.eq(nil, session.active); H.eq(nil, session.suspended, 'Ctrl-c explicitly discards navigation')
CE.open({interactive=false}); H.ok(session.active ~= state, 'Explicit reset starts a new logical session')
state = session.active
CE.open({interactive=false})
H.eq(state, session.suspended, 'Toggling the public entry follows the ordinary return policy')
CE.open({interactive=false}); H.eq(state, session.active)

-- The search query, caret and selected identity survive. A new attachment
-- captures the current editor revision instead of reusing old command facts.
state = open({search='return'})
state.query_cursor = 2
local old_context = vim.deepcopy(state.ctx)
keys('\\')
vim.api.nvim_buf_set_lines(old_context.buf, 0, -1, false, {'fresh native text'})
vim.api.nvim_win_set_cursor(old_context.win, {1, 4})
CE.open({interactive=false})
H.eq('return', state.query); H.eq(2, state.query_cursor)
H.ok(state.ctx.changedtick ~= old_context.changedtick)
H.eq({1, 4}, state.ctx.cursor)
CE.close()

-- A Workspace is left through its normal cleanup, never parked with arbitrary
-- provider data or approval authority. Return selects its menu destination.
local entered, left = 0, 0
CE.register_workspace({id='fixture.return_workspace', name='Return workspace',
  enter=function(frame) entered=entered+1; frame.data.private_draft='not portable navigation' end,
  leave=function(frame) left=left+1; frame.data.private_draft=nil end})
for _, destination in ipairs({'key', 'editor'}) do
  state = open({workspace='fixture.return_workspace'})
  local old_frame = state.stack[#state.stack]
  if destination == 'key' then keys('\\') else H.ok(session:enter_workspace('editor')) end
  H.eq(nil, session.active); H.eq(state, session.suspended)
  H.eq(0, #state.stack); H.eq(nil, old_frame.data.private_draft)
  no_floats()
  CE.open({interactive=false})
  H.eq('selector', state.mode)
  H.eq('fixture.return_workspace', session:workspace_choices()[state.selected].id,
    'Both return routes preserve the Workspace menu destination')
  H.ok(session:enter_workspace('fixture.return_workspace'))
  H.ok(state.stack[#state.stack] ~= old_frame, 'Reentry owns a fresh Workspace frame')
  CE.close()
end
H.eq(4, entered); H.eq(4, left, 'Each Workspace owner is cleaned exactly once')

-- A failed auxiliary-window close keeps its cleanup owner. Retrying must
-- clean that window before returning and must not repeat provider leave.
state = open({workspace='fixture.return_workspace'})
local View, close_view, blocked = require('command_tree.view'), require('command_tree.view').close, true
local owned_view = state.stack[#state.stack].view
owned_view.win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
  {relative='editor', row=1, col=1, width=10, height=1, style='minimal'})
owned_view.buf = vim.api.nvim_win_get_buf(owned_view.win)
local window, previous_left = owned_view.win, left
local retired_execute = state.workspace_execute
View.close = function(view)
  if blocked and view == owned_view then return false, 'fixture auxiliary cleanup failure' end
  return close_view(view)
end
local accepted, reason = session:leave()
H.eq(false, accepted); H.ok(reason:find('auxiliary cleanup failure', 1, true))
H.eq(state, session.active); H.eq(nil, session.suspended)
H.eq(previous_left+1, left); H.ok(vim.api.nvim_win_is_valid(window))
H.eq(false, retired_execute('fixture.return_action'), 'A retired Workspace cannot execute after partial cleanup')
H.eq(1, runs)
blocked = false
View.close = close_view
H.ok(session:leave(), 'Return retries known remaining Workspace surfaces')
H.eq(previous_left+1, left, 'Retry does not repeat provider cleanup')
H.eq(false, vim.api.nvim_win_is_valid(window)); no_floats()
CE.close()

-- Ordinary return must not silently throw away staged Settings edits or a
-- live Workspace editor. Users can complete/cancel that input or reset.
state = open({workspace='settings'})
local settings = state.stack[#state.stack]
settings.data.base, settings.data.draft = {ui={density='full'}}, {ui={density='minimal'}}
keys('\\')
H.eq(state, session.active); H.eq(nil, session.suspended)
H.eq('minimal', settings.data.draft.ui.density)
H.ok(state.message:find('Apply or discard', 1, true))
H.eq(settings, state.stack[#state.stack])
settings.data.draft = vim.deepcopy(settings.data.base)
H.ok(session:leave(), 'Unchanged Settings drafts do not block return')
H.eq(state, session.suspended)
state = open({workspace='fixture.return_workspace'})
local editing_frame = state.stack[#state.stack]
editing_frame.data.input_active = true
local left_before_input = left
accepted, reason = session:leave()
H.eq(false, accepted); H.ok(reason:find('Finish the Workspace input', 1, true))
H.eq(state, session.active); H.eq(left_before_input, left)
editing_frame.data.input_active = false
H.ok(session:leave(), 'Completing the Workspace input allows ordinary return')
H.eq(left_before_input+1, left)
CE.close()

-- Leave saves only nonsecret drafts. Old forms and an old selected Apply
-- cannot become authority when the surface is reopened.
CE.register({id='fixture.return_review', name='Return review', review_policy='explicit_apply', arguments={
  {name='text', required=true}, {name='secret', required=true, secret=true},
  {name='apply', kind='boolean', default=false, required=true,
    items={{label='Cancel',value=false},{label='Apply',value=true}}},
}, run=function() error('A returned review must require fresh input') end})
state = open({command='fixture.return_review'})
keys('remember<CR>private<CR><Down>')
local form = state.input
keys('\\')
H.eq(state, session.suspended); H.eq(nil, state.input)
H.eq(nil, form.args.secret); H.eq(nil, form.args.apply)
H.eq('', form.text)
CE.open({interactive=false})
H.eq('inspect', state.mode); H.eq('fixture.return_review', state.inspected_id)
keys('<CR>')
H.ok(state.input ~= form); H.eq('remember', state.input.args.text)
H.eq(nil, state.input.args.secret); H.eq(nil, state.input.args.apply)
CE.close()

-- A handoff command detaches before invoking the external tool and retains
-- navigation for the next entry, rather than erasing the logical Session.
CE.register({id='fixture.return_handoff', path='xy', name='External handoff', handoff=true,
  run=function(ctx)
    H.eq(nil, session.active); H.ok(session.suspended)
    runs, seen = runs+1, vim.deepcopy(ctx)
  end})
state = open(); keys('xy')
H.eq(state, session.suspended); H.eq(2, runs); H.ok(K.valid(seen))
CE.open({interactive=false}); H.eq({'x'}, state.path)
CE.close(); CE.disable(); Session.new=create
no_floats()
print('Session return checks: ' .. H.checks)
