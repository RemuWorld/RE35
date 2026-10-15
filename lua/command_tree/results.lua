-- Native result sources stay owned by Neovim. The workspace keeps a reference
-- to the originating window (especially for location lists), never replaces
-- quickfix/location lists, and revalidates selection before jumping.
local K, V = require("command_tree.keys"), require("command_tree.view")
local Text = require("command_tree.text")
local M = {}
local Lists = require('command_tree.list_navigation')
local names = { diagnostics = "Diagnostics", quickfix = "Quickfix", loclist = "Location list", task = "Task results" }

-- Provenance describes a result; it never authorizes a child task or a jump.
-- Retain only bounded scalar IDs, without traversing arbitrary result tables.
local function provenance(location)
  local step = rawget(location, 'recipe_step')
  local child = rawget(location, 'child_task_id')
  if type(step) ~= 'string' or #step > 4096 or not step:match('^[%w_.-]+$') then step = nil end
  if type(child) ~= 'number' or child < 1 or child % 1 ~= 0 or child > 9007199254740991 then child = nil end
  return step, child
end

local function document_reference(location)
  local value = rawget(location, 'document_target')
  if value == nil then return nil end
  if type(value) ~= 'table' then return false end
  local ref = { buf = rawget(value, 'buf'), uri = rawget(value, 'uri'), revision = rawget(value, 'revision'),
    encoding = rawget(value, 'encoding') }
  if type(ref.buf) ~= 'number' or ref.buf < 1 or ref.buf % 1 ~= 0 or ref.buf > 9007199254740991
    or type(ref.uri) ~= 'string' or #ref.uri > 4096 or type(ref.revision) ~= 'string' or #ref.revision > 1024
    or ref.encoding ~= 'utf-8' then return false end
  return ref
end

local function compact(value)
  local text = tostring(value or ""):gsub("[\r\n\t]", " ")
  return #text > 2000 and vim.fn.strcharpart(text, 0, 500) .. "…" or text
end

local function target_name(item)
  if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
    local name = vim.api.nvim_buf_get_name(item.bufnr)
    return name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  end
  return item.filename and vim.fn.fnamemodify(item.filename, ":~:.") or "[No location]"
end

