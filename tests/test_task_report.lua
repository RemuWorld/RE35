local H, R, K = require('helpers'), require('command_tree.task_report'), require('command_tree.keys')
local Search = require('command_environment.core.search_provider')
local folder = H.tempdir('task-report')
local original = folder .. '/private-user-source.cpp'
vim.fn.writefile({ 'int main() {}' }, original)
vim.cmd('edit ' .. vim.fn.fnameescape(original))
local buf = vim.api.nvim_get_current_buf()
local ctx = K.context()
local poison = { __index = function() error('Metatable lookup must not run') end,
  __tostring = function() error('Result conversion must not run') end,
  __pairs = function() error('Result traversal must not run') end }
local operation = setmetatable({ id = 7, command_id = 'tool.compile', name = 'Personal project name',
  status = 'failed', started = 100, finished = 200, ctx = ctx, buffer = original,
  args = setmetatable({ password = 'never-share-args' }, poison),
  process_target = setmetatable({ file = original, root = folder, cwd = folder, argv = { '--token', 'never-share-argv' } }, poison),
  detail = setmetatable({ exit_code = 2, signal = 0, output = 'token=never-share-output\n' .. original,
    message = 'never-share-reason', credentials = 'never-share-object' }, poison),
  cancel_error = 'never-share-cancel-error', request = setmetatable({}, poison) }, poison)
local search_request = Search.request('ripgrep', 'token=never-share-search-query ' .. original,
  { mode = 'regex', case = 'insensitive', limits = { results = 321, max_file_bytes = 1234,
    read_bytes = 4096, output_bytes = 8192, milliseconds = 250 } })
operation.detail.search_provider = Search.report(search_request, true)
local options = { version = '5.2.0', descriptor = setmetatable({ backend = 'process', provider = 'project' }, poison) }
local preview = H.ok(R.prepare(operation, options), 'safe allowlist accepts opaque tables without invoking callbacks')
local decoded = vim.json.decode(preview.encoded)
H.eq('failed', decoded.task.status)
H.eq(2, decoded.task.exit_code)
H.eq(true, decoded.task.cancel_error)
H.eq('process', decoded.task.backend)
H.eq('unknown', decoded.task.provider, 'current registry descriptor is not presented as historical execution origin')
H.eq(0, decoded.task.elapsed_ms, 'completed duration is a stable captured value')
H.eq('cpp', decoded.target.extension)
H.eq('excluded', decoded.scope.output)
H.eq(vim.json.decode(vim.json.encode(operation.detail.search_provider)), decoded.search_provider,
  'safe summary includes exact portable engine provenance and effective options')
H.eq('ripgrep', decoded.search_provider.provider)
H.eq('regex', decoded.search_provider.mode); H.eq('insensitive', decoded.search_provider.case)
H.eq(search_request.limits, decoded.search_provider.limits, 'reports effective invocation limits rather than provider ceilings')
H.eq('none', decoded.search_provider.fallback)
H.eq(nil, decoded.search_provider.query, 'portable engine provenance excludes even the original sensitive search query')
for _, secret in ipairs({ folder, 'private-user', 'Personal project', 'never-share', '--token', 'argv', 'credentials' }) do
  H.ok(not preview.encoded:find(secret, 1, true), 'summary excludes sensitive or arbitrary field: ' .. secret)
end
local destination = folder .. '/summary.json'
H.ok(not R.export(preview, operation, destination), 'export requires a separately reviewed destination')
H.eq(destination:gsub('\\', '/'), H.ok(R.review_destination(preview, operation, destination)), 'review shows normalized destination')
H.ok(not R.export(preview, operation, folder .. '/other.json'), 'path cannot switch after review')
H.ok(not vim.uv.fs_stat(folder .. '/other.json'), 'unreviewed path stays absent')
H.ok(R.export(preview, operation, destination), 'reviewed report publishes atomically')
H.eq(decoded, vim.json.decode(table.concat(vim.fn.readfile(destination), '\n')), 'published file contains the exact preview')
local search_task = { id = 9, command_id = 'search.project_text', status = 'succeeded', ctx = ctx, buffer = original,
  provider = 'builtin', backend = 'ripgrep', detail = { search_provider = Search.report(search_request, true) } }
