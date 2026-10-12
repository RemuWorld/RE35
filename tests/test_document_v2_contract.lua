-- Runs with ordinary Lua 5.1 or the isolated Neovim test runner.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local D = require('command_environment.core.document_v2')
local V1 = require('command_environment.core.document')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label)
  check(U.deep_equal(J.decode(J.encode(expected)), J.decode(J.encode(actual))), label)
end
local function raises(callback, label) check(not pcall(callback), label) end
local function page(encoding, content, start, total_lines, total_bytes)
  content = content or { 'A한😀B한😀', '😀한', '' }
  local bytes = 0; for _, line in ipairs(content) do bytes = bytes + #line end
  start = start or 14
  return { contract_version = 2, uri = 'file:///project/%ED%95%9C.cpp', revision = 'host:17',
    encoding = encoding or 'utf-8', start_line = start, total_lines = total_lines or start + #content,
    total_bytes = total_bytes or bytes, lines = content }
end
local caps = D.capabilities()
check(vim == nil and D.contract_version == 2 and caps.contract_version == 2, 'Paged contract runs without any editor API')
check(caps.limits.max_document_lines == 10000 and caps.limits.max_document_bytes == 1048576
  and caps.limits.max_page_lines == 256 and caps.limits.max_page_bytes == 65536
  and caps.limits.max_matches == 4096 and caps.limits.max_plan_bytes == 524288
  and caps.limits.processing_timeout_ms == 5000, 'Capabilities publish frozen per-page and host aggregate obligations')
caps.limits.max_document_lines = 1; caps.operations[1] = 'injected'
check(D.capabilities().limits.max_document_lines == 10000 and D.capabilities().operations[1] == 'search',
  'Capability discovery returns detached data')
local source = page()
local detached = D.validate(source); detached.lines[1] = 'detached'
check(source.lines[1] == 'A한😀B한😀', 'Page validation returns detached line arrays')
local bounds = {
  ['utf-8'] = { { 1, 8 }, { 9, 16 } },
  ['utf-16'] = { { 1, 4 }, { 5, 8 } },
  ['utf-32'] = { { 1, 3 }, { 4, 6 } },
}
for encoding, positions in pairs(bounds) do
  local input = page(encoding)
  local result = D.search(input, '한😀')
  check(result.contract_version == 2 and result.uri == input.uri and result.revision == input.revision
    and result.start_line == 14 and result.total_lines == 17 and #result.locations == 2 and not result.truncated,
    encoding .. ' page result carries common source identity once')
  for index, pair in ipairs(positions) do
    local location = result.locations[index]
    equal({ start = { line = 14, character = pair[1] }, ['end'] = { line = 14, character = pair[2] } },
      location.range, encoding .. ' absolute zero-based end-exclusive ranges')
    check(location.uri == nil and location.revision == nil and location.encoding == nil,
      encoding .. ' locations do not duplicate identity')
  end
  local plan = D.prepare_replace(input, { find = '한😀', replace = '🧩한' })
  check(plan.match_count == 2 and plan.line_count == 3 and plan.start_line == 14
    and plan.original_lines == nil and plan.next_lines == nil, encoding .. ' wire plans retain compact edits only')
  equal(result.locations[1].range, plan.edits[1].range, encoding .. ' search and edit coordinates agree')
  equal({ 'A🧩한B🧩한', '😀한', '' }, D.apply(input, J.decode(J.encode(plan))), encoding .. ' transported plan applies exactly')
  check(plan.output_bytes == #'A🧩한B🧩한' + #'😀한' and input.lines[1] == 'A한😀B한😀',
    encoding .. ' render byte count excludes separators and calls never write the capture')
end
local independent = page('utf-16', { '😀x', 'x' }, 9998, 10000, 1048576)
local late = D.search(independent, 'x')
check(late.locations[1].range.start.line == 9998 and late.locations[1].range.start.character == 2
  and late.locations[2].range.start.line == 9999, 'Independent last page uses whole-document positions without prior core calls')
