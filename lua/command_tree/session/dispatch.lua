-- Coordinate command routes. Session alone owns private submission authority;
-- this module neither creates approval nor owns operation completion lifetime.
local K = require('command_tree.keys')
local Maps = require('command_tree.mappings')
local M = {}

local function reject(state, done, reason)
  state.message = reason
  if done then pcall(done, false, reason) end
  return false, reason
end

local function failure_message(detail)
  if detail == nil then return 'Cancelled' end
  local function bounded(value)
    local ok, value_text = pcall(tostring, value)
    local text = (ok and value_text or 'Unable to display error'):gsub('[\r\n]+', ' '):gsub('[%z\1-\8\11\12\14-\31]', '')
    return vim.fn.strchars(text) > 300 and vim.fn.strcharpart(text, 0, 300) .. '…' or text
  end
  if type(detail) ~= 'table' then return bounded(detail) end
  local kind = rawget(detail, 'kind')
  if rawget(detail, 'timed_out') == true then return bounded(rawget(detail, 'message') or 'Command timed out') end
  if kind == 'cancel' or kind == 'cancelled' or kind == 'canceled' or rawget(detail, 'cancelled') == true then return 'Cancelled' end
  if kind == 'process' then
    local code, output = rawget(detail, 'exit_code'), rawget(detail, 'output')
    local message = (type(code) == 'number' or type(code) == 'string') and 'Process exited with code ' .. bounded(code) or 'Process failed'
    if type(output) == 'string' then
      for line in output:gmatch('[^\r\n]+') do
        if line:find('%S') then return bounded(message .. ': ' .. line) end
      end
    end
    return message
  end
  for _, key in ipairs({ 'message', 'error', 'reason' }) do
    local value = rawget(detail, key)
    if type(value) == 'string' and value ~= '' then return bounded(value) end
  end
  local ok, inspected = pcall(vim.inspect, detail, { depth = 2 })
  return 'Command failed: ' .. bounded(ok and inspected or 'completion detail could not be displayed')
end

local function retain_backend_query(state, command, args)
  if command.id ~= 'search.project_text' or type(args) ~= 'table' or args.query == nil then return end
  -- Only a public, nonsecret literal query survives an unavailable backend.
  local valid, why = require('command_tree.backend_editor').query_valid(args.query)
  if args.mode ~= nil and args.mode ~= 'literal' or args.case ~= nil and args.case ~= 'sensitive' then
    valid, why = false, 'Explicit query syntax or case options cannot be carried to another backend; reopen the command and choose supported options'
  end
  state.backend_query = { command = command, query = valid and args.query or nil, invalid = not valid, reason = not valid and why or nil }
end

local function open_workspace(self, state, command, route, done)
  -- Search is transient; keep the workspace selector as the return point.
  if (state.mode == 'search' or state.mode == 'words') and #state.frames > 0 then self:pop_mode() end
  state = self.active
  local entered, err = self:enter_workspace(command.workspace, command.workspace_options)
  if not entered then return reject(state, done, err) end
  if route then state.path = vim.deepcopy(route) end
  self.usage:record(command.id)
  if done then pcall(done, true, { workspace = command.workspace }) end
  return true
end

