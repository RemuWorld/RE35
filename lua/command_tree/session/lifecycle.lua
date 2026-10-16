-- Logical session lifetime is separate from its visible surface and input lease.
local K = require('command_tree.keys')
local V = require('command_tree.view')
local Input = require('command_tree.session.input')
local Driver = require('command_tree.session.input_driver')
local Navigation = require('command_tree.session.navigation')
local M, serial = {}, 0
local safe_modes = { tree=true, search=true, words=true, inspect=true, selector=true }

local function transition(self, name, call)
  if self.transitioning then return false, 'Session lifecycle is already changing: ' .. self.transitioning end
  self.transitioning = name
  local ok, result, reason = xpcall(call, debug.traceback)
  self.transitioning = nil
  if not ok then
    if self.active then self.active.message = 'Session ' .. name .. ': ' .. tostring(result) end
    return false, tostring(result)
  end
  return result, reason
end

local function save_draft(self, input, current, handoff)
  if input.callback or not input.command.id or input.succeeded then return end
  local draft = { index = input.index, args = vim.tbl_extend('force', {}, input.args),
    drafts = vim.tbl_extend('force', {}, input.drafts) }
  local field = input.command.arguments[input.index]
  if current and field and not field.secret then
    if input.choices then draft.drafts[field.name] = Input.value(input) else draft.drafts[field.name] = input.text end
  end
  -- A remembered confirmation is not a new review. Keep ordinary nonsecret
  -- drafts, but never carry explicit-Apply boolean gates across a handoff.
  if handoff and input.command.review_policy == 'explicit_apply' then
    for _, item in ipairs(input.command.arguments) do
      if item.kind == 'boolean' then draft.args[item.name], draft.drafts[item.name] = nil, nil end
    end
  end
  if handoff then
    for index, item in ipairs(input.command.arguments) do
      if item.secret then draft.index = math.min(draft.index, index) end
    end
  end
  self.drafts:save(input.command, draft, input.context or (self.active or self.suspended).ctx)
end

