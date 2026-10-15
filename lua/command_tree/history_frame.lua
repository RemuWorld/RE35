-- History-only display space; the native source window remains the authority
-- for context, cursor, undo and the user's split layout.
local V = require('command_tree.view')
local M = {}

local function close_source(state)
  local display = state.source_display
  if not display then return true end
  -- This window displays the real source buffer. V.close owns scratch buffers
  -- as well as windows and must never be used for this borrowed buffer.
  local win = display.win
  display.win = nil
  local ok, err = true, nil
  if win and vim.api.nvim_win_is_valid(win) then ok, err = pcall(vim.api.nvim_win_close, win, true) end
  if win and vim.api.nvim_win_is_valid(win) then
    display.win = win
    return false, tostring(err or 'History source display remains open')
  end
  state.source_display = nil
  return ok, err
end

function M.clear(state)
  local ok, err = close_source(state)
  local failures = {}
  if not ok then failures[#failures + 1] = tostring(err) end
  for _, part in ipairs(state.frames or {}) do
    local closed, reason = V.close(part)
    if not closed then failures[#failures + 1] = tostring(reason) end
  end
  -- Keep every failed handle owned and retryable on a later lifecycle clear.
  if #failures > 0 then return false, table.concat(failures, '; ') end
  state.frames = {}
  return true
end

local function source_display(state)
  local ctx = state.ctx
  local pos = vim.api.nvim_win_get_position(ctx.win)
  local top, left = math.max(0, pos[1]), math.max(0, pos[2])
  local width = math.min(vim.api.nvim_win_get_width(ctx.win), vim.o.columns - left)
  local height = math.min(vim.api.nvim_win_get_height(ctx.win), vim.o.lines - vim.o.cmdheight - top)
  -- Reserve the frame's cells in a native source display. Clamping a frame
  -- outside a full-screen source would put its left/top edges over real text.
  -- If even one source cell cannot fit inside, containment shows the regular
  -- workspace fallback after releasing every partially allocated window.
  assert(width >= 3 and height >= 3, 'History needs three source rows and columns for its frame')
  local display = state.source_display
  if display and (display.source_win ~= ctx.win or display.source_buf ~= ctx.buf) then
    local ok, err = close_source(state)
    assert(ok, err)
    display = nil
  end
  display = display or { source_win = ctx.win, source_buf = ctx.buf }
  state.source_display = display
  local config = { relative = 'editor', row = top + 1, col = left + 1, width = width - 2,
    height = height - 2, border = 'none', zindex = 44, focusable = false }
  if display.win and vim.api.nvim_win_is_valid(display.win) then
    vim.api.nvim_win_set_config(display.win, config)
  else
    config.noautocmd = true
    -- Native cloning inherits source-local number/sign/status columns, wrap,
    -- tabs, highlighting and manual fold definitions/closure state. Creating
    -- this in the source's context avoids inheriting another popup's options.
    -- The original window, split layout, cursor and view remain untouched.
    vim.api.nvim_win_call(ctx.win, function()
      display.win = vim.api.nvim_open_win(ctx.buf, false, config)
    end)
    vim.wo[display.win].winblend = 0
    -- The display borrows appearance, never the user's scroll/cursor bindings.
    -- Restoring its smaller viewport must not move another bound source.
    vim.wo[display.win].scrollbind, vim.wo[display.win].cursorbind = false, false
  end
  local view = vim.api.nvim_win_call(ctx.win, vim.fn.winsaveview)
  vim.api.nvim_win_call(display.win, function() vim.fn.winrestview(view) end)
  return display.win, top, left, width, height
end

function M.draw(state)
  local target_win, top, left, width, height = source_display(state)
  local bottom, right = top + height - 1, left + width - 1
  state.frames = state.frames or {}
  local vertical = {}
  for _ = 1, height - 2 do vertical[#vertical + 1] = '┃' end
  -- These four windows mark the source being edited. Popup density never
  -- changes this symbolic frame or the reserved native source display space.
  local parts = {
    { { '┏' .. string.rep('━', width - 2) .. '┓' }, top, left, width, 1 },
    { { '┗' .. string.rep('━', width - 2) .. '┛' }, bottom, left, width, 1 },
    { vertical, top + 1, left, 1, height - 2 }, { vertical, top + 1, right, 1, height - 2 },
  }
  for index, part in ipairs(parts) do
    state.frames[index] = state.frames[index] or {}
    V.window(state.frames[index], part[1], { relative = 'editor', row = part[2], col = part[3],
      width = part[4], height = part[5], border = 'none', zindex = 45 }, true)
  end
  return target_win
end

return M
