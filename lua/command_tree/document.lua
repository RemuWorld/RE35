-- A Neovim document is a captured loaded buffer, including unsaved text.
-- Literal search/replacement and edit-plan validation belong to the portable
-- contract; window focus, buffer identity, undo and preview belong to this host.
local K = require('command_tree.keys')
local Core = require('command_environment.core.document')
local Paged = require('command_tree.document.paged')
local M = {}
local namespace = vim.api.nvim_create_namespace('command_tree_document')

local function message(err) return tostring(err):gsub('^.-:%d+:%s*', '') end
local function target(ctx, editable)
  local valid, reason = K.unchanged(ctx)
  if not valid then return false, reason end
  if ctx.mode ~= 'n' or vim.bo[ctx.buf].buftype ~= '' or not vim.api.nvim_buf_is_loaded(ctx.buf) then
    return false, 'Open this command from a normal document buffer'
  end
  if type(ctx.changedtick) ~= 'number' then return false, 'A captured document revision is required' end
  if ctx.document_uri and ctx.document_uri ~= K.document_uri(ctx.buf) then
    return false, 'The original document was renamed; reopen the command'
  end
  if editable and not vim.bo[ctx.buf].modifiable then return false, 'This buffer cannot be modified' end
  if editable and vim.bo[ctx.buf].readonly then return false, 'This buffer is read-only' end
  if editable then
    local levels = vim.bo[ctx.buf].undolevels
    if levels == -123456 then levels = vim.go.undolevels end
    if levels < 0 then return false, 'Undo is disabled for this buffer; enable undo before reviewed replacement' end
  end
  return true
end

function M.snapshot(ctx, editable)
  local valid, reason = target(ctx, editable)
  assert(valid, reason)
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  assert(count <= 2000, 'Document snapshot exceeds 2000 lines')
  -- Reject a large host buffer before copying its contents into the contract.
  assert(vim.api.nvim_buf_get_offset(ctx.buf, count) - count <= 262144, 'Document snapshot exceeds 256 KiB')
  return Core.validate({ uri = K.document_uri(ctx.buf), revision = tostring(ctx.changedtick), encoding = 'utf-8',
    lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, true) })
end

-- The public v1 snapshot API keeps its original schema and bounds. Existing
-- commands opt into v2 only when a loaded document exceeds that v1 scope.
local function capture(ctx, editable)
  local valid, reason = target(ctx, editable); assert(valid, reason)
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  if count > 2000 or vim.api.nvim_buf_get_offset(ctx.buf, count) - count > 262144 then
    return Paged.capture(ctx, function(value) return target(value, editable) end)
  end
  return M.snapshot(ctx, editable)
end
local function prepare(snapshot, args)
  local replacement = { find = args.find, replace = args.replace or '' }
  return snapshot.contract_version == 2 and Paged.prepare(snapshot, replacement) or Core.prepare_replace(snapshot, replacement)
end

local function text_valid(value, replacement)
  local ok, err = pcall(Core.prepare_replace,
    { uri = 're35-buffer://validation', revision = '0', encoding = 'utf-8', lines = { '' } },
    { find = replacement and 'x' or value, replace = replacement and (value or '') or '' })
  return ok, not ok and message(err) or nil
end

-- These references remain in retained in-process tasks; they are neither file
-- revisions nor permission to resolve a similarly named replacement buffer.
function M.validate_location(item)
  local ref = item and item.document_target
  if ref == nil then return true end
  if item.vcol == true or item.vcol == 1 then
    return false, 'Document search locations require UTF-8 byte columns'
  end
  if type(ref) ~= 'table' or type(ref.buf) ~= 'number' or ref.buf < 1 or ref.buf % 1 ~= 0
    or ref.buf > 9007199254740991 or type(ref.uri) ~= 'string'
    or type(ref.revision) ~= 'string' or ref.encoding ~= 'utf-8'
    or not vim.api.nvim_buf_is_valid(ref.buf) or not vim.api.nvim_buf_is_loaded(ref.buf)
    or vim.bo[ref.buf].buftype ~= '' or K.document_uri(ref.buf) ~= ref.uri
    or tostring(vim.api.nvim_buf_get_changedtick(ref.buf)) ~= ref.revision then
    return false, 'Document search target changed, was renamed or closed; search the document again'
  end
  if item.bufnr ~= ref.buf or type(item.line) ~= 'number' or item.line % 1 ~= 0 or item.line < 1
    or item.line > vim.api.nvim_buf_line_count(ref.buf) or type(item.col) ~= 'number' or item.col % 1 ~= 0 or item.col < 1 then
    return false, 'Document search location is no longer valid; search the document again'
  end
  local line = vim.api.nvim_buf_get_lines(ref.buf, item.line - 1, item.line, true)[1]
  if item.col > #line + 1 or item.col > 1 and (line:byte(item.col) or 0) >= 128 and (line:byte(item.col) or 0) <= 191 then
    return false, 'Document search location is not a UTF-8 boundary'
  end
  return true
