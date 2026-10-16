-- Declared backend choices use the ordinary Settings draft transaction.
-- Recovery is a bounded, process-local navigation receipt, never a retry.
local M = {}
local K = require('command_tree.keys')
-- Only an Apply admitted from the live recovery frame may return automatically.
-- This authorization is process-local and never part of a portable profile.
local apply_returns = setmetatable({}, { __mode = 'k' })
local capabilities = {
  { id = 'file_find', command = 'file.find', label = 'Find project file' },
  { id = 'project_search', command = 'search.project_text', label = 'Search project text' },
}
local function CE() return require('command_tree') end
local function receipt_data(value)
  local seen, items, bytes = {}, 0, 0
  local function clone(child, depth)
    items = items + 1
    assert(items <= 1024 and depth <= 8, 'Recovery exceeds its data bounds')
    local kind = type(child)
    if kind == 'string' then
      bytes = bytes + #child
      assert(bytes <= 65536, 'Recovery exceeds its text bounds')
      return child
    end
    if kind == 'nil' or kind == 'boolean' then return child end
    if kind == 'number' then assert(child == child and math.abs(child) < math.huge, 'Invalid recovery number'); return child end
    assert(kind == 'table' and getmetatable(child) == nil and not seen[child], 'Recovery must contain only plain data')
    seen[child] = true
    local result = {}
    for key, item in pairs(child) do
      assert(type(key) == 'string' or type(key) == 'number' and key >= 1 and key % 1 == 0, 'Invalid recovery key')
      result[key] = clone(item, depth + 1)
    end
    seen[child] = nil
    return result
  end
  return clone(value, 0)
end
local function capability(id)
  for _, spec in ipairs(capabilities) do if spec.id == id or spec.command == id then return spec end end
end
local function selected(data, id)
  local adapters = data.adapters or {}
  return adapters[id] or (adapters.picker == 'telescope' and 'telescope') or 'builtin'
end
local function canonical(path)
  local real = type(path) == 'string' and vim.uv.fs_realpath(path)
  if not real then return nil end
  real = vim.fs.normalize(real)
  return vim.uv.os_uname().sysname == 'Windows_NT' and vim.fn.tolower(real) or real
