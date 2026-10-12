-- The same fixture can run through tests/run.py or ordinary Lua 5.1:
-- lua tests/test_document_contract.lua /absolute/path/to/RE35
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local D = require('command_environment.core.document')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label)
  check(U.deep_equal(J.decode(J.encode(expected)), J.decode(J.encode(actual))), label)
end
local function raises(callback, label) check(not pcall(callback), label) end
local function snapshot(encoding, content)
  return { uri = 'file:///project/%ED%95%9C.cpp', revision = 'host:17', encoding = encoding or 'utf-8',
    lines = content or { 'A한😀B한😀', '😀한', '' } }
end
local source = snapshot()
local detached = D.validate(source)
detached.lines[1] = 'changed copy'
check(source.lines[1] == 'A한😀B한😀', 'Validation detaches line data without editing the source')
check(D.contract_version == 1 and vim == nil, 'Document contract runs without an editor API')
local expected = {
  ['utf-8'] = { { 1, 8 }, { 9, 16 } },
  ['utf-16'] = { { 1, 4 }, { 5, 8 } },
  ['utf-32'] = { { 1, 3 }, { 4, 6 } },
}
for encoding, bounds in pairs(expected) do
  local document = snapshot(encoding)
  local result = D.search(document, '한😀')
  check(result.contract_version == 1 and result.uri == document.uri and result.revision == document.revision
    and result.encoding == encoding and #result.locations == 2 and not result.truncated, encoding .. ' result identity')
  for index, position in ipairs(bounds) do
    local location = result.locations[index]
    equal({ start = { line = 0, character = position[1] }, ['end'] = { line = 0, character = position[2] } },
      location.range, encoding .. ' zero-based end-exclusive Korean and emoji positions')
    check(location.text == document.lines[1] and location.uri == document.uri
      and location.revision == document.revision and location.encoding == encoding, encoding .. ' source location identity')
  end
  local emoji = D.search(document, '😀').locations[3]
  check(emoji.range.start.line == 1 and emoji.range.start.character == 0
    and emoji.range['end'].character == (encoding == 'utf-8' and 4 or encoding == 'utf-16' and 2 or 1),
    encoding .. ' beginning-of-line supplementary code point boundary')
  local plan = D.prepare_replace(document, { find = '한😀', replace = '🧩한' })
  check(plan.contract_version == 1 and plan.match_count == 2, encoding .. ' replacement review counts matches')
  equal(result.locations[1].range, plan.edits[1].range, encoding .. ' edit range agrees with search')
  check(plan.edits[1].old_text == '한😀' and plan.edits[1].text == '🧩한', encoding .. ' review includes exact before and after text')
  equal({ 'A🧩한B🧩한', '😀한', '' }, plan.next_lines, encoding .. ' preview performs literal replacement only')
  equal(document.lines, plan.original_lines, encoding .. ' review retains original document content')
  equal(document.lines, snapshot(encoding).lines, encoding .. ' search and preparation have no write side effects')
  local applied = D.apply(document, J.decode(J.encode(plan)))
  equal(plan.next_lines, applied, encoding .. ' transported plan applies identically')
  applied[1] = 'changed returned copy'
  check(plan.next_lines[1] == 'A🧩한B🧩한' and document.lines[1] == 'A한😀B한😀', encoding .. ' apply returns detached lines')
end
local literal = snapshot(nil, { 'a.b % [x]', 'aaa' })
check(#D.search(literal, '.').locations == 1, 'Search does not interpret Lua patterns')
equal({ 'a.b % [x]', 'Xa' }, D.prepare_replace(literal, { find = 'aa', replace = 'X' }).next_lines,
  'Replacement uses non-overlapping matches')
equal({ '%1%1%1' }, D.prepare_replace(snapshot(nil, { 'aaa' }), { find = 'a', replace = '%1' }).next_lines,
  'Replacement text does not interpret captures or pattern substitution syntax')
local one = D.search(source, '한', { limit = 1 })
check(#one.locations == 1 and one.truncated, 'Search reports truncation when additional matches exist')
check(not D.search(snapshot(nil, { '한' }), '한', { limit = 1 }).truncated, 'Exact search limit does not imply truncation')
local empty = snapshot(nil, {})
check(#D.search(empty, 'x').locations == 0 and not D.search(empty, 'x').truncated, 'Empty snapshots retain empty result arrays')
equal(U.array(), D.apply(empty, D.prepare_replace(empty, { find = 'x', replace = '' })), 'Empty replacement plan round-trips')
equal(source.lines, D.apply(source, D.prepare_replace(source, { find = 'not found', replace = '' })), 'No matches is a valid reviewed no-op')
local plan = D.prepare_replace(source, { find = '한', replace = '' })
for _, field in ipairs({ 'uri', 'revision', 'encoding' }) do
  local stale = U.clone(source)
  stale[field] = field == 'uri' and 'untitled:other' or field == 'encoding' and 'utf-16' or 'host:18'
  raises(function() D.apply(stale, plan) end, 'Changed ' .. field .. ' rejects reviewed writes')
end
local changed = U.clone(source); changed.lines[1] = 'Different content despite unchanged revision'
raises(function() D.apply(changed, plan) end, 'Content drift rejects writes even if host revision stayed unchanged')
local tamperers = {
  function(p) p.next_lines[1] = 'injected' end,
  function(p) p.original_lines[1] = 'injected' end,
  function(p) p.edits[1].range.start.character = 2 end,
  function(p) p.edits[1].text = 'injected' end,
  function(p) p.edits[1].old_text = 'injected' end,
  function(p) p.edits[1].extra = true end,
  function(p) p.match_count = 0 end,
  function(p) p.contract_version = 2 end,
  function(p) p.extra = true end,
  function(p) p.next_lines[2001] = 'oversized sparse data' end,
  function(p) p.edits[1].range.start.extra = p end,
}
for index, tamper in ipairs(tamperers) do
  local bad = U.clone(plan); tamper(bad)
  raises(function() D.apply(source, bad) end, 'Review plan tampering rejected: ' .. index)
end
local called = false
local callback_data = setmetatable({}, { __index = function() called = true; return source.lines end,
  __pairs = function() called = true; error('must not execute') end })
raises(function() D.validate(callback_data) end, 'Foreign metatables cannot enter the document contract')
check(not called, 'Malformed document validation never invokes foreign callbacks')
local unknown_snapshot = snapshot(); unknown_snapshot.count = 1
raises(function() D.validate(unknown_snapshot) end, 'Snapshot schemas reject internal-looking unknown fields')
raises(function() D.search(source, '한', { count = 1 }) end, 'Search option schemas reject internal-looking unknown fields')
raises(function() D.prepare_replace(source, { find = '한', replace = '', count = 1 }) end,
  'Replacement schemas reject internal-looking unknown fields')
for _, invalid in ipairs({ string.char(192, 128), string.char(237, 160, 128), string.char(244, 144, 128, 128),
  string.char(240, 159), string.char(128), string.char(224, 128, 128) }) do
  raises(function() D.validate(snapshot(nil, { invalid })) end, 'Reject malformed UTF-8 snapshot')
  raises(function() D.search(source, invalid) end, 'Reject malformed UTF-8 query')
  raises(function() D.prepare_replace(source, { find = '한', replace = invalid }) end, 'Reject malformed UTF-8 replacement')
end
for _, bad in ipairs({ '', 'x\ny', 'x\ry', 'x\0y', string.rep('a', 4097) }) do
  raises(function() D.search(source, bad) end, 'Reject invalid literal query')
  raises(function() D.prepare_replace(source, { find = bad, replace = 'x' }) end, 'Reject invalid find text')
end
for _, bad in ipairs({ 'x\ny', 'x\ry', 'x\0y', string.rep('a', 262145) }) do
  raises(function() D.prepare_replace(source, { find = '한', replace = bad }) end, 'Reject invalid replacement text')
end
for _, bad in ipairs({ 'utf8', 'UTF-8', 'bytes', '' }) do
  local document = snapshot(); document.encoding = bad
  raises(function() D.validate(document) end, 'Reject unspecified character encodings')
end
for _, bad in ipairs({ '', 'relative/file.cpp', 'C:\\source.cpp', 'file:///has space', 'file:///nul\0', string.rep('u', 4097) }) do
  local document = snapshot(); document.uri = bad
  raises(function() D.validate(document) end, 'Reject invalid absolute URI')
end
local identity = snapshot(); identity.uri = 'file:///a/../b.cpp'
check(D.validate(identity).uri == identity.uri, 'The core preserves host URI identity without filesystem normalization')
for _, bad in ipairs({ '', string.rep('r', 1025) }) do
  local document = snapshot(); document.revision = bad
  raises(function() D.validate(document) end, 'Reject unbounded or empty opaque revision')
end
for _, content in ipairs({ { 'x\ny' }, { 'x\ry' }, { 'x\0y' }, { [2] = 'sparse' }, { extra = 'object' },
  { string.rep('x', 262145) } }) do
  raises(function() D.validate(snapshot(nil, content)) end, 'Reject malformed or oversized snapshot lines')
end
local many_lines = {}; for index = 1, 2001 do many_lines[index] = '' end
raises(function() D.validate(snapshot(nil, many_lines)) end, 'Reject more than 2000 lines before copying')
local maximum = {}; for index = 1, 2000 do maximum[index] = '' end
check(#D.validate(snapshot(nil, maximum)).lines == 2000, 'Exactly 2000 lines is supported')
check(#D.validate(snapshot(nil, { string.rep('x', 262144) })).lines[1] == 262144, 'Exactly 256 KiB input is supported')
for _, limit in ipairs({ 0, 1001, 1.5, math.huge }) do raises(function() D.search(source, '한', { limit = limit }) end, 'Reject invalid search bounds') end
raises(function() D.search(source, '한', { callback = function() end }) end, 'Search has no callback extension surface')
local default_limit = D.search(snapshot(nil, { string.rep('x', 201) }), 'x')
check(#default_limit.locations == 200 and default_limit.truncated, 'Default search limits 200 locations')
local long_line = string.rep('x', 262144)
local bounded = D.search(snapshot(nil, { long_line }), 'x', { limit = 1000 })
check(#bounded.locations > 0 and #bounded.locations < 1000 and bounded.truncated and #J.encode(bounded) <= 1048576,
  'Long repeated source text cannot exceed the bridge output bound')
raises(function() D.prepare_replace(snapshot(nil, { string.rep('x', 1001) }), { find = 'x', replace = 'y' }) end,
  'Replacement refuses more than 1000 matches')
check(D.prepare_replace(snapshot(nil, { string.rep('x', 1000) }), { find = 'x', replace = '' }).match_count == 1000,
  'Exactly 1000 replacement matches is supported')
raises(function() D.prepare_replace(snapshot(nil, { 'xxxxx' }), { find = 'x', replace = string.rep('y', 262144) }) end,
  'Replacement refuses oversized rendered output')
raises(function() D.prepare_replace(snapshot(nil, { 'xxx' }), { find = 'x', replace = string.rep('y', 200000) }) end,
  'The entire review artifact must fit the 1 MiB bridge boundary')
local large_source = snapshot(nil, { 'x' .. string.rep('y', 240000) })
raises(function() D.prepare_replace(large_source, { find = 'x', replace = string.rep('z', 110000) }) end,
  'A prepared plan must fit the Apply request together with its source snapshot')
require('command_environment.core.bridge')
ce_bridge_init('document-contract')
local before = J.decode(ce_bridge('snapshot', '{}')).value
local search_reply = J.decode(ce_bridge('document_search', J.encode({ snapshot = source, query = '한😀', options = { limit = 1 } })))
check(search_reply.ok and search_reply.value.contract_version == 1 and search_reply.value.truncated, 'Bridge exposes shared search additively')
local review_reply = J.decode(ce_bridge('document_prepare_replace', J.encode({ snapshot = source, find = '한😀', replace = 'B' })))
check(review_reply.ok and review_reply.value.match_count == 2, 'Bridge exposes detached replacement review')
local apply_reply = J.decode(ce_bridge('document_apply', J.encode({ snapshot = source, plan = review_reply.value })))
equal({ 'ABBB', '😀한', '' }, apply_reply.value, 'Bridge applies the same shared replacement contract')
check(apply_reply.ok, 'Bridge confirms validated replacement data')
review_reply.value.next_lines[1] = 'tampered'
check(not J.decode(ce_bridge('document_apply', J.encode({ snapshot = source, plan = review_reply.value }))).ok,
  'Bridge reports tampered plans as ordinary protocol failures')
check(not J.decode(ce_bridge('document_search', J.encode({ snapshot = source, query = '' }))).ok,
  'Bridge reports malformed document input without executing anything')
equal(before, J.decode(ce_bridge('snapshot', '{}')).value, 'Document preview leaves registry, navigation, and operations unchanged')
print('Shared document contract: ' .. checks .. ' checks PASS; no editor API; ' .. _VERSION)
