-- Input owns forms, completion, preview, drafts and text editing.
local K = require('command_tree.keys')
local A = require('command_tree.arguments')
local Text = require('command_tree.text')
local M = {}
local function field_value(input)
  local field = input.command.arguments[input.index]
  if field.kind == "multiselect" then return vim.deepcopy(input.checked or {}) end
  if input.choices then return A.value(input.choices[input.selected]) end
  return A.coerce(field, input.text)
end
local function input_context(state)
  return state.input and state.input.context or state.ctx
end
M.value, M.context = field_value, input_context

function M.attach(self, dispatch_submission)
  local function refresh_presentation(state, input)
    if state.view.presentation_options then
      local mode = state.mode
      -- A resize can happen while getchar waits. Recheck the actual display
      -- before accepting a named-preset form, retaining its original owner.
      self:draw()
      return self.active == state and state.input == input and state.mode == mode
    end
    return true
  end
  local function validate_form(state, input, ctx)
    if not K.valid(ctx) then state.message = "Input target changed; reopen the command"; return false end
    if state.busy then state.message = "Another command is running; wait before submitting these arguments"; return false end
    if self.registry:get(input.command.id) ~= input.command then
      state.message = "Command changed while editing; reopen it to validate the new inputs"
      return false
    end
    for index, field in ipairs(input.command.arguments) do
      local valid, why = A.validate(field, input.args[field.name], ctx, input.args)
      if not valid then
        state.mode, input.index, input.editing_review = "input", index, true
        self:input_field(); state.message = why
        return false
      end
    end
    return true
  end
  function self:preview_input()
    local state = self.active
    if not state or not state.input or not self:clear_preview() then return end
    local command, input = state.input.command, state.input
    local ctx = input_context(state)
    if not K.valid(ctx) then state.message = "Input target changed; reopen the command"; return end
    if input.callback then
      if type(input.preview) == "function" then
        local ok, cleanup = pcall(vim.api.nvim_win_call, ctx.win, function() return input.preview(field_value(input), ctx) end)
        if ok then
          self:clear_feedback('Preview')
          if type(cleanup) == 'function' then state.preview_cleanup = cleanup end
        else self:record_feedback('Preview', cleanup, command) end
      end
      return
    end
    if type(command.preview) ~= "function" then return end
    local args = vim.deepcopy(input.args)
    local field = command.arguments[input.index]
    args[field.name] = field_value(input)
    local ok, cleanup = pcall(vim.api.nvim_win_call, ctx.win, function() return command.preview(ctx, args) end)
    if ok then
      self:clear_feedback('Preview')
      if type(cleanup) == 'function' then state.preview_cleanup = cleanup end
    else self:record_feedback('Preview', cleanup, command) end
  end

  function self:input_field()
    local state, input = self.active, self.active.input
    local ctx = input_context(state)
    assert(K.valid(ctx), "Input target changed; reopen the command")
    local field = input.command.arguments[input.index]
    local value = input.drafts[field.name]
    if value == nil then value = input.args[field.name] end
    if value == nil then value = A.default(field, ctx, input.args) end
    input.text, input.selected, input.choices = value == nil and "" or tostring(value), 1, nil
    input.all_choices, input.filtering, input.filter, input.filter_cursor, input.completion = nil, false, "", 0, nil
    input.history_index, input.history_draft = nil, nil
    input.checked = field.kind == "multiselect" and vim.deepcopy(value or {}) or nil
    input.cursor = vim.fn.strchars(input.text)
    if field.kind == "select" or field.kind == "boolean" or field.kind == "multiselect" then
      input.choices = A.items(field, ctx, input.args)
      input.all_choices = input.choices
      if #input.choices == 0 then state.message = field.empty_message or "No choices are available"; return end
      for i, item in ipairs(input.choices) do if vim.deep_equal(A.value(item), value) then input.selected = i end end
    end
    state.message = nil
    self:preview_input()
  end

  function self:filter_choices()
    local input = self.active.input
    local selected = input.choices and input.choices[input.selected]
    local needle = vim.fn.tolower(input.filter or "")
    input.choices = vim.tbl_filter(function(item) return vim.fn.tolower(A.label(item)):find(needle, 1, true) ~= nil end, input.all_choices or {})
    input.selected = math.max(1, math.min(input.selected or 1, #input.choices))
    if selected then
      for index, item in ipairs(input.choices) do
        if vim.deep_equal(A.value(item), A.value(selected)) then input.selected = index; break end
      end
    end
    self:preview_input()
  end

  function self:request_field(field, options, callback, context)
    local state = self.active
    if not state then callback(nil); return end
    local origin = state.input
    self:push_mode("input")
    local input = { command = { name = options.prompt or "Input", arguments = { field } },
      args = {}, drafts = {}, index = 1, callback = callback, preview = options.preview,
      context = vim.deepcopy(context or state.ctx) }
    state.input = input
    local cleaned = false
    input.cleanup = function()
      if cleaned then return end
      cleaned = true
      input.callback = nil
      if self.active == state and state.input == input then
        self:clear_preview()
        self:pop_mode(true)
        state.input = origin
      end
    end
    local ok, err = pcall(self.input_field, self)
    if not ok then input.cleanup(); error(err) end
    self:draw()
    return input.cleanup
  end

  function self:request(items, options, callback, context)
    assert(type(items) == "table" and vim.islist(items), "Selection items must be an array")
    if #items == 0 then callback(nil); return end
    local choices = {}
    for _, item in ipairs(items) do choices[#choices + 1] = { label = options.format_item and options.format_item(item) or tostring(item), value = item } end
    return self:request_field({ name = "choice", kind = "select", prompt = options.prompt or "Select", items = choices }, options, callback, context)
  end

  function self:request_input(options, callback, context)
    local field = vim.tbl_extend("force", {}, options, { name = "value", kind = options.kind or "text" })
    return self:request_field(field, options, callback, context)
  end

  function self:accept_input(skip)
    local state, input = self.active, self.active.input
    if not refresh_presentation(state, input) then return end
    if state.view.presentation_input_complete == false then
      state.message = state.view.presentation_input_reason
      return false, state.message
    end
    local ctx = input_context(state)
    if not K.valid(ctx) then state.message = "Input target changed; reopen the command"; return end
    if not input.callback and self.registry:get(input.command.id) ~= input.command then
      state.message = "Command changed while editing; reopen it to validate the new inputs"
      return
    end
    local field = input.command.arguments[input.index]
    if skip and field.required then state.message = (field.prompt or field.name) .. " is required"; return end
    local value, coercion
    if not skip then value, coercion = field_value(input) end
    if coercion then state.message = coercion; return end
    if input.choices and field.kind ~= "multiselect" and #input.choices == 0 and not skip then
      state.message = field.empty_message or "No choices are available"; return
    end
    local valid, why = A.validate(field, value, ctx, input.args)
    if not valid then state.message = why; return end
    if input.callback then
      if not self:clear_preview() then return end
      local callback, index = input.callback, input.selected
      if input.all_choices then
        for i, item in ipairs(input.all_choices) do if vim.deep_equal(A.value(item), value) then index = i; break end end
      end
      input.cleanup()
      callback(value, index)
      return
    end
    if not skip and not input.choices and not field.secret and field.history ~= false and input.text ~= "" then
      local history_key = input.command.id .. "\0" .. field.name
      local values = self.input_history[history_key] or {}
      for i = #values, 1, -1 do if values[i] == input.text then table.remove(values, i) end end
      table.insert(values, 1, input.text)
      while #values > 20 do table.remove(values) end
      self.input_history[history_key] = values
    end
    input.args[field.name], input.drafts[field.name] = value, value
    if input.command.review_policy == 'explicit_apply' and input.index == #input.command.arguments
      and field.kind == 'boolean' and field.required and dispatch_submission then
      if not validate_form(state, input, ctx) or not self:clear_preview() then return end
      local done = input.done
      input.done = nil
      if value == false then
        self.drafts:save(input.command, input, ctx)
        state.input = nil
        self:pop_mode()
        if done then pcall(done, false, 'Cancelled') end
      else dispatch_submission(input, done) end
    elseif input.editing_review or (input.index == #input.command.arguments and #input.command.arguments >= 2) then
      if not self:clear_preview() then return end
      input.review_selected = input.editing_review and input.index or #input.command.arguments + 1
      input.editing_review, state.mode = nil, "review"
      state.message = nil
    elseif input.index == #input.command.arguments then
      local done = input.done
      input.done = nil
      if not self:clear_preview() then input.done = done; return end
      self:run(input.command.id, input.args, nil, done, true, input.context)
    else input.index = input.index + 1; self:input_field() end
  end

  function self:execute_review()
    local state, input = self.active, self.active.input
    if not refresh_presentation(state, input) then return end
    if state.view.presentation_review_complete == false then
      state.message = state.view.presentation_review_reason
      return false, state.message
    end
    local ctx = input_context(state)
    if not validate_form(state, input, ctx) then return end
    if not self:clear_preview() then return end
    local done = input.done
    input.done = nil
    self:run(input.command.id, input.args, nil, done, true, input.context)
  end

  function self:complete_input()
    local state = self.active
    if not state or state.mode ~= "input" or not state.input then return end
    local input, ctx = state.input, input_context(state)
    if not K.unchanged(ctx) then state.message = "Input target changed; reopen the command"; return end
    if not input.callback and self.registry:get(input.command.id) ~= input.command then
      input.completion, state.message = nil, "Command changed while editing; reopen it to validate the new inputs"
      return
    end
    local field = input.command.arguments[input.index]
    if not field then return end
    local completion = field.completion or (field.kind == "path" and "file")
    if not completion then return end
    local command, index, text, cursor = input.command, input.index, input.text, input.cursor
    local context, tick, filetype = vim.deepcopy(ctx), vim.api.nvim_buf_get_changedtick(ctx.buf), vim.bo[ctx.buf].filetype
    local function current()
      return self.active == state and state.mode == "input" and state.input == input
        and input.command == command and input.index == index and input.text == text and input.cursor == cursor
    end
    local function target_unchanged()
      return current() and vim.deep_equal(input_context(state), context) and K.valid(ctx)
        and vim.api.nvim_buf_get_changedtick(ctx.buf) == tick and vim.bo[ctx.buf].filetype == filetype
        and (input.callback or self.registry:get(command.id) == command)
    end
    if not input.completion then
      local ok, matches, edit = pcall(function()
        if type(completion) == "function" then return completion(input.text, ctx, input.args, { cursor = input.cursor }) end
        return vim.fn.getcompletion(input.text, completion)
      end)
      if not current() then return end
      if not target_unchanged() then state.message = "Completion target changed; reopen the command"; return end
      if not ok then self:record_feedback('Completion', matches, command); return end
      if type(matches) ~= "table" or not vim.islist(matches) then state.message = "Completion must return an array"; return end
      if #matches == 0 then state.message = "No completions"; return end
      for _, match in ipairs(matches) do if type(match) ~= "string" then state.message = "Completion choices must be text"; return end end
      local cursors, validate
      -- Unrelated historical second returns are ignored; this is additive metadata.
      if type(edit) == "table" and (edit.cursors ~= nil or edit.validate ~= nil) then
        if edit.cursors ~= nil and (type(edit.cursors) ~= "table" or not vim.islist(edit.cursors) or #edit.cursors ~= #matches) then
          state.message = "Completion cursor metadata must match its choices"; return
        end
        for match_index, match_cursor in ipairs(edit.cursors or {}) do
          if type(match_cursor) ~= "number" or match_cursor ~= match_cursor or match_cursor % 1 ~= 0 or match_cursor < 0 or match_cursor > vim.fn.strchars(matches[match_index]) then
            state.message = "Completion cursor is outside its text"; return
          end
        end
        cursors = edit.cursors
        if edit.validate ~= nil and type(edit.validate) ~= "function" then
          state.message = "Completion validator must be a function"; return
        end
        validate = edit.validate
      end
      input.completion = { matches = matches, cursors = cursors, validate = validate, index = 0 }
    end
    local completion_state = input.completion
    if completion_state.validate then
      local ok, valid, why = pcall(completion_state.validate)
      if not current() then return end
      if not target_unchanged() then input.completion, state.message = nil, "Completion target changed; reopen the command"; return end
      if not ok or valid ~= true then
        input.completion = nil
        self:record_feedback('Completion', ok and (why or "Command is no longer available") or valid, command)
        return
      end
    end
    completion_state.index = completion_state.index % #completion_state.matches + 1
    input.text = completion_state.matches[completion_state.index]
    input.cursor = completion_state.cursors and completion_state.cursors[completion_state.index] or vim.fn.strchars(input.text)
    self:preview_input()
  end

  function self:browse_input_history(direction)
    local input = self.active.input
    local field = input.command.arguments[input.index]
    if input.callback or field.secret or field.history == false then return end
    local values = self.input_history[input.command.id .. "\0" .. field.name] or {}
    if not input.history_index then input.history_index, input.history_draft = 0, input.text end
    input.history_index = math.max(0, math.min(#values, input.history_index + direction))
    input.text = input.history_index == 0 and input.history_draft or values[input.history_index]
    input.cursor, input.completion = vim.fn.strchars(input.text), nil
    self:preview_input()
  end

  function self:paste(lines)
    local state = self.active
    local value = table.concat(lines, "\n")
    if state.mode == "search" or state.mode == "words" or state.mode == "selector" and state.selector_filtering then
      value = value:gsub("[\r\n]", " ")
      state.query, state.query_cursor = Text.insert(state.query or "", state.query_cursor, value)
      state.selected, state.selected_id = 1, nil
    elseif state.mode == "input" then
      local input = state.input
      if value:find("[\r\n]") then state.message = "This field accepts one line; multiline paste was ignored"
      elseif input.choices and input.filtering then
        input.filter, input.filter_cursor = Text.insert(input.filter, input.filter_cursor, value)
        self:filter_choices()
      elseif not input.choices then
        input.text, input.cursor = Text.insert(input.text or "", input.cursor, value)
        input.completion, input.history_index = nil, nil
        self:preview_input()
      else state.message = "Press / to filter before pasting into a choice list" end
    else state.message = "Open an input or search field before pasting" end
    self:draw()
    return true
  end

end

return M