function M.read(source, ctx, scope, task_id)
  if not names[source] then return nil, "Unknown result source: " .. tostring(source) end
  if scope ~= nil and scope ~= "all" and scope ~= "buffer" then return nil, "Unknown diagnostic scope: " .. tostring(scope) end
  if not K.valid(ctx) then return nil, "Result source window or buffer is no longer available" end
  local ok, data = pcall(function()
    if source == "task" then
      local operation
      for _, candidate in ipairs(require("command_tree").operations()) do if candidate.id == task_id then operation = candidate; break end end
      assert(operation, "Task is no longer in retained history")
      assert(operation.status ~= "pending", "Task is still running")
      local detail = type(operation.detail) == "table" and operation.detail or {}
      local raw = {}
      for index, location in ipairs(type(detail.locations) == "table" and detail.locations or {}) do
        if index > 5000 then break end
        local step, child = provenance(location)
        local existing = type(location.filename) == "string" and vim.fn.bufnr(location.filename) or -1
        raw[#raw + 1] = { filename = location.filename, bufnr = existing > 0 and existing or nil, lnum = location.line, col = location.col,
          text = location.text, valid = location.valid == true and 1 or 0, type = location.type, vcol = location.vcol and 1 or 0,
          file_revision = location.file_revision, scan_root = location.scan_root, recipe_step = step, child_task_id = child,
          document_target = document_reference(location) }
        if rawget(location, 'document_target') ~= nil then raw[#raw].bufnr = rawget(location, 'bufnr') end
      end
      return { items = raw, title = "#" .. operation.id .. " " .. operation.name, id = operation.id,
        changedtick = operation.finished or 0, task_status = operation.status,
        reason = detail.locations_status == "error" and detail.locations_message or nil,
        empty = detail.locations_message or "This task has no source locations", truncated = detail.locations_truncated,
        status_message = detail.locations_message }
    end
    if source == "diagnostics" then return { items = vim.diagnostic.get(scope == "buffer" and ctx.buf or nil), title = names[source] } end
    if source == "quickfix" then return vim.fn.getqflist({ items = 1, title = 1, id = 0, changedtick = 0 }) end
    return vim.api.nvim_win_call(ctx.win, function()
      return vim.fn.getloclist(0, { items = 1, title = 1, id = 0, changedtick = 0 })
    end)
  end)
  if not ok then return nil, "Cannot read " .. names[source] .. ": " .. tostring(data):gsub("^.-:%d+:%s*", "") end
  local items, signatures = {}, { source, tostring(data.id or 0), tostring(data.changedtick or 0) }
  local duplicates = {}
  for index, raw in ipairs(data.items or {}) do
    if #items >= 5000 then break end
    local diagnostic = source == "diagnostics"
    local item = { bufnr = raw.bufnr, filename = raw.filename, line = diagnostic and raw.lnum + 1 or raw.lnum or 0,
      col = diagnostic and raw.col + 1 or raw.col or 0, vcol = raw.vcol == 1, text = raw.message or raw.text or "",
      severity = raw.severity, source = source, index = index, valid = diagnostic or raw.valid == 1,
      namespace = raw.namespace, diagnostic_source = raw.source, task_id = source == "task" and task_id or nil,
      file_revision = raw.file_revision, scan_root = raw.scan_root, document_target = raw.document_target,
      recipe_step = source == 'task' and raw.recipe_step or nil, child_task_id = source == 'task' and raw.child_task_id or nil }
    local identity_fields = { source, tostring(item.bufnr or item.filename or ""), tostring(item.line),
      tostring(item.col), tostring(item.vcol), tostring(item.namespace or ""), item.text }
    if item.recipe_step or item.child_task_id then
      identity_fields[#identity_fields + 1], identity_fields[#identity_fields + 2] = item.recipe_step or '', tostring(item.child_task_id or '')
    end
    if type(item.document_target) == 'table' then
      identity_fields[#identity_fields + 1] = item.document_target.uri or ''
      identity_fields[#identity_fields + 1] = item.document_target.revision or ''
    end
    local identity = vim.json.encode(identity_fields)
    duplicates[identity] = (duplicates[identity] or 0) + 1
    item.id = vim.fn.sha256(identity) .. ":" .. duplicates[identity]
    item.name = compact(item.text)
    item.detail = target_name(item) .. (item.line > 0 and ":" .. item.line .. ":" .. math.max(1, item.col) or "")
    if item.recipe_step then item.detail = item.detail .. ' · step ' .. item.recipe_step end
    if item.child_task_id then item.detail = item.detail .. ' · #' .. item.child_task_id end
    item.disabled = not item.valid or item.line < 1
    item.reason = item.disabled and "This result has no navigable source location" or nil
    items[#items + 1], signatures[#signatures + 1] = item, item.id
  end
  return { items = items, source = source, title = data.title or names[source], list_id = data.id,
    revision = vim.fn.sha256(vim.json.encode(signatures)), truncated = data.truncated or #(data.items or {}) > #items,
    reason = data.reason, empty = data.empty, status_message = data.status_message }
end

local function refresh(frame)
  local result, err = M.read(frame.data.source or "diagnostics", frame.ctx, frame.data.scope, frame.data.task_id)
  if not result then frame.data.message = err; frame.data.items, frame.data.result, frame.data.selected_id = {}, nil, nil; return nil, err end
  local items, query = {}, (frame.data.filter or ""):lower()
  for _, item in ipairs(result.items) do
    if query == "" or (item.name .. " " .. item.detail):lower():find(query, 1, true) then items[#items + 1] = item end
  end
  local selected = math.max(1, math.min(frame.data.selected or 1, #items))
  for i, item in ipairs(items) do if item.id == frame.data.selected_id then selected = i; break end end
  frame.data.result, frame.data.items, frame.data.selected = result, items, selected
  frame.data.selected_id = items[selected] and items[selected].id
  return result
end

local function validate(frame)
  assert(frame.data.source == nil or names[frame.data.source], "Unknown result source")
  assert(frame.data.scope == nil or frame.data.scope == "all" or frame.data.scope == "buffer", "Unknown diagnostic scope")
end

function M.jump(item, ctx)
  if not K.valid(ctx) then return false, "Result target window or buffer is no longer available" end
  if not item or not item.valid or item.line < 1 then return false, "This result has no source location" end
  if item.document_target ~= nil then
    local valid, reason = require('command_tree.document').validate_location(item)
    if not valid then return false, reason end
  end
  local valid, reason = require("command_tree.file_search").validate_location(item)
  if not valid then return false, reason end
  if item.source == "task" and item.document_target == nil then
    local stat = type(item.filename) == "string" and vim.uv.fs_stat(item.filename)
    if not stat or stat.type ~= "file" then return false, "Task source file no longer exists; run the tool again" end
  end
  local bufnr = item.bufnr
  local ok, err = pcall(function()
    if not bufnr or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
      assert(type(item.filename) == "string" and item.filename ~= "", "Result buffer is no longer available")
      bufnr = vim.fn.bufadd(item.filename)
    end
    vim.fn.bufload(bufnr)
    assert(vim.api.nvim_buf_is_loaded(bufnr), "Result buffer could not be loaded")
    if item.document_target ~= nil then
      -- Focusing/loading the original document can run native WinEnter and
      -- BufEnter hooks. Recheck its exact URI/revision after that boundary,
      -- before reading text or placing a cursor using the retained location.
      vim.api.nvim_set_current_win(ctx.win)
      vim.api.nvim_win_set_buf(ctx.win, bufnr)
      local valid_now, reason_now = require('command_tree.document').validate_location(item)
      assert(valid_now, reason_now)
    end
    local line = math.min(item.line, vim.api.nvim_buf_line_count(bufnr))
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
    if item.document_target == nil then
      vim.api.nvim_set_current_win(ctx.win)
      vim.api.nvim_win_set_buf(ctx.win, bufnr)
    end
    local col = item.vcol and vim.fn.virtcol2col(ctx.win, line, math.max(1, item.col)) or item.col
    vim.api.nvim_win_set_cursor(ctx.win, { line, math.max(0, math.min(#text, (col or 1) - 1)) })
  end)
  return ok, not ok and tostring(err) or nil
end

local function selected(frame)
  return (frame.data.items or {})[frame.data.selected or 1]
end

local function task_location_exists(item)
  if item.source ~= "task" then return true end
  if item.document_target ~= nil then return require('command_tree.document').validate_location(item) end
  local stat = type(item.filename) == "string" and vim.uv.fs_stat(item.filename)
  return stat and stat.type == "file"
end

local function open_selected(frame, ctx, session)
  local item, snapshot = selected(frame), frame.data.result
  if not item then return false, "Select a result first" end
  if item.disabled then return false, item.reason end
  if item.document_target ~= nil then
    local valid, reason = require('command_tree.document').validate_location(item)
    if not valid then return false, reason end
  end
  local valid, reason = require("command_tree.file_search").validate_location(item)
  if not valid then return false, reason end
  if not task_location_exists(item) then return false, "Task source file no longer exists; run the tool again" end
  local current, err = M.read(frame.data.source, ctx, frame.data.scope, frame.data.task_id)
  if not current then return false, err end
  if not snapshot or current.revision ~= snapshot.revision then
    refresh(frame)
    return false, "Results changed; review the refreshed list before opening a location"
  end
  if session.workspace_navigate then return session.workspace_navigate(item, ctx) end
  -- A custom host may supply workspace_navigate. The standalone fallback
  -- closes only UI resources before focusing the original source window.
  if frame.manager then frame.manager:clear(session) end
  session.running = false
  return M.jump(item, ctx)
end

local function preview(item)
  if not item or item.line < 1 then return "Source preview unavailable" end
  if item.document_target ~= nil then
    local valid, reason = require('command_tree.document').validate_location(item)
    if not valid then return reason end
  end
  local lines, start
  if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) and vim.api.nvim_buf_is_loaded(item.bufnr) then
    local count = vim.api.nvim_buf_line_count(item.bufnr)
    start = math.max(0, math.min(count - 1, item.line - 2))
    lines = vim.api.nvim_buf_get_lines(item.bufnr, start, math.min(count, start + 3), false)
  elseif item.source == "task" and task_location_exists(item) then
    local fd = vim.uv.fs_open(item.filename, "r", 0)
    if not fd then return "Source preview cannot read this file" end
    local stat = vim.uv.fs_fstat(fd)
    local contents = stat and vim.uv.fs_read(fd, math.min(stat.size, 1048576), 0)
    vim.uv.fs_close(fd)
    if not contents then return "Source preview cannot read this file" end
    local all = vim.split(contents:gsub("\r\n", "\n"), "\n", { plain = true })
    if item.line > #all then return "Source preview exceeds the 1 MiB limit; open the location instead" end
    start = math.max(0, item.line - 2)
    lines = {}
    for i = start + 1, math.min(#all, start + 3) do lines[#lines + 1] = all[i] end
  else return "Source preview unavailable" end
  local result = {}
  for offset, line in ipairs(lines) do result[#result + 1] = (start + offset) .. ": " .. compact(line) end
  return table.concat(result, "\n")
end

function M.definition()
  local actions = {
    open = { label = "Open", run = open_selected },
    refresh = { label = "Refresh", run = function(frame)
      frame.data.message = nil
      local result, err = refresh(frame)
      return result ~= nil, err
    end },
    preview = { label = "Preview", run = function(frame) frame.data.preview = not frame.data.preview end },
    owning_task = { label = 'Owning task', run = function(frame, _, session)
      if frame.data.source~='task' then return false,'This result list is not owned by a task'end
      local result,why=M.read('task',frame.ctx,frame.data.scope,frame.data.task_id)
      if not result then return false,why end
      local stack=session.stack or {};local parent=stack[#stack-1]
      if parent and parent.id=='tasks' and (parent.data.detail_id or parent.data.selected_id)==frame.data.task_id then
        return session.workspace_back(frame)
      end
      return require('command_tree.project.follow_up').run(frame.data.task_id,'details',session)
    end },
    filter = { label = "Filter", run = function(frame)
      frame.data.filter_before, frame.data.input_active = frame.data.filter or "", true
      frame.data.filter_before_cursor = frame.data.filter_cursor
      frame.data.filter_before_selected, frame.data.filter_before_selected_id = frame.data.selected, frame.data.selected_id
      frame.data.filter_cursor = frame.data.filter_cursor or vim.fn.strchars(frame.data.filter_before)
      frame.data.message = nil
    end },
    clear_filter = { label = "Clear filter", run = function(frame) frame.data.filter, frame.data.filter_cursor = "", 0; refresh(frame) end },
  }
  for action,label in pairs({retry='Retry original task',recover='Recipe remedy',review='Review original recipe'})do
    actions['follow_'..action]={label=label,run=function(frame,_,session)
      if frame.data.source~='task'then return false,'Select owned task Results before choosing a follow-up'end
      return require('command_tree.project.follow_up').run(frame.data.task_id,action,session)
    end}
  end
  for source, label in pairs(names) do
    actions[source] = { label = label, run = function(frame)
      frame.data.source, frame.data.selected_id, frame.data.selected, frame.data.message = source, nil, 1, nil
      local result, err = refresh(frame)
      return result ~= nil, err
    end }
  end
  for id, delta in pairs({ next = 1, previous = -1, page_down = 10, page_up = -10 }) do
    actions[id] = { label = id:gsub("_", " "), hidden = true,
      control = id:sub(1, 5) == "page_" and id or nil, run = function(frame, _, _, opts)
        local items = frame.data.items or {}
        frame.data.selected = Lists.move(frame.data.selected, #items, delta, opts and opts.navigation)
        frame.data.selected_id = items[frame.data.selected] and items[frame.data.selected].id
        frame.data.message = nil
      end }
  end
  return { id = "results", name = "Results", icon = "≡", actions = actions,
    state_scope = "window", state_fields = { "source", "scope", "filter", "filter_cursor", "selected", "selected_id", "preview", "task_id" },
    bindings = { ["<CR>"] = "open", r = "refresh", p = "preview", f = "filter", c = "clear_filter",t='owning_task',
      R='follow_retry',C='follow_recover',V='follow_review',
      d = "diagnostics", q = "quickfix", l = "loclist", j = "next", ["<Down>"] = "next", ["<C-n>"] = "next",
      k = "previous", ["<Up>"] = "previous", ["<C-p>"] = "previous", ["<C-d>"] = "page_down",
      ["<PageDown>"] = "page_down", ["<C-u>"] = "page_up", ["<PageUp>"] = "page_up" },
    enter = function(frame)
      validate(frame)
      local initial, saved = frame.initial_data or {}, frame.remembered_data or {}
      if initial.source ~= nil and initial.source ~= saved.source or initial.scope ~= nil and initial.scope ~= saved.scope
        or initial.task_id ~= nil and initial.task_id ~= saved.task_id then
        frame.data.filter, frame.data.filter_cursor, frame.data.selected, frame.data.selected_id = "", 0, 1, nil
      end
      frame.data.source, frame.data.filter, frame.data.selected = frame.data.source or "diagnostics", frame.data.filter or "", frame.data.selected or 1
      frame.data.filter_cursor = math.min(frame.data.filter_cursor or vim.fn.strchars(frame.data.filter), vim.fn.strchars(frame.data.filter))
      refresh(frame)
    end,
    resume = function(frame)
      validate(frame)
      local update = frame.initial_update
      if update then
        local initial, before = update.values, update.before
        if initial.source ~= nil and initial.source ~= before.source or initial.scope ~= nil and initial.scope ~= before.scope
          or initial.task_id ~= nil and initial.task_id ~= before.task_id then
          frame.data.filter, frame.data.filter_cursor, frame.data.selected, frame.data.selected_id = "", 0, 1, nil
          frame.data.input_active, frame.data.message = nil, nil
        end
      end
      refresh(frame)
    end,
    handle = function(frame, key, _, _, opts)
      if not frame.data.input_active then return false end
      if key == "<Esc>" then
        frame.data.filter, frame.data.input_active = frame.data.filter_before, false
        frame.data.filter_cursor = frame.data.filter_before_cursor or vim.fn.strchars(frame.data.filter)
        frame.data.selected, frame.data.selected_id = frame.data.filter_before_selected, frame.data.filter_before_selected_id
      elseif key == "<CR>" then frame.data.input_active = false
      elseif key == "<Up>" or key == "<Down>" then actions[key == "<Up>" and "previous" or "next"].run(frame, nil, nil, opts)
      else
        local value, cursor = Text.edit(frame.data.filter, frame.data.filter_cursor, key)
        if #value <= 4096 then frame.data.filter, frame.data.filter_cursor = value, cursor end
      end
      refresh(frame)
      return true
    end,
    draw = function(frame, _, session, opts)
      local result, item = frame.data.result, selected(frame)
      local status = item and item.reason or result and (result.reason or result.status_message)
      local content = frame.data.preview and item and vim.split(preview(item), "\n", { plain = true }) or nil
      if result and result.truncated and frame.data.source ~= "task" then status = (status and status .. "\n" or "") .. "Showing the first 5000 results" end
      V.draw(frame.view, { title = vim.trim(opts.title or "Results"), path = opts.path,
        required_label = frame.data.source == 'task' and result and result.title or nil,
        required_notice = result and result.truncated and (result.status_message or status or 'Partial results; output limit reached') or nil,
        target = item and item.detail or nil,
        _source_target_items = result and result.items or nil,
        label = (frame.data.source == "task" and result and result.title or names[frame.data.source]) .. (frame.data.source == "diagnostics" and (frame.data.scope == "buffer" and " · current buffer" or " · all buffers") or "")
          .. " · " .. #(frame.data.items or {}) .. " results",
        query = frame.data.input_active and frame.data.filter or nil,
        query_text = frame.data.input_active and frame.data.filter or nil, query_cursor = frame.data.filter_cursor,
        query_label = "Filter", items = frame.data.items or {}, selected = frame.data.selected,
        empty = frame.data.source == "diagnostics" and ((frame.data.filter or "") ~= "" and "No diagnostics match this filter" or "No diagnostics")
          or frame.data.source == "task" and result and result.empty or "No matching results",
        details = status and { reason = status } or nil, status = status, content = content, message = frame.data.message or session.message,
        help = frame.data.input_active and "Enter Apply · Esc Restore filter · F1 View" or opts.help,
        minimal_help = frame.data.input_active and "Enter Apply · Esc Back" or "Enter Open · f Filter · Esc Back" },
        vim.tbl_extend("force", { width = 80, max_width = 120, icons = false }, opts.window or {},
          { density = opts.density, accent = opts.accent }))
    end,
  }
end

return M