local search_preview = H.ok(R.prepare(search_task, options))
local search_data = vim.json.decode(search_preview.encoded)
H.eq('builtin', search_data.task.provider, 'historical command owner remains distinct from search engine identity')
H.eq('ripgrep', search_data.task.backend); H.eq('ripgrep', search_data.search_provider.provider)
search_task.detail.search_provider = Search.report(Search.request('builtin', 'private builtin query'), true)
search_data = vim.json.decode(H.ok(R.prepare(search_task, options)).encoded)
H.eq('builtin', search_data.search_provider.provider); H.eq('ready', search_data.search_provider.status)
H.eq(false, search_data.search_provider.ignore_rules.project_ignore)
search_task.detail.search_provider = Search.report(search_request, false)
search_data = vim.json.decode(H.ok(R.prepare(search_task, options)).encoded)
H.eq(false, search_data.search_provider.available); H.eq('unavailable', search_data.search_provider.status)
H.eq('ripgrep', search_data.search_provider.provider, 'missing optional engine remains the explicitly selected provider')
H.eq('none', search_data.search_provider.fallback, 'unavailable provenance does not claim fallback')
H.ok(search_data.search_provider.message:find('Selected ripgrep provider is unavailable', 1, true))
H.ok(not R.validate(search_preview, search_task), 'changed provider availability invalidates the reviewed export')

local function canonical_search()
  return vim.json.decode(vim.json.encode(Search.report(search_request, true)))
end
search_task.detail.search_provider = canonical_search()
H.ok(vim.json.decode(H.ok(R.prepare(search_task, options)).encoded).search_provider,
  'plain transported portable provenance is accepted after canonical reconstruction')
local malformed = {
  { 'unknown top-level query', function(value) value.query = 'never-share-search-query' end },
  { 'private executable path', function(value) value.command = original end },
  { 'unknown provider', function(value) value.provider = 'private-provider' end },
  { 'unknown contract version', function(value) value.contract_version = 2 end },
  { 'unknown readiness', function(value) value.status = 'unknown' end },
  { 'inconsistent readiness', function(value) value.status = 'unavailable' end },
  { 'nonboolean availability', function(value) value.available = 1 end },
  { 'unsupported mode', function(value) value.mode = 'fuzzy' end },
  { 'unsupported case', function(value) value.case = 'smart' end },
  { 'unknown fallback', function(value) value.fallback = 'builtin' end },
  { 'private status message', function(value) value.message = 'never-share-private-message' end },
  { 'over-ceiling result limit', function(value) value.limits.results = 5001 end },
  { 'nonfinite byte limit', function(value) value.limits.output_bytes = math.huge end },
  { 'fractional time limit', function(value) value.limits.milliseconds = 1.5 end },
  { 'missing normalized limit', function(value) value.limits.read_bytes = nil end },
  { 'private nested limit field', function(value) value.limits.path = original end },
  { 'unsupported coordinates', function(value) value.coordinates.unit = 'utf-16' end },
  { 'unknown coordinate field', function(value) value.coordinates.path = original end },
  { 'changed ignore policy', function(value) value.ignore_rules.symlinks = 'included' end },
  { 'unbounded ignore list', function(value) value.ignore_rules.generated_directories[7] = string.rep('never-share', 10000) end },
  { 'foreign provenance object', function(value) setmetatable(value, poison) end },
  { 'foreign nested limits', function(value) setmetatable(value.limits, poison) end },
  { 'foreign ignore array', function(value) setmetatable(value.ignore_rules.generated_directories, poison) end },
  { 'callback in coordinates', function(value) value.coordinates.end_exclusive = function() error('Must not run') end end },
  { 'cyclic nested data', function(value) value.coordinates.encoding = value end },
}
for _, spec in ipairs(malformed) do
  local value = canonical_search(); spec[2](value)
  search_task.detail.search_provider = value
  local safe_preview = H.ok(R.prepare(search_task, options), 'malformed provenance never breaks the bounded task report: ' .. spec[1])
  H.eq(nil, vim.json.decode(safe_preview.encoded).search_provider, 'malformed provenance is omitted: ' .. spec[1])
  H.ok(not safe_preview.encoded:find('never-share', 1, true), 'omitted foreign provenance cannot disclose its values: ' .. spec[1])
