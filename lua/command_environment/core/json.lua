-- Bounded UTF-8 JSON transport. Data only; no code evaluation or host APIs.
local U = require('command_environment.core.util')
local M = { max_bytes = 1048576, max_depth = 64, max_number = 9007199254740991 }
local function utf8(s)
  local i = 1
  while i <= #s do
    local b, n, low, high = s:byte(i), 0, 128, 191
    if b < 128 then n = 0
    elseif b >= 194 and b <= 223 then n = 1
    elseif b >= 224 and b <= 239 then n = 2; if b == 224 then low = 160 elseif b == 237 then high = 159 end
    elseif b >= 240 and b <= 244 then n = 3; if b == 240 then low = 144 elseif b == 244 then high = 143 end
    else return false end
    for j = 1, n do
      local c = s:byte(i + j)
      if not c or c < (j == 1 and low or 128) or c > (j == 1 and high or 191) then return false end
    end
    i = i + n + 1
  end
  return true
end
M.valid_utf8 = utf8
local function codepoint(n)
  if n < 128 then return string.char(n) end
  if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
  if n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64) end
  return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end
function M.decode(text)
  assert(type(text) == 'string' and #text <= M.max_bytes, 'JSON input exceeds the byte limit')
  assert(utf8(text), 'JSON input is not valid UTF-8')
  local pos = 1
  local function skip() local _, last = text:find('^[ \t\r\n]*', pos); pos = (last or pos - 1) + 1 end
  local function fail(message) error(message .. ' at JSON byte ' .. pos, 0) end
  local function hex()
    local raw = text:sub(pos, pos + 3)
    if #raw ~= 4 or not raw:match('^%x%x%x%x$') then fail('Invalid Unicode escape') end
    pos = pos + 4; return tonumber(raw, 16)
  end
  local function str()
    pos = pos + 1
    local chunks, begin = {}, pos
    while pos <= #text do
      local c = text:sub(pos, pos)
      if c == '"' then chunks[#chunks + 1] = text:sub(begin, pos - 1); pos = pos + 1; return table.concat(chunks) end
      if c == '\\' then
        chunks[#chunks + 1] = text:sub(begin, pos - 1); pos = pos + 1
        local esc = text:sub(pos, pos); pos = pos + 1
        local mapped = ({ ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' })[esc]
        if mapped then chunks[#chunks + 1] = mapped
        elseif esc == 'u' then
          local n = hex()
          if n >= 55296 and n <= 56319 then
            if text:sub(pos, pos + 1) ~= '\\u' then fail('Missing low surrogate') end
            pos = pos + 2; local low = hex()
            if low < 56320 or low > 57343 then fail('Invalid low surrogate') end
            n = 65536 + (n - 55296) * 1024 + low - 56320
          elseif n >= 56320 and n <= 57343 then fail('Unexpected low surrogate') end
          chunks[#chunks + 1] = codepoint(n)
        else fail('Invalid string escape') end
        begin = pos
      else if text:byte(pos) < 32 then fail('Unescaped control character') end; pos = pos + 1 end
    end
    fail('Unterminated string')
  end
  local parse
  parse = function(depth)
    if depth > M.max_depth then fail('JSON nesting exceeds the depth limit') end
    skip(); local c = text:sub(pos, pos)
    if c == '"' then return str() end
    if c == '{' or c == '[' then
      local object = c == '{'; local value = object and U.object() or U.array(); pos = pos + 1; skip()
      local closing = object and '}' or ']'
      if text:sub(pos, pos) == closing then pos = pos + 1; return value end
      while true do
        skip(); local key
        if object then
          if text:sub(pos, pos) ~= '"' then fail('Expected object key') end
          key = str(); if value[key] ~= nil then fail('Duplicate object key') end
          skip(); if text:sub(pos, pos) ~= ':' then fail('Expected colon') end; pos = pos + 1
        else key = #value + 1 end
        value[key] = parse(depth + 1); skip(); local separator = text:sub(pos, pos); pos = pos + 1
        if separator == closing then return value end
        if separator ~= ',' then fail('Expected comma or closing delimiter') end
      end
    end
    for literal, value in pairs({ ['true']=true, ['false']=false, ['null']=U.null }) do
      if text:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return value end
    end
    local start = pos
    if c == '-' then pos = pos + 1 end
    c = text:sub(pos, pos)
    if c == '0' then pos = pos + 1
    elseif c:match('[1-9]') and #c > 0 then repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
    else fail('Expected value') end
    if text:sub(pos, pos) == '.' then
      pos = pos + 1; if not text:sub(pos, pos):match('%d') then fail('Missing fractional digit') end
      repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
    end
    c = text:sub(pos, pos)
    if c == 'e' or c == 'E' then
      pos = pos + 1; c = text:sub(pos, pos); if c == '+' or c == '-' then pos = pos + 1 end
      if not text:sub(pos, pos):match('%d') then fail('Missing exponent digit') end
      repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
    end
    local number = tonumber(text:sub(start, pos - 1))
    if not number or number ~= number or math.abs(number) > M.max_number then fail('Number outside the supported range') end
    return number
  end
  local result = parse(0); skip(); if pos <= #text then fail('Trailing input') end; return result
end
function M.encode(value)
  local seen, bytes = {}, 0
  local function quoted(s)
    assert(utf8(s), 'String is not valid UTF-8')
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
      return ({ ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' })[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  end
  local encode
  encode = function(v, depth)
    assert(depth <= M.max_depth, 'JSON nesting exceeds the depth limit')
    local t, kind = type(v), U.kind(v)
    local result
    if v == nil or kind == 'null' then result = 'null'
    elseif t == 'boolean' then result = v and 'true' or 'false'
    elseif t == 'number' then assert(v == v and math.abs(v) <= M.max_number, 'Number outside the supported range'); result = string.format('%.17g', v)
    elseif t == 'string' then result = quoted(v)
    elseif t == 'table' then
      assert(not seen[v], 'Cyclic JSON data'); assert(getmetatable(v) == nil or kind, 'Unexpected JSON metatable'); seen[v] = true
      local array = kind == 'array' or kind ~= 'object' and next(v) ~= nil and U.islist(v)
      local parts = {}
      if array then U.assert_array(v, 'JSON array'); for i = 1, #v do parts[#parts + 1] = encode(v[i], depth + 1) end
      else for _, k in ipairs(U.sorted_keys(v)) do assert(type(k) == 'string', 'JSON object keys must be strings'); parts[#parts + 1] = quoted(k) .. ':' .. encode(v[k], depth + 1) end end
      seen[v] = nil; result = (array and '[' or '{') .. table.concat(parts, ',') .. (array and ']' or '}')
    else error('Unsupported JSON data type: ' .. t) end
    assert(#result <= M.max_bytes, 'JSON output exceeds the byte limit')
    bytes = bytes + #result; assert(bytes <= M.max_bytes * (M.max_depth + 1), 'JSON encoding exceeds the work limit')
    return result
  end
  return encode(value, 0)
end
return M
