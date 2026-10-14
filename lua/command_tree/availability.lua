-- Read-only, bounded diagnostics. A recovery receipt returns to navigation;
-- it never invokes a command, loads an integration, or changes configuration.
local M = {}
local K = require('command_tree.keys')
local Json = require('command_environment.core.json')
local methods = {
  ['code.action'] = 'textDocument/codeAction', ['code.rename'] = 'textDocument/rename',
  ['code.definition'] = 'textDocument/definition', ['code.declaration'] = 'textDocument/declaration',
  ['code.type_definition'] = 'textDocument/typeDefinition', ['code.implementation'] = 'textDocument/implementation',
  ['code.references'] = 'textDocument/references', ['code.document_symbols'] = 'textDocument/documentSymbol',
  ['code.hover'] = 'textDocument/hover',
}
local titles = {
  ready = 'Available', unavailable = 'Unavailable', stale_target = 'Source changed',
  command_changed = 'Command changed', condition_error = 'Provider check failed', status_error = 'Status inspection failed',
  filetype_missing = 'Filetype is not set', lsp_not_attached = 'Language server is not attached',
  lsp_capability_missing = 'Language capability is unavailable', selection_unsupported = 'Selection is unsupported',
  executable_missing = 'Executable is unavailable', backend_missing = 'Backend is not configured',
  backend_unavailable = 'Backend is unavailable', formatter_unavailable = 'Formatter is unavailable',
}
local context_fields = { 'buf', 'win', 'mode', 'count', 'register', 'cursor', 'changedtick', 'filetype',
  'selection', 'file', 'project_root', 'cwd' }
local function text(value)
  if type(value) ~= 'string' then
    if value == nil then return '' end
    if type(value) == 'number' or type(value) == 'boolean' then value = tostring(value)
    else return '[invalid status text]' end
  end
  local limited = #value > 512
  value = value:sub(1, 512)
  -- Truncating a valid UTF-8 message can split its final character.
  for _ = 1, 4 do
    if Json.valid_utf8(value) then break end
    if not limited then return '[invalid UTF-8 status text]' end
    value = value:sub(1, -2)
  end
  if not Json.valid_utf8(value) then return '[invalid UTF-8 status text]' end
  value = value:gsub('[\r\n\t]+', ' '):gsub('[%z\1-\8\11\12\14-\31\127]', '')
  return value .. (limited and '…' or '')
end
local function add(report, line)
  if #report.lines < 24 then report.lines[#report.lines + 1] = text(line)
  else report.truncated = true end
end
local function guidance(report, line)
  if #report.guidance < 8 then report.guidance[#report.guidance + 1] = text(line) end
end
local function method(command, ctx)
  if command.provider ~= 'lsp' then return nil end
  if command.id == 'code.format' then
    if command.backend ~= nil and command.backend ~= 'LSP' then return nil end
    return ctx.selection and 'textDocument/rangeFormatting' or 'textDocument/formatting'
  end
  return methods[command.id]
end
local function lsp(report, command, ctx, options)
  local requested = method(command, ctx)
  if not requested then return end
  report.method = requested
  add(report, 'Requested capability: ' .. requested)
  local ok, attached = pcall(vim.lsp.get_clients, { bufnr = ctx.buf })
  if not ok or type(attached) ~= 'table' then
    add(report, 'Attached language servers could not be inspected')
    if not report.available then report.code = 'status_error' end
    guidance(report, 'Inspect the language-server configuration; this status view does not start or install a server.')
    return
  end
  report.attached, report.supporting = 0, 0
  for index, client in ipairs(attached) do
    if index > 32 then report.truncated = true; break end
    report.attached = report.attached + 1
    local checked, supported = pcall(function() return client:supports_method(requested, ctx.buf) end)
    if checked and supported == true then report.supporting = report.supporting + 1 end
    add(report, text(type(client) == 'table' and client.name or nil) .. ': '
      .. (checked and (supported == true and 'supports this capability' or 'does not support this capability') or 'capability check failed'))
  end
  if report.attached == 0 then add(report, 'Attached language servers: none') end
  if not report.available and report.code == 'unavailable' then
    if vim.bo[ctx.buf].filetype == '' then report.code = 'filetype_missing'
    elseif report.attached == 0 then report.code = 'lsp_not_attached'
    elseif report.supporting == 0 then report.code = 'lsp_capability_missing' end
  end
  if report.code == 'filetype_missing' then
    guidance(report, 'Use Settings / Select buffer language, then reopen the command for the new filetype.')
  elseif report.code == 'lsp_not_attached' then
    guidance(report, 'Configure a server for this filetype in your Neovim LSP setup and check its executable and project root.')
    guidance(report, 'Wait for the server to attach, then Recheck here. No language-server manager is required by RE35.')
  elseif report.code == 'lsp_capability_missing' then
    guidance(report, 'Use a server that supports the requested capability; attachment alone does not make every Code command available.')
  end
  local integration = options.integrations and options.integrations.lsp
  if integration and type(integration.status) == 'function' then
    local inspected, lines = pcall(integration.status, ctx)
    if not inspected or type(lines) ~= 'table' or getmetatable(lines) ~= nil or not vim.islist(lines) then
      add(report, 'Configured language status callback failed')
    else
      for index, line in ipairs(lines) do
        if index > 16 then report.truncated = true; break end
        add(report, line)
      end
    end
  end
