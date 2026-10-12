local K = require("command_tree.keys")
local M = {}
local namespace = vim.api.nvim_create_namespace("command_tree_substitute")
local limits = { lines = 2000, bytes = 262144, line_bytes = 8192, pattern = 512,
  replacement = 4096, output = 1048576, matches = 20000, preview_lines = 100, elapsed_ms = 120 }

local function target(ctx)
  local valid, reason = K.unchanged(ctx)
  if not valid then return false, reason end
  if type(ctx.changedtick) ~= "number" then return false, "Substitution requires a captured document version" end
  if vim.bo[ctx.buf].buftype ~= "" then return false, "Substitution is available in normal file buffers" end
  if not vim.bo[ctx.buf].modifiable then return false, "This buffer cannot be modified" end
  if vim.bo[ctx.buf].readonly then return false, "This buffer is read-only" end
  return true
end

local function pattern_valid(pattern)
  if type(pattern) ~= "string" or pattern == "" then return false, "Enter a Vim pattern; an empty pattern does not repeat the last search" end
  if #pattern > limits.pattern then return false, "Pattern is too long (maximum " .. limits.pattern .. " bytes)" end
  if pattern:find("[%z\r\n]") then return false, "Only patterns within one line are supported" end
  -- Skip escaped backslashes so a literal \\n remains valid. Multiline atoms
  -- cannot be evaluated faithfully against the individual line snapshots.
  local i = 1
  while i <= #pattern do
    if pattern:sub(i, i) == "\\" then
      local next_char = pattern:sub(i + 1, i + 1)
      if next_char == "n" or next_char == "_" then return false, "Multiline patterns are unsupported; use a pattern within each line" end
      i = i + 2
    else i = i + 1 end
  end
  local ok, err = pcall(vim.regex, "\\C" .. pattern)
  return ok, not ok and ("Invalid Vim pattern: " .. tostring(err)) or nil
end

local function replacement_valid(replacement)
  if replacement == nil then return true end
  if type(replacement) ~= "string" then return false, "Replacement must be literal text" end
  if #replacement > limits.replacement then return false, "Replacement is too long (maximum " .. limits.replacement .. " bytes)" end
  if replacement:find("[%z\r\n]") then return false, "Replacement accepts one line of literal text" end
  return true
end

local function range(ctx, scope)
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  if scope == "buffer" then return 0, count end
  if scope == "line" then
    local row = ctx.cursor and ctx.cursor[1]
    assert(type(row) == "number" and row >= 1 and row <= count, "The captured cursor is no longer available")
    return row - 1, row
  end
  if scope == "selection" then
    local selection = ctx.selection
    assert(selection and selection.start and selection.finish, "Select lines before opening this command")
    local first, last = selection.start[1], selection.finish[1]
    assert(type(first) == "number" and type(last) == "number" and first >= 1 and last >= first and last <= count,
      "The captured selection is no longer available")
    -- The scope is deliberately whole selected lines, including block/character
    -- selections. The picker labels it explicitly rather than promising columns.
    return first - 1, last
  end
  error("Choose current line, selected lines, or entire buffer")
end

