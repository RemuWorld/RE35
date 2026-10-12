-- Stateless complete-line pages. Hosts own captures, completeness and writes.
-- Lua 5.1; the core never retains a page, performs I/O or measures host time.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 2 }
local L = {
  max_document_lines = 10000, max_document_bytes = 1048576,
  max_page_lines = 256, max_page_bytes = 65536, max_line_bytes = 65536,
  max_matches = 4096, max_search_results = 200, max_plan_bytes = 524288,
  max_output_bytes = 1048576, max_page_output_bytes = 262144,
  max_query_bytes = 4096, max_replacement_bytes = 65536,
  processing_timeout_ms = 5000, max_excerpt_bytes = 1024,
}
local encodings = { ['utf-8'] = true, ['utf-16'] = true, ['utf-32'] = true }
local function object(value, fields, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'object'),
    label .. ' must be plain object data')
  local count = 0
  for key in next, value do
    count = count + 1
    assert(count <= fields.count and fields[key] == true, 'Unknown ' .. label .. ' field')
  end
  return value
end
local function integer(value, minimum, maximum, label)
  assert(type(value) == 'number' and value == value and value % 1 == 0
    and value >= minimum and value <= maximum, label .. ' is outside its integer bounds')
  return value
end
local function text(value, label, maximum, nonempty, single_line)
  assert(type(value) == 'string' and #value <= maximum and (not nonempty or #value > 0),
    label .. ' exceeds its text bounds')
  assert(J.valid_utf8(value), label .. ' must be valid UTF-8')
  if single_line then assert(not value:find('[\r\n%z]'), label .. ' must be single-line text without NUL') end
  return value
end
local function dense(value, maximum, minimum, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'array'),
    label .. ' must be a dense array')
  local count = 0
  for key in next, value do
    count = count + 1
    assert(count <= maximum and type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= maximum,
      label .. ' exceeds its dense array bounds')
  end
  assert(count >= minimum, label .. ' must contain at least ' .. minimum .. ' entries')
  for index = 1, count do assert(rawget(value, index) ~= nil, label .. ' must be dense') end
  return count
end
local page_fields = { count = 8, contract_version = true, uri = true, revision = true, encoding = true,
  start_line = true, total_lines = true, total_bytes = true, lines = true }
function M.validate(page)
  object(page, page_fields, 'document page')
  assert(page.contract_version == 2, 'Document page must use contract version 2')
  local uri = text(page.uri, 'Document URI', 4096, true)
  assert(uri:match('^[A-Za-z][A-Za-z0-9+%.%-]*:.+') and not uri:find('[%z\1-\32\127\\]'),
    'Document URI must be an absolute URI without spaces, controls, or backslashes')
  local revision = text(page.revision, 'Document revision', 1024, true)
  assert(encodings[page.encoding], 'Document encoding must be utf-8, utf-16, or utf-32')
  local total_lines = integer(page.total_lines, 1, L.max_document_lines, 'Document total lines')
  local total_bytes = integer(page.total_bytes, 0, L.max_document_bytes, 'Document total bytes')
  local start_line = integer(page.start_line, 0, total_lines - 1, 'Document page start line')
  local count = dense(page.lines, L.max_page_lines, 1, 'Document page lines')
  assert(start_line + count <= total_lines, 'Document page exceeds the declared line scope')
  local result, bytes = U.array(), 0
  for index = 1, count do
    local line = text(rawget(page.lines, index), 'Document line', L.max_line_bytes, false, true)
    bytes = bytes + #line
    assert(bytes <= L.max_page_bytes and bytes <= total_bytes, 'Document page exceeds its byte scope')
    result[index] = line
  end
  return { contract_version = 2, uri = uri, revision = revision, encoding = page.encoding,
    start_line = start_line, total_lines = total_lines, total_bytes = total_bytes, lines = result }
end
function M.capabilities()
  -- Whole-document aggregation and timeout are host obligations, not proof
  -- that this stateless call saw every page or cancelled an executing host.
  local limits = {}; for key, value in next, L do limits[key] = value end
  return { contract_version = 2, limits = limits, operations = U.array({ 'search', 'prepare_replace', 'apply' }) }
end
local function advance(line, byte, finish, units, encoding)
  if encoding == 'utf-8' then return finish, finish - 1 end
  while byte < finish do
    local lead = line:byte(byte)
    local width = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
    units, byte = units + (encoding == 'utf-16' and width == 4 and 2 or 1), byte + width
  end
  assert(byte == finish, 'Document range must end on a UTF-8 boundary')
  return byte, units
