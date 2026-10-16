-- Own raw input only while this particular surface attachment is current.
-- Logical sessions can outlive a surface; an old poll or paste callback must
-- never deliver input to the same state after it has acquired a new attachment.
local K = require('command_tree.keys')
local Maps = require('command_tree.mappings')
local Guide = require('command_tree.session.key_guide')
local M = {}
-- All Session/Environment owners share the paste entry point. A retired
-- wrapper must not bypass a surface belonging to a different owner.
local attachments = setmetatable({}, { __mode = 'k' })

local function owns(owner, state, attachment)
  return attachment and not attachment.detached and owner.active == state
    and state.input_attachment == attachment
end

local function live(owner, state, attachment)
  return owns(owner, state, attachment) and state.running and not owner.transitioning
end

function M.detach(owner, state)
  local attachment = state and state.input_attachment
  if not attachment then return end
  -- Invalidate before restoring hooks: callbacks invoked during cleanup already
  -- belong to an expired attachment, including streamed paste fragments.
  attachment.detached = true
  attachments[attachment] = nil
  state.input_attachment, state.paste_text = nil, nil
  if vim.paste == attachment.paste_handler then vim.paste = attachment.original_paste end
  state.paste_handler, state.original_paste = nil, nil
end

function M.attach(owner, state)
  if owner.active ~= state then return nil end
  M.detach(owner, state)
  local attachment = { original_paste = vim.paste }
  attachments[attachment] = true
  state.input_attachment = attachment
  attachment.paste_handler = function(lines, phase)
    if not live(owner, state, attachment) then
      -- A plugin can wrap vim.paste after our hook is installed. Keep that
      -- wrapper usable for complete native pastes after every RE35 surface has
      -- detached. Call-chain identity is not detectable: this is a deliberate
      -- complete native-paste exception, never a route into a command surface.
      -- In particular, no previous Environment can bypass a newer attachment.
      if attachment.detached and phase == -1 and next(attachments) == nil
        and vim.paste ~= attachment.paste_handler and vim.paste ~= attachment.original_paste then
        return attachment.original_paste(lines, phase)
      end
      return false
    end
    if state.mode == 'keymaps' then
      owner:close()
      return attachment.original_paste(lines, phase)
    end
    if phase == -1 or phase == 1 then state.paste_text = '' end
    state.paste_text = (state.paste_text or '') .. table.concat(lines, '\n')
    if #state.paste_text > 1048576 then
      state.paste_text, state.message = nil, 'Paste exceeds the 1 MiB input limit'
      owner:draw()
      return false
    end
    if phase == -1 or phase == 3 then
      local value = state.paste_text
      state.paste_text = nil
      local ok, err = pcall(owner.paste, owner, { value })
      if not live(owner, state, attachment) then return false end
      if not ok then
        state.message = 'Paste: ' .. tostring(err)
        owner:draw()
        return false
      end
    end
    return true
  end
  state.original_paste, state.paste_handler = attachment.original_paste, attachment.paste_handler
  vim.paste = attachment.paste_handler
  return attachment
end

function M.drive(owner, state)
  local attachment, ctx = state.input_attachment, state.ctx
  if not owns(owner, state, attachment) then return state end
  local function source_valid()
    return K.valid(ctx) and vim.api.nvim_get_current_win() == ctx.win
  end
  local ok, err = xpcall(function()
    while live(owner, state, attachment) do
      if not source_valid() then break end
      local started = vim.uv.hrtime()
      local node = state.mode == 'keymaps' and Maps.node(state.keymap_root, state.path)
      local timeout = state.automatic and node and node.native and Guide.has_children(node)
        and vim.o.timeout and vim.o.timeoutlen
      while live(owner, state, attachment) do
        local raw = vim.fn.getcharstr(0)
        -- getcharstr and vim.wait may run callbacks that suspend, resume, or
        -- replace this session. Check the captured lease after each boundary.
        if not live(owner, state, attachment) then break end
        if not source_valid() then owner:close(); break end
        if raw ~= '' then owner:handle(K.tokens(raw, true)[1], raw); break end
        if not state.visible and (vim.uv.hrtime() - state.opened) / 1e6 >= state.delay then
          state.visible = true
          owner:draw()
        end
        if not live(owner, state, attachment) then break end
        if not source_valid() then owner:close(); break end
        if timeout and (vim.uv.hrtime() - started) / 1e6 >= timeout then
          owner:handle('timeout')
          break
        end
        if not live(owner, state, attachment) then break end
        if not source_valid() then owner:close(); break end
        vim.wait(10, function() return not live(owner, state, attachment) end, 10)
        if not live(owner, state, attachment) then break end
      end
    end
  end, debug.traceback)
  -- A suspended/replaced attachment owns no cleanup. In particular, it must
  -- not close a resumed state just because that state has the same identity.
  if owns(owner, state, attachment) then
    owner:close()
    if not ok and not tostring(err):match('[Ii]nterrupt') then
      vim.notify(err, vim.log.levels.ERROR, { title = 'Command Environment' })
    end
  end
  return state
end

return M
