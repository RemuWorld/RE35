-- Shared document data contract. Hosts own snapshots, revisions, and writes.
-- Lua 5.1; no editor, filesystem, callbacks, or external object dependency.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local M = { contract_version = 1 }
local MAX_LINES, MAX_INPUT, MAX_OUTPUT = 2000, 262144, 1048576
local MAX_MATCHES, MAX_QUERY = 1000, 4096
local encodings = { ['utf-8'] = true, ['utf-16'] = true, ['utf-32'] = true }

local function object(value, fields, label)
  assert(type(value) == 'table', label .. ' must be an object')
  local kind, mt = U.kind(value), getmetatable(value)
  assert(mt == nil or kind == 'object', label .. ' must be plain object data')
  local count = 0
  for key in next, value do
    count = count + 1
    assert(count <= fields.count and fields[key] == true, 'Unknown ' .. label .. ' field')
  end
  return value
end
local function text(value, label, maximum, nonempty, single_line)
  assert(type(value) == 'string' and #value <= maximum and (not nonempty or #value > 0),
    label .. ' exceeds its text bounds')
  assert(J.valid_utf8(value), label .. ' must be valid UTF-8')
  if single_line then assert(not value:find('[\r\n%z]'), label .. ' must be single-line text without NUL') end
  return value
end
local function lines(value, maximum)
  assert(type(value) == 'table' and (getmetatable(value) == nil or U.kind(value) == 'array'),
    'Document lines must be a dense array')
  local count = 0
  for key in next, value do
    count = count + 1
    assert(count <= MAX_LINES and type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= MAX_LINES,
      'Document lines exceed the dense array bounds')
  end
  local result, bytes = U.array(), 0
  for index = 1, count do
    local line = rawget(value, index)
    assert(type(line) == 'string', 'Document lines must be dense strings')
    bytes = bytes + #line
    assert(bytes <= maximum, 'Document lines exceed the byte limit')
    result[index] = text(line, 'Document line', maximum, false, true)
  end
  return result
end
local snapshot_fields = { count = 4, uri = true, revision = true, encoding = true, lines = true }
function M.validate(snapshot)
  object(snapshot, snapshot_fields, 'document snapshot')
  local uri = text(snapshot.uri, 'Document URI', 4096, true)
  assert(uri:match('^[A-Za-z][A-Za-z0-9+%.%-]*:.+') and not uri:find('[%z\1-\32\127\\]'),
    'Document URI must be an absolute URI without spaces, controls, or backslashes')
  local revision = text(snapshot.revision, 'Document revision', 1024, true)
  assert(encodings[snapshot.encoding], 'Document encoding must be utf-8, utf-16, or utf-32')
  return { uri = uri, revision = revision, encoding = snapshot.encoding, lines = lines(snapshot.lines, MAX_INPUT) }
end

-- A valid UTF-8 leading byte gives the code point width. UTF-16 uses two
-- character units only for four-byte UTF-8 code points, including emoji.
local function advance(line, byte, finish, units, encoding)
  if encoding == 'utf-8' then return finish, finish - 1 end
  while byte < finish do
    local lead = line:byte(byte)
    local width = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
    units = units + (encoding == 'utf-16' and width == 4 and 2 or 1)
    byte = byte + width
  end
  assert(byte == finish, 'Document range must end on a UTF-8 boundary')
  return byte, units
end
local function scan(snapshot, query, callback)
  for index, line in ipairs(snapshot.lines) do
    local start, byte, units = 1, 1, 0
    while true do
      local first, last = line:find(query, start, true)
      if not first then break end
      local first_units
      byte, units = advance(line, byte, first, units, snapshot.encoding)
      first_units = units
      byte, units = advance(line, byte, last + 1, units, snapshot.encoding)
      local range = { start = { line = index - 1, character = first_units },
        ['end'] = { line = index - 1, character = units } }
      if callback(index, line, first, last, range) == false then return end
      start = last + 1
    end
  end
end
local function json_text_bytes(value)
  -- Exact quoted UTF-8 byte length, without constructing an escaped copy.
  local bytes = #value + 2
  for control in value:gmatch('[%z\1-\31\\"]') do
    bytes = bytes + ((control == '\b' or control == '\f' or control == '\n'
      or control == '\r' or control == '\t' or control == '\\' or control == '"') and 1 or 5)
  end
  return bytes
end
local function integer(value, minimum, maximum, label)
  assert(type(value) == 'number' and value == value and value % 1 == 0 and value >= minimum and value <= maximum,
    label .. ' is outside its integer bounds')
  return value
