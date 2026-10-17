-- Expected conditions are concise while browsing and complete when inspected.
local H, K = require('helpers'), require('command_tree.keys')
local Feedback = require('command_tree.session.feedback')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE, Profile = require('re35'), require('command_tree.profile')
local function text(part)
  return part and part.buf and vim.api.nvim_buf_is_valid(part.buf)
    and table.concat(vim.api.nvim_buf_get_lines(part.buf, 0, -1, false), '\n'):gsub('%s+', ' ') or ''
end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function setup(density)
  local profile = Profile.empty()
  profile.presentation = { version = 1, selected = density, presets = {} }
  CE.setup({ profile = { path = false, data = profile }, usage = { path = false }, preferences = { path = false },
    theme = { persist = false }, guidance = { first_run = false }, auto = false, operator_help = false, triggers = {},
    providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    window = { layout = 'fixed', width = 65, max_height = 16, icons = false } })
end
vim.o.columns, vim.o.lines = 180, 60
local ran = 0
local condition = { kind = 'condition', code = 'appearance_mismatch', severity = 'warning',
  message = 'Light-only theme. Choose Light or another theme.',
  details = 'Observed appearance: light\nRequested appearance: dark\nProvider detail: original appearance restored.' }
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  setup(density)
  CE.register({ id = 'fixture.condition', name = 'Condition fixture', provider = 'fixture-provider',
    arguments = { { name = 'theme', kind = 'select', items = { 'One', 'Two' } } },
    input_ui = { status = function() return { description = 'Confirm to use this choice.' } end },
    run = function() ran = ran + 1 end })
  H.ok(CE.open({ command = 'fixture.condition', interactive = false }))
  local state, input = session.active, session.active.input
  local navigation = state.navigation
  local record = session:record_condition('Preview', condition, input.command)
  session:draw()
  H.eq('condition', record.kind); H.eq('warning', record.severity)
  H.eq('appearance_mismatch', record.code)
  H.eq('fixture.condition', record.command_id); H.eq('fixture-provider', record.provider); H.eq('theme', record.field)
  local normal = text(state.view) .. ' ' .. text(state.view.details)
  H.ok(normal:find('Light%-only theme'), density .. ': concise remedy is visible during normal browsing')
  H.ok(not normal:find('Provider detail', 1, true), density .. ': technical context is hidden until inspection')
  H.ok(not normal:find('action · registered', 1, true) and not normal:find('Target: current buffer', 1, true),
    density .. ': a real description does not fabricate command metadata')
  H.ok(record.full_message:find('Provider detail', 1, true), 'Technical explanation remains retained')
  H.eq(record.message, Feedback.display(state).full_message, 'Display projection contains only the summary')
  H.eq(record, Feedback.current(state), 'Display projection cannot replace the retained record')
  keys('<C-h>')
  H.eq('feedback', state.mode); H.eq(record, state.feedback_inspection)
  local inspection = text(state.view) .. ' ' .. text(state.view.details)
  H.ok(inspection:find('Provider detail', 1, true), density .. ': inspection exposes technical details')
  keys('<CR><Esc>')
  H.eq('input', state.mode); H.ok(state.input == input); H.eq(navigation, state.navigation)
  H.eq(0, ran, 'Inspection never authorizes execution')
  session:clear_feedback('Completion')
  H.eq(record, Feedback.current(state), 'Clearing another stage preserves the condition')
  session:clear_feedback('Preview')
  H.eq(nil, Feedback.current(state)); H.eq(nil, state.message)

  local error_record = session:record_feedback('Preview', 'Unexpected provider exception\nTechnical failure detail', input.command)
  H.eq('error', error_record.kind); H.eq('error', error_record.severity)
  H.eq(error_record, Feedback.display(state), 'Actual exceptions retain their complete existing error presentation')
  session:draw()
  H.ok((text(state.view) .. ' ' .. text(state.view.details)):find('Unexpected provider exception', 1, true))
  keys('<C-h>'); H.eq(error_record, state.feedback_inspection)
  keys('<Esc>')
  CE.close()
end

