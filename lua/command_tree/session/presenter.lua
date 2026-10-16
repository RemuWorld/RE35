-- Build the display model; rendering stays in command_tree.view.
local K = require('command_tree.keys')
local Maps = require('command_tree.mappings')
local V = require('command_tree.view')
local A = require('command_tree.arguments')
local Text = require('command_tree.text')
local Guide = require('command_tree.session.key_guide')
local Feedback = require('command_tree.session.feedback')
local has_children, guide_owns_key, path_label = Guide.has_children, Guide.owns_key, Guide.path_label
local function copy_path(path) return vim.deepcopy(path or {}) end
local M = {}
local function diagnostic_rows(record, width)
  local items = {}
  for _, line in ipairs(record.lines or {}) do
    local chunk, occupied = '', 0
    for char in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      local size = vim.fn.strdisplaywidth(char)
      if occupied + size > width and chunk ~= '' then
        items[#items + 1] = { key = '', name = chunk }; chunk, occupied = '', 0
      end
      chunk, occupied = chunk .. char, occupied + size
    end
    items[#items + 1] = { key = '', name = chunk }
  end
  return items
end

function M.attach(self)
  function self:command_details(command, enabled, reason, context)
    local state = self.active
    if not command then return nil end
    local ctx = context or state.ctx
    if enabled == nil then enabled, reason = self.registry:available(command.id, ctx) end
    local valid = K.valid(ctx)
    local target = valid and vim.api.nvim_buf_get_name(ctx.buf) or "[Unavailable source]"
    target = target == "" and "[No name]" or vim.fn.fnamemodify(target, ":~:.")
    return { kind = command.type or "action", description = command.description, id = command.id,
      target = target .. " · " .. (valid and vim.bo[ctx.buf].filetype ~= "" and vim.bo[ctx.buf].filetype or "plain text"),
      source = command.provider or "registered", reason = not enabled and (reason or "Unavailable") or nil }
  end

  function self:draw()
    local state = self.active
    if not state or not state.visible or not K.valid(state.ctx) then return end
    if state.mode == "workspace" then
      self.workspaces:draw(state, self.options)
      return
    end
    local opts = vim.tbl_extend("force", {}, self.options.window, { density = state.density })
    local data = { title = "Commands", path = self.options.open_key .. " " .. path_label(state.path),
      label = "Commands", items = {}, message = state.message, notice = Feedback.notice(state),
      page = state.page, diagnostic = Feedback.current(state),
      help = "Esc Back  ·  " .. K.label(self.options.keys.search) .. " Search  ·  " .. K.label(self.options.keys.detail) .. " View  ·  " .. self.options.open_key .. " Close" }
    if state.mode == "search" or state.mode == "words" then
      local words = state.mode == "words"
      data.title, data.label, data.query = words and "Paths" or "Search", words and "Word paths" or state.filter and (state.filter == "recent" and "Recent" or "Favorites") or "All commands", Text.display(state.query or "", state.query_cursor)
      data.path = self.options.open_key .. (words and " › path" or " / ") .. (words and "" or state.query)
      data.query_label = words and "Path" or "Search"
      data.query_text, data.query_cursor = state.query or "", state.query_cursor
      data.help = "Enter Run  ·  " .. (words and "Tab Complete  ·  " or "Ctrl-f Favorite  ·  ") .. K.label(self.options.keys.inspect or "<C-h>") .. " Details  ·  F1 View  ·  Esc Back"
      local favorites = {}
      for _, id in ipairs(self.usage:favorites()) do favorites[id] = true end
      local results = self:results()
      state.selected = math.max(1, math.min(state.selected, #results))
      for _, result in ipairs(results) do
        local command = result.command
        local available, why = result.available, result.reason
        local path = (result.paths or {})[1]
        data.items[#data.items + 1] = { key = favorites[command.id] and "*" or "", name = command.name or command.id,
          id = command.id, detail = words and result.word_path or path and (self.options.open_key .. " " .. path_label(path)) or (command.provider == "ex" and "External command" or command.id),
          disabled = not available, reason = why, icon = command.icon }
      end
      data.selected = state.selected
      local selected = results[state.selected]
      data.details = selected and self:command_details(selected.command, selected.available, selected.reason)
    elseif state.mode == "selector" then
      data.title, data.label = "Workspaces", "Select workspace"
      local workspaces = self:workspace_choices()
      for _, workspace in ipairs(workspaces) do
        data.items[#data.items + 1] = { key = "", name = workspace.name or workspace.id, icon = workspace.icon }
      end
      if state.selector_filtering or (state.query or "") ~= "" then
        data.query, data.query_label = Text.display(state.query or "", state.query_cursor), "Filter"
        data.query_text, data.query_cursor = state.query or "", state.query_cursor
      end
      data.selected, data.help = state.selected, state.selector_filtering and "Enter Open  ·  Esc Finish filter"
        or "Enter Open  ·  / Filter  ·  Esc Back  ·  " .. self.options.open_key .. " Close"
      data.empty = "No matching workspaces"
    elseif state.mode == "inspect" then
      local command = self.registry:get(state.inspected_id)
      data.title, data.label, data.input = "Command details", command and command.name or state.inspected_id, true
      data.path = self.options.open_key .. " › " .. (state.inspected_id or "Details")
      data.help = "e Connection  ·  s Status  ·  Enter Run  ·  Esc Back  ·  ? View"
      if command then
        local detail = self:command_details(command)
        if detail.reason and require("command_tree.backend_editor").supports(command) then
          data.help = "c Configure backend  ·  e Connection  ·  s Status  ·  Enter Run  ·  Esc Back  ·  ? View"
        end
        data.items = {
          { key = "Type", name = detail.kind }, { key = "Source", name = detail.source }, { key = "Target", name = detail.target },
          { key = "Status", name = detail.reason or "Available", disabled = detail.reason ~= nil },
        }
        if detail.description and detail.description ~= "" then data.items[#data.items + 1] = { key = "About", name = detail.description } end
        if self.registry.paths then
          for _, route in ipairs(self.registry:paths(command.id)) do data.items[#data.items + 1] = { key = "Path", name = self.options.open_key .. " " .. path_label(route) } end
        end
        if command.aliases and #command.aliases > 0 then data.items[#data.items + 1] = { key = "Aliases", name = table.concat(command.aliases, ", ") } end
        for _, field in ipairs(command.arguments or {}) do data.items[#data.items + 1] = {
          key = "Input", name = (field.prompt or field.name) .. " · " .. (field.kind or "text") .. (field.required and " · required" or " · optional") } end
        if state.recovered_query_command == command and state.recovered_query then
          data.items[#data.items + 1] = { key = "Query", name = state.recovered_query }
        end
      else data.message = "Command is no longer registered; its saved reference is preserved" end
    elseif state.mode == 'feedback' then
      local record = state.feedback_inspection or {}
      data.title, data.label, data.input = 'Diagnostic details', record.phase or 'Diagnostic', true
      data.path = self.options.open_key .. ' › Diagnostic'
      data.diagnostic, data.message = record, nil
      data.items = { { key = 'Phase', name = record.phase or 'Unknown' } }
      if record.command_id then data.items[#data.items + 1] = { key = 'Command', name = record.command_id } end
      if record.provider then data.items[#data.items + 1] = { key = 'Provider', name = record.provider } end
      if record.field then data.items[#data.items + 1] = { key = 'Field', name = record.field } end
      data.help = '↑/↓ Scroll message  ·  Ctrl-d/u Page  ·  Esc Back to form'
    elseif state.mode == "availability" then
      local report = state.availability_report or {}
      data.title, data.label, data.input = "Command status", report.title or "Status", true
      data.path = self.options.open_key .. " › " .. (state.availability_command and state.availability_command.id or "Status")
      data.help = "r Recheck  ·  Enter Return  ·  Esc Back  ·  ? View"
      if report.backend_settings then data.help = "c Configure backend  ·  " .. data.help end
      data.items = { { key = "Status", name = report.reason or report.title or "Unknown" } }
      for _, line in ipairs(report.lines or {}) do
        data.items[#data.items + 1] = type(line) == "table" and line or { key = "Info", name = tostring(line) }
      end
      for _, line in ipairs(report.guidance or {}) do data.items[#data.items + 1] = { key = "Next", name = line } end
    elseif state.mode == "review" then
      local input = state.input
      data.title, data.label, data.input, data.review = input.command.name, "Review arguments", true, true
      data.path = self.options.open_key .. " " .. path_label(state.path) .. " › Review"
      for index, field in ipairs(input.command.arguments) do
        local value = input.args[field.name]
        local label = value == nil and "(not set)" or field.secret and "••••" or type(value) == "table" and vim.inspect(value) or tostring(value)
        data.items[#data.items + 1] = { key = tostring(index), name = (field.prompt or field.name) .. " = " .. label }
      end
      data.items[#data.items + 1] = { key = "Run", name = "Execute with these arguments" }
      input.review_selected = math.max(1, math.min(input.review_selected or #data.items, #data.items))
      data.selected, data.help = input.review_selected, "↑/↓ Select  ·  Enter Edit / Run  ·  Esc Back  ·  ? View"
      data.details = self:command_details(input.command, nil, nil, input.context)
    elseif state.mode == "input" then
      data.input = true
      local input = state.input
      local field = input.command.arguments[input.index]
      data.title, data.label = input.command.name, (field.prompt or field.name) .. " (" .. input.index .. "/" .. #input.command.arguments .. ")"
      data.path = self.options.open_key .. " " .. path_label(state.path) .. " › " .. field.name
      if input.choices then
        -- Layout uses the stable unfiltered domain, not the current filtered
        -- count or selection. Oversized/private domains keep the larger safe
        -- reading budget without copying unbounded labels into the view.
        data._input_choice_labels = false
        local domain = input.all_choices or input.choices
        if not field.secret and #domain <= 1024 then
          local labels = {}
          for _, item in ipairs(domain) do
            local label = A.label(item)
            if #vim.fn.strcharpart(label, 0, 4096) ~= #label then labels = nil; break end
            labels[#labels + 1] = label
          end
          data._input_choice_labels = labels or false
        end
        for _, item in ipairs(input.choices) do data.items[#data.items + 1] = {
          key = field.kind == "multiselect" and (A.contains(input.checked, A.value(item)) and "[x]" or "[ ]") or "", name = A.label(item) } end
        data.selected = input.selected
        if input.filtering or input.filter ~= "" then
          data.query = Text.display(input.filter, input.filter_cursor)
          data.query_text, data.query_cursor = input.filter, input.filter_cursor
        end
        if #input.choices == 0 then data.message = data.message or "No matching choices" end
      else
        local shown = field.secret and string.rep("•", vim.fn.strchars(input.text or "")) or input.text or ""
        data.items = { { key = ">", name = Text.display(shown, input.cursor), editing_text = shown, editing_cursor = input.cursor } }
      end
      data.help = input.choices and (field.kind == "multiselect" and "Space Toggle  ·  Enter Accept  ·  / Filter  ·  Esc Back" or "Enter Select  ·  / Filter  ·  F1 View  ·  Esc Back")
        or ("Enter Next / Run  ·  Tab Complete  ·  ↑/↓ History  ·  Esc Back")
      if input.choices then
        data.help = data.help .. '  ·  ' .. Guide.hint_pair(self.options.keys.page_up or '<PageUp>', self.options.keys.page_down or '<PageDown>') .. ' Page'
        local attachment = state.input_attachment
        local status = self:input_status()
        -- A native presentation hook may synchronously close, replace or
        -- reattach its Session. Never reopen the retired view from old data.
        if not self:is_attached(state, attachment) or state.mode ~= 'input' or state.input ~= input
          or not input.callback and self.registry:get(input.command.id) ~= input.command then return end
        if status then
          if status.label and status.label ~= '' then data.label = status.label .. ' · ' .. data.label end
          if status.help and status.help ~= '' then data.help = data.help .. '  ·  ' .. status.help end
          if status.description and status.description ~= '' then data.details = { description = status.description } end
        end
      end
      if not field.required and not input.callback then data.help = data.help .. "  ·  Ctrl-s Skip" end
      if data.diagnostic then data.help = data.help .. '  ·  ' .. K.label(self.options.keys.inspect or '<C-h>') .. ' Inspect error' end
    else
      local node = state.mode == "keymaps" and Maps.node(state.keymap_root, state.path) or self.registry:node(state.path)
      if not node then state.message = "Path is no longer registered"; return end
      data.label = type(node.name) == "function" and node.name(state.ctx) or node.name or "Commands"
      if state.mode == "keymaps" then
        -- A guide shares the session's density. Legacy hints.density remains
        -- accepted configuration, but cannot reset a live density change.
        opts = vim.tbl_extend("force", opts, self.options.hints, { density = state.density })
        data.title, data.path = "Key Guide", path_label(state.path)
        local view_key = not guide_owns_key(state, self.options.keys.detail) and self.options.keys.detail
          or not guide_owns_key(state, "<F1>") and "<F1>" or nil
        data.help = "Esc Back  ·  Enter Execute  ·  " .. (view_key and (K.label(view_key) .. " View  ·  ") or "") .. self.options.open_key .. " Close"
        for _, entry in ipairs(Maps.items(node)) do
          local value = entry.node.group_name or entry.node.name or "Group"
          data.items[#data.items + 1] = { key = entry.key, name = type(value) == "function" and tostring(value(state.ctx)) or value,
            group = has_children(entry.node), icon = entry.node.icon }
        end
      else
        state.tree_items = {}
        if node.command_id and not (self.registry.hidden and self.registry:hidden(node.command_id)) then
          local command = self.registry:get(node.command_id)
          local enabled, why = self.registry:available(node.command_id, state.ctx)
          data.items[#data.items + 1] = { key = "", current = true, name = command and command.name or node.command_id,
            disabled = not enabled, reason = why, icon = command and command.icon }
          state.tree_items[#state.tree_items + 1] = { id = node.command_id, path = copy_path(state.path) }
        end
        local keys = vim.tbl_keys(node.children or {})
        table.sort(keys)
        for _, key in ipairs(keys) do
          local child = node.children[key]
          local hidden = child.command_id and self.registry.hidden and self.registry:hidden(child.command_id)
          if not hidden or has_children(child) then
          local command = child.command_id and self.registry:get(child.command_id)
          local available, why = true, nil
          if command and not has_children(child) then available, why = self.registry:available(command.id, state.ctx) end
          data.items[#data.items + 1] = { key = key, name = child.name or (command and command.name) or key,
            group = has_children(child), disabled = not available, reason = why,
            icon = child.icon or (command and command.icon), detail = child.command_id and not command and "Unavailable" or nil }
          local route = copy_path(state.path); route[#route + 1] = key
          state.tree_items[#state.tree_items + 1] = { id = not hidden and child.command_id or nil, path = route, group = has_children(child) }
          if child.command_id and not command then
            data.items[#data.items].disabled, data.items[#data.items].reason = true, "Command is temporarily unavailable"
          end
          end
        end
        if #state.path == 0 and self.options.quick_slots ~= false and self.usage.slots then
          for slot = 1, 9 do
            local id = self.usage:slot(slot)
            if id then
              local command = self.registry:get(id)
              local enabled, why = self.registry:available(id, state.ctx)
              data.items[#data.items + 1] = { key = tostring(slot), name = command and command.name or id,
                detail = "Quick slot", disabled = not enabled, reason = why }
              state.tree_items[#state.tree_items + 1] = { id = id }
            end
          end
        end
        if state.tree_selection then
          local previous = state.tree_selected_entry
          if previous then
            state.tree_selection = nil
            for index, entry in ipairs(state.tree_items) do
              if vim.deep_equal(entry, previous) then state.tree_selection = index; break end
            end
            if not state.tree_selection then state.message, data.message = "Selected command changed; select it again", "Selected command changed; select it again" end
          elseif #state.tree_items > 0 then
            state.tree_selection = math.max(1, math.min(state.tree_selection, #state.tree_items))
          else state.tree_selection = nil end
          if state.tree_selection then
            state.tree_selected_entry = vim.deepcopy(state.tree_items[state.tree_selection])
            data.selected = state.tree_selection
            data.details = self:command_details(self:selected_command())
            if not data.details and data.items[state.tree_selection].reason then
              data.details = { reason = data.items[state.tree_selection].reason }
            end
          end
        end
        if not state.tree_selection then state.tree_selected_entry = nil end
        data.help = data.help .. "  ·  ↑/↓ Select  ·  " .. K.label(self.options.keys.inspect or "<C-h>") .. " Details"
      end
    end
    local scene = ({ search = 'search', words = 'search', selector = 'tree', input = 'input', review = 'review' })[state.mode] or 'tree'
    opts = require('command_tree.presentation').options(self.options, state, scene, opts)
    if data.details or data.diagnostic then data.help = data.help .. '  ·  '
      .. Guide.hint_pair(self.options.keys.details_up or '<S-PageUp>', self.options.keys.details_down or '<S-PageDown>')
      .. ' Scroll details' end
    data.hints = Guide.help_hints(data.help)
    state.page, state.pages = V.draw(state.view, data, opts)
    if state.mode == 'feedback' and not (state.view.details and state.view.details.win and vim.api.nvim_win_is_valid(state.view.details.win)) then
      -- Dynamic opt-out and very small screens still expose the complete bounded
      -- message as a paged list. Enter never invokes a diagnostic row.
      local width = state.view.win and vim.api.nvim_win_get_width(state.view.win) or opts.width or 48
      data.items = diagnostic_rows(state.feedback_inspection or {}, math.max(1, width - 8))
      state.feedback_rows = #data.items
      state.feedback_offset = math.max(1, math.min(#data.items, state.feedback_offset or 1))
      data.selected = state.feedback_offset
      data.diagnostic, data.message = nil, nil
      state.page, state.pages = V.draw(state.view, data, opts)
    end
  end

end

return M
