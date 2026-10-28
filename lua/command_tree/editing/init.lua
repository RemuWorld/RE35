-- One bounded native editing action against one captured Neovim source.
-- User definitions contain semantic IDs and values, never these native keys.
local Core = require('command_environment.core.editing')
local M = {}
local receipts = setmetatable({}, { __mode = 'k' })
local ids = {
  ['edit.move_words'] = true, ['edit.select_word'] = true,
  ['edit.uppercase_selection'] = true, ['edit.delete_lines'] = true,
}

local function copy(value) return vim.deepcopy(value) end
local function uri(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name == '' and ('re35-buffer://' .. buf) or vim.uri_from_fname(name)
end
local function position(value, buf)
  if type(value) ~= 'table' or type(value[1]) ~= 'number' or value[1] % 1 ~= 0
    or type(value[2]) ~= 'number' or value[2] % 1 ~= 0 or value[1] < 1
    or value[1] > vim.api.nvim_buf_line_count(buf) or value[2] < 0 then return false end
  local line = vim.api.nvim_buf_get_lines(buf, value[1] - 1, value[1], true)[1]
  if value[2] > #line then return false end
  local byte = line:byte(value[2] + 1)
  return not byte or byte < 128 or byte > 191
end
local function before(first, second)
  return first[1] < second[1] or first[1] == second[1] and first[2] < second[2]
end
local function context()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local raw = vim.api.nvim_get_mode().mode
  local ctx = { buf = buf, win = win, mode = (raw == 'v' or raw == 'V' or raw == '\22') and 'x' or raw:sub(1, 1),
    raw_mode = raw, cursor = vim.api.nvim_win_get_cursor(win),
    changedtick = vim.api.nvim_buf_get_changedtick(buf), document_uri = uri(buf), filetype = vim.bo[buf].filetype }
  if ctx.mode == 'x' then
    local start = vim.fn.getpos('v')
    local anchor = { start[2], math.max(0, start[3] - 1) }
    local first, last = copy(anchor), copy(ctx.cursor)
    if before(last, first) then first, last = last, first end
    if raw == 'V' then
      first[2] = 0
      last[2] = #(vim.api.nvim_buf_get_lines(buf, last[1] - 1, last[1], true)[1] or '')
    end
    ctx.selection = { start = first, finish = last, anchor = anchor, mode = raw,
      exclusive = vim.o.selection == 'exclusive' }
  end
  return ctx
end
M.context = context

local function source(ctx, host)
  if type(ctx) ~= 'table' or type(ctx.buf) ~= 'number' or type(ctx.win) ~= 'number'
    or not vim.api.nvim_buf_is_valid(ctx.buf) or not vim.api.nvim_buf_is_loaded(ctx.buf)
    or not vim.api.nvim_win_is_valid(ctx.win) or vim.api.nvim_win_get_buf(ctx.win) ~= ctx.buf then
    return false, 'The original editing buffer or window is no longer available'
  end
  if host == 'vscode-neovim' then
    -- vscode-neovim owns acwrite documents and their BufWriteCmd integration.
    -- This opt-in is supplied by the bundled host, never imported command data.
    local filename = vim.api.nvim_buf_get_name(ctx.buf)
    if (vim.g.vscode ~= true and vim.g.vscode ~= 1) or vim.bo[ctx.buf].buftype ~= 'acwrite'
      or not (filename:match('^%a:[/\\]') or filename:match('^/')) then
      return false, 'The VS Code editing source is not an owned local acwrite document'
    end
  elseif vim.bo[ctx.buf].buftype ~= '' then
    return false, 'Open editing commands from a normal document buffer'
  end
  if type(ctx.changedtick) ~= 'number' or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.changedtick then
    return false, 'The editing source changed; invoke the command again'
  end
  if type(ctx.document_uri) ~= 'string' or uri(ctx.buf) ~= ctx.document_uri then
    return false, 'The editing source was renamed; invoke the command again'
  end
  if not position(ctx.cursor, ctx.buf) or not vim.deep_equal(ctx.cursor, vim.api.nvim_win_get_cursor(ctx.win)) then
    return false, 'The source cursor changed; invoke the command again'
  end
  if ctx.mode ~= 'n' and ctx.mode ~= 'x' then return false, 'This editing command supports Normal or character/line Visual mode only' end
  if ctx.mode == 'n' and ctx.raw_mode and ctx.raw_mode ~= 'n' then
    return false, 'Finish the current native input before running this editing command'
  end
  if ctx.mode == 'x' then
    local selection = ctx.selection
    if type(selection) ~= 'table' or selection.mode ~= 'v' and selection.mode ~= 'V' then
      return false, 'Only character and line Visual selections are supported'
    end
    if not position(selection.start, ctx.buf) or not position(selection.finish, ctx.buf)
      or type(selection.exclusive) ~= 'boolean' then return false, 'The captured Visual selection is not valid' end
    if selection.anchor ~= nil and not position(selection.anchor, ctx.buf) then
      return false, 'The captured Visual anchor is not valid'
    end
    if selection.exclusive ~= (vim.o.selection == 'exclusive') then
      return false, 'The native selection option changed; invoke the command again'
    end
  end
  return true
end

local function operation(ctx, request, host)
  local valid, reason = source(ctx, host)
  if not valid then return nil, reason end
  if type(request) == 'string' then request = { command = request, args = {} } end
  if type(request) ~= 'table' or not ids[request.command] then return nil, 'Unknown native editing command' end
  local spec, why = Core.operation(request.command, request.args)
  if not spec then return nil, why end
  if spec.command == 'edit.uppercase_selection' then
    if ctx.mode ~= 'x' then return nil, 'Select text in character or line Visual mode before uppercasing' end
  elseif ctx.mode ~= 'n' then return nil, 'This editing command starts from Normal mode' end
  if spec.requires_nonblank then
    local line = vim.api.nvim_buf_get_lines(ctx.buf, ctx.cursor[1] - 1, ctx.cursor[1], true)[1]
    if ctx.cursor[2] >= #line or line:sub(ctx.cursor[2] + 1):match('^%s') then
      return nil, 'Place the cursor on a word or punctuation before selecting the current word'
    end
  end
  if spec.mutates then
    if not vim.bo[ctx.buf].modifiable or vim.bo[ctx.buf].readonly then return nil, 'This document is not writable' end
    local levels = vim.bo[ctx.buf].undolevels
    if levels == -123456 then levels = vim.go.undolevels end
    if levels < 0 then return nil, 'Enable native Undo before running this editing command' end
  end
  return spec
end

function M.available(ctx, request)
  local ok, value, why = pcall(operation, ctx, request)
  return ok and value ~= nil, not ok and tostring(value) or why
end

function M.capture(ctx, options)
  if options ~= nil then
    if type(options) ~= 'table' or getmetatable(options) ~= nil then return nil, 'Editing capture options must be a plain object' end
    for key in pairs(options) do if key ~= 'host' then return nil, 'Unknown editing capture option: ' .. tostring(key) end end
    if options.host ~= 'vscode-neovim' then return nil, 'Unsupported editing capture host' end
  end
  local host = options and options.host
  local copied = copy(ctx or context())
  local ok, valid, reason = pcall(source, copied, host)
  if not ok or not valid then return nil, tostring(ok and reason or valid) end
  local receipt = {}
  receipts[receipt] = { context = copied, iskeyword = vim.bo[copied.buf].iskeyword,
    selection = vim.o.selection, startofline = vim.o.startofline, host = host }
  return receipt
end

local function normal(keys)
  vim.api.nvim_cmd({ cmd = 'normal', bang = true, args = { keys }, mods = { silent = true, keepjumps = true } }, {})
end
local function undo_seq() return vim.fn.undotree().seq_cur end
local function anchor(ctx)
  local selected = ctx.selection
  if selected.anchor then return copy(selected.anchor) end
  -- Older captured contexts predate explicit direction. The source cursor
  -- identifies the active end; new contexts always retain the actual anchor.
  if before(ctx.cursor, selected.finish) then return copy(selected.finish) end
  return copy(selected.start)
end
local function check_owner(guard)
  if not guard then return true end
  local ok, accepted, reason = pcall(guard)
  if not ok then return false, tostring(accepted) end
  if accepted == false then return false, tostring(reason or 'The native editing owner was retired') end
  return true
end

function M.execute(receipt, request, guard)
  local owned = receipts[receipt]
  if not owned then return nil, 'This editing capture is foreign, expired or already used' end
  receipts[receipt] = nil
  if guard ~= nil and type(guard) ~= 'function' then return nil, 'Native editing ownership guard must be a function' end
  local authorized, owner_error = check_owner(guard)
  if not authorized then return nil, owner_error end
  local ctx = owned.context
  if type(request) == 'string' then request = { command = request, args = {} } end
  local spec, why = operation(ctx, request, owned.host)
  if not spec then return nil, why end
  if vim.bo[ctx.buf].iskeyword ~= owned.iskeyword or vim.o.selection ~= owned.selection
    or vim.o.startofline ~= owned.startofline then
    return nil, 'The native word or selection rules changed; invoke the command again'
  end
  local observed
  local ok, failure = pcall(vim.api.nvim_win_call, ctx.win, function()
    local first = { context = copy(ctx), undo_seq = undo_seq() }
    if spec.mutates then
      -- Native commands inside one Lua turn otherwise share its undo block.
      -- Close the prior block without changing either global or local value.
      vim.cmd('let &g:undolevels = &g:undolevels')
      local authorized, reason = check_owner(guard)
      assert(authorized, reason)
      local still_valid, reason = operation(ctx, request, owned.host)
      assert(still_valid, reason)
      assert(vim.api.nvim_get_current_win() == ctx.win, 'The source focus changed while preparing native Undo')
      assert(vim.bo[ctx.buf].iskeyword == owned.iskeyword and vim.o.selection == owned.selection
        and vim.o.startofline == owned.startofline, 'The native word or selection rules changed; invoke the command again')
    end
    normal(vim.api.nvim_replace_termcodes('<Esc>', true, true, true))
    vim.api.nvim_win_set_cursor(ctx.win, ctx.cursor)
    if spec.command == 'edit.move_words' then normal(tostring(spec.count) .. 'w')
    elseif spec.command == 'edit.select_word' then normal('viw')
    elseif spec.command == 'edit.uppercase_selection' then
      vim.api.nvim_win_set_cursor(ctx.win, anchor(ctx))
      normal(ctx.selection.mode)
      vim.api.nvim_win_set_cursor(ctx.win, ctx.cursor)
      normal('U')
    else
      local count = math.min(spec.count, vim.api.nvim_buf_line_count(ctx.buf) - ctx.cursor[1] + 1)
      normal('"_' .. tostring(count) .. 'dd')
    end
    local last = { context = context(), undo_seq = undo_seq() }
    observed = { command = spec.command, args = Core.normalize(request.command, request.args).args,
      changed = first.context.changedtick ~= last.context.changedtick, before = first, after = last,
      repeat_supported = false }
  end)
  if not ok then return nil, tostring(failure) end
  return observed
end

return M