end
local unsupported_builtin = Search.report(Search.request('builtin', 'private'), true)
unsupported_builtin.mode = 'regex'; search_task.detail.search_provider = unsupported_builtin
H.eq(nil, vim.json.decode(H.ok(R.prepare(search_task, options)).encoded).search_provider,
  'builtin cannot falsely claim unsupported query options')
search_task.detail.search_provider = canonical_search()
search_preview = H.ok(R.prepare(search_task, options))
search_task.detail.search_provider.limits.results = 100
H.ok(not R.validate(search_preview, search_task), 'changed effective limits invalidate a reviewed search report')
local uncertain={id=8,command_id='recipe.fixture',status='cancelled',ctx=ctx,cancel_state='unconfirmed',
  process_scope='sequential-windows_job',detail={termination_confirmed=false,descendant_termination='unconfirmed',detached_observed=-1}}
local uncertainty=vim.json.decode(H.ok(R.prepare(uncertain,options)).encoded)
H.eq('sequential-windows_job',uncertainty.task.process_scope)
H.eq('Cancellation completed without termination confirmation',uncertainty.task.summary,'a completed UI task is not proof of process termination')
H.eq(false,uncertainty.task.termination_confirmed);H.eq('unconfirmed',uncertainty.task.descendant_termination)
H.eq(-1,uncertainty.task.detached_observed);H.eq('excluded',uncertainty.scope.paths)
uncertain.process_scope='sequential-linux_group';uncertain.detail.descendant_termination='private-not-a-scope'
uncertain.detail.detached_observed='private-not-a-count'
local bounded_scope=vim.json.decode(H.ok(R.prepare(uncertain,options)).encoded)
H.eq('sequential-linux_group',bounded_scope.task.process_scope)
H.eq(nil,bounded_scope.task.descendant_termination);H.eq(nil,bounded_scope.task.detached_observed)
H.ok(not R.validate(preview, operation), 'saved receipt cannot be reused')
preview = H.ok(R.prepare(operation, options))
H.ok(not R.review_destination(preview, operation, destination), 'existing destination cannot be overwritten')
H.ok(not R.review_destination(preview, operation, folder .. '/missing/report.json'), 'export never creates directories')
H.ok(not R.review_destination(preview, operation, 'bad\npath'), 'control characters rejected')

local sensitive = 'FOO=ok token="private output"\nAuthorization: Bearer secret-header\nC:\\Users\\Private\\secret.cpp\n/home/private/secret.cpp\n'
  .. 'ghp_fakeprivatecredential\n' .. string.rep('é', 10000) .. '\255\0'
operation.detail.output = sensitive
local with_output = H.ok(R.prepare(operation, vim.tbl_extend('force', options, { include_output = true })))
decoded = vim.json.decode(with_output.encoded)
H.eq(true, decoded.output_truncated, 'optional output is bounded before processing')
H.ok(with_output.byte_count < 32768, 'final report has a strict bounded size')
for _, secret in ipairs({ 'private output', 'secret-header', 'C:\\Users', '/home/private', 'ghp_fake' }) do
  H.ok(not decoded.output:find(secret, 1, true), 'known output credential/path scrubbed: ' .. secret)