local literal = page(nil, { 'items[i].name /a/b %1', 'aaa' }, 0)
equal({ 'X /a/b %1', 'aaa' }, D.apply(literal, D.prepare_replace(literal, { find = 'items[i].name', replace = 'X' })),
  'Replacement remains literal with punctuation and slash inputs')
equal({ '%1a' }, D.apply(page(nil, { 'aaa' }, 0), D.prepare_replace(page(nil, { 'aaa' }, 0), { find = 'aa', replace = '%1' })),
  'Non-overlapping matching does not interpret replacement captures')
local one = D.search(source, '한', { limit = 1 })
check(#one.locations == 1 and one.truncated, 'Search marks additional undisplayed matches as partial')
check(not D.search(page(nil, { '한' }, 0), '한', { limit = 1 }).truncated, 'Exactly the result limit remains complete')
local default = D.search(page(nil, { string.rep('x', 201) }, 0), 'x')
check(#default.locations == 200 and default.truncated, 'Default search returns at most 200 compact locations')
local long = page(nil, { string.rep('한😀', 9000) .. 'x' }, 0)
local excerpt = D.search(long, 'x').locations[1]
check(#excerpt.text <= 1024 and J.valid_utf8(excerpt.text) and excerpt.range.start.character == 63000,
  'Long Unicode source excerpts remain bounded without changing the target range')
local large_query = string.rep('한', 1365)
local large_match = D.search(page(nil, { large_query }, 0), large_query).locations[1]
check(#large_match.text <= 1024 and J.valid_utf8(large_match.text) and large_match.range['end'].character == #large_query,
  'A query larger than the excerpt retains its complete coordinate range')
equal(source.lines, D.apply(source, D.prepare_replace(source, { find = 'absent', replace = '' })), 'No matches is a detached no-op')
local plan = D.prepare_replace(source, { find = '한', replace = '' })
local tamperers = {
  function(p) p.uri = 'untitled:other' end,
  function(p) p.revision = 'host:18' end,
  function(p) p.encoding = 'utf-16' end,
  function(p) p.start_line = p.start_line + 1 end,
  function(p) p.total_lines = p.total_lines + 1 end,
  function(p) p.total_bytes = p.total_bytes + 1 end,
  function(p) p.line_count = 2 end,
  function(p) p.match_count = 0 end,
  function(p) p.output_bytes = 0 end,
  function(p) p.contract_version = 1 end,
  function(p) p.edits[1].range.start.character = 2 end,
  function(p) p.edits[1].range['end'].line = 15 end,
  function(p) p.edits[1].text = 'injected' end,
  function(p) p.edits[1].old_text = 'injected' end,
  function(p) p.edits[1], p.edits[2] = p.edits[2], p.edits[1] end,
  function(p) p.edits[1].extra = true end,
  function(p) p.edits[1].range.extra = true end,
  function(p) p.edits[1].range.start.extra = p end,
  function(p) p.next_lines = { 'injected' } end,
  function(p) p.edits[4097] = p.edits[1] end,
}
for index, mutate in ipairs(tamperers) do
  local invalid = U.clone(plan); mutate(invalid)
  raises(function() D.apply(source, invalid) end, 'Tampered page review refused: ' .. index)
end
local drift = U.clone(source); drift.lines[1] = 'different'
raises(function() D.apply(drift, plan) end, 'Changed matching content is refused even with an unchanged opaque revision')
local called = false
local foreign = setmetatable({}, { __index = function() called = true; return 'x' end,
  __pairs = function() called = true; error('must not execute') end })
raises(function() D.validate(foreign) end, 'Foreign page objects are refused')
local foreign_lines = U.clone(source); foreign_lines.lines = foreign
raises(function() D.validate(foreign_lines) end, 'Foreign line arrays are refused')
local foreign_plan = U.clone(plan); foreign_plan.edits[1].range.start = foreign
raises(function() D.apply(source, foreign_plan) end, 'Foreign nested plan objects are refused')
check(not called, 'Invalid document data cannot invoke host callbacks')
for _, field in ipairs({ 'contract_version', 'uri', 'revision', 'encoding', 'start_line', 'total_lines', 'total_bytes', 'lines' }) do
  local invalid = U.clone(source); invalid[field] = nil
  raises(function() D.validate(invalid) end, 'Missing required page field: ' .. field)
end
for _, invalid in ipairs({ { [2] = 'sparse' }, { extra = 'object' }, {}, { 'x\ny' }, { 'x\ry' }, { 'x\0y' },
  { string.rep('x', 65537) }, U.object({ ['1'] = 'not an array' }) }) do
  raises(function() D.validate(page(nil, invalid, 0, 10000, 1048576)) end, 'Malformed complete-line page refused')
end
local full = {}; for index = 1, 256 do full[index] = string.rep('x', 256) end
check(#D.validate(page(nil, full, 9744, 10000, 1048576)).lines == 256, 'Exactly 256 lines and 64 KiB fit a late page')
local too_many = U.clone(full); too_many[257] = ''
raises(function() D.validate(page(nil, too_many, 0, 10000, 1048576)) end, '257 lines are refused before copying')
raises(function() D.validate(page(nil, { string.rep('x', 65536), 'x' }, 0, 2, 65537)) end, 'Aggregate page content cannot exceed 64 KiB')
for _, patch in ipairs({ { start_line = -1 }, { start_line = 16 }, { total_lines = 10001 }, { total_lines = 0 },
  { total_bytes = 1048577 }, { total_bytes = 0 }, { start_line = 1.5 }, { total_bytes = math.huge },
  { encoding = 'UTF-8' }, { contract_version = 1 }, { extra = true } }) do
  local invalid = U.clone(source); for key, value in pairs(patch) do invalid[key] = value end
  raises(function() D.validate(invalid) end, 'Invalid page scope, schema or encoding refused')
end
check(D.validate(page(nil, { '' }, 9999, 10000, 0)).total_bytes == 0, 'A nonempty page array may contain an empty final document line')
for _, invalid in ipairs({ '', 'x\ny', 'x\ry', 'x\0y', string.rep('x', 4097), string.char(192, 128), string.char(240, 159) }) do
  raises(function() D.search(source, invalid) end, 'Invalid literal search text refused')
  raises(function() D.prepare_replace(source, { find = invalid, replace = '' }) end, 'Invalid literal find text refused')
end
for _, invalid in ipairs({ 'x\ny', 'x\ry', 'x\0y', string.rep('x', 65537), string.char(128) }) do
  raises(function() D.prepare_replace(source, { find = '한', replace = invalid }) end, 'Invalid replacement text refused')
end
for _, invalid in ipairs({ 0, 201, 1.5, math.huge }) do
  raises(function() D.search(source, '한', { limit = invalid }) end, 'Invalid paged search result bound refused')
end
raises(function() D.search(source, '한', { callback = function() end }) end, 'Paged search has no callback option')
raises(function() D.search(source, '한', false) end, 'Explicit false is not silently treated as absent search options')
raises(function() D.prepare_replace(source, { find = '한', replace = '', extra = true }) end, 'Replacement schema is strict')
local matches = {}; for index = 1, 64 do matches[index] = string.rep('x', 64) end
local max_plan = D.prepare_replace(page(nil, matches, 0), { find = 'x', replace = '' })
check(max_plan.match_count == 4096 and #J.encode(max_plan) <= 524288, 'Exactly 4096 compact edits can fit the plan budget')
local more = U.clone(matches); more[65] = 'x'
raises(function() D.prepare_replace(page(nil, more, 0), { find = 'x', replace = '' }) end, '4097 replacement edits are refused')
raises(function() D.prepare_replace(page(nil, { 'xx' }, 0), { find = 'x', replace = string.rep('z', 40000) }) end,
  'Rendered lines cannot grow past the 64 KiB line limit')
raises(function() D.prepare_replace(page(nil, { 'x', 'x', 'x', 'x', 'x' }, 0), { find = 'x', replace = string.rep('z', 65536) }) end,
  'Rendered page output cannot exceed 256 KiB')
raises(function() D.prepare_replace(page(nil, { 'x' }, 0), { find = 'x', replace = string.rep('\1', 65536) }) end,
  'JSON escaping is included in the exact compact plan budget')
local enormous = U.clone(plan)
enormous.edits, enormous.match_count = {}, 4096
local repeated = U.clone(plan.edits[1]); repeated.text = string.rep('\1', 65536)
for index = 1, 4096 do enormous.edits[index] = repeated end
local valid_utf8, inspected = J.valid_utf8, 0
J.valid_utf8 = function(value) inspected = inspected + 1; return valid_utf8(value) end
local accepted = pcall(D.apply, source, enormous)
J.valid_utf8 = valid_utf8
check(not accepted and inspected < 30, 'Direct Lua oversized plans are refused before inspecting all repeated large edit strings')
check(#J.encode({ page = source, plan = plan }) <= 1048576 and #J.encode({ ok = true, value = D.apply(source, plan) }) <= 1048576,
  'Prepared plans fit both exact Apply input and response envelopes')
local previous = V1.prepare_replace({ uri = source.uri, revision = source.revision, encoding = 'utf-8', lines = { 'x' } },
  { find = 'x', replace = 'y' })
check(V1.contract_version == 1 and previous.original_lines[1] == 'x' and previous.next_lines[1] == 'y',
  'The original v1 schema and preview shape remain unchanged')
raises(function() V1.validate(source) end, 'V1 still rejects new page fields instead of silently adopting v2')
require('command_environment.core.bridge')
ce_bridge_init('document-page-contract')
local before = J.decode(ce_bridge('snapshot', '{}')).value
local capabilities = J.decode(ce_bridge('document_page_capabilities', '{}'))
check(capabilities.ok and capabilities.value.contract_version == 2, 'Protocol 1 discovers additive page capabilities')
local search = J.decode(ce_bridge('document_page_search', J.encode({ page = source, query = '한😀', options = { limit = 1 } })))
check(search.ok and search.value.truncated and search.value.locations[1].range.start.line == 14, 'Bridge uses absolute paged search positions')
local prepared = J.decode(ce_bridge('document_page_prepare_replace', J.encode({ page = source, find = '한😀', replace = 'B' })))
check(prepared.ok and prepared.value.match_count == 2 and prepared.value.next_lines == nil, 'Bridge transports compact edit plans')
local applied = J.decode(ce_bridge('document_page_apply', J.encode({ page = source, plan = prepared.value })))
check(applied.ok, 'Bridge accepts exactly regenerated reviewed page edits')
equal({ 'ABBB', '😀한', '' }, applied.value, 'Native transport and in-process page rendering share the same meaning')
prepared.value.edits[1].text = 'tampered'
check(not J.decode(ce_bridge('document_page_apply', J.encode({ page = source, plan = prepared.value }))).ok,
  'Bridge returns ordinary protocol failure for plan tampering')
check(not J.decode(ce_bridge('document_page_apply', J.encode({ page = source, plan = plan, extra = true }))).ok,
  'The additive Apply request accepts exactly page and plan fields')
check(not J.decode(ce_bridge('document_page_capabilities', '[]')).ok,
  'Capability discovery request is a strict empty object rather than an array')
equal(before, J.decode(ce_bridge('snapshot', '{}')).value, 'Page operations never change engine navigation, registry or pending requests')
print('Stateless paged document contract: ' .. checks .. ' checks PASS; no editor API; ' .. _VERSION)