local function session_action(self, state, command, ctx, done)
  local action = command.session_action
  if action == 'selected_recipe' then
    if state.busy then return reject(state, done, 'Another command is running; inspect Tasks or wait before starting this recipe') end
    if not self.project_recipes then return reject(state, done, 'Project recipe support is not available') end
    return self.project_recipes:run_selected(ctx, { done = done, interactive = #vim.api.nvim_list_uis() > 0 })
  elseif action == 'ui_import' then
    local ok, why = require('command_tree.settings.ui_import').open(self, ctx)
    if not ok then return reject(state, done, why) end
  elseif action == 'presentation_import' then
    local ok, why = require('command_tree.settings.presentation_import').open(self, ctx)
    if not ok then return reject(state, done, why) end
  elseif action == 'density' then self:cycle_density()
  elseif action == 'keymaps' then self:push_mode('keymaps', { path = K.tokens(command.keys or ''), keymap_root = Maps.collect(state.ctx, self.options) })
  elseif action == 'workspaces' then self:push_mode('selector', { query = '', query_cursor = 0, selector_filtering = false })
  elseif action == 'words' then self:push_mode('words', { query = '', query_cursor = 0, filter = false })
  elseif action == 'inspect' then self:inspect()
  else self:push_mode('search', { query = '', filter = action ~= 'search' and action or false }) end
  self.usage:record(command.id)
  if done then pcall(done, true, { action = command.session_action }) end
  return true
end

local function missing_argument(command, args, prepared)
  if not prepared then
    for index, field in ipairs(command.arguments or {}) do
      if not args or args[field.name] == nil then return index end
    end
  end
end

local function open_form(self, state, command, args, ctx, route, done, missing)
  local draft = self.drafts:get(command, ctx, args)
  self:push_mode('input')
  if route then state.path = vim.deepcopy(route) end
  state.input = { command = command, args = vim.tbl_extend('force', {}, draft and draft.args or {}, vim.deepcopy(args or {})),
    drafts = draft and draft.drafts or {}, index = draft and draft.index or missing, done = done, context = vim.deepcopy(ctx) }
  local input, attachment = state.input, state.input_attachment
  local ok, err = pcall(self.input_field, self)
  if not ok then state.message = tostring(err) end
  if draft and (next(draft.args) or next(draft.drafts)) and ok and not state.message
    and self:is_attached(state, attachment) and state.input == input then
    self:set_notice('Restored unsaved inputs; review them before running', 'Inputs restored · review before running')
  end
  return true
end

local function run_recipe(self, state, command, args, ctx, done, input, caller_id)
  if input and input.command.id == caller_id and not input.callback then
    self.drafts:save(command, input, ctx)
    self:release_input_choices(input)
    state.input = nil
    self:pop_mode(true)
  end
  local function complete(ok, detail, operation)
    if ok then
      self.drafts:forget(command.id, ctx.buf)
      if input then input.succeeded = true end
    end
    if done then done(ok, detail, operation) end
  end
  return self.project_recipes:run(command.recipe_id, args, ctx, { done = complete, interactive = #vim.api.nvim_list_uis() > 0 })
end

local function completion(self, state, command, ctx, done, origin)
  return function(ok, detail, operation)
    local warning = type(detail) == 'table' and type(rawget(detail, 'warning')) == 'string' and rawget(detail, 'warning') or nil
    local persistence = type(detail) == 'table' and type(rawget(detail, 'persistence')) == 'table' and rawget(detail, 'persistence') or nil
    local notice = persistence and ((command.name or command.id) .. ' · ' .. require('command_tree.persistence').label(persistence))
    state.busy = false
    if ok then
      self.drafts:forget(command.id, ctx.buf)
      if origin.input then origin.input.succeeded = true end
    end
    if self:is_attached(state, origin.attachment) then
      if ok and origin.input and origin.parent_mode == 'workspace' and state.input == origin.input
        and origin.navigation == (state.navigation or 0) then
        self:release_input_choices(origin.input)
        state.input = nil
        self:pop_mode(true)
        state.message = warning or notice or (command.name or command.id) .. ' completed'
        if warning then self:record_feedback('Storage', warning, command) end
        self:draw()
      elseif ok and warning then
        if origin.input and state.input == origin.input and origin.navigation == (state.navigation or 0) then
          self:release_input_choices(origin.input)
          state.input = nil
          self:pop_mode(true)
        end
        self:record_feedback('Storage', warning, command)
        self:draw()
      elseif ok and origin.mode ~= 'workspace' and origin.navigation == (state.navigation or 0) then
        local left, reason = self:leave()
        if not left then state.message = reason; self:draw() end
        if notice and #vim.api.nvim_list_uis() > 0 then vim.notify(notice, vim.log.levels.INFO, { title = 'RE35' }) end
      elseif ok then state.message = (command.name or command.id) .. ' completed; results are available in Tasks'; self:draw()
      else
        state.message = failure_message(detail)
        if state.mode == 'input' and state.input and not state.input.callback then self:preview_input() end
        self:draw()
      end
    elseif not ok and detail and failure_message(detail) ~= 'Cancelled' then
      vim.notify((command.name or command.id) .. ': ' .. failure_message(detail), vim.log.levels.ERROR, { title = 'Command Environment' })
    end
    if ok and self:is_attached(state, origin.attachment) and K.valid(state.ctx) then
      local tick = vim.api.nvim_buf_get_changedtick(state.ctx.buf)
      if state.ctx.changedtick ~= tick then state.ctx.selection = nil end
      state.ctx.changedtick, state.ctx.cursor = tick, vim.api.nvim_win_get_cursor(state.ctx.win)
    end
    if done then done(ok, detail, operation) end
  end
end

local function execute(self, state, command, args, ctx, done, process_target, execution_scope, caller_id)
  local origin = { navigation = state.navigation or 0, mode = state.mode, input = state.input, attachment = state.input_attachment,
    parent_mode = state.frames[#state.frames] and state.frames[#state.frames].mode }
  -- Transfer completion from the form to its execution before closing any UI.
  if origin.input and origin.input.command.id == caller_id then origin.input.done = nil end
  if command.recipe_id and not process_target and self.project_recipes then
    return run_recipe(self, state, command, args, ctx, done, origin.input, caller_id)
  end
  state.busy, state.message = true, 'Running ' .. (command.name or command.id) .. '…'
  if command.handoff then
    local left, reason = self:leave()
    if not left then
      state.busy = false
      return reject(state, done, reason or 'Could not return to the editor')
    end
  end
  local complete = completion(self, state, command, ctx, done, origin)
  local accepted, detail, operation = self.executor:execute(command.id, args, ctx, complete, {
    with_submission = execution_scope and execution_scope(command), process_target = process_target,
    select = function(items, options, callback)
      if not self:is_attached(state, origin.attachment) then callback(nil); return end
      return self:request(items, options, callback, ctx)
    end,
    input = function(options, callback)
      if not self:is_attached(state, origin.attachment) then callback(nil); return end
      return self:request_input(options, callback, ctx)
    end,
  })
  if state.busy then state.operation = operation end
  return accepted, detail, operation
end

function M.run(self, id, args, route, done, prepared, context, process_target, execution_scope)
  local state = self.active
  local ctx = context or state.ctx
  if not K.valid(ctx) or context and (context.buf ~= state.ctx.buf or context.win ~= state.ctx.win) then
    return reject(state, done, 'Execution target changed; reopen the environment on the intended target')
  end
  local command = self.registry:get(id)
  if prepared and state.input and not state.input.callback and state.input.command.id == id and state.input.command ~= command then
    return reject(state, done, 'Command changed while editing; reopen it to validate the new inputs')
  end
  if not command then return reject(state, done, 'Command is no longer registered') end
  local available, reason = self.registry:available(command.id, ctx)
  if self.active ~= state or self.registry:get(command.id) ~= command or not K.valid(ctx) then
    return reject(state, done, 'Command or source changed during availability inspection; select it again')
  end
  if not available then retain_backend_query(state, command, args); return reject(state, done, reason) end
  if command.workspace then return open_workspace(self, state, command, route, done) end
  if command.session_action then return session_action(self, state, command, ctx, done) end
  if state.busy then return reject(state, done, 'Another command is running; inspect Tasks or wait before starting this command') end
  local missing = missing_argument(command, args, prepared)
  if missing then return open_form(self, state, command, args, ctx, route, done, missing) end
  return execute(self, state, command, args, ctx, done, process_target, execution_scope, id)
end
return M