end
-- Fingerprints must not depend on Lua table iteration order or JSON key order.
local function fingerprint(value)
  local function ordered(item)
    if type(item) ~= 'table' then return item end
    if vim.islist(item) then
      local result = { 'array' }
      for _, child in ipairs(item) do result[#result + 1] = ordered(child) end
      return result
    end
    local keys, result = {}, { 'object' }
    for key in pairs(item) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do result[#result + 1] = { key, ordered(item[key]) } end
    return result
  end
  return vim.fn.sha256(vim.json.encode(ordered(value)))
end
function M.supports(command)
  return capability(type(command) == 'table' and command.id or command) ~= nil
end
function M.query_valid(value)
  local valid = type(value) == 'string' and value ~= '' and #value <= 4096 and not value:find('[\r\n]')
    and not value:find('\0', 1, true) and require('command_environment.core.json').valid_utf8(value)
  return valid, 'The previous project text query cannot be retained; use one nonempty UTF-8 line of at most 4096 bytes and reopen the command'
end
function M.normalize_route(data)
  data.entity, data.detail, data.step = nil, nil, nil
end
local function row(id, label, value)
  return { id = id, key = '', label = label, value = value,
    name = label .. (value and ' = ' .. value or '') }
end
function M.rows(frame, data, session)
  if frame.data.backend_recovery and session and not frame._backend_recovery_owner then
    frame._backend_recovery_owner, frame._backend_recovery_navigation = session, session.navigation
    local id = type(frame.data.backend_recovery) == 'table' and frame.data.backend_recovery.command_id
    frame._backend_recovery_command = type(id) == 'string' and CE().registry():get(id) or nil
  end
  local result = {}
  for _, spec in ipairs(capabilities) do
    local own = (data.adapters or {})[spec.id]
    local value = selected(data, spec.id)
    result[#result + 1] = row(spec.id, spec.label .. ' · ' .. spec.command,
      own and value .. ' (declared)' or value .. ' (inherited)')
  end
  if frame.data.backend_recovery then
    local id = type(frame.data.backend_recovery) == 'table' and frame.data.backend_recovery.command_id
    result[#result + 1] = row('__return_command__', 'Return to original command · ' .. (type(id) == 'string' and id or '(invalid recovery)'))
  end
  return result
end
function M.activate(frame, ctx, session, item, ops)
  if item.id == '__return_command__' then
    if frame.data.draft and not vim.deep_equal(frame.data.base, frame.data.draft) then
      return false, 'Apply or discard the draft before returning to the command'
    end
    if not session.workspace_recover then return false, 'Command recovery is unavailable in this session' end
    return session.workspace_recover(frame.data.backend_recovery)
  end
  local spec = capability(item.id)
  if not spec then return false, 'Select a supported backend capability' end
  if not session.workspace_input then return false, 'Settings input is unavailable' end
  local data, baseline = ops.profile(), ops.baseline()
  local own, effective = (data.adapters or {})[spec.id], selected(data, spec.id)
  local items = {
    { value = false, label = 'Inherited choice (builtin, or the declared picker)' },
    { value = 'builtin', label = 'Builtin · bounded native project scan' },
    { value = 'telescope', label = 'Telescope · requires an already installed plugin' },
  }
  if spec.id=='project_search'then items[#items+1]={value='ripgrep',label='Ripgrep · requires an already installed executable; structured results'}end
  if own and own ~= 'builtin' and own ~= 'telescope' and (own~='ripgrep' or spec.id~='project_search')then
    items[#items + 1] = { value = own, label = own .. ' · preserve the current declaration' }
  end
  return session.workspace_input({ kind = 'select', required = true,
    prompt = spec.label .. ' backend · no installation or automatic fallback',
    items = items, default = own or false }, function(value)
    if value == nil then return end
    if not session.running or session.mode ~= 'workspace' or session.stack[#session.stack] ~= frame then return end
    ops.stage(function(candidate) candidate.adapters[spec.id] = value or nil end,
      { id = 'adapters.' .. spec.id, label = spec.label .. ' backend',
        before = own and own .. ' (declared)' or effective .. ' (inherited)',
        after = value or 'Inherited choice' }, baseline)
  end, ctx)
end
function M.reset(frame, item, ops)
  local spec = capability(item.id)
  if not spec then return false, 'Select a backend choice before resetting it' end
  return ops.stage(function(candidate) candidate.adapters[spec.id] = nil end,
    { id = 'adapters.' .. spec.id, label = spec.label .. ' backend', before = item.value, after = 'Inherited choice' })
end
local origin_fields = { 'mode', 'path', 'query', 'query_cursor', 'filter', 'selected', 'selected_id', 'selected_word',
  'tree_selection', 'tree_selected_entry', 'page' }
function M.capture(command, state, origin)
  local spec = capability(command.id)
  if not spec then return nil, 'This command has no declared backend Settings route' end
  if state.ctx.mode ~= 'n' or state.ctx.selection then return nil, 'Reopen the command from a normal source window' end
  local unchanged, why = K.unchanged(state.ctx)
  if not unchanged then return nil, why end
  if not origin or (origin.mode ~= 'tree' and origin.mode ~= 'search' and origin.mode ~= 'words') then
    return nil, 'Reopen details from command navigation'
  end
  local query = origin.query or ''
  if type(query) ~= 'string' or #query > 16384 then return nil, 'Search query is too large to retain; reopen the command' end
  local root = canonical(require('command_tree.project').root(state.ctx))
  if not root then return nil, 'Project root is unavailable; reopen the command from an existing project' end
  local ctx = {}
  for _, field in ipairs({ 'buf', 'win', 'mode', 'count', 'register', 'cursor', 'changedtick', 'filetype' }) do
    ctx[field] = vim.deepcopy(state.ctx[field])
  end
  local saved = {}
  for _, field in ipairs(origin_fields) do saved[field] = vim.deepcopy(origin[field]) end
  saved.selected_id = command.id
  local profile = CE().profile()
  local attempt = state.backend_query
  local query
  if spec.command == 'search.project_text' and attempt and attempt.command == command then
    if attempt.invalid then return nil, attempt.reason end
    query = attempt.query
  end
  local ok, receipt = pcall(receipt_data, { version = 1, command_id = command.id, capability = spec.id, context = ctx, origin = saved,
    filename = vim.api.nvim_buf_get_name(ctx.buf), root = root,
    profile = fingerprint(profile), runtime = fingerprint(CE().runtime_bindings()), backend = selected(profile, spec.id), query = query })
  return ok and receipt or nil, not ok and tostring(receipt) or nil
end
function M.applied_recovery(receipt, applied_profile)
  if not receipt then return nil end
  local ok, result = pcall(receipt_data, receipt)
  if not ok or type(result) ~= 'table' or result.version ~= 1 or not capability(result.command_id)
    or result.capability ~= capability(result.command_id).id then return nil end
  result.profile, result.runtime = fingerprint(applied_profile), fingerprint(CE().runtime_bindings())
  result.backend = selected(applied_profile, result.capability)
  return result
end
local function validate_recovery(receipt, ctx, inspection)
  local safe = pcall(receipt_data, receipt)
  if not safe then return false, 'The command recovery data is invalid; reopen the command' end
  if type(receipt) ~= 'table' or receipt.version ~= 1 or not capability(receipt.command_id)
    or receipt.capability ~= capability(receipt.command_id).id or type(receipt.origin) ~= 'table'
    or type(receipt.filename) ~= 'string' or type(receipt.root) ~= 'string' then
    return false, 'The command recovery receipt is invalid; reopen the command'
  end
  local original = receipt.context
  if type(original) ~= 'table' or original.mode ~= 'n' or original.selection
    or not K.valid(ctx) or ctx.buf ~= original.buf or ctx.win ~= original.win then
    return false, 'The original command context changed; reopen the command'
  end
  if vim.api.nvim_buf_get_name(original.buf) ~= receipt.filename then return false, 'The source filename changed; reopen the command' end
  if not inspection then
    local unchanged, why = K.unchanged(original)
    if not unchanged then return false, why end
    if canonical(require('command_tree.project').root(original)) ~= receipt.root then return false, 'Project root changed; reopen the command' end
    if fingerprint(CE().profile()) ~= receipt.profile or fingerprint(CE().runtime_bindings()) ~= receipt.runtime then
      return false, 'Settings or command paths changed since this recovery; reopen the command'
    end
    local command = CE().registry():get(receipt.command_id)
    if not command or command.backend ~= receipt.backend then return false, 'The original command backend changed; reopen the command' end
  end
  if receipt.origin.mode ~= 'tree' and receipt.origin.mode ~= 'search' and receipt.origin.mode ~= 'words' then
    return false, 'The original navigation is unavailable; reopen the command'
  end
  if receipt.query ~= nil and (receipt.command_id ~= 'search.project_text' or not M.query_valid(receipt.query)) then
    return false, 'The retained project text query is invalid; reopen the command'
  end
  if type(receipt.origin.path) ~= 'table' or not vim.islist(receipt.origin.path)
    or receipt.origin.query ~= nil and type(receipt.origin.query) ~= 'string' then
    return false, 'The original command navigation is invalid; reopen the command'
  end
  for _, key in ipairs(receipt.origin.path) do if type(key) ~= 'string' then return false, 'The original command path is invalid; reopen the command' end end
  if inspection then
    local ok, fresh = pcall(K.call, ctx, K.context)
    if not ok or not K.valid(fresh) then return false, 'The original command context changed; reopen the command' end
    return true, nil, fresh
  end
  return true
end
function M.validate_recovery(receipt, ctx) return validate_recovery(receipt, ctx, false) end
function M.validate_navigation(receipt, ctx) return validate_recovery(receipt, ctx, true) end
function M.prepare_apply_return(frame, ctx, session, changes)
  local receipt = frame.data.backend_recovery
  if not receipt then return nil end
  local valid, why = M.validate_navigation(receipt, ctx)
  if not valid then return nil, why end
  -- Editing other settings keeps the ordinary Settings navigation. A targeted
  -- backend edit is the only transaction which completes this recovery step.
  if #changes ~= 1 or changes[1].id ~= 'adapters.' .. tostring(receipt.capability) then return nil end
  if not session or not session.running or session.mode ~= 'workspace'
    or session.stack[#session.stack] ~= frame or frame._backend_recovery_owner ~= session
    or frame._backend_recovery_navigation ~= session.navigation then
    return nil, 'Command navigation changed; reopen the command instead of restoring this recovery'
  end
  if CE().registry():get(receipt.command_id) ~= frame._backend_recovery_command then
    return nil, 'The original command changed; reopen its details before returning'
  end
  local token = {}
  apply_returns[token] = vim.deepcopy(receipt)
  return token
end
function M.applied_return(token, receipt)
  if not token then return nil end
  local original = apply_returns[token]
  apply_returns[token] = nil
  if not original or not vim.deep_equal(receipt, M.applied_recovery(original, CE().profile())) then return nil end
  local expected, owner = CE().registry():get(receipt.command_id), CE().environment_token()
  if not expected then return nil end
  local used = false
  return function(session)
    if used then return end
    used = true
    local frame = session.stack[#session.stack]
    if not CE().is_current_environment(owner) or session.workspace_registry ~= CE().registry()
      or session.mode ~= 'workspace' or not frame or frame.id ~= 'settings'
      or not vim.deep_equal(frame.data.backend_recovery, receipt) then return end
    if CE().registry():get(receipt.command_id) ~= expected then
      session.message = 'The original command changed; reopen its details before returning'
      frame.data.message = session.message
      return
    end
    -- Bind the replacement Settings frame exactly as ordinary row rendering
    -- does, then use the same guarded navigation-only Return implementation.
    M.rows(frame, CE().profile(), session)
    local valid, why = M.validate_navigation(receipt, session.ctx)
    if not valid then session.message, frame.data.message = why, why; return end
    local ok, reason = session.workspace_recover(receipt)
    if not ok then session.message, frame.data.message = reason, reason end
  end
end
return M