-- The same weak ownership rules apply to conditions and exceptions. Stale
-- input/index ownership also clears its message instead of leaving a warning.
setup('full')
CE.register({ id = 'fixture.ownership', name = 'Ownership fixture', arguments = { { name = 'one' }, { name = 'two' } }, run = function() end })
H.ok(CE.open({ command = 'fixture.ownership', interactive = false }))
local state, input = session.active, session.active.input
session:record_condition('Preview', condition, input.command)
input.index = 2
H.eq(nil, Feedback.current(state)); H.eq(nil, state.message, 'Advancing an input retires its condition message')
input.index = 1
local retained = session:record_condition('Preview', { kind = 'condition', message = 'Keep browsing', severity = 'info',
  details = string.rep('한', 10000) }, input.command)
H.eq('info', retained.severity); H.eq(true, retained.truncated)
H.ok(#retained.full_message < 17000); H.ok(pcall(vim.str_utfindex, retained.full_message), 'Bounded condition preserves Unicode boundaries')
session:record_condition('Preview', { kind = 'condition', message = 'Line limit', details = string.rep('line\n', 1000) }, input.command)
H.ok(#Feedback.current(state).lines <= 257, 'Expected conditions share bounded inspection storage')
session:record_condition('Preview', { kind = 'condition', message = 'Fallback severity', severity = 'error' }, input.command)
H.eq('warning', Feedback.current(state).severity, 'A condition cannot smuggle an exception severity')
session:record_condition('Preview', { kind = 'condition' }, input.command)
H.eq('error', Feedback.current(state).kind, 'Malformed conditions remain inspectable integration errors')

local location = 'C:/project with spaces/' .. string.rep('nested/', 24) .. 'adapter.lua:912: '
local exception = location .. 'Error executing lua: ' .. location .. 'Error executing lua: '
  .. location .. 'deliberate preview host failure\nstack traceback:\n\t[C]: in function error'
local exception_record = session:record_feedback('Preview', exception, input.command)
H.eq('Preview: deliberate preview host failure', exception_record.message,
  'Nested long Lua locations never displace the actionable error reason')
H.eq(exception, exception_record.full_message, 'Summary extraction preserves the original full exception and traceback')
H.eq('error', exception_record.kind); H.eq('error', exception_record.severity)
session:record_feedback('Preview', '\n  \nError executing lua:\nrelative.lua:7: Useful reason on the next line', input.command)
H.eq('Preview: Useful reason on the next line', Feedback.current(state).message,
  'An empty wrapper line does not hide the first meaningful error line')
for _, explanation in ipairs({ 'Build: target: 4: preserve user message', 'Config: user.lua:2: preserve colon semantics' }) do
  session:record_feedback('Preview', explanation, input.command)
  H.eq('Preview: ' .. explanation, Feedback.current(state).message, 'Ordinary colon-delimited prose is not stripped')
end

-- Read-only provider reports open on demand, with the actual selected value
-- rather than only previously submitted args. Neither lookup nor Inspect is Run.
CE.close()
local inspect_calls, captured = 0, nil
local function inspect_command(id, callback, fields)
  CE.register({ id = id, name = 'Inspect fixture', provider = 'fixture-provider',
    arguments = fields or { { name = 'choice', kind = 'select', items = { 'Alpha', 'Beta' } } },
    input_ui = { status = function() return { description = 'One classification needs attention.', inspectable = true } end,
      inspect = callback }, run = function() ran = ran + 1 end })
end
local function open(id)
  CE.close(); H.ok(CE.open({ command = id, interactive = false }))
  return session.active, session.active and session.active.input
end
inspect_command('fixture.on_demand', function(ctx, args)
  inspect_calls, captured = inspect_calls + 1, vim.deepcopy(args)
  ctx.buf, ctx.cursor[1], args.choice, args.poison = -1, 1000, 'mutated copy', true
  return { kind = 'condition', code = 'classification_report', severity = 'info',
    message = 'Classification report', details = 'Detailed reason available only after inspection.' }
end)
state, input = open('fixture.on_demand')
local function hint_count()
  local guide = text(state.view.guide) .. ' ' .. text(state.view.details)
  local _, count = guide:gsub('Ctrl%+h Inspect details', '')
  return count
end
H.eq(1, hint_count(), 'The available report advertises one Inspect details action')
H.eq(0, inspect_calls, 'Drawing the hint never runs the inspection hook')
keys('<Down>')
H.eq(nil, input.args.choice, 'The selected input value has not been submitted')
local original_ctx = vim.deepcopy(input.context or state.ctx)
local old_navigation = state.navigation
keys('<C-h>')
H.eq('Beta', captured.choice, 'Report receives the current unsubmitted selected value')
H.eq(nil, input.args.choice); H.eq(nil, input.args.poison, 'The provider cannot mutate live args through its report input')
H.eq(original_ctx, input.context or state.ctx, 'The provider cannot mutate the live context')
H.eq('feedback', state.mode); H.eq('classification_report', state.feedback_inspection.code)
H.ok((text(state.view) .. ' ' .. text(state.view.details)):find('Detailed reason', 1, true), 'Requested report exposes complete details')
H.eq(0, ran, 'Read-only report inspection has no execution effects')
keys('<Esc>'); H.eq('input', state.mode); H.ok(state.input == input)
H.eq(2, input.selected); H.eq(old_navigation, state.navigation)
H.eq(nil, Feedback.current(state), 'Returning from an on-demand report retires its snapshot')
H.eq(nil, state.message, 'An inspected report adds no persistent status noise')
session:draw(); H.eq(1, hint_count(), 'An inspectable status advertises one hint after returning')
keys('<C-h>'); H.eq(2, inspect_calls, 'Inspecting again requests a fresh provider report')
keys('<Esc>')
session:clear_feedback()
session:record_feedback('Preview', 'An existing exception', input.command)
keys('<C-h>'); H.eq(2, inspect_calls, 'Existing failure inspection takes precedence over a fresh provider report')
keys('<Esc>')

inspect_command('fixture.text_report', function(_, args)
  captured = args
  return { kind = 'condition', message = 'Text details', severity = 'info' }
end, { { name = 'choice' } })
state, input = open('fixture.text_report')
keys('current draft<C-h>')
H.eq('current draft', captured.choice, 'Text forms also report their current unsubmitted field value')
H.eq('feedback', state.mode); H.eq(0, ran)

inspect_command('fixture.report_error', function() error('Read-only report fixture failure', 0) end)
state, input = open('fixture.report_error'); keys('<C-h>')
H.eq('feedback', state.mode); H.eq('error', state.feedback_inspection.kind)
H.ok(state.feedback_inspection.full_message:find('Read%-only report fixture failure'))
inspect_command('fixture.report_invalid', function() return { description = 'Malformed reply' } end)
state = open('fixture.report_invalid'); keys('<C-h>')
H.eq('error', state.feedback_inspection.kind, 'Malformed reports become inspectable integration errors')
inspect_command('fixture.report_absent', function() return nil end)
state = open('fixture.report_absent'); keys('<C-h>')
H.eq('input', state.mode, 'An absent report never opens an empty details mode')

local retired
inspect_command('fixture.report_close', function()
  retired = session.active
  CE.close()
  return { kind = 'condition', message = 'Retired report must not return' }
end)
open('fixture.report_close'); keys('<C-h>')
H.eq(nil, session.active); H.eq(nil, retired.view.win, 'A retired report never reopens its surface')
inspect_command('fixture.report_replace', function()
  CE.close(); CE.open({ command = 'fixture.report_absent', interactive = false })
  return { kind = 'condition', message = 'Retired report must not overwrite replacement' }
end)
open('fixture.report_replace'); keys('<C-h>')
state = session.active
H.eq('fixture.report_absent', state.input.command.id); H.eq('input', state.mode)
H.eq(nil, Feedback.current(state), 'A stale report cannot attach to a replacement form')
H.ok(not (text(state.view) .. ' ' .. text(state.view.details)):find('Retired report', 1, true))

inspect_command('fixture.report_reattach', function()
  require('command_tree.session.input_driver').attach(session, session.active)
  return { kind = 'condition', message = 'Expired attachment report' }
end)
state, input = open('fixture.report_reattach')
local old_attachment = state.input_attachment
keys('<C-h>')
H.ok(old_attachment.detached and state.input_attachment ~= old_attachment)
H.eq('input', state.mode); H.eq(nil, Feedback.current(state), 'Reattaching the same form rejects the old input lease reply')

inspect_command('fixture.report_next_field', function()
  session.active.input.index = 2
  session:input_field()
  return { kind = 'condition', message = 'Old field report' }
end, { { name = 'choice', kind = 'select', items = { 'Alpha' } }, { name = 'second' } })
state, input = open('fixture.report_next_field'); keys('<C-h>')
H.eq(2, input.index); H.eq('input', state.mode)
H.eq(nil, Feedback.current(state), 'A report cannot attach after its field changed')
H.eq(0, ran, 'Every report path remains read-only with respect to command execution')
CE.close(); CE.disable(); Session.new = construct
print('Condition feedback checks: ' .. H.checks)
