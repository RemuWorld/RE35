local K = require("command_tree.keys")
local Maps = require("command_tree.mappings")
local V = require("command_tree.view")
local A = require("command_tree.arguments")
local Text = require("command_tree.text")
local Navigation = require('command_tree.session.navigation')
local Input = require('command_tree.session.input')
local Presenter = require('command_tree.session.presenter')
local Guide = require('command_tree.session.key_guide')
local Dispatch = require('command_tree.session.dispatch')
local Lists = require('command_tree.list_navigation')
local Feedback = require('command_tree.session.feedback')
local snapshot, restore = Navigation.snapshot, Navigation.restore
local capture_settings_navigation, validate_settings_navigation = Navigation.capture_settings, Navigation.validate_settings
local field_value = Input.value
local has_children, guide_owns_key = Guide.has_children, Guide.owns_key
local M = {}
-- Only a submitted live form can authorize an explicit Apply. This scope is
-- process-local and never appears in args, public state, drafts or profiles.
local active_execution
function M.consume_submission(command, ctx, args, operation)
  local execution = active_execution
  local scope = execution and execution.submission
  if not scope or execution.consumed or execution.context ~= ctx or execution.args ~= args
    or execution.operation ~= operation or scope.owner.active ~= scope.state
    or scope.state.input ~= scope.input or scope.input.command ~= command
    or scope.owner.registry:get(command.id) ~= command then return false end
  execution.consumed = true
  return true
end
local function copy_path(path) return vim.deepcopy(path or {}) end
local function text_key(key, raw)
  if key == "<Space>" then return " " end
  if key == "<lt>" then return "<" end
  if key and not key:match("^<.*>$") then return raw or key end
end
-- A captured live form can supply an invocation boundary, never public args.
local function execution_scope(self, submission, command)
  if not submission or submission.owner ~= self or submission.input.command ~= command then return nil end
  return function(executed_command, executed_ctx, executed_args, invocation, call)
    local previous = active_execution
    -- Activate only after Executor admission. Validation hooks carry no Apply.
    local matches = executed_command == command and self.active == submission.state
      and submission.state.input == submission.input
      and vim.deep_equal(executed_ctx, submission.context) and vim.deep_equal(executed_args, submission.args)
    active_execution = matches and { submission = submission, context = executed_ctx,
      args = executed_args, operation = invocation } or nil
    local ok, result, why = pcall(call)
    active_execution = previous
    if not ok then error(result, 0) end
    return result, why
  end
end

