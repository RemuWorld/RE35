-- Explicit editing shortcuts are host-owned maps, separate from tree paths.
-- A declaration invokes the same semantic request as every other entry point.
local K = require('command_tree.keys')
local M = { owned = {}, records = {} }
local generation = 0
local allowed_modes = { n = true, x = true, i = true }

local function tokens(key) return K.tokens(K.raw(key), true) end
local function same(first, second) return vim.deep_equal(first, second) end
local function prefix(first, second)
  if #first > #second then return false end
  for index, token in ipairs(first) do if second[index] ~= token then return false end end
  return true
end
local function overlaps(first, second) return prefix(first, second) or prefix(second, first) end
local function maps(mode, buf)
  return buf and vim.api.nvim_buf_get_keymap(buf, mode) or vim.api.nvim_get_keymap(mode)
end
local function lookup(mode, key)
  local wanted = tokens(key)
  for _, map in ipairs(maps(mode)) do if same(tokens(map.lhs), wanted) then return map end end
end
local function owner(mode, key)
  local wanted = tokens(key)
  for _, item in ipairs(M.owned) do if item.mode == mode and same(item.tokens, wanted) then return item end end
end
local function effective_maps(mode)
  local result = {}
  for _, map in ipairs(maps(mode)) do
    local owned = owner(mode, map.lhs)
    if not owned or map.callback ~= owned.callback then result[#result + 1] = map end
  end
  -- Preparing another environment must inspect the original map which clear()
  -- will restore, rather than treating our own temporary replacement as free.
  for _, record in ipairs(M.records) do
    if record.mode == mode then
      local current, owned = lookup(mode, record.map.lhs), owner(mode, record.map.lhs)
      if not current or owned and current.callback == owned.callback then result[#result + 1] = record.map end
    end
  end
  return result
end

function M.validate(declarations, open_key)
  assert(type(declarations) == 'table' and vim.islist(declarations), 'editor_keys must be a list')
  assert(#declarations <= 128, 'editor_keys exceeds 128 bindings')
  local prepared, boundary = {}, tokens(open_key)
  for index, spec in ipairs(declarations) do
    local label = 'editor_keys[' .. index .. ']'
    assert(type(spec) == 'table' and getmetatable(spec) == nil, label .. ' must be a plain table')
    for key in pairs(spec) do
      assert(key == 'key' or key == 'command' or key == 'args' or key == 'mode' or key == 'replace',
        'Unknown ' .. label .. ' field: ' .. tostring(key))
    end
    assert(type(spec.key) == 'string' and spec.key ~= '' and not spec.key:find('\0', 1, true), label .. '.key must be a nonempty key sequence')
    local raw = K.raw(spec.key)
    assert(#raw > 0 and #raw <= 50, label .. '.key exceeds Neovim\'s 50-byte mapping limit')
    assert(spec.replace == nil or type(spec.replace) == 'boolean', label .. '.replace must be a boolean')
    local request, reason = require('command_environment.core.invocation').validate({ command = spec.command, args = spec.args })
    assert(request, label .. ': ' .. tostring(reason))
    local selected = type(spec.mode) == 'table' and spec.mode or { spec.mode == nil and 'n' or spec.mode }
    assert(vim.islist(selected) and #selected > 0 and #selected <= 3, label .. '.mode must select n, x or i')
    local selected_modes, key_tokens = {}, K.tokens(raw, true)
    -- Freeze the actual slot, including Leader/LocalLeader expansion. Later
    -- editor settings must not redirect status checks, removal or restoration.
    local resolved_key = table.concat(key_tokens)
    for _, mode in ipairs(selected) do
      assert(allowed_modes[mode], label .. '.mode supports only n, x and i')
      assert(not selected_modes[mode], label .. '.mode repeats ' .. mode)
      selected_modes[mode] = true
      assert(mode == 'i' or not overlaps(boundary, key_tokens), label .. '.key conflicts with the RE35 entry boundary: ' .. open_key)
      for _, previous in ipairs(prepared) do
        assert(previous.mode ~= mode or not overlaps(previous.tokens, key_tokens),
          label .. '.key conflicts with ' .. previous.origin .. ': ' .. previous.key)
      end
      prepared[#prepared + 1] = { key = resolved_key, mode = mode, tokens = key_tokens,
        request = request, replace = spec.replace == true, origin = label }
    end
  end
  return prepared
end

function M.check(prepared)
  for _, binding in ipairs(prepared) do
    for _, map in ipairs(effective_maps(binding.mode)) do
      local other = tokens(map.lhs)
      if overlaps(binding.tokens, other) then
        assert(binding.replace and same(binding.tokens, other), binding.origin .. ': native ' .. binding.mode .. ' mapping conflicts with ' .. map.lhs
          .. '; choose another key' .. (same(binding.tokens, other) and ' or explicitly set replace = true' or ' (prefix conflicts cannot be replaced)'))
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= 'command-tree' then
        for _, map in ipairs(maps(binding.mode, buf)) do
          assert(not overlaps(binding.tokens, tokens(map.lhs)), binding.origin .. ': buffer-local ' .. binding.mode
            .. ' mapping conflicts with ' .. map.lhs .. ' in buffer ' .. buf .. '; choose another key')
        end
      end
    end
  end
  return true
end

function M.clear()
  generation = generation + 1
  local remaining, pending, errors = {}, {}, {}
  for _, item in ipairs(M.owned) do
    local current = lookup(item.mode, item.key)
    if current and current.callback == item.callback then
      local removed, why = pcall(vim.keymap.del, item.mode, item.key)
      current = lookup(item.mode, item.key)
      if current and current.callback == item.callback then
        remaining[#remaining + 1] = item
        errors[#errors + 1] = 'Could not remove ' .. item.key .. ': ' .. tostring(not removed and why or 'mapping remains installed')
      end
    end
  end
  M.owned = remaining
  for _, record in ipairs(M.records) do
    local current, held = lookup(record.mode, record.map.lhs), owner(record.mode, record.map.lhs)
    if held and current and current.callback == held.callback then
      pending[#pending + 1] = record
    elseif not current then
      local restored, why = pcall(vim.fn.mapset, record.mode, false, record.map)
      if not restored then
        pending[#pending + 1] = record
        errors[#errors + 1] = 'Could not restore ' .. record.map.lhs .. ': ' .. tostring(why)
      end
    end
  end
  M.records = pending
  assert(#errors == 0, table.concat(errors, '; '))
end

function M.setup(declarations, open_key, invoke)
  local prepared = M.validate(declarations, open_key)
  assert(type(invoke) == 'function', 'Editing shortcuts require an invocation callback')
  M.check(prepared)
  M.clear()
  local token = generation
  local ok, reason = xpcall(function()
    -- Check again after original maps have been restored. No map is silently
    -- replaced even if another plugin changed it after candidate preparation.
    M.check(prepared)
    for _, binding in ipairs(prepared) do
      local previous = lookup(binding.mode, binding.key)
      if previous then M.records[#M.records + 1] = { mode = binding.mode, map = previous } end
      local callback = function()
        if token ~= generation or vim.bo.filetype == 'command-tree' then return end
        local accepted, why = invoke(vim.deepcopy(binding.request), { context = K.context(binding.mode), mode = binding.mode })
        if accepted == false and why then vim.notify(tostring(why), vim.log.levels.WARN, { title = 'RE35' }) end
        return accepted, why
      end
      local item = { key = binding.key, mode = binding.mode, tokens = binding.tokens, command = binding.request.command,
        callback = callback, generation = token }
      -- Record before installation so cleanup also handles an editor API which
      -- installs a map and then throws while an environment is being replaced.
      M.owned[#M.owned + 1] = item
      vim.keymap.set(binding.mode, binding.key, callback,
        { silent = true, desc = 'RE35: ' .. binding.request.command })
    end
  end, debug.traceback)
  if not ok then
    local cleaned, cleanup_error = pcall(M.clear)
    error(tostring(reason) .. (not cleaned and '; shortcut cleanup is incomplete: ' .. tostring(cleanup_error) or ''), 0)
  end
end

function M.is_owned(map)
  if not map or type(map.callback) ~= 'function' then return false end
  for _, item in ipairs(M.owned) do if item.callback == map.callback then return true end end
  return false
end

function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local result = {}
  for _, item in ipairs(M.owned) do
    local current, state, reason = lookup(item.mode, item.key), 'active', nil
    if item.generation ~= generation then
      state, reason = 'cleanup_pending', 'This retired shortcut still needs host mapping cleanup'
    elseif not current or current.callback ~= item.callback then
      state, reason = 'replaced', 'Another mapping replaced this RE35 shortcut'
    elseif vim.api.nvim_buf_is_valid(buf) then
      for _, map in ipairs(maps(item.mode, buf)) do if overlaps(item.tokens, tokens(map.lhs)) then
        state, reason = 'shadowed', 'Buffer-local mapping: ' .. map.lhs; break
      end end
    end
    result[#result + 1] = { key = item.key, mode = item.mode, command = item.command, status = state, reason = reason }
  end
  return result
end

return M
