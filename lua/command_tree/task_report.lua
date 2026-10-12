-- A task report is an explicit, bounded diagnostic snapshot, never a dump of
-- operation tables. Preview receipts stay in memory and cannot be forged by
-- editing the displayed JSON or serialized profile state.
local M = {}
local receipts = setmetatable({}, { __mode = 'k' })
local LIMIT, OUTPUT_LIMIT = 32768, 8192
local statuses = { pending = true, succeeded = true, failed = true, cancelled = true }
local function get(value, key) if type(value) == 'table' then return rawget(value, key) end end
local function number(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge and value or nil
end
local function identifier(value)
  return type(value) == 'string' and #value <= 128 and value:match('^[%w_.-]+$') and value or '[omitted]'
end
local function scalar(value)
  if type(value) == 'boolean' then return value end
  return number(value)
end
local Search = require('command_environment.core.search_provider')
local Data = require('command_environment.core.util')
local function canonical_data(value, expected)
  if type(value) ~= type(expected) then return false end
  if type(expected) ~= 'table' then return value == expected end
  local kind = Data.kind(expected) or 'object'
  if getmetatable(value) ~= nil and Data.kind(value) ~= kind then return false end
  local fields = 0
  for key, item in next, expected do
    fields = fields + 1
    if not canonical_data(rawget(value, key), item) then return false end
  end
  -- Every branch is bounded by the canonical contract. Extra fields, including
  -- private paths or queries, invalidate the provenance without traversal.
  local count = 0
  for _ in next, value do
    count = count + 1
    if count > fields then return false end
  end
  return count == fields
end
local function search_provider(value)
  local provider = get(value, 'provider')
  if provider ~= 'builtin' and provider ~= 'ripgrep' then return nil end
  local mode, case = get(value, 'mode'), get(value, 'case')
  if mode ~= 'literal' and mode ~= 'regex' or case ~= 'sensitive' and case ~= 'insensitive' then return nil end
  local limits = {}
  for _, key in ipairs({ 'results', 'max_file_bytes', 'read_bytes', 'output_bytes', 'milliseconds' }) do
    limits[key] = get(get(value, 'limits'), key)
  end
  local ok, checked = pcall(function()
    -- The query is excluded from this contract. Rebuild using a fixed local
    -- placeholder; only fresh canonical provenance can enter an export.
    return Search.report(Search.request(provider, '[excluded]', { mode = mode, case = case, limits = limits }), get(value, 'available'))
  end)
  if ok and canonical_data(value, checked) then return checked end
end
local function normalized(path)
  if type(path) ~= 'string' or path == '' then return nil end
  return path:gsub('\\', '/'):gsub('/+$', '')
end
local function within(path, root)
  path, root = normalized(path), normalized(root)
  if not path or not root then return false end
  if vim.fn.has('win32') == 1 then path, root = path:lower(), root:lower() end
  return path == root or path:sub(1, #root + 1) == root .. '/'
end
local function source(ctx)
  local buf = get(ctx, 'buf')
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return nil end
  return { buf = buf, name = vim.api.nvim_buf_get_name(buf), tick = vim.api.nvim_buf_get_changedtick(buf) }
end
local function scrub(value, operation)
  if type(value) ~= 'string' then return nil end
  -- Bound work before pattern matching. Only explicit string output fields are
  -- read; an arbitrary result object and its metamethods are never traversed.
  value = value:sub(1, OUTPUT_LIMIT)
  local target = get(operation, 'process_target')
  for _, path in ipairs({ get(target, 'file') or '', get(target, 'cwd') or '', get(target, 'root') or '',
    get(operation, 'buffer') or '' }) do
    if type(path) == 'string' and #path > 1 then
      value = value:gsub(path:gsub('([^%w])', '%%%1'), '[path]')
      local alternative = path:gsub('\\', '/')
      value = value:gsub(alternative:gsub('([^%w])', '%%%1'), '[path]')
    end
  end
  value = value:gsub('[Aa]uthorization%s*:%s*[^\r\n]+', 'Authorization: [redacted]')
  value = value:gsub('[Bb]earer%s+[%w%._~+/-]+=*', 'Bearer [redacted]')
  -- Preserve the label, remove the entire remainder of its line. This also
  -- handles quoted or whitespace-containing values without guessing their end.
  value = value:gsub('[^\r\n]+', function(line)
    for key in line:gmatch('([%w_-]+)%s*[:=]') do
      local name = key:lower():gsub('[-_]', '')
      if name:find('password', 1, true) or name:find('secret', 1, true) or name:find('token', 1, true)
        or name == 'apikey' or name == 'accesskey' or name == 'credential' then return key .. ': [redacted]' end
    end
    return line
  end)
  value = value:gsub('gh[pousr]_[%w]+', '[credential]'):gsub('github_pat_[%w_]+', '[credential]')
  value = value:gsub('[A-Za-z]:[/\\][^%s"\'<>|]*', '[path]')
  value = value:gsub('[/][%w_.-]+[/][^%s"\'<>|]*', '[path]')
  value = value:gsub('[%z\1-\8\11\12\14-\31\127]', '')
  -- A byte cap may bisect UTF-8; JSON requires valid UTF-8 on every host.
  local clean, index = {}, 1
  while index <= #value do
    local first = value:byte(index)
    local length = first < 128 and 1 or first >= 194 and first <= 223 and 2
      or first >= 224 and first <= 239 and 3 or first >= 240 and first <= 244 and 4 or 0
    local valid = length > 0 and index + length - 1 <= #value
    for position = index + 1, index + length - 1 do
      local byte = value:byte(position)
      if not byte or byte < 128 or byte > 191 then valid = false end
    end
    local second = value:byte(index + 1) or 0
    if length == 3 and (first == 224 and second < 160 or first == 237 and second >= 160)
      or length == 4 and (first == 240 and second < 144 or first == 244 and second > 143) then valid = false end
    if valid then clean[#clean + 1], index = value:sub(index, index + length - 1), index + length
    else index = index + 1 end
  end
  value = table.concat(clean)
  return value
end
local function readable_json(encoded)
  -- Format only the encoder's JSON, never arbitrary operation objects. Quotes
  -- and escapes are tracked so output text remains byte-for-byte equivalent
  -- when decoded, while scalar diagnostic fields have readable separate rows.
  local out, depth, quoted, escaped = {}, 0, false, false
  local function line() out[#out + 1] = '\n' .. string.rep('  ', depth) end
  for index = 1, #encoded do
    local char = encoded:sub(index, index)
    if quoted then
      out[#out + 1] = char
      if escaped then escaped = false elseif char == '\\' then escaped = true elseif char == '"' then quoted = false end
    elseif char == '"' then quoted = true; out[#out + 1] = char
    elseif char == '{' or char == '[' then
      out[#out + 1] = char; depth = depth + 1
      local next_char = encoded:sub(index + 1, index + 1)
      if next_char ~= '}' and next_char ~= ']' then line() end
    elseif char == '}' or char == ']' then
      depth = depth - 1
      local previous = encoded:sub(index - 1, index - 1)
      if previous ~= '{' and previous ~= '[' then line() end
      out[#out + 1] = char
    elseif char == ',' then out[#out + 1] = char; line()
    elseif char == ':' then out[#out + 1] = ': '
    else out[#out + 1] = char end
  end
  return table.concat(out)
end
local function build(operation, options)
  local status, detail = get(operation, 'status'), get(operation, 'detail')
  local target = get(operation, 'process_target')
  local id = number(get(operation, 'id'))
  if not id or id < 1 or id % 1 ~= 0 or not statuses[status] then return nil, 'Invalid retained task record' end
  local host = vim.version()
  local platform = vim.fn.has('win32') == 1 and 'windows' or vim.fn.has('mac') == 1 and 'macos' or 'unix'
  local data = { format = 're35.task-report', version = 1, re35_version = identifier(options.version or 'unknown'),
    host = { editor = 'Neovim', version = ('%d.%d.%d'):format(host.major, host.minor, host.patch), platform = platform },
    task = { id = id, command_id = identifier(get(operation, 'command_id')), status = status,
      backend = identifier(get(operation, 'backend') or (type(target) == 'table' and 'process' or 'unknown')),
      provider = identifier(get(operation, 'provider') or 'unknown') },
    scope = { arguments = 'excluded', environment = 'excluded', paths = 'excluded',
      history = 'excluded', output = options.include_output == true and 'explicit bounded selection' or 'excluded' } }
  for _, key in ipairs({ 'cancel_requested', 'force_requested', 'timed_out' }) do
    data.task[key] = scalar(get(operation, key))
  end
  local started, finished = number(get(operation, 'started')), number(get(operation, 'finished'))
  if started and finished and finished >= started then data.task.elapsed_ms = math.floor((finished - started) / 1e6) end
  data.task.summary = status == 'pending' and 'Pending at preview time'
    or status == 'cancelled' and (get(detail,'termination_confirmed')==false or get(operation,'cancel_state')=='unconfirmed')
      and 'Cancellation completed without termination confirmation'
    or status == 'cancelled' and 'Cancellation confirmed by the backend'
    or status == 'succeeded' and 'Command completed successfully' or 'Command reported a failure'
  local cancel_state = get(operation, 'cancel_state')
  if cancel_state == 'requested' or cancel_state == 'confirmed' or cancel_state == 'unconfirmed' then data.task.cancel_state = cancel_state end
  for _, key in ipairs({ 'exit_code', 'signal', 'cancelled', 'forced', 'termination_confirmed', 'truncated' }) do
    data.task[key] = scalar(get(detail, key))
  end
  data.task.cancel_error = get(operation, 'cancel_error') ~= nil
  data.task.cleanup_error = get(operation, 'cleanup_error') ~= nil
  local process_scope = get(operation, 'process_scope') or get(detail, 'process_scope')
  if ({direct=true,tree=true,['sequential-direct']=true,windows_job=true,linux_group=true,
    ['sequential-windows_job']=true,['sequential-linux_group']=true})[process_scope] then
    data.task.process_scope = process_scope
  end
  local descendants=get(detail,'descendant_termination')
  if descendants=='unknown' or descendants=='confirmed' or descendants=='unconfirmed'then data.task.descendant_termination=descendants end
  local detached=number(get(detail,'detached_observed'))
  if detached and detached%1==0 and detached>=-1 and detached<=65536 then data.task.detached_observed=detached end
  data.search_provider = search_provider(get(detail, 'search_provider'))
  if type(target) == 'table' then
    local file = get(target, 'file')
    local extension = type(file) == 'string' and file:match('%.([%w]+)$') or nil
    data.target = { kind = file == '' and 'project tool' or 'project source',
      source_in_project = within(file, get(target, 'root')), cwd_in_project = within(get(target, 'cwd'), get(target, 'root')),
      extension = extension and #extension <= 16 and extension or nil }
  else data.target = { kind = get(operation, 'buffer') == '' and 'unnamed buffer' or 'editor buffer' } end
  if options.include_output == true then
    local output = get(detail, 'output')
    if type(output) ~= 'string' then output = get(detail, 'stderr') end
    if type(output) ~= 'string' then output = get(detail, 'stdout') end
    data.output = scrub(output, operation) or '[No string process output]'
    data.output_truncated = type(output) == 'string' and #output > OUTPUT_LIMIT or false
    data.output_notice = 'Output can contain undiscovered sensitive text. Review every line before sharing.'
  end
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return nil, 'Diagnostic report exceeds its safe size or encoding limit' end
  encoded = readable_json(encoded)
  if #encoded + 1 > LIMIT then return nil, 'Diagnostic report exceeds its safe size or encoding limit' end
  return data, encoded .. '\n'
end
local function active(receipt)
  local session, frame = receipt.session, receipt.frame
  if session and (session.running == false or session.owner ~= receipt.owner or session.mode ~= 'workspace'
    or not session.stack or session.stack[#session.stack] ~= frame) then return false, 'Report preview is no longer active' end
  if frame and (get(frame, 'data') ~= receipt.frame_data or get(frame.data, 'report_epoch') ~= receipt.epoch
    or get(frame.data, 'report_preview') ~= receipt.preview) then return false, 'Report preview changed; reopen it' end
  for _, saved in ipairs(receipt.sources) do
    if not vim.api.nvim_buf_is_valid(saved.buf) or vim.api.nvim_buf_get_name(saved.buf) ~= saved.name
      or vim.api.nvim_buf_get_changedtick(saved.buf) ~= saved.tick then return false, 'Task source changed; prepare a new report' end
  end
  return true
end
local function revision(operation)
  local target = get(operation, 'process_target')
  local values = {}
  for _, key in ipairs({ 'started', 'finished', 'buffer', 'process_revision' }) do
    local value = get(operation, key)
    if type(value) == 'string' then values[#values + 1] = #value .. ':' .. value:sub(1, 4096)
    elseif number(value) then values[#values + 1] = tostring(value) end
  end
  for _, key in ipairs({ 'file', 'root', 'cwd' }) do
    local value = get(target, key)
    if type(value) == 'string' then values[#values + 1] = #value .. ':' .. value:sub(1, 4096) end
  end
  -- Compare the private, bounded scalar revision inside Lua. Neovim 0.11's
  -- sha256() does not accept NUL-separated Lua strings.
  return table.concat(values, '\0')
end
function M.prepare(operation, options)
  options = type(options) == 'table' and options or {}
  if options.include_output ~= nil and type(options.include_output) ~= 'boolean' then return nil, 'Output inclusion must be an explicit boolean' end
  if options.session ~= nil and type(options.session) ~= 'table' or options.frame ~= nil and type(options.frame) ~= 'table' then
    return nil, 'Report ownership must use an active session and workspace frame'
  end
  local data, encoded = build(operation, options)
  if not data then return nil, encoded end
  local preview = { data = data, encoded = encoded, byte_count = #encoded, include_output = options.include_output == true,
    lines = { 'Task #' .. data.task.id .. ' · ' .. data.task.status,
      'Arguments, environment, paths, history and arbitrary result objects are excluded.',
      options.include_output == true and 'Output included: review it for undiscovered sensitive text.' or 'Process output is excluded. The include-output action selects up to 8 KiB.',
      'Choose an unused JSON destination, review it here, then confirm again to save.', (encoded:gsub('\n$', '')) } }
  local sources = {}
  local original, origin = source(get(operation, 'ctx')), source(options.ctx)
  if original then sources[#sources + 1] = original end
  if origin and (not original or original.buf ~= origin.buf) then sources[#sources + 1] = origin end
  receipts[preview] = { preview = preview, operation = operation, encoded = encoded, revision = revision(operation),
    lines = table.concat(preview.lines, '\n'), byte_count = #encoded,
    options = { version = options.version, descriptor = options.descriptor, include_output = options.include_output == true },
    session = options.session, frame = options.frame, owner = get(options.session, 'owner'),
    frame_data = get(options.frame, 'data'), epoch = get(get(options.frame, 'data'), 'report_epoch'),
    sources = sources }
  return preview
end
function M.validate(preview, operation)
  local receipt = receipts[preview]
  if not receipt or operation ~= receipt.operation then return false, 'Task report receipt is no longer valid' end
  local ok, why = active(receipt)
  if not ok then return false, why end
  local _, encoded = build(operation, receipt.options)
  local lines = get(preview, 'lines')
  if type(lines) ~= 'table' or #lines > 8 then return false, 'Task report preview changed; reopen it' end
  local current_lines = {}
  for index = 1, #lines do
    local line = rawget(lines, index)
    if type(line) ~= 'string' then return false, 'Task report preview changed; reopen it' end
    current_lines[index] = line
  end
  if encoded ~= receipt.encoded or get(preview, 'encoded') ~= receipt.encoded or revision(operation) ~= receipt.revision
    or get(preview, 'byte_count') ~= receipt.byte_count or get(preview, 'include_output') ~= receipt.options.include_output
    or table.concat(current_lines, '\n') ~= receipt.lines then
    return false, 'Task report changed; prepare a new preview'
  end
  return true
end
function M.encode(preview, operation)
  local ok, why = M.validate(preview, operation)
  if not ok then return nil, why end
  return receipts[preview].encoded
end
local ExportFile = require('command_tree.host.export_file')
function M.review_destination(preview, operation, path)
  local ok, why = M.validate(preview, operation)
  if not ok then return nil, why end
  local reviewed, reason = ExportFile.destination(path)
  if not reviewed then return nil, reason end
  receipts[preview].destination = reviewed
  return reviewed.path
end
function M.export(preview, operation, path)
  local ok, why = M.validate(preview, operation)
  if not ok then return false, why end
  local receipt = receipts[preview]
  local saved, result = ExportFile.publish(path, receipt.destination, receipt.encoded,
    function() return M.validate(preview, operation) end)
  if not saved then return false, result end
  receipts[preview] = nil
  return true, result
end
function M.discard(preview) if type(preview) == 'table' then receipts[preview] = nil end end
return M