local function inputs(state)
  local result, seen, input = {}, {}, state.input
  while input and not seen[input] do
    seen[input], result[#result + 1] = true, input
    input = input.parent
  end
  return result
end

local function retire_inputs(state, chain)
  local callbacks = {}
  for _, input in ipairs(chain) do
    if input.callback then callbacks[#callbacks + 1] = { input.callback, true } end
    if input.done then callbacks[#callbacks + 1] = { input.done, false } end
    input.retired = true
    input.callback, input.done, input.parent = nil, nil, nil
    input.args, input.drafts, input.text, input.choices, input.all_choices, input.checked = {}, {}, '', nil, nil, nil
    input.completion, input.context = nil, nil
    input.filter, input.filter_cursor, input.filtering, input.history_draft, input.history_index = nil, nil, nil, nil, nil
    input.preview, input.cursor = nil, nil
  end
  state.input = nil
  return function()
    for _, item in ipairs(callbacks) do
      if item[2] then pcall(item[1], nil) else pcall(item[1], false, 'Cancelled') end
    end
  end
end

local function retain_navigation(state)
  local frames = {}
  for _, frame in ipairs(state.frames or {}) do
    if safe_modes[frame.mode] then frames[#frames + 1] = Navigation.snapshot(frame) end
  end
  local origin
  if safe_modes[state.mode] then origin = Navigation.snapshot(state)
  elseif state.input and state.input.command.id then
    origin = { mode='inspect', inspected_id=state.input.command.id, path=vim.deepcopy(state.path), page=1 }
  else origin = table.remove(frames) or { mode='tree', path={}, page=1, selected=1 } end
  local last = frames[#frames]
  if origin.mode == 'inspect' and last and last.mode == 'inspect' and last.inspected_id == origin.inspected_id then
    table.remove(frames)
  end
  Navigation.restore(state, origin)
  state.frames = frames
end

local function reconcile_navigation(state, registry)
  local changed = false
  local function reconcile(frame)
    frame.path = frame.path or {}
    while #frame.path > 0 and not registry:node(frame.path) do
      table.remove(frame.path)
      frame.page, frame.tree_selection, frame.tree_selected_entry = 1, nil, nil
      changed = true
    end
    if frame.mode == 'inspect' and not registry:get(frame.inspected_id) then
      frame.mode, frame.inspected_id = 'tree', nil
      changed = true
    end
    if frame.selected_id and not registry:get(frame.selected_id) then frame.selected_id, frame.selected_word = nil, nil end
  end
  reconcile(state)
  for _, frame in ipairs(state.frames) do reconcile(frame) end
  if changed then state.message = 'Commands changed while in Editor; returned to available command navigation' end
end

local function source_exists(ctx)
  return ctx and vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_win_is_valid(ctx.win)
end

local function cleanup_views(state)
  if state.cleanup_views then return state.cleanup_views end
  local views = { state.view }
  for _, frame in ipairs(state.stack or {}) do
    for _, view in pairs({ frame.view, frame.error_view, frame.data.view, frame.data.hud, frame.data.timeline_view }) do
      if type(view) == 'table' then views[#views + 1] = view end
    end
  end
  state.cleanup_views = views
  return views
end

local function invalidate(state)
  state.navigation = (state.navigation or 0) + 1
  state.search_cache, state.tree_items, state.keymap_root, state.literal = nil, nil, nil, nil
  for _, key in ipairs({ 'availability_receipt', 'availability_guard', 'availability_report', 'availability_command',
    'feedback_inspection', 'backend_query', 'recovered_query', 'recovered_query_command', 'recovered_query_id',
    'recovered_query_receipt', 'settings_navigation', 'settings_navigation_error', 'execute_result' }) do state[key] = nil end
end

function M.attach(self)
  function self:is_attached(state, attachment)
    return not self.transitioning and state ~= nil and self.active == state and attachment ~= nil
      and state.input_attachment == attachment and not attachment.detached
  end

  function self:identify(state)
    serial = serial + 1
    state.session_id, state.disposed, state.suspended = serial, false, false
  end

  function self:close()
    return transition(self, 'close', function()
      local state = self.active or self.suspended or self.cleanup_pending
      if not state then return true end
      local chain = inputs(state)
      for index, input in ipairs(chain) do
        pcall(save_draft, self, input, index == 1 or index == 2 and state.input.callback ~= nil)
      end
      if self.active == state then self:clear_preview() end
      local settle = retire_inputs(state, chain)
      local views = cleanup_views(state)
      Driver.detach(self, state)
      self.active, self.suspended = nil, nil
      self.cleanup_pending = state
      state.running, state.suspended, state.disposed = false, false, true
      invalidate(state)
      local errors = {}
      local ok, cleaned, reasons = pcall(self.workspaces.clear, self.workspaces, state)
      if not ok then errors[#errors + 1] = tostring(cleaned)
      elseif cleaned == false then errors[#errors + 1] = table.concat(reasons or { 'Workspace cleanup failed' }, '; ') end
      for _, view in ipairs(views) do
        local called, closed, why = pcall(V.close, view)
        if not called then errors[#errors + 1] = tostring(closed)
        elseif not closed then errors[#errors + 1] = tostring(why) end
      end
      settle()
      if #errors > 0 then
        state.cleanup_error = table.concat(errors, '; '):sub(1, 8192)
        return false, state.cleanup_error
      end
      self.cleanup_pending, state.cleanup_views = nil, nil
      return true
    end)
  end

  function self:suspend()
    return transition(self, 'suspend', function()
      local state = self.active
      if not state then return false, 'Command session is not attached' end
      if not K.valid(state.ctx) then return false, 'Original editor window is no longer available' end
      if state.workspace_mutating then return false, 'Workspace lifecycle is already changing' end
      if #(state.stack or {}) > 0 then
        state.message = 'Return from the current workspace before switching to Editor; its drafts and resources were kept'
        return false, state.message
      end
      if state.mode == 'keymaps' then return false, 'Finish or close the native key guide before switching to Editor' end
      if not self:clear_preview() then return false, state.message end
      local chain = inputs(state)
      for index, input in ipairs(chain) do save_draft(self, input, index == 1 or index == 2 and state.input.callback ~= nil, true) end
      local closed, why = V.close(state.view)
      if not closed then state.message = 'Could not detach command surface: ' .. tostring(why); return false, state.message end
      retain_navigation(state)
      self:clear_feedback()
      local settle = retire_inputs(state, chain)
      invalidate(state)
      Driver.detach(self, state)
      self.active, self.suspended = nil, state
      state.running, state.suspended, state.visible = false, true, false
      state.message = 'Returned from Editor; select the command again to review saved inputs'
      settle()
      vim.api.nvim_set_current_win(state.ctx.win)
      return true, state
    end)
  end

  function self:resume(opts)
    opts = opts or {}
    if type(opts) ~= 'table' then return nil, 'Resume options must be a table' end
    local state, why = transition(self, 'resume', function()
      if self.active then return false, 'A command surface is already attached' end
      local saved = self.suspended
      if not saved or saved.disposed then return false, 'No suspended command session' end
      if not source_exists(saved.ctx) then return false, 'Original editor source is no longer available' end
      local ctx
      if opts.context then
        if not K.valid(opts.context) then return false, 'Resume target is no longer available' end
        ctx = vim.api.nvim_win_call(opts.context.win, function() return K.context(opts.mode or opts.context.mode) end)
      else ctx = K.context(opts.mode) end
      if not K.valid(ctx) then return false, 'Resume target is no longer available' end
      saved.ctx, saved.view = ctx, {}
      saved.running, saved.suspended, saved.visible, saved.automatic = true, false, true, false
      saved.opened, saved.delay = vim.uv.hrtime(), 0
      invalidate(saved)
      reconcile_navigation(saved, self.registry)
      self.suspended, self.active = nil, saved
      Driver.attach(self, saved)
      self:bind_workspace(saved)
      return saved
    end)
    if not state then return nil, why end
    local ok, err = xpcall(function()
      if opts.on_open then opts.on_open(state) end
      if self.active == state then self:draw() end
    end, debug.traceback)
    if not ok then self:close(); return nil, tostring(err) end
    if opts.interactive ~= false and self.active == state then Driver.drive(self, state) end
    return state
  end

  function self:editor_event(ev)
    if self.transitioning then return end
    local state = self.active or self.suspended
    if not state then return end
    local closed = ev.event == 'WinClosed' and tonumber(ev.match)
    if not source_exists(state.ctx) or closed == state.ctx.win
      or ev.event == 'BufWipeout' and ev.buf == state.ctx.buf then self:close(); return end
    if self.active == state and (not K.valid(state.ctx) or closed == state.view.win
      or ev.event == 'WinEnter' and vim.api.nvim_get_current_win() ~= state.ctx.win) then self:close() end
  end
end

return M
