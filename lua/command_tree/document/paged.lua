-- Whole-document ownership belongs to the host; pure v2 calls see independent
-- complete-line pages. Only a fully validated plan can produce proposed text.
local Core = require('command_environment.core.document_v2')
local Json = require('command_environment.core.json')
local Data = require('command_environment.core.util')
local K = require('command_tree.keys')
local M = {}
local LIMITS = Core.capabilities().limits
local function now() return vim.uv.hrtime() / 1000000 end
local function budget(deadline)
  assert(now() <= deadline, 'Document processing exceeded the 5 second limit; source unchanged')
end
local function guard(ctx, check)
  local valid, reason
  if check then valid, reason = check(ctx) else valid, reason = K.unchanged(ctx) end
  assert(valid, reason)
  assert(vim.api.nvim_buf_is_loaded(ctx.buf) and vim.bo[ctx.buf].buftype == '', 'The original document is no longer loaded')
  assert(not ctx.document_uri or K.document_uri(ctx.buf) == ctx.document_uri, 'The original document was renamed; reopen the command')
end
local function identity(value)
  return { contract_version = 2, uri = value.uri, revision = value.revision, encoding = value.encoding,
    total_lines = value.total_lines, total_bytes = value.total_bytes }
end
local function same_identity(first, second)
  return first.contract_version == 2 and second.contract_version == 2 and first.uri == second.uri
    and first.revision == second.revision and first.encoding == second.encoding
    and first.total_lines == second.total_lines and first.total_bytes == second.total_bytes
end
local function plain(value, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or Data.kind(value) == 'object'), label .. ' must be plain object data')
end
local function dense(value, maximum, label)
  assert(type(value) == 'table' and (getmetatable(value) == nil or Data.kind(value) == 'array'), label .. ' must be a dense array')
  local count = 0
  for key in next, value do
    count = count + 1
    assert(count <= maximum and type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= maximum,
      label .. ' exceeds its dense array bounds')
  end
  for index = 1, count do assert(rawget(value, index) ~= nil, label .. ' must not contain gaps') end
  return count
end

