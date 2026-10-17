-- Bounded host text layout. Callers supply display-cell measurement; this
-- module has no editor APIs and does not change command or review data.
local M = {}

local function codepoint(char)
  local a, b, c, d = char:byte(1, 4)
  if a < 128 then return a end
  if not b or a >= 224 and not c or a >= 240 and not d then return 0xFFFD end
  if a < 224 then return (a - 192) * 64 + b - 128 end
  if a < 240 then return (a - 224) * 4096 + (b - 128) * 64 + c - 128 end
  return (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
end

local function extend(cp)
  return cp >= 0x300 and cp <= 0x36F or cp >= 0x1AB0 and cp <= 0x1AFF
    or cp >= 0x1DC0 and cp <= 0x1DFF or cp >= 0x20D0 and cp <= 0x20FF
    or cp >= 0xFE20 and cp <= 0xFE2F or cp >= 0xFE00 and cp <= 0xFE0F
    or cp >= 0xE0100 and cp <= 0xE01EF or cp >= 0x1F3FB and cp <= 0x1F3FF
    or cp >= 0xE0020 and cp <= 0xE007F
end

local function hangul(cp)
  if cp >= 0x1100 and cp <= 0x115F or cp >= 0xA960 and cp <= 0xA97C then return 'L' end
  if cp >= 0x1160 and cp <= 0x11A7 or cp >= 0xD7B0 and cp <= 0xD7C6 then return 'V' end
  if cp >= 0x11A8 and cp <= 0x11FF or cp >= 0xD7CB and cp <= 0xD7FB then return 'T' end
  if cp >= 0xAC00 and cp <= 0xD7A3 then return (cp - 0xAC00) % 28 == 0 and 'LV' or 'LVT' end
end

-- Preserve common combining sequences, decomposed Hangul, emoji modifiers,
-- flags and ZWJ sequences during emergency wrapping. This is deliberately not
-- a full Unicode line-breaking engine or a language-specific word segmenter.
local function units(text)
  local output, previous, regional = {}, nil, 0
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local cp = codepoint(char)
    local kind, prior = hangul(cp), previous and hangul(previous)
    local flag = cp >= 0x1F1E6 and cp <= 0x1F1FF
    local joined = #output > 0 and (extend(cp) or cp == 0x200D or previous == 0x200D
      or prior == 'L' and (kind == 'L' or kind == 'V' or kind == 'LV' or kind == 'LVT')
      or (prior == 'LV' or prior == 'V') and (kind == 'V' or kind == 'T')
      or (prior == 'LVT' or prior == 'T') and kind == 'T'
      or flag and regional % 2 == 1)
    if joined then output[#output][#output[#output] + 1] = char else output[#output + 1] = { char } end
    regional = flag and regional + 1 or 0
    previous = cp
  end
  for index, parts in ipairs(output) do output[index] = table.concat(parts) end
  return output
end

function M.wrap(text, width, measure, opts)
  opts = opts or {}
  width = math.max(1, width)
  local maximum, char_limit = opts.max_rows or 512, opts.max_chars or 16384
  local rows, current, complete, count, byte_end = {}, '', true, 0, 0
  -- Bound work before tokenization, including hostile zero-width mark runs.
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    count = count + 1
    if count > char_limit then complete = false; break end
    byte_end = byte_end + #char
  end
  if byte_end ~= #text then complete = false end
  text = text:sub(1, byte_end):gsub('\r\n', '\n'):gsub('[\r\t%z]', ' ')
  local function emit()
    if #rows >= maximum then complete = false; return false end
    rows[#rows + 1], current = current, ''
    return true
  end
  local function word(value, separator)
    if measure(current .. separator .. value) <= width then
      current = current .. separator .. value
      return true
    end
    if current ~= '' and not emit() then return false end
    if measure(value) <= width then current = value; return true end
    -- Only tokens wider than a whole row are split. Prefer path separators
    -- when present, but never insert a hyphen or modify the underlying text.
    local chunks, last_boundary = units(value), nil
    for _, unit in ipairs(chunks) do
      if measure(current .. unit) > width then
        if last_boundary and last_boundary < #current then
          local rest = current:sub(last_boundary + 1)
          current = current:sub(1, last_boundary)
          if not emit() then return false end
          current = rest
        elseif current ~= '' and not emit() then return false end
        last_boundary = nil
      end
      if measure(current .. unit) > width and current ~= '' and not emit() then return false end
      if measure(unit) > width then
        -- An indivisible cluster cannot fit this viewport. Keep a visible
        -- replacement and report incomplete; required facts must refuse it.
        complete = false
        current = measure('…') <= width and '…' or ''
      else current = current .. unit end
      if unit == '/' or unit == '\\' then last_boundary = #current end
    end
    return true
  end
  for paragraph in (text .. '\n'):gmatch('(.-)\n') do
    local position, trailing = 1, ''
    while position <= #paragraph do
      local first, last, spaces, value = paragraph:find('([ ]*)([^ ]+)', position)
      if not first then trailing = paragraph:sub(position); break end
      if not word(value, current ~= '' and spaces or position == 1 and spaces or '') then return rows, false end
      position = last + 1
    end
    -- Preserve explicit blank/indented lines; wrapping separator whitespace
    -- need not consume a new row by itself.
    if current == '' and trailing ~= '' then
      current = measure(trailing) <= width and trailing or ''
    end
    if not emit() then return rows, false end
  end
  return rows, complete
end

return M