function M.new(services)
  local self = services
  self.active = nil
  self.input_history = {}
  self.drafts = require("command_tree.drafts").new()

  function self:clear_preview()
    local state = self.active
    if state and state.preview_restore_failed then
      local record = Feedback.current(state)
      state.message = record and record.message or 'Preview restoration failed; close and reopen this command'
      return false, state.message
    end
    if state and state.preview_cleanup then
      local cleanup = state.preview_cleanup
      state.preview_cleanup = nil
      local ok, err = pcall(cleanup)
      if not ok then
        state.preview_restore_failed = true
        self:record_feedback('Restore preview failed; close and reopen this command', err)
        vim.notify(state.message, vim.log.levels.ERROR, { title = "Command Environment" })
        return false, state.message
      end
    end
    return true
  end

  function self:close()
    local state = self.active
    if not state then return end
    if state.input and not state.input.callback and state.input.command.id then
      local input, field = state.input, state.input.command.arguments[state.input.index]
      local form_visible = state.mode == 'input' or state.mode == 'feedback' and state.frames[#state.frames] and state.frames[#state.frames].mode == 'input'
      if field and form_visible and not field.secret then
        input.drafts[field.name] = input.choices and field_value(input) or input.text
      end
      if not input.succeeded then self.drafts:save(input.command, input, input.context or state.ctx) end
    end
    self:clear_preview()
    self.active = nil
    state.running = false
    if state.paste_handler and vim.paste == state.paste_handler then vim.paste = state.original_paste end
    if state.input and state.input.callback then
      local callback = state.input.callback
      state.input.callback = nil
      pcall(callback, nil)
    end
    if state.input and state.input.done then
      local done = state.input.done
      state.input.done = nil
      pcall(done, false, "Cancelled")
    end
    self.workspaces:clear(state)
    V.close(state.view)
  end

  function self:results()
    local state = self.active
    local ids = state.filter == "recent" and self.usage:recent() or state.filter == "favorites" and self.usage:favorites() or nil
    local cache_key = table.concat({ state.mode, state.query or "", state.filter or "", tostring(self.registry.generation),
      tostring(vim.api.nvim_buf_get_changedtick(state.ctx.buf)), vim.bo[state.ctx.buf].filetype, ids and table.concat(ids, "\0") or "" }, "\1")
    local results
    if state.search_cache and state.search_cache.key == cache_key then results = state.search_cache.results
    else
      results = state.mode == "words" and self.registry:words(state.query or "", state.ctx)
        or self.registry:search(state.query or "", state.ctx, { ids = ids })
      state.search_cache = { key = cache_key, results = results }
    end
    if state.selected_id then
      for index, result in ipairs(results) do
        if result.id == state.selected_id and (state.mode ~= "words" or not state.selected_word or result.word_path == state.selected_word) then state.selected = index; break end
      end
    end
    state.selected = math.max(1, math.min(state.selected or 1, #results))
    state.selected_id = results[state.selected] and results[state.selected].id
    state.selected_word = state.mode == "words" and results[state.selected] and results[state.selected].word_path or nil
    return results
  end

  function self:selected_command()
    local state = self.active
    if not state then return nil end
    if state.mode == "inspect" then return self.registry:get(state.inspected_id) end
    if state.mode == "search" or state.mode == "words" then
      local result = self:results()[state.selected]
      return result and result.command
    end
    if state.mode == "input" or state.mode == "review" then return state.input and state.input.command end
    local selected = state.tree_items and state.tree_items[state.tree_selection or 1]
    return selected and selected.id and self.registry:get(selected.id)
  end

  function self:inspect()
    local state, command = self.active, self:selected_command()
    if self:inspect_feedback() then return end
    if state.mode == 'input' or state.mode == 'review' then state.message = 'No diagnostic to inspect for this form'; return end
    if not command then state.message = "Select a command with ↑/↓ or search before opening details"; return end
    self:push_mode("inspect", { inspected_id = command.id })
  end

  function self:configure_backend()
    local state = self.active
    if not state or state.mode ~= "inspect" then return false, "Open command details first" end
    if state.busy then return false, "Wait for the active command before changing its backend" end
    local command = self.registry:get(state.inspected_id)
    local editor = require("command_tree.backend_editor")
    if not command or not editor.supports(command) then return false, "This command has no backend Settings route" end
    local available = self.registry:available(command.id, state.ctx)
    if available then return false, "This command is available; backend choices are in Settings / Backends" end
    local receipt, why = editor.capture(command, state, state.frames[#state.frames])
    if not receipt then return false, why end
    return self:enter_workspace("settings", { section = "backends", selected_id = receipt.capability,
      backend_recovery = receipt })
  end

  function self:inspect_availability()
    local state = self.active
    if not state or state.mode ~= "inspect" then return false, "Open command details first" end
    local command = self.registry:get(state.inspected_id)
    if not command then return false, "Command is no longer registered" end
    local availability = require("command_tree.availability")
    self:push_mode("availability", { availability_command = command })
    local receipt, guard = availability.capture(command, state, self.registry)
    if not receipt then self:pop_mode(); return false, guard end
    state.availability_receipt, state.availability_guard = receipt, guard
    state.availability_report = availability.report(command, state.ctx, self.registry, { integrations = self.options.integrations })
    return true
  end

  function self:edit_connection()
    local state = self.active
    if not state or state.mode ~= 'inspect' then return false, 'Open command details first' end
    local command = self.registry:get(state.inspected_id)
    if not command then return false, 'Command is no longer registered' end
    local valid, why = require('command_tree.command_links').validate({ [command.id] = {} })
    if not valid then return false, why end
    local navigation, why = capture_settings_navigation(state)
    local ok, err = self:enter_workspace('settings', { section = 'commands', entity = command.id })
    if ok then
      state.settings_navigation = navigation
      if why then state.message = why .. '; settings can still be edited' end
    end
    return ok, err
  end

  function self:availability_action(key)
    local state = self.active
    local availability = require("command_tree.availability")
    local valid, reason = availability.validate(state.availability_receipt, state.availability_guard, state, self.registry)
    if not valid then state.message = reason; return false, reason end
    if key == "c" and not (state.availability_report and state.availability_report.backend_settings) then
      return false, "This command has no backend Settings route"
    end
    local command = state.availability_command
    if key == "r" then
      state.availability_report = availability.report(command, state.ctx, self.registry, { integrations = self.options.integrations })
      state.message = "Status rechecked; no command was executed"
      return true
    end
    self:pop_mode()
    state.availability_receipt, state.availability_guard, state.availability_report, state.availability_command = nil, nil, nil, nil
    if key == "c" then return self:configure_backend() end
    local enabled, why = self.registry:available(command.id, state.ctx)
    state.message = enabled and "Returned to command details; press Enter when ready to run" or why
    return true
  end

  -- Every entry suspends shared authority, including another Session's calls.
  -- Only the lexical Input callback below can supply a captured submission.
  local function run_scoped(submission, id, args, route, done, prepared, context, process_target)
    local previous = active_execution
    active_execution = nil
    local boundary = submission and function(command) return execution_scope(self, submission, command) end
    local ok, accepted, detail, operation = pcall(Dispatch.run, self, id, args, route, done,
      prepared, context, process_target, boundary)
    active_execution = previous
    if not ok then error(accepted, 0) end
    return accepted, detail, operation
  end

  function self:run(id, args, route, done, prepared, context, process_target)
    return run_scoped(nil, id, args, route, done, prepared, context, process_target)
  end

  local function dispatch_submission(input, done)
    local submission = { owner = self, state = self.active, input = input,
      context = vim.deepcopy(input.context), args = vim.deepcopy(input.args) }
    return run_scoped(submission, input.command.id, input.args, nil, done, true, input.context)
  end

  function self:cycle_density()
    local state = self.active
    local pending_settings = false
    for _, frame in ipairs(state.stack or {}) do
      if frame.id == 'settings' and (state.mode == 'input' and state.input and state.input.callback
        or frame.data.draft and #require('command_tree.settings.transaction').changes(frame) > 0) then
        pending_settings = true; break
      end
    end
    if self.options.presentation then
      local Core, Data = require('command_environment.core.presentation'), require('command_tree.presentation_data')
      local ids = { 'full', 'compact', 'minimal' }
      for _, id in ipairs(assert(Core.ids(Data.core(self.options.presentation)))) do
        if id ~= 'full' and id ~= 'compact' and id ~= 'minimal' then ids[#ids + 1] = id end
      end
      local current = state.presentation_id or state.density
      local index = 0
      for i, id in ipairs(ids) do if id == current then index = i; break end end
      local id = ids[index % #ids + 1]
      local resolved = assert(Core.resolve(Data.core(self.options.presentation), id, 'tree', { density = state.density }))
      state.presentation_id, state.density = id, resolved.layout.density
      if pending_settings then return end
      self.options.presentation.selected = id
      if self.select_presentation then
        local ok, err = self.select_presentation(id)
        if not ok then state.message = 'View changed for this session; saving failed: ' .. tostring(err) end
        if ok then
          local status = require('re35').persistence_status().profile
          state.message = status.scope == 'startup' and 'View saved · restored at startup' or 'View changed · this session only'
        end
      end
      return
    end
    local next_density = { full = "compact", compact = "minimal", minimal = "full" }
    state.density = next_density[state.density] or "full"
    if pending_settings then return end
    self.options.window.density = state.density
    if self.preferences then
      local ok, err = self.preferences:set("density", state.density)
      if not ok then state.message = "View changed for this session; saving failed: " .. tostring(err) end
      if ok then
        local status = require('re35').persistence_status().profile
        state.message = status.scope == 'startup' and 'View saved · restored at startup' or 'View changed · this session only'
      end
    end
  end

  function self:handle(key, raw)
    local state = self.active
    if not state then return end
    local workspace_input = state.mode == "workspace" and self.workspaces.input_active and self.workspaces:input_active(state)
    local shortcut_input = workspace_input or state.mode == "selector" and state.selector_filtering
    raw = raw or (key:match("^<.*>$") and K.raw(key) or key)
    local editing = workspace_input or state.mode == "search" or state.mode == "words"
      or state.mode == "selector" and state.selector_filtering
      or state.mode == "input" and (not state.input.choices or state.input.filtering)
    if not editing then
      if key == "<BS>" then key = "<Esc>"
      elseif state.mode ~= "keymaps" and key == "<Left>" then key = "<Esc>"
      elseif state.mode ~= "keymaps" and key == "<Right>" then key = "<CR>" end
    end
    if key == self.options.keys.details_down or key == self.options.keys.details_up then
      local view = state.view
      if state.mode == 'workspace' then
        local frame = self.workspaces:active(state)
        view = frame and frame.view or view
        if frame and frame.id == 'history' then view = frame.data.timeline and frame.data.timeline_view or frame.data.hud end
      end
      local amount = math.max(1, view and view.details and (view.details.visible or 1) - 1 or 1)
      if V.scroll_details and V.scroll_details(view, key == self.options.keys.details_down and amount or -amount) then
        self:draw()
        return
      end
    end
    state.message = nil
    if state.mode == 'feedback' then
      local function scroll(delta)
        if not V.scroll_details or not V.scroll_details(state.view, delta) then
          state.feedback_offset = math.max(1, math.min(state.feedback_rows or 1, (state.feedback_offset or 1) + delta))
        end
      end
      if key == '<C-c>' or key == self.options.keys.close then self:close()
      elseif key == '<Esc>' then self:back()
      elseif key == '<Down>' or key == '<C-n>' or key == 'j' then
        scroll(1)
      elseif key == '<Up>' or key == '<C-p>' or key == 'k' then
        scroll(-1)
      elseif key == '<C-d>' or key == '<PageDown>' then
        scroll(6)
      elseif key == '<C-u>' or key == '<PageUp>' then
        scroll(-6)
      end
      self:draw()
      return
    end
    if state.busy and not (state.mode == "input" and state.input.callback) then state.navigation = (state.navigation or 0) + 1 end
    if state.literal and (state.mode == "input" or state.mode == "search" or state.mode == "words") then
      state.literal = false
      local text = text_key(key, raw)
      if text then
        if state.mode == "input" then
          local input = state.input
          if input.choices and input.filtering then input.filter, input.filter_cursor = Text.edit(input.filter, input.filter_cursor, key, raw); self:filter_choices()
          elseif not input.choices then input.text, input.cursor = Text.edit(input.text, input.cursor, key, raw); input.completion = nil; self:preview_input() end
        else state.query, state.query_cursor = Text.edit(state.query, state.query_cursor, key, raw); state.selected_id = nil end
      end
    elseif key == "<C-c>" or key == self.options.keys.close then
      local ctx = state.ctx
      self:close()
      if ctx.mode == "o" then vim.api.nvim_feedkeys(K.raw("<Esc>"), "ni", false) end
    elseif state.mode == "keymaps" and (key == self.options.keys.detail or key == "<F1>") and not guide_owns_key(state, key) then self:cycle_density()
    elseif (key == self.options.keys.detail and not shortcut_input and state.mode ~= "keymaps" and state.mode ~= "search" and state.mode ~= "words" and (state.mode ~= "input" or (state.input.choices and not state.input.filtering))) or (key == "<F1>" and state.mode ~= "keymaps") then self:cycle_density()
    elseif state.busy and key == "<C-x>" and state.operation and state.mode ~= "workspace" and not (state.mode == "input" and state.input.callback) then
      local ok, err = state.operation:cancel()
      if not ok then state.message = err
      elseif state.operation.status == "pending" then state.message = err or "Cancellation requested; waiting for backend completion"
      else state.message = "Task cancelled" end
    elseif key == self.options.keys.workspaces and not shortcut_input and state.mode ~= "keymaps" and (state.mode ~= "input" or state.busy and not state.input.callback) then self:push_mode("selector", { query = "", query_cursor = 0, selector_filtering = false })
    elseif key == (self.options.keys.words or "<C-l>") and not shortcut_input and state.mode ~= "keymaps" and (state.mode ~= "input" or state.busy and not state.input.callback) then
      self:push_mode("words", { query = "", query_cursor = 0, filter = false })
    elseif key == (self.options.keys.inspect or "<C-h>") and (state.mode == "tree" or state.mode == "search" or state.mode == "words" or state.mode == "input" or state.mode == "review") then self:inspect()
    elseif state.mode == "workspace" and self.workspaces:handle(state, key, self.options) then
      -- Workspace-local navigation (including a nested picker) gets first Back.
    elseif state.mode == "keymaps" and key == "<Esc>" then
      local ctx = state.ctx
      self:close()
      if ctx.mode == "o" then vim.api.nvim_feedkeys(K.raw("<Esc>"), "ni", false) end
    elseif key == "<Esc>" then self:back()
    elseif state.mode == "availability" and (key == "r" or key == "<CR>" or key == "c") then
      local ok, why = self:availability_action(key)
      if not ok then state.message = why end
    elseif state.mode == "inspect" and key == "s" then
      local ok, why = self:inspect_availability()
      if not ok then state.message = why end
    elseif state.mode == 'inspect' and key == 'e' then
      local ok, why = self:edit_connection()
      if not ok then state.message = why end
    elseif state.mode == "inspect" and key == "c" then
      local ok, why = self:configure_backend()
      if not ok then state.message = why end
    elseif state.mode == "inspect" and key == "<CR>" then
      if state.recovered_query_command and state.recovered_query_id == state.inspected_id then
        if self.registry:get(state.inspected_id) ~= state.recovered_query_command then
          state.message = "The command changed after recovery; reopen it before running"
        else
          local valid,why=require('command_tree.backend_editor').validate_recovery(state.recovered_query_receipt,state.ctx)
          if not valid then state.message=why else
            local query = state.recovered_query
            state.recovered_query_command, state.recovered_query, state.recovered_query_id, state.recovered_query_receipt = nil, nil, nil, nil
            self:run(state.inspected_id, { query = query })
          end
        end
      else self:run(state.inspected_id) end
    elseif state.mode == "review" then
      local input, count = state.input, #state.input.command.arguments
      if key == "<Down>" or key == "<C-n>" or key == "j" then input.review_selected = Lists.move(input.review_selected or count + 1, count + 1, 1, self.options.navigation)
      elseif key == "<Up>" or key == "<C-p>" or key == "k" then input.review_selected = Lists.move(input.review_selected or count + 1, count + 1, -1, self.options.navigation)
      elseif key == "<CR>" then
        if input.review_selected == count + 1 then self:execute_review()
        else state.mode, input.index, input.editing_review = "input", input.review_selected, true; self:input_field() end
      elseif key:match("^[1-9]$") and tonumber(key) <= count then
        state.mode, input.index, input.editing_review = "input", tonumber(key), true; self:input_field()
      end
    elseif state.mode == "input" then
      local input, field = state.input, state.input.command.arguments[state.input.index]
      if key == "<CR>" then
        self:accept_input(false)
      elseif key == "<C-s>" and not input.callback then self:accept_input(true)
      elseif input.choices then
        if key == "<Down>" or key == "<C-n>" or (not input.filtering and key == "j") then input.selected = Lists.move(input.selected, #input.choices, 1, self.options.navigation)
        elseif key == "<Up>" or key == "<C-p>" or (not input.filtering and key == "k") then input.selected = Lists.move(input.selected, #input.choices, -1, self.options.navigation)
        elseif not input.filtering and key == "/" then input.filtering = true
        elseif not input.filtering and key == "<Space>" and field.kind == "multiselect" then
          local item = input.choices[input.selected]
          if item then
            local value = A.value(item)
            local index = A.contains(input.checked, value)
            if index then table.remove(input.checked, index) else input.checked[#input.checked + 1] = value end
          end
        elseif input.filtering then
          if key == "<C-v>" then state.literal = true
          else input.filter, input.filter_cursor = Text.edit(input.filter, input.filter_cursor, key, raw); self:filter_choices() end
        end
        self:preview_input()
      elseif key == "<C-v>" then state.literal = true
      elseif key == "<Tab>" then self:complete_input()
      elseif key == "<Up>" then self:browse_input_history(1)
      elseif key == "<Down>" then self:browse_input_history(-1)
      else
        input.text, input.cursor = Text.edit(input.text, input.cursor, key, raw)
        input.completion, input.history_index = nil, nil
        self:preview_input()
      end
    elseif state.mode == "search" or state.mode == "words" or state.mode == "selector" then
      local results = state.mode ~= "selector" and self:results() or self:workspace_choices()
      if key == "<Down>" or key == "<C-n>" or (state.mode == "selector" and not state.selector_filtering and key == "j") then state.selected = Lists.move(state.selected, #results, 1, self.options.navigation)
      elseif key == "<Up>" or key == "<C-p>" or (state.mode == "selector" and not state.selector_filtering and key == "k") then state.selected = Lists.move(state.selected, #results, -1, self.options.navigation)
      elseif key == "<Tab>" and state.mode == "words" and results[state.selected] then
        state.query = results[state.selected].word_path or state.query
        state.query_cursor, state.selected_id = vim.fn.strchars(state.query), nil
      elseif key == "<CR>" and state.mode == "words" and self.registry:resolve_word(state.query or "") then
        local resolved = self.registry:resolve_word(state.query or "")
        self:run(type(resolved) == "table" and resolved.id or resolved)
      elseif key == "<CR>" and results[state.selected] then
        if state.mode == "selector" then
          local workspace = results[state.selected]
          local entered, err = self:enter_workspace(workspace.id)
          if not entered then state.message = err end
        else self:run(results[state.selected].id) end
      elseif state.mode == "selector" then
        if not state.selector_filtering and key == "/" then
          state.selector_filtering = true
          state.query_cursor = vim.fn.strchars(state.query or "")
        elseif state.selector_filtering then
          state.query, state.query_cursor = Text.edit(state.query or "", state.query_cursor, key, raw)
          state.selected = 1
        end
      elseif state.mode == "search" or state.mode == "words" then
        if key == self.options.keys.favorite and results[state.selected] then
          local result = results[state.selected]
          local persistent = result.command.persistent ~= false
          local enabled, err = self.usage:toggle(result.id, persistent)
          state.message = err and ("Favorite could not be saved: " .. tostring(err))
            or enabled and (persistent and "Added to favorites" or "Favorited for this Neovim session") or "Removed from favorites"
        elseif key == "<C-v>" then state.literal = true
        else state.query, state.query_cursor = Text.edit(state.query or "", state.query_cursor, key, raw); state.selected, state.selected_id = 1, nil end
      end
      if (state.mode == "search" or state.mode == "words") and (key == "<Down>" or key == "<Up>" or key == "<C-n>" or key == "<C-p>") then
        state.selected_id = results[state.selected] and results[state.selected].id
        state.selected_word = state.mode == "words" and results[state.selected] and results[state.selected].word_path or nil
      end
    elseif state.mode ~= "keymaps" and key == self.options.keys.search then self:push_mode("search", { query = "", filter = false })
    elseif state.mode ~= "keymaps" and key == self.options.keys.workspaces then self:push_mode("selector", { query = "", query_cursor = 0, selector_filtering = false })
    elseif state.mode ~= "keymaps" and key == self.options.keys.recent then self:push_mode("search", { query = "", filter = "recent" })
    elseif state.mode ~= "keymaps" and key == self.options.keys.favorites then self:push_mode("search", { query = "", filter = "favorites" })
    elseif state.mode ~= "keymaps" and key == self.options.keys.detail then self:cycle_density()
    elseif key == "<BS>" then self:back()
    elseif key == "<C-d>" or key == "<C-u>" then state.page = math.max(1, math.min(state.pages or 1, state.page + (key == "<C-d>" and 1 or -1)))
    elseif state.mode == "tree" then
      if key == "<Down>" or key == "<Up>" then
        state.tree_selected_entry = nil
        state.tree_selection = state.tree_selection and Lists.move(state.tree_selection, #(state.tree_items or {}), key == '<Down>' and 1 or -1, self.options.navigation) or 1
        self:draw(); return
      elseif key == "<CR>" and state.tree_items and state.tree_items[state.tree_selection or 1] then
        if not state.tree_selection then
          -- Enter selects the first visible row before it can execute.
          -- This keeps Minimal's idle strip bare while all densities share
          -- the same explicit-selection rule.
          state.tree_selection, state.tree_selected_entry = math.max(1, math.min(state.view.visible_first or 1, #state.tree_items)), nil
          self:draw(); return
        end
        local selected = state.tree_items[state.tree_selection]
        if selected.group then state.path, state.page, state.tree_selection = copy_path(selected.path), 1, nil; state.navigation = (state.navigation or 0) + 1
        elseif selected.id then self:run(selected.id, nil, selected.path) end
        self:draw(); return
      end
      if #state.path == 0 and self.options.quick_slots ~= false and key:match("^[1-9]$") and self.usage.slot then
        local id = self.usage:slot(tonumber(key))
        if id then self:run(id) else state.message = "Quick slot " .. key .. " is empty; assign it in Settings" end
        self:draw(); return
      end
      local node = self.registry:node(state.path)
      if not node then state.path = {}; state.message = "Path is no longer registered"
      elseif key == self.options.keys.execute then
        if node.command_id and not (self.registry.hidden and self.registry:hidden(node.command_id)) then self:run(node.command_id) else state.message = "This group has no visible default command" end
      else
        local child = node.children and node.children[key]
        if not child or (child.command_id and self.registry.hidden and self.registry:hidden(child.command_id) and not has_children(child)) then state.message = "No command for " .. K.label(key)
        elseif has_children(child) then state.path[#state.path + 1], state.page, state.tree_selection = key, 1, nil; state.navigation = (state.navigation or 0) + 1
        elseif child.command_id then
          local route = copy_path(state.path)
          route[#route + 1] = key
          self:run(child.command_id, nil, route)
        end
      end
    elseif state.mode == "keymaps" then
      local node = Maps.node(state.keymap_root, state.path)
      local child = node and node.children and node.children[key]
      if key == "timeout" or (key == "<CR>" and node and node.native and not child) then
        local ctx, replay = state.ctx, K.raw(table.concat(state.path))
        self:close(); self.triggers.replay(replay, ctx, true)
      elseif has_children(child) then state.path[#state.path + 1], state.page = key, 1
      else
        local ctx, replay = state.ctx, K.raw(table.concat(state.path)) .. raw
        self:close(); self.triggers.replay(replay, ctx, child and child.native or false)
      end
    end
    self:draw()
  end

  function self:refresh()
    local state = self.active
    if not state then return end
    state.search_cache = nil
    if not K.valid(state.ctx) then self:close(); return end
    if state.mode == "keymaps" then state.keymap_root = Maps.collect(state.ctx, self.options) end
    self:draw()
  end

  function self:open(opts)
    opts = opts or {}
    if self.active then self:close(); return end
    local ctx = opts.context or K.context(opts.mode)
    local settings_return, settings_return_error
    if opts.settings_navigation then
      settings_return, settings_return_error = validate_settings_navigation(opts.settings_navigation, ctx)
      if not settings_return then ctx = K.context() end
    end
    if not K.valid(ctx) then return end
    local state = { ctx = ctx, mode = opts.kind or "tree", path = K.tokens(opts.keys or ""), view = {},
      frames = {}, stack = {}, workspace_returns = {}, running = true, selected = 1, page = 1, navigation = 0,
      visible = not opts.automatic, automatic = opts.automatic, opened = vim.uv.hrtime(),
      density = self.preferences and self.preferences:get("density", self.options.window.density) or self.options.window.density, delay = opts.automatic and self.options.delay or 0,
      hud_visible = self.options.history.visible }
    self.active = state
    if self.options.presentation then
      local Core, Data = require('command_environment.core.presentation'), require('command_tree.presentation_data')
      local config = Data.core(self.options.presentation)
      state.presentation_id = config.selected or state.density
      local model = assert(Core.resolve(config, state.presentation_id, 'tree', { density = state.density }))
      state.density = model.layout.density
    end
    state.workspace_registry = self.registry
    state.workspace_execute = function(id, args, context) return self:run(id, args, nil, nil, false, context) end
    state.workspace_input = function(options, callback, context) return self:request_input(options, callback, context or state.ctx) end
    state.workspace_select = function(items, options, callback, context) return self:request(items, options, callback, context or state.ctx) end
    state.workspace_open = function(id, options)
      local ok, err = self:enter_workspace(id, options)
      if ok then self:draw() end
      return ok, err
    end
    state.workspace_back = function(frame)
      if self.active~=state or state.mode~='workspace' or state.stack[#state.stack]~=frame then
        return false,'Workspace navigation changed; reopen the owning task'
      end
      local ok,err=self:back()
      if ok==false then return false,err end
      if self.active~=state or state.stack[#state.stack]==frame then return false,err or 'Workspace could not return to its owner'end
      self:draw();return true
    end
    state.workspace_recover = function(receipt)
      local frame = state.stack[#state.stack]
      if self.active ~= state or state.mode ~= "workspace" or not frame or frame.id ~= "settings"
        or frame._backend_recovery_owner ~= state or frame._backend_recovery_navigation ~= state.navigation
        or not vim.deep_equal(frame.data.backend_recovery, receipt) then
        return false, "Command navigation changed; reopen the command instead of restoring this recovery"
      end
      if self.registry:get(receipt.command_id) ~= frame._backend_recovery_command then
        return false, "The original command changed; reopen its details before returning"
      end
      local valid, why = require("command_tree.backend_editor").validate_recovery(receipt, state.ctx)
      if not valid then return false, why end
      -- This is a navigation return. Opening Inspect never invokes its command.
      -- Keep the same input loop and source context while releasing all Settings resources.
      local cleaned = self.workspaces:clear(state)
      if not cleaned then
        state.mode, state.frames, state.workspace_returns = "tree", {}, {}
        return false, "Settings cleanup failed; reopen the original command"
      end
      state.workspace_returns, state.frames = {}, {}
      restore(state, vim.deepcopy(receipt.origin))
      if state.mode ~= "tree" then state.frames[1] = { mode = "tree", path = {}, page = 1, selected = 1 } end
      self:push_mode("inspect", { inspected_id = receipt.command_id })
      state.recovered_query, state.recovered_query_command = receipt.query, receipt.query and self.registry:get(receipt.command_id) or nil
      state.recovered_query_id = receipt.query and receipt.command_id or nil
      state.recovered_query_receipt = receipt.query and vim.deepcopy(receipt) or nil
      state.message = "Returned to the original command; press Enter to run explicitly"
      self:draw()
      return true
    end
    state.workspace_navigate = function(item, context)
      local origin = context or state.ctx
      self:close()
      return require("command_tree.results").jump(item, origin)
    end
    state.original_paste = vim.paste
    state.paste_handler = function(lines, phase)
      if self.active ~= state then return state.original_paste(lines, phase) end
      if state.mode == "keymaps" then
        self:close()
        return state.original_paste(lines, phase)
      end
      if phase == -1 or phase == 1 then state.paste_text = "" end
      state.paste_text = (state.paste_text or "") .. table.concat(lines, "\n")
      if #state.paste_text > 1048576 then
        state.paste_text, state.message = nil, "Paste exceeds the 1 MiB input limit"
        self:draw()
        return false
      end
      if phase == -1 or phase == 3 then
        local value = state.paste_text
        state.paste_text = nil
        local ok, err = pcall(self.paste, self, { value })
        if not ok then state.message = "Paste: " .. tostring(err); self:draw(); return false end
      end
      return true
    end
    vim.paste = state.paste_handler
    local prepared, failure = xpcall(function()
      if state.mode == "keymaps" then state.keymap_root = Maps.collect(ctx, self.options) end
      if state.mode == "search" or state.mode == "words" or state.mode == "selector" then
        state.frames[1] = { mode = "tree", path = {}, page = 1, selected = 1 }
        state.query, state.filter = opts.search or "", false
      end
      if opts.workspace or opts.history then
        local frame, err = self.workspaces:push(state, opts.workspace or "history", opts.workspace_data)
        if frame then
          state.workspace_returns[1] = snapshot(state); state.mode = "workspace"
          if frame.id == 'settings' and settings_return then
            state.settings_navigation = opts.settings_navigation
            state.frames = vim.deepcopy(settings_return.frames)
            state.workspace_returns[1] = vim.deepcopy(settings_return.origin)
          elseif settings_return_error then
            state.settings_navigation_error = settings_return_error
            frame.data.message = (frame.data.message and frame.data.message .. ' · ' or '') .. settings_return_error
            state.message = settings_return_error
          end
          if frame.definition._extension_ready then frame.definition._extension_ready(frame) end
        else state.message = err end
      end
      if opts.on_open then
        assert(type(opts.on_open) == "function", "on_open must be a function")
        opts.on_open(state)
        if self.active ~= state then return end
      end
      if opts.command then state.execute_result = { self:run(opts.command, opts.args, nil, opts.done, false, nil, opts.process_target) } end
      if opts.search ~= nil and self.active and state.mode ~= "search" then self:push_mode("search", { query = opts.search, filter = false }) end
      self:draw()
    end, debug.traceback)
    if not prepared then state.message = tostring(failure); self:draw() end
    if opts.interactive == false or not self.active then return state end
    local ok, err = xpcall(function()
      while self.active == state and state.running do
        if not K.valid(ctx) or vim.api.nvim_get_current_win() ~= ctx.win then break end
        local started = vim.uv.hrtime()
        local node = state.mode == "keymaps" and Maps.node(state.keymap_root, state.path)
        local timeout = state.automatic and node and node.native and has_children(node) and vim.o.timeout and vim.o.timeoutlen
        while self.active == state do
          local raw = vim.fn.getcharstr(0)
          if raw ~= "" then self:handle(K.tokens(raw, true)[1], raw); break end
          if not state.visible and (vim.uv.hrtime() - state.opened) / 1e6 >= state.delay then state.visible = true; self:draw() end
          if timeout and (vim.uv.hrtime() - started) / 1e6 >= timeout then self:handle("timeout"); break end
          if not K.valid(ctx) or vim.api.nvim_get_current_win() ~= ctx.win then self:close(); break end
          vim.wait(10, function() return self.active ~= state end, 10)
        end
      end
    end, debug.traceback)
    if self.active == state then self:close() end
    if not ok and not tostring(err):match("[Ii]nterrupt") then vim.notify(err, vim.log.levels.ERROR, { title = "Command Environment" }) end
    return state
  end

  function self:state()
    local state = self.active
    if not state then return { active = false } end
    local workspaces = {}
    for _, frame in ipairs(state.stack) do workspaces[#workspaces + 1] = frame.id end
    return { active = true, kind = state.mode, context = vim.deepcopy(state.ctx), path = copy_path(state.path),
      visible = state.visible, density = state.density, presentation_id = state.presentation_id, query = state.query, selected = state.selected,
      page = state.page, message = state.message, busy = state.busy, workspaces = workspaces, window = state.view.win, buffer = state.view.buf,
      details_window = state.view.details and state.view.details.win,
      panels = state.view.panel_report and vim.deepcopy(state.view.panel_report) or nil }
  end

  Navigation.attach(self)
  Feedback.attach(self)
  Input.attach(self, dispatch_submission)
  Presenter.attach(self)

  local handle = self.handle
  function self:handle(key, raw)
    local ok, err = xpcall(function() handle(self, key, raw) end, debug.traceback)
    if not ok and self.active then
      self:record_feedback('Interaction', err)
      local rendered = pcall(self.draw, self)
      if not rendered then self:close(); vim.notify(tostring(err), vim.log.levels.ERROR) end
    end
  end
  return self
end

return M