end
H.ok(decoded.output_notice:find('undiscovered', 1, true), 'opt-in output never claims comprehensive redaction')
operation.detail.output = '\255' .. string.rep('x', 8191) .. 'é'
H.ok(R.prepare(operation, vim.tbl_extend('force', options, { include_output = true })), 'invalid/bisected UTF-8 is omitted safely')
H.ok(R.validate(preview, operation), 'omitted output cannot change the safe summary')
operation.detail.exit_code = 3
H.ok(not R.validate(preview, operation), 'task revision changes invalidate a preview')
operation.detail.exit_code = 2
-- Ubuntu's Lua runtime honors __pairs, unlike some LuaJIT builds. Construct
-- the deliberately opaque replacement with raw iteration before testing it;
-- fixture creation must not invoke the trap intended for the report reader.
local replacement = {}
for key, value in next, operation do replacement[key] = value end
setmetatable(replacement, poison)
H.ok(not R.validate(preview, replacement), 'replacement object cannot impersonate retained task')
preview = H.ok(R.prepare(operation, options))
preview.encoded = preview.encoded .. ' '
H.ok(not R.validate(preview, operation), 'editing a detached preview cannot alter its reviewed receipt')
preview = H.ok(R.prepare(operation, options))
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
H.ok(not R.validate(preview, operation), 'changed source invalidates report export')
ctx = K.context(); operation.ctx = ctx
local frame = { data = { report_epoch = 9 } }
local session = { running = true, mode = 'workspace', owner = {}, stack = { frame } }
preview = H.ok(R.prepare(operation, vim.tbl_extend('force', options, { frame = frame, session = session })))
frame.data.report_preview = preview
H.ok(R.validate(preview, operation), 'active workspace owns its preview')
session.running = false
H.ok(not R.validate(preview, operation), 'closed environment cannot export a previous preview')
session.running = true; frame.data.report_epoch = 10
H.ok(not R.validate(preview, operation), 'changed report generation invalidates receipt')

-- A racing writer wins safely: its content remains intact, with no partial
-- report and no temporary files left behind.
preview = H.ok(R.prepare(operation, options))
destination = folder .. '/race.json'
H.ok(R.review_destination(preview, operation, destination))
local link = vim.uv.fs_link
vim.uv.fs_link = function(from, to)
  vim.fn.writefile({ 'other writer' }, to)
  return link(from, to)
end
local exported = R.export(preview, operation, destination)
vim.uv.fs_link = link
H.ok(not exported, 'destination race fails without overwriting')
H.eq({ 'other writer' }, vim.fn.readfile(destination), 'racing writer content is preserved')
H.eq({}, vim.fn.glob(folder .. '/*.tmp', false, true), 'temporary report cleaned after failure')

-- Observe a real failing process and a real cancellation through Executor;
-- serialization itself must never start, rerun, or cancel either process.
local Executor = require('command_tree.executor')
local commands = {}
local registry = { get = function(_, id) return commands[id] end, available = function() return true end }
local executor = Executor.new(registry, { record = function() return true end })
local launched = 0
local function process_command(id, waits)
  commands[id] = { id = id, name = id, async = true, backend = 'process', provider = 'fixture-original', run = function(_, _, done, task)
    launched = launched + 1
    local cancelled = false
    local process = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
      '-c', waits and 'lua vim.wait(10000)' or 'cquit 7', '-c', 'qa!' }, { text = true }, function(result)
        vim.schedule(function() done(false, { exit_code = result.code, signal = result.signal,
          output = result.stderr, cancelled = cancelled }) end)
      end)
    task:on_cancel(function() cancelled = true; process:kill(15); return 'pending' end)
  end }
end
process_command('fixture.fail', false)
local accepted, _, failed = executor:execute('fixture.fail', {}, K.context(), function() end)
H.ok(accepted)
H.ok(vim.wait(8000, function() return failed.status ~= 'pending' end, 10), 'real failed process completes')
H.eq('failed', failed.status)
H.eq(7, vim.json.decode(H.ok(R.prepare(failed, options)).encoded).task.exit_code, 'real process exit exported')
H.eq('fixture-original', failed.provider, 'Executor captures historical provider at operation creation')
local saved_command = commands['fixture.fail']
commands['fixture.fail'] = { id = 'fixture.fail', provider = 'replacement-provider', backend = 'replacement-backend' }
decoded = vim.json.decode(H.ok(R.prepare(failed, { descriptor = commands['fixture.fail'], version = '5.2.0' })).encoded)
H.eq('fixture-original', decoded.task.provider, 'real retained task reports original provider after registry replacement')
H.eq('process', decoded.task.backend, 'real retained task reports original backend after registry replacement')
commands['fixture.fail'] = saved_command
process_command('fixture.cancel', true)
accepted, _, operation = executor:execute('fixture.cancel', {}, K.context(), function() end)
H.ok(accepted)
H.ok(operation:cancel(), 'explicit cancellation accepted')
H.ok(vim.wait(8000, function() return operation.status ~= 'pending' end, 10), 'real cancelled process completes')
H.eq('cancelled', operation.status)
decoded = vim.json.decode(H.ok(R.prepare(operation, options)).encoded)
H.eq('confirmed', decoded.task.cancel_state, 'confirmed cancellation remains distinct from requested pending')
H.eq(true, decoded.task.cancelled)
H.eq(2, launched, 'previews never rerun or cancel a process')

