-- One real editor flow: unsaved literal search -> retained results -> exact
-- location -> typed replacement preview/Apply -> undo -> stale refusal/retry.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Document, Results = require('re35'), require('command_tree.document'), require('command_tree.results')
H.eq(require('command_tree'), CE, 'canonical RE35 API and legacy API share the identical live module')
local folder = H.tempdir('document-workflow')
local source_path = folder .. '/source 한글 space.txt'
local saved = { 'saved needle', 'disk contents remain intact' }
vim.fn.writefile(saved, source_path)
vim.api.nvim_cmd({ cmd = 'edit', args = { source_path } }, {})
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local lines = { '한글🙂 needle needle', 'Needle needle', 'literal .* / & \\1 needle' }
vim.api.nvim_buf_set_lines(source, 0, -1, true, lines)
vim.o.columns, vim.o.lines = 130, 44
vim.fn.setqflist({}, ' ', { title = 'untouched quickfix', items = { { filename = source_path, lnum = 2, col = 1, text = 'native quickfix' } } })
vim.fn.setloclist(0, {}, ' ', { title = 'untouched locations', items = { { filename = source_path, lnum = 1, col = 1, text = 'native location' } } })
local qf = vim.fn.getqflist({ items = 1, title = 1, id = 0, changedtick = 0 })
local loc = vim.fn.getloclist(source_win, { items = 1, title = 1, id = 0, changedtick = 0 })
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false }, window = { icons = false }, integrations = { theme = false },
  providers = { builtin = true, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false } })