end

local function report_impl(command, ctx, registry, options)
  options = options or {}
  local report = { version = 1, code = 'unavailable', title = titles.unavailable,
    available = false, lines = {}, guidance = {}, command_id = command and text(command.id) or nil }
  local valid, why = K.unchanged(ctx)
  if not valid then
    report.code, report.reason = 'stale_target', text(why)
    report.title = titles[report.code]
    add(report, report.reason)
    guidance(report, 'Reopen Command Environment on the intended source; the old target will not be reused.')
    return report
  end
  if ctx.filetype ~= nil and ctx.filetype ~= vim.bo[ctx.buf].filetype then
    report.code, report.reason = 'stale_target', 'The source filetype changed; reopen the command'
    report.title = titles[report.code]
    add(report, report.reason)
    guidance(report, 'Reopen Command Environment so inputs and capabilities use the new language.')
    return report
  end
  if not command or registry:get(command.id) ~= command then
    report.code, report.reason = 'command_changed', 'The original command was removed or replaced'
    report.title = titles[report.code]
    add(report, report.reason)
    guidance(report, 'Reopen command discovery and inspect its current declaration.')
    return report
  end
  local generation = registry.generation
  local filename, filetype, tick = vim.api.nvim_buf_get_name(ctx.buf), vim.bo[ctx.buf].filetype,
    vim.api.nvim_buf_get_changedtick(ctx.buf)
  local checked, enabled, reason = pcall(registry.available, registry, command.id, ctx)
  report.available = checked and enabled == true
  if report.available then
    report.reason = nil
  elseif checked then
    report.reason = text(reason)
  else
    report.reason = text('Availability inspection failed: ' .. text(enabled))
  end
  report.code = report.available and 'ready' or 'unavailable'
  add(report, 'Command: ' .. command.id)
  add(report, 'Filetype: ' .. (vim.bo[ctx.buf].filetype ~= '' and vim.bo[ctx.buf].filetype or '(not set)'))
  if command.backend then add(report, 'Backend: ' .. text(command.backend)) end
  add(report, report.reason or 'Available in the captured source')
  local reason_text = report.reason or ''
  if not report.available then
    if reason_text:find('Condition failed:', 1, true) or not checked then
      report.code = 'condition_error'
      guidance(report, 'The availability callback failed; inspect the provider configuration and recheck after correcting it.')
    elseif ctx.selection and ctx.selection.mode == '\22' and reason_text:find('Block selection', 1, true) then
      report.code = 'selection_unsupported'
      guidance(report, 'Reopen the command with a character or line selection.')
    elseif reason_text:find('Executable is not available:', 1, true) then
      report.code = 'executable_missing'
      guidance(report, 'Make the declared executable available on PATH, or review its executable in Settings / Tools.')
      guidance(report, 'RE35 will not install a tool or replace its declaration automatically.')
    elseif require('command_tree.backend_editor').supports(command) then
      if reason_text:find('backend is not configured:', 1, true) or reason_text:find('not installed', 1, true) then
        report.code = 'backend_missing'
      else report.code = 'backend_unavailable' end
      report.backend_settings = true
      guidance(report, 'Configure the declared backend in Settings / Backends, then explicitly return to this command.')
      guidance(report, 'A backend change requires draft review and Apply; there is no automatic fallback or retry.')
    elseif command.id == 'code.format' and command.backend and command.backend ~= 'LSP' then
      report.code = 'formatter_unavailable'
      guidance(report, 'Review the selected formatter integration and its executable configuration for this filetype.')
      guidance(report, 'Formatter configuration is owned by that integration; RE35 does not load it during inspection.')
    end
  end
  lsp(report, command, ctx, options)
  if not report.available and #report.guidance == 0 then
    guidance(report, 'Review the provider and captured source, then Recheck. Availability checks never execute this command.')
  end
  -- Availability/status hooks are supplied by the host. Detect synchronous
  -- declaration or source changes before presenting their answer as current.
  if registry.generation ~= generation or registry:get(command.id) ~= command then
    report.code, report.available, report.reason = 'command_changed', false, 'Commands changed during status inspection; reopen the command'
    report.guidance = { 'Reopen discovery to inspect the current command declaration.' }
  elseif not K.valid(ctx) or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= tick
    or vim.api.nvim_buf_get_name(ctx.buf) ~= filename or vim.bo[ctx.buf].filetype ~= filetype then
    report.code, report.available, report.reason = 'stale_target', false, 'The source changed during status inspection; reopen the command'
    report.guidance = { 'Reopen Command Environment on the intended source before running an action.' }
  end
  if report.code == 'command_changed' or report.code == 'stale_target' then
    report.lines = { 'Status inspection was invalidated; previous capability details were discarded.' }
    report.method, report.attached, report.supporting, report.backend_settings = nil, nil, nil, nil
  end
  report.title = titles[report.code] or titles.unavailable
  return report