local function plan(ctx, args)
  local valid, reason = target(ctx)
  assert(valid, reason)
  valid, reason = pattern_valid(args.pattern); assert(valid, reason)
  valid, reason = replacement_valid(args.replacement); assert(valid, reason)
  local first, last = range(ctx, args.scope or (ctx.selection and "selection" or "buffer"))
  assert(last - first <= limits.lines, "Scope exceeds " .. limits.lines .. " lines; select a smaller range")
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, first, last, true)
  local bytes = 0
  for _, line in ipairs(lines) do
    assert(#line <= limits.line_bytes, "A line exceeds " .. limits.line_bytes .. " bytes; choose a smaller scope")
    bytes = bytes + #line
    assert(bytes <= limits.bytes, "Scope exceeds 256 KiB; select a smaller range")
  end
  local result = { first = first, last = last, lines = {}, changed = {}, matches = 0 }
  local replacement, output_bytes, generated_bytes, started = args.replacement or "", 0, 0, vim.uv.hrtime()
  for index, line in ipairs(lines) do
    assert((vim.uv.hrtime() - started) / 1000000 <= limits.elapsed_ms, "Substitution took too long; simplify the pattern or select fewer lines")
    -- A function result is literal. User text such as \=, &, \1, or a slash
    -- never becomes an expression, capture expansion, or an Ex command.
    local callback_failure
    local updated = vim.fn.substitute(line, "\\C" .. args.pattern, function()
      -- Some supported Vim callback bridges repeat errors raised inside the
      -- replacement function. Reject outside that bridge and keep discarded
      -- preview output bounded after the first failure; the source is untouched.
      if callback_failure then return "" end
      result.matches, generated_bytes = result.matches + 1, generated_bytes + #replacement
      if result.matches > limits.matches then callback_failure = "Too many matches; select a smaller range"
      elseif generated_bytes > limits.output then callback_failure = "Replacement output exceeds 1 MiB; reduce the scope or replacement" end
      if callback_failure then return "" end
      return replacement
    end, args.all == false and "" or "g")
    assert(not callback_failure, callback_failure)
    output_bytes = output_bytes + #updated
    assert(output_bytes <= limits.output, "Replacement output exceeds 1 MiB; reduce the scope or replacement")
    result.lines[index] = updated
    if updated ~= line then result.changed[#result.changed + 1] = { row = first + index - 1, text = updated } end
  end
  valid, reason = target(ctx); assert(valid, reason)
  return result
end

local function summary(result)
  return result.matches .. " match(es), " .. #result.changed .. " changed line(s)"
end

local function preview(ctx, args)
  if not args.pattern or args.pattern == "" then return end
  local result = plan(ctx, args)
  local ids, cleaned = {}, false
  local function cleanup()
    if cleaned then return end
    cleaned = true
    if vim.api.nvim_buf_is_valid(ctx.buf) then
      for _, id in ipairs(ids) do pcall(vim.api.nvim_buf_del_extmark, ctx.buf, namespace, id) end
    end
  end
  local ok, err = pcall(function()
    for index, change in ipairs(result.changed) do
      if index > limits.preview_lines then break end
      local text = vim.fn.strcharpart(change.text, 0, 180)
      if vim.fn.strchars(change.text) > 180 then text = text .. "…" end
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(ctx.buf, namespace, change.row, 0, {
        line_hl_group = "DiffDelete", priority = 150,
        virt_lines = { { { "  → " .. text, "DiffAdd" } } },
      })
    end
    local note = " Preview: " .. summary(result) .. " · source unchanged"
    if #result.changed > limits.preview_lines then note = note .. " · first " .. limits.preview_lines .. " lines shown" end
    local row = math.max(0, math.min(vim.api.nvim_buf_line_count(ctx.buf) - 1, (ctx.cursor or { result.first + 1 })[1] - 1))
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(ctx.buf, namespace, row, 0, {
      virt_text = { { note, "DiagnosticInfo" } }, virt_text_pos = "eol", priority = 151,
    })
  end)
  if not ok then cleanup(); error(err) end
  return cleanup
end

local function run(ctx, args)
  if args.confirm ~= true then return false, "Cancelled" end
  local ok, result = pcall(plan, ctx, args)
  if not ok then return false, tostring(result) end
  if result.matches == 0 then return false, "No matches; the document was not changed" end
  if #result.changed == 0 then return true, summary(result) .. "; the document was already unchanged" end
  local applied, err = pcall(vim.api.nvim_win_call, ctx.win, function()
    -- A direct API invocation can share a Lua event with an earlier edit.
    -- Closing that undo block makes the complete substitution one new undo step.
    vim.cmd("let &g:undolevels = &g:undolevels")
    local valid, reason = target(ctx); assert(valid, reason)
    vim.api.nvim_buf_set_lines(ctx.buf, result.first, result.last, true, result.lines)
  end)
  if not applied then return false, tostring(err) end
  return true, summary(result)
end

function M.spec()
  return {
    id = "edit.substitute", name = "Substitute with preview", type = "input", stable_target = true,
    aliases = { "substitute", "replace" },
    description = "Vim pattern within each line; replacement is literal. Case-sensitive unless the pattern contains \\c. Preview, then explicitly Apply.",
    available = target,
    arguments = {
      { name = "scope", prompt = "Scope", kind = "select", required = true,
        default = function(ctx) return ctx.selection and "selection" or "buffer" end,
        items = function(ctx)
          local items = { { value = "line", label = "Current line" }, { value = "buffer", label = "Entire buffer (up to 2000 lines / 256 KiB)" } }
          if ctx.selection then table.insert(items, 1, { value = "selection", label = "Selected lines (whole lines)" }) end
          return items
        end },
      { name = "pattern", prompt = "Vim pattern (within each line)", kind = "text", required = true, validate = pattern_valid },
      { name = "replacement", prompt = "Replacement (literal; empty deletes)", kind = "text", default = "", validate = replacement_valid },
      { name = "all", prompt = "Occurrences", kind = "boolean", required = true, default = true,
        items = { { value = true, label = "All matches in each line" }, { value = false, label = "First match in each line" } } },
      { name = "confirm", prompt = "Apply previewed changes?", kind = "boolean", required = true, default = false,
        items = function(ctx, args)
          local ok, result = pcall(plan, ctx, args)
          return { { value = false, label = "Cancel — keep source unchanged" },
            { value = true, label = ok and ("Apply — " .. summary(result)) or "Apply (resolve preview error first)" } }
        end },
    },
    preview = preview, run = run,
  }
end

return M
