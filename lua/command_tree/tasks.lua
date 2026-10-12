-- Task records outlive their UI. This workspace only observes operations and
-- requests cancellation when the user explicitly presses x / Ctrl-x.
local V = require("command_tree.view")
local Report = require("command_tree.task_report")
local M = {}
local function failure(value) return tostring(value):gsub("^.-:%d+:%s*", "") end
local function discard_report(frame)
  if frame.data.report_preview then Report.discard(frame.data.report_preview) end
  frame.data.report_preview, frame.data.report_destination, frame.data.report_id, frame.data.report_row = nil, nil, nil, nil
  frame.data.report_epoch = (frame.data.report_epoch or 0) + 1
end

local function stop(frame)
  frame.data.epoch = (frame.data.epoch or 0) + 1
  local timer = frame.data.timer
  frame.data.timer = nil
  if timer then timer:stop(); timer:close() end
end

local function visible(frame, session)
  local stack = session.stack or {}
  return session.running ~= false and session.mode == "workspace" and stack[#stack] == frame
end

local function text(value)
  if value == nil then return "" end
  if type(value) == "string" then return value end
  if type(value) == 'number' or type(value) == 'boolean' then return tostring(value) end
  if type(value) ~= 'table' then return '[Non-text result]' end
  local lines, count = {}, 0
  -- Backend results are untrusted. Do not invoke __pairs/__tostring or expand
  -- arbitrary nested objects merely to refresh an observer window.
  for key, item in next, value do
    count = count + 1
    if count > 32 then lines[#lines + 1] = '[Additional fields omitted]'; break end
    if type(key) == 'string' or type(key) == 'number' then
      local label = tostring(key):sub(1, 80)
      local body = type(item) == 'string' and item:sub(1, 4096)
        or (type(item) == 'number' or type(item) == 'boolean') and tostring(item) or '[Structured/non-text field]'
      lines[#lines + 1] = label .. ': ' .. body
    end
  end
  return table.concat(lines, '\n')
end

local function bounded(value)
  value = text(value)
  -- Results may contain an entire process output. Keep UI work bounded while
  -- preserving the backend's original result for integrations to open fully.
  if #value > 16384 then value = vim.fn.strcharpart(value, 0, 4096) .. "\n… Result truncated in this view" end
  return value
end

local function elapsed(operation)
  local duration = ((operation.finished or vim.uv.hrtime()) - (operation.started or vim.uv.hrtime())) / 1e9
  return ("%.1fs"):format(math.max(0, duration))
end

local function operations(frame)
  local ok, result = pcall(function() return require("command_tree").operations() end)
  if not ok or type(result) ~= "table" then
    frame.data.read_error = "Tasks unavailable: " .. failure(result)
    frame.data.message = frame.data.read_error
    return frame.data.operations or {}
  end
  if frame.data.message == frame.data.read_error then frame.data.message = nil end
  frame.data.read_error = nil
  frame.data.operations = result
  frame.data.counts = { all = #result, failed = 0, pending = 0 }
  local filtered = {}
  for _, operation in ipairs(result) do
    local failed = operation.status == 'failed' or operation.status == 'cancelled'
    if failed then frame.data.counts.failed = frame.data.counts.failed + 1 end
    if operation.status == 'pending' then frame.data.counts.pending = frame.data.counts.pending + 1 end
    if frame.data.filter == 'failed' and failed or frame.data.filter == 'pending' and operation.status == 'pending'
      or frame.data.filter ~= 'failed' and frame.data.filter ~= 'pending' then filtered[#filtered + 1] = operation end
  end
  -- A details/report view owns its task until Back, even if it no longer matches
  -- the list filter. Refresh must never silently replace that owned record.
  if frame.data.detail_id or frame.data.report_preview then return result end
  result = filtered
  local selected = math.max(1, math.min(frame.data.selected or 1, #result))
  for i, operation in ipairs(result) do
    if operation.id == frame.data.selected_id then selected = i; break end
  end
  frame.data.selected = selected
  frame.data.selected_id = result[selected] and result[selected].id or nil
  return result
end

local function find(records, id)
  for _, operation in ipairs(records) do if operation.id == id then return operation end end
end
local function prepare_report(frame, session, records, include_output)
  local id = frame.data.report_id or frame.data.detail_id or frame.data.selected_id
  local operation = find(records, id)
  if not operation then return false, 'Selected task is no longer in retained history' end
  discard_report(frame)
  local CE = require('command_tree')
  local preview, why = Report.prepare(operation, { version = CE.version, descriptor = CE.registry():get(operation.command_id),
    include_output = include_output, session = session, frame = frame, ctx = frame.ctx })
  if not preview then return false, why end
  frame.data.report_preview, frame.data.report_id, frame.data.report_row = preview, operation.id, 1
  frame.data.message = nil
  return true
end

local function export_report(frame, ctx, session, records)
  local preview = frame.data.report_preview
  local operation = find(records, frame.data.report_id)
  if not operation then return false, 'Reported task is no longer in retained history' end
  if frame.data.report_destination then
    local ok, why = Report.export(preview, operation, frame.data.report_destination)
    if not ok then return false, why end
    discard_report(frame)
    frame.data.message = 'Task report saved: ' .. why
    return true
  end
  return session.workspace_input({ prompt = 'Unused task-report JSON destination', kind = 'text', required = true,
    default = vim.fn.getcwd() .. '/re35-task-' .. operation.id .. '.json' }, function(value)
      if value == nil then return end
      if frame.data.report_preview ~= preview then return end
      local current = find(operations(frame), frame.data.report_id)
      if not current then frame.data.message = 'Reported task is no longer in retained history'; return end
      local path, why = Report.review_destination(preview, current, value)
      if not path then frame.data.message = why; return end
      frame.data.report_destination = path
      local keys = (frame.data.options or {}).action_keys or {}
      frame.data.message = 'Destination reviewed; ' .. (keys.details or 'Enter') .. ' saves this preview'
    end, ctx)
end

local function report_items(frame, width)
  local items = {}
  local function append(value)
    for _, line in ipairs(vim.split(value, '\n', { plain = true })) do
      local part = ''
      for char in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if part ~= '' and V.width(part .. char) > width then items[#items + 1] = { key = '', name = part }; part = '' end
        part = part .. char
      end
      items[#items + 1] = { key = '', name = part }
    end
  end
  for _, line in ipairs(frame.data.report_preview.lines) do append(line) end
  if frame.data.report_destination then append('Destination: ' .. frame.data.report_destination) end
  return items
end

local function detail_items(operation, width)
  local items, truncated = {}, false
  local function append(line)
    if #items >= 250 then
      if not truncated then
        items[#items + 1] = { key = "", name = "… Result truncated in this view" }
        truncated = true
      end
      return false
    end
    items[#items + 1] = { key = "", name = line }
    return true
  end
  local function add(label, value)
    for i, line in ipairs(vim.split(bounded(value), "\n", { plain = true })) do
      -- Put text in the name column so detail remains readable in every density.
      line = ((i == 1 and label .. ": " or "  ") .. line):gsub("[\r\t]", " ")
      local part = ""
      for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if part ~= "" and V.width(part .. char) > width then
          if not append(part) then return end
          part = ""
        end
        part = part .. char
      end
      if not append(part) then return end
    end
  end
  add("Command", operation.command_id)
  add("Status", operation.status)
  add("Elapsed", elapsed(operation))
  if operation.recipe_id and operation.process_target then
    local target=operation.process_target
    add('Recipe choices', (target.configuration or '?')..' / '..(target.target or '?'))
    if operation.step_id then add('Running step',operation.step_id)end
    for _,step in ipairs(type(operation.detail)=='table' and operation.detail.steps or operation.progress_steps or {})do
      add('Step '..step.id,step.status..(step.task_id and ' · child #'..step.task_id or ''))
    end
  end
  if type(operation.detail) == "table" and operation.detail.locations_status then
    add("Source locations", (#(operation.detail.locations or {})) .. " · " .. operation.detail.locations_status .. " · press o to open Results")
    if operation.detail.descendant_termination then add('Descendant termination',operation.detail.descendant_termination)end
    if operation.detail.detached_observed and operation.detail.detached_observed>0 then
      add('Detached descendants observed',operation.detail.detached_observed..' · outside the promised cancellation scope')
    end
  end
  if operation.recipe_id then add('Recipe recovery', 'c Source results / step Settings · v Review original choices with current tools · r Retry original argv')end
  add(operation.process_target and "UI buffer" or "Buffer", operation.buffer ~= "" and operation.buffer or "[No Name]")
  if operation.process_target then
    add("Task source", operation.process_target.file ~= "" and operation.process_target.file or "[Project tool]")
    add("Project", operation.process_target.root)
    add("Working directory", operation.process_target.cwd)
    add("Arguments", operation.process_target.argv)
  end
  if operation.process_scope_message then add("Termination scope", operation.process_scope_message) end
  if operation.status == "pending" then
    add("Cancellation", operation.cancel_state == "unconfirmed" and "Still running after grace period; F can force the owned execution scope"
      or operation.force_requested and "Force requested; waiting for exit"
      or operation.cancel_requested and "Requested; waiting for backend completion"
      or operation.cancel_hook and "x / Ctrl-x" or "Backend cannot be interrupted safely")
  end
  if operation.cancel_error then add("Cancellation error", operation.cancel_error) end
  if operation.cleanup_error then add("Cleanup error", operation.cleanup_error) end
  if operation.detail ~= nil then add("Result", operation.detail) end
  return items
end

local function render(frame, session, opts, records)
  records = records or operations(frame)
  local items, selected, label = {}, frame.data.selected, "Tasks and results"
  local detail
  if frame.data.report_preview then
    local window = opts.window or {}
    local width = math.max(1, math.min(window.width or 64, window.max_width or 100, vim.o.columns - 4) - 10)
    items = report_items(frame, width)
    label = 'Task #' .. frame.data.report_id .. ' report · ' .. frame.data.report_preview.byte_count .. ' bytes'
    frame.data.report_row = math.max(1, math.min(frame.data.report_row or 1, #items))
    selected = frame.data.report_row
  elseif frame.data.detail_id then
    for _, operation in ipairs(records) do if operation.id == frame.data.detail_id then detail = operation; break end end
    if detail then
      local window = opts.window or {}
      local width = math.max(1, math.min(window.width or 64, window.max_width or 100, vim.o.columns - 4) - 10)
      items = detail_items(detail, width)
      label = "#" .. detail.id .. " " .. detail.name
      frame.data.detail_row = math.max(1, math.min(frame.data.detail_row or 1, #items))
      selected = frame.data.detail_row
    else
      label = "Task no longer in retained history"
      selected = 1
    end
  else
    local pending = 0
    for _, operation in ipairs(records) do
      if operation.status == "pending" then pending = pending + 1 end
      items[#items + 1] = { key = "#" .. operation.id, name = operation.status .. " · " .. operation.name,
        detail = operation.cancel_error and "Cancellation failed" or operation.cancel_state == "unconfirmed"
          and (operation.status=='pending' and "Still running" or 'Termination unconfirmed')
          or operation.force_requested and "Force requested" or operation.cancel_requested and "Cancellation requested"
          or operation.recipe_id and operation.process_target and ((operation.process_target.configuration or '?')..' / '..(operation.process_target.target or '?')
            ..(operation.step_id and ' · '..operation.step_id or '')) or elapsed(operation) }
    end
    local names = { all = 'All', failed = 'Failed + cancelled', pending = 'Pending' }
    label = (names[frame.data.filter] or 'All') .. ' · ' .. #records .. '/' .. (frame.data.counts or {}).all .. ' tasks · ' .. pending .. ' running'
  end
  local view_key = require("command_tree.keys").label((opts.keys or {}).detail or "?")
  local help = frame.data.detail_id and "j/k Scroll · Esc List" or "j/k Select · Enter Details · Esc Back"
  help = opts.help or (help .. " · x Cancel · " .. view_key .. " View · " .. (opts.open_key or "\\") .. " Close")
  if frame.data.report_preview then
    local keys = opts.action_keys or {}
    help = (keys.details or 'Enter') .. ' ' .. (frame.data.report_destination and 'Save' or 'Path')
      .. ' · ' .. (keys.results or 'o') .. ' ' .. (frame.data.report_preview.include_output and 'Hide output' or 'Output')
      .. ' · ' .. (keys.back or 'Esc') .. ' Tasks · ' .. view_key .. ' View'
  end
  local cancel_key = (opts.action_keys or {}).cancel or "x"
  V.draw(frame.view, { title = vim.trim(opts.title or "Tasks"), path = opts.path, label = label,
    required_label = (frame.data.detail_id or frame.data.report_preview) and label or nil,
    items = items, selected = selected, empty = frame.data.detail_id and "Esc returns to tasks" or "No tasks yet",
    message = frame.data.message or session.message, help = help,
    minimal_help = frame.data.report_preview and help or frame.data.detail_id and "Esc List · " .. cancel_key .. " Cancel · " .. view_key .. " View"
      or ((opts.action_keys or {}).details or "Enter") .. " Details · " .. cancel_key .. " Cancel · " .. view_key .. " View" },
    vim.tbl_extend("force", { width = 64, max_width = 100, icons = false }, opts.window or {},
      { density = opts.density, accent = opts.accent, icons = false }))
end

local function signature(frame, records)
  local parts = { tostring(frame.data.detail_id), tostring(frame.data.selected_id), bounded(frame.data.message) }
  local counts = frame.data.counts or {}
  parts[#parts + 1] = table.concat({ frame.data.filter or 'all', tostring(counts.all), tostring(counts.failed), tostring(counts.pending) }, ':')
  for _, operation in ipairs(records) do
    parts[#parts + 1] = table.concat({ tostring(operation.id), operation.status or "", bounded(operation.detail),
      bounded(operation.cancel_error), bounded(operation.cleanup_error), tostring(operation.cancel_requested),
      tostring(operation.cancel_state), tostring(operation.force_requested),
      -- Pending elapsed time updates once per second, not on every poll.
      tostring(math.floor(((operation.finished or vim.uv.hrtime()) - (operation.started or 0)) / 1e9)) }, "\0")
  end
  return table.concat(parts, "\1")
end

local function start(frame, session)
  if frame.data.timer or not visible(frame, session) then return end
  local timer = vim.uv.new_timer()
  if not timer then frame.data.message = "Live task refresh is unavailable"; return end
  frame.data.timer = timer
  local epoch = frame.data.epoch
  timer:start(500, 500, vim.schedule_wrap(function()
    if frame.data.timer ~= timer or frame.data.epoch ~= epoch then return end
    if not visible(frame, session) then stop(frame); return end
    local ok, err = pcall(function()
      local records = operations(frame)
      local current = signature(frame, records)
      if current ~= frame.data.signature then
        frame.data.signature = current
        render(frame, session, frame.data.options, records)
      end
    end)
    if not ok then
      stop(frame)
      session.message = "Task refresh failed: " .. tostring(err)
      vim.notify(session.message, vim.log.levels.WARN, { title = "Command Environment" })
    end
  end))
end

function M.definition()
  local definition = {
    id = "tasks", name = "Tasks", icon = "󰐊",
    state_scope = "global", state_fields = { "selected", "selected_id", "detail_id", "detail_row", 'filter' },
    enter = function(frame) frame.data.selected = frame.data.selected or 1 end,
    suspend = function(frame) stop(frame); discard_report(frame) end,
    leave = function(frame) stop(frame); discard_report(frame) end,
    resume = function(frame) frame.data.signature = nil end,
    draw = function(frame, _, session, opts)
      frame.data.options = opts
      local records = operations(frame)
      frame.data.signature = signature(frame, records)
      render(frame, session, opts, records)
      start(frame, session)
    end,
    handle = function(frame, key, _, session)
      local records = operations(frame)
      local detail = frame.data.detail_id ~= nil
      local delta = ({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1,
        ["<C-n>"] = 1, ["<C-p>"] = -1, ["<C-d>"] = 10, ["<C-u>"] = -10,
        ["<PageDown>"] = 10, ["<PageUp>"] = -10 })[key]
      if frame.data.report_preview then
        if delta then frame.data.message = nil; frame.data.report_row = math.max(1, (frame.data.report_row or 1) + delta)
        elseif key == '<Esc>' or key == '<BS>' then discard_report(frame)
        elseif key == 'o' then return prepare_report(frame, session, records, not frame.data.report_preview.include_output)
        elseif key == '<CR>' then return export_report(frame, frame.ctx, session, records)
        elseif key == 'p' then return true
        else return false, 'Return to Tasks before using another task action' end
      elseif key == 'p' then return prepare_report(frame, session, records, false)
      elseif key == 'f' then
        if detail then frame.data.message = 'Return to the task list before changing its filter'
        else frame.data.filter = ({ all = 'failed', failed = 'pending', pending = 'all' })[frame.data.filter or 'all'] or 'all'; operations(frame) end
      elseif delta then
        frame.data.message = nil
        if detail then frame.data.detail_row = math.max(1, (frame.data.detail_row or 1) + delta)
        else
          frame.data.selected = math.max(1, math.min(#records, (frame.data.selected or 1) + delta))
          frame.data.selected_id = records[frame.data.selected] and records[frame.data.selected].id or nil
        end
      elseif key == "<CR>" and not detail then
        frame.data.detail_id, frame.data.detail_row = frame.data.selected_id, 1
      elseif (key == "<Esc>" or key == "<BS>") and detail then
        frame.data.detail_id, frame.data.detail_row, frame.data.message = nil, nil, nil
      elseif key == "x" or key == "<C-x>" then
        local id, operation = frame.data.detail_id or frame.data.selected_id
        for _, item in ipairs(records) do if item.id == id then operation = item; break end end
        if not operation then frame.data.message = "Select a task first"
        elseif operation.status ~= "pending" then frame.data.message = "This task has already finished"
        else
          local safe, ok, why = pcall(function() return require("command_tree").cancel(id) end)
          if not safe or not ok then frame.data.message = "Cancellation failed: " .. failure(safe and why or ok)
          else
            local pending = false
            for _, current in ipairs(operations(frame)) do
              if current.id == id then pending = current.status == "pending"; break end
            end
            frame.data.message = pending and (why or "Cancellation requested; waiting for backend completion") or "Task cancelled"
          end
        end
      else return false end
      return true
    end,
  }
  local handle = definition.handle
  definition.actions = {}
  for id, spec in pairs({ next = { "Next", "j", true }, previous = { "Previous", "k", true },
    details = { "Details", "<CR>" }, cancel = { "Cancel", "x" }, back = { "List", "<Esc>", true, "back" },
    page_down = { "Page down", "<C-d>", true, "page_down" }, page_up = { "Page up", "<C-u>", true, "page_up" } }) do
    definition.actions[id] = { label = spec[1], hidden = spec[3], control = spec[4], run = function(frame, ctx, session)
      return handle(frame, spec[2], ctx, session)
    end }
  end
  definition.actions.rerun = { label = "Run again", run = function(frame)
    if frame.data.report_preview then return false, 'Return to Tasks before running a task' end
    local id = frame.data.detail_id or frame.data.selected_id
    if not id then return false, "Select a task first" end
    return require('command_tree.project.follow_up').run(id,'retry')
  end }
  definition.actions.results = { label = "Source results", run = function(frame, ctx, session)
    if frame.data.report_preview then return handle(frame, 'o', ctx, session) end
    local id = frame.data.detail_id or frame.data.selected_id
    if not id then return false, "Select a task first" end
    return require('command_tree.project.follow_up').run(id,'results',session)
  end }
  definition.actions.source = { label = "Return to task source", run = function(frame)
    if frame.data.report_preview then return false, 'Return to Tasks before opening its source' end
    local id = frame.data.detail_id or frame.data.selected_id
    if not id then return false, "Select a task first" end
    return require("command_tree").return_task_source(id)
  end }
  definition.actions.recover_recipe = { label = 'Recipe remedy', run = function(frame)
    if frame.data.report_preview then return false,'Return to Tasks before recovering a recipe'end
    return require('command_tree.project.follow_up').run(frame.data.detail_id or frame.data.selected_id,'recover')
  end }
  definition.actions.review_recipe = { label = 'Review original recipe', run = function(frame)
    if frame.data.report_preview then return false,'Return to Tasks before reviewing a recipe'end
    return require('command_tree.project.follow_up').run(frame.data.detail_id or frame.data.selected_id,'review')
  end }
  definition.actions.force = { label = "Force owned execution scope", run = function(frame)
    if frame.data.report_preview then return false, 'Return to Tasks before forcing termination' end
    local id = frame.data.detail_id or frame.data.selected_id
    if not id then return false, "Select a task first" end
    return require("command_tree").force_cancel(id)
  end }
  definition.actions.report = { label = 'Report preview', run = function(frame, ctx, session) return handle(frame, 'p', ctx, session) end }
  definition.actions.filter = { label = 'Filter tasks', run = function(frame, ctx, session) return handle(frame, 'f', ctx, session) end }
  definition.bindings = { j = "next", ["<Down>"] = "next", ["<C-n>"] = "next",
    k = "previous", ["<Up>"] = "previous", ["<C-p>"] = "previous", ["<CR>"] = "details", x = "cancel", ["<C-x>"] = "cancel",
    ["<Esc>"] = "back", ["<BS>"] = "back", ["<C-d>"] = "page_down", ["<PageDown>"] = "page_down",
    ["<C-u>"] = "page_up", ["<PageUp>"] = "page_up", r = "rerun", o = "results", s = "source", F = "force", p = 'report', f = 'filter',
    c = 'recover_recipe', v = 'review_recipe' }
  return definition
end

return M
