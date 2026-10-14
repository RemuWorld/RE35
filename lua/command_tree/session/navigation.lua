-- Session navigation owns mode frames and bounded return receipts.
local K = require('command_tree.keys')
local V = require('command_tree.view')
local Input = require('command_tree.session.input')
local field_value = Input.value
local M = {}
-- Settings rebuilds the environment on Apply/Undo/Reload. Its return route is
-- a bounded, process-local read-only receipt, separate from profile/workspace
-- memory and backend-recovery receipts. It contains no descriptor or input.
local settings_navigation = setmetatable({}, { __mode = 'k' })
local function navigation_frame(frame)
  if type(frame) ~= 'table' or not ({ tree = true, search = true, words = true, inspect = true })[frame.mode] then return nil end
  local out = { mode = frame.mode, path = {} }
  local path = frame.path or {}
  if type(path) ~= 'table' or #path > 32 then return nil end
  for _, token in ipairs(path) do
    if type(token) ~= 'string' or #token > 64 then return nil end
    out.path[#out.path + 1] = token
  end
  for _, key in ipairs({ 'query', 'selected_id', 'selected_word', 'inspected_id' }) do
    local value = frame[key]
    if value ~= nil then
      if type(value) ~= 'string' or #value > (key == 'query' and 4096 or 512) then return nil end
      out[key] = value
    end
  end
  local entry = frame.tree_selected_entry
  if entry ~= nil then
    if type(entry) ~= 'table' then return nil end
    local selected = {}
    if entry.id ~= nil then
      if type(entry.id) ~= 'string' or #entry.id > 512 then return nil end
      selected.id = entry.id
    end
    if type(entry.group) == 'boolean' then selected.group = entry.group end
    if entry.path ~= nil then
      if type(entry.path) ~= 'table' or #entry.path > 32 then return nil end
      selected.path = {}
      for _, token in ipairs(entry.path) do
        if type(token) ~= 'string' or #token > 64 then return nil end
        selected.path[#selected.path + 1] = token
      end
    end
    out.tree_selected_entry = selected
  end
  for _, key in ipairs({ 'query_cursor', 'selected', 'tree_selection', 'page' }) do
    local value = frame[key]
    if type(value) == 'number' and value == value and value >= 0 and value <= 100000 and value % 1 == 0 then out[key] = value end
  end
  if frame.filter == false or frame.filter == 'recent' or frame.filter == 'favorites' then out.filter = frame.filter end
  return out
end
local function capture_settings_navigation(state)
  if not K.valid(state.ctx) then return nil, 'Original command source is no longer available' end
  local origin = navigation_frame(state)
  if not origin or origin.mode ~= 'inspect' or type(origin.inspected_id) ~= 'string' or #(state.frames or {}) > 16 then
    return nil, 'Original command navigation cannot be preserved safely'
  end
  local frames = {}
  for _, previous in ipairs(state.frames or {}) do
    local bounded = navigation_frame(previous)
    if not bounded then return nil, 'Original command navigation contains a workspace that cannot be restored after settings change' end
    frames[#frames + 1] = bounded
  end
  local ctx, token = state.ctx, {}
  settings_navigation[token] = { origin = origin, frames = frames, source = { buf = ctx.buf, win = ctx.win,
    name = vim.api.nvim_buf_get_name(ctx.buf), tick = vim.api.nvim_buf_get_changedtick(ctx.buf),
    filetype = vim.bo[ctx.buf].filetype, cursor = vim.api.nvim_win_get_cursor(ctx.win) } }
  return token
end
local function validate_settings_navigation(token, ctx)
  local receipt = settings_navigation[token]
  if not receipt then return nil, 'Original command return receipt is no longer available' end
  local source = receipt.source
  if not K.valid(ctx) or ctx.buf ~= source.buf or ctx.win ~= source.win
    or vim.api.nvim_buf_get_name(source.buf) ~= source.name
    or vim.api.nvim_buf_get_changedtick(source.buf) ~= source.tick
    or vim.bo[source.buf].filetype ~= source.filetype
    or not vim.deep_equal(vim.api.nvim_win_get_cursor(source.win), source.cursor) then
    return nil, 'Original command source changed; returned to the command home'
  end
  return receipt
end

local function snapshot(state)
  local result = {}
  for _, key in ipairs({ "mode", "path", "query", "query_cursor", "filter", "selected", "selected_id", "selected_word", "selector_filtering", "tree_selection", "tree_selected_entry", "page", "keymap_root", "inspected_id" }) do
    result[key] = key == "keymap_root" and state[key] or vim.deepcopy(state[key])
  end
  return result
end
local function restore(state, frame)
  for _, key in ipairs({ "mode", "path", "query", "query_cursor", "filter", "selected", "selected_id", "selected_word", "selector_filtering", "tree_selection", "tree_selected_entry", "page", "keymap_root", "inspected_id" }) do state[key] = frame[key] end
end
M.snapshot, M.restore = snapshot, restore
M.capture_settings, M.validate_settings = capture_settings_navigation, validate_settings_navigation

function M.attach(self)
  function self:push_mode(mode, values)
    local state = self.active
    if mode ~= "input" then state.navigation = (state.navigation or 0) + 1 end
    state.frames[#state.frames + 1] = snapshot(state)
    state.mode, state.page, state.selected, state.selected_id, state.message = mode, 1, 1, nil, nil
    for key, value in pairs(values or {}) do state[key] = value end
  end

  function self:pop_mode(keep_navigation)
    local state = self.active
    if not keep_navigation and (state.mode ~= "input" or not (state.input and state.input.callback)) then state.navigation = (state.navigation or 0) + 1 end
    local frame = table.remove(state.frames)
    if frame then
      restore(state, frame)
      if state.mode == "workspace" then V.close(state.view) end
    else self:close() end
  end

  function self:workspace_choices()
    local state, query = self.active, vim.fn.tolower(self.active.query or "")
    local choices = self.workspaces:list()
    if query ~= "" then
      choices = vim.tbl_filter(function(workspace)
        return vim.fn.tolower((workspace.name or workspace.id) .. " " .. workspace.id):find(query, 1, true) ~= nil
      end, choices)
    end
    state.selected = math.max(1, math.min(state.selected or 1, #choices))
    return choices
  end

  function self:enter_workspace(id, options)
    local definition = self.workspaces:get(id)
    if definition and definition.destination == 'editor' then
      local state = self.active
      if not state or not K.valid(state.ctx) then return false, 'Original editor window is no longer available' end
      if state.workspace_mutating then return false, 'Workspace lifecycle is already changing' end
      if not self:clear_preview() then return false, state.message end
      local win = state.ctx.win
      self:close()
      if not vim.api.nvim_win_is_valid(win) then return false, 'Original editor window is no longer available' end
      local ok, why = pcall(vim.api.nvim_set_current_win, win)
      return ok, not ok and tostring(why) or nil
    end
    local state, origin = self.active, snapshot(self.active)
    local frame, err, pushed = self.workspaces:push(state, id, options)
    if not frame then return false, err end
    if pushed ~= false or origin.mode == "selector" then
      origin.workspace_reused = pushed == false
      state.workspace_returns[#state.workspace_returns + 1] = origin
    end
    state.mode, state.visible = "workspace", true
    state.navigation = (state.navigation or 0) + 1
    if frame.definition._extension_ready then frame.definition._extension_ready(frame) end
    V.close(state.view)
    return true
  end

  function self:back()
    local state = self.active
    if not state then return false, 'Command session is closed' end
    local ctx = state.ctx
    if state.mode == 'feedback' then
      local record = state.feedback_inspection
      state.feedback_inspection = nil
      self:pop_mode(true)
      if self.active == state then state.message = record and record.message end
      return true
    end
    if not self:clear_preview() then return false, state.message end
    if state.mode == "workspace" then
      local settings_frame = self.workspaces:active(state)
      local receipt, return_error
      if settings_frame and settings_frame.id == 'settings' and state.settings_navigation then
        receipt, return_error = validate_settings_navigation(state.settings_navigation, state.ctx)
      elseif settings_frame and settings_frame.id == 'settings' then
        return_error = state.settings_navigation_error
      end
      local origin = state.workspace_returns[#state.workspace_returns]
      local pop_error
      if not (origin and origin.workspace_reused) then
        local popped
        popped, pop_error = self.workspaces:pop(state)
        -- A rejected lifecycle transition has not left the workspace. Keep
        -- its return route intact so the next Back can complete it once.
        if not popped then
          state.message = pop_error or 'Workspace is no longer active'
          return false, state.message
        end
        if self.active ~= state then return false, 'Command session changed during workspace cleanup' end
      end
      table.remove(state.workspace_returns)
      if return_error then
        state.frames, state.settings_navigation, state.settings_navigation_error = {}, nil, nil
        state.ctx = K.context()
        restore(state, { mode = 'tree', path = {}, page = 1, selected = 1 })
        state.message = return_error
      else
        restore(state, origin or { mode = "tree", path = {}, page = 1, selected = 1 })
        if receipt then state.settings_navigation = nil end
        if pop_error then state.message = pop_error end
      end
      state.navigation = (state.navigation or 0) + 1
      local frame = self.workspaces:active(state)
      if frame and frame.definition._extension_ready then frame.definition._extension_ready(frame) end
    elseif state.mode == "selector" and state.selector_filtering then
      state.selector_filtering = false
    elseif state.mode == "review" then
      state.mode, state.input.editing_review = "input", true
      state.input.index = math.min(state.input.review_selected or 1, #state.input.command.arguments)
      self:input_field()
    elseif state.mode == "input" and state.input.editing_review then
      local input, field = state.input, state.input.command.arguments[state.input.index]
      input.drafts[field.name] = input.choices and field_value(input) or input.text
      state.mode, input.editing_review = "review", nil
    elseif state.mode == "input" and state.input.filtering then
      state.input.filtering = false
      self:preview_input()
    elseif state.mode == "input" and state.input.callback then
      local callback = state.input.callback
      state.input.cleanup()
      callback(nil)
    elseif state.mode == "input" and state.input.index > 1 then
      local input = state.input
      local field = input.command.arguments[input.index]
      if input.choices then input.drafts[field.name] = field_value(input) else input.drafts[field.name] = input.text end
      state.input.index = state.input.index - 1
      self:input_field()
    elseif (state.mode == "tree" or state.mode == "keymaps") and #state.path > 0 then
      table.remove(state.path)
      state.page, state.tree_selection = 1, nil
      state.navigation = (state.navigation or 0) + 1
    else
      if state.mode == "input" then
        local input = state.input
        state.input = nil
        if input.done then pcall(input.done, false, "Cancelled") end
      end
      self:pop_mode()
    end
    if not self.active and ctx.mode == "o" then vim.api.nvim_feedkeys(K.raw("<Esc>"), "ni", false) end
  end

end

return M
