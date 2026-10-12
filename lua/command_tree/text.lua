-- Character-indexed editing; byte slicing here would corrupt non-ASCII input.
local M = {}
function M.insert(text, cursor, value)
  cursor = math.max(0, math.min(cursor or vim.fn.strchars(text), vim.fn.strchars(text)))
  return vim.fn.strcharpart(text, 0, cursor) .. value .. vim.fn.strcharpart(text, cursor), cursor + vim.fn.strchars(value)
end
function M.edit(text, cursor, key, raw)
  cursor = math.max(0, math.min(cursor or vim.fn.strchars(text), vim.fn.strchars(text)))
  local function part(start, length) return vim.fn.strcharpart(text, start, length or vim.fn.strchars(text)) end
  if key == "<Left>" then return text, math.max(0, cursor - 1)
  elseif key == "<Right>" then return text, math.min(vim.fn.strchars(text), cursor + 1)
  elseif key == "<Home>" or key == "<C-a>" then return text, 0
  elseif key == "<End>" or key == "<C-e>" then return text, vim.fn.strchars(text)
  elseif key == "<BS>" or key == "<C-h>" then
    if cursor > 0 then return part(0, cursor - 1) .. part(cursor), cursor - 1 end
    return text, cursor
  elseif key == "<Del>" then return part(0, cursor) .. part(cursor + 1), cursor
  elseif key == "<C-u>" then return part(cursor), 0
  elseif key == "<C-w>" then
    local before = part(0, cursor):gsub("%s+$", ""):gsub("%S+$", "")
    return before .. part(cursor), vim.fn.strchars(before)
  end
  local value = key == "<Space>" and " " or key == "<lt>" and "<" or (not key:match("^<.*>$") and (raw or key))
  if value then return part(0, cursor) .. value .. part(cursor), cursor + vim.fn.strchars(value) end
  return text, cursor
end
function M.display(text, cursor)
  cursor = cursor or vim.fn.strchars(text)
  return vim.fn.strcharpart(text, 0, cursor) .. "▏" .. vim.fn.strcharpart(text, cursor)
end
return M
