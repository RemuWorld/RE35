-- Optional asynchronous picker presentation. Executable argument membership
-- remains field.items; a view's filtered choices never grant execution rights.
local A = require('command_tree.arguments')
local M = {}

function M.attach(self, current, control_call, context)
  function self:release_input_choices(input, state)
    state = state or self.active
    local entry = state and state.choice_sources and state.choice_sources[input]
    if not entry then return end
    state.choice_sources[input] = nil
    entry.retired = true
    if entry.cleanup then
      local cleanup = entry.cleanup
      entry.cleanup = nil
      local ok, why = pcall(cleanup)
      if not ok and self.active == state then self:record_feedback('Choice subscription cleanup', why, input.command) end
    end
  end

  function self:release_all_input_choices(state)
    local pending = {}
    for input in pairs(state and state.choice_sources or {}) do pending[#pending + 1] = input end
    for _, input in ipairs(pending) do self:release_input_choices(input, state) end
  end

  function self:load_input_choices()
    local state, input = self.active, self.active and self.active.input
    if not input then return nil end
    local command, ctx, attachment, index = input.command, context(state), state.input_attachment, input.index
    local field = command.arguments[index]
    local choices, handled
    if not input.callback and command.input_ui and command.input_ui.choices and not input.choice_domain then
      local domain = A.items(field, ctx, input.args)
      if not current(state, input, command, ctx, attachment, index) then return nil end
      input.choice_domain = domain
    end
    if not input.callback then choices, handled = control_call(state, input, 'choices', field.name) end
    if not handled then choices = A.items(field, ctx, input.args) end
    if input.callback then
      if self.active ~= state or state.input ~= input then return nil end
    elseif not current(state, input, command, ctx, attachment, index) then return nil end
    if choices == nil and handled then return nil end
    assert(type(choices) == 'table' and vim.islist(choices), 'Picker choices must be an array')
    return choices
  end

  function self:refresh_input_choices(preview)
    local state, input = self.active, self.active and self.active.input
    if not input or not input.choices or input.callback then return false end
    if not current(state, input, input.command, context(state)) then return false end
    local old = input.choices[input.selected]
    local ok, choices = pcall(self.load_input_choices, self)
    if not ok then self:record_feedback('Choice refresh', choices, input.command); return false end
    if not choices then return false end
    input.all_choices = choices
    self:filter_choices(false)
    if not input.choice_touched and input.preferred_choice ~= nil then
      for index, item in ipairs(input.choices) do
        if vim.deep_equal(A.value(item), input.preferred_choice) then input.selected = index; break end
      end
    end
    local selected = input.choices[input.selected]
    if preview ~= false and (old and not selected or selected and not old or old and selected and not vim.deep_equal(A.value(old), A.value(selected))) then
      self:preview_input()
    end
    input.choices_dirty = nil
    return true
  end

  function self:subscribe_input_choices()
    local state, input = self.active, self.active and self.active.input
    local controls = input and not input.callback and input.command.input_ui
    if not controls or type(controls.subscribe) ~= 'function' then return end
    local command, ctx, attachment, index = input.command, context(state), state.input_attachment, input.index
    state.choice_sources = state.choice_sources or {}
    local entry = {}
    state.choice_sources[input] = entry
    local function owned()
      return not entry.retired and self:is_attached(state, attachment) and state.input == input and not input.retired
        and input.index == index and self.registry:get(command.id) == command and context(state) == ctx
    end
    local function notify()
      if not owned() or entry.scheduled then return end
      entry.scheduled = true
      vim.schedule(function()
        entry.scheduled = nil
        if not owned() then
          if state.choice_sources and state.choice_sources[input] == entry then self:release_input_choices(input, state) end
          return
        end
        input.choices_dirty = true
        if state.mode ~= 'input' then return end
        if self:refresh_input_choices() then self:draw() end
      end)
    end
    local ok, cleanup = pcall(vim.api.nvim_win_call, ctx.win, function()
      return controls.subscribe(vim.deepcopy(ctx), vim.deepcopy(input.args), notify)
    end)
    if not owned() then if ok and type(cleanup) == 'function' then pcall(cleanup) end; return end
    if not ok then self:release_input_choices(input, state); self:record_feedback('Choice subscription', cleanup, command)
    elseif cleanup ~= nil and type(cleanup) ~= 'function' then
      self:release_input_choices(input, state)
      self:record_feedback('Choice subscription', 'Choice subscriptions must return cleanup or nil', command)
    else entry.cleanup = cleanup end
  end
end

return M