end
local options_fields = { count = 1, limit = true }
function M.search(snapshot, query, options)
  snapshot = M.validate(snapshot)
  query = text(query, 'Document query', MAX_QUERY, true, true)
  options = options or {}
  object(options, options_fields, 'document search options')
  local limit = integer(options.limit == nil and 200 or options.limit, 1, MAX_MATCHES, 'Search limit')
  local result = { contract_version = 1, uri = snapshot.uri, revision = snapshot.revision,
    encoding = snapshot.encoding, locations = U.array(), truncated = false }
  -- The JSON bridge has a 1 MiB payload boundary. Reserve the envelope and
  -- range keys, so repeating a long source line cannot build an unbounded reply.
  local bytes = #J.encode(result)
  scan(snapshot, query, function(_, line, _, _, range)
    local cost = json_text_bytes(line) + json_text_bytes(snapshot.uri)
      + json_text_bytes(snapshot.revision) + 256
    if #result.locations == limit or bytes + cost > MAX_OUTPUT then
      result.truncated = true
      return false
    end
    result.locations[#result.locations + 1] = { uri = snapshot.uri, revision = snapshot.revision,
      encoding = snapshot.encoding, range = range, text = line }
    bytes = bytes + cost
  end)
  return result
end

local replace_fields = { count = 2, find = true, replace = true }
function M.prepare_replace(snapshot, specification)
  snapshot = M.validate(snapshot)
  object(specification, replace_fields, 'document replacement')
  local find = text(specification.find, 'Replacement find', MAX_QUERY, true, true)
  local replace = text(specification.replace, 'Replacement text', MAX_INPUT, false, true)
  local plan = { contract_version = 1, uri = snapshot.uri, revision = snapshot.revision,
    encoding = snapshot.encoding, find = find, replace = replace, match_count = 0,
    edits = U.array(), original_lines = snapshot.lines, next_lines = U.array() }
  local chunks, positions, output_bytes = {}, {}, 0
  for index, line in ipairs(snapshot.lines) do output_bytes = output_bytes + #line; chunks[index], positions[index] = {}, 1 end
  scan(snapshot, find, function(index, line, first, last, range)
    plan.match_count = plan.match_count + 1
    assert(plan.match_count <= MAX_MATCHES, 'Replacement exceeds the 1000 match limit')
    output_bytes = output_bytes + #replace - #find
    assert(output_bytes <= MAX_OUTPUT, 'Replacement output exceeds the 1 MiB limit')
    local pieces = chunks[index]
    pieces[#pieces + 1], pieces[#pieces + 2] = line:sub(positions[index], first - 1), replace
    positions[index] = last + 1
    plan.edits[#plan.edits + 1] = { range = range, text = replace, old_text = find }
  end)
  for index, line in ipairs(snapshot.lines) do
    local pieces = chunks[index]
    pieces[#pieces + 1] = line:sub(positions[index])
    plan.next_lines[index] = table.concat(pieces)
  end
  -- Bounds the complete Apply round trip. A prepared artifact must remain
  -- transportable together with the current snapshot through Protocol 1.
  J.encode({ snapshot = snapshot, plan = plan })
  return plan
end
local plan_fields = { count = 10, contract_version = true, uri = true, revision = true, encoding = true,
  find = true, replace = true, match_count = true, edits = true, original_lines = true, next_lines = true }
local function same_data(actual, expected)
  if type(actual) ~= type(expected) then return false end
  if type(expected) ~= 'table' then return actual == expected end
  local kind, marker = U.kind(actual), U.kind(expected)
  if getmetatable(actual) ~= nil and kind ~= 'array' and kind ~= 'object' then return false end
  if marker == 'array' and kind == 'object' or marker ~= 'array' and kind == 'array' then return false end
  local count = 0
  for key, value in next, expected do
    count = count + 1
    if not same_data(rawget(actual, key), value) then return false end
  end
  local actual_count = 0
  for key in next, actual do
    actual_count = actual_count + 1
    if actual_count > count or rawget(expected, key) == nil then return false end
  end
  return actual_count == count
end
function M.apply(snapshot, plan)
  snapshot = M.validate(snapshot)
  object(plan, plan_fields, 'document replacement plan')
  assert(plan.uri == snapshot.uri and plan.revision == snapshot.revision and plan.encoding == snapshot.encoding,
    'Document replacement plan target is stale')
  local expected = M.prepare_replace(snapshot, { find = plan.find, replace = plan.replace })
  assert(same_data(plan, expected), 'Document replacement plan content changed or was tampered with')
  return expected.next_lines
end
return M