end

local function plan(ctx, args)
  return prepare(capture(ctx, true), args)
end
local function summary(value)
  return value.match_count .. ' literal match(es)'
end
local function preview(ctx, value, snapshot)
  local ids, closed = {}, false
  local function cleanup()
    if closed then return end
    closed = true
    if vim.api.nvim_buf_is_valid(ctx.buf) then
      for _, id in ipairs(ids) do pcall(vim.api.nvim_buf_del_extmark, ctx.buf, namespace, id) end
    end
  end
  local ok, err = pcall(function()
    local changes, shown = {}, 0
    if value.contract_version == 2 then
      changes, shown = Paged.preview_changes(snapshot, value, 100)
    else
      for index, line in ipairs(value.next_lines) do
        if line ~= value.original_lines[index] then
          shown = shown + 1
          if shown <= 100 then
            local text = vim.fn.strcharpart(line, 0, 180)
            if vim.fn.strchars(line) > 180 then text = text .. '…' end
            changes[#changes + 1] = { line = index - 1, text = text }
          end
        end
      end
    end
    for _, change in ipairs(changes) do
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(ctx.buf, namespace, change.line, 0, {
        line_hl_group = 'DiffDelete', priority = 150, virt_lines = { { { '  → ' .. change.text, 'DiffAdd' } } },
      })
    end
    local row = math.max(0, math.min(#snapshot.lines - 1, (ctx.cursor or { 1 })[1] - 1))
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(ctx.buf, namespace, row, 0, {
      virt_text = { { ' Preview: ' .. summary(value) .. ' · source unchanged'
        .. (shown > 100 and ' · first 100 changed lines shown' or ''), 'DiagnosticInfo' } },
      virt_text_pos = 'eol', priority = 151,
    })
  end)
  if not ok then cleanup(); error(err) end
  return cleanup
end

function M.replace_spec()
  -- The exact reviewed data is private to this command/environment. A task or
  -- API caller cannot supply a plan, reuse another form's preview, or substitute
  -- inputs between the preview and the final Apply action. Only the Session's
  -- scoped final-field submission can authorize mutation; public arguments and
  -- a visible input form do not confer that authority.
  local receipt, spec
  spec = { id = 'edit.replace_literal', name = 'Replace literal text with preview', aliases = { 'replace-literal' },
    type = 'input', stable_target = true, review_policy = 'explicit_apply',
    description = 'Case-sensitive literal replacement in the current saved or unsaved document. Review, explicitly Apply, one undo step; no file write.',
    available = function(ctx) return target(ctx, true) end,
    arguments = {
      { name = 'find', prompt = 'Find literal text (case-sensitive)', kind = 'text', required = true,
        validate = function(value) return text_valid(value, false) end },
      { name = 'replace', prompt = 'Replacement (literal; empty deletes)', kind = 'text', default = '',
        validate = function(value) return text_valid(value, true) end },
      { name = 'confirm', prompt = 'Apply previewed replacement?', kind = 'boolean', required = true, default = false,
        items = function(ctx, args)
          local ok, value = pcall(plan, ctx, args)
          return { { value = false, label = 'Cancel — keep source unchanged' },
            { value = true, label = ok and ('Apply — ' .. summary(value)) or 'Apply (resolve preview error first)' } }
        end },
    }, preview = function(ctx, args)
      receipt = nil
      ctx.document_review = nil
      if args.find == nil or args.find == '' then return end
      local snapshot = capture(ctx, true)
      local value = prepare(snapshot, args)
      local cleanup = preview(ctx, value, snapshot)
      local valid, reason = target(ctx, true)
      if not valid then cleanup(); error(reason) end
      local CE, state = require('command_tree'), require('command_tree').state()
      local nonce = {}
      ctx.document_review = tostring(nonce)
      -- v2 retains only the compact reviewed plan. The host capture is private
      -- to preparation/preview and a fresh exact-revision capture serves Apply.
      receipt = { plan = value, find = args.find, replace = args.replace or '',
        buf = ctx.buf, win = ctx.win, view = state.buffer, nonce = nonce, id = ctx.document_review, token = CE.environment_token() }
      return cleanup
    end,
    run = function(ctx, args, _, invocation)
      if args.confirm ~= true then return false, 'Cancelled' end
      local CE, state = require('command_tree'), require('command_tree').state()
      local command = CE.registry():get(spec.id)
      if not receipt or not command or command.run ~= spec.run
        or not require('command_tree.session').consume_submission(command, ctx, args, invocation)
        or not CE.is_current_environment(receipt.token) or state.kind ~= 'input'
        or receipt.view and state.buffer ~= receipt.view or ctx.document_review ~= receipt.id
        or ctx.buf ~= receipt.buf or ctx.win ~= receipt.win
        or args.find ~= receipt.find or (args.replace or '') ~= receipt.replace then
        return false, 'Replacement requires its original preview and explicit Apply; reopen the command'
      end
      local reviewed, value = receipt, receipt.plan
      if value.match_count == 0 then return false, 'No matches; the document was not changed' end
      local current = value.contract_version == 2
        and Paged.capture(ctx, function(context) return target(context, true) end) or M.snapshot(ctx, true)
      local next_lines = value.contract_version == 2 and Paged.apply(current, value) or Core.apply(current, value)
      assert(receipt == reviewed and CE.is_current_environment(reviewed.token),
        'Replacement preview ownership changed; reopen the command')
      local valid, reason = target(ctx, true); assert(valid, reason)
      if vim.deep_equal(current.lines, next_lines) then receipt = nil; return true, summary(value) .. '; source already unchanged' end
      local applied, err = pcall(vim.api.nvim_win_call, ctx.win, function()
        -- End an earlier Lua-event edit block; this whole edit is one undo step.
        vim.cmd('let &g:undolevels = &g:undolevels')
        -- Revalidate after the native option boundary too: an OptionSet hook
        -- may intentionally edit or rename the source while closing its block.
        local valid, reason = target(ctx, true); assert(valid, reason)
        assert(receipt == reviewed and CE.is_current_environment(reviewed.token),
          'Replacement preview ownership changed; reopen the command')
        vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, true, next_lines)
      end)
      if not applied then return false, message(err) end
      receipt = nil
      return true, summary(value) .. '; use Undo to reverse the replacement'
    end,
  }
  return spec
end

function M.search_spec()
  local spec
  spec = { id = 'search.document', name = 'Search current document', aliases = { 'docfind' },
    type = 'input', async = true, stable_target = true,
    description = 'Literal, case-sensitive search of the current saved or unsaved document. Results retain the original buffer and revision; no quickfix changes.',
    available = function(ctx) return target(ctx, false) end,
    arguments = { { name = 'query', prompt = 'Literal document text (case-sensitive)', kind = 'text', required = true,
      validate = function(value) return text_valid(value, false) end } },
    run = function(ctx, args, done, invocation)
      local snapshot = capture(ctx, false)
      local found = snapshot.contract_version == 2 and Paged.search(snapshot, args.query) or Core.search(snapshot, args.query, { limit = 200 })
      local valid, reason = target(ctx, false); assert(valid, reason)
      local ref = { buf = ctx.buf, uri = snapshot.uri, revision = snapshot.revision, encoding = snapshot.encoding }
      local locations = {}
      for _, location in ipairs(found.locations) do
        locations[#locations + 1] = { filename = vim.api.nvim_buf_get_name(ctx.buf), bufnr = ctx.buf,
          line = location.range.start.line + 1, col = location.range.start.character + 1,
          text = location.text, valid = true, type = '', document_target = vim.deepcopy(ref) }
      end
      local detail = { kind = 'document', query = args.query, locations = locations,
        locations_status = #locations > 0 and 'ready' or 'empty', locations_truncated = found.truncated,
        locations_message = #locations .. ' literal matches in the captured document'
          .. (found.truncated and '; retained results are limited' or '')
          .. (found.complete == false and '; partial document processing: ' .. tostring(found.reason) or ''),
        document_contract_version = snapshot.contract_version or 1,
        document_complete = found.complete ~= false }
      local CE = require('command_tree')
      local token, origin = CE.environment_token(), CE.state()
      done(true, detail)
      -- Completion may close its form. Never steal a newly opened session or
      -- resurrect results after source/profile ownership has changed.
      vim.schedule(function()
        if not CE.is_current_environment(token) then return end
        local command = CE.registry():get('search.document')
        if not command or command.run ~= spec.run or not target(ctx, false) then return end
        local current = CE.state()
        if current.active and (current.buffer ~= origin.buffer or current.kind ~= origin.kind
          or not vim.deep_equal(current.context, origin.context)) then return end
        CE.open_task_results(invocation.id, { context = vim.deepcopy(ctx), interactive = #vim.api.nvim_list_uis() > 0 })
      end)
    end,
  }
  return spec
end

return M
