-- Actual tree/input/Results/Apply on a full-sized, unsaved Document v2 target.
-- Machine elapsed/Lua allocation samples are controlled integration evidence,
-- not physical UI observations, human timing or performance comparisons.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Document = require('re35'), require('command_tree.document')
local Paged = require('command_tree.document.paged')
local folder = H.tempdir('document-v2-workflow')
local source_path = folder .. '/large unsaved 한글.txt'
local saved = { 'saved document stays unchanged', 'needle on disk is not the source' }
vim.fn.writefile(saved, source_path)
vim.api.nvim_cmd({ cmd = 'edit', args = { source_path } }, {})
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.o.columns, vim.o.lines = 130, 44
vim.fn.setqflist({}, ' ', { title = 'native quickfix stays unchanged', items = {
  { filename = source_path, lnum = 2, col = 1, text = 'existing native result' },
} })
local qf = vim.fn.getqflist({ items = 1, title = 1, id = 0, changedtick = 0 })
CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
  profile = { path = false }, window = { icons = false }, integrations = { theme = false },
  providers = { builtin = true, ex = false, native = false, keymaps = false, lsp = false, runner = false, plugins = false } })

local function keys(value) for _, token in ipairs(K.tokens(value)) do session:handle(token) end end
local function text() return vim.api.nvim_buf_get_lines(source, 0, -1, true) end
local function frame() return session.active.stack[#session.active.stack] end
local function bytes(lines) local total = 0; for _, line in ipairs(lines) do total = total + #line end; return total end
local function set_source(lines)
  CE.close(); vim.api.nvim_set_current_win(source_win); vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_set_lines(source, 0, -1, true, lines)
  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
end
local function open(route)
  CE.close(); vim.api.nvim_set_current_win(source_win); vim.api.nvim_set_current_buf(source)
  H.ok(CE.open({ interactive = false }), 'Open the actual command tree from the original document')
  keys(route)
  H.eq('input', session.active.mode, 'Tree path opens its real typed command form')
end
local function results_ready()
  H.ok(vim.wait(1000, function()
    return session.active and session.active.mode == 'workspace' and frame().id == 'results'
  end, 10), 'Completed document search opens its retained Results workspace')
end
local function untouched(expected, label)
  H.ok(vim.deep_equal(expected, text()), label .. ': every current source byte is preserved')
  H.eq(saved, vim.fn.readfile(source_path), label .. ': the saved file is unchanged')
  H.eq(qf, vim.fn.getqflist({ items = 1, title = 1, id = 0, changedtick = 0 }), label .. ': native quickfix is unchanged')
end
local function apply_choice()
  H.eq('confirm', session.active.input.command.arguments[session.active.input.index].name)
  if session.active.input.choices[session.active.input.selected].value ~= true then keys('<Down>') end
  H.eq(true, session.active.input.choices[session.active.input.selected].value)
end
local function prepare(find, replacement)
  CE.close(); vim.api.nvim_set_current_win(source_win); vim.api.nvim_set_current_buf(source)
  H.ok(CE.execute('replace-literal', { find = find, replace = replacement }, { interactive = false }),
    'Open an actual replacement form with explicit arguments')
  H.eq('input', session.active.mode)
  H.eq(3, session.active.input.index)
  -- Moving to the explicit Apply choice refreshes the actual preview after any
  -- restored-draft notice, so a capture/limit error remains visible to users.
  keys('<Down>'); apply_choice()
end
local function refusal(patterns, expected, label)
  H.eq('input', session.active.mode, label .. ': failed submission keeps the form visible')
  local reason, found = session.active.message or '', false
  for _, pattern in ipairs(type(patterns) == 'table' and patterns or { patterns }) do
    if reason:find(pattern, 1, true) then found = true end
  end
  H.ok(found, label .. ': refusal explains its limit or stale target: ' .. reason)
  untouched(expected, label)
end

-- Exactly both frozen whole-document limits, with sparse matches so result and
-- edit quotas do not disguise whether the full document was actually processed.
local lines = {}
for index = 1, 10000 do lines[index] = string.rep('x', index <= 8576 and 105 or 104) end
local prefixes = { [1] = '한글🙂 needle needle', [257] = 'middle needle',
  [4097] = 'late needle', [10000] = '끝🙂 needle' }
for index, prefix in pairs(prefixes) do lines[index] = prefix .. string.rep('x', #lines[index] - #prefix) end
H.eq(10000, #lines)
H.eq(1048576, bytes(lines), 'Acceptance source is exactly 1 MiB of UTF-8 line content, excluding separators')
set_source(lines)
H.ok(H.raises(function() Document.snapshot(K.context()) end):find('2000 lines', 1, true),
  'The additive host flow does not silently expand the public Document v1 snapshot contract')
local measurements = { source_lines = #lines, source_utf8_bytes = bytes(lines),
  machine_only = true, lua_kib_before = collectgarbage('count') }
local started = vim.uv.hrtime()
open('ef'); keys('needle<CR>'); results_ready()
measurements.search_ms = (vim.uv.hrtime() - started) / 1000000
measurements.lua_kib_after_search = collectgarbage('count')
local search, rows = CE.operations()[1], frame().data.items
H.eq('succeeded', search.status)
H.eq(2, search.detail.document_contract_version, 'The oversized source selects the additive Document v2 contract')
H.eq(true, search.detail.document_complete, 'The host explicitly reports completed whole-document processing')
H.eq(5, #rows, 'Search processes the whole document, including late pages and its last line')
H.eq({ 1, 1, 257, 4097, 10000 }, vim.tbl_map(function(item) return item.line end, rows))
H.eq({ 12, 19, 8, 6, 9 }, vim.tbl_map(function(item) return item.col end, rows),
  'Absolute document coordinates retain original UTF-8 byte columns after Korean and emoji')
H.eq(false, search.detail.locations_truncated, 'Sparse whole-document results are complete')
for _, row in ipairs(rows) do
  H.eq(source, row.bufnr)
  H.eq(K.document_uri(source), row.document_target.uri)
  H.eq(tostring(vim.api.nvim_buf_get_changedtick(source)), row.document_target.revision)
end
untouched(lines, 'full-sized search')
keys('<Down><Down><Down><Down><CR>')
H.eq(nil, session.active, 'A retained result closes its UI and focuses the original loaded document')
H.eq(source, vim.api.nvim_get_current_buf())
H.eq({ 10000, 8 }, vim.api.nvim_win_get_cursor(source_win), 'Last-line result jumps using its original absolute byte coordinate')

started = vim.uv.hrtime()
open('er'); keys('needle<CR>새XYZ')
local namespace = vim.api.nvim_create_namespace('command_tree_document')
local marks = vim.api.nvim_buf_get_extmarks(source, namespace, 0, -1, { details = true })
H.ok(#marks > 0, 'The typed large-document replacement has a real source preview')
local last_preview = false
for _, mark in ipairs(marks) do if mark[2] == 9999 and mark[4].virt_lines then last_preview = true end end
H.ok(last_preview, 'Preview includes the absolute last-line edit, rather than only the first page')
untouched(lines, 'full-sized typed preview')
keys('<CR>')
H.eq(3, session.active.input.index)
H.eq(false, session.active.input.choices[session.active.input.selected].value, 'A new typed replacement defaults to explicit Cancel')
measurements.review_ms = (vim.uv.hrtime() - started) / 1000000
measurements.lua_kib_after_preview = collectgarbage('count')
apply_choice(); started = vim.uv.hrtime(); keys('<CR>')
measurements.apply_ms = (vim.uv.hrtime() - started) / 1000000
measurements.lua_kib_after_apply = collectgarbage('count')
local replaced = vim.deepcopy(lines)
for index in pairs(prefixes) do replaced[index] = replaced[index]:gsub('needle', '새XYZ') end
H.eq(nil, session.active, 'One explicit Apply finishes without another review or confirmation')
H.eq('succeeded', CE.operations()[1].status)
H.ok(vim.deep_equal(replaced, text()), 'All sparse literal replacements, including the last page, are applied together')
H.eq(1048576, bytes(text()), 'Equal-byte Unicode replacement remains within the exact output bound')
H.eq(true, vim.bo[source].modified)
H.eq(0, #vim.api.nvim_buf_get_extmarks(source, namespace, 0, -1, {}), 'Apply releases its source preview')
H.eq(saved, vim.fn.readfile(source_path), 'Apply changes only the loaded buffer and never writes its file')
vim.cmd.undo(); H.ok(vim.deep_equal(lines, text()), 'One native Undo restores the entire large reviewed replacement')
vim.cmd.redo(); H.ok(vim.deep_equal(replaced, text()), 'One native Redo restores the entire large reviewed replacement')
vim.cmd.undo(); untouched(lines, 'large replacement undo')

local count, completed, completion_ok, completion_reason = #CE.operations(), 0
H.ok(CE.execute('replace-literal', { find = 'needle', replace = 'discarded' }, { interactive = false,
  done = function(ok, reason) completed, completion_ok, completion_reason = completed + 1, ok, reason end }))
H.eq(false, session.active.input.choices[session.active.input.selected].value)
keys('<CR>')
H.eq(count, #CE.operations(), 'Cancel admits no replacement operation')
H.eq(1, completed)
H.eq(false, completion_ok)
H.eq('Cancelled', completion_reason)
H.eq(0, #vim.api.nvim_buf_get_extmarks(source, namespace, 0, -1, {}))
untouched(lines, 'large replacement cancel'); CE.close()
H.eq(1, completed, 'Closing after Cancel cannot invoke its completion callback twice')

-- Keep later ownership/failure probes on a smaller v2-only document, rather
-- than repeatedly measuring the maximum-sized case or allocating large test
-- failure messages. The acceptance source above remains available for bounds.
local full_lines = lines
lines = {}; for index = 1, 2200 do lines[index] = 'ordinary unchanged line' end
lines[1], lines[257], lines[2199] = '한글🙂 needle needle', 'middle needle', '끝🙂 needle'
set_source(lines)

prepare('needle', 'stale!'); apply_choice()
local changed = vim.deepcopy(lines); changed[1] = changed[1]:sub(1, -2) .. 'y'
vim.api.nvim_buf_set_lines(source, 0, 1, true, { changed[1] })
keys('<CR>'); refusal('changed', changed, 'revision changed after preview'); set_source(lines)
prepare('needle', 'rename'); apply_choice()
local tick = vim.api.nvim_buf_get_changedtick(source)
vim.api.nvim_buf_set_name(source, folder .. '/renamed large.txt')
H.eq(tick, vim.api.nvim_buf_get_changedtick(source), 'Rename changes identity without changing the text revision')
keys('<CR>'); refusal('renamed', lines, 'target renamed after preview')
CE.close(); vim.api.nvim_buf_set_name(source, source_path)
prepare('needle', 'locked'); apply_choice(); vim.bo[source].readonly = true
keys('<CR>'); refusal('read-only', lines, 'read-only changed after preview')
CE.close(); vim.bo[source].readonly = false
prepare('needle', 'noUndo'); apply_choice()
local undo_levels = vim.bo[source].undolevels; vim.bo[source].undolevels = -1
keys('<CR>'); refusal('Undo is disabled', lines, 'Undo disabled after preview')
CE.close(); vim.bo[source].undolevels = undo_levels

-- The v2 data contract is not Apply authority. Public callers cannot borrow an
-- active large-document preview even with exactly matching fields and context.
prepare('needle', 'public'); apply_choice()
local bypass_ok, bypass_reason = CE.execute('replace-literal', { find = 'needle', replace = 'public', confirm = true },
  { interactive = false, context = vim.deepcopy(session.active.input.context) })
H.eq(false, bypass_ok)
H.ok(bypass_reason:find('preview and explicit Apply', 1, true))
untouched(lines, 'public replay refusal'); CE.close()

-- Inject changes at actual native capture boundaries. Neither a partial copy
-- nor an intentional edit occurring during capture can become a complete plan.
open('ef'); keys('<C-u>needle')
local get_lines, copy_calls = vim.api.nvim_buf_get_lines, 0
vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
  local value = get_lines(buf, first, last, strict)
  if buf == source and first == 0 and last == -1 and copy_calls == 0 then
    copy_calls = copy_calls + 1; value[#value] = nil
  end
  return value
end
keys('<CR>'); vim.api.nvim_buf_get_lines = get_lines
H.eq(1, copy_calls, 'The incomplete-copy injection ran at the real source capture boundary')
refusal({ 'incomplete', 'count', 'changed', 'capture' }, lines, 'incomplete native capture'); CE.close()

open('ef'); keys('<C-u>needle'); copy_calls = 0
vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
  local value = get_lines(buf, first, last, strict)
  if buf == source and first == 0 and last == -1 and copy_calls == 0 then
    copy_calls = copy_calls + 1; vim.api.nvim_buf_set_lines(source, 0, 1, true, { changed[1] })
  end
  return value
end
keys('<CR>'); vim.api.nvim_buf_get_lines = get_lines
H.eq(1, copy_calls, 'The source edit injection ran while the native capture was in progress')
refusal('changed', changed, 'revision changed during native capture'); set_source(lines)

local capture, gaps = Paged.capture, 0
Paged.capture = function(...)
  local value = capture(...)
  gaps = gaps + 1; table.remove(value.pages, 2)
  return value
end
prepare('needle', 'gapped')
Paged.capture = capture
H.ok(gaps > 0, 'The coverage fault is injected after a real complete host capture')
refusal({ 'complete', 'gap', 'coverage', 'page', 'ordered' }, lines, 'missing independent page cannot authorize Apply')
keys('<CR>')
untouched(lines, 'incomplete page Apply refusal'); CE.close()

Paged.capture = function(...)
  local value = capture(...); value.deadline = vim.uv.hrtime() / 1000000 - 1; return value
end
prepare('needle', 'expiry')
Paged.capture = capture
refusal('5 second', lines, 'expired replacement processing budget')
keys('<CR>'); untouched(lines, 'expired-budget Apply refusal'); CE.close()

-- Expire the real monotonic budget after one actual pure-core page search.
-- This deliberately advances the test clock, rather than sleeping or claiming
-- a naturally observed slow operation. Retained results must say partial.
open('ef'); keys('<C-u>needle')
local CoreV2 = require('command_environment.core.document_v2')
local core_search, clock, expired, searched = CoreV2.search, vim.uv.hrtime, false, 0
vim.uv.hrtime = function() return clock() + (expired and 6000000000 or 0) end
CoreV2.search = function(...)
  local found = core_search(...); searched, expired = searched + 1, true; return found
end
keys('<CR>'); CoreV2.search, vim.uv.hrtime = core_search, clock
results_ready()
local partial = CE.operations()[1]
H.eq(1, searched, 'The budget expires after exactly one real independent page search')
H.eq(false, partial.detail.document_complete, 'Interrupted whole-document processing is explicitly partial')
H.eq(true, partial.detail.locations_truncated, 'Partial processing cannot be presented as complete search results')
H.ok(partial.detail.locations_message:find('partial document processing', 1, true), 'The retained result explains incomplete processing')
H.eq(2, #frame().data.items, 'Only matches from the actually processed first page are retained')
untouched(lines, 'partial search processing'); CE.close()

local function search_refused(value, pattern, label)
  set_source(value); open('ef'); keys('<C-u>needle<CR>')
  refusal(pattern, value, label); CE.close()
end
local too_many = {}; for index = 1, 10001 do too_many[index] = 'x' end
search_refused(too_many, '10000 lines', 'whole-document line bound')
local too_large = vim.deepcopy(full_lines); too_large[10000] = too_large[10000] .. 'x'
search_refused(too_large, '1 MiB', 'whole-document content byte bound')
local long_line = {}; for index = 1, 2200 do long_line[index] = 'x' end
long_line[1] = string.rep('x', 65537)
search_refused(long_line, '64 KiB', 'complete-line byte bound')

-- The exact complete-line bound is supported, not merely rejected above it.
long_line[1] = '한글🙂 needle' .. string.rep('x', 65536 - #'한글🙂 needle')
set_source(long_line); open('ef'); keys('<C-u>needle<CR>'); results_ready()
H.eq(1, #frame().data.items)
H.eq(12, frame().data.items[1].col)
untouched(long_line, 'exact 64 KiB line search'); CE.close()

local many_matches = {}; for index = 1, 4097 do many_matches[index] = 'needle' end
set_source(many_matches); vim.bo[source].readonly = true
open('ef'); keys('<C-u>needle<CR>'); results_ready()
local bounded_search = CE.operations()[1]
H.eq(200, #frame().data.items, 'Retained large-document search rows respect their finite result limit')
H.eq(true, bounded_search.detail.document_complete, 'Every page was processed even when the retained list is bounded')
H.eq(true, bounded_search.detail.locations_truncated)
H.ok(bounded_search.detail.locations_message:find('retained results are limited', 1, true), 'Result truncation is visible rather than silent')
untouched(many_matches, 'bounded read-only document search')
CE.close(); vim.bo[source].readonly = false
prepare('needle', 'quota!')
refusal({ '4096', 'edit limit', 'match limit' }, many_matches, 'aggregate replacement edit bound')
apply_choice(); keys('<CR>'); untouched(many_matches, 'edit-quota Apply refusal'); CE.close()
many_matches[4097] = nil
set_source(many_matches); prepare('needle', string.rep('r', 128))
refusal('512 KiB', many_matches, 'compact plan encoded JSON bound')
apply_choice(); keys('<CR>'); untouched(many_matches, 'plan-quota Apply refusal'); CE.close()
set_source(full_lines); prepare('needle', 'changed')
refusal('1 MiB', full_lines, 'aggregate replacement output bound')
apply_choice(); keys('<CR>'); untouched(full_lines, 'output-quota Apply refusal'); CE.close()

measurements.lua_kib_at_end = collectgarbage('count')
print('document v2 controlled machine samples: ' .. vim.json.encode(measurements))
CE.disable(); Session.new = create
print('document v2 real workflow checks: ' .. H.checks)