end
local function scan(page, query, callback)
  for index, line in ipairs(page.lines) do
    local start, byte, units = 1, 1, 0
    while true do
      local first, last = line:find(query, start, true)
      if not first then break end
      byte, units = advance(line, byte, first, units, page.encoding)
      local first_units = units
      byte, units = advance(line, byte, last + 1, units, page.encoding)
      local absolute = page.start_line + index - 1
      local range = { start = { line = absolute, character = first_units },
        ['end'] = { line = absolute, character = units } }
      if callback(index, line, first, last, range) == false then return end
      start = last + 1
    end
  end
end
local function excerpt(line, first)
  local start = math.max(1, first - 256)
  while start < first and line:byte(start) >= 128 and line:byte(start) < 192 do start = start + 1 end
  local finish = math.min(#line + 1, start + L.max_excerpt_bytes)
  while finish <= #line and line:byte(finish) >= 128 and line:byte(finish) < 192 do finish = finish - 1 end
  return line:sub(start, finish - 1)
end
local options_fields = { count = 1, limit = true }
function M.search(page, query, options)
  page = M.validate(page)
  query = text(query, 'Document query', L.max_query_bytes, true, true)
  if options == nil then options = {} end
  object(options, options_fields, 'document search options')
  local limit = integer(options.limit == nil and L.max_search_results or options.limit,
    1, L.max_search_results, 'Search limit')
  local result = { contract_version = 2, uri = page.uri, revision = page.revision, encoding = page.encoding,
    start_line = page.start_line, total_lines = page.total_lines, total_bytes = page.total_bytes,
    locations = U.array(), truncated = false }
  scan(page, query, function(_, line, first, _, range)
    if #result.locations == limit then result.truncated = true; return false end
    result.locations[#result.locations + 1] = { range = range, text = excerpt(line, first) }
  end)
  J.encode({ ok = true, value = result })
  return result
end
local replace_fields = { count = 2, find = true, replace = true }
local function prepare(page, specification)
  object(specification, replace_fields, 'document replacement')
  local find = text(specification.find, 'Replacement find', L.max_query_bytes, true, true)
  local replace = text(specification.replace, 'Replacement text', L.max_replacement_bytes, false, true)
  local plan = { contract_version = 2, uri = page.uri, revision = page.revision, encoding = page.encoding,
    start_line = page.start_line, total_lines = page.total_lines, total_bytes = page.total_bytes,
    line_count = #page.lines, find = find, replace = replace, match_count = 0,
    edits = U.array(), output_bytes = 0 }
  local output, positions, chunks, line_bytes = U.array(), {}, {}, {}
  for index, line in ipairs(page.lines) do
    plan.output_bytes = plan.output_bytes + #line
    positions[index], chunks[index], line_bytes[index] = 1, {}, #line
  end
  local encoded_bytes = #J.encode(plan)
  scan(page, find, function(index, line, first, last, range)
    local before_count, before_bytes = plan.match_count, plan.output_bytes
    plan.match_count = plan.match_count + 1
    assert(plan.match_count <= L.max_matches, 'Replacement exceeds the 4096 edit limit')
    local delta = #replace - #find
    plan.output_bytes, line_bytes[index] = plan.output_bytes + delta, line_bytes[index] + delta
    assert(plan.output_bytes <= L.max_page_output_bytes, 'Replacement page output exceeds the 256 KiB limit')
    assert(line_bytes[index] <= L.max_line_bytes, 'Replacement line exceeds the 64 KiB limit')
    local edit = { range = range, text = replace, old_text = find }
    encoded_bytes = encoded_bytes + #J.encode(edit) + (plan.match_count > 1 and 1 or 0)
      + #tostring(plan.match_count) - #tostring(before_count)
      + #tostring(plan.output_bytes) - #tostring(before_bytes)
    assert(encoded_bytes <= L.max_plan_bytes, 'Replacement plan exceeds the 512 KiB JSON limit')
    plan.edits[#plan.edits + 1] = edit
    local pieces = chunks[index]
    pieces[#pieces + 1], pieces[#pieces + 2] = line:sub(positions[index], first - 1), replace
    positions[index] = last + 1
  end)
  for index, line in ipairs(page.lines) do
    local pieces = chunks[index]; pieces[#pieces + 1] = line:sub(positions[index])
    output[index] = table.concat(pieces)
  end
  assert(#J.encode(plan) <= L.max_plan_bytes, 'Replacement plan exceeds the 512 KiB JSON limit')
  -- Exact transport boundaries include escaping and metadata. A page which is
  -- individually valid is not automatically a transportable Apply request.
  J.encode({ page = page, plan = plan })
  J.encode({ ok = true, value = plan })
  J.encode({ ok = true, value = output })
  return plan, output
end
function M.prepare_replace(page, specification)
  page = M.validate(page)
  local plan = prepare(page, specification)
  return plan
end
local plan_fields = { count = 13, contract_version = true, uri = true, revision = true, encoding = true,
  start_line = true, total_lines = true, total_bytes = true, line_count = true,
  find = true, replace = true, match_count = true, edits = true, output_bytes = true }
local edit_fields = { count = 3, range = true, text = true, old_text = true }
local range_fields = { count = 2, start = true, ['end'] = true }
local position_fields = { count = 2, line = true, character = true }
local function checked_plan(plan)
  object(plan, plan_fields, 'document replacement plan')
  assert(plan.contract_version == 2 and encodings[plan.encoding], 'Invalid document plan contract or encoding')
  text(plan.uri, 'Plan URI', 4096, true)
  text(plan.revision, 'Plan revision', 1024, true)
  integer(plan.start_line, 0, L.max_document_lines - 1, 'Plan start line')
  integer(plan.total_lines, 1, L.max_document_lines, 'Plan total lines')
  integer(plan.total_bytes, 0, L.max_document_bytes, 'Plan total bytes')
  integer(plan.line_count, 1, L.max_page_lines, 'Plan line count')
  integer(plan.match_count, 0, L.max_matches, 'Plan match count')
  integer(plan.output_bytes, 0, L.max_page_output_bytes, 'Plan output bytes')
  text(plan.find, 'Plan find', L.max_query_bytes, true, true)
  text(plan.replace, 'Plan replacement', L.max_replacement_bytes, false, true)
  local count = dense(plan.edits, L.max_matches, 0, 'Document edits')
  local header = {}
  for key in next, plan do header[key] = key == 'edits' and U.array() or rawget(plan, key) end
  local encoded_bytes = #J.encode(header)
  assert(encoded_bytes <= L.max_plan_bytes, 'Replacement plan exceeds the 512 KiB JSON limit')
  for index = 1, count do
    local edit = object(rawget(plan.edits, index), edit_fields, 'document edit')
    text(edit.text, 'Edit replacement', L.max_replacement_bytes, false, true)
    text(edit.old_text, 'Edit original text', L.max_query_bytes, true, true)
    local range = object(edit.range, range_fields, 'document edit range')
    for _, key in ipairs({ 'start', 'end' }) do
      local position = object(rawget(range, key), position_fields, 'document position')
      integer(position.line, 0, L.max_document_lines - 1, 'Document position line')
      integer(position.character, 0, L.max_line_bytes, 'Document position character')
    end
    -- Refuse oversized direct Lua data incrementally, before inspecting every
    -- repeated large replacement or serializing the entire foreign plan.
    encoded_bytes = encoded_bytes + #J.encode(edit) + (index > 1 and 1 or 0)
    assert(encoded_bytes <= L.max_plan_bytes, 'Replacement plan exceeds the 512 KiB JSON limit')
  end
end
local function same(actual, expected)
  if type(actual) ~= type(expected) then return false end
  if type(expected) ~= 'table' then return actual == expected end
  local kind, marker = U.kind(actual), U.kind(expected)
  if getmetatable(actual) ~= nil and kind ~= 'array' and kind ~= 'object' then return false end
  if marker == 'array' and kind == 'object' or marker ~= 'array' and kind == 'array' then return false end
  local count, actual_count = 0, 0
  for key, value in next, expected do
    count = count + 1
    if not same(rawget(actual, key), value) then return false end
  end
  for key in next, actual do
    actual_count = actual_count + 1
    if actual_count > count or rawget(expected, key) == nil then return false end
  end
  return actual_count == count
end
function M.apply(page, plan)
  page = M.validate(page)
  checked_plan(plan)
  assert(plan.uri == page.uri and plan.revision == page.revision and plan.encoding == page.encoding
    and plan.start_line == page.start_line and plan.total_lines == page.total_lines
    and plan.total_bytes == page.total_bytes and plan.line_count == #page.lines,
    'Document replacement plan target is stale')
  local expected, output = prepare(page, { find = plan.find, replace = plan.replace })
  assert(same(plan, expected), 'Document replacement plan content changed or was tampered with')
  -- Validate supplied data, not only the regenerated copy, before returning.
  assert(#J.encode(plan) <= L.max_plan_bytes, 'Replacement plan exceeds the 512 KiB JSON limit')
  J.encode({ page = page, plan = plan })
  return output
end
return M
