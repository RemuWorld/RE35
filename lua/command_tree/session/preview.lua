-- Preview effects have one cleanup owner. Identity reuse is an explicit host
-- opt-in; arbitrary preview callbacks retain their historical call semantics.
local K, V = require('command_tree.keys'), require('command_tree.view')
local Feedback = require('command_tree.session.feedback')
local M = {}

function M.attach(self, value, context)
  function self:preview_call(callback)
    self.preview_depth = (self.preview_depth or 0) + 1
    local ok, result = pcall(callback)
    self.preview_depth = self.preview_depth - 1
    if self.preview_depth == 0 and self.preview_palette_dirty then
      self.preview_palette_dirty = nil
      -- ColorScheme hooks belonging to other plugins still ran normally. Only
      -- RE35's intermediate redraws were deferred until the final palette.
      V.highlights()
    end
    return ok, result
  end

  function self:clear_preview()
    local state = self.active
    if not state then return true end
    state.preview_identity = nil
    if state.preview_restore_failed then
      local record = Feedback.current(state)
      state.message = record and record.message or 'Preview restoration failed; close and reopen this command'
      return false, state.message
    end
    if state.preview_cleanup then
      local cleanup = state.preview_cleanup
      state.preview_cleanup = nil
      local ok, err = self:preview_call(cleanup)
      if not ok then
        state.preview_restore_failed = true
        self:record_feedback('Restore preview failed; close and reopen this command', err)
        vim.notify(state.message, vim.log.levels.ERROR, { title = 'Command Environment' })
        return false, state.message
      end
    end
    return true
  end

  function self:preview_input()
    local state, input = self.active, self.active and self.active.input
    if not input or input.retired then return end
    local command, ctx, attachment, index = input.command, context(state), state.input_attachment, input.index
    local function current()
      return self:is_attached(state, attachment) and state.mode == 'input' and state.input == input
        and not input.retired and input.index == index and context(state) == ctx and K.valid(ctx)
        and (input.callback or self.registry:get(command.id) == command)
    end
    if not current() then return end
    local args = vim.deepcopy(input.args)
    local field = command.arguments[index]
    if field then args[field.name] = value(input) end
    local identity
    local key = not input.callback and command.input_ui and command.input_ui.preview_key
    if type(key) == 'function' then
      local ok, result = pcall(vim.api.nvim_win_call, ctx.win, function()
        return key(vim.deepcopy(ctx), vim.deepcopy(args), command.preview)
      end)
      if not current() then return end
      if not ok then self:record_feedback('Preview identity', result, command); return end
      if result ~= nil and (type(result) ~= 'string' or #result > 4096) then
        self:record_feedback('Preview identity', 'Preview identity must be bounded text or nil', command); return
      end
      identity = result
      local previous = state.preview_identity
      if identity and previous and previous.input == input and previous.command == command
        and previous.index == index and previous.key == identity then return end
    end
    local ok, result = self:preview_call(function()
      if not self:clear_preview() or not current() then return { skipped = true } end
      local callback = input.callback and input.preview or command.preview
      if type(callback) ~= 'function' then return { absent = true } end
      return { cleanup = vim.api.nvim_win_call(ctx.win, function()
        if input.callback then return callback(value(input), ctx) end
        return callback(ctx, args)
      end) }
    end)
    if not current() then
      -- A callback may close or replace its own form. Its late cleanup cannot
      -- become the new form's owner, but its temporary effect still needs undo.
      if ok and type(result) == 'table' and type(result.cleanup) == 'function' then
        local cleaned, why = self:preview_call(result.cleanup)
        if not cleaned then vim.notify('Retired preview restoration failed: ' .. tostring(why), vim.log.levels.ERROR) end
      end
      return
    end
    if not ok then self:record_feedback('Preview', result, command); return end
    if result.skipped then return end
    self:clear_feedback('Preview')
    local cleanup = result.cleanup
    if type(cleanup) == 'table' and cleanup.kind == 'condition' then
      self:record_condition('Preview', cleanup, command)
    elseif type(cleanup) == 'function' then state.preview_cleanup = cleanup end
    if identity then state.preview_identity = { input = input, command = command, index = index, key = identity } end
  end
end

return M