function M.capture(ctx, check)
  local deadline = now() + LIMITS.processing_timeout_ms
  guard(ctx, check)
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  assert(count <= LIMITS.max_document_lines, 'Document v2 exceeds 10000 lines')
  local bytes = vim.api.nvim_buf_get_offset(ctx.buf, count) - count
  assert(bytes <= LIMITS.max_document_bytes, 'Document v2 exceeds 1 MiB of line content')
  -- One bounded host capture. Page line arrays share immutable string values;
  -- a wire plan never retains another original/proposed whole-document copy.
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, true)
  assert(#lines == count, 'Document capture is incomplete; reopen the command')
  local captured = { contract_version = 2, uri = K.document_uri(ctx.buf), revision = tostring(ctx.changedtick),
    encoding = 'utf-8', total_lines = count, total_bytes = bytes, lines = lines, pages = {}, deadline = deadline }
  local page, page_bytes, actual_bytes = nil, 0, 0
  for index, line in ipairs(lines) do
    if index % LIMITS.max_page_lines == 1 then budget(deadline) end
    assert(#line <= LIMITS.max_line_bytes, 'Document v2 line exceeds 64 KiB')
    actual_bytes = actual_bytes + #line
    if not page or #page.lines == LIMITS.max_page_lines or page_bytes + #line > LIMITS.max_page_bytes then
      page = identity(captured); page.start_line, page.lines = index - 1, {}
      captured.pages[#captured.pages + 1], page_bytes = page, 0
    end
    page.lines[#page.lines + 1], page_bytes = line, page_bytes + #line
  end
  assert(actual_bytes == bytes, 'Document capture byte scope changed; reopen the command')
  guard(ctx, check); budget(deadline)
  return captured
end

local function validate_capture(capture, deadline)
  plain(capture, 'Host document capture')
  local line_count = dense(capture.lines, LIMITS.max_document_lines, 'Host document lines')
  assert(line_count == capture.total_lines, 'Document capture is incomplete')
  local page_count = dense(capture.pages, LIMITS.max_document_lines, 'Document pages')
  assert(page_count > 0, 'Document pages are incomplete')
  local next_line, bytes = 0, 0
  for _, page in ipairs(capture.pages) do
    budget(deadline)
    local valid = Core.validate(page)
    assert(same_identity(valid, capture), 'Document page identity or revision changed')
    assert(valid.start_line == next_line, 'Document pages contain a gap, overlap or duplicate')
    for _, line in ipairs(valid.lines) do
      next_line, bytes = next_line + 1, bytes + #line
      assert(rawget(capture.lines, next_line) == line, 'Document page content changed')
    end
  end
  assert(next_line == capture.total_lines and bytes == capture.total_bytes, 'Document page coverage is incomplete')
  budget(deadline)
end
local function deadline(capture)
  return type(capture.deadline) == 'number' and capture.deadline or (now() + LIMITS.processing_timeout_ms)
end
local function plan_bytes(plan)
  assert(#Json.encode(plan) <= LIMITS.max_plan_bytes, 'Whole-document replacement plan exceeds 512 KiB')
end

function M.prepare(capture, args)
  local finish = deadline(capture)
  validate_capture(capture, finish)
  local plan = identity(capture)
  plan.find, plan.replace, plan.match_count, plan.pages = args.find, args.replace or '', 0, Data.array()
  plan.output_bytes = 0
  local output_bytes = 0
  for _, page in ipairs(capture.pages) do
    budget(finish)
    local value = Core.prepare_replace(page, { find = plan.find, replace = plan.replace })
    plan.match_count = plan.match_count + value.match_count
    assert(plan.match_count <= LIMITS.max_matches, 'Whole-document replacement exceeds 4096 matches')
    output_bytes = output_bytes + value.output_bytes
    assert(output_bytes <= LIMITS.max_output_bytes, 'Whole-document replacement output exceeds 1 MiB')
    -- Retain common identity and inputs once. Each stateless core call still
    -- receives its complete versioned page plan reconstructed at validation.
    local compact = { start_line = value.start_line, line_count = value.line_count,
      match_count = value.match_count, edits = value.edits, output_bytes = value.output_bytes }
    plan.output_bytes = output_bytes
    -- Check the exact added array member before constructing an oversized
    -- aggregate serialization; escaping and changing counters are included.
    local cost = #Json.encode(plan) + #Json.encode(compact) + (#plan.pages > 0 and 1 or 0)
    assert(cost <= LIMITS.max_plan_bytes, 'Whole-document replacement plan exceeds 512 KiB')
    plan.pages[#plan.pages + 1] = compact
  end
  plan.output_bytes = output_bytes
  plan_bytes(plan); budget(finish)
  return plan
end

function M.search(capture, query)
  local finish = deadline(capture)
  validate_capture(capture, finish)
  local result = identity(capture)
  result.locations, result.truncated, result.complete = Data.array(), false, true
  for _, page in ipairs(capture.pages) do
    if now() > finish then
      result.truncated, result.complete, result.reason = true, false, 'Document processing exceeded the 5 second limit'
      break
    end
    local room = LIMITS.max_search_results - #result.locations
    -- When full, ask for one further match rather than claiming missing data
    -- solely because unvisited pages exist. Whole-scope absence remains exact.
    local found = Core.search(page, query, { limit = math.max(1, room) })
    if room == 0 then
      if #found.locations > 0 then result.truncated = true end
    else
      for _, location in ipairs(found.locations) do result.locations[#result.locations + 1] = location end
      result.truncated = result.truncated or found.truncated
    end
  end
  if now() > finish then
    result.truncated, result.complete, result.reason = true, false, 'Document processing exceeded the 5 second limit'
  end
  assert(#Json.encode(result) <= LIMITS.max_output_bytes, 'Whole-document search result exceeds 1 MiB')
  return result
end

local plan_fields = { contract_version = true, uri = true, revision = true, encoding = true,
  total_lines = true, total_bytes = true, find = true, replace = true, match_count = true,
  pages = true, output_bytes = true }
local function validate_plan(capture, plan, finish)
  validate_capture(capture, finish)
  plain(plan, 'Whole-document replacement plan')
  local fields = 0
  for key in next, plan do fields = fields + 1; assert(fields <= 11 and plan_fields[key], 'Unknown whole-document replacement plan field') end
  assert(same_identity(capture, plan), 'Whole-document replacement plan target is stale')
  assert(dense(plan.pages, LIMITS.max_document_lines, 'Replacement plan pages') == #capture.pages,
    'Replacement plan page coverage is incomplete')
  assert(type(plan.match_count) == 'number' and plan.match_count % 1 == 0 and plan.match_count >= 0
    and plan.match_count <= LIMITS.max_matches, 'Whole-document replacement exceeds 4096 matches')
  assert(type(plan.output_bytes) == 'number' and plan.output_bytes % 1 == 0 and plan.output_bytes >= 0
    and plan.output_bytes <= LIMITS.max_output_bytes, 'Whole-document replacement output exceeds 1 MiB')
  plan_bytes(plan)
end
local function render(capture, plan, callback, finish)
  validate_plan(capture, plan, finish)
  local matches, bytes = 0, 0
  for index, page in ipairs(capture.pages) do
    budget(finish)
    local value = plan.pages[index]
    plain(value, 'Replacement page plan')
    local allowed = { start_line = true, line_count = true, match_count = true, edits = true, output_bytes = true }
    local fields = 0
    for key in next, value do fields = fields + 1; assert(fields <= 5 and allowed[key], 'Unknown replacement page plan field') end
    local wire = identity(plan)
    wire.start_line, wire.line_count, wire.match_count = value.start_line, value.line_count, value.match_count
    wire.find, wire.replace, wire.edits, wire.output_bytes = plan.find, plan.replace, value.edits, value.output_bytes
    local lines = Core.apply(page, wire)
    matches, bytes = matches + value.match_count, bytes + value.output_bytes
    assert(matches <= LIMITS.max_matches and bytes <= LIMITS.max_output_bytes, 'Replacement aggregate quota exceeded')
    callback(page, lines)
  end
  assert(matches == plan.match_count and bytes == plan.output_bytes, 'Replacement aggregate plan content changed')
  budget(finish)
end
function M.apply(capture, plan)
  local output = {}
  render(capture, plan, function(_, lines)
    for _, line in ipairs(lines) do output[#output + 1] = line end
  end, deadline(capture))
  return output
end
function M.preview_changes(capture, plan, maximum)
  local changes, count = {}, 0
  render(capture, plan, function(page, lines)
    for index, line in ipairs(lines) do
      if line ~= page.lines[index] then
        count = count + 1
        if #changes < maximum then
          local excerpt = vim.fn.strcharpart(line, 0, 180)
          if vim.fn.strchars(line) > 180 then excerpt = excerpt .. '…' end
          changes[#changes + 1] = { line = page.start_line + index - 1, text = excerpt }
        end
      end
    end
  end, deadline(capture))
  return changes, count
end
return M
