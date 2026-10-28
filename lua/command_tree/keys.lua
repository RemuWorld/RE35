local M = {}

function M.expand(keys)
  return (keys:gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function() return vim.g.mapleader or "\\" end)
    :gsub("<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>", function() return vim.g.maplocalleader or "\\" end))
end

function M.raw(keys)
  return vim.api.nvim_replace_termcodes(M.expand(keys), true, true, true)
end

function M.tokens(keys, raw)
  -- Termcode expansion escapes K_SPECIAL bytes inside UTF-8 text. Expand only
  -- key notation, never ordinary text, before handing it to keytrans.
  local text = raw and vim.fn.keytrans(keys) or M.expand(keys)
  local result, i = {}, 1
  while i <= #text do
    local token = text:sub(i):match("^<[^>]+>")
    if not token then
      local byte = text:byte(i)
      local length = byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4
      token = text:sub(i, i + length - 1)
    end
    local normalized = token
    if not raw and token:match("^<[^>]+>$") then normalized = vim.fn.keytrans(M.raw(token)) end
    if token == " " then normalized = "<Space>" end
    normalized = normalized:gsub("<C%-(%u)>", function(letter) return "<C-" .. letter:lower() .. ">" end)
    result[#result + 1], i = normalized, i + #token
  end
  return result
end

function M.label(key)
  return ({ ["<Space>"] = "SPC", ["<CR>"] = "Enter", ["<BS>"] = "BS", ["<lt>"] = "<" })[key] or key
end

function M.mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 2) == "no" then return "o" end
  if mode == "v" or mode == "V" or mode == "\22" then return "x" end
  if mode == "s" or mode == "S" or mode == "\19" then return "s" end
  return mode:sub(1, 1)
end

-- The document identity is distinct from a buffer's text revision. Renaming a
-- buffer need not increment changedtick, and unnamed documents have no file.
function M.document_uri(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name == "" and ("re35-buffer://" .. buf) or vim.uri_from_fname(name)
end

function M.context(mode)
  local ctx = {
    buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(),
    mode = mode or M.mode(), count = vim.v.count, register = vim.v.register,
    cursor = vim.api.nvim_win_get_cursor(0), changedtick = vim.api.nvim_buf_get_changedtick(0),
    filetype = vim.bo.filetype,
    document_uri = M.document_uri(vim.api.nvim_get_current_buf()),
  }
  local raw_mode = vim.api.nvim_get_mode().mode
  ctx.raw_mode = raw_mode
  if ctx.mode == "x" then
    local start, finish = vim.fn.getpos("v"), vim.fn.getpos(".")
    local anchor = { start[2], math.max(0, start[3] - 1) }
    if start[2] > finish[2] or (start[2] == finish[2] and start[3] > finish[3]) then start, finish = finish, start end
    if raw_mode == "V" then
      start[3] = 1
      finish[3] = #(vim.api.nvim_buf_get_lines(ctx.buf, finish[2] - 1, finish[2], false)[1] or "") + 1
    end
    ctx.selection = { anchor = anchor, start = { start[2], math.max(0, start[3] - 1) },
      finish = { finish[2], math.max(0, finish[3] - 1) }, mode = raw_mode, exclusive = vim.o.selection == "exclusive" }
  end
  return ctx
end

function M.valid(ctx)
  return type(ctx) == "table" and type(ctx.buf) == "number" and type(ctx.win) == "number"
    and vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_win_is_valid(ctx.win)
    and vim.api.nvim_win_get_buf(ctx.win) == ctx.buf
end

function M.unchanged(ctx)
  if not M.valid(ctx) then return false, "The original buffer or window is no longer available" end
  if ctx.changedtick and vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.changedtick then
    return false, "The document changed; reopen the command to use its current contents"
  end
  return true
end

-- Execute against the captured window while retaining an intentional focus
-- change made by the action (for example selecting or creating a window).
function M.call(ctx, callback)
  local focused
  local result = vim.api.nvim_win_call(ctx.win, function()
    local value = callback()
    focused = vim.api.nvim_get_current_win()
    return value
  end)
  if focused and focused ~= ctx.win and vim.api.nvim_win_is_valid(focused) then vim.api.nvim_set_current_win(focused) end
  return result
end

return M
