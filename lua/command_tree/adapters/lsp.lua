local M = { timeout_ms = 8000 }
local K = require("command_tree.keys")

local function clients(ctx, method)
  local result = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = ctx.buf })) do
    if client:supports_method(method, ctx.buf) then result[#result + 1] = client end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

function M.available(method, ranges, integration)
  return function(ctx)
    if ranges and ctx.selection and ctx.selection.mode == "\22" then
      return false, "Block selections are not supported; use a character or line selection"
    end
    local name = type(method) == "function" and method(ctx) or method
    if #clients(ctx, name) > 0 then return true end
    if integration and integration.readiness then
      local ready, why = integration.readiness(ctx, name)
      -- Host setup readiness can explain a missing server, but it cannot
      -- supply the attached capability required by the executor below.
      if not ready then return false, why or 'Language support is unavailable' end
    end
    if vim.bo[ctx.buf].filetype == "" then return false, "Filetype is not set; choose a filetype before using LSP" end
    if #vim.lsp.get_clients({ bufnr = ctx.buf }) == 0 then return false, "No language server is attached for " .. vim.bo[ctx.buf].filetype end
    return false, "Attached language servers do not support " .. name
  end
end

local function unchanged(ctx)
  if not K.valid(ctx) then return false, "Command target changed" end
  if ctx.changedtick and vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.changedtick then
    return false, "Source changed while waiting; run the command again"
  end
  return true
end

local function position(ctx, client, cursor)
  cursor = cursor or ctx.cursor or vim.api.nvim_win_get_cursor(ctx.win)
  local line = vim.api.nvim_buf_get_lines(ctx.buf, cursor[1] - 1, cursor[1], false)[1] or ""
  return { line = cursor[1] - 1,
    character = vim.str_utfindex(line, client.offset_encoding or "utf-16", math.min(cursor[2], #line), false) }
end

function M.word(ctx)
  return vim.api.nvim_win_call(ctx.win, function()
    local original = vim.api.nvim_win_get_cursor(ctx.win)
    if ctx.cursor then vim.api.nvim_win_set_cursor(ctx.win, ctx.cursor) end
    local ok, word = pcall(vim.fn.expand, "<cword>")
    vim.api.nvim_win_set_cursor(ctx.win, original)
    if not ok then error(word) end
    return word
  end)
end

local function params(ctx, client)
  return { textDocument = { uri = vim.uri_from_bufnr(ctx.buf) }, position = position(ctx, client) }
end

local function range(ctx, client)
  if not ctx.selection then
    local point = position(ctx, client)
    return { start = point, ["end"] = vim.deepcopy(point) }
  end
  local selection = ctx.selection
  local last = vim.deepcopy(selection.finish)
  local line = vim.api.nvim_buf_get_lines(ctx.buf, last[1] - 1, last[1], false)[1] or ""
  if selection.mode == "V" then last[2] = #line
  elseif not selection.exclusive and last[2] < #line then
    local tail = line:sub(last[2] + 1)
    local char = vim.fn.strcharpart(tail, 0, 1)
    last[2] = last[2] + #char
  end
  return { start = position(ctx, client, selection.start), ["end"] = position(ctx, client, last) }
end

local function operation(ctx, done, invocation)
  local op = { pending = {}, finished = false, ticks = {} }
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then op.ticks[buf] = vim.api.nvim_buf_get_changedtick(buf) end
  end
  function op:finish(ok, result)
    if self.finished then return end
    self.finished = true
    for _, request in ipairs(self.pending) do
      if request.timer then request.timer:stop(); request.timer:close(); request.timer = nil end
      if request.id and not request.complete then pcall(request.client.cancel_request, request.client, request.id) end
    end
    done(ok, result)
  end
  function op:valid()
    if self.finished then return false end
    local ok, reason = unchanged(ctx)
    if not ok then self:finish(false, reason) end
    return ok
  end
  function op:request(client, method, payload, callback)
    if not self:valid() then return end
    local request = { client = client }
    self.pending[#self.pending + 1] = request
    local dispatched, accepted, id = pcall(client.request, client, method, payload, function(err, response)
      if request.complete then return end
      request.complete = true
      if request.timer then request.timer:stop(); request.timer:close(); request.timer = nil end
      if self.finished then return end
      if err then self:finish(false, client.name .. ": " .. ((type(err) == "table" and err.message) or vim.inspect(err))); return end
      if not self:valid() then return end
      local ok, failure = pcall(callback, response)
      if not ok then self:finish(false, failure) end
    end, ctx.buf)
    if not dispatched then self:finish(false, tostring(accepted)); return end
    request.id = id
    if not accepted then self:finish(false, "LSP rejected " .. method); return end
    if self.finished and not request.complete then
      if id then pcall(client.cancel_request, client, id) end
      return
    end
    if not request.complete and not self.finished then
      local started, failure = pcall(function()
        request.timer = assert(vim.uv.new_timer(), "Could not allocate LSP timeout timer")
        request.timer:start(M.timeout_ms, 0, vim.schedule_wrap(function()
          self:finish(false, "LSP request timed out: " .. method)
        end))
      end)
      if not started then self:finish(false, "Could not start LSP timeout: " .. tostring(failure)) end
    end
  end
  function op:select(items, prompt, label, callback, options)
    if not self:valid() then return end
    local function accept(item)
      if self.finished then return end
      if item == nil then self:finish(false, "Cancelled"); return end
      if not self:valid() then return end
      local ok, err = pcall(callback, item)
      if not ok then self:finish(false, err) end
    end
    options = vim.tbl_extend("force", {}, options or {}, { prompt = prompt, format_item = label })
    if invocation and invocation.select then invocation:select(items, options, accept)
    else vim.ui.select(items, options, accept) end
  end
  function op:client(method, callback)
    local eligible = clients(ctx, method)
    if #eligible == 0 then self:finish(false, "No LSP supports " .. method)
    elseif #eligible == 1 then callback(eligible[1])
    else self:select(eligible, "Choose language server", function(client) return client.name .. " (#" .. client.id .. ")" end, callback) end
  end
  local cancel = function() op:finish(false, "Cancelled") end
  if invocation and invocation.on_cancel then invocation:on_cancel(cancel) end
  return op, cancel
end

function M.format(ctx, _, done, invocation)
  local op, cancel = operation(ctx, done, invocation)
  local method = ctx.selection and "textDocument/rangeFormatting" or "textDocument/formatting"
  op:client(method, function(client)
    local options = vim.bo[ctx.buf]
    local payload = { textDocument = { uri = vim.uri_from_bufnr(ctx.buf) },
      options = { tabSize = options.shiftwidth > 0 and options.shiftwidth or options.tabstop, insertSpaces = options.expandtab } }
    if ctx.selection then payload.range = range(ctx, client) end
    op:request(client, method, payload, function(edits)
      if not op:valid() then return end
      edits = edits ~= vim.NIL and edits or nil
      vim.lsp.util.apply_text_edits(edits or {}, ctx.buf, client.offset_encoding)
      op:finish(true, { edits = edits and #edits or 0, client = client.name })
    end)
  end)
  return cancel
end

-- A review holds the exact bytes/lines that produced its diff. No target is
-- loaded or edited merely to inspect it, including files outside the source.
local function disk_bytes(path)
  local stat, failure, code = vim.uv.fs_stat(path)
  if not stat then
    assert(code == "ENOENT", "Cannot inspect rename target: " .. tostring(failure))
    return false
  end
  assert(stat.type == "file", "Rename target is not a regular file: " .. path)
  assert(stat.size <= 1048576, "Rename target exceeds the 1 MiB review limit: " .. path)
  local fd, failure = vim.uv.fs_open(path, "r", 438)
  assert(fd, "Cannot read rename target: " .. tostring(failure))
  local ok, bytes = pcall(vim.uv.fs_read, fd, stat.size + 1, 0)
  vim.uv.fs_close(fd)
  assert(ok and type(bytes) == "string", "Cannot read rename target: " .. tostring(bytes))
  assert(#bytes == stat.size, "Rename target changed while reading: " .. path)
  return bytes
end

local function disk_lines(bytes)
  assert(type(bytes) == "string", "An unloaded rename target no longer exists")
  assert(not bytes:find("\0", 1, true), "Binary documents cannot be reviewed for rename")
  bytes = bytes:gsub("^\239\187\191", ""):gsub("\r\n", "\n")
  if bytes:sub(-1) == "\n" then bytes = bytes:sub(1, -2) end
  return vim.split(bytes, "\n", { plain = true })
end

local function rename_plan(op, client, edit)
  assert(type(edit) == "table", "Language server returned an invalid rename edit")
  assert(not (edit.changes and edit.documentChanges), "Rename returned two conflicting edit representations")
  local targets, order, count, total = {}, {}, 0, 0
  local function add(uri, edits, version)
    assert(type(uri) == "string" and #uri <= 32768, "Rename returned an invalid document URI")
    assert(type(edits) == "table" and vim.islist(edits), "Rename returned an invalid edit list")
    assert(not targets[uri], "Rename returned repeated document changes; request a fresh rename")
    if #edits == 0 then return end
    local buf = vim.uri_to_bufnr(uri)
    local loaded = vim.api.nvim_buf_is_loaded(buf)
    if loaded and op.ticks[buf] and op.ticks[buf] ~= vim.api.nvim_buf_get_changedtick(buf) then
      error("A target document changed while waiting; request a fresh rename")
    end
    if loaded and not op.ticks[buf] and vim.bo[buf].modified then error("A target document changed while waiting") end
    local path = uri:match("^file:") and vim.uri_to_fname(uri) or nil
    assert(loaded or path, "Cannot review an unloaded non-file document")
    local disk = path and disk_bytes(path) or nil
    local before = loaded and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or disk_lines(disk)
    local text = table.concat(before, "\n") .. "\n"
    total, count = total + #text, count + #edits
    assert(#order < 100 and count <= 10000 and total <= 4194304, "Rename is too large to review safely (100 files / 10000 edits / 4 MiB)")
    local annotations, annotation_ids = {}, {}
    for _, item in ipairs(edits) do
      assert(type(item) == "table" and type(item.newText) == "string" and type(item.range) == "table", "Rename returned an invalid text edit")
      if item.annotationId then
        local annotation = (edit.changeAnnotations or {})[item.annotationId]
        assert(type(annotation) == "table" and type(annotation.label) == "string", "Rename returned an invalid change annotation")
        assert(#annotation.label <= 4096 and (annotation.description == nil or
          (type(annotation.description) == "string" and #annotation.description <= 4096)), "Rename annotation is too large")
        if not annotation_ids[item.annotationId] then
          annotation_ids[item.annotationId] = true
          annotations[#annotations + 1] = "# " .. (annotation.needsConfirmation and "Requires confirmation: " or "")
            .. annotation.label .. (annotation.description and (" — " .. annotation.description) or "")
        end
        -- The complete edit is copied before review. Our explicit Apply choice
        -- confirms these displayed annotations; prevent a later native prompt
        -- from independently accepting only part of the reviewed workspace edit.
        item.annotationId = nil
      end
      total = total + #item.newText
      assert(total <= 4194304, "Rename replacement text exceeds the 4 MiB review limit")
      local points = { item.range.start, item.range["end"] }
      assert(points[1] and points[2], "Rename returned an incomplete text range")
      for _, point in ipairs(points) do
        assert(type(point.line) == "number" and point.line >= 0 and point.line % 1 == 0 and point.line <= #before,
          "Rename range is outside the current document")
        local line = before[point.line + 1] or ""
        local length = vim.str_utfindex(line, client.offset_encoding or "utf-16", #line, false)
        assert(type(point.character) == "number" and point.character >= 0 and point.character % 1 == 0 and point.character <= length,
          "Rename column is outside the current document")
      end
      assert(points[1].line < points[2].line or (points[1].line == points[2].line and points[1].character <= points[2].character),
        "Rename returned a reversed text range")
    end
    local scratch = vim.api.nvim_create_buf(false, true)
    local applied, after = pcall(function()
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, before)
      vim.lsp.util.apply_text_edits(vim.deepcopy(edits), scratch, client.offset_encoding or "utf-16")
      return vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    end)
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    assert(applied, "Could not prepare rename diff: " .. tostring(after))
    local difference = vim.diff(text, table.concat(after, "\n") .. "\n", { result_type = "unified", ctxlen = 3 })
    local label = path and vim.fn.fnamemodify(path, ":~:.") or uri
    local lines = { "--- " .. label, "+++ " .. label }
    vim.list_extend(lines, annotations)
    vim.list_extend(lines, vim.split(difference, "\n", { plain = true, trimempty = true }))
    local target = { uri = uri, buf = buf, name = vim.api.nvim_buf_get_name(buf), loaded = loaded,
      tick = loaded and vim.api.nvim_buf_get_changedtick(buf) or nil, before = before, disk = disk, path = path,
      version = version, edits = #edits, label = label, lines = lines }
    targets[uri], order[#order + 1] = target, target
  end
  for uri, edits in pairs(edit.changes or {}) do add(uri, edits) end
  for _, change in ipairs(edit.documentChanges or {}) do
    assert(type(change) == "table" and change.textDocument and not change.kind,
      "Rename includes file create/delete/move operations; no changes were applied")
    add(change.textDocument.uri, change.edits, change.textDocument.version)
  end
  assert(#order > 0, "The server returned no rename changes")
  table.sort(order, function(a, b) return a.label < b.label end)
  return { targets = order, edits = count }
end

local function validate_plan(plan, load)
  -- Loading may trigger user autocmds. Finish loading *all* targets before the
  -- final pass, then verify all of them again before the first actual edit.
  if load then
    for _, target in ipairs(plan.targets) do
      assert(vim.api.nvim_buf_is_valid(target.buf) and vim.api.nvim_buf_get_name(target.buf) == target.name,
        "A reviewed document was removed or renamed")
      if not vim.api.nvim_buf_is_loaded(target.buf) then vim.fn.bufload(target.buf) end
    end
  end
  for _, target in ipairs(plan.targets) do
    assert(vim.api.nvim_buf_is_valid(target.buf) and vim.api.nvim_buf_get_name(target.buf) == target.name,
      "A reviewed document was removed or renamed")
    if target.path then assert(disk_bytes(target.path) == target.disk, "A target file changed on disk after review: " .. target.label) end
    if target.loaded then
      assert(vim.api.nvim_buf_is_loaded(target.buf) and vim.api.nvim_buf_get_changedtick(target.buf) == target.tick,
        "A target buffer changed after review: " .. target.label)
    end
    if vim.api.nvim_buf_is_loaded(target.buf) then
      assert(vim.bo[target.buf].modifiable, "A target buffer is not modifiable: " .. target.label)
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(target.buf, 0, -1, false), target.before),
        "A target buffer changed after review: " .. target.label)
      local version = vim.lsp.util.buf_versions[target.buf]
      assert(type(target.version) ~= "number" or not version or target.version == version,
        "The reviewed document version no longer matches the language server")
    end
  end
end

local function apply_workspace(op, ctx, client, edit, plan)
  if not op:valid() then return false end
  if plan then
    local valid, failure = pcall(validate_plan, plan, true)
    if not valid then op:finish(false, tostring(failure) .. "; no workspace edits were applied"); return false end
    if not op:valid() then return false end
  end
  if edit then
    local affected = {}
    for uri in pairs(edit.changes or {}) do affected[vim.uri_to_bufnr(uri)] = true end
    for _, change in ipairs(edit.documentChanges or {}) do
      if change.textDocument then
        local buffer = vim.uri_to_bufnr(change.textDocument.uri)
        affected[buffer] = true
        local version = vim.lsp.util.buf_versions[buffer]
        if type(change.textDocument.version) == "number" and change.textDocument.version > 0 and version and version > change.textDocument.version then
          op:finish(false, "A document changed before the workspace edit could be applied")
          return false
        end
      end
    end
    for buffer in pairs(affected) do
      if vim.api.nvim_buf_is_loaded(buffer) and
        ((op.ticks[buffer] and op.ticks[buffer] ~= vim.api.nvim_buf_get_changedtick(buffer))
          or (not op.ticks[buffer] and vim.bo[buffer].modified)) then
        op:finish(false, "A target document changed while waiting; no workspace edits were applied")
        return false
      end
    end
    local applied, failure = pcall(vim.lsp.util.apply_workspace_edit, edit, client.offset_encoding)
    if not applied then
      op:finish(false, "Workspace edit failed; some edits may already have been applied: " .. tostring(failure))
      return false
    end
    for buffer in pairs(affected) do
      if vim.api.nvim_buf_is_valid(buffer) then op.ticks[buffer] = vim.api.nvim_buf_get_changedtick(buffer) end
    end
  end
  -- A code action may execute a server command after applying its own edits.
  ctx.changedtick = vim.api.nvim_buf_get_changedtick(ctx.buf)
  return true
end

local function review_rename(op, ctx, client, edit, plan)
  local function preview(lines, selected)
    local bounded = {}
    for index = math.max(1, (selected or 1) - 4), math.min(#lines, (selected or 1) + 12) do
      bounded[#bounded + 1] = vim.fn.strcharpart(lines[index], 0, 2000)
    end
    local _, win = vim.lsp.util.open_floating_preview(bounded, "diff", {
      focus = false, focusable = false, border = "rounded", max_width = 100, max_height = 17,
    })
    return function() if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
  end
  local menu
  menu = function()
    if not op:valid() then return end
    local entries = {}
    for _, target in ipairs(plan.targets) do entries[#entries + 1] = { target = target,
      label = "Inspect " .. target.label .. " (" .. target.edits .. " edits)" } end
    entries[#entries + 1] = { apply = true, label = "Apply reviewed rename to " .. #plan.targets .. " files" }
    entries[#entries + 1] = { cancel = true, label = "Cancel rename" }
    op:select(entries, "Review rename — " .. #plan.targets .. " files, " .. plan.edits .. " edits",
      function(item) return item.label end, function(item)
        if item.cancel then op:finish(false, "Cancelled")
        elseif item.apply then
          if apply_workspace(op, ctx, client, edit, plan) then
            op:finish(true, { client = client.name, files = #plan.targets, edits = plan.edits, reviewed = true })
          end
        else
          local lines = {}
          for index, line in ipairs(item.target.lines) do lines[#lines + 1] = { line = index, text = line } end
          op:select(lines, "Diff: " .. item.target.label .. " — Enter returns to review",
            function(line) return vim.fn.strcharpart(line.text, 0, 2000) end, function() menu() end,
            { preview = function(line) return preview(item.target.lines, line and line.line) end })
        end
      end, { preview = function(item)
        if item and item.target then return preview(item.target.lines) end
        return preview({ "Review all affected files before applying.",
          "Loaded buffers and file bytes will be rechecked before the first edit.", "Changes remain unsaved in Neovim buffers." })
      end })
  end
  menu()
end

function M.rename(ctx, args, done, invocation)
  local op, cancel = operation(ctx, done, invocation)
  op:client("textDocument/rename", function(client)
    local payload = params(ctx, client)
    payload.newName = args.new_name
    op:request(client, "textDocument/rename", payload, function(edit)
      if not edit or edit == vim.NIL then op:finish(false, "The server returned no rename edit"); return end
      local reviewed = vim.deepcopy(edit)
      local plan = rename_plan(op, client, reviewed)
      review_rename(op, ctx, client, reviewed, plan)
    end)
  end)
  return cancel
end

local function diagnostics(ctx, client)
  local namespace = vim.lsp.diagnostic.get_namespace(client.id)
  local result = {}
  local first = ctx.selection and ctx.selection.start[1] - 1 or (ctx.cursor or vim.api.nvim_win_get_cursor(ctx.win))[1] - 1
  local last = ctx.selection and ctx.selection.finish[1] - 1 or first
  for _, diagnostic in ipairs(vim.diagnostic.get(ctx.buf, { namespace = namespace })) do
    if diagnostic.lnum <= last and (diagnostic.end_lnum or diagnostic.lnum) >= first then
      local original = diagnostic.user_data and diagnostic.user_data.lsp
      if original then result[#result + 1] = original end
    end
  end
  return result
end

function M.code_action(ctx, _, done, invocation)
  local op, cancel = operation(ctx, done, invocation)
  local eligible, actions, remaining = clients(ctx, "textDocument/codeAction"), {}, 0
  remaining = #eligible
  if remaining == 0 then op:finish(false, "No LSP supports code actions"); return cancel end
  local function execute(item)
    local client, action = item.client, item.action
    local function apply(resolved)
      if not op:valid() then return end
      if resolved.disabled then op:finish(false, resolved.disabled.reason or "Action is disabled"); return end
      if resolved.edit and not apply_workspace(op, ctx, client, resolved.edit) then return end
      local command = type(resolved.command) == "string" and resolved or resolved.command
      if not command then op:finish(true, { title = resolved.title, client = client.name }); return end
      local handler = (client.commands or {})[command.command] or vim.lsp.commands[command.command]
      if handler then
        handler(command, { bufnr = ctx.buf, client_id = client.id })
        op:finish(true, { title = resolved.title, client = client.name, dispatched = true,
          detail = "Client command handler returned; any later plugin work is managed by that plugin" })
      else
        op:request(client, "workspace/executeCommand", { command = command.command, arguments = command.arguments }, function(result)
          op:finish(true, { title = resolved.title, client = client.name, result = result })
        end)
      end
    end
    if not action.edit and type(action.command) ~= "string" and client:supports_method("codeAction/resolve", ctx.buf) then
      op:request(client, "codeAction/resolve", action, apply)
    else apply(action) end
  end
  for _, client in ipairs(eligible) do
    local payload = { textDocument = { uri = vim.uri_from_bufnr(ctx.buf) }, range = range(ctx, client),
      context = { diagnostics = diagnostics(ctx, client), triggerKind = 1 } }
    op:request(client, "textDocument/codeAction", payload, function(result)
      for _, action in ipairs(result ~= vim.NIL and result or {}) do
        if not action.disabled then actions[#actions + 1] = { client = client, action = action } end
      end
      remaining = remaining - 1
      if remaining == 0 then
        table.sort(actions, function(a, b) return (a.action.title or "") < (b.action.title or "") end)
        if #actions == 0 then op:finish(false, "No code actions at the captured position")
        else op:select(actions, "Code actions", function(item) return item.action.title .. " [" .. item.client.name .. "]" end, execute) end
      end
    end)
  end
  return cancel
end

local function location_record(location, client, name)
  assert(type(location) == "table", "Language server returned an invalid location")
  local uri, selected = location.uri or location.targetUri, location.range or location.targetSelectionRange
  assert(type(uri) == "string" and #uri <= 32768 and uri:match("^[%a][%w+.-]*:"), "Language server returned an invalid location URI")
  assert(type(selected) == "table", "Language server returned a location without a selection range")
  for _, point in ipairs({ selected.start, selected["end"] }) do
    assert(type(point) == "table", "Language server returned an incomplete location range")
    for _, field in ipairs({ "line", "character" }) do
      local value = point[field]
      assert(type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0,
        "Language server returned an invalid location " .. field)
    end
  end
  assert(selected["end"].line > selected.start.line or (selected["end"].line == selected.start.line
    and selected["end"].character >= selected.start.character), "Language server returned a reversed location range")
  local filename = uri:match("^file:") and vim.uri_to_fname(uri) or uri
  local label = vim.fn.fnamemodify(filename, ":~:.") .. ":" .. (selected.start.line + 1) .. ":" .. (selected.start.character + 1)
  return { location = { uri = uri, range = selected }, client = client,
    label = name and (name .. " — " .. label) or label }
end

local function location_buffer(item)
  local uri, point = item.location.uri, item.location.range.start
  local buf = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(buf) then
    if uri:match("^file:") then
      local stat = vim.uv.fs_stat(vim.uri_to_fname(uri))
      assert(stat and stat.type == "file", "Location file no longer exists")
    end
    vim.fn.bufload(buf)
  end
  assert(vim.api.nvim_buf_is_loaded(buf), "Could not load the location document")
  assert(point.line < vim.api.nvim_buf_line_count(buf), "Location is outside the current document")
  local line = vim.api.nvim_buf_get_lines(buf, point.line, point.line + 1, false)[1] or ""
  local last = vim.str_utfindex(line, item.client.offset_encoding or "utf-16", #line, false)
  assert(point.character <= last, "Location column is outside the current document")
  return buf
end

local function floating_preview(lines, syntax)
  -- A server or generated source can contain very long lines. Bound the actual
  -- preview buffer, not just the floating window's visible dimensions.
  local bounded = {}
  for index = 1, math.min(#lines, 14) do
    local line = lines[index]
    bounded[index] = vim.fn.strcharpart(line, 0, 2000)
    if #bounded[index] < #line then bounded[index] = bounded[index] .. "…" end
  end
  local _, win = vim.lsp.util.open_floating_preview(bounded, syntax, {
    focus = false, focusable = false, border = "rounded", max_width = 80, max_height = 14,
  })
  return function() if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
end

local function preview_location(item)
  if not item then return end
  local buf = location_buffer(item)
  local point = item.location.range.start
  local first, last = math.max(0, point.line - 3), math.min(vim.api.nvim_buf_line_count(buf), point.line + 9)
  local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
  for index, line in ipairs(lines) do lines[index] = (first + index == point.line + 1 and "› " or "  ") .. line end
  return floating_preview(lines, vim.bo[buf].filetype)
end

local function choose_location(op, ctx, client, locations, prompt, symbols, truncated)
  local items, seen = {}, {}
  local maximum = 2000
  for index, entry in ipairs(locations) do
    if index > 10000 then truncated = true; break end
    local item = location_record(symbols and entry.location or entry, client, symbols and entry.name or nil)
    local point = item.location.range.start
    local key = item.location.uri .. ":" .. point.line .. ":" .. point.character
    if not seen[key] then
      seen[key] = true
      if #items == maximum then truncated = true; break end
      items[#items + 1] = item
    end
  end
  local function jump(item)
    if not op:valid() then return end
    location_buffer(item)
    local opened = vim.api.nvim_win_call(ctx.win, function()
      return vim.lsp.util.show_document(item.location, client.offset_encoding or "utf-16", { reuse_win = false, focus = true })
    end)
    if not opened then op:finish(false, "Could not open the selected location"); return end
    op:finish(true, { client = client.name, location = item.location })
  end
  if #items == 0 then op:finish(false, "No " .. prompt:lower() .. " at the captured position")
  elseif #items == 1 and not truncated then jump(items[1])
  else
    if truncated then prompt = prompt .. " (results limited to " .. maximum .. ")" end
    op:select(items, prompt, function(item) return item.label end, jump, { preview = preview_location })
  end
end

function M.navigation(method, prompt)
  return function(ctx, _, done, invocation)
    local op, cancel = operation(ctx, done, invocation)
    op:client(method, function(client)
      local payload = params(ctx, client)
      if method == "textDocument/references" then payload.context = { includeDeclaration = true } end
      op:request(client, method, payload, function(result)
        local locations = result ~= vim.NIL and result or {}
        assert(type(locations) == "table", "Language server returned an invalid location response")
        if locations.uri or locations.targetUri then locations = { locations } end
        assert(vim.islist(locations), "Language server returned an invalid location list")
        choose_location(op, ctx, client, locations, prompt)
      end)
    end)
    return cancel
  end
end

function M.document_symbols(ctx, _, done, invocation)
  local op, cancel = operation(ctx, done, invocation)
  op:client("textDocument/documentSymbol", function(client)
    op:request(client, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(ctx.buf) } }, function(result)
      local entries, truncated = {}, false
      local function collect(symbols, prefix, depth)
        assert(depth < 64, "Language server returned excessively nested symbols")
        assert(type(symbols) == "table" and vim.islist(symbols), "Language server returned an invalid symbol list")
        for _, symbol in ipairs(symbols) do
          if #entries >= 2000 then truncated = true; return end
          assert(type(symbol) == "table" and type(symbol.name) == "string", "Language server returned an invalid symbol")
          local name = vim.fn.strcharpart(prefix .. vim.fn.strcharpart(symbol.name, 0, 512), 0, 4096)
          entries[#entries + 1] = { name = name, location = symbol.location or {
            uri = vim.uri_from_bufnr(ctx.buf), range = symbol.selectionRange or symbol.range,
          } }
          if symbol.children then collect(symbol.children, name .. " › ", depth + 1) end
        end
      end
      collect(result ~= vim.NIL and result or {}, "", 0)
      choose_location(op, ctx, client, entries, "Document symbols", true, truncated)
    end)
  end)
  return cancel
end

local function hover_lines(contents)
  local budget, nodes, truncated = 131072, 0, false
  local function text(value)
    assert(type(value) == "string", "Language server returned invalid hover text")
    if #value <= budget then budget = budget - #value; return value end
    local last = budget
    -- Do not split a UTF-8 sequence when enforcing the total byte budget.
    while last > 0 do
      local byte = value:byte(last + 1)
      if not byte or byte < 128 or byte >= 192 then break end
      last = last - 1
    end
    budget, truncated = 0, true
    return value:sub(1, last)
  end
  local function bounded(value, depth)
    nodes = nodes + 1
    assert(depth < 16 and nodes <= 4000, "Language server returned excessively nested hover content")
    if type(value) == "string" then return text(value) end
    assert(type(value) == "table", "Language server returned invalid hover content")
    if value.kind then return { kind = value.kind, value = text(value.value or "") } end
    if value.language then
      assert(type(value.language) == "string" and #value.language <= 128, "Language server returned invalid hover language")
      return { language = value.language, value = text(value.value or "") }
    end
    assert(vim.islist(value), "Language server returned an invalid hover list")
    local items = {}
    for index, item in ipairs(value) do
      if budget == 0 or index > 2000 then truncated = true; break end
      items[#items + 1] = bounded(item, depth + 1)
    end
    return items
  end
  local lines = vim.lsp.util.convert_input_to_markdown_lines(bounded(contents, 0))
  if #lines > 2000 then lines, truncated = vim.list_slice(lines, 1, 2000), true end
  return lines, truncated
end

function M.hover(ctx, _, done, invocation)
  local op, cancel = operation(ctx, done, invocation)
  op:client("textDocument/hover", function(client)
    op:request(client, "textDocument/hover", params(ctx, client), function(result)
      if not result or result == vim.NIL or not result.contents then op:finish(false, "No hover information at the captured position"); return end
      local lines, truncated = hover_lines(result.contents)
      if #lines == 0 or table.concat(lines, ""):match("^%s*$") then op:finish(false, "No hover information at the captured position"); return end
      -- A bounded line picker lets long documentation scroll using the same
      -- selection controls. The adjacent preview shows a readable paragraph.
      local items = {}
      for index = 1, math.min(#lines, 2000) do items[#items + 1] = { line = index, text = lines[index] } end
      op:select(items, "Hover — Enter closes" .. (truncated and " (content limited)" or ""),
        function(item) return item.text ~= "" and vim.fn.strcharpart(item.text, 0, 2000) or " " end,
        function() op:finish(true, { client = client.name, lines = #lines }) end,
        { preview = function(item)
          if not item then return end
          return floating_preview(vim.list_slice(lines, math.max(1, item.line - 3), math.min(#lines, item.line + 10)), "markdown")
        end })
    end)
  end)
  return cancel
end

function M.health_lines(ctx, integration)
  local lines = { "Filetype: " .. vim.bo[ctx.buf].filetype }
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = ctx.buf })) do
    local capabilities = {}
    for _, entry in ipairs({ { "format", "textDocument/formatting" }, { "rename", "textDocument/rename" },
      { "action", "textDocument/codeAction" } }) do
      if client:supports_method(entry[2], ctx.buf) then capabilities[#capabilities + 1] = entry[1] end
    end
    lines[#lines + 1] = client.name .. ": " .. table.concat(capabilities, ", ")
  end
  if #lines == 1 then lines[#lines + 1] = "No language server attached" end
  if integration and integration.status then
    local additional = integration.status(ctx)
    assert(type(additional) == "table", "integrations.lsp.status must return a list of lines")
    for _, line in ipairs(additional) do
      assert(type(line) == "string", "integrations.lsp.status lines must be strings")
      lines[#lines + 1] = line
    end
  end
  if integration and integration.readiness then
    local ready, why = integration.readiness(ctx)
    lines[#lines + 1] = ready and "Ready" or (why or "Language support is unavailable")
  end
  return lines
end

function M.health(ctx, integration)
  local lines = M.health_lines(ctx, integration)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable, vim.bo[buffer].bufhidden = false, "wipe"
  vim.cmd("botright 10split")
  vim.api.nvim_win_set_buf(0, buffer)
  return true
end

return M