local function keys(value) for _, token in ipairs(K.tokens(value)) do session:handle(token) end end
local function frame() return session.active.stack[#session.active.stack] end
local function text() return vim.api.nvim_buf_get_lines(source, 0, -1, true) end
local function untouched(label)
  H.eq(saved, vim.fn.readfile(source_path), label .. ': no file write')
  H.eq(qf, vim.fn.getqflist({ items = 1, title = 1, id = 0, changedtick = 0 }), label .. ': quickfix unchanged')
  H.eq(loc, vim.fn.getloclist(source_win, { items = 1, title = 1, id = 0, changedtick = 0 }), label .. ': location list unchanged')
end
local function results_ready()
  H.ok(vim.wait(1000, function() return session.active and session.active.mode == 'workspace' and frame().id == 'results' end, 10),
    'search completion opens the actual retained Results workspace')
end

H.eq('search.document', CE.registry():node('ef').command_id)
H.eq('edit.replace_literal', CE.registry():node('er').command_id)
H.eq('edit.substitute', CE.registry():node('es').command_id, 'regex substitution remains its original command')
H.eq('file.open', CE.registry():node('fo').command_id, 'existing typed file open remains its original command')
H.ok(CE.execute('docfind', nil, { interactive = false }), 'alias opens a real typed search form')
H.eq('input', session.active.mode)
keys('needle<CR>'); results_ready()
local search = CE.operations()[1]
H.eq('succeeded', search.status)
H.eq('needle', search.args.query)
H.eq(4, #search.detail.locations, 'literal search includes all unsaved occurrences and is case-sensitive')
H.eq(4, #frame().data.items)
H.eq(12, frame().data.items[1].col, 'Korean and emoji prefix use UTF-8 byte units')
H.eq(19, frame().data.items[2].col, 'second occurrence retains its exact byte column')
H.eq(source, frame().data.items[1].bufnr)
H.eq(K.document_uri(source), frame().data.items[1].document_target.uri)
H.eq(tostring(vim.api.nvim_buf_get_changedtick(source)), frame().data.items[1].document_target.revision)
H.eq(lines, text(), 'search never edits the source')
H.eq(true, vim.bo[source].modified, 'search uses unsaved contents')
untouched('search')
keys('<Down><CR>')
H.eq(nil, session.active, 'result selection closes only its UI and focuses the original document')
H.eq(source, vim.api.nvim_get_current_buf())
H.eq(source_win, vim.api.nvim_get_current_win())
H.eq({ 1, 18 }, vim.api.nvim_win_get_cursor(source_win), 'result Enter uses the selected original UTF-8 location')

-- Retained rows reject same-buffer edits and rename even when changedtick does
-- not change, rather than silently opening a file of the same name.
H.ok(CE.open_task_results(search.id, { interactive = false }))
local tick = vim.api.nvim_buf_get_changedtick(source)
vim.api.nvim_buf_set_name(source, folder .. '/renamed 한글.txt')
H.eq(tick, vim.api.nvim_buf_get_changedtick(source), 'rename fixture changes identity without changing text revision')
keys('<CR>')
H.eq('workspace', session.active.mode, 'renamed search target leaves Results visible')
H.ok((frame().data.message or session.active.message or ''):find('renamed', 1, true), 'rename refusal is visible')
H.eq(lines, text())
CE.close(); vim.api.nvim_buf_set_name(source, source_path)
H.ok(CE.open_task_results(search.id, { interactive = false }))
vim.api.nvim_buf_set_lines(source, 1, 2, true, { 'Needle needle changed after search' })
local edited = text()
keys('<CR>')
H.eq('workspace', session.active.mode, 'stale search revision leaves Results visible')
H.ok((frame().data.message or session.active.message or ''):find('changed', 1, true), 'revision refusal is visible')
H.eq(edited, text(), 'stale jump never edits current text')
CE.close(); vim.api.nvim_buf_set_lines(source, 0, -1, true, lines)

-- Actual text fields and host extmarks preview literal output without writing.
H.ok(CE.execute('replace-literal', nil, { interactive = false }))
H.eq('input', session.active.mode)
keys('needle<CR>')
H.eq(2, session.active.input.index)
keys('.* / & <C-v>\\1🙂')
H.eq(lines, text(), 'replacement preview retains the whole original document')
H.ok(#vim.api.nvim_buf_get_extmarks(source, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}) > 0,
  'typed replacement has a real host-owned source preview: ' .. tostring(session.active.message))
keys('<CR>')
H.eq(3, session.active.input.index)
H.eq(false, session.active.input.choices[session.active.input.selected].value, 'replacement defaults to explicit Cancel')
H.eq(lines, text(), 'the Apply field retains the unchanged source until Enter')
untouched('preview')
keys('<Down><CR>')
H.eq(nil, session.active, 'one explicit Apply executes without a duplicate final review')
local replaced = { '한글🙂 .* / & \\1🙂 .* / & \\1🙂', 'Needle .* / & \\1🙂', 'literal .* / & \\1 .* / & \\1🙂' }
H.eq(replaced, text(), 'all replacement bytes remain literal, including regex-like text and emoji')
H.eq('succeeded', CE.operations()[1].status)
H.eq(true, vim.bo[source].modified)
H.eq(0, #vim.api.nvim_buf_get_extmarks(source, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}),
  'review execution releases all preview extmarks')
untouched('replacement')
vim.cmd.undo()
H.eq(lines, text(), 'one native undo restores the entire reviewed replacement')
vim.cmd.redo()
H.eq(replaced, text(), 'one native redo restores the entire replacement')
vim.cmd.undo()

-- Cancel is a form decision, not a failed edit operation or a second review.
local cancel_source, cancel_count = text(), #CE.operations()
local cancel_done, cancel_ok, cancel_reason = 0
H.ok(CE.execute('replace-literal', { find = 'needle', replace = 'cancelled edit' }, { interactive = false,
  done = function(ok, reason) cancel_done, cancel_ok, cancel_reason = cancel_done + 1, ok, reason end }))
H.eq(false, session.active.input.choices[session.active.input.selected].value)
keys('<CR>')
H.ok(not session.active or session.active.mode ~= 'input', 'Cancel leaves the form without another confirmation')
H.eq(cancel_source, text(), 'Cancel leaves every source byte unchanged')
H.eq(cancel_count, #CE.operations(), 'Cancel admits no edit operation')
H.eq(1, cancel_done, 'Cancel invokes its completion callback exactly once')
H.eq(false, cancel_ok)
H.eq('Cancelled', cancel_reason)
H.eq(0, #vim.api.nvim_buf_get_extmarks(source, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}),
  'Cancel releases its visible source preview')
untouched('cancel')
CE.close()
H.eq(1, cancel_done, 'closing the remaining parent cannot cancel the submitted form twice')
H.ok(CE.execute('replace-literal', nil, { interactive = false }))
H.eq('needle', session.active.input.args.find, 'Cancel retains the literal find draft')
H.eq('cancelled edit', session.active.input.args.replace, 'Cancel retains the replacement draft')
H.eq(false, session.active.input.choices[session.active.input.selected].value, 'restored cancelled draft still defaults to Cancel')
CE.close()

-- A direct API call with all fields cannot invent its own reviewed edit plan.
local before_bypass, bypass_count = text(), #CE.operations()
local bypass_ok, bypass_reason = CE.execute('replace-literal', { find = 'needle', replace = 'unreviewed', confirm = true,
  plan = { next_lines = { 'untrusted caller plan' } } }, { interactive = false })
H.eq(false, bypass_ok)
H.ok(bypass_reason:find('preview and explicit Apply', 1, true))
H.eq(before_bypass, text(), 'unreviewed direct execution cannot mutate source')
H.eq(bypass_count + 1, #CE.operations(), 'refused API run is retained as a visible failed operation')
CE.close()

local count = #CE.operations()
vim.bo[source].readonly = true
local accepted, reason = CE.execute('replace-literal', { find = 'needle', replace = 'blocked', confirm = true }, { interactive = false })
H.eq(false, accepted)
H.ok(reason:find('read-only', 1, true))
H.eq(count, #CE.operations(), 'read-only rejection creates no operation')
H.eq(lines, text())
CE.close(); vim.bo[source].readonly = false

-- The explicit Apply field holds the original source revision. Failed Apply
-- stays visible; reopening captures a new revision and needs a fresh Enter.
H.ok(CE.execute('replace-literal', { find = 'needle', replace = 'retry' }, { interactive = false }))
H.eq('input', session.active.mode)
H.eq(3, session.active.input.index)
keys('<Down>')
vim.api.nvim_buf_set_lines(source, 1, 2, true, { 'intentional later edit needle' })
local current = text()
keys('<CR>')
H.eq('input', session.active.mode, 'stale replacement keeps the explicit Apply field visible')
H.ok((session.active.message or ''):find('changed', 1, true))
H.eq(current, text(), 'stale Apply never overwrites the intentional edit')
H.eq(count, #CE.operations(), 'stale replacement is rejected before an operation')
CE.close()
H.ok(CE.execute('replace-literal', { find = 'needle', replace = 'retry' }, { interactive = false }))
H.eq(current, text(), 'reopened draft performs no automatic replacement')
H.eq(count, #CE.operations())
keys('<CR>')
H.eq(nil, session.active, 'restored Apply choice still requires one fresh Enter')
H.eq({ '한글🙂 retry retry', 'intentional later edit retry', 'literal .* / & \\1 retry' }, text(),
  'explicit retry applies to the freshly captured revision')
untouched('stale retry')

-- Neither changed nor exactly matching public API arguments can borrow the
-- visible form's private Apply authority, even with its exact preview context.
count = #CE.operations()
H.ok(CE.execute('replace-literal', { find = 'retry', replace = 'reviewed' }, { interactive = false }))
keys('<Down>')
H.eq('input', session.active.mode)
local reviewed_source = text()
local form_context = vim.deepcopy(session.active.input.context)
local changed_ok, changed_reason = CE.execute('replace-literal', { find = 'retry', replace = 'different', confirm = true },
  { interactive = false, context = form_context })
H.eq(false, changed_ok)
H.ok(changed_reason:find('preview and explicit Apply', 1, true))
H.eq(reviewed_source, text(), 'changed external inputs cannot use the form preview')
H.eq('input', session.active.mode)
local matching_ok, matching_reason = CE.execute('replace-literal', { find = 'retry', replace = 'reviewed', confirm = true },
  { interactive = false, context = vim.deepcopy(session.active.input.context) })
H.eq(false, matching_ok)
H.ok(matching_reason:find('preview and explicit Apply', 1, true))
H.eq(reviewed_source, text(), 'matching public inputs and context still cannot authorize Apply')
keys('<CR>')
H.eq({ '한글🙂 reviewed reviewed', 'intentional later edit reviewed', 'literal .* / & \\1 reviewed' }, text(),
  'the original form still requires and accepts its own explicit Apply Enter')
H.eq(count + 3, #CE.operations(), 'two refused API runs and actual Apply are distinct retained operations')
untouched('review input substitution')

-- A host preview failure cannot leave a usable reviewed plan behind. Restoring
-- the host boundary and reopening the reviewed field creates a fresh preview.
H.ok(CE.execute('replace-literal', { find = 'reviewed', replace = 'final' }, { interactive = false }))
local setmark, failures = vim.api.nvim_buf_set_extmark, 0
vim.api.nvim_buf_set_extmark = function(buf, ns, ...)
  if buf == source and ns == vim.api.nvim_create_namespace('command_tree_document') then
    failures = failures + 1; error('deliberate preview host failure')
  end
  return setmark(buf, ns, ...)
end
keys('<Down>')
vim.api.nvim_buf_set_extmark = setmark
H.eq(1, failures, 'only the explicitly owned preview boundary is injected')
H.ok((session.active.message or ''):find('preview host failure', 1, true))
local preview_failed_source = text()
keys('<CR>')
H.eq('input', session.active.mode)
H.eq(preview_failed_source, text(), 'failed preview cannot authorize a replacement')
H.ok((session.active.message or ''):find('preview and explicit Apply', 1, true))
H.ok(#vim.api.nvim_buf_get_extmarks(source, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}) > 0,
  'failed execution regenerates a fresh visible preview after the host boundary is restored')
keys('<CR>')
H.eq({ '한글🙂 final final', 'intentional later edit final', 'literal .* / & \\1 final' }, text(),
  'restored host boundary still needs and accepts a new reviewed Apply: ' .. tostring(session.active and session.active.message))
untouched('preview failure recovery')

-- Back into a text field invalidates the old preview context. New text must
-- receive its own preview and explicit Apply; the former receipt is unusable.
H.ok(CE.execute('replace-literal', { find = 'final', replace = 'previous draft' }, { interactive = false }))
keys('<Down>')
local previous_context, editing_source = vim.deepcopy(session.active.input.context), text()
keys('<BS>')
H.eq(2, session.active.input.index, 'Back from Apply edits replacement text instead of submitting')
keys('<C-u>changed draft<CR>')
H.eq(3, session.active.input.index)
H.ok(previous_context.document_review ~= session.active.input.context.document_review,
  'editing replacement text creates a different private preview receipt')
local old_ok, old_reason = CE.execute('replace-literal', { find = 'final', replace = 'previous draft', confirm = true },
  { interactive = false, context = previous_context })
H.eq(false, old_ok)
H.ok(old_reason:find('preview and explicit Apply', 1, true))
H.eq(editing_source, text(), 'the abandoned draft cannot mutate source through its former context')
keys('<CR>')
H.eq({ '한글🙂 changed draft changed draft', 'intentional later edit changed draft', 'literal .* / & \\1 changed draft' }, text(),
  'only the currently previewed replacement is applied')
vim.cmd.undo()
H.eq(editing_source, text(), 'the edited draft replacement still has a single native Undo')

-- Public reentrant calls from an availability hook cannot borrow an active
-- Session submission. Refreshing the preview also invalidates the outer scope;
-- the resulting form needs another explicit Enter before any mutation.
H.ok(CE.execute('replace-literal', { find = 'final', replace = 'reentrant safe' }, { interactive = false }))
keys('<Down>')
local registered = CE.registry():get('edit.replace_literal')
local original_available, nested = registered.available, nil
registered.available = function(ctx)
  if not nested then
    nested = { attempted = true }
    nested.ok, nested.reason = CE.execute('replace-literal', { find = 'final', replace = 'reentrant safe', confirm = true },
      { interactive = false, context = vim.deepcopy(session.active.input.context) })
  end
  return original_available(ctx)
end
keys('<CR>')
registered.available = original_available
H.ok(nested and nested.attempted, 'the actual availability boundary made its nested public call')
H.eq(false, nested.ok, 'a nested public invocation cannot use the private Apply scope')
H.ok(nested.reason:find('preview and explicit Apply', 1, true))
H.eq(editing_source, text(), 'the nested preview refresh invalidates the pending outer Apply too')
H.eq('input', session.active.mode)
keys('<CR>')
H.eq({ '한글🙂 reentrant safe reentrant safe', 'intentional later edit reentrant safe', 'literal .* / & \\1 reentrant safe' }, text(),
  'a fresh explicit Enter applies the current preview after the rejected nested call')
vim.cmd.undo()
H.eq(editing_source, text(), 'the reentrant refusal leaves one reversible actual edit')

-- A descriptor exposed by the registry cannot run from an availability hook
-- before operation admission, even with cloned arguments and preview context.
-- The original Apply remains valid and produces its single retained task.
H.ok(CE.execute('replace-literal', { find = 'final', replace = 'descriptor safe' }, { interactive = false }))
keys('<Down>')
local descriptor_nested, descriptor_count = nil, #CE.operations()
registered.available = function(ctx)
  if not descriptor_nested then
    descriptor_nested = { attempted = true }
    descriptor_nested.ok, descriptor_nested.reason = registered.run(vim.deepcopy(ctx), vim.deepcopy(session.active.input.args))
    descriptor_nested.lines, descriptor_nested.count = text(), #CE.operations()
  end
  return original_available(ctx)
end
keys('<CR>')
registered.available = original_available
H.ok(descriptor_nested and descriptor_nested.attempted, 'the availability callback attempted its direct descriptor invocation')
H.eq(false, descriptor_nested.ok, 'availability has no Apply invocation authority')
H.ok(descriptor_nested.reason:find('preview and explicit Apply', 1, true))
H.eq(editing_source, descriptor_nested.lines, 'direct descriptor call cannot mutate before admission')
H.eq(descriptor_count, descriptor_nested.count, 'a refused descriptor call creates no fake task')
H.eq(descriptor_count + 1, #CE.operations(), 'the original Apply creates exactly one retained operation')
H.eq('succeeded', CE.operations()[1].status, 'the original consented invocation still succeeds')
H.eq({ '한글🙂 descriptor safe descriptor safe', 'intentional later edit descriptor safe', 'literal .* / & \\1 descriptor safe' }, text())
vim.cmd.undo()
H.eq(editing_source, text(), 'the admitted descriptor-safe edit has a single Undo')

-- Inject a real scoped OptionSet hook at the native option boundary. Startup
-- suppresses automatic OptionSet in this fixture, so the wrapper dispatches
-- that event explicitly after the option command rather than claiming a full
-- editor gesture test. The hook's revision change must beat the prepared edit.
H.ok(CE.execute('replace-literal', { find = 'final', replace = 'must not apply' }, { interactive = false }))
keys('<Down>')
local option_hook_calls, command_boundary = 0, vim.cmd
local execution_context, execution_args, native_nested
local apply_field, original_validate = registered.arguments[3], registered.arguments[3].validate
apply_field.validate = function(value, ctx, args)
  -- The last validation is the executor's actual invocation. Retain those
  -- exact objects so the native hook tests one-time consumption, not cloning.
  execution_context, execution_args = ctx, args
  if original_validate then return original_validate(value, ctx, args) end
  return true
end
local option_count = #CE.operations()
local option_group = vim.api.nvim_create_augroup('re35_document_option_boundary', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', { group = option_group, pattern = 'undolevels', once = true, callback = function()
  option_hook_calls = option_hook_calls + 1
  local invocation = CE.operations()[1]
  H.eq(execution_context, invocation.ctx, 'native hook receives the admitted invocation context')
  native_nested = { attempted = true }
  native_nested.ok, native_nested.reason = registered.run(execution_context, execution_args, nil, invocation)
  native_nested.lines, native_nested.count = text(), #CE.operations()
  vim.api.nvim_buf_set_lines(source, 0, 1, true, { 'intentional option-hook edit final' })
end })
vim.cmd = setmetatable({}, { __index = command_boundary, __call = function(_, command)
  command_boundary(command)
  if command == 'let &g:undolevels = &g:undolevels' and option_hook_calls == 0 then
    vim.api.nvim_exec_autocmds('OptionSet', { pattern = 'undolevels' })
  end
end })
keys('<CR>')
vim.cmd = command_boundary
apply_field.validate = original_validate
vim.api.nvim_del_augroup_by_id(option_group)
H.eq(1, option_hook_calls, 'the scoped option hook changes the source at the guarded boundary')
H.ok(native_nested and native_nested.attempted)
H.eq(false, native_nested.ok, 'native hooks cannot reuse already consumed Apply authority')
H.ok(native_nested.reason:find('preview and explicit Apply', 1, true))
H.eq(editing_source, native_nested.lines, 'the nested native descriptor call cannot mutate any source byte')
H.eq(option_count + 1, native_nested.count, 'only the actual admitted operation is retained at the native boundary')
H.eq({ 'intentional option-hook edit final', editing_source[2], editing_source[3] }, text(),
  'Apply cannot overwrite the native hook or change the remaining source lines')
H.eq('input', session.active.mode)
H.ok((session.active.message or ''):find('changed', 1, true), 'option-hook revision refusal is visible')
CE.close(); vim.api.nvim_buf_set_lines(source, 0, -1, true, editing_source)
untouched('option boundary refusal')

H.ok(CE.execute('replace-literal', { find = 'final', replace = 'renamed refusal' }, { interactive = false }))
if require('command_tree.arguments').value(session.active.input.choices[session.active.input.selected]) ~= true then keys('<Down>') end
H.eq('input', session.active.mode)
local rename_count, rename_lines, rename_tick = #CE.operations(), text(), vim.api.nvim_buf_get_changedtick(source)
vim.api.nvim_buf_set_name(source, folder .. '/rename during replace.txt')
H.eq(rename_tick, vim.api.nvim_buf_get_changedtick(source))
keys('<CR>')
H.eq('input', session.active.mode)
H.ok((session.active.message or ''):find('renamed', 1, true))
H.eq(rename_count, #CE.operations(), 'rename rejects before native mutation/operation admission')
H.eq(rename_lines, text())
CE.close(); vim.api.nvim_buf_set_name(source, source_path)

vim.bo[source].modifiable = false
accepted, reason = CE.execute('replace-literal', { find = 'final', replace = 'blocked', confirm = true }, { interactive = false })
H.eq(false, accepted)
H.ok(reason:find('cannot be modified', 1, true))
H.eq(rename_lines, text())
CE.close(); vim.bo[source].modifiable = true

local undo_global, undo_local = vim.go.undolevels, vim.bo[source].undolevels
vim.go.undolevels, vim.bo[source].undolevels = -1, -123456
accepted, reason = CE.execute('replace-literal', { find = 'final', replace = 'no undo', confirm = true }, { interactive = false })
H.eq(false, accepted)
H.ok(reason:find('Undo is disabled', 1, true), 'inherited disabled undo refuses replacement')
H.eq(rename_lines, text())
CE.close(); vim.go.undolevels, vim.bo[source].undolevels = undo_global, undo_local
H.ok(CE.execute('replace-literal', { find = 'final', replace = 'undo disabled after preview' }, { interactive = false }))
if require('command_tree.arguments').value(session.active.input.choices[session.active.input.selected]) ~= true then keys('<Down>') end
H.eq('input', session.active.mode)
vim.bo[source].undolevels = -1
keys('<CR>')
H.eq('input', session.active.mode)
H.ok((session.active.message or ''):find('Undo is disabled', 1, true), 'changing undo support invalidates Apply after preview')
H.eq(rename_lines, text())
CE.close(); vim.bo[source].undolevels = undo_local

-- Search is allowed on read-only documents, including a meaningful retained
-- empty result. Malformed task provenance never falls back to a saved filename.
vim.bo[source].readonly = true
H.ok(CE.execute('docfind', { query = 'no such literal' }, { interactive = false }))
results_ready()
H.eq('empty', CE.operations()[1].detail.locations_status)
H.eq(0, #frame().data.items)
H.eq(rename_lines, text())
CE.close(); vim.bo[source].readonly = false
H.ok(CE.execute('docfind', { query = 'final' }, { interactive = false }))
results_ready()
local malformed = CE.operations()[1]
malformed.detail.locations[1].document_target.uri = { invalid = true }
local reread = H.ok(Results.read('task', K.context(), nil, malformed.id))
H.eq(false, reread.items[1].document_target, 'malformed host reference stays explicitly refused')
local malformed_ok, malformed_reason = Results.jump(reread.items[1], K.context())
H.eq(false, malformed_ok)
H.ok(malformed_reason:find('changed', 1, true))
H.eq(source, vim.api.nvim_get_current_buf(), 'bad reference cannot reopen a same-named file')
CE.close()

-- A location can become stale inside native BufEnter. The jump must not place
-- its retained cursor after an entry hook intentionally edits or renames it.
local other_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(other_buffer, 0, -1, true, { 'unrelated document' })
local function hook_jump(change, label)
  H.ok(CE.execute('docfind', { query = 'final' }, { interactive = false }))
  results_ready()
  local item = frame().data.items[1]
  CE.close(); vim.api.nvim_set_current_buf(other_buffer)
  local called, before_tick = 0, vim.api.nvim_buf_get_changedtick(source)
  vim.api.nvim_create_autocmd('BufEnter', { buffer = source, once = true, callback = function()
    called = called + 1
    change()
    vim.api.nvim_win_set_cursor(source_win, { 2, 2 })
  end })
  local jumped, why = Results.jump(item, K.context())
  H.eq(false, jumped, label .. ': native entry change rejects the retained location')
  H.ok(why:find('changed', 1, true), label .. ': refusal explains the stale source')
  H.eq(1, called, label .. ': real scoped BufEnter ran once')
  H.eq({ 2, 2 }, vim.api.nvim_win_get_cursor(source_win), label .. ': retained cursor never overrides the native hook')
  return before_tick
end
hook_jump(function() vim.api.nvim_buf_set_lines(source, 0, 1, true, { 'intentional BufEnter edit' }) end, 'entry edit')
H.eq('intentional BufEnter edit', text()[1], 'intentional native entry edit is never overwritten')
vim.api.nvim_buf_set_lines(source, 0, -1, true, rename_lines)
local before_rename = hook_jump(function() vim.api.nvim_buf_set_name(source, folder .. '/BufEnter renamed.txt') end, 'entry rename')
H.eq(before_rename, vim.api.nvim_buf_get_changedtick(source), 'real entry rename preserves text revision')
vim.api.nvim_buf_set_name(source, source_path)
vim.api.nvim_buf_delete(other_buffer, { force = true })
untouched('native entry refusal')

local oversized = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(oversized)
local many = {}; for index = 1, 2001 do many[index] = 'x' end
vim.api.nvim_buf_set_lines(oversized, 0, -1, true, many)
H.ok(H.raises(function() Document.snapshot(K.context()) end):find('2000 lines', 1, true),
  'host checks actual buffer line bound before copying the snapshot')
vim.api.nvim_buf_set_lines(oversized, 0, -1, true, { string.rep('x', 262145) })
H.ok(H.raises(function() Document.snapshot(K.context()) end):find('256 KiB', 1, true),
  'host checks actual buffer byte bound before copying the snapshot')
vim.api.nvim_set_current_buf(source); vim.api.nvim_buf_delete(oversized, { force = true })

-- Unnamed documents are valid exact buffer targets; no saved-file fallback.
local unnamed = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(unnamed)
vim.api.nvim_buf_set_lines(unnamed, 0, -1, true, { '🙂 unsaved needle' })
H.ok(CE.execute('docfind', { query = 'needle' }, { interactive = false }))
results_ready()
local unnamed_task, unnamed_item = CE.operations()[1], frame().data.items[1]
H.eq('', unnamed_item.filename)
H.eq('re35-buffer://' .. unnamed, unnamed_item.document_target.uri)
keys('<CR>')
H.eq(unnamed, vim.api.nvim_get_current_buf())
H.eq({ 1, 13 }, vim.api.nvim_win_get_cursor(source_win))

vim.api.nvim_buf_set_lines(unnamed, 0, -1, true, { '\tneedle' })
H.ok(CE.execute('docfind', { query = 'needle' }, { interactive = false }))
results_ready()
local tab_task, tab_item = CE.operations()[1], frame().data.items[1]
H.eq(2, tab_item.col, 'document results use byte columns even after a tab')
keys('<CR>')
H.eq({ 1, 1 }, vim.api.nvim_win_get_cursor(source_win), 'normal tab-prefixed result jumps by UTF-8 byte offset')
vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
tab_task.detail.locations[1].vcol = true
local tab_rows = H.ok(Results.read('task', K.context(), nil, tab_task.id))
local tab_ok, tab_reason = Results.jump(tab_rows.items[1], K.context())
H.eq(false, tab_ok)
H.ok(tab_reason:find('byte columns', 1, true), 'malformed document result cannot request visual-column conversion')
H.eq({ 1, 0 }, vim.api.nvim_win_get_cursor(source_win), 'malformed column units leave the cursor untouched')
local numeric_vcol = vim.deepcopy(tab_item); numeric_vcol.vcol = 1
tab_ok, tab_reason = Document.validate_location(numeric_vcol)
H.eq(false, tab_ok)
H.ok(tab_reason:find('byte columns', 1, true), 'numeric visual-column flag is also refused for a document row')
H.ok(CE.open_task_results(unnamed_task.id, { interactive = false }))
vim.api.nvim_buf_delete(unnamed, { force = true })
local ok, why = Results.jump(unnamed_item, K.context())
H.eq(false, ok)
H.ok(why:find('closed', 1, true), 'closed unnamed target is not re-resolved as another buffer')
CE.close(); vim.api.nvim_set_current_buf(source)

-- Existing typed file open uses native non-bang safety. Missing paths create
-- an unsaved document, and a dirty unhidden source refuses replacement.
local other = folder .. '/other file.txt'
vim.fn.writefile({ 'other saved file' }, other)
local hidden = vim.o.hidden; vim.o.hidden = false
accepted, reason = CE.execute('file.open', { path = other }, { interactive = false })
H.eq(false, accepted, 'native edit refuses a modified source when hidden is disabled')
H.eq(source, vim.api.nvim_win_get_buf(source_win))
H.eq({ 'other saved file' }, vim.fn.readfile(other))
CE.close(); vim.o.hidden = true
local missing = folder .. '/new missing file.txt'
H.ok(CE.execute('file.open', { path = missing }, { interactive = false }))
H.eq(vim.fs.normalize(missing), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
H.eq(nil, vim.uv.fs_stat(missing), 'opening a missing path never creates or writes a file')
vim.o.hidden = hidden
untouched('file open')
CE.close(); CE.disable(); Session.new = create
print('document real workflow checks: ' .. H.checks)