end

function M.report(command, ctx, registry, options)
  -- Host callbacks may invalidate a buffer/window while it is being inspected.
  -- Contain any follow-up API failure rather than letting status crash the UI.
  local ok, report = pcall(report_impl, command, ctx, registry, options)
  if ok then return report end
  local code = K.valid(ctx) and 'status_error' or 'stale_target'
  return { version = 1, code = code, title = titles[code], available = false,
    command_id = command and text(command.id) or nil,
    reason = code == 'stale_target' and 'The source changed during status inspection; reopen the command'
      or 'Status inspection failed: ' .. text(report),
    lines = { 'Status inspection was interrupted; previous capability details were discarded.' },
    guidance = { 'Reopen the command on its intended source after reviewing the provider configuration.' } }
end

local function plain(value)
  local seen, count, bytes = {}, 0, 0
  local function clone(item, depth)
    count = count + 1
    assert(count <= 512 and depth <= 8, 'Availability recovery exceeds its data bounds')
    local kind = type(item)
    if kind == 'string' then bytes = bytes + #item; assert(bytes <= 65536, 'Availability recovery exceeds its text bounds'); return item end
    if kind == 'nil' or kind == 'boolean' then return item end
    if kind == 'number' then assert(item == item and math.abs(item) < math.huge, 'Invalid availability recovery number'); return item end
    assert(kind == 'table' and getmetatable(item) == nil and not seen[item], 'Availability recovery must contain only plain data')
    seen[item] = true
    local result = {}
    for key, child in pairs(item) do
      assert(type(key) == 'string' or type(key) == 'number' and key >= 1 and key % 1 == 0, 'Invalid availability recovery key')
      if type(key) == 'string' then
        bytes = bytes + #key
        assert(#key <= 256 and bytes <= 65536, 'Availability recovery exceeds its key bounds')
      end
      result[key] = clone(child, depth + 1)
    end
    seen[item] = nil
    return result
  end
  return clone(value, 0)
end
local function root(ctx)
  local found = require('command_tree.project').root(ctx)
  local real = type(found) == 'string' and vim.uv.fs_realpath(found)
  if not real then return nil end
  real = vim.fs.normalize(real)
  return vim.uv.os_uname().sysname == 'Windows_NT' and real:lower() or real
end
function M.capture(command, state, registry)
  if not state or not state.running or state.mode ~= 'availability' then return nil, 'Open availability status before capturing recovery' end
  local unchanged, why = K.unchanged(state.ctx)
  if not unchanged then return nil, why end
  if state.ctx.filetype ~= nil and state.ctx.filetype ~= vim.bo[state.ctx.buf].filetype then
    return nil, 'The source filetype changed; reopen the command'
  end
  if not command or registry:get(command.id) ~= command then return nil, 'The original command changed; reopen its details' end
  local copied, receipt = pcall(function()
    local ctx = {}
    for _, name in ipairs(context_fields) do
      ctx[name] = state.ctx[name]
    end
    return plain({ version = 1, command_id = command.id, context = ctx,
      filename = vim.api.nvim_buf_get_name(ctx.buf), filetype = vim.bo[ctx.buf].filetype, root = root(ctx) })
  end)
  if not copied then return nil, text(receipt) end
  return receipt, { owner = state, command = command, registry = registry, generation = registry.generation,
    mode = state.mode, navigation = state.navigation, receipt = vim.deepcopy(receipt) }
end
function M.validate(receipt, guard, state, registry)
  local copied, data = pcall(plain, receipt)
  if not copied or type(data) ~= 'table' or data.version ~= 1 or type(guard) ~= 'table'
    or not vim.deep_equal(data, guard.receipt) then return false, 'The availability recovery receipt is invalid; reopen the command' end
  if not state or not state.running or guard.owner ~= state or state.mode ~= guard.mode
    or state.navigation ~= guard.navigation then
    return false, 'Command navigation changed; reopen its details'
  end
  if registry ~= guard.registry or registry.generation ~= guard.generation
    or registry:get(data.command_id) ~= guard.command then
    return false, 'Commands or settings changed; reopen the original command'
  end
  local original = data.context
  -- Only captured fields are compared: providers may keep unrelated data in a
  -- context. That data must not enter a receipt or escape process-local memory.
  if not K.valid(state.ctx) then return false, 'The original source window is no longer available' end
  for _, name in ipairs(context_fields) do
    if not vim.deep_equal(state.ctx[name], original[name]) then return false, 'The captured command context changed; reopen it' end
  end
  local unchanged, why = K.unchanged(original)
  if not unchanged then return false, why end
  if vim.api.nvim_buf_get_name(original.buf) ~= data.filename or vim.bo[original.buf].filetype ~= data.filetype then
    return false, 'The original filename or filetype changed; reopen the command'
  end
  local inspected, current = pcall(root, original)
  if not inspected or current ~= data.root then return false, 'Project root changed; reopen the command' end
  return true
end

return M