-- Real Tasks and Session navigation, including configurable actions and filter
-- retention, exercises the complete preview/input/review/save boundary.
local Session, real_session = require('command_tree.session')
local create = Session.new
Session.new = function(services) real_session = create(services); return real_session end
local CE = require('command_tree')
local invoked = 0
local review_output = string.rep('Reviewable Unicode 표 text and escaped "quotes". ', 80) .. 'FINAL_REVIEW_MARKER'
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false }, profile = { path = false },
  providers = { builtin = false, lsp = false, plugins = false, runner = false, ex = false, native = false, keymaps = false },
  commands = { { id = 'fixture.success', path = 'X', name = 'Success', run = function() invoked = invoked + 1; return true end },
    { id = 'fixture.failed', path = 'Y', name = 'Failure', async = true, run = function(_, _, done)
      done(false, { output = review_output, message = 'private failure', exit_code = 7 }) end },
    { id = 'fixture.pending', path = 'Z', name = 'Pending', async = true, run = function() end } } })
vim.o.columns, vim.o.lines = 130, 44
CE.execute('fixture.success', {}, { interactive = false })
CE.execute('fixture.failed', {}, { interactive = false })
CE.execute('fixture.pending', {}, { interactive = false })
CE.close()
CE.open({ interactive = false, workspace = 'tasks' })
if real_session.active.mode ~= 'workspace' then H.ok(real_session:enter_workspace('tasks')) end
local function key(value) for _, token in ipairs(K.tokens(value)) do real_session:handle(token) end end
local state = real_session.active
frame = state.stack[#state.stack]
key('f'); H.eq('failed', frame.data.filter, 'All cycles to failed/cancelled')
H.eq(2, frame.data.selected_id, 'filtered list selects the failed task')
key('<CR>f'); H.eq(2, frame.data.detail_id, 'owned task details never switch when filter is pressed')
key('p'); H.ok(frame.data.report_preview, 'selected task opens a report preview')
H.ok(table.concat(vim.api.nvim_buf_get_lines(frame.view.buf, 0, -1, false), '\n'):find('Arguments, environment', 1, true),
  'real report preview renders its disclosure rather than a fallback/error window')
local before = #CE.operations()
key('o'); H.eq(true, frame.data.report_preview.include_output, 'output requires explicit opt-in with a new preview')
local seen = {}
local function rendered_report()
  local lines = vim.api.nvim_buf_get_lines(frame.view.buf, 0, -1, false)
  if frame.view.details and vim.api.nvim_buf_is_valid(frame.view.details.buf) then
    vim.list_extend(lines, vim.api.nvim_buf_get_lines(frame.view.details.buf, 0, -1, false))
  end
  if frame.view.guide and vim.api.nvim_buf_is_valid(frame.view.guide.buf) then
    for _, line in ipairs(vim.api.nvim_buf_get_lines(frame.view.guide.buf, 0, -1, false)) do
      -- Guide columns align keys visually; the key/label association is the
      -- same whether controls are beside or below the report preview.
      lines[#lines + 1] = line:gsub('%s+', ' ')
    end
  end
  return table.concat(lines, '\n')
end
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  state.density, frame.data.report_row = density, 1
  real_session:draw()
  for _ = 1, 500 do
    seen[#seen + 1] = rendered_report()
    local row = frame.data.report_row
    key('j')
    if frame.data.report_row == row then break end
  end
  H.ok(table.concat(seen, '\n'):find('MARKER', 1, true), 'complete opt-in output can be scrolled and reviewed in ' .. density
    )
  seen = {}
end
state.density = 'full'
key('o'); H.eq(false, frame.data.report_preview.include_output, 'output can be explicitly removed')
key('<CR>'); H.eq('input', state.mode, 'Enter asks a destination through CE input')
state.input.text = folder .. '/ui-report.json'; state.input.cursor = vim.fn.strchars(state.input.text)
key('<CR>'); H.eq('workspace', state.mode, 'destination acceptance returns to report preview')
H.ok(frame.data.report_destination, 'destination is displayed for review')
H.ok(rendered_report():find('Destination reviewed', 1, true),
  'reviewed destination is visible in the actual Tasks window')
H.ok(not vim.uv.fs_stat(folder .. '/ui-report.json'), 'choosing destination does not write')
local report_columns, report_lines = vim.o.columns, vim.o.lines
vim.o.columns, vim.o.lines = 12, 7
real_session:draw()
key('<CR>')
H.ok(not vim.uv.fs_stat(folder .. '/ui-report.json'), 'A clipped destination cannot authorize report publication')
H.ok(frame.data.report_destination and frame.data.report_preview, 'Refused publication preserves its reviewed destination and preview')
vim.o.columns, vim.o.lines = report_columns, report_lines
real_session:draw()
key('<CR>'); H.ok(vim.uv.fs_stat(folder .. '/ui-report.json'), 'second explicit Enter saves exact report')
H.eq(nil, frame.data.report_preview, 'saved report returns to original task details')
H.eq(2, frame.data.detail_id, 'export preserves owned task')
H.eq(before, #CE.operations(), 'export never executes an action')
H.eq(1, invoked)
key('<Esc>f'); H.eq('pending', frame.data.filter, 'failed cycles to pending after returning to list')
H.eq(3, frame.data.selected_id, 'pending task selected')
key('f'); H.eq('all', frame.data.filter, 'pending cycles back to All')
H.eq(3, frame.data.selected_id, 'selected operation survives filter changes when still present')
key('p<Esc>'); H.eq(nil, frame.data.report_preview, 'Back discards preview and stays in Tasks')
H.eq('workspace', state.mode)
key('p')
local retained = CE.operations
CE.operations = function() return {} end
key('<CR>')
H.eq('workspace', state.mode, 'missing retained task cannot open destination input')
H.ok(frame.data.message:find('no longer in retained history', 1, true), 'missing task has a visible reason')
CE.operations = retained
key('<Esc>')
-- The report and filter actions participate in the existing customizable
-- workspace key policy; the old default key is actually disabled.
real_session.workspaces:configure({ tasks = { keys = { p = false, P = 'report', f = false, A = 'filter',
  ['<CR>'] = false, Q = 'details', o = false, I = 'results', ['<Esc>'] = false, B = 'back' } } })
key('p'); H.eq(nil, frame.data.report_preview, 'disabled report key does not fall through to default handler')
key('P'); H.ok(frame.data.report_preview, 'custom report key opens real preview')
H.ok(rendered_report():find('Q Path', 1, true), 'report help shows effective confirmation key')
H.ok(rendered_report():find('I Output', 1, true), 'report help shows effective output key')
H.ok(rendered_report():find('B Tasks', 1, true), 'report help shows effective Back key')
key('o'); H.eq(false, frame.data.report_preview.include_output, 'disabled output key cannot include output')
key('I'); H.eq(true, frame.data.report_preview.include_output, 'remapped output action creates a reviewed opt-in preview')
key('Q'); H.eq('input', state.mode, 'remapped confirmation action opens actual destination input')
state.input.text = folder .. '/remapped-ui-report.json'; state.input.cursor = vim.fn.strchars(state.input.text)
key('<CR>'); H.eq('workspace', state.mode, 'text input uses ordinary Enter to accept a destination')
H.ok(rendered_report():find('Q saves this preview', 1, true), 'reviewed status shows effective save key')
key('j'); H.ok(rendered_report():find('Q Save', 1, true), 'scrolling clears transient status and reveals effective save help')
key('Q'); H.ok(vim.uv.fs_stat(folder .. '/remapped-ui-report.json'), 'remapped confirmation saves the exact reviewed report')
key('PA'); H.ok(frame.data.report_preview, 'other task shortcuts cannot switch an owned report')
key('BA'); H.eq('failed', frame.data.filter, 'custom Back returns to Tasks and custom filter applies')
H.eq(before, #CE.operations(), 'custom discovery actions never execute')
CE.close(); CE.disable(); Session.new = create
